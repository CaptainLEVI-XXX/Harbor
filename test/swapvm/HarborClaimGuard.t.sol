// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {LidoClaimFixture} from "test/claims/LidoClaimSecurity.t.sol";
import {HarborClaimGuard} from "src/swapvm/instructions/HarborClaimGuard.sol";
import {HarborExactFill} from "src/swapvm/instructions/HarborExactFill.sol";
import {HarborSwapVMRouter} from "src/swapvm/HarborSwapVMRouter.sol";
import {Context, ContextLib, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";
import {CalldataPtrLib} from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";
import {Opcode} from "@1inch/swap-vm/src/libs/OpcodeList.sol";
import {FillAuthority} from "test/swapvm/HarborExactFill.t.sol";

contract ClaimGuardHarness is HarborSwapVMRouter {
  using ContextLib for Context;
  constructor() HarborSwapVMRouter(address(1), address(2), address(3), "Guard", "1") {}

  function run(bytes calldata args, address tokenIn, address tokenOut, uint256 quantity, bool buy)
    external
    view
    returns (bytes32 beforeHash, bytes32 afterHash)
  {
    Context memory ctx;
    ctx.query.tokenIn = tokenIn;
    ctx.query.tokenOut = tokenOut;
    ctx.swap = SwapRegisters(123, 456, buy ? quantity : 99, buy ? 99 : quantity);
    beforeHash = keccak256(abi.encode(ctx.query, ctx.swap));
    HarborClaimGuard.exec(ctx, args);
    afterHash = keccak256(abi.encode(ctx.query, ctx.swap));
  }

  function runLoop(bytes calldata program, bytes calldata payload, address tokenIn, address tokenOut) external {
    Context memory ctx;
    ctx.vm.programPtr = CalldataPtrLib.from(program);
    ctx.vm.takerArgsPtr = CalldataPtrLib.from(payload);
    ctx.vm.dispatch = _dispatch;
    ctx.query.tokenIn = tokenIn;
    ctx.query.tokenOut = tokenOut;
    ctx.query.isExactIn = true;
    ctx.swap.amountIn = 11;
    ctx.runLoop();
  }
}

contract HarborClaimGuardTest is LidoClaimFixture {
  ClaimGuardHarness internal guard;

  function setUp() public override {
    super.setUp();
    guard = new ClaimGuardHarness();
  }

  function test_GuardPreservesRegistersBothDirections() public view {
    bytes memory args = abi.encode(address(receipt), address(factory), factory.version());
    (bytes32 beforeHash, bytes32 afterHash) = guard.run(args, address(receipt), address(weth), 1, true);
    assertEq(beforeHash, afterHash);
    (beforeHash, afterHash) = guard.run(args, address(weth), address(receipt), 1, false);
    assertEq(beforeHash, afterHash);
    assertEq(uint8(Opcode._56), HarborClaimGuard.OPCODE);
  }

  function testFuzz_RejectsEveryNonUnitQuantity(uint256 quantity, bool buy) public {
    vm.assume(quantity != 1);
    vm.expectRevert();
    guard.run(
      abi.encode(address(receipt), address(factory), uint256(1)),
      buy ? address(receipt) : address(weth),
      buy ? address(weth) : address(receipt),
      quantity,
      buy
    );
  }

  function testFuzz_RejectsNoncanonicalArgumentLength(bytes memory args) public {
    vm.assume(args.length != 96);
    vm.expectRevert();
    guard.run(args, address(receipt), address(weth), 1, true);
  }

  function test_LateGuardFailureRollsBackPrecedingAuthorization() public {
    FillAuthority authority = new FillAuthority();
    bytes memory program = bytes.concat(
      HarborExactFill.build(address(authority), 7, 9), HarborClaimGuard.build(address(receipt), address(factory), 1)
    );
    vm.expectRevert();
    guard.runLoop(program, hex"abcdef", address(receipt), address(weth));
    assertEq(authority.consumed(), 0);
  }

  function test_ChangedFactoryVersionOrFinalizedClaimRejected() public {
    bytes memory args = abi.encode(address(receipt), address(factory), uint256(2));
    vm.expectRevert();
    guard.run(args, address(receipt), address(weth), 1, true);
    queue.setFinalized(id, 1 ether);
    args = abi.encode(address(receipt), address(factory), uint256(1));
    vm.expectRevert();
    guard.run(args, address(receipt), address(weth), 1, true);
  }
}
