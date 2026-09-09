import { DESIGN } from './design';

export type Particle = {
  x: number; y: number;
  vx: number; vy: number;
  rot: number; vrot: number;
  size: number;
  bornAt: number;
};

export function spawnBurst(
  cx: number, cy: number, sp: number, now: number, rng: () => number = Math.random,
): Particle[] {
  const { minCoins, maxCoins } = DESIGN.burst;
  const count = minCoins + Math.floor(rng() * (maxCoins - minCoins + 1));
  const out: Particle[] = [];
  for (let i = 0; i < count; i++) {
    const angle = rng() * Math.PI * 2;          // no gravity: purely radial
    const speed = sp * (0.022 + rng() * 0.028);
    out.push({
      x: cx, y: cy,
      vx: Math.cos(angle) * speed,
      vy: Math.sin(angle) * speed,
      rot: rng() * 360,
      vrot: (rng() - 0.5) * 4,
      size: sp * (0.14 + rng() * 0.12),
      bornAt: now,
    });
  }
  return out;
}

/**
 * Coins never fade. They drift out of the pop, friction brings them to rest, and
 * they stay there for the life of the page - the same permanence the popped
 * cells have. Returns `settled` so the caller can drop the particle from the
 * simulation while leaving its element on screen.
 */
export function stepParticle(p: Particle, now: number): { settled: boolean } {
  const { friction, restSpeed } = DESIGN.burst;

  p.vx *= friction;
  p.vy *= friction;
  p.x += p.vx;
  p.y += p.vy;
  p.rot += p.vrot;
  p.vrot *= 0.97;

  const speed = Math.abs(p.vx) + Math.abs(p.vy);
  const age = (now - p.bornAt) / 1000;
  return { settled: speed < restSpeed || age > 6 };
}
