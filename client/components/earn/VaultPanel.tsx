'use client';

import { useState } from 'react';
import ExitTracker from './ExitTracker';
import AmountFlip from '@/components/AmountFlip';
import { actionDisabled, actionLabel, panelState, type Tab } from '@/lib/earn/panel';
import type { ExitLiquidity, ExitTicket } from '@/lib/earn/types';
import { ASSET_DECIMALS, SHARE_DECIMALS } from '@/lib/earn/types';
import type { EarnSnapshot } from '@/lib/harbor/reads';
import type { VaultAction } from '@/lib/harbor/vaultActions';
import { formatWeiFixed, group, parseWei } from '@/lib/format';
import { typedToWei, weiToTyped, type Unit } from '@/lib/price';
import { useDisplayPrice } from '@/lib/harbor/DisplayPriceProvider';
import { useResource } from '@/lib/harbor/useResource';
import TokenMark from '@/components/TokenMark';
import CarvedDeck from '@/components/swap/CarvedDeck';
import { useSend } from '@/lib/wallet/useSend';
import { usePending } from '@/lib/wallet/pending';

import { WAD, SHARE_OFFSET as OFFSET } from '@/lib/constants';

type Leg = 'top' | 'bottom';

type Props = {
  connected: boolean;
  connectLabel: string;
  onConnect: () => void;
  ticket: ExitTicket | null;
  /** ETH per hWETH, scaled 1e18; 0n when no price is known */
  priceWad: bigint;
  liquidity: ExitLiquidity;
  paused?: boolean;
  snapshot?: EarnSnapshot;
  onSubmit?: (action: VaultAction, amount: bigint, upgradeAccount: boolean) => void;
  busy?: string;
  error?: string;
};

/**
 * Two decisions, two tabs - and each has two ways to say it, one per panel.
 * The top panel is always ETH, the bottom always hWETH; whichever one you type
 * in is the exact side, and the call follows it:
 *
 *   Deposit   ETH typed -> deposit(assets)     hWETH typed -> mint(shares)
 *   Withdraw  ETH typed -> request ≈ shares    hWETH typed -> requestRedeem(shares)
 *   Claim     ETH typed -> withdraw(assets)    units typed -> redeem(units)
 *
 * A request is always in shares (the vault has no asset-denominated request),
 * so a typed ETH amount becomes an estimated share count. Once a request is
 * funded the same two panels claim it, at the ratio it was funded at.
 */
