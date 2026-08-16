import { generateKeyPairSync, sign } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  WebCapsuleErrorCode,
  canonicalJson,
  createManifestSignaturePayload,
  parseCapsuleManifest,
  type CapsuleManifest,
} from "@webcapsule/format";
import { afterEach, describe, expect, it } from "vitest";
import yauzl, { type Entry } from "yauzl";
import yazl from "yazl";

import { inspectCapsule, verifyCapsule } from "./archive.js";
import { buildCapsule } from "./build.js";
import {
  mutateFile,
  records,
  replaceName,
  set16,
  set32,
  setArchiveComment,
  setEntryComment,
} from "./zip-mutation.test-helper.js";

const roots: string[] = [];
async function artifact() {
  const root = await mkdtemp(join(tmpdir(), "webcapsule-archive-"));
  roots.push(root);
  const input = join(root, "input");
  await mkdir(input);
  await writeFile(join(input, "index.html"), "hello");
  const pair = generateKeyPairSync("ed25519", {
    privateKeyEncoding: { format: "pem", type: "pkcs8" },
    publicKeyEncoding: { format: "pem", type: "spki" },
  });
  const privateKey = join(root, "private.pem");
  await writeFile(privateKey, pair.privateKey);
  const capsule = join(root, "app.capsule");
  await buildCapsule({
    inputDirectory: input,
    id: "com.example.app",
    version: "1.0.0",
    entry: "index.html",
    minimumRuntimeVersion: "1.0.0",
    keyId: "release",
    privateKey,
    out: capsule,
    createdAt: "2026-08-16T10:00:02Z",
  });
  return {
    capsule,
    publicKey: pair.publicKey,
    privateKey: pair.privateKey,
    manifest: parseCapsuleManifest(
      JSON.parse(
        (await readZipEntry(capsule, "capsule.json")).toString("utf8"),
      ),
    ),
  };
}

async function readZipEntry(path: string, name: string): Promise<Buffer> {
  const zip = await new Promise<yauzl.ZipFile>((resolve, reject) =>
    yauzl.open(path, { lazyEntries: true }, (error, value) =>
      error || !value
        ? reject(error ?? new Error("ZIP open failed"))
        : resolve(value),
    ),
  );
  return new Promise((resolve, reject) => {
    zip.on("entry", (entry: Entry) => {
      if (entry.fileName !== name) return zip.readEntry();
      zip.openReadStream(entry, (error, stream) => {
        if (error || !stream)
          return reject(error ?? new Error("stream missing"));
        const chunks: Buffer[] = [];
        stream.on("data", (chunk: Buffer) => chunks.push(Buffer.from(chunk)));
        stream.on("error", reject);
        stream.on("end", () => {
          zip.close();
          resolve(Buffer.concat(chunks));
        });
      });
    });
    zip.on("error", reject);
    zip.on("end", () => reject(new Error(`entry missing: ${name}`)));
    zip.readEntry();
  });
}

interface TestEntry {
  readonly name: string;
  readonly bytes: Buffer;
}

async function writeTestArchive(
  path: string,
  manifest: CapsuleManifest,
  privateKey: string,
  options: {
    readonly manifestBytes?: Buffer;
    readonly signatureBytes?: Buffer;
    readonly entries?: readonly TestEntry[];
    readonly extraEntries?: readonly TestEntry[];
  } = {},
): Promise<void> {
  const manifestBytes =
    options.manifestBytes ?? Buffer.from(`${canonicalJson(manifest)}\n`);
  const signatureBytes =
    options.signatureBytes ??
    Buffer.from(
      `${sign(null, createManifestSignaturePayload(manifest), privateKey).toString("base64")}\n`,
      "ascii",
    );
  const entries =
    options.entries ??
    manifest.files.map((file) => ({
      name: `files/${file.path}`,
      bytes: Buffer.from(file.path === "index.html" ? "hello" : ""),
    }));
  const zip = new yazl.ZipFile();
  const entryOptions = {
    mtime: new Date(2026, 7, 16, 10, 0, 2),
    mode: 0o100644,
    compress: true,
    compressionLevel: 9,
    forceDosTimestamp: true,
  };
  zip.addBuffer(manifestBytes, "capsule.json", entryOptions);
  zip.addBuffer(signatureBytes, "capsule.sig", entryOptions);
  for (const entry of [...entries, ...(options.extraEntries ?? [])])
    zip.addBuffer(entry.bytes, entry.name, entryOptions);
  zip.end({ forceZip64Format: false });
  const chunks: Buffer[] = [];
  for await (const chunk of zip.outputStream) chunks.push(Buffer.from(chunk));
  await writeFile(path, Buffer.concat(chunks));
}
afterEach(async () =>
  Promise.all(
    roots.splice(0).map((root) => rm(root, { recursive: true, force: true })),
  ),
);

