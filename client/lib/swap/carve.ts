import { DESIGN } from '@/lib/design';

/**
 * The swap deck is two glass panels with the direction control CARVED OUT of
 * the seam between them - not a button laid over two rectangles. Each panel's
 * silhouette therefore has a real notch, and the lattice below stays visible
 * and continuous through the channel around the control.
 *
 * A notch cannot be expressed as a border-radius, so the silhouette is a path.
 * Everything that has to follow it - the frosted face, the luminous edge, the
 * shadow - is clipped or stroked with this same path, which is why it lives
 * here as a pure function rather than inside the component that draws it.
 */

export type Notch = 'top' | 'bottom' | null;

type Carve = {
  /** the panel's border box */
  w: number;
  h: number;
  /** outer corner radius */
  r: number;
  notch: Notch;
  /** the notch mouth, across the edge it is cut into */
  nw: number;
  /** how far the notch reaches into the panel */
  nh: number;
  /** the notch's own inner corner radius - the control's radius plus clearance */
  nr: number;
  /** the convex blend where the notch mouth meets the straight edge */
  fr: number;
};

/** the lattice's own corner: border-radius 25 on an 84px cell */
export const TILE_RADIUS = DESIGN.cell.radiusRatio;

const clamp = (v: number, lo: number, hi: number) => Math.min(Math.max(v, lo), hi);
/** two decimals is under a device pixel and keeps the `d` attribute short */
const n = (v: number) => Math.round(v * 100) / 100;

/**
 * No arc may be larger than the edge it has to fit on, or the path folds back
 * on itself and the silhouette inverts. Order matters: the depth bounds the
 * notch radius, which the mouth then bounds again.
 */
function fitCarve(c: Carve): Carve {
  const r = clamp(c.r, 0, Math.min(c.w, c.h) / 2);
  const nh = clamp(c.nh, 0, Math.max(0, c.h - r));
  const fr = clamp(c.fr, 0, nh / 2);
  const nw = clamp(c.nw, 0, Math.max(0, c.w - 2 * (r + fr) - 2));
  const nr = clamp(c.nr, 0, Math.min(nw / 2, nh - fr));
  return { ...c, r, nh, fr, nw, nr };
}

function plainRect(w: number, h: number, r: number): string {
  return [
    `M ${n(r)} 0`,
    `H ${n(w - r)}`, `A ${n(r)} ${n(r)} 0 0 1 ${n(w)} ${n(r)}`,
    `V ${n(h - r)}`, `A ${n(r)} ${n(r)} 0 0 1 ${n(w - r)} ${n(h)}`,
    `H ${n(r)}`, `A ${n(r)} ${n(r)} 0 0 1 0 ${n(h - r)}`,
    `V ${n(r)}`, `A ${n(r)} ${n(r)} 0 0 1 ${n(r)} 0`,
    'Z',
  ].join(' ');
}

/**
 * The silhouette, drawn clockwise in a y-down space. Convex corners sweep 1,
 * the notch's two reflex corners sweep 0 - that difference is the whole reason
 * the notch reads as carved rather than as an applied shape.
 */
