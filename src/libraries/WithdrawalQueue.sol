// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";

/// @title WithdrawalQueue
/// @notice FIFO pending shares and nontransferable funded receipt units.
/// @dev No share burns or token transfers here. The vault applies returned effects
/// atomically under its operation lock. Internal tickets are not ERC request IDs.
library WithdrawalQueue {
  uint256 internal constant MAX_PROCESS = 8;

  struct Ticket {
    address controller;
    uint256 pending; // Escrowed, still yield-bearing LP shares.
  }

  struct Credit {
    uint256 pending; // Sum of controller's pending tickets.
    uint256 units; // Already burned shares represented by funded receipts.
    uint256 assets; // Fixed reserved WETH wei backing those receipts.
  }

  struct State {
    mapping(uint256 => Ticket) tickets;
    mapping(address => Credit) credits;
    uint256 head;
    uint256 tail;
    uint256 totalPending;
    uint256 reserved;
  }

  error InvalidRequest();
  error InvalidFunding();
  error InsufficientCredit();
  /// @notice A partial asset claim would consume the last unit and strand cash.
  error ClaimAllAssets(uint256 assets);

  /// @notice Append an already escrowed share request; no cash liability yet.
  function append(State storage self, address controller, uint256 shares) internal returns (uint256 ticket) {
    if (controller == address(0) || shares == 0) revert InvalidRequest();
    ticket = self.tail++;
    self.tickets[ticket] = Ticket(controller, shares);
    self.credits[controller].pending += shares;
    self.totalPending += shares;
  }

  /// @notice Fund only the oldest ticket at an externally validated NAV rate.
  /// @return controller Owner of the funded credit.
  function fundHead(State storage self, uint256 shares, uint256 assets) internal returns (address controller) {
    Ticket storage ticket = self.tickets[self.head];
    if (self.head == self.tail || shares == 0 || shares > ticket.pending) revert InvalidFunding();
    controller = ticket.controller;
    Credit storage credit = self.credits[controller];
    ticket.pending -= shares;
    credit.pending -= shares;
    credit.units += shares;
    credit.assets += assets;
    self.totalPending -= shares;
    self.reserved += assets;
    if (ticket.pending == 0) {
      delete self.tickets[self.head];
      ++self.head;
    }
  }

  /// @notice Largest share portion whose floor-priced assets fit available cash.
  /// @param pending Head ticket's unfunded shares.
  /// @param cash Actual unreserved accounted WETH wei, excluding no LP buffer.
  /// @param numerator NAV plus virtual assets, or zero for verified total loss.
  /// @param denominator Supply plus virtual shares; always positive.
  /// @return shares Largest fundable share portion, capped at pending.
  /// @return assets WETH wei to reserve, rounded down.
  function fundable(uint256 pending, uint256 cash, uint256 numerator, uint256 denominator)
    internal
    pure
    returns (uint256 shares, uint256 assets)
  {
    if (denominator == 0) revert InvalidFunding();
    assets = Math.fullMulDiv(pending, numerator, denominator);
    if (assets == 0 && numerator != 0) return (0, 0);
    if (assets <= cash) return (pending, assets);
    // Here cash < floor(pending * numerator / denominator), so cash+1 and
    // the inverse both fit. Strict floor inverse: ceil((cash+1)*d/n)-1.
    shares = Math.fullMulDivUp(cash + 1, denominator, numerator) - 1;
    assets = Math.fullMulDiv(shares, numerator, denominator);
    // Nonzero NAV must not turn sub-wei rounding into a forced zero-value exit.
    if (assets == 0) return (0, 0);
  }

  /// @notice Redeem receipt units; the final claim takes every remaining wei.
  function redeem(State storage self, address controller, uint256 units) internal returns (uint256 assets) {
    Credit storage c = self.credits[controller];
    if (units == 0 || units > c.units) revert InsufficientCredit();
    assets = units == c.units ? c.assets : Math.fullMulDiv(units, c.assets, c.units);
    c.units -= units;
    c.assets -= assets;
    self.reserved -= assets;
  }

  /// @notice Withdraw exact WETH wei, consuming receipt units rounded up.
  function withdraw(State storage self, address controller, uint256 assets) internal returns (uint256 units) {
    Credit storage c = self.credits[controller];
    if (assets == 0 || assets > c.assets) revert InsufficientCredit();
    units = assets == c.assets ? c.units : Math.fullMulDivUp(assets, c.units, c.assets);
    if (units == c.units && assets != c.assets) revert ClaimAllAssets(c.assets);
    c.units -= units;
    c.assets -= assets;
    self.reserved -= assets;
  }
}
