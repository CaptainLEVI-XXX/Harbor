import { describe, it, expect } from 'vitest';
import { readdirSync, readFileSync } from 'node:fs';
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

  it('caps the content column but lets it shrink, and keeps a gutter', () => {
    // a fixed 760px track plus a grid child's default min-width:auto is what
    // let the strategy table push the page wider than the viewport
    expect(earnCss).toContain('grid-template-columns:minmax(0,760px) 420px');
    // sized off its own box, never the viewport: 100vw counts the scrollbar
    expect(earnCss).toContain('max-width:calc(1204px + 88px)');
    expect(earnCss).not.toContain('100vw');
    expect(earnCss).toContain('gap:24px');
  });

  it('stops any card from pushing its track open', () => {
    expect(earnCss).toMatch(/\.earn \.stack > \*\{min-width:0;max-width:100%\}/);
  });

  it('caps the two lists so they scroll instead of stretching the card', () => {
    expect(earnCss).toMatch(/\.earn \.scroller \{[^}]*overflow-y: auto/);
    // the cap is a multiple of a FIXED row height, so it always lands on half
    // a row: that half row is the affordance. A content-sized row clips at an
    // arbitrary point and reads as a rendering bug.
    expect(earnCss).toMatch(/max-height: calc\(var\(--row\) \* 5\.5\)/);
    expect(earnCss).toMatch(/\.earn \.srow \{ height: 48px/);
    expect(earnCss).toMatch(/\.earn \.act-row \{ height: 40px/);
    expect(earnCss).toMatch(/\.earn \.list \.scroller \{ --row: 48px; \}/);
    expect(earnCss).toMatch(/\.earn \.acts \.scroller \{ --row: 40px; \}/);
    // scrolling the rows must not scroll the page with them
    expect(earnCss).toMatch(/overscroll-behavior: contain/);
    // and the cut edge fades, so the half row reads as "more" not as clipping
    expect(earnCss).toMatch(/\.earn \.scrollwrap::after \{/);
  });


  it('never reuses a layout class that an unscoped rule already owns', () => {
    // The landing page owns `.col` with align-items/text-align: center. A
    // scoped `.earn .col` rule ADDS to that, it does not replace it, so the
    // centring leaked in: cards sized to their content instead of stretching,
    // prose rendered centred, and the wide strategy table overflowed its track.
    const shared = css.slice(0, css.indexOf('/* ================= earn ================='));
    const ownedElsewhere = new Set<string>();
    for (const m of shared.matchAll(/(?:^|\})\s*([^{@}]+?)\s*\{/g)) {
      for (const part of m[1].split(',')) {
        const name = part.trim().match(/^\.([A-Za-z][\w-]*)$/);
        if (name) ownedElsewhere.add(name[1]);
      }
    }

    // material vocabulary is shared on purpose - swap reuses it too
    const material = new Set(['well', 'list', 'act', 'amt', 'asset', 'qrow', 'seg', 'fmeta', 'flabel', 'modal', 'sec', 'glass', 'foot', 'note', 'panel']);

    const markup = ['components/earn', 'components/charts']
      .flatMap(dir => readdirSync(join(process.cwd(), dir)).filter(f => f.endsWith('.tsx')).map(f => readFileSync(join(process.cwd(), dir, f), 'utf8')))
      .concat(readFileSync(join(process.cwd(), 'app/(app)/earn/page.tsx'), 'utf8'))
      .join('\n');

    const used = new Set<string>();
    for (const m of markup.matchAll(/className=[{"`\']+([^"`\'{}]+)/g)) {
      for (const c of m[1].split(/\s+/)) if (c) used.add(c);
    }

    const layoutCollisions = [...used].filter(c => ownedElsewhere.has(c) && !material.has(c));
    expect(layoutCollisions).toEqual([]);
  });

  it('sets its own px base, because .fg sets cqw', () => {
    expect(earnCss).toMatch(/\.earn \{ font-size: 15px; \}/);
  });
});
