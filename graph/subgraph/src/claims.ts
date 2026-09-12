import { BigInt } from "@graphprotocol/graph-ts";
import { RedemptionRequested, RedemptionRecovered, PositionRealized, ReceiptAcquired, ReceiptDisposed, NativeClaimExported } from "../generated/Book/Book";
import { Strategy, NativeClaim, ClaimRecovery, Realization, HoldingEpisode, NativeExport } from "../generated/schema";
import { pool, poolId, routeId, eventId, nativeId, nativeKey, uint256, provenance, issue } from "./common";

export function handleRedemptionRequested(event: RedemptionRequested): void {
  const p = pool(), s = Strategy.load(routeId(event.params.route));
  p.portfolioChangedSinceCheckpoint = true; p.save();
  if (s == null) { issue(event, p, "MISSING_CLAIM_ROUTE"); return; }
  const id = nativeId(s.adapter, event.params.id);
  const existing = NativeClaim.load(id);
  if (existing != null) {
    if (!existing.requestTransaction.equals(event.transaction.hash) || !existing.requestLogIndex.equals(event.logIndex)) issue(event, p, "DUPLICATE_NATIVE_CLAIM");
    return;
  }
  if (s.inventoryUnits.lt(event.params.shares) || s.inventoryBasis.lt(event.params.basis)) {
    issue(event, p, "MISSING_REQUEST_INVENTORY"); return;
  }
  const c = new NativeClaim(id); c.pool = p.id; c.strategy = s.id; c.issuerId = event.params.id;
  c.representation = "NATIVE_REQUEST";
  c.bookKey = nativeKey(s.adapter, event.params.id); c.basis = event.params.basis;
  c.initialEntitlement = event.params.entitlement; c.remainingEntitlement = event.params.entitlement;
  c.recoveredCash = BigInt.zero(); c.state = "PENDING"; c.requestedAt = event.block.timestamp;
  c.requestTransaction = event.transaction.hash; c.requestLogIndex = event.logIndex; c.save();
  s.inventoryUnits = s.inventoryUnits.minus(event.params.shares); s.inventoryBasis = s.inventoryBasis.minus(c.basis);
  s.pendingBasis = s.pendingBasis.plus(c.basis); s.save();
}

/** Only Book recovery increments pool recovery cash. Final realization proceeds are cumulative. */
export function handleRedemptionRecovered(event: RedemptionRecovered): void {
  const p = pool(), source = Strategy.load(routeId(event.params.route)), id = eventId(event);
  if (ClaimRecovery.load(id) != null) return;
  p.portfolioChangedSinceCheckpoint = true; p.save();
  if (source == null) { issue(event, p, "MISSING_RECOVERY_ROUTE"); return; }
  const c = NativeClaim.load(nativeId(source.adapter, event.params.id));
  if (c == null) { issue(event, p, "MISSING_NATIVE_CLAIM"); return; }
  const s = Strategy.load(c.strategy);
  if (s == null) { issue(event, p, "MISSING_RECOVERY_STRATEGY"); return; }
  if (c.state != "PENDING" || c.remainingEntitlement.lt(event.params.remaining)) {
    issue(event, p, "INVALID_NATIVE_RECOVERY"); return;
  }
  const total = c.recoveredCash.plus(event.params.cash);
  if (event.params.remaining.isZero()) {
    const realizationId = c.finalRealization;
    if (realizationId === null) { issue(event, p, "MISSING_FINAL_REALIZATION"); return; }
    const final = Realization.load(realizationId);
    if (final == null || !final.proceeds.equals(total)) { issue(event, p, "RECOVERY_RECONCILIATION"); return; }
    c.state = "CLOSED"; c.closedAt = event.block.timestamp;
  }
  if (c.representation == "RAW_NFT") {
    s.heldNominal = s.heldNominal.minus(c.remainingEntitlement.minus(event.params.remaining));
    if (event.params.remaining.isZero()) s.inventoryUnits = s.inventoryUnits.minus(BigInt.fromI32(1));
  }
  c.recoveredCash = total; c.remainingEntitlement = event.params.remaining; c.save();
  s.recoveredCash = s.recoveredCash.plus(event.params.cash); s.save();
  const recovery = new ClaimRecovery(id); recovery.pool = p.id; recovery.claim = c.id;
  recovery.cash = event.params.cash; recovery.remaining = event.params.remaining; provenance(recovery, event); recovery.save();
}

