import type { Quote, TradeMode, Direction } from './types';
import { TOKEN_RATE_1E18, FEE_BPS, BOOK_LIMIT_WEI } from './fixtures';
import { formatWei } from './format';

/** A firm signed quote genuinely dies. The UI has to show it dying. */
export const QUOTE_TTL_MS = 30_000;

const ONE = 10n ** 18n;
const BPS = 10_000n;

const divUp = (a: bigint, b: bigint) => (a + b - 1n) / b;

const empty = (state: Quote['state'], extra: Partial<Quote> = {}): Quote => ({
  state,
  payWei: 0n,
  receiveWei: 0n,
  feeWei: 0n,
  rate: '',
  expiresAt: null,
  ...extra,
});

/**
 * The pair as a fraction, so no step ever passes through a float.
 * Selling wstETH pays out at the rate; buying it pays in at the same rate,
 * inverted.
 */
function pair(direction: Direction) {
  return direction === 'sell'
    ? { num: TOKEN_RATE_1E18, den: ONE }
    : { num: ONE, den: TOKEN_RATE_1E18 };
}

function rateLabel(direction: Direction): string {
  return direction === 'sell'
    ? `1 wstETH = ${formatWei(TOKEN_RATE_1E18, 18)} WETH`
    : `1 WETH = ${formatWei((ONE * ONE) / TOKEN_RATE_1E18, 18)} wstETH`;
}

export type QuoteRequest = {
  /** whichever leg the user typed: pay under exactInput, receive under exactOutput */
  amountWei: bigint;
  mode: TradeMode;
  direction: Direction;
  now: number;
};

/**
 * Prices the token pair. The leg the user did not type is derived here, so the
 * view never does pricing arithmetic of its own.
 *
 * Rounding always favours the vault - down on what the user receives, up on
 * what the user pays - so a quoted exact output is never short.
 */
export function quoteTokens({ amountWei, mode, direction, now }: QuoteRequest): Quote {
  if (amountWei <= 0n) return empty('idle');

  const { num, den } = pair(direction);

  let payWei: bigint;
  let receiveWei: bigint;
  let feeWei: bigint;
  let grossWei: bigint;

  if (mode === 'exactInput') {
    payWei = amountWei;
    grossWei = (payWei * num) / den;
    feeWei = (grossWei * FEE_BPS) / BPS;
    receiveWei = grossWei - feeWei;
  } else {
    receiveWei = amountWei;
    grossWei = divUp(receiveWei * BPS, BPS - FEE_BPS);
    feeWei = grossWei - receiveWei;
    payWei = divUp(grossWei * den, num);
  }

  // the book limit is measured on the wstETH leg, whichever side that is
  const wstethWei = direction === 'sell' ? payWei : grossWei;
  if (wstethWei > BOOK_LIMIT_WEI) {
    return empty('wontfill', { payWei, limitWei: BOOK_LIMIT_WEI });
  }

  return {
    state: 'firm',
    payWei,
    receiveWei,
    feeWei,
    rate: rateLabel(direction),
    expiresAt: now + QUOTE_TTL_MS,
  };
}

/**
 * Prices one withdrawal receipt. The receipt leg is always exactly 1 - a
 * receipt is a whole claim on one queued request and does not divide.
 */
export function quoteReceipt(markWei: bigint | null, now: number): Quote {
  if (markWei === null) {
    return empty('unavailable', {
      reason:
        'Harbor is not quoting this receipt. That does not affect recovery — a ' +
        'finalized receipt can always be redeemed directly by whoever holds it.',
    });
  }

  const feeWei = (markWei * FEE_BPS) / BPS;

  return {
    state: 'firm',
    payWei: 1n,
    receiveWei: markWei - feeWei,
    feeWei,
    rate: 'priced at the conservative mark',
    expiresAt: now + QUOTE_TTL_MS,
  };
}

export function isExpired(quote: Quote, now: number): boolean {
  return quote.expiresAt !== null && now > quote.expiresAt;
}
