import { beforeEach, describe, expect, it, vi } from 'vitest';
import { decodeFunctionData, encodeAbiParameters, encodeEventTopics, type Address } from 'viem';
import { runVaultAction } from '../vaultActions';
import { peripheryAbi, vaultAbi } from '../abis';
import { HARBOR } from '../config';
import { USER } from './fixtures';

const WAD = 10n ** 18n;
const rpc = vi.hoisted(() => ({ getChainId: vi.fn(), getBlockNumber: vi.fn(), getBalance: vi.fn(), readContract: vi.fn(), call: vi.fn(), simulateContract: vi.fn(), simulateCalls: vi.fn(), waitForTransactionReceipt: vi.fn() }));
vi.mock('@/lib/chain', async actual => ({ ...await actual<typeof import('@/lib/chain')>(), publicClient: rpc }));
beforeEach(() => {
  vi.clearAllMocks();
  rpc.getChainId.mockResolvedValue(560048);
  rpc.getBlockNumber.mockResolvedValue(42n);
  rpc.getBalance.mockResolvedValue(1000n * WAD);
  rpc.readContract.mockImplementation(async ({ functionName }) =>
    ({ maxDeposit: 1000n * WAD, maxMint: 1000n * 10n ** 24n, previewDeposit: 10n ** 24n, previewMint: 3n * WAD + 1n, maxWithdraw: 2n * WAD, maxRedeem: 2n * 10n ** 24n, isOperator: true, pendingRedeemRequest: 0n, claimableRedeemRequest: 0n }[functionName as string]));
  rpc.call.mockResolvedValue({});
  rpc.simulateContract.mockResolvedValue({});
  rpc.simulateCalls.mockResolvedValue({ results: [{ status: 'success', data: '0x' }, { status: 'success', data: '0x' }, { status: 'success', data: encodeAbiParameters([{ type: 'uint256' }], [WAD]) }] });
  rpc.waitForTransactionReceipt.mockResolvedValue({ status: 'success' });
});

describe('atomic request, FIFO funding and native payout', () => {
  const shares = 10n ** 24n;
  const wallet = () => Object.assign(vi.fn().mockResolvedValue('0x02'), {
    atomic: vi.fn().mockResolvedValue('supported'), batch: vi.fn().mockResolvedValue('0x01'),
  });
  const confirmed = (caller: Address = USER) => ({ status: 'success', logs: [{
    address: HARBOR.periphery,
    topics: encodeEventTopics({ abi: peripheryAbi, eventName: 'NativeWithdrawal', args: { caller, book: HARBOR.book } }),
    data: encodeAbiParameters([{ type: 'uint256' }, { type: 'uint256' }], [WAD, shares]),
  }] });

  it('uses funded share units, minimum ETH and the connected recipient in one batch', async () => {
    rpc.readContract.mockImplementation(async ({ functionName }) => functionName === 'isOperator' ? false : 0n);
    rpc.simulateCalls.mockResolvedValue({ results: [0, 1, 2].map(() => ({ status: 'success', data: '0x' })).concat([{ status: 'success', data: encodeAbiParameters([{ type: 'uint256' }], [WAD]) }]) });
    rpc.waitForTransactionReceipt.mockResolvedValue(confirmed());
    const send = wallet();
    await expect(runVaultAction('request', shares, USER, send, vi.fn())).resolves.toBe('0x01');
    const calls = send.batch.mock.calls[0][0];
    expect(calls.map((c: { account: string }) => c.account)).toEqual([USER, USER, USER, USER]);
    const decoded = calls.map((c: { to: string; data: `0x${string}` }) => decodeFunctionData({ abi: c.to === HARBOR.vault ? vaultAbi : peripheryAbi, data: c.data }));
    expect(decoded.map((d: { functionName: string }) => d.functionName)).toEqual(['requestRedeem', 'fulfillWithdrawals', 'setOperator', 'redeem']);
    expect(decoded[0].args).toEqual([shares, expect.stringMatching(new RegExp(USER, 'i')), expect.stringMatching(new RegExp(USER, 'i'))]);
    expect(decoded[1].args).toEqual([8n]);
    expect(decoded[3].args[1]).toBe(shares);
    expect(decoded[3].args[2]).toBe(WAD * 9750n / 10000n);
    expect(rpc.simulateCalls.mock.calls[0][0]).toMatchObject({ account: USER, blockNumber: 42n });
    expect(send).not.toHaveBeenCalled();
  });

  it.each(['partial FIFO funding', 'unsupported simulation RPC'])('queues safely before submission when %s prevents an immediate exit', async reason => {
    if (reason === 'partial FIFO funding') rpc.simulateCalls.mockResolvedValue({ results: [{ status: 'success' }, { status: 'success' }, { status: 'failure' }] });
    else rpc.simulateCalls.mockRejectedValue(new Error('Method not found'));
    const send = wallet();
    await runVaultAction('request', shares, USER, send, vi.fn());
    expect(send.batch).not.toHaveBeenCalled();
    expect(send).toHaveBeenCalledTimes(2);
    expect(send.mock.calls.map(([c]) => decodeFunctionData({ abi: vaultAbi, data: c.data }).functionName)).toEqual(['requestRedeem', 'fulfillWithdrawals']);
  });

  it('does not merge a previously funded claim into a new immediate withdrawal', async () => {
    rpc.readContract.mockImplementation(async ({ functionName }) => functionName === 'claimableRedeemRequest' ? shares : functionName === 'isOperator' ? true : 0n);
    const send = wallet();
    await runVaultAction('request', shares, USER, send, vi.fn());
    expect(rpc.simulateCalls).not.toHaveBeenCalled();
    expect(send.batch).not.toHaveBeenCalled();
  });

  it('requires upgrade consent and never queues again after an uncertain submitted batch', async () => {
    const send = wallet();
    send.atomic.mockResolvedValue('ready');
    await runVaultAction('request', shares, USER, send, vi.fn());
    expect(send.batch).not.toHaveBeenCalled();
    send.mockClear();
    send.batch.mockRejectedValue(new Error('Batch not confirmed'));
    await expect(runVaultAction('request', shares, USER, send, vi.fn(), true)).rejects.toThrow('Batch not confirmed');
    expect(send).not.toHaveBeenCalled();
  });

  it('rejects a successful transaction without this user’s native payout, without resubmitting', async () => {
    rpc.waitForTransactionReceipt.mockResolvedValue(confirmed(HARBOR.periphery));
    const send = wallet();
    await expect(runVaultAction('request', shares, USER, send, vi.fn())).rejects.toThrow('without the expected native payout');
    expect(send).not.toHaveBeenCalled();
  });
});

