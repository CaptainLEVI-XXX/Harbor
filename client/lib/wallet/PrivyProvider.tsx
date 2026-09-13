'use client';

import { PrivyProvider, addRpcUrlOverrideToChain, usePrivy } from '@privy-io/react-auth';
import type { Address } from 'viem';
import { DESIGN } from '@/lib/design';
import { chain, RPC_URL } from '@/lib/chain';

import { PRIVY_APP_ID as APP_ID, privyConfigured } from './config';

/** the embedded wallet estimates and broadcasts through the app's RPC, not Privy's default for the chain */
const walletChain = RPC_URL ? addRpcUrlOverrideToChain(chain, RPC_URL) : chain;

export function Providers({ children }: { children: React.ReactNode }) {
  if (!privyConfigured) {
    // The page must still render and be fully interactive without an app ID -
    // otherwise `next build` cannot prerender it. Connect is inert instead.
    return <>{children}</>;
  }

  return (
    <PrivyProvider
      appId={APP_ID as string}
      config={{
        appearance: {
          theme: 'light',
          accentColor: DESIGN.ink.strong,      // #4A2F6B
          walletList: ['detected_wallets', 'metamask', 'coinbase_wallet', 'wallet_connect'],
        },
        loginMethods: ['wallet', 'email'],
        // no defaultChain: setting it makes Privy force a chain switch on connect,
        // which races the sign-in signature. The first supported chain is the default.
        supportedChains: [walletChain],
        embeddedWallets: {
          ethereum: { createOnLogin: 'users-without-wallets' },
          // the Swap button is the confirmation - no second modal on top of it
          showWalletUIs: false,
        },
      }}
    >
      {children}
    </PrivyProvider>
  );
}

export function truncateAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

/**
 * `onConnect` only ever signs in. Signing out is `disconnect`, reached from the
 * wallet menu: a Privy session survives reloads and visits, and ending it by
 * accident is what sent people back through the email code.
 */
type Connect = { label: string; connected: boolean; address?: Address; onConnect: () => void; disconnect: () => void };

function useConnectWithPrivy(): Connect {
  const { ready, authenticated, user, login, logout } = usePrivy();

  if (!ready) return { label: DESIGN.copy.connect, connected: false, onConnect: () => {}, disconnect: () => {} };
  if (authenticated && user?.wallet?.address) {
    return {
      label: truncateAddress(user.wallet.address),
      connected: true,
      address: user.wallet.address as Address,
      onConnect: () => {},
      disconnect: () => { void logout(); },
    };
  }
  return { label: DESIGN.copy.connect, connected: false, onConnect: login, disconnect: () => {} };
}

function useConnectUnconfigured(): Connect {
  return {
    label: DESIGN.copy.connect,
    connected: false,
    disconnect: () => {},
    onConnect: () => {
      console.warn(
        'NEXT_PUBLIC_PRIVY_APP_ID is not set. Copy .env.local.example to .env.local and add an app ID from dashboard.privy.io.',
      );
    },
  };
}

export const useConnect: () => Connect = privyConfigured
  ? useConnectWithPrivy
  : useConnectUnconfigured;
