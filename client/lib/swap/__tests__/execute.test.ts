import { decodeFunctionData, erc20Abi } from 'viem';
import { describe, it, expect } from 'vitest';
import { buildSteps, MOCK_EXECUTOR } from '../execute';

const token = '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14';

describe('buildSteps', () => {
  it('approves exactly the pay amount, and only when the allowance falls short', () => {
    const [approve, swap] = buildSteps({ allowance: 1n, payWei: 5n, token });
    expect(approve.call.to).toBe(token);
    expect(decodeFunctionData({ abi: erc20Abi, data: approve.call.data }).args).toEqual([MOCK_EXECUTOR, 5n]);
    expect(swap.kind).toBe('swap');

    expect(buildSteps({ allowance: 5n, payWei: 5n, token }).map(s => s.kind)).toEqual(['swap']);
  });
});
