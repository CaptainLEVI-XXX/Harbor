'use client';

import { useEffect, useId, useRef } from 'react';

/**
 * The Harbor symbol - "vessel and coin", variant 2d "fading rim" from the
 * Harbor Logo design. A C-shaped bowl open at the top holds a coin; the ring
 * steps through two lighter lavenders as it approaches the opening, so the C
 * dissolves rather than stops. It is the "o" of the harb-o-r wordmark.
 *
 * Geometry and motion are the design's; colours are ours (the design's
 * lavenders are mapped onto the site palette).
 *
 * Motion resolves once, then stops: the bowl starts tilted and rocks to rest
 * while the coin rolls inside it under gravity, never through the opening.
 */

const BOWL =
  'M -23.48 -44.15 A 50 50 0 1 0 23.48 -44.15 L 15.78 -29.67 A 33.64 33.64 0 1 1 -15.78 -29.67 Z';
const FADE_NEAR =
  'M -23.48 -44.15 A 50 50 0 0 0 -43.30 -25.00 L -29.13 -16.82 A 33.64 33.64 0 0 1 -15.80 -29.70 Z';
const FADE_FAR =
  'M -43.30 -25.00 A 50 50 0 0 0 -49.97 1.75 L -33.62 1.17 A 33.64 33.64 0 0 1 -29.13 -16.82 Z';

const SETTLE_S = 18;
const START_TILT = (-45 * Math.PI) / 180;
/** inner ring radius, coin radius, and the radius the coin's centre travels on */
const R_IN = 33.64;
const R_C = 21.8;
const RHO = 11.8;
const G = 356;
const C_REL = 1.25;
const C_ABS = 0.28;
/** the 56 degree opening the coin may never pass through */
const GAP_LO = (62 * Math.PI) / 180;
const GAP_HI = (118 * Math.PI) / 180;
const PHI_START = -Math.PI / 2 + 0.95;
const PHI_REST = -Math.PI / 2;

/** The bowl's tilt at time t: a damped rock that tapers to exactly 0 at SETTLE_S. */
function tilt(t: number): number {
  if (t >= SETTLE_S) return 0;
  const u = Math.min(1, Math.max(0, (t - (SETTLE_S - 2.2)) / 2.2));
  const taper = 1 - u * u * (3 - 2 * u);
  return (
    START_TILT *
    Math.exp(-t / (SETTLE_S / 5)) *
    Math.cos((2 * Math.PI * t) / (SETTLE_S / 9.5)) *
    taper
  );
}

type Pose = { tilt: number; phi: number; spin: number };

const deg = (rad: number) => (rad * 180) / Math.PI;
const bowlTransform = (p: Pose) => `rotate(${deg(-p.tilt).toFixed(3)})`;
const coinTransform = (p: Pose) =>
  `translate(${(RHO * Math.cos(p.phi)).toFixed(3)} ${(-RHO * Math.sin(p.phi)).toFixed(3)})`;
const spinTransform = (p: Pose) => `rotate(${deg(-p.spin).toFixed(2)})`;

const START: Pose = { tilt: tilt(0), phi: PHI_START, spin: 0 };
const REST: Pose = { tilt: 0, phi: PHI_REST, spin: 0 };

