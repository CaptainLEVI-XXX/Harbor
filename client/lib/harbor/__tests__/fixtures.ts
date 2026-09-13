import type { ExecutableQuote } from '../quote';
import type { EarnSnapshot } from '../reads';
import { TOKENS } from '@/lib/chain';
import { HARBOR } from '../config';

export const USER = '0x1234567890abcdef1234567890abcdef12345678' as const;
export function quoteFixture(): ExecutableQuote {
  return {
    // the periphery funds every trade and the customer receives it
    trade: { trader: HARBOR.periphery, receiver: USER, tokenIn: TOKENS.wstETH, tokenOut: TOKENS.WETH, route: 0n, side: 0, mode: 0, amountSpecified: 1000n, limitAmount: 990n, deadline: 2000n, pricingVersion: 1n, configVersion: 2n, strategyVersion: 3n },
    input: { amountWei: 1000n, mode: 'exactInput', direction: 'sell', user: USER },
    payWei: 1000n, receiveWei: 1000n, feeWei: 0n, blockNumber: 42n,
    blockHash: `0x${'11'.repeat(32)}`, orderHash: `0x${'22'.repeat(32)}`,
    fetchedAt: Date.now(), refreshAt: Date.now() + 15_000, rate: '1 wstETH = 1 WETH',
  };
}
export function snapshotFixture(): EarnSnapshot {
  return { source: 'chain', blockNumber: 42n, blockHash: `0x${'11'.repeat(32)}`, timestamp: 1000n, shareDecimals: 24, supply: 10n ** 25n, nav: 10n ** 19n, sharePrice: 10n ** 18n, maxDeposit: 100n * 10n ** 18n,
    cash: 5n * 10n ** 18n, reservedAssets: 0n, totalPendingShares: 0n, valid: true, insolvent: false,
    account: { address: USER, balance: 10n ** 20n, operator: false, shares: 10n ** 25n, pendingShares: 0n, fundedUnits: 0n, claimableAssets: 0n, positionAssets: 10n ** 19n } };
}
