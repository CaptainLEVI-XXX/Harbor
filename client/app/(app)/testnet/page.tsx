'use client';

import { useRef, useState } from 'react';
import type { Hex } from 'viem';
import AmountFlip from '@/components/AmountFlip';
import InfoDot from '@/components/InfoDot';
import { useConnect } from '@/lib/wallet';
import { useSend } from '@/lib/wallet/useSend';
import { useResource } from '@/lib/harbor/useResource';
import { getTokenBalances } from '@/lib/harbor/reads';
import { getWithdrawalNFT, getWstETH } from '@/lib/harbor/testnet';
import { errorMessage } from '@/lib/harbor/config';
import { useDisplayPrice } from '@/lib/harbor/DisplayPriceProvider';
import { formatWei } from '@/lib/format';
import TxToast from '@/components/TxToast';
import { pending } from '@/lib/wallet/pending';
import { typedToWei, weiToTyped, type Unit } from '@/lib/price';
import { chain } from '@/lib/chain';

/** As many decimals as anyone reads on a faucet ladder. */
const PLACES = 6;

/**
 * One amount, typeable in its token or in dollars. What the field shows is
 * what the transaction spends: a flip rounds to the places it can display
 * rather than keeping hidden wei behind a shorter figure.
 */
function useAmount(initial: string, symbol: string) {
  const { prices, usd } = useDisplayPrice();
  const [typed, setTyped] = useState(initial);
  const [unit, setUnit] = useState<Unit>('token');
  const valid = typed.trim() !== '' && /^\d*(\.\d*)?$/.test(typed);
  const wei = !valid || (unit === 'usd' && !prices) ? null : typedToWei(typed, unit, symbol, 18, prices);
  function flip() {
    if (wei === null) return;
    const next: Unit = unit === 'usd' ? 'token' : 'usd';
    setTyped(next === 'token' ? formatWei(wei, 18, PLACES) : weiToTyped(wei, 'usd', symbol, 18, prices));
    setUnit(next);
  }
  const field = (disabled: boolean) => <span className="tamt">
    <span className="tamt-in">
      {unit === 'usd' && <i className="cur">$</i>}
      {/* the box grows to the digits: a right-aligned full-width input would
          strand the $ at the far left of the tile */}
      <span className="grow" data-value={typed || '0'}>
        <input aria-label={`${symbol} amount`} inputMode="decimal" value={typed} disabled={disabled}
          onChange={e => setTyped(e.target.value)} />
      </span>
      {unit === 'token' && <i className="unit">{symbol}</i>}
    </span>
    <AmountFlip unit={unit} available={Boolean(prices)} symbol={symbol} onFlip={flip}
      other={wei === null ? '—' : unit === 'usd' ? `${formatWei(wei, 18, PLACES)} ${symbol}` : usd(wei, symbol)} />
  </span>;
  return { wei, field };
}

export default function TestnetPage() {
  const { address, label, onConnect } = useConnect();
  const balances = useResource(`testnet:${address ?? 'public'}`, () => getTokenBalances(address));
  const send = useSend();
  const active = useRef(false);
  const stake = useAmount('0.01', 'ETH');
  const request = useAmount('0.005', 'wstETH');
  const [busy, setBusy] = useState<'stake' | 'request'>();
  // the outcome is a notice, like every other transaction: pending once
  // broadcast, confirmed when the block lands. Only a failure stays inline.
  const [result, setResult] = useState<{ owner?: string; kind?: 'stake' | 'request'; hash?: Hex; pending?: boolean; amount?: bigint; requestId?: bigint; error?: string }>({});

  // Holding the asset a rung spends is what opens it. A balance we could not
  // read shuts nothing: the action states the real reason far better than a
  // dead button does.
  const held = balances.data;
  const funded = stake.wei !== null && stake.wei > 0n && (!held || held.ETH > stake.wei);
  const staked = request.wei !== null && request.wei > 0n && (!held || held.wstETH >= request.wei);

  async function run(kind: 'stake' | 'request') {
    if (!address) { onConnect(); return; }
    if (active.current) return;
    active.current = true; setBusy(kind); setResult({ owner: address });
    const amount = kind === 'stake' ? stake.wei! : request.wei!;
    let broadcast: Hex | undefined;
    const submitted = (hash: Hex) => {
      broadcast = hash;
      pending.add(hash, address, kind === 'stake' ? { ETH: -amount } : { wstETH: -amount });
      setBusy(undefined); setResult({ owner: address, kind, hash, amount, pending: true });
    };
    try {
      if (kind === 'stake') {
        const hash = await getWstETH(amount, address, send, submitted);
        setResult({ owner: address, kind, hash, amount });
      } else {
        const { hash, requestId } = await getWithdrawalNFT(amount, address, send, () => {}, submitted);
        setResult({ owner: address, kind, hash, amount, requestId });
      }
      pending.settle(broadcast, true);
    } catch (error) { pending.settle(broadcast, false); setResult({ owner: address, error: errorMessage(error) }); }
    finally { active.current = false; setBusy(undefined); balances.refresh(); }
  }

  const act = (kind: 'stake' | 'request', name: string, open: boolean) =>
    <button className="act" disabled={Boolean(busy) || (Boolean(address) && !open)} onClick={() => void run(kind)}>
      {!address ? label : busy === kind ? 'Confirm in wallet…' : name}
    </button>;

  return <div className="swap-wrap ladder"><div className="panel"><div className="modal">
    <ol className="steps">
      <li>
        <span className="rlabel">Get test ETH<InfoDot>{`Get ${chain.name} ETH from a public faucet.`}</InfoDot></span>
        <a className="act" href="https://hoodi-faucet.pk910.de/" target="_blank" rel="noreferrer">Faucet ↗</a>
      </li>
      <li data-shut={!funded || undefined}>
        <span className="rlabel">Get wstETH<InfoDot>Stakes your ETH with Lido and wraps the stETH.</InfoDot></span>
        {stake.field(Boolean(busy))}
        {act('stake', 'Deposit', funded)}
      </li>
      <li data-shut={!staked || undefined}>
        <span className="rlabel">Get receipts<InfoDot>Request a withdrawal to get receipts to sell on harbor for instant liquidity.</InfoDot></span>
        {request.field(Boolean(busy))}
        {act('request', 'Get receipts', staked)}
      </li>
    </ol>
    {result.owner === address && result.error && <p className="note" role="alert">{result.error}</p>}
    {result.owner === address && result.hash && result.kind && (
      <TxToast hash={result.hash} pending={result.pending}
        title={result.kind === 'stake' ? 'Deposit confirmed' : 'Receipt created'}
        detail={result.kind === 'stake'
          ? `${formatWei(result.amount ?? 0n, 18)} ETH staked for wstETH`
          : `${formatWei(result.amount ?? 0n, 18)} wstETH queued${result.requestId !== undefined ? ` · withdrawal NFT #${result.requestId}` : ''}`}
        onDismiss={() => setResult({})} />
    )}
    {balances.error && <p className="note" role="alert">{balances.error}</p>}
  </div></div></div>;
}
