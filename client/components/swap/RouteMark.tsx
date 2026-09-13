/**
 * The same vessel-and-coin the browser tab carries (app/icon.svg), at rest and
 * at row scale: bowl, fading rim, coin. Flat fills, not the icon's gradients -
 * at 15px a gradient is one colour anyway, and flat paint needs no element ids
 * to collide with another instance on the page.
 */
export default function RouteMark() {
  return (
    <svg viewBox="-55 -55 110 110" className="routemark" aria-hidden="true">
      <path d="M -23.48 -44.15 A 50 50 0 1 0 23.48 -44.15 L 15.78 -29.67 A 33.64 33.64 0 1 1 -15.78 -29.67 Z" fill="#4A2F6B" />
      <path d="M -23.48 -44.15 A 50 50 0 0 0 -43.30 -25.00 L -29.13 -16.82 A 33.64 33.64 0 0 1 -15.80 -29.70 Z" fill="#B097D8" />
      <path d="M -43.30 -25.00 A 50 50 0 0 0 -49.97 1.75 L -33.62 1.17 A 33.64 33.64 0 0 1 -29.13 -16.82 Z" fill="#8B6BB8" />
      <g transform="translate(0 11.8)">
        <circle cx="1.5" cy="1.9" r="21.8" fill="#4A2F6B" />
        <circle r="21.8" fill="#8E6FC8" />
        <circle r="20.2" fill="#E4DBF3" />
        <circle r="16.4" fill="none" stroke="#A98CD6" strokeWidth="2.8" />
      </g>
    </svg>
  );
}
