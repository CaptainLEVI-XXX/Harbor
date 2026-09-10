import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, it, expect } from 'vitest';
import VaultPanel from '../VaultPanel';
import { EXIT_LIQUIDITY, TICKET } from '@/lib/earn/fixtures';

const PRICE = 1_041_200_000_000_000_000n;

function panel(props: Partial<React.ComponentProps<typeof VaultPanel>> = {}) {
  return render(
    <VaultPanel
      connected={false}
      connectLabel="Connect wallet"
      onConnect={() => {}}
      ticket={null}
      priceWad={PRICE}
      liquidity={EXIT_LIQUIDITY}
      {...props}
    />,
  );
}

describe('VaultPanel', () => {
  it('offers two tabs, because a depositor makes two decisions', () => {
    panel();
    expect(screen.getByRole('button', { name: 'Deposit' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Withdraw' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Claim' })).toBeNull();
  });

  it('hides balances until a wallet is connected', () => {
    panel();
    expect(screen.getByText('Connect to see balance')).toBeInTheDocument();
  });

  it('derives the other leg from what is typed', async () => {
    panel({ connected: true });
    await userEvent.type(screen.getByLabelText('Amount to deposit'), '10');
    // 10 WETH at 1.0412 per share = 9.6043 hWETH
    expect(screen.getByText('9.6043 hWETH')).toBeInTheDocument();
  });

  it('converts back the other way at share scale, not asset scale', async () => {
    panel({ connected: true });
    await userEvent.click(screen.getByRole('button', { name: 'Withdraw' }));
    await userEvent.type(screen.getByLabelText('Amount to withdraw'), '10');
    // 10 hWETH at 1.0412 = 10.4120 WETH. Reading the input at 18 decimals
    // instead of 24 would give a figure a million times too large.
    expect(screen.getByText('10.4120 WETH')).toBeInTheDocument();
  });

  it('names the amount on the action once one is typed', async () => {
    panel({ connected: true });
    await userEvent.type(screen.getByLabelText('Amount to deposit'), '2.5');
    expect(screen.getByRole('button', { name: 'Deposit 2.5000 WETH' })).toBeInTheDocument();
  });

  it('shows partial funding and offers only the funded part', async () => {
    panel({ connected: true, ticket: TICKET });
    await userEvent.click(screen.getByRole('button', { name: 'Withdraw' }));
    expect(screen.getByText('3.2000 of 8.0000')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Claim 3.2000 WETH' })).toBeInTheDocument();
    expect(screen.getByText(/4\.8000 WETH is still waiting/)).toBeInTheDocument();
  });

  it('says deposits are closed without naming a mechanism', () => {
    panel({ connected: true, paused: true });
    const action = screen.getByRole('button', { name: 'Deposits are closed' });
    expect(action).toBeDisabled();
    expect(document.body.textContent).not.toMatch(/stale|valuation|insolvent/i);
  });
});
