/** WETH. */
export const ASSET_DECIMALS = 18;
/**
 * hWETH. HarborVault._decimalsOffset() returns 6, and Solady's ERC4626 reports
 * underlying + offset, so shares carry SIX MORE decimals than the asset.
 * Mixing the two scales produces figures wrong by a factor of a million that
 * still look like plausible balances. Verify against the deployed decimals().
 */
export const SHARE_DECIMALS = 24;

/**
 * One ValuationCheckpoint. In the build this is a subgraph row; here it is a
 * fixture with the same shape.
 */
export type Checkpoint = {
  /** epoch ms */
  at: number;
  /** committed NAV, WETH wei */
  navWei: bigint;
  /** committed LP supply, hWETH raw units */
  supplyRaw: bigint;
  /** spendable cash, WETH wei */
  cashWei: bigint;
  /** WETH value per strategy id. A strategy absent from the map did not exist yet. */
  byStrategy: Record<string, bigint>;
};

/**
 * A strategy is an ISSUER, not a token pair: a route carries an adapter, and
 * the adapter is the protocol whose withdrawal queue Harbor is taking on.
 * One issuer may own several routes (wstETH and receipts are both Lido).
 */
export type Strategy = {
  id: string;
  issuer: string;
  asset: string;
  /** band colour - one hue at six lightnesses, darkest first */
  colour: string;
  /** native units held, pre-formatted: each asset has its own decimals */
  holding: string;
  /** WETH wei traded through this route in the last 30 days */
  volume30dWei: bigint | null;
  /** realized gains minus realized losses, WETH wei. null where the row has none */
  earnedWei: bigint | null;
  /** WETH wei waiting inside the issuer's own withdrawal queue */
  inQueueWei: bigint;
};

export type Fill = {
  /** epoch ms */
  at: number;
  action: 'Bought' | 'Sold' | 'Recovered';
  /** what moved - "412.00 wstETH" */
  subject: string;
  /** the connecting words - "for", "from the Lido queue" */
  detail: string;
  /** the other leg, if there is one */
  counter: string | null;
  issuer: string;
};

export type Position = {
  sharesRaw: bigint;
  valueWei: bigint;
  /** signed */
  earnedWei: bigint;
};

/** An LP exit in flight. Partial funding is the normal case, not an edge case. */
export type ExitTicket = {
  requestedWei: bigint;
  fundedWei: bigint;
};

export type ExitLiquidity = {
  readyWei: bigint;
  queuedAheadWei: bigint;
  /** plain English, because "4h" is what a person asked for */
  typicalWait: string;
};
