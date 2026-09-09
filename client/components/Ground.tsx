'use client';

import { useEffect, useRef } from 'react';
import { DESIGN } from '@/lib/design';
import { paintSheet, paintCell, paintPoppedCell, paintDentCell } from '@/lib/ground';
import { computeGeometry, cellAt, PopState, type GridGeometry } from '@/lib/grid';
import { spawnBurst, stepParticle, type Particle } from '@/lib/burst';

/** a cell that has been left: scale eases back to 1 and opacity to 0 over 420ms */
type Fading = { x: number; y: number; releasedAt: number; fromScale: number };
/** the cell under the pointer: scale springs toward 0.93, opacity rises over 120ms */
type Active = { x: number; y: number; scale: number; vel: number; enteredAt: number };

let burstUid = 0;
function burstCoinSvg(size: number): string {
  const id = ++burstUid;
  const pale = Math.random() < 0.45;
  const f = pale
    ? ['#F0EBFA', '#D6C9F0', '#B9A4E0']
    : ['#E7DFF7', '#B79FE2', '#8E6FC8'];
  return `<svg viewBox="0 0 120 150" width="${size}" height="${size * 150 / 120}">
    <defs>
      <linearGradient id="k${id}" x1=".9" y1="0" x2=".1" y2="1">
        <stop offset="0" stop-color="${f[0]}" stop-opacity=".48"/>
        <stop offset=".45" stop-color="${f[1]}" stop-opacity=".78"/>
        <stop offset="1" stop-color="${f[2]}" stop-opacity=".92"/>
      </linearGradient>
      <linearGradient id="m${id}" x1=".05" y1="0" x2=".9" y2="1">
        <stop offset="0" stop-color="#FFF"/>
        <stop offset=".55" stop-color="#DDD5EE"/>
        <stop offset="1" stop-color="#FFF"/>
      </linearGradient>
      <filter id="n${id}" x="-80%" y="-200%" width="260%" height="520%">
        <feGaussianBlur stdDeviation="4"/>
      </filter>
    </defs>
    <ellipse cx="59" cy="106" rx="33" ry="4.5" fill="#4A2F6B" opacity=".13" filter="url(#n${id})"/>
    <path d="M17 62 A43 27 0 0 0 103 62 L103 71 A43 27 0 0 1 17 71 Z" fill="url(#m${id})"/>
    <ellipse cx="60" cy="62" rx="43" ry="27" fill="url(#k${id})"/>
    <ellipse cx="60" cy="62" rx="43" ry="27" fill="none" stroke="#FFF" stroke-opacity=".85" stroke-width="2.6"/>
  </svg>`;
}

