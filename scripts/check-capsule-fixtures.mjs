#!/usr/bin/env node
import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
const root = resolve(import.meta.dirname, "..");
async function snapshot() {
  const targets = [
    ["capsules", ".capsule"],
    ["update-index-v1", ".json"],
  ];
  const result = new Map();
  for (const [directory, extension] of targets) {
    const files = (await readdir(resolve(root, "fixtures", directory)))
      .filter((value) => value.endsWith(extension))
      .sort();
    for (const file of files)
      result.set(
        `${directory}/${file}`,
        createHash("sha256")
          .update(await readFile(resolve(root, "fixtures", directory, file)))
          .digest("hex"),
      );
  }
  return result;
}
const contractPath = resolve(root, "fixtures/expected-results.json");
const contractBefore = await readFile(contractPath);
const before = await snapshot();
const run = spawnSync(
  process.execPath,
  [resolve(root, "scripts/generate-capsule-fixtures.mjs")],
  { cwd: root, stdio: "inherit" },
);
if (run.status !== 0) process.exit(run.status ?? 1);
const after = await snapshot();
await (
  await import("node:fs/promises")
).writeFile(contractPath, contractBefore);
if (JSON.stringify([...before]) !== JSON.stringify([...after])) {
  console.error("Generated fixtures are not byte-identical");
  process.exit(1);
}
