'use client';
import { useEffect, useId, useRef, useState } from 'react';
import { bisectRight, curveStepAfter, extent, line, scaleLinear, scaleSymlog, scaleUtc, utcFormat } from 'd3';
import type { Benchmark, ModelKey, Point } from '@/lib/analytics/schema';
import styles from './analytics.module.css';

export type PlotKind = 'accuracy' | 'profit' | 'surplus' | 'tradeoff';
type Key = ModelKey | 'hurdle';

/** Validated as a categorical set on the lavender ground; fixed-delay also dashes. */
export const COLOURS: Record<Key, string> = { harbor: '#6A3FD1', queue_aware: '#0F8FA8', age_based: '#B8741A', fixed_delay: '#D0508A', hurdle: '#9086A8' };
/** Display names; full labels stay the accessible names. */
export const SHORT: Record<Key, string> = { harbor: 'harbor', fixed_delay: 'fixed-delay', age_based: 'age-based', queue_aware: 'queue-aware', hurdle: '5% hurdle' };
const DASH: Partial<Record<Key, string>> = { hurdle: '5 4', fixed_delay: '4 3' };

const TITLE: Record<PlotKind, string> = { accuracy: 'Valuation error', profit: 'LP profit', surplus: 'Profit per trade', tradeoff: 'Who gains' };
/** What the numbers under a chart mean when nothing is hovered. */
const REST: Record<PlotKind, string> = { accuracy: 'avg miss · lower is better', profit: 'total, WETH', surplus: 'trades below cost · lower is better', tradeoff: 'LP gain vs queue-aware, WETH' };
const AXIS: Record<PlotKind, [x: string, y: string]> = {
  accuracy: ['forecast error, bp', '% of receipts'], profit: ['date, UTC', 'WETH'],
  surplus: ['surplus after funding, bp', '% of trades'], tradeoff: ['seller change, WETH', 'LP change, WETH'],
};

const fixed = (x: number, places = 2) => x.toLocaleString('en-US', { minimumFractionDigits: places, maximumFractionDigits: places });
const signed = (x: number, places = 2) => `${x > 0 ? '+' : x < 0 ? '−' : ''}${fixed(Math.abs(x), places)}`;
const tick = (x: number) => x.toLocaleString('en-US', { maximumFractionDigits: 2 }).replace('-', '−');
const day = utcFormat('%d %b %Y');
function padded(values: number[], ratio = .09): [number, number] {
  const [a = 0, b = 1] = extent(values); const lo = Math.min(0, a), hi = Math.max(0, b), pad = (hi - lo || 1) * ratio;
  return [lo - pad, hi + pad];
}