describe('vault transaction units and ownership', () => {
  it('does not repeat a mined request when its separate funding attempt fails', async () => {
    rpc.call.mockRejectedValue(new Error('ValuationUnavailable'));
    const send = Object.assign(vi.fn().mockResolvedValue('0x01'), { batch: vi.fn() });
    await expect(runVaultAction('request', 10n ** 24n, USER, send, vi.fn())).rejects.toThrow('Withdrawal request confirmed (0x01)');
    expect(send).toHaveBeenCalledTimes(1);
    expect(decodeFunctionData({ abi: vaultAbi, data: send.mock.calls[0][0].data }).functionName).toBe('requestRedeem');
  });

  it('rejects excess funded cash before granting operator permission', async () => {
    const send = Object.assign(vi.fn(), { batch: vi.fn() });
    await expect(runVaultAction('claim', 3n * WAD, USER, send, vi.fn())).rejects.toThrow('funded withdrawal');
    expect(send).not.toHaveBeenCalled();
    expect(send.batch).not.toHaveBeenCalled();
  });

  it('reauthorizes a revoked operator and never resends an uncertain claim batch', async () => {
    rpc.readContract.mockImplementation(async ({ functionName }) => functionName === 'isOperator' ? false : 2n * WAD);
    const send = Object.assign(vi.fn().mockResolvedValue('0x01'), { batch: vi.fn().mockResolvedValue(null) });
    await runVaultAction('claim', WAD, USER, send, vi.fn());
    const approval = decodeFunctionData({ abi: vaultAbi, data: send.mock.calls[0][0].data });
    expect(approval.functionName).toBe('setOperator');
    expect(approval.args?.[0]?.toString().toLowerCase()).toBe(HARBOR.periphery);
    expect(approval.args?.[1]).toBe(true);
    expect(decodeFunctionData({ abi: peripheryAbi, data: send.mock.calls[1][0].data }).functionName).toBe('withdraw');
    send.mockClear();
    send.batch.mockRejectedValue(new Error('Batch not confirmed'));
    await expect(runVaultAction('claim', WAD, USER, send, vi.fn(), true)).rejects.toThrow('Batch not confirmed');
    expect(send).not.toHaveBeenCalled();
  });

  it('reads the funded conversion ratio at one block, not the portfolio share price', async () => {
    const send = vi.fn().mockResolvedValue('0x01');
    await runVaultAction('redeem', 10n ** 24n, USER, send, vi.fn());
    const ratioReads = rpc.readContract.mock.calls.filter(([r]) => ['maxRedeem', 'maxWithdraw'].includes(r.functionName));
    expect(ratioReads).toHaveLength(2);
    expect(ratioReads.every(([r]) => r.blockNumber === 42n)).toBe(true);
  });
  it('pays ETH in and takes ETH out, with the vault only ever queueing shares', async () => {
    const send = Object.assign(vi.fn().mockResolvedValue('0x01'), { batch: vi.fn() });
    await runVaultAction('deposit', 2n * WAD, USER, send, vi.fn());
    await runVaultAction('request', 2n * 10n ** 24n, USER, send, vi.fn());
    await runVaultAction('claim', 19n * 10n ** 17n, USER, send, vi.fn());
    const [deposit, request, funding, claim] = send.mock.calls.map(([call]) => call);

    // in: native ETH to the periphery, never an ERC-20 transfer
    expect(deposit.to).toBe(HARBOR.periphery);
    expect(deposit.value).toBe(2n * WAD);
    expect(decodeFunctionData({ abi: peripheryAbi, data: deposit.data }).functionName).toBe('deposit');

    // queueing an exit is the customer's own shares, so it stays a vault call
    expect(request.to).toBe(HARBOR.vault);
    const queued = decodeFunctionData({ abi: vaultAbi, data: request.data });
    expect(queued.functionName).toBe('requestRedeem');
    expect(queued.args?.[0]).toBe(2n * 10n ** 24n);
    for (const arg of [queued.args?.[1], queued.args?.[2]]) expect(arg?.toString().toLowerCase()).toBe(USER);

    // out: the periphery unwraps and pays native ETH to the customer
    expect(funding.to).toBe(HARBOR.vault);
    expect(decodeFunctionData({ abi: vaultAbi, data: funding.data })).toMatchObject({ functionName: 'fulfillWithdrawals', args: [8n] });
    expect(funding.value).toBeUndefined();
    expect(claim.to).toBe(HARBOR.periphery);
    expect(claim.value).toBeUndefined();
    const claimed = decodeFunctionData({ abi: peripheryAbi, data: claim.data });
    expect(claimed.functionName).toBe('withdraw');
    expect(claimed.args?.[1]).toBe(19n * 10n ** 17n);
  });

  it('mints exact shares for exactly the ETH the vault previews', async () => {
    const send = Object.assign(vi.fn().mockResolvedValue('0x01'), { batch: vi.fn() });
    await runVaultAction('mint', 3n * 10n ** 24n, USER, send, vi.fn());
    const [mint] = send.mock.calls.map(([call]) => call);
    expect(mint.to).toBe(HARBOR.periphery);
    expect(mint.value).toBe(3n * WAD + 1n);
    const minted = decodeFunctionData({ abi: peripheryAbi, data: mint.data });
    expect(minted.functionName).toBe('mint');
    expect(minted.args?.[1]).toBe(3n * 10n ** 24n);
  });

  it('redeems exact funded units with a floor at the funded ratio', async () => {
    const send = Object.assign(vi.fn().mockResolvedValue('0x01'), { batch: vi.fn() });
    await runVaultAction('redeem', 10n ** 24n, USER, send, vi.fn());
    const redeemed = decodeFunctionData({ abi: peripheryAbi, data: send.mock.calls[0][0].data });
    expect(redeemed.functionName).toBe('redeem');
    expect(redeemed.args?.[1]).toBe(10n ** 24n);
    // one unit of two funded pays half the funded ETH, less the tolerance
    expect(redeemed.args?.[2]).toBe(WAD * 9750n / 10_000n);
  });

  it('does not send if the chain rejects the claim before it is signed', async () => {
    rpc.call.mockRejectedValue(new Error('Insufficient credit'));
    const send = Object.assign(vi.fn(), { batch: vi.fn() });
    await expect(runVaultAction('claim', 1n, USER, send, vi.fn())).rejects.toThrow('credit');
    expect(send).not.toHaveBeenCalled();
  });

  it('refuses a zero or negative amount before touching the chain', async () => {
    const send = Object.assign(vi.fn(), { batch: vi.fn() });
    await expect(runVaultAction('deposit', 0n, USER, send, vi.fn())).rejects.toThrow('positive');
    expect(send).not.toHaveBeenCalled();
  });
});

describe('reopening a vault whose mark went stale', () => {
  it('sends the permissionless checkpoint, with no amount and no value', async () => {
    const send = Object.assign(vi.fn().mockResolvedValue('0x01'), { batch: vi.fn() });
    await expect(runVaultAction('checkpoint', 0n, USER, send, vi.fn())).resolves.toBe('0x01');
    const call = send.mock.calls[0][0];
    expect(call.to).toBe(HARBOR.vault);
    expect(call.value).toBeUndefined();
    expect(decodeFunctionData({ abi: vaultAbi, data: call.data }).functionName).toBe('checkpointValuation');
    // a checkpoint carries no amount, so the positive-amount guard must not run
    expect(send.batch).not.toHaveBeenCalled();
  });

  it('does not send a checkpoint the chain would reject', async () => {
    rpc.simulateContract.mockRejectedValue(new Error('ValuationUnavailable'));
    const send = Object.assign(vi.fn(), { batch: vi.fn() });
    await expect(runVaultAction('checkpoint', 0n, USER, send, vi.fn())).rejects.toThrow('ValuationUnavailable');
    expect(send).not.toHaveBeenCalled();
  });
});
