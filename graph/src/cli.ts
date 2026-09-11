import { candidates, gatewayEndpoint } from "./sources.js";
import { graphClient } from "./graph.js";
import { inspectSource, vaultAtFinalizedNumber } from "./standardized-vaults.js";
import { rpcClient } from "./rpc.js";
import { AnalyticsError, requireValue } from "./types.js";

async function main(): Promise<void> {
  const [command, ...ids] = process.argv.slice(2);
  const catalog = candidates();
  if (command === "list") { console.log(JSON.stringify(catalog, null, 2)); return; }
  if (command === "history") {
    requireValue(ids.length >= 3 && ids.length <= 4, "USAGE: history source-id vault-address start-block [end-block]");
    const source = catalog.find(s => s.id === ids[0]);
    requireValue(source, "UNKNOWN_SOURCE");
    const blocks = ids.slice(2).map(value => {
      requireValue(/^(0|[1-9][0-9]*)$/.test(value), "INVALID_BLOCK");
      return Number(value);
    });
    if (blocks.length === 2) requireValue(blocks[1]! > blocks[0]!, "INVALID_WINDOW");
    const request = graphClient(gatewayEndpoint(source), process.env.GRAPH_API_KEY);
    const rpc = rpcClient(process.env[`GRAPH_RPC_URL_${source.chainId}`]);
    const observations = [];
    for (const block of blocks) observations.push(await vaultAtFinalizedNumber(source, ids[1]!, block, request, rpc));
    // Source reports are not automatically converted into an investable return series.
    console.log(JSON.stringify({ admitted: false, observations }, null, 2));
    return;
  }
  requireValue(command === "inspect", "USAGE: list | inspect [source-id ...] | history source-id vault-address start-block [end-block]");
  requireValue(ids.length <= 8 && new Set(ids).size === ids.length, "INVALID_SOURCE_SELECTION");
  requireValue(ids.every(id => catalog.some(s => s.id === id)), "UNKNOWN_SOURCE");
  const selected = ids.length === 0 ? catalog : catalog.filter(source => ids.includes(source.id));
  const results = [];
  for (const source of selected) {
    try {
      const request = graphClient(gatewayEndpoint(source), process.env.GRAPH_API_KEY);
      results.push({ ok: true, observation: await inspectSource(source, request) });
    } catch (error) {
      results.push({ ok: false, sourceId: source.id, code: error instanceof AnalyticsError ? error.code : "INSPECTION_FAILED" });
    }
  }
  console.log(JSON.stringify({ admitted: false, results }, null, 2));
  if (results.some(result => !result.ok)) process.exitCode = 1;
}

main().catch(error => {
  console.error(error instanceof AnalyticsError ? error.code : "COMMAND_FAILED");
  process.exitCode = 1;
});
