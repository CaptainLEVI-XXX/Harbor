import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import SwapPage from '../page';

const send = vi.hoisted(() => vi.fn());

vi.mock('@/components/PrivyProvider', () => ({
  privyConfigured: true,
  useConnect: () => ({
    label: '0x1234…5678',
    address: '0x1234567890abcdef1234567890abcdef12345678',
    onConnect: vi.fn(),
  }),
}));

vi.mock('@/lib/wallet/useSend', () => ({ useSend: () => send }));

// no allowance yet, and every tx lands
vi.mock('@/lib/chain', async importActual => ({
  ...(await importActual<typeof import('@/lib/chain')>()),
  publicClient: {
    readContract: async () => 0n,
    waitForTransactionReceipt: async () => ({ status: 'success' }),
  },
}));

beforeEach(() => {
  send.mockReset();
});

describe('swapping', () => {
  it('approves and swaps on one click', async () => {
    send.mockResolvedValue('0xabc');
    render(<SwapPage />);
    await userEvent.click(screen.getByRole('button', { name: 'Swap' }));
    expect(await screen.findByRole('button', { name: 'Swapped' })).toBeDisabled();
    expect(send).toHaveBeenCalledTimes(2);
  });

  it('stops for a new price when the quote dies between approve and swap', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    try {
      // the approval lands with too little of the quote left to land the swap
      send.mockImplementationOnce(async () => {
        vi.advanceTimersByTime(25_000);
        return '0xabc';
      });
      render(<SwapPage />);
      const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
      await user.click(screen.getByRole('button', { name: 'Swap' }));
      expect(await screen.findByRole('button', { name: 'Confirm new price' })).toBeEnabled();
      expect(send).toHaveBeenCalledOnce();
    } finally {
      vi.useRealTimers();
    }
  });
});
