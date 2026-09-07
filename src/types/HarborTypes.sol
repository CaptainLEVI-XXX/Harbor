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

/// @notice One indivisible trader instruction; amounts use raw token units.
struct Trade {
  address trader;
  address receiver;
  uint256 route;
  Side side;
  AmountMode mode;
  uint256 amountSpecified;
  uint256 limitAmount;
  uint256 deadline;
  uint256 nonce;
}

/// @notice Exact trader and router token amounts plus the WETH fee.
struct FillAmounts {
  uint256 traderIn;
  uint256 traderOut;
  uint256 routerIn;
  uint256 routerOut;
  uint256 fee;
}
