import { chain } from '@/lib/chain';
import type { connectedClient } from './client';
import type { Atomic, BatchOptions, Call } from './types';

type Client = Awaited<ReturnType<typeof connectedClient>>;

/** Capabilities are wallet- and chain-specific; Pectra alone proves nothing. */
export async function atomicCapability(client: Client): Promise<Atomic> {
  try {
    const capabilities = await client.getCapabilities({ chainId: chain.id });
    const status = capabilities.atomic?.status;
    return status === 'supported' || status === 'ready' ? status : 'unsupported';
  } catch { return 'unsupported'; }
}

/** EIP-5792 delegates any 7702 upgrade to the wallet after explicit consent.
 * forceAtomic disables Viem's sequential fallback. Submitted or uncertain
 * batches must never be repeated as individual transactions.
 */
export async function sendAtomic(client: Client, calls: Call[], status: Atomic, options?: BatchOptions) {
  if (status === 'unsupported' || (status === 'ready' && !options?.upgradeAccount)) return null;
  let id: string | undefined;
  try {
    const result = await client.sendCalls({
      calls: calls.map(({ to, data, value }) => ({ to, data, value })), forceAtomic: true,
    });
    id = result.id;
    const confirmed = await client.waitForCallsStatus({ id, throwOnFailure: true, timeout: 120_000 });
    if (confirmed.status !== 'success' || !confirmed.atomic || confirmed.chainId !== chain.id
      || !confirmed.receipts?.length || confirmed.receipts.some(r => r.status !== 'success')) {
      throw new Error('Unverified batch result');
    }
    return confirmed.receipts[confirmed.receipts.length - 1].transactionHash;
  } catch {
    throw new Error(`Batch not confirmed. Check your wallet activity before retrying.${id ? ` Batch ID: ${id}` : ''}`);
  }
}
