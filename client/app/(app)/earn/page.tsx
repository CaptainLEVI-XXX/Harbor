'use client';

import VaultHero from '@/components/earn/VaultHero';
import CapitalSection from '@/components/earn/CapitalSection';
import ExitAndAbout from '@/components/earn/ExitAndAbout';
import ActivityList from '@/components/earn/ActivityList';
import PositionCard from '@/components/earn/PositionCard';
import VaultPanel from '@/components/earn/VaultPanel';
import { useConnect } from '@/components/PrivyProvider';
import { allocationSeries, sharePriceWad, yieldSeries } from '@/lib/earn/derive';
import {
  CHECKPOINTS,
  EXIT_LIQUIDITY,
  FILLS,
  POSITION,
  STRATEGIES,
  TICKET,
} from '@/lib/earn/fixtures';

const yieldPoints = yieldSeries(CHECKPOINTS);
const allocPoints = allocationSeries(CHECKPOINTS, STRATEGIES);
const latest = CHECKPOINTS[CHECKPOINTS.length - 1];
const priceWad = sharePriceWad(latest.navWei, latest.supplyRaw);

const apyPct = yieldPoints[yieldPoints.length - 1]?.trailingPct ?? 0;
const monthAgo = yieldPoints[yieldPoints.length - 31]?.trailingPct ?? apyPct;
const volume30dWei = STRATEGIES.reduce((sum, s) => sum + (s.volume30dWei ?? 0n), 0n);

/**
 * The vault. One vault today, so /earn is the detail page and there is no list.
 *
 * The ticket is shown for anyone connected: this is a mock build, and an exit
 * in flight is the state worth reviewing. Nothing here constructs a transaction.
 */
export default function EarnPage() {
  const { label, connected, onConnect } = useConnect();

  return (
    <div className="earn">
      <div className="col">
        <VaultHero
          apyPct={apyPct}
          deltaPct={apyPct - monthAgo}
          navWei={latest.navWei}
          volume30dWei={volume30dWei}
          priceWad={priceWad}
          points={yieldPoints}
        />
        <CapitalSection points={allocPoints} strategies={STRATEGIES} />
        <ExitAndAbout liquidity={EXIT_LIQUIDITY} />
        <ActivityList fills={FILLS} />
      </div>

      <aside className="rail">
        {connected && <PositionCard position={POSITION} />}
        <VaultPanel
          connected={connected}
          connectLabel={label}
          onConnect={onConnect}
          ticket={connected ? TICKET : null}
          priceWad={priceWad}
          liquidity={EXIT_LIQUIDITY}
        />
      </aside>
    </div>
  );
}
