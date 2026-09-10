import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { DESIGN } from '@/lib/design';

const css = readFileSync(join(process.cwd(), 'app/globals.css'), 'utf8');

/**
 * globals.css now carries more than one page. These checks are about the swap
 * surface's discipline, so they read only the swap block - the earn block has
 * its own equivalents in lib/earn/__tests__/parity.test.ts.
 */
const SWAP_START = css.indexOf('/* ============================================================\n   SWAP');
const EARN_START = css.indexOf('/* ================= earn =================');
const swapCss = css.slice(SWAP_START, EARN_START === -1 ? undefined : EARN_START);

/** Spec §13 - the parts of landing-page parity a test can hold. */
describe('landing page parity', () => {
  it('shares the landing page ink values', () => {
    expect(DESIGN.ink.strong).toBe('#4A2F6B');
    expect(DESIGN.ink.secondary).toBe('#6F6689');
    expect(DESIGN.ink.tertiary).toBe('#9086A8');
  });

  it('uses no ink outside those three, plus the one accent', () => {
    const colours = new Set((swapCss.match(/#[0-9A-Fa-f]{6}/g) ?? []).map(c => c.toUpperCase()));
    const allowed = new Set([
      '#4A2F6B', '#6F6689', '#9086A8',              // the three inks
      '#6A3FD1',                                     // exit violet
      '#5B4478', '#5F4A7C', '#5F4A82', '#B3A7C8',   // material tints of the same hue
      '#E4DBF3', '#E9E2F6', '#F7F3FD', '#EFE8F9',
      '#5C3D82', '#402659', '#FFF',
    ]);
    for (const c of colours) expect(allowed, `unexpected colour ${c}`).toContain(c);
  });

  it('shares the lattice geometry', () => {
    expect(DESIGN.cell.size).toBe(84);
    expect(DESIGN.cell.radiusRatio).toBeCloseTo(25 / 84);
  });

  it('keeps the landing page press spring untouched', () => {
    expect(DESIGN.motion.pressScale).toBe(0.93);
    expect(DESIGN.motion.pressSpringStiffness).toBe(420);
    expect(DESIGN.motion.pressSpringDamping).toBe(26);
    expect(DESIGN.motion.dentDecayMs).toBe(420);
  });

  it('spends Exit Violet as ink on nothing but the value that moves and the countdown', () => {
    // every rule that paints text in the accent, by selector
    // the leading boundary matters: without it this also matches `caret-color`
    const inked = [...swapCss.matchAll(/([^{}]+)\{[^{}]*[;{\s]color:\s*#6A3FD1[^{}]*\}/g)].map(m =>
      m[1].trim(),
    );
    expect(inked.sort()).toEqual([
      '.amt input.out',       // the derived leg, in the well
      '.count',               // the expiry countdown
      '.qrow > span.big',     // that same derived leg, restated in the quote
    ]);
    // no view shows more than one of the two amount selectors: .amt exists on
    // Tokens only, and there .qrow > span.big restates the very same figure.
    // The Basin mark's exit unit is the accent too, but that is the brand mark
    // shipped with the landing page, not ink this surface spends.
  });

  it('sets tabular mono figures wherever a number renders', () => {
    for (const sel of ['.amt input {', '.count {', '.ent {', '.mk {', '.swap-foot {']) {
      const block = css.slice(css.indexOf(sel), css.indexOf(sel) + 320);
      expect(block, sel).toContain('var(--font-mono)');
    }
    for (const sel of ['.amt input {', '.count {', '.ent {', '.mk {']) {
      const block = css.slice(css.indexOf(sel), css.indexOf(sel) + 320);
      expect(block, sel).toContain('tabular-nums');
    }
  });

  it('carves the exchange rather than raising it', () => {
    const block = css.slice(css.indexOf('.rev button {'), css.indexOf('.rev button:hover'));
    expect(block).toContain('translate(-50%, -50%)');           // straddles the seam
    expect(block).toContain('0 1px 0 rgba(255,255,255,.95)');   // the lip below the hole
    expect(block).toMatch(/border:\s*0/);                       // no raised edge
    // the only non-inset shadow allowed is that 1px lip - nothing that spreads
    const shadow = block.slice(block.indexOf('box-shadow:') + 'box-shadow:'.length, block.indexOf('transition:'));
    // split on the commas between layers - not the ones inside rgba(), and not
    // the ones inside the comments that annotate each wall
    const layers: string[] = [];
    let depth = 0;
    let current = '';
    const clean = shadow.replace(/\/\*[\s\S]*?\*\//g, '').replace(/;[\s\S]*$/, '');
    for (const ch of clean) {
      if (ch === '(') depth++;
      else if (ch === ')') depth--;
      if (ch === ',' && depth === 0) { layers.push(current); current = ''; }
      else current += ch;
    }
    layers.push(current);
    const outer = layers.map(l => l.trim()).filter(l => l && !l.includes('inset'));
    expect(outer).toHaveLength(1);
    expect(outer[0]).toContain('0 1px 0');
  });

  it('keeps the wells touching, so there is a seam to cut through', () => {
    expect(css).toMatch(/\.rev \{ position: relative; height: 0/);
  });
});
