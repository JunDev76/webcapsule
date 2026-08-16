import {
  createUpdateIndexSignaturePayload,
  parseUpdateIndexJson,
} from "@webcapsule/format";
import { createPublicKey, generateKeyPairSync, verify } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { WebCapsuleCliError } from "./errors.js";
import { createUpdateIndex } from "./update-index.js";

const directories: string[] = [];
const release = {
  version: "1.0.0",
  url: "https://example.com/app-1.0.0.capsule",
  sha256: "a".repeat(64),
  size: 42,
  minimumRuntimeVersion: "1.0.0",
};

async function setup(): Promise<{
  directory: string;
  privateKey: string;
  publicKey: ReturnType<typeof createPublicKey>;
}> {
  const directory = await mkdtemp(join(tmpdir(), "webcapsule-index-"));
  directories.push(directory);
  const pair = generateKeyPairSync("ed25519");
  const privateKey = join(directory, "private.pem");
  await writeFile(
    privateKey,
    pair.privateKey.export({ format: "pem", type: "pkcs8" }),
  );
  return { directory, privateKey, publicKey: pair.publicKey };
}

async function descriptor(
  directory: string,
  name: string,
  value: unknown,
): Promise<string> {
  const path = join(directory, name);
  await writeFile(path, JSON.stringify(value));
  return path;
}

afterEach(async () => {
  await Promise.all(
    directories
      .splice(0)
      .map((path) => rm(path, { recursive: true, force: true })),
  );
});

describe("createUpdateIndex", () => {
  it("sorts releases and produces deterministic signed canonical bytes", async () => {
    const { directory, privateKey, publicKey } = await setup();
    const oldRelease = await descriptor(directory, "old.json", release);
    const newRelease = await descriptor(directory, "new.json", {
      ...release,
      version: "2.0.0",
      url: "https://example.com/app-2.capsule",
    });
    const first = join(directory, "first.json");
    const second = join(directory, "second.json");
    const base = {
      id: "com.example.app",
      channel: "stable",
      keyId: "release",
      privateKey,
    };
    await createUpdateIndex({
      ...base,
      releases: [oldRelease, newRelease],
      out: first,
    });
    await createUpdateIndex({
      ...base,
      releases: [newRelease, oldRelease],
      out: second,
    });
    const firstBytes = await readFile(first);
    expect(firstBytes).toEqual(await readFile(second));
    expect(firstBytes.at(-1)).toBe(10);
    const parsed = parseUpdateIndexJson(firstBytes.toString("utf8"));
    expect(parsed.releases.map(({ version }) => version)).toEqual([
      "2.0.0",
      "1.0.0",
    ]);
    expect(
      verify(
        null,
        createUpdateIndexSignaturePayload(parsed),
        publicKey,
        Buffer.from(parsed.signature, "base64"),
      ),
    ).toBe(true);
  });

  it("rejects equivalent versions and malformed descriptors", async () => {
    const { directory, privateKey } = await setup();
    const one = await descriptor(directory, "one.json", {
      ...release,
      version: "1.0.0+one",
    });
    const two = await descriptor(directory, "two.json", {
      ...release,
      version: "1.0.0+two",
    });
    await expect(
      createUpdateIndex({
        id: "com.example.app",
        channel: "stable",
        keyId: "release",
        privateKey,
        releases: [one, two],
        out: join(directory, "index.json"),
      }),
    ).rejects.toMatchObject({ code: "INVALID_INPUT" });
    const bad = join(directory, "bad.json");
    await writeFile(bad, '{"version":"1.0.0","version":"2.0.0"}');
    await expect(
      createUpdateIndex({
        id: "com.example.app",
        channel: "stable",
        keyId: "release",
        privateKey,
        releases: [bad],
        out: join(directory, "bad-index.json"),
      }),
    ).rejects.toThrow();
  });

  it("preserves an existing output and rejects no releases", async () => {
    const { directory, privateKey } = await setup();
    const item = await descriptor(directory, "release.json", release);
    const output = join(directory, "index.json");
    await writeFile(output, "preserve");
    await expect(
      createUpdateIndex({
        id: "com.example.app",
        channel: "stable",
        keyId: "release",
        privateKey,
        releases: [item],
        out: output,
      }),
    ).rejects.toBeInstanceOf(WebCapsuleCliError);
    await expect(readFile(output, "utf8")).resolves.toBe("preserve");
    await expect(
      createUpdateIndex({
        id: "com.example.app",
        channel: "stable",
        keyId: "release",
        privateKey,
        releases: [],
        out: join(directory, "none.json"),
      }),
    ).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
  });
});
