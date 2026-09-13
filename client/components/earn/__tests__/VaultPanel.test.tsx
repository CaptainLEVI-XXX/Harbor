import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, it, expect, vi } from 'vitest';
import VaultPanel from '../VaultPanel';
const WEI = 10n ** 18n;
const TICKET = { requestedWei: 8n * WEI, fundedWei: 32n * WEI / 10n };
const EXIT_LIQUIDITY = { readyWei: 84240n * WEI / 100n, queuedAheadWei: 118n * WEI };
import { snapshotFixture } from '@/lib/harbor/__tests__/fixtures';

const PRICE = 1_041_200_000_000_000_000n;
/** the tab is also called Deposit; the action is the one that submits */
const action = () => document.querySelector('button.act') as HTMLButtonElement;

function panel(props: Partial<React.ComponentProps<typeof VaultPanel>> = {}) {
  return render(
    <VaultPanel
      connected={false}
      connectLabel="Connect wallet"
      onConnect={() => {}}
      ticket={null}
      priceWad={PRICE}
      liquidity={EXIT_LIQUIDITY}
      snapshot={snapshotFixture()}
      onSubmit={() => {}}
      {...props}
    />,
  );
}

describe('VaultPanel', () => {
  it('offers two tabs, each with two ways to say the amount', async () => {
    panel();
    expect(screen.getByLabelText('Amount to deposit')).toBeInTheDocument();
    expect(screen.getByLabelText('Shares to receive')).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: 'Withdraw' }));
    expect(screen.getByLabelText('Amount to withdraw')).toBeInTheDocument();
    expect(screen.getByLabelText('Shares to redeem')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Claim' })).toBeNull();
  });

  it('hides balances until a wallet is connected', () => {
    panel();
    expect(screen.getAllByText('Connect to see balance')).toHaveLength(2);
  });

  it('derives the other leg from what is typed', async () => {
    panel({ connected: true });
    await userEvent.type(screen.getByLabelText('Amount to deposit'), '10');
    // 10 ETH at 1.0412 per share = 9.6043 hWETH
    expect(screen.getByLabelText('Shares to receive')).toHaveValue('9.6043');
  });

  it('converts back the other way at share scale, not asset scale', async () => {
    panel({ connected: true });
    await userEvent.click(screen.getByRole('button', { name: 'Withdraw' }));
    await userEvent.type(screen.getByLabelText('Shares to redeem'), '10');
    // 10 hWETH at 1.0412 = 10.4120 ETH. Reading the input at 18 decimals
    // instead of 24 would give a figure a million times too large.
    expect(screen.getByLabelText('Amount to withdraw')).toHaveValue('10.4120');
  });

  it('mints exact shares when the shares are what was typed', async () => {
    const onSubmit = vi.fn();
    panel({ connected: true, onSubmit });
    await userEvent.type(screen.getByLabelText('Shares to receive'), '5');
    // the ETH leg is only an estimate of what previewMint will ask for
    expect(screen.getByLabelText('Amount to deposit')).toHaveValue('5.2060');
    await userEvent.click(action());
    expect(action()).toHaveTextContent(/^Deposit$/);
    expect(onSubmit).toHaveBeenCalledWith('mint', 5n * 10n ** 24n, false);
  });

  it('names the verb on the action, never the amount typed', async () => {
    panel({ connected: true });
    await userEvent.type(screen.getByLabelText('Amount to deposit'), '2.5');
    expect(action()).toHaveTextContent(/^Deposit$/);
  });

  it('shows partial funding and offers only the funded part', async () => {
    panel({ connected: true, ticket: TICKET });
    await userEvent.click(screen.getByRole('button', { name: 'Withdraw' }));
    expect(screen.getByText('3.2000 of 8.0000')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Claim' })).toBeInTheDocument();
    expect(screen.getByText(/4\.8000 ETH \(USD unavailable\) is still waiting/)).toBeInTheDocument();
  });

  it('says deposits are closed without naming a mechanism', () => {
    panel({ connected: true, paused: true });
    const action = screen.getByRole('button', { name: 'Deposits are closed' });
    expect(action).toBeDisabled();
    expect(document.body.textContent).not.toMatch(/stale|valuation|insolvent/i);
  });
});

describe('withdrawing', () => {
  it('requests exact shares when shares are typed', async () => {
    const onSubmit = vi.fn();
    panel({ connected: true, onSubmit });
    await userEvent.click(screen.getByRole('button', { name: 'Withdraw' }));
    await userEvent.type(screen.getByLabelText('Shares to redeem'), '2');
    await userEvent.click(screen.getByRole('button', { name: 'Request withdrawal' }));
    expect(onSubmit).toHaveBeenCalledWith('request', 2n * 10n ** 24n, false);
  });

  it('claims funded credit by exact ETH or by exact units', async () => {
    const onSubmit = vi.fn();
    const base = snapshotFixture();
    const snapshot = { ...base, account: { ...base.account!, pendingShares: 0n, fundedUnits: 4n * 10n ** 24n, claimableAssets: 4n * 10n ** 18n } };
    panel({ connected: true, onSubmit, snapshot, ticket: { requestedWei: 4n * 10n ** 18n, fundedWei: 4n * 10n ** 18n } });
    await userEvent.click(screen.getByRole('button', { name: 'Withdraw' }));
    await userEvent.type(screen.getByLabelText('Shares to redeem'), '1');
    await userEvent.click(screen.getByRole('button', { name: 'Claim' }));
    expect(onSubmit).toHaveBeenLastCalledWith('redeem', 10n ** 24n, false);
    await userEvent.clear(screen.getByLabelText('Shares to redeem'));
    await userEvent.type(screen.getByLabelText('Amount to withdraw'), '1.5');
    await userEvent.click(screen.getByRole('button', { name: 'Claim' }));
    expect(onSubmit).toHaveBeenLastCalledWith('claim', 15n * 10n ** 17n, false);
  });
});
