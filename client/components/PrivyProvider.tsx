'use client';

import { PrivyProvider, usePrivy } from '@privy-io/react-auth';
import type { Address } from 'viem';
import { DESIGN } from '@/lib/design';
import { chain } from '@/lib/chain';

const APP_ID = process.env.NEXT_PUBLIC_PRIVY_APP_ID;

/**
 * Whether Privy is configured. Resolved once at module load, so the hook
 * selection below is stable for the life of the app.
 */
export const privyConfigured = Boolean(APP_ID);

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
        supportedChains: [chain],
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

type Connect = { label: string; connected: boolean; address?: Address; onConnect: () => void };

function useConnectWithPrivy(): Connect {
  const { ready, authenticated, user, login, logout } = usePrivy();

  if (!ready) return { label: DESIGN.copy.connect, connected: false, onConnect: () => {} };
  if (authenticated && user?.wallet?.address) {
    return {
      label: truncateAddress(user.wallet.address),
      connected: true,
      address: user.wallet.address as Address,
      onConnect: logout,
    };
  }
  return { label: DESIGN.copy.connect, connected: false, onConnect: login };
}

function useConnectUnconfigured(): Connect {
  return {
    label: DESIGN.copy.connect,
    connected: false,
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
