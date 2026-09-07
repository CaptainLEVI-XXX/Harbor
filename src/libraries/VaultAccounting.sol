// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {WithdrawalQueue} from "src/libraries/WithdrawalQueue.sol";

/// @title VaultAccounting
/// @notice Accounted cash, reserved liabilities and coherent valuation snapshots.
/// @dev The vault supplies measured deltas and authenticated public observations.
library VaultAccounting {
  struct State {
    uint256 cash; // Accounted WETH wei, including reserved exit cash.
    uint256 inventoryValue; // Public mark; never part of cash capacity.
    uint256 claimsValue; // Public mark of residual rights; never part of cash capacity.
    uint256 nav; // Committed share backing after reserved liabilities.
    uint256 supply; // Matching committed ERC-20 supply for conversion reads.
    uint256 portfolioVersion;
    uint256 markedVersion;
    uint256 observedAt;
    uint256 policyVersion;
    bool valid;
    bool insolvent;
    WithdrawalQueue.State withdrawals;
  }

  error CashDeficit(uint256 actual, uint256 accounted);
  error ReservedCash(uint256 available, uint256 requested);
  error InvalidValuation();

  /// @notice Detect physical shortage without recognizing unsolicited surplus.
  function requireBacked(State storage self, uint256 actual) internal view {
    if (actual < self.cash) revert CashDeficit(actual, self.cash);
  }

  /// @notice Unreserved accounted cash; pending rights and inventory contribute zero.
  function available(State storage self, uint256 buffer) internal view returns (uint256) {
    if (self.cash <= self.withdrawals.reserved) return 0;
    uint256 unreserved = self.cash - self.withdrawals.reserved;
    return unreserved > buffer ? unreserved - buffer : 0;
  }

  /// @notice Record a measured external receipt, invalidating previous portfolio marks.
  function receiveCash(State storage self, uint256 amount) internal {
    self.cash += amount;
    invalidate(self);
  }

  /// @notice Debit cash without consuming funded LP reserves.
  function spendCash(State storage self, uint256 amount, uint256 buffer) internal {
    uint256 capacity = available(self, buffer);
    if (amount > capacity) revert ReservedCash(capacity, amount);
    self.cash -= amount;
    invalidate(self);
  }

  /// @notice Mark a changed portfolio unavailable for new issuance or fulfillment.
  function invalidate(State storage self) internal {
    ++self.portfolioVersion;
    self.valid = false;
  }

  /// @notice Store a coherent publicly verified mark with its matching live supply.
  /// @dev No call to an oracle is made by this library. Asset quantities, provenance
  /// and policy authorization must have been verified by the boundary contract.
  function checkpoint(
    State storage self,
    uint256 inventory,
    uint256 claims,
    uint256 supply,
    uint256 observedAt,
    uint256 policyVersion,
    uint256 maxAge
  ) internal {
    if (observedAt == 0 || observedAt > block.timestamp || block.timestamp - observedAt > maxAge) {
      revert InvalidValuation();
    }
    self.inventoryValue = inventory;
    self.claimsValue = claims;
    self.observedAt = observedAt;
    self.policyVersion = policyVersion;
    self.markedVersion = self.portfolioVersion;
    self.valid = true;
    commit(self, supply);
  }

  /// @notice Commit numerator and denominator together, after all external callbacks.
  function commit(State storage self, uint256 supply) internal {
    uint256 assets = self.cash + self.inventoryValue + self.claimsValue;
    uint256 liabilities = self.withdrawals.reserved;
    self.insolvent = assets < liabilities;
    self.nav = assets > liabilities ? assets - liabilities : 0;
    self.supply = supply;
  }

  function fresh(State storage self, uint256 maxAge) internal view returns (bool) {
    return self.valid && !self.insolvent && self.markedVersion == self.portfolioVersion
      && self.observedAt <= block.timestamp && block.timestamp - self.observedAt <= maxAge;
  }
}
