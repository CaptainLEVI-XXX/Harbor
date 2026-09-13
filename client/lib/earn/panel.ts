import type { ExitTicket } from './types';

export type Tab = 'deposit' | 'withdraw';

type PanelState = 'visitor' | 'paused' | 'inFlight' | 'idle' | 'entered';

type PanelInput = {
  connected: boolean;
  tab: Tab;
  /** ETH wei on the deposit tab, hWETH raw units on the withdraw tab */
  amountWei: bigint;
  ticket: ExitTicket | null;
  /** the vault is not accepting deposits. The reason is never surfaced. */
  paused: boolean;
};

/**
 * Order matters, and it is the order of what a person can do:
 * no wallet beats everything; a closed door beats what is behind it; an exit
 * already in flight beats starting another one.
 */
export function panelState(input: PanelInput): PanelState {
  if (!input.connected) return 'visitor';
  if (input.paused && input.tab === 'deposit') return 'paused';
  if (input.tab === 'withdraw' && input.ticket) return 'inFlight';
  if (input.amountWei === 0n) return 'idle';
  // Depositing ETH needs no allowance: the periphery is paid in the call itself.
  return 'entered';
}

/**
 * The action names the verb, not the amount: the panels above already show
 * the figure, and a button that restates it changes on every keystroke.
 *
 * On the withdraw tab it says Request, never Withdraw: withdrawing is
 * asynchronous, and a button that promises something synchronous is a lie the
 * user only discovers after signing.
 */
export function actionLabel(input: PanelInput, connectLabel: string): string {
  const state = panelState(input);
  switch (state) {
    case 'visitor':
      return connectLabel;
    case 'paused':
      return 'Deposits are closed';
    case 'inFlight': {
      const funded = input.ticket?.fundedWei ?? 0n;
      return funded > 0n ? 'Claim' : 'Waiting to be funded';
    }
    case 'idle':
      return 'Enter an amount';
    case 'entered':
      return input.tab === 'deposit' ? 'Deposit' : 'Request withdrawal';
  }
}

export function actionDisabled(state: PanelState): boolean {
  return state === 'idle' || state === 'paused';
}
