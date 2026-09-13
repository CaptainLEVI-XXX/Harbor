import { beforeEach, describe, expect, it, vi } from 'vitest';
import { decodeFunctionData, encodeEventTopics, encodeAbiParameters, parseAbiParameters, erc20Abi } from 'viem';
import { peripheryAbi, vaultAbi, queueAbi as lidoHelperAbi } from '../abis';
import { fromUsdWad, toUsdWad, typedToWei } from '@/lib/price';
import { getWithdrawalNFT, getWstETH } from '../testnet';
import { runVaultAction } from '../vaultActions';
import { HARBOR } from '../config';
import { TOKENS } from '@/lib/chain';
import { USER } from './fixtures';

const rpc = vi.hoisted(() => ({ getChainId: vi.fn(), getBalance: vi.fn(), readContract: vi.fn(), call: vi.fn(), simulateContract: vi.fn(), waitForTransactionReceipt: vi.fn() }));
vi.mock('@/lib/chain', async actual => ({ ...await actual<typeof import('@/lib/chain')>(), publicClient: rpc }));
const WAD = 10n ** 18n;
beforeEach(() => {
  vi.clearAllMocks(); rpc.getChainId.mockResolvedValue(560048); rpc.getBalance.mockResolvedValue(10n * WAD);
  rpc.readContract.mockImplementation(async ({ functionName }) => ({ WSTETH: TOKENS.wstETH, MIN_STETH_WITHDRAWAL_AMOUNT: 100n, MAX_STETH_WITHDRAWAL_AMOUNT: 1000n * WAD, getStETHByWstETH: WAD, balanceOf: WAD, allowance: 0n, maxDeposit: WAD })[functionName as string]);
  rpc.call.mockResolvedValue({}); rpc.simulateContract.mockResolvedValue({});
  rpc.waitForTransactionReceipt.mockResolvedValue({ status: 'success', logs: [] });
});
describe('display conversion and user-funded testnet actions', () => {
  it('converts dollars in both directions without using floats or an executable-price assumption', () => {
    const prices = { WETH: 2500n * WAD, wstETH: 3000n * WAD, fetchedAt: Date.now() };
    expect(typedToWei('25', 'usd', 'WETH', 18, prices)).toBe(WAD / 100n);
    expect(toUsdWad(WAD / 100n, 'WETH', 18, prices)).toBe(25n * WAD);
    const dollars = 100n * WAD + 17n;
    const tokens = fromUsdWad(dollars, 'wstETH', 18, prices);
    expect(toUsdWad(tokens, 'wstETH', 18, prices)).toBeLessThanOrEqual(dollars);
    expect(toUsdWad(tokens + 1n, 'wstETH', 18, prices)).toBeGreaterThan(dollars);
    expect(typedToWei('25', 'usd', 'WETH')).toBe(0n);
  });
  it('sends only the chosen ETH amount to wstETH.receive and leaves gas', async () => {
    const send = vi.fn().mockResolvedValue('0x01');
    await getWstETH(WAD, USER, send);
    expect(send).toHaveBeenCalledWith({ to: TOKENS.wstETH, account: USER, data: '0x', value: WAD });
    expect(rpc.call).toHaveBeenCalledWith(send.mock.calls[0][0]);
    await expect(getWstETH(10n * WAD, USER, send)).rejects.toThrow('gas');
    expect(send).toHaveBeenCalledTimes(1);
  });
  it('approves the queue, requests one NFT for the user, and uses its actual event ID', async () => {
    const log = { address: HARBOR.queue, topics: encodeEventTopics({ abi: lidoHelperAbi, eventName: 'WithdrawalRequested', args: { requestId: 1234n, requestor: USER, owner: USER } }), data: encodeAbiParameters(parseAbiParameters('uint256,uint256'), [WAD, WAD]) };
    rpc.waitForTransactionReceipt.mockResolvedValue({ status: 'success', logs: [log] });
    const send = vi.fn().mockResolvedValue('0x01');
    const result = await getWithdrawalNFT(WAD, USER, send, vi.fn());
    const approval = decodeFunctionData({ abi: erc20Abi, data: send.mock.calls[0][0].data });
    expect(approval.args?.[0]?.toString().toLowerCase()).toBe(HARBOR.queue);
    expect(approval.args?.[1]).toBe(WAD);
    const request = decodeFunctionData({ abi: lidoHelperAbi, data: send.mock.calls[1][0].data });
    expect(request.functionName).toBe('requestWithdrawalsWstETH');
    expect(request.args?.[0]).toEqual([WAD]);
    expect(request.args?.[1]?.toString().toLowerCase()).toBe(USER);
    expect(result.requestId).toBe(1234n);
  });
  it('never retries an uncertain batch as separate transactions', async () => {
    const send = Object.assign(vi.fn().mockResolvedValue('0x01'), { batch: vi.fn().mockRejectedValue(new Error('Batch not confirmed')) });
    await expect(getWithdrawalNFT(WAD, USER, send, vi.fn())).rejects.toThrow('Batch');
    expect(send).not.toHaveBeenCalled();
  });

  it('deposits native ETH straight into the periphery, with a share floor', async () => {
    const send = Object.assign(vi.fn().mockResolvedValue('0x01'), { batch: vi.fn() });
    rpc.readContract.mockImplementation(async ({ functionName }) =>
      ({ maxDeposit: 10n * WAD, previewDeposit: 1000n }[functionName as string]));
    await runVaultAction('deposit', WAD, USER, send, vi.fn());
    const call = send.mock.calls[0][0];
    expect(call.to).toBe(HARBOR.periphery);
    expect(call.value).toBe(WAD);                          // the deposit IS the payment
    const decoded = decodeFunctionData({ abi: peripheryAbi, data: call.data });
    expect(decoded.functionName).toBe('deposit');
    expect(decoded.args?.[0]?.toString().toLowerCase()).toBe(HARBOR.book);
    expect(decoded.args?.[1]).toBe(975n);                  // previewDeposit less 2.50%
    expect(send.batch).not.toHaveBeenCalled();             // one call, nothing to batch
  });

  it('refuses a deposit past the cap or one that would leave no gas', async () => {
    const send = Object.assign(vi.fn(), { batch: vi.fn() });
    rpc.readContract.mockImplementation(async ({ functionName }) =>
      ({ maxDeposit: WAD / 2n, previewDeposit: 1000n }[functionName as string]));
    await expect(runVaultAction('deposit', WAD, USER, send, vi.fn())).rejects.toThrow('current limit');
    rpc.readContract.mockImplementation(async ({ functionName }) =>
      ({ maxDeposit: 100n * WAD, previewDeposit: 1000n }[functionName as string]));
    rpc.getBalance.mockResolvedValue(WAD);
    await expect(runVaultAction('deposit', WAD, USER, send, vi.fn())).rejects.toThrow('gas');
    expect(send).not.toHaveBeenCalled();
  });

  it('authorises the periphery once, then claims, atomically where it can', async () => {
    const send = Object.assign(vi.fn().mockResolvedValue('0x01'), { batch: vi.fn().mockResolvedValue('0xba7c4') });
    rpc.readContract.mockImplementation(async ({ functionName }) => ({ isOperator: false }[functionName as string]));
    await expect(runVaultAction('claim', WAD, USER, send, vi.fn())).resolves.toBe('0xba7c4');
    const calls = send.batch.mock.calls[0][0];
    expect(calls.map((c: { to: string }) => c.to)).toEqual([HARBOR.vault, HARBOR.periphery]);
    expect(decodeFunctionData({ abi: vaultAbi, data: calls[0].data }).functionName).toBe('setOperator');
    expect(decodeFunctionData({ abi: peripheryAbi, data: calls[1].data }).functionName).toBe('withdraw');
    expect(send).not.toHaveBeenCalled();
  });

  it('skips the authorisation entirely once the periphery is already an operator', async () => {
    const send = Object.assign(vi.fn().mockResolvedValue('0x01'), { batch: vi.fn() });
    rpc.readContract.mockImplementation(async ({ functionName }) => ({ isOperator: true }[functionName as string]));
    await runVaultAction('claim', WAD, USER, send, vi.fn());
    expect(send.batch).not.toHaveBeenCalled();
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][0].to).toBe(HARBOR.periphery);
  });
});
