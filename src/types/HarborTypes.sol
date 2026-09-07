// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @notice Direction from the vault's perspective, opposite to the trader's.
enum Side {
  BUY_BASE,
  SELL_BASE
}

/// @notice Exactness applies to trader amounts after Harbor fee normalization.
enum AmountMode {
  EXACT_IN,
  EXACT_OUT
}

/// @notice Shared operation domain; values are never durable accounting state.
enum Operation {
  NONE,
  VAULT,
  TRADE,
  REDEMPTION,
  RECOVERY
}

/// @notice Immutable route mandate. Numeric values require independent calibration.
struct RouteConfig {
  address base;
  address adapter;
  uint256 bid;
  uint256 ask;
  uint256 buyBuffer;
  uint256 sellBuffer;
  uint256 maxExposure;
  uint256 maxPurchases;
  uint256 lossBudget;
  uint256 maxDailyRedemption; // Requested underlying ETH wei per UTC day.
}

/// @notice Keeper mandate bound to one exact inventory transition, not a quote.
struct RedeemIntent {
  uint256 chainId;
  address vault;
  address book;
  uint256 route;
  address adapter;
  uint256 adapterVersion;
  uint256 shares;
  uint256 minUnderlying;
  uint256 maxIds;
  uint256 positionVersion;
  uint256 epoch;
  uint256 nonce;
  uint256 deadline;
  bytes32 splitsHash;
}

/// @notice One indivisible trader instruction; amounts use raw token units.
struct Trade {
  address trader;
  address receiver;
  address tokenIn;
  address tokenOut;
  uint256 route;
  Side side;
  AmountMode mode;
  uint256 amountSpecified;
  uint256 limitAmount;
  uint256 deadline;
  uint256 nonce;
}

/// @notice Final exact-fill commitment shared by signer and policy receiver.
/// @dev All amounts are raw token units; time is Unix seconds. No partial fills.
struct FillTerms {
  address vault;
  address adapter;
  address feeRecipient;
  uint256 strategyVersion;
  uint256 adapterVersion;
  uint256 epoch;
  uint256 nonce;
  uint256 portfolioVersion;
  uint256 positionVersion;
  uint256 valuationVersion;
  uint256 policyVersion;
  uint256 traderIn;
  uint256 traderOut;
  uint256 routerIn;
  uint256 routerOut;
  uint256 fee;
  uint256 feeBps;
  uint256 observedAt;
  uint256 validUntil;
  bytes32 orderHash;
  bytes32 observationHash;
}

/// @notice Exact trader and router token amounts plus the WETH fee.
struct FillAmounts {
  uint256 traderIn;
  uint256 traderOut;
  uint256 routerIn;
  uint256 routerOut;
  uint256 fee;
}
