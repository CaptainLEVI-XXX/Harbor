import { readFileSync } from "node:fs";
import { requireValue } from "./types.js";
import type { SourceCandidate } from "./types.js";

export const CATALOG_REVISION = "2711ac91ef119f321f65b339e10a57f9aa74f9d8";
const networks: Record<string, number> = { MAINNET: 1, ARBITRUM_ONE: 42161, OPTIMISM: 10 };

/** Load reviewed public identifiers, never endpoints or keys supplied by a UI. */
export function candidates(): SourceCandidate[] {
  const raw = JSON.parse(readFileSync(new URL("../../sources/catalog.json", import.meta.url), "utf8"));
  requireValue(raw.catalogRevision === CATALOG_REVISION && Array.isArray(raw.sources), "INVALID_CATALOG");
  const seen = new Set<string>();
  for (const source of raw.sources) {
    requireValue(typeof source.id === "string" && !seen.has(source.id), "DUPLICATE_SOURCE");
    requireValue(source.status === "DISCOVERED", "UNREVIEWED_ADMISSION");
    requireValue(networks[source.network] === source.chainId, "INVALID_CHAIN");
    requireValue(typeof source.protocol === "string" && /^[a-z0-9-]+$/.test(source.protocol), "INVALID_PROTOCOL");
    requireValue(/^[1-9A-HJ-NP-Za-km-z]{40,60}$/.test(source.queryId), "INVALID_QUERY_ID");
    requireValue(typeof source.expectedDeployment === "string" && /^[1-9A-HJ-NP-Za-km-z]{40,60}$/.test(source.expectedDeployment), "INVALID_DEPLOYMENT");
    requireValue(source.feePolicy === undefined || source.feePolicy === "QUARANTINE_UPSTREAM_MAPPING", "INVALID_FEE_POLICY");
    if (source.vaultIds !== undefined) {
      requireValue(Array.isArray(source.vaultIds) && source.vaultIds.length > 0 && source.vaultIds.length <= 5
        && new Set(source.vaultIds).size === source.vaultIds.length
        && source.vaultIds.every((id: unknown) => typeof id === "string" && /^0x[0-9a-f]{40}$/.test(id)), "INVALID_VAULT_SELECTION");
    }
    requireValue(["1.3.0", "1.3.1"].includes(source.expectedVersions?.schema), "UNSUPPORTED_SCHEMA");
    requireValue(typeof source.expectedVersions?.subgraph === "string" && typeof source.expectedVersions?.methodology === "string", "INVALID_VERSIONS");
    seen.add(source.id);
  }
  return raw.sources;
}

/** Avoid logging a key-bearing URL by keeping credentials exclusively in headers. */
export function gatewayEndpoint(source: SourceCandidate): string {
  requireValue(/^[1-9A-HJ-NP-Za-km-z]{40,60}$/.test(source.queryId), "INVALID_QUERY_ID");
  return `https://gateway.thegraph.com/api/subgraphs/id/${source.queryId}`;
}
