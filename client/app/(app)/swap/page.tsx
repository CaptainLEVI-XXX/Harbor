'use client';

import { useEffect, useState, type CSSProperties } from 'react';
import AssetSelect from '@/components/swap/AssetSelect';
import QuotePanel from '@/components/swap/QuotePanel';
import ReceiptBrowser, { type SelectedReceipt } from '@/components/swap/ReceiptBrowser';
import CarvedDeck from '@/components/swap/CarvedDeck';
import TxToast from '@/components/TxToast';
import { useLaneWidth } from '@/lib/swap/useLaneWidth';
import { useConnect } from '@/lib/wallet';
import { chain } from '@/lib/chain';
import { ASSETS } from '@/lib/harbor/config';
import { formatWei } from '@/lib/format';
import { useLiveQuote } from '@/lib/harbor/useLiveQuote';
import { AUTO_SLIPPAGE_BPS } from '@/lib/harbor/quote';
import RouteMark from '@/components/swap/RouteMark';
import { getTokenBalances } from '@/lib/harbor/reads';
import { useResource } from '@/lib/harbor/useResource';
import type { Direction, TradeMode } from '@/lib/swap/types';
import type { ExecutableQuote } from '@/lib/harbor/quote';
import { useSwap } from '@/lib/swap/useSwap';
import { isRejection } from '@/lib/swap/execute';
import { errorMessage } from '@/lib/harbor/config';
import { fundWithdrawals, type Funding } from '@/lib/harbor/withdrawals';
import type { Hex } from 'viem';
import { useSend } from '@/lib/wallet/useSend';
import { usePending, useRereadOnSettle } from '@/lib/wallet/pending';
import AmountFlip from '@/components/AmountFlip';
import TokenMark from '@/components/TokenMark';
import { useDisplayPrice } from '@/lib/harbor/DisplayPriceProvider';
import { typedToWei, weiToTyped, type Unit } from '@/lib/price';

/** basis points as a percentage, without a float: 250n -> "2.50" */
function formatBps(bps: bigint): string {
  return `${bps / 100n}.${String(bps % 100n).padStart(2, '0')}`;
}

