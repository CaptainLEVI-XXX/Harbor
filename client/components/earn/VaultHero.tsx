import HarborMark from '@/components/HarborMark';
import { ASSET_DECIMALS } from '@/lib/earn/types';
import { formatWeiFixed, group } from '@/lib/format';
import { useDisplayPrice } from '@/lib/harbor/DisplayPriceProvider';

type Props = {
  apyPct: number | null;
  /** set when the APY is an estimate from short history, and says how short */
  apyNote?: string;
  navWei: bigint | null;
  tradedWei: bigint | null;
  priceWad: bigint | null;
};

/**
 * The name sits on the page itself; each figure gets its own pane of glass.
 * The APY leads the row because it is the question a depositor arrives with,
 * and a missing figure stays a dash - never a zero.
 */
export default function VaultHero({ apyPct, apyNote, navWei, tradedWei, priceWad }: Props) {
  const { usd } = useDisplayPrice();
  const traded = tradedWei === null ? null : Number(tradedWei / 10n ** BigInt(ASSET_DECIMALS));

  return (
    <section className="hero">
      <div className="vname">
        <div className="vaultmark" aria-hidden="true"><HarborMark face="weth" /></div>
        <div>
          <h1>harbor WETH</h1>
          <p>Deposit ETH, hold hWETH.</p>
        </div>
      </div>

      <div className="metrics">
        <div className="metric hero-apy">
          <span className="lab">{apyNote ? 'Est. 30-day APY' : '30-day APY'}</span>
          <b>{apyPct === null ? '—' : `${apyPct.toFixed(2)}%`}</b>
          {/* no history is not a gain: the note is set in neutral ink */}
          <span className="delta none">{apyNote ?? 'Insufficient history'}</span>
        </div>
        <div className="metric">
          <span className="lab">Total value</span>
          <div className="fig">
            <b>{navWei === null ? '—' : group(formatWeiFixed(navWei, ASSET_DECIMALS, 3))}</b>
            <i>WETH</i>
          </div>
          {navWei !== null && <small className="usd">{usd(navWei)}</small>}
        </div>
        <div className="metric">
          <span className="lab">Traded, all time</span>
          <div className="fig">
            <b>{traded === null || tradedWei === null ? '—' : traded >= 10_000 ? `${(traded / 1000).toFixed(2)}k` : group(formatWeiFixed(tradedWei, ASSET_DECIMALS, 3))}</b>
            <i>WETH</i>
          </div>
          {tradedWei !== null && <small className="usd">{usd(tradedWei)}</small>}
        </div>
        <div className="metric">
          <span className="lab">hWETH price</span>
          <div className="fig">
            <b>{priceWad === null ? '—' : formatWeiFixed(priceWad, 18, 4)}</b>
            <i>WETH</i>
          </div>
          {priceWad !== null && <small className="usd">{usd(priceWad)}</small>}
        </div>
      </div>
    </section>
  );
}
