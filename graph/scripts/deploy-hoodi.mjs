import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const key = process.env.GRAPH_DEPLOY_KEY;
const slug = process.env.GRAPH_SUBGRAPH_SLUG;
const version = process.argv[2];
if (!key || !slug || !/^[a-z0-9-]+$/.test(slug) || !version || !/^\d+\.\d+\.\d+(?:-[a-z0-9.-]+)?$/.test(version)) {
  throw Error('Configure GRAPH_DEPLOY_KEY/GRAPH_SUBGRAPH_SLUG and supply a version label');
}
const root = fileURLToPath(new URL('../', import.meta.url));
// Rebuild reviewed Hoodi inputs; never publish the default synthetic fixture.
const built = spawnSync(process.execPath, [root + 'scripts/build-subgraph.mjs', '--deployment', 'hoodi'], { stdio: 'inherit' });
if (built.status !== 0) process.exit(built.status ?? 1);
process.chdir(root + 'subgraph');
const manifest = JSON.parse(readFileSync('subgraph.yaml', 'utf8'));
if (manifest.dataSources.some(s => s.network !== 'hoodi' || s.context.environment.data !== 'TESTNET' || s.source.startBlock === 0)) {
  throw Error('Refusing a fixture deployment');
}
// Invoke the pinned CLI in-process: deploy key stays out of OS argv and auth files.
// Suppress debug logging and redact the two credential values from CLI output.
process.env.DEBUG = '';
for (const stream of [process.stdout, process.stderr]) {
  const write = stream.write.bind(stream);
  stream.write = (chunk, ...args) => {
    let text = String(chunk);
    for (const secret of [key, process.env.GRAPH_API_KEY]) if (secret) text = text.split(secret).join('[REDACTED]');
    return write(text, ...args);
  };
}
try {
  const { default: Deploy } = await import('../node_modules/@graphprotocol/graph-cli/dist/commands/deploy.js');
  await Deploy.run([slug, '--node', 'https://api.studio.thegraph.com/deploy/', '--version-label', version, '--deploy-key', key]);
} catch {
  console.error('Studio deployment failed; inspect the sanitized CLI output before retrying');
  process.exitCode = 1;
}
