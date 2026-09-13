'use client';

import { useEffect, useId, useRef, useState } from 'react';
import QRCode from 'qrcode';
import { isAddress, type Address, type Hex } from 'viem';
import { publicClient } from '@/lib/chain';
import { formatWei, formatWeiFixed, parseWei } from '@/lib/format';
import { errorMessage } from '@/lib/harbor/config';
import { useDisplayPrice } from '@/lib/harbor/DisplayPriceProvider';
import { useResource } from '@/lib/harbor/useResource';
import { isRejection } from '@/lib/swap/execute';
import { pending, truncateAddress, useConnect, useFund, usePending, useRereadOnSettle, useSend, useSigner } from '@/lib/wallet';
import { fastFees } from '@/lib/wallet/fees';
import TxToast from './TxToast';

type Props = { onConnect: () => void; connectLabel: string };
type View = 'home' | 'deposit' | 'withdraw';

/**
 * What Max leaves behind: gas at the max fee the send will actually carry. The
 * wallet checks balance against the max fee, not the fee it ends up paying.
 */
async function sendReserve(from: Address, to: Address, value: bigint) {
  const [gas, fees] = await Promise.all([
    publicClient.estimateGas({ account: from, to, value }).catch(() => 21_000n),
    fastFees(),
  ]);
  return gas * fees.maxFeePerGas * 6n / 5n;
}

