import {
  readFileSync,
  writeFileSync,
  mkdirSync,
  renameSync,
  existsSync,
} from "node:fs";
import path from "node:path";
import { hash, requireValue } from "./types.js";
import { objectNever } from "./validation.js";
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
  if (value !== null && typeof value === "object")
    return (
      "{" +
      Object.entries(value)
        .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
        .map(([k, v]) => JSON.stringify(k) + ":" + canonical(v))
        .join(",") +
      "}"
    );
  return JSON.stringify(value);
}
export interface PageCache {
  read(name: string, identity: string): unknown[] | null;
  write(name: string, identity: string, rows: unknown[]): void;
}
export function pageCache(folder: string): PageCache {
  const file = (name: string) => {
    requireValue(/^[a-z]+$/.test(name), "INVALID_CHECKPOINT_NAME");
    return path.join(folder, name + ".json");
  };
  return {
    read(name, identity) {
      const f = file(name);
      if (!existsSync(f)) return null;
      const p = objectNever(JSON.parse(readFileSync(f, "utf8")));
      if (p.identity !== identity) return null;
      requireValue(
        Array.isArray(p.rows) && p.digest === hash(canonical(p.rows)),
        "CORRUPT_CHECKPOINT",
      );
      return p.rows;
    },
    write(name, identity, rows) {
      mkdirSync(folder, { recursive: true });
      const f = file(name);
      writeFileSync(
        f + ".tmp",
        JSON.stringify({ identity, rows, digest: hash(canonical(rows)) }),
      );
      renameSync(f + ".tmp", f);
    },
  };
}
export function publishDataset(
  folder: string,
  files: Record<string, unknown>,
): void {
  requireValue(!existsSync(folder), "OUTPUT_ALREADY_EXISTS");
  mkdirSync(path.dirname(folder), { recursive: true });
  const staging = folder + ".partial-" + process.pid;
  requireValue(!existsSync(staging), "STAGING_ALREADY_EXISTS");
  mkdirSync(staging);
  for (const [name, value] of Object.entries(files)) {
    requireValue(/^[a-z-]+\.json$/.test(name), "INVALID_ARTIFACT_NAME");
    writeFileSync(path.join(staging, name), JSON.stringify(value) + "\n");
  }
  renameSync(staging, folder);
}
