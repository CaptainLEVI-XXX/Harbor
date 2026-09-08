// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import {ILidoWithdrawalQueue as Queue} from "src/interfaces/ILidoWithdrawalQueue.sol";
import {IHarborClaim, IHarborClaimFactory} from "src/interfaces/IHarborClaim.sol";
import {LidoClaimFactory} from "src/claims/LidoClaimFactory.sol";

contract WethMock is TokenMock {
  constructor() TokenMock("WETH", "WETH") {}
  function deposit() external payable { _mint(msg.sender, msg.value); }
}

contract ClaimQueueMock is ERC721 {
  mapping(uint256 => Queue.WithdrawalRequestStatus) internal _status;
  mapping(uint256 => uint256) internal _payout;
  uint256 public constant MIN_STETH_WITHDRAWAL_AMOUNT = 100;
  uint256 public constant MAX_STETH_WITHDRAWAL_AMOUNT = 1000 ether;
  address public immutable WSTETH_TOKEN;

  constructor(address base) ERC721("mock", "MOCK") { WSTETH_TOKEN = base; }
  function setRequest(uint256 id, address owner, uint256 amount) external {
    _mint(owner, id);
    _status[id] = Queue.WithdrawalRequestStatus(amount, amount, owner, block.timestamp, false, false);
  }
  function finalize(uint256 id, uint256 payout) external { _status[id].isFinalized = true; _payout[id] = payout; }
  function WSTETH() external view returns (address) { return WSTETH_TOKEN; }
  function getWithdrawalStatus(uint256[] calldata ids) external view returns (Queue.WithdrawalRequestStatus[] memory out) {
    out = new Queue.WithdrawalRequestStatus[](ids.length);
    for (uint256 i; i < ids.length; ++i) out[i] = _status[ids[i]];
  }
  function getClaimableEther(uint256[] calldata ids, uint256[] calldata) external view returns (uint256[] memory out) {
    out = new uint256[](ids.length);
    for (uint256 i; i < ids.length; ++i) out[i] = _payout[ids[i]];
  }
  function claimWithdrawals(uint256[] calldata ids, uint256[] calldata) external {
    for (uint256 i; i < ids.length; ++i) {
      require(ownerOf(ids[i]) == msg.sender && _status[ids[i]].isFinalized);
      _status[ids[i]].isClaimed = true;
      _burn(ids[i]);
      (bool ok,) = msg.sender.call{value: _payout[ids[i]]}("");
      require(ok);
    }
  }
  function _update(address to, uint256 id, address auth) internal override returns (address previous) {
    previous = super._update(to, id, auth);
    if (to != address(0)) _status[id].owner = to;
  }
  receive() external payable {}
}

contract LidoClaimFactoryTest is Test {
  WethMock internal weth;
  ClaimQueueMock internal queue;
  LidoClaimFactory internal factory;
  address internal alice = address(0xA11CE);

  function setUp() public {
    weth = new WethMock();
    queue = new ClaimQueueMock(address(weth));
    factory = new LidoClaimFactory(address(queue), address(weth), address(this));
    queue.setRequest(1, alice, 10 ether);
    vm.prank(alice);
    queue.setApprovalForAll(address(factory), true);
  }

  function test_WrapTransfersExclusiveRightAndMintsOneUnit() public {
    vm.prank(alice);
    address receipt = factory.wrap(1);
    assertEq(queue.ownerOf(1), receipt);
    assertEq(uint8(IHarborClaim(receipt).status()), uint8(IHarborClaim.Status.PENDING));
    assertEq(TokenMock(receipt).balanceOf(alice), 1);
    vm.prank(alice);
    vm.expectRevert();
    factory.wrap(1);
  }

  function test_RetirementStopsNewImportsButDoesNotChangeExistingReceipt() public {
    vm.prank(alice);
    address receipt = factory.wrap(1);
    factory.retire();
    assertFalse(factory.active());
    assertEq(uint8(IHarborClaim(receipt).status()), uint8(IHarborClaim.Status.PENDING));
  }

  function test_FullRecoveryPaysOnlyReceiptHolder() public {
    vm.prank(alice);
    address receipt = factory.wrap(1);
    queue.finalize(1, 9 ether);
    vm.deal(address(queue), 9 ether);
    IHarborClaim(receipt).recover(0);
    uint256 before = weth.balanceOf(alice);
    vm.prank(alice);
    IHarborClaim(receipt).redeem(alice);
    assertEq(weth.balanceOf(alice), before + 9 ether);
    assertEq(uint8(IHarborClaim(receipt).status()), uint8(IHarborClaim.Status.CLOSED));
  }
}
