import { useState } from 'react';
import type { Address, Hex } from 'viem';
import { useSend } from '@/lib/wallet/useSend';
import { buildSteps, isRejection, readAllowance, runSteps } from './execute';
import type { Quote } from './types';

export type SwapStatus =
  | 'ready'
  | 'preparing'
  | 'approving'
  | 'swapping'
  | 'swapped'
  | 'repriced'
  | 'failed';

/** One block. A quote with less left than this cannot land in time. */
const BLOCK_MS = 12_000;

type Run = { quote: Quote | null; status: SwapStatus; hash?: Hex };

/** The click-to-Swapped flow for the quote on screen. */
export function useSwap(quote: Quote, onRepriced: () => void) {
  const send = useSend();
  const [run, setRun] = useState<Run>({ quote, status: 'ready' });

  // A status belongs to the quote it was reached with, so a new quote starts
  // fresh - except the re-quote a veto asked for (quote: null), which keeps it.
  if (run.quote !== quote) setRun({ quote, status: run.quote === null ? run.status : 'ready' });

  async function swap(token: Address, owner: Address) {
    // what was on screen at the click is what the user agreed to
    const clicked = quote;
    const expiresAt = clicked.expiresAt as number;
    const set = (status: SwapStatus, hash?: Hex) => setRun({ quote: clicked, status, hash });

    set('preparing');
    try {
      const allowance = await readAllowance(token, owner);
      const steps = buildSteps({ allowance, payWei: clicked.payWei, token });
      const hash = await runSteps(steps, send, step => {
        if (expiresAt - Date.now() < BLOCK_MS) return false;
        set(step.kind === 'approve' ? 'approving' : 'swapping');
        return true;
      });
      if (hash) return set('swapped', hash);
      setRun({ quote: null, status: 'repriced' });
      onRepriced();
    } catch (error) {
      if (isRejection(error)) return set('ready');
      console.error(error);
      set('failed');
    }
  }

  return { status: run.status, hash: run.hash, swap };
}
