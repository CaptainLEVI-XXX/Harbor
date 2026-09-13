import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it, vi } from 'vitest';
import SwapPage from '../page';
const quoteHook = vi.hoisted(() => vi.fn<(...args: unknown[]) => unknown>(() => ({ quote: { state: 'requesting', payWei: 0n, receiveWei: 0n, feeWei: 0n, rate: '', expiresAt: null }, executable: undefined })));
const display = vi.hoisted(() => ({ enabled: false }));
vi.mock('@/lib/harbor/DisplayPriceProvider', () => ({ useDisplayPrice: () => ({ prices: display.enabled ? { WETH: 2500n * 10n ** 18n, wstETH: 3000n * 10n ** 18n, fetchedAt: Date.now() } : null, usd: () => 'Reference USD' }) }));
const ctl = vi.hoisted(() => ({ address: undefined as string | undefined, atomic: null as string | null }));
vi.mock('@/lib/wallet', () => ({ privyConfigured: false, useSigner: () => null, truncateAddress: (a: string) => a, useConnect: () => ({ label: 'Connect wallet', onConnect: vi.fn(), address: ctl.address }) }));
const funder = vi.hoisted(() => vi.fn());
vi.mock('@/lib/harbor/withdrawals', () => ({ fundWithdrawals: funder }));
vi.mock('@/lib/harbor/useLiveQuote', () => ({ useLiveQuote: quoteHook }));
vi.mock('@/lib/harbor/useResource', () => ({ useResource: (key: string) => ({ loading: false, refresh: vi.fn(), data: key.startsWith('atomic:') ? ctl.atomic : key.startsWith('nfts:') ? { rows: [], truncated: false } : null }) }));
const run = vi.hoisted(() => ({ busy: false, status: 'ready' as string, hash: undefined as string | undefined, error: undefined as string | undefined }));
vi.mock('@/lib/swap/useSwap', () => ({ useSwap: () => ({ ...run, swap: vi.fn() }) }));
vi.mock('@/lib/wallet/useSend', () => ({ useSend: () => Object.assign(vi.fn(), { atomic: vi.fn() }) }));
describe('live swap interface', () => {
  it('preserves exact token wei when flipping units and converts typed dollars to tokens', async () => {
    display.enabled = true;
    try {
      render(<SwapPage />);
      const input = screen.getByLabelText('Amount you pay');
      await userEvent.clear(input); await userEvent.type(input, '1.000000000000000001');
      await userEvent.click(screen.getAllByRole('button', { name: 'Enter amount in dollars' })[0]);
      expect(quoteHook.mock.lastCall?.[0]).toMatchObject({ amountWei: 1000000000000000001n });
      await userEvent.click(screen.getByRole('button', { name: 'Enter amount in wstETH' }));
      expect(input).toHaveValue('1.000000000000000001');
      await userEvent.click(screen.getAllByRole('button', { name: 'Enter amount in dollars' })[0]);
      await userEvent.clear(input); await userEvent.type(input, '30');
      expect(quoteHook.mock.lastCall?.[0]).toMatchObject({ amountWei: 10n ** 16n });
    } finally { display.enabled = false; }
  });
  it('does not invent a received amount while a quote is loading', () => {
    render(<SwapPage />);
    expect(screen.getByLabelText('Amount you receive')).toHaveValue('');
    expect(screen.getByText(/canonical SwapVM/)).toBeInTheDocument();
  });
  it('switches direction and exactness without frontend pricing arithmetic', async () => {
    render(<SwapPage />);
    await userEvent.click(screen.getByRole('button', { name: 'Reverse direction' }));
    await userEvent.type(screen.getByLabelText('Amount you receive'), '2');
    expect(quoteHook.mock.lastCall?.[0]).toMatchObject({ direction: 'buy', mode: 'exactOutput', amountWei: 2n * 10n ** 18n });
  });
  it('does not present fixture receipts before connecting', async () => {
    render(<SwapPage />);
    await userEvent.click(screen.getByRole('button', { name: 'Receipts' }));
    expect(screen.getByText('Connect to see receipts')).toBeInTheDocument();
    expect(screen.queryByText(/18421/)).toBeNull();
    // the picker opens, but only to say why it is empty
    await userEvent.click(screen.getByRole('button', { name: 'Select a receipt' }));
    expect(screen.getByRole('dialog')).toHaveTextContent('Connect your wallet to see your receipts.');
    expect(screen.queryAllByRole('button', { name: /^#\d+/ })).toHaveLength(0);
    await userEvent.keyboard('{Escape}');
    expect(screen.queryByLabelText('Amount you pay')).toBeNull();
    expect(screen.queryByLabelText('Amount you receive')).toBeNull();
  });
  it('has nothing to buy and never offers a fractional receipt trade', async () => {
    render(<SwapPage />);
    await userEvent.click(screen.getByRole('button', { name: 'Receipts' }));
    await userEvent.click(screen.getByRole('button', { name: 'Reverse direction' }));
    expect(screen.getByText('Nothing in inventory')).toBeInTheDocument();
    // nothing is quoted until a whole receipt is chosen, in either direction
    expect(quoteHook.mock.lastCall?.[0]).toBeNull();
    await userEvent.click(screen.getByRole('button', { name: 'Reverse direction' }));
    expect(quoteHook.mock.lastCall?.[0]).toBeNull();
    expect(screen.queryByLabelText('Amount you pay')).toBeNull();
  });
});

describe('the one-transaction offer', () => {
  const USER = '0x1234567890abcdef1234567890abcdef12345678';
  afterEach(() => { ctl.address = undefined; ctl.atomic = null; });
  const offer = () => screen.queryByRole('checkbox');

  it('offers the upgrade only for a token-funded trade, the one two-call case', async () => {
    ctl.address = USER; ctl.atomic = 'ready';
    render(<SwapPage />);
    // selling wstETH means approve then swap
    expect(offer()).not.toBeNull();
    // paying in ETH needs no allowance, so there is nothing to join together
    await userEvent.click(screen.getByRole('button', { name: 'Reverse direction' }));
    expect(offer()).toBeNull();
  });

  it('never offers an upgrade the wallet cannot make, or one it does not need', () => {
    ctl.address = USER;
    for (const status of ['unsupported', 'supported', null]) {
      ctl.atomic = status;
      const { unmount } = render(<SwapPage />);
      expect(offer(), String(status)).toBeNull();
      unmount();
    }
  });

  it('does not offer an account upgrade to someone who has not connected', () => {
    ctl.atomic = 'ready';
    render(<SwapPage />);
    expect(offer()).toBeNull();
  });

  it('leaves the upgrade off until it is ticked', async () => {
    ctl.address = USER; ctl.atomic = 'ready';
    render(<SwapPage />);
    expect(offer()).not.toBeChecked();
    await userEvent.click(offer()!);
    expect(offer()).toBeChecked();
  });
});

describe('the outcome of a run', () => {
  afterEach(() => { run.busy = false; run.status = 'ready'; run.hash = undefined; run.error = undefined; });

  it('says nothing at all until a run has an outcome', () => {
    render(<SwapPage />);
    expect(screen.queryByRole('status')).toBeNull();
    expect(screen.queryByRole('alert')).toBeNull();
  });

  it('announces a landed swap with the transaction it landed as', async () => {
    run.status = 'swapped'; run.hash = '0xfeed';
    render(<SwapPage />);
    expect(screen.getByRole('status')).toHaveTextContent('Transaction completed');
    expect(screen.getByRole('link', { name: /View on explorer/ })).toHaveAttribute(
      'href', expect.stringContaining('0xfeed'),
    );
    // and it can be sent away
    await userEvent.click(screen.getByRole('button', { name: 'Dismiss notification' }));
    expect(screen.queryByRole('status')).toBeNull();
  });

  it('raises a failure rather than announcing one', () => {
    run.status = 'failed'; run.error = 'Reverted by the vault';
    render(<SwapPage />);
    expect(screen.getByRole('alert')).toHaveTextContent('Reverted by the vault');
    expect(screen.queryByRole('status')).toBeNull();
  });

  it('lightens the action button one step per phase, and only while running', () => {
    const { container, rerender } = render(<SwapPage />);
    expect(container.querySelector('.act')).not.toHaveAttribute('data-phase');
    for (const status of ['preparing', 'approving', 'swapping']) {
      run.busy = true; run.status = status;
      rerender(<SwapPage />);
      expect(container.querySelector('.act'), status).toHaveAttribute('data-phase', status);
      // and it cannot be pressed again mid-run
      expect(container.querySelector('.act'), status).toBeDisabled();
    }
  });
});

describe('unfunded withdrawals blocking a sale', () => {
  const unavailable = (extra: object) => ({ quote: { state: 'unavailable', payWei: 0n, receiveWei: 0n, feeWei: 0n, rate: '', expiresAt: null, reason: 'x', ...extra }, executable: undefined });
  afterEach(() => { ctl.address = undefined; quoteHook.mockReset(); funder.mockReset(); });

  it('offers funding only when the exit queue is the blocker', () => {
    quoteHook.mockReturnValue(unavailable({}));
    const { unmount } = render(<SwapPage />);
    expect(screen.queryByRole('button', { name: 'Fund withdrawals' })).toBeNull();
    unmount();
    ctl.address = '0x1234567890abcdef1234567890abcdef12345678';
    quoteHook.mockReturnValue(unavailable({ blocker: 'unfundedWithdrawals' }));
    render(<SwapPage />);
    expect(screen.getByRole('button', { name: 'Fund withdrawals' })).toBeEnabled();
    expect(screen.getByRole('button', { name: 'Waiting on withdrawals' })).toBeDisabled();
  });

  it('funds from the connected wallet, then announces what it reserved', async () => {
    ctl.address = '0x1234567890abcdef1234567890abcdef12345678';
    quoteHook.mockReturnValue(unavailable({ blocker: 'unfundedWithdrawals' }));
    funder.mockResolvedValue({ hash: '0xabc', tickets: 1, shares: 10n ** 22n, assets: 10n ** 16n, stillPending: 0n });
    render(<SwapPage />);
    await userEvent.click(screen.getByRole('button', { name: 'Fund withdrawals' }));
    expect(funder.mock.calls[0][0]).toBe(ctl.address);
    expect(await screen.findByText('Withdrawals funded')).toBeInTheDocument();
    expect(screen.getByText(/1 request · 0.01 ETH reserved for LPs · selling reopened/)).toBeInTheDocument();
  });
});
