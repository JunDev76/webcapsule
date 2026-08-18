#!/usr/bin/env node
// Deterministic security fixture generator. All keys and artifacts are TEST ONLY.
import { sign } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { buildCapsule } from "../packages/cli/dist/build.js";
import {
  canonicalJson,
  createManifestSignaturePayload,
} from "../packages/format/dist/index.js";
import yazl from "../packages/cli/node_modules/yazl/index.js";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const fixtures = join(root, "fixtures"),
  out = join(fixtures, "capsules"),
  work = join(fixtures, ".generate");
const privateKey = await readFile(
  join(fixtures, "keys/test-only-private.pem"),
  "utf8",
);
const createdAt = "2026-08-18T10:00:02Z";
await rm(work, { recursive: true, force: true });
await mkdir(join(work, "input"), { recursive: true });
await mkdir(out, { recursive: true });
await writeFile(join(work, "input/index.html"), "hello\n");
const valid = join(out, "valid-minimal.capsule");
await rm(valid, { force: true });
await buildCapsule({
  inputDirectory: join(work, "input"),
  id: "com.example.fixture",
  version: "1.0.0",
  entry: "index.html",
  minimumRuntimeVersion: "1.0.0",
  keyId: "test-only",
  privateKey: join(fixtures, "keys/test-only-private.pem"),
  out: valid,
  createdAt,
});
const base = await readFile(valid);
const baseManifest = JSON.parse((await entryBytes(base, 0)).toString("utf8"));
const definitions = [];
function add(id, bytes, errorCode, verification = {}) {
  definitions.push({
    id,
    kind: "capsule",
    path: `capsules/${id}.capsule`,
    accepted: !errorCode,
    ...(errorCode ? { errorCode } : {}),
    verification: {
      expectedCapsuleId: "com.example.fixture",
      runtimeVersion: "1.0.0",
      trustedPublicKey: "keys/test-only-public.pem",
      ...verification,
    },
    platforms: ["typescript", "android"],
  });
  return writeFile(join(out, `${id}.capsule`), bytes);
}
await add("valid-minimal", base);

async function buildE2eFixture(id, version, files) {
  const input = join(work, id);
  await mkdir(input, { recursive: true });
  for (const [name, bytes] of Object.entries(files)) {
    const target = join(input, name);
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, bytes);
  }
  const target = join(out, `${id}.capsule`);
  await rm(target, { force: true });
  await buildCapsule({
    inputDirectory: input,
    id: "com.example.android.e2e",
    version,
    entry: "index.html",
    minimumRuntimeVersion: "1.0.0",
    keyId: "test-only",
    privateKey: join(fixtures, "keys/test-only-private.pem"),
    out: target,
    createdAt,
  });
  const bytes = await readFile(target);
  definitions.push({
    id,
    kind: "capsule",
    path: `capsules/${id}.capsule`,
    accepted: true,
    verification: {
      expectedCapsuleId: "com.example.android.e2e",
      runtimeVersion: "1.0.0",
      trustedPublicKey: "keys/test-only-public.pem",
    },
    platforms: ["typescript", "android"],
  });
  return bytes;
}

const e2eScript = (version) => `
Promise.all([
  fetch('data.json').then(r => r.json()),
  new Promise((resolve, reject) => { const image = new Image(); image.onload = resolve; image.onerror = reject; image.src = 'pixel.png'; })
]).then(([data]) => {
  globalThis.__E2E_MARKERS__ = { script: true, css: getComputedStyle(document.body).color === 'rgb(1, 2, 3)', image: true, data: data.version, version: '${version}' };
  WebCapsuleBridge.postMessage(JSON.stringify(globalThis.__WEBCAPSULE_SESSION__));
}).catch(error => { document.title = 'resource-failure:' + error; });
`;
const e2eHtml = `<!doctype html><html><head><link rel="stylesheet" href="style.css"></head><body><script src="app.js"></script></body></html>`;
const pixel = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAF/gL+XWn0AAAAAElFTkSuQmCC",
  "base64",
);
for (const [id, version] of [
  ["android-e2e-v1", "1.0.0"],
  ["android-e2e-v2", "2.0.0"],
]) {
  await buildE2eFixture(id, version, {
    "index.html": e2eHtml,
    "app.js": e2eScript(version),
    "style.css": "body { color: rgb(1, 2, 3); }\n",
    "data.json": `${JSON.stringify({ version })}\n`,
    "pixel.png": pixel,
  });
}
await buildE2eFixture("android-e2e-iframe", "3.0.0", {
  "index.html": `<!doctype html><iframe src="frame.html"></iframe>`,
  "frame.html": `<script>WebCapsuleBridge.postMessage(JSON.stringify(globalThis.__WEBCAPSULE_SESSION__))</script>`,
});

