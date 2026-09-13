const HOUR = 3_600_000;

/** each window is cut into buckets small enough to see movement, few enough to read */
const BUCKET_MS: Record<number, number> = { 12: HOUR, 24: HOUR, 168: 6 * HOUR, 720: 24 * HOUR };

export type Observation = { at: number; price: bigint };
type Bucket = { start: number; end: number; pct: number | null; total: number | null };

const change = (next: bigint, prev: bigint) => prev === 0n ? 0 : Number((next - prev) * 1_000_000n / prev) / 10_000;

/**
 * Share-price return per bucket, carried forward between checkpoints: a bucket
 * with no checkpoint is one where the price did not move, not a gap. Buckets
 * before the first observation are null - no history, not zero.
 *
 * Buckets start on the reader's own clock (whole local hours, local six-hour
 * blocks, local midnights), so a UTC offset of half an hour never shows as
 * ":30" on every tick. `offsetMinutes` is `Date#getTimezoneOffset`.
 */
export function returnBuckets(points: Observation[], hours: number, now: number, offsetMinutes: number): Bucket[] {
  const size = BUCKET_MS[hours];
  const shift = -offsetMinutes * 60_000;
  const end = Math.ceil((now + shift) / size) * size - shift;
  const count = Math.round((hours * HOUR) / size);
  const closeBy = (t: number) => { let p: bigint | null = null; for (const o of points) if (o.at < t) p = o.price; return p; };
  let base: bigint | null = null;
  return Array.from({ length: count }, (_, i) => {
    const start = end - (count - i) * size, stop = start + size;
    const close = closeBy(stop);
    const open = closeBy(start) ?? points.find(o => o.at >= start && o.at < stop)?.price ?? null;
    if (close === null || open === null) return { start, end: stop, pct: null, total: null };
    base ??= open;
    return { start, end: stop, pct: change(close, open), total: change(close, base) };
  });
}

/** Round ticks - 1, 2, 2.5 or 5 times a power of ten - covering min..max and zero. */
export function niceTicks(min: number, max: number, target = 4): { ticks: number[]; places: number } {
  const lo = Math.min(min, 0), hi = Math.max(max, 0);
  const raw = (hi - lo || 0.01) / target;
  const magnitude = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map(m => m * magnitude).find(s => s >= raw)!;
  const first = Math.floor(lo / step) * step, last = Math.ceil(hi / step) * step;
  const ticks: number[] = [];
  for (let v = first; v <= last + step / 2; v += step) ticks.push(Number((Math.round(v / step) * step).toFixed(10)));
  const places = Math.max(0, -Math.floor(Math.log10(step)) + (step / magnitude === 2.5 ? 1 : 0));
  return { ticks, places };
}
