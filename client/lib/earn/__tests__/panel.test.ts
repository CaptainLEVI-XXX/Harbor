import { describe, it, expect } from 'vitest';
import { panelState, actionLabel, actionDisabled } from '../panel';

const WEI = 10n ** 18n;
/** hWETH carries six more decimals than WETH. Withdraw amounts are typed in shares. */
const SHARE = 10n ** 24n;

const base = {
  connected: true,
  approved: true,
  tab: 'deposit' as const,
  amountWei: 0n,
  ticket: null,
  paused: false,
};

describe('panelState', () => {
  it('is visitor before a wallet is connected, whatever else is true', () => {
    expect(panelState({ ...base, connected: false, amountWei: 5n * WEI })).toBe('visitor');
  });

  it('is paused ahead of everything except the visitor case', () => {
    expect(panelState({ ...base, paused: true })).toBe('paused');
    expect(panelState({ ...base, connected: false, paused: true })).toBe('visitor');
  });

  it('is idle with no amount typed', () => {
    expect(panelState(base)).toBe('idle');
  });

  it('needs approval before the first deposit only', () => {
    expect(panelState({ ...base, approved: false, amountWei: WEI })).toBe('needsApproval');
    expect(panelState({ ...base, approved: false, amountWei: SHARE, tab: 'withdraw' })).toBe('entered');
  });

  it('shows an exit in flight on the withdraw tab', () => {
    const ticket = { requestedWei: 8n * WEI, fundedWei: 3n * WEI };
    expect(panelState({ ...base, tab: 'withdraw', ticket })).toBe('inFlight');
  });

  it('lets a holder with an exit in flight still deposit', () => {
    const ticket = { requestedWei: 8n * WEI, fundedWei: 3n * WEI };
    expect(panelState({ ...base, tab: 'deposit', ticket, amountWei: WEI })).toBe('entered');
  });
});

describe('actionLabel', () => {
  it('offers to connect a wallet when there is none', () => {
    expect(actionLabel({ ...base, connected: false }, 'Connect wallet')).toBe('Connect wallet');
  });

  it('asks for an amount before it will name one', () => {
    expect(actionLabel(base, 'Connect wallet')).toBe('Enter an amount');
  });

  it('names the amount it is about to move', () => {
    expect(actionLabel({ ...base, amountWei: (25n * WEI) / 10n }, 'x')).toBe('Deposit 2.5000 WETH');
  });

  it('says Request on the withdraw tab - never Withdraw, which promises something synchronous', () => {
    const label = actionLabel({ ...base, tab: 'withdraw', amountWei: 3n * SHARE }, 'x');
    expect(label).toBe('Request 3.0000 hWETH');
    expect(label).not.toContain('Withdraw');
  });

  it('offers the funded part of an exit, not the whole request', () => {
    const ticket = { requestedWei: 8n * WEI, fundedWei: (32n * WEI) / 10n };
    expect(actionLabel({ ...base, tab: 'withdraw', ticket }, 'x')).toBe('Claim 3.2000 WETH');
  });

  it('says deposits are closed without naming a mechanism', () => {
    const label = actionLabel({ ...base, paused: true }, 'x');
    expect(label).toBe('Deposits are closed');
    expect(label.toLowerCase()).not.toContain('mark');
    expect(label.toLowerCase()).not.toContain('stale');
  });
});

describe('actionDisabled', () => {
  it('blocks only the states with nothing to do', () => {
    expect(actionDisabled('idle')).toBe(true);
    expect(actionDisabled('paused')).toBe(true);
    expect(actionDisabled('visitor')).toBe(false);
    expect(actionDisabled('entered')).toBe(false);
    expect(actionDisabled('inFlight')).toBe(false);
    expect(actionDisabled('needsApproval')).toBe(false);
  });
});
