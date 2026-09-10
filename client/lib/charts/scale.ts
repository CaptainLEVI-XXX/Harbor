/**
 * Chart geometry, kept out of the components so it can be tested without a DOM.
 * jsdom gives every element a zero-sized bounding box, so anything that depends
 * on measurement is untestable inside a component - it belongs here instead.
 */

/** The plot box shared by both charts, in viewBox units. */
export const PLOT = { width: 680, left: 6, right: 40, top: 10, bottom: 22 } as const;

export function linear(
  domain: [number, number],
  range: [number, number],
): (value: number) => number {
  const [d0, d1] = domain;
  const [r0, r1] = range;
  const span = d1 - d0;
  if (span === 0) return () => r0;
  return value => r0 + ((value - d0) / span) * (r1 - r0);
}

/** `steps` equal intervals from min to max, inclusive of both ends. */
export function evenTicks(min: number, max: number, steps: number): number[] {
  return Array.from({ length: steps + 1 }, (_, i) => min + ((max - min) / steps) * i);
}

export function linePath(points: [number, number][]): string {
  if (points.length === 0) return '';
  return points.map(([x, y], i) => `${i === 0 ? 'M' : 'L'}${x} ${y}`).join(' ');
}

/** A closed band: along the top, back along the bottom. */
export function bandPath(top: [number, number][], bottom: [number, number][]): string {
  if (top.length === 0) return '';
  const back = [...bottom]
    .reverse()
    .map(([x, y]) => `L${x} ${y}`)
    .join(' ');
  return `${linePath(top)} ${back} Z`;
}

/** Which column a pointer at `x` (in viewBox units) is over. */
export function indexAt(x: number, plotLeft: number, step: number, count: number): number {
  if (count <= 0) return 0;
  const raw = Math.floor((x - plotLeft) / step);
  return Math.max(0, Math.min(count - 1, raw));
}
