import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, mkdirSync, writeFileSync } from 'node:fs';

// Stages intentionally require explicit amounts. There is no auto-funding or live default budget.
const modes = {
  fund: ['fund(uint256,uint256,uint256)', 3],
  'stake-a': ['stake(bool,uint256,uint256)', 2, 'true'],
  'stake-b': ['stake(bool,uint256,uint256)', 2, 'false'],
  request: ['requestNfts(uint256[])', 1],
  token: ['sellToken(uint256,uint256,uint256)', 3],
  nfts: ['sellNfts(uint256[],uint256[],uint256)', 3],
  publish: ['publish()', 0],
};
function redact(value) {
  for (const [name, secret] of Object.entries(process.env)) {
    if (!secret || !/PRIVATE_KEY|RPC_URL|^LP_[AB]$|^TRADER_[AB]$/.test(name)) continue;
    const variants = /^0x[\da-f]{64}$/i.test(secret) ? [secret, secret.slice(2), BigInt(secret).toString()] : [secret];
    for (const item of variants) value = value.split(item).join('[REDACTED]');
  }
  return value;
}
try {
  const [mode, ...args] = process.argv.slice(2);
  const broadcast = args.at(-1) === '--broadcast';
  const values = broadcast ? args.slice(0, -1) : args;
  const config = modes[mode];
  if (!config || values.length !== config[1] || values.some(v => !/^(\d+|\[\d+(,\d+)*\])$/.test(v))) {
    throw Error('Use fund A_WEI B_WEI GAS_FLOOR | stake-a/stake-b ETH_WEI MIN_WSTETH | request [WSTETH_AMOUNTS] | token WSTETH MIN_ETH CASH_FLOOR | nfts [CONFIRMED_IDS] [MIN_ETH] CASH_FLOOR | publish. Optional --broadcast.');
  }
  for (const key of ['HOODI_RPC_URL', 'HOODI_PRIVATE_KEY', 'TRADER_A', 'TRADER_B', 'LP_A', 'LP_B']) {
    if (!process.env[key]) throw Error(`Missing ${key}; configure ignored .env, never command arguments`);
  }
  const dir = 'broadcast/SeedInventoryHoodi.s.sol/560048';
  const journal = `${dir}/${mode}-operator.json`;
  if (broadcast) {
    mkdirSync(dir, { recursive: true });
    if (existsSync(journal)) throw Error('Stage already attempted. Reconcile receipts; do not blindly repeat or delete its journal.');
    // Exclusive journal stays after failures: a failed process may already have mined transactions.
    writeFileSync(journal, JSON.stringify({ mode, values, status: 'STARTED', startedAt: new Date().toISOString() }, null, 2), { flag: 'wx' });
  }
  const signature = config[0];
  const command = ['script', 'script/seed/SeedInventoryHoodi.s.sol:SeedInventoryHoodi', '--rpc-url', 'hoodi', '--sig', signature,
    ...(config[2] ? [config[2]] : []), ...values, ...(broadcast ? ['--broadcast', '--slow'] : [])];
  const result = spawnSync('forge', command, { env: { ...process.env, RUST_LOG: 'off' }, encoding: 'utf8', maxBuffer: 16_000_000 });
  process.stdout.write(redact(result.stdout ?? ''));
  process.stderr.write(redact(result.stderr ?? ''));
  if (result.error || result.status !== 0) throw Error('Stage did not complete. Inspect the original receipts before any retry.');
  if (broadcast) {
    const record = JSON.parse(readFileSync(`${dir}/${signature.split('(')[0]}-latest.json`, 'utf8'));
    const transactions = record.transactions.map(t => {
      const r = record.receipts.find(r => r.transactionHash === t.hash);
      if (!r || Number(r.status) !== 1) throw Error('Not all stage transactions have successful receipts');
      return { hash: t.hash, to: t.transaction.to, block: Number(r.blockNumber) };
    });
    const ids = [];
    if (mode === 'request') {
      const topic = spawnSync('cast', ['keccak', 'WithdrawalRequested(uint256,address,address,uint256,uint256)'], { encoding: 'utf8' });
      if (topic.status !== 0) throw Error('Cannot decode confirmed withdrawal IDs');
      for (const r of record.receipts) for (const log of r.logs) {
        if (log.address.toLowerCase() === '0xfe56573178f1bcdf53f01a6e9977670dcbbd9186' && log.topics[0] === topic.stdout.trim()) {
          ids.push({ id: BigInt(log.topics[1]).toString(), owner: '0x' + log.topics[3].slice(-40), transactionHash: r.transactionHash });
        }
      }
      if (!ids.length) throw Error('No confirmed NFT IDs found; do not use simulation predictions');
    }
    writeFileSync(journal, JSON.stringify({ mode, values, status: 'MINED', transactions, confirmedNfts: ids }, null, 2));
    console.log(JSON.stringify({ journal, confirmedNfts: ids }));
  }
} catch (error) {
  console.error(redact(error.message));
  process.exitCode = 1;
}
