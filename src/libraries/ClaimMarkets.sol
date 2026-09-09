// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {IHarborClaim, IHarborClaimFactory, IHarborClaimExporter} from "src/interfaces/IHarborClaim.sol";
import {IHarborAdapter} from "src/interfaces/IHarborAdapter.sol";
import {BookAccounting as Accounting} from "src/libraries/BookAccounting.sol";
import {ClaimAccounting} from "src/libraries/ClaimAccounting.sol";
import {RouteConfig} from "src/types/HarborTypes.sol";

/// @title ClaimMarkets
/// @notice Book-owned admission, canonical receipt identity and issuer-wide risk totals.
/// @dev Linked library calls operate on explicit Book storage. No configurable
/// delegatecall target exists. Individual position basis remains in Accounting.
library ClaimMarkets {
  using ClaimAccounting for ClaimAccounting.State;

  struct Integration {
    uint256 sourceRoute; // Original issuer route; shares all of its spending limits.
    uint256 readyAt; // Earliest activation, Unix seconds; zero means unscheduled.
    uint256 bid; // Maximum buy multiplier on the public claim mark, 1e18 scale.
    uint256 ask; // Minimum sell multiplier on the public claim mark, 1e18 scale.
    bool enabled;
    bool retired; // Irreversible; recovery remains independent of admission.
  }

  struct Market {
    address factory;
    address receipt; // Canonical one-unit base token; native configuration is not copied.
    uint256 sourceRoute;
    uint256 requestId;
  }

  struct Totals {
    uint256 basis; // Current receipt cost, WETH wei, across one issuer's markets.
    uint256 purchases; // Lifetime additional receipt purchase debits; export adds zero.
    uint256 losses; // Lifetime realized receipt losses; gains never reset this budget.
  }

  struct State {
    mapping(address => Integration) integrations;
    mapping(uint256 => Market) markets;
    mapping(address => uint256) routePlusOne;
    mapping(uint256 => Totals) totals;
    uint256[] active; // Only held receipt routes; native rights share the 64-position cap.
    mapping(uint256 => uint256) indexPlusOne;
    uint256 count; // Stable next receipt route offset; IDs are never reused after disposal.
  }

  error InvalidIntegration();
  error InvalidReceipt();
  error MarketCapacity();
  /// @notice Cursor exceeds the live set or page size is not 1..32.
  error InvalidPage();

  /// @notice Exact delayed factory policy; bid/ask are 1e18 multipliers, readyAt is Unix seconds.
  event ClaimIntegrationScheduled(
    address indexed factory,
    uint256 indexed sourceRoute,
    address issuer,
    address weth,
    uint256 bid,
    uint256 ask,
    uint256 readyAt
  );
  event IntegrationActivated(address indexed factory);
  event IntegrationRetired(address indexed factory);
  event ClaimMarketRegistered(
    uint256 indexed route, address indexed receipt, address indexed factory, uint256 requestId
  );
  /// @notice One-unit acquisition at WETH cost; version is the resulting position version, not a history counter.
  event ReceiptAcquired(uint256 indexed route, uint256 indexed positionVersion, uint256 basisWeth, bool exported);
  /// @notice Whole-unit disposal; WETH proceeds are net of fees, or measured recovery.
  event ReceiptDisposed(
    uint256 indexed route, uint256 indexed positionVersion, uint256 basisWeth, uint256 proceedsWeth, bool recovered
  );
  /// @notice Native custody becomes a receipt at the same cost, without cash or realized PnL.
  event NativeClaimExported(
    uint256 indexed sourceRoute,
    uint256 indexed issuerId,
    uint256 indexed receiptRoute,
    address receipt,
    uint256 basisWeth
  );

  /// @notice Bounded current receipt-route discovery without reading any issuer or token.
  /// @dev Callers pin the block: swap-pop removal may change offsets between transactions.
  function activeRoutes(State storage self, uint256 cursor, uint256 limit)
    public
    view
    returns (uint256[] memory routes, uint256 next)
  {
    uint256 length = self.active.length;
    if (limit == 0 || limit > 32 || cursor > length) revert InvalidPage();
    uint256 size = length - cursor;
    if (size > limit) size = limit;
    routes = new uint256[](size);
    for (uint256 i; i < size; ++i) {
      routes[i] = self.active[cursor + i];
    }
    next = cursor + size;
  }

  /// @notice Resolve the public route view without storing another copy of issuer limits.
  /// @dev Original routes are immutable. Receipt pricing is fixed by its admitted integration.
  function config(State storage self, RouteConfig[] storage routes, uint256 route)
    public
    view
    returns (RouteConfig memory r)
  {
    if (route < routes.length) return routes[route];
    Market storage m = self.markets[route];
    if (m.factory == address(0)) revert InvalidReceipt();
    r = routes[m.sourceRoute];
    r.base = m.receipt;
    r.adapter = m.factory;
    r.bid = self.integrations[m.factory].bid;
    r.ask = self.integrations[m.factory].ask;
  }

  /// @notice Resolve only the token identity required for settlement or custody checks.
  function base(State storage self, RouteConfig[] storage routes, uint256 route) internal view returns (address) {
    return route < routes.length ? routes[route].base : self.markets[route].receipt;
  }

  /// @notice Schedule one immutable factory/issuer/pricing configuration.
  function schedule(
    State storage self,
    RouteConfig[] storage routes,
    address factory,
    uint256 source,
    uint256 bid,
    uint256 ask,
    uint256 delay,
    address vault,
    address weth
  ) public {
    if (
      self.integrations[factory].readyAt != 0 || source >= routes.length || factory.code.length == 0 || bid == 0
        || bid > ask || ask > 1e18
    ) revert InvalidIntegration();
    IHarborClaimFactory f = IHarborClaimFactory(factory);
    IHarborAdapter a = IHarborAdapter(routes[source].adapter);
    if (
      a.BOOK() != address(this) || a.VAULT() != vault || a.BASE() != routes[source].base || a.WETH() != weth
        || f.WETH() != weth || !f.active() || f.ISSUER() != IHarborClaimExporter(address(a)).ISSUER()
    ) revert InvalidIntegration();
    uint256 readyAt = block.timestamp + delay;
    self.integrations[factory] = Integration(source, readyAt, bid, ask, false, false);
    emit ClaimIntegrationScheduled(factory, source, f.ISSUER(), weth, bid, ask, readyAt);
  }

  /// @notice Activate after the Book's governance delay; configuration cannot be replaced.
  function activate(State storage self, address factory) public {
    Integration storage i = self.integrations[factory];
    if (
      i.readyAt == 0 || block.timestamp < i.readyAt || i.retired || i.enabled || !IHarborClaimFactory(factory).active()
    ) revert InvalidIntegration();
    i.enabled = true;
    emit IntegrationActivated(factory);
  }

  function retire(State storage self, address factory) public {
    Integration storage i = self.integrations[factory];
    if (i.readyAt == 0 || i.retired) revert InvalidIntegration();
    i.enabled = false;
    i.retired = true;
    emit IntegrationRetired(factory);
  }

  /// @notice Register a stable market ID without acquiring its receipt or assigning NAV.
  function register(State storage self, RouteConfig[] storage routes, address factory, address receipt, address weth)
    public
    returns (uint256 route)
  {
    Integration storage i = self.integrations[factory];
    IHarborClaimFactory f = IHarborClaimFactory(factory);
    if (!i.enabled || !f.active() || self.routePlusOne[receipt] != 0) revert InvalidIntegration();
    IHarborClaim c = IHarborClaim(receipt);
    if (
      !f.isReceipt(receipt) || c.FACTORY() != factory || c.ISSUER() != f.ISSUER() || c.WETH() != weth
        || c.CHAIN_ID() != block.chainid || f.receiptOf(c.REQUEST_ID()) != receipt
        || c.status() != IHarborClaim.Status.PENDING
    ) revert InvalidReceipt();
    route = routes.length + self.count++;
    self.markets[route] = Market(factory, receipt, i.sourceRoute, c.REQUEST_ID());
    self.routePlusOne[receipt] = route + 1;
    emit ClaimMarketRegistered(route, receipt, factory, c.REQUEST_ID());
  }

  /// @notice Include a newly held receipt in the shared bounded active set.
  function acquire(State storage self, Accounting.State storage book, uint256 route, uint256 cost, bool exported)
    public
  {
    if (self.indexPlusOne[route] != 0 || self.active.length + book.claims.active.length >= 64) {
      revert MarketCapacity();
    }
    Market storage m = self.markets[route];
    Accounting.Position storage p = book.positions[route];
    if (m.factory == address(0) || p.shares != 0 || p.basis != 0 || (!exported && cost == 0)) revert InvalidReceipt();
    self.active.push(route);
    self.indexPlusOne[route] = self.active.length;
    Totals storage t = self.totals[m.sourceRoute];
    t.basis += cost;
    if (!exported) t.purchases += cost;
    p.shares = 1;
    p.basis = cost;
    ++p.version;
    ++book.version;
    emit ReceiptAcquired(route, p.version, cost, exported);
  }

  /// @notice Remove a held receipt after measured sale or holder redemption.
  function dispose(State storage self, Accounting.State storage book, uint256 route, uint256 cash, bool recovered)
    public
  {
    uint256 index = self.indexPlusOne[route];
    Accounting.Position storage p = book.positions[route];
    if (index == 0 || p.shares != 1) revert InvalidReceipt();
    uint256 basis = p.basis;
    Market storage m = self.markets[route];
    Totals storage t = self.totals[m.sourceRoute];
    t.basis -= basis;
    if (basis > cash) t.losses += basis - cash;
    uint256 last = self.active[self.active.length - 1];
    self.active[index - 1] = last;
    self.indexPlusOne[last] = index;
    self.active.pop();
    delete self.indexPlusOne[route];
    p.shares = 0;
    p.basis = 0;
    ++p.version;
    ++book.version;
    emit ReceiptDisposed(route, p.version, basis, cash, recovered);
  }

  /// @notice Export exactly one unrecovered native right, preserving its full cost.
  function exportRight(
    State storage self,
    Accounting.State storage book,
    RouteConfig[] storage routes,
    uint256 source,
    uint256 id,
    address factory,
    address vault,
    address weth
  ) public returns (uint256 route) {
    Integration storage i = self.integrations[factory];
    if (!i.enabled || i.sourceRoute != source) revert InvalidIntegration();
    address adapter = routes[source].adapter;
    bytes32 key = ClaimAccounting.key(adapter, id);
    ClaimAccounting.Claim storage c = book.claims.claims[key];
    if (!c.exists || c.closed || c.route != source || c.received != 0) revert InvalidReceipt();
    address receipt = IHarborClaimExporter(adapter).exportClaim(id, factory);
    if (
      SafeTransfer.balanceOf(receipt, vault) != 1 || IHarborClaim(receipt).REQUEST_ID() != id
        || IHarborClaim(receipt).entitlement() != c.remaining
    ) revert InvalidReceipt();
    route = register(self, routes, factory, receipt, weth);
    uint256 basis = book.claims.transferRight(key);
    delete book.protocolIds[key];
    book.positions[source].pendingBasis -= basis;
    ++book.positions[source].version;
    acquire(self, book, route, basis, true);
    emit NativeClaimExported(source, id, route, receipt, basis);
  }
}
