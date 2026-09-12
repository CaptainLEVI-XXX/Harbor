import { readFileSync, writeFileSync, mkdirSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const directory = path.join(root, "subgraph");
const repo = path.dirname(root);
const hash = value => createHash("sha256").update(value).digest("hex");
const deployment = process.argv[2] === "--deployment" ? process.argv[3] : null;
if (process.argv[2] === "--deployment" && !deployment) throw new Error("Deployment network required");
const selected = deployment ? [deployment] : process.argv[2] ? [process.argv[2]] : ["mainnet", "arbitrum-one"];
if (!deployment && selected.some(network => !["mainnet", "arbitrum-one"].includes(network))) throw new Error("Unsupported build fixture");
const networks = JSON.parse(readFileSync(path.join(directory, "networks.json"), "utf8"));
const live = deployment ? networks[deployment] : null;
if (deployment) {
  if (!live || live.environment !== "TESTNET" || live.chainId !== 560048 || deployment !== "hoodi") {
    throw new Error("Unreviewed deployment network");
  }
  const record = JSON.parse(readFileSync(path.join(repo, "script/records/harbor-nft-hoodi.deployment.json"), "utf8"));
  if (record.chainId !== live.chainId) throw new Error("Deployment chain mismatch");
  for (const [name, contract] of Object.entries({ Vault: "HarborVault", Book: "HarborBook", Factory: "HarborClaimFactory", Adapter: "LidoAdapter", Executor: "HarborExecutor" })) {
    const source = live.contracts[name];
    const tx = record.transactions.find(tx => tx.type === "CREATE" && tx.name === contract);
    if (!source || !tx || source.address.toLowerCase() !== tx.address.toLowerCase() || source.startBlock !== tx.block) {
      throw new Error(`Deployment address/start block mismatch: ${name}`);
    }
  }
  const config = JSON.parse(readFileSync(path.join(repo, "script/config/hoodi.config.json"), "utf8"));
  if (live.asset.toLowerCase() !== config.routerConstructor.wrappedNative.toLowerCase() || live.cashDecimals !== 18) {
    throw new Error("Settlement asset mismatch");
  }
  const addressPattern = /^0x[0-9a-fA-F]{40}$/;
  if (live.periphery && !addressPattern.test(live.periphery)) throw new Error("Invalid reviewed Periphery address");
  const labels = live.strategyMetadata ?? [], routes = new Set();
  if (!Array.isArray(labels)) throw new Error("Strategy metadata must be an array");
  for (const row of labels) {
    if (!/^(0|[1-9][0-9]*)$/.test(row.route) || routes.has(row.route)
      || !addressPattern.test(row.base) || !addressPattern.test(row.adapter)
      || typeof row.issuer !== "string" || !row.issuer.trim()
      || typeof row.tokenSymbol !== "string" || !row.tokenSymbol.trim()) {
      throw new Error("Malformed or duplicate strategy metadata");
    }
    routes.add(row.route);
  }
}

// Default builds remain synthetic. --deployment selects reviewed onchain addresses,
// not provider deployment authority: compiling never publishes a subgraph.
const events = {
  Vault: { LiquidityIssued: "handleLiquidityIssued", Transfer: "handleTransfer", WithdrawalQueued: "handleWithdrawalQueued",
    WithdrawalFunded: "handleWithdrawalFunded", Withdraw: "handleWithdraw", ValuationCommitted: "handleValuationCommitted" },
  Book: { FillSettled: "handleFillSettled", RedemptionRequested: "handleRedemptionRequested",
    NftPolicyConfigured: "handleNftPolicyConfigured", NftPricingPublished: "handleNftPricingPublished", NftTraded: "handleNftTraded",
    RedemptionRecovered: "handleRedemptionRecovered", ReceiptAcquired: "handleReceiptAcquired",
    ReceiptDisposed: "handleReceiptDisposed", NativeClaimExported: "handleNativeClaimExported",
    PositionRealized: "handlePositionRealized", IssuerRouteConfigured: "handleIssuerRouteConfigured",
    ClaimIntegrationScheduled: "handleIntegrationScheduled", IntegrationActivated: "handleIntegrationActivated",
    IntegrationRetired: "handleIntegrationRetired", ClaimMarketRegistered: "handleClaimMarketRegistered" },
  Factory: { ClaimWrapped: "handleClaimWrapped" },
  Adapter: { ClaimCashCollected: "handleClaimCashCollected" },
  ReceiptToken: { Transfer: "handleReceiptTransfer", Activated: "handleReceiptActivated", Redeemed: "handleReceiptRedeemed" },
};
const artifacts = { Vault: ["HarborVault"], Book: ["HarborBook", "ClaimMarkets", "BookAccounting", "NftMarket"],
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
  if (name === "Adapter") {
    const issuer = entries.find(entry => entry.type === "function" && entry.name === "ISSUER");
    if (!issuer) throw new Error("Missing Adapter.ISSUER artifact; run forge build");
    abi.push(issuer);
  }
  writeFileSync(path.join(directory, "abis", `${name}.json`), JSON.stringify(abi, null, 2) + "\n");
}

const schemaHash = hash(readFileSync(path.join(directory, "schema.graphql")));
const mappingFiles = readdirSync(path.join(directory, "src")).filter(file => file.endsWith(".ts")).sort();
const mappingHash = hash(Buffer.concat(mappingFiles.flatMap(file => [Buffer.from(file + "\0"), readFileSync(path.join(directory, "src", file))])));
const summaries = [];
for (const network of selected) {
  const chainId = live ? live.chainId : network === "mainnet" ? 1 : 42161;
  const address = suffix => "0x" + suffix.padStart(40, "0");
  const context = {
    chainId: { type: "BigInt", data: String(chainId) }, book: { type: "Bytes", data: live ? live.contracts.Book.address : address("101") },
    vault: { type: "Bytes", data: live ? live.contracts.Vault.address : address("102") }, asset: { type: "Bytes", data: live ? live.asset : address("103") },
    executor: { type: "Bytes", data: live ? live.contracts.Executor.address : address("104") },
    strategyMetadata: { type: "String", data: JSON.stringify(live?.strategyMetadata ?? []) },
    ...(live?.periphery ? { periphery: { type: "Bytes", data: live.periphery } } : {}),
    cashDecimals: { type: "Int", data: live ? live.cashDecimals : network === "mainnet" ? 18 : 6 }, environment: { type: "String", data: live ? live.environment : "BUILD_FIXTURE" },
  };
  const addresses = { Vault: address("102"), Book: address("101"), Factory: address("105"), Adapter: address("106") };
  const mapping = (name, handlers) => ({ kind: "ethereum/events", apiVersion: "0.0.9", language: "wasm/assemblyscript",
    entities: [...readFileSync(path.join(directory, "schema.graphql"), "utf8").matchAll(/^type (\w+) @entity/gm)].map(match => match[1]),
    abis: [{ name, file: `./abis/${name}.json` }, ...(name === "Book" ? [{ name: "Adapter", file: "./abis/Adapter.json" }] : [])],
    eventHandlers: abis[name].filter(entry => entry.type === "event").map(event => ({
      event: `${event.name}(${event.inputs.map(input => (input.indexed ? "indexed " : "") + abiType(input)).join(",")})`,
      handler: handlers[event.name],
      ...(["FillSettled", "ClaimWrapped", "NftTraded"].includes(event.name) ? { receipt: true } : {}),
    })), file: name === "Vault" ? "./src/vault.ts" : name === "Book" ? "./src/book.ts" : "./src/receipts.ts",
  });
  const dataSources = Object.entries(events).filter(([name]) => name !== "ReceiptToken").map(([name, handlers]) => ({
    kind: "ethereum/contract", name, network, context,
    source: { address: live ? live.contracts[name].address : addresses[name], abi: name, startBlock: live ? live.contracts[name].startBlock : 0 }, mapping: mapping(name, handlers),
  }));
  // JSON is valid YAML; avoid a new templating dependency for static manifest generation.
  const templates = [{ kind: "ethereum/contract", name: "ReceiptToken", network, source: { abi: "ReceiptToken" }, mapping: mapping("ReceiptToken", events.ReceiptToken) }];
  const manifest = { specVersion: "1.3.0", description: live ? "Harbor on Hoodi — testnet activity, not mainnet returns" : "BUILD FIXTURE ONLY — not a deployed Harbor network", schema: { file: "./schema.graphql" }, indexerHints: { prune: "never" }, dataSources, templates };
  writeFileSync(path.join(directory, "subgraph.yaml"), JSON.stringify(manifest, null, 2) + "\n");
  for (const command of ["codegen", "build"]) {
    const result = spawnSync(path.join(root, "node_modules/.bin/graph"), [command], { cwd: directory, stdio: "inherit" });
    if (result.error) throw result.error;
    if (result.status !== 0) process.exit(result.status ?? 1);
  }
  summaries.push({ network, chainId, environment: live ? live.environment : "BUILD_FIXTURE", schemaHash, mappingHash, built: true, deployed: false });
}
console.log(JSON.stringify(summaries, null, 2));

function abiType(input) {
  return input.type.startsWith("tuple")
    ? `(${input.components.map(abiType).join(",")})${input.type.slice(5)}` : input.type;
}
