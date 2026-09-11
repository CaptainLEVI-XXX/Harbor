import test from "node:test";
import assert from "node:assert/strict";
import { candidates, gatewayEndpoint } from "../src/sources.js";
import { graphClient, headOf } from "../src/graph.js";
import { rpcClient, quantity } from "../src/rpc.js";
import type { RpcRequest } from "../src/rpc.js";
import { inspectSource, INSPECTION_QUERY, vaultAt, vaultAtFinalizedNumber } from "../src/standardized-vaults.js";
import { assetKey, decimal, fraction, harborShareValue, periodReturn, comparableAssets, alignedWindows, formatFraction } from "../src/metrics.js";
import type { ReturnObservation, SourceCandidate } from "../src/types.js";

// Synthetic transport fixtures: never counted as live provider evidence.
const hash = "0x" + "11".repeat(32);
const nextHash = "0x" + "22".repeat(32);
const address = "0x" + "ab".repeat(20);
const deployment = "Qm" + "a".repeat(44);
const meta = { deployment, hasIndexingErrors: false, block: { number: 100, hash } };
const sample = {
  id: address, name: "Synthetic vault", inputToken: { id: address, symbol: "USD", decimals: 6 },
  outputToken: { id: address, symbol: "SHARE", decimals: 18 }, inputTokenBalance: "1000000",
  outputTokenSupply: "1000000000000000000", pricePerShare: "1.01", totalValueLockedUSD: "1.01",
  fees: [{ feeType: "WITHDRAWAL_FEE", feePercentage: "0.6" }],
  dailySnapshots: [{ id: "day-2", timestamp: "2000", blockNumber: "90", pricePerShare: "1.01" },
    { id: "day-1", timestamp: "1000", blockNumber: "80", pricePerShare: "1" }],
};

function protocol(source: SourceCandidate) {
  return { network: source.network, schemaVersion: source.expectedVersions.schema,
    subgraphVersion: source.expectedVersions.subgraph, methodologyVersion: source.expectedVersions.methodology };
}

function fixtureSource(): SourceCandidate {
  return { ...candidates()[0]!, expectedDeployment: deployment, vaultIds: [address] };
}

const rpcFixture: RpcRequest = async (method, params) => method === "eth_chainId" ? "0x1"
  : { number: params[0] === "finalized" ? "0x6e" : params[0], hash,
    timestamp: params[0] === "finalized" ? "0xfa0" : "0xbb8" };

function observation(overrides: Partial<ReturnObservation> = {}): ReturnObservation {
  return { sourceId: "fixture", vaultId: address, chainId: 1, assetAddress: address,
    environment: "PUBLIC_CHAIN", timestamp: 1000, blockNumber: 80, blockHash: hash, deployment,
    methodologyVersion: "1.0.0", measurement: "HISTORICAL_SHARE_RETURN", shareValue: fraction(1n, 1n),
    treatment: "net-share-value-excluding-external-rewards", fresh: true, ...overrides };
}

test("one query spans two protocols and chains while admission remains explicit", async () => {
  const catalog = candidates();
  assert.ok(new Set(catalog.map(s => s.protocol)).size >= 2);
  assert.ok(new Set(catalog.map(s => s.chainId)).size >= 2);
  const queryHashes = new Set<string>();
  for (const candidate of catalog) {
    const source = { ...candidate, expectedDeployment: deployment };
    const samples = (source.vaultIds ?? [address]).map(id => ({ ...sample, id,
      pricePerShare: source.protocol === "arrakis-finance" ? null : sample.pricePerShare }));
    const queries: string[] = [];
    const result = await inspectSource(source, async (query, variables) => {
      queries.push(query);
      if (queries.length === 1) return { _meta: meta };
      assert.deepEqual(variables, { block: { hash }, where: source.vaultIds ? { id_in: source.vaultIds } : {} });
      return { _meta: meta, yieldAggregators: [protocol(source)], vaults: samples };
    });
    assert.equal(queries[1], INSPECTION_QUERY);
    assert.equal(result.chainId, source.chainId);
    assert.equal(result.admitted, false);
    assert.equal(result.vaults[0]!.inputToken.decimals, 6);
    queryHashes.add(result.queryHash);
    assert.equal(result.vaults[0]!.quality.returnComparable, false);
    if (source.feePolicy) {
      assert.equal(result.vaults[0]!.fees[0]!.feePercentage, null);
      assert.equal(result.vaults[0]!.fees[0]!.status, "QUARANTINED");
      assert.ok(result.vaults[0]!.quality.reasons.includes("FEE_MAPPING_QUARANTINED"));
    }
    if (source.protocol === "arrakis-finance") {
      assert.equal(result.vaults[0]!.pricePerShare, null);
      assert.ok(result.vaults[0]!.quality.reasons.includes("MISSING_SHARE_PRICE"));
    }
    const fetched = await vaultAt(source, address, result.head, async (_, vars) => {
      assert.deepEqual(vars, { id: address, block: { hash } });
      return { _meta: meta, vault: { ...sample, protocol: protocol(source) } };
    });
    assert.equal(fetched.pricePerShare, "1.01");
    if (source.feePolicy) assert.equal(fetched.fees[0]!.status, "QUARANTINED");
  }
  assert.equal(queryHashes.size, 1);
  assert.match(INSPECTION_QUERY, /orderBy: totalValueLockedUSD, orderDirection: desc/);
});

