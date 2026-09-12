// Read-only evidence of execution-layer indexing; not Harbor deployment evidence.
const id = 'F4AU5vPCuKfHvnLsusibxJEiTN7ELCoYTvnzg3YHGYbh';
async function post(url, body, headers = {}) {
  const response = await fetch(url, { method: 'POST',
    headers: { 'Content-Type': 'application/json', ...headers },
    body: JSON.stringify(body), signal: AbortSignal.timeout(30000) });
  const data = await response.json();
  if (!response.ok || data.errors || data.error) throw Error('Provider request failed');
  return data;
}
async function rpc(method, params = []) {
  const data = await post(process.env.HOODI_RPC_URL, { jsonrpc: '2.0', id: 1, method, params });
  if (data.result == null) throw Error('Missing RPC result');
  return data.result;
}
try {
  if (!process.env.GRAPH_API_KEY || !process.env.HOODI_RPC_URL) throw Error('Configure GRAPH_API_KEY and HOODI_RPC_URL');
  if (BigInt(await rpc('eth_chainId')) !== 560048n) throw Error('Wrong RPC chain');
  const data = await post(`https://gateway.thegraph.com/api/subgraphs/id/${id}`, {
    query: '{ _meta { deployment hasIndexingErrors block { number hash timestamp } } accounts(first: 1) { id } }',
  }, { Authorization: `Bearer ${process.env.GRAPH_API_KEY}` });
  const meta = data.data?._meta;
  if (!meta || meta.hasIndexingErrors || !Number.isSafeInteger(meta.block.number) || !meta.block.hash || !data.data.accounts?.length) {
    throw Error('Missing or unhealthy live Graph evidence');
  }
  const block = await rpc('eth_getBlockByNumber', ['0x' + meta.block.number.toString(16), false]);
  if (block.hash.toLowerCase() !== meta.block.hash.toLowerCase()
    || BigInt(block.timestamp) !== BigInt(meta.block.timestamp)) throw Error('Graph/RPC block mismatch');
  console.log(JSON.stringify({ chainId: 560048, network: 'hoodi', subgraphId: id,
    ...meta, rpcHeaderMatched: true, accountSampleReturned: true,
    harborSubgraphDeployed: false, newStudioDeploymentPermissionVerified: false }, null, 2));
} catch {
  // Provider exceptions may embed authenticated URLs. Do not print raw errors.
  console.error('Hoodi provider verification failed; check credentials, network and provider health');
  process.exitCode = 1;
}
