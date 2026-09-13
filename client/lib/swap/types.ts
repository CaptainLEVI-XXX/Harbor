export type Asset = { symbol: string; name: string; decimals: number };

type QuoteState = 'idle' | 'requesting' | 'firm' | 'expired' | 'unavailable';

export type Quote = {
  state: QuoteState;
  payWei: bigint;
  receiveWei: bigint;
  feeWei: bigint;
  rate: string;
  /** epoch ms; null unless the quote is firm */
  expiresAt: number | null;
  /** why no quote exists - `unavailable` only */
  reason?: string;
  /** a reason the reader can clear themselves - `unavailable` only */
  blocker?: 'unfundedWithdrawals';
};

/** Which leg the user typed into. The contract reaches both from one surface. */
export type TradeMode = 'exactInput' | 'exactOutput';

/**
 * Which way round the pair is. Together with TradeMode this reaches all four
 * contract modes from one surface; the UI never uses the word "side".
 */
export type Direction = 'sell' | 'buy';
