import { act, renderHook } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { pending, usePending, useRereadOnSettle } from '../pending';

const ME = '0x1234567890abcdef1234567890abcdef12345678';
beforeEach(() => act(() => pending.reset()));

describe('pending balance changes', () => {
  it('shows a broadcast change for its own account until the block decides it', () => {
    const { result } = renderHook(() => usePending(ME.toUpperCase().replace('0X', '0x')));
    act(() => pending.add('0x01', ME, { ETH: -5n, wstETH: 3n }));
    expect([result.current.delta('ETH'), result.current.delta('wstETH'), result.current.active]).toEqual([-5n, 3n, true]);
    expect(renderHook(() => usePending('0x0000000000000000000000000000000000000001')).result.current.active).toBe(false);
  });

  it('rolls a failed change straight back, and re-reads the chain only on a confirmation', () => {
    const reread = vi.fn();
    renderHook(() => useRereadOnSettle(reread));
    const { result } = renderHook(() => usePending(ME));
    act(() => pending.add('0x01', ME, { ETH: -5n }));
    act(() => pending.settle('0x01', false));
    expect(result.current.delta('ETH')).toBe(0n);
    expect(reread).not.toHaveBeenCalled();
    act(() => pending.add('0x02', ME, { ETH: -5n }));
    act(() => pending.settle('0x02', true));
    expect(result.current.delta('ETH')).toBe(0n);
    expect(reread).toHaveBeenCalledOnce();
  });
});
