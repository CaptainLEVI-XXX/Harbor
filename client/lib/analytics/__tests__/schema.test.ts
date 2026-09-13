import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe,it,expect,afterEach,vi } from 'vitest';
import dataset from '@/data/analytics/benchmark.json';
import { MODEL_LABELS, parseBenchmark } from '../schema';
import { loadBenchmark } from '../server';
import { GET } from '@/app/api/analytics/route';
const copy = () => JSON.parse(JSON.stringify(dataset));
afterEach(() => vi.unstubAllEnvs());
describe('historical analytics admission', () => {
  it('keeps exactly one Harbor and all four agreed names', async () => {
    const d = await loadBenchmark();
    expect(d.models.map(m => m.label)).toEqual(Object.values(MODEL_LABELS));
    expect(d.models.filter(m => m.label.includes('Harbor'))).toHaveLength(1);
    expect(d.meta.sourceMode).toBe('CACHED_RESEARCH');
    expect(d.summary.harbor.profit).toBeCloseTo(316.6089088878236,9);
  });
  it.each(['missing-bin','wrong-endpoint','wrong-cohort','graph-without-proof','nonfinite','renamed-model','wrong-wei'])('rejects %s', kind => {
    const d=copy();
    if(kind==='missing-bin') d.surplus.counts.harbor.pop();
    if(kind==='wrong-endpoint') d.profit.series.harbor.at(-1)[1]+=1;
    if(kind==='wrong-cohort') d.accuracy.n.queue_aware--;
    if(kind==='graph-without-proof') d.meta.sourceMode='GRAPH_VERIFIED';
    if(kind==='nonfinite') d.summary.harbor.profit=Infinity;
    if(kind==='renamed-model') d.models[0].label='Harbor + FACE';
    if(kind==='wrong-wei') d.summary.harbor.profitWei='1';
    expect(()=>parseBenchmark(d)).toThrow('Invalid analytics dataset');
  });
  it('serves the data without wallet identity or private source paths', async () => {
    const response=await GET(); expect(response.status).toBe(200);
    const text=await response.text(); expect(text).not.toContain('/Users/'); expect(text).not.toContain('api.studio');
    expect(JSON.parse(text).benchmarkId).toBe(dataset.benchmarkId);
  });
  it('rejects a schema-valid artifact whose content no longer matches its identity', async () => {
    const directory = await mkdtemp(path.join(tmpdir(), 'harbor-analytics-'));
    try {
      const changed = copy(); changed.meta.contractParity = 'OUT_OF_SCOPE';
      changed.benchmarkId = '0'.repeat(64);
      const filename = path.join(directory, 'benchmark.json');
      await writeFile(filename, JSON.stringify(changed));
      vi.stubEnv('HARBOR_ANALYTICS_FILE', filename);
      await expect(loadBenchmark()).rejects.toThrow('Analytics checksum mismatch');
    } finally { await rm(directory, { recursive: true, force: true }); }
  });
  it('fails closed when the configured artifact is missing', async () => {
    vi.stubEnv('HARBOR_ANALYTICS_FILE','/nonexistent/harbor-analytics.json');
    const response=await GET(); expect(response.status).toBe(503); expect(await response.text()).not.toContain('/nonexistent');
  });
});
