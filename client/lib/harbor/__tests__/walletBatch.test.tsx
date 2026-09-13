import { renderHook } from '@testing-library/react';
import { beforeEach, expect, it, vi } from 'vitest';
import { useSend } from '@/lib/wallet/useSend';
import { USER } from './fixtures';
import { TOKENS } from '@/lib/chain';

const mock = vi.hoisted(() => ({ capabilities: vi.fn(), sendCalls: vi.fn(), status: vi.fn(), sendTransaction: vi.fn(), externalSend: vi.fn(), wallet: { address: '0x1234567890abcdef1234567890abcdef12345678', walletClientType: 'external', switchChain: vi.fn(), getEthereumProvider: vi.fn() } }));
vi.mock('@/lib/wallet/config', () => ({ privyConfigured: true }));
// fees are read from the chain; pin them so the call each wallet receives is exact
const FEES = { maxPriorityFeePerGas: 2_000_000_000n, maxFeePerGas: 4_000_000_000n };
vi.mock('@/lib/wallet/fees', () => ({ fastFees: () => Promise.resolve(FEES) }));
vi.mock('@privy-io/react-auth', () => ({ usePrivy: () => ({ user: { wallet: { address: mock.wallet.address } } }), useWallets: () => ({ wallets: [mock.wallet] }), useSendTransaction: () => ({ sendTransaction: mock.sendTransaction }) }));
vi.mock('viem', async actual => ({ ...await actual<typeof import('viem')>(), createWalletClient: () => ({ getCapabilities: mock.capabilities, sendCalls: mock.sendCalls, waitForCallsStatus: mock.status, sendTransaction: mock.externalSend }), custom: vi.fn() }));
beforeEach(() => {
  vi.clearAllMocks(); mock.wallet.walletClientType = 'external'; mock.capabilities.mockResolvedValue({ atomic: { status: 'supported' } });
  mock.wallet.address = USER;
  mock.sendCalls.mockResolvedValue({ id: 'batch-123' });
  mock.status.mockResolvedValue({ status: 'success', atomic: true, chainId: 560048, receipts: [{ status: 'success', transactionHash: '0x01' }] });
});
it('uses the connected provider for a normal external-wallet transaction', async () => {
  mock.externalSend.mockResolvedValueOnce('0x01');
  const { result } = renderHook(() => useSend());
  await expect(result.current(calls[0])).resolves.toBe('0x01');
  expect(mock.externalSend).toHaveBeenCalledWith({ to: TOKENS.WETH, data: '0xd0e30db0', value: 1n, ...FEES });
  expect(mock.sendTransaction).not.toHaveBeenCalled();
  expect(mock.sendCalls).not.toHaveBeenCalled();
});

it('rechecks the expected wallet after awaiting its provider', async () => {
  mock.wallet.getEthereumProvider.mockImplementationOnce(async () => { mock.wallet.address = TOKENS.WETH; return {}; });
  const { result } = renderHook(() => useSend());
  await expect(result.current(calls[0])).rejects.toThrow('Wallet changed');
  expect(mock.externalSend).not.toHaveBeenCalled();
  expect(mock.sendTransaction).not.toHaveBeenCalled();
});
it('sends an embedded wallet’s single calls through Privy’s own hook', async () => {
  mock.wallet.walletClientType = 'privy';
  mock.sendTransaction.mockResolvedValue({ hash: '0x01' });
  const { result } = renderHook(() => useSend());
  await expect(result.current(calls[0])).resolves.toBe('0x01');
  expect(mock.sendTransaction).toHaveBeenCalledWith({ to: TOKENS.WETH, data: '0xd0e30db0', value: 1n, ...FEES, chainId: 560048 }, { address: USER, sponsor: false });
  expect(mock.sendCalls).not.toHaveBeenCalled();
});

it('batches an embedded wallet that has already delegated under 7702', async () => {
  // Hoodi is past Pectra, so an embedded EOA can carry a delegation. If it
  // does, it batches like any other capable account - no new address, no 4337.
  mock.wallet.walletClientType = 'privy';
  const { result } = renderHook(() => useSend());
  await expect(result.current.batch!(calls)).resolves.toBe('0x01');
  expect(mock.capabilities).toHaveBeenCalled();
  expect(mock.sendCalls).toHaveBeenCalledWith({ calls: [{ to: TOKENS.WETH, data: '0xd0e30db0', value: 1n }], forceAtomic: true });
});

