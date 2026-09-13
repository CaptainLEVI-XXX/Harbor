import { erc20Abi, zeroAddress, type Address } from 'viem';
import { publicClient, TOKENS } from '@/lib/chain';
import { vaultAbi, executorAbi } from './abis';
import { HARBOR, requireNetwork } from './config';

async function optional<T>(read: Promise<T>): Promise<T | null> {
  try { return await read; } catch { return null; }
}

/** Values are raw units. NAV failures never erase balances or funded credits. */
export async function getEarnSnapshot(user?: Address) {
  await requireNetwork();
  const block = await publicClient.getBlock();
  const at = { address: HARBOR.vault, abi: vaultAbi, blockNumber: block.number } as const;
  const account = user ?? zeroAddress;
  const [asset, book, boundVault, shareDecimals, supply, accounting, nav, sharePrice, maxDeposit, balance, operator, shares, pendingShares, fundedUnits, claimableAssets] = await Promise.all([
    publicClient.readContract({ ...at, functionName: 'asset' }),
    publicClient.readContract({ ...at, functionName: 'BOOK' }),
    publicClient.readContract({ address: HARBOR.executor, abi: executorAbi, functionName: 'vaultOf', args: [HARBOR.book], blockNumber: block.number }),
    publicClient.readContract({ ...at, functionName: 'decimals' }),
    publicClient.readContract({ ...at, functionName: 'totalSupply' }),
    publicClient.readContract({ ...at, functionName: 'accountingStatus' }),
    optional(publicClient.readContract({ ...at, functionName: 'totalAssets' })),
    optional(publicClient.readContract({ ...at, functionName: 'convertToAssets', args: [10n ** 24n] })),
    publicClient.readContract({ ...at, functionName: 'maxDeposit', args: [account] }),
    // deposits are funded with native ETH now, so that is the balance that matters
    user ? publicClient.getBalance({ address: user, blockNumber: block.number }) : null,
    // the periphery can only claim a funded exit on the customer's behalf once
    // they have made it an operator - a one-time switch, not a per-claim approval
    user ? publicClient.readContract({ ...at, functionName: 'isOperator', args: [user, HARBOR.periphery] }) : null,
    user ? publicClient.readContract({ ...at, functionName: 'balanceOf', args: [user] }) : null,
    user ? publicClient.readContract({ ...at, functionName: 'pendingRedeemRequest', args: [0n, user] }) : null,
    user ? publicClient.readContract({ ...at, functionName: 'claimableRedeemRequest', args: [0n, user] }) : null,
    user ? publicClient.readContract({ ...at, functionName: 'maxWithdraw', args: [user] }) : null,
  ]);
  if (asset.toLowerCase() !== TOKENS.WETH || book.toLowerCase() !== HARBOR.book || boundVault.toLowerCase() !== HARBOR.vault || shareDecimals !== 24) {
    throw new Error('Deployment identity or units do not match this interface.');
  }
  const positionAssets = shares === null ? null : await optional(publicClient.readContract({ ...at, functionName: 'convertToAssets', args: [shares] }));
  return {
    source: 'chain' as const, blockNumber: block.number, blockHash: block.hash, timestamp: block.timestamp,
    shareDecimals, supply, nav, sharePrice, maxDeposit,
    cash: accounting[0], reservedAssets: accounting[1], totalPendingShares: accounting[2], valid: accounting[3], insolvent: accounting[4],
    account: user ? { address: user, balance: balance!, operator: operator!, shares: shares!, pendingShares: pendingShares!, fundedUnits: fundedUnits!, claimableAssets: claimableAssets!, positionAssets } : null,
  };
}
export type EarnSnapshot = Awaited<ReturnType<typeof getEarnSnapshot>>;

export async function getTokenBalances(user?: Address) {
  if (!user) return null;
  await requireNetwork();
  const blockNumber = await publicClient.getBlockNumber();
  const [WETH, wstETH, ETH] = await Promise.all([
    ...Object.values(TOKENS).map(address => publicClient.readContract({ address, abi: erc20Abi, functionName: 'balanceOf', args: [user], blockNumber })),
    publicClient.getBalance({ address: user, blockNumber }),
  ]);
  return { blockNumber, WETH, wstETH, ETH };
}