async function archive(id, manifest = baseManifest, options = {}) {
  const canonical = Buffer.from(canonicalJson(manifest));
  const manifestBytes =
    options.manifestBytes ?? Buffer.concat([canonical, Buffer.from("\n")]);
  const signature =
    options.signatureBytes ??
    Buffer.from(
      `${sign(null, createManifestSignaturePayload(manifest), privateKey).toString("base64")}\n`,
    );
  const contents = options.contents ?? [
    { name: "files/index.html", bytes: Buffer.from("hello\n") },
  ];
  const zip = new yazl.ZipFile();
  const z = {
    mtime: new Date(2026, 7, 18, 10, 0, 2),
    mode: 0o100644,
    compress: true,
    compressionLevel: 9,
    forceDosTimestamp: true,
  };
  zip.addBuffer(manifestBytes, "capsule.json", z);
  zip.addBuffer(signature, "capsule.sig", z);
  for (const e of contents) zip.addBuffer(e.bytes, e.name, z);
  zip.end({ forceZip64Format: false });
  const chunks = [];
  for await (const c of zip.outputStream) chunks.push(Buffer.from(c));
  return Buffer.concat(chunks);
}
let b = Buffer.from(base);
let sig = await entryBytes(b, 1);
sig[0] = sig[0] === 65 ? 66 : 65;
await add(
  "signature-mismatch",
  await archive("", baseManifest, { signatureBytes: sig }),
  "SIGNATURE_MISMATCH",
);
await add(
  "content-hash-mismatch",
  await archive("", {
    ...baseManifest,
    files: [{ ...baseManifest.files[0], sha256: "0".repeat(64) }],
  }),
  "HASH_MISMATCH",
);
const canon = canonicalJson(baseManifest);
await add(
  "duplicate-nested-json-key",
  await archive("", baseManifest, {
    manifestBytes: Buffer.from(
      `${canon.replace('"network":{"mode":"deny"}', '"network":{"mode":"deny","mode":"deny"}')}\n`,
    ),
  }),
  "DUPLICATE_JSON_KEY",
);
await add(
  "noncanonical-manifest",
  await archive("", baseManifest, {
    manifestBytes: Buffer.from(`${JSON.stringify(baseManifest, null, 2)}\n`),
  }),
  "INVALID_MANIFEST",
);
await add(
  "unknown-content",
  await archive("", baseManifest, {
    contents: [
      { name: "files/index.html", bytes: Buffer.from("hello\n") },
      { name: "files/unknown.xx", bytes: Buffer.from("x") },
    ],
  }),
  "INVALID_ORDER",
);
await add(
  "missing-content",
  await archive("", baseManifest, { contents: [] }),
  "INVALID_ORDER",
);
await add(
  "malformed-signature",
  await archive("", baseManifest, { signatureBytes: Buffer.from("bad\n") }),
  "INVALID_SIGNATURE",
);
await add("id-mismatch", base, "ID_MISMATCH", {
  expectedCapsuleId: "com.other.fixture",
});
await add("key-id-absent", base, "KEY_ID_MISMATCH", { trustedKeyId: "other" });
await add("runtime-incompatible", base, "RUNTIME_INCOMPATIBLE", {
  runtimeVersion: "0.9.0",
});
function mutate(id, fn, code = "INVALID_ARCHIVE_PROFILE") {
  const x = Buffer.from(base);
  const y = fn(x) ?? x;
  return add(id, y, code);
}
await mutate(
  "local-central-filename-mismatch",
  (x) => replaceName(x, 2, Buffer.from("files/Index.html"), false),
  "INVALID_ARCHIVE_PROFILE",
);
await mutate("raw-backslash", (x) =>
  replaceName(x, 2, Buffer.from("files\\index.html")),
);
await mutate("path-traversal", (x) =>
  replaceName(x, 2, Buffer.from("files/../evil.tx")),
);
await add(
  "ascii-case-collision",
  await archive("", baseManifest, {
    contents: [
      { name: "files/index.html", bytes: Buffer.from("hello\n") },
      { name: "files/Index.html", bytes: Buffer.from("x") },
    ],
  }),
  "CASE_COLLISION",
);
await add(
  "non-nfc",
  await archive("", baseManifest, {
    contents: [
      { name: "files/cafe\u0301.html", bytes: Buffer.from("hello\n") },
    ],
  }),
  "INVALID_PATH",
);
await mutate("encrypted-bit", (x) => {
  set16(x, 2, "central", 8, 0x801);
  set16(x, 2, "local", 6, 0x801);
});
await mutate("unsupported-flags", (x) => {
  set16(x, 2, "central", 8, 0x802);
  set16(x, 2, "local", 6, 0x802);
});
await mutate("archive-comment", setArchiveComment);
await mutate("entry-comment", (x) => setEntryComment(x, 2));
await mutate("central-extra", (x) => set16(x, 2, "central", 30, 1));
await mutate("local-extra", (x) => set16(x, 2, "local", 28, 1));
await mutate("wrong-mode", (x) => set32(x, 2, "central", 38, 0o100600 << 16));
await mutate("nonunix-mode", (x) => set16(x, 2, "central", 4, 20));
await mutate("symlink-mode", (x) => set32(x, 2, "central", 38, 0o120644 << 16));
await mutate("fifo-mode", (x) => set32(x, 2, "central", 38, 0o010644 << 16));
await mutate("store-method", (x) => {
  set16(x, 2, "central", 10, 0);
  set16(x, 2, "local", 8, 0);
});
await mutate("timestamp-mismatch", (x) => set16(x, 2, "local", 10, 0));
await rm(work, { recursive: true, force: true });
const contractPath = join(fixtures, "expected-results.json");
const contract = JSON.parse(await readFile(contractPath, "utf8"));
contract.fixtures = contract.fixtures
  .filter((value) => value.kind !== "capsule")
  .concat(definitions);
