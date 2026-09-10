import type { Quote, TradeMode } from './types';
import { TOKEN_RATE_1E18, FEE_BPS, BOOK_LIMIT_WEI } from './fixtures';

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

const RATE_LABEL = '1 wstETH = 1.18406 WETH';

/**
 * Prices the token pair.
 *
 * `amountWei` is whichever leg the user typed: the pay leg under `exactInput`,
 * the receive leg under `exactOutput`. The other leg is derived here so the
 * view never does pricing arithmetic of its own.
 *
 * Rounding always favours the vault - down on what the user receives, up on
 * what the user pays - so a quoted exact output is never short.
 */
export function quoteTokens(amountWei: bigint, mode: TradeMode, now: number): Quote {
  if (amountWei <= 0n) return empty('idle');

  let payWei: bigint;
  let receiveWei: bigint;
  let feeWei: bigint;

  if (mode === 'exactInput') {
    payWei = amountWei;
    const gross = (payWei * TOKEN_RATE_1E18) / ONE;
    feeWei = (gross * FEE_BPS) / BPS;
    receiveWei = gross - feeWei;
  } else {
    receiveWei = amountWei;
    const gross = divUp(receiveWei * BPS, BPS - FEE_BPS);
    feeWei = gross - receiveWei;
    payWei = divUp(gross * ONE, TOKEN_RATE_1E18);
  }

  if (payWei > BOOK_LIMIT_WEI) {
    return empty('wontfill', { payWei, limitWei: BOOK_LIMIT_WEI });
  }

  return {
    state: 'firm',
    payWei,
    receiveWei,
    feeWei,
    rate: RATE_LABEL,
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