test("provider failures do not leak credentials or become partial successful data", async () => {
  const endpoint = gatewayEndpoint(candidates()[0]!);
  assert.throws(() => graphClient(endpoint, undefined), /MISSING_GRAPH_API_KEY/);
  assert.throws(() => graphClient("https://attacker.invalid", "private-test-value"), /UNAPPROVED_ENDPOINT/);
  const replies = [
    { errors: [{ message: "private-test-value" }], data: { _meta: meta } },
    { data: null },
  ];
  for (const payload of replies) {
    const client = graphClient(endpoint, "private-test-value", async (url, options) => {
      assert.equal(url, endpoint);
      assert.equal(options?.redirect, "error");
      assert.equal((options?.headers as Record<string, string>).Authorization, "Bearer private-test-value");
      assert.ok(!String(url).includes("private-test-value"));
      return new Response(JSON.stringify(payload));
    });
    await assert.rejects(client("query"), error => {
      assert.ok(error instanceof Error);
      assert.ok(!error.message.includes("private-test-value"));
      return true;
    });
  }
  const success = graphClient(endpoint, "private-test-value", async () => new Response(JSON.stringify({ data: { ok: true } })));
  assert.deepEqual(await success("query"), { ok: true });
  assert.throws(() => rpcClient(undefined), /MISSING_GRAPH_RPC_URL/);
  assert.throws(() => rpcClient("http://unapproved.invalid"), /INVALID_RPC_ENDPOINT/);
  const rpc = rpcClient("https://rpc.invalid/private-test-value", async (_, options) => {
    assert.equal(options?.redirect, "error");
    throw new Error("private-test-value");
  });
  await assert.rejects(rpc("eth_chainId", []), /^AnalyticsError: RPC_REQUEST_FAILED$/);
  const partialRpc = rpcClient("https://rpc.invalid", async () => new Response(JSON.stringify({
    jsonrpc: "2.0", id: 1, result: "0x1", error: { message: "private-test-value" },
  })));
  await assert.rejects(partialRpc("eth_chainId", []), /^AnalyticsError: RPC_ERROR$/);
  await assert.rejects(rpc("eth_getBlockByNumber", ["latest", false]), /INVALID_RPC_PARAMS/);
  assert.throws(() => quantity("0x01"), /INVALID_RPC_QUANTITY/);
});

