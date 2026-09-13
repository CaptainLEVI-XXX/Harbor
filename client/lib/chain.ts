import { createPublicClient, http } from 'viem';
import { chain, RECEIPT_POLL_MS, RPC_URL } from './constants';
export { chain, TOKENS, sponsored, deploymentEnabled, RPC_URL } from './constants';

// JSON-RPC batching requires no Multicall deployment. Related reads specify
// the same block number; a batch is one HTTP request, not one EVM computation.
export const publicClient = createPublicClient({
  chain,
  pollingInterval: RECEIPT_POLL_MS,
  transport: http(RPC_URL, {
    batch: { wait: 10, batchSize: 50 }, timeout: 15_000, retryCount: 1,
  }),
});
