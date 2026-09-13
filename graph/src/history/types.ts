import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { requireValue, objectNever } from "./validation.js";
export { requireValue } from "./validation.js";
export interface SeriesConfig {
  id: string;
  chainId: string;
  network: string;
  environment: "MAINNET" | "TESTNET" | "BUILD_FIXTURE";
  issuer: string;
  adapterVersion: "lido-inclusive-v1";
  sourceAsset: string;
  settlementAsset: string;
  decimals: number;
  startBlock: number;
  endBlock: number;
  cutoffHash: string;
  cutoffTimestamp: string;
  coverageOrigin: "FROM_FIRST_REQUEST";
  evidence: "CACHED_RESEARCH" | "FIXTURE";
  finalityPolicy: "RPC_FINALIZED";
  expectedDeployment: string | null;
}
export interface Coordinate {
  blockNumber: string;
  blockHash: string;
  transactionHash: string;
  transactionIndex: string;
  logIndex: string;
  timestamp: string;
}
export interface Request extends Coordinate {
  requestId: string;
  face: string;
  shares: string;
  requestor: string;
  ownerAtRequest: string;
  prefixFace: string;
  prefixShares: string;
}
export interface Batch extends Coordinate {
  sequence: string;
  firstRequest: string;
  lastRequest: string;
  locked: string;
  shares: string;
  requestedFace: string;
  finalizedAt: string;
}
export interface Claim extends Coordinate {
  requestId: string;
  ownerAtClaim: string;
  receiver: string;
  amount: string;
}
export interface Facts {
  requests: Request[];
  batches: Batch[];
  claims: Claim[];
}
export interface Outcome {
  requestId: string;
  finalizationSequence: string | null;
  finalizedAt: string | null;
  recovery: string | null;
  observedClaim: string | null;
  claimedAt: string | null;
}
export function hash(value: string | Uint8Array): string {
  return createHash("sha256").update(value).digest("hex");
}
export function uint(value: unknown): string {
  requireValue(
    typeof value === "string" && /^(0|[1-9][0-9]*)$/.test(value),
    "INVALID_INTEGER",
  );
  requireValue(BigInt(value) < 2n ** 256n, "INTEGER_OVERFLOW");
  return value;
}
export function hex(value: unknown, bytes: number): string {
  requireValue(
    typeof value === "string" &&
      new RegExp(`^0x[0-9a-fA-F]{${bytes * 2}}$`).test(value),
    "INVALID_HEX",
  );
  return value.toLowerCase();
}
export function word(value: string): string {
  return BigInt(uint(value)).toString(16).padStart(64, "0");
}
export function seriesId(c: SeriesConfig): string {
  return (
    "0x" +
    Buffer.from("harbor:history:v1").toString("hex") +
    word(c.chainId) +
    c.issuer.slice(2)
  );
}
export function validateConfig(raw: unknown): SeriesConfig {
  const c = objectNever(raw);
  requireValue(
    typeof c.id === "string" && /^[a-z0-9][a-z0-9-]{0,79}$/.test(c.id),
    "INVALID_SERIES_ID",
  );
  uint(c.chainId);
  requireValue(BigInt(c.chainId as string) > 0n, "INVALID_CHAIN");
  requireValue(
    typeof c.network === "string" && /^[a-z0-9-]+$/.test(c.network),
    "INVALID_NETWORK",
  );
  requireValue(
    ["MAINNET", "TESTNET", "BUILD_FIXTURE"].includes(String(c.environment)),
    "INVALID_ENVIRONMENT",
  );
  const chains = objectNever(
    JSON.parse(
      readFileSync(
        new URL("../../../history/chains.json", import.meta.url),
        "utf8",
      ),
    ),
  );
  requireValue(
    objectNever(chains[c.chainId as string]).network === c.network,
    "CHAIN_NETWORK_MISMATCH",
  );
  hex(c.issuer, 20);
  hex(c.cutoffHash, 32);
  uint(c.cutoffTimestamp);
  requireValue(
    c.adapterVersion === "lido-inclusive-v1",
    "UNSUPPORTED_ISSUER_ADAPTER",
  );
  requireValue(
    c.coverageOrigin === "FROM_FIRST_REQUEST",
    "UNVERIFIED_BOOTSTRAP",
  );
  requireValue(
    c.finalityPolicy === "RPC_FINALIZED",
    "UNSUPPORTED_FINALITY_POLICY",
  );
  requireValue(
    Number.isInteger(c.decimals) &&
      Number(c.decimals) >= 0 &&
      Number(c.decimals) <= 36,
    "INVALID_DECIMALS",
  );
  requireValue(
    Number.isSafeInteger(c.startBlock) &&
      Number(c.startBlock) >= 0 &&
      Number.isSafeInteger(c.endBlock) &&
      Number(c.endBlock) >= Number(c.startBlock),
    "INVALID_COVERAGE",
  );
  for (const key of ["sourceAsset", "settlementAsset"])
    requireValue(
      typeof c[key] === "string" &&
        (c[key] as string).startsWith(`eip155:${c.chainId}/`) &&
        /^eip155:[1-9][0-9]*\/(erc20:0x[0-9a-fA-F]{40}|slip44:[0-9]+)$/.test(
          c[key] as string,
        ),
      "ASSET_CHAIN_MISMATCH",
    );
  requireValue(
    c.evidence ===
      (c.environment === "BUILD_FIXTURE" ? "FIXTURE" : "CACHED_RESEARCH"),
    "INVALID_SOURCE_EVIDENCE",
  );
  requireValue(
    c.expectedDeployment === null ||
      (typeof c.expectedDeployment === "string" &&
        /^[a-zA-Z0-9]{40,100}$/.test(c.expectedDeployment)),
    "INVALID_DEPLOYMENT",
  );
  return {
    ...c,
    issuer: hex(c.issuer, 20),
    cutoffHash: hex(c.cutoffHash, 32),
  } as unknown as SeriesConfig;
}
export function coordinate(raw: Record<string, unknown>): Coordinate {
  return {
    blockNumber: uint(raw.blockNumber),
    blockHash: hex(raw.blockHash, 32),
    transactionHash: hex(raw.transactionHash, 32),
    transactionIndex: uint(raw.transactionIndex),
    logIndex: uint(raw.logIndex),
    timestamp: uint(raw.timestamp),
  };
}
export function order(a: Coordinate, b: Coordinate): number {
  for (const field of [
    "blockNumber",
    "transactionIndex",
    "logIndex",
  ] as const) {
    const x = BigInt(a[field]),
      y = BigInt(b[field]);
    if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
}
