export type GridGeometry = {
  cols: number;
  rows: number;
  sp: number;
  rad: number;
};

export function computeGeometry(
  width: number,
  height: number,
  referenceWidth: number,
  cellSize: number,
  radiusRatio: number,
): GridGeometry {
  const scale = width / referenceWidth;
  const sp = cellSize * scale;
  return {
    sp,
    rad: sp * radiusRatio,
    cols: Math.ceil(width / sp) + 1,
    rows: Math.ceil(height / sp) + 1,
  };
}

export function cellAt(
  px: number, py: number, geom: GridGeometry,
): { x: number; y: number } | null {
  const x = Math.floor(px / geom.sp);
  const y = Math.floor(py / geom.sp);
  if (x < 0 || y < 0 || x >= geom.cols || y >= geom.rows) return null;
  return { x, y };
}

/**
 * Pops are permanent by design (spec §9). There is deliberately no un-pop,
 * no cap and no eviction. Do not add one without changing the spec first.
 */
export class PopState {
  private readonly bits: Uint8Array;
  private popped = 0;

  constructor(private readonly cols: number, private readonly rows: number) {
    this.bits = new Uint8Array(cols * rows);
  }

  private inRange(x: number, y: number): boolean {
    return x >= 0 && y >= 0 && x < this.cols && y < this.rows;
  }

  isPopped(x: number, y: number): boolean {
    if (!this.inRange(x, y)) return false;
    return this.bits[y * this.cols + x] === 1;
  }

  pop(x: number, y: number): boolean {
    if (!this.inRange(x, y)) return false;
    const i = y * this.cols + x;
    if (this.bits[i] === 1) return false;
    this.bits[i] = 1;
    this.popped += 1;
    return true;
  }

  count(): number {
    return this.popped;
  }
}
