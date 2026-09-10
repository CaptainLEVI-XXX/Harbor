import YieldChart from '@/components/charts/YieldChart';
import type { YieldPoint } from '@/lib/earn/derive';
import { ASSET_DECIMALS } from '@/lib/earn/types';
import { formatWeiFixed } from '@/lib/format';

type Props = {
  apyPct: number;
  /** change in the trailing APY against a month ago */
  deltaPct: number;
  navWei: bigint;
  volume30dWei: bigint;
  priceWad: bigint;
  points: YieldPoint[];
};

/** Thousands separators on the whole part, fraction left alone. */
function grouped(value: string): string {
  const [whole, fraction] = value.split('.');
  const separated = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return fraction ? `${separated}.${fraction}` : separated;
}

/**
 * Name, headline, three stats and the yield chart share ONE modal. They are one
 * argument, not four widgets - chopping them into equal cards is the default.
 */
export default function VaultHero({ apyPct, deltaPct, navWei, volume30dWei, priceWad, points }: Props) {
  const volume = Number(volume30dWei / 10n ** BigInt(ASSET_DECIMALS));
  const sign = deltaPct < 0 ? 'loss' : 'gain';
  const delta = `${deltaPct < 0 ? '−' : '+'}${Math.abs(deltaPct).toFixed(2)} vs last month`;

  return (
    <section className="modal">
      <div className="ident">
        <div className="vname">
          <div className="badge">hW</div>
          <div>
            <h1>Harbor WETH</h1>
            <p>Deposit WETH, hold hWETH. One vault, live since 12 August.</p>
          </div>
        </div>
        <div className="hero-apy">
          <b>{apyPct.toFixed(2)}%</b>
          <span className="lab">30-day APY</span>
          <span className={`delta ${sign}`}>{delta}</span>
        </div>
      </div>

      <div className="stats">
        <div className="stat">
          <span>Total value</span>
          <b>{grouped(formatWeiFixed(navWei, ASSET_DECIMALS, 3))}</b>
          <i>WETH</i>
        </div>
        <div className="stat">
          <span>Traded, 30 days</span>
          <b>{volume >= 10_000 ? `${(volume / 1000).toFixed(2)}k` : volume.toFixed(0)}</b>
          <i>WETH</i>
        </div>
        <div className="stat">
          <span>hWETH price</span>
          <b>{formatWeiFixed(priceWad, 18, 4)}</b>
          <i>WETH</i>
        </div>
      </div>

      <YieldChart points={points} />
    </section>
  );
}