export default function Ground() {
  const baseRef = useRef<HTMLCanvasElement>(null);
  const dentRef = useRef<HTMLCanvasElement>(null);
  const burstRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const base = baseRef.current, dent = dentRef.current, burstLayer = burstRef.current;
    if (!base || !dent || !burstLayer) return;
    const stage = base.parentElement as HTMLElement | null;
    if (!stage) return;
    const bc = base.getContext('2d'), dc = dent.getContext('2d');
    if (!bc || !dc) return;

    const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    let geom: GridGeometry = { cols: 0, rows: 0, sp: 1, rad: 0 };
    let pops = new PopState(1, 1);
    let W = 0, H = 0;
    // the cell the pointer is in right now - held, springing down to 0.93
    let active: Active | null = null;
    const fading: Fading[] = [];
    const particles: { p: Particle; el: HTMLElement }[] = [];

    const paintAll = () => {
      bc.clearRect(0, 0, W, H);
      paintSheet(bc, W, H);
      for (let y = 0; y < geom.rows; y++) {
        for (let x = 0; x < geom.cols; x++) {
          if (pops.isPopped(x, y)) paintPoppedCell(bc, x, y, geom.sp, geom.rad, W, H);
          else paintCell(bc, x, y, geom.sp, geom.rad, W, H);
        }
      }
    };

    const repaintCell = (x: number, y: number) => {
      bc.save();
      bc.beginPath();
      bc.rect(x * geom.sp - 2, y * geom.sp - 2, geom.sp + 4, geom.sp + 4);
      bc.clip();
      paintSheet(bc, W, H);
      for (let j = -1; j <= 1; j++) {
        for (let i = -1; i <= 1; i++) {
          const nx = x + i, ny = y + j;
          if (nx < 0 || ny < 0 || nx >= geom.cols || ny >= geom.rows) continue;
          if (pops.isPopped(nx, ny)) paintPoppedCell(bc, nx, ny, geom.sp, geom.rad, W, H);
          else paintCell(bc, nx, ny, geom.sp, geom.rad, W, H);
        }
      }
      bc.restore();
    };

    const build = () => {
      W = stage.clientWidth; H = stage.clientHeight;
      if (!W || !H) return;
      geom = computeGeometry(W, H, DESIGN.referenceWidth, DESIGN.cell.size, DESIGN.cell.radiusRatio);
      pops = new PopState(geom.cols, geom.rows);
      for (const c of [base, dent]) {
        c.width = W * dpr; c.height = H * dpr;
        c.getContext('2d')!.setTransform(dpr, 0, 0, dpr, 0, 0);
      }
      paintAll();
    };

    build();
    const ro = new ResizeObserver(build);
    ro.observe(stage);

    /** the pointer left this cell - hand its current scale to the exit animation */
    const release = (cell: Active | null, at: number) => {
      if (cell) fading.push({ x: cell.x, y: cell.y, releasedAt: at, fromScale: cell.scale });
    };

    const onMove = (e: PointerEvent) => {
      if (reduceMotion) return;                    // no hover trail; popping still works
      if (e.pointerType !== 'mouse') return;        // crumbs gates hover on mouse only
      const b = stage.getBoundingClientRect();
      const cell = cellAt(e.clientX - b.left, e.clientY - b.top, geom);
      if (!cell || pops.isPopped(cell.x, cell.y)) return;
      // still inside the same cell: hold it, do not restart or decay anything
      if (active && active.x === cell.x && active.y === cell.y) return;
      const now = performance.now();
      release(active, now);
      active = { x: cell.x, y: cell.y, scale: 1, vel: 0, enteredAt: now };
    };

    const onDown = (e: PointerEvent) => {
      const b = stage.getBoundingClientRect();
      const cell = cellAt(e.clientX - b.left, e.clientY - b.top, geom);
      if (!cell || !pops.pop(cell.x, cell.y)) return;
      // a popped cell can no longer be dented
      if (active && active.x === cell.x && active.y === cell.y) active = null;
      repaintCell(cell.x, cell.y);
      const cx = (cell.x + 0.5) * geom.sp, cy = (cell.y + 0.5) * geom.sp;
      for (const p of spawnBurst(cx, cy, geom.sp, performance.now())) {
        const el = document.createElement('div');
        el.style.cssText = 'position:absolute;left:0;top:0;will-change:transform,opacity';
        el.innerHTML = burstCoinSvg(p.size);
        burstLayer.appendChild(el);
        particles.push({ p, el });
      }
    };

    const onLeave = () => { release(active, performance.now()); active = null; };

    stage.addEventListener('pointermove', onMove);
    stage.addEventListener('pointerdown', onDown);
    stage.addEventListener('pointerleave', onLeave);

    let raf = 0;
    let lastFrame = performance.now();
    const loop = (now: number) => {
      dc.clearRect(0, 0, W, H);
      // released cells: scale eases back to 1, opacity to 0, over 420ms easeOut
      for (let i = fading.length - 1; i >= 0; i--) {
        const f = fading[i];
        const t = (now - f.releasedAt) / DESIGN.motion.dentDecayMs;
        if (t >= 1) { fading.splice(i, 1); continue; }
        const e = 1 - Math.pow(1 - t, 3);                       // easeOut
        const sc = f.fromScale + (1 - f.fromScale) * e;
        paintDentCell(dc, f.x, f.y, geom.sp, geom.rad, 1 - e, W, H, sc);
      }
      // the cell under the pointer: spring toward 0.93, hold there
      if (active) {
        const { pressScale, pressSpringStiffness, pressSpringDamping, pressFadeInMs } = DESIGN.motion;
        const dt = Math.min(0.032, (now - lastFrame) / 1000);
        const a = -pressSpringStiffness * (active.scale - pressScale) - pressSpringDamping * active.vel;
        active.vel += a * dt;
        active.scale += active.vel * dt;
        const op = Math.min(1, (now - active.enteredAt) / pressFadeInMs);
        paintDentCell(dc, active.x, active.y, geom.sp, geom.rad, op, W, H, active.scale);
      }
      lastFrame = now;
      for (let i = particles.length - 1; i >= 0; i--) {
        const { p, el } = particles[i];
        const { settled } = stepParticle(p, now);
        el.style.transform =
          `translate(${p.x - p.size / 2}px, ${p.y - p.size / 2}px) rotate(${p.rot}deg)`;
        // settled coins leave the simulation but stay on screen, permanently
        if (settled) particles.splice(i, 1);
      }
      raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);

    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
      stage.removeEventListener('pointermove', onMove);
      stage.removeEventListener('pointerdown', onDown);
      stage.removeEventListener('pointerleave', onLeave);
    };
  }, []);

  return (
    <>
      <canvas ref={baseRef} className="layer" />
      <canvas ref={dentRef} className="layer" />
      <div ref={burstRef} className="layer" data-testid="burst-layer" />
    </>
  );
}
