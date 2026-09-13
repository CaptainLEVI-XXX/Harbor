export const MODEL_LABELS = {
  harbor: 'Harbor', fixed_delay: 'Fixed-delay pricing', age_based: 'Age-based pricing', queue_aware: 'Queue-aware valuation',
} as const;
export type ModelKey = keyof typeof MODEL_LABELS;
export type Point = [number, number];
export type Histogram = { edges: number[]; counts: Partial<Record<ModelKey, number[]>>; n: Partial<Record<ModelKey, number>>; width: number; metrics: Partial<Record<ModelKey, { mae?: number; negativeFraction?: number }>> };
export type Summary = { profit: number; profitWei: string; seller: number; sellerWei: string; feeWei: string; surplus: number; negativeFraction: number; fills: number };
export type Benchmark = {
  version: 1; benchmarkId: string;
  meta: { chain: string; chainId: string; issuer: string; start: number; end: number; sourceMode: 'CACHED_RESEARCH' | 'GRAPH_VERIFIED'; calculationMode: 'ARCHIVED_REFERENCE'; execution: 'SIMULATED'; historyDatasetId: string; historyReconciled: true; cutoffBlock: number; cutoffHash: string; graphDeployment: string | null; oneDayOpportunities: number; matchedFills: number; scheduledOffers: number; indexedRequests: number; indexedClaims: number; assumptions: { capital_weth: number; funding_rate: number; margin_bps: number; cost_weth: number; customer_gas_weth: number; external_fee_bps: number; recovery_operation_lag_hours: number }; fixedDelayDays: number };
  models: { key: ModelKey; label: string; description: string }[];
  accuracy: Histogram; surplus: Histogram;
  profit: { series: Record<ModelKey, Point[]>; hurdle: Point[] };
  tradeoff: { key: ModelKey; seller: number; lp: number; fee: number; residualWei: string; commonFills: number; exclusiveFills: number }[];
  summary: Record<ModelKey, Summary>;
};

const ensure: (ok: unknown) => asserts ok = (ok) => { if (!ok) throw new Error('Invalid analytics dataset'); };
const object = (x: unknown): Record<string, unknown> => { ensure(x && typeof x === 'object' && !Array.isArray(x)); return x as Record<string, unknown>; };
const finite = (x: unknown): x is number => typeof x === 'number' && Number.isFinite(x);
const count = (x: unknown): x is number => finite(x) && Number.isSafeInteger(x) && x >= 0;
const uint = (x: unknown): x is string => typeof x === 'string' && /^(0|[1-9][0-9]*)$/.test(x);
const string = (x: unknown): x is string => typeof x === 'string' && x.length > 0 && x.length < 300;
const digest = (x: unknown): boolean => typeof x === 'string' && /^[a-f0-9]{64}$/.test(x);
const keys = Object.keys(MODEL_LABELS) as ModelKey[];

