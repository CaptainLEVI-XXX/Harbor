import { BaseError, ContractFunctionRevertedError, encodeFunctionData, parseAbi, parseEventLogs, type Address, type Hex } from 'viem';
import { publicClient, TOKENS } from '@/lib/chain';
import { WITHDRAWAL_BATCH_SIZE } from '@/lib/constants';
import { sendConfirmed } from '@/lib/wallet/confirmation';
import type { Call, Send } from '@/lib/wallet/types';
import { vaultAbi } from './abis';
import { HARBOR, requireNetwork } from './config';

/** The executor's and Book's `CapacityExceeded()`. */
export const CAPACITY_EXCEEDED = '0x9ff41fe0';

const queueAbi = parseAbi([
  'function tradingCash(uint256 buffer) view returns (uint256)',
  'function balanceOf(address owner) view returns (uint256)',
  'event WithdrawalFulfilled(uint256 indexed ticket, address indexed controller, uint256 shares, uint256 assets, uint256 valuationVersion, uint256 remaining)',
]);

/**
 * A quote the vault cannot fill because LP exits come first: while any request
 * is unfunded the vault spends no cash, so every trade that pays out ETH stops.
 */
export class UnfundedWithdrawalsError extends Error {
  constructor(readonly pendingShares: bigint) {
    super('Selling to the vault resumes once pending withdrawals are funded.');
    this.name = 'UnfundedWithdrawalsError';
  }
}

/** The 4-byte selector a contract call reverted with, decoded or not. */
function revertSelector(error: unknown): Hex | undefined {
  if (!(error instanceof BaseError)) return undefined;
  const revert = error.walk(e => e instanceof ContractFunctionRevertedError);
  if (!(revert instanceof ContractFunctionRevertedError)) return undefined;
  return (revert.signature ?? revert.raw?.slice(0, 10)) as Hex | undefined;
}

/**
 * Shares waiting to be funded, when they are what stops the vault spending.
 * `CapacityExceeded` has other causes - route caps, loss budgets, a cash
 * deficit - so this answers 0n unless the pending queue is the reason the
 * vault's spendable cash reads zero while its cash is physically there.
 */
async function blockingWithdrawals(): Promise<bigint> {
  const [[cash, , pending], spendable, held] = await Promise.all([
    publicClient.readContract({ address: HARBOR.vault, abi: vaultAbi, functionName: 'accountingStatus' }),
    publicClient.readContract({ address: HARBOR.vault, abi: queueAbi, functionName: 'tradingCash', args: [0n] }),
    publicClient.readContract({ address: TOKENS.WETH, abi: queueAbi, functionName: 'balanceOf', args: [HARBOR.vault] }),
  ]);
  return pending > 0n && spendable === 0n && held >= cash ? pending : 0n;
}

/** Rethrow a vault-buy revert as the queue blocker it is, or as itself. */
export async function explainCapacity(error: unknown, vaultPays: boolean): Promise<never> {
  if (vaultPays && revertSelector(error) === CAPACITY_EXCEEDED) {
    const pending = await blockingWithdrawals().catch(() => 0n);
    if (pending > 0n) throw new UnfundedWithdrawalsError(pending);
  }
  throw error;
}

export type Funding = {
  hash: Hex;
  /** tickets funded by this call, and the WETH they now have reserved */
  tickets: number;
  assets: bigint;
  /** still unfunded afterwards - a partial head stops the batch */
  stillPending: bigint;
};

const call = (functionName: 'checkpointValuation' | 'fulfillWithdrawals', user: Address): Call => ({
  to: HARBOR.vault, account: user,
  data: functionName === 'fulfillWithdrawals'
    ? encodeFunctionData({ abi: vaultAbi, functionName, args: [WITHDRAWAL_BATCH_SIZE] })
    : encodeFunctionData({ abi: vaultAbi, functionName }),
});

/**
 * Fund the oldest withdrawal tickets from the vault's cash. This reserves WETH
 * for those LPs; it does not pay them, and it pays the caller nothing. Anyone
 * may call it and the caller pays the gas.
 *
 * Funding needs a fresh valuation, and every trade leaves the valuation stale,
 * so a stale vault is re-marked first - also permissionless, also paid by the
 * caller. Both calls are simulated before the wallet is asked to sign.
 */
export async function fundWithdrawals(
  user: Address,
  send: Send,
  progress: (step: string) => void,
  submitted: (hash: Hex) => void = () => {},
): Promise<Funding> {
  await requireNetwork();
  const vault = { address: HARBOR.vault, abi: vaultAbi, account: user } as const;
  const [, , pending, valid] = await publicClient.readContract({ address: HARBOR.vault, abi: vaultAbi, functionName: 'accountingStatus' });
  if (pending === 0n) throw new Error('No withdrawals are waiting to be funded.');

  if (!valid) {
    await publicClient.simulateContract({ ...vault, functionName: 'checkpointValuation' });
    progress('Refreshing valuation…');
    await sendConfirmed(call('checkpointValuation', user), send);
  }

  await publicClient.simulateContract({ ...vault, functionName: 'fulfillWithdrawals', args: [WITHDRAWAL_BATCH_SIZE] });
  progress('Funding withdrawals…');
  const hash = await send(call('fulfillWithdrawals', user));
  submitted(hash);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') throw new Error('Funding reverted. No withdrawals were funded.');

  const funded = parseEventLogs({ abi: queueAbi, eventName: 'WithdrawalFulfilled', logs: receipt.logs })
    .filter(log => log.address.toLowerCase() === HARBOR.vault);
  const [, , stillPending] = await publicClient.readContract({ address: HARBOR.vault, abi: vaultAbi, functionName: 'accountingStatus' });
  return { hash, stillPending, tickets: funded.length, assets: funded.reduce((sum, log) => sum + log.args.assets, 0n) };
}
