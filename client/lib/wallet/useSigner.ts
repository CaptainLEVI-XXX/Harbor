'use client';

import { usePrivy, useWallets } from '@privy-io/react-auth';
import { privyConfigured } from './config';

export type Signer = { address: string; name: string; embedded: boolean };

/**
 * Which wallet signs, as Privy reports it: the embedded wallet by its own
 * name, an external one by the connector's (MetaMask, Rainbow, ...).
 */
function useSignerWithPrivy(): Signer | null {
  const { user } = usePrivy();
  const { wallets } = useWallets();
  const address = user?.wallet?.address?.toLowerCase();
  const wallet = wallets.find(w => w.address.toLowerCase() === address);
  if (!wallet) return null;
  const embedded = wallet.walletClientType === 'privy';
  return { address: wallet.address, embedded, name: embedded ? 'Privy embedded wallet' : wallet.meta?.name || wallet.walletClientType };
}

export const useSigner: () => Signer | null = privyConfigured ? useSignerWithPrivy : () => null;
