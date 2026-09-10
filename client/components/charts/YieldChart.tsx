'use client';

import { useState } from 'react';
import type { YieldPoint } from '@/lib/earn/derive';
import { PLOT, linear, evenTicks, linePath, indexAt } from '@/lib/charts/scale';
import { fullDate, shortDate } from '@/lib/charts/dates';

const RANGES = [
  { label: '1W', days: 7 },
  { label: '1M', days: 30 },
  { label: '6M', days: 180 },
  { label: '1Y', days: 365 },
];

const HEIGHT = 196;
/** The lattice cell's own corner ratio, applied to a bar's width. */
const LATTICE_RATIO = 25 / 84;

/**
 * Daily yield as bars, the trailing average as a line over them.
 *
 * The tooltip IS the header: hovering a column rewrites the date and figure
 * above the plot. There is no floating box, so there is nothing to position
 * and nothing to collide with the card edge.
 */
export default function YieldChart({ points }: { points: YieldPoint[] }) {
  const [days, setDays] = useState(30);
  const [hover, setHover] = useState<number | null>(null);

  const shown = points.slice(-days);
  const plotWidth = PLOT.width - PLOT.left - PLOT.right;
  const plotHeight = HEIGHT - PLOT.top - PLOT.bottom;
  const step = plotWidth / Math.max(1, shown.length);
  const barWidth = Math.max(1.2, Math.min(15, step * 0.62));

  const max = Math.max(...shown.map(p => p.dailyPct), 0.001) * 1.12;
  const y = linear([0, max], [PLOT.top + plotHeight, PLOT.top]);
  const centre = (i: number) => PLOT.left + step * i + step / 2;

  const active = hover ?? shown.length - 1;
  const current = shown[active];
  const line: [number, number][] = shown.map((p, i) => [centre(i), y(p.trailingPct)]);
  const labelEvery = Math.ceil(shown.length / 6);

  return (
    <div className="chart well">
      <div className="chead">
        <div>
          <div className="when">{current ? fullDate(current.at) : ''}</div>
          <div className="now">
            {current ? current.trailingPct.toFixed(2) : '0.00'}%<small>30-day average</small>
          </div>
        </div>
        <div className="seg glass" role="group" aria-label="Yield range">
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

      <svg
        viewBox={`0 0 ${PLOT.width} ${HEIGHT}`}
        role="img"
        aria-label="Daily yield with its 30-day trailing average"
        onPointerMove={event => {
          const box = event.currentTarget.getBoundingClientRect();
          if (box.width === 0) return;
          const x = ((event.clientX - box.left) / box.width) * PLOT.width;
          setHover(indexAt(x, PLOT.left, step, shown.length));
        }}
        onPointerLeave={() => setHover(null)}
      >
        <defs>
          <linearGradient id="yieldBar" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#7A60AC" stopOpacity=".42" />
            <stop offset="1" stopColor="#7A60AC" stopOpacity=".24" />
          </linearGradient>
        </defs>

        {evenTicks(0, max, 4).map((value, i) => (
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
              {value.toFixed(0)}%
            </text>
          </g>
        ))}

        {shown.map((p, i) => (
          <rect
            key={p.at}
            data-bar=""
            x={PLOT.left + step * i + (step - barWidth) / 2}
            y={y(p.dailyPct)}
            width={barWidth}
            height={Math.max(1.2, PLOT.top + plotHeight - y(p.dailyPct))}
            rx={Math.min(barWidth * LATTICE_RATIO, barWidth / 2)}
            fill={hover === i ? 'rgba(106,63,209,.55)' : 'url(#yieldBar)'}
          />
        ))}

        <path
          d={linePath(line)}
          fill="none"
          stroke="#6A3FD1"
          strokeWidth={2}
          strokeLinejoin="round"
          strokeLinecap="round"
        />

        {hover !== null && line[hover] && (
          <circle
            cx={line[hover][0]}
            cy={line[hover][1]}
            r={3.5}
            fill="#6A3FD1"
            stroke="#EFE8F9"
            strokeWidth={2}
          />
        )}

        {shown.map((p, i) =>
          i % labelEvery || i > shown.length - labelEvery / 2 ? null : (
            <text
              key={`x${p.at}`}
              className="xtick"
              x={centre(i)}
              y={HEIGHT - 7}
              textAnchor="middle"
            >
              {shortDate(p.at)}
            </text>
          ),
        )}
      </svg>
    </div>
  );
}
