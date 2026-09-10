import { describe, it, expect } from 'vitest';
import { STRATEGIES, CHECKPOINTS } from '../fixtures';

describe('earn fixtures', () => {
  it('gives every strategy a distinct band colour, darkest first', () => {
    const colours = STRATEGIES.map(s => s.colour);
    expect(new Set(colours).size).toBe(colours.length);
    expect(colours[0]).toBe('#4A2F6B');
  });

  it('has strategy values that sum to NAV at every checkpoint, to the wei', () => {
    for (const cp of CHECKPOINTS) {
      const sum = Object.values(cp.byStrategy).reduce((a, b) => a + b, 0n);
      expect(sum, new Date(cp.at).toISOString()).toBe(cp.navWei);
    }
  });

  it('ends on the headline figures the page shows', () => {
    const last = CHECKPOINTS[CHECKPOINTS.length - 1];
    expect(last.navWei).toBe(3279579000000000000000n);
  });

  it('lets a strategy appear part-way through, contributing nothing before it exists', () => {
    const ethena = CHECKPOINTS.map(cp => cp.byStrategy['ethena'] ?? 0n);
    expect(ethena[0]).toBe(0n);
    expect(ethena[ethena.length - 1]).toBeGreaterThan(0n);
  });

  it('carries enough history for a 30-day trailing window plus a 1Y range', () => {
    expect(CHECKPOINTS.length).toBeGreaterThanOrEqual(395);
  });
});
