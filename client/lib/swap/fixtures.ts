import type { Asset, Receipt } from './types';

export const ASSETS: Record<'wstETH' | 'WETH', Asset> = {
  wstETH: { symbol: 'wstETH', name: 'Wrapped staked ETH', decimals: 18 },
  WETH: { symbol: 'WETH', name: 'Wrapped ETH', decimals: 18 },
};

/**
 * wstETH -> WETH, scaled 1e18. Fixture only: a real rate arrives inside a
 * signed firm quote, never from the client.
 */
export const TOKEN_RATE_1E18 = 1184060000000000000n;

/** Harbor fee, in basis points of the output. */
export const FEE_BPS = 10n;

/** The largest single fill the vault's inventory will take, in wstETH wei. */
export const BOOK_LIMIT_WEI = 8400000000000000000n;

export const RECEIPTS: Receipt[] = [
  { requestId: 18421, entitlementWei: 4120000000000000000n, markWei: 3941400000000000000n, queuedDays: 6, state: 'pending' },
  { requestId: 18422, entitlementWei: 1800000000000000000n, markWei: 1722600000000000000n, queuedDays: 2, state: 'pending' },
  { requestId: 18987, entitlementWei: 12500000000000000000n, markWei: 11962500000000000000n, queuedDays: 11, state: 'pending' },
  { requestId: 19003, entitlementWei: 9000000000000000000n, markWei: null, queuedDays: 14, state: 'finalized' },
];
