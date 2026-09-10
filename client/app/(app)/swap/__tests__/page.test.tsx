import { act, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, it, expect, vi, beforeAll } from 'vitest';
import SwapPage from '../page';

vi.mock('@/components/PrivyProvider', () => ({
  useConnect: () => ({ label: 'Connect wallet', onConnect: vi.fn() }),
}));

beforeAll(() => {
  window.HTMLElement.prototype.scrollIntoView = vi.fn();
  window.HTMLElement.prototype.hasPointerCapture = vi.fn(() => false);
  window.HTMLElement.prototype.releasePointerCapture = vi.fn();
});

const receipts = () => userEvent.click(screen.getByRole('button', { name: 'Receipts' }));

describe('/swap', () => {
  it('opens on the Tokens surface', () => {
    render(<SwapPage />);
    expect(screen.getByRole('button', { name: 'Tokens' })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByLabelText('Amount you pay')).toBeInTheDocument();
  });

  it('derives the receive amount from the pay amount', async () => {
    render(<SwapPage />);
    const pay = screen.getByLabelText('Amount you pay');
    await userEvent.clear(pay);
    await userEvent.type(pay, '2');
    expect(screen.getByLabelText('Amount you receive')).toHaveValue('2.365751');
  });

  it('typing in the receive well sets exact output and derives the pay leg', async () => {
    render(<SwapPage />);
    const recv = screen.getByLabelText('Amount you receive');
    await userEvent.clear(recv);
    await userEvent.type(recv, '1');
    expect(screen.getByLabelText('Amount you receive')).toHaveValue('1');
    expect(screen.getByLabelText('Amount you pay')).not.toHaveValue('');
    // the accent follows the derived leg - under exact output that is the pay side
    expect(screen.getByText('You pay')).toBeInTheDocument();
    expect(screen.getByLabelText('Amount you pay')).toHaveClass('out');
    expect(screen.getByLabelText('Amount you receive')).not.toHaveClass('out');
  });

  it('refuses an amount above the book and names the limit', async () => {
    render(<SwapPage />);
    const pay = screen.getByLabelText('Amount you pay');
    await userEvent.clear(pay);
    await userEvent.type(pay, '99');
    expect(screen.getByText('Above the book')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Amount too large' })).toBeDisabled();
  });

  it('goes idle with an empty amount', async () => {
    render(<SwapPage />);
    await userEvent.clear(screen.getByLabelText('Amount you pay'));
    expect(screen.getByRole('button', { name: 'Enter an amount' })).toBeDisabled();
  });

  it('switches to Receipts and offers no amount input on the receipt side', async () => {
    render(<SwapPage />);
    await receipts();
    expect(screen.queryByLabelText('Amount you pay')).toBeNull();
    expect(screen.queryByLabelText('Amount you receive')).toBeNull();
    expect(screen.getByRole('button', { name: /18421/ })).toBeInTheDocument();
  });

  it('offers no exchange control on Receipts - the trade only goes one way', async () => {
    render(<SwapPage />);
    expect(screen.getByRole('button', { name: 'Reverse direction' })).toBeInTheDocument();
    await receipts();
    expect(screen.queryByRole('button', { name: 'Reverse direction' })).toBeNull();
  });

  it('gives exactly one whole receipt, never a fraction', async () => {
    render(<SwapPage />);
    await receipts();
    const row = screen.getByText('You give').closest('.qrow') as HTMLElement;
    expect(within(row).getByText('1 receipt · #18421')).toBeInTheDocument();
  });

  it('prices a receipt against its mark and shows the entitlement beside it', async () => {
    render(<SwapPage />);
    await receipts();
    expect(screen.getByText('3.937458 WETH')).toBeInTheDocument();   // mark less fee
    expect(screen.getByText('4.12 ETH')).toBeInTheDocument();        // entitlement
  });

  it('reprices when another receipt is chosen', async () => {
    render(<SwapPage />);
    await receipts();
    await userEvent.click(screen.getByRole('button', { name: /18422/ }));
    expect(screen.getByText('1.720877 WETH')).toBeInTheDocument();
  });

  it('reverses the pair', async () => {
    render(<SwapPage />);
    expect(screen.getByRole('combobox', { name: 'Pay asset' })).toHaveTextContent('wstETH');
    await userEvent.click(screen.getByRole('button', { name: 'Reverse direction' }));
    expect(screen.getByRole('combobox', { name: 'Pay asset' })).toHaveTextContent('WETH');
  });
});

describe('/swap quote states', () => {
  it('says a receipt is not quotable and that recovery is unaffected', async () => {
    render(<SwapPage />);
    await receipts();
    await userEvent.click(screen.getByRole('button', { name: /18990/ }));
    expect(screen.getByText('No quote available')).toBeInTheDocument();
    expect(screen.getByText(/does not affect recovery/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Not quotable' })).toBeDisabled();
  });

  it('shows no figures at all when there is no quote', async () => {
    render(<SwapPage />);
    await receipts();
    await userEvent.click(screen.getByRole('button', { name: /18990/ }));
    expect(screen.queryByText(/Conservative mark/)).toBeNull();
  });

  it('lets the quote expire and offers a refresh', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    try {
      render(<SwapPage />);
      expect(screen.getByRole('button', { name: 'Connect wallet' })).toBeInTheDocument();
      await act(() => vi.advanceTimersByTimeAsync(31_000));
      expect(screen.getByText('expired')).toBeInTheDocument();
      expect(screen.getByRole('button', { name: 'Refresh quote' })).toBeEnabled();
    } finally {
      vi.useRealTimers();
    }
  });
});

describe('the derived leg', () => {
  it('is blank rather than zero when nothing was quoted', async () => {
    render(<SwapPage />);
    const pay = screen.getByLabelText('Amount you pay');
    await userEvent.clear(pay);
    await userEvent.type(pay, '99');
    // 0 in the receive well would read as a price the vault had offered
    expect(screen.getByLabelText('Amount you receive')).toHaveValue('');
  });

  it('keeps the last figures visible once a quote expires', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    try {
      render(<SwapPage />);
      const before = (screen.getByLabelText('Amount you receive') as HTMLInputElement).value;
      expect(before).not.toBe('');
      await act(() => vi.advanceTimersByTimeAsync(31_000));
      expect(screen.getByText('expired')).toBeInTheDocument();
      expect(screen.getByLabelText('Amount you receive')).toHaveValue(before);
    } finally {
      vi.useRealTimers();
    }
  });
});
