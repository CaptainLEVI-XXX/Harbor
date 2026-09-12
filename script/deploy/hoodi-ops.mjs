import { spawnSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';

// Credentials stay in the child environment, never command arguments or output.
const rpcUrl = process.env.HOODI_RPC_URL;
const key = process.env.HOODI_PRIVATE_KEY;
function clean(text) {
  for (const secret of [rpcUrl, key, key?.replace(/^0x/, '')]) {
    if (secret) text = text.split(secret).join('[REDACTED]');
  }
  return text;
}
async function rpc(method, params = []) {
  const response = await fetch(rpcUrl, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
    signal: AbortSignal.timeout(20000),
  });
  const data = await response.json();
  if (!response.ok || data.error || data.result === undefined) throw new Error('RPC_READ_FAILED');
  return data.result;
}
async function main() {
  const [mode, ...args] = process.argv.slice(2);
  if (!rpcUrl || !key) throw new Error('MISSING_HOODI_CONFIGURATION');
  if (BigInt(await rpc('eth_chainId')) !== 560048n) throw new Error('WRONG_CHAIN');
  if (mode === 'inspect') {
    const weth = '0xE0decAa66aED871ac9eb924443D1Bf333Fdb062E';
    const code = await rpc('eth_getCode', [weth, 'latest']);
    const calls = {};
    for (const [name, data] of [['decimals', '0x313ce567'], ['symbol', '0x95d89b41'], ['name', '0x06fdde03']]) {
      calls[name] = await rpc('eth_call', [{ to: weth, data }, 'latest']);
    }
    console.log(JSON.stringify({ chainId: 560048, weth, runtime: code, calls }, null, 2));
    return;
  }
  if (mode === 'read') {
    if (!['eth_getTransactionReceipt', 'eth_getCode', 'eth_call', 'eth_getTransactionCount', 'eth_getBalance', 'eth_getBlockByNumber'].includes(args[0])) throw new Error('READ_METHOD_REQUIRED');
    console.log(JSON.stringify(await rpc(args[0], JSON.parse(args[1])), null, 2));
    return;
  }
  if (mode === 'verify') {
    if (args.length !== 2 || args.some(a => !/^0x[0-9a-fA-F]{40}$/.test(a))) throw new Error('INVALID_ARGUMENTS');
    const result = [];
    for (const [index, name] of ['Aqua', 'AquaSwapVMRouter'].entries()) {
      const artifact = JSON.parse(readFileSync(`out/${name}.sol/${name}.json`, 'utf8'));
      const entrypoint = index === 0 ? 'runAqua' : 'runRouter';
      const record = JSON.parse(readFileSync(`broadcast/DeployAquaHoodi.s.sol/560048/${entrypoint}-latest.json`, 'utf8'));
      if (record.transactions.length !== 1 || record.transactions[0].contractName !== name) throw new Error('UNEXPECTED_DEPLOYMENT_SCOPE');
      const transactionHash = record.transactions[0].hash;
      const receipt = await rpc('eth_getTransactionReceipt', [transactionHash]);
      const transaction = await rpc('eth_getTransactionByHash', [transactionHash]);
      if (!receipt || receipt.status !== '0x1' || receipt.contractAddress?.toLowerCase() !== args[index].toLowerCase()
        || !transaction || transaction.to !== null || BigInt(transaction.value) !== 0n
        || transaction.from.toLowerCase() !== '0x41363507931dd8963f5eb836e299d74272d0ccb0') throw new Error('DEPLOYMENT_RECEIPT_MISMATCH');
      let input = artifact.bytecode.object;
      if (index === 1) {
        const encoded = spawnSync('cast', ['abi-encode', 'constructor(address,address,address,string,string)',
          args[0], '0xE0decAa66aED871ac9eb924443D1Bf333Fdb062E', transaction.from, 'Harbor', '2'], { encoding: 'utf8' });
        if (encoded.status !== 0) throw new Error('CONSTRUCTOR_ENCODING_FAILED');
        input += encoded.stdout.trim().slice(2);
      }
      if (transaction.input.toLowerCase() !== input.toLowerCase()) throw new Error('CREATION_INPUT_MISMATCH');
      const code = await rpc('eth_getCode', [args[index], 'latest']);
      const actual = Buffer.from(code.slice(2), 'hex');
      const expected = Buffer.from(artifact.deployedBytecode.object.replace(/^0x/, ''), 'hex');
      const normalized = Buffer.from(actual);
      for (const refs of Object.values(artifact.deployedBytecode.immutableReferences ?? {})) {
        for (const { start, length } of refs) {
          normalized.fill(0, start, start + length);
          expected.fill(0, start, start + length);
        }
      }
      if (!normalized.equals(expected)) throw new Error('RUNTIME_MISMATCH');
      result.push({ name, address: args[index], runtimeBytes: actual.length,
        runtimeSha256: createHash('sha256').update(actual).digest('hex'), compiledRuntimeMatched: true,
        creationInputMatched: true, transactionHash, blockNumber: Number(BigInt(receipt.blockNumber)),
        blockHash: receipt.blockHash, gasUsed: BigInt(receipt.gasUsed).toString(),
        feeWei: (BigInt(receipt.gasUsed) * BigInt(receipt.effectiveGasPrice)).toString() });
    }
    const bindings = {};
    for (const signature of ['AQUA()', 'WETH()', 'owner()']) {
      const selector = spawnSync('cast', ['sig', signature], { encoding: 'utf8' });
      if (selector.status !== 0) throw new Error('SELECTOR_FAILED');
      const value = await rpc('eth_call', [{ to: args[1], data: selector.stdout.trim() }, 'latest']);
      bindings[signature] = `0x${value.slice(-40)}`;
    }
    if (bindings['AQUA()'] !== args[0].toLowerCase()
      || bindings['WETH()'] !== '0xe0decaa66aed871ac9eb924443d1bf333fdb062e'
      || bindings['owner()'] !== '0x41363507931dd8963f5eb836e299d74272d0ccb0') throw new Error('BINDING_MISMATCH');
    console.log(JSON.stringify({ chainId: 560048, contracts: result, bindings }, null, 2));
    return;
  }
  const operations = {
    'simulate-aqua': ['runAqua()'],
    'broadcast-aqua': ['runAqua()'],
    'simulate-router': ['runRouter(address,address)', ...args],
    'broadcast-router': ['runRouter(address,address)', ...args],
    'check-weth': ['checkWeth(address)', ...args],
  };
  if (!(mode in operations)) throw new Error('UNKNOWN_OPERATION');
  const count = mode.endsWith('router') ? 2 : mode === 'check-weth' ? 1 : 0;
  if (args.length !== count || args.some(a => !/^0x[0-9a-fA-F]{40}$/.test(a))) throw new Error('INVALID_ARGUMENTS');
  if (mode.startsWith('broadcast-')) {
    const entrypoint = mode === 'broadcast-aqua' ? 'runAqua' : 'runRouter';
    if (existsSync(`broadcast/DeployAquaHoodi.s.sol/560048/${entrypoint}-latest.json`)) {
      throw new Error('BROADCAST_RECORD_EXISTS_CHECK_RECEIPTS_DO_NOT_REDEPLOY');
    }
  }
  const command = ['script', 'script/deploy/DeployAquaHoodi.s.sol:DeployAquaHoodi', '--rpc-url', 'hoodi', '--sig', ...operations[mode]];
  if (mode.startsWith('broadcast-')) command.push('--broadcast', '--slow');
  const child = spawnSync('forge', command, {
    env: { ...process.env, ETH_RPC_URL: rpcUrl, RUST_LOG: 'off' },
    encoding: 'utf8', maxBuffer: 8_000_000,
  });
  process.stdout.write(clean(child.stdout ?? ''));
  process.stderr.write(clean(child.stderr ?? ''));
  if (child.error) throw new Error('FORGE_PROCESS_FAILED');
  process.exitCode = child.status ?? 1;
}
main().catch(error => { console.error(clean(error.message)); process.exitCode = 1; });
