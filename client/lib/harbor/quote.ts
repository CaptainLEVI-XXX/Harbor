import { maxUint256, type Address, type Hex } from 'viem';
import { publicClient, TOKENS } from '@/lib/chain';
import { formatWei } from '@/lib/format';
import { bookAbi, executorAbi } from './abis';
import { HARBOR, requireNetwork } from './config';
import { explainCapacity } from './withdrawals';
import type { NftTrade } from './nfts';
import type { Direction, TradeMode } from '@/lib/swap/types';

export type Trade = {
  trader: Address; receiver: Address; tokenIn: Address; tokenOut: Address;
  route: bigint; side: 0 | 1; mode: 0 | 1; amountSpecified: bigint;
  limitAmount: bigint; deadline: bigint; pricingVersion: bigint;
  configVersion: bigint; strategyVersion: bigint;
};
export type QuoteInput = {
  amountWei: bigint; mode: TradeMode; direction: Direction;
  user?: Address; route?: bigint; receipt?: Address; tokenId?: bigint; slippageBps?: bigint;
};
export type ExecutableQuote = {
  nft?: NftTrade; trade: Trade; payWei: bigint; receiveWei: bigint; feeWei: bigint;
  blockNumber: bigint; blockHash: Hex; fetchedAt: number; refreshAt: number;
  orderHash: Hex; rate: string; input: QuoteInput;
};

/** The tolerance every quote carries. Not a control: one policy, stated in the quote. */
import { AUTO_SLIPPAGE_BPS, PREVIEW_ACCOUNT, QUOTE_LIFETIME_SECONDS, QUOTE_REFRESH_MS } from '@/lib/constants';
export { AUTO_SLIPPAGE_BPS } from '@/lib/constants';

/** Customer limits, not a second implementation of Harbor pricing. */
export function slippageLimit(mode: TradeMode, input: bigint, output: bigint, bps: bigint) {
  if (bps < 0n || bps > 500n) throw new Error('Slippage must be between 0 and 5%.');
  return mode === 'exactInput' ? output * (10_000n - bps) / 10_000n
    : (input * (10_000n + bps) + 9_999n) / 10_000n;
}

export async function readQuote(input: QuoteInput): Promise<ExecutableQuote> {
  if (input.amountWei <= 0n || input.amountWei > maxUint256) throw new Error('Enter a valid amount.');
  if (input.tokenId !== undefined) return (await import('./nfts')).readNftQuote(input);
  await requireNetwork();
  const block = await publicClient.getBlock();
  const route = input.route ?? HARBOR.inventoryRoute;
  const at = { address: HARBOR.book, abi: bookAbi, blockNumber: block.number } as const;
  const [p, configVersion, strategyVersion, stopped] = await Promise.all([
    publicClient.readContract({ ...at, functionName: 'pricingParameters', args: [route] }),
    publicClient.readContract({ ...at, functionName: 'configVersion' }),
    publicClient.readContract({ ...at, functionName: 'strategyVersion', args: [route] }),
    publicClient.readContract({ ...at, functionName: 'stopped' }),
  ]);
  if (stopped) throw new Error('Trading is paused.');
  if (p.version === 0n || p.validUntil <= block.timestamp) throw new Error('Pricing parameters need a fresh publication.');
  const base = input.receipt ?? TOKENS.wstETH;
  // A disconnected public quote uses a nonzero preview address; reconnecting
  // obtains a new quote with the actual receiver. No funds or allowance needed.
  const user = input.user ?? PREVIEW_ACCOUNT;
  // The periphery funds the trade and is therefore the trader the VM prices and
  // authorizes; the customer is the receiver, and only they can be paid out.
  // Quoting with any other trader would produce an order the periphery cannot run.
  const sell = input.direction === 'sell';
  const deadline = block.timestamp + QUOTE_LIFETIME_SECONDS < p.validUntil ? block.timestamp + QUOTE_LIFETIME_SECONDS : p.validUntil;
  const trade: Trade = {
    trader: HARBOR.periphery, receiver: user, tokenIn: sell ? base : TOKENS.WETH,
    tokenOut: sell ? TOKENS.WETH : base, route, side: sell ? 0 : 1,
    mode: input.mode === 'exactInput' ? 0 : 1, amountSpecified: input.amountWei,
    limitAmount: input.mode === 'exactInput' ? 0n : maxUint256, deadline,
    pricingVersion: p.version, configVersion, strategyVersion,
  };
  const quoteAt = { address: HARBOR.executor, abi: executorAbi, args: [HARBOR.book, trade], blockNumber: block.number } as const;
  // selling to the vault spends its cash, which a pending exit queue freezes
  const [[payWei, receiveWei, orderHash], breakdown] = await Promise.all([
    publicClient.readContract({ ...quoteAt, functionName: 'quoteSwap' }),
    publicClient.readContract({ ...quoteAt, functionName: 'quote' }),
  ]).catch(error => explainCapacity(error, sell));
  // VM is authoritative. Never silently display a divergent compatibility preview.
  if (payWei !== breakdown.traderIn || receiveWei !== breakdown.traderOut) throw new Error('Quote paths disagree. Trade disabled.');
  if (input.receipt && (sell ? payWei : receiveWei) !== 1n) throw new Error('A receipt trade must move exactly one whole unit.');
  trade.limitAmount = slippageLimit(input.mode, payWei, receiveWei, input.slippageBps ?? AUTO_SLIPPAGE_BPS);
  // Slippage belongs on the cash leg. Rounding one receipt down to zero, or
  // a maximum receipt input up to two, would misstate the user's permission.
  if (input.receipt && ((sell && input.mode === 'exactOutput') || (!sell && input.mode === 'exactInput'))) trade.limitAmount = 1n;
  const fetchedAt = Date.now();
  return {
    trade, payWei, receiveWei, feeWei: breakdown.fee,
    blockNumber: block.number, blockHash: block.hash, orderHash, fetchedAt,
    refreshAt: Math.min(fetchedAt + QUOTE_REFRESH_MS, Number(deadline) * 1000), input,
    rate: input.receipt ? 'One indivisible redemption right' : `1 ${sell ? 'wstETH' : 'ETH'} = ${formatWei(receiveWei * 10n ** 18n / payWei, 18)} ${sell ? 'ETH' : 'wstETH'}`,
  };
}

export function withinLimits(quote: ExecutableQuote, actualIn: bigint, actualOut: bigint) {
  const t = quote.trade;
  return t.mode === 0
    ? actualIn === t.amountSpecified && actualOut >= t.limitAmount
    : actualOut === t.amountSpecified && actualIn <= t.limitAmount;
}