export default function VaultPanel({
  connected,
  connectLabel,
  onConnect,
  ticket,
  priceWad,
  liquidity,
  paused = false,
  snapshot,
  onSubmit,
  busy,
  error,
}: Props) {
  const [tab, setTab] = useState<Tab>('deposit');
  const [edited, setEdited] = useState<Leg>('top');
  const [typed, setTyped] = useState('');
  const [chosenUnit, setChosenUnit] = useState<Unit>('token');
  const [canonical, setCanonical] = useState<bigint>();
  const [upgradeAccount, setUpgradeAccount] = useState<string | null>(null);
  const { prices, usd } = useDisplayPrice();
  const send = useSend();
  // A wallet may batch a full native exit or operator approval plus an existing claim.
  // Capability discovery is read-only; a new delegation still needs explicit consent.
  const atomic = useResource(`atomic:${snapshot?.account?.address ?? 'none'}`, () => snapshot?.account && send.atomic ? send.atomic() : Promise.resolve(null));

  const depositing = tab === 'deposit';
  const wallet = snapshot?.account;
  const inflight = usePending(wallet?.address);
  /** a balance as it will be once pending transactions land */
  const ahead = (held: bigint, asset: 'ETH' | 'hWETH') => { const v = held + inflight.delta(asset); return v > 0n ? v : 0n; };
  const pendingMark = (asset: 'ETH' | 'hWETH') => inflight.delta(asset) ? ' · pending' : '';
  const oneTx = Boolean(wallet) && upgradeAccount === wallet?.address;
  const claiming = !depositing && Boolean(ticket) && (wallet?.claimableAssets ?? 0n) > 0n && (wallet?.fundedUnits ?? 0n) > 0n;
  // dollars are a way to type an ETH amount, so only the ETH panel has them
  const unit: Unit = edited === 'top' ? chosenUnit : 'token';
  const typedWei = edited === 'top'
    ? (unit === 'usd' && !prices ? 0n : canonical ?? typedToWei(typed, unit, 'ETH', ASSET_DECIMALS, prices))
    : (parseWei(typed, SHARE_DECIMALS) ?? 0n);

  /**
   * Crossing the two scales, which is where this page is most likely to be
   * wrong. A share is not just an asset at a different price - it carries six
   * more decimals, so OFFSET is part of the conversion, not a fudge factor.
   * Funded credit is the exception: it converts at its own funded ratio.
   */
  const funded = { assets: wallet?.claimableAssets ?? 0n, units: wallet?.fundedUnits ?? 0n };
  const priced = priceWad > 0n;
  const toShares = (wei: bigint) => claiming ? (wei * funded.units + funded.assets - 1n) / funded.assets
    : priced ? (wei * OFFSET * WAD) / priceWad : null;
  const toEth = (shares: bigint) => claiming ? shares * funded.assets / funded.units
    : priced ? (depositing ? shares * priceWad + OFFSET * WAD - 1n : shares * priceWad) / (OFFSET * WAD) : null;
  const ethWei = edited === 'top' ? typedWei : toEth(typedWei);
  const sharesWei = edited === 'top' ? toShares(typedWei) : typedWei;
  const entered = typed !== '' && typedWei > 0n;

  const primary = (depositing ? ethWei : sharesWei) ?? 0n;
  const input = { connected, tab, amountWei: primary, ticket, paused };
  const offerUpgrade = Boolean(wallet) && !depositing && atomic.data === 'ready'
    && (claiming ? !wallet?.operator : !ticket);
  const state = panelState(input);
  const remaining = ticket?.requestedWei != null ? ticket.requestedWei - ticket.fundedWei : null;

  function switchTo(next: Tab) {
    setTab(next);
    setEdited('top');
    setTyped('');
    setCanonical(undefined);
    setChosenUnit('token');
  }

  function edit(value: string, leg: Leg) {
    if (leg !== edited) setChosenUnit('token');
    setEdited(leg);
    setTyped(value);
    setCanonical(undefined);
  }

  /** Same amount, other unit: flipping never changes what would be sent. */
  function flip() {
    const wei = ethWei ?? 0n;
    const next: Unit = unit === 'usd' ? 'token' : 'usd';
    setTyped(wei > 0n ? weiToTyped(wei, next, 'ETH', ASSET_DECIMALS, prices) : '');
    setCanonical(wei);
    setEdited('top');
    setChosenUnit(next);
  }

  /** the panel being typed keeps every digit; the other is read at four places */
  function shown(leg: Leg) {
    if (leg === edited) return typed;
    const wei = leg === 'top' ? ethWei : sharesWei;
    return wei && wei > 0n ? formatWeiFixed(wei, leg === 'top' ? ASSET_DECIMALS : SHARE_DECIMALS, 4) : '';
  }

  function panel(leg: Leg) {
    const eth = leg === 'top';
    // the tab already says which way; the panel says which side of it this is
    const label = eth ? 'Amount' : 'Shares';
    const aria = eth ? (depositing ? 'Amount to deposit' : 'Amount to withdraw') : (depositing ? 'Shares to receive' : 'Shares to redeem');
    const four = (wei: bigint, decimals: number) => formatWeiFixed(wei, decimals, 4);
    const side = !connected ? 'Connect to see balance'
      : !wallet ? 'Balance —'
      : claiming ? `Funded ${eth ? four(funded.assets, ASSET_DECIMALS) : four(funded.units, SHARE_DECIMALS)}`
      : eth ? (depositing ? `Balance ${four(ahead(wallet.balance, 'ETH'), ASSET_DECIMALS)}${pendingMark('ETH')}` : '')
      : `Balance ${four(ahead(wallet.shares, 'hWETH'), SHARE_DECIMALS)}${pendingMark('hWETH')}`;
    return <>
      <div className="frow"><span className="flabel">{label}</span></div>
      <div className="amt">
        {eth && unit === 'usd' && edited === leg && <span className="cur">$</span>}
        <input inputMode="decimal" placeholder="0" aria-label={aria} value={shown(leg)}
          onChange={event => edit(event.target.value, leg)} />
        <span className="asset still">
          <TokenMark symbol={eth ? 'ETH' : 'hWETH'} chain={eth} />
          {eth ? 'ETH' : 'hWETH'}
        </span>
      </div>
      <div className="fmeta">
        {eth ? (
          <AmountFlip unit={edited === leg ? unit : 'token'} available={Boolean(prices)} symbol="ETH"
            other={edited === leg && unit === 'usd' ? `${four(ethWei ?? 0n, ASSET_DECIMALS)} ETH` : usd(ethWei ?? 0n)}
            onFlip={flip} />
        ) : (
          <span className="fusd">{ethWei === null ? 'Price unavailable' : usd(ethWei)}</span>
        )}
        <span>{side}</span>
      </div>
    </>;
  }

  const label = busy ?? (connected && !wallet ? 'Loading account…'
    : claiming && entered ? 'Claim'
    : !depositing && !ticket && state === 'entered' && (atomic.data === 'supported' || (atomic.data === 'ready' && oneTx)) ? 'Withdraw'
    : actionLabel(input, connectLabel));
  const blocked = connected && (Boolean(busy) || !wallet || !onSubmit || actionDisabled(state) || (
    state === 'inFlight'
      ? !claiming || (entered && ((ethWei ?? 0n) > funded.assets || (sharesWei ?? 0n) > funded.units))
      : depositing ? ethWei === null || ethWei >= wallet.balance || ethWei > (snapshot?.maxDeposit ?? 0n)
      : sharesWei === null || sharesWei === 0n || sharesWei > wallet.shares));

  function submit() {
    if (!connected) return onConnect();
    if (!onSubmit) return;
    if (!depositing && ticket) {
      if (!entered) return onSubmit('claim', funded.assets, oneTx);
      return edited === 'top' ? onSubmit('claim', ethWei ?? 0n, oneTx) : onSubmit('redeem', sharesWei ?? 0n, oneTx);
    }
    if (depositing) return edited === 'top' ? onSubmit('deposit', ethWei ?? 0n, oneTx) : onSubmit('mint', sharesWei ?? 0n, oneTx);
    onSubmit('request', sharesWei ?? 0n, oneTx);
  }

  const withUsd = (wei: bigint) => <small className="usd">{usd(wei)}</small>;

  return (
    <div className="panelcard">
      {/* the same control as Swap's Tokens / Receipts, in the same place */}
      <div className="panelhead">
        <div className="seg" role="group" aria-label="Deposit or withdraw">
          <button type="button" aria-pressed={depositing} onClick={() => switchTo('deposit')}>Deposit</button>
          <button type="button" aria-pressed={!depositing} onClick={() => switchTo('withdraw')}>Withdraw</button>
        </div>
      </div>

      <CarvedDeck pay={panel('top')} receive={panel('bottom')} flow={depositing ? 'down' : 'up'} />

      {unit === 'usd' && !prices && <p className="note">Price unavailable: switch to token entry.</p>}

      <div className="sec">
        {depositing ? (
          <>
            <div className="qrow">
              <span>hWETH price</span>
              <span>
                {priced ? <>{formatWeiFixed(priceWad, 18, 4)} ETH{withUsd(priceWad)}</> : '—'}
              </span>
            </div>
            <div className="qrow">
              <span>Fee</span>
              <span>Free</span>
            </div>
          </>
        ) : (
          <>
            <div className="qrow">
              <span>Pool cash</span>
              <span>{group(formatWeiFixed(liquidity.readyWei, ASSET_DECIMALS, 4))} ETH{withUsd(liquidity.readyWei)}</span>
            </div>
            <div className="qrow">
              <span>Pending exits</span>
              <span>{snapshot && !snapshot.valid ? '—' : <>{group(formatWeiFixed(liquidity.queuedAheadWei, ASSET_DECIMALS, 4))} ETH{withUsd(liquidity.queuedAheadWei)}</>}</span>
            </div>
            {wallet && (wallet.pendingShares > 0n || wallet.claimableAssets > 0n) && <>
              <div className="qrow">
                <span>Your pending</span>
                <span>{formatWeiFixed(wallet.pendingShares, SHARE_DECIMALS, 4)} hWETH</span>
              </div>
              <div className="qrow">
                <span>Your funded</span>
                <span>{formatWeiFixed(wallet.claimableAssets, ASSET_DECIMALS, 4)} ETH{withUsd(wallet.claimableAssets)}</span>
              </div>
            </>}
          </>
        )}
      </div>

      {!depositing && ticket && <ExitTracker ticket={ticket} />}
      {offerUpgrade && <label className="upgrade">
        <input type="checkbox" checked={oneTx} disabled={Boolean(busy)} onChange={e => setUpgradeAccount(e.target.checked ? wallet?.address ?? null : null)} />
        <span>{claiming ? 'Authorise and claim in one transaction' : 'Request, fund and claim in one transaction'}<small>One-time smart account upgrade (EIP-7702). Same address.</small></span>
      </label>}

      <button type="button" className="act" disabled={blocked} onClick={submit}>{label}</button>
      {!depositing && !ticket && wallet && <p className="foot">When your wallet supports batching and FIFO liquidity is available, this completes as one ETH withdrawal. Otherwise we queue your request, attempt funding, and you claim separately.</p>}
      {error && <p role="alert" className="note">{error}</p>}

      {!depositing && ticket && remaining !== null && remaining > 0n && (
        <p className="foot">{formatWeiFixed(remaining, ASSET_DECIMALS, 4)} ETH ({usd(remaining)}) is still waiting to be funded</p>
      )}
    </div>
  );
}