it('leaves an undelegated embedded wallet to the sequential path', async () => {
  mock.wallet.walletClientType = 'privy';
  mock.capabilities.mockResolvedValueOnce({ atomic: { status: 'ready' } });
  const { result } = renderHook(() => useSend());
  // "ready" means Harbor would have to upgrade the account first; that is the
  // user's decision to make, so we fall back rather than request it.
  await expect(result.current.batch!(calls)).resolves.toBeNull();
  expect(mock.sendCalls).not.toHaveBeenCalled();
});

it('upgrades a "ready" account only once the customer has accepted it', async () => {
  mock.capabilities.mockResolvedValue({ atomic: { status: 'ready' } });
  const { result } = renderHook(() => useSend());
  await expect(result.current.batch!(calls)).resolves.toBeNull();
  expect(mock.sendCalls).not.toHaveBeenCalled();
  // the same account, the same call, with consent
  await expect(result.current.batch!(calls, { upgradeAccount: true })).resolves.toBe('0x01');
  expect(mock.sendCalls).toHaveBeenCalledTimes(1);
});

it('never upgrades an account that the wallet says cannot batch at all', async () => {
  mock.capabilities.mockResolvedValue({});
  const { result } = renderHook(() => useSend());
  await expect(result.current.batch!(calls, { upgradeAccount: true })).resolves.toBeNull();
  expect(mock.sendCalls).not.toHaveBeenCalled();
});

it('reports what batching would cost this account, without doing anything', async () => {
  const { result } = renderHook(() => useSend());
  mock.capabilities.mockResolvedValueOnce({ atomic: { status: 'ready' } });
  await expect(result.current.atomic!()).resolves.toBe('ready');
  mock.capabilities.mockResolvedValueOnce({ atomic: { status: 'supported' } });
  await expect(result.current.atomic!()).resolves.toBe('supported');
  mock.capabilities.mockRejectedValueOnce(new Error('no 5792'));
  await expect(result.current.atomic!()).resolves.toBe('unsupported');
  expect(mock.sendCalls).not.toHaveBeenCalled();
  expect(mock.wallet.switchChain).not.toHaveBeenCalled();
});

it('rejects an intent for another wallet before requesting any signature', async () => {
  const { result } = renderHook(() => useSend());
  await expect(result.current({ ...calls[0], account: TOKENS.WETH })).rejects.toThrow('Wallet changed');
  await expect(result.current.batch!([{ ...calls[0], account: TOKENS.WETH }])).rejects.toThrow('Wallet changed');
  expect(mock.wallet.switchChain).not.toHaveBeenCalled();
  expect(mock.sendCalls).not.toHaveBeenCalled();
  expect(mock.sendTransaction).not.toHaveBeenCalled();
});

it('rejects non-atomic or wrong-chain confirmations without falling back', async () => {
  const { result } = renderHook(() => useSend());
  mock.status.mockResolvedValueOnce({ status: 'success', atomic: false, chainId: 560048, receipts: [{ status: 'success', transactionHash: '0x01' }] });
  await expect(result.current.batch!(calls)).rejects.toThrow('Check your wallet activity');
  mock.status.mockResolvedValueOnce({ status: 'success', atomic: true, chainId: 1, receipts: [{ status: 'success', transactionHash: '0x01' }] });
  await expect(result.current.batch!(calls)).rejects.toThrow('Check your wallet activity');
  expect(mock.sendTransaction).not.toHaveBeenCalled();
});
const calls = [{ to: TOKENS.WETH, account: USER, data: '0xd0e30db0' as const, value: 1n }];
it('requires atomic execution on an already-capable account', async () => {
  const { result } = renderHook(() => useSend());
  await expect(result.current.batch!(calls)).resolves.toBe('0x01');
  expect(mock.sendCalls).toHaveBeenCalledWith({ calls: [{ to: TOKENS.WETH, data: '0xd0e30db0', value: 1n }], forceAtomic: true });
});
it('does not upgrade an account that is only ready and never retries an uncertain submission', async () => {
  const { result } = renderHook(() => useSend());
  mock.capabilities.mockResolvedValueOnce({ atomic: { status: 'ready' } });
  await expect(result.current.batch!(calls)).resolves.toBeNull();
  expect(mock.sendCalls).not.toHaveBeenCalled();
  mock.status.mockRejectedValue(new Error('Timeout'));
  await expect(result.current.batch!(calls)).rejects.toThrow('Check your wallet activity');
  expect(mock.sendCalls).toHaveBeenCalledTimes(1);
  expect(mock.sendTransaction).not.toHaveBeenCalled();
});
