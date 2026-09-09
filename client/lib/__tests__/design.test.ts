import { describe, it, expect } from 'vitest';
import { DESIGN, CONTENT_BOX } from '../design';

describe('DESIGN constants', () => {
  it('matches the measured spec values', () => {
    expect(DESIGN.cell.size).toBe(84);              // crumbs' hit test: floor(x / 84)
    expect(DESIGN.cell.radiusRatio).toBeCloseTo(25 / 84);
    expect(DESIGN.type.baseCqw).toBe(1.3);      // NOT 2.55 - see Global Constraints
    expect(DESIGN.layout.columnWidthPct).toBeCloseTo(28.3);
    expect(DESIGN.motion.coinPeriodSeconds).toBeCloseTo(6.3);
    expect(DESIGN.motion.dentDecayMs).toBe(420);        // crumbs exit: duration .42
    expect(DESIGN.motion.pressScale).toBeCloseTo(0.93);  // crumbs animate: scale .93
    expect(DESIGN.motion.pressSpringStiffness).toBe(420);
    expect(DESIGN.motion.pressSpringDamping).toBe(26);
  });

  it('exposes exactly three ink values', () => {
    expect(Object.keys(DESIGN.ink)).toHaveLength(3);
    expect(DESIGN.ink.strong).toBe('#4A2F6B');
  });

  it('places seven coins, none overlapping the content block', () => {
    expect(DESIGN.coins).toHaveLength(7);
    for (const c of DESIGN.coins) {
      const right = c.leftPct + c.widthPct;
      // the coin svg is a 240x320 viewBox, so its height is 4/3 of its width
      const bottom = c.topPct + c.widthPct * (320 / 240);
      const overlaps =
        c.leftPct < CONTENT_BOX.right && right > CONTENT_BOX.left &&
        c.topPct < CONTENT_BOX.bottom && bottom > CONTENT_BOX.top;
      expect(overlaps).toBe(false);
    }
  });
});
