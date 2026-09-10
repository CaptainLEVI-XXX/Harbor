import { describe, it, expect } from 'vitest';
import { linear, evenTicks, linePath, bandPath, indexAt } from '../scale';

describe('linear', () => {
  it('maps the domain onto the range', () => {
    const y = linear([0, 100], [180, 20]);
    expect(y(0)).toBe(180);
    expect(y(100)).toBe(20);
    expect(y(50)).toBe(100);
  });

  it('pins a zero-width domain to the range start rather than dividing by zero', () => {
    const y = linear([5, 5], [180, 20]);
    expect(y(5)).toBe(180);
  });
});

describe('evenTicks', () => {
  it('returns one more value than there are steps, inclusive of both ends', () => {
    expect(evenTicks(0, 8, 4)).toEqual([0, 2, 4, 6, 8]);
  });
});

describe('linePath', () => {
  it('writes a move followed by lines', () => {
    expect(linePath([[0, 1], [2, 3]])).toBe('M0 1 L2 3');
  });

  it('is empty for no points, so an empty series renders nothing', () => {
    expect(linePath([])).toBe('');
  });
});

describe('bandPath', () => {
  it('runs along the top then back along the bottom and closes', () => {
    expect(bandPath([[0, 1], [2, 1]], [[0, 5], [2, 5]])).toBe('M0 1 L2 1 L2 5 L0 5 Z');
  });
});

describe('indexAt', () => {
  it('finds the column under a pointer', () => {
    expect(indexAt(8, 8, 10, 30)).toBe(0);
    expect(indexAt(28, 8, 10, 30)).toBe(2);
  });

  it('clamps inside the series rather than reading off the end', () => {
    expect(indexAt(-100, 8, 10, 30)).toBe(0);
    expect(indexAt(10_000, 8, 10, 30)).toBe(29);
  });
});
