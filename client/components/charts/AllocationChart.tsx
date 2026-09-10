'use client';

import { useState } from 'react';
import type { AllocationPoint } from '@/lib/earn/derive';
import type { Strategy } from '@/lib/earn/types';
import { ASSET_DECIMALS } from '@/lib/earn/types';
import { formatWeiFixed } from '@/lib/format';
import { PLOT, linear, evenTicks, linePath, bandPath, indexAt } from '@/lib/charts/scale';
import { fullDate, shortDate } from '@/lib/charts/dates';

const RANGES = [
  { label: '1M', days: 30 },
  { label: '6M', days: 180 },
  { label: '1Y', days: 365 },
];

const HEIGHT = 180;

type Props = {
  points: AllocationPoint[];
  strategies: Strategy[];
  focus: string | null;
  onFocus: (id: string | null) => void;
};

/** Axis ticks: whole WETH, abbreviated above a thousand. */
function tick(whole: number): string {
  return whole >= 1000 ? `${(whole / 1000).toFixed(2)}k` : whole.toFixed(0);
}

/**
 * Where the capital is, over time. Total height is TVL, so this one chart
 * carries both readings - which is why the page has no separate TVL section.
 *
 * Bands are ONE hue at six lightnesses, darkest at the bottom, taken from the
 * strategy fixture in fixture order. Six distinct hues would be six accents.
 */
export default function AllocationChart({ points, strategies, focus, onFocus }: Props) {
  const [split, setSplit] = useState(true);
  const [days, setDays] = useState(30);
  const [hover, setHover] = useState<number | null>(null);

  const shown = points.slice(-days);
  const plotWidth = PLOT.width - PLOT.left - PLOT.right;
  const plotHeight = HEIGHT - PLOT.top - PLOT.bottom;
  const step = plotWidth / Math.max(1, shown.length - 1);

  /** WETH as a plain number. Charts are pixels; money elsewhere stays bigint. */
  const eth = (wei: bigint) => Number(wei / 10n ** 15n) / 1000;

  const totals = shown.map(p => eth(p.totalWei));
  const high = Math.max(...totals, 1);
  const low = Math.min(...totals, high);
  const pad = split ? high * 0.08 : (high - low) * 0.22 || 1;
  const floor = split ? 0 : Math.max(0, low - pad);
  const ceiling = high + pad;

  const y = linear([floor, ceiling], [PLOT.top + plotHeight, PLOT.top]);
  const x = (i: number) => PLOT.left + step * i;

  // stack from the darkest band upward, so the ramp reads ground-to-sky
  const stacked = strategies.map((strategy, band) => {
    const bottom: [number, number][] = [];
    const top: [number, number][] = [];
    shown.forEach((point, i) => {
      let below = 0;
      for (let k = 0; k < band; k++) below += eth(point.bands[k] ?? 0n);
      bottom.push([x(i), y(below)]);
      top.push([x(i), y(below + eth(point.bands[band] ?? 0n))]);
    });
    return { strategy, d: bandPath(top, bottom) };
  });

  const current = shown[hover ?? shown.length - 1];
  const labelEvery = Math.ceil(shown.length / 5);
  const outline: [number, number][] = shown.map((p, i) => [x(i), y(eth(p.totalWei))]);

  return (
    <div className="chart well">
      <div className="chead">
        <div>
          <div className="when">{current ? fullDate(current.at) : ''}</div>
          <div className="now">
            {current ? formatWeiFixed(current.totalWei, ASSET_DECIMALS, 3) : '0.000'}
            <small>WETH</small>
          </div>
        </div>
        <div className="ctools">
          <div className="seg glass" role="group" aria-label="Chart mode">
            <button type="button" aria-pressed={split} onClick={() => setSplit(true)}>
              By strategy
            </button>
            <button type="button" aria-pressed={!split} onClick={() => setSplit(false)}>
              Total
            </button>
          </div>
          <div className="seg glass" role="group" aria-label="Value range">
            {RANGES.map(r => (
              <button
                key={r.label}
                type="button"
                aria-pressed={days === r.days}
                onClick={() => setDays(r.days)}
              >
                {r.label}
              </button>
            ))}
          </div>
        </div>
      </div>

      <svg
        viewBox={`0 0 ${PLOT.width} ${HEIGHT}`}
        role="img"
        aria-label="Capital allocation across strategies over time"
        onPointerMove={event => {
          const box = event.currentTarget.getBoundingClientRect();
          if (box.width === 0) return;
          const px = ((event.clientX - box.left) / box.width) * PLOT.width;
          setHover(indexAt(px + step / 2, PLOT.left, step, shown.length));
        }}
        onPointerLeave={() => setHover(null)}
      >
        <defs>
          <linearGradient id="allocTotal" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#8E6FC8" stopOpacity=".32" />
            <stop offset="1" stopColor="#8E6FC8" stopOpacity=".02" />
          </linearGradient>
        </defs>

        {evenTicks(floor, ceiling, 3).map((value, i) => (
          <g key={value}>
            <line
              x1={PLOT.left}
              x2={PLOT.left + plotWidth}
              y1={y(value)}
              y2={y(value)}
              stroke="rgba(116,94,166,.13)"
              strokeWidth={1}
              strokeDasharray={i ? '2 5' : undefined}
            />
            <text className="gtick" x={PLOT.left + plotWidth + 8} y={y(value) + 3.4}>
              {tick(value)}
            </text>
          </g>
        ))}

        {split ? (
          <>
            {stacked.map(({ strategy, d }) => (
              <path
                key={strategy.id}
                data-band={strategy.id}
                className="band"
                d={d}
                fill={strategy.colour}
                opacity={focus === null ? 0.92 : focus === strategy.id ? 1 : 0.28}
                onPointerEnter={() => onFocus(strategy.id)}
                onPointerLeave={() => onFocus(null)}
              />
            ))}
            {/* the total stays readable against the bands */}
            <path d={linePath(outline)} fill="none" stroke="rgba(255,255,255,.75)" strokeWidth={1.5} />
          </>
        ) : (
          <path
            data-total=""
            d={`${linePath(outline)} L${x(shown.length - 1)} ${PLOT.top + plotHeight} L${PLOT.left} ${PLOT.top + plotHeight} Z`}
            fill="url(#allocTotal)"
            stroke="#5C3D82"
            strokeWidth={2}
          />
        )}

        {hover !== null && (
          <line
            x1={x(hover)}
            x2={x(hover)}
            y1={PLOT.top}
            y2={PLOT.top + plotHeight}
            stroke="rgba(74,47,107,.42)"
            strokeWidth={1}
          />
        )}

        {shown.map((p, i) =>
          i % labelEvery || i > shown.length - labelEvery / 2 ? null : (
            <text key={p.at} className="xtick" x={x(i)} y={HEIGHT - 7} textAnchor="middle">
              {shortDate(p.at)}
            </text>
          ),
        )}
      </svg>
    </div>
  );
}
