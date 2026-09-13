import {
  type Facts,
  type SeriesConfig,
  type Outcome,
  type Coordinate,
  uint,
  hex,
  order,
  requireValue,
} from "./types.js";
export interface Rate {
  sequence: string;
  firstRequest: string;
  rate: string;
}
/** Exact deployed conditional branch; not min(face, floor(shares*rate/scale)). */
export function claimable(face: bigint, shares: bigint, rate: bigint): bigint {
  requireValue(face > 0n && shares > 0n && rate >= 0n, "INVALID_PAYOUT_INPUT");
  return (face * 10n ** 27n) / shares > rate
    ? (shares * rate) / 10n ** 27n
    : face;
}
export function reconcileFacts(facts: Facts, c: SeriesConfig, rates: Rate[]) {
  const requests = [...facts.requests].sort(order),
    batches = [...facts.batches].sort(order),
    claims = [...facts.claims].sort(order);
  const blockFacts = new Map<string, string>(),
    txFacts = new Map<string, string>(),
    positions = new Map<string, string>();
  const events = new Set<string>(),
    ids = new Map<string, (typeof requests)[number]>();
  let face = 0n,
    shares = 0n;
  const check = (e: Coordinate) => {
    for (const key of [
      "blockNumber",
      "transactionIndex",
      "logIndex",
      "timestamp",
    ] as const)
      uint(e[key]);
    hex(e.blockHash, 32);
    hex(e.transactionHash, 32);
    requireValue(
      BigInt(e.blockNumber) >= BigInt(c.startBlock) &&
        BigInt(e.blockNumber) <= BigInt(c.endBlock) &&
        BigInt(e.timestamp) <= BigInt(c.cutoffTimestamp),
      "EVENT_OUTSIDE_COVERAGE",
    );
    const bh = e.blockHash + ":" + e.timestamp,
      th = e.blockNumber + ":" + e.transactionIndex,
      slot = e.blockNumber + ":" + e.logIndex;
    requireValue(
      !blockFacts.has(e.blockNumber) || blockFacts.get(e.blockNumber) === bh,
      "BLOCK_PROVENANCE_CONFLICT",
    );
    blockFacts.set(e.blockNumber, bh);
    requireValue(
      !txFacts.has(e.transactionHash) || txFacts.get(e.transactionHash) === th,
      "TX_PROVENANCE_CONFLICT",
    );
    txFacts.set(e.transactionHash, th);
    requireValue(
      !positions.has(slot) || positions.get(slot) === e.transactionHash,
      "LOG_POSITION_CONFLICT",
    );
    positions.set(slot, e.transactionHash);
    if (e.blockNumber === String(c.endBlock))
      requireValue(
        e.blockHash === c.cutoffHash && e.timestamp === c.cutoffTimestamp,
        "CUTOFF_EVENT_MISMATCH",
      );
    const id = e.transactionHash + ":" + e.logIndex;
    requireValue(!events.has(id), "DUPLICATE_EVENT");
    events.add(id);
  };
  for (const r of requests) {
    check(r);
    uint(r.requestId);
    uint(r.face);
    uint(r.shares);
    hex(r.requestor, 20);
    hex(r.ownerAtRequest, 20);
    requireValue(
      BigInt(r.requestId) === BigInt(ids.size) + 1n &&
        BigInt(r.face) > 0n &&
        BigInt(r.shares) > 0n,
      "REQUEST_SEQUENCE_OR_AMOUNT",
    );
    face += BigInt(r.face);
    shares += BigInt(r.shares);
    requireValue(
      uint(r.prefixFace) === String(face) &&
        uint(r.prefixShares) === String(shares),
      "PREFIX_MISMATCH",
    );
    ids.set(r.requestId, r);
  }
  const rateMap = new Map<string, Rate>();
  for (const r of rates) {
    uint(r.sequence);
    uint(r.firstRequest);
    uint(r.rate);
    requireValue(!rateMap.has(r.sequence), "DUPLICATE_CHECKPOINT");
    rateMap.set(r.sequence, r);
  }
  const outcomes = new Map<string, Outcome>();
  let last = 0n,
    locked = 0n,
    claimableTotal = 0n;
  requireValue(rates.length === batches.length, "CHECKPOINT_COVERAGE");
  for (let i = 0; i < batches.length; i++) {
    const b = batches[i]!;
    check(b);
    for (const key of [
      "sequence",
      "firstRequest",
      "lastRequest",
      "locked",
      "shares",
      "requestedFace",
      "finalizedAt",
    ] as const)
      uint(b[key]);
    requireValue(
      b.sequence === String(i + 1) &&
        BigInt(b.firstRequest) === last + 1n &&
        BigInt(b.lastRequest) >= BigInt(b.firstRequest),
      "FINALIZATION_SEQUENCE",
    );
    const end = ids.get(b.lastRequest),
      before = ids.get(String(BigInt(b.firstRequest) - 1n));
    requireValue(end, "MISSING_REQUEST");
    requireValue(
      b.shares ===
        String(
          BigInt(end.prefixShares) - BigInt(before?.prefixShares ?? "0"),
        ) &&
        b.requestedFace ===
          String(BigInt(end.prefixFace) - BigInt(before?.prefixFace ?? "0")) &&
        BigInt(b.locked) <= BigInt(b.requestedFace),
      "BATCH_AMOUNT",
    );
    requireValue(b.finalizedAt === b.timestamp, "FINALIZATION_TIMESTAMP");
    const rate = rateMap.get(b.sequence);
    requireValue(
      rate && rate.firstRequest === b.firstRequest,
      "CHECKPOINT_BINDING",
    );
    let subtotal = 0n;
    // Offchain ordered expansion is linear over all requests, never inside a Graph handler.
    for (let id = BigInt(b.firstRequest); id <= BigInt(b.lastRequest); id++) {
      const r = ids.get(String(id));
      requireValue(
        r && order(r, b) < 0 && BigInt(r.timestamp) <= BigInt(b.timestamp),
        "FINALIZATION_CHRONOLOGY",
      );
      const payout = claimable(
        BigInt(r.face),
        BigInt(r.shares),
        BigInt(rate.rate),
      );
      subtotal += payout;
      outcomes.set(r.requestId, {
        requestId: r.requestId,
        finalizationSequence: b.sequence,
        finalizedAt: b.timestamp,
        recovery: String(payout),
        observedClaim: null,
        claimedAt: null,
      });
    }
    requireValue(subtotal <= BigInt(b.locked), "NEGATIVE_ROUNDING_RESIDUAL");
    claimableTotal += subtotal;
    locked += BigInt(b.locked);
    last = BigInt(b.lastRequest);
  }
  let paid = 0n;
  const claimed = new Set<string>();
  for (const cl of claims) {
    check(cl);
    uint(cl.requestId);
    uint(cl.amount);
    hex(cl.receiver, 20);
    hex(cl.ownerAtClaim, 20);
    requireValue(!claimed.has(cl.requestId), "DUPLICATE_CLAIM");
    claimed.add(cl.requestId);
    const out = outcomes.get(cl.requestId);
    requireValue(out, "CLAIM_NOT_FINALIZED");
    const b = batches[Number(out.finalizationSequence) - 1]!;
    requireValue(
      order(b, cl) < 0 && BigInt(cl.timestamp) >= BigInt(b.timestamp),
      "CLAIM_CHRONOLOGY",
    );
    requireValue(cl.amount === out.recovery, "CLAIM_PAYOUT_MISMATCH");
    out.observedClaim = cl.amount;
    out.claimedAt = cl.timestamp;
    paid += BigInt(cl.amount);
  }
  for (const r of requests)
    if (!outcomes.has(r.requestId))
      outcomes.set(r.requestId, {
        requestId: r.requestId,
        finalizationSequence: null,
        finalizedAt: null,
        recovery: null,
        observedClaim: null,
        claimedAt: null,
      });
  const timeline = [...requests, ...batches, ...claims].sort(order);
  for (let i = 1; i < timeline.length; i++)
    requireValue(
      BigInt(timeline[i]!.timestamp) >= BigInt(timeline[i - 1]!.timestamp),
      "NONMONOTONIC_TIME",
    );
  const finalizedFace =
    last === 0n ? 0n : BigInt(ids.get(String(last))!.prefixFace);
  return {
    facts: { requests, batches, claims },
    outcomes: [...outcomes.values()].sort((a, b) =>
      BigInt(a.requestId) < BigInt(b.requestId) ? -1 : 1,
    ),
    totals: {
      requests: requests.length,
      batches: batches.length,
      claims: claims.length,
      finalizedRequests: String(last),
      pendingRequests: String(BigInt(requests.length) - last),
      requestedFace: String(face),
      locked: String(locked),
      paid: String(paid),
      lockedRemaining: String(locked - paid),
      unfinalizedFace: String(face - finalizedFace),
      roundingResidual: String(locked - claimableTotal),
    },
  };
}
