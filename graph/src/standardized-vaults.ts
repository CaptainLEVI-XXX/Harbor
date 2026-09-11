import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { headOf, numberHeadOf, object, sameHead } from "./graph.js";
import type { GraphRequest } from "./graph.js";
import { blockHeader, quantity } from "./rpc.js";
import type { RpcRequest } from "./rpc.js";
import { decimal } from "./metrics.js";
import { requireValue } from "./types.js";
import type { GraphHead, NumberGraphHead, HistoricalVaultObservation, SourceCandidate, SourceInspection, Token, VaultSample } from "./types.js";

export const INSPECTION_QUERY = readFileSync(new URL("../../queries/source-inspection.graphql", import.meta.url), "utf8");
export const SNAPSHOT_QUERY = readFileSync(new URL("../../queries/vault-snapshot.graphql", import.meta.url), "utf8");
const HEAD_QUERY = "{ _meta { deployment hasIndexingErrors block { number hash } } }";

function string(value: unknown): string {
  requireValue(typeof value === "string", "MISSING_FIELD");
  return value;
}

function integer(value: unknown): string {
  const text = string(value);
  requireValue(/^(0|[1-9][0-9]*)$/.test(text) && text.length <= 100, "INVALID_INTEGER");
  return text;
}

function amount(value: unknown): string {
  const text = string(value);
  requireValue(decimal(text).numerator >= 0n, "NEGATIVE_AMOUNT");
  return text;
}

function address(value: unknown): string {
  const text = string(value);
  requireValue(/^0x[0-9a-fA-F]{40}$/.test(text), "INVALID_ADDRESS");
  return text.toLowerCase();
}

function token(value: unknown): Token {
  const raw = object(value);
  requireValue(Number.isInteger(raw.decimals) && (raw.decimals as number) >= 0 && (raw.decimals as number) <= 36, "INVALID_DECIMALS");
  return { id: address(raw.id), symbol: string(raw.symbol), decimals: raw.decimals as number };
}

export function parseVault(value: unknown, head: NumberGraphHead, source: SourceCandidate): VaultSample {
  const raw = object(value);
  requireValue(Array.isArray(raw.fees) && raw.fees.length <= 20, "INVALID_FEES");
  requireValue(Array.isArray(raw.dailySnapshots) && raw.dailySnapshots.length <= 2, "INVALID_HISTORY");
  const fees = raw.fees.map(value => {
    const fee = object(value);
    const kind = string(fee.feeType);
    requireValue(["DEPOSIT_FEE", "WITHDRAWAL_FEE", "PERFORMANCE_FEE", "MANAGEMENT_FEE"].includes(kind), "UNKNOWN_FEE");
    const quarantined = source.feePolicy === "QUARANTINE_UPSTREAM_MAPPING";
    // Do not interpret a known-bad mapping value, even if it is syntactically valid.
    const percentage = quarantined || fee.feePercentage === null ? null : amount(fee.feePercentage);
    if (percentage !== null) {
      const ratio = decimal(percentage);
      requireValue(ratio.numerator <= 100n * ratio.denominator, "INVALID_FEE");
    }
    const status: VaultSample["fees"][number]["status"] = quarantined ? "QUARANTINED"
      : percentage === null ? "UNAVAILABLE" : "SOURCE_REPORTED";
    return { feeType: kind, feePercentage: percentage, status };
  });
  const history = raw.dailySnapshots.map(value => {
    const snapshot = object(value);
    const blockNumber = integer(snapshot.blockNumber);
    requireValue(BigInt(blockNumber) <= BigInt(head.block.number), "FUTURE_HISTORY");
    return { id: string(snapshot.id), timestamp: integer(snapshot.timestamp), blockNumber,
      pricePerShare: snapshot.pricePerShare === null ? null : amount(snapshot.pricePerShare) };
  });
  for (let i = 1; i < history.length; i++) {
    requireValue(BigInt(history[i - 1]!.timestamp) > BigInt(history[i]!.timestamp), "UNORDERED_HISTORY");
  }
  const pricePerShare = raw.pricePerShare === null ? null : amount(raw.pricePerShare);
  const reasons = ["PER_VAULT_METHODOLOGY_UNVERIFIED", "CONTRACT_VALUE_UNVERIFIED", "VALUATION_FRESHNESS_UNVERIFIED"];
  if (pricePerShare === null) reasons.push("MISSING_SHARE_PRICE");
  if (raw.outputToken === null || raw.outputTokenSupply === null) reasons.push("MISSING_SHARE_METADATA");
  if (source.feePolicy === "QUARANTINE_UPSTREAM_MAPPING") reasons.push("FEE_MAPPING_QUARANTINED");
  if (history.length === 0) reasons.push("MISSING_OBSERVATION_TIME");
  return {
    id: address(raw.id), name: raw.name === null ? null : string(raw.name), inputToken: token(raw.inputToken),
    outputToken: raw.outputToken === null ? null : token(raw.outputToken),
    inputTokenBalance: integer(raw.inputTokenBalance),
    outputTokenSupply: raw.outputTokenSupply === null ? null : integer(raw.outputTokenSupply),
    pricePerShare,
    totalValueLockedUSD: amount(raw.totalValueLockedUSD), fees, dailySnapshots: history,
    quality: { sharePrice: pricePerShare === null ? "UNAVAILABLE" : "SOURCE_REPORTED", returnComparable: false, reasons },
  };
}

