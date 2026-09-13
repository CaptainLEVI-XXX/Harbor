'use client';

import { useState } from 'react';
import { PLOT, linear, evenTicks, linePath } from '@/lib/charts/scale';
import { moment, rangeLabel, since, tickLabel } from '@/lib/charts/dates';
import RangeTabs from './RangeTabs';
import { formatWei } from '@/lib/format';
import { useDisplayPrice } from '@/lib/harbor/DisplayPriceProvider';

const HEIGHT = 170;

type Props = { points: { at: number; price: bigint }[]; now: number };

/**
 * WETH per whole hWETH, on a time axis: checkpoints are irregular, and spacing
 * them evenly would draw a burst of trading as a long flat stretch. Hovering
 * snaps to the nearest checkpoint and the header becomes its readout.
 */
export default function ShareValueChart({ points: all, now }: Props) {
  const { usd } = useDisplayPrice();
  const [hover, setHover] = useState<number | null>(null);
  const [hours, setHours] = useState(24);
  // the price in force when the window opens is carried in as its first point,
  // so a quiet window is a flat line rather than an empty chart
  const opening = [...all].reverse().find(p => p.at <= now - hours * 3_600_000);
  const inside = since(all, hours, now);
  const points = [...(opening ? [{ at: now - hours * 3_600_000, price: opening.price }] : []), ...inside];
  if (points.length && points[points.length - 1].at < now) points.push({ at: now, price: points[points.length - 1].price });
  const plotWidth = PLOT.width - PLOT.left - PLOT.right;
  const plotHeight = HEIGHT - PLOT.top - PLOT.bottom;
  const first = points[0] ?? { at: now, price: 0n }, last = points[points.length - 1] ?? first;
  const span = last.at - first.at;
  const values = points.map(p => Number(p.price / 10n ** 12n) / 1e6);
  const lo = Math.min(...values), hi = Math.max(...values);
  const pad = (hi - lo) * 0.18 || hi * 0.001 || 0.001;
  const y = linear([lo - pad, hi + pad], [PLOT.top + plotHeight, PLOT.top]);
  const x = linear([first.at, last.at], [PLOT.left, PLOT.left + plotWidth]);
  const line: [number, number][] = points.map((p, i) => [x(p.at), y(values[i])]);
  const empty = points.length < 2;
  const hovered = hover === null ? null : points[hover];

  return (
    <div className="chart well">
      <div className="chead">
        <div className="clabel">
          <div className="when">{hovered ? moment(hovered.at, span) : 'WETH per hWETH'}</div>
          {hovered ? (
            <div className="now">{formatWei(hovered.price, 18)}<small>WETH · {usd(hovered.price)}</small></div>
          ) : (
            <div className="now rest">{empty ? 'No history in this window' : rangeLabel(first.at, last.at)}</div>
          )}
        </div>
        <RangeTabs hours={hours} onChange={h => { setHours(h); setHover(null); }} />
      </div>
      {!empty && (
      <svg
        viewBox={`0 0 ${PLOT.width} ${HEIGHT}`}
        role="img"
        aria-label="WETH value per hWETH share"
        onPointerMove={event => {
          const box = event.currentTarget.getBoundingClientRect();
          if (box.width === 0) return;
          const px = ((event.clientX - box.left) / box.width) * PLOT.width;
          let best = 0;
          line.forEach(([lx], i) => { if (Math.abs(lx - px) < Math.abs(line[best][0] - px)) best = i; });
          setHover(best);
        }}
        onPointerLeave={() => setHover(null)}
      >
        <defs>
          <linearGradient id="shareWash" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#8E6FC8" stopOpacity=".26" />
            <stop offset="1" stopColor="#8E6FC8" stopOpacity="0" />
          </linearGradient>
        </defs>
        {evenTicks(lo - pad, hi + pad, 3).map((value, i) => (
          <g key={value}>
            <line x1={PLOT.left} x2={PLOT.left + plotWidth} y1={y(value)} y2={y(value)}
              stroke="rgba(116,94,166,.13)" strokeDasharray={i ? '2 5' : undefined} />
            <text className="gtick" x={PLOT.left + plotWidth + 8} y={y(value) + 3.4}>{value.toFixed(4)}</text>
          </g>
        ))}
        <path d={`${linePath(line)} L${line[line.length - 1][0]} ${PLOT.top + plotHeight} L${line[0][0]} ${PLOT.top + plotHeight} Z`} fill="url(#shareWash)" />
        <path d={linePath(line)} fill="none" stroke="#5C3D82" strokeWidth={2} strokeLinejoin="round" strokeLinecap="round" />
        {hovered && hover !== null && <>
          <line x1={line[hover][0]} x2={line[hover][0]} y1={PLOT.top} y2={PLOT.top + plotHeight} stroke="rgba(74,47,107,.42)" />
          <circle cx={line[hover][0]} cy={line[hover][1]} r={4} fill="#5C3D82" stroke="#EFE8F9" strokeWidth={2} />
        </>}
        {[first, last].map((p, i) => (
          <text key={i} className="xtick" x={x(p.at)} y={HEIGHT - 7} textAnchor={i ? 'end' : 'start'}>{tickLabel(p.at, span)}</text>
        ))}
      </svg>
      )}
    </div>
  );
}
