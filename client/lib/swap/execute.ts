import {
  BaseError,
  UserRejectedRequestError,
  encodeFunctionData,
  erc20Abi,
  type Address,
  type Hex,
} from 'viem';
import { publicClient } from '@/lib/chain';

/**
 * Stand-ins until the quote service and a testnet deployment exist. A call to
 * an address with no code succeeds and does nothing, so the flow runs for real.
 * They become the deployed HarborExecutor and its `execute` calldata.
 */
export const MOCK_EXECUTOR: Address = '0x000000000000000000000000000000000000dEaD';
const MOCK_SWAP_CALLDATA: Hex = '0xdeadbeef';

export type Call = { to: Address; data: Hex };
export type Step = { kind: 'approve' | 'swap'; call: Call };

const SWAP: Step = { kind: 'swap', call: { to: MOCK_EXECUTOR, data: MOCK_SWAP_CALLDATA } };

/** Approve exactly what the trade pays, and only when the allowance falls short. */
export function buildSteps({
  allowance,
  payWei,
  token,
}: {
  allowance: bigint;
  payWei: bigint;
  token: Address;
}): Step[] {
  if (allowance >= payWei) return [SWAP];
  const data = encodeFunctionData({
    abi: erc20Abi,
    functionName: 'approve',
    args: [MOCK_EXECUTOR, payWei],
  });
  return [{ kind: 'approve', call: { to: token, data } }, SWAP];
}

export function readAllowance(token: Address, owner: Address): Promise<bigint> {
  return publicClient.readContract({
    address: token,
    abi: erc20Abi,
    functionName: 'allowance',
    args: [owner, MOCK_EXECUTOR],
  });
}

/**
 * Sends the steps in order, each confirmed before the next. `onStep` runs
 * before every step and may veto it, which resolves null. Otherwise resolves
 * the last step's hash - the swap's.
 */
export async function runSteps(
  steps: Step[],
  send: (call: Call) => Promise<Hex>,
  onStep: (step: Step) => boolean,
): Promise<Hex | null> {
  let hash: Hex | null = null;
  for (const step of steps) {
    if (!onStep(step)) return null;
    hash = await send(step.call);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status === 'reverted') throw new Error(`${step.kind} reverted: ${hash}`);
  }
  return hash;
}

/** The user said no in their own wallet - not a failure. */
export function isRejection(error: unknown): boolean {
  return (
    error instanceof BaseError &&
    error.walk(e => e instanceof UserRejectedRequestError) !== null
  );
}
