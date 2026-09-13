import type { Address, Hex } from 'viem';

/** Every prepared call is bound to the account that approved the intent. */
export type Call = { to: Address; data: Hex; value?: bigint; account: Address };
export type Atomic = 'supported' | 'ready' | 'unsupported';
export type BatchOptions = { upgradeAccount?: boolean };
export type Send = ((call: Call) => Promise<Hex>) & {
  /** null only before submission. Rejections and uncertain submissions throw. */
  batch?: (calls: Call[], options?: BatchOptions) => Promise<Hex | null>;
  atomic?: () => Promise<Atomic>;
};