export function carvePath(input: Carve): string {
  const c = fitCarve(input);
  const { w, h, r, nw, nh, nr, fr, notch } = c;
  if (!notch || nw <= 0 || nh <= 0) return plainRect(w, h, r);

  const x1 = w / 2 - nw / 2;   // the notch mouth's left lip
  const x2 = w / 2 + nw / 2;   // and its right lip

  if (notch === 'bottom') {
    return [
      `M ${n(r)} 0`,
      `H ${n(w - r)}`, `A ${n(r)} ${n(r)} 0 0 1 ${n(w)} ${n(r)}`,
      `V ${n(h - r)}`, `A ${n(r)} ${n(r)} 0 0 1 ${n(w - r)} ${n(h)}`,
      // right lip: the straight edge blends up into the notch wall
      `H ${n(x2 + fr)}`, `A ${n(fr)} ${n(fr)} 0 0 1 ${n(x2)} ${n(h - fr)}`,
      // the notch's own two corners, cut into the panel
      `V ${n(h - nh + nr)}`, `A ${n(nr)} ${n(nr)} 0 0 0 ${n(x2 - nr)} ${n(h - nh)}`,
      `H ${n(x1 + nr)}`, `A ${n(nr)} ${n(nr)} 0 0 0 ${n(x1)} ${n(h - nh + nr)}`,
      // left lip, back down to the straight edge
      `V ${n(h - fr)}`, `A ${n(fr)} ${n(fr)} 0 0 1 ${n(x1 - fr)} ${n(h)}`,
      `H ${n(r)}`, `A ${n(r)} ${n(r)} 0 0 1 0 ${n(h - r)}`,
      `V ${n(r)}`, `A ${n(r)} ${n(r)} 0 0 1 ${n(r)} 0`,
      'Z',
    ].join(' ');
  }

  return [
    `M ${n(r)} 0`,
    `H ${n(x1 - fr)}`, `A ${n(fr)} ${n(fr)} 0 0 1 ${n(x1)} ${n(fr)}`,
    `V ${n(nh - nr)}`, `A ${n(nr)} ${n(nr)} 0 0 0 ${n(x1 + nr)} ${n(nh)}`,
    `H ${n(x2 - nr)}`, `A ${n(nr)} ${n(nr)} 0 0 0 ${n(x2)} ${n(nh - nr)}`,
    `V ${n(fr)}`, `A ${n(fr)} ${n(fr)} 0 0 1 ${n(x2 + fr)} 0`,
    `H ${n(w - r)}`, `A ${n(r)} ${n(r)} 0 0 1 ${n(w)} ${n(r)}`,
    `V ${n(h - r)}`, `A ${n(r)} ${n(r)} 0 0 1 ${n(w - r)} ${n(h)}`,
    `H ${n(r)}`, `A ${n(r)} ${n(r)} 0 0 1 0 ${n(h - r)}`,
    `V ${n(r)}`, `A ${n(r)} ${n(r)} 0 0 1 ${n(r)} 0`,
    'Z',
  ].join(' ');
}

/**
 * Everything the panel is NOT, out to `margin` past its box. Filled with the
 * even-odd rule this is the region a drop shadow may occupy - which is how the
 * shadow follows the notch instead of a rectangle, without any of it landing
 * under the translucent face and dirtying the glass.
 */
export function aroundPath(input: Carve, margin = 160): string {
  const { w, h } = input;
  const ring = `M ${-margin} ${-margin} H ${n(w + margin)} V ${n(h + margin)} H ${-margin} Z`;
  return `${ring} ${carvePath(input)}`;
}

export type DeckGeometry = {
  /** the control's side: one lattice cell, so it reads as a tile lifted out */
  tile: number;
  /** the channel between the two panels */
  gap: number;
  /** visible page background left around the control */
  clear: number;
  /** the convex blend at the notch mouth */
  blend: number;
  /** the panels' outer corner radius */
  radius: number;
};

/**
 * The deck follows the proportions of a swap card, not of a page section:
 * roughly 480px across, so the trim scales off the DECK rather than off the
 * window. The control still wants to be a lattice cell - Ground's own
 * 84px-at-1413 cell - but on a card that narrow a full cell would swallow the
 * panel, so three limits bound it: a share of the deck, a share of the window
 * (the route is one viewport), and a floor that keeps it thumb-sized.
 */
export function deckGeometry(stageWidth: number, panelWidth: number, stageHeight = 0): DeckGeometry {
  const cell = (DESIGN.cell.size * stageWidth) / DESIGN.referenceWidth;
  const byDeck = panelWidth > 0 ? panelWidth * 0.135 : Infinity;
  const byWindow = stageHeight > 0 ? stageHeight * 0.12 : Infinity;
  const tile = Math.max(44, Math.min(cell, byDeck, byWindow));
  const snug = panelWidth > 0 && panelWidth < 380;
  return {
    tile,
    gap: snug ? 5 : 6,
    clear: snug ? 6 : 7,
    blend: snug ? 10 : 13,
    radius: snug ? 20 : 24,
  };
}

/** the notch one panel needs so the control clears it by `clear` on every side */
export function notchFor(g: DeckGeometry, w: number, h: number, notch: Notch): Carve {
  return {
    w, h,
    r: g.radius,
    notch,
    nw: g.tile + 2 * g.clear,
    nh: (g.tile - g.gap) / 2 + g.clear,
    nr: g.tile * TILE_RADIUS + g.clear,
    fr: g.blend,
  };
}
