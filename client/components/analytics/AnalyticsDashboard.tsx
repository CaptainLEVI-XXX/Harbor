'use client';
import { useState } from 'react';
import { utcFormat } from 'd3';
import type { Benchmark, ModelKey } from '@/lib/analytics/schema';
import BenchmarkPlot, { COLOURS, SHORT, type PlotKind } from './BenchmarkPlot';
import styles from './analytics.module.css';

const number = (x: number, places = 2) => x.toLocaleString('en-US', { minimumFractionDigits: places, maximumFractionDigits: places });
const date = (x: number) => utcFormat('%d %b %Y')(new Date(x * 1000));
const PLOTS: PlotKind[] = ['profit', 'surplus', 'accuracy', 'tradeoff'];

/** "best of 4", "2nd of 4": where harbor stands, computed, never asserted. */
function standing(values: Record<ModelKey, number>, higherIsBetter: boolean): string {
  const mine = values.harbor;
  const ahead = Object.values(values).filter(v => higherIsBetter ? v > mine : v < mine).length;
  const n = Object.keys(values).length;
  return `${ahead === 0 ? 'best' : ['2nd', '3rd', '4th'][ahead - 1]} of ${n} models`;
}

export default function AnalyticsDashboard({ data }: { data: Benchmark }) {
  const keys = data.models.map(m => m.key);
  const [visible, setVisible] = useState<ModelKey[]>(keys);
  const [announcement, setAnnouncement] = useState('');
  const toggle = (key: ModelKey) => {
    if (visible.length === 1 && visible.includes(key)) return;
    const next = visible.includes(key) ? visible.filter(k => k !== key) : keys.filter(k => visible.includes(k) || k === key);
    setVisible(next); setAnnouncement('Showing ' + data.models.filter(m => next.includes(m.key)).map(m => m.label).join(', '));
  };
  const a = data.meta.assumptions;
  const per = (f: (key: ModelKey) => number) => Object.fromEntries(keys.map(k => [k, f(k)])) as Record<ModelKey, number>;
  // harbor's forecast is queue-aware's, so its accuracy is that model's
  const mae = per(k => data.accuracy.metrics[k === 'harbor' ? 'queue_aware' : k]!.mae!);
  const tiles = [
    { label: 'LP profit', value: number(data.summary.harbor.profit), unit: 'WETH', note: standing(per(k => data.summary[k].profit), true) },
    { label: 'Trades below cost', value: number(data.summary.harbor.negativeFraction * 100, 1), unit: '%', note: standing(per(k => data.summary[k].negativeFraction), false) },
    { label: 'Valuation error', value: number(mae.harbor), unit: 'bp', note: standing(mae, false) },
    { label: 'Trades simulated', value: number(data.meta.matchedFills, 0), unit: '', note: `${number(data.meta.oneDayOpportunities, 0)} receipts valued` },
  ];

  return <section className={styles.page}>
    <header className={styles.head}>
      <h1>How harbor prices</h1>
      <p>Four pricing models, replayed on the same withdrawal history.</p>
      <div className={styles.facts}>
        <span className={styles.chip}>Historical simulation</span>
        <span>{data.meta.chain} · {data.meta.issuer}</span>
        <span className={styles.mono}>{date(data.meta.start)} – {date(data.meta.end)}</span>
      </div>
    </header>

    <div className={styles.tiles}>
      {tiles.map((t, i) => <div key={t.label} className={styles.tile} data-lead={i === 0 ? '' : undefined}>
        <span>{t.label}</span>
        <b>{t.value}<i>{t.unit}</i></b>
        <small>{t.note}</small>
      </div>)}
    </div>

    <div className={styles.bar}>
      <div className={styles.legend} role="group" aria-label="Pricing mechanisms">
        {data.models.map(m => <button key={m.key} type="button" aria-label={m.label} title={m.description} aria-pressed={visible.includes(m.key)} onClick={() => toggle(m.key)}>
          <i style={{ borderColor: COLOURS[m.key], borderTopStyle: m.key === 'fixed_delay' ? 'dashed' : 'solid' }} />{SHORT[m.key]}
        </button>)}
      </div>
      <span className={styles.aside}>tap to show or hide</span>
    </div>
    <span className={styles.srOnly} role="status" aria-live="polite">{announcement}</span>

    <div className={styles.grid}>
      {PLOTS.map(kind => <BenchmarkPlot key={kind} kind={kind} data={data} visible={visible} />)}
    </div>

    <details className={styles.more}>
      <summary>How it was tested</summary>
      <dl className={styles.models}>{data.models.map(m => <div key={m.key}>
        <dt><i style={{ borderColor: COLOURS[m.key], borderTopStyle: m.key === 'fixed_delay' ? 'dashed' : 'solid' }} />{SHORT[m.key]}</dt><dd>{m.description}</dd>
      </div>)}</dl>
      <dl className={styles.facts2}>
        <div><dt>Capital</dt><dd>{number(a.capital_weth, 0)} WETH</dd></div>
        <div><dt>Funding</dt><dd>{number(a.funding_rate * 100, 0)}% / yr</dd></div>
        <div><dt>LP margin</dt><dd>{a.margin_bps} bp</dd></div>
        <div><dt>External fee</dt><dd>{a.external_fee_bps} bp</dd></div>
        <div><dt>Operations / receipt</dt><dd>{a.cost_weth} WETH</dd></div>
        <div><dt>Seller gas / receipt</dt><dd>{a.customer_gas_weth} WETH</dd></div>
        <div><dt>Settlement lag</dt><dd>+{a.recovery_operation_lag_hours} h</dd></div>
      </dl>
      <div className={styles.tableScroll}><table>
        <caption>Results · WETH</caption>
        <thead><tr><th>Model</th><th>LP profit</th><th>After funding</th><th>Seller proceeds</th></tr></thead>
        <tbody>{data.models.map(m => <tr key={m.key}><th scope="row" title={m.label}>{SHORT[m.key]}</th><td>{number(data.summary[m.key].profit, 4)}</td><td>{number(data.summary[m.key].surplus, 4)}</td><td>{number(data.summary[m.key].seller, 4)}</td></tr>)}</tbody>
      </table></div>
      <p className={styles.note}>Simulated on history, not observed harbor trades or future returns. harbor capacity: 60% utilization target, kappa 25 bp, up to 64 receipts. The test period was already inspected.</p>
      <p className={styles.evidence}>{data.meta.sourceMode === 'GRAPH_VERIFIED' ? 'Issuer history verified from The Graph' : 'Reconciled research data · Graph indexing pending'}</p>
      <dl className={styles.proof}>
        <div><dt>History</dt><dd>{number(data.meta.indexedRequests, 0)} requests · {number(data.meta.indexedClaims, 0)} claims · block {number(data.meta.cutoffBlock, 0)}</dd></div>
        <div><dt>Dataset</dt><dd>{data.meta.historyDatasetId}</dd></div>
        <div><dt>Benchmark</dt><dd>{data.benchmarkId}</dd></div>
        {data.meta.graphDeployment && <div><dt>Graph</dt><dd>{data.meta.graphDeployment}</dd></div>}
      </dl>
      <a className={styles.link} href="/api/analytics" target="_blank" rel="noreferrer">Chart data ↗</a>
    </details>
  </section>;
}
