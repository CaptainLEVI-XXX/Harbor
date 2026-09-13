import { describe, expect, it, vi } from 'vitest';
import { fastFees } from '../fees';

const rpc = vi.hoisted(() => ({ getBlock: vi.fn(), estimateMaxPriorityFeePerGas: vi.fn() }));
vi.mock('@/lib/chain', async actual => ({ ...await actual<typeof import('@/lib/chain')>(), publicClient: rpc }));
const GWEI = 1_000_000_000n;

describe('fees for early inclusion', () => {
  it('tips at least the floor when the network suggests less', async () => {
    rpc.getBlock.mockResolvedValue({ baseFeePerGas: GWEI });
    rpc.estimateMaxPriorityFeePerGas.mockResolvedValue(GWEI / 10n);
    expect(await fastFees()).toEqual({ maxPriorityFeePerGas: 2n * GWEI, maxFeePerGas: 4n * GWEI });
  });

  it('triples a suggested tip above the floor, and survives two blocks of base-fee growth', async () => {
    rpc.getBlock.mockResolvedValue({ baseFeePerGas: 2n * GWEI });
    rpc.estimateMaxPriorityFeePerGas.mockResolvedValue(3n * GWEI);
    expect(await fastFees()).toEqual({ maxPriorityFeePerGas: 9n * GWEI, maxFeePerGas: 13n * GWEI });
  });
});