function reviewedDeployment(source: SourceCandidate, head: NumberGraphHead): void {
  requireValue(head.deployment === source.expectedDeployment, "DEPLOYMENT_REVIEW_REQUIRED");
}

function versionsOf(value: unknown, source: SourceCandidate): SourceCandidate["expectedVersions"] {
  const raw = object(value);
  requireValue(raw.network === source.network, "CHAIN_MISMATCH");
  const versions = { schema: string(raw.schemaVersion), subgraph: string(raw.subgraphVersion), methodology: string(raw.methodologyVersion) };
  requireValue(["1.3.0", "1.3.1"].includes(versions.schema), "UNSUPPORTED_SCHEMA");
  for (const field of ["schema", "subgraph", "methodology"] as const) {
    requireValue(versions[field] === source.expectedVersions[field], "VERSION_REVIEW_REQUIRED");
  }
  return versions;
}

/** Pin the sample to the discovered hash; never accept a mixed deployment/fork. */
export async function inspectSource(source: SourceCandidate, request: GraphRequest): Promise<SourceInspection> {
  const head = headOf(await request(HEAD_QUERY));
  reviewedDeployment(source, head);
  const data = object(await request(INSPECTION_QUERY, {
    block: { hash: head.block.hash }, where: source.vaultIds ? { id_in: source.vaultIds } : {},
  }));
  sameHead(head, headOf(data));
  requireValue(Array.isArray(data.yieldAggregators) && data.yieldAggregators.length === 1, "INVALID_PROTOCOL_COUNT");
  const versions = versionsOf(data.yieldAggregators[0], source);
  requireValue(Array.isArray(data.vaults) && data.vaults.length > 0 && data.vaults.length <= 5, "NO_VAULT_SAMPLE");
  const vaults = data.vaults.map(value => parseVault(value, head, source));
  requireValue(new Set(vaults.map(v => v.id)).size === vaults.length, "DUPLICATE_VAULT");
  if (source.vaultIds) requireValue(vaults.length === source.vaultIds.length
    && vaults.every(v => source.vaultIds!.includes(v.id)), "SELECTED_VAULTS_MISSING");
  return {
    sourceId: source.id, protocol: source.protocol, chainId: source.chainId,
    environment: "PUBLIC_CHAIN", queryHash: createHash("sha256").update(INSPECTION_QUERY).digest("hex"),
    queriedAt: new Date().toISOString(), head, versions, vaults, liveQueryVerified: true, admitted: false,
    outstandingChecks: ["CANONICAL_RPC_AND_FINALITY", "PER_VAULT_METHODOLOGY", "ALIGNED_HISTORICAL_WINDOW", "VALUATION_FRESHNESS", "ASSET_COMPARABILITY"],
  };
}

