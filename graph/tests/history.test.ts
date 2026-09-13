import { buildSchema, parse, validate } from "graphql";
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  validateConfig,
  seriesId,
  word,
  type Facts,
  type SeriesConfig,
} from "../src/history/types.js";
import { claimable, reconcileFacts, type Rate } from "../src/history/lido.js";
import { exactJSON, csv, decodeLogs, TOPICS } from "../src/history/cache.js";
import { exportHistory } from "../src/history/export.js";
import { transport } from "../src/history/transport.js";
import {
  canonical,
  pageCache,
  publishDataset,
} from "../src/history/artifacts.js";
const addr = "0x" + "01".repeat(20),
  other = "0x" + "02".repeat(20),
  block = "0x" + "aa".repeat(32);
function config(): SeriesConfig {
  return validateConfig({
    id: "test",
    chainId: "1",
    network: "mainnet",
    environment: "MAINNET",
    issuer: addr,
    adapterVersion: "lido-inclusive-v1",
    sourceAsset: "eip155:1/erc20:" + addr,
    settlementAsset: "eip155:1/slip44:60",
    decimals: 18,
    startBlock: 0,
    endBlock: 10,
    cutoffHash: block,
    cutoffTimestamp: "100",
    coverageOrigin: "FROM_FIRST_REQUEST",
    evidence: "CACHED_RESEARCH",
    finalityPolicy: "RPC_FINALIZED",
    expectedDeployment: "Qm" + "x".repeat(44),
  });
}
function event(n: number) {
  return {
    blockNumber: String(n),
    blockHash: "0x" + word(String(n)),
    transactionHash: "0x" + word(String(n)),
    transactionIndex: "0",
    logIndex: "0",
    timestamp: String(n * 10),
  };
}
function facts(): Facts {
  return {
    requests: [1, 2, 3].map((n) => ({
      ...event(n),
      requestId: String(n),
      face: "100",
      shares: "100",
      requestor: addr,
      ownerAtRequest: addr,
      prefixFace: String(n * 100),
      prefixShares: String(n * 100),
    })),
    batches: [
      {
        ...event(4),
        sequence: "1",
        firstRequest: "1",
        lastRequest: "2",
        locked: "180",
        shares: "200",
        requestedFace: "200",
        finalizedAt: "40",
      },
    ],
    claims: [
      {
        ...event(5),
        requestId: "1",
        ownerAtClaim: other,
        receiver: addr,
        amount: "90",
      },
    ],
  };
}
const rates: Rate[] = [
  { sequence: "1", firstRequest: "1", rate: String(9n * 10n ** 26n) },
];
test("network, asset, finality and adapter configuration reject unsupported identities", () => {
  const c = config();
  assert.notEqual(seriesId(c), seriesId({ ...c, chainId: "42161" }));
  assert.notEqual(seriesId(c), seriesId({ ...c, issuer: other }));
  for (const bad of [
    { chainId: 1 },
    { network: "arbitrum-one" },
    { sourceAsset: "eip155:2/slip44:60" },
    { adapterVersion: "generic" },
    { finalityPolicy: "CONFIRMATIONS" },
    { decimals: 37 },
    { startBlock: 11 },
    { coverageOrigin: "MID_QUEUE" },
  ])
    assert.throws(() => validateConfig({ ...c, ...bad }));
});
test("chain configuration does not implicitly rescale six decimal cash", () => {
  const c = validateConfig({ ...config(), decimals: 6 });
  assert.equal(reconcileFacts(facts(), c, rates).totals.paid, "90");
});
test("exact checkpoint parser never rounds 27 digit integers or quoted numeric text", () => {
  assert.deepEqual(
    exactJSON('{"rate":1124349247312577330121566909,"text":"123 \\"456\\""}'),
    { rate: "1124349247312577330121566909", text: '123 "456"' },
  );
});
test("payout preserves contract boundary branch rather than min approximation", () => {
  const scale = 10n ** 27n;
  assert.equal(claimable(1n, 3n, scale / 3n), 1n);
  assert.equal((3n * (scale / 3n)) / scale, 0n);
  assert.equal(claimable(100n, 100n, 9n * 10n ** 26n), 90n);
  assert.throws(() => claimable(1n, 0n, 1n));
});
test("inclusive ranges, pending labels, discounted actual claim and residual reconcile", () => {
  const r = reconcileFacts(facts(), config(), rates);
  assert.equal(r.totals.finalizedRequests, "2");
  assert.equal(r.totals.pendingRequests, "1");
  assert.equal(r.totals.lockedRemaining, "90");
  assert.equal(r.outcomes[1]!.recovery, "90");
  assert.equal(r.outcomes[2]!.recovery, null);
});
for (const [name, edit] of Object.entries({
  gap: (f: Facts) => {
    f.requests[1]!.requestId = "4";
  },
  prefix: (f: Facts) => {
    f.requests[2]!.prefixFace = "301";
  },
  overlap: (f: Facts) => {
    f.batches[0]!.firstRequest = "2";
  },
  shares: (f: Facts) => {
    f.batches[0]!.shares = "201";
  },
  payout: (f: Facts) => {
    f.claims[0]!.amount = "91";
  },
  unfinalizedClaim: (f: Facts) => {
    f.claims[0]!.requestId = "3";
  },
  duplicate: (f: Facts) => {
    f.claims.push({ ...f.claims[0]! });
  },
  future: (f: Facts) => {
    f.requests[0]!.timestamp = "101";
  },
  chronology: (f: Facts) => {
    f.claims[0]!.blockNumber = "0";
  },
  negativeResidual: (f: Facts) => {
    f.batches[0]!.locked = "179";
  },
}))
  test("reject invalid historical " + name, () => {
    const f = facts();
    edit(f);
    assert.throws(() => reconcileFacts(f, config(), rates));
  });
