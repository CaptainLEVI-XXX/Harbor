import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import path from "node:path";
const root = fileURLToPath(new URL("../", import.meta.url));
const configs = JSON.parse(
  readFileSync(path.join(root, "history/networks.json"), "utf8"),
);
for (const c of configs) {
  const result = spawnSync(
    path.join(root, "node_modules/.bin/graph"),
    ["test", "history", "--version", "0.6.0", "--recompile"],
    { cwd: path.join(root, "history/.build", c.id), stdio: "inherit" },
  );
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
