import type { Receipt } from '@/lib/swap/types';
import { formatWeiFixed } from '@/lib/format';

type Props = {
  receipts: Receipt[];
  selectedId: number | null;
  onSelect: (requestId: number) => void;
};

/**
 * List first, because the question is WHICH receipt, not how much of one.
 * A receipt is a whole claim on one queued request; there is no amount to type.
 *
 * Entitlement and mark sit adjacent so the gap between them explains itself:
 * the mark is the conservative price reference, always below what the receipt
 * eventually pays at recovery.
 */
export default function ReceiptList({ receipts, selectedId, onSelect }: Props) {
  return (
    <div className="list">
      <div className="rhead">
        <span>request</span>
        <span>entitlement</span>
        <span>mark</span>
        <span>queued</span>
        <span />
      </div>

      {receipts.map(r => {
        // a queued receipt can always be inspected, even when Harbor is not
        // quoting it - the quote panel is where it explains why
        const selectable = r.state === 'pending';
        const quoted = r.markWei !== null;
        return (
          <button
            type="button"
            key={r.requestId}
            className="rcpt"
            disabled={!selectable}
            aria-pressed={selectable && r.requestId === selectedId}
            onClick={() => onSelect(r.requestId)}
          >
            <span className="rid">#{r.requestId}</span>
            <span className="ent">{formatWeiFixed(r.entitlementWei, 18, 4)}</span>
            <span className="mk">
              {quoted ? formatWeiFixed(r.markWei as bigint, 18, 4) : selectable ? 'not quoted' : r.state}
            </span>
            <span className="qd">{selectable ? `${r.queuedDays}d` : '—'}</span>
            <span className="chev">{selectable ? '›' : '✕'}</span>
          </button>
        );
      })}
    </div>
  );
}
