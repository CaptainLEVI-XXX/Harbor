import { chain, deploymentEnabled, publicClient } from '@/lib/chain';
export { HARBOR, ASSETS, GRAPH_ENDPOINT, GRAPH_DEPLOYMENT, POOL_ID } from '@/lib/constants';

export async function requireNetwork() {
  if (!deploymentEnabled) throw new Error('This harbor deployment requires NEXT_PUBLIC_CHAIN=hoodi.');
  if (await publicClient.getChainId() !== chain.id) throw new Error('RPC is not connected to Hoodi.');
}

export function errorMessage(error: unknown): string {
  // Do not expose authenticated RPC URLs or request bodies in the UI.
  const message = error instanceof Error && 'shortMessage' in error ? String(error.shortMessage) : error instanceof Error ? error.message.split('\n')[0] : 'Request failed. Please retry.';
  return message.replace(/https?:\/\/\S+/g, '[endpoint]');
}
