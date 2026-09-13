import { decodeFunctionResult, encodeFunctionData, parseEventLogs, type Address, type Hex } from 'viem';
import { publicClient } from '@/lib/chain';
import { peripheryAbi, vaultAbi } from './abis';
import { AUTO_SLIPPAGE_BPS, WITHDRAWAL_BATCH_SIZE } from '@/lib/constants';
import { sendConfirmed } from '@/lib/wallet/confirmation';
import { HARBOR, requireNetwork } from './config';
import type { Call } from '@/lib/wallet/types';
import type { Send } from '@/lib/wallet/types';

/** claim pays exact ETH (vault withdraw); redeem spends exact funded claim units */
export type VaultAction = 'deposit' | 'mint' | 'request' | 'claim' | 'redeem' | 'checkpoint';

const depositCall = (minShares: bigint, amount: bigint, user: Address): Call => ({
  to: HARBOR.periphery, account: user, value: amount,
  data: encodeFunctionData({ abi: peripheryAbi, functionName: 'deposit', args: [HARBOR.book, minShares] }),
});

/** exact shares out; the value is the ETH the vault asks for them, never more */
const mintCall = (shares: bigint, assets: bigint, user: Address): Call => ({
  to: HARBOR.periphery, account: user, value: assets,
  data: encodeFunctionData({ abi: peripheryAbi, functionName: 'mint', args: [HARBOR.book, shares] }),
});

const redeemCall = (units: bigint, minAssets: bigint, user: Address): Call => ({
  to: HARBOR.periphery, account: user,
  data: encodeFunctionData({ abi: peripheryAbi, functionName: 'redeem', args: [HARBOR.book, units, minAssets] }),
});

/**
 * Funded credit converts at the ratio it was funded at, so the floor is that
 * ratio less the swap tolerance - never a fresh share price.
 */
async function minimumClaimAssets(units: bigint, user: Address) {
  const blockNumber = await publicClient.getBlockNumber();
  const [assets, credit] = await Promise.all([
    publicClient.readContract({ address: HARBOR.vault, abi: vaultAbi, functionName: 'maxWithdraw', args: [user], blockNumber }),
    publicClient.readContract({ address: HARBOR.vault, abi: vaultAbi, functionName: 'maxRedeem', args: [user], blockNumber }),
  ]);
  if (credit === 0n || units > credit) throw new Error('That is more than your funded withdrawal.');
  return units * assets / credit * (10_000n - AUTO_SLIPPAGE_BPS) / 10_000n;
}

const operatorCall = (user: Address): Call => ({
  to: HARBOR.vault, account: user,
  data: encodeFunctionData({ abi: vaultAbi, functionName: 'setOperator', args: [HARBOR.periphery, true] }),
});

const claimCall = (assets: bigint, user: Address): Call => ({
  to: HARBOR.periphery, account: user,
  data: encodeFunctionData({ abi: peripheryAbi, functionName: 'withdraw', args: [HARBOR.book, assets] }),
});

const requestCall = (shares: bigint, user: Address): Call => ({
  to: HARBOR.vault, account: user,
  data: encodeFunctionData({ abi: vaultAbi, functionName: 'requestRedeem', args: [shares, user, user] }),
});
const fundingCall = (user: Address): Call => ({
  to: HARBOR.vault, account: user,
  data: encodeFunctionData({ abi: vaultAbi, functionName: 'fulfillWithdrawals', args: [WITHDRAWAL_BATCH_SIZE] }),
});

/** One funded unit equals one funded requested share (LPExitQueue.fundHead).
 * Simulate the complete FIFO sequence before offering an immediate native payout.
 * Existing credits stay separate: do not consume an older entitlement accidentally.
 * A null result means nothing was submitted. Never catch a submission to retry it.
 */
