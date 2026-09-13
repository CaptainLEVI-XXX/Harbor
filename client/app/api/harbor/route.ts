import { isAddress, zeroAddress } from 'viem';
import { GRAPH_DEPLOYMENT, GRAPH_ENDPOINT, HARBOR, POOL_ID } from '@/lib/harbor/config';
import type { History } from '@/lib/harbor/history';

const QUERY = `query HarborPage($pool: Bytes!, $owner: Bytes!, $block: Block_height!) {
  _meta(block: $block) { deployment hasIndexingErrors block { number hash } }
  pool(id: $pool, block: $block) { book chainId complete portfolioChangedSinceCheckpoint
    lastCheckpoint { nav supply cash reserved inventoryMark claimMark timestamp observedAt } }
  strategies(first: 100, orderBy: id, block: $block, where: { pool: $pool }) {
    id route kind label settlementPath base inventoryUnits inventoryBasis pendingBasis customerCashVolume protocolFees recoveredCash realizedResult }
  trades(first: 20, orderBy: timestamp, orderDirection: desc, block: $block, where: { pool: $pool }) {
    id timestamp buyBase amountIn amountOut customerCash fee transactionHash logIndex blockNumber tokenId strategy { kind route label } }
  exitRequests(first: 20, orderBy: requestedAt, orderDirection: desc, block: $block, where: { pool: $pool }) {
    id requestedShares pendingShares fundedAssets requestedAt fundingCompletedAt requestTransaction requestLogIndex }
  lpDeposits: lpdeposits(first: 20, orderBy: blockNumber, orderDirection: desc, block: $block, where: { pool: $pool }) {
    id receiver assets shares timestamp transactionHash logIndex blockNumber }
  claimRecoveries(first: 20, orderBy: blockNumber, orderDirection: desc, block: $block, where: { pool: $pool }) {
    id cash timestamp transactionHash logIndex blockNumber }
  exitPayouts(first: 20, orderBy: blockNumber, orderDirection: desc, block: $block, where: { pool: $pool }) {
    id assets timestamp transactionHash logIndex blockNumber }
  valuationCheckpoints(first: 100, orderBy: blockNumber, orderDirection: desc, block: $block, where: { pool: $pool }) {
    id nav supply cash reserved inventoryMark claimMark timestamp blockNumber logIndex }
  tradeSeries: trades(first: 1000, orderBy: timestamp, orderDirection: desc, block: $block, where: { pool: $pool }) {
    timestamp customerCash strategy { id } }
  realizations(first: 1000, orderBy: timestamp, orderDirection: desc, block: $block, where: { pool: $pool }) {
    timestamp result strategy { id } }
  userDeposits: lpdeposits(first: 100, block: $block, where: { pool: $pool, receiver: $owner }) {
    assets shares }
  receipts(first: 20, orderBy: id, block: $block, where: { owner: $owner, chainId: "560048" }) {
    id address owner complete redeemed nominal collectedCash paidCash createdAt }
}`;

async function query<T>(query: string, variables = {}): Promise<T> {
  const response = await fetch(GRAPH_ENDPOINT, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ query, variables }),
    cache: 'force-cache', next: { revalidate: 60 }, signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) throw new Error('Graph provider unavailable');
  const result = await response.json();
  if (result.errors?.length || !result.data) throw new Error('Graph query failed');
  return result.data as T;
}

/** Fixed, bounded query surface. Not an arbitrary provider proxy or a balance authority. */
export async function GET(request: Request) {
  const owner = new URL(request.url).searchParams.get('owner') ?? zeroAddress;
  if (!isAddress(owner)) return Response.json({ error: 'Invalid owner' }, { status: 400 });
  try {
    const head = await query<Pick<History, '_meta'>>('{ _meta { deployment hasIndexingErrors block { number hash } } }');
    if (head._meta.deployment !== GRAPH_DEPLOYMENT || head._meta.hasIndexingErrors || !head._meta.block.hash) throw new Error('Invalid Graph source');
    const data = await query<History>(QUERY, { pool: POOL_ID, owner: owner.toLowerCase(), block: { hash: head._meta.block.hash } });
    if (!data.pool || data.pool.book.toLowerCase() !== HARBOR.book || data.pool.chainId !== '560048' || !data.pool.complete || data._meta.hasIndexingErrors || data._meta.deployment !== GRAPH_DEPLOYMENT || data._meta.block.hash !== head._meta.block.hash) throw new Error('Incomplete Graph projection');
    return Response.json(data, { headers: { 'Cache-Control': 'private, max-age=30' } });
  } catch {
    return Response.json({ error: 'Historical data unavailable or incomplete' }, { status: 503 });
  }
}
