'use client';

import { useState } from 'react';
import AllocationChart from '@/components/charts/AllocationChart';
import StrategyTable, { type StrategyRow } from './StrategyTable';
import type { AllocationPoint } from '@/lib/earn/derive';
import { sharePct } from '@/lib/earn/derive';
import type { Strategy } from '@/lib/earn/types';

type Props = { points: AllocationPoint[]; strategies: Strategy[] };

/**
 * The allocation chart and the strategy table are one card because the table
 * IS the chart's legend. `focus` is owned here so hovering either side lights
 * up the other; that link is the whole reason they are not two sections.
 */
export default function CapitalSection({ points, strategies }: Props) {
  const [focus, setFocus] = useState<string | null>(null);
  const latest = points[points.length - 1];

  const rows: StrategyRow[] = strategies.map((s, i) => ({
    id: s.id,
    valueWei: latest?.bands[i] ?? 0n,
    pct: latest ? sharePct(latest.bands[i] ?? 0n, latest.totalWei) : 0,
  }));

  // cash is where capital sits, not a strategy it works in
  const working = strategies.filter(s => s.id !== 'cash').length;

  return (
    <section className="modal">
      <div className="shead">
        <h2>Where the capital works</h2>
        <span className="aside">{working} strategies sharing one pot</span>
      </div>

      <AllocationChart points={points} strategies={strategies} focus={focus} onFocus={setFocus} />
      <StrategyTable strategies={strategies} rows={rows} focus={focus} onFocus={setFocus} />

      <p className="note">
        Earned is realised profit in WETH since 12 August. Yield is not split per strategy — it
        accrues to the vault as a whole and shows up in the hWETH price. In queue is capital waiting
        inside an issuer&rsquo;s own withdrawal queue; it is still yours, it is just not spendable yet.
      </p>
    </section>
  );
}