async function immediateWithdrawal(shares: bigint, user: Address, send: Send, progress: (label: string) => void, upgradeAccount: boolean) {
  if (!send.batch || !send.atomic) return null;
  const capability = await send.atomic();
  if (capability !== 'supported' && !(capability === 'ready' && upgradeAccount)) return null;
  let calls: Call[];
  let minimum: bigint;
  try {
    const blockNumber = await publicClient.getBlockNumber();
    const [pending, funded, operator] = await Promise.all([
      publicClient.readContract({ address: HARBOR.vault, abi: vaultAbi, functionName: 'pendingRedeemRequest', args: [0n, user], blockNumber }),
      publicClient.readContract({ address: HARBOR.vault, abi: vaultAbi, functionName: 'claimableRedeemRequest', args: [0n, user], blockNumber }),
      publicClient.readContract({ address: HARBOR.vault, abi: vaultAbi, functionName: 'isOperator', args: [user, HARBOR.periphery], blockNumber }),
    ]);
    if (pending !== 0n || funded !== 0n) return null;
    calls = [requestCall(shares, user), fundingCall(user), ...(operator ? [] : [operatorCall(user)]), redeemCall(shares, 1n, user)];
    const simulation = await publicClient.simulateCalls({
      account: user, blockNumber, calls: calls.map(({ to, data, value }) => ({ to, data, value })),
    });
    if (simulation.results.length !== calls.length || simulation.results.some(r => r.status !== 'success')) return null;
    const last = simulation.results[simulation.results.length - 1];
    const assets = decodeFunctionResult({ abi: peripheryAbi, functionName: 'redeem', data: last.data });
    if (assets === 0n) return null;
    minimum = assets * (10_000n - AUTO_SLIPPAGE_BPS) / 10_000n;
    if (minimum === 0n) minimum = 1n;
    calls[calls.length - 1] = redeemCall(shares, minimum, user);
  } catch {
    // Unsupported simulation RPC, insufficient FIFO cash, or stale issuer inputs:
    // preserve the independently available request path. No transaction exists yet.
    return null;
  }
  progress('Withdrawing ETH in one transaction…');
  const hash = await send.batch(calls, { upgradeAccount });
  if (!hash) return null;
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') throw new Error('Withdrawal batch reverted. No request or payout from this batch was retained.');
  const paid = parseEventLogs({ abi: peripheryAbi, eventName: 'NativeWithdrawal', logs: receipt.logs }).some(e =>
    e.address.toLowerCase() === HARBOR.periphery && e.args.book.toLowerCase() === HARBOR.book
    && e.args.caller.toLowerCase() === user.toLowerCase() && e.args.shares === shares && e.args.assets >= minimum);
  if (!paid) throw new Error(`Withdrawal transaction confirmed (${hash}) without the expected native payout. Check wallet activity before retrying.`);
  return hash;
}

/** The floor of shares a deposit must mint, on the same tolerance a swap carries. */
async function minimumShares(amount: bigint) {
  const preview = await publicClient.readContract({
    address: HARBOR.vault, abi: vaultAbi, functionName: 'previewDeposit', args: [amount],
  });
  return preview * (10_000n - AUTO_SLIPPAGE_BPS) / 10_000n;
}

/**
 * Immediate native exit when an atomic wallet and full FIFO simulation permit it;
 * otherwise a durable request followed by one permissionless funding attempt.
 * No pricing, governance, issuer recovery or Aqua publication calls.
 *
 * ETH is the only thing a customer hands over and the only thing they get back:
 * the periphery wraps on the way in and unwraps on the way out, so WETH never
 * reaches the wallet. Requesting an exit stays a direct vault call, because the
 * shares being queued are the customer's own and no periphery is involved.
 */
