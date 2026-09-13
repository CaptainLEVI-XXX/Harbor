import { BigInt, dataSource, ethereum } from '@graphprotocol/graph-ts';
import { WithdrawalRequested, WithdrawalsFinalized, WithdrawalClaimed } from '../generated/Queue/LidoWithdrawalQueue';
import { HistorySeries, WithdrawalRequest, FinalizationBatch, WithdrawalClaim, HistoryIssue } from '../generated/schema';
import { seriesId, requestId, claimId, eventId, provenance } from './identity';
const ZERO = BigInt.zero();
const ONE = BigInt.fromI32(1);
export function series(): HistorySeries {
  let s = HistorySeries.load(seriesId());
  if (s != null) return s;
  const c = dataSource.context(); s = new HistorySeries(seriesId());
  s.chainId = c.getBigInt('chainId'); s.issuer = c.getBytes('issuer'); s.adapterVersion = c.getString('adapterVersion');
  s.environment = c.getString('environment'); s.sourceAsset = c.getString('sourceAsset'); s.settlementAsset = c.getString('settlementAsset');
  s.decimals = c.getI32('decimals'); s.complete = true;
  s.requestCount = ZERO; s.batchCount = ZERO; s.claimCount = ZERO; s.lastRequest = ZERO; s.lastFinalized = ZERO;
  s.cumulativeFace = ZERO; s.cumulativeShares = ZERO; s.locked = ZERO; s.paid = ZERO;
  return s;
}
function issue(e: ethereum.Event, s: HistorySeries, code: string): void {
  s.complete = false; s.save(); const id = eventId(e, 'issue:' + code);
  if (HistoryIssue.load(id) != null) return;
  const row = new HistoryIssue(id); row.series = s.id; row.code = code; provenance(row, e); row.save();
}
function emitter(e: ethereum.Event, s: HistorySeries): boolean {
  if (e.address.equals(s.issuer)) return true;
  issue(e, s, 'WRONG_ISSUER'); return false;
}
export function handleRequest(e: WithdrawalRequested): void {
  const s = series(); if (!emitter(e, s)) return;
  const id = requestId(e.params.requestId); const previous = WithdrawalRequest.load(id);
  if (previous != null) {
    if (!previous.transactionHash.equals(e.transaction.hash) || !previous.logIndex.equals(e.logIndex)) issue(e, s, 'DUPLICATE_REQUEST');
    return;
  }
  if (!e.params.requestId.equals(s.lastRequest.plus(ONE)) || e.params.amountOfStETH.le(ZERO) || e.params.amountOfShares.le(ZERO)) {
    issue(e, s, 'REQUEST_SEQUENCE_OR_AMOUNT'); return;
  }
  const row = new WithdrawalRequest(id); row.series = s.id; row.requestId = e.params.requestId;
  row.face = e.params.amountOfStETH; row.shares = e.params.amountOfShares; row.requestor = e.params.requestor; row.ownerAtRequest = e.params.owner;
  row.prefixFace = s.cumulativeFace.plus(row.face); row.prefixShares = s.cumulativeShares.plus(row.shares);
  provenance(row, e); row.save(); s.cumulativeFace = row.prefixFace; s.cumulativeShares = row.prefixShares;
  s.lastRequest = row.requestId; s.requestCount = s.requestCount.plus(ONE); s.save();
}
export function handleFinalization(e: WithdrawalsFinalized): void {
  const s = series(); if (!emitter(e, s)) return;
  const id = eventId(e, 'finalization'); if (FinalizationBatch.load(id) != null) return;
  const a = e.params.from; const b = e.params.to;
  if (!a.equals(s.lastFinalized.plus(ONE)) || a.gt(b) || b.gt(s.lastRequest) || !e.params.timestamp.equals(e.block.timestamp)) {
    issue(e, s, 'FINALIZATION_RANGE_OR_TIME'); return;
  }
  const end = WithdrawalRequest.load(requestId(b));
  const before: WithdrawalRequest | null = a.equals(ONE) ? null : WithdrawalRequest.load(requestId(a.minus(ONE)));
  if (end == null || (!a.equals(ONE) && before == null)) { issue(e, s, 'MISSING_PREFIX'); return; }
  const face = end.prefixFace.minus(before == null ? ZERO : before.prefixFace);
  const shares = end.prefixShares.minus(before == null ? ZERO : before.prefixShares);
  if (!shares.equals(e.params.sharesToBurn) || e.params.amountOfETH.gt(face)) { issue(e, s, 'BATCH_AMOUNT'); return; }
  // Exactly two prefix reads; never enumerate the IDs in a finalization range.
  const row = new FinalizationBatch(id); row.series = s.id; row.sequence = s.batchCount.plus(ONE);
  row.firstRequest = a; row.lastRequest = b; row.locked = e.params.amountOfETH; row.shares = shares; row.requestedFace = face;
  row.finalizedAt = e.params.timestamp; provenance(row, e); row.save();
  s.batchCount = row.sequence; s.lastFinalized = b; s.locked = s.locked.plus(row.locked); s.save();
}
export function handleClaim(e: WithdrawalClaimed): void {
  const s = series(); if (!emitter(e, s)) return;
  const id = claimId(e.params.requestId);
  const prior = WithdrawalClaim.load(id);
  if (prior != null) {
    if (!prior.transactionHash.equals(e.transaction.hash) || !prior.logIndex.equals(e.logIndex)) issue(e, s, 'DUPLICATE_CLAIM');
    return;
  }
  const request = WithdrawalRequest.load(requestId(e.params.requestId));
  if (request == null || e.params.requestId.gt(s.lastFinalized) || e.params.amountOfETH.gt(request.face)) {
    issue(e, s, 'CLAIM_BEFORE_FINALIZATION_OR_AMOUNT'); return;
  }
  const row = new WithdrawalClaim(id); row.series = s.id; row.requestId = e.params.requestId;
  row.ownerAtClaim = e.params.owner; row.receiver = e.params.receiver; row.amount = e.params.amountOfETH; provenance(row, e); row.save();
  s.claimCount = s.claimCount.plus(ONE); s.paid = s.paid.plus(row.amount); s.save();
}
