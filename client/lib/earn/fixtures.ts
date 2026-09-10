import type { Checkpoint, ExitLiquidity, ExitTicket, Fill, Position, Strategy } from './types';

const WEI = 10n ** 18n;
/** WETH wei from a decimal string, e.g. "3279.579". Fixtures only. */
function weth(value: string): bigint {
  const [whole, fraction = ''] = value.split('.');
  return BigInt(whole) * WEI + BigInt(fraction.padEnd(18, '0').slice(0, 18));
}

/**
 * Band colours: ONE hue at six lightnesses, darkest first. Six distinct hues
 * would be six accents; a single-hue ramp stays inside the material system.
 * Order is by size, so the stack reads as a gradient.
 */
export const STRATEGIES: Strategy[] = [
  { id: 'lido', issuer: 'Lido', asset: 'wstETH', colour: '#4A2F6B',
    holding: '1,168.92 wstETH', volume30dWei: weth('59350'), earnedWei: weth('18.4'), inQueueWei: weth('124') },
  { id: 'ethena', issuer: 'Ethena', asset: 'sUSDe', colour: '#6A4A96',
    holding: '1.61M sUSDe', volume30dWei: weth('14200'), earnedWei: weth('6.2'), inQueueWei: weth('88') },
  { id: 'rocket', issuer: 'Rocket Pool', asset: 'rETH', colour: '#8B6BB8',
    holding: '363.42 rETH', volume30dWei: weth('9100'), earnedWei: weth('2.1'), inQueueWei: 0n },
  { id: 'lidoR', issuer: 'Lido', asset: 'receipts', colour: '#B097D8',
    holding: '4 held', volume30dWei: weth('2400'), earnedWei: weth('4.9'), inQueueWei: 0n },
  { id: 'cbeth', issuer: 'Coinbase', asset: 'cbETH', colour: '#C9B6E6',
    holding: '84.59 cbETH', volume30dWei: weth('840'), earnedWei: -weth('0.3'), inQueueWei: weth('41') },
  { id: 'cash', issuer: 'Cash', asset: 'idle WETH', colour: '#DFD3F2',
    holding: '842.40 WETH', volume30dWei: null, earnedWei: null, inQueueWei: 0n },
];

/** Share of NAV each strategy holds at the final checkpoint, in basis points. */
const END_BPS: Record<string, number> = {
  lido: 4220, ethena: 1226, rocket: 1208, lidoR: 497, cbeth: 281, cash: 2568,
};
/** Where each strategy started. */
const START_BPS: Record<string, number> = {
  lido: 6400, ethena: 0, rocket: 900, lidoR: 400, cbeth: 300, cash: 2000,
};
/** When a strategy first appeared, as a fraction through the series. */
const APPEARS: Record<string, number> = { ethena: 0.82, lidoR: 0.35 };

const DAYS = 400;
const END_AT = Date.UTC(2026, 8, 10);
const DAY_MS = 86_400_000;
const END_NAV = weth('3279.579');
/** What the trailing 30-day mean is built to land near. */
const TARGET_APY_PCT = 4.1;

/** Deterministic pseudo-random, so a review and a test see the same page. */
function makeRandom(seed: number): () => number {
  let s = seed;
  return () => ((s = (s * 1664525 + 1013904223) % 4294967296) / 4294967296);
}
const smooth = (t: number) => t * t * (3 - 2 * t);

/**
 * A ValuationCheckpoint series. Every yield figure on the page derives from
 * this one series - the headline, the chart, the month-on-month delta - so
 * they can never disagree with each other.
 */
