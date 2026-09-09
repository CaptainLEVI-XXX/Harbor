import { DESIGN } from './design';

/**
 * The ground, rebuilt from crumbs' own source rather than from pixel analysis.
 * Their bundle exposes three layers and a hit test:
 *
 *   hit test        col = floor(x / 84), row = floor(y / 84)      -> 84px cells
 *   .glass-tile     background #eaf6e7
 *   .glass-tile-bloom   radial(58% 42% at 84% 8%,  #92f48499, transparent 68%)
 *                       radial(64% 48% at 10% 96%, #bef6b88c, transparent 72%)
 *   .glass-tile-relief  84x84 svg, rect x2 y2 w80 h80 rx25, fill 135deg
 *                       white .60 -> white .085 @50% -> rgb(120,200,115) .17
 *                       masked by radial(46% 38%, transparent 0, #0000004d 48%, #000 80%)
 *
 * Three things that differ from what was built by eye:
 *   - cells are 84px with rx 25 (29.8%), and the tile is 80x80 INSET 2px in its
 *     cell, so there is always a 4px gutter - they never tile edge to edge
 *   - the tile layer is explicitly MASKED so the pattern vanishes in the middle
 *     of the page; it is not merely alpha over a light ground
 *   - the ground is exactly two blooms, not a stack of washes
 */