describe("capsule archive verification", () => {
  it("verifies every content byte and compatibility constraints", async () => {
    const value = await artifact();
    await expect(
      verifyCapsule(value.capsule, {
        publicKey: value.publicKey,
        expectedId: "com.example.app",
        expectedKeyId: "release",
        runtimeVersion: "1.0.0",
      }),
    ).resolves.toMatchObject({
      capsuleId: "com.example.app",
      declaredBytes: 5,
    });
    await expect(
      verifyCapsule(value.capsule, {
        publicKey: value.publicKey,
        runtimeVersion: "0.9.0",
      }),
    ).rejects.toMatchObject({ code: "RUNTIME_INCOMPATIBLE" });
  });
  it("rejects the wrong Ed25519 public key", async () => {
    const value = await artifact();
    const wrong = generateKeyPairSync("ed25519")
      .publicKey.export({ format: "pem", type: "spki" })
      .toString();
    await expect(
      verifyCapsule(value.capsule, { publicKey: wrong }),
    ).rejects.toMatchObject({ code: "SIGNATURE_MISMATCH" });
  });
  it("reports a structurally valid one-byte signature mutation", async () => {
    const value = await artifact();
    const signature = await readZipEntry(value.capsule, "capsule.sig");
    signature[0] = signature[0] === 65 ? 66 : 65;
    await writeTestArchive(value.capsule, value.manifest, value.privateKey, {
      signatureBytes: signature,
    });
    await expect(
      verifyCapsule(value.capsule, { publicKey: value.publicKey }),
    ).rejects.toMatchObject({ code: "SIGNATURE_MISMATCH" });
  });

  it("reports a signed manifest with an incorrect content hash", async () => {
    const value = await artifact();
    const manifest = parseCapsuleManifest({
      ...value.manifest,
      files: [{ ...value.manifest.files[0]!, sha256: "0".repeat(64) }],
    });
    await writeTestArchive(value.capsule, manifest, value.privateKey);
    await expect(
      verifyCapsule(value.capsule, { publicKey: value.publicKey }),
    ).rejects.toMatchObject({ code: "HASH_MISMATCH" });
  });

  it("rejects signed semantic-equivalent noncanonical manifest bytes", async () => {
    const value = await artifact();
    const noncanonical = Buffer.from(
      `${JSON.stringify(value.manifest, null, 2)}\n`,
      "utf8",
    );
    await writeTestArchive(value.capsule, value.manifest, value.privateKey, {
      manifestBytes: noncanonical,
    });
    await expect(inspectCapsule(value.capsule)).rejects.toMatchObject({
      code: "INVALID_ARCHIVE_PROFILE",
    });
  });

  it("rejects a signed duplicate-key manifest at JSON parsing", async () => {
    const value = await artifact();
    const canonical = canonicalJson(value.manifest);
    const duplicate = Buffer.from(
      `${canonical.replace("{", '{"formatVersion":1,')}\n`,
      "utf8",
    );
    await writeTestArchive(value.capsule, value.manifest, value.privateKey, {
      manifestBytes: duplicate,
    });
    await expect(inspectCapsule(value.capsule)).rejects.toMatchObject({
      code: WebCapsuleErrorCode.DuplicateJsonKey,
    });
  });

  it("rejects unknown and missing content entries independently", async () => {
    const value = await artifact();
    await writeTestArchive(value.capsule, value.manifest, value.privateKey, {
      extraEntries: [{ name: "files/unknown.txt", bytes: Buffer.from("x") }],
    });
    await expect(inspectCapsule(value.capsule)).rejects.toMatchObject({
      code: "INVALID_ARCHIVE_PROFILE",
    });
    await writeTestArchive(value.capsule, value.manifest, value.privateKey, {
      entries: [],
    });
    await expect(inspectCapsule(value.capsule)).rejects.toMatchObject({
      code: "INVALID_ARCHIVE_PROFILE",
    });
  });

  it("rejects logical duplicate, ASCII case, and non-NFC paths", async () => {
    const value = await artifact();
    const cases: readonly {
      readonly entries: readonly TestEntry[];
      readonly code: WebCapsuleErrorCode;
    }[] = [
      {
        entries: [
          { name: "files/index.html", bytes: Buffer.from("hello") },
          { name: "files/index.html", bytes: Buffer.from("hello") },
        ],
        code: WebCapsuleErrorCode.DuplicatePath,
      },
      {
        entries: [
          { name: "files/index.html", bytes: Buffer.from("hello") },
          { name: "files/Index.html", bytes: Buffer.from("hello") },
        ],
        code: WebCapsuleErrorCode.CaseCollision,
      },
      {
        entries: [
          { name: "files/cafe\u0301.html", bytes: Buffer.from("hello") },
        ],
        code: WebCapsuleErrorCode.InvalidPath,
      },
    ];
    for (const testCase of cases) {
      await writeTestArchive(value.capsule, value.manifest, value.privateKey, {
        entries: testCase.entries,
      });
      await expect(inspectCapsule(value.capsule)).rejects.toMatchObject({
        code: testCase.code,
      });
    }
  });

  it("rejects entry enumeration beyond the declared profile limit", async () => {
    const value = await artifact();
    const extras = Array.from({ length: 10_001 }, (_, index) => ({
      name: `files/x${index.toString().padStart(5, "0")}`,
      bytes: Buffer.alloc(0),
    }));
    await writeTestArchive(value.capsule, value.manifest, value.privateKey, {
      entries: [],
      extraEntries: extras,
    });
    await expect(inspectCapsule(value.capsule)).rejects.toMatchObject({
      code: "LIMIT_EXCEEDED",
    });
  }, 20_000);

  it("rejects a private PEM passed as the public key", async () => {
    const value = await artifact();
    const privatePem = generateKeyPairSync("ed25519", {
      privateKeyEncoding: { format: "pem", type: "pkcs8" },
      publicKeyEncoding: { format: "pem", type: "spki" },
    }).privateKey;
    await expect(
      verifyCapsule(value.capsule, { publicKey: privatePem }),
    ).rejects.toMatchObject({ code: "INVALID_PUBLIC_KEY" });
  });
  it("inspects only bounded structural metadata and marks no trust", async () => {
    const value = await artifact();
    const result = await inspectCapsule(value.capsule);
    expect(result).toEqual({
      trust: "unverified",
      capsuleId: "com.example.app",
      version: "1.0.0",
      keyId: "release",
      entry: "index.html",
      createdAt: "2026-08-16T10:00:02Z",
      fileCount: 1,
      declaredBytes: 5,
    });
    expect(result).not.toHaveProperty("verified");
  });
  it("rejects malformed archives", async () => {
    const value = await artifact();
    await writeFile(
      value.capsule,
      (await readFile(value.capsule)).subarray(0, 20),
    );
    await expect(inspectCapsule(value.capsule)).rejects.toMatchObject({
      code: "INVALID_ARCHIVE_PROFILE",
    });
  });

  it.each([
    [
      "backslash name",
      (bytes: Buffer) =>
        replaceName(bytes, 2, Buffer.from("files\\index.html")),
    ],
    [
      "invalid UTF-8 name",
      (bytes: Buffer) => {
        const name = records(bytes)[2]!.name;
        const bad = Buffer.from(name);
        bad[6] = 0xff;
        replaceName(bytes, 2, bad);
      },
    ],
    [
      "local/central name mismatch",
      (bytes: Buffer) =>
        replaceName(bytes, 2, Buffer.from("files/Index.html"), false),
    ],
    [
      "encrypted flag",
      (bytes: Buffer) => {
        set16(bytes, 2, "central", 8, 0x801);
        set16(bytes, 2, "local", 6, 0x801);
      },
    ],
    [
      "unsupported flag",
      (bytes: Buffer) => {
        set16(bytes, 2, "central", 8, 0x802);
        set16(bytes, 2, "local", 6, 0x802);
      },
    ],
    [
      "directory name",
      (bytes: Buffer) => replaceName(bytes, 2, Buffer.from("files/index.htm/")),
    ],
    [
      "Unix symlink mode",
      (bytes: Buffer) => set32(bytes, 2, "central", 38, 0o120644 << 16),
    ],
    [
      "Unix FIFO mode",
      (bytes: Buffer) => set32(bytes, 2, "central", 38, 0o010644 << 16),
    ],
    ["non-Unix madeBy", (bytes: Buffer) => set16(bytes, 2, "central", 4, 20)],
    [
      "wrong mode",
      (bytes: Buffer) => set32(bytes, 2, "central", 38, 0o100600 << 16),
    ],
    [
      "STORE method",
      (bytes: Buffer) => {
        set16(bytes, 2, "central", 10, 0);
        set16(bytes, 2, "local", 8, 0);
      },
    ],
    [
      "central/local timestamp mismatch",
      (bytes: Buffer) => set16(bytes, 2, "local", 10, 0),
    ],
    [
      "manifest timestamp mismatch",
      (bytes: Buffer) => {
        set16(bytes, 2, "central", 12, 0);
        set16(bytes, 2, "local", 10, 0);
      },
    ],
    [
      "duplicate metadata entry",
      (bytes: Buffer) => replaceName(bytes, 2, Buffer.from("capsule.jsonxxxx")),
    ],
    [
      "path traversal",
      (bytes: Buffer) => replaceName(bytes, 2, Buffer.from("files/../evil.tx")),
    ],
    [
      "case collision/order mismatch",
      (bytes: Buffer) => replaceName(bytes, 2, Buffer.from("files/Index.html")),
    ],
  ] as const)("rejects raw ZIP profile mutation: %s", async (_name, mutate) => {
    const value = await artifact();
    await mutateFile(value.capsule, mutate);
    await expect(inspectCapsule(value.capsule)).rejects.toMatchObject({
      code: "INVALID_ARCHIVE_PROFILE",
    });
  });

  it("rejects archive and entry comments", async () => {
    for (const mutate of [
      setArchiveComment,
      (bytes: Buffer) => setEntryComment(bytes, 2),
    ]) {
      const value = await artifact();
      await mutateFile(value.capsule, mutate);
      await expect(inspectCapsule(value.capsule)).rejects.toMatchObject({
        code: "INVALID_ARCHIVE_PROFILE",
      });
    }
  });

  it("rejects nonzero local extra length", async () => {
    const value = await artifact();
    await mutateFile(value.capsule, (bytes) => set16(bytes, 2, "local", 28, 1));
    await expect(inspectCapsule(value.capsule)).rejects.toMatchObject({
      code: "INVALID_ARCHIVE_PROFILE",
    });
  });

  it("rejects corrupted content streams in inspect and verify", async () => {
    const value = await artifact();
    await mutateFile(value.capsule, (bytes) => {
      const content = records(bytes)[2]!;
      const offset =
        content.compressedData + Math.floor(content.compressedSize / 2);
      bytes[offset] = bytes[offset]! ^ 0xff;
    });
    await expect(inspectCapsule(value.capsule)).rejects.toMatchObject({
      code: "INVALID_ARCHIVE_PROFILE",
    });
    await expect(
      verifyCapsule(value.capsule, { publicKey: value.publicKey }),
    ).rejects.toMatchObject({ code: "INVALID_ARCHIVE_PROFILE" });
  });
});
