pragma solidity 0.7.6;

import '../dependencies/openzeppelin/contracts/SafeMath.sol';
import '../interfaces/IMultiFeeDistribution.sol';

contract TokenVesting {
  using SafeMath for uint256;

  uint256 public startTime;
  uint256 public immutable maxMintableTokens;
  uint256 public mintedTokens;
  IMultiFeeDistribution public minter;
  address public owner;

  struct Vest {
    uint256 duration;
    uint256 total;
    uint256 claimed;
  }

  mapping(address => Vest) public vests;

  constructor(
    IMultiFeeDistribution _minter,
    uint256 _maxMintable,
    address[] memory _receivers,
    uint256[] memory _amounts,
    uint256[] memory _durations
  ) {
    require(_receivers.length == _amounts.length);
    minter = _minter;
    uint256 mintable;
    for (uint256 i = 0; i < _receivers.length; i++) {
      require(vests[_receivers[i]].total == 0);
      require(_durations[i] > 0);
      mintable = mintable.add(_amounts[i]);
      vests[_receivers[i]].total = _amounts[i];
      vests[_receivers[i]].duration = _durations[i];
    }
    require(mintable == _maxMintable);
    maxMintableTokens = mintable;
    owner = msg.sender;
  }

  function start() external {
    require(msg.sender == owner);
    require(startTime == 0);
    startTime = block.timestamp;
  }

  function claimable(address _claimer) external view returns (uint256) {
    if (startTime == 0) return 0;
    Vest storage v = vests[_claimer];
    uint256 elapsedTime = block.timestamp.sub(startTime);
    if (elapsedTime > v.duration) elapsedTime = v.duration;
    uint256 _claimable = v.total.mul(elapsedTime).div(v.duration);
    return _claimable.sub(v.claimed);
  }

  function claim(address _receiver) external {
    require(startTime != 0);
    Vest storage v = vests[msg.sender];
    uint256 elapsedTime = block.timestamp.sub(startTime);
    if (elapsedTime > v.duration) elapsedTime = v.duration;
    uint256 _claimable = v.total.mul(elapsedTime).div(v.duration);
    if (_claimable > v.claimed) {
      uint256 amount = _claimable.sub(v.claimed);
      mintedTokens = mintedTokens.add(amount);
      require(mintedTokens <= maxMintableTokens);
      minter.mint(_receiver, amount, false);
      v.claimed = _claimable;
    }
  }
}
