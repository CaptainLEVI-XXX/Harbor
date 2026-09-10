import type { ExitLiquidity } from '@/lib/earn/types';
import { ASSET_DECIMALS } from '@/lib/earn/types';
import { formatWeiFixed } from '@/lib/format';

/**
 * Two subjects in one card because they are one argument: the mechanism, and
 * its liquidity consequence. Async withdrawal is the biggest surprise this
 * vault can spring on someone, so it sits above the decision, not after it.
 */
export default function ExitAndAbout({ liquidity }: { liquidity: ExitLiquidity }) {
  return (
    <section className="modal">
      <div className="duo">
        <div>
          <div className="shead">
            <h2>Getting out</h2>
          </div>
          <div className="liq">
            <div>
              <span>Ready to pay now</span>
              <b className="num">{formatWeiFixed(liquidity.readyWei, ASSET_DECIMALS, 2)} WETH</b>
            </div>
            <div>
              <span>Already queued</span>
              <b className="num">{formatWeiFixed(liquidity.queuedAheadWei, ASSET_DECIMALS, 2)} WETH</b>
            </div>
            <div>
              <span>Recent exits took</span>
              <b className="num">{liquidity.typicalWait}</b>
            </div>
          </div>
          <p className="note">
            Withdrawals are funded oldest first, as the vault&rsquo;s assets settle. You request an
            amount, wait for it to be funded, then claim it.
          </p>
        </div>

        <div className="rule">
          <div className="shead">
            <h2>How Harbor earns</h2>
          </div>
          <div className="prose">
            <p>
              Every one of these protocols makes you wait to get your ETH back. Harbor buys that
              wait — staked tokens and pending withdrawal tickets, at a discount to what they
              finally settle at — and holds them until they do. <b>The gap is the yield.</b>
            </p>
            <p>
              Sellers get their ETH today instead of queueing. Depositors are paid for carrying the
              wait. One pot of capital serves whichever queue is paying best, which is why the mix
              moves.
            </p>
            <p>
              hWETH is your share of that pot. It pays nothing out; it is worth more WETH over time.
            </p>
          </div>
          <div className="links">
            <a href="#">Vault contract</a>
            <a href="#">Book contract</a>
            <a href="#">Audit</a>
            <a href="#">Docs</a>
          </div>
        </div>
      </div>
    </section>
  );
}
