import { createHash } from "node:crypto";
import { mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const keys = resolve(root, "examples/.demo-keys");
const cli = resolve(root, "packages/cli/dist/index.js");
const out = resolve(root, "examples/demo-hosting");

const CAPSULE_ID = "dev.webcapsule.demo";
const BASE_URL = "https://jundev76.github.io/webcapsule-demo-tmp/releases";

await mkdir(out, { recursive: true });

const releases = [
  ["updated-v2", "2.0.0", "guide-2.0.0.capsule", "stable-v2.json"],
  ["broken-v3", "3.0.0", "guide-3.0.0.capsule", "stable-v3.json"],
];

for (const [source, version, file, _index] of releases) {
  const capsulePath = resolve(out, file);
  await rm(capsulePath, { force: true });
  run("node", [
    cli,
    "build",
    resolve(root, "examples/capsule-content", source),
    "--id",
    CAPSULE_ID,
    "--version",
    version,
    "--entry",
    "index.html",
    "--minimum-runtime-version",
    "1.0.0",
    "--key-id",
    "demo",
    "--private-key",
    resolve(keys, "private.pem"),
    "--created-at",
    "2026-08-26T00:00:00Z",
    "--out",
    capsulePath,
  ]);

  const bytes = await readFile(capsulePath);
  const sha256 = createHash("sha256").update(bytes).digest("hex");
  const size = (await stat(capsulePath)).size;
  const descriptor = {
    version,
    url: `${BASE_URL}/${file}`,
    sha256,
    size,
    minimumRuntimeVersion: "1.0.0",
  };
  const descriptorPath = resolve(out, `${version}.json`);
  await writeFile(descriptorPath, JSON.stringify(descriptor, null, 2) + "\n");

  const indexPath = resolve(out, _index);
  await rm(indexPath, { force: true });
  run("node", [
    cli,
    "index",
    "--id",
    CAPSULE_ID,
    "--channel",
    "stable",
    "--key-id",
    "demo",
    "--private-key",
    resolve(keys, "private.pem"),
    "--release",
    descriptorPath,
    "--out",
    indexPath,
  ]);
}

console.log(`\nHosting artifacts written to ${out}`);
console.log("Upload these files to GitHub Pages (releases/ directory):");
for (const [, , file, index] of releases) {
  console.log(`  ${file}`);
  console.log(`  ${index}`);
}

function run(command, args) {
  const result = spawnSync(command, args, { stdio: "inherit" });
  if (result.status !== 0) process.exit(result.status ?? 1);
}
