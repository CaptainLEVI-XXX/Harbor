import { describe, it, expect } from 'vitest';
import { spawnBurst, stepParticle } from '../burst';

const fixedRng = () => 0.5;

describe('spawnBurst', () => {
  it('emits between six and nine particles', () => {
    for (let i = 0; i < 40; i++) {
      const n = spawnBurst(100, 100, 88, 0, Math.random).length;
      expect(n).toBeGreaterThanOrEqual(6);
      expect(n).toBeLessThanOrEqual(9);
    }
  });
  it('starts every particle at the burst origin', () => {
    for (const p of spawnBurst(250, 120, 88, 0, fixedRng)) {
      expect(p.x).toBe(250);
      expect(p.y).toBe(120);
    }
  });
  it('spreads particles in varied directions', () => {
    const ps = spawnBurst(0, 0, 88, 0, Math.random);
    const angles = ps.map(p => Math.atan2(p.vy, p.vx));
    expect(new Set(angles.map(a => Math.round(a * 10))).size).toBeGreaterThan(1);
  });
});

describe('stepParticle', () => {
  it('applies friction, not gravity - vy must not grow', () => {
    const p = spawnBurst(0, 0, 88, 0, fixedRng)[0];
    const vy0 = Math.abs(p.vy);
    for (let i = 0; i < 30; i++) stepParticle(p, i * 16);
    expect(Math.abs(p.vy)).toBeLessThan(vy0);
  });
  it('is still moving shortly after the burst', () => {
    const p = spawnBurst(0, 0, 88, 0, fixedRng)[0];
    expect(stepParticle(p, 100).settled).toBe(false);
  });
  it('comes to rest and stays - coins never fade or disappear', () => {
    const p = spawnBurst(0, 0, 88, 0, fixedRng)[0];
    let settled = false;
    for (let i = 0; i < 400 && !settled; i++) settled = stepParticle(p, i * 16).settled;
    expect(settled).toBe(true);
    const restX = p.x, restY = p.y;
    // once at rest it must not drift any further
    stepParticle(p, 9999);
    expect(Math.abs(p.x - restX)).toBeLessThan(0.5);
    expect(Math.abs(p.y - restY)).toBeLessThan(0.5);
  });
});
