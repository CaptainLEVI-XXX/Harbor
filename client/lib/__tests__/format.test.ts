import { describe, it, expect } from 'vitest';
import { formatSigned, formatWei, formatWeiFixed, group, parseWei } from '../format';

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

describe('the two decimal scales', () => {
  it('round-trips hWETH at 24 decimals as well as WETH at 18', () => {
    // the same displayed figure, six orders of magnitude apart in raw units
    expect(parseWei('11.996', 18)).toBe(11_996_000_000_000_000_000n);
    expect(parseWei('11.996', 24)).toBe(11_996_000n * 10n ** 18n);
    expect(formatWeiFixed(parseWei('11.996', 24)!, 24, 4)).toBe('11.9960');
  });

  it('does not silently accept a share amount at asset scale', () => {
    // a million times too small, and it must look it - not round to something plausible
    expect(formatWeiFixed(parseWei('11.996', 18)!, 24, 4)).toBe('0.0000');
  });
});

describe('formatSigned', () => {
  it('prefixes a plus and pads the fraction', () => {
    expect(formatSigned(18400000000000000000n, 18, 1)).toBe('+18.4');
  });

  it('uses U+2212 MINUS SIGN, never a hyphen', () => {
    const out = formatSigned(-300000000000000000n, 18, 1);
    expect(out).toBe('−0.3');
    expect(out).not.toContain('-');
  });

  it('gives zero no sign at all', () => {
    expect(formatSigned(0n, 18, 2)).toBe('0.00');
  });
});

describe('group', () => {
  it('separates thousands and leaves the fraction alone', () => {
    expect(group('3279.579')).toBe('3,279.579');
    expect(group('1383.98')).toBe('1,383.98');
  });

  it('leaves a short figure untouched', () => {
    expect(group('84.59')).toBe('84.59');
  });

  it('keeps a real minus outside the grouping', () => {
    expect(group('−1234.5')).toBe('−1,234.5');
  });
});
