import type { ExitTicket } from './types';
import { ASSET_DECIMALS, SHARE_DECIMALS } from './types';
import { formatWeiFixed } from '@/lib/format';

export type Tab = 'deposit' | 'withdraw';

export type PanelState = 'visitor' | 'paused' | 'inFlight' | 'needsApproval' | 'idle' | 'entered';

export type PanelInput = {
  connected: boolean;
  /** whether the vault already has a WETH allowance from this wallet */
  approved: boolean;
  tab: Tab;
  /** WETH wei on the deposit tab, hWETH raw units on the withdraw tab */
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
  if (input.tab === 'deposit' && !input.approved) return 'needsApproval';
  return 'entered';
}

/**
 * The action always names what it is about to do.
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
      return funded > 0n
        ? `Claim ${formatWeiFixed(funded, ASSET_DECIMALS, 4)} WETH`
        : 'Waiting to be funded';
    }
    case 'needsApproval':
      return 'Approve WETH';
    case 'idle':
      return 'Enter an amount';
    case 'entered':
      return input.tab === 'deposit'
        ? `Deposit ${formatWeiFixed(input.amountWei, ASSET_DECIMALS, 4)} WETH`
        : `Request ${formatWeiFixed(input.amountWei, SHARE_DECIMALS, 4)} hWETH`;
  }
}

export function actionDisabled(state: PanelState): boolean {
  return state === 'idle' || state === 'paused';
}