/** Reject partial/corrupt artifacts; unavailable data must never become a zero chart. */
export function parseBenchmark(input: unknown): Benchmark {
  const d = object(input), meta = object(d.meta);
  ensure(d.version === 1 && digest(d.benchmarkId) && digest(meta.historyDatasetId));
  ensure(meta.execution === 'SIMULATED' && meta.calculationMode === 'ARCHIVED_REFERENCE' && meta.historyReconciled === true);
  ensure(['CACHED_RESEARCH', 'GRAPH_VERIFIED'].includes(String(meta.sourceMode)));
  ensure(uint(meta.chainId) && string(meta.chain) && string(meta.issuer) && finite(meta.start) && finite(meta.end) && meta.end > meta.start);
  ensure(count(meta.cutoffBlock) && typeof meta.cutoffHash === 'string' && /^0x[a-f0-9]{64}$/.test(meta.cutoffHash));
  ensure(meta.sourceMode === 'GRAPH_VERIFIED' ? string(meta.graphDeployment) : meta.graphDeployment === null);
  for (const k of ['oneDayOpportunities','matchedFills','scheduledOffers','indexedRequests','indexedClaims']) ensure(count(meta[k]) && Number(meta[k]) > 0);
  ensure(finite(meta.fixedDelayDays));
  const assumptions = object(meta.assumptions);
  for (const k of ['capital_weth','funding_rate','margin_bps','cost_weth','customer_gas_weth','external_fee_bps','recovery_operation_lag_hours']) ensure(finite(assumptions[k]) && Number(assumptions[k]) >= 0);
  ensure(Array.isArray(d.models) && d.models.length === keys.length);
  d.models.forEach((m, i) => { const x = object(m); ensure(x.key === keys[i] && x.label === MODEL_LABELS[keys[i]] && string(x.description)); });
  const summary = object(d.summary), profit = object(d.profit), series = object(profit.series);
  const points = (v: unknown) => {
    ensure(Array.isArray(v) && v.length >= 2 && v.length <= 5000);
    let previous = -Infinity;
    for (const p of v) { ensure(Array.isArray(p) && p.length === 2 && finite(p[0]) && finite(p[1]) && p[0] > previous); previous = p[0]; }
    ensure(v[0][0] === meta.start && v.at(-1)[0] === meta.end);
  };
  points(profit.hurdle);
  for (const key of keys) {
    const s = object(summary[key]);
    for (const k of ['profit','seller','surplus','negativeFraction']) ensure(finite(s[k]));
    for (const k of ['profitWei','sellerWei','feeWei']) ensure(typeof s[k] === 'string' && /^-?(0|[1-9][0-9]*)$/.test(s[k] as string));
    ensure(s.fills === meta.matchedFills && Number(s.negativeFraction) >= 0 && Number(s.negativeFraction) <= 1);
    points(series[key]);
    ensure(Math.abs((series[key] as Point[]).at(-1)![1] - Number(s.profit)) < 1e-8);
  }
  for (const kind of ['accuracy','surplus']) {
    const h = object(d[kind]), values = object(h.counts), totals = object(h.n), metrics = object(h.metrics);
    ensure(Array.isArray(h.edges) && h.edges.length > 1 && h.edges.length <= 5000 && finite(h.width) && h.width > 0);
    const edges = h.edges as unknown[];
    edges.forEach((x,i) => ensure(finite(x) && (i === 0 || x > Number(edges[i-1]))));
    const expected = kind === 'accuracy' ? keys.filter(k => k !== 'harbor') : keys;
    ensure(Object.keys(values).length === expected.length);
    for (const key of expected) {
      const bins = values[key]; ensure(Array.isArray(bins) && bins.length === edges.length-1 && bins.every(count));
      ensure(totals[key] === (kind === 'accuracy' ? meta.oneDayOpportunities : meta.matchedFills) && bins.reduce((a,b) => a+b,0) === totals[key]);
      const metric = object(metrics[key]); ensure(finite(metric[kind === 'accuracy' ? 'mae' : 'negativeFraction']));
    }
  }
  ensure(Array.isArray(d.tradeoff) && d.tradeoff.length === 4 && new Set(d.tradeoff.map(x => object(x).key)).size === 4);
  for (const p of d.tradeoff) {
    const x = object(p); ensure(keys.includes(x.key as ModelKey) && ['seller','lp','fee'].every(k => finite(x[k])) && x.residualWei === '0' && x.commonFills === meta.matchedFills && x.exclusiveFills === 0);
    const s = object(summary[x.key as ModelKey]), base = object(summary.queue_aware);
    ensure(BigInt(String(s.profitWei))-BigInt(String(base.profitWei))+BigInt(String(s.sellerWei))-BigInt(String(base.sellerWei))+BigInt(String(s.feeWei))-BigInt(String(base.feeWei)) === 0n);
  }
  return input as Benchmark;
}