test("indexing errors, changed blocks, versions and malformed economics fail closed", async () => {
  const source = fixtureSource();
  const base = { _meta: meta, yieldAggregators: [protocol(source)], vaults: [sample] };
  const changes: [(data: typeof base) => void, RegExp][] = [
    [data => { data._meta.hasIndexingErrors = true; }, /INDEXING_ERRORS/],
    [data => { data._meta.block.hash = nextHash; }, /BLOCK_CHANGED/],
    [data => { data._meta.deployment = "Qm" + "b".repeat(44); }, /DEPLOYMENT_CHANGED/],
    [data => { data.yieldAggregators[0]!.network = "ARBITRUM_ONE"; }, /CHAIN_MISMATCH/],
    [data => { data.yieldAggregators[0]!.schemaVersion = "1.2.1"; }, /UNSUPPORTED_SCHEMA/],
    [data => { data.yieldAggregators[0]!.methodologyVersion = "2.0.0"; }, /VERSION_REVIEW_REQUIRED/],
    [data => { data.vaults[0]!.inputToken.decimals = -1; }, /INVALID_DECIMALS/],
    [data => { data.vaults[0]!.fees[0]!.feePercentage = "NaN"; }, /INVALID_DECIMAL/],
    [data => { data.vaults[0]!.dailySnapshots[0]!.blockNumber = "101"; }, /FUTURE_HISTORY/],
  ];
  for (const [mutate, reason] of changes) {
    const changed = structuredClone(base); mutate(changed);
    let count = 0;
    await assert.rejects(inspectSource(source, async () => ++count === 1 ? { _meta: meta } : changed), reason);
  }
  const supported = { ...source, expectedVersions: { ...source.expectedVersions, schema: "1.3.1" } };
  let count = 0;
  const valid = await inspectSource(supported, async () => ++count === 1 ? { _meta: meta } : { ...base, yieldAggregators: [protocol(supported)] });
  assert.equal(valid.versions.schema, "1.3.1");
  await assert.rejects(inspectSource({ ...source, expectedDeployment: "Qm" + "b".repeat(44) },
    async () => ({ _meta: meta })), /DEPLOYMENT_REVIEW_REQUIRED/);
  count = 0;
  await assert.rejects(inspectSource({ ...source, vaultIds: ["0x" + "cd".repeat(20)] },
    async () => ++count === 1 ? { _meta: meta } : base), /SELECTED_VAULTS_MISSING/);

  // Number-based history is an explicit mode, not a relaxation of strict reads.
  const historical = { _meta: { ...meta, block: { number: 100, hash: null as string | null } },
    vault: { ...sample, protocol: protocol(source) } };
  assert.throws(() => headOf(historical), /MISSING_BLOCK_HASH/);
  const request = async (_: string, variables?: Record<string, unknown>) => {
    if (!variables) return { _meta: meta };
    assert.deepEqual(variables, { id: address, block: { number: 100 } });
    return historical;
  };
  const result = await vaultAtFinalizedNumber(source, address, 100, request, rpcFixture);
  assert.equal(result.graphHead.block.hash, null);
  assert.equal(result.canonicalBlock.hash, hash);
  assert.equal(result.canonicalBlock.timestamp, 3000);
  assert.equal(result.vault.dailySnapshots[0]!.timestamp, "2000"); // never rewrite as query time
  assert.equal(result.contractValueVerified, false);
  assert.equal(result.admitted, false);
  assert.equal(result.vault.pricePerShare, "1.01");
  const quarantined = await vaultAtFinalizedNumber({ ...source, feePolicy: "QUARANTINE_UPSTREAM_MAPPING" },
    address, 100, request, rpcFixture);
  assert.equal(quarantined.vault.fees[0]!.feePercentage, null);
  assert.equal(quarantined.vault.fees[0]!.status, "QUARANTINED");
  const historyChanges: [(data: typeof historical) => void, RegExp][] = [
    [data => { data._meta.block.number = 99; }, /BLOCK_CHANGED/],
    [data => { data._meta.block.hash = nextHash; }, /BLOCK_CHANGED/],
    [data => { data._meta.deployment = "Qm" + "b".repeat(44); }, /DEPLOYMENT_CHANGED/],
    [data => { data._meta.hasIndexingErrors = true; }, /INDEXING_ERRORS/],
    [data => { data.vault.dailySnapshots[0]!.timestamp = "3001"; }, /FUTURE_HISTORY/],
    [data => { data.vault.protocol.network = "OPTIMISM"; }, /CHAIN_MISMATCH/],
  ];
  for (const [mutate, reason] of historyChanges) {
    const changed = structuredClone(historical); mutate(changed);
    await assert.rejects(vaultAtFinalizedNumber(source, address, 100,
      async (_, vars) => vars ? changed : { _meta: meta }, rpcFixture), reason);
  }
  await assert.rejects(vaultAtFinalizedNumber(source, address, 111, request, rpcFixture), /BLOCK_NOT_FINALIZED/);
  await assert.rejects(vaultAtFinalizedNumber({ ...source, chainId: 10 }, address, 100, request, rpcFixture), /UNREVIEWED_FINALITY_POLICY/);
  await assert.rejects(vaultAtFinalizedNumber(source, address, 100, request,
    async (method, params) => method === "eth_chainId" ? "0xa" : rpcFixture(method, params)), /RPC_CHAIN_MISMATCH/);
  let headers = 0;
  await assert.rejects(vaultAtFinalizedNumber(source, address, 100, request, async (method, params) => {
    const value = await rpcFixture(method, params);
    if (method === "eth_getBlockByNumber" && params[0] !== "finalized" && ++headers === 2) {
      return { ...(value as object), hash: nextHash };
    }
    return value;
  }), /RPC_BLOCK_CHANGED/);
  let graphReads = 0;
  await assert.rejects(vaultAtFinalizedNumber(source, address, 100, async (query, vars) => {
    if (++graphReads === 3) return { _meta: { ...meta, deployment: "Qm" + "b".repeat(44) } };
    return request(query, vars);
  }, rpcFixture), /DEPLOYMENT_CHANGED/);
});

