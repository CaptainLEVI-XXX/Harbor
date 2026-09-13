import { describe, expect, it } from 'vitest';
import { niceTicks, returnBuckets } from '../returns';

const H = 3_600_000;
const WAD = 10n ** 18n;
// IST is UTC+5:30: getTimezoneOffset() reports -330
const IST = -330;

describe('share price return buckets', () => {
  it('starts buckets on whole local hours, not on UTC hours', () => {
    const now = Date.UTC(2026, 8, 13, 2, 33); // 08:03 IST
    const [first] = returnBuckets([], 12, now, IST);
    expect(new Date(first.start).getUTCMinutes()).toBe(30); // :00 IST
  });

  it('matches the indexed history: the jump, the dip, and quiet hours as zero, not gaps', () => {
    const t = (h: number, m: number) => Date.UTC(2026, 8, 12, h, m);
    const points = [
      { at: t(19, 11), price: WAD },                 // 00:41 IST
      { at: t(21, 13), price: 1_004_323_360_000_000_000n }, // 02:43 IST
      { at: t(0, 49) + 24 * H, price: 1_004_096_680_000_000_000n }, // 06:19 IST
    ];
    const buckets = returnBuckets(points, 12, Date.UTC(2026, 8, 13, 1, 30), IST).filter(b => b.pct !== null);
    // IST hours 00-06: the first check, a quiet hour, the 02:43 jump, three quiet hours, the 06:19 dip
    expect(buckets.map(b => b.pct)).toEqual([0, 0, 0.4323, 0, 0, 0, -0.0225]);
    expect(buckets.at(-1)!.total).toBe(0.4096);
  });

  it('has no history before the first observation', () => {
    const buckets = returnBuckets([{ at: Date.UTC(2026, 8, 13, 0, 0), price: WAD }], 24, Date.UTC(2026, 8, 13, 1, 0), 0);
    expect(buckets[0].pct).toBeNull();
  });
});

describe('round ticks', () => {
  it('lands on round numbers and always includes zero', () => {
    expect(niceTicks(-0.0226, 0.4925)).toEqual({ ticks: [-0.2, 0, 0.2, 0.4, 0.6], places: 1 });
    expect(niceTicks(0, 0.0509).ticks).toContain(0);
  });
});
