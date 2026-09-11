// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {LidoClaimFixture} from "test/base/LidoClaimFixture.sol";
import {ClaimValidation} from "src/libraries/ClaimValidation.sol";
import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";
import {HarborPricing} from "src/swapvm/instructions/HarborPricing.sol";
import {HarborSwapVMRouter} from "src/swapvm/HarborSwapVMRouter.sol";
import {Context, ContextLib, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";
import {CalldataPtrLib} from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";
import {FillAuthority} from "test/swapvm/HarborPricing.t.sol";
import {Extruction, IExtruction} from "@1inch/swap-vm/src/instructions/Extruction.sol";
import {SwapQuery} from "@1inch/swap-vm/src/libs/VM.sol";

contract ClaimGuardTarget is IExtruction {
  function extruction(
    bool,
    uint256 pc,
    SwapQuery calldata q,
    SwapRegisters calldata s,
    bytes calldata args,
    bytes calldata
  ) external view returns (uint256, uint256, SwapRegisters memory) {
    (address receipt, address factory, uint256 version) = abi.decode(args, (address, address, uint256));
    IHarborClaim c = IHarborClaim(receipt);
    bool buy = q.tokenIn == receipt;
    ClaimValidation.check(factory, c.ADAPTER(), version, buy, buy ? s.amountIn : s.amountOut, c.status());
    return (pc, 0, s);
  }
}

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
    (address receipt, address factory, uint256 version) = abi.decode(args, (address, address, uint256));
    IHarborClaim c = IHarborClaim(receipt);
    ClaimValidation.check(factory, c.ADAPTER(), version, buy, quantity, c.status());
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

contract ClaimValidationTest is LidoClaimFixture {
  ClaimGuardHarness internal guard;

  function setUp() public override {
    super.setUp();
    guard = new ClaimGuardHarness();
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

  function test_LateGuardFailureRollsBackPrecedingAuthorization() public {
    FillAuthority authority = new FillAuthority();
    bytes memory program = bytes.concat(
      HarborPricing.build(address(authority), 7, 9),
      Extruction.build(address(new ClaimGuardTarget()), abi.encode(address(receipt), address(factory), uint256(1)))
    );
    vm.expectRevert();
    guard.runLoop(program, hex"abcdef", address(receipt), address(weth));
    assertEq(authority.consumed(), 0);
  }
}
