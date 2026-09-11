import { readFileSync, writeFileSync, mkdirSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const directory = path.join(root, "subgraph");
const repo = path.dirname(root);
const hash = value => createHash("sha256").update(value).digest("hex");
const selected = process.argv[2] ? [process.argv[2]] : ["mainnet", "arbitrum-one"];
if (selected.some(network => !["mainnet", "arbitrum-one"].includes(network))) throw new Error("Unsupported build fixture");

// Compile fixtures only. These addresses are deliberately synthetic and cannot authorize deployment.
// Public network/deployment configuration remains empty until actual contracts are reviewed.
const events = {
  Vault: { LiquidityIssued: "handleLiquidityIssued", Transfer: "handleTransfer", WithdrawalQueued: "handleWithdrawalQueued",
    WithdrawalFunded: "handleWithdrawalFunded", Withdraw: "handleWithdraw", ValuationCommitted: "handleValuationCommitted" },
  Book: { FillSettled: "handleFillSettled", RedemptionRequested: "handleRedemptionRequested",
    RedemptionRecovered: "handleRedemptionRecovered", ReceiptAcquired: "handleReceiptAcquired",
    ReceiptDisposed: "handleReceiptDisposed", NativeClaimExported: "handleNativeClaimExported",
    PositionRealized: "handlePositionRealized", IssuerRouteConfigured: "handleIssuerRouteConfigured",
    ClaimIntegrationScheduled: "handleIntegrationScheduled", IntegrationActivated: "handleIntegrationActivated",
    IntegrationRetired: "handleIntegrationRetired", ClaimMarketRegistered: "handleClaimMarketRegistered" },
  Factory: { ClaimWrapped: "handleClaimWrapped" },
  Adapter: { ClaimCashCollected: "handleClaimCashCollected" },
  ReceiptToken: { Transfer: "handleReceiptTransfer", Activated: "handleReceiptActivated", Redeemed: "handleReceiptRedeemed" },
};
const artifacts = { Vault: ["HarborVault"], Book: ["HarborBook", "ClaimMarkets", "BookAccounting"],
  Factory: ["HarborClaimFactory"], Adapter: ["LidoAdapter"], ReceiptToken: ["HarborClaimReceipt"] };
const abis = {};
mkdirSync(path.join(directory, "abis"), { recursive: true });
for (const [name, contracts] of Object.entries(artifacts)) {
  const entries = contracts.flatMap(contract => JSON.parse(readFileSync(path.join(repo, "out", `${contract}.sol`, `${contract}.json`), "utf8")).abi);
  const abi = [];
  for (const event of Object.keys(events[name])) {
    const match = entries.find(entry => entry.type === "event" && entry.name === event);
    if (!match) throw new Error(`Missing current artifact event: ${name}.${event}; run forge build`);
    abi.push(match);
  }
  abis[name] = abi;
  writeFileSync(path.join(directory, "abis", `${name}.json`), JSON.stringify(abi, null, 2) + "\n");
}

const schemaHash = hash(readFileSync(path.join(directory, "schema.graphql")));
const mappingFiles = readdirSync(path.join(directory, "src")).filter(file => file.endsWith(".ts")).sort();
const mappingHash = hash(Buffer.concat(mappingFiles.flatMap(file => [Buffer.from(file + "\0"), readFileSync(path.join(directory, "src", file))])));
const summaries = [];
for (const network of selected) {
  const chainId = network === "mainnet" ? 1 : 42161;
  const address = suffix => "0x" + suffix.padStart(40, "0");
  const context = {
    chainId: { type: "BigInt", data: String(chainId) }, book: { type: "Bytes", data: address("101") },
    vault: { type: "Bytes", data: address("102") }, asset: { type: "Bytes", data: address("103") },
    executor: { type: "Bytes", data: address("104") },
    cashDecimals: { type: "Int", data: network === "mainnet" ? 18 : 6 }, environment: { type: "String", data: "BUILD_FIXTURE" },
  };
  const addresses = { Vault: address("102"), Book: address("101"), Factory: address("105"), Adapter: address("106") };
  const mapping = (name, handlers) => ({ kind: "ethereum/events", apiVersion: "0.0.9", language: "wasm/assemblyscript",
    entities: [...readFileSync(path.join(directory, "schema.graphql"), "utf8").matchAll(/^type (\w+) @entity/gm)].map(match => match[1]),
    abis: [{ name, file: `./abis/${name}.json` }],
    eventHandlers: abis[name].map(event => ({
      event: `${event.name}(${event.inputs.map(input => (input.indexed ? "indexed " : "") + input.type).join(",")})`,
      handler: handlers[event.name],
      ...(["FillSettled", "ClaimWrapped"].includes(event.name) ? { receipt: true } : {}),
    })), file: name === "Vault" ? "./src/vault.ts" : name === "Book" ? "./src/book.ts" : "./src/receipts.ts",
  });
  const dataSources = Object.entries(events).filter(([name]) => name !== "ReceiptToken").map(([name, handlers]) => ({
    kind: "ethereum/contract", name, network, context,
    source: { address: addresses[name], abi: name, startBlock: 0 }, mapping: mapping(name, handlers),
  }));
  // JSON is valid YAML; avoid a new templating dependency for static manifest generation.
  const templates = [{ kind: "ethereum/contract", name: "ReceiptToken", network, source: { abi: "ReceiptToken" }, mapping: mapping("ReceiptToken", events.ReceiptToken) }];
  const manifest = { specVersion: "1.3.0", description: "BUILD FIXTURE ONLY — not a deployed Harbor network", schema: { file: "./schema.graphql" }, indexerHints: { prune: "never" }, dataSources, templates };
  writeFileSync(path.join(directory, "subgraph.yaml"), JSON.stringify(manifest, null, 2) + "\n");
  for (const command of ["codegen", "build"]) {
    const result = spawnSync(path.join(root, "node_modules/.bin/graph"), [command], { cwd: directory, stdio: "inherit" });
    if (result.error) throw result.error;
    if (result.status !== 0) process.exit(result.status ?? 1);
  }
  summaries.push({ network, chainId, environment: "BUILD_FIXTURE", schemaHash, mappingHash, built: true, deployed: false });
}
console.log(JSON.stringify(summaries, null, 2));
