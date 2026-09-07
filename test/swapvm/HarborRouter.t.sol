// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Context, ContextLib, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";
import {Salt, Deadline} from "@1inch/swap-vm/src/instructions/Controls.sol";
import {AquaOpcodes} from "@1inch/swap-vm/src/opcodes/AquaOpcodes.sol";
import {CalldataPtrLib} from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";
import {HarborSwapVMRouter} from "src/swapvm/HarborSwapVMRouter.sol";
import {HarborExactFill} from "src/swapvm/instructions/HarborExactFill.sol";
import {FillAuthority} from "test/swapvm/HarborExactFill.t.sol";

/// @notice Test-only entrypoint into the real inherited dispatch and official VM loop.
contract RouterProgramHarness is HarborSwapVMRouter {
  using ContextLib for Context;

  constructor() HarborSwapVMRouter(address(1), address(2), address(3), "Test", "1") {}

  function inspect(bytes calldata program, bytes calldata payload, bool exactIn, bool quoting)
    external
    returns (SwapRegisters memory)
  {
    Context memory ctx;
    ctx.vm.programPtr = CalldataPtrLib.from(program);
    ctx.vm.takerArgsPtr = CalldataPtrLib.from(payload);
    ctx.vm.isStaticContext = quoting;
    ctx.vm.dispatch = _dispatch;
    ctx.query.isExactIn = exactIn;
    ctx.swap = SwapRegisters(100, 200, exactIn ? 11 : 0, exactIn ? 0 : 13);
    ctx.runLoop();
    require(ctx.vm.nextPC == program.length && ctx.takerArgs().length == 0, "program completion");
    return ctx.swap;
  }
}

/// @title HarborRouterTest
/// @notice Native opcode composition, argument bounds and upstream dispatch preservation.
contract HarborRouterTest is Test {
  RouterProgramHarness internal router = new RouterProgramHarness();
  FillAuthority internal authority = new FillAuthority();

  function testFuzz_SaltFillDeadlineComposition(bool exactIn, bool quoting) public {
    vm.warp(1000);
    bytes memory program = bytes.concat(Salt.build(uint64(7)), _fill(), Deadline.build(uint40(2000)));
    SwapRegisters memory r = router.inspect(program, hex"abcdef", exactIn, quoting);
    assertEq(r.amountIn, 11);
    assertEq(r.amountOut, 13);
    assertEq(r.balanceIn, 100);
    assertEq(r.balanceOut, 200);
    assertEq(authority.consumed(), quoting ? 0 : 1);
  }

  function test_LaterUpstreamDeadlineFailureRollsBackBookWrite() public {
    vm.warp(2001);
    bytes memory program = bytes.concat(_fill(), Deadline.build(uint40(2000)));
    vm.expectRevert();
    router.inspect(program, hex"abcdef", true, false);
    assertEq(authority.consumed(), 0);
  }

  function test_ChoppedProgramFailsInOfficialVMLoop() public {
    vm.expectRevert(abi.encodeWithSelector(ContextLib.RunLoopExceedProgramLength.selector, uint256(86), uint256(2)));
    router.inspect(hex"5554", hex"abcdef", true, false);
    assertEq(authority.consumed(), 0);
  }

  function test_UnallocatedOpcodeStillUsesUpstreamRejection() public {
    vm.expectRevert(abi.encodeWithSelector(AquaOpcodes.UnknownOpcode.selector, uint256(0x56)));
    router.inspect(hex"5600", hex"abcdef", true, false);
  }

  function _fill() private view returns (bytes memory) {
    return HarborExactFill.build(address(authority), 7, 9);
  }
}
