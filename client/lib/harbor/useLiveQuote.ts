'use client';

import { useEffect, useState } from 'react';
import { errorMessage } from './config';
import { readQuote, type QuoteInput, type ExecutableQuote } from './quote';
import { UnfundedWithdrawalsError } from './withdrawals';
import type { Quote } from '@/lib/swap/types';

const blank = (state: Quote['state'], reason?: string): Quote => ({ state, reason, payWei: 0n, receiveWei: 0n, feeWei: 0n, rate: '', expiresAt: null });

/** Debounce typing, coalesce identical inputs, invalidate immediately on identity change. */
export function useLiveQuote(input: QuoteInput | null, revision = 0) {
  const key = JSON.stringify(input, (_, v) => typeof v === 'bigint' ? v.toString() : v);
  const [result, setResult] = useState<{ key: string; quote: Quote; executable?: ExecutableQuote }>({ key: '', quote: blank('idle') });
  useEffect(() => {
    if (!input || input.amountWei <= 0n) return;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout>;
    async function refresh() {
      try {
        const executable = await readQuote(input!);
        if (!cancelled) {
          setResult({ key, executable, quote: { state: 'firm', payWei: executable.payWei, receiveWei: executable.receiveWei, feeWei: executable.feeWei, rate: executable.rate, expiresAt: executable.refreshAt } });
        }
      } catch (error) {
        if (!cancelled) setResult({ key, quote: { ...blank('unavailable', errorMessage(error)), blocker: error instanceof UnfundedWithdrawalsError ? 'unfundedWithdrawals' : undefined } });
      }
      if (!cancelled) timer = setTimeout(refresh, 15_000);
    }
    timer = setTimeout(refresh, 300);
    return () => { cancelled = true; clearTimeout(timer); };
    // key is the complete serialized input identity, not an object reference.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, revision]);
  if (!input || input.amountWei <= 0n) return { quote: blank('idle'), executable: undefined };
  return result.key === key ? result : { quote: blank('requesting'), executable: undefined };
}