test("returns preserve exact units, negative outcomes and Harbor virtual shares", () => {
  assert.deepEqual(decimal("1.234e-6"), { numerator: 617n, denominator: 500000000n });
  assert.throws(() => decimal("1e999"), /DECIMAL_TOO_LARGE/);
  assert.throws(() => fraction(1n, 0n), /INVALID_DENOMINATOR/);
  // Matching virtual scales make a one-cash-unit/full-share deposit worth exactly one.
  assert.deepEqual(harborShareValue(1_000_000n, 1_000_000_000_000n, 6, 12), fraction(1n, 1n));
  assert.deepEqual(harborShareValue(10n ** 18n, 10n ** 24n, 18, 24), fraction(1n, 1n));
  const start = observation();
  const end = observation({ timestamp: 87400, blockNumber: 100, blockHash: nextHash, shareValue: fraction(103n, 100n) });
  assert.deepEqual(periodReturn(start, end), fraction(3n, 100n));
  assert.equal(formatFraction(periodReturn(start, { ...end, shareValue: fraction(97n, 100n) })), "-0.03000000");
  assert.deepEqual(periodReturn(start, { ...end, shareValue: fraction(0n, 1n) }), fraction(-1n, 1n));
  assert.throws(() => periodReturn({ ...start, shareValue: fraction(0n, 1n) }, end), /INVALID_SHARE_VALUE/);
  assert.throws(() => periodReturn(start, { ...end, treatment: "gross-plus-rewards" }), /METHODOLOGY_CHANGED/);
  assert.throws(() => periodReturn(start, { ...end, environment: "SIMULATION" }), /NON_LIVE_SERIES/);
  assert.throws(() => periodReturn(start, { ...end, fresh: false }), /STALE_OBSERVATION/);
});

test("cross-chain comparison uses explicit asset equivalence and time, not symbols or block heights", () => {
  const a = observation();
  const b = observation({ chainId: 42161, timestamp: 1008, blockNumber: 800 });
  assert.notEqual(assetKey(a.chainId, address), assetKey(b.chainId, address));
  assert.equal(comparableAssets(a, b, new Map()), false);
  const groups = new Map([[assetKey(1, address), "reviewed-asset"], [assetKey(42161, address), "reviewed-asset"]]);
  assert.equal(comparableAssets(a, b, groups), true);
  const ae = { ...a, timestamp: 2000, blockNumber: 100, blockHash: nextHash };
  const be = { ...b, timestamp: 2008, blockNumber: 1000, blockHash: nextHash };
  assert.equal(alignedWindows([a, ae], [b, be], 10), true);
  assert.equal(alignedWindows([a, ae], [b, be], 5), false);
  assert.equal(alignedWindows([a, ae], [{ ...b, chainId: 1 }, { ...be, chainId: 1 }], 10), false);
  assert.throws(() => alignedWindows([a, ae], [b, be], 90000), /INVALID_TOLERANCE/);
});
