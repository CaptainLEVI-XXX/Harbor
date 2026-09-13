import { publicClient } from '@/lib/chain';
import { PRIORITY_FEE_FLOOR, PRIORITY_FEE_MULTIPLE } from '@/lib/constants';

/**
 * Fees that put a transaction at the front of the next block: a multiple of the
 * suggested tip or the floor, whichever is higher, and a max fee that survives
 * two blocks of base-fee growth. Unused max fee is never charged.
 */
export async function fastFees() {
  const [block, suggested] = await Promise.all([
    publicClient.getBlock(),
    publicClient.estimateMaxPriorityFeePerGas().catch(() => 0n),
  ]);
  const boosted = suggested * PRIORITY_FEE_MULTIPLE;
  const maxPriorityFeePerGas = boosted > PRIORITY_FEE_FLOOR ? boosted : PRIORITY_FEE_FLOOR;
  return { maxPriorityFeePerGas, maxFeePerGas: (block.baseFeePerGas ?? 0n) * 2n + maxPriorityFeePerGas };
}
