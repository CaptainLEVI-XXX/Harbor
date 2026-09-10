'use client';

import type { Strategy } from '@/lib/earn/types';
import { ASSET_DECIMALS } from '@/lib/earn/types';
import { formatSigned, formatWeiFixed, group } from '@/lib/format';

export type StrategyRow = { id: string; valueWei: bigint; pct: number };

type Props = {
  strategies: Strategy[];
  rows: StrategyRow[];
  focus: string | null;
  onFocus: (id: string | null) => void;
};

/**
 * WETH volume in k. Every figure in the column takes the same form: "9100"
 * beside "59.35k" makes the reader convert in their head to compare two
 * numbers that sit one above the other.
 */
function volume(wei: bigint | null): string {
  if (wei === null) return '—';
  const whole = Number(wei / 10n ** BigInt(ASSET_DECIMALS));
  return whole >= 1000 ? `${(whole / 1000).toFixed(2)}k` : whole.toFixed(0);
}

/**
 * The strategy table is the allocation chart's legend: same swatch, same
 * order, linked on hover. That is why the two share a card.
 *
 * There is no per-strategy APY column and there must never be one. Yield
 * accrues to the vault as a whole; splitting it across routes would mean
 * inventing a cost allocation and publishing a fabricated figure.
 */
export default function StrategyTable({ strategies, rows, focus, onFocus }: Props) {
  const byId = new Map(rows.map(r => [r.id, r]));
  const earnedTotal = strategies.reduce((sum, s) => sum + (s.earnedWei ?? 0n), 0n);
  const volumeTotal = strategies.reduce((sum, s) => sum + (s.volume30dWei ?? 0n), 0n);
  const queueTotal = strategies.reduce((sum, s) => sum + s.inQueueWei, 0n);

  return (
    <div className="list well">
      <div className="shdr cols">
        <span>strategy</span>
        <span>holding</span>
        <span>traded 30d</span>
        <span>earned</span>
        <span>in queue</span>
      </div>

      <div className="scrollwrap">
        <div className="scroller">
          {strategies.map(s => {
            const row = byId.get(s.id);
            const sign = s.earnedWei === null ? 'none' : s.earnedWei < 0n ? 'loss' : 'gain';
            return (
              <div
                key={s.id}
                className="srow cols"
                data-row={s.id}
                data-focused={focus === s.id ? '' : undefined}
                onPointerEnter={() => onFocus(s.id)}
                onPointerLeave={() => onFocus(null)}
              >
                <span className="pair">
                  <i className="sw" style={{ background: s.colour }} />
                  <span className="who">
                    {s.issuer} <i>· {s.asset}</i>
                  </span>
                </span>
                <span className="hold">
                  <span className="num sub">{s.holding}</span>
                  <span className="pct">
                    {row
                      ? `${group(formatWeiFixed(row.valueWei, ASSET_DECIMALS, 2))} WETH · ${row.pct.toFixed(1)}%`
                      : '—'}
                  </span>
                </span>
                <span className="num sub">{volume(s.volume30dWei)}</span>
                <span className={`num ${sign}`}>
                  {s.earnedWei === null ? '—' : formatSigned(s.earnedWei, ASSET_DECIMALS, 1)}
                </span>
                <span className={`num ${s.inQueueWei > 0n ? 'sub' : 'none'}`}>
                  {s.inQueueWei > 0n ? group(formatWeiFixed(s.inQueueWei, ASSET_DECIMALS, 1)) : '—'}
                </span>
              </div>
            );
          })}
        </div>
      </div>

      <div className="stot cols">
        <span>Across all strategies</span>
        <span />
        <span className="num sub">{volume(volumeTotal)}</span>
        <span className={`num ${earnedTotal < 0n ? 'loss' : 'gain'}`}>
          {formatSigned(earnedTotal, ASSET_DECIMALS, 1)}
        </span>
        <span className="num sub">{group(formatWeiFixed(queueTotal, ASSET_DECIMALS, 1))}</span>
      </div>
    </div>
  );
}
