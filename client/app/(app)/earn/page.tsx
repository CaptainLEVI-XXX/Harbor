'use client';

import { useEffect, useRef, useState } from 'react';
import type { Hex } from 'viem';
import VaultHero from '@/components/earn/VaultHero';
import VaultPanel from '@/components/earn/VaultPanel';
import HistorySections from '@/components/earn/HistorySections';
import TxToast from '@/components/TxToast';
import { pending, useRereadOnSettle, type Deltas } from '@/lib/wallet/pending';
import { useConnect } from '@/lib/wallet';
import { useSend } from '@/lib/wallet/useSend';
import { getEarnSnapshot } from '@/lib/harbor/reads';
import { getHistory } from '@/lib/harbor/history';
import { entryPrice, estimatedApy, shareObservations, trailingApy } from '@/lib/harbor/analytics';
import { useResource } from '@/lib/harbor/useResource';
import { useDisplayPrice } from '@/lib/harbor/DisplayPriceProvider';
import { HARBOR, errorMessage } from '@/lib/harbor/config';
import { runVaultAction, type VaultAction } from '@/lib/harbor/vaultActions';
import { formatSigned, formatWei, formatWeiFixed, tone } from '@/lib/format';
import { chain } from '@/lib/chain';

/** what landed, in the words of the action that sent it */
const DONE: Record<VaultAction, string> = {
  deposit: 'Deposit confirmed', mint: 'Deposit confirmed', request: 'Withdrawal requested',
  claim: 'Claim confirmed', redeem: 'Claim confirmed', checkpoint: 'Valuation refreshed',
};
/** what an action moves in the wallet, where the amount alone says it; gas aside */
function actionDeltas(action: VaultAction, amount: bigint): Deltas {
  switch (action) {
    case 'deposit': return { ETH: -amount };
    case 'mint': return { hWETH: amount };
    case 'request': return { hWETH: -amount };
    case 'claim': return { ETH: amount };
    default: return {};
  }
}
function doneDetail(action: VaultAction, amount: bigint): string | undefined {
  if (action === 'deposit' || action === 'claim') return `${formatWeiFixed(amount, 18, 4)} ETH`;
  if (action === 'mint' || action === 'request' || action === 'redeem') return `${formatWeiFixed(amount, 24, 4)} hWETH`;
  return undefined;
}

