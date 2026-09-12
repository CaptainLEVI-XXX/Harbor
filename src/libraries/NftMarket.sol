// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {NftTrade, NftObservation} from "src/types/NftTypes.sol";
import {Trade, FillAmounts, RouteConfig, Side} from "src/types/HarborTypes.sol";
import {PricingMarket, PricingCurve, PricingParameters} from "src/types/PricingTypes.sol";
import {PricingState} from "src/libraries/PricingState.sol";
import {PricingMath} from "src/libraries/PricingMath.sol";
import {BookAccounting as Accounting} from "src/libraries/BookAccounting.sol";
import {ClaimAccounting} from "src/libraries/ClaimAccounting.sol";
import {ClaimMarkets} from "src/libraries/ClaimMarkets.sol";
import {BookPortfolio} from "src/libraries/BookPortfolio.sol";
import {IHarborAdapter} from "src/interfaces/IHarborAdapter.sol";
import {IHarborNftAdapter} from "src/interfaces/IHarborNftAdapter.sol";
import {IHarborPool} from "src/interfaces/IHarborPool.sol";
import {HarborVault} from "src/vault/HarborVault.sol";

/// @notice Linked raw-NFT pricing/settlement on Book-owned state. One policy per issuer.
library NftMarket {
  using ClaimAccounting for ClaimAccounting.State;

  struct State {
    PricingState.State pricing;
    mapping(bytes32 => uint256) generation; // Acquisition/sale epoch; zero means never purchased as a raw NFT.
  }

  struct Config {
    address vault;
    address asset;
    address feeRecipient;
    uint256 feeBps;
    uint256 cashBuffer;
    uint256 maxExposure;
    uint256 maxAge;
    uint256 epoch;
    bool stopped;
    PricingCurve curve;
  }

  error InvalidNft();
  error CapacityExceeded();
  error SettlementMismatch();
  event NftTraded(
    uint256 indexed route,
    uint256 indexed tokenId,
    address indexed trader,
    address receiver,
    bool acquired,
    uint256 nominal,
    uint256 basis,
    uint256 cash,
    uint256 fee,
    uint256 generation
  );

  function quote(
    State storage self,
    Accounting.State storage ledger,
    ClaimMarkets.State storage markets,
    RouteConfig[] storage routes,
    NftTrade memory t
  ) public view returns (FillAmounts memory a) {
    (a,,) = _quote(self, ledger, markets, routes, t, INftConfiguration(address(this)).nftConfiguration());
  }

  function _quote(
    State storage self,
    Accounting.State storage ledger,
    ClaimMarkets.State storage markets,
    RouteConfig[] storage routes,
    NftTrade memory t,
    Config memory c
  ) private view returns (FillAmounts memory a, BookPortfolio.Value memory v, uint256 nominal) {
    if (t.route >= routes.length || c.stopped || block.timestamp > t.deadline) revert InvalidNft();
    PricingParameters memory p = self.pricing.parameters[t.route];
    if (
      p.version == 0 || p.version != t.pricingVersion || p.configVersion != c.epoch || t.configVersion != c.epoch
        || block.timestamp > p.validUntil
    ) revert InvalidNft();
    RouteConfig memory r = routes[t.route];
    bytes32 key = ClaimAccounting.key(r.adapter, t.tokenId);
    if (
      self.generation[key] != t.generation || !_recipient(t.trader, r.adapter, c)
        || !_recipient(t.receiver, r.adapter, c)
    ) revert InvalidNft();
    IHarborAdapter adapter = IHarborAdapter(r.adapter);
    if (
      adapter.BOOK() != address(this) || adapter.VAULT() != c.vault || adapter.ASSET() != c.asset
        || adapter.BASE() != r.base
    ) revert InvalidNft();
    NftObservation memory o = IHarborNftAdapter(r.adapter).nftObservation(t.tokenId);
    nominal = o.nominal;
    bool buy = t.side == Side.BUY_BASE;
    ClaimAccounting.Claim storage held = ledger.claims.claims[key];
    if (
      !o.valid || o.observedAt > block.timestamp || block.timestamp - o.observedAt > c.maxAge || o.mark > o.nominal
        || (buy
            ? o.owner != t.trader || held.exists
            : o.owner != r.adapter || !held.exists || held.closed || held.remaining != o.nominal
            || self.generation[key] == 0)
    ) {
      revert InvalidNft();
    }
    v = BookPortfolio.valuation(ledger, markets, routes, routes.length, c.vault, c.asset, c.stopped);
    if (!v.valid || v.observedAt > block.timestamp || block.timestamp - v.observedAt > c.maxAge) revert InvalidNft();
    PricingMarket memory m;
    m.policy = PricingState.loadPolicy(self.pricing, t.route);
    m.discount = p.discount;
    m.exposure = BookPortfolio.face(ledger, markets, routes, routes.length, c.vault);
    m.numerator = o.nominal;
    m.denominator = 1;
    m.maxQuantity = 1;
    m.receipt = true;
    if (buy && (m.exposure >= c.curve.capacity || o.nominal > c.curve.capacity - m.exposure)) {
      revert CapacityExceeded();
    }
    address issuer = IHarborNftAdapter(r.adapter).ISSUER();
    Trade memory intent = Trade(
      t.trader,
      t.receiver,
      buy ? issuer : c.asset,
      buy ? c.asset : issuer,
      t.route,
      t.side,
      t.mode,
      t.amountSpecified,
      t.limitAmount,
      t.deadline,
      t.pricingVersion,
      t.configVersion,
      0
    );
    a = PricingMath.quote(intent, c.curve, m, c.feeBps);
    if (buy) {
      if (ledger.claims.active.length + markets.active.length >= 64) revert CapacityExceeded();
      BookPortfolio.capacity(
        ledger,
        markets,
        routes,
        routes.length,
        t.route,
        true,
        1,
        a.routerOut,
        HarborVault(c.vault).tradingCash(c.cashBuffer),
        c.maxExposure,
        c.vault
      );
    } else {
      uint256 losses = ledger.positions[t.route].realizedLosses + markets.totals[t.route].losses;
      if (held.basis > a.routerIn && (losses >= r.lossBudget || held.basis - a.routerIn > r.lossBudget - losses)) {
        revert CapacityExceeded();
      }
    }
  }

  /// @dev Caller holds the Book/Vault NFT_TRADE lock. Quote and live NAV are computed once under that lock.
  function execute(
    State storage self,
    Accounting.State storage ledger,
    ClaimMarkets.State storage markets,
    RouteConfig[] storage routes,
    NftTrade memory t,
    bytes32 context
  ) public returns (FillAmounts memory a) {
    Config memory c = INftConfiguration(address(this)).nftConfiguration();
    BookPortfolio.Value memory v;
    uint256 expectedNominal;
    (a, v, expectedNominal) = _quote(self, ledger, markets, routes, t, c);
    HarborVault vault = HarborVault(c.vault);
    vault.checkpointTrade(context, v.inventory, v.claims, v.observedAt, v.evidence);
    address adapter = routes[t.route].adapter;
    bytes32 key = ClaimAccounting.key(adapter, t.tokenId);
    Accounting.Position storage position = ledger.positions[t.route];
    bool buy = t.side == Side.BUY_BASE;
    uint256 nominal;
    uint256 basis;
    if (buy) {
      nominal = IHarborNftAdapter(adapter).acquireNft(t.trader, t.tokenId);
      NftObservation memory observed = IHarborNftAdapter(adapter).nftObservation(t.tokenId);
      if (!observed.valid || observed.owner != adapter || observed.nominal != nominal || nominal != expectedNominal) {
        revert SettlementMismatch();
      }
      // Exact one-unit price used the same nominal, re-read only custody/entitlement after transfer.
      basis = a.routerOut;
      ledger.claims.create(key, t.route, basis, nominal);
      ledger.protocolIds[key] = t.tokenId;
      ledger.nativeClaimsFace += nominal;
      position.pendingBasis += basis;
      position.purchases += basis;
    } else {
      ClaimAccounting.Claim storage held = ledger.claims.claims[key];
      nominal = held.remaining;
      basis = ledger.claims.transferRight(key);
      // Raw resale relinquishes all rights and permits a new acquisition. Recovery never deletes its tombstone.
      delete ledger.claims.claims[key];
      delete ledger.protocolIds[key];
      ledger.nativeClaimsFace -= nominal;
      position.pendingBasis -= basis;
      if (basis > a.routerIn) position.realizedLosses += basis - a.routerIn;
      _collect(c.asset, t.trader, c.vault, a.routerIn);
      if (a.fee != 0) _collect(c.asset, t.trader, c.feeRecipient, a.fee);
      IHarborNftAdapter(adapter).releaseNft(t.receiver, t.tokenId);
    }
    ++position.version;
    uint256 generation = ++self.generation[key];
    vault.settleNftTrade(context, buy, t.receiver, buy ? a.routerOut : a.routerIn, a.fee);
    emit NftTraded(
      t.route, t.tokenId, t.trader, t.receiver, buy, nominal, basis, buy ? a.traderOut : a.traderIn, a.fee, generation
    );
  }

  function _collect(address token, address from, address to, uint256 amount) private {
    uint256 beforeBalance = SafeTransfer.balanceOf(token, to);
    SafeTransfer.safeTransferFrom(token, from, to, amount);
    if (SafeTransfer.balanceOf(token, to) != beforeBalance + amount) revert SettlementMismatch();
  }

  /// @notice Bounded discovery from the same claim ledger used by recovery and NAV.
  function inventory(
    State storage self,
    Accounting.State storage ledger,
    RouteConfig[] storage routes,
    uint256 cursor,
    uint256 limit
  ) public view returns (BookPortfolio.NativeClaim[] memory claims, uint256 next) {
    (BookPortfolio.NativeClaim[] memory page, uint256 end) = BookPortfolio.nativeClaims(ledger, routes, cursor, limit);
    uint256 size;
    for (uint256 i; i < page.length; ++i) {
      if (self.generation[page[i].key] != 0) ++size;
    }
    claims = new BookPortfolio.NativeClaim[](size);
    size = 0;
    for (uint256 i; i < page.length; ++i) {
      if (self.generation[page[i].key] != 0) claims[size++] = page[i];
    }
    return (claims, end);
  }

  function _recipient(address who, address adapter, Config memory c) private view returns (bool) {
    IHarborPool pool = IHarborPool(address(this));
    return who != address(0) && who != address(this) && who != c.vault && who != adapter && who != c.feeRecipient
      && who != pool.EXECUTOR() && who != pool.ROUTER() && who != pool.AQUA();
  }
}

/// @dev Immutable mandate and current epoch read from the storage-owning Book, never supplied by a trader.
interface INftConfiguration {
  function nftConfiguration() external view returns (NftMarket.Config memory);
}
