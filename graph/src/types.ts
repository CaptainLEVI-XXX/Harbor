/** Public observations are not executable quotes or source-admission decisions. */
export interface SourceCandidate {
  id: string;
  protocol: string;
  chainId: number;
  network: string;
  queryId: string;
  status: "DISCOVERED";
  expectedVersions: { schema: string; subgraph: string; methodology: string };
  /** A network query ID can move to another deployment without changing versions. */
  expectedDeployment: string;
  /** Explicit discovery targets, not financially admitted investments. */
  vaultIds?: string[];
  feePolicy?: "QUARANTINE_UPSTREAM_MAPPING";
}

export interface GraphHead {
  deployment: string;
  block: { number: number; hash: string };
}

/** Number-based Graph responses may omit the hash; never substitute an RPC hash. */
export interface NumberGraphHead {
  deployment: string;
  block: { number: number; hash: string | null };
}

export interface BlockHeader { number: number; hash: string; timestamp: number }

export interface HistoricalVaultObservation {
  sourceId: string;
  chainId: number;
  environment: "PUBLIC_CHAIN";
  mode: "FINALIZED_NUMBER";
  queryHash: string;
  queriedAt: string;
  graphHead: NumberGraphHead;
  canonicalBlock: BlockHeader;
  finalizedAtCheck: BlockHeader;
  /** Header checks do not verify archive eth_call or the mapping's valuation. */
  contractValueVerified: false;
  admitted: false;
  vault: VaultSample;
}

export interface Token {
  id: string;
  symbol: string;
  decimals: number;
}

export interface VaultSample {
  id: string;
  name: string | null;
  inputToken: Token;
  outputToken: Token | null;
  inputTokenBalance: string;
  outputTokenSupply: string | null;
  pricePerShare: string | null;
  totalValueLockedUSD: string;
  fees: { feeType: string; feePercentage: string | null;
    status: "SOURCE_REPORTED" | "UNAVAILABLE" | "QUARANTINED" }[];
  quality: {
    sharePrice: "SOURCE_REPORTED" | "UNAVAILABLE";
    returnComparable: false;
    reasons: string[];
  };
  dailySnapshots: {
    id: string;
    timestamp: string;
    blockNumber: string;
    pricePerShare: string | null;
  }[];
}

export interface SourceInspection {
  sourceId: string;
  protocol: string;
  chainId: number;
  environment: "PUBLIC_CHAIN";
  queryHash: string;
  queriedAt: string;
  head: GraphHead;
  versions: SourceCandidate["expectedVersions"];
  vaults: VaultSample[];
  liveQueryVerified: true;
  admitted: false;
  outstandingChecks: string[];
}

/** Exact rational arithmetic; amounts remain integers until display formatting. */
export interface Fraction { numerator: bigint; denominator: bigint }

/** This input is produced only after source/methodology and pinned-block review. */
export interface ReturnObservation {
  sourceId: string;
  vaultId: string;
  chainId: number;
  assetAddress: string;
  environment: "PUBLIC_CHAIN" | "LOCAL" | "SIMULATION";
  timestamp: number;
  blockNumber: number;
  blockHash: string;
  deployment: string;
  methodologyVersion: string;
  measurement: "HISTORICAL_SHARE_RETURN" | "CURRENT_SUPPLY_APR" | "SIMULATED_RETURN";
  shareValue: Fraction;
  /** Describes included fees/rewards; equality is required within a return series. */
  treatment: string;
  fresh: boolean;
}

export class AnalyticsError extends Error {
  readonly code: string;
  constructor(code: string) { super(code); this.name = "AnalyticsError"; this.code = code; }
}

export function requireValue(condition: unknown, code: string): asserts condition {
  if (!condition) throw new AnalyticsError(code);
}
