'use client';

import { useState } from 'react';
import { linear } from '@/lib/charts/scale';
import { moment, since, tickLabel } from '@/lib/charts/dates';
import { formatWei } from '@/lib/format';
import { useDisplayPrice } from '@/lib/harbor/DisplayPriceProvider';
import type { ActivityKind } from '@/lib/harbor/analytics';
import RangeTabs from './RangeTabs';

const WIDTH = 680, LEFT = 92, RIGHT = 18, TOP = 12, LANE = 34, BOTTOM = 24;

/** one lane per kind, in the order money moves through the vault */
const LANES: { kind: ActivityKind; name: string; colour: string }[] = [
  { kind: 'deposit', name: 'Deposits', colour: '#8B6BB8' },
  { kind: 'bought', name: 'Bought', colour: '#4A2F6B' },
  { kind: 'sold', name: 'Sold', colour: '#6A4A96' },
  { kind: 'recovery', name: 'Recoveries', colour: '#B097D8' },
  { kind: 'payout', name: 'Withdrawals', colour: '#9A86BC' },
];

export type ActivityEvent = { id: string; at: number; kind: ActivityKind; label: string; wei: bigint; href: string };

/**
 * When things happened, what they were, and how big: time runs left to right,
 * each kind of event keeps its own lane, and a dot's area is its size. The
 * nearest dot to the pointer is the readout; each dot opens its transaction.
 */
export default function ActivityTimeline({ events, now }: { events: ActivityEvent[]; now: number }) {
  const { usd } = useDisplayPrice();
  const [hours, setHours] = useState(24);
  const [hover, setHover] = useState<string | null>(null);
  const shown = since(events, hours, now);
  const lanes = LANES.filter(l => events.some(e => e.kind === l.kind));
  const height = TOP + lanes.length * LANE + BOTTOM;
  const x = linear([now - hours * 3_600_000, now], [LEFT, WIDTH - RIGHT]);
  const laneY = (kind: ActivityKind) => TOP + LANE * lanes.findIndex(l => l.kind === kind) + LANE / 2;
  const eth = (wei: bigint) => Number(wei / 10n ** 12n) / 1e6;
  const biggest = Math.max(...shown.map(e => eth(e.wei)), 1e-9);
  // area, not radius, tracks size - a dot twice as wide reads as four times as much
  const radius = (wei: bigint) => 3.5 + 10 * Math.sqrt(eth(wei) / biggest);
  const hovered = shown.find(e => e.id === hover) ?? null;
  const ticks = [0, 1, 2, 3].map(i => now - hours * 3_600_000 * (1 - i / 3));

  return (
    <div className="chart well">
      <div className="chead">
        <div className="clabel">
          <div className="when">{hovered ? `${hovered.label} · ${moment(hovered.at, 0)}` : 'Vault activity'}</div>
          {hovered ? (
            <div className="now">{formatWei(hovered.wei, 18)}<small>WETH · {usd(hovered.wei)}</small></div>
          ) : (
            <div className="now rest">{shown.length ? `${shown.length} event${shown.length === 1 ? '' : 's'}` : 'Nothing in this window'}</div>
          )}
        </div>
        <RangeTabs hours={hours} onChange={h => { setHours(h); setHover(null); }} />
      </div>
      <svg
        viewBox={`0 0 ${WIDTH} ${height}`}
        role="img"
        aria-label="Vault activity over time"
        onPointerMove={event => {
          const box = event.currentTarget.getBoundingClientRect();
          if (box.width === 0) return;
          const px = ((event.clientX - box.left) / box.width) * WIDTH;
          const py = ((event.clientY - box.top) / box.height) * height;
          let best: string | null = null, distance = 28;
          for (const e of shown) {
            const d = Math.hypot(x(e.at) - px, laneY(e.kind) - py);
            if (d < distance) { distance = d; best = e.id; }
          }
          setHover(best);
        }}
        onPointerLeave={() => setHover(null)}
      >
        {lanes.map((l, i) => (
          <g key={l.kind}>
            <line x1={LEFT} x2={WIDTH - RIGHT} y1={TOP + LANE * i + LANE / 2} y2={TOP + LANE * i + LANE / 2} stroke="rgba(116,94,166,.14)" strokeDasharray="2 5" />
            <text className="lane" x={LEFT - 12} y={TOP + LANE * i + LANE / 2 + 4} textAnchor="end">{l.name}</text>
          </g>
        ))}
        {shown.map(e => {
          const lane = lanes.find(l => l.kind === e.kind)!;
          const on = hover === e.id;
          return (
            <a key={e.id} href={e.href} target="_blank" rel="noreferrer" onFocus={() => setHover(e.id)} onBlur={() => setHover(null)}>
              <title>{`${e.label}, ${formatWei(e.wei, 18)} WETH`}</title>
              <circle data-dot="" cx={x(e.at)} cy={laneY(e.kind)} r={radius(e.wei) + (on ? 2 : 0)} fill={lane.colour}
                fillOpacity={hover === null || on ? 0.78 : 0.3} stroke={on ? '#FFF' : 'rgba(255,255,255,.7)'} strokeWidth={on ? 2.5 : 1.2} />
            </a>
          );
        })}
        {hovered && <line x1={x(hovered.at)} x2={x(hovered.at)} y1={TOP} y2={height - BOTTOM} stroke="rgba(74,47,107,.35)" />}
        {ticks.map((t, i) => (
          <text key={i} className="xtick" x={x(t)} y={height - 7} textAnchor={i === 0 ? 'start' : i === 3 ? 'end' : 'middle'}>{tickLabel(t, hours * 3_600_000)}</text>
        ))}
      </svg>
    </div>
  );
}
