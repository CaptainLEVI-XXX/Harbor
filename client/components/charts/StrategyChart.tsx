'use client';

import { useId, useState } from 'react';
import TokenMark from '@/components/TokenMark';
import { linear, linePath, bandPath } from '@/lib/charts/scale';
import { moment, tickLabel } from '@/lib/charts/dates';
import { formatSigned, formatWei, tone } from '@/lib/format';
import { useDisplayPrice } from '@/lib/harbor/DisplayPriceProvider';
import type { StrategyEvent } from '@/lib/harbor/analytics';
import RangeTabs from './RangeTabs';

type StrategyLine = { id: string; label: string; issuer: string };

const WIDTH = 680, LEFT = 6, RIGHT = 58, GAP = 26;
const TOP_H = 118, PL_H = 74, AXIS = 22;
const HEIGHT = 10 + TOP_H + GAP + PL_H + AXIS;
/** one hue, darkest first, as every stacked chart here is */
const SHADES = ['#4A2F6B', '#8B6BB8', '#B097D8', '#C9B6E6'];
const HOUR = 3_600_000;

const eth = (wei: bigint) => Number(wei / 10n ** 12n) / 1e6;

type Sample = { at: number; traded: bigint[]; result: bigint };

/**
 * Two readings on one clock: what the strategies traded, stacked, and what that
 * trading has realized, as a line about zero. Both are cumulative - a step up
 * is a fill - and one crosshair reads both panels at the same instant.
 */
