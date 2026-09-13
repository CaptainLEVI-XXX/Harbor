import { BaseError, UserRejectedRequestError, encodeFunctionData, erc20Abi, erc721Abi, parseEventLogs, type Address, type Hex } from 'viem';
import { publicClient, TOKENS } from '@/lib/chain';
import type { Send } from '@/lib/wallet/types';
import { nftBookAbi, nftPeripheryAbi } from '@/lib/harbor/abis';
import { nftApproved } from '@/lib/harbor/nfts';
import { executorAbi, peripheryAbi } from '@/lib/harbor/abis';
import { HARBOR, requireNetwork } from '@/lib/harbor/config';
import { withinLimits, type ExecutableQuote } from '@/lib/harbor/quote';

import type { Call } from '@/lib/wallet/types';
export type Step = { kind: 'approve' | 'swap'; call: Call };
type Settlement = { amountIn: bigint; amountOut: bigint };

/** Native ETH funds the trade, so the cash leg never needs an allowance. */
function fundsWithETH(quote: ExecutableQuote) {
  return quote.trade.tokenIn.toLowerCase() === TOKENS.WETH;
}

/** What the trade may spend: the exact input, or the ceiling an exact output allows. */
function maximumInput(quote: ExecutableQuote) {
  return quote.trade.mode === 0 ? quote.trade.amountSpecified : quote.trade.limitAmount;
}

/**
 * One call, plus an allowance only when the customer is paying in a token.
 *
 * The periphery funds token execution and handles native wrapping/unwrapping.
 * ETH input needs no separate customer wrap transaction or token approval.
 */
export function buildSteps({ allowance, quote }: { allowance: bigint; quote: ExecutableQuote }): Step[] {
  const t = quote.trade;
  const maximum = maximumInput(quote);
  const swap: Step = { kind: 'swap', call: {
    to: HARBOR.periphery, account: t.receiver,
    value: fundsWithETH(quote) ? maximum : 0n,
    data: quote.nft ? encodeFunctionData({ abi: nftPeripheryAbi, functionName: 'executeNft', args: [HARBOR.book, quote.nft] }) : encodeFunctionData({ abi: peripheryAbi, functionName: 'execute', args: [HARBOR.book, t] }),
  } };
  if (fundsWithETH(quote) || allowance >= maximum) return [swap];
  return [{ kind: 'approve', call: { to: t.tokenIn, account: t.receiver,
    data: quote.nft ? encodeFunctionData({ abi: erc721Abi, functionName: 'approve', args: [HARBOR.periphery, quote.nft.tokenId] }) : encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [HARBOR.periphery, maximum] }),
  } }, swap];
}

/** The periphery spends the allowance, so that is the spender to read. */
function readAllowance(token: Address, owner: Address): Promise<bigint> {
  return publicClient.readContract({ address: token, abi: erc20Abi, functionName: 'allowance', args: [owner, HARBOR.periphery] });
}

/** The displayed intent is immutable during approval. Never silently accept worse limits. */
/** `submitted` fires once the swap itself is broadcast; an approval never frees the page. */
export async function executeQuote(quote: ExecutableQuote, send: Send, onStep: (step: Step) => void, upgradeAccount = false, submitted?: (hash: Hex) => void) {
  await requireNetwork();
  const t = quote.trade;
  const user = t.receiver;
  const maximum = maximumInput(quote);
  const allowance = fundsWithETH(quote) ? maximum : quote.nft ? (await nftApproved(quote.nft.tokenId,user) ? maximum : 0n) : await readAllowance(t.tokenIn, user);
  if (fundsWithETH(quote) && await publicClient.getBalance({ address: user }) <= maximum) {
    throw new Error('Insufficient ETH. Keep some ETH for gas.');
  }
  const steps = buildSteps({ allowance, quote });

  // An approval and the swap are independent of each other only in order, not in
  // intent: a wallet that can run them atomically should, so a customer is never
  // left holding an allowance for a trade that then did not happen.
  if (steps.length > 1) {
    await assertQuoteHolds(quote);
    const batch = await send.batch?.(steps.map(s => s.call), { upgradeAccount });
    if (batch) {
      onStep(steps[steps.length - 1]);
      const receipt = await publicClient.waitForTransactionReceipt({ hash: batch });
      if (receipt.status !== 'success') throw new Error('Swap batch reverted.');
      assertSettlement(quote, receipt.logs);
      return batch;
    }
  }

  let hash: Hex | undefined;
  for (const step of steps) {
    if ((await publicClient.getBlock()).timestamp >= t.deadline) throw new Error('Trade deadline passed. Refresh and confirm a new quote.');
    if (step.kind === 'swap') {
      await assertQuoteHolds(quote);
      if (quote.nft) await publicClient.call({to:step.call.to,data:step.call.data,value:step.call.value,account:user});
      else await publicClient.simulateContract({address:HARBOR.periphery,abi:peripheryAbi,functionName:'execute',args:[HARBOR.book,t],value:step.call.value,account:user});
    } else {
      await publicClient.call({ to: step.call.to, data: step.call.data, account: user });
    }
    onStep(step);
    hash = await send(step.call);
    if (step.kind === 'swap') submitted?.(hash);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== 'success') throw new Error(`${step.kind} reverted.`);
    if (step.kind === 'swap') assertSettlement(quote, receipt.logs);
  }
  return hash!;
}

