import {
  readFileSync,
  writeFileSync,
  mkdirSync,
  cpSync,
  rmSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { validateConfig } from "../dist/src/history/types.js";
const root = fileURLToPath(new URL("../", import.meta.url));
const history = path.join(root, "history");
const configs = JSON.parse(
  readFileSync(path.join(history, "networks.json"), "utf8"),
);
const requested = process.argv[2];
const selected = requested
  ? configs.filter((c) => c.id === requested)
  : configs;
if (!selected.length) throw new Error("UNKNOWN_HISTORY_SERIES");
const hash = (x) => createHash("sha256").update(x).digest("hex");
const summaries = [];
for (const raw of selected) {
  const c = validateConfig(raw);
  const folder = path.join(history, ".build", c.id);
  if (c.environment !== "BUILD_FIXTURE") {
    const evidence = JSON.parse(
      readFileSync(path.join(history, "evidence", c.id + ".json"), "utf8"),
    );
    if (
      evidence.series !== c.id ||
      evidence.cutoffHash !== c.cutoffHash ||
      evidence.cutoffBlock !== c.endBlock ||
      evidence.abiSha256 !==
        hash(readFileSync(path.join(history, "abis/LidoWithdrawalQueue.json")))
    )
      throw Error("UNREVIEWED_HISTORY_ABI_OR_CUTOFF");
  }
  rmSync(folder, { recursive: true, force: true });
  mkdirSync(folder, { recursive: true });
  for (const name of ["schema.graphql", "src", "tests", "abis"])
    cpSync(path.join(history, name), path.join(folder, name), {
      recursive: true,
    });
  writeFileSync(
    path.join(folder, "tsconfig.json"),
    JSON.stringify({
      extends: path.join(
        root,
        "node_modules/@graphprotocol/graph-ts/types/tsconfig.base.json",
      ),
    }),
  );
  writeFileSync(
    path.join(folder, "matchstick.yaml"),
    `libsFolder: ${path.join(root, "node_modules")}\ntestsFolder: ./tests\nmanifestPath: ./subgraph.yaml\n`,
  );
  const context = Object.fromEntries(
    [
      ["chainId", "BigInt", c.chainId],
      ["issuer", "Bytes", c.issuer],
      ["adapterVersion", "String", c.adapterVersion],
      ["environment", "String", c.environment],
      ["sourceAsset", "String", c.sourceAsset],
      ["settlementAsset", "String", c.settlementAsset],
      ["decimals", "Int", c.decimals],
    ].map(([name, type, data]) => [name, { type, data }]),
  );
  const manifest = {
    specVersion: "1.3.0",
    description: `Issuer history: ${c.id} — ${c.environment}; no simulated trades`,
    schema: { file: "./schema.graphql" },
    indexerHints: { prune: "never" },
    dataSources: [
      {
        kind: "ethereum/contract",
        name: "Queue",
        network: c.network,
        context,
        source: {
          address: c.issuer,
          abi: "LidoWithdrawalQueue",
          startBlock: c.startBlock,
          endBlock: c.endBlock,
        },
        mapping: {
          kind: "ethereum/events",
          apiVersion: "0.0.9",
          language: "wasm/assemblyscript",
          entities: [
            "HistorySeries",
            "WithdrawalRequest",
            "FinalizationBatch",
            "WithdrawalClaim",
            "HistoryIssue",
          ],
          abis: [
            {
              name: "LidoWithdrawalQueue",
              file: "./abis/LidoWithdrawalQueue.json",
            },
          ],
          eventHandlers: [
            {
              event:
                "WithdrawalRequested(indexed uint256,indexed address,indexed address,uint256,uint256)",
              handler: "handleRequest",
            },
            {
              event:
                "WithdrawalsFinalized(indexed uint256,indexed uint256,uint256,uint256,uint256)",
              handler: "handleFinalization",
            },
            {
              event:
                "WithdrawalClaimed(indexed uint256,indexed address,indexed address,uint256)",
              handler: "handleClaim",
            },
          ],
          file: "./src/lido.ts",
        },
      },
    ],
  };
  writeFileSync(
    path.join(folder, "subgraph.yaml"),
    JSON.stringify(manifest, null, 2) + "\n",
  );
  for (const command of ["codegen", "build"]) {
    const p = spawnSync(path.join(root, "node_modules/.bin/graph"), [command], {
      cwd: folder,
      stdio: "inherit",
    });
    if (p.error) throw p.error;
    if (p.status !== 0) process.exit(p.status ?? 1);
  }
  summaries.push({
    series: c.id,
    network: c.network,
    environment: c.environment,
    schemaHash: hash(readFileSync(path.join(history, "schema.graphql"))),
    mappingHash: hash(
      ["identity.ts", "lido.ts"]
        .map(
          (n) => n + "\0" + readFileSync(path.join(history, "src", n), "utf8"),
        )
        .join("\0"),
    ),
    built: true,
    deployed: false,
  });
}
writeFileSync(
  path.join(history, ".build", "build-matrix.json"),
  JSON.stringify(summaries, null, 2) + "\n",
);
console.log(JSON.stringify(summaries, null, 2));
