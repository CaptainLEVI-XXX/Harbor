export type Asset = { symbol: string; name: string; decimals: number };

/**
 * Only `pending` can trade. A finalized or recovered receipt is still the
 * holder's to redeem directly - it is simply not tradable through Harbor.
 */
export type ReceiptState = 'pending' | 'finalized' | 'recovered';

export type Receipt = {
  requestId: number;
  /** what the receipt eventually pays at recovery */
  entitlementWei: bigint;
  /** the conservative mark - the PRICE REFERENCE, never the entitlement */
  markWei: bigint | null;
  queuedDays: number;
  state: ReceiptState;
};

export type QuoteState =
  | 'idle'
  | 'requesting'
  | 'firm'
  | 'expired'
  | 'unavailable'
  | 'wontfill';

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
  /** the largest fill the book will take - `wontfill` only */
  limitWei?: bigint;
};

/** Which leg the user typed into. The contract reaches both from one surface. */
export type TradeMode = 'exactInput' | 'exactOutput';
