import { describe, it, expect } from 'vitest';
import { fullDate, shortDate, timeOfDay } from '../dates';

const SEP_10 = Date.UTC(2026, 8, 10, 14, 22);

describe('date formatting', () => {
  it('gives every month exactly three letters', () => {
    // en-GB renders September as "Sept", which shifts an axis label
    expect(fullDate(SEP_10)).toBe('10 Sep 2026');
    expect(shortDate(SEP_10)).toBe('10 Sep');
  });

  it('pads the day so a column of ticks stays aligned', () => {
    expect(shortDate(Date.UTC(2026, 7, 3))).toBe('03 Aug');
  });

  it('reads the clock in UTC, so the page does not move with the reader', () => {
    expect(timeOfDay(SEP_10)).toBe('14:22');
  });
});
