'use client';

import { useEffect, useRef } from 'react';
import { DESIGN } from '@/lib/design';
import Coin from './Coin';

export default function FloatingCoins() {
  const layerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const layer = layerRef.current;
    if (!layer) return;
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

    const nodes = Array.from(layer.children) as HTMLElement[];
    const { coinPeriodSeconds, coinDriftXPx, coinDriftYPx, coinRotateDeg } = DESIGN.motion;
    const omega = (2 * Math.PI) / coinPeriodSeconds;
    const start = performance.now();
    let raf = 0;

    const loop = (now: number) => {
      const t = (now - start) / 1000;
      nodes.forEach((node, i) => {
        const phase = i * 1.9;                       // phase-offset per coin
        const dx = Math.cos(omega * t + phase) * coinDriftXPx;
        const dy = Math.sin(omega * t + phase) * coinDriftYPx;
        const rot = Math.sin(omega * t * 0.8 + phase) * coinRotateDeg;
        node.style.transform = `translate(${dx}px, ${dy}px) rotate(${rot}deg)`;
      });
      raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(raf);
  }, []);

  return (
    <div ref={layerRef} className="layer">
      {DESIGN.coins.map((c, i) => (
        <div
          key={i}
          style={{
            position: 'absolute',
            left: `${c.leftPct}%`,
            top: `${c.topPct}%`,
            width: `${c.widthPct}%`,
          }}
        >
          <Coin pale={c.pale} rotation={c.rotationDeg} index={i} />
        </div>
      ))}
    </div>
  );
}