function useSettle(still: boolean) {
  const bowl = useRef<SVGGElement>(null);
  const coin = useRef<SVGGElement>(null);
  const spin = useRef<SVGGElement>(null);

  useEffect(() => {
    const paint = (p: Pose) => {
      bowl.current?.setAttribute('transform', bowlTransform(p));
      coin.current?.setAttribute('transform', coinTransform(p));
      spin.current?.setAttribute('transform', spinTransform(p));
    };

    if (still || window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      paint(REST);
      return;
    }

    let t = 0;
    let phi = PHI_START;
    let phiDot = 0;
    let psi = 0;
    let last: number | null = null;
    let raf = 0;

    const step = (dt: number) => {
      const h = 0.004;
      const tiltDot = (tilt(t + h) - tilt(t - h)) / (2 * h);
      const acc = -((2 * G) / (3 * RHO)) * Math.cos(phi) - C_REL * (phiDot - tiltDot) - C_ABS * phiDot;
      phiDot += acc * dt;
      phi += phiDot * dt;

      // keep the coin inside the arc - bounce it off the lips of the opening
      let a = phi % (2 * Math.PI);
      if (a < 0) a += 2 * Math.PI;
      if (a > GAP_LO && a < GAP_HI) {
        phi += (a - GAP_LO < GAP_HI - a ? GAP_LO : GAP_HI) - a;
        phiDot = -phiDot * 0.25;
      }

      psi += ((R_IN * tiltDot - RHO * phiDot) / R_C) * dt;
      t += dt;
    };

    const frame = (now: number) => {
      let left = Math.min(0.05, last === null ? 0 : (now - last) / 1000);
      last = now;
      while (left > 0) {
        const dt = Math.min(1 / 240, left);
        step(dt);
        left -= dt;
      }
      if (t >= SETTLE_S) return paint(REST);
      paint({ tilt: tilt(t), phi, spin: psi });
      raf = requestAnimationFrame(frame);
    };

    raf = requestAnimationFrame(frame);
    return () => cancelAnimationFrame(raf);
  }, [still]);

  return { bowl, coin, spin };
}

/**
 * `face="weth"` strikes the coin as WETH - the vault's own asset held in the
 * bowl - rather than badging a second logo beside the mark. It keeps the coin's
 * geometry and rolls with it, so the ticker settles upright with the coin.
 *
 * `still` draws it at rest from the first frame: a token mark repeated in
 * controls should not replay the settle every time it mounts.
 */
export default function HarborMark({ face = 'harbor', still = false }: { face?: 'harbor' | 'weth'; still?: boolean }) {
  const { bowl, coin, spin } = useSettle(still);
  const id = useId();
  const ink = `${id}-ink`;
  const coinFace = `${id}-face`;

  return (
    <svg
      viewBox="-55 -55 110 110"
      aria-hidden="true"
      style={{ filter: 'drop-shadow(0 3px 6px rgba(74,47,107,.26))' }}
    >
      <defs>
        {/* the site's lit ink, as the previous mark carried it */}
        <linearGradient id={ink} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#63428C" />
          <stop offset="0.55" stopColor="#4A2F6B" />
          <stop offset="1" stopColor="#3B2456" />
        </linearGradient>
        <radialGradient id={coinFace} cx="34%" cy="28%" r="78%">
          <stop offset="0" stopColor="#F0EBFA" />
          <stop offset="0.62" stopColor="#E4DBF3" />
          <stop offset="1" stopColor="#CBBEEA" />
        </radialGradient>
      </defs>

      <g ref={bowl} transform={bowlTransform(still ? REST : START)}>
        <path d={BOWL} fill={`url(#${ink})`} />
        <path d={FADE_NEAR} fill="#B097D8" />
        <path d={FADE_FAR} fill="#8B6BB8" />
      </g>

      <g ref={coin} transform={coinTransform(still ? REST : START)}>
        <g ref={spin}>
          {face === 'weth' ? <>
            <circle cx="-2.6" cy="0.6" r="21.8" fill="#EC1C79" />
            <circle r="21.8" fill="#FFF" stroke="#16121C" strokeWidth="2.4" />
            <text y="4.6" textAnchor="middle" fontFamily="Arial Black, Arial, sans-serif" fontWeight="900" fontSize="12.4" letterSpacing="-.4" fill="#16121C">WETH</text>
          </> : <>
            <circle cx="1.5" cy="1.9" r="21.8" fill="#4A2F6B" />
            <circle r="21.8" fill="#8E6FC8" />
            <circle r="20.2" fill={`url(#${coinFace})`} />
            <circle r="16.4" fill="none" stroke="#A98CD6" strokeWidth="2.8" />
          </>}
        </g>
      </g>
    </svg>
  );
}