export default function StrategyChart({ strategies, events, now }: { strategies: StrategyLine[]; events: StrategyEvent[]; now: number }) {
  const { usd } = useDisplayPrice();
  const [hours, setHours] = useState(24);
  const [hover, setHover] = useState<number | null>(null);
  const uid = useId().replace(/[^a-zA-Z0-9]/g, '');
  const from = now - hours * HOUR;
  const index = new Map(strategies.map((s, i) => [s.id, i]));

  // running totals, sampled at the window's edges and at every event inside it
  const traded = strategies.map(() => 0n);
  let result = 0n;
  const snap = (at: number): Sample => ({ at, traded: [...traded], result });
  const samples: Sample[] = [];
  for (const e of events) {
    if (e.at > now) break;
    if (e.at > from && samples.length === 0) samples.push(snap(from));
    const i = index.get(e.strategy);
    if (i !== undefined) traded[i] += e.traded;
    result += e.result;
    if (e.at > from) samples.push(snap(e.at));
  }
  if (samples.length === 0) samples.push(snap(from));
  samples.push(snap(now));

  const x = linear([from, now], [LEFT, WIDTH - RIGHT]);
  const totals = samples.map(s => eth(s.traded.reduce((a, b) => a + b, 0n)));
  const ceiling = Math.max(...totals, 0.0001) * 1.12;
  const yT = linear([0, ceiling], [10 + TOP_H, 10]);
  const plTop = 10 + TOP_H + GAP;
  const pls = samples.map(s => eth(s.result));
  const reach = Math.max(...pls.map(Math.abs), 0.000001) * 1.25;
  const yP = linear([-reach, reach], [plTop + PL_H, plTop]);

  // a cumulative total holds its value until the next event: draw steps, not slopes
  const steps = (ys: number[]): [number, number][] => samples.flatMap((s, i) => i === 0 ? [[x(s.at), ys[0]]] as [number, number][] : [[x(s.at), ys[i - 1]], [x(s.at), ys[i]]] as [number, number][]);
  const bands = strategies.map((_, band) => {
    const below = samples.map(s => yT(eth(s.traded.slice(0, band).reduce((a, b) => a + b, 0n))));
    const above = samples.map(s => yT(eth(s.traded.slice(0, band + 1).reduce((a, b) => a + b, 0n))));
    return bandPath(steps(above), steps(below));
  });
  const plLine = steps(pls.map(yP));
  const last = samples[samples.length - 1];
  const shown = hover === null ? last : samples[hover];
  const total = shown.traded.reduce((a, b) => a + b, 0n);

  return (
    <div className="chart well strat">
      <div className="chead">
        <div className="clabel">
          <div className="when">{hover === null ? `Last ${hours < 48 ? `${hours} hours` : `${hours / 24} days`}, cumulative` : moment(shown.at, 0)}</div>
          <div className="now">
            {formatWei(total, 18)}<small>WETH traded · {usd(total)}</small>
            <span className={`pl ${tone(shown.result)}`}>{formatSigned(shown.result, 18, 6)}</span><small>realized</small>
          </div>
        </div>
        <RangeTabs hours={hours} onChange={h => { setHours(h); setHover(null); }} />
      </div>

      <svg
        viewBox={`0 0 ${WIDTH} ${HEIGHT}`}
        role="img"
        aria-label="Cumulative traded volume by strategy, and realized profit and loss"
        onPointerMove={event => {
          const box = event.currentTarget.getBoundingClientRect();
          if (box.width === 0) return;
          const px = ((event.clientX - box.left) / box.width) * WIDTH;
          // the step in force at the pointer: the last sample at or before it
          let at = 0;
          samples.forEach((s, i) => { if (x(s.at) <= px) at = i; });
          setHover(at);
        }}
        onPointerLeave={() => setHover(null)}
      >
        <defs>
          <clipPath id={`up${uid}`}><rect x={0} y={0} width={WIDTH} height={yP(0) + 1} /></clipPath>
          {/* the zero line itself belongs to neither side, or a loss colour bleeds along it */}
          <clipPath id={`down${uid}`}><rect x={0} y={yP(0) + 1.5} width={WIDTH} height={HEIGHT} /></clipPath>
        </defs>

        <text className="lane" x={WIDTH - RIGHT + 8} y={16}>Traded</text>
        {[0, 0.5, 1].map(f => {
          const v = f * ceiling;
          return <g key={f}>
            <line x1={LEFT} x2={WIDTH - RIGHT} y1={yT(v)} y2={yT(v)} stroke="rgba(116,94,166,.13)" strokeDasharray={f ? '2 5' : undefined} />
            {f === 0.5 && <text className="gtick" x={WIDTH - RIGHT + 8} y={yT(v) + 14}>{v.toFixed(v < 1 ? 3 : 2)}</text>}
          </g>;
        })}
        {bands.map((d, i) => <path key={strategies[i].id} d={d} fill={SHADES[i % SHADES.length]} opacity={0.9} />)}

        <text className="lane" x={WIDTH - RIGHT + 8} y={plTop + 6}>P/L</text>
        <line x1={LEFT} x2={WIDTH - RIGHT} y1={yP(0)} y2={yP(0)} stroke="rgba(116,94,166,.35)" />
        <text className="gtick" x={WIDTH - RIGHT + 8} y={yP(0) + 3.4}>0</text>
        {[
          { clip: `up${uid}`, colour: '#2F7355' },
          { clip: `down${uid}`, colour: '#A83C56' },
        ].map(p => (
          <g key={p.clip} clipPath={`url(#${p.clip})`}>
            <path d={`${linePath(plLine)} L${x(now)} ${yP(0)} L${x(from)} ${yP(0)} Z`} fill={p.colour} opacity={0.22} />
            <path d={linePath(plLine)} fill="none" stroke={p.colour} strokeWidth={2} strokeLinejoin="round" />
          </g>
        ))}

        {hover !== null && <>
          <line x1={x(shown.at)} x2={x(shown.at)} y1={10} y2={plTop + PL_H} stroke="rgba(74,47,107,.42)" />
          <circle cx={x(shown.at)} cy={yT(eth(total))} r={3.5} fill="#4A2F6B" stroke="#EFE8F9" strokeWidth={2} />
          <circle cx={x(shown.at)} cy={yP(eth(shown.result))} r={3.5} fill={shown.result < 0n ? '#A83C56' : '#2F7355'} stroke="#EFE8F9" strokeWidth={2} />
        </>}
        {[0, 1, 2, 3].map(i => {
          const t = from + (hours * HOUR * i) / 3;
          return <text key={i} className="xtick" x={x(t)} y={HEIGHT - 6} textAnchor={i === 0 ? 'start' : i === 3 ? 'end' : 'middle'}>{tickLabel(t, hours * HOUR)}</text>;
        })}
      </svg>

      <ul className="legend">
        {strategies.map((s, i) => (
          <li key={s.id}>
            <i style={{ background: SHADES[i % SHADES.length] }} /><TokenMark symbol={s.issuer} />{s.label}
            <span className="num">{formatWei(shown.traded[i], 18)}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
