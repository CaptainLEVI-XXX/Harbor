import type { ReactNode } from 'react';
import type { Quote } from '@/lib/swap/types';

type QuoteRow = {
  label: string;
  value: string;
  /** a quiet qualifier before the value - "Auto" */
  chip?: string;
  /** a mark before the value - the venue's logo */
  icon?: ReactNode;
};

type Props = { quote: Quote; rows: QuoteRow[]; now: number; block?: bigint; source?: 'SwapVM' | 'harbor NFT' };

function countdown(expiresAt: number, now: number): string {
  const left = Math.max(0, Math.ceil((expiresAt - now) / 1000));
  return `refresh in ${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`;
}

const TITLE: Partial<Record<Quote['state'], string>> = {
  requesting: 'Requesting quote',
  unavailable: 'No quote available',
};

/**
 * The quote sits flat on the modal face behind a hairline - depth 4. It is
 * never a card: a second raised surface inside a raised surface reads as
 * clutter, and the quote is a consequence of the panels above it, not a peer.
 *
 * A stale quote is NOT faded. Dimming the figures makes them hard to read
 * while saying nothing about what to do; the status label and the action
 * button both say "refresh", which is the actual answer.
 */
export default function QuotePanel({ quote, rows, now, block, source = 'SwapVM' }: Props) {
  if (quote.state === 'idle') return null;

  const settled = quote.state === 'firm' || quote.state === 'expired';
  const showFigures = settled;

  return (
    <div className="sec">
      <div className="qhead">
        <b>
          {TITLE[quote.state] ?? source + ' quote'}
          {block !== undefined && <em className="qblock">block <i>{block.toString()}</i></em>}
        </b>
        {settled && (
          <span className="count">
            {quote.state === 'expired' || quote.expiresAt === null
              ? 'refresh needed'
              : countdown(quote.expiresAt, now)}
          </span>
        )}
      </div>

      {showFigures &&
        rows.map(row => (
          <div className="qrow" key={row.label}>
            <span>{row.label}</span>
            <span>
              {row.chip && <em className="chip">{row.chip}</em>}
              {row.icon}
              {row.value}
            </span>
          </div>
        ))}

      {quote.state === 'requesting' && (
        <p className="qnote">{source === 'SwapVM' ? 'Reading the canonical SwapVM program.' : 'Reading the harbor NFT pricing and issuer state.'} No signature is required and no liquidity is reserved.</p>
      )}

      {quote.reason && <p className="qnote">{quote.reason}</p>}

    </div>
  );
}
