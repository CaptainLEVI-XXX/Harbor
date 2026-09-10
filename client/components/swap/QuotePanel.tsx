import type { Quote } from '@/lib/swap/types';
import { formatWei } from '@/lib/format';

export type QuoteRow = {
  label: string;
  /** a quiet qualifier after the label - "included", "at recovery" */
  hint?: string;
  value: string;
  /** the one value that moves. At most one row per view carries it. */
  accent?: boolean;
};

type Props = { quote: Quote; rows: QuoteRow[]; now: number };

function countdown(expiresAt: number, now: number): string {
  const left = Math.max(0, Math.ceil((expiresAt - now) / 1000));
  return `expires in ${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`;
}

const TITLE: Partial<Record<Quote['state'], string>> = {
  requesting: 'Requesting quote',
  unavailable: 'No quote available',
  wontfill: 'Above the book',
};

/**
 * The quote sits flat on the modal face behind a hairline - depth 4. It is
 * never a card: a second raised surface inside a raised surface reads as
 * clutter, and the quote is a consequence of the wells above it, not a peer.
 */
export default function QuotePanel({ quote, rows, now }: Props) {
  if (quote.state === 'idle') return null;

  const settled = quote.state === 'firm' || quote.state === 'expired';
  const showFigures = settled;

  return (
    <div className={`sec${quote.state === 'expired' ? ' dim' : ''}`}>
      <div className="qhead">
        <b>{TITLE[quote.state] ?? 'Quote'}</b>
        {settled && (
          <span className="count">
            {quote.state === 'expired' || quote.expiresAt === null
              ? 'expired'
              : countdown(quote.expiresAt, now)}
          </span>
        )}
      </div>

      {showFigures &&
        rows.map(row => (
          <div className="qrow" key={row.label}>
            <span>
              {row.label}
              {row.hint && <small>{row.hint}</small>}
            </span>
            <span className={row.accent ? 'big' : undefined}>{row.value}</span>
          </div>
        ))}

      {quote.state === 'requesting' && (
        <p className="qnote">Asking the vault for a signed price. Nothing is committed yet.</p>
      )}

      {quote.reason && <p className="qnote">{quote.reason}</p>}

      {quote.state === 'wontfill' && quote.limitWei !== undefined && (
        <p className="qnote">
          The vault will fill up to {formatWei(quote.limitWei, 18)} wstETH in one trade. Reduce the
          amount to get a quote.
        </p>
      )}
    </div>
  );
}
