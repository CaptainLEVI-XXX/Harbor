import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

// Read-only verification. Credentials never enter command arguments or output.
const rpcUrl = process.env.HOODI_RPC_URL;
async function rpc(method, params) {
  const response = await fetch(rpcUrl, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
    signal: AbortSignal.timeout(30000),
  });
  const data = await response.json();
  if (!response.ok || data.error || data.result == null) throw Error(`RPC failed: ${method}`);
  return data.result;
}
function check(ok, message) { if (!ok) throw Error(message); }
async function call(target, signature, args = []) {
  const encoded = spawnSync('cast', ['calldata', signature, ...args], { encoding: 'utf8' });
  check(encoded.status === 0, 'Calldata encoding failed');
  return BigInt(await rpc('eth_call', [{ to: target, data: encoded.stdout.trim() }, 'latest']));
}
async function main() {
  check(BigInt(await rpc('eth_chainId', [])) === 560048n, 'Wrong network');
  const record = JSON.parse(readFileSync('broadcast/DeployHarborHoodi.s.sol/560048/run-latest.json'));
  check(record.transactions.length === 17, 'Unexpected deployment scope');
  const verified = [];
  let fees = 0n;
  for (const tx of record.transactions) {
    check(Boolean(tx.hash), 'Missing transaction hash');
    const receipt = await rpc('eth_getTransactionReceipt', [tx.hash]);
    check(receipt.status === '0x1', `Unsuccessful transaction: ${tx.hash}`);
    const sent = await rpc('eth_getTransactionByHash', [tx.hash]);
    check(sent.from.toLowerCase() === '0x41363507931dd8963f5eb836e299d74272d0ccb0', 'Unexpected deployer');
    check(BigInt(sent.value) === 0n, 'Unexpected value transfer');
    check(sent.input.toLowerCase() === tx.transaction.input.toLowerCase(), 'Transaction input mismatch');
    fees += BigInt(receipt.gasUsed) * BigInt(receipt.effectiveGasPrice);
    if (tx.transactionType !== 'CALL') {
      const code = await rpc('eth_getCode', [tx.contractAddress, 'latest']);
      check(code !== '0x' && (code.length - 2) / 2 <= 24576, 'Missing or oversized deployed code');
      if (tx.transactionType === 'CREATE') {
        check(receipt.contractAddress.toLowerCase() === tx.contractAddress.toLowerCase(), 'CREATE address mismatch');
      }
    }
    verified.push({ name: tx.contractName, type: tx.transactionType, address: tx.contractAddress,
      transactionHash: tx.hash, block: Number(BigInt(receipt.blockNumber)), gasUsed: BigInt(receipt.gasUsed).toString() });
  }
  const address = name => verified.find(t => t.name === name && t.type === 'CREATE').address;
  const book = address('HarborBook'), vault = address('HarborVault');
  const executor = address('HarborExecutor'), adapter = address('LidoAdapter');
  const factory = address('HarborClaimFactory');
  const governor = '0x41363507931dd8963f5eb836e299d74272d0ccb0';
  const weth = '0xE0decAa66aED871ac9eb924443D1Bf333Fdb062E';
  const router = '0x63C78337758eA9c98b4Ce6Cc9988E72e2D8F3303';
  const expectations = [
    [book, 'VAULT()', vault], [book, 'EXECUTOR()', executor], [vault, 'BOOK()', book],
    [book, 'ASSET()', weth], [vault, 'ASSET()', weth], [book, 'ROUTER()', router],
    [book, 'AQUA()', '0xf40826aFd0de1078bc4b39b77E87E42d3b35Fe6A'],
    [executor, 'ROUTER()', router], [adapter, 'BOOK()', book], [adapter, 'VAULT()', vault],
    [adapter, 'FACTORY()', factory], [adapter, 'ASSET()', weth],
    [book, 'FEE_BPS()', 0n], [book, 'CASH_BUFFER()', 0n], [book, 'CAPACITY_PENALTY()', 0n],
    [book, 'MAX_EXPOSURE()', 1000n * 10n ** 18n], [book, 'FACE_CAP()', 1000n * 10n ** 18n],
    [book, 'MAX_PARAMETER_AGE()', 8640000n], [book, 'MAX_MARK_AGE()', 8640000n],
    [vault, 'MAX_MARK_AGE()', 8640000n], [adapter, 'MAX_AGE()', 8640000n],
    [vault, 'MIN_INITIAL_ASSETS()', 10n ** 12n], [vault, 'MIN_REQUEST_SHARES()', 10n ** 18n],
    [factory, 'GOVERNANCE_DELAY()', 0n],
    ...[book, executor, adapter, factory].map(a => [a, 'GOVERNOR()', governor]),
    ...['GUARDIAN()', 'KEEPER()', 'FEE_RECIPIENT()', 'parameterUpdater()'].map(s => [book, s, governor]),
    [adapter, 'publisher()', governor],
  ];
  for (const [target, signature, expected] of expectations) {
    check(await call(target, signature) === BigInt(expected), `Binding/config mismatch: ${signature}`);
  }
  check(await call(executor, 'vaultOf(address)', [book]) === BigInt(vault), 'Pool registration mismatch');
  console.log(JSON.stringify({ chainId: 560048, verifiedAt: new Date().toISOString(),
    status: 'DEPLOYED_NOT_CONFIGURED', transactions: verified, actualDeploymentFeeWei: fees.toString(),
    bindingAndConfigChecks: expectations.length + 1, finalityAttested: false }, null, 2));
}
main().catch(error => {
  let message = error.message;
  for (const secret of [rpcUrl, process.env.HOODI_PRIVATE_KEY]) {
    if (secret) message = message.split(secret).join('[REDACTED]');
  }
  console.error(message); process.exitCode = 1;
});
