// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Context, ContextLib, SwapQuery, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";
import {CalldataPtrLib} from "@1inch/solidity-utils/contracts/libraries/CalldataPtr.sol";
import {IHarborFill} from "src/interfaces/IHarborFill.sol";
import {HarborExactFill} from "src/swapvm/instructions/HarborExactFill.sol";

/// @notice Synthetic authority: amounts and attempted quote writes are test-controlled.
contract FillAuthority is IHarborFill {
  uint256 public amountIn = 11;
  uint256 public amountOut = 13;
  uint256 public consumed;
  bool public writeInQuote;

  function configure(uint256 ai, uint256 ao, bool writes) external {
    amountIn = ai;
    amountOut = ao;
    writeInQuote = writes;
  }

  function authorizeFill(bool quoting, SwapQuery calldata, uint256 route, uint256 version, bytes calldata payload)
    external
    returns (uint256, uint256)
  {
    require(route == 7 && version == 9 && keccak256(payload) == keccak256(hex"abcdef"), "binding");
    if (!quoting || writeInQuote) ++consumed;
    return (amountIn, amountOut);
  }
}

contract PackedFillParser {
  function parse(bytes calldata args) external pure returns (address, uint256, uint256) {
    return HarborExactFill.parse(args);
  }
}

contract ExactFillHarness is PackedFillParser {
  using ContextLib for Context;

  function run(bytes calldata args, bytes calldata payload, SwapRegisters calldata r, bool exactIn, bool quoting)
    external
    returns (SwapRegisters memory)
  {
    Context memory ctx;
    ctx.vm.isStaticContext = quoting;
    ctx.vm.nextPC = 123;
    ctx.vm.takerArgsPtr = CalldataPtrLib.from(payload);
    ctx.query.isExactIn = exactIn;
    ctx.query.maker = address(0x1234);
    ctx.swap = r;
    ctx.fee.feeTotal = 99;
    bytes32 queryHash = keccak256(abi.encode(ctx.query));
    HarborExactFill.exec(ctx, args);
    require(ctx.vm.nextPC == 123 && ctx.vm.isStaticContext == quoting, "VM control changed");
    require(ctx.fee.feeTotal == 99 && keccak256(abi.encode(ctx.query)) == queryHash, "query or fees changed");
    require(ctx.takerArgs().length == 0, "unconsumed payload");
    return ctx.swap;
  }
}

/// @notice Readable packed-decoding reference with the same external signature.
contract ReferenceFillParser {
  function parse(bytes calldata args) external pure returns (address book, uint256 route, uint256 version) {
    if (args.length != 84) revert HarborExactFill.InvalidArgumentsLength(args.length);
    book = address(bytes20(args[:20]));
    (route, version) = abi.decode(args[20:], (uint256, uint256));
    if (book == address(0)) revert HarborExactFill.InvalidAuthority();
  }
}

/// @title HarborExactFillTest
/// @notice Differential decoding, instruction isolation and CALL/STATICCALL boundaries.
contract HarborExactFillTest is Test {
  ExactFillHarness internal h = new ExactFillHarness();
  ReferenceFillParser internal referenceParser = new ReferenceFillParser();
  PackedFillParser internal packedParser = new PackedFillParser();
  FillAuthority internal authority = new FillAuthority();

  function testFuzz_PackedParserMatchesReference(address book, uint256 route, uint256 version) public view {
    if (book == address(0)) book = address(1);
    bytes memory args = abi.encodePacked(book, route, version);
    (address b, uint256 r, uint256 v) = h.parse(args);
    (address rb, uint256 rr, uint256 rv) = referenceParser.parse(args);
    assertEq(b, rb);
    assertEq(r, rr);
    assertEq(v, rv);
  }

  function testFuzz_RejectsAllNoncanonicalLengths(uint16 length) public {
    vm.assume(length != 84);
    vm.expectRevert(abi.encodeWithSelector(HarborExactFill.InvalidArgumentsLength.selector, uint256(length)));
    h.parse(new bytes(length));
  }

  function test_RejectsZeroAuthority() public {
    vm.expectRevert(HarborExactFill.InvalidAuthority.selector);
    h.parse(abi.encodePacked(address(0), uint256(7), uint256(9)));
  }

  function testFuzz_ExecPreservesRegistersAndConsumesPayload(uint128 ai, uint128 ao, bool exactIn, bool quoting)
    public
  {
    uint256 amountIn = uint256(ai) + 1;
    uint256 amountOut = uint256(ao) + 1;
    authority.configure(amountIn, amountOut, false);
    SwapRegisters memory r = SwapRegisters(123, 456, exactIn ? amountIn : 999, exactIn ? 999 : amountOut);
    SwapRegisters memory result = h.run(_args(), hex"abcdef", r, exactIn, quoting);
    assertEq(result.balanceIn, 123);
    assertEq(result.balanceOut, 456);
    assertEq(result.amountIn, amountIn);
    assertEq(result.amountOut, amountOut);
    assertEq(authority.consumed(), quoting ? 0 : 1);
  }

  function test_StaticAuthorizationCannotWriteEvenUnderNormalCall() public {
    authority.configure(11, 13, true);
    (bool ok,) = address(h).call{gas: 200_000}(
      abi.encodeCall(h.run, (_args(), hex"abcdef", SwapRegisters(100, 100, 11, 0), true, true))
    );
    assertFalse(ok);
    assertEq(authority.consumed(), 0);
  }

  function test_ChangedSpecifiedAmountRollsBackAuthorization() public {
    vm.expectRevert(HarborExactFill.InvalidAmounts.selector);
    h.run(_args(), hex"abcdef", SwapRegisters(100, 100, 12, 0), true, false);
    assertEq(authority.consumed(), 0);
    vm.expectRevert(HarborExactFill.InvalidAmounts.selector);
    h.run(_args(), hex"abcdef", SwapRegisters(100, 100, 0, 14), false, false);
    assertEq(authority.consumed(), 0);
  }

  function test_ZeroPairRejected() public {
    authority.configure(11, 0, false);
    vm.expectRevert(HarborExactFill.InvalidAmounts.selector);
    h.run(_args(), hex"abcdef", SwapRegisters(100, 100, 11, 0), true, false);
    assertEq(authority.consumed(), 0);
  }

  function test_PackedParserGasAgainstReadableReference() public {
    bytes memory args = _args();
    packedParser.parse(args);
    uint256 optimized = vm.lastFrameGas().gasTotalUsed;
    referenceParser.parse(args);
    uint256 readable = vm.lastFrameGas().gasTotalUsed;
    emit log_named_uint("packed parser call gas", optimized);
    emit log_named_uint("reference parser call gas", readable);
    assertLt(optimized, readable);
  }

  function _args() private view returns (bytes memory) {
    return abi.encodePacked(address(authority), uint256(7), uint256(9));
  }
}
