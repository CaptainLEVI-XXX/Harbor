import type { History } from './history';
import type { AllocationPoint, Band } from '@/lib/earn/types';

export type ActivityKind = 'deposit' | 'bought' | 'sold' | 'recovery' | 'payout';

export function recentActivity(h: History) {
  const events = [
    ...h.lpDeposits.map(e => ({ ...e, kind: 'deposit' as ActivityKind, label: 'Deposited into vault', cash: e.assets })),
    ...h.trades.map(e => ({ ...e, kind: (e.buyBase ? 'bought' : 'sold') as ActivityKind, label: (e.buyBase ? 'Vault bought · ' : 'Vault sold · ') + e.strategy.label + (e.tokenId ? ' #' + e.tokenId : ''), cash: e.customerCash })),
    ...h.claimRecoveries.map(e => ({ ...e, kind: 'recovery' as ActivityKind, label: 'Issuer recovery received', cash: e.cash })),
    ...h.exitPayouts.map(e => ({ ...e, kind: 'payout' as ActivityKind, label: 'Withdrawal paid', cash: e.assets })),
  ];
  return events.sort((a,b) => Number(BigInt(b.blockNumber)-BigInt(a.blockNumber)) || Number(BigInt(b.logIndex)-BigInt(a.logIndex))).slice(0,20);
}

/** Observed NAV per whole share, not annualized yield. Skip zero-supply checkpoints. */
export function shareObservations(h: History) {
  return h.valuationCheckpoints.filter(e => BigInt(e.supply)>0n)
    .sort((a,b) => Number(BigInt(a.blockNumber)-BigInt(b.blockNumber)) || Number(BigInt(a.logIndex)-BigInt(b.logIndex)))
    .map(e => ({ ...e, price: BigInt(e.nav)*10n**24n/BigInt(e.supply) }));
}

const DAY = 86_400_000;
/** a change as a percentage, to four places, without a float until the end */
const change = (next: bigint, prev: bigint) => prev === 0n ? 0 : Number((next - prev) * 1_000_000n / prev) / 10_000;

/**
 * Simple annualised return over the trailing 30 days. Under a week of history
 * an annualised figure is noise dressed as a rate, so there is none.
 */
export function trailingApy(h: History): number | null {
  const obs = shareObservations(h);
  if (obs.length < 2) return null;
  const last = obs[obs.length - 1];
  const end = Number(last.timestamp) * 1000;
  const start = [...obs].reverse().find(o => Number(o.timestamp) * 1000 <= end - 30 * DAY) ?? obs[0];
  const days = (end - Number(start.timestamp) * 1000) / DAY;
  return days < 7 ? null : change(last.price, start.price) * 365 / days;
}

/** What the NAV is made of. Darkest band first, as every stacked chart here is. */
export const COMPOSITION: Band[] = [
  { id: 'inventory', colour: '#4A2F6B' },
  { id: 'claims', colour: '#8B6BB8' },
  { id: 'cash', colour: '#C9B6E6' },
];

/** A share of a total, as a percentage to two places. */
export function sharePct(partWei: bigint, totalWei: bigint): number {
  if (totalWei === 0n) return 0;
  return Number((partWei * 1_000_000n) / totalWei) / 10_000;
}

export function compositionSeries(h: History): AllocationPoint[] {
  return [...h.valuationCheckpoints]
    .sort((a,b) => Number(BigInt(a.blockNumber)-BigInt(b.blockNumber)) || Number(BigInt(a.logIndex)-BigInt(b.logIndex)))
    .map(c => {
      const bands = [BigInt(c.inventoryMark), BigInt(c.claimMark), BigInt(c.cash)];
      return { at: Number(c.timestamp) * 1000, totalWei: bands.reduce((a, b) => a + b, 0n), bands };
    });
}

/**
 * The wallet's average entry price, WETH per whole share (1e18), from its own
 * deposits. Shares that arrived by transfer have no entry here, so this is an
 * estimate - and there is none at all without a deposit.
 */
export function entryPrice(h: History): bigint | null {
  let assets = 0n, shares = 0n;
  for (const d of h.userDeposits ?? []) { assets += BigInt(d.assets); shares += BigInt(d.shares); }
  return shares > 0n ? assets * 10n ** 24n / shares : null;
}

/**
 * An estimate of the 30-day APY from whatever history exists: the share-price
 * return since the first observation, annualised to `now`. Young history makes
 * this noisy, which is why it is only ever shown as an estimate.
 */
export function estimatedApy(h: History, now: number): { pct: number; hours: number } | null {
  const obs = shareObservations(h);
  if (obs.length < 2) return null;
  const start = [...obs].reverse().find(o => Number(o.timestamp) * 1000 <= now - 30 * DAY) ?? obs[0];
  const hours = (now - Number(start.timestamp) * 1000) / 3_600_000;
  if (hours < 1) return null;
  return { pct: change(obs[obs.length - 1].price, start.price) * 8760 / hours, hours };
}

export type StrategyEvent = { at: number; strategy: string; traded: bigint; result: bigint };

/** Every trade and realization as one time-ordered stream, for cumulative lines. */
export function strategyEvents(h: History): StrategyEvent[] {
  return [
    ...(h.tradeSeries ?? []).map(t => ({ at: Number(t.timestamp) * 1000, strategy: t.strategy.id, traded: BigInt(t.customerCash), result: 0n })),
    ...(h.realizations ?? []).map(r => ({ at: Number(r.timestamp) * 1000, strategy: r.strategy.id, traded: 0n, result: BigInt(r.result) })),
  ].sort((a, b) => a.at - b.at);
}
