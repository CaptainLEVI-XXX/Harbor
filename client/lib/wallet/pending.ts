'use client';

import { useEffect, useRef, useSyncExternalStore } from 'react';
import type { Hex } from 'viem';

export type Asset = 'ETH' | 'wstETH' | 'hWETH';
export type Deltas = Partial<Record<Asset, bigint>>;

type Entry = { hash: Hex; account: string; deltas: Deltas };
type Snapshot = { entries: Entry[]; settled: number };

/**
 * Balance changes a broadcast transaction will make once it lands, so every
 * balance on the page can read as it will be, marked pending, instead of as it
 * was. Gas is not included. An entry leaves when its transaction confirms -
 * `settled` then ticks, which is a reader's cue to re-read the chain - or
 * fails, which rolls the figure straight back.
 */
let state: Snapshot = { entries: [], settled: 0 };
const listeners = new Set<() => void>();
const set = (next: Snapshot) => { state = next; listeners.forEach(l => l()); };

export const pending = {
  add(hash: Hex, account: string, deltas: Deltas) {
    if (Object.values(deltas).every(v => !v)) return;
    set({ ...state, entries: [...state.entries.filter(e => e.hash !== hash), { hash, account: account.toLowerCase(), deltas }] });
  },
  settle(hash: Hex | undefined, confirmed: boolean) {
    if (!hash || !state.entries.some(e => e.hash === hash)) return;
    set({ entries: state.entries.filter(e => e.hash !== hash), settled: state.settled + (confirmed ? 1 : 0) });
  },
  /** test seam: start from nothing */
  reset() { set({ entries: [], settled: 0 }); },
};

const subscribe = (listener: () => void) => { listeners.add(listener); return () => { listeners.delete(listener); }; };
const EMPTY: Snapshot = { entries: [], settled: 0 };

/** Run `reread` whenever any pending transaction confirms: the chain now holds what was shown as pending. */
export function useRereadOnSettle(reread: () => void) {
  const latest = useRef(reread);
  useEffect(() => { latest.current = reread; });
  const settled = useSyncExternalStore(subscribe, () => state.settled, () => 0);
  useEffect(() => { if (settled) latest.current(); }, [settled]);
}

/** What is pending for one account: a delta per asset, and a counter that ticks on each confirmation. */
export function usePending(account?: string) {
  const snapshot = useSyncExternalStore(subscribe, () => state, () => EMPTY);
  const mine = account ? snapshot.entries.filter(e => e.account === account.toLowerCase()) : [];
  const delta = (asset: Asset) => mine.reduce((sum, e) => sum + (e.deltas[asset] ?? 0n), 0n);
  return { delta, active: mine.length > 0, settled: snapshot.settled };
}
