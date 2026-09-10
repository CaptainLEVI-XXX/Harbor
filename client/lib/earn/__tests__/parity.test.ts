import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { STRATEGIES } from '../fixtures';

const css = readFileSync(join(process.cwd(), 'app/globals.css'), 'utf8');
const earnCss = css.slice(css.indexOf('/* ================= earn ================='));

/**
 * Spec §17 - the parts of the earn parity checklist a test can hold. The
 * counterpart to lib/swap/__tests__/parity.test.ts, which reads the swap block.
 */
describe('earn page parity', () => {
  it('is a real block, not an empty marker', () => {
    expect(earnCss.length).toBeGreaterThan(2000);
  });

  it('scopes every rule under .earn, so it cannot reach the swap page', () => {
    const selectors = [...earnCss.matchAll(/(?:^|\})\s*([.#][^{@}]*?)\s*\{/g)].map(m => m[1].trim());
    expect(selectors.length).toBeGreaterThan(40);
    for (const selector of selectors) {
      for (const part of selector.split(',')) {
        expect(part.trim(), selector).toMatch(/^\.earn\b/);
      }
    }
  });

  it('spends Exit Violet as ink on nothing but the headline and the received amount', () => {
    // the leading boundary matters: without it this also matches `caret-color`,
    // which the amount field legitimately paints in the accent
    const inked = [...earnCss.matchAll(/([^{}]+)\{[^{}]*[;{\s]color:\s*#6A3FD1[^{}]*\}/g)].map(m =>
      m[1].trim(),
    );
    expect(inked.sort()).toEqual([
      '.earn .hero-apy b', // the headline APY
      '.earn .qrow .big', // the amount you receive or claim
    ]);
    // the third permitted site is the yield chart's trailing line, which is an
    // SVG stroke set in the component, not ink this stylesheet spends
  });

  it('defines the state colours once, outside the earn block', () => {
    expect(earnCss).not.toContain('#2F7355');
    expect(earnCss).not.toContain('#A83C56');
    expect(css).toMatch(/\.gain \{ color: #2F7355; \}/);
    expect(css).toMatch(/\.loss \{ color: #A83C56; \}/);
  });

  it('gives the chart bands one hue at six lightnesses, darkest first', () => {
    const bands = STRATEGIES.map(s => s.colour);
    expect(bands).toHaveLength(6);
    expect(new Set(bands).size).toBe(6);

    // luminance must rise monotonically: the ramp reads as a gradient, and a
    // band out of order would look like a second hue
    const luminance = (hex: string) => {
      const [r, g, b] = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16));
      return 0.299 * r + 0.587 * g + 0.114 * b;
    };
    const values = bands.map(luminance);
    for (let i = 1; i < values.length; i++) {
      expect(values[i], bands[i]).toBeGreaterThan(values[i - 1]);
    }
  });

  it('keeps the charts in a well and never gives them a surface of their own', () => {
    expect(earnCss).toMatch(/\.earn \.chart\{/);
    // .chart carries only padding - the surface comes from .well beside it
    const block = earnCss.slice(earnCss.indexOf('.earn .chart{'));
    const rule = block.slice(0, block.indexOf('}'));
    expect(rule).not.toContain('background');
    expect(rule).not.toContain('box-shadow');
  });

  it('sizes the page at 760 + 24 + 420', () => {
    expect(earnCss).toContain('grid-template-columns:760px 420px');
    expect(earnCss).toContain('gap:24px');
  });

  it('sets its own px base, because .fg sets cqw', () => {
    expect(earnCss).toMatch(/\.earn \{ font-size: 15px; \}/);
  });
});