test("checkpoint coverage and binding are mandatory", () => {
  assert.throws(() => reconcileFacts(facts(), config(), []));
  assert.throws(() =>
    reconcileFacts(facts(), config(), [{ ...rates[0]!, firstRequest: "2" }]),
  );
});
test("CSV values retain raw integers and support escaped quotes", () => {
  assert.deepEqual(
    csv('id,note,value\r\n1,"a,""b""",1000000000000000001\r\n'),
    [{ id: "1", note: 'a,"b"', value: "1000000000000000001" }],
  );
});
test("raw decoder distinguishes claim owner and receiver and rejects removed logs", () => {
  const coord = {
    blockNumber: "0x1",
    blockHash: block,
    transactionHash: block,
    transactionIndex: "0x0",
    logIndex: "0x0",
    blockTimestamp: "0xa",
    removed: false,
    address: addr,
  };
  const log = {
    ...coord,
    topics: [
      TOPICS.claim,
      "0x" + word("1"),
      "0x" + "0".repeat(24) + other.slice(2),
      "0x" + "0".repeat(24) + addr.slice(2),
    ],
    data: "0x" + word("99"),
  };
  const decoded = decodeLogs(
    { requests: [], batches: [], claims: [log] },
    config(),
  );
  assert.equal(decoded.claims[0]!.ownerAtClaim, other);
  assert.equal(decoded.claims[0]!.receiver, addr);
  assert.throws(() =>
    decodeLogs(
      { requests: [], batches: [], claims: [{ ...log, removed: true }] },
      config(),
    ),
  );
});
function server(mutate?: (data: Record<string, any>, query: string) => void) {
  const c = config(),
    f = facts(),
    id = seriesId(c);
  const state = {
    id,
    chainId: c.chainId,
    issuer: c.issuer,
    adapterVersion: c.adapterVersion,
    environment: c.environment,
    sourceAsset: c.sourceAsset,
    settlementAsset: c.settlementAsset,
    decimals: c.decimals,
    complete: true,
    requestCount: "3",
    batchCount: "1",
    claimCount: "1",
    lastRequest: "3",
    lastFinalized: "2",
    cumulativeFace: "300",
    cumulativeShares: "300",
    locked: "180",
    paid: "90",
  };
  const rows = {
    withdrawalRequests: f.requests,
    finalizationBatches: f.batches,
    withdrawalClaims: f.claims,
  };
  let calls = 0;
  return {
    get calls() {
      return calls;
    },
    request: async (query: string, variables: Record<string, unknown> = {}) => {
      calls++;
      assert.deepEqual(variables.block, { hash: block });
      const data: Record<string, any> = {
        _meta: {
          hasIndexingErrors: false,
          deployment: c.expectedDeployment,
          block: { number: c.endBlock, hash: block },
        },
      };
      if (query.includes("query HistorySeries"))
        data.historySeries = structuredClone(state);
      else
        for (const [entity, values] of Object.entries(rows))
          if (query.includes(entity + "("))
            data[entity] = values
              .map((r, i) => ({
                ...r,
                id: "0x" + word(String(i + 1)),
                series: { id },
              }))
              .filter((r) => r.id > String(variables.after))
              .slice(0, Number(variables.first));
      mutate?.(data, query);
      return data;
    },
  };
}
const canonicalCheck = async () => ({
  chainId: "1",
  number: 10,
  hash: block,
  timestamp: "100",
  finalizedNumber: 12,
});
test("pinned paginated Graph export has complete record parity", async () => {
  const s = server();
  const out = await exportHistory(config(), s.request, canonicalCheck, 2);
  assert.deepEqual(out.facts, facts());
  assert.equal(s.calls, 6);
});
for (const [label, change] of Object.entries({
  deployment: (d: any) => {
    d._meta.deployment = "wrong";
  },
  block: (d: any) => {
    d._meta.block.hash = "0x" + "ff".repeat(32);
  },
  indexing: (d: any) => {
    d._meta.hasIndexingErrors = true;
  },
  incomplete: (d: any) => {
    if (d.historySeries) d.historySeries.complete = false;
  },
  missing: (d: any) => {
    if (d.withdrawalRequests) d.withdrawalRequests = [];
  },
  foreign: (d: any) => {
    if (d.withdrawalRequests?.[0]) d.withdrawalRequests[0].series.id = "0xdead";
  },
  duplicate: (d: any) => {
    if (d.withdrawalRequests?.length === 2)
      d.withdrawalRequests[1] = d.withdrawalRequests[0];
  },
}))
  test("export rejects " + label, async () => {
    await assert.rejects(
      exportHistory(config(), server(change).request, canonicalCheck, 2),
    );
  });
