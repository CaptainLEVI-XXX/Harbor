import type { Checkpoint, Strategy } from './types';

const WAD = 10n ** 18n;
/** HarborVault: 1e6, from _decimalsOffset() == 6. */
const VIRTUAL_SHARES = 10n ** 6n;

export type YieldPoint = { at: number; dailyPct: number; trailingPct: number };
export type AllocationPoint = { at: number; totalWei: bigint; bands: bigint[] };

/**
 * WETH per hWETH, scaled 1e18.
 *
 * The vault computes convertToAssets(shares) as
 *   shares * (nav + 1) / (supply + VIRTUAL_SHARES)
 * and shares carry six more decimals than assets, so one whole hWETH is 1e24
 * raw units and the price of one share is that expression times 1e6/1e18.
 * Both the +1 and the virtual shares are part of the inflation defence and
 * must be kept: dropping them makes an empty vault divide by zero.
 */
export function sharePriceWad(navWei: bigint, supplyRaw: bigint): bigint {
  return ((navWei + 1n) * VIRTUAL_SHARES * WAD) / (supplyRaw + VIRTUAL_SHARES);
}

/**
 * A simple annualised rate between two checkpoints, as a percentage.
 *
 * Percentages are `number` deliberately - they are display figures, not money,
 * and a rate has no wei. Money stays bigint everywhere else.
 */
export function dailyYieldPct(prev: Checkpoint, next: Checkpoint): number {
  const days = (next.at - prev.at) / 86_400_000;
  if (days <= 0) return 0;
  const before = sharePriceWad(prev.navWei, prev.supplyRaw);
  if (before === 0n) return 0;
  const after = sharePriceWad(next.navWei, next.supplyRaw);
  const growth = Number(after - before) / Number(before);
  return ((growth * 365) / days) * 100;
}

/**
 * Daily yields with a trailing mean over `window` days.
 *
 * The first checkpoint has no predecessor and therefore no yield, so the series
 * is one shorter than its input. Early in the vault's life the window is
 * shorter than 30 days and the mean is taken over what exists - reporting a
 * 30-day average from six days of data would be a fabricated figure.
 */
export function yieldSeries(checkpoints: Checkpoint[], window = 30): YieldPoint[] {
  const daily: YieldPoint[] = [];
  for (let i = 1; i < checkpoints.length; i++) {
    daily.push({
      at: checkpoints[i].at,
      dailyPct: dailyYieldPct(checkpoints[i - 1], checkpoints[i]),
      trailingPct: 0,
    });
  }
  return daily.map((point, i) => {
    const from = Math.max(0, i - window + 1);
    const slice = daily.slice(from, i + 1);
    const mean = slice.reduce((sum, p) => sum + p.dailyPct, 0) / slice.length;
    return { ...point, trailingPct: mean };
  });
}

/**
 * Per-strategy WETH values over time, in strategy order.
 *
 * The total is the sum of the bands, never the checkpoint's NAV: if those two
 * ever disagree the chart must show the bands it actually drew, not a taller
 * total with a gap under it.
 */
export function allocationSeries(
  checkpoints: Checkpoint[],
  strategies: Strategy[],
): AllocationPoint[] {
  return checkpoints.map(cp => {
    const bands = strategies.map(s => cp.byStrategy[s.id] ?? 0n);
    return { at: cp.at, totalWei: bands.reduce((a, b) => a + b, 0n), bands };
  });
}

/** A share of the pot, as a percentage. */
export function sharePct(partWei: bigint, totalWei: bigint): number {
  if (totalWei === 0n) return 0;
  return Number((partWei * 1_000_000n) / totalWei) / 10_000;
}
