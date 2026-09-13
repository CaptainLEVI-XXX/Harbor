'use client';

import { useState } from 'react';
import type { AllocationPoint, Band } from '@/lib/earn/types';
import { ASSET_DECIMALS } from '@/lib/earn/types';
import { formatWeiFixed, group } from '@/lib/format';
import { useDisplayPrice } from '@/lib/harbor/DisplayPriceProvider';
import { PLOT, linear, evenTicks, linePath, bandPath, indexAt } from '@/lib/charts/scale';
import { moment, rangeLabel, since, tickLabel } from '@/lib/charts/dates';
import RangeTabs from './RangeTabs';


const HEIGHT = 180;

type Props = {
  points: AllocationPoint[];
  strategies: Band[];
  focus: string | null;
  onFocus: (id: string | null) => void;
  /** the window is measured back from now */
  now: number;
};

/** Axis ticks: whole WETH, abbreviated above a thousand. */
function tick(whole: number): string {
  return whole >= 1000 ? `${(whole / 1000).toFixed(2)}k` : whole >= 10 ? whole.toFixed(0) : whole.toFixed(2);
}

/**
 * Where the capital is, over time. Total height is TVL, so this one chart
 * carries both readings - which is why the page has no separate TVL section.
 *
 * Bands are ONE hue at six lightnesses, darkest at the bottom, taken from the
 * strategy fixture in fixture order. Six distinct hues would be six accents.
 */
export default function AllocationChart({ points, strategies, focus, onFocus, now }: Props) {
  const [split, setSplit] = useState(true);
  const [hours, setHours] = useState(24);
  const [hover, setHover] = useState<number | null>(null);

  const { usd } = useDisplayPrice();
  // the composition in force when the window opens is its first point
  const opening = [...points].reverse().find(p => p.at <= now - hours * 3_600_000);
  const shown = [...(opening ? [{ ...opening, at: now - hours * 3_600_000 }] : []), ...since(points, hours, now)];
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

  /** Same rule as the yield chart: the header names the chart at rest, and
   *  becomes the readout on hover. Its total already appears in the hero. */
  const hovered = hover === null ? null : shown[hover];
  const first = shown[0];
  const last = shown[shown.length - 1];
  const labelEvery = Math.ceil(shown.length / 5);
  const span = first && last ? last.at - first.at : 0;
  const outline: [number, number][] = shown.map((p, i) => [x(i), y(eth(p.totalWei))]);

  return (
    <div className="chart well">
      <div className="chead">
        <div className="clabel">
          <div className="when">
            {hovered ? moment(hovered.at, span) : split ? 'Split across strategies' : 'Total value'}
          </div>
          {hovered ? (
            <div className="now">
              {group(formatWeiFixed(hovered.totalWei, ASSET_DECIMALS, 3))}
              <small>WETH · {usd(hovered.totalWei)}</small>
            </div>
          ) : (
            <div className="now rest">
              {first && last ? rangeLabel(first.at, last.at) : ''}
            </div>
          )}
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
          <RangeTabs hours={hours} onChange={h => { setHours(h); setHover(null); }} />
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
            <text
              key={p.at}
              className="xtick"
              x={x(i)}
              y={HEIGHT - 7}
              /* a centred label at the plot's edge falls half outside the
                 viewBox and is clipped - the first one read "Aug" */
              textAnchor={i === 0 ? 'start' : i === shown.length - 1 ? 'end' : 'middle'}
            >
              {tickLabel(p.at, span)}
            </text>
          ),
        )}
      </svg>
    </div>
  );
}
