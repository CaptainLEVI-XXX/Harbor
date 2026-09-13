import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { parseBenchmark, type Benchmark } from './schema';

function canonical(x: unknown): string {
  if (Array.isArray(x)) return '[' + x.map(canonical).join(',') + ']';
  if (x && typeof x === 'object') return '{' + Object.entries(x).sort(([a],[b]) => a < b ? -1 : a > b ? 1 : 0).map(([k,v]) => JSON.stringify(k) + ':' + canonical(v)).join(',') + '}';
  return JSON.stringify(x);
}

/** Only a server-configured artifact can override the bundled, reconciled dataset. */
export async function loadBenchmark(): Promise<Benchmark> {
  // Read exact exported JSON: compilation must not rewrite floating-point literals
  // before integrity verification. This path is included in both server traces.
  const override = process.env.HARBOR_ANALYTICS_FILE;
  // External artifacts are mounted by the host; only the bundled file is traced.
  const raw = override
    ? await readFile(/* turbopackIgnore: true */ override, 'utf8')
    : await readFile(path.join(process.cwd(), 'data/analytics/benchmark.json'), 'utf8');
  if (Buffer.byteLength(raw) > 1_000_000) throw new Error('Analytics artifact too large');
  const source: unknown = JSON.parse(raw);
  const data = parseBenchmark(source);
  const { benchmarkId, ...payload } = data;
  if (createHash('sha256').update(canonical(payload)).digest('hex') !== benchmarkId) throw new Error('Analytics checksum mismatch');
  return data;
}
