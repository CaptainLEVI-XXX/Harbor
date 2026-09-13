import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  type SeriesConfig,
  type Facts,
  type Coordinate,
  hash,
  hex,
  uint,
  order,
  requireValue,
} from "./types.js";
import { type Rate, reconcileFacts } from "./lido.js";
import { objectNever } from "./validation.js";
export const TOPICS = {
  request: "0xf0cb471f23fb74ea44b8252eb1881a2dca546288d9f6e90d1a0e82fe0ed342ab",
  batch: "0x197874c72af6a06fb0aa4fab45fd39c7cb61ac0992159872dc3295207da7e9eb",
  claim: "0x6ad26c5e238e7d002799f9a5db07e81ef14e37386ae03496d7a7ef04713e145b",
};
/** Preserve integer JSON tokens before JSON.parse; never round checkpoint rates through Number. */
export function exactJSON(text: string): unknown {
  return JSON.parse(
    text.replace(
      /"(?:\\.|[^"\\])*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/g,
      (token) => (token.startsWith('"') ? token : JSON.stringify(token)),
    ),
  );
}
const quantity = (x: unknown) => {
  requireValue(
    typeof x === "string" && /^0x[0-9a-fA-F]+$/.test(x),
    "INVALID_LOG_QUANTITY",
  );
  return uint(String(BigInt(x)));
};
export function decodeLogs(
  input: { requests: unknown[]; batches: unknown[]; claims: unknown[] },
  c: SeriesConfig,
): Facts {
  function log(value: unknown, topic: string, topics: number, words: number) {
    const x = objectNever(value);
    requireValue(x.removed === false, "REMOVED_OR_UNPROVEN_LOG");
    requireValue(hex(x.address, 20) === c.issuer, "WRONG_LOG_ISSUER");
    requireValue(
      Array.isArray(x.topics) &&
        x.topics.length === topics &&
        x.topics[0] === topic,
      "EVENT_SIGNATURE",
    );
    const ts = quantity(x.blockTimestamp ?? x.timeStamp);
    if (x.timeStamp !== undefined)
      requireValue(quantity(x.timeStamp) === ts, "LOG_TIMESTAMP_MISMATCH");
    const at: Coordinate = {
      blockNumber: quantity(x.blockNumber),
      blockHash: hex(x.blockHash, 32),
      transactionHash: hex(x.transactionHash, 32),
      transactionIndex: quantity(x.transactionIndex),
      logIndex: quantity(x.logIndex),
      timestamp: ts,
    };
    const data = hex(x.data, words * 32).slice(2);
    return {
      at,
      topic: (n: number) => hex((x.topics as unknown[])[n], 32),
      value: (n: number) =>
        String(BigInt("0x" + data.slice(n * 64, (n + 1) * 64))),
    };
  }
  const address = (word: string) => {
    requireValue(/^0x0{24}/.test(word), "ADDRESS_PADDING");
    return hex("0x" + word.slice(-40), 20);
  };
  let face = 0n,
    shares = 0n;
  const requests = input.requests
    .map((x) => {
      const l = log(x, TOPICS.request, 4, 2);
      return {
        ...l.at,
        requestId: quantity(l.topic(1)),
        face: l.value(0),
        shares: l.value(1),
        requestor: address(l.topic(2)),
        ownerAtRequest: address(l.topic(3)),
        prefixFace: "0",
        prefixShares: "0",
      };
    })
    .sort(order);
  const ids = new Map<string, (typeof requests)[number]>();
  for (const r of requests) {
    face += BigInt(r.face);
    shares += BigInt(r.shares);
    r.prefixFace = String(face);
    r.prefixShares = String(shares);
    ids.set(r.requestId, r);
  }
  const batches = input.batches
    .map((x) => {
      const l = log(x, TOPICS.batch, 3, 3);
      return {
        ...l.at,
        sequence: "0",
        firstRequest: quantity(l.topic(1)),
        lastRequest: quantity(l.topic(2)),
        locked: l.value(0),
        shares: l.value(1),
        requestedFace: "0",
        finalizedAt: l.value(2),
      };
    })
    .sort(order);
  for (let i = 0; i < batches.length; i++) {
    const b = batches[i]!;
    b.sequence = String(i + 1);
    const end = ids.get(b.lastRequest),
      before = ids.get(String(BigInt(b.firstRequest) - 1n));
    requireValue(end, "MISSING_REQUEST");
    b.requestedFace = String(
      BigInt(end.prefixFace) - BigInt(before?.prefixFace ?? "0"),
    );
  }
  const claims = input.claims
    .map((x) => {
      const l = log(x, TOPICS.claim, 4, 1);
      return {
        ...l.at,
        requestId: quantity(l.topic(1)),
        ownerAtClaim: address(l.topic(2)),
        receiver: address(l.topic(3)),
        amount: l.value(0),
      };
    })
    .sort(order);
  return { requests, batches, claims };
}
export function readReference(root: string, c: SeriesConfig) {
  requireValue(c.environment !== "BUILD_FIXTURE", "FIXTURE_NOT_REFERENCE");
  const fileHashes: Record<string, string> = {};
  const read = (name: string) => {
    const b = readFileSync(path.join(root, name));
    fileHashes[name] = hash(b);
    return b;
  };
  const snapshot = objectNever(
    JSON.parse(read("work/raw/study_snapshot.json").toString()),
  );
  requireValue(
    hex(snapshot.hash, 32) === c.cutoffHash &&
      quantity(snapshot.number) === String(c.endBlock) &&
      quantity(snapshot.timestamp) === c.cutoffTimestamp,
    "REFERENCE_CUTOFF",
  );
  const logs = (name: string) => {
    const x: unknown = JSON.parse(
      gunzipSync(read("work/raw/" + name + "_complete.json.gz")).toString(),
    );
    requireValue(Array.isArray(x), "INVALID_LOG_ARRAY");
    return x;
  };
  const facts = decodeLogs(
    {
      requests: logs("requested"),
      batches: logs("finalized"),
      claims: logs("claimed"),
    },
    c,
  );
  const checkpoints = exactJSON(
    read("work/raw/checkpoint_rates.json").toString(),
  );
  requireValue(Array.isArray(checkpoints), "INVALID_CHECKPOINTS");
  const rates: Rate[] = checkpoints.map((value) => {
    const x = objectNever(value);
    return {
      sequence: uint(x.checkpoint),
      firstRequest: uint(x.first_id),
      rate: uint(x.max_share_rate_1e27),
    };
  });
  const result = reconcileFacts(facts, c, rates);
  const audit = objectNever(
    exactJSON(read("outputs/boundary_audit.json").toString()),
  );
  const values = objectNever(audit.values);
  requireValue(audit.cutoff_block === String(c.endBlock), "BOUNDARY_CUTOFF");
  for (const [key, actual] of [
    ["getLastRequestId()", result.totals.requests],
    ["getLastFinalizedRequestId()", result.totals.finalizedRequests],
    ["getLastCheckpointIndex()", result.totals.batches],
    ["getLockedEtherAmount()", result.totals.lockedRemaining],
    ["unfinalizedStETH()", result.totals.unfinalizedFace],
  ])
    requireValue(values[key!] === String(actual), "BOUNDARY_MISMATCH");
  const decodedRequests = csv(read("work/decoded/requests.csv").toString()),
    decodedBatches = csv(read("work/decoded/finalizations.csv").toString()),
    decodedClaims = csv(read("work/decoded/claims.csv").toString());
  requireValue(
    decodedRequests.length === facts.requests.length &&
      decodedBatches.length === facts.batches.length &&
      decodedClaims.length === facts.claims.length,
    "CSV_COUNT",
  );
  const match = (
    row: Record<string, string>,
    fields: Record<string, string>,
  ) => {
    for (const [key, value] of Object.entries(fields))
      requireValue(row[key] === value, "CSV_MISMATCH_" + key);
  };
  result.facts.requests.forEach((r, i) => {
    const o = result.outcomes[i]!;
    match(decodedRequests[i]!, {
      id: r.requestId,
      request_ts: r.timestamp,
      request_block: r.blockNumber,
      request_tx: r.transactionHash,
      request_log: r.logIndex,
      steth_wei: r.face,
      shares: r.shares,
      requestor: r.requestor,
      owner_at_request: r.ownerAtRequest,
      final_ts: o.finalizedAt ?? "0",
      batch: o.finalizationSequence ?? "0",
      recovery_wei: o.recovery ?? "",
      claim_ts: o.claimedAt ?? "0",
      claim_wei: o.observedClaim ?? "",
    });
  });
  result.facts.batches.forEach((b, i) =>
    match(decodedBatches[i]!, {
      batch: b.sequence,
      from_inclusive: b.firstRequest,
      to_inclusive: b.lastRequest,
      ts: b.timestamp,
      block: b.blockNumber,
      tx: b.transactionHash,
      locked_wei: b.locked,
      requested_wei: b.requestedFace,
      max_share_rate_1e27: rates[i]!.rate,
    }),
  );
  result.facts.claims.forEach((cl, i) =>
    match(decodedClaims[i]!, {
      id: cl.requestId,
      block: cl.blockNumber,
      ts: cl.timestamp,
      tx: cl.transactionHash,
      log_index: cl.logIndex,
      tx_index: cl.transactionIndex,
      amount_wei: cl.amount,
    }),
  );
  const pinPath = fileURLToPath(
    new URL("../../../history/evidence/" + c.id + ".json", import.meta.url),
  );
  const pin = objectNever(JSON.parse(readFileSync(pinPath, "utf8")));
  requireValue(
    pin.series === c.id &&
      pin.cutoffHash === c.cutoffHash &&
      pin.cutoffBlock === c.endBlock,
    "EVIDENCE_SERIES_MISMATCH",
  );
  for (const [name, expected] of Object.entries(
    objectNever(pin.sourceFilesSha256),
  )) {
    if (!fileHashes[name]) read(name);
    requireValue(fileHashes[name] === expected, "REFERENCE_HASH_MISMATCH");
  }
  return { ...result, rates, fileHashes };
}
/** RFC-style quoted cells, escaped quotes and CRLF; monetary columns remain strings. */
export function csv(text: string): Record<string, string>[] {
  const rows: string[][] = [];
  let row: string[] = [],
    cell = "",
    quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]!;
    if (ch === '"') {
      if (quoted && text[i + 1] === '"') {
        cell += '"';
        i++;
      } else quoted = !quoted;
    } else if (ch === "," && !quoted) {
      row.push(cell);
      cell = "";
    } else if (ch === "\n" && !quoted) {
      row.push(cell.replace(/\r$/, ""));
      rows.push(row);
      row = [];
      cell = "";
    } else cell += ch;
  }
  requireValue(!quoted, "INVALID_CSV");
  if (cell || row.length) {
    row.push(cell.replace(/\r$/, ""));
    rows.push(row);
  }
  const header = rows.shift();
  requireValue(
    header && new Set(header).size === header.length,
    "INVALID_CSV_HEADER",
  );
  return rows.map((r) => {
    requireValue(r.length === header.length, "INVALID_CSV_WIDTH");
    return Object.fromEntries(header.map((h, i) => [h, r[i]!]));
  });
}