test("canonical reorg or wrong chain rejects a completed export", async () => {
  let n = 0;
  await assert.rejects(
    exportHistory(
      config(),
      server().request,
      async () => ({
        ...(await canonicalCheck()),
        hash: n++ === 0 ? block : "0x" + "ff".repeat(32),
      }),
      2,
    ),
  );
  await assert.rejects(
    exportHistory(config(), server().request, async () => ({
      ...(await canonicalCheck()),
      chainId: "2",
    })),
  );
});
test("resume binds config and detects corrupt cached rows", async () => {
  const dir = mkdtempSync(path.join(tmpdir(), "harbor-pages-"));
  try {
    const cache = pageCache(dir);
    const one = await exportHistory(
      config(),
      server().request,
      canonicalCheck,
      2,
      cache,
    );
    const two = await exportHistory(
      config(),
      server().request,
      canonicalCheck,
      2,
      cache,
    );
    assert.deepEqual(one, two);
    assert.equal(cache.read("requests", "different"), null);
    const f = path.join(dir, "requests.json");
    const data = JSON.parse(readFileSync(f, "utf8"));
    data.rows[0].face = "0";
    writeFileSync(f, JSON.stringify(data));
    await assert.rejects(
      exportHistory(config(), server().request, canonicalCheck, 2, cache),
      /CORRUPT_CHECKPOINT/,
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
test("endpoint admission refuses credentials, redirects through query strings, unsupported hosts and missing gateway keys", () => {
  for (const url of [
    "https://evil.test/subgraphs/name/x",
    "http://user:password@localhost:8000/subgraphs/name/x",
    "http://localhost:8000/subgraphs/name/x?token=secret",
  ])
    assert.throws(() => transport(url, "LOCAL"));
  assert.throws(() =>
    transport("https://gateway.thegraph.com/api/subgraphs/id/abc", "GATEWAY"),
  );
});
test("GraphQL partial errors and missing data cannot be accepted", async () => {
  const old = globalThis.fetch;
  try {
    globalThis.fetch = async () =>
      new Response(
        JSON.stringify({ data: { x: 1 }, errors: [{ message: "partial" }] }),
      );
    await assert.rejects(
      transport("http://localhost:8000/subgraphs/name/x", "LOCAL")("x"),
      /GRAPHQL_ERRORS/,
    );
    globalThis.fetch = async () => new Response("{}");
    await assert.rejects(
      transport("http://localhost:8000/subgraphs/name/x", "LOCAL")("x"),
      /MISSING_DATA/,
    );
  } finally {
    globalThis.fetch = old;
  }
});
test("artifact identities ignore key order and dataset publishing refuses overwrites", () => {
  assert.equal(canonical({ b: 2, a: 1 }), canonical({ a: 1, b: 2 }));
  const dir = mkdtempSync(path.join(tmpdir(), "harbor-output-"));
  try {
    const out = path.join(dir, "dataset");
    publishDataset(out, { "facts.json": facts() });
    assert.throws(
      () => publishDataset(out, { "facts.json": {} }),
      /OUTPUT_ALREADY_EXISTS/,
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("conflicting block provenance is rejected even when event IDs are distinct", () => {
  const f = facts();
  f.requests[1]!.blockNumber = f.requests[0]!.blockNumber;
  f.requests[1]!.logIndex = "1";
  assert.throws(
    () => reconcileFacts(f, config(), rates),
    /BLOCK_PROVENANCE_CONFLICT/,
  );
});

// These queried API rules follow Graph Node's graph/src/schema/api.rs.
// This is a static query-contract check; live Graph Node remains a separate gate.
test("all query documents satisfy Graph Node relation and scalar argument types", () => {
  const source = readFileSync(
    new URL("../../history/schema.graphql", import.meta.url),
    "utf8",
  );
  const api = `scalar Bytes
scalar BigInt
directive @entity(immutable:Boolean) on OBJECT
 input Block_height {hash:Bytes number:Int number_gte:Int}
 input History_filter {series:String id_gt:Bytes}
 enum History_orderBy {id}
 enum OrderDirection {asc desc}
 type _Block_ {number:Int! hash:Bytes}
 type _Meta_ {deployment:String! hasIndexingErrors:Boolean! block:_Block_!}
 type Query {
  _meta(block:Block_height):_Meta_
  historySeries(id:ID!,block:Block_height):HistorySeries
  withdrawalRequests(block:Block_height,first:Int,orderBy:History_orderBy,orderDirection:OrderDirection,where:History_filter):[WithdrawalRequest!]!
  finalizationBatches(block:Block_height,first:Int,orderBy:History_orderBy,orderDirection:OrderDirection,where:History_filter):[FinalizationBatch!]!
  withdrawalClaims(block:Block_height,first:Int,orderBy:History_orderBy,orderDirection:OrderDirection,where:History_filter):[WithdrawalClaim!]!
 }`;
  const schema = buildSchema(source + "\n" + api);
  for (const name of ["series", "requests", "finalizations", "claims"]) {
    const query = readFileSync(
      new URL("../../queries/history-" + name + ".graphql", import.meta.url),
      "utf8",
    );
    assert.deepEqual(validate(schema, parse(query)), []);
    if (name !== "series")
      assert.ok(
        validate(
          schema,
          parse(query.replace("$series: String!", "$series: Bytes!")),
        ).length > 0,
      );
  }
});
