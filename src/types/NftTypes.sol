// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Side, AmountMode} from "src/types/HarborTypes.sol";

/// @notice A whole issuer NFT. Route selects the issuer policy, never an ID-specific market.
struct NftTrade {
  address trader;
  address receiver;
  uint256 route;
  uint256 tokenId;
  Side side;
  AmountMode mode;
  uint256 amountSpecified;
  uint256 limitAmount;
  uint256 deadline;
  uint256 pricingVersion;
  uint256 configVersion;
  uint256 generation;
}

/// @notice Direct issuer evidence plus an independently authorized pending NAV mark.
struct NftObservation {
  address owner;
  uint256 nominal;
  uint256 mark;
  uint256 observedAt;
  bool valid;
}
