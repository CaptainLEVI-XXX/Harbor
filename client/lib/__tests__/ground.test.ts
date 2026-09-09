import { describe, it, expect, vi } from 'vitest';
import { paintSheet, paintCell, roundedRect, maskAt } from '../ground';

function stubCtx() {
  const calls: string[] = [];
  const alphas: number[] = [];
  const gradient = { addColorStop: vi.fn() };
  return {
    calls,
    ctx: {
      fillRect: () => calls.push('fillRect'),
      createRadialGradient: () => { calls.push('radial'); return gradient; },
      createLinearGradient: () => { calls.push('linear'); return gradient; },
      beginPath: () => calls.push('beginPath'),
      moveTo: () => {}, arcTo: () => {}, closePath: () => calls.push('closePath'),
      save: () => calls.push('save'), restore: () => calls.push('restore'),
      clip: () => calls.push('clip'),
      set fillStyle(_v: unknown) {},
      set globalAlpha(v: number) { alphas.push(v); },
    } as unknown as CanvasRenderingContext2D,
    gradient,
    alphas,
  };
}

describe('ground renderer', () => {
  it('paints the sheet then exactly two blooms, as crumbs does', () => {
    const { ctx, calls } = stubCtx();
    paintSheet(ctx, 1413, 726);
    expect(calls.filter(c => c === 'radial')).toHaveLength(2);
  });

  it('masks the relief out at the centre of the page and in fully at the edges', () => {
    // crumbs: mask-image radial-gradient(46% 38%, transparent 0, #0000004d 48%, #000 80%)
    expect(maskAt(706, 363, 1413, 726)).toBeCloseTo(0, 2);   // dead centre
    expect(maskAt(20, 20, 1413, 726)).toBe(1);               // far corner
    const mid = maskAt(706 + 1413 * 0.46 * 0.48, 363, 1413, 726);
    expect(mid).toBeGreaterThan(0.2);
    expect(mid).toBeLessThan(0.4);
  });

  it('draws centre cells far fainter than edge cells', () => {
    const centre = stubCtx();
    paintCell(centre.ctx, 8, 4, 84, 25, 1413, 726);          // ~page centre
    const edge = stubCtx();
    paintCell(edge.ctx, 0, 0, 84, 25, 1413, 726);            // far corner
    expect(centre.alphas[0]).toBeLessThan(0.1);
    expect(edge.alphas[0]).toBe(1);
  });

  it('clips every cell to a rounded rect before filling', () => {
    const { ctx, calls } = stubCtx();
    paintCell(ctx, 0, 0, 84, 25);
    expect(calls).toContain('clip');
    expect(calls.indexOf('clip')).toBeLessThan(calls.lastIndexOf('fillRect'));
    expect(calls).toContain('restore');
  });

  it('roundedRect closes its path', () => {
    const { ctx, calls } = stubCtx();
    roundedRect(ctx, 0, 0, 84, 84, 25);
    expect(calls).toContain('beginPath');
    expect(calls).toContain('closePath');
  });
});
