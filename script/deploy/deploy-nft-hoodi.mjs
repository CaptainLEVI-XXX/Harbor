import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';

// Load ignored .env with node --env-file. Never pass secrets in argv or print them.
const signatures = {
  run: ['run()', 0],
  setup: ['setup(address)', 1],
  seed: ['seed(address,address,uint256,uint256)', 4],
  verify: ['verify(address,address,address)', 3],
  'verify-nft': ['verifyNft(address,address,uint256,bool)', 4],
};
function redact(value) {
  for (const [key, secret] of Object.entries(process.env)) {
    if (!secret || !/PRIVATE_KEY|RPC_URL|^LP_[AB]$/.test(key)) continue;
    const variants = /^0x[0-9a-fA-F]{64}$/.test(secret) ? [secret, secret.slice(2), BigInt(secret).toString()] : [secret];
    for (const item of variants) value = value.split(item).join('[REDACTED]');
  }
  return value;
}
try {
  const [mode, ...input] = process.argv.slice(2);
  const broadcast = input.at(-1) === '--broadcast';
  const values = broadcast ? input.slice(0, -1) : input;
  const selected = signatures[mode];
  if (!selected || values.length !== selected[1] || !process.env.HOODI_RPC_URL) {
    throw Error('Use run | setup BOOK | seed BOOK PERIPHERY ETH_USD_6 OBSERVED_AT | verify BOOK PERIPHERY TRADER | verify-nft BOOK TRADER ID true/false. Optional --broadcast only for write stages.');
  }
  if (broadcast && mode.startsWith('verify')) throw Error('Verification is read-only');
  if (!process.env.HOODI_PRIVATE_KEY || (mode === 'seed' && (!process.env.LP_A || !process.env.LP_B))) {
    throw Error('Missing required signer environment variables');
  }
  const method = selected[0].split('(')[0];
  const record = `broadcast/DeployHarborNftHoodi.s.sol/560048/${method}-latest.json`;
  if (broadcast && existsSync(record)) {
    const previous = JSON.parse(readFileSync(record, 'utf8'));
    if (previous.transactions?.some(tx => tx.hash) || previous.pending?.length) {
      throw Error('An existing broadcast record needs receipt reconciliation. Do not repeat deployments/funding; inspect and resume the original record.');
    }
  }
  const args = ['script', 'script/deploy/DeployHarborNftHoodi.s.sol:DeployHarborNftHoodi', '--rpc-url', 'hoodi', '--sig', selected[0], ...values];
  if (broadcast) args.push('--broadcast', '--slow');
  const result = spawnSync('forge', args, {
    env: { ...process.env, RUST_LOG: 'off' }, encoding: 'utf8', maxBuffer: 16_000_000,
  });
  process.stdout.write(redact(result.stdout ?? ''));
  process.stderr.write(redact(result.stderr ?? ''));
  if (result.error) throw Error(result.error.message);
  process.exitCode = result.status ?? 1;
} catch (error) {
  console.error(redact(error.message)); process.exitCode = 1;
}
