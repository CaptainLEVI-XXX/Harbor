type Props = { pale: boolean; rotation: number; index: number };

export default function Coin({ pale, rotation, index }: Props) {
  const id = index;
  // saturated at the TOP-LEFT, washing to near-white at the bottom-right
  // Measured against crumbs in the same recording: their coins reach a 95th
  // percentile chroma of 84, mine were at 38 - washed out. The coins are the only
  // saturated thing on the page, so they have to carry it.
  const f = pale
    ? ['#B9A4E0', '#CCBEEC', '#E3DCF5', '#FBFAFE']
    : ['#8E6FC8', '#A98CD6', '#CBBEEA', '#F0EBFA'];

  return (
    <svg viewBox="0 0 240 320" width="100%" height="100%" aria-hidden="true">
      <defs>
        <linearGradient id={`face${id}`} x1=".24" y1="-.02" x2=".86" y2="1">
          <stop offset="0" stopColor={f[0]} />
          <stop offset=".45" stopColor={f[1]} />
          <stop offset=".80" stopColor={f[2]} />
          <stop offset="1" stopColor={f[3]} />
        </linearGradient>
        <linearGradient id={`rim${id}`} x1=".08" y1="0" x2=".92" y2=".7">
          <stop offset="0" stopColor="#EFEAF9" />
          <stop offset=".3" stopColor="#FDFCFE" />
          <stop offset=".68" stopColor="#E3DCF2" />
          <stop offset="1" stopColor="#FAF8FD" />
        </linearGradient>
        <filter id={`blur${id}`} x="-90%" y="-260%" width="280%" height="620%">
          <feGaussianBlur stdDeviation="7.5" />
        </filter>
      </defs>

      {/* detached cast shadow - the gap is what makes the coin read as floating */}
      <ellipse
        data-role="shadow"
        cx="118" cy="207" rx="66" ry="9"
        fill="#4A2F6B" opacity=".22" filter={`url(#blur${id})`}
      />

      <g transform={`rotate(${rotation} 120 110)`}>
        {/* side wall, 19 units on a 57-unit semi-minor axis */}
        <path d="M34 110 A86 57 0 0 0 206 110 L206 129 A86 57 0 0 1 34 129 Z" fill={`url(#rim${id})`} />
        <ellipse cx="120" cy="110" rx="86" ry="57" fill={`url(#face${id})`} />
        {/* thin bright crescent on the NEAR rim only - never a ring around the whole disc */}
        <path d="M34 110 A86 57 0 0 0 206 110" fill="none" stroke="#FFFFFF" strokeOpacity=".78" strokeWidth="3.0" />
        <path d="M34 110 A86 57 0 0 1 206 110" fill="none" stroke="#FFFFFF" strokeOpacity=".22" strokeWidth="1.6" />
        <ellipse cx="142" cy="94" rx="42" ry="20" fill="#FFF" opacity=".13" />
      </g>
    </svg>
  );
}
