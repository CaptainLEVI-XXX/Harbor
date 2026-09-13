'use client';

import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import { publicClient, TOKENS } from '@/lib/chain';
import { parseWei } from '@/lib/format';
import { usd, type DisplayPrices } from '@/lib/price';
import { useResource } from './useResource';
import { requireNetwork } from './config';

const Context = createContext<DisplayPrices | null>(null);
import { conversionAbi } from './abis';

async function readDisplayPrices(): Promise<DisplayPrices> {
  await requireNetwork();
  const [response, conversion] = await Promise.all([
    fetch('/api/prices', { signal: AbortSignal.timeout(12_000) }),
    publicClient.readContract({ address: TOKENS.wstETH, abi: conversionAbi, functionName: 'getStETHByWstETH', args: [10n ** 18n] }),
  ]);
  if (!response.ok) throw new Error('USD reference unavailable');
  const data = await response.json();
  const WETH = typeof data.ethUsd === 'string' ? parseWei(data.ethUsd, 18) : null;
  if (!WETH || WETH <= 0n || conversion <= 0n || !Number.isFinite(data.fetchedAt) || Date.now() - data.fetchedAt > 120_000 || data.fetchedAt > Date.now() + 10_000) throw new Error('USD reference is invalid or stale');
  return { WETH, wstETH: WETH * conversion / 10n ** 18n, fetchedAt: data.fetchedAt };
}

export function DisplayPriceProvider({ children }: { children: ReactNode }) {
  const { data } = useResource('display-prices', readDisplayPrices, 30_000);
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const update = () => setNow(Date.now());
    const timer = setInterval(update, 15_000);
    document.addEventListener('visibilitychange', update);
    return () => { clearInterval(timer); document.removeEventListener('visibilitychange', update); };
  }, []);
  return <Context.Provider value={data && now - data.fetchedAt <= 120_000 ? data : null}>{children}</Context.Provider>;
}

export function useDisplayPrice() {
  const prices = useContext(Context);
  return { prices, usd: (amount: bigint, symbol = 'WETH', decimals = 18) => usd(amount, symbol, decimals, prices) };
}
