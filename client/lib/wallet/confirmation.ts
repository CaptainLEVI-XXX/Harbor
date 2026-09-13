import type { Hex } from 'viem';
import { publicClient } from '@/lib/chain';
import type { Call, Send } from './types';

/**
 * Send, then wait for the block. `submitted` fires the moment the chain has the
 * transaction, so a page can stop waiting on a button and say "Confirming…".
 */
export async function sendConfirmed(call: Call, send: Send, submitted?: (hash: Hex) => void) {
  const hash = await send(call);
  submitted?.(hash);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') throw new Error('Transaction reverted.');
  return hash;
}
