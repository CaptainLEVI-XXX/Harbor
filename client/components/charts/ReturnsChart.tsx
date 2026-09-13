'use client';

import { useId, useState } from 'react';
import { PLOT, linear, linePath, indexAt } from '@/lib/charts/scale';
import { clock, local } from '@/lib/charts/dates';
import { niceTicks, returnBuckets, type Observation } from '@/lib/charts/returns';
import { tone } from '@/lib/format';
import RangeTabs from './RangeTabs';

const HEIGHT = 190;

const signed = (v: number) => `${v > 0 ? '+' : v < 0 ? '−' : ''}${Math.abs(v).toFixed(3)}%`;

/**
 * Returns, not annualised: the running return across the window as one filled
 * step - green above zero, red below - that holds flat while the price holds
 * and steps where it moves. A dot marks each period with a move; hovering any
 * period reads its own change and the running total.
 *
 * The share price counts the vault's holdings at their mark, so a purchase
 * below mark lifts it the moment it lands. That is unrealized, and said so.
 */
export default function ReturnsChart({ points, now }: { points: Observation[]; now: number }) {
  const [hours, setHours] = useState(24);
  const [hover, setHover] = useState<number | null>(null);
  const uid = useId().replace(/[^a-zA-Z0-9]/g, '');
  const shown = returnBuckets(points, hours, now, new Date(now).getTimezoneOffset());
  const intraday = hours < 48;
  const plotWidth = PLOT.width - PLOT.left - PLOT.right;
  const plotHeight = HEIGHT - PLOT.top - PLOT.bottom;
  const step = plotWidth / shown.length;
  const totals = shown.flatMap(b => b.total === null ? [] : [b.total]);
  const { ticks, places } = niceTicks(Math.min(...totals, 0), Math.max(...totals, 0.01));
  const y = linear([ticks[0], ticks[ticks.length - 1]], [PLOT.top + plotHeight, PLOT.top]);
  const left = (i: number) => PLOT.left + step * i;
  const zero = y(0);

  // the running return holds through a period and steps at its start
  const line: [number, number][] = [];
  let previous = 0;
  shown.forEach((b, i) => {
    if (b.total === null) return;
    if (line.length === 0) line.push([left(i), zero]);
    line.push([left(i), y(previous)], [left(i), y(b.total)], [left(i + 1), y(b.total)]);
    previous = b.total;
  });
  const area = line.length ? `${linePath(line)} L${line[line.length - 1][0]} ${zero} L${line[0][0]} ${zero} Z` : '';

  const hovered = hover === null ? null : shown[hover];
  const last = [...shown].reverse().find(b => b.total !== null);
  const labelEvery = Math.ceil(shown.length / 6);
  const label = (at: number) => intraday ? clock(at) : local(at);
  const span = (b: { start: number; end: number }) => intraday ? `${local(b.start)}, ${clock(b.start)} – ${clock(b.end)}` : local(b.start);

  return (
    <div className="chart well">
      <div className="chead">
        <div className="clabel">
          <div className="when">{hovered ? span(hovered) : 'Share price return · incl. unrealized marks'}</div>
          {hovered ? (
            hovered.pct === null ? <div className="now rest">No history yet</div>
              : <div className="now"><span className={tone(hovered.total ?? 0)}>{signed(hovered.total ?? 0)}</span><small>{hovered.pct === 0 ? 'no change this period' : `${signed(hovered.pct)} this period`}</small></div>
          ) : (
            <div className="now">{last ? <span className={tone(last.total ?? 0)}>{signed(last.total ?? 0)}</span> : '—'}<small>last {intraday ? `${hours} hours` : `${hours / 24} days`}</small></div>
          )}
        </div>
        <RangeTabs hours={hours} onChange={h => { setHours(h); setHover(null); }} />
      </div>

      <svg
        viewBox={`0 0 ${PLOT.width} ${HEIGHT}`}
        role="img"
        aria-label="Share price return over time"
        onPointerMove={event => {
          const box = event.currentTarget.getBoundingClientRect();
          if (box.width === 0) return;
          setHover(indexAt(((event.clientX - box.left) / box.width) * PLOT.width, PLOT.left, step, shown.length));
        }}
        onPointerLeave={() => setHover(null)}
      >
        <defs>
          <linearGradient id={`up${uid}`} x1="0" y1={PLOT.top} x2="0" y2={zero} gradientUnits="userSpaceOnUse">
            <stop offset="0" stopColor="#3A9A6C" stopOpacity=".30" />
            <stop offset="1" stopColor="#3A9A6C" stopOpacity="0" />
          </linearGradient>
          <linearGradient id={`down${uid}`} x1="0" y1={zero} x2="0" y2={PLOT.top + plotHeight} gradientUnits="userSpaceOnUse">
            <stop offset="0" stopColor="#C24B68" stopOpacity="0" />
            <stop offset="1" stopColor="#C24B68" stopOpacity=".30" />
          </linearGradient>
          {/* the zero line belongs to the gain side, or a loss colour bleeds along it */}
          <clipPath id={`above${uid}`}><rect x="0" y="0" width={PLOT.width} height={zero + 1.5} /></clipPath>
          <clipPath id={`below${uid}`}><rect x="0" y={zero + 1.5} width={PLOT.width} height={HEIGHT} /></clipPath>
        </defs>

        {ticks.map(value => (
          <g key={value}>
            <line x1={PLOT.left} x2={PLOT.left + plotWidth} y1={y(value)} y2={y(value)}
              stroke={value === 0 ? 'rgba(116,94,166,.3)' : 'rgba(116,94,166,.11)'} strokeDasharray={value === 0 ? undefined : '2 5'} />
            <text className="gtick" x={PLOT.left + plotWidth + 8} y={y(value) + 3.4}>{value.toFixed(places)}%</text>
          </g>
        ))}

        {[{ side: 'above', fill: 'up', ink: '#2F7355' }, { side: 'below', fill: 'down', ink: '#A83C56' }].map(p => (
          <g key={p.side} clipPath={`url(#${p.side}${uid})`}>
            <path d={area} fill={`url(#${p.fill}${uid})`} />
            <path d={linePath(line)} fill="none" stroke={p.ink} strokeWidth={2} strokeLinejoin="round" strokeLinecap="round" />
          </g>
        ))}

        {shown.map((b, i) => !b.pct || b.total === null ? null : (
          <circle key={b.start} data-move="" cx={left(i)} cy={y(b.total)} r={hover === i ? 4.5 : 3}
            fill={b.pct > 0 ? '#2F7355' : '#A83C56'} stroke="#F7F3FD" strokeWidth={1.5} />
        ))}

        {hovered && hover !== null && hovered.total !== null && <>
          <line x1={left(hover) + step / 2} x2={left(hover) + step / 2} y1={PLOT.top} y2={PLOT.top + plotHeight} stroke="rgba(74,47,107,.28)" />
          <circle cx={left(hover) + step / 2} cy={y(hovered.total)} r={4} fill="#fff" stroke={hovered.total < 0 ? '#A83C56' : '#2F7355'} strokeWidth={2} />
        </>}

        {shown.map((b, i) => i % labelEvery ? null : (
          <text key={`x${b.start}`} className="xtick" x={left(i)} y={HEIGHT - 7} textAnchor="start">{label(b.start)}</text>
        ))}
      </svg>
    </div>
  );
}
