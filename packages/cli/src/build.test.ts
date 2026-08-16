import { execFile } from "node:child_process";
import { createHash, generateKeyPairSync, verify } from "node:crypto";
import {
  mkdtemp,
  mkdir,
  readFile,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";

import {
  createManifestSignaturePayload,
  parseCapsuleManifestJson,
} from "@webcapsule/format";
import yauzl, { type Entry } from "yauzl";
import { afterEach, describe, expect, it } from "vitest";

import { buildCapsule } from "./build.js";
import { WebCapsuleCliErrorCode } from "./errors.js";

const roots: string[] = [];
const execute = promisify(execFile);
async function fixture(): Promise<{
  root: string;
  input: string;
  key: string;
}> {
  const root = await mkdtemp(join(tmpdir(), "webcapsule-build-"));
  roots.push(root);
  const input = join(root, "input");
  await mkdir(join(input, "nested"), { recursive: true });
  await writeFile(join(input, "index.html"), "<h1>Hello</h1>");
  await writeFile(join(input, ".hidden"), "hidden");
  await writeFile(join(input, "nested", "data.unknownext"), "data");
  const pair = generateKeyPairSync("ed25519", {
    privateKeyEncoding: { format: "pem", type: "pkcs8" },
    publicKeyEncoding: { format: "pem", type: "spki" },
  });
  const key = join(root, "private.pem");
  await writeFile(key, pair.privateKey);
  await writeFile(join(root, "public.pem"), pair.publicKey);
  return { root, input, key };
}
afterEach(async () => {
  await Promise.all(
    roots.splice(0).map((root) => rm(root, { recursive: true, force: true })),
  );
});

function options(
  value: { root: string; input: string; key: string },
  out = "result.capsule",
) {
  return {
    inputDirectory: value.input,
    id: "com.example.app",
    version: "1.0.0",
    entry: "index.html",
    minimumRuntimeVersion: "1.0.0",
    keyId: "release",
    privateKey: value.key,
    out: join(value.root, out),
    createdAt: "2026-08-16T10:00:02Z",
  } as const;
}

async function entries(
  path: string,
): Promise<
  Array<{ name: string; bytes: Buffer; method: number; extras: number }>
> {
  return new Promise((resolve, reject) =>
    yauzl.open(path, { lazyEntries: true }, (error, zip) => {
      if (error || !zip) {
        reject(error instanceof Error ? error : new Error("ZIP open failed"));
        return;
      }
      const result: Array<{
        name: string;
        bytes: Buffer;
        method: number;
        extras: number;
      }> = [];
      zip.on("error", reject);
      zip.on("end", () => resolve(result));
      zip.on("entry", (entry: Entry) => {
        zip.openReadStream(entry, (streamError, stream) => {
          if (streamError) {
            reject(streamError);
            return;
          }
          const chunks: Buffer[] = [];
          stream.on("data", (chunk: Buffer) => chunks.push(chunk));
          stream.on("end", () => {
            result.push({
              name: entry.fileName,
              bytes: Buffer.concat(chunks),
              method: entry.compressionMethod,
              extras: entry.extraFields.length,
            });
            zip.readEntry();
          });
          stream.on("error", reject);
        });
      });
      zip.readEntry();
    }),
  );
}

describe("buildCapsule", () => {
  it("builds deterministic ordered bytes with a valid manifest signature", async () => {
    const value = await fixture();
    const first = options(value, "a.capsule");
    const second = options(value, "b.capsule");
    await buildCapsule(first);
    await buildCapsule(second);
    expect(await readFile(first.out)).toEqual(await readFile(second.out));
    const archive = await entries(first.out);
    expect(archive.map((item) => item.name)).toEqual([
      "capsule.json",
      "capsule.sig",
      "files/.hidden",
      "files/index.html",
      "files/nested/data.unknownext",
    ]);
    expect(
      archive.every((item) => item.method === 8 && item.extras === 0),
    ).toBe(true);
    const manifestText = archive[0]!.bytes.toString("utf8");
    expect(manifestText.endsWith("\n")).toBe(true);
    const manifest = parseCapsuleManifestJson(manifestText);
    expect(
      manifest.files.find((file) => file.path.endsWith("unknownext"))
        ?.mediaType,
    ).toBe("application/octet-stream");
    const publicKey = await readFile(join(value.root, "public.pem"));
    expect(
      verify(
        null,
        createManifestSignaturePayload(manifest),
        publicKey,
        Buffer.from(archive[1]!.bytes.toString("ascii").trim(), "base64"),
      ),
    ).toBe(true);
  });

  it("rejects missing entry, output inside input, existing output, and invalid timestamps", async () => {
    const value = await fixture();
    await expect(
      buildCapsule({ ...options(value), entry: "missing.html" }),
    ).rejects.toMatchObject({ code: "INVALID_MANIFEST" });
    await expect(
      buildCapsule({
        ...options(value),
        out: join(value.input, "bad.capsule"),
      }),
    ).rejects.toMatchObject({ code: WebCapsuleCliErrorCode.InvalidArgument });
    const existing = join(value.root, "existing.capsule");
    await writeFile(existing, "keep");
    await expect(
      buildCapsule({ ...options(value), out: existing }),
    ).rejects.toMatchObject({ code: WebCapsuleCliErrorCode.OutputExists });
    expect(await readFile(existing, "utf8")).toBe("keep");
    const base = options(value);
    const withoutTimestamp = {
      inputDirectory: base.inputDirectory,
      id: base.id,
      version: base.version,
      entry: base.entry,
      minimumRuntimeVersion: base.minimumRuntimeVersion,
      keyId: base.keyId,
      privateKey: base.privateKey,
      out: base.out,
    };
    await expect(buildCapsule(withoutTimestamp)).rejects.toMatchObject({
      code: WebCapsuleCliErrorCode.InvalidTimestamp,
    });
    await expect(
      buildCapsule({ ...base, createdAt: "2026-08-16T10:00:03Z" }),
    ).rejects.toMatchObject({ code: WebCapsuleCliErrorCode.InvalidTimestamp });
    await expect(
      buildCapsule({ ...withoutTimestamp, sourceDateEpoch: "1" }),
    ).rejects.toMatchObject({ code: WebCapsuleCliErrorCode.InvalidTimestamp });
  });

  it("rejects malformed and non-Ed25519 keys", async () => {
    const value = await fixture();
    await writeFile(value.key, "bad");
    await expect(buildCapsule(options(value))).rejects.toMatchObject({
      code: WebCapsuleCliErrorCode.InvalidPrivateKey,
    });
    const rsa = generateKeyPairSync("rsa", {
      modulusLength: 2048,
      privateKeyEncoding: { format: "pem", type: "pkcs8" },
      publicKeyEncoding: { format: "pem", type: "spki" },
    });
    await writeFile(value.key, rsa.privateKey);
    await expect(buildCapsule(options(value))).rejects.toMatchObject({
      code: WebCapsuleCliErrorCode.InvalidPrivateKey,
    });
  });

  it("produces identical bytes in different process time zones", async () => {
    const value = await fixture();
    await execute("pnpm", ["build"], {
      cwd: resolve(import.meta.dirname, ".."),
    });
    const script = `import { buildCapsule } from ${JSON.stringify(resolve(import.meta.dirname, "../dist/build.js"))}; await buildCapsule(JSON.parse(process.argv[1]));`;
    const first = options(value, "utc.capsule");
    const second = options(value, "new-york.capsule");
    await execute(process.execPath, ["--eval", script, JSON.stringify(first)], {
      env: { ...process.env, TZ: "UTC" },
    });
    await execute(
      process.execPath,
      ["--eval", script, JSON.stringify(second)],
      { env: { ...process.env, TZ: "America/New_York" } },
    );
    const hashes = await Promise.all(
      [first.out, second.out].map(async (path) =>
        createHash("sha256")
          .update(await readFile(path))
          .digest("hex"),
      ),
    );
    expect(hashes[0]).toBe(hashes[1]);
  });

  it("reports missing private key and unwritable output parent with stable codes", async () => {
    const value = await fixture();
    await expect(
      buildCapsule({
        ...options(value),
        privateKey: join(value.root, "missing.pem"),
      }),
    ).rejects.toMatchObject({ code: WebCapsuleCliErrorCode.InvalidPrivateKey });
    const parentFile = join(value.root, "not-a-directory");
    await writeFile(parentFile, "file");
    await expect(
      buildCapsule({ ...options(value), out: join(parentFile, "out.capsule") }),
    ).rejects.toMatchObject({ code: WebCapsuleCliErrorCode.BuildFailed });
  });

  it.runIf(process.platform !== "win32")("rejects symlinks", async () => {
    const value = await fixture();
    await symlink(
      join(value.input, "index.html"),
      join(value.input, "link.html"),
    );
    await expect(buildCapsule(options(value))).rejects.toMatchObject({
      code: WebCapsuleCliErrorCode.InvalidInput,
    });
  });
});
