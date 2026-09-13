export { ASSET_DECIMALS, SHARE_DECIMALS } from '@/lib/constants';

/** One band of a stacked chart: which series it is, and its shade. */
export type Band = { id: string; colour: string };

/** WETH wei per band at one instant; the total is the sum of the bands drawn. */
export type AllocationPoint = { at: number; totalWei: bigint; bands: bigint[] };

/** An LP exit in flight. Partial funding is the normal case, not an edge case. */
export type ExitTicket = {
  /** Estimate only; null when a fresh share conversion is unavailable. */
  requestedWei: bigint | null;
  fundedWei: bigint;
};

export type ExitLiquidity = {
  readyWei: bigint;
  queuedAheadWei: bigint;
};
