// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FillAmounts, Operation} from "src/types/HarborTypes.sol";
import {NftTrade} from "src/types/NftTypes.sol";
import {PricingPolicy, PricingParameters} from "src/types/PricingTypes.sol";
import {BookPricing} from "src/book/base/BookPricing.sol";
import {BookContext as Context} from "src/libraries/BookContext.sol";
import {NftMarket} from "src/libraries/NftMarket.sol";
import {PricingState} from "src/libraries/PricingState.sol";
import {ClaimAccounting} from "src/libraries/ClaimAccounting.sol";
import {BookPortfolio} from "src/libraries/BookPortfolio.sol";

/// @notice Raw-NFT entrypoints in the same Book as ordinary Aqua/SwapVM trades.
/// @dev Only issuer observation and NFT custody differ; pricing, portfolio risk,
/// cash and NAV use the common libraries and Book/Vault operation lock.
abstract contract BookNfts is BookPricing {
  NftMarket.State private _nfts;

  event NftPolicyConfigured(uint256 indexed route, PricingPolicy policy);
  event NftPricingPublished(uint256 indexed route, PricingParameters parameters);

  /// @notice Approve one existing issuer adapter and immutable NFT pricing bounds, not individual IDs.
  function configureNfts(uint256 route, PricingPolicy calldata policy) external {
    if (msg.sender != GOVERNOR) revert Unauthorized();
    if (Context.operation() != Operation.NONE) revert Busy();
    PricingState.configure(_nfts.pricing, route, INVENTORY_ROUTES, policy, pricingCurve(), ASSET_UNIT, true);
  }

  function publishNfts(uint256 route, PricingParameters calldata parameters) external {
    if (msg.sender != parameterUpdater) revert Unauthorized();
    if (Context.operation() != Operation.NONE) revert Busy();
    PricingState.publish(_nfts.pricing, route, parameters, configVersion, MAX_PARAMETER_AGE, true);
  }

  function nftParameters(uint256 route) external view returns (PricingParameters memory) {
    return _nfts.pricing.parameters[route];
  }

  function nftGeneration(uint256 route, uint256 id) external view returns (uint256) {
    return _nfts.generation[ClaimAccounting.key(_routes[route].adapter, id)];
  }

  function quoteNft(NftTrade calldata trade) external view returns (FillAmounts memory amounts) {
    if (Context.operation() != Operation.NONE) revert Busy();
    amounts = NftMarket.quote(_nfts, _state, _claimMarkets, _routes, trade);
  }

  /// @notice Caller-owned NFT sales or caller-funded purchases; receiver is validated by the shared policy.
  function executeNft(NftTrade calldata trade) external returns (FillAmounts memory amounts) {
    if (msg.sender != trade.trader) revert Unauthorized();
    _open(keccak256(abi.encode(msg.sender, trade)), Operation.NFT_TRADE);
    amounts = NftMarket.execute(_nfts, _state, _claimMarkets, _routes, trade, Context.context());
    _release();
  }

  /// @notice Bounded held raw IDs; status/asks are live reads. Pin all pages to one block.
  /// @dev Cursor indexes the shared <=64 active claim set, including native requests.
  function nftInventory(uint256 cursor, uint256 limit)
    external
    view
    returns (BookPortfolio.NativeClaim[] memory claims, uint256 next)
  {
    return NftMarket.inventory(_nfts, _state, _routes, cursor, limit);
  }

  /// @notice One read boundary for the linked module; no caller-provided risk configuration.
  function nftConfiguration() external view returns (NftMarket.Config memory) {
    return NftMarket.Config(
      address(VAULT),
      ASSET,
      FEE_RECIPIENT,
      FEE_BPS,
      CASH_BUFFER,
      MAX_EXPOSURE,
      MAX_MARK_AGE,
      configVersion,
      stopped,
      pricingCurve()
    );
  }
}
