import {mkdir, readFile, rm, writeFile} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {resolve} from 'node:path';

const root = resolve(import.meta.dirname, '..');
const keys = resolve(root, 'examples/.demo-keys');
const resources = resolve(root, 'examples/rn-demo/ios/WebCapsuleDemo/WebCapsule');
const cli = resolve(root, 'packages/cli/dist/index.js');

await mkdir(keys, {recursive: true});
await mkdir(resources, {recursive: true});
try {
  await readFile(resolve(keys, 'private.pem'));
} catch {
  run('node', [cli, 'keygen', '--out', keys]);
}

for (const [source, version, output] of [
  ['bundled-v1', '1.0.0', 'bundled-v1.capsule'],
  ['updated-v2', '2.0.0', 'updated-v2.capsule'],
  ['broken-v3', '3.0.0', 'broken-v3.capsule'],
]) {
  const outputPath = resolve(resources, output);
  await rm(outputPath, {force: true});
  run('node', [cli, 'build', resolve(root, 'examples/capsule-content', source), '--id', 'dev.webcapsule.demo', '--version', version, '--entry', 'index.html', '--minimum-runtime-version', '1.0.0', '--key-id', 'demo', '--private-key', resolve(keys, 'private.pem'), '--created-at', '2026-08-26T00:00:00Z', '--out', outputPath]);
}

const publicKey = await readFile(resolve(keys, 'public.pem'), 'utf8');
await writeFile(resolve(root, 'examples/rn-demo/demo-config.ts'), `export const DEMO_PUBLIC_KEY = ${JSON.stringify(publicKey)};\n`);

function run(command, args) {
  const result = spawnSync(command, args, {stdio: 'inherit'});
  if (result.status !== 0) process.exit(result.status ?? 1);
}
