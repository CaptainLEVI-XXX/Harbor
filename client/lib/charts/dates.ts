/**
 * Explicit date formatting, not `toLocaleDateString`.
 *
 * Two reasons. `en-GB` renders September as "Sept" - four letters where every
 * other month gets three, which shifts an axis label and breaks the tabular
 * rhythm. And locale data comes from the runtime's ICU build, so the same call
 * can format differently in Node and in a browser: a test would pass while the
 * page was wrong.
 */
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const DAY = 86_400_000;
const pad = (n: number) => String(n).padStart(2, '0');

/** "10 Sep 2026", UTC - a hovered day on a daily chart. */
function fullDate(at: number): string {
  const d = new Date(at);
  return `${pad(d.getUTCDate())} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`;
}

/** "10 Sep", UTC - a daily axis tick. */
function shortDate(at: number): string {
  const d = new Date(at);
  return `${pad(d.getUTCDate())} ${MONTHS[d.getUTCMonth()]}`;
}

/** "13 Sep" on the viewer's own calendar: intraday labels are read against a clock. */
export function local(at: number): string {
  const d = new Date(at);
  return `${pad(d.getDate())} ${MONTHS[d.getMonth()]}`;
}

/** "14:22" on the viewer's own clock. */
export function clock(at: number): string {
  const d = new Date(at);
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/** Within two days a date tells nothing apart, so ticks become clock times. */
export function tickLabel(at: number, span: number): string {
  return span < 2 * DAY ? clock(at) : shortDate(at);
}

/** The window a chart covers, at the grain its ticks use. */
export function rangeLabel(from: number, to: number): string {
  if (to - from >= 2 * DAY) return `${shortDate(from)} – ${shortDate(to)}`;
  return local(from) === local(to)
    ? `${local(from)}, ${clock(from)} – ${clock(to)}`
    : `${local(from)} ${clock(from)} – ${local(to)} ${clock(to)}`;
}

/** A hovered instant: the date, and the local time when the chart is intraday. */
export function moment(at: number, span: number): string {
  return span < 2 * DAY ? `${local(at)} ${new Date(at).getFullYear()}, ${clock(at)}` : fullDate(at);
}

/** The ranges a live chart offers: a young vault is read in hours, not years. */
export const RANGES = [
  { label: '12H', hours: 12 },
  { label: '24H', hours: 24 },
  { label: '7D', hours: 24 * 7 },
  { label: '30D', hours: 24 * 30 },
] as const;

/** The points inside the last `hours` before `now`. */
export function since<T extends { at: number }>(points: T[], hours: number, now: number): T[] {
  return points.filter(p => p.at > now - hours * 3_600_000 && p.at <= now);
}
