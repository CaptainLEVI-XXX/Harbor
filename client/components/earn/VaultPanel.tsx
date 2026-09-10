'use client';

import { useState } from 'react';
import ExitTracker from './ExitTracker';
import { actionDisabled, actionLabel, panelState, type Tab } from '@/lib/earn/panel';
import type { ExitLiquidity, ExitTicket } from '@/lib/earn/types';
import { ASSET_DECIMALS, SHARE_DECIMALS } from '@/lib/earn/types';
import { WALLET } from '@/lib/earn/fixtures';
import { formatWeiFixed, parseWei } from '@/lib/format';

const WAD = 10n ** 18n;
/** HarborVault._decimalsOffset(): shares carry six MORE decimals than assets. */
const OFFSET = 10n ** 6n;

type Props = {
  connected: boolean;
  connectLabel: string;
  onConnect: () => void;
  ticket: ExitTicket | null;
  /** WETH per hWETH, scaled 1e18 */
  priceWad: bigint;
  liquidity: ExitLiquidity;
  paused?: boolean;
};

/**
 * Two tabs, because a depositor makes two decisions - in, or out. Claim is a
 * step inside the exit, not a peer of Deposit: a third tab would be empty for
 * everyone with nothing in flight.
 */
export default function VaultPanel({
  connected,
  connectLabel,
  onConnect,
  ticket,
  priceWad,
  liquidity,
  paused = false,
}: Props) {
  const [tab, setTab] = useState<Tab>('deposit');
  const [typed, setTyped] = useState('');

  const depositing = tab === 'deposit';
  const amountWei = parseWei(typed, depositing ? ASSET_DECIMALS : SHARE_DECIMALS) ?? 0n;
  const input = { connected, approved: true, tab, amountWei, ticket, paused };
  const state = panelState(input);

  /**
   * Crossing the two scales, which is where this page is most likely to be
   * wrong. A share is not just an asset at a different price - it carries six
   * more decimals, so OFFSET is part of the conversion, not a fudge factor.
   */
  const derivedWei = depositing
    ? (amountWei * OFFSET * WAD) / priceWad // WETH (18) -> hWETH (24)
    : (amountWei * priceWad) / (OFFSET * WAD); // hWETH (24) -> WETH (18)
  const derived = depositing
    ? `${formatWeiFixed(derivedWei, SHARE_DECIMALS, 4)} hWETH`
    : `${formatWeiFixed(derivedWei, ASSET_DECIMALS, 4)} WETH`;

  const remaining = ticket ? ticket.requestedWei - ticket.fundedWei : 0n;

  function switchTo(next: Tab) {
    setTab(next);
    setTyped('');
  }

  return (
    <div className="panelcard modal">
      <div className="tabs well" role="group" aria-label="Deposit or withdraw">
        <button type="button" aria-pressed={depositing} onClick={() => switchTo('deposit')}>
          Deposit
        </button>
        <button type="button" aria-pressed={!depositing} onClick={() => switchTo('withdraw')}>
          Withdraw
        </button>
      </div>

      <div className="field well">
        <span className="flabel">{depositing ? 'You deposit' : 'You withdraw'}</span>
        <div className="amt">
          <input
            inputMode="decimal"
            placeholder="0.0"
            aria-label={depositing ? 'Amount to deposit' : 'Amount to withdraw'}
            value={typed}
            onChange={event => setTyped(event.target.value)}
          />
          <span className="asset">
            <i className={depositing ? 'tok-weth' : 'tok-hweth'}>{depositing ? 'W' : 'h'}</i>
            {depositing ? 'WETH' : 'hWETH'}
          </span>
        </div>
        <div className="fmeta">
          <span />
          <span>
            {connected ? (
              <>
                Balance{' '}
                <span className="num">
                  {depositing
                    ? formatWeiFixed(WALLET.wethWei, ASSET_DECIMALS, 4)
                    : formatWeiFixed(WALLET.sharesRaw, SHARE_DECIMALS, 4)}
                </span>{' '}
                {depositing ? 'WETH' : 'hWETH'}
              </>
            ) : (
              'Connect to see balance'
            )}
          </span>
        </div>
      </div>

      <div className="sec">
        <div className="qrow">
          <span>You receive</span>
          <span className="big num">{derived}</span>
        </div>
        {depositing ? (
          <>
            <div className="qrow">
              <span>hWETH price</span>
              <span>{formatWeiFixed(priceWad, 18, 4)} WETH</span>
            </div>
            <div className="qrow">
              <span>Harbor fee</span>
              <span>None</span>
            </div>
          </>
        ) : (
          <>
            <div className="qrow">
              <span>Ready to pay now</span>
              <span>{formatWeiFixed(liquidity.readyWei, ASSET_DECIMALS, 2)} WETH</span>
            </div>
            <div className="qrow">
              <span>Queued ahead of you</span>
              <span>{formatWeiFixed(liquidity.queuedAheadWei, ASSET_DECIMALS, 2)} WETH</span>
            </div>
          </>
        )}
      </div>

      {!depositing && ticket && <ExitTracker ticket={ticket} />}

      <button
        type="button"
        className="act"
        disabled={actionDisabled(state)}
        onClick={state === 'visitor' ? onConnect : undefined}
      >
        {actionLabel(input, connectLabel)}
      </button>

      <p className="foot">
        {state === 'paused'
          ? 'Withdrawing is unaffected.'
          : depositing
            ? 'Deposits settle immediately'
            : ticket && remaining > 0n
              ? `${formatWeiFixed(remaining, ASSET_DECIMALS, 4)} WETH is still waiting to be funded`
              : 'Funded oldest first · claim when ready'}
      </p>
    </div>
  );
}
