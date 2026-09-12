// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {LPExitQueue} from "src/libraries/LPExitQueue.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";

/// @title VaultLedger
/// @notice Accounted cash, reserved liabilities and coherent valuation snapshots.
/// @dev The vault supplies measured deltas and authenticated public observations.
library VaultLedger {
  /// @dev Paired with one virtual asset wei; shared by conversions and numeric limits.
  uint256 internal constant VIRTUAL_SHARES = 1e6;

  struct State {
    uint256 cash; // Accounted settlement-asset raw units, including reserved exit cash.
    uint256 inventoryValue; // Public mark; never part of cash capacity.
    uint256 claimsValue; // Public mark of residual rights; never part of cash capacity.
    uint256 nav; // Committed share backing after reserved liabilities.
    uint256 supply; // Matching committed ERC-20 supply for conversion reads.
    uint256 observedAt;
    bool valid;
    bool insolvent;
    LPExitQueue.State withdrawals;
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
    uint256 maxAge
  ) internal {
    if (observedAt == 0 || observedAt > block.timestamp || block.timestamp - observedAt > maxAge) {
      revert InvalidValuation();
    }
    self.inventoryValue = inventory;
    self.claimsValue = claims;
    self.observedAt = observedAt;
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
    return
      self.valid && !self.insolvent && self.observedAt <= block.timestamp && block.timestamp - self.observedAt <= maxAge;
  }

  /// @notice Numeric headroom, not an economic deposit cap. Reserves remain in gross backing.
  /// @dev Bound both virtualized additions and exact ERC4626 floor/ceil issuance.
  /// @dev Caller proves gross < uint256.max and supply <= max - VIRTUAL_SHARES.
  /// Scalar inputs let read-only issuance use current marks without storing them.
  function headroom(uint256 nav, uint256 supply, uint256 gross) internal pure returns (uint256 assets, uint256 shares) {
    uint256 assetRoom = type(uint256).max - 1 - gross;
    uint256 shareRoom = type(uint256).max - VIRTUAL_SHARES - supply;
    uint256 n = nav + 1;
    uint256 d = supply + VIRTUAL_SHARES;
    // floor(((shareRoom + 1) * n - 1) / d) without overflowing the product.
    uint256 shareLimited = _mulDivCapped(shareRoom + 1, n, d);
    if (shareLimited != type(uint256).max && mulmod(shareRoom + 1, n, d) == 0) --shareLimited;
    assets = Math.min(assetRoom, shareLimited);
    shares = Math.min(shareRoom, _mulDivCapped(assetRoom, d, n));
  }

  /// @notice Independent raw addition limits before applying a deposit/mint conversion.
  /// @dev Used by both capacity views and issuance. Bound gross backing, including
  /// reserves, so cash + marks + virtual assets and supply + virtual shares fit.
  /// @return assets Additional settlement-token raw units that fit the ledger.
  /// @return shares Additional LP share raw units that fit the virtualized supply.
  function issuanceLimits(State storage self) internal view returns (uint256 assets, uint256 shares) {
    assets = type(uint256).max - 1 - self.cash - self.inventoryValue - self.claimsValue;
    shares = type(uint256).max - VIRTUAL_SHARES - self.supply;
  }

  function _mulDivCapped(uint256 x, uint256 y, uint256 d) private pure returns (uint256) {
    // When y <= d, the quotient cannot exceed x. Otherwise the threshold fits.
    if (y > d && x > Math.fullMulDiv(type(uint256).max, d, y)) return type(uint256).max;
    return Math.fullMulDiv(x, y, d);
  }
}
