'use client';

import { usePrivy, useSendTransaction, useWallets } from '@privy-io/react-auth';
import { useEffect, useRef } from 'react';
import { chain, sponsored } from '@/lib/chain';
import { privyConfigured } from './config';
import { connectedClient } from './client';
import { atomicCapability, sendAtomic } from './batch';
import { fastFees } from './fees';
import type { Call, Send } from './types';

function useSendWithPrivy(): Send {
  const { user } = usePrivy();
  const { wallets } = useWallets();
  const { sendTransaction } = useSendTransaction();
  const session = useRef({ user, wallets });
  useEffect(() => { session.current = { user, wallets }; }, [user, wallets]);

  function currentWallet(calls: Call[] = []) {
    const address = session.current.user?.wallet?.address?.toLowerCase();
    const wallet = session.current.wallets.find(w => w.address.toLowerCase() === address);
    if (!wallet || calls.some(c => !c.account || c.account.toLowerCase() !== address)) {
      throw new Error('Wallet changed. Refresh before confirming.');
    }
    return wallet;
  }
  function assertCurrent(wallet: ReturnType<typeof currentWallet>, calls: Call[] = []) {
    if (currentWallet(calls) !== wallet) throw new Error('Wallet changed. Refresh before confirming.');
  }

  const send: Send = async request => {
    const wallet = currentWallet([request]);
    // the fee read runs beside the chain switch, not after it; one that fails
    // leaves the wallet to price the transaction itself
    const [fees] = await Promise.all([fastFees().catch(() => ({})), wallet.switchChain(chain.id)]);
    assertCurrent(wallet, [request]);
    const { to, data, value } = request;
    const call = { to, data, value, ...fees };
    if (wallet.walletClientType === 'privy') {
      const { hash } = await sendTransaction({ ...call, chainId: chain.id }, { address: wallet.address, sponsor: sponsored });
      return hash;
    }
    const client = await connectedClient(wallet);
    assertCurrent(wallet, [request]);
    return client.sendTransaction(call);
  };

  send.atomic = async () => {
    try {
      const wallet = currentWallet();
      // No network switching merely because a page rendered.
      const status = await atomicCapability(await connectedClient(wallet));
      assertCurrent(wallet);
      return status;
    } catch { return 'unsupported'; }
  };

  send.batch = async (calls, options) => {
    if (!calls.length) throw new Error('No calls to submit.');
    const wallet = currentWallet(calls);
    await wallet.switchChain(chain.id);
    assertCurrent(wallet, calls);
    const client = await connectedClient(wallet);
    const status = await atomicCapability(client);
    assertCurrent(wallet, calls);
    return sendAtomic(client, calls, status, options);
  };
  return send;
}

function useSendUnconfigured(): Send {
  return () => Promise.reject(new Error('NEXT_PUBLIC_PRIVY_APP_ID is not set.'));
}
export const useSend: () => Send = privyConfigured ? useSendWithPrivy : useSendUnconfigured;
