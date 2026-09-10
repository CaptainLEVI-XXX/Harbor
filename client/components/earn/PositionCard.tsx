import type { Position } from '@/lib/earn/types';
import { ASSET_DECIMALS, SHARE_DECIMALS } from '@/lib/earn/types';
import { formatSigned, formatWeiFixed } from '@/lib/format';

/** A summary only. Deposit history and reporting belong to Portfolio. */
export default function PositionCard({ position }: { position: Position }) {
  return (
    <div className="pos modal">
      <div className="top">
        <span className="lab">Your position</span>
        <b className="big num">
          {formatWeiFixed(position.valueWei, ASSET_DECIMALS, 4)}
          <i>WETH</i>
        </b>
      </div>
      <div className="bot">
        <span className="num">{formatWeiFixed(position.sharesRaw, SHARE_DECIMALS, 4)} hWETH</span>
        <span>
          Earned{' '}
          <b className={`num ${position.earnedWei < 0n ? 'loss' : 'gain'}`}>
            {formatSigned(position.earnedWei, ASSET_DECIMALS, 4)}
          </b>
        </span>
      </div>
    </div>
  );
}
