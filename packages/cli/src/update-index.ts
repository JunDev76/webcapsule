import {
  canonicalJson,
  compareVersions,
  createUpdateIndexSignaturePayload,
  parseUnsignedUpdateIndex,
  parseUpdateIndexJson,
  parseUpdateReleaseJson,
  UPDATE_INDEX_SCHEMA_VERSION,
  type UpdateRelease,
} from "@webcapsule/format";
import {
  createPrivateKey,
  createPublicKey,
  randomUUID,
  sign,
  verify,
} from "node:crypto";
import { link, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

import { WebCapsuleCliError, WebCapsuleCliErrorCode } from "./errors.js";

export interface CreateUpdateIndexOptions {
  readonly id: string;
  readonly channel: string;
  readonly keyId: string;
  readonly privateKey: string;
  readonly releases: readonly string[];
  readonly out: string;
}

export interface CreatedUpdateIndex {
  readonly outputPath: string;
  readonly capsuleId: string;
  readonly channel: string;
  readonly releaseCount: number;
}

function invalidPrivateKey(cause?: unknown): WebCapsuleCliError {
  return new WebCapsuleCliError(
    WebCapsuleCliErrorCode.InvalidPrivateKey,
    "private key must be an Ed25519 PKCS#8 PEM key",
    cause === undefined ? undefined : { cause },
  );
}

export async function createUpdateIndex(
  options: CreateUpdateIndexOptions,
): Promise<CreatedUpdateIndex> {
  if (options.releases.length === 0) {
    throw new WebCapsuleCliError(
      WebCapsuleCliErrorCode.InvalidArgument,
      "at least one --release descriptor is required",
    );
  }

  const releases: UpdateRelease[] = [];
  for (const descriptorPath of options.releases) {
    const text = await readFile(descriptorPath, "utf8").catch(
      (cause: unknown) => {
        throw new WebCapsuleCliError(
          WebCapsuleCliErrorCode.InvalidInput,
          `cannot read release descriptor: ${descriptorPath}`,
          { cause },
        );
      },
    );
    releases.push(parseUpdateReleaseJson(text));
  }
  releases.sort((left, right) => compareVersions(right.version, left.version));
  for (let index = 1; index < releases.length; index += 1) {
    if (
      compareVersions(
        releases[index - 1]!.version,
        releases[index]!.version,
      ) === 0
    ) {
      throw new WebCapsuleCliError(
        WebCapsuleCliErrorCode.InvalidInput,
        "release descriptors contain SemVer-equivalent versions",
      );
    }
  }

  const unsigned = parseUnsignedUpdateIndex({
    schemaVersion: UPDATE_INDEX_SCHEMA_VERSION,
    capsuleId: options.id,
    channel: options.channel,
    releases,
    keyId: options.keyId,
  });

  let privateKey;
  try {
    privateKey = createPrivateKey({
      key: await readFile(options.privateKey, "utf8"),
      format: "pem",
      type: "pkcs8",
    });
  } catch (error: unknown) {
    throw invalidPrivateKey(error);
  }
  if (privateKey.asymmetricKeyType !== "ed25519") throw invalidPrivateKey();

  const payload = createUpdateIndexSignaturePayload(unsigned);
  const signatureBytes = sign(null, payload, privateKey);
  if (signatureBytes.length !== 64) throw invalidPrivateKey();
  const signed = { ...unsigned, signature: signatureBytes.toString("base64") };
  const bytes = Buffer.from(`${canonicalJson(signed)}\n`, "utf8");
  const parsed = parseUpdateIndexJson(bytes.toString("utf8"));
  const publicKey = createPublicKey(privateKey);
  if (
    !verify(
      null,
      createUpdateIndexSignaturePayload(parsed),
      publicKey,
      Buffer.from(parsed.signature, "base64"),
    )
  ) {
    throw new WebCapsuleCliError(
      WebCapsuleCliErrorCode.InvalidPrivateKey,
      "generated update index signature failed verification",
    );
  }

  const outputPath = resolve(options.out);
  const parent = dirname(outputPath);
  const temporaryPath = `${outputPath}.${randomUUID()}.tmp`;
  await mkdir(parent, { recursive: true });
  try {
    await writeFile(temporaryPath, bytes, { flag: "wx", mode: 0o644 });
    try {
      await link(temporaryPath, outputPath);
    } catch (error: unknown) {
      throw new WebCapsuleCliError(
        WebCapsuleCliErrorCode.OutputExists,
        `output already exists: ${outputPath}`,
        { cause: error },
      );
    }
  } finally {
    await rm(temporaryPath, { force: true });
  }

  return {
    outputPath,
    capsuleId: parsed.capsuleId,
    channel: parsed.channel,
    releaseCount: parsed.releases.length,
  };
}
