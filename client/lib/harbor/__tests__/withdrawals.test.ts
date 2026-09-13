import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ContractFunctionExecutionError, ContractFunctionRevertedError, decodeFunctionData, encodeAbiParameters, encodeEventTopics, parseAbi } from 'viem';
import { vaultAbi } from '../abis';
import { HARBOR } from '../config';
import { CAPACITY_EXCEEDED, explainCapacity, fundWithdrawals, UnfundedWithdrawalsError } from '../withdrawals';

const USER = '0x1234567890abcdef1234567890abcdef12345678';
const rpc = vi.hoisted(() => ({ getChainId: vi.fn(), readContract: vi.fn(), simulateContract: vi.fn(), waitForTransactionReceipt: vi.fn() }));
vi.mock('@/lib/chain', async actual => ({ ...await actual<typeof import('@/lib/chain')>(), publicClient: rpc }));

const state = { valid: false, pending: 5n, spendable: 0n, held: 10n, cash: 10n, after: 0n };
beforeEach(() => {
  vi.clearAllMocks();
  Object.assign(state, { valid: false, pending: 5n, spendable: 0n, held: 10n, cash: 10n, after: 0n });
  rpc.getChainId.mockResolvedValue(560048);
  let status = 0;
  rpc.readContract.mockImplementation(async ({ functionName }) => ({
    accountingStatus: status++ === 0 ? [state.cash, 0n, state.pending, state.valid, false] : [state.cash, 0n, state.after, true, false],
    tradingCash: state.spendable, balanceOf: state.held,
  }[functionName as string]));
  rpc.simulateContract.mockResolvedValue({});
});

const capacity = () => new ContractFunctionExecutionError(
  new ContractFunctionRevertedError({ abi: [], functionName: 'quoteSwap', data: CAPACITY_EXCEEDED }), { abi: [], functionName: 'quoteSwap' });

describe('the exit queue as a quote blocker', () => {
  it('names the queue only when it is what zeroes the vault\'s spendable cash', async () => {
    await expect(explainCapacity(capacity(), true)).rejects.toBeInstanceOf(UnfundedWithdrawalsError);
  });

  it('leaves other capacity limits, and trades the vault does not pay for, as they were', async () => {
    state.pending = 0n;
    await expect(explainCapacity(capacity(), true)).rejects.toBeInstanceOf(ContractFunctionExecutionError);
    state.pending = 5n;
    await expect(explainCapacity(capacity(), false)).rejects.toBeInstanceOf(ContractFunctionExecutionError);
  });
});

describe('funding withdrawals', () => {
  const event = parseAbi(['event WithdrawalFulfilled(uint256 indexed ticket, address indexed controller, uint256 shares, uint256 assets, uint256 valuationVersion, uint256 remaining)']);
  const log = { address: HARBOR.vault, topics: encodeEventTopics({ abi: event, eventName: 'WithdrawalFulfilled', args: { ticket: 0n, controller: USER } }), data: encodeAbiParameters([{ type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }], [5n, 7n, 1n, 0n]) };

  it('re-marks a stale vault, then funds up to eight tickets from the caller\'s wallet', async () => {
    rpc.waitForTransactionReceipt.mockResolvedValue({ status: 'success', logs: [log] });
    const send = vi.fn().mockResolvedValueOnce('0x01').mockResolvedValueOnce('0x02');
    const done = await fundWithdrawals(USER, send, vi.fn());
    const [checkpoint, fund] = send.mock.calls.map(([call]) => call);
    expect(decodeFunctionData({ abi: vaultAbi, data: checkpoint.data }).functionName).toBe('checkpointValuation');
    const funded = decodeFunctionData({ abi: vaultAbi, data: fund.data });
    expect(funded.functionName).toBe('fulfillWithdrawals');
    expect(funded.args).toEqual([8n]);
    expect([fund.to, fund.account, fund.value]).toEqual([HARBOR.vault, USER, undefined]);
    expect(done).toEqual({ hash: '0x02', tickets: 1, assets: 7n, stillPending: 0n });
  });

  it('skips the re-mark when the valuation is already fresh', async () => {
    state.valid = true;
    rpc.waitForTransactionReceipt.mockResolvedValue({ status: 'success', logs: [] });
    const send = vi.fn().mockResolvedValue('0x02');
    await fundWithdrawals(USER, send, vi.fn());
    expect(send).toHaveBeenCalledTimes(1);
  });

  it('does not sign when the chain rejects funding in simulation', async () => {
    state.valid = true;
    rpc.simulateContract.mockRejectedValue(new Error('ValuationUnavailable'));
    const send = vi.fn();
    await expect(fundWithdrawals(USER, send, vi.fn())).rejects.toThrow('ValuationUnavailable');
    expect(send).not.toHaveBeenCalled();
  });
});