export const CHECKPOINTS: Checkpoint[] = (() => {
  const rnd = makeRandom(20260910);
  const rows: Checkpoint[] = [];

  // NAV walks up with noise, then is rescaled so the last row is exact.
  const raw: number[] = [];
  let nav = 760;
  for (let i = 0; i < DAYS; i++) {
    nav += (rnd() - 0.36) * 26 + (i / DAYS) * 7.6;
    raw.push(Math.max(180, nav));
  }
  const scale = 3279.579 / raw[DAYS - 1];

  // Daily share-price growth, varying around the target rate. The multiplier
  // averages to 1.0, so the noise changes the shape of the chart without
  // moving the trailing mean off TARGET_APY_PCT.
  const perDay = TARGET_APY_PCT / 100 / 365;
  const cumulative: number[] = [];
  let grown = 0;
  for (let i = 0; i < DAYS; i++) {
    grown += perDay * (0.15 + rnd() * 1.7);
    cumulative.push(grown);
  }

  for (let i = 0; i < DAYS; i++) {
    const t = i / (DAYS - 1);
    const at = END_AT - (DAYS - 1 - i) * DAY_MS;
    const navWei = i === DAYS - 1 ? END_NAV : weth((raw[i] * scale).toFixed(6));

    // Supply is derived from the share price, so every yield figure on the page
    // comes from this one series. The price walks up with real day-to-day
    // variance rather than on a straight line: a linear ramp gives every day
    // the same yield, and the chart renders as a solid block instead of a
    // chart. Multipliers average to 1, so the trailing mean still lands on
    // TARGET_APY_PCT.
    const priceE6 = 1_000_000 + Math.round(cumulative[i] * 1_000_000);
    const supplyRaw = (navWei * 10n ** 6n * 1_000_000n) / BigInt(priceE6);

    // weights drift from START_BPS to END_BPS; a late arrival is zero before it exists
    const weights: Record<string, number> = {};
    let weightSum = 0;
    for (const s of STRATEGIES) {
      const appears = APPEARS[s.id] ?? 0;
      let w = 0;
      if (t >= appears) {
        const local = appears ? (t - appears) / (1 - appears) : t;
        w = START_BPS[s.id] + (END_BPS[s.id] - START_BPS[s.id]) * smooth(local);
        w *= 0.94 + rnd() * 0.12;
      }
      weights[s.id] = Math.max(0, w);
      weightSum += weights[s.id];
    }

    // Split navWei by weight, giving the LAST band the remainder so the parts
    // sum to the whole exactly. A rounded split that loses a wei only ever
    // shows up as a one-pixel gap at the top of the stacked chart.
    const byStrategy: Record<string, bigint> = {};
    let assigned = 0n;
    STRATEGIES.forEach((s, index) => {
      if (index === STRATEGIES.length - 1) {
        byStrategy[s.id] = navWei - assigned;
        return;
      }
      const bps = i === DAYS - 1 ? END_BPS[s.id] : Math.round((weights[s.id] / weightSum) * 10_000);
      const part = (navWei * BigInt(bps)) / 10_000n;
      byStrategy[s.id] = part;
      assigned += part;
    });

    rows.push({ at, navWei, supplyRaw, cashWei: byStrategy['cash'], byStrategy });
  }
  return rows;
})();

/** A day's fills. Enough of them that the list genuinely scrolls - a vault
 *  that traded five times in a day would not be worth depositing into. */
export const FILLS: Fill[] = [
  { at: Date.UTC(2026, 8, 10, 14, 22), action: 'Bought', subject: '412.00 wstETH', detail: 'for', counter: '487.81 WETH', issuer: 'Lido' },
  { at: Date.UTC(2026, 8, 10, 13, 58), action: 'Bought', subject: '184,200 sUSDe', detail: 'for', counter: '44.06 WETH', issuer: 'Ethena' },
  { at: Date.UTC(2026, 8, 10, 13, 5), action: 'Recovered', subject: '61.40 WETH', detail: 'from the Lido queue', counter: null, issuer: 'Lido' },
  { at: Date.UTC(2026, 8, 10, 12, 41), action: 'Sold', subject: '48.00 rETH', detail: 'for', counter: '52.33 WETH', issuer: 'Rocket Pool' },
  { at: Date.UTC(2026, 8, 10, 11, 47), action: 'Sold', subject: '120.00 wstETH', detail: 'for', counter: '142.31 WETH', issuer: 'Lido' },
  { at: Date.UTC(2026, 8, 10, 11, 3), action: 'Bought', subject: 'receipt #19042', detail: 'for', counter: '18.74 WETH', issuer: 'Lido' },
  { at: Date.UTC(2026, 8, 10, 10, 12), action: 'Bought', subject: '218,400 sUSDe', detail: 'for', counter: '52.24 WETH', issuer: 'Ethena' },
  { at: Date.UTC(2026, 8, 10, 9, 55), action: 'Recovered', subject: '22.90 WETH', detail: 'from the Ethena cooldown', counter: null, issuer: 'Ethena' },
  { at: Date.UTC(2026, 8, 10, 9, 20), action: 'Sold', subject: '31.60 cbETH', detail: 'for', counter: '34.37 WETH', issuer: 'Coinbase' },
  { at: Date.UTC(2026, 8, 10, 8, 36), action: 'Bought', subject: '96.20 rETH', detail: 'for', counter: '104.84 WETH', issuer: 'Rocket Pool' },
  { at: Date.UTC(2026, 8, 10, 7, 48), action: 'Bought', subject: 'receipt #19038', detail: 'for', counter: '9.11 WETH', issuer: 'Lido' },
  { at: Date.UTC(2026, 8, 10, 6, 14), action: 'Recovered', subject: '104.20 WETH', detail: 'from the Lido queue', counter: null, issuer: 'Lido' },
];

/** hWETH is 24 decimals: 11.9960 shares is 11996000 * 1e18 raw units. */
export const POSITION: Position = {
  sharesRaw: 11_996_000n * 10n ** 18n,
  valueWei: weth('12.4903'),
  earnedWei: weth('0.4903'),
};

export const TICKET: ExitTicket = { requestedWei: weth('8'), fundedWei: weth('3.2') };

export const EXIT_LIQUIDITY: ExitLiquidity = {
  readyWei: weth('842.40'),
  queuedAheadWei: weth('118'),
  typicalWait: '~4h',
};

/** Wallet balances, shown only when connected. */
export const WALLET = { wethWei: weth('24.0180'), sharesRaw: 11_996_000n * 10n ** 18n };
