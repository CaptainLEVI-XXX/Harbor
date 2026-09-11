// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Context, ContextLib, SwapQuery, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";
import {IExtruction} from "@1inch/swap-vm/src/instructions/Extruction.sol";
import {CalldataPtrLib} from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";
import {HarborPricing} from "src/swapvm/instructions/HarborPricing.sol";
import {HarborSwapVMRouter} from "src/swapvm/HarborSwapVMRouter.sol";
import {Trade, AmountMode} from "src/types/HarborTypes.sol";

/// @notice Synthetic extension: amounts and attempted quote writes are test-controlled.
contract FillAuthority is IExtruction {
  uint256 public amountIn = 11;
  uint256 public amountOut = 13;
  uint256 public consumed;
  bool public writeInQuote;

  function configure(uint256 ai, uint256 ao, bool writes) external {
    amountIn = ai;
    amountOut = ao;
    writeInQuote = writes;
  }

  function extruction(
    bool quoting,
    uint256 nextPC,
    SwapQuery calldata query,
    SwapRegisters calldata registers,
    bytes calldata args,
    bytes calldata payload
  ) external returns (uint256, uint256, SwapRegisters memory) {
    (uint256 route, uint256 version) = HarborPricing.parse(args);
    require(route == 7 && version == 9 && keccak256(payload) == keccak256(hex"abcdef"), "binding");
    if (!quoting || writeInQuote) ++consumed;
    Trade memory t;
    t.mode = query.isExactIn ? AmountMode.EXACT_IN : AmountMode.EXACT_OUT;
    return (nextPC, payload.length, HarborPricing.complete(registers, t, amountIn, amountOut, 0, false));
  }
}

contract PricingInstructionHarness is HarborSwapVMRouter {
  using ContextLib for Context;
  constructor() HarborSwapVMRouter(address(1), address(2), address(3), "Test", "1") {}

  function parse(bytes calldata args) external pure returns (uint256, uint256) {
    return HarborPricing.parse(args);
  }

  function run(bytes calldata program, bytes calldata payload, SwapRegisters calldata r, bool exactIn, bool quoting)
    external
    returns (SwapRegisters memory)
  {
    Context memory ctx;
    ctx.vm.isStaticContext = quoting;
    ctx.vm.programPtr = CalldataPtrLib.from(program);
    ctx.vm.takerArgsPtr = CalldataPtrLib.from(payload);
    ctx.vm.dispatch = _dispatch;
    ctx.query.isExactIn = exactIn;
    ctx.query.maker = address(0x1234);
    ctx.swap = r;
    ctx.fee.feeTotal = 99;
    bytes32 queryHash = keccak256(abi.encode(ctx.query));
    ctx.runLoop();
    require(ctx.vm.nextPC == program.length && ctx.vm.isStaticContext == quoting, "VM control changed");
    require(ctx.fee.feeTotal == 99 && keccak256(abi.encode(ctx.query)) == queryHash, "query or fees changed");
    require(ctx.takerArgs().length == 0, "unconsumed payload");
    return ctx.swap;
  }
}

/// @notice Official Extruction dispatch, strict maker args and write-free quote enforcement.
contract HarborPricingTest is Test {
  PricingInstructionHarness internal h = new PricingInstructionHarness();
  FillAuthority internal authority = new FillAuthority();

  function testFuzz_ArgumentsMatchAbiAndRejectMalformed(uint256 route, uint256 version) public {
    bytes memory args = abi.encode(route, version);
    (uint256 r, uint256 v) = h.parse(args);
    assertEq(r, route);
    assertEq(v, version);
    vm.expectRevert(abi.encodeWithSelector(HarborPricing.InvalidArgumentsLength.selector, 65));
    h.parse(bytes.concat(args, hex"00"));
    vm.expectRevert(abi.encodeWithSelector(HarborPricing.InvalidArgumentsLength.selector, 0));
    h.parse("");
  }

  function testFuzz_ExecPreservesRegistersAndConsumesPayload(uint128 ai, uint128 ao, bool exactIn, bool quoting)
    public
  {
    uint256 input = uint256(ai) + 1;
    uint256 output = uint256(ao) + 1;
    authority.configure(input, output, false);
    SwapRegisters memory r = SwapRegisters(123, 456, exactIn ? input : 999, exactIn ? 999 : output);
    SwapRegisters memory result = h.run(HarborPricing.build(address(authority), 7, 9), hex"abcdef", r, exactIn, quoting);
    assertEq(result.balanceIn, 123);
    assertEq(result.balanceOut, 456);
    assertEq(result.amountIn, input);
    assertEq(result.amountOut, output);
    assertEq(authority.consumed(), quoting ? 0 : 1);
  }

  function test_StaticAuthorizationCannotWriteEvenUnderNormalCall() public {
    authority.configure(11, 13, true);
    (bool ok,) = address(h).call{gas: 200_000}(
      abi.encodeCall(
        h.run, (HarborPricing.build(address(authority), 7, 9), hex"abcdef", SwapRegisters(100, 100, 11, 0), true, true)
      )
    );
    assertFalse(ok);
    assertEq(authority.consumed(), 0);
  }
}
