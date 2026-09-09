'use client';

import { PrivyProvider, usePrivy } from '@privy-io/react-auth';
import { DESIGN } from '@/lib/design';

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
        embeddedWallets: { ethereum: { createOnLogin: 'users-without-wallets' } },
      }}
    >
      {children}
    </PrivyProvider>
  );
}

export function truncateAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

type Connect = { label: string; onConnect: () => void };

function useConnectWithPrivy(): Connect {
  const { ready, authenticated, user, login, logout } = usePrivy();

  if (!ready) return { label: DESIGN.copy.connect, onConnect: () => {} };
  if (authenticated && user?.wallet?.address) {
    return { label: truncateAddress(user.wallet.address), onConnect: logout };
  }
  return { label: DESIGN.copy.connect, onConnect: login };
}

function useConnectUnconfigured(): Connect {
  return {
    label: DESIGN.copy.connect,
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
