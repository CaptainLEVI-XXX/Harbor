import { describe, it, expect } from 'vitest';
import { quoteTokens, quoteReceipt, isExpired } from '../useQuote';
import { BOOK_LIMIT_WEI } from '../fixtures';

const NOW = 1_000_000;
const sell = (amountWei: bigint, mode: 'exactInput' | 'exactOutput' = 'exactInput') =>
  quoteTokens({ amountWei, mode, direction: 'sell', now: NOW });
const buy = (amountWei: bigint, mode: 'exactInput' | 'exactOutput' = 'exactInput') =>
  quoteTokens({ amountWei, mode, direction: 'buy', now: NOW });

describe('quoteTokens', () => {
  it('is idle for a zero amount', () => {
    expect(sell(0n).state).toBe('idle');
  });

  it('quotes 1 wstETH at the fixture rate, net of fee', () => {
    const q = sell(10n ** 18n);
    expect(q.state).toBe('firm');
    expect(q.receiveWei + q.feeWei).toBe(1184060000000000000n);
    expect(q.feeWei).toBeGreaterThan(0n);
  });

  it('refuses above the book and states the limit', () => {
    const q = sell(BOOK_LIMIT_WEI + 1n);
    expect(q.state).toBe('wontfill');
    expect(q.limitWei).toBe(BOOK_LIMIT_WEI);
  });

  it('sets an expiry only when firm', () => {
    expect(sell(10n ** 18n).expiresAt).toBeGreaterThan(NOW);
    expect(sell(0n).expiresAt).toBeNull();
  });

  it('reaches exact-output: the receive leg is exactly what was asked for', () => {
    const q = sell(10n ** 18n, 'exactOutput');
    expect(q.state).toBe('firm');
    expect(q.receiveWei).toBe(10n ** 18n);
    expect(q.payWei).toBeLessThan(10n ** 18n);   // the rate is above 1
  });

  it('rounds the pay leg up in exact-output so the output is always covered', () => {
    const want = 10n ** 18n;
    const q = sell(want, 'exactOutput');
    expect(sell(q.payWei).receiveWei).toBeGreaterThanOrEqual(want);
  });

  it('refuses an exact-output amount whose pay leg is above the book', () => {
    expect(sell(10n ** 19n, 'exactOutput').state).toBe('wontfill');
  });

  it('inverts the rate when the pair is reversed', () => {
    expect(sell(10n ** 18n).rate).toBe('1 wstETH = 1.18406 WETH');
    expect(buy(10n ** 18n).rate).toBe('1 WETH = 0.844551 wstETH');
  });

  it('pays out less wstETH than the WETH put in, because the rate is above 1', () => {
    const q = buy(10n ** 18n);
    expect(q.state).toBe('firm');
    expect(q.receiveWei).toBeLessThan(10n ** 18n);
  });

  it('measures the book against the wstETH leg whichever side it is on', () => {
    // 9 WETH buys 7.60 wstETH and fills; 10 buys 8.45 and is over the 8.4 book
    expect(buy(9n * 10n ** 18n).state).toBe('firm');
    expect(buy(10n * 10n ** 18n).state).toBe('wontfill');
  });
});

describe('quoteReceipt', () => {
  it('is unavailable for an untradable receipt and says recovery is unaffected', () => {
    const q = quoteReceipt(null, NOW);
    expect(q.state).toBe('unavailable');
    expect(q.reason).toMatch(/recover/i);
  });

  it('prices against the mark, not the entitlement, and the leg is exactly 1', () => {
    const q = quoteReceipt(3941400000000000000n, NOW);
    expect(q.state).toBe('firm');
    expect(q.payWei).toBe(1n);
    expect(q.receiveWei + q.feeWei).toBe(3941400000000000000n);
  });
});

describe('isExpired', () => {
  it('expires once the deadline passes', () => {
    const q = sell(10n ** 18n);
    expect(isExpired(q, NOW)).toBe(false);
    expect(isExpired(q, q.expiresAt! + 1)).toBe(true);
  });

  it('never expires a quote that has no deadline', () => {
    expect(isExpired(sell(0n), NOW + 1e9)).toBe(false);
  });
});
