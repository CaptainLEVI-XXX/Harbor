import type { Receipt } from '@/lib/swap/types';
import { formatWei } from '@/lib/swap/format';

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
        const tradable = r.state === 'pending' && r.markWei !== null;
        return (
          <button
            type="button"
            key={r.requestId}
            className="rcpt"
            disabled={!tradable}
            aria-pressed={tradable && r.requestId === selectedId}
            onClick={() => onSelect(r.requestId)}
          >
            <span className="rid">#{r.requestId}</span>
            <span className="ent">{formatWei(r.entitlementWei, 18)}</span>
            <span className="mk">{r.markWei !== null ? formatWei(r.markWei, 18) : r.state}</span>
            <span className="qd">{tradable ? `${r.queuedDays}d` : '—'}</span>
            <span className="chev">{tradable ? '›' : '✕'}</span>
          </button>
        );
      })}
    </div>
  );
}
