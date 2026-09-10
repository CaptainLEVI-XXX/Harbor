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

const pad = (n: number) => String(n).padStart(2, '0');

/** "10 Sep 2026" - the chart card header. */
export function fullDate(at: number): string {
  const d = new Date(at);
  return `${pad(d.getUTCDate())} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`;
}

/** "10 Sep" - an axis tick. */
export function shortDate(at: number): string {
  const d = new Date(at);
  return `${pad(d.getUTCDate())} ${MONTHS[d.getUTCMonth()]}`;
}

/** "14:22", UTC - the activity list. */
export function timeOfDay(at: number): string {
  const d = new Date(at);
  return `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`;
}
