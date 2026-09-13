/** Deploy only the finite issuer-history manifest, never the live trading subgraph. */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
const root = fileURLToPath(new URL('../', import.meta.url));
const key = process.env.GRAPH_DEPLOY_KEY, slug = process.env.HISTORY_GRAPH_SLUG;
const [series = 'ethereum-lido-2025-03', version] = process.argv.slice(2);
if (!key || !slug || !/^[a-z0-9-]+$/.test(slug) || slug === 'harbor' || !version || !/^\d+\.\d+\.\d+(?:-[a-z0-9.-]+)?$/.test(version)) throw Error('Set GRAPH_DEPLOY_KEY and a separate HISTORY_GRAPH_SLUG; pass SERIES VERSION');
const configs = JSON.parse(readFileSync(root + 'history/networks.json', 'utf8'));
const config = configs.find(c => c.id === series);
if (!config || config.environment === 'BUILD_FIXTURE') throw Error('Refusing a fixture or unknown series');
const built = spawnSync(process.execPath, [root + 'scripts/build-history-subgraph.mjs', series], { stdio: 'inherit' });
if (built.status !== 0) process.exit(built.status ?? 1);
process.chdir(root + 'history/.build/' + series);
const manifest = JSON.parse(readFileSync('subgraph.yaml', 'utf8'));
if (manifest.dataSources.length !== 1 || manifest.dataSources[0].source.address !== config.issuer || manifest.dataSources[0].source.endBlock !== config.endBlock) throw Error('History manifest mismatch');
process.env.DEBUG = '';
for (const stream of [process.stdout,process.stderr]) {
 const write = stream.write.bind(stream);
 stream.write = (chunk,...args) => { let text = String(chunk); for (const secret of [key,process.env.GRAPH_API_KEY]) if (secret) text = text.split(secret).join('[REDACTED]'); return write(text,...args); };
}
try {
 const { default: Deploy } = await import('../node_modules/@graphprotocol/graph-cli/dist/commands/deploy.js');
 await Deploy.run([slug,'--node','https://api.studio.thegraph.com/deploy/','--version-label',version,'--deploy-key',key]);
} catch { console.error('Historical Studio deployment failed; inspect sanitized output.'); process.exitCode = 1; }
