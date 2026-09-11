// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {QuoteValidation} from "src/libraries/QuoteValidation.sol";
import {QuoteValidationReference} from "test/base/QuoteValidationReference.sol";
import {ClaimAccounting} from "src/libraries/ClaimAccounting.sol";
import {BookContext as Context} from "src/libraries/BookContext.sol";
import {SwapQuery} from "@1inch/swap-vm/src/libs/VM.sol";
import {Trade, Side, AmountMode, Operation} from "src/types/HarborTypes.sol";
import {PricingState} from "src/libraries/PricingState.sol";
import {PricingPolicy, PricingCurve} from "src/types/PricingTypes.sol";

/// @notice Differential byte/slot checks reused by existing fuzz entrypoints.
contract PrimitiveChecks is Test {
  mapping(uint256 => bytes32) private _hashes;
  PricingState.State private _policies;
  error Rollback();

  function intent(SwapQuery calldata q, bytes calldata args, bytes calldata payload)
    external
    view
    returns (Trade memory, bytes32)
  {
    return QuoteValidation.intent(q, _hashes, args, payload);
  }

  function originalIntent(SwapQuery calldata q, bytes calldata args, bytes calldata payload)
    external
    view
    returns (Trade memory, bytes32)
  {
    return QuoteValidationReference.intent(q, _hashes, args, payload);
  }

  function encoding(uint256 seed, uint256 version) external {
    Trade memory t;
    t.trader = address(uint160(seed));
    t.receiver = address(2);
    t.tokenIn = address(3);
    t.tokenOut = address(4);
    t.route = seed;
    t.strategyVersion = version;
    t.side = Side(seed & 1);
    t.mode = AmountMode(version & 1);
    SwapQuery memory q;
    q.tokenIn = t.tokenIn;
    q.tokenOut = t.tokenOut;
    q.orderHash = bytes32(version);
    q.isExactIn = t.mode == AmountMode.EXACT_IN;
    _hashes[seed] = q.orderHash;
    bytes memory args = abi.encode(seed, version);
    _compare(q, args, abi.encode(t), true);
    for (uint256 i; i < 7; ++i) {
      if (i == 4) continue; // Full-width route IDs are canonical at every value.
      bytes memory malformed = abi.encode(t);
      uint256 dirty = i < 4 ? (uint256(1) << 200) | seed : 2;
      // Exact 13-word allocation; write only the selected address/enum lane.
      assembly ("memory-safe") { mstore(add(add(malformed, 32), mul(i, 32)), dirty) }
      _compare(q, args, malformed, false);
    }
    _compare(q, args, new bytes(415), false);
    _compare(q, args, bytes.concat(abi.encode(t), hex"00"), false);
    _compare(q, args, "", false);
  }

  function _compare(SwapQuery memory q, bytes memory args, bytes memory payload, bool succeeds) private view {
    (bool ok, bytes memory result) = address(this).staticcall(abi.encodeCall(this.intent, (q, args, payload)));
    (bool oldOk, bytes memory oldResult) =
      address(this).staticcall(abi.encodeCall(this.originalIntent, (q, args, payload)));
    assertEq(ok, succeeds);
    assertEq(ok, oldOk);
    assertEq(result, oldResult); // Includes exact malformed-input revert data.
  }

  function hashAndContext(uint256 bits, uint256 id) external {
    PricingPolicy memory policy = PricingPolicy(
      0.5e18, 0.5e18 + bits % (0.5e18 + 1), bits % (0.05e18 + 1), id % (0.05e18 + 1), bits % (1e18 + 1), id % (1e18 + 1)
    );
    PricingState.configure(_policies, 0, 1, policy, PricingCurve(1e27, 0.9e18, 0.01e18), 1e18);
    assertEq(abi.encode(PricingState.loadPolicy(_policies, 0)), abi.encode(policy));
    address dirty;
    uint256 beforeMemory;
    assembly ("memory-safe") {
      dirty := bits
      beforeMemory := mload(0x40)
    }
    bytes32 actual = ClaimAccounting.key(dirty, id);
    uint256 afterMemory;
    uint256 zeroWord;
    assembly ("memory-safe") {
      afterMemory := mload(0x40)
      zeroWord := mload(0x60)
    }
    assertEq(afterMemory, beforeMemory);
    assertEq(zeroWord, 0);
    assertEq(actual, keccak256(abi.encode(address(uint160(bits)), id)));
    assertEq(Context.ROOT, uint256(keccak256("harbor.book.context")));
    for (uint256 i = 1; i <= 12; ++i) {
      Context.set(i, bits ^ i);
    }
    for (uint256 i; i < 6; ++i) {
      Context.control(Operation.RECOVERY, Context.Phase.IDLE, bits & 1 != 0);
      Context.advance(Context.Phase(i));
      assertEq(uint256(Context.operation()), uint256(Operation.RECOVERY));
      assertEq(uint256(Context.phase()), i);
      assertEq(Context.buy(), bits & 1 != 0);
      for (uint256 j = 1; j <= 12; ++j) {
        assertEq(Context.get(j), bits ^ j);
      }
    }
    uint256 saved = Context.get(Context.CONTROL);
    (bool ok,) = address(this).call(abi.encodeCall(this.clearAndFail, ()));
    assertFalse(ok);
    assertEq(Context.get(Context.CONTROL), saved);
    assertEq(Context.get(Context.CLAIM_ID), bits ^ 12);
    Context.clear();
    for (uint256 i; i <= 12; ++i) {
      assertEq(Context.get(i), 0);
    }
  }

  function clearAndFail() external {
    Context.clear();
    revert Rollback();
  }

  /// @notice Same-state loop comparison; keep results live to prevent elimination.
  function hashGas(uint256 seed) external view returns (uint256 optimized, uint256 straightforward) {
    bytes32 actual;
    uint256 start = gasleft();
    for (uint256 i; i < 64; ++i) {
      actual ^= ClaimAccounting.key(address(uint160(seed)), i);
    }
    optimized = start - gasleft();
    bytes32 expected;
    start = gasleft();
    for (uint256 i; i < 64; ++i) {
      expected ^= keccak256(abi.encode(address(uint160(seed)), i));
    }
    straightforward = start - gasleft();
    assertEq(actual, expected);
  }
}
