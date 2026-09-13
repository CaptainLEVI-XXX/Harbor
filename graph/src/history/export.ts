import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  type Facts,
  type SeriesConfig,
  type Request,
  type Batch,
  type Claim,
  coordinate,
  uint,
  hex,
  seriesId,
  requireValue,
  hash,
} from "./types.js";
import { canonical as stable, type PageCache } from "./artifacts.js";
import { objectNever } from "./validation.js";
import type { Requester } from "./transport.js";
export type CanonicalCheck = () => Promise<{
  chainId: string;
  number: number;
  hash: string;
  timestamp: string;
  finalizedNumber: number;
}>;
const queryPath = (name: string) =>
  fileURLToPath(
    new URL(`../../../queries/history-${name}.graphql`, import.meta.url),
  );
export async function exportHistory(
  c: SeriesConfig,
  request: Requester,
  canonical: CanonicalCheck,
  pageSize = 500,
  cache?: PageCache,
) {
  requireValue(c.expectedDeployment, "MISSING_REVIEWED_DEPLOYMENT");
  requireValue(c.environment !== "BUILD_FIXTURE", "FIXTURE_NOT_LIVE");
  requireValue(
    Number.isInteger(pageSize) && pageSize > 0 && pageSize <= 500,
    "INVALID_PAGE_SIZE",
  );
  const before = await canonical();
  requireValue(
    before.chainId === c.chainId &&
      before.number === c.endBlock &&
      before.hash === c.cutoffHash &&
      before.timestamp === c.cutoffTimestamp &&
      before.finalizedNumber >= c.endBlock,
    "CANONICAL_CUTOFF_MISMATCH",
  );
  const meta = (data: Record<string, unknown>) => {
    const m = objectNever(data._meta),
      b = objectNever(m.block);
    requireValue(m.hasIndexingErrors === false, "INDEXING_ERRORS");
    requireValue(m.deployment === c.expectedDeployment, "DEPLOYMENT_CHANGED");
    requireValue(
      b.number === c.endBlock && b.hash === c.cutoffHash,
      "BLOCK_CHANGED",
    );
  };
  const block = { hash: c.cutoffHash },
    id = seriesId(c);
  const seriesQuery = readFileSync(queryPath("series"), "utf8");
  const s = objectNever(await request(seriesQuery, { id, block }));
  meta(s);
  const state = objectNever(s.historySeries);
  requireValue(
    state.complete === true &&
      state.chainId === c.chainId &&
      hex(state.issuer, 20) === c.issuer &&
      state.adapterVersion === c.adapterVersion &&
      state.environment === c.environment &&
      state.sourceAsset === c.sourceAsset &&
      state.settlementAsset === c.settlementAsset &&
      state.decimals === c.decimals,
    "SERIES_MISMATCH_OR_INCOMPLETE",
  );
  const collected: Record<string, Record<string, unknown>[]> = {};
  const queryHashes: Record<string, string> = { series: hash(seriesQuery) };
  for (const [name, entity] of [
    ["requests", "withdrawalRequests"],
    ["finalizations", "finalizationBatches"],
    ["claims", "withdrawalClaims"],
  ] as const) {
    const query = readFileSync(queryPath(name), "utf8");
    queryHashes[name] = hash(query);
    let after = "0x";
    const rows: Record<string, unknown>[] = [];
    const identity = hash(
      stable({ config: c, queryHash: hash(query), pageSize }),
    );
    const append = (value: unknown) => {
      const row = objectNever(value);
      requireValue(
        typeof row.id === "string" &&
          /^0x[0-9a-f]+$/.test(row.id) &&
          row.id > after,
        "CURSOR_ORDER",
      );
      requireValue(objectNever(row.series).id === id, "FOREIGN_SERIES");
      after = row.id;
      rows.push(row);
    };
    const expected = Number(
      uint(
        state[
          name === "requests"
            ? "requestCount"
            : name === "claims"
              ? "claimCount"
              : "batchCount"
        ],
      ),
    );
    requireValue(Number.isSafeInteger(expected), "COUNT_OVERFLOW");
    for (const value of cache?.read(name, identity) ?? []) append(value);
    requireValue(rows.length <= expected, "CHECKPOINT_COUNT");
    while (true) {
      const data = objectNever(
        await request(query, { series: id, after, first: pageSize, block }),
      );
      meta(data);
      const page = data[entity];
      requireValue(
        Array.isArray(page) && page.length <= pageSize,
        "INVALID_PAGE",
      );
      for (const value of page) append(value);
      requireValue(rows.length <= expected, "COUNT_MISMATCH");
      cache?.write(name, identity, rows);
      if (page.length < pageSize) break;
    }
    requireValue(rows.length === expected, "MISSING_PAGE_OR_RECORDS");
    collected[name] = rows;
  }
  const facts: Facts = {
    requests: collected.requests!.map(
      (r) =>
        ({
          ...coordinate(r),
          requestId: uint(r.requestId),
          face: uint(r.face),
          shares: uint(r.shares),
          requestor: hex(r.requestor, 20),
          ownerAtRequest: hex(r.ownerAtRequest, 20),
          prefixFace: uint(r.prefixFace),
          prefixShares: uint(r.prefixShares),
        }) as Request,
    ),
    batches: collected.finalizations!.map(
      (r) =>
        ({
          ...coordinate(r),
          sequence: uint(r.sequence),
          firstRequest: uint(r.firstRequest),
          lastRequest: uint(r.lastRequest),
          locked: uint(r.locked),
          shares: uint(r.shares),
          requestedFace: uint(r.requestedFace),
          finalizedAt: uint(r.finalizedAt),
        }) as Batch,
    ),
    claims: collected.claims!.map(
      (r) =>
        ({
          ...coordinate(r),
          requestId: uint(r.requestId),
          ownerAtClaim: hex(r.ownerAtClaim, 20),
          receiver: hex(r.receiver, 20),
          amount: uint(r.amount),
        }) as Claim,
    ),
  };
  const after = await canonical();
  requireValue(
    after.chainId === before.chainId &&
      after.number === before.number &&
      after.hash === before.hash &&
      after.timestamp === before.timestamp &&
      after.finalizedNumber >= c.endBlock,
    "CANONICAL_CUTOFF_CHANGED",
  );
  const final = objectNever(await request(seriesQuery, { id, block }));
  meta(final);
  requireValue(stable(final.historySeries) === stable(state), "SERIES_CHANGED");
  return {
    facts,
    proof: {
      deployment: c.expectedDeployment,
      cutoff: before,
      queryHashes,
      state,
    },
  };
}