export default function EarnPage() {
  const { label, connected, onConnect, address } = useConnect();
  const { data, error, refresh } = useResource(`earn:${address ?? 'public'}`, () => getEarnSnapshot(address));
  useRereadOnSettle(refresh);
  // read once here: the sections show it, its latest checkpoint prices the panel
  // whenever the live mark is stale, and it carries this wallet's own deposits
  const history = useResource(`pool-history:${address ?? 'public'}`, () => getHistory(address), 60_000);
  const { usd } = useDisplayPrice();
  const send = useSend();
  const active = useRef(false);
  const [tx, setTx] = useState<{ account?: string; busy?: string; error?: string; hash?: Hex; action?: VaultAction; amount?: bigint; pending?: boolean }>({});
  const latest = useRef(0);
  const account = data?.account;
  const live = data?.valid ? data.sharePrice : null;
  const indexed = history.data ? shareObservations(history.data).at(-1)?.price ?? null : null;
  const price = live ?? indexed;
  const pendingValue = account?.pendingShares === 0n ? 0n : account && price !== null ? account.pendingShares * price / 10n ** 24n : null;
  const ticket = account && (account.pendingShares > 0n || account.claimableAssets > 0n)
    ? { requestedWei: pendingValue === null ? null : pendingValue + account.claimableAssets, fundedWei: account.claimableAssets } : null;
  const liquidity = {
    readyWei: data ? (data.cash > data.reservedAssets ? data.cash - data.reservedAssets : 0n) : 0n,
    queuedAheadWei: data && live != null ? data.totalPendingShares * live / 10n ** 24n : 0n,
  };
  const worth = account && data?.valid && account.positionAssets != null ? account.positionAssets
    : account && price !== null ? account.shares * price / 10n ** 24n : null;
  // what the held shares have gained over what was paid for them - an estimate:
  // shares that arrived by transfer have no entry price
  const entry = history.data ? entryPrice(history.data) : null;
  const profit = account && price !== null && entry !== null ? account.shares * (price - entry) / 10n ** 24n : null;
  // a measured 30-day rate once there is a week of history; an estimate before
  const [now] = useState(() => Date.now());
  const measured = history.data ? trailingApy(history.data) : null;
  const estimate = history.data && measured === null ? estimatedApy(history.data, now) : null;
  const apy = measured ?? estimate?.pct ?? null;
  const mark = history.data?.pool.lastCheckpoint;
  const nav = data?.valid ? data.nav : mark ? BigInt(mark.nav) : null;
  const traded = history.data ? history.data.strategies.reduce((sum, s) => sum + BigInt(s.customerCashVolume), 0n) : null;
  const shareUsd = (shares: bigint) => price === null ? null : usd(shares * price / 10n ** 24n);
  // The rail follows the page the way a long sidebar should: scrolling down it
  // rides up until its foot is on screen, scrolling up it rides back down until
  // its head is. It never scrolls inside itself, so the wheel is never trapped.
  const rail = useRef<HTMLElement>(null);
  useEffect(() => {
    const el = rail.current;
    if (!el) return;
    const HEAD = 84, FOOT = 24;
    let top = HEAD, last = window.scrollY, frame = 0;
    const place = () => {
      frame = 0;
      const lowest = Math.min(HEAD, window.innerHeight - el.offsetHeight - FOOT);
      top = Math.min(HEAD, Math.max(lowest, top - (window.scrollY - last)));
      last = window.scrollY;
      el.style.setProperty('--rail-top', `${top}px`);
    };
    const schedule = () => { if (!frame) frame = requestAnimationFrame(place); };
    place();
    const size = new ResizeObserver(schedule);
    size.observe(el);
    window.addEventListener('scroll', schedule, { passive: true });
    window.addEventListener('resize', schedule);
    return () => { cancelAnimationFrame(frame); size.disconnect(); window.removeEventListener('scroll', schedule); window.removeEventListener('resize', schedule); };
  }, []);
  async function transact(action: VaultAction, amount: bigint, upgradeAccount = false) {
    if (!address || active.current) return;
    active.current = true;
    const id = ++latest.current;
    // a later action owns the panel and the notice; this one still refreshes when it lands
    const mine = (next: typeof tx) => { if (latest.current === id) setTx(next); };
    mine({ account: address, busy: 'Preparing…' });
    let broadcast: Hex | undefined;
    try {
      const hash = await runVaultAction(action, amount, address, send, busy => mine({ account: address, busy }), upgradeAccount, submitted => {
        // broadcast: the panel is free, and the notice waits on the block instead
        broadcast = submitted;
        active.current = false;
        pending.add(submitted, address, actionDeltas(action, amount));
        mine({ account: address, hash: submitted, action, amount, pending: true });
      });
      pending.settle(broadcast, true);
      mine({ account: address, hash, action, amount });
    } catch (error) { pending.settle(broadcast, false); mine({ account: address, error: errorMessage(error) }); }
    finally { if (latest.current === id) active.current = false; refresh(); }
  }
  return <div className="earn">
    <div className="stack">
      {error && <p role="alert" className="alert"><span>{error}</span> <button type="button" className="ghost" onClick={refresh}>Retry</button></p>}
      <VaultHero apyPct={apy} apyNote={estimate ? `Est. from ${estimate.hours < 48 ? `${Math.round(estimate.hours)}h` : `${Math.round(estimate.hours / 24)}d`} of history` : undefined}
        navWei={nav} tradedWei={traded} priceWad={price} />
      {data && <section className="modal">
        <div className="shead"><h2>Pool liquidity</h2></div>
        <div className="stats">
          <div className="stat"><span>Accounted cash</span><b>{formatWei(data.cash, 18)}</b><i>ETH</i><small className="usd">{usd(data.cash)}</small></div>
          <div className="stat"><span>Reserved for exits</span><b>{formatWei(data.reservedAssets, 18)}</b><i>ETH</i><small className="usd">{usd(data.reservedAssets)}</small></div>
          <div className="stat"><span>Pending exits</span><b>{formatWei(data.totalPendingShares, 24)}</b><i>hWETH</i>{shareUsd(data.totalPendingShares) && <small className="usd">{shareUsd(data.totalPendingShares)}</small>}</div>
        </div>
        <div className="links"><a href={`${chain.blockExplorers.default.url}/address/${HARBOR.vault}`}>Vault contract</a><a href={`${chain.blockExplorers.default.url}/address/${HARBOR.book}`}>Book contract</a></div>
      </section>}
      <HistorySections history={history} />
    </div>
    <aside className="rail" ref={rail}>
      {connected && <section className="pos" aria-labelledby="pos-head"><h2 id="pos-head">Your position</h2>
        <div className="pane">
          <p className="big num">{account ? <>{formatWeiFixed(account.shares, 24, 4)}<i>hWETH</i></> : '—'}</p>
          <p className="worth">
            {worth === null ? 'Value unavailable' : <><span className="num">≈ {formatWeiFixed(worth, 18, 4)} ETH</span><small className="usd">{usd(worth)}</small></>}
          </p>
          {profit !== null && <p className="pnl">
            <span className={`num ${tone(profit)}`}>{formatSigned(profit, 18, 4)} ETH</span>
            <small className="usd">{usd(profit < 0n ? -profit : profit)}</small>
            <em className="chip">Est. profit</em>
          </p>}
        </div>
      </section>}
      <VaultPanel connected={connected} connectLabel={label} onConnect={onConnect}
        ticket={ticket} priceWad={price ?? 0n} liquidity={liquidity} snapshot={data}
        paused={!data || data.maxDeposit === 0n} onSubmit={transact}
        busy={tx.busy} error={tx.account === address ? tx.error : undefined} />
      {tx.hash && tx.account === address && tx.action && (
        <TxToast hash={tx.hash} pending={tx.pending} title={DONE[tx.action]} detail={doneDetail(tx.action, tx.amount ?? 0n)} onDismiss={() => setTx({})} />
      )}
    </aside>
  </div>;
}
