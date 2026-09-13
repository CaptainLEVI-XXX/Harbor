import { act, renderHook } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { useLiveQuote } from '../useLiveQuote';
import { quoteFixture } from './fixtures';
const read = vi.hoisted(() => vi.fn());
vi.mock('../quote', () => ({ readQuote: read }));
afterEach(() => vi.useRealTimers());
describe('quote response ownership', () => {
  it('debounces typing and ignores an old response after the amount changes', async () => {
    vi.useFakeTimers();
    let resolveOld!: (value: ReturnType<typeof quoteFixture>) => void;
    read.mockReturnValueOnce(new Promise(resolve => { resolveOld = resolve; })).mockResolvedValueOnce({ ...quoteFixture(), payWei: 2n });
    const { result, rerender } = renderHook(({ amount }) => useLiveQuote({ amountWei: amount, direction: 'sell', mode: 'exactInput' }), { initialProps: { amount: 1n } });
    expect(read).not.toHaveBeenCalled();
    await act(() => vi.advanceTimersByTimeAsync(300));
    rerender({ amount: 2n });
    expect(result.current.executable).toBeUndefined();
    await act(() => vi.advanceTimersByTimeAsync(300));
    expect(result.current.quote.payWei).toBe(2n);
    await act(async () => { resolveOld(quoteFixture()); });
    expect(result.current.quote.payWei).toBe(2n);
    expect(read).toHaveBeenCalledTimes(2);
  });
});