async function assertQuoteHolds(quote: ExecutableQuote) {
  if ((await publicClient.getBlock()).timestamp >= quote.trade.deadline) throw new Error('Trade deadline passed. Refresh the quote.');
  if(quote.nft) {
    const a=await publicClient.readContract({address:HARBOR.book,abi:nftBookAbi,functionName:'quoteNft',args:[quote.nft]});
    if(!withinLimits(quote,a.traderIn,a.traderOut))throw Error('Price moved beyond your limits. Refresh the quote.');
    return;
  }
  const [input, output] = await publicClient.readContract({
    address: HARBOR.executor, abi: executorAbi, functionName: 'quoteSwap', args: [HARBOR.book, quote.trade],
  });
  if (!withinLimits(quote, input, output)) throw new Error('Price moved beyond your limits. Refresh the quote.');
}

/**
 * The settlement the VM emits names the periphery as trader, because the
 * periphery funded it. Token sales pay WETH to Periphery before unwrapping;
 * require its NativeTrade event as well to authenticate the final ETH caller.
 */
function assertSettlement(quote: ExecutableQuote, logs: Parameters<typeof parseEventLogs>[0]['logs']): Settlement {
  const t = quote.trade;
  if(quote.nft) {
    const n=quote.nft;
    const e=parseEventLogs({abi:nftPeripheryAbi,eventName:'NativeNftTrade',logs}).find(e=>e.address.toLowerCase()===HARBOR.periphery&&e.args.book.toLowerCase()===HARBOR.book&&e.args.caller.toLowerCase()===n.trader.toLowerCase()&&e.args.tokenId===n.tokenId&&e.args.route===n.route&&e.args.buyBase===(n.side===0)&&withinLimits(quote,e.args.input,e.args.output));
    if(!e)throw Error('Transaction confirmed without the expected NFT settlement. Check the explorer before retrying.');
    return {amountIn:e.args.input,amountOut:e.args.output};
  }
  const events = parseEventLogs({ abi: executorAbi, eventName: 'TradeExecuted', logs });
  const receiver = fundsWithETH(quote) ? t.receiver : HARBOR.periphery;
  const settled = events.find(e => e.address.toLowerCase() === HARBOR.executor && e.args.book.toLowerCase() === HARBOR.book && e.args.trader.toLowerCase() === t.trader.toLowerCase() && e.args.receiver.toLowerCase() === receiver.toLowerCase() && e.args.route === t.route && e.args.pricingVersion === t.pricingVersion && withinLimits(quote, e.args.amountIn, e.args.amountOut));
  if (!settled) throw new Error('Transaction confirmed without the expected harbor settlement event. Check the explorer before retrying.');
  if (!fundsWithETH(quote)) {
    const payout = parseEventLogs({ abi: peripheryAbi, eventName: 'NativeTrade', logs }).find(e =>
      e.address.toLowerCase() === HARBOR.periphery && e.args.book.toLowerCase() === HARBOR.book
      && e.args.caller.toLowerCase() === t.receiver.toLowerCase()
      && e.args.input === settled.args.amountIn && e.args.output === settled.args.amountOut && e.args.refund === 0n);
    if (!payout) throw new Error('Transaction confirmed without the expected native payout. Check the explorer before retrying.');
  }
  return { amountIn: settled.args.amountIn, amountOut: settled.args.amountOut };
}

export function isRejection(error: unknown): boolean {
  return error instanceof BaseError && error.walk(e => e instanceof UserRejectedRequestError) instanceof UserRejectedRequestError;
}
