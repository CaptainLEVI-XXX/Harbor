// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SwapVM} from "@1inch/swap-vm/src/SwapVM.sol";
import {ILidoWithdrawalQueue as Queue} from "src/interfaces/ILidoWithdrawalQueue.sol";

interface ILidoQueueHistory {
  function proxy__getImplementation() external view returns (address);
  function getLastCheckpointIndex() external view returns (uint256);
  function findCheckpointHints(uint256[] calldata ids, uint256 first, uint256 last)
    external
    view
    returns (uint256[] memory hints);
}

/// @notice Public Hoodi dependencies; Harbor deployments and transfers stay inside the fork.
/// @dev No latest-block fallback, mock tokens, etching or dependency deployments.
abstract contract HoodiFork is Test {
  uint256 internal constant FORK_BLOCK = 3_602_344;
  address internal constant AQUA = 0xf40826aFd0de1078bc4b39b77E87E42d3b35Fe6A;
  address internal constant ROUTER_ADDRESS = 0x63C78337758eA9c98b4Ce6Cc9988E72e2D8F3303;
  address internal constant ASSET = 0xE0decAa66aED871ac9eb924443D1Bf333Fdb062E;
  address internal constant WSTETH = 0x7E99eE3C66636DE415D2d7C880938F2f40f94De4;
  address internal constant QUEUE = 0xfe56573178f1bcdf53F01A6E9977670dcBBD9186;
  address internal constant IMPLEMENTATION = 0xD0a60e52837e045F4567193Cf8921191C486eCD5;
  uint256 internal constant HISTORICAL_ID = 4989;
  address internal constant HISTORICAL_OWNER = 0xCE90a202b4bEE63e296224212f46d47Bc25D8478;

  function setUp() public virtual {
    vm.createSelectFork("hoodi", forkBlock());
    assertEq(block.chainid, 560048);
    assertEq(block.number, forkBlock());
    assertEq(sha256(AQUA.code), 0x706c1d4144d97a2b44f2c6ed15f0844d8c5b9f4ca9cb6496e889506ade128260);
    assertEq(sha256(ROUTER_ADDRESS.code), 0x3dc8de1feb9cad7f43a5c47d146b4974e71df2f13e61b7d5b8fc43e67a524237);
    assertEq(address(SwapVM(payable(ROUTER_ADDRESS)).AQUA()), AQUA);
    assertEq(address(SwapVM(payable(ROUTER_ADDRESS)).WETH()), ASSET);
    assertGt(ASSET.code.length, 0);
    assertEq(Queue(QUEUE).WSTETH(), WSTETH);
    assertEq(ILidoQueueHistory(QUEUE).proxy__getImplementation(), IMPLEMENTATION);
    assertGt(IMPLEMENTATION.code.length, 0);
  }

  /// @dev New integration tests may pin a newer available snapshot without moving historical recovery tests.
  function forkBlock() internal pure virtual returns (uint256) {
    return FORK_BLOCK;
  }

  /// @dev Minimal Book binding for adapter-only recovery checks; no fake Router.
  function ROUTER() external pure returns (address) {
    return ROUTER_ADDRESS;
  }

  function isIdle() external pure returns (bool) {
    return true;
  }
}
