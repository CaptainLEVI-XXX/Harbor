// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title ClaimAccounting
/// @notice Bounded issuer-right ledger; receipts are cash only after external verification.
/// @dev The Book authenticates adapters, ownership and remaining rights before mutation.
library ClaimAccounting {
  uint256 internal constant MAX_ACTIVE = 64;

  /// @notice Live accounting payload with permanent exists/closed replay tombstones.
  /// @dev Closure clears the payload; completed cost and proceeds belong in events.
  struct Claim {
    uint256 route;
    uint256 basis; // Assigned settlement-asset raw units, fixed at request.
    uint256 remaining; // Verified settlement-asset-denominated entitlement, not spendable cash.
    uint256 received; // Cumulative attributable settlement-asset raw units actually recovered.
    bool exists;
    bool closed;
  }

  struct State {
    mapping(bytes32 => Claim) claims;
    bytes32[] active;
    mapping(bytes32 => uint256) indexPlusOne;
  }

  error DuplicateClaim(bytes32 key);
  error InactiveClaim(bytes32 key);
  error ClaimLimit();
  error InvalidRemainingRight();

  /// @notice Domain separates protocol request IDs by immutable adapter identity.
  function key(address adapter, uint256 id) internal pure returns (bytes32) {
    return keccak256(abi.encode(adapter, id));
  }

  /// @notice Register externally verified rights and assigned basis atomically.
  function create(State storage self, bytes32 id, uint256 route, uint256 basis, uint256 entitlement) internal {
    if (self.claims[id].exists) revert DuplicateClaim(id);
    if (self.active.length == MAX_ACTIVE) revert ClaimLimit();
    if (entitlement == 0) revert InvalidRemainingRight();
    self.claims[id] = Claim(route, basis, entitlement, 0, true, false);
    self.active.push(id);
    self.indexPlusOne[id] = self.active.length;
  }

  /// @notice Record measured receipts and the remaining verified entitlement.
  /// @dev Entitlement cannot increase here. A new issuer valuation observation is
  /// not a receipt. Closing requires verified extinction of all remaining rights.
  /// @return closed Whether this call retires the claim's basis exposure.
  /// @return basis Basis retired only on closure, otherwise zero.
  /// @return receipts Lifetime receipts only on closure, otherwise zero.
  function receiveCash(State storage self, bytes32 id, uint256 cash, uint256 remaining)
    internal
    returns (bool closed, uint256 basis, uint256 receipts)
  {
    Claim storage c = self.claims[id];
    if (!c.exists || c.closed) revert InactiveClaim(id);
    if (remaining > c.remaining) revert InvalidRemainingRight();
    c.received += cash;
    c.remaining = remaining;
    if (remaining != 0) return (false, 0, 0);
    basis = c.basis;
    receipts = c.received;
    _close(self, id);
    return (true, basis, receipts);
  }

  /// @notice Retire native representation after verified export without recording cash.
  /// @dev Only whole, unrecovered rights are exportable in the initial integration.
  function transferRight(State storage self, bytes32 id) internal returns (uint256 basis) {
    Claim storage c = self.claims[id];
    if (!c.exists || c.closed) revert InactiveClaim(id);
    if (c.received != 0) revert InvalidRemainingRight();
    basis = c.basis;
    _close(self, id);
  }

  function _close(State storage self, bytes32 id) private {
    Claim storage c = self.claims[id];
    // Keep identity consumption even when the completed economic payload is retired.
    delete c.route;
    delete c.basis;
    delete c.remaining;
    delete c.received;
    c.closed = true;
    uint256 index = self.indexPlusOne[id] - 1;
    bytes32 last = self.active[self.active.length - 1];
    self.active[index] = last;
    self.indexPlusOne[last] = index + 1;
    self.active.pop();
    delete self.indexPlusOne[id];
  }
}
