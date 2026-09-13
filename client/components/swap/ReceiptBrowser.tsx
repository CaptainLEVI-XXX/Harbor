'use client';

import { useEffect, useRef, useState, type KeyboardEvent } from 'react';
import * as Dialog from '@radix-ui/react-dialog';
import type { Address } from 'viem';
import TokenMark from '@/components/TokenMark';
import { useResource } from '@/lib/harbor/useResource';
import { listNfts } from '@/lib/harbor/nfts';
import { formatWei } from '@/lib/format';

export type SelectedReceipt = { address: Address; route: bigint; tokenId: bigint; entitlement?: bigint; requestedAt?: bigint };

type Props = {
  user?: Address;
  buying: boolean;
  selected?: SelectedReceipt;
  onSelect: (receipt: SelectedReceipt) => void;
  now: number;
};

/** how long a request has waited in the issuer's queue, at a glance */
function age(requestedAt: bigint | undefined, now: number): string {
  if (requestedAt === undefined) return '—';
  const minutes = Math.max(0, Math.floor((now / 1000 - Number(requestedAt)) / 60));
  if (minutes < 60) return `${minutes}m`;
  if (minutes < 60 * 24) return `${Math.floor(minutes / 60)}h`;
  return `${Math.floor(minutes / (60 * 24))}d`;
}

function Check() {
  return (
    <svg viewBox="0 0 16 16" fill="none" aria-hidden="true">
      <path d="M3.5 8.4 6.6 11.4 12.5 4.8" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

/** arrow keys walk the rows, as they would in any list you pick one thing from */
function walk(event: KeyboardEvent<HTMLUListElement>) {
  if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
  const rows = [...event.currentTarget.querySelectorAll<HTMLButtonElement>('button')];
  const at = rows.indexOf(document.activeElement as HTMLButtonElement);
  const next = rows[at + (event.key === 'ArrowDown' ? 1 : -1)];
  if (next) { event.preventDefault(); next.focus(); }
}

/**
 * The receipt leg of a receipt trade. A receipt is one whole claim, so there is
 * no amount to type: the panel names WHICH receipt, and the picker behind the
 * pill is where you choose it. The picker is single-choice by construction -
 * choosing a row closes it.
 *
 * The panel always says what the list holds (loading, empty, how many), so the
 * state is readable before the picker is ever opened.
 */
export default function ReceiptBrowser({ user, buying, selected, onSelect, now }: Props) {
  const [open, setOpen] = useState(false);
  const list = useRef<HTMLUListElement>(null);
  // whether rows sit below the cut, so the fade appears only when it means something
  const [more, setMore] = useState(false);
  const measure = () => {
    const el = list.current;
    setMore(Boolean(el) && el!.scrollTop + el!.clientHeight < el!.scrollHeight - 2);
  };
  const nfts = useResource('nfts:' + buying + ':' + (user ?? 'public'), () => listNfts(user, buying), 15000);
  const locked = !buying && !user;
  const rows = locked ? [] : nfts.data?.rows ?? [];

  // the panel's line is short - it shares its row with the notch - and the
  // picker repeats it in full
  const status = locked ? 'Connect to see receipts'
    : nfts.error ? 'Receipts unavailable'
    : nfts.loading && !nfts.data ? 'Loading receipts…'
    : rows.length === 0 ? (buying ? 'Nothing in inventory' : 'None in your wallet')
    : `${rows.length}${nfts.data?.truncated ? '+' : ''} ${buying ? 'in inventory' : 'in your wallet'}`;
  const explained = locked ? 'Connect your wallet to see your receipts.'
    : nfts.error ?? (rows.length === 0 && nfts.data ? (buying ? 'Nothing in inventory.' : 'No pending withdrawal NFTs in your wallet.') : status);

  const count = rows.length;
  useEffect(() => {
    if (!open) return;
    const frame = requestAnimationFrame(measure);
    return () => cancelAnimationFrame(frame);
  }, [open, count]);

  function choose(receipt: SelectedReceipt) {
    onSelect(receipt);
    setOpen(false);
  }

  return (
    <>
      <div className="frow"><span className="flabel">{buying ? 'You receive' : 'You sell'}</span></div>
      <div className="amt">
        <span className={`rpick${selected ? '' : ' none'}`}>{selected ? `#${selected.tokenId.toString()}` : '—'}</span>
        <Dialog.Root open={open} onOpenChange={setOpen}>
          <Dialog.Trigger className="asset" aria-label={selected ? 'Change receipt' : 'Select a receipt'}>
            <TokenMark symbol="receipt" />
            <span>{selected ? 'Receipt' : 'Select'}</span>
            <span className="caret" aria-hidden="true">▾</span>
          </Dialog.Trigger>
          <Dialog.Portal>
            <Dialog.Overlay className="rveil" />
            <Dialog.Content className="rsheet">
              <div className="rsheet-head">
                <div>
                  <Dialog.Title>Select a receipt</Dialog.Title>
                  <Dialog.Description>
                    {buying
                      ? 'Pending withdrawal NFTs in harbor’s inventory. You buy one whole receipt.'
                      : 'Pending withdrawal NFTs in your wallet. You sell one whole receipt.'}
                  </Dialog.Description>
                </div>
                <Dialog.Close className="rclose" aria-label="Close">
                  <svg viewBox="0 0 12 12" fill="none" aria-hidden="true"><path d="M2.5 2.5l7 7m0-7-7 7" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" /></svg>
                </Dialog.Close>
              </div>

              {rows.length > 0 ? (
                <>
                  <div className="rcols" aria-hidden="true"><span>NFT ID</span><span>Nominal</span><span>Queued</span><span /></div>
                  <div className="rscroll" data-more={more ? '' : undefined}>
                    <ul className="rrows" ref={list} onScroll={measure} onKeyDown={walk}>
                      {rows.map(r => {
                        const on = selected?.tokenId === r.tokenId;
                        return (
                          <li key={r.tokenId.toString()}>
                            <button type="button" className="ropt" aria-pressed={on} autoFocus={on} onClick={() => choose(r)}>
                              <span className="rid">#{r.tokenId.toString()}</span>
                              <span className="ent">{formatWei(r.entitlement, 18)} <small>ETH</small></span>
                              <span className="qd">{age(r.requestedAt, now)}</span>
                              <span className="rtick">{on && <Check />}</span>
                            </button>
                          </li>
                        );
                      })}
                    </ul>
                  </div>
                </>
              ) : (
                <p className="rempty" role={nfts.error ? 'alert' : 'status'}>{explained}</p>
              )}

              <p className="rfoot">
                {nfts.data?.truncated ? 'Showing the first 100 withdrawal IDs. ' : ''}
                Nominal is the amount each withdrawal was requested for, not harbor’s price. The quote follows your choice.
              </p>
            </Dialog.Content>
          </Dialog.Portal>
        </Dialog.Root>
      </div>
      <div className="fmeta">
        <span>{selected?.entitlement !== undefined ? `${formatWei(selected.entitlement, 18)} ETH nominal` : status}</span>
        <span>{selected ? `Queued ${age(selected.requestedAt, now)}` : 'One whole receipt'}</span>
      </div>
    </>
  );
}
