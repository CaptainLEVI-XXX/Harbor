import { describe, it, expect } from 'vitest';
import { computeGeometry, PopState, cellAt } from '../grid';

describe('computeGeometry', () => {
  it('scales the cell with the viewport, keeping 88px at the reference width', () => {
    const g = computeGeometry(1413, 726, 1413, 88, 0.33);
    expect(g.sp).toBeCloseTo(88);
    expect(g.rad).toBeCloseTo(88 * 0.33);
  });
  it('halves the cell at half the reference width', () => {
    expect(computeGeometry(706.5, 400, 1413, 88, 0.33).sp).toBeCloseTo(44);
  });
  it('covers the viewport with one cell of overscan', () => {
    const g = computeGeometry(1413, 726, 1413, 88, 0.33);
    expect(g.cols * g.sp).toBeGreaterThanOrEqual(1413);
    expect(g.rows * g.sp).toBeGreaterThanOrEqual(726);
  });
});

describe('cellAt', () => {
  const geom = computeGeometry(1413, 726, 1413, 88, 0.33);
  it('maps a point to its cell', () => {
    expect(cellAt(0, 0, geom)).toEqual({ x: 0, y: 0 });
    expect(cellAt(100, 100, geom)).toEqual({ x: 1, y: 1 });
  });
  it('returns null outside the grid', () => {
    expect(cellAt(-5, 10, geom)).toBeNull();
    expect(cellAt(10, -5, geom)).toBeNull();
  });
});

describe('PopState', () => {
  it('starts with nothing popped', () => {
    const s = new PopState(10, 10);
    expect(s.count()).toBe(0);
    expect(s.isPopped(3, 3)).toBe(false);
  });
  it('pops a cell once and reports it', () => {
    const s = new PopState(10, 10);
    expect(s.pop(3, 3)).toBe(true);
    expect(s.isPopped(3, 3)).toBe(true);
    expect(s.count()).toBe(1);
  });
  it('refuses to pop the same cell twice', () => {
    const s = new PopState(10, 10);
    s.pop(3, 3);
    expect(s.pop(3, 3)).toBe(false);
    expect(s.count()).toBe(1);
  });
  it('never un-pops - permanence is a product decision, not an accident', () => {
    const s = new PopState(10, 10);
    s.pop(2, 2);
    for (let i = 0; i < 100; i++) s.pop(2, 2);
    expect(s.isPopped(2, 2)).toBe(true);
    expect(s.count()).toBe(1);
  });
  it('ignores out-of-range coordinates', () => {
    const s = new PopState(10, 10);
    expect(s.pop(-1, 5)).toBe(false);
    expect(s.pop(10, 5)).toBe(false);
    expect(s.count()).toBe(0);
  });
});
