import { describe, it, expect } from 'vitest';
import { sharePriceWad, dailyYieldPct, yieldSeries, allocationSeries, sharePct } from '../derive';
import type { Checkpoint, Strategy } from '../types';
import { CHECKPOINTS, STRATEGIES } from '../fixtures';

const WEI = 10n ** 18n;
const DAY = 86_400_000;

/** A checkpoint at a chosen share price. Supply is 1e6x assets at price 1. */
function cp(at: number, navEth: bigint, priceE6: bigint, bands: Record<string, bigint> = {}): Checkpoint {
  const navWei = navEth * WEI;
  return {
    at,
    navWei,
    supplyRaw: (navWei * 10n ** 6n * 1_000_000n) / priceE6,
    cashWei: 0n,
    byStrategy: bands,
  };
}

describe('sharePriceWad', () => {
  it('is exactly 1.0 when nav and supply are at issue parity', () => {
    // one WETH deposited at price 1 mints 1e24 share units
    expect(sharePriceWad(WEI, 10n ** 24n)).toBe(WEI);
  });

  it('accounts for the virtual shares that defend against inflation', () => {
    // an empty vault: nav 0, supply 0 -> (0+1) * 1e6 * 1e18 / 1e6 = 1e18
    expect(sharePriceWad(0n, 0n)).toBe(WEI);
  });

  it('rises as NAV grows against a fixed supply', () => {
    const before = sharePriceWad(100n * WEI, 100n * 10n ** 24n);
    const after = sharePriceWad(110n * WEI, 100n * 10n ** 24n);
    expect(after).toBeGreaterThan(before);
    // a wei short of 1.1, not exactly 1.1: the virtual shares sit in the
    // denominator and integer division floors, so the price rounds DOWN.
    // That direction is the inflation defence working - it must never round
    // in the depositor's favour.
    expect(after).toBe(1_100_000_000_000_000_000n - 1n);
  });
});

describe('dailyYieldPct', () => {
  it('annualises a one-day move simply, not compounded', () => {
    // 1.0000 -> 1.0001 in one day = 0.01% * 365 = 3.65%
    const a = cp(0, 100n, 1_000_000n);
    const b = cp(DAY, 100n, 1_000_100n);
    expect(dailyYieldPct(a, b)).toBeCloseTo(3.65, 2);
  });

  it('divides by the real gap when checkpoints skip a day', () => {
    const a = cp(0, 100n, 1_000_000n);
    const b = cp(2 * DAY, 100n, 1_000_200n);
    // 0.02% over two days = 0.01%/day = 3.65%
    expect(dailyYieldPct(a, b)).toBeCloseTo(3.65, 2);
  });

  it('is zero when no time passed, rather than infinite', () => {
    const a = cp(0, 100n, 1_000_000n);
    expect(dailyYieldPct(a, a)).toBe(0);
  });
});

describe('yieldSeries', () => {
  const rows = [
    cp(0, 100n, 1_000_000n),
    cp(DAY, 100n, 1_000_100n),
    cp(2 * DAY, 100n, 1_000_300n),
  ];

  it('produces one point fewer than there are checkpoints', () => {
    // the first checkpoint has no predecessor, so it has no yield
    expect(yieldSeries(rows)).toHaveLength(2);
  });

  it('averages over however many days exist when the vault is younger than the window', () => {
    const out = yieldSeries(rows, 30);
    expect(out[0].trailingPct).toBeCloseTo(out[0].dailyPct, 6);
    expect(out[1].trailingPct).toBeCloseTo((out[0].dailyPct + out[1].dailyPct) / 2, 6);
  });

  it('drops days outside the window', () => {
    const out = yieldSeries(rows, 1);
    expect(out[1].trailingPct).toBeCloseTo(out[1].dailyPct, 6);
  });
});

describe('allocationSeries', () => {
  const strategies = [
    { id: 'a', colour: '#000' },
    { id: 'b', colour: '#111' },
  ] as Strategy[];

  it('orders bands by the strategy list, not by the map', () => {
    const rows = [cp(0, 10n, 1_000_000n, { b: 4n * WEI, a: 6n * WEI })];
    expect(allocationSeries(rows, strategies)[0].bands).toEqual([6n * WEI, 4n * WEI]);
  });

  it('sums bands to the total exactly, with no rounding drift', () => {
    const rows = [cp(0, 10n, 1_000_000n, { a: 6n * WEI, b: 4n * WEI })];
    const point = allocationSeries(rows, strategies)[0];
    expect(point.bands.reduce((x, y) => x + y, 0n)).toBe(point.totalWei);
  });

  it('gives a strategy that does not exist yet a zero band, not a gap', () => {
    const rows = [cp(0, 6n, 1_000_000n, { a: 6n * WEI })];
    expect(allocationSeries(rows, strategies)[0].bands).toEqual([6n * WEI, 0n]);
  });
});

describe('sharePct', () => {
  it('reports a share of the pot to one decimal place', () => {
    expect(sharePct(4220n * WEI, 10_000n * WEI)).toBeCloseTo(42.2, 6);
  });

  it('is zero against an empty pot rather than NaN', () => {
    expect(sharePct(0n, 0n)).toBe(0);
  });
});

describe('the fixture series', () => {
  it('lands on a plausible headline APY', () => {
    const series = yieldSeries(CHECKPOINTS);
    const headline = series[series.length - 1].trailingPct;
    expect(headline).toBeGreaterThan(1);
    expect(headline).toBeLessThan(12);
  });

  it('allocates the whole pot at the last checkpoint', () => {
    const points = allocationSeries(CHECKPOINTS, STRATEGIES);
    const last = points[points.length - 1];
    expect(last.totalWei).toBe(CHECKPOINTS[CHECKPOINTS.length - 1].navWei);
    expect(sharePct(last.bands[0], last.totalWei)).toBeCloseTo(42.2, 1);
  });
});
