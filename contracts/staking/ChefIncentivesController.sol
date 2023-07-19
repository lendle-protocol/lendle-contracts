// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import '../interfaces/IMultiFeeDistribution.sol';
import '../interfaces/IOnwardIncentivesController.sol';
import '../dependencies/openzeppelin/contracts/IERC20.sol';
import '../dependencies/openzeppelin/contracts/SafeERC20.sol';
import '../dependencies/openzeppelin/contracts/SafeMath.sol';
import '../misc/OwnableUpgradable.sol';

// based on the Sushi MasterChef
// https://github.com/sushiswap/sushiswap/blob/master/contracts/MasterChef.sol
contract ChefIncentivesController is OwnableUpgradable {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  // Info of each user.
  struct UserInfo {
    uint256 amount;
    uint256 rewardDebt;
  }
  // Info of each pool.
  struct PoolInfo {
    uint256 totalSupply;
    uint256 allocPoint; // How many allocation points assigned to this pool.
    uint256 lastRewardTime; // Last second that reward distribution occurs.
    uint256 accRewardPerShare; // Accumulated rewards per share, times 1e12. See below.
    IOnwardIncentivesController onwardIncentives;
  }
  // Info about token emissions for a given time period.
  struct EmissionPoint {
    uint128 startTimeOffset;
    uint128 rewardsPerSecond;
  }

  uint256 public constant VERSION = 0x1;

  address public poolConfigurator;

  IMultiFeeDistribution public rewardMinter;
  uint256 public rewardsPerSecond;
  uint256 public maxMintableTokens;
  uint256 public mintedTokens;

  // Info of each pool.
  address[] public registeredTokens;
  mapping(address => PoolInfo) public poolInfo;

  // Data about the future reward rates. emissionSchedule stored in reverse chronological order,
  // whenever the number of blocks since the start block exceeds the next block offset a new
  // reward rate is applied.
  EmissionPoint[] public emissionSchedule;
  // token => user => Info of each user that stakes LP tokens.
  mapping(address => mapping(address => UserInfo)) public userInfo;
  // user => base claimable balance
  mapping(address => uint256) public userBaseClaimable;
  // Total allocation poitns. Must be the sum of all allocation points in all pools.
  uint256 public totalAllocPoint = 0;
  // The block number when reward mining starts.
  uint256 public startTime;

  // account earning rewards => receiver of rewards for this account
  // if receiver is set to address(0), rewards are paid to the earner
  // this is used to aid 3rd party contract integrations
  mapping(address => address) public claimReceiver;

  event BalanceUpdated(
    address indexed token,
    address indexed user,
    uint256 balance,
    uint256 totalSupply
  );

  /* ========== INITIALIZER ========== */

  function initialize(
    address owner,
    uint128[] memory _startTimeOffset,
    uint128[] memory _rewardsPerSecond,
    address _poolConfigurator,
    IMultiFeeDistribution _rewardMinter,
    uint256 _maxMintable,
    uint256 _startTime
  ) external initializer {
    _transferOwnership(owner);

    poolConfigurator = _poolConfigurator;
    rewardMinter = _rewardMinter;
    uint256 length = _startTimeOffset.length;
    for (uint256 i = length - 1; i + 1 != 0; i--) {
      emissionSchedule.push(
        EmissionPoint({
          startTimeOffset: _startTimeOffset[i],
          rewardsPerSecond: _rewardsPerSecond[i]
        })
      );
    }
    maxMintableTokens = _maxMintable;
    startTime = _startTime;
  }

  // Add a new lp to the pool. Can only be called by the poolConfigurator.
  function addPool(address _token, uint256 _allocPoint) external {
    require(msg.sender == poolConfigurator);
    require(poolInfo[_token].lastRewardTime == 0);
    _updateEmissions();
    totalAllocPoint = totalAllocPoint.add(_allocPoint);
    registeredTokens.push(_token);
    poolInfo[_token] = PoolInfo({
      totalSupply: 0,
      allocPoint: _allocPoint,
      lastRewardTime: block.timestamp,
      accRewardPerShare: 0,
      onwardIncentives: IOnwardIncentivesController(0)
    });
  }

  // Update the given pool's allocation point. Can only be called by the owner.
  function batchUpdateAllocPoint(
    address[] calldata _tokens,
    uint256[] calldata _allocPoints
  ) public onlyOwner {
    require(_tokens.length == _allocPoints.length);
    _massUpdatePools();
    uint256 _totalAllocPoint = totalAllocPoint;
    for (uint256 i = 0; i < _tokens.length; i++) {
      PoolInfo storage pool = poolInfo[_tokens[i]];
      require(pool.lastRewardTime > 0);
      _totalAllocPoint = _totalAllocPoint.sub(pool.allocPoint).add(_allocPoints[i]);
      pool.allocPoint = _allocPoints[i];
    }
    totalAllocPoint = _totalAllocPoint;
  }

  function setOnwardIncentives(
    address _token,
    IOnwardIncentivesController _incentives
  ) external onlyOwner {
    require(poolInfo[_token].lastRewardTime != 0);
    poolInfo[_token].onwardIncentives = _incentives;
  }

  function setClaimReceiver(address _user, address _receiver) external {
    require(msg.sender == _user || msg.sender == owner());
    claimReceiver[_user] = _receiver;
  }

  function poolLength() external view returns (uint256) {
    return registeredTokens.length;
  }

  function claimableReward(
    address _user,
    address[] calldata _tokens
  ) external view returns (uint256[] memory) {
    uint256[] memory claimable = new uint256[](_tokens.length);
    for (uint256 i = 0; i < _tokens.length; i++) {
      address token = _tokens[i];
      PoolInfo storage pool = poolInfo[token];
      UserInfo storage user = userInfo[token][_user];
      uint256 accRewardPerShare = pool.accRewardPerShare;
      uint256 lpSupply = pool.totalSupply;
      if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
        uint256 duration = block.timestamp.sub(pool.lastRewardTime);
        uint256 reward = duration.mul(rewardsPerSecond).mul(pool.allocPoint).div(totalAllocPoint);
        accRewardPerShare = accRewardPerShare.add(reward.mul(1e12).div(lpSupply));
      }
      claimable[i] = user.amount.mul(accRewardPerShare).div(1e12).sub(user.rewardDebt);
    }
    return claimable;
  }

  function _updateEmissions() internal {
    uint256 length = emissionSchedule.length;
    if (block.timestamp > startTime && length > 0) {
      EmissionPoint memory e = emissionSchedule[length - 1];
      if (block.timestamp.sub(startTime) > e.startTimeOffset) {
        _massUpdatePools();
        rewardsPerSecond = uint256(e.rewardsPerSecond);
        emissionSchedule.pop();
      }
    }
  }

  // Update reward variables for all pools
  function _massUpdatePools() internal {
    uint256 totalAP = totalAllocPoint;
    uint256 length = registeredTokens.length;
    for (uint256 i = 0; i < length; ++i) {
      _updatePool(poolInfo[registeredTokens[i]], totalAP);
    }
  }

  // Update reward variables of the given pool to be up-to-date.
  function _updatePool(PoolInfo storage pool, uint256 _totalAllocPoint) internal {
    if (block.timestamp <= pool.lastRewardTime) {
      return;
    }
    uint256 lpSupply = pool.totalSupply;
    if (lpSupply == 0) {
      pool.lastRewardTime = block.timestamp;
      return;
    }
    uint256 duration = block.timestamp.sub(pool.lastRewardTime);
    uint256 reward = duration.mul(rewardsPerSecond).mul(pool.allocPoint).div(_totalAllocPoint);
    pool.accRewardPerShare = pool.accRewardPerShare.add(reward.mul(1e12).div(lpSupply));
    pool.lastRewardTime = block.timestamp;
  }

  function _mint(address _user, uint256 _amount) internal {
    uint256 minted = mintedTokens;
    if (minted.add(_amount) > maxMintableTokens) {
      _amount = maxMintableTokens.sub(minted);
    }
    if (_amount > 0) {
      mintedTokens = minted.add(_amount);
      address receiver = claimReceiver[_user];
      if (receiver == address(0)) receiver = _user;
      rewardMinter.mint(receiver, _amount, true);
    }
  }

  function handleAction(address _user, uint256 _balance, uint256 _totalSupply) external {
    PoolInfo storage pool = poolInfo[msg.sender];
    require(pool.lastRewardTime > 0);
    _updateEmissions();
    _updatePool(pool, totalAllocPoint);
    UserInfo storage user = userInfo[msg.sender][_user];
    uint256 amount = user.amount;
    uint256 accRewardPerShare = pool.accRewardPerShare;
    if (amount > 0) {
      uint256 pending = amount.mul(accRewardPerShare).div(1e12).sub(user.rewardDebt);
      if (pending > 0) {
        userBaseClaimable[_user] = userBaseClaimable[_user].add(pending);
      }
    }
    user.amount = _balance;
    user.rewardDebt = _balance.mul(accRewardPerShare).div(1e12);
    pool.totalSupply = _totalSupply;
    if (pool.onwardIncentives != IOnwardIncentivesController(0)) {
      pool.onwardIncentives.handleAction(msg.sender, _user, _balance, _totalSupply);
    }
    emit BalanceUpdated(msg.sender, _user, _balance, _totalSupply);
  }

  // Claim pending rewards for one or more pools.
  // Rewards are not received directly, they are minted by the rewardMinter.
  function claim(address _user, address[] calldata _tokens) external {
    _updateEmissions();
    uint256 pending = userBaseClaimable[_user];
    userBaseClaimable[_user] = 0;
    uint256 _totalAllocPoint = totalAllocPoint;
    for (uint256 i = 0; i < _tokens.length; i++) {
      PoolInfo storage pool = poolInfo[_tokens[i]];
      require(pool.lastRewardTime > 0);
      _updatePool(pool, _totalAllocPoint);
      UserInfo storage user = userInfo[_tokens[i]][_user];
      uint256 rewardDebt = user.amount.mul(pool.accRewardPerShare).div(1e12);
      pending = pending.add(rewardDebt.sub(user.rewardDebt));
      user.rewardDebt = rewardDebt;
    }
    _mint(_user, pending);
  }
}
