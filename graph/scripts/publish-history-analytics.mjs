/** Turn a reconciled issuer export + frozen simulation into the website dataset. */
import { readFileSync, writeFileSync, mkdirSync, renameSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import path from 'node:path';
import { canonical } from '../dist/src/history/artifacts.js';
import { hash } from '../dist/src/history/types.js';
import { csv } from '../dist/src/history/cache.js';
import { reconcileFacts } from '../dist/src/history/lido.js';

const check = (ok, message) => { if (!ok) throw Error(message); };
const load = p => JSON.parse(readFileSync(p, 'utf8'));
const [dataset, research, destination] = process.argv.slice(2);
check(dataset && research && destination && process.argv.length === 5, 'Usage: publish-history-analytics.mjs DATASET_DIR BENCHMARK_PREVIEW_DIR OUTPUT_JSON');
const manifest = load(path.join(dataset, 'manifest.json'));
const { datasetId, createdAt, runtime, executionEvidence, checkpointEvidence, checkpointUse, totals, ...identity } = manifest;
check(datasetId === hash(canonical(identity)), 'History identity mismatch');
check(['CACHED_RESEARCH', 'GRAPH_VERIFIED'].includes(manifest.sourceMode), 'Unsupported history evidence');
check(manifest.series.environment !== 'BUILD_FIXTURE', 'Fixture cannot feed public analytics');
const files = {};
for (const name of ['facts.json', 'outcomes.json', 'checkpoints.json', 'reconciliation.json']) {
  files[name] = load(path.join(dataset, name));
  check(hash(canonical(files[name])) === manifest.contentHashes[name], 'History content mismatch: ' + name);
}
check(files['reconciliation.json'].passed === true, 'History not reconciled');
const normalized = reconcileFacts(files['facts.json'], manifest.series, files['checkpoints.json']);
check(canonical(normalized.outcomes) === canonical(files['outcomes.json']) && canonical(normalized.totals) === canonical(totals), 'History normalization mismatch');
if (manifest.sourceMode === 'GRAPH_VERIFIED') {
  const proof = manifest.graphProof;
  check(files['reconciliation.json'].graphComparison && proof?.deployment === manifest.series.expectedDeployment && proof?.state?.complete === true, 'Graph proof missing');
  check(proof.cutoff?.hash === manifest.series.cutoffHash && proof.cutoff?.number === manifest.series.endBlock && proof.cutoff?.chainId === manifest.series.chainId && proof.cutoff.finalizedNumber >= manifest.series.endBlock, 'Graph cutoff mismatch');
}
const source = load(path.join(research, 'chart-data.json'));
const provenance = load(path.join(research, 'provenance.json'));
check(source.meta.chartDataId === provenance.chartDataId && source.meta.execution === 'SIMULATED', 'Wrong simulation provenance');
// Verify exact source bytes rather than reserializing Python floats in JavaScript.
const raw = readFileSync(path.join(research, 'chart-data.json'), 'utf8').trim();
const untagged = raw.replace(',"chartDataId":"' + provenance.chartDataId + '"', '');
check(hash(untagged) === provenance.chartDataId, 'Chart source hash mismatch');
for (const [filename, digest] of Object.entries(provenance.inputSha256)) check(hash(readFileSync(filename)) === digest, 'Research input changed');
check(hash(readFileSync(path.join(research, 'build_chart_data.py'))) === provenance.generatorSha256, 'Research generator changed');
const reference = Object.entries(provenance.inputSha256).find(([name]) => name.endsWith('/work/decoded/requests.csv'));
check(reference && reference[1] === manifest.referenceHashes['work/decoded/requests.csv'], 'Research and history references differ');
check(source.meta.end === Number(manifest.series.cutoffTimestamp) && manifest.series.chainId === '1' && manifest.series.issuer === '0x889edc2edab5f40e902b864ad4d7ade8e412f9b1', 'Frozen study requires its Ethereum Lido series');
const requests = new Map(normalized.facts.requests.map(r => [r.requestId, r]));
const outcomes = new Map(normalized.outcomes.map(r => [r.requestId, r]));
const mapping = { harbor_face: 'harbor', fixed_delay: 'fixed_delay', age_only: 'age_based', harbor_conditional: 'queue_aware' };
const models = [
  { key: 'harbor', label: 'Harbor', description: 'Queue-aware valuation with FACE capacity pricing.' },
  { key: 'fixed_delay', label: 'Fixed-delay pricing', description: 'One historical settlement-time estimate for every receipt.' },
  { key: 'age_based', label: 'Age-based pricing', description: 'Remaining settlement time estimated from receipt age.' },
  { key: 'queue_aware', label: 'Queue-aware valuation', description: 'Receipt age and queue conditions, without a capacity adjustment.' },
];
let common = null;
for (const [old] of Object.entries(mapping)) {
  const ledger = csv(gunzipSync(readFileSync(path.join(research, old + '-ledger.csv.gz'))).toString());
  const ids = new Set(); let profit = 0n, seller = 0n, fee = 0n;
  for (const row of ledger) {
    const req = requests.get(row.id), outcome = outcomes.get(row.id);
    check(req && outcome && !ids.has(row.id), 'Unknown or duplicate simulated receipt'); ids.add(row.id);
    check(row.face_wei === req.face && row.recovery_wei === outcome.recovery && Number(row.spendable_ts) === Number(outcome.finalizedAt) + 21600, 'Simulated receipt differs from indexed outcome');
    check(Number(row.quote_ts) === Number(req.timestamp) + 86400 && Number(row.quote_ts) >= source.meta.start, 'Simulation timing mismatch');
    const result = BigInt(row.recovery_wei) - BigInt(row.gross_wei) - BigInt(row.operation_wei);
    check(result === BigInt(row.profit_wei), 'Receipt profit mismatch');
    profit += result; seller += BigInt(row.net_after_gas_wei); fee += BigInt(row.fee_wei);
  }
  const ordered = [...ids].sort().join(','); common ??= ordered;
  check(common === ordered && ids.size === source.meta.matchedFills, 'Different model cohorts');
  check(String(profit) === source.summary[old].profitWei && String(seller) === source.summary[old].sellerWei && String(fee) === source.summary[old].feeWei, 'Ledger aggregate mismatch');
}
const valuation = csv(gunzipSync(readFileSync(path.join(research, 'valuation-errors.csv.gz'))).toString());
check(valuation.length === source.meta.oneDayOpportunities && new Set(valuation.map(r => r.id)).size === valuation.length, 'Valuation cohort mismatch');
for (const row of valuation) check(requests.get(row.id)?.face === row.face_wei && Number(row.quote_ts) === Number(requests.get(row.id).timestamp) + 86400 && outcomes.get(row.id)?.recovery !== null, 'Valuation source mismatch');
const remap = object => Object.fromEntries(Object.entries(object).map(([key, value]) => [mapping[key], value]));
const histogram = h => {
  for (const [key, counts] of Object.entries(h.counts)) check(counts.length === h.edges.length - 1 && counts.every(n => Number.isSafeInteger(n) && n >= 0) && counts.reduce((a,b) => a+b,0) === h.n[key], 'Histogram mismatch');
  return { ...h, counts: remap(h.counts), n: remap(h.n), metrics: remap(h.metrics) };
};
const data = {
  version: 1,
  meta: { ...source.meta, sourceMode: manifest.sourceMode, historyDatasetId: datasetId, chainId: manifest.series.chainId, cutoffBlock: manifest.series.endBlock, cutoffHash: manifest.series.cutoffHash, graphDeployment: manifest.graphProof?.deployment ?? null, indexedRequests: totals.requests, indexedClaims: totals.claims, contractParity: 'OUT_OF_SCOPE', historyReconciled: true },
  models,
  accuracy: histogram(source.accuracy),
  profit: { ...source.profit, series: remap(source.profit.series) },
  surplus: histogram(source.surplus),
  tradeoff: source.tradeoff.map(p => ({ ...p, key: mapping[p.key] })),
  summary: remap(source.summary),
};
for (const model of models) {
  const points = data.profit.series[model.key];
  check(Math.abs(points.at(-1)[1] - data.summary[model.key].profit) < 1e-9, 'Profit endpoint mismatch');
}
const benchmarkId = hash(canonical(data));
const artifact = { ...data, benchmarkId };
mkdirSync(path.dirname(path.resolve(destination)), { recursive: true });
const tmp = destination + '.tmp-' + process.pid;
writeFileSync(tmp, JSON.stringify(artifact) + '\n'); renameSync(tmp, destination);
console.log(JSON.stringify({ output: destination, benchmarkId, historyDatasetId: datasetId, sourceMode: manifest.sourceMode, models: models.map(m => m.label), matchedFills: source.meta.matchedFills, valuationOpportunities: valuation.length }, null, 2));
