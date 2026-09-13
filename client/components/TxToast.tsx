'use client';

import { useEffect, useState } from 'react';
import type { Hex } from 'viem';
import { chain, publicClient } from '@/lib/chain';
import { formatWei } from '@/lib/format';
import { truncateAddress, useSigner } from '@/lib/wallet';

type Props = {
  /** the summary line: what happened, in the units it settled in */
  detail?: string;
  /** where the transaction can be read, on the chain's own explorer */
  href?: string;
  /** a run that did not land says so here instead */
  error?: string;
  /** submitted and waiting for a block */
  pending?: boolean;
  /** the transaction, so the notice can state its block and network fee */
  hash?: Hex;
  title?: string;
  failTitle?: string;
  onDismiss: () => void;
};

/** the one moment this surface earns a mark: it landed */
function Landed() {
  return (
    <span className="toastmark" aria-hidden="true">
      <svg viewBox="0 0 24 24" fill="none">
        <path d="M5.5 12.4 10 16.9 18.6 7.6" stroke="#4A2F6B" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    </span>
  );
}

/** a ring that turns while the chain has not answered yet */
function Waiting() {
  return (
    <span className="toastmark" aria-hidden="true">
      <svg viewBox="0 0 24 24" fill="none" className="toastspin">
        <circle cx="12" cy="12" r="7.5" stroke="rgba(74,47,107,.18)" strokeWidth="2.4" />
        <path d="M12 4.5a7.5 7.5 0 0 1 7.5 7.5" stroke="#4A2F6B" strokeWidth="2.4" strokeLinecap="round" />
      </svg>
    </span>
  );
}

/**
 * A transaction confirms on chain, not in this tab: by the time it lands the
 * person has usually looked away from the button they pressed. So the outcome
 * comes back as its own surface - the deck's frosted glass at a quarter of its
 * weight - carrying what the page cannot show: the transaction itself, the
 * block it landed in, what it cost, and the wallet that signed it.
 *
 * It holds for a while once confirmed and then leaves. A failure, or a
 * transaction still waiting, stays until it is read.
 */
export default function TxToast({ detail, href, error, pending = false, hash, title = 'Transaction completed', failTitle = 'Swap failed', onDismiss }: Props) {
  const signer = useSigner();
  const [landed, setLanded] = useState<{ hash: Hex; block: bigint; fee: bigint }>();
  const receipt = landed?.hash === hash ? landed : undefined;
  // A hash is only returned once a node has accepted the transaction, so the
  // moment there is one it is sent - no second lookup, no timer.
  const sent = pending && Boolean(hash);

  useEffect(() => {
    if (error || pending) return;
    const id = setTimeout(onDismiss, 14_000);
    return () => clearTimeout(id);
  }, [error, pending, onDismiss]);

  // the receipt is already final when this renders confirmed; reading it back
  // is what lets the notice state the block and the fee rather than guess them
  useEffect(() => {
    if (!hash || pending || error) return;
    let cancelled = false;
    publicClient.getTransactionReceipt({ hash })
      .then(r => { if (!cancelled) setLanded({ hash, block: r.blockNumber, fee: r.gasUsed * r.effectiveGasPrice }); })
      .catch(() => {});
    return () => { cancelled = true; };
  }, [hash, pending, error]);

  const heading = error ? failTitle : sent ? 'Sent' : pending ? 'Sending…' : title;
  const link = href ?? (hash ? `${chain.blockExplorers.default.url}/tx/${hash}` : undefined);

  return (
    <div className="toastdock">
      <div className="toast" data-tone={error ? 'failed' : sent ? 'sent' : pending ? 'pending' : 'done'} role={error ? 'alert' : 'status'} aria-live="polite">
        {!error && (pending && !sent ? <Waiting /> : <Landed />)}
        <div className="toastbody">
          <strong>{heading}</strong>
          {error ? <small>{error}</small> : detail && <small>{detail}</small>}
          {sent && <>
            <small>Confirming in the next block</small>
            {/* a Hoodi slot is 12s; the line fills toward it and waits if the block is late */}
            <span className="toastbar" aria-hidden="true"><i key={hash} /></span>
          </>}
          {!error && (receipt || signer) && (
            <dl className="toastmeta">
              {receipt && <><dt>Block</dt><dd className="num">{receipt.block.toString()}</dd></>}
              {receipt && <><dt>Network fee</dt><dd className="num">{formatWei(receipt.fee, 18, 6)} ETH</dd></>}
              {signer && <><dt>Signed by</dt><dd>{signer.name} · <span className="num">{truncateAddress(signer.address)}</span></dd></>}
            </dl>
          )}
          {link && !error && (
            <a href={link} target="_blank" rel="noreferrer" className="toastlink">
              View on explorer<span aria-hidden="true"> ↗</span>
            </a>
          )}
        </div>
        <button type="button" className="toastx" aria-label="Dismiss notification" onClick={onDismiss}>
          <svg viewBox="0 0 16 16" fill="none" aria-hidden="true">
            <path d="M4 4l8 8M12 4l-8 8" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
          </svg>
        </button>
      </div>
    </div>
  );
}
