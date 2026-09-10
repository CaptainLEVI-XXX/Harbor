'use client';

import { useEffect, useMemo, useState } from 'react';
import AssetSelect from '@/components/swap/AssetSelect';
import QuotePanel, { type QuoteRow } from '@/components/swap/QuotePanel';
import ReceiptList from '@/components/swap/ReceiptList';
import { useConnect } from '@/components/PrivyProvider';
import { ASSETS, RECEIPTS } from '@/lib/swap/fixtures';
import { formatWei, parseWei } from '@/lib/format';
import { quoteTokens, quoteReceipt, isExpired } from '@/lib/swap/useQuote';
import type { Direction, TradeMode } from '@/lib/swap/types';

type Surface = 'tokens' | 'receipts';

const PAIR = [ASSETS.wstETH, ASSETS.WETH];

/** Which asset sits on each leg, given the direction. */
function legs(direction: Direction) {
  return direction === 'sell'
    ? { pay: ASSETS.wstETH, receive: ASSETS.WETH }
    : { pay: ASSETS.WETH, receive: ASSETS.wstETH };
}

export default function SwapPage() {
  const { label, onConnect } = useConnect();

  const [surface, setSurface] = useState<Surface>('tokens');
  const [direction, setDirection] = useState<Direction>('sell');
  const [mode, setMode] = useState<TradeMode>('exactInput');
  const [typed, setTyped] = useState('1');
  const [selectedId, setSelectedId] = useState<number | null>(RECEIPTS[0].requestId);
  const [now, setNow] = useState(() => Date.now());

  // the countdown has to move: a firm signed quote genuinely dies
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, []);

  const receipt = RECEIPTS.find(r => r.requestId === selectedId) ?? null;
  const { pay, receive } = legs(direction);

  // `now` deliberately stays out of the deps: re-pricing every second would
  // reset the expiry the countdown is there to show running out.
  const quote = useMemo(
    () =>
      surface === 'receipts'
        ? quoteReceipt(receipt?.markWei ?? null, now)
        : quoteTokens({ amountWei: parseWei(typed, 18) ?? 0n, mode, direction, now }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [surface, typed, mode, direction, receipt?.markWei],
  );

  const shown = isExpired(quote, now) ? { ...quote, state: 'expired' as const } : quote;

  /**
   * The leg the user is not typing into, rendered from the quote. Only a firm
   * quote has figures: showing 0 when nothing was quoted would read as a price.
   */
  const derived =
    quote.state === 'firm'
      ? formatWei(mode === 'exactInput' ? quote.receiveWei : quote.payWei, 18)
      : '';

  const payValue = mode === 'exactInput' ? typed : derived;
  const receiveValue = mode === 'exactInput' ? derived : typed;

  const rows: QuoteRow[] =
    surface === 'tokens'
      ? [
          { label: 'Rate', value: quote.rate },
          { label: 'Harbor fee', hint: 'included', value: `${formatWei(quote.feeWei, 18)} ${receive.symbol}` },
          {
            label: mode === 'exactInput' ? 'You receive' : 'You pay',
            value:
              mode === 'exactInput'
                ? `${formatWei(quote.receiveWei, 18)} ${receive.symbol}`
                : `${formatWei(quote.payWei, 18)} ${pay.symbol}`,
            accent: true,
          },
        ]
      : [
          { label: 'You give', value: `1 receipt · #${selectedId}` },
          { label: 'You receive', value: `${formatWei(quote.receiveWei, 18)} WETH`, accent: true },
          {
            label: 'Entitlement',
            hint: 'at recovery',
            value: receipt ? `${formatWei(receipt.entitlementWei, 18)} ETH` : '—',
          },
          {
            label: 'Conservative mark',
            hint: 'price reference',
            value: receipt?.markWei != null ? `${formatWei(receipt.markWei, 18)} ETH` : '—',
          },
          { label: 'Harbor fee', hint: 'included', value: `${formatWei(quote.feeWei, 18)} WETH` },
        ];

  const action =
    shown.state === 'idle' ? 'Enter an amount'
    : shown.state === 'wontfill' ? 'Amount too large'
    : shown.state === 'unavailable' ? 'Not quotable'
    : shown.state === 'expired' ? 'Refresh quote'
    : label;

  const disabled = shown.state === 'idle' || shown.state === 'wontfill' || shown.state === 'unavailable';

  function onAction() {
    // a stale quote is refreshed in place; a live one is a wallet's problem
    if (shown.state === 'expired') setNow(Date.now());
    else onConnect();
  }

  function reverse() {
    setDirection(d => (d === 'sell' ? 'buy' : 'sell'));
    // keep whichever number the user typed - the other leg re-derives
  }

  function chooseAsset(leg: 'pay' | 'receive', symbol: string) {
    const wantSell = leg === 'pay' ? symbol === 'wstETH' : symbol === 'WETH';
    setDirection(wantSell ? 'sell' : 'buy');
  }

  return (
    <div className="swap-wrap">
      <div className="panel">
        <div className="modal">
          <div className="swap-head">
            <div>
              <h1>{surface === 'tokens' ? 'Swap inventory' : 'Trade withdrawal receipts'}</h1>
              <p>
                {surface === 'tokens'
                  ? 'Quoted both ways, at exact amounts.'
                  : 'One request, one whole receipt. Never a fraction.'}
              </p>
            </div>
            <div className="seg">
              <button type="button" aria-pressed={surface === 'tokens'} onClick={() => setSurface('tokens')}>
                Tokens
              </button>
              <button type="button" aria-pressed={surface === 'receipts'} onClick={() => setSurface('receipts')}>
                Receipts
              </button>
            </div>
          </div>

          {surface === 'tokens' ? (
            <>
              <div className="well">
                <div className="frow">
                  <span className="flabel">Pay</span>
                  <span className="flabel">Ethereum</span>
                </div>
                <div className="amt">
                  <input
                    aria-label="Amount you pay"
                    className={mode === 'exactOutput' ? 'out' : undefined}
                    inputMode="decimal"
                    placeholder="0"
                    value={payValue}
                    onChange={e => {
                      setMode('exactInput');
                      setTyped(e.target.value);
                    }}
                  />
                  <AssetSelect
                    label="Pay asset"
                    value={pay.symbol}
                    options={PAIR}
                    onChange={s => chooseAsset('pay', s)}
                  />
                </div>
                <div className="fmeta">
                  <span>{pay.name}</span>
                  <span>Balance —</span>
                </div>
              </div>

              <div className="rev">
                <button type="button" aria-label="Reverse direction" onClick={reverse}>
                  ⇅
                </button>
              </div>

              <div className="well">
                <div className="frow">
                  <span className="flabel">Receive</span>
                  <span className="flabel">Fee included</span>
                </div>
                <div className="amt">
                  <input
                    aria-label="Amount you receive"
                    className={mode === 'exactInput' ? 'out' : undefined}
                    inputMode="decimal"
                    placeholder="0"
                    value={receiveValue}
                    onChange={e => {
                      setMode('exactOutput');
                      setTyped(e.target.value);
                    }}
                  />
                  <AssetSelect
                    label="Receive asset"
                    value={receive.symbol}
                    options={PAIR}
                    onChange={s => chooseAsset('receive', s)}
                  />
                </div>
                <div className="fmeta">
                  <span>{receive.name}</span>
                  <span>Balance —</span>
                </div>
              </div>
            </>
          ) : (
            <ReceiptList receipts={RECEIPTS} selectedId={selectedId} onSelect={setSelectedId} />
          )}

          <QuotePanel quote={shown} rows={rows} now={now} />

          <button type="button" className="act" disabled={disabled} onClick={onAction}>
            {action}
          </button>
        </div>

        <p className="swap-foot">
          {surface === 'tokens'
            ? 'exact quoted amounts · the whole trade completes or reverts'
            : 'receipts are whole units · one receipt, one queued request'}
        </p>
      </div>
    </div>
  );
}