await writeFile(contractPath, JSON.stringify(contract, null, 2) + "\n");
function eocd(x) {
  for (let i = x.length - 22; i >= Math.max(0, x.length - 65557); i--)
    if (x.readUInt32LE(i) === 0x06054b50) return i;
  throw Error("EOCD missing");
}
function records(x) {
  const e = eocd(x),
    n = x.readUInt16LE(e + 10);
  let c = x.readUInt32LE(e + 16);
  const a = [];
  for (let i = 0; i < n; i++) {
    const nl = x.readUInt16LE(c + 28),
      xl = x.readUInt16LE(c + 30),
      cl = x.readUInt16LE(c + 32),
      l = x.readUInt32LE(c + 42),
      ln = x.readUInt16LE(l + 26),
      lx = x.readUInt16LE(l + 28);
    a.push({
      central: c,
      local: l,
      centralName: c + 46,
      localName: l + 30,
      name: Buffer.from(x.subarray(c + 46, c + 46 + nl)),
      data: l + 30 + ln + lx,
      compressed: x.readUInt32LE(c + 20),
    });
    c += 46 + nl + xl + cl;
  }
  return a;
}
function replaceName(x, i, n, local = true) {
  const r = records(x)[i];
  if (n.length !== r.name.length)
    throw Error(`name length ${n.length} != ${r.name.length}`);
  n.copy(x, r.centralName);
  if (local) n.copy(x, r.localName);
}
function set16(x, i, a, o, v) {
  const r = records(x)[i];
  x.writeUInt16LE(v, r[a] + o);
}
function set32(x, i, a, o, v) {
  const r = records(x)[i];
  x.writeUInt32LE(v >>> 0, r[a] + o);
}
function setArchiveComment(x) {
  const e = eocd(x),
    y = Buffer.concat([x, Buffer.from("x")]);
  y.writeUInt16LE(1, e + 20);
  return y;
}
function setEntryComment(x, i) {
  const r = records(x)[i],
    nl = x.readUInt16LE(r.central + 28),
    xl = x.readUInt16LE(r.central + 30),
    at = r.central + 46 + nl + xl,
    y = Buffer.concat([x.subarray(0, at), Buffer.from("x"), x.subarray(at)]);
  y.writeUInt16LE(1, r.central + 32);
  const e = eocd(y);
  y.writeUInt32LE(y.readUInt32LE(e + 12) + 1, e + 12);
  return y;
}
async function entryBytes(x, index) {
  const r = records(x)[index];
  const z = await import("node:zlib");
  return z.inflateRawSync(x.subarray(r.data, r.data + r.compressed));
}
