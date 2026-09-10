import type { ExitTicket } from '@/lib/earn/types';
import { ASSET_DECIMALS } from '@/lib/earn/types';
import { formatWeiFixed } from '@/lib/format';

/**
 * Three states of the same money: requested, funded, claimed.
 *
 * The connector is solid for distance covered and dashed for the wait - the
 * dashes ARE the waiting, which is the whole point of the component. Partial
 * funding is the normal case, not an edge case: the queue funds oldest-first
 * and stops at a partial head.
 */
export default function ExitTracker({ ticket }: { ticket: ExitTicket }) {
  const funded = ticket.fundedWei > 0n;
  const amount = (wei: bigint) => formatWeiFixed(wei, ASSET_DECIMALS, 4);

  return (
    <div className="track well">
      <h3>Your withdrawal</h3>
      <div className="rail-line">
        <div className="bar" />
        <div className="fill" style={{ width: funded ? 'calc(50% - 5px)' : 0 }} />
        <div className="node on" style={{ left: 5 }} />
        <div className={`node${funded ? ' on' : ''}`} style={{ left: '50%' }} />
        <div className="node" style={{ left: 'calc(100% - 5px)' }} />
      </div>
      <div className="tlabs">
        <div>
          Requested<b>{amount(ticket.requestedWei)} WETH</b>
        </div>
        <div>
          Funded
          <b>{funded ? `${amount(ticket.fundedWei)} of ${amount(ticket.requestedWei)}` : 'not yet'}</b>
        </div>
        <div className="idle">
          Claim<b>—</b>
        </div>
      </div>
    </div>
  );
}
