import {
  readFileSync,
  writeFileSync,
  mkdirSync,
  copyFileSync,
  existsSync,
} from "node:fs";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { validateConfig, order } from "../dist/src/history/types.js";
import { readReference } from "../dist/src/history/cache.js";
const root = fileURLToPath(new URL("../", import.meta.url));
const args = process.argv.slice(2);
if (args.length !== 2 || args[0] !== "--reference")
  throw Error("USAGE_history_replay_--reference_PATH");
const c = validateConfig(
  JSON.parse(
    readFileSync(path.join(root, "history/networks.json"), "utf8"),
  ).find((c) => c.id === "ethereum-lido-2025-03"),
);
const folder = path.join(root, "history/.build", c.id);
if (!existsSync(path.join(folder, "generated/schema.ts")))
  throw Error("RUN_HISTORY_BUILD_FIRST");
const ref = readReference(path.resolve(args[1]), c);
const records = [
  ...ref.facts.requests.map((r) => ({ ...r, kind: "request" })),
  ...ref.facts.batches.map((r) => ({ ...r, kind: "batch" })),
  ...ref.facts.claims.map((r) => ({ ...r, kind: "claim" })),
].sort(order);
const fixtures = path.join(folder, "tests/fixtures");
mkdirSync(fixtures, { recursive: true });
copyFileSync(
  path.join(root, "history/replay/full-history.test.ts.template"),
  path.join(folder, "tests/full-history.test.ts"),
);
const state = {
  requestCount: "0",
  batchCount: "0",
  claimCount: "0",
  lastRequest: "0",
  lastFinalized: "0",
  cumulativeFace: "0",
  cumulativeShares: "0",
  locked: "0",
  paid: "0",
};
const requests = new Map();
let windows = 0;
for (let offset = 0; offset < records.length; offset += 2500) {
  const rows = records.slice(offset, offset + 2500),
    before = { ...state },
    parents = new Map();
  for (const row of rows) {
    const needed =
      row.kind === "batch"
        ? [row.lastRequest, String(BigInt(row.firstRequest) - 1n)]
        : row.kind === "claim"
          ? [row.requestId]
          : [];
    for (const id of needed)
      if (requests.has(id)) parents.set(id, requests.get(id));
  }
  for (const row of rows) {
    if (row.kind === "request") {
      state.requestCount = String(BigInt(state.requestCount) + 1n);
      state.lastRequest = row.requestId;
      state.cumulativeFace = row.prefixFace;
      state.cumulativeShares = row.prefixShares;
      requests.set(row.requestId, row);
    } else if (row.kind === "batch") {
      state.batchCount = row.sequence;
      state.lastFinalized = row.lastRequest;
      state.locked = String(BigInt(state.locked) + BigInt(row.locked));
    } else {
      state.claimCount = String(BigInt(state.claimCount) + 1n);
      state.paid = String(BigInt(state.paid) + BigInt(row.amount));
    }
  }
  writeFileSync(
    path.join(fixtures, "current.json"),
    JSON.stringify({
      config: c,
      before,
      parents: [...parents.values()],
      rows,
      after: state,
    }),
  );
  const p = spawnSync(
    path.join(root, "node_modules/.bin/graph"),
    [
      "test",
      "full-history",
      "--version",
      "0.6.0",
      ...(windows === 0 ? ["--recompile"] : []),
    ],
    { cwd: folder, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 },
  );
  if (p.error) throw p.error;
  if (p.status !== 0) {
    process.stdout.write(p.stdout ?? "");
    process.stderr.write(p.stderr ?? "");
    process.exit(p.status ?? 1);
  }
  windows++;
  console.log(
    `Verified historical window ${windows}: ${Math.min(offset + rows.length, records.length)}/${records.length} events`,
  );
}
writeFileSync(
  path.join(folder, "full-history-replay.json"),
  JSON.stringify(
    {
      passed: true,
      mode: "BOUNDED_WINDOWS_WITH_RECONCILED_BOOTSTRAP",
      windows,
      events: records.length,
      totals: ref.totals,
      graphNodeReplay: false,
    },
    null,
    2,
  ) + "\n",
);