export default function SwapPage() {
  const { label, onConnect, address } = useConnect();
  const [surface, setSurface] = useState<'tokens' | 'receipts'>('tokens');
  const [direction, setDirection] = useState<Direction>('sell');
  const [tokenMode, setTokenMode] = useState<TradeMode>('exactInput');
  const [typed, setTyped] = useState('0.001');
  const [unit, setUnit] = useState<Unit>('token');
  const [canonical, setCanonical] = useState<bigint>();
  const { prices, usd } = useDisplayPrice();
  const [selection, setSelection] = useState<{ key: string; receipt: SelectedReceipt }>();
  const [now, setNow] = useState(() => Date.now());
  const [revision, setRevision] = useState(0);
  const [frozen, setFrozen] = useState<ExecutableQuote>();
  // the deck shares the nav bar's width, so page and card sit in one lane
  const lane = useLaneWidth();
  // a landed swap is announced once; dismissing it names the hash, so the next
  // swap's notice is not suppressed by the last one's dismissal
  const [dismissed, setDismissed] = useState<string>();
  const balances = useResource(`balances:${address ?? 'public'}`, () => getTokenBalances(address));
  const inflight = usePending(address);
  useRereadOnSettle(balances.refresh);
  // Only a token-funded trade needs an allowance, and only then is there more
  // than one call to make atomic. An ETH-funded trade is already one call.
  const send = useSend();
  const [oneTx, setOneTx] = useState(false);
  const atomic = useResource(`atomic:${address ?? 'none'}`, () => address && send.atomic ? send.atomic() : Promise.resolve(null));
  useEffect(() => { const id = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(id); }, []);
  const identity = `${address ?? 'public'}:${direction}`;
  const selected = selection?.key === identity ? selection.receipt : undefined;
  // Selling gives one whole receipt; buying takes one. Neither is divisible,
  // so exactness is a consequence of the direction, never a control.
  const mode: TradeMode = surface === 'receipts' ? (direction === 'sell' ? 'exactInput' : 'exactOutput') : tokenMode;
  const base = surface === 'receipts' ? { symbol: 'receipt', name: 'Withdrawal receipt', decimals: 0 } : ASSETS.wstETH;
  const pay = direction === 'sell' ? base : ASSETS.ETH;
  const receive = direction === 'sell' ? ASSETS.ETH : base;
  const decimals = mode === 'exactInput' ? pay.decimals : receive.decimals;
  const specified = mode === 'exactInput' ? pay : receive;
  const validText = /^\d*(\.\d*)?$/.test(typed) && (typed.split('.')[1]?.length ?? 0) <= (unit === 'usd' ? 18 : decimals);
  const amountWei = !validText || (unit === 'usd' && !prices) ? 0n : canonical ?? typedToWei(typed, unit, specified.symbol, decimals, prices);
  const available = surface === 'tokens' || selected !== undefined;
  const live = useLiveQuote(available ? { amountWei, mode, direction, user: address, route: selected && surface === 'receipts' ? selected.route : undefined, tokenId: selected && surface === 'receipts' ? selected.tokenId : undefined } : null, revision);
  const transaction = useSwap(live.executable, () => { balances.refresh(); setRevision(r => r + 1); }, oneTx);
  // Funding the LP exit queue reopens selling to the vault. It reserves those
  // LPs' cash - it claims nothing for whoever presses it - and the caller pays gas.
  const [funding, setFunding] = useState<{ step?: string; hash?: Hex; done?: Funding; error?: string; pending?: boolean }>();
  const fundingBusy = Boolean(funding?.step);
  async function onFund() {
    if (!address) { onConnect(); return; }
    if (fundingBusy) return;
    setFunding({ step: 'Preparing…' });
    try {
      const done = await fundWithdrawals(address, send, step => setFunding(f => ({ ...f, step })), hash => setFunding({ hash, pending: true }));
      setFunding({ done, hash: done.hash });
      // the vault's cash and queue just changed: re-read both, then re-quote
      balances.refresh();
      setRevision(r => r + 1);
    } catch (error) {
      setFunding(isRejection(error) ? undefined : { error: errorMessage(error) });
    }
  }
  const locked = transaction.busy && frozen;
  const quote = locked ? { state: 'firm' as const, payWei: frozen.payWei, receiveWei: frozen.receiveWei, feeWei: frozen.feeWei, rate: frozen.rate, expiresAt: frozen.refreshAt } : live.quote;
  const executable = locked ? frozen : live.executable;
  const stale = quote.expiresAt !== null && now >= quote.expiresAt;
  const shown = stale && !transaction.busy ? { ...quote, state: 'expired' as const } : quote;
  const quoted = quote.state === 'firm';
  // The leg the user types keeps every digit they typed; the quoted leg is read,
  // not edited, so it is shown at reading precision. The trade always settles on
  // the quote's own wei, never on this string.
  const payValue = mode === 'exactInput' ? typed : quoted ? formatWei(quote.payWei, pay.decimals) : '';
  const receiveValue = mode === 'exactOutput' ? typed : quoted ? formatWei(quote.receiveWei, receive.decimals) : '';
  const symbols = [ASSETS.wstETH, ASSETS.ETH];
  // Paying in a token means approve-then-swap; paying in ETH is already one call.
  const needsAllowance = pay.symbol !== 'ETH';
  const offerUpgrade = Boolean(address) && atomic.data === 'ready' && needsAllowance;
  const actionLabel = !address ? label : transaction.busy
    ? transaction.status === 'approving' ? 'Approving…' : transaction.status === 'swapping' ? 'Swapping…' : 'Preparing…'
    : stale ? 'Refresh quote' : shown.state === 'requesting' ? (surface === 'receipts' ? 'Reading NFT quote…' : 'Reading SwapVM…')
    : !available ? 'Select a receipt' : !validText ? 'Invalid token precision'
    : shown.blocker === 'unfundedWithdrawals' ? 'Waiting on withdrawals'
    : shown.state === 'unavailable' ? 'No executable quote' : amountWei === 0n ? 'Enter an amount'
    : selected && surface === 'receipts' ? `${direction === 'sell' ? 'Sell' : 'Buy'} receipt #${selected.tokenId.toString()}` : 'Swap';
  function chooseSurface(next: 'tokens' | 'receipts') {
    setUnit('token'); setCanonical(undefined);
    setSurface(next); setTyped(next === 'receipts' ? '1' : '0.001');
    setTokenMode('exactInput');
  }
  function reverse() {
    setUnit('token'); setCanonical(undefined);
    setDirection(d => d === 'sell' ? 'buy' : 'sell');
    if (surface === 'receipts') setTyped('1');
  }
  function edit(value: string, nextMode: TradeMode) {
    if (mode !== nextMode) setUnit('token');
    setTokenMode(nextMode); setTyped(value); setCanonical(undefined);
  }
  function flip(nextMode: TradeMode, symbol: string, value: bigint) {
    const next: Unit = mode === nextMode && unit === 'usd' ? 'token' : 'usd';
    setTyped(weiToTyped(value, next, symbol, 18, prices)); setCanonical(value); setTokenMode(nextMode); setUnit(next);
  }
  function onAction() {
    if (!address) { onConnect(); return; }
    if (stale) { setRevision(r => r + 1); return; }
    if (live.executable) { setFrozen(live.executable); void transaction.swap(); }
  }
  // one key per outcome: dismissing this run's notice cannot silence the next
  // keyed by phase too: dismissing "Confirming…" must not also swallow "completed"
  const noticeKey = transaction.error ? `failed:${transaction.error}` : transaction.hash && `${transaction.status}:${transaction.hash}`;
  const notice = !noticeKey || noticeKey === dismissed ? undefined
    : transaction.error ? { error: transaction.error }
    : {
        href: `${chain.blockExplorers.default.url}/tx/${transaction.hash}`,
        hash: transaction.hash,
        pending: transaction.status === 'confirming',
        detail: frozen
          ? `${formatWei(frozen.payWei, pay.decimals)} ${pay.symbol} \u2192 ${formatWei(frozen.receiveWei, receive.decimals)} ${receive.symbol}`
          : undefined,
      };
  // the button lightens as the run advances, so a wallet that has been open a
  // while still says which step it is on
  const phase = transaction.busy ? transaction.status : undefined;
  const balance = (symbol: string) => {
    if (!address) return 'Connect to see balance';
    if (symbol === 'receipt') return 'One whole receipt';
    if (!balances.data) return 'Balance unavailable';
    const asset = symbol as 'ETH' | 'wstETH';
    const change = inflight.delta(asset);
    const shown = balances.data[asset] + change;
    return `Balance ${formatWei(shown > 0n ? shown : 0n, 18)}${change ? ' · pending' : ''}`;
  };

  return <div className="swap-wrap swapx" style={{
    '--lane': lane.width ? `${lane.width}px` : undefined,
    '--lane-left': lane.left ? `${lane.left}px` : undefined,
  } as CSSProperties}><div className="panel">
    <div className="swap-head">
      <div className="seg">{(['tokens', 'receipts'] as const).map(s => <button key={s} disabled={transaction.busy} aria-pressed={surface === s} onClick={() => chooseSurface(s)}>{s === 'tokens' ? 'Tokens' : 'Receipts'}</button>)}</div>
    </div>
    <fieldset disabled={transaction.busy} style={{ border: 0, padding: 0, margin: 0, minWidth: 0 }}>
      {surface === 'receipts' && (() => {
        // the receipt leg names which receipt; the cash leg is read from the quote
        const receipt = <ReceiptBrowser key={identity} user={address} buying={direction === 'buy'} selected={selected} now={now} onSelect={r => setSelection({ key: identity, receipt: r })} />;
        const cashWei = direction === 'sell' ? quote.receiveWei : quote.payWei;
        const cash = <>
          <div className="frow"><span className="flabel">{direction === 'sell' ? 'You receive' : 'You pay'}</span></div>
          <div className="amt"><output className={`rcash${quoted ? '' : ' none'}`} aria-label={direction === 'sell' ? 'ETH you receive' : 'ETH you pay'}>{quoted ? formatWei(cashWei, 18) : '—'}</output>
            <span className="asset still"><TokenMark symbol="ETH" chain /><span>ETH</span></span></div>
          <div className="fmeta"><span>{quoted ? usd(cashWei) : selected ? 'Waiting for a quote' : 'Choose a receipt'}</span><span>{balance('ETH')}</span></div>
        </>;
        return <CarvedDeck onReverse={reverse} pay={direction === 'sell' ? receipt : cash} receive={direction === 'sell' ? cash : receipt} />;
      })()}
      {surface === 'tokens' && <CarvedDeck onReverse={reverse}
        pay={<>
          <div className="frow"><span className="flabel">Pay</span></div>
          <div className="amt">{mode === 'exactInput' && unit === 'usd' && <span className="cur">$</span>}<input aria-label="Amount you pay" inputMode="decimal" placeholder="0" value={payValue} onChange={e => edit(e.target.value, 'exactInput')} />
            <AssetSelect label="Pay asset" value={pay.symbol} options={symbols} onChange={s => { if (s !== pay.symbol) reverse(); }} /></div>
          <div className="fmeta"><AmountFlip unit={mode === 'exactInput' ? unit : 'token'} available={Boolean(prices)} symbol={pay.symbol} other={mode === 'exactInput' && unit === 'usd' ? formatWei(amountWei, 18) : usd(mode === 'exactInput' ? amountWei : quote.payWei, pay.symbol)} onFlip={() => flip('exactInput', pay.symbol, mode === 'exactInput' ? amountWei : quote.payWei)} /><span>{balance(pay.symbol)}</span></div>
        </>}
        receive={<>
          <div className="frow"><span className="flabel">Receive</span></div>
          <div className="amt">{mode === 'exactOutput' && unit === 'usd' && <span className="cur">$</span>}<input aria-label="Amount you receive" inputMode="decimal" placeholder="0" value={receiveValue} onChange={e => edit(e.target.value, 'exactOutput')} />
            <AssetSelect label="Receive asset" value={receive.symbol} options={symbols} onChange={s => { if (s !== receive.symbol) reverse(); }} /></div>
          <div className="fmeta"><AmountFlip unit={mode === 'exactOutput' ? unit : 'token'} available={Boolean(prices)} symbol={receive.symbol} other={mode === 'exactOutput' && unit === 'usd' ? formatWei(amountWei, 18) : usd(mode === 'exactOutput' ? amountWei : quote.receiveWei, receive.symbol)} onFlip={() => flip('exactOutput', receive.symbol, mode === 'exactOutput' ? amountWei : quote.receiveWei)} /><span>{balance(receive.symbol)}</span></div>
        </>}
      />}
      {unit === 'usd' && !prices && <p className="note">Price unavailable: switch back to token entry.</p>}
    </fieldset>
    {offerUpgrade && <label className="upgrade">
      <input type="checkbox" checked={oneTx} disabled={transaction.busy} onChange={e => setOneTx(e.target.checked)} />
      <span>Approve and swap in one transaction<small>Upgrades your account to a smart account (EIP-7702). One time, and your address does not change.</small></span>
    </label>}
    {/* the tiles above already say what you receive; the panel says on what terms */}
    <QuotePanel source={surface === 'receipts' ? 'harbor NFT' : 'SwapVM'} quote={shown} now={now} block={executable?.blockNumber} rows={[
      { label: 'Rate', value: quote.rate },
      { label: 'Fee', value: quote.feeWei === 0n ? 'Free' : usd(quote.feeWei) },
      { label: 'Max slippage', chip: 'Auto', value: `${formatBps(AUTO_SLIPPAGE_BPS)}%` },
      { label: 'Route', icon: <RouteMark />, value: 'harbor' },
    ]} />
    {shown.blocker === 'unfundedWithdrawals' && <div className="unblock">
      <p>LP withdrawals are funded before the vault buys. Funding reserves their cash; it claims nothing for you. You pay gas.</p>
      <button type="button" className="ghost" onClick={onFund} disabled={fundingBusy || transaction.busy}>
        {funding?.step ?? (address ? 'Fund withdrawals' : label)}
      </button>
    </div>}
    <button type="button" className="act" data-phase={phase} onClick={onAction} disabled={transaction.busy || Boolean(address && (!validText || (!stale && (!live.executable || shown.state !== 'firm'))))}>{actionLabel}</button>
    {balances.error && <p className="qnote">{balances.error}</p>}
    {funding && (funding.hash || funding.error) ? (
      <TxToast
        pending={Boolean(funding.pending)}
        hash={funding.hash}
        error={funding.error}
        title="Withdrawals funded"
        failTitle="Funding failed"
        detail={funding.done
          ? `${funding.done.tickets} request${funding.done.tickets === 1 ? '' : 's'} · ${formatWei(funding.done.assets, 18)} ETH reserved for LPs${funding.done.stillPending > 0n ? ' · more still waiting' : ' · selling reopened'}`
          : 'Funding pending withdrawals'}
        onDismiss={() => setFunding(undefined)}
      />
    ) : notice && <TxToast {...notice} onDismiss={() => setDismissed(noticeKey)} />}
  </div></div>;
}
