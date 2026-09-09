type Props = { reversed?: boolean; idSuffix?: string };

/**
 * The Basin mark - Harbor Brand Guidelines §01.
 *
 *   "The mark is a basin drawn in the same rounded-square geometry as the
 *    interface lattice, left open on one side. Inside it sits the inventory
 *    Harbor holds; at the mouth, the next exit already leaving. The opening
 *    never closes - a harbor that cannot be exited is not a harbor."
 *
 * Geometry copied verbatim from the guidelines SVG - 48x48 squircle, R18,
 * stroke 7.5, inventory 15x15, next exit 8.5x8.5 at the mouth. The inventory
 * and exit unit are rounded SQUARES, not circles. Do not redraw them by eye.
 *
 * Two deliberate deviations from the guidelines:
 *   - ink is the landing's #4A2F6B, not Ink Violet #3A2358 (page palette stays)
 *   - the ink is LIT rather than flat: a 135 degree gradient plus a soft drop,
 *     the same light the tiles, coins and Connect button carry. Flat ink read as
 *     a hard foreign shape on a page where nothing else is flat.
 */
export default function HarborMark({ reversed = false, idSuffix = '' }: Props) {
  const gid = `hm-ink${idSuffix}`;
  const exit = '#6A3FD1';

  const stops = reversed
    ? ['#FFFFFF', '#F4F1FC', '#E4DDF3']
    : ['#63428C', '#4A2F6B', '#3B2456'];

  return (
    <svg
      width="1.02em"
      height="1.02em"
      viewBox="0 0 64 64"
      role="img"
      aria-label="Harbor"
      style={{ filter: reversed ? undefined : 'drop-shadow(0 3px 6px rgba(74,47,107,.26))' }}
    >
      <defs>
        <linearGradient id={gid} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor={stops[0]} />
          <stop offset="0.55" stopColor={stops[1]} />
          <stop offset="1" stopColor={stops[2]} />
        </linearGradient>
      </defs>
      <path
        d="M 56 38 A 18 18 0 0 1 38 56 L 26 56 A 18 18 0 0 1 8 38 L 8 26 A 18 18 0 0 1 26 8 L 38 8 A 18 18 0 0 1 56 26"
        fill="none"
        stroke={`url(#${gid})`}
        strokeWidth="7.5"
        strokeLinecap="round"
      />
      {/* the inventory Harbor holds */}
      <rect x="19" y="24.5" width="15" height="15" rx="5" fill={`url(#${gid})`} />
      {/* the next exit, already leaving */}
      <rect x="39" y="28" width="8.5" height="8.5" rx="2.8" fill={exit} />
    </svg>
  );
}
