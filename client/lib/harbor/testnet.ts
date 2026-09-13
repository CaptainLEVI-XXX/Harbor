import { encodeFunctionData, erc20Abi, parseEventLogs, type Address, type Hex } from 'viem';
import { publicClient, TOKENS } from '@/lib/chain';
import type { Send } from '@/lib/wallet/types';
import { HARBOR, requireNetwork } from './config';
import { sendConfirmed } from '@/lib/wallet/confirmation';

import { queueAbi as lidoHelperAbi, conversionAbi } from './abis';

/** One request, one NFT, no custodial helper contract or private key. */
function withdrawalCall(amount: bigint, owner: Address) {
  return { to: HARBOR.queue, account: owner, data: encodeFunctionData({ abi: lidoHelperAbi, functionName: 'requestWithdrawalsWstETH', args: [[amount], owner] }) };
}

export async function getWstETH(amount: bigint, user: Address, send: Send, submitted?: (hash: Hex) => void) {
  await requireNetwork();
  if (amount <= 0n || await publicClient.getBalance({ address: user }) <= amount) throw new Error('Enter an ETH amount and leave some ETH for gas.');
  // Lido wstETH.receive() submits ETH to Lido and wraps the resulting stETH.
  const call = { to: TOKENS.wstETH, data: '0x' as const, value: amount, account: user };
  await publicClient.call(call);
  return sendConfirmed(call, send, submitted);
}

export async function getWithdrawalNFT(amount: bigint, user: Address, send: Send, progress: (message: string) => void, submitted?: (hash: Hex) => void) {
  await requireNetwork();
  if (amount <= 0n) throw new Error('Enter a positive wstETH amount.');
  const [binding, minimum, maximum, nominal, balance, allowance] = await Promise.all([
    publicClient.readContract({ address: HARBOR.queue, abi: lidoHelperAbi, functionName: 'WSTETH' }),
    publicClient.readContract({ address: HARBOR.queue, abi: lidoHelperAbi, functionName: 'MIN_STETH_WITHDRAWAL_AMOUNT' }),
    publicClient.readContract({ address: HARBOR.queue, abi: lidoHelperAbi, functionName: 'MAX_STETH_WITHDRAWAL_AMOUNT' }),
    publicClient.readContract({ address: TOKENS.wstETH, abi: conversionAbi, functionName: 'getStETHByWstETH', args: [amount] }),
    publicClient.readContract({ address: TOKENS.wstETH, abi: erc20Abi, functionName: 'balanceOf', args: [user] }),
    publicClient.readContract({ address: TOKENS.wstETH, abi: erc20Abi, functionName: 'allowance', args: [user, HARBOR.queue] }),
  ]);
  if (binding.toLowerCase() !== TOKENS.wstETH) throw new Error('Unexpected Lido queue asset binding.');
  if (amount > balance) throw new Error('Not enough wstETH. Obtain wstETH first.');
  if (nominal < minimum || nominal > maximum) throw new Error('Amount is outside Lido’s withdrawal-request limits.');
  const approval = { to: TOKENS.wstETH, account: user, data: encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [HARBOR.queue, amount] }) };
  const request = withdrawalCall(amount, user);
  let hash;
  if (allowance < amount) {
    progress('Approve wstETH & request NFT · batch where supported…');
    hash = await send.batch?.([approval, request]);
    if (!hash) {
      progress('Sequential flow: approve wstETH…');
      await publicClient.call(approval);
      await sendConfirmed(approval, send);
    }
  }
  if (!hash) {
    progress('Requesting Lido withdrawal NFT…');
    await publicClient.call(request);
    hash = await sendConfirmed(request, send, submitted);
  }
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') throw new Error('Withdrawal request reverted.');
  const events = parseEventLogs({ abi: lidoHelperAbi, eventName: 'WithdrawalRequested', logs: receipt.logs });
  const created = events.filter(e => e.address.toLowerCase() === HARBOR.queue && e.args.owner.toLowerCase() === user.toLowerCase() && e.args.requestor.toLowerCase() === user.toLowerCase());
  // The simulation's predicted ID can race other users. Read actual mint IDs.
  if (created.length !== 1) throw new Error('Could not verify the new NFT. Check the explorer before retrying.');
  return { hash, requestId: created[0].args.requestId };
}
