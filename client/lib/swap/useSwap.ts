'use client';

import { useRef, useState } from 'react';
import type { Hex } from 'viem';
import { useSend } from '@/lib/wallet/useSend';
import { pending, type Deltas } from '@/lib/wallet/pending';
import { errorMessage } from '@/lib/harbor/config';
import type { ExecutableQuote } from '@/lib/harbor/quote';
import { executeQuote, isRejection, type Step } from './execute';

type SwapStatus = 'ready' | 'preparing' | 'approving' | 'swapping' | 'confirming' | 'swapped' | 'repriced' | 'failed';

const statusOf: Record<Step['kind'], SwapStatus> = { approve: 'approving', swap: 'swapping' };

/** what the trade moves, per asset, as the quote states it. A receipt is not a balance. */
function swapDeltas(quote: ExecutableQuote): Deltas {
  const token = quote.nft ? undefined : 'wstETH';
  return quote.input.direction === 'sell'
    ? { ETH: quote.receiveWei, ...(token && { [token]: -quote.payWei }) }
    : { ETH: -quote.payWei, ...(token && { [token]: quote.receiveWei }) };
}

/**
 * The page is held only while the wallet is still being asked. Once the swap
 * is broadcast the run is `confirming`: the button and the deck are free again,
 * and the outcome arrives as a notice when the block does.
 */
export function useSwap(quote: ExecutableQuote | undefined, onComplete: () => void, upgradeAccount = false) {
  const send = useSend();
  const active = useRef(false);
  const latest = useRef(0);
  const [run, setRun] = useState<{ status: SwapStatus; hash?: Hex; error?: string }>({ status: 'ready' });
  async function swap() {
    if (!quote || active.current) return;
    active.current = true;
    const id = ++latest.current;
    // a later run owns the notice; an earlier one still refreshes balances when it lands
    const mine = (next: typeof run) => { if (latest.current === id) setRun(next); };
    mine({ status: 'preparing' });
    let broadcast: Hex | undefined;
    try {
      const hash = await executeQuote(quote, send, step => mine({ status: statusOf[step.kind] }), upgradeAccount, submitted => {
        broadcast = submitted;
        active.current = false;
        pending.add(submitted, quote.trade.receiver, swapDeltas(quote));
        mine({ status: 'confirming', hash: submitted });
      });
      pending.settle(broadcast, true);
      mine({ status: 'swapped', hash });
      onComplete();
    } catch (error) {
      pending.settle(broadcast, false);
      mine(isRejection(error) ? { status: 'ready' } : { status: 'failed', error: errorMessage(error) });
    } finally { if (latest.current === id) active.current = false; }
  }
  const settled: SwapStatus[] = ['ready', 'confirming', 'swapped', 'failed', 'repriced'];
  return { ...run, swap, busy: !settled.includes(run.status) };
}
