import { describe, it, expect } from 'vitest';
import { quoteTokens, quoteReceipt, isExpired } from '../useQuote';
import { BOOK_LIMIT_WEI } from '../fixtures';

const NOW = 1_000_000;

describe('quoteTokens', () => {
  it('is idle for a zero amount', () => {
    expect(quoteTokens(0n, 'exactInput', NOW).state).toBe('idle');
  });

  it('quotes 1 wstETH at the fixture rate, net of fee', () => {
    const q = quoteTokens(10n ** 18n, 'exactInput', NOW);
    expect(q.state).toBe('firm');
    expect(q.receiveWei + q.feeWei).toBe(1184060000000000000n);
    expect(q.feeWei).toBeGreaterThan(0n);
  });

  it('refuses above the book and states the limit', () => {
    const q = quoteTokens(BOOK_LIMIT_WEI + 1n, 'exactInput', NOW);
    expect(q.state).toBe('wontfill');
    expect(q.limitWei).toBe(BOOK_LIMIT_WEI);
  });

  it('sets an expiry only when firm', () => {
    expect(quoteTokens(10n ** 18n, 'exactInput', NOW).expiresAt).toBeGreaterThan(NOW);
    expect(quoteTokens(0n, 'exactInput', NOW).expiresAt).toBeNull();
  });

  it('reaches exact-output: the receive leg is exactly what was asked for', () => {
    const q = quoteTokens(10n ** 18n, 'exactOutput', NOW);
    expect(q.state).toBe('firm');
    expect(q.receiveWei).toBe(10n ** 18n);
    expect(q.payWei).toBeLessThan(10n ** 18n);   // the rate is above 1
  });

  it('rounds the pay leg up in exact-output so the output is always covered', () => {
    const want = 10n ** 18n;
    const q = quoteTokens(want, 'exactOutput', NOW);
    const back = quoteTokens(q.payWei, 'exactInput', NOW);
    expect(back.receiveWei).toBeGreaterThanOrEqual(want);
  });

  it('refuses an exact-output amount whose pay leg is above the book', () => {
    expect(quoteTokens(10n ** 19n, 'exactOutput', NOW).state).toBe('wontfill');
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
    const q = quoteTokens(10n ** 18n, 'exactInput', NOW);
    expect(isExpired(q, NOW)).toBe(false);
    expect(isExpired(q, q.expiresAt! + 1)).toBe(true);
  });

  it('never expires a quote that has no deadline', () => {
    expect(isExpired(quoteTokens(0n, 'exactInput', NOW), NOW + 1e9)).toBe(false);
  });
});