function Copy({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  useEffect(() => { if (!copied) return; const id = setTimeout(() => setCopied(false), 1600); return () => clearTimeout(id); }, [copied]);
  async function copy() {
    try { await navigator.clipboard.writeText(text); setCopied(true); } catch { /* nothing to copy into */ }
  }
  return (
    <button type="button" className="wcopy" onClick={copy} aria-label={copied ? 'Address copied' : 'Copy address'}>
      <svg viewBox="0 0 16 16" fill="none" aria-hidden="true">
        {copied
          ? <path d="M3.5 8.4 6.6 11.4 12.5 4.8" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
          : <><rect x="5.5" y="5.5" width="7.5" height="7.5" rx="2" stroke="currentColor" strokeWidth="1.5" /><path d="M10.5 3.5H5A1.5 1.5 0 0 0 3.5 5v5.5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" /></>}
      </svg>
      <span aria-live="polite">{copied ? 'Copied' : 'Copy'}</span>
    </button>
  );
}

/** the receiving address as a code a phone wallet can scan - the address alone, no payment URI */
function AddressCode({ address }: { address: string }) {
  const [svg, setSvg] = useState('');
  useEffect(() => {
    let live = true;
    QRCode.toString(address, { type: 'svg', margin: 0, errorCorrectionLevel: 'M', color: { dark: '#4A2F6BFF', light: '#00000000' } })
      .then(markup => { if (live) setSvg(markup); }).catch(() => {});
    return () => { live = false; };
  }, [address]);
  // generated locally from a checksummed address - no external markup reaches this
  return <div className="wqr" role="img" aria-label="QR code of your wallet address" dangerouslySetInnerHTML={{ __html: svg }} />;
}

/**
 * The connected wallet, stated in the nav: what it holds, and the menu for
 * everything a wallet needs that the pages do not do - copy the address, move
 * ETH in and out, sign out. Clicking the address never signs out by itself.
 *
 * Deposit and Withdraw are for the Privy embedded wallet only: a browser wallet
 * already has its own receive and send, and a second one here would compete.
 */
export default function WalletButton({ onConnect, connectLabel }: Props) {
  const { connected, address, disconnect } = useConnect();
  const signer = useSigner();
  const fund = useFund();
  const send = useSend();
  const { usd } = useDisplayPrice();
  const [open, setOpen] = useState(false);
  const [view, setView] = useState<View>('home');
  const root = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const menuId = useId();
  const balance = useResource(`native:${address ?? 'none'}`, () => address ? publicClient.getBalance({ address }) : Promise.resolve(null), 15_000);
  const inflight = usePending(address);
  useRereadOnSettle(balance.refresh);
  // the balance as it will be once pending transactions land, marked as such
  const held = balance.data ?? null;
  const eth = held === null ? null : held + inflight.delta('ETH') > 0n ? held + inflight.delta('ETH') : 0n;
  const settling = inflight.delta('ETH') !== 0n;
  const embedded = Boolean(signer?.embedded);

  // withdraw form
  const [to, setTo] = useState('');
  const [amount, setAmount] = useState('');
  const [sending, setSending] = useState<{ step?: string; hash?: Hex; error?: string; value?: bigint; pending?: boolean }>();
  const value = parseWei(amount, 18);
  const recipient = isAddress(to) ? (to as Address) : null;
  const problem = !to ? null : !recipient ? 'Not a valid address'
    : address && recipient.toLowerCase() === address.toLowerCase() ? 'That is this wallet'
    : amount && (value === null || value === 0n) ? 'Enter a valid amount'
    : eth !== null && value !== null && value > eth ? 'More than this wallet holds' : null;
  const busy = Boolean(sending?.step);

  useEffect(() => {
    if (!open) return;
    const outside = (event: PointerEvent) => { if (!root.current?.contains(event.target as Node)) setOpen(false); };
    const escape = (event: KeyboardEvent) => { if (event.key === 'Escape') { setOpen(false); trigger.current?.focus(); } };
    document.addEventListener('pointerdown', outside);
    document.addEventListener('keydown', escape);
    return () => { document.removeEventListener('pointerdown', outside); document.removeEventListener('keydown', escape); };
  }, [open]);

  if (!connected || !address) {
    return <button type="button" className="connect" onClick={onConnect}>{connectLabel}</button>;
  }

  function show(next: View) { setView(next); setSending(s => (s?.step ? s : undefined)); }

  async function max() {
    if (!address || eth === null) return;
    const reserve = await sendReserve(address, recipient ?? address, eth).catch(() => 0n);
    setAmount(eth > reserve ? formatWei(eth - reserve, 18, 18) : '0');
  }

  async function withdraw() {
    if (!address || !recipient || !value || problem || busy) return;
    setSending({ step: 'Confirm in wallet…', value });
    try {
      const hash = await send({ to: recipient, data: '0x', value, account: address });
      // broadcast: the form is free again, and the notice waits on the block
      setSending({ hash, value, pending: true });
      pending.add(hash, address, { ETH: -value });
      setAmount(''); setTo('');
      const receipt = await publicClient.waitForTransactionReceipt({ hash }).catch(error => { pending.settle(hash, false); throw error; });
      if (receipt.status !== 'success') { pending.settle(hash, false); throw new Error('The transfer reverted.'); }
      pending.settle(hash, true);
      setSending({ hash, value });
    } catch (error) {
      setSending(isRejection(error) ? undefined : { error: errorMessage(error) });
    }
  }

  const short = eth === null ? '—' : formatWeiFixed(eth, 18, 4);

  return (
    <div className="wallet" ref={root}>
      <button ref={trigger} type="button" className="connect wbtn" aria-expanded={open} aria-controls={menuId}
        aria-label={`${truncateAddress(address)}, wallet menu`} onClick={() => { setOpen(o => !o); setView('home'); }}>
        {/* the address only: balances live in the menu, so the button keeps one width */}
        <span className="waddr" data-pending={settling || undefined}>{truncateAddress(address)}</span>
        <svg className="wcaret" viewBox="0 0 12 12" fill="none" aria-hidden="true"><path d="M3 4.6 6 7.6l3-3" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" /></svg>
      </button>

      {open && (
        <div className="wmenu" id={menuId} role="dialog" aria-label="Wallet">
          {view === 'home' && <>
            <div className="wwho"><i className={embedded ? 'wdot on' : 'wdot'} />{signer?.name ?? 'Connected wallet'}</div>
            <div className="waddrrow"><span className="num" title={address}>{truncateAddress(address)}</span><Copy text={address} /></div>
            <div className="wfig">
              <b className="num">{eth === null ? '—' : formatWeiFixed(eth, 18, 6)}</b><i>ETH</i>
              <small className="usd">{eth === null ? (balance.error ? 'Balance unavailable' : 'Loading…') : usd(eth)}{settling && <em className="wpend"> · pending</em>}</small>
            </div>
            {embedded && <div className="wacts">
              <button type="button" className="wact" onClick={() => show('deposit')}>Deposit</button>
              <button type="button" className="wact" onClick={() => show('withdraw')}>Withdraw</button>
            </div>}
            <button type="button" className="wout" onClick={() => { setOpen(false); disconnect(); }}>Disconnect</button>
          </>}

          {view === 'deposit' && <>
            <div className="whead"><button type="button" className="wback" aria-label="Back" onClick={() => show('home')}>‹</button><strong>Deposit ETH</strong></div>
            <AddressCode address={address} />
            <div className="waddrfull"><span className="num">{address}</span><Copy text={address} /></div>
            <p className="wnote">Send Hoodi ETH to this address. Other networks&rsquo; ETH will not arrive here.</p>
            {fund && <button type="button" className="wact wide" onClick={() => { setOpen(false); void fund(address).catch(() => {}); }}>Transfer from another wallet</button>}
          </>}

          {view === 'withdraw' && <>
            <div className="whead"><button type="button" className="wback" aria-label="Back" onClick={() => show('home')} disabled={busy}>‹</button><strong>Withdraw ETH</strong></div>
            <label className="wfield"><span>To</span>
              <input value={to} onChange={e => setTo(e.target.value.trim())} placeholder="0x…" spellCheck={false} autoComplete="off" aria-invalid={Boolean(to && !recipient)} disabled={busy} />
            </label>
            <label className="wfield"><span>Amount</span>
              <span className="wamt">
                <input inputMode="decimal" value={amount} onChange={e => setAmount(e.target.value)} placeholder="0" disabled={busy} />
                <em>ETH</em>
                <button type="button" className="wmax" onClick={max} disabled={busy || eth === null}>Max</button>
              </span>
              <small>{value ? usd(value) : `Balance ${short} ETH`}</small>
            </label>
            {problem && <p className="werr" role="alert">{problem}</p>}
            {sending?.error && <p className="werr" role="alert">{sending.error}</p>}
            <button type="button" className="act wsend" onClick={withdraw} disabled={!recipient || !value || Boolean(problem) || busy}>
              {sending?.step ?? 'Withdraw'}
            </button>
            <p className="wnote">Max leaves enough ETH for this transfer&rsquo;s gas.</p>
          </>}
        </div>
      )}

      {sending?.hash && (
        <TxToast pending={Boolean(sending.pending)} hash={sending.hash} title="Withdrawal sent" failTitle="Withdrawal failed"
          detail={sending.value ? `${formatWei(sending.value, 18)} ETH` : undefined} onDismiss={() => setSending(undefined)} />
      )}
    </div>
  );
}
