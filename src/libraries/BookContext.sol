// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Operation} from "src/types/HarborTypes.sol";

/// @title BookContext
/// @notice One transaction-local context shared by Book and its fixed linked code.
/// @dev ROOT = keccak256("harbor.book.context"). Slots ROOT..ROOT+12 belong
/// exclusively to this library, in the Book's transient store under delegatecall.
/// They are disjoint from compiler persistent storage and Solady guard slots.
/// No entrypoint can supply a slot index. Every successful operation clears all
/// words after Vault completion; reverted frames roll back their own writes.
library BookContext {
  uint256 internal constant ROOT = 0xc90902bae0560bbdb8cea06600b82578524a313f66480dbc5f5fc2132929bc14;
  uint256 internal constant CONTROL = 0; // operation [0..2], phase [3..5], buy [6].
  uint256 internal constant CONTEXT = 1; // Exact intent/operation hash.
  uint256 internal constant HOOK_HASH = 2; // ABI hash of maker/taker/tokens/order.
  uint256 internal constant BEFORE_IN = 3; // Pre-transfer maker input balance, raw units.
  uint256 internal constant BEFORE_OUT = 4; // Pre-transfer maker output balance, raw units.
  uint256 internal constant ROUTE = 5; // Native or receipt route, full width.
  uint256 internal constant CASH = 6; // Trade cash; wrapped shares during an issuer request.
  uint256 internal constant INPUT = 7; // Core VM amountIn before external fees.
  uint256 internal constant OUTPUT = 8; // Core VM amountOut before external fees.
  uint256 internal constant FEE = 9; // Actual cash fee measured from the first hook.
  uint256 internal constant EVIDENCE = 10; // Exact-quantity observation hash.
  uint256 internal constant CLAIM_ADAPTER = 11; // Selected tokenized recovery/export adapter.
  uint256 internal constant CLAIM_ID = 12; // Selected tokenized recovery/export identity.

  enum Phase {
    IDLE,
    OPENED,
    AUTHORIZED,
    INPUT_RECEIVED,
    OUTPUT_AUTHORIZED,
    OUTPUT_SENT
  }

  /// @dev Safety considerations: all callers use the declared 0..12 indices;
  /// ROOT+12 fits uint256. TLOAD changes no memory or persistent state.
  function get(uint256 index) internal view returns (uint256 value) {
    assembly ("memory-safe") { value := tload(add(ROOT, index)) }
  }

  /// @dev Safety considerations: same closed slot domain as get. TSTORE requires
  /// Cancun and a non-static frame; only authenticated mutation paths call set.
  function set(uint256 index, uint256 value) internal {
    assembly ("memory-safe") { tstore(add(ROOT, index), value) }
  }

  function operation() internal view returns (Operation) {
    return Operation(get(CONTROL) & 7);
  }

  function phase() internal view returns (Phase) {
    return Phase((get(CONTROL) >> 3) & 7);
  }

  function buy() internal view returns (bool) {
    return get(CONTROL) & 64 != 0;
  }

  function context() internal view returns (bytes32) {
    return bytes32(get(CONTEXT));
  }

  /// @dev Typed enums constrain both lanes to three bits. This is a whole-word
  /// transition, not a read-modify-write of independent accounting fields.
  function control(Operation op, Phase step, bool buying) internal {
    set(CONTROL, uint256(op) | (uint256(step) << 3) | (buying ? 64 : 0));
  }

  /// @dev Preserve operation and direction while advancing only the phase lane.
  function advance(Phase step) internal {
    set(CONTROL, (get(CONTROL) & ~uint256(56)) | (uint256(step) << 3));
  }

  /// @dev Safety considerations: fixed 13-word range, no memory effects. Explicit
  /// cleanup is required for sequential operations in the same transaction.
  function clear() internal {
    assembly ("memory-safe") {
      for { let i := 0 } lt(i, 13) { i := add(i, 1) } { tstore(add(ROOT, i), 0) }
    }
  }
}
