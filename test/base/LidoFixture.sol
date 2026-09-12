// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;
import {LidoViews} from "src/adapters/lido/LidoViews.sol";

import {Test} from "forge-std/Test.sol";
import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import {ILidoWithdrawalQueue as Queue} from "src/interfaces/ILidoWithdrawalQueue.sol";
import {LidoAdapter} from "src/adapters/LidoAdapter.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {HarborClaimFactory} from "src/claims/HarborClaimFactory.sol";

contract MockWrappedEther is TokenMock {
  constructor() TokenMock("Synthetic ASSET", "ASSET") {}

  function deposit() external payable {
    _mint(msg.sender, msg.value);
  }

  function withdraw(uint256 amount) external {
    _burn(msg.sender, amount);
    payable(msg.sender).transfer(amount);
  }
}

contract MockWstETH is TokenMock {
  uint256 public rate = 1.2e18;
  constructor() TokenMock("Synthetic wstETH", "wstETH") {}

  function getStETHByWstETH(uint256 amount) external view returns (uint256) {
    return amount * rate / 1e18;
  }

  function stETH() external view returns (address) {
    return address(this);
  }

  function getTotalPooledEther() external view returns (uint256) {
    return rate;
  }

  function getTotalShares() external pure returns (uint256) {
    return 1e18;
  }
}

/// @notice Deliberately synthetic finalization and issuer faults, never fork evidence.
contract MockLidoQueue is Queue {
  address public immutable WSTETH;
  uint256 public constant MIN_STETH_WITHDRAWAL_AMOUNT = 100;
  uint256 public constant MAX_STETH_WITHDRAWAL_AMOUNT = 1000 ether;
  uint256 public nextId;
  mapping(uint256 => WithdrawalRequestStatus) internal _statuses;
  mapping(uint256 => uint256) internal _payout;
  uint256 public fault;
  address public callback;
  bool public callbackSucceeded;
  mapping(uint256 => address) public getApproved;

  constructor(address base) {
    WSTETH = base;
  }

  function setFault(uint256 value) external {
    fault = value;
  }

  function setCallback(address target) external {
    callback = target;
  }

  function setFinalized(uint256 id, uint256 amount) external {
    _statuses[id].isFinalized = true;
    _payout[id] = amount;
  }

  function setOwner(uint256 id, address owner) external {
    _statuses[id].owner = owner;
  }

  function approve(address spender, uint256 id) external {
    require(_statuses[id].owner == msg.sender);
    getApproved[id] = spender;
  }

  function transferFrom(address from, address to, uint256 id) public {
    require(!_statuses[id].isClaimed && from == _statuses[id].owner && to != address(0));
    require(msg.sender == from || getApproved[id] == msg.sender);
    _statuses[id].owner = to;
    delete getApproved[id];
  }

  function safeTransferFrom(address from, address to, uint256 id) external {
    transferFrom(from, to, id);
    if (to.code.length != 0) {
      require(
        IERC721Receiver(to).onERC721Received(msg.sender, from, id, "") == IERC721Receiver.onERC721Received.selector
      );
    }
  }

  function ownerOf(uint256 id) external view returns (address) {
    require(!_statuses[id].isClaimed && _statuses[id].owner != address(0));
    return _statuses[id].owner;
  }

  function requestWithdrawalsWstETH(uint256[] calldata amounts, address owner) external returns (uint256[] memory ids) {
    ids = new uint256[](amounts.length);
    for (uint256 i; i < amounts.length; ++i) {
      TokenMock(WSTETH).transferFrom(msg.sender, address(this), amounts[i] - (fault == 1 ? 1 : 0));
      uint256 id = ++nextId;
      uint256 entitlement = MockWstETH(WSTETH).getStETHByWstETH(amounts[i]);
      _statuses[id] = WithdrawalRequestStatus(
        entitlement, amounts[i], fault == 2 ? address(1) : owner, block.timestamp, false, false
      );
      ids[i] = fault == 3 && i != 0 ? ids[0] : id;
    }
  }

  function getWithdrawalStatus(uint256[] calldata ids) external view returns (WithdrawalRequestStatus[] memory s) {
    s = new WithdrawalRequestStatus[](ids.length);
    for (uint256 i; i < ids.length; ++i) {
      s[i] = _statuses[ids[i]];
    }
  }

  function getClaimableEther(uint256[] calldata ids, uint256[] calldata hints)
    external
    view
    returns (uint256[] memory amounts)
  {
    amounts = new uint256[](ids.length);
    for (uint256 i; i < ids.length; ++i) {
      require(hints[i] == 1);
      amounts[i] = _payout[ids[i]];
    }
  }

  function getLastCheckpointIndex() external pure returns (uint256) {
    return 1;
  }

  function findCheckpointHints(uint256[] calldata ids, uint256 first, uint256 last)
    external
    pure
    returns (uint256[] memory hints)
  {
    require(first == 1 && last == 1);
    hints = new uint256[](ids.length);
    for (uint256 i; i < ids.length; ++i) {
      hints[i] = 1;
    }
  }

  function claimWithdrawals(uint256[] calldata ids, uint256[] calldata hints) external {
    for (uint256 i; i < ids.length; ++i) {
      uint256 id = ids[i];
      require(hints[i] == 1 && _statuses[id].owner == msg.sender);
      require(_statuses[id].isFinalized && !_statuses[id].isClaimed);
      if (fault != 4) _statuses[id].isClaimed = true;
      if (callback != address(0)) (callbackSucceeded,) = callback.call(abi.encodeWithSignature("reenter()"));
      uint256 amount = _payout[id];
      if (fault == 5) amount -= 1;
      (bool ok,) = msg.sender.call{value: amount}("");
      require(ok);
    }
  }
}

abstract contract LidoFixture is Test {
  /// @dev Isolated adapter tests model only the Book/Router wrapped-native binding.
  function ROUTER() external view returns (address) {
    return address(this);
  }

  function WETH() external view returns (address) {
    return address(weth);
  }
  MockWrappedEther internal weth;
  MockWstETH internal base;
  MockLidoQueue internal queue;
  LidoAdapter internal adapter;
  HarborClaimFactory internal factory;
  address internal vault = address(0x123456);

  function setUp() public virtual {
    vm.warp(1000);
    weth = new MockWrappedEther();
    base = new MockWstETH();
    queue = new MockLidoQueue(address(base));
    factory = new HarborClaimFactory(address(weth), address(this), 1 days);
    adapter = new LidoAdapter(
      address(this),
      vault,
      address(base),
      address(weth),
      address(queue),
      LidoViews.Config(address(factory), address(this), address(this), 60, 1 days)
    );
    vm.deal(address(queue), 10000 ether);
  }

  function isIdle() external pure returns (bool) {
    return true;
  }

  function _request(uint256 amount) internal returns (uint256 id) {
    uint256 beforeBalance = base.balanceOf(address(adapter));
    base.mint(address(adapter), amount);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = amount;
    id = adapter.request(amounts, beforeBalance)[0].id;
  }
}