export default function BenchmarkPlot({ kind, data, visible }: { kind: PlotKind; data: Benchmark; visible: ModelKey[] }) {
  const ref = useRef<HTMLDivElement>(null);
  const id = useId().replace(/:/g, '');
  const [width, setWidth] = useState(440);
  const [hover, setHover] = useState<{ x: number; y: number } | null>(null);
  useEffect(() => {
    const node = ref.current; if (!node) return;
    const resize = () => { const w = Math.floor(node.getBoundingClientRect().width); if (w > 0) setWidth(w); };
    resize(); const observer = new ResizeObserver(resize); observer.observe(node); return () => observer.disconnect();
  }, []);

  const height = 236, left = 40, right = 10, top = 24, bottom = 40;
  const w = Math.max(100, width - left - right), h = height - top - bottom;
  const histogram = kind === 'accuracy' || kind === 'surplus';
  const source = kind === 'accuracy' ? data.accuracy : data.surplus;
  const label = (key: ModelKey) => data.models.find(m => m.key === key)!.label;

  // harbor and queue-aware share one forecast, so accuracy draws it once
  const shown: ModelKey[] = kind === 'accuracy'
    ? [...visible.filter(k => k !== 'harbor' && k !== 'queue_aware'), ...(visible.includes('harbor') ? ['harbor' as const] : visible.includes('queue_aware') ? ['queue_aware' as const] : [])]
    : [...visible.filter(k => k !== 'harbor'), ...(visible.includes('harbor') ? ['harbor' as const] : [])];
  const countKey = (key: ModelKey): ModelKey => kind === 'accuracy' && key === 'harbor' ? 'queue_aware' : key;
  const series: { key: Key; points: Point[] }[] = histogram
    ? shown.map(key => ({ key, points: [...source.counts[countKey(key)]!.map((n, i) => [source.edges[i], 100 * n / source.n[countKey(key)]!] as Point), [source.edges.at(-1)!, 0]] }))
    : kind === 'profit' ? [{ key: 'hurdle', points: data.profit.hurdle }, ...shown.map(key => ({ key, points: data.profit.series[key] }))] : [];

  const allProfit = [...Object.values(data.profit.series).flat(), ...data.profit.hurdle];
  const xd: [number, number] = histogram ? padded(source.edges, .025) : kind === 'profit' ? [data.meta.start, data.meta.end] : padded(data.tradeoff.map(p => p.seller), .28);
  const yd: [number, number] = histogram ? [0, Math.max(...Object.entries(source.counts).flatMap(([k, ns]) => ns!.map(n => 100 * n / source.n[k as ModelKey]!))) * 1.08]
    : kind === 'profit' ? [Math.min(0, ...allProfit.map(p => p[1])), Math.max(...allProfit.map(p => p[1])) * 1.06] : padded(data.tradeoff.map(p => p.lp), .28);
  // both histograms have long thin tails; a signed log keeps the bulk readable
  const xs = (histogram ? scaleSymlog().constant(kind === 'accuracy' ? 1 : 2) : scaleLinear()).domain(xd).range([left, left + w]);
  const ys = scaleLinear().domain(yd).range([top + h, top]);
  // log1p differs in the last bits between server and browser; rounded pixels hydrate cleanly
  const round = (v: number) => Math.round(v * 100) / 100;
  const x = Object.assign((v: number) => round(xs(v)), { invert: (px: number) => xs.invert(px), ticks: (n: number) => xs.ticks(n) });
  const y = Object.assign((v: number) => round(ys(v)), { ticks: (n: number) => ys.ticks(n) });
  const compact = width < 380;
  const xticks: number[] = kind === 'accuracy' ? (compact ? [-100, 0, 100] : [-100, -10, -1, 0, 1, 10, 100])
    : kind === 'surplus' ? (compact ? [0, 5, 25] : [-4, -2, 0, 2, 5, 10, 25]) : kind === 'profit' ? scaleUtc().domain(xd.map(t => new Date(t * 1000))).ticks(compact ? 3 : 5).map(d => +d / 1000)
    : x.ticks(compact ? 3 : 5);
  const yticks = y.ticks(4);
  const path = line<Point>().x(p => x(p[0])).y(p => y(p[1])); if (histogram) path.curve(curveStepAfter);
  const area = line<Point>().x(p => x(p[0])).y(p => y(p[1])).curve(curveStepAfter);

  const at = hover ? x.invert(hover.x) : 0;
  const bin = Math.max(0, Math.min(source.edges.length - 2, bisectRight(source.edges, at) - 1));
  const interpolate = (points: Point[], value: number) => {
    const i = Math.max(0, Math.min(points.length - 2, bisectRight(points.map(p => p[0]), value) - 1)); const [a, b] = [points[i], points[i + 1]];
    return a[1] + (b[1] - a[1]) * Math.max(0, Math.min(1, (value - a[0]) / (b[0] - a[0])));
  };
  const dots = data.tradeoff.filter(p => visible.includes(p.key));
  const nearest = kind === 'tradeoff' && hover
    ? dots.reduce<typeof dots[number] | null>((best, p) => !best || Math.hypot(x(p.seller) - hover.x, y(p.lp) - hover.y) < Math.hypot(x(best.seller) - hover.x, y(best.lp) - hover.y) ? p : best, null)
    : null;

  // the figures under the chart: a summary at rest, the hovered slice otherwise
  const hovering = hover !== null && kind !== 'tradeoff';
  const value = (key: Key): string => {
    if (key === 'hurdle') return fixed(hovering ? interpolate(data.profit.hurdle, at) : data.profit.hurdle.at(-1)![1]);
    if (kind === 'accuracy') return hovering ? `${fixed(100 * source.counts[countKey(key)]![bin] / source.n[countKey(key)]!, 1)}%` : `${fixed(data.accuracy.metrics[countKey(key)]!.mae!, 2)} bp`;
    if (kind === 'surplus') return hovering ? `${fixed(100 * source.counts[key]![bin] / source.n[key]!, 1)}%` : `${fixed(data.summary[key].negativeFraction * 100, 1)}%`;
    if (kind === 'profit') return fixed(hovering ? interpolate(data.profit.series[key], at) : data.summary[key].profit);
    const p = data.tradeoff.find(t => t.key === key)!;
    return signed(p.lp);
  };
  const readout: Key[] = kind === 'profit' ? [...visible, 'hurdle'] : kind === 'accuracy' ? visible.filter(k => shown.includes(k)) : visible;
  const hint = nearest ? `${SHORT[nearest.key]}: sellers ${signed(nearest.seller)}, LP ${signed(nearest.lp)} WETH`
    : !hovering ? REST[kind] : histogram ? `${tick(source.edges[bin])} to ${tick(source.edges[bin + 1])} bp` : day(new Date(at * 1000));

  const move = (event: React.PointerEvent<SVGSVGElement>) => {
    const box = event.currentTarget.getBoundingClientRect();
    const px = (event.clientX - box.left) * (width / (box.width || width)), py = (event.clientY - box.top) * (height / (box.height || height));
    setHover(px < left || px > left + w || py < top - 8 || py > top + h + 8 ? null : { x: px, y: py });
  };
  const [xlabel, ylabel] = AXIS[kind];
  const zeroX = xd[0] <= 0 && xd[1] >= 0, zeroY = yd[0] < 0 && yd[1] > 0;

  return <figure className={styles.well} aria-labelledby={`plot-${id}`}>
    <figcaption className={styles.chead}>
      <h2 id={`plot-${id}`}>{TITLE[kind]}</h2>
      <span className={styles.hint} data-live={hovering || nearest ? '' : undefined}>{hint}</span>
    </figcaption>
    <div className={styles.plot} ref={ref} data-plot={kind}>
      <svg width="100%" height={height} viewBox={`0 0 ${width} ${height}`} role="img" aria-label={`${TITLE[kind]}: ${ylabel} by ${xlabel}`}
        onPointerMove={move} onPointerLeave={() => setHover(null)}>
        <defs>
          <clipPath id={`clip-${id}`}><rect x={left} y={top - 4} width={w} height={h + 8} /></clipPath>
          <linearGradient id={`fill-${id}`} x1="0" y1={top} x2="0" y2={top + h} gradientUnits="userSpaceOnUse">
            <stop offset="0" stopColor={COLOURS.harbor} stopOpacity=".22" /><stop offset="1" stopColor={COLOURS.harbor} stopOpacity="0" />
          </linearGradient>
        </defs>
        {yticks.map(t => <g key={t}>
          <line x1={left} x2={left + w} y1={y(t)} y2={y(t)} stroke={t === 0 ? 'rgba(116,94,166,.32)' : 'rgba(116,94,166,.12)'} strokeDasharray={t === 0 ? undefined : '2 5'} />
          <text className={styles.tick} x={left - 8} y={y(t) + 3.5} textAnchor="end">{tick(t)}</text>
        </g>)}
        {xticks.filter(t => t >= xd[0] && t <= xd[1]).map(t => <text key={t} className={styles.tick} x={x(t)} y={top + h + 16} textAnchor="middle">{kind === 'profit' ? utcFormat('%b %y')(new Date(t * 1000)) : tick(t)}</text>)}
        <text className={`axis-title ${styles.axis}`} data-axis="y" x={left - 8} y={top - 11} textAnchor="start">{ylabel}</text>
        <text className={`axis-title ${styles.axis}`} data-axis="x" x={left + w} y={height - 4} textAnchor="end">{xlabel}</text>
        <g clipPath={`url(#clip-${id})`}>
          {zeroX && kind !== 'profit' && <line x1={x(0)} x2={x(0)} y1={top} y2={top + h} stroke="rgba(116,94,166,.32)" />}
          {zeroY && <line x1={left} x2={left + w} y1={y(0)} y2={y(0)} stroke="rgba(116,94,166,.32)" />}
          {histogram && series.some(s => s.key === 'harbor') && <path d={`${area(series.find(s => s.key === 'harbor')!.points)}L${x(xd[1])},${y(0)}L${x(xd[0])},${y(0)}Z`} fill={`url(#fill-${id})`} />}
          {kind === 'profit' && visible.includes('harbor') && <path d={`${path(data.profit.series.harbor)}L${x(xd[1])},${y(0)}L${x(xd[0])},${y(0)}Z`} fill={`url(#fill-${id})`} />}
          {series.map(s => <path key={s.key} data-series={s.key} d={path(s.points) ?? ''} fill="none" stroke={COLOURS[s.key]}
            strokeWidth={s.key === 'harbor' ? 2 : 1.5} strokeDasharray={DASH[s.key]} strokeLinejoin="round" />)}
          {kind === 'tradeoff' && <>
            <text className={styles.quad} x={left + 6} y={top + 12}>LP earns more ↑</text>
            <text className={styles.quad} x={left + 6} y={top + h - 6}>← sellers get less</text>
            {dots.map(p => <circle key={p.key} data-series={p.key} cx={x(p.seller)} cy={y(p.lp)} r={nearest?.key === p.key ? 8 : 6} fill={COLOURS[p.key]} stroke="#F7F3FD" strokeWidth={2} />)}
          </>}
          {hovering && hover && <>
            <line x1={hover.x} x2={hover.x} y1={top} y2={top + h} stroke="rgba(74,47,107,.28)" />
            {series.map(s => <circle key={s.key} cx={hover.x} cy={y(histogram ? s.points[bin][1] : interpolate(s.points, at))} r={3.5} fill="#fff" stroke={COLOURS[s.key]} strokeWidth={2} />)}
          </>}
        </g>
        {kind === 'tradeoff' && dots.map(p => {
          // queue-aware is the origin and fixed-delay sits beside it: one label goes under, one over
          const [dx, dy, anchor]: [number, number, 'start' | 'end'] = p.key === 'queue_aware' ? [-10, 18, 'end'] : p.key === 'fixed_delay' ? [8, -12, 'start'] : [12, 4, 'start'];
          return <text key={p.key} className={styles.direct} x={x(p.seller) + dx} y={y(p.lp) + dy} textAnchor={anchor}>{SHORT[p.key]}</text>;
        })}
      </svg>
    </div>
    <dl className={styles.readout}>
      {readout.map(key => <div key={key} data-active={nearest?.key === key ? '' : undefined}>
        <dt title={key === 'hurdle' ? 'Pool funding hurdle' : label(key)}>
          <i style={{ borderColor: COLOURS[key], borderTopStyle: DASH[key] ? 'dashed' : 'solid' }} />
          {kind === 'accuracy' && key === 'harbor' && visible.includes('queue_aware') ? 'harbor / queue-aware' : SHORT[key]}
        </dt>
        <dd>{value(key)}</dd>
      </div>)}
    </dl>
  </figure>;
}
