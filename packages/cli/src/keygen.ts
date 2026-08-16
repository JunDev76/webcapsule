import {
  createHash,
  createPublicKey,
  generateKeyPair as generateKeyPairCallback,
  randomUUID,
} from "node:crypto";
import { link, lstat, mkdir, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { WebCapsuleCliError, WebCapsuleCliErrorCode } from "./errors.js";

const generateKeyPair = promisify(generateKeyPairCallback);
const PRIVATE_KEY_NAME = "private.pem";
const PUBLIC_KEY_NAME = "public.pem";

export interface GeneratedKeyPair {
  readonly fingerprint: string;
  readonly privateKeyPath: string;
  readonly publicKeyPath: string;
}

async function outputExists(path: string): Promise<boolean> {
  try {
    await lstat(path);
    return true;
  } catch (error) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") {
      return false;
    }
    throw error;
  }
}

export async function generateKeys(
  outputDirectory: string,
): Promise<GeneratedKeyPair> {
  const directory = resolve(outputDirectory);
  const privateKeyPath = join(directory, PRIVATE_KEY_NAME);
  const publicKeyPath = join(directory, PUBLIC_KEY_NAME);
  const suffix = randomUUID();
  const privateTempPath = join(directory, `.${PRIVATE_KEY_NAME}.${suffix}.tmp`);
  const publicTempPath = join(directory, `.${PUBLIC_KEY_NAME}.${suffix}.tmp`);
  const createdPaths = new Set<string>();

  try {
    await mkdir(directory, { recursive: true });
    if (
      (await outputExists(privateKeyPath)) ||
      (await outputExists(publicKeyPath))
    ) {
      throw new WebCapsuleCliError(
        WebCapsuleCliErrorCode.OutputExists,
        `key output already exists in ${directory}`,
      );
    }

    const { privateKey, publicKey } = await generateKeyPair("ed25519", {
      privateKeyEncoding: { format: "pem", type: "pkcs8" },
      publicKeyEncoding: { format: "pem", type: "spki" },
    });
    const publicDer = createPublicKey(publicKey).export({
      format: "der",
      type: "spki",
    });

    await writeFile(privateTempPath, privateKey, { flag: "wx", mode: 0o600 });
    createdPaths.add(privateTempPath);
    await writeFile(publicTempPath, publicKey, { flag: "wx", mode: 0o644 });
    createdPaths.add(publicTempPath);

    try {
      await link(privateTempPath, privateKeyPath);
      createdPaths.add(privateKeyPath);
      await link(publicTempPath, publicKeyPath);
      createdPaths.add(publicKeyPath);
    } catch (error) {
      throw new WebCapsuleCliError(
        WebCapsuleCliErrorCode.OutputExists,
        `key output already exists in ${directory}`,
        { cause: error },
      );
    }
    await rm(privateTempPath);
    createdPaths.delete(privateTempPath);
    await rm(publicTempPath);
    createdPaths.delete(publicTempPath);

    return {
      fingerprint: createHash("sha256").update(publicDer).digest("hex"),
      privateKeyPath,
      publicKeyPath,
    };
  } catch (error) {
    await Promise.all(
      [...createdPaths].map((path) => rm(path, { force: true })),
    );
    if (error instanceof WebCapsuleCliError) {
      throw error;
    }
    throw new WebCapsuleCliError(
      WebCapsuleCliErrorCode.KeyGenerationFailed,
      `failed to generate keys in ${directory}`,
      { cause: error },
    );
  }
}
