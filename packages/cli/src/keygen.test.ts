import { createHash, createPrivateKey, createPublicKey } from "node:crypto";
import { access, mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { WebCapsuleCliErrorCode } from "./errors.js";
import { generateKeys } from "./keygen.js";

const directories: string[] = [];

afterEach(async () => {
  const { rm } = await import("node:fs/promises");
  await Promise.all(
    directories.splice(0).map((path) => rm(path, { recursive: true })),
  );
});

async function temporaryDirectory(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "webcapsule-keygen-"));
  directories.push(directory);
  return directory;
}

describe("generateKeys", () => {
  it("writes PKCS#8 and SPKI PEM keys and returns the SPKI fingerprint", async () => {
    const directory = await temporaryDirectory();
    const result = await generateKeys(directory);
    const privatePem = await readFile(result.privateKeyPath, "utf8");
    const publicPem = await readFile(result.publicKeyPath, "utf8");
    const expectedFingerprint = createHash("sha256")
      .update(
        createPublicKey(publicPem).export({ format: "der", type: "spki" }),
      )
      .digest("hex");

    expect(createPrivateKey(privatePem).type).toBe("private");
    expect(createPublicKey(publicPem).type).toBe("public");
    expect(result.fingerprint).toBe(expectedFingerprint);
    expect((await stat(result.privateKeyPath)).mode & 0o777).toBe(0o600);
  });

  it.each(["private.pem", "public.pem"])(
    "does not alter outputs when %s already exists",
    async (existingName) => {
      const directory = await temporaryDirectory();
      const existingPath = join(directory, existingName);
      await writeFile(existingPath, "existing");

      await expect(generateKeys(directory)).rejects.toMatchObject({
        code: WebCapsuleCliErrorCode.OutputExists,
      });
      await expect(readFile(existingPath, "utf8")).resolves.toBe("existing");
      const otherName =
        existingName === "private.pem" ? "public.pem" : "private.pem";
      await expect(access(join(directory, otherName))).rejects.toThrow();
    },
  );
});
