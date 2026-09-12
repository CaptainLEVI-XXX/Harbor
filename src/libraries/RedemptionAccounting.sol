// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {RedeemIntent} from "src/types/HarborTypes.sol";

/// @notice Independent keeper nonce and bounded daily request accounting.
library RedemptionAccounting {
  /// @notice Only the current UTC day's usage affects future request authorization.
  struct DailyUsage {
    uint256 day; // block.timestamp / 1 days at the last successful request.
    uint256 used; // settlement-asset-denominated issuer entitlement consumed that day.
  }

  struct State {
    uint256 epoch;
    bool revoked;
    mapping(uint256 => mapping(uint256 => uint256)) nonceWords;
    mapping(uint256 => DailyUsage) dailyUsage;
  }
  error InvalidIntent();
  error DailyLimit();

  /// @dev Fixed linked validation keeps the full keeper-intent decoder out of
  /// the Book runtime. Delegatecall retains Book identity and nonce ownership.
  function consume(
    State storage self,
    RedeemIntent calldata intent,
    uint256[] calldata amounts,
    address vault,
    address adapter,
    uint256 positionVersion
  ) public returns (bytes32 context) {
    if (
      self.revoked || intent.chainId != block.chainid || intent.book != address(this) || intent.vault != vault
        || intent.adapter != adapter || intent.adapterVersion != 1 || intent.positionVersion != positionVersion
        || intent.epoch != self.epoch || usedNonce(self, intent.epoch, intent.nonce)
        || block.timestamp > intent.deadline || intent.deadline - block.timestamp > 1 days || intent.shares == 0
        || intent.minUnderlying == 0 || amounts.length == 0 || amounts.length > 8 || amounts.length > intent.maxIds
        || intent.maxIds > 8 || intent.splitsHash != keccak256(abi.encode(amounts))
    ) revert InvalidIntent();
    uint256 total;
    for (uint256 i; i < amounts.length; ++i) {
      total += amounts[i];
    }
    if (total != intent.shares) revert InvalidIntent();
    self.nonceWords[intent.epoch][intent.nonce >> 8] |= uint256(1) << (intent.nonce & 255);
    context = keccak256(abi.encode(intent));
  }

  /// @notice Full-width nonces partition into 256-bit words independently per epoch.
  /// @dev No narrowing: even uint256.max has a distinct word/bit. Never clear
  /// consumed words; failed requests revert the bit with the enclosing operation.
  function usedNonce(State storage self, uint256 epoch, uint256 nonce) internal view returns (bool) {
    return self.nonceWords[epoch][nonce >> 8] & (uint256(1) << (nonce & 255)) != 0;
  }

  function record(State storage self, uint256 route, uint256 underlying, uint256 minimum, uint256 limit) internal {
    if (underlying < minimum) revert InvalidIntent();
    uint256 day = block.timestamp / 1 days;
    DailyUsage storage usage = self.dailyUsage[route];
    uint256 total = (usage.day == day ? usage.used : 0) + underlying;
    if (total > limit) revert DailyLimit();
    usage.day = day;
    usage.used = total;
  }

  /// @notice Current-day entitlement consumed, in settlement-asset raw units; expired days read as zero.
  function usedToday(State storage self, uint256 route) internal view returns (uint256) {
    DailyUsage storage usage = self.dailyUsage[route];
    return usage.day == block.timestamp / 1 days ? usage.used : 0;
  }
}
