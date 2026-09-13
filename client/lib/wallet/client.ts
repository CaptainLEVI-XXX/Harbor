import type { ConnectedWallet } from '@privy-io/react-auth';
import { createWalletClient, custom, type Address } from 'viem';
import { chain } from '@/lib/chain';
import { RECEIPT_POLL_MS } from '@/lib/constants';

/** Connected provider only; never pick another injected/global wallet. */
export async function connectedClient(wallet: ConnectedWallet) {
  return createWalletClient({ account: wallet.address as Address, chain, pollingInterval: RECEIPT_POLL_MS,
    transport: custom(await wallet.getEthereumProvider()) });
}
