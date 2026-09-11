import { usePrivy, useSendTransaction, useWallets } from '@privy-io/react-auth';
import { createWalletClient, custom, type Address, type Hex } from 'viem';
import { privyConfigured } from '@/components/PrivyProvider';
import { chain, sponsored } from '@/lib/chain';
import type { Call } from '@/lib/swap/execute';

export type Send = (call: Call) => Promise<Hex>;

/**
 * Sends one call from the connected wallet. Privy's embedded wallet sends it
 * sponsored and without a modal; an external wallet confirms it in its own UI
 * and pays its own gas.
 */
function useSendWithPrivy(): Send {
  const { user } = usePrivy();
  const { wallets } = useWallets();
  const { sendTransaction } = useSendTransaction();

  return async call => {
    const address = user?.wallet?.address?.toLowerCase();
    const wallet = wallets.find(w => w.address.toLowerCase() === address);
    if (!wallet) throw new Error('No connected wallet');

    if (wallet.walletClientType === 'privy') {
      const { hash } = await sendTransaction({ ...call, chainId: chain.id }, { sponsor: sponsored });
      return hash;
    }

    await wallet.switchChain(chain.id);
    const client = createWalletClient({
      account: wallet.address as Address,
      chain,
      transport: custom(await wallet.getEthereumProvider()),
    });
    return client.sendTransaction(call);
  };
}

function useSendUnconfigured(): Send {
  // without an app ID nobody can connect, so nothing ever reaches this
  return () => Promise.reject(new Error('NEXT_PUBLIC_PRIVY_APP_ID is not set.'));
}

export const useSend: () => Send = privyConfigured ? useSendWithPrivy : useSendUnconfigured;
