import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

const network = JSON.parse(readFileSync(new URL('../subgraph/networks.json', import.meta.url))).hoodi;
const deployment = network.subgraphDeployment;
async function post(url, body) {
  const response = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' },
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
async function graph(query, variables = {}) {
  const data = (await post(deployment.queryUrl, { query, variables })).data;
  if (!data?._meta || data._meta.hasIndexingErrors || data._meta.deployment !== deployment.id) throw Error('Unhealthy or changed deployment');
  return data;
}
try {
  if (!deployment || !process.env.HOODI_RPC_URL || BigInt(await rpc('eth_chainId')) !== 560048n) throw Error('Missing or wrong network');
  const head = (await graph('{ _meta { deployment hasIndexingErrors block { number hash } } }'))._meta.block;
  const block = '0x' + head.number.toString(16);
  const before = await rpc('eth_getBlockByNumber', [block, false]);
  if (before.hash !== head.hash) throw Error('Graph/RPC fork mismatch');
  const poolId = '0x' + Buffer.from('harbor:pool:v1').toString('hex')
    + BigInt(network.chainId).toString(16).padStart(64, '0') + network.contracts.Book.address.slice(2).toLowerCase();
  const query = readFileSync(new URL('../queries/harbor.graphql', import.meta.url), 'utf8');
  const data = await graph(query, { id: poolId, block: { hash: head.hash } });
  const p = data.pool;
  if (!p?.complete || p.chainId !== '560048' || p.book !== network.contracts.Book.address.toLowerCase()
    || p.vault !== network.contracts.Vault.address.toLowerCase() || p.environment !== 'TESTNET') throw Error('Pool mismatch or incomplete history');
  async function call(to, signature, args = []) {
    const input = execFileSync('cast', ['calldata', signature, ...args], { encoding: 'utf8' }).trim();
    return BigInt(await rpc('eth_call', [{ to, data: input }, block]));
  }
  const supply = await call(p.vault, 'totalSupply()');
  if (supply !== BigInt(p.shareSupply)) throw Error('Indexed share supply disagrees with contract');
  const cash = await call(p.asset, 'balanceOf(address)', [p.vault]);
  const after = await rpc('eth_getBlockByNumber', [block, false]);
  if (after.hash !== before.hash) throw Error('Reorg during verification');
  console.log(JSON.stringify({ deployment: deployment.id, queryUrl: deployment.queryUrl,
    block: head, rpcHeaderMatched: true, shareSupplyMatched: true, pool: p,
    cashOverlay: { raw: cash.toString(), blockHash: head.hash },
    note: 'Checkpoint is historical; current cash is a separate pinned RPC observation. Not a full lifecycle or finality proof.' }, null, 2));
} catch {
  console.error('Harbor live verification failed; check deployment, indexing health, RPC and reconciliation');
  process.exitCode = 1;
}