export function roundedRect(
  ctx: CanvasRenderingContext2D,
  x: number, y: number, w: number, h: number, r: number,
): void {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

/** crumbs' relief mask: invisible at the centre, full strength past 80% */
export function maskAt(x: number, y: number, w: number, h: number): number {
  const d = Math.hypot((x - w / 2) / (w * 0.46), (y - h / 2) / (h * 0.38));
  if (d <= 0) return 0;
  if (d >= 0.80) return 1;
  if (d <= 0.48) return (d / 0.48) * 0.30;
  return 0.30 + ((d - 0.48) / 0.32) * 0.70;
}

export function paintSheet(ctx: CanvasRenderingContext2D, w: number, h: number): void {
  ctx.fillStyle = DESIGN.ground.sheet;
  ctx.fillRect(0, 0, w, h);

  // bloom 1 - top right, at their exact position and extent
  const tr = ctx.createRadialGradient(w * 0.84, h * 0.08, 0,
                                      w * 0.84, h * 0.08, Math.max(w * 0.58, h * 0.42));
  tr.addColorStop(0,    DESIGN.ground.bloomTopRight);
  tr.addColorStop(0.68, 'rgba(150,132,244,0)');
  ctx.fillStyle = tr; ctx.fillRect(0, 0, w, h);

  // bloom 2 - bottom left
  const bl = ctx.createRadialGradient(w * 0.10, h * 0.96, 0,
                                      w * 0.10, h * 0.96, Math.max(w * 0.64, h * 0.48));
  bl.addColorStop(0,    DESIGN.ground.bloomBottomLeft);
  bl.addColorStop(0.72, 'rgba(190,184,246,0)');
  ctx.fillStyle = bl; ctx.fillRect(0, 0, w, h);
}

/**
 * One relief tile: 80x80 inset 2px in an 84px cell, rx 25, filled with a 135deg
 * gradient. Its alpha is scaled by the page mask, so tiles fade out toward the
 * middle of the screen exactly as crumbs' mask-image does.
 */
export function paintCell(
  ctx: CanvasRenderingContext2D, gx: number, gy: number, sp: number, rad: number,
  w = 0, h = 0,
): void {
  const x = gx * sp, y = gy * sp;
  const inset = sp * (2 / 84);
  const m = w && h ? maskAt(x + sp / 2, y + sp / 2, w, h) : 1;
  if (m <= 0.001) return;

  ctx.save();
  ctx.globalAlpha = m;
  roundedRect(ctx, x + inset, y + inset, sp - inset * 2, sp - inset * 2, rad);
  ctx.clip();
  const g = ctx.createLinearGradient(x, y, x + sp, y + sp);
  g.addColorStop(0,   'rgba(255,255,255,.60)');
  g.addColorStop(0.5, 'rgba(255,255,255,.085)');
  g.addColorStop(1,   DESIGN.ground.reliefTint);
  ctx.fillStyle = g; ctx.fillRect(x, y, sp, sp);
  ctx.restore();
}

/** Popped: the relief is gone, leaving the bare sheet with a faint dimple. */
export function paintPoppedCell(
  ctx: CanvasRenderingContext2D, gx: number, gy: number, sp: number, rad: number,
  w = 0, h = 0,
): void {
  const x = gx * sp, y = gy * sp;
  const inset = sp * (2 / 84);
  const m = w && h ? maskAt(x + sp / 2, y + sp / 2, w, h) : 1;
  if (m <= 0.001) return;
  ctx.save();
  ctx.globalAlpha = m * 0.5;
  roundedRect(ctx, x + inset, y + inset, sp - inset * 2, sp - inset * 2, rad);
  ctx.clip();
  const g = ctx.createLinearGradient(x, y, x, y + sp * 0.4);
  g.addColorStop(0, 'rgba(116,94,166,.12)');
  g.addColorStop(1, 'rgba(116,94,166,0)');
  ctx.fillStyle = g; ctx.fillRect(x, y, sp, sp);
  ctx.restore();
}

/**
 * Hover, straight from `.glass-tile-press`:
 *   background   linear-gradient(135deg, dark .34 0%, mid .06 44%, white .95 100%)
 *   box-shadow   inset 0 3px 10px dark .30
 *                inset 0 -2px 1px  white .85
 *                0 0 22px accent .30
 *   84x84, border-radius 25 - a full-cell overlay.
 *
 * It DOES shrink, via framer-motion rather than CSS:
 *   initial    { opacity: 0, scale: 1 }
 *   animate    { opacity: 1, scale: .93 }
 *   exit       { opacity: 0, scale: 1, transition: { duration: .42, ease: easeOut } }
 *   transition { opacity: 120ms easeOut, scale: spring stiffness 420 damping 26 }
 * so entering springs down to 93% and leaving eases back to 100% over 420ms -
 * which is why moving between cells shows the old one growing back as the new
 * one shrinks. The caller drives `scale`; this function only draws it.
 */
export function paintDentCell(
  ctx: CanvasRenderingContext2D,
  gx: number, gy: number, sp: number, rad: number, alpha: number,
  w: number, h: number, scale = 1,
): void {
  const x = gx * sp, y = gy * sp;
  const k = sp / 84;                       // their values are authored at 84px
  ctx.save();
  ctx.globalAlpha = alpha;
  // framer applies `scale` about the element centre
  ctx.translate(x + sp / 2, y + sp / 2);
  ctx.scale(scale, scale);
  ctx.translate(-(x + sp / 2), -(y + sp / 2));

  // outer glow - 0 0 22px
  ctx.save();
  ctx.shadowColor = DESIGN.ground.pressGlow;
  ctx.shadowBlur = 22 * k;
  ctx.fillStyle = 'rgba(255,255,255,0.01)';
  roundedRect(ctx, x, y, sp, sp, rad); ctx.fill();
  ctx.restore();

  roundedRect(ctx, x, y, sp, sp, rad);
  ctx.clip();

  // the 135deg face
  const g = ctx.createLinearGradient(x, y, x + sp, y + sp);
  g.addColorStop(0,    DESIGN.ground.pressDark);
  g.addColorStop(0.44, DESIGN.ground.pressMid);
  g.addColorStop(1,    'rgba(255,255,255,.95)');
  ctx.fillStyle = g; ctx.fillRect(x, y, sp, sp);

  // inset 0 3px 10px - the shadow that makes it read pressed
  const top = ctx.createLinearGradient(x, y, x, y + 13 * k);
  top.addColorStop(0,   DESIGN.ground.pressInset);
  top.addColorStop(0.5, DESIGN.ground.pressInsetMid);
  top.addColorStop(1,   'rgba(70,56,96,0)');
  ctx.fillStyle = top; ctx.fillRect(x, y, sp, sp);

  // inset 0 -2px 1px - the light lip along the bottom
  const bot = ctx.createLinearGradient(x, y + sp, x, y + sp - 3 * k);
  bot.addColorStop(0, 'rgba(255,255,255,.85)');
  bot.addColorStop(1, 'rgba(255,255,255,0)');
  ctx.fillStyle = bot; ctx.fillRect(x, y, sp, sp);

  ctx.restore();
}