/** `submitted` fires for the action's final transaction only, never an intermediate authorisation. */
export async function runVaultAction(action: VaultAction, amount: bigint, user: Address, send: Send, progress: (label: string) => void, upgradeAccount = false, submitted?: (hash: Hex) => void) {
  await requireNetwork();

  // Optional refresh only. Current deposit/mint execution refreshes authorized
  // marks itself; a checkpoint cannot repair expired or invalid issuer inputs.
  if (action === 'checkpoint') {
    const call: Call = { to: HARBOR.vault, account: user, data: encodeFunctionData({ abi: vaultAbi, functionName: 'checkpointValuation' }) };
    await publicClient.simulateContract({ address: HARBOR.vault, abi: vaultAbi, functionName: 'checkpointValuation', account: user });
    progress('Refreshing valuation…');
    return sendConfirmed(call, send, submitted);
  }

  if (amount <= 0n) throw new Error('Enter a positive amount.');

  if (action === 'deposit') {
    const maximum = await publicClient.readContract({ address: HARBOR.vault, abi: vaultAbi, functionName: 'maxDeposit', args: [user] });
    if (amount > maximum) throw new Error('Deposit exceeds the vault’s current limit. No ETH was spent.');
    if (await publicClient.getBalance({ address: user }) <= amount) throw new Error('Keep some native ETH for gas.');
    const call = depositCall(await minimumShares(amount), amount, user);
    await publicClient.call({ to: call.to, data: call.data, value: call.value, account: user });
    progress('Depositing…');
    return sendConfirmed(call, send, submitted);
  }

  // Exact shares: the ETH is read from previewMint at the latest block and sent
  // as-is. No buffer - if the price rises before inclusion the call reverts
  // rather than taking more than was shown.
  if (action === 'mint') {
    const assets = await publicClient.readContract({ address: HARBOR.vault, abi: vaultAbi, functionName: 'previewMint', args: [amount] });
    const maximum = await publicClient.readContract({ address: HARBOR.vault, abi: vaultAbi, functionName: 'maxMint', args: [user] });
    if (amount > maximum) throw new Error('Deposit exceeds the vault’s current limit. No ETH was spent.');
    if (await publicClient.getBalance({ address: user }) <= assets) throw new Error('Keep some native ETH for gas.');
    const call = mintCall(amount, assets, user);
    await publicClient.call({ to: call.to, data: call.data, value: call.value, account: user });
    progress('Depositing…');
    return sendConfirmed(call, send, submitted);
  }

  if (action === 'request') {
    const immediate = await immediateWithdrawal(amount, user, send, progress, upgradeAccount);
    if (immediate) return immediate;
    await publicClient.simulateContract({ address: HARBOR.vault, abi: vaultAbi, functionName: 'requestRedeem', args: [amount, user, user], account: user });
    progress('Requesting withdrawal…');
    const requestHash = await sendConfirmed(requestCall(amount, user), send);
    // The request is durable before this independent attempt. Funding respects
    // FIFO and may fund earlier users, partially fund this user, or fund nobody.
    // Never loop, claim automatically, or repeat a request after funding fails.
    try {
      const funding = fundingCall(user);
      await publicClient.call({ ...funding });
      progress('Request confirmed. Funding available withdrawals…');
      return await sendConfirmed(funding, send, submitted);
    } catch {
      throw new Error(`Withdrawal request confirmed (${requestHash}). Funding was not confirmed. Do not request again; refresh your pending/funded balance and check wallet activity.`);
    }
  }

  // Claiming pays out through the periphery, which must be an operator on the
  // vault to redeem on the customer's behalf. Check again: users can revoke it.
  if (action === 'claim') {
    const available = await publicClient.readContract({ address: HARBOR.vault, abi: vaultAbi, functionName: 'maxWithdraw', args: [user] });
    if (amount > available) throw new Error('That is more than your funded withdrawal.');
  }
  const operator = await publicClient.readContract({ address: HARBOR.vault, abi: vaultAbi, functionName: 'isOperator', args: [user, HARBOR.periphery] });
  const payout = action === 'redeem' ? redeemCall(amount, await minimumClaimAssets(amount, user), user) : claimCall(amount, user);
  const calls = [...(operator ? [] : [operatorCall(user)]), payout];
  if (calls.length > 1) {
    progress('Authorising, then claiming…');
    const batch = await send.batch?.(calls, { upgradeAccount });
    if (batch) {
      const receipt = await publicClient.waitForTransactionReceipt({ hash: batch });
      if (receipt.status !== 'success') throw new Error('Claim batch reverted.');
      return batch;
    }
    progress('Authorising the periphery…');
    await publicClient.call({ to: calls[0].to, data: calls[0].data, account: user });
    await sendConfirmed(calls[0], send);
  }
  const claim = calls[calls.length - 1];
  await publicClient.call({ to: claim.to, data: claim.data, account: user });
  progress('Claiming ETH…');
  return sendConfirmed(claim, send, submitted);
}
