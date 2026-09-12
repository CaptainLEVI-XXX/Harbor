import { BigInt, Bytes, dataSource, json } from "@graphprotocol/graph-ts";
import { IssuerRouteConfigured, ClaimIntegrationScheduled, IntegrationActivated, IntegrationRetired, ClaimMarketRegistered } from "../generated/Book/Book";
import { Strategy, Integration, Receipt } from "../generated/schema";
import { pool, poolId, routeId, issue } from "./common";
import { receiptId } from "./receipts";

export function initializeStrategy(route: BigInt, base: Bytes, adapter: Bytes, kind: string): Strategy {
  const s = new Strategy(routeId(route)); s.pool = poolId(); s.route = route; s.base = base; s.adapter = adapter; s.kind = kind;
  s.label = kind == "NATIVE" ? "Token strategy" : "Wrapped claim strategy";
  s.settlementPath = "AQUA_SWAP_VM"; s.heldNominal = BigInt.zero();
  // Human labels are reviewed deployment metadata, never inferred from an arbitrary token symbol.
  const raw = dataSource.context().get("strategyMetadata");
  if (raw != null) {
    const rows = json.fromString(raw.toString()).toArray();
    for (let i = 0; i < rows.length; ++i) {
      const row = rows[i].toObject();
      const id = row.get("route"), b = row.get("base"), a = row.get("adapter"), name = row.get("issuer"), symbol = row.get("tokenSymbol");
      if (id == null || b == null || a == null || name == null || symbol == null) continue;
      if (id.toString() != route.toString() || !Bytes.fromHexString(b.toString()).equals(base)
        || !Bytes.fromHexString(a.toString()).equals(adapter)) continue;
      s.issuerName = name.toString(); s.tokenSymbol = symbol.toString();
      s.label = name.toString() + " · " + symbol.toString();
    }
  }
  s.inventoryUnits = BigInt.zero(); s.inventoryBasis = BigInt.zero(); s.pendingBasis = BigInt.zero();
  s.customerCashVolume = BigInt.zero(); s.protocolFees = BigInt.zero(); s.buyCashDebit = BigInt.zero();
  s.sellCashCredit = BigInt.zero(); s.recoveredCash = BigInt.zero(); s.realizedResult = BigInt.zero();
  return s;
}

export function handleIssuerRouteConfigured(event: IssuerRouteConfigured): void {
  const p = pool(); p.save();
  if (Strategy.load(routeId(event.params.route)) != null) return;
  initializeStrategy(event.params.route, event.params.base, event.params.adapter, "NATIVE").save();
}

function integrationId(factory: Bytes, adapter: Bytes): Bytes { return poolId().concat(factory).concat(adapter); }

export function handleIntegrationScheduled(event: ClaimIntegrationScheduled): void {
  const p = pool(), source = Strategy.load(routeId(event.params.sourceRoute));
  if (source == null || !source.adapter.equals(event.params.adapter) || !p.asset.equals(event.params.cashAsset)) {
    issue(event, p, "MISSING_INTEGRATION_SOURCE"); return;
  }
  const i = new Integration(integrationId(event.params.factory, event.params.adapter));
  i.pool = p.id; i.factory = event.params.factory; i.adapter = event.params.adapter; i.source = source.id; i.enabled = false; i.save();
}

export function handleIntegrationActivated(event: IntegrationActivated): void {
  const i = Integration.load(integrationId(event.params.factory, event.params.adapter));
  if (i == null) { issue(event, pool(), "MISSING_INTEGRATION"); return; }
  i.enabled = true; i.save();
}

export function handleIntegrationRetired(event: IntegrationRetired): void {
  const i = Integration.load(integrationId(event.params.factory, event.params.adapter));
  if (i == null) { issue(event, pool(), "MISSING_INTEGRATION"); return; }
  i.enabled = false; i.save();
}

export function handleClaimMarketRegistered(event: ClaimMarketRegistered): void {
  const p = pool(), r = Receipt.load(receiptId(event.params.receipt));
  if (Strategy.load(routeId(event.params.route)) != null) return;
  if (r == null || !r.complete || !r.factory.equals(event.params.factory) || !r.claimId.equals(event.params.claimId)
    || !r.asset.equals(p.asset)) { issue(event, p, "MISSING_CANONICAL_RECEIPT"); return; }
  const i = Integration.load(integrationId(r.factory, r.adapter));
  if (i == null || !i.enabled) { issue(event, p, "MISSING_RECEIPT_ADMISSION"); return; }
  const s = initializeStrategy(event.params.route, r.address, r.adapter, "RECEIPT");
  s.source = i.source; s.factory = r.factory; s.adapterClaimId = r.claimId; s.save();
}