/** Fetch an explicit historical block. Caller verifies canonicality/finality by RPC. */
export async function vaultAt(source: SourceCandidate, vaultId: string, head: GraphHead, request: GraphRequest): Promise<VaultSample> {
  reviewedDeployment(source, head);
  const id = address(vaultId);
  const data = object(await request(SNAPSHOT_QUERY, { id, block: { hash: head.block.hash } }));
  sameHead(head, headOf(data));
  const raw = object(data.vault);
  versionsOf(raw.protocol, source);
  const vault = parseVault(raw, head, source);
  requireValue(vault.id === id, "VAULT_MISMATCH");
  return vault;
}

/**
 * Explicit Ethereum finalized-number mode for providers omitting historical hashes.
 * RPC headers bracket the entire read; Graph provenance remains separate. This is
 * provider-trusted data, not a proof of Graph execution or of contract valuation.
 * No fallback to latest data, confirmation-count guesses, or automatic admission.
 */
export async function vaultAtFinalizedNumber(
  source: SourceCandidate, vaultId: string, blockNumber: number, request: GraphRequest, rpc: RpcRequest,
): Promise<HistoricalVaultObservation> {
  requireValue(source.chainId === 1, "UNREVIEWED_FINALITY_POLICY");
  requireValue(Number.isSafeInteger(blockNumber) && blockNumber >= 0 && blockNumber <= 2_147_483_647, "INVALID_BLOCK");
  const id = address(vaultId);
  requireValue(quantity(await rpc("eth_chainId", [])) === source.chainId, "RPC_CHAIN_MISMATCH");
  const finalized = await blockHeader(rpc, "finalized");
  requireValue(blockNumber <= finalized.number, "BLOCK_NOT_FINALIZED");
  const tag = `0x${blockNumber.toString(16)}`;
  const canonical = await blockHeader(rpc, tag);
  requireValue(canonical.timestamp <= finalized.timestamp, "RPC_TIME_MISMATCH");
  if (canonical.number === finalized.number) requireValue(canonical.hash === finalized.hash, "RPC_BLOCK_CHANGED");
  const current = headOf(await request(HEAD_QUERY));
  reviewedDeployment(source, current);
  requireValue(current.block.number >= blockNumber, "SOURCE_BEHIND");
  const data = object(await request(SNAPSHOT_QUERY, { id, block: { number: blockNumber } }));
  const historical = numberHeadOf(data);
  requireValue(historical.deployment === current.deployment, "DEPLOYMENT_CHANGED");
  requireValue(historical.block.number === blockNumber, "BLOCK_CHANGED");
  requireValue(historical.block.hash === null || historical.block.hash === canonical.hash, "BLOCK_CHANGED");
  const raw = object(data.vault);
  versionsOf(raw.protocol, source);
  const vault = parseVault(raw, historical, source);
  requireValue(vault.id === id, "VAULT_MISMATCH");
  requireValue(vault.dailySnapshots.every(s => BigInt(s.timestamp) <= BigInt(canonical.timestamp)), "FUTURE_HISTORY");
  const after = await blockHeader(rpc, tag);
  requireValue(after.hash === canonical.hash && after.timestamp === canonical.timestamp, "RPC_BLOCK_CHANGED");
  const currentAfter = headOf(await request(HEAD_QUERY));
  requireValue(currentAfter.deployment === current.deployment, "DEPLOYMENT_CHANGED");
  requireValue(currentAfter.block.number >= blockNumber, "SOURCE_BEHIND");
  return {
    sourceId: source.id, chainId: source.chainId, environment: "PUBLIC_CHAIN", mode: "FINALIZED_NUMBER",
    queryHash: createHash("sha256").update(SNAPSHOT_QUERY).digest("hex"), queriedAt: new Date().toISOString(),
    graphHead: historical, canonicalBlock: canonical, finalizedAtCheck: finalized,
    contractValueVerified: false, admitted: false, vault,
  };
}
