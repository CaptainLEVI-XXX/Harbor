import { act, renderHook } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { useSwap } from '@/lib/swap/useSwap';
import { quoteFixture } from '@/lib/harbor/__tests__/fixtures';
const execute = vi.hoisted(() => vi.fn());
vi.mock('@/lib/wallet/useSend', () => ({ useSend: () => vi.fn() }));
vi.mock('@/lib/swap/execute', () => ({ executeQuote: execute, isRejection: () => false }));
describe('swap submission lifecycle', () => {
  it('prevents duplicate submissions while the wallet is open', async () => {
    let finish!: (hash: string) => void;
    execute.mockReturnValue(new Promise(resolve => { finish = resolve; }));
    const done = vi.fn(); const q = quoteFixture();
    const { result } = renderHook(() => useSwap(q, done));
    let pending!: Promise<void>;
    act(() => { pending = result.current.swap(); void result.current.swap(); });
    expect(execute).toHaveBeenCalledTimes(1);
    await act(async () => { finish('0x01'); await pending; });
    expect(result.current.status).toBe('swapped'); expect(done).toHaveBeenCalledTimes(1);
  });
});
