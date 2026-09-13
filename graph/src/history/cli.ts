import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { validateConfig, hash, requireValue } from "./types.js";
import { readReference } from "./cache.js";
import { reconcileFacts } from "./lido.js";
import { exportHistory } from "./export.js";
import { transport } from "./transport.js";
import { canonical, pageCache, publishDataset } from "./artifacts.js";
import { rpcClient, blockHeader, quantity } from "../rpc.js";
const root = fileURLToPath(new URL("../../../", import.meta.url));
async function main() {
  const [command, ...args] = process.argv.slice(2);
  requireValue(
    command === "cache" || command === "export",
    "USAGE_history_cache_OR_export",
  );
  requireValue(args.length % 2 === 0, "EXPECTED_FLAG_VALUE_PAIRS");
  const flags: Record<string, string> = {};
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i]!;
    requireValue(
      ["--series", "--reference", "--out", "--deployment", "--mode"].includes(
        key,
      ) && !flags[key],
      "UNKNOWN_OR_DUPLICATE_FLAG",
    );
    flags[key] = args[i + 1]!;
  }
  const configs: unknown = JSON.parse(
    readFileSync(path.join(root, "history/networks.json"), "utf8"),
  );
  requireValue(Array.isArray(configs), "INVALID_CONFIGS");
  let c = configs
    .map(validateConfig)
    .find((x) => x.id === (flags["--series"] ?? "ethereum-lido-2025-03"));
  requireValue(c, "UNKNOWN_SERIES");
  requireValue(
    flags["--reference"] && flags["--out"],
    "REQUIRED_reference_AND_out",
  );
  const reference = path.resolve(flags["--reference"]),
    out = path.resolve(flags["--out"]);
  requireValue(
    out !== reference && !out.startsWith(reference + path.sep),
    "OUTPUT_OVERLAPS_REFERENCE",
  );
  const ref = readReference(reference, c);
  let result = reconcileFacts(ref.facts, c, ref.rates);
  let graphProof: unknown = null;
  if (command === "export") {
    requireValue(flags["--deployment"], "REQUIRED_REVIEWED_DEPLOYMENT");
    c = validateConfig({ ...c, expectedDeployment: flags["--deployment"] });
    const mode = flags["--mode"] ?? "STUDIO";
    requireValue(
      mode === "STUDIO" || mode === "GATEWAY" || mode === "LOCAL",
      "INVALID_PROVIDER_MODE",
    );
    requireValue(process.env.HISTORY_GRAPH_URL, "MISSING_HISTORY_GRAPH_URL");
    const requester = transport(
      process.env.HISTORY_GRAPH_URL,
      mode,
      process.env.GRAPH_API_KEY,
    );
    const rpc = rpcClient(process.env.HISTORY_RPC_URL);
    const canonicalCheck = async () => {
      const [chain, cutoff, finalized] = await Promise.all([
        rpc("eth_chainId", []),
        blockHeader(rpc, "0x" + c!.endBlock.toString(16)),
        blockHeader(rpc, "finalized"),
      ]);
      return {
        chainId: String(quantity(chain)),
        number: cutoff.number,
        hash: cutoff.hash,
        timestamp: String(cutoff.timestamp),
        finalizedNumber: finalized.number,
      };
    };
    const exported = await exportHistory(
      c,
      requester,
      canonicalCheck,
      500,
      pageCache(out + ".resume"),
    );
    result = reconcileFacts(exported.facts, c, ref.rates);
    requireValue(
      canonical(result) === canonical(reconcileFacts(ref.facts, c, ref.rates)),
      "GRAPH_REFERENCE_MISMATCH",
    );
    const state = exported.proof.state;
    for (const [key, value] of Object.entries({
      lastRequest: String(result.totals.requests),
      lastFinalized: result.totals.finalizedRequests,
      cumulativeFace: result.totals.requestedFace,
      cumulativeShares: result.facts.requests.at(-1)?.prefixShares ?? "0",
      locked: result.totals.locked,
      paid: result.totals.paid,
    }))
      requireValue(state[key] === value, "GRAPH_STATE_TOTAL_MISMATCH");
    graphProof = exported.proof;
  }
  const files: Record<string, unknown> = {
    "facts.json": result.facts,
    "outcomes.json": result.outcomes,
    "checkpoints.json": ref.rates,
    "reconciliation.json": {
      passed: true,
      totals: result.totals,
      recordLevelCsv: true,
      boundaryTotals: true,
      graphComparison: command === "export",
    },
  };
  const contentHashes = Object.fromEntries(
    Object.entries(files).map(([k, v]) => [k, hash(canonical(v))]),
  );
  const sourceFiles = [
    "history/schema.graphql",
    "history/chains.json",
    "history/evidence/" + c.id + ".json",
    "history/src/identity.ts",
    "history/src/lido.ts",
    "history/abis/LidoWithdrawalQueue.json",
    "src/history/types.ts",
    "src/history/cache.ts",
    "src/history/lido.ts",
    "src/history/export.ts",
    "src/history/transport.ts",
    "src/history/artifacts.ts",
    "src/history/cli.ts",
    "scripts/build-history-subgraph.mjs",
    "package-lock.json",
  ];
  const implementationHashes = Object.fromEntries(
    sourceFiles.map((p) => [p, hash(readFileSync(path.join(root, p)))]),
  );
  const identity = {
    schemaVersion: 1,
    hashEncoding: "SHA256_CANONICAL_JSON_SORTED_KEYS_V1",
    series: c,
    sourceMode: command === "export" ? "GRAPH_VERIFIED" : "CACHED_RESEARCH",
    contentHashes,
    implementationHashes,
    referenceHashes: ref.fileHashes,
    graphProof,
  };
  files["manifest.json"] = {
    ...identity,
    datasetId: hash(canonical(identity)),
    createdAt: new Date().toISOString(),
    runtime: process.version,
    executionEvidence: "ISSUER_EVENTS_ONLY",
    checkpointEvidence: "CACHED_CUTOFF_STORAGE_RECONCILED_TO_OBSERVED_CLAIMS",
    checkpointUse: "OUTCOME_LABELS_ONLY",
    totals: result.totals,
  };
  publishDataset(out, files);
  console.log(
    JSON.stringify(
      {
        out,
        datasetId: (files["manifest.json"] as Record<string, unknown>)
          .datasetId,
        sourceMode: identity.sourceMode,
        totals: result.totals,
      },
      null,
      2,
    ),
  );
}
main().catch((error) => {
  console.error(
    error instanceof Error && /^[A-Z0-9_]+$/.test(error.message)
      ? error.message
      : "HISTORY_COMMAND_FAILED",
  );
  process.exitCode = 1;
});
