// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LidoAdapter} from "src/adapters/LidoAdapter.sol";
import {IHarborAdapter} from "src/interfaces/IHarborAdapter.sol";
import {ILidoWithdrawalQueue as Queue, IWstETHConversion} from "src/interfaces/ILidoWithdrawalQueue.sol";

interface ILidoQueueHistory {
  function proxy__getImplementation() external view returns (address);
  function getLastCheckpointIndex() external view returns (uint256);
  function findCheckpointHints(uint256[] calldata ids, uint256 first, uint256 last)
    external
    view
    returns (uint256[] memory hints);
}

/// @notice TEST ONLY: isolates production claim code against a historical mature NFT.
/// @dev This setup is absent from the production adapter. It does not prove a new
/// Harbor request matures, nor authorize importing pre-existing rights into a vault.
contract HistoricalLidoHarness is LidoAdapter {
  constructor(address book, address vault, address base, address weth, address queue)
    LidoAdapter(book, vault, base, weth, queue)
  {}

  function seedHistoricalRight(uint256 id) external onlyBook {
    require(Queue(ISSUER).ownerOf(id) == address(this));
    require(!accepted[id]);
    accepted[id] = true;
  }
}

contract LidoAdapterForkTest is Test {
  uint256 private constant FORK_BLOCK = 25_924_311;
  address private constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
  address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address private constant QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
  address private constant IMPLEMENTATION = 0xE42C659Dc09109566720EA8b2De186c2Be7D94D9;
  address private constant VAULT = address(0x484152424f52);
  uint256 private constant HISTORICAL_ID = 134_829;

  function setUp() public {
    string memory rpc = vm.envOr("HARBOR_MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
    vm.createSelectFork(rpc, FORK_BLOCK);
    assertEq(block.chainid, 1);
    assertEq(block.number, FORK_BLOCK);
    assertEq(Queue(QUEUE).WSTETH(), WSTETH);
    assertEq(ILidoQueueHistory(QUEUE).proxy__getImplementation(), IMPLEMENTATION);
    assertGt(IMPLEMENTATION.code.length, 0);
  }

  function test_ForkRealWrappedRequestCreatesAdapterOwnedRight() public {
    LidoAdapter adapter = new LidoAdapter(address(this), VAULT, WSTETH, WETH, QUEUE);
    vm.deal(address(this), 2 ether); // Test ETH only; issuer/token storage is untouched.
    (bool ok,) = WSTETH.call{value: 2 ether}("");
    assertTrue(ok);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = IERC20(WSTETH).balanceOf(address(this));
    assertGt(amounts[0], 0);
    uint256 expected = IWstETHConversion(WSTETH).getStETHByWstETH(amounts[0]);
    IERC20(WSTETH).transfer(address(adapter), amounts[0]);
    IHarborAdapter.Request[] memory requests = adapter.request(amounts, 0);
    assertEq(requests.length, 1);
    assertEq(requests[0].entitlement, expected);
    assertEq(requests[0].shares, amounts[0]);
    assertEq(Queue(QUEUE).ownerOf(requests[0].id), address(adapter));
    assertEq(IERC20(WSTETH).allowance(address(adapter), QUEUE), 0);
    assertEq(IERC20(WSTETH).balanceOf(address(adapter)), 0);
    assertEq(IERC20(WETH).balanceOf(VAULT), 0);
    uint256[] memory ids = new uint256[](1);
    ids[0] = requests[0].id;
    assertFalse(Queue(QUEUE).getWithdrawalStatus(ids)[0].isFinalized);
    vm.expectRevert();
    adapter.claim(requests[0].id, 1);
  }

  function test_ForkHistoricalMatureRightUsesActualIssuerETH() public {
    HistoricalLidoHarness adapter = new HistoricalLidoHarness(address(this), VAULT, WSTETH, WETH, QUEUE);
    uint256[] memory ids = new uint256[](1);
    ids[0] = HISTORICAL_ID;
    Queue.WithdrawalRequestStatus memory status = Queue(QUEUE).getWithdrawalStatus(ids)[0];
    assertTrue(status.isFinalized);
    assertFalse(status.isClaimed);
    assertEq(status.owner, 0x8C309B2a7296AD96C1d6A1B64B74102d8e2e17DF);
    // Fork-only NFT transfer from its actual owner, then explicit harness ledger setup.
    // No finalizer impersonation, oracle/storage edits, or ETH injection into issuer.
    vm.prank(status.owner);
    IERC721(QUEUE).transferFrom(status.owner, address(adapter), HISTORICAL_ID);
    adapter.seedHistoricalRight(HISTORICAL_ID);
    uint256[] memory hints =
      ILidoQueueHistory(QUEUE).findCheckpointHints(ids, 1, ILidoQueueHistory(QUEUE).getLastCheckpointIndex());
    uint256 expected = Queue(QUEUE).getClaimableEther(ids, hints)[0];
    assertGt(expected, 0);
    uint256 issuerBefore = QUEUE.balance;
    uint256 vaultBefore = IERC20(WETH).balanceOf(VAULT);
    uint256 adapterEthBefore = address(adapter).balance;
    uint256 adapterWethBefore = IERC20(WETH).balanceOf(address(adapter));
    (uint256 cash, uint256 remaining) = adapter.claim(HISTORICAL_ID, hints[0]);
    assertEq(cash, expected);
    assertEq(remaining, 0);
    assertEq(QUEUE.balance, issuerBefore - cash);
    assertEq(IERC20(WETH).balanceOf(VAULT), vaultBefore + cash);
    assertEq(address(adapter).balance, adapterEthBefore);
    assertEq(IERC20(WETH).balanceOf(address(adapter)), adapterWethBefore);
    assertTrue(Queue(QUEUE).getWithdrawalStatus(ids)[0].isClaimed);
    emit log_named_uint("actual_issuer_recovery_wei", cash);
  }
}
