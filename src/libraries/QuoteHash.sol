// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Trade, FillTerms} from "src/types/HarborTypes.sol";

/// @title QuoteHash
/// @notice Typed exact-fill identity bound to every settlement authority.
library QuoteHash {
  bytes32 internal constant TRADE_TYPEHASH = keccak256(
    "Trade(address trader,address receiver,address tokenIn,address tokenOut,uint256 route,uint8 side,uint8 mode,uint256 amountSpecified,uint256 limitAmount,uint256 deadline,uint256 nonce)"
  );
  bytes32 internal constant TERMS_TYPEHASH = keccak256(
    "FillTerms(address vault,address adapter,address feeRecipient,uint256 strategyVersion,uint256 adapterVersion,uint256 epoch,uint256 nonce,uint256 portfolioVersion,uint256 positionVersion,uint256 valuationVersion,uint256 policyVersion,uint256 traderIn,uint256 traderOut,uint256 routerIn,uint256 routerOut,uint256 fee,uint256 feeBps,uint256 observedAt,uint256 validUntil,bytes32 orderHash,bytes32 observationHash)"
  );
  bytes32 internal constant FILL_TYPEHASH = keccak256("Fill(bytes32 tradeHash,bytes32 termsHash)");
  bytes32 internal constant DOMAIN_TYPEHASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)");

  struct Domain {
    uint256 chainId;
    address book;
    address vault;
    address executor;
    address router;
    address receiver;
  }

  /// @notice Static tuple ABI encoding is identical to listing its fixed fields.
  function tradeHash(Trade memory trade) internal pure returns (bytes32) {
    return keccak256(abi.encode(TRADE_TYPEHASH, trade));
  }

  function termsHash(FillTerms memory terms) internal pure returns (bytes32) {
    return keccak256(abi.encode(TERMS_TYPEHASH, terms));
  }

  function digest(Domain memory domain, Trade memory trade, FillTerms memory terms) internal pure returns (bytes32) {
    bytes32 salt = keccak256(abi.encode(domain.vault, domain.executor, domain.router, domain.receiver));
    bytes32 separator =
      keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("Harbor"), keccak256("1"), domain.chainId, domain.book, salt));
    bytes32 fill = keccak256(abi.encode(FILL_TYPEHASH, tradeHash(trade), termsHash(terms)));
    return keccak256(abi.encodePacked(hex"1901", separator, fill));
  }
}
