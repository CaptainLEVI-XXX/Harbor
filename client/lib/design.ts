export type Coin = {
  leftPct: number;
  topPct: number;
  widthPct: number;
  rotationDeg: number;
  pale: boolean;
};

/** positions are % of the stage. verified in tests not to overlap the content block. */
/**
 * Widths are the ELEMENT width; the coin's ellipse is rx=86 in a 240-wide
 * viewBox, so the visible coin is 71.7% of the number below.
 * Measured on crumbs: individual coins occupy 6.7-8.1% of viewport width. An
 * earlier build sat at 9.7-12.2% - about 1.4x too big. Positions are adjusted
 * so each coin's centre stays where it was.
 */
const COINS: Coin[] = [
  { leftPct: 3.4,  topPct: 8.3,  widthPct: 12.2, rotationDeg: -24, pale: true  },
  { leftPct: 10.5, topPct: 4.4,  widthPct: 9.7,  rotationDeg: 16,  pale: false },
  { leftPct: 0.6,  topPct: 50.8, widthPct: 10.8, rotationDeg: 60,  pale: true  },
  { leftPct: 87.6, topPct: 7.8,  widthPct: 10.8, rotationDeg: -10, pale: false },
  { leftPct: 90.9, topPct: 48.4, widthPct: 9.7,  rotationDeg: 32,  pale: true  },
  { leftPct: 71.3, topPct: 74.2, widthPct: 8.0,  rotationDeg: -18, pale: false },
  { leftPct: 46.1, topPct: 85.9, widthPct: 7.4,  rotationDeg: 6,   pale: true  },
];

export const DESIGN = {
  /** the viewport the spec's pixel measurements were taken at */
  referenceWidth: 1413,

  layout: {
    columnWidthPct: 28.3,
    navPaddingTopPct: 2.55,
    navPaddingSidePct: 3.1,
    columnBottomBiasPct: 2.4,
  },

  type: {
    baseCqw: 1.3,
    headlineEm: 2.44,
    subcopyEm: 0.87,
    wordmarkEm: 1.06,
    navItemEm: 0.72,
    connectEm: 0.72,
    betaEm: 0.44,
  },

  ink: {
    strong: '#4A2F6B',
    secondary: '#6F6689',
    tertiary: '#9086A8',
  },

  /**
   * Lavender translations of crumbs' own values (see lib/ground.ts for the
   * source they came from). Structure is theirs; hue is ours.
   */
  /**
   * Luminance-matched to crumbs, not channel-swapped.
   * Green carries 0.587 of luminance and blue only 0.114, so translating a green
   * to violet by moving channels makes it 15-52 levels darker and the effect
   * stops reading. Every value below matches its crumbs counterpart's luminance;
   * where blue would clip past 255, chroma is reduced instead of luminance.
   */
  ground: {
    sheet:          '#F4EDFC',                 // their #eaf6e7   lum 241
    bloomTopRight:  'rgba(216,184,255,.60)',   // their #92f48499 lum 202
    bloomBottomLeft:'rgba(231,211,255,.55)',   // their #bef6b88c lum 222
    reliefTint:     'rgba(184,145,230,.17)',   // their rgb(120,200,115) lum 166
    pressDark:      'rgba(115,90,146,.34)',    // their #4a7e4657 lum 104
    pressMid:       'rgba(182,162,206,.06)',   // their #96be920f lum 173
    pressInset:     'rgba(88,70,110,.30)',     // their #3a60384d lum 80
    pressInsetMid:  'rgba(88,70,110,.13)',
    pressGlow:      'rgba(214,180,255,.30)',   // their #96eb8c4d lum 199
  },

  cell: {
    size: 84,                                // their hit test: floor(x / 84)
    radiusRatio: 25 / 84,                    // border-radius 25px on an 84px cell
  },

  motion: {
    coinPeriodSeconds: 6.3,
    coinDriftYPx: 5,
    coinDriftXPx: 2,
    coinRotateDeg: 3,
    /** crumbs' press: animate scale 1 -> 0.93 on a spring, back to 1 on exit */
    pressScale: 0.93,
    pressSpringStiffness: 420,
    pressSpringDamping: 26,
    pressFadeInMs: 120,
    dentDecayMs: 420,                        // their exit: duration .42 easeOut
    ringSizePx: 74,
    ringPressedPx: 46,
  },

  burst: {
    minCoins: 6,
    maxCoins: 9,
    friction: 0.955,
    /** below this speed a coin is considered at rest and stops being simulated */
    restSpeed: 0.02,
  },

  coins: COINS,

  copy: {
    /** one sentence, broken where it reads naturally */
    headline: ['Get instant liquidity', 'for your assets at the best price.'],
    subcopy:
      'Swap redeemable assets or sell pending withdrawal claims for instant liquidity. Supply the pool to earn from trading.',
    connect: 'Connect wallet',
    nav: ['Swap', 'Earn', 'Testnet', 'Portfolio', 'Analytics', 'Docs'],
  },
} as const;
