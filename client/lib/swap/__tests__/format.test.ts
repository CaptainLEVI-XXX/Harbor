import { describe, it, expect } from 'vitest';
import { formatWei, formatWeiFixed, parseWei } from '../format';

describe('formatWei', () => {
  it('formats 1e18 as 1', () => {
    expect(formatWei(1000000000000000000n, 18)).toBe('1');
  });
  it('keeps significant fraction digits and trims trailing zeros', () => {
    expect(formatWei(1184060000000000000n, 18)).toBe('1.18406');
  });
  it('never uses floats - full precision survives', () => {
    expect(formatWei(123456789012345678n, 18, 18)).toBe('0.123456789012345678');
  });
  it('handles zero-decimal receipts', () => {
    expect(formatWei(1n, 0)).toBe('1');
  });
  it('formats zero as 0', () => {
    expect(formatWei(0n, 18)).toBe('0');
  });
});

describe('parseWei', () => {
  it('parses a whole number', () => {
    expect(parseWei('1', 18)).toBe(1000000000000000000n);
  });
  it('parses a fraction without float error', () => {
    expect(parseWei('1.18406', 18)).toBe(1184060000000000000n);
  });
  it('truncates beyond the decimal scale rather than rounding', () => {
    expect(parseWei('1.0000000000000000009', 18)).toBe(1000000000000000000n);
  });
  it('rejects nonsense', () => {
    expect(parseWei('abc', 18)).toBeNull();
    expect(parseWei('', 18)).toBeNull();
    expect(parseWei('1.2.3', 18)).toBeNull();
  });
  it('round-trips', () => {
    const v = 3937500000000000000n;
    expect(parseWei(formatWei(v, 18, 18), 18)).toBe(v);
  });
});

describe('formatWeiFixed', () => {
  it('pads so a column lines up on the decimal point', () => {
    const col = [4120000000000000000n, 1800000000000000000n, 12500000000000000000n, 9000000000000000000n];
    expect(col.map(v => formatWeiFixed(v, 18, 4))).toEqual(['4.1200', '1.8000', '12.5000', '9.0000']);
  });
  it('truncates rather than rounding, like formatWei', () => {
    expect(formatWeiFixed(1184069999999999999n, 18, 4)).toBe('1.1840');
  });
  it('leaves zero-decimal receipts alone', () => {
    expect(formatWeiFixed(1n, 0, 4)).toBe('1');
  });
});