/** Emitted before FillSettled / RedemptionRecovered. Basis and proceeds already include fees. */
export function handlePositionRealized(event: PositionRealized): void {
  const p = pool(), id = eventId(event);
  let s = Strategy.load(routeId(event.params.route));
  if (event.params.kind == 1) {
    const held = NativeClaim.load(poolId().concat(event.params.claimKey));
    if (held != null) s = Strategy.load(held.strategy);
  }
  if (Realization.load(id) != null) return;
  if (s == null) { issue(event, p, "MISSING_REALIZATION_ROUTE"); return; }
  if (event.params.kind == 0) {
    if (s.inventoryBasis.lt(event.params.basis)) { issue(event, p, "MISSING_SALE_BASIS"); return; }
    s.inventoryBasis = s.inventoryBasis.minus(event.params.basis);
  } else if (event.params.kind == 1) {
    const c = NativeClaim.load(poolId().concat(event.params.claimKey));
    if (c == null || c.state != "PENDING" || c.finalRealization !== null || !c.strategy.equals(s.id)
      || !c.basis.equals(event.params.basis) || s.pendingBasis.lt(event.params.basis)) {
      issue(event, p, "MISSING_FINAL_CLAIM_BASIS"); return;
    }
    c.finalRealization = id; c.save(); s.pendingBasis = s.pendingBasis.minus(event.params.basis);
  } else { issue(event, p, "UNKNOWN_REALIZATION_KIND"); return; }
  const r = new Realization(id); r.pool = p.id; r.strategy = s.id;
  r.kind = event.params.kind == 0 ? "SALE" : "ISSUER_RECOVERY"; r.basis = event.params.basis;
  r.proceeds = event.params.proceeds; r.result = r.proceeds.minus(r.basis); r.positionVersion = event.params.positionVersion;
  provenance(r, event); r.save(); s.realizedResult = s.realizedResult.plus(r.result); s.save();
  p.portfolioChangedSinceCheckpoint = true; p.save();
}

export function handleReceiptAcquired(event: ReceiptAcquired): void {
  const p = pool(), s = Strategy.load(routeId(event.params.route)), id = routeId(event.params.route).concat(uint256(event.params.positionVersion));
  if (HoldingEpisode.load(id) != null) return;
  if (s == null || s.kind != "RECEIPT" || s.currentEpisode !== null || !s.inventoryUnits.isZero()) {
    issue(event, p, "INVALID_RECEIPT_ACQUISITION"); return;
  }
  const episode = new HoldingEpisode(id); episode.pool = p.id; episode.strategy = s.id;
  episode.acquisitionVersion = event.params.positionVersion; episode.basis = event.params.basis; episode.exported = event.params.exported;
  episode.acquiredAt = event.block.timestamp; episode.acquisitionTransaction = event.transaction.hash; episode.acquisitionLogIndex = event.logIndex; episode.save();
  s.currentEpisode = id; s.inventoryUnits = BigInt.fromI32(1); s.inventoryBasis = event.params.basis; s.save();
  p.portfolioChangedSinceCheckpoint = true; p.save();
}

export function handleReceiptDisposed(event: ReceiptDisposed): void {
  const p = pool(), s = Strategy.load(routeId(event.params.route)), id = eventId(event);
  if (Realization.load(id) != null) return;
  if (s == null) { issue(event, p, "MISSING_RECEIPT_ROUTE"); return; }
  const current = s.currentEpisode;
  if (current === null) { issue(event, p, "MISSING_HOLDING_EPISODE"); return; }
  const episode = HoldingEpisode.load(current);
  if (episode == null || episode.disposal !== null || !episode.basis.equals(event.params.basis)) {
    issue(event, p, "RECEIPT_BASIS_MISMATCH"); return;
  }
  const r = new Realization(id); r.pool = p.id; r.strategy = s.id;
  r.kind = event.params.recovered ? "RECEIPT_RECOVERY" : "RECEIPT_SALE"; r.basis = event.params.basis;
  r.proceeds = event.params.proceeds; r.result = r.proceeds.minus(r.basis); r.positionVersion = event.params.positionVersion;
  provenance(r, event); r.save(); episode.disposal = id; episode.save();
  s.currentEpisode = null; s.inventoryUnits = BigInt.zero(); s.inventoryBasis = BigInt.zero();
  s.realizedResult = s.realizedResult.plus(r.result);
  // Sale cash belongs to FillSettled; this branch alone owns managed-receipt recovery cash.
  if (event.params.recovered) s.recoveredCash = s.recoveredCash.plus(r.proceeds);
  s.save(); p.portfolioChangedSinceCheckpoint = true; p.save();
}

export function handleNativeClaimExported(event: NativeClaimExported): void {
  const p = pool(), s = Strategy.load(routeId(event.params.sourceRoute)), market = Strategy.load(routeId(event.params.receiptRoute)), id = eventId(event);
  if (NativeExport.load(id) != null) return;
  if (s == null || market == null) { issue(event, p, "MISSING_EXPORT_ROUTE"); return; }
  const c = NativeClaim.load(nativeId(s.adapter, event.params.issuerId));
  const source = market.source;
  if (c == null || c.state != "PENDING" || !c.recoveredCash.isZero() || !c.basis.equals(event.params.basis)
    || source === null || !source.equals(s.id) || !market.adapter.equals(s.adapter)
    || !market.inventoryBasis.equals(c.basis) || !market.base.equals(event.params.receipt) || s.pendingBasis.lt(c.basis)) {
    issue(event, p, "EXPORT_BASIS_MISMATCH"); return;
  }
  c.state = "EXPORTED"; c.exportedMarket = market.id; c.closedAt = event.block.timestamp; c.save();
  s.pendingBasis = s.pendingBasis.minus(c.basis); s.save();
  const transition = new NativeExport(id); transition.pool = p.id; transition.claim = c.id; transition.market = market.id;
  transition.basis = c.basis; provenance(transition, event); transition.save();
  p.portfolioChangedSinceCheckpoint = true; p.save();
}
