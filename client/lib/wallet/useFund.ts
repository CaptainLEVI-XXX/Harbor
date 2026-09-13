'use client';

import { useFundWallet } from '@privy-io/react-auth';
import { chain } from '@/lib/chain';
import { privyConfigured } from './config';

/**
 * Privy's own funding modal, opened on its transfer-from-another-wallet route.
 * Card and exchange onramps cannot buy testnet ETH, so on Hoodi the transfer
 * is the one route that can work. The methods shown are those enabled for the
 * app in the Privy dashboard.
 */
function useFundWithPrivy() {
  const { fundWallet } = useFundWallet();
  return (address: string) => fundWallet({ address, options: { chain, defaultFundingMethod: 'wallet' } });
}

export const useFund: () => ((address: string) => Promise<unknown>) | null = privyConfigured ? useFundWithPrivy : () => null;
