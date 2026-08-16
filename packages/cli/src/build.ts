import { createHash, createPrivateKey, randomUUID, sign } from "node:crypto";
import { createWriteStream } from "node:fs";
import {
  lstat,
  mkdir,
  open,
  readdir,
  readFile,
  realpath,
  rm,
  stat,
  unlink,
} from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { pipeline } from "node:stream/promises";

import {
  CAPSULE_LIMITS,
  FORMAT_VERSION,
  canonicalJson,
  createManifestSignaturePayload,
  parseCapsuleManifest,
  type CapsuleFileEntry,
  type CapsuleManifest,
} from "@webcapsule/format";
import { lookup } from "mime-types";
import yazl from "yazl";

import { assertGeneratedArchive } from "./archive.js";
import { WebCapsuleCliError, WebCapsuleCliErrorCode } from "./errors.js";

export interface BuildOptions {
  readonly inputDirectory: string;
  readonly id: string;
  readonly version: string;
  readonly entry: string;
  readonly minimumRuntimeVersion: string;
  readonly keyId: string;
  readonly privateKey: string;
  readonly out: string;
  readonly createdAt?: string;
  readonly sourceDateEpoch?: string;
}

interface SourceFile {
  readonly absolutePath: string;
  readonly logicalPath: string;
  readonly size: number;
  readonly device: number;
  readonly inode: number;
  readonly modifiedMilliseconds: number;
  hash?: string;
}

function cliError(
  code: WebCapsuleCliErrorCode,
  message: string,
  cause?: unknown,
): WebCapsuleCliError {
  return new WebCapsuleCliError(
    code,
    message,
    cause === undefined ? undefined : { cause },
  );
}

function parseTimestamp(
  createdAt: string | undefined,
  epoch: string | undefined,
): { text: string; date: Date } {
  let text: string;
  if (createdAt !== undefined) text = createdAt;
  else {
    if (epoch === undefined || !/^(?:0|[1-9]\d*)$/.test(epoch))
      throw cliError(
        WebCapsuleCliErrorCode.InvalidTimestamp,
        "--created-at or a valid SOURCE_DATE_EPOCH is required",
      );
    const seconds = Number(epoch);
    if (!Number.isSafeInteger(seconds) || seconds % 2 !== 0)
      throw cliError(
        WebCapsuleCliErrorCode.InvalidTimestamp,
        "SOURCE_DATE_EPOCH must be a safe, even Unix second",
      );
    const date = new Date(seconds * 1000);
    if (!Number.isFinite(date.getTime()))
      throw cliError(
        WebCapsuleCliErrorCode.InvalidTimestamp,
        "SOURCE_DATE_EPOCH is outside the supported range",
      );
    text = date.toISOString().replace(".000Z", "Z");
  }
  if (
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(text) ||
    new Date(text).toISOString().replace(".000Z", "Z") !== text ||
    new Date(text).getUTCSeconds() % 2 !== 0
  )
    throw cliError(
      WebCapsuleCliErrorCode.InvalidTimestamp,
      "Timestamp must be valid UTC YYYY-MM-DDTHH:mm:ssZ with an even second",
    );
  const date = new Date(text);
  if (date.getUTCFullYear() < 1980 || date.getUTCFullYear() > 2107)
    throw cliError(
      WebCapsuleCliErrorCode.InvalidTimestamp,
      "Timestamp must be within the ZIP DOS range 1980 through 2107",
    );
  return { text, date };
}

function byteSort(left: SourceFile, right: SourceFile): number {
  return Buffer.compare(
    Buffer.from(left.logicalPath),
    Buffer.from(right.logicalPath),
  );
}

async function collectFiles(root: string): Promise<SourceFile[]> {
  const result: SourceFile[] = [];
  async function visit(directory: string, prefix: string): Promise<void> {
    const entries = await readdir(directory, { withFileTypes: true });
    for (const entry of entries) {
      const absolutePath = join(directory, entry.name);
      const logicalPath =
        prefix === "" ? entry.name : `${prefix}/${entry.name}`;
      if (entry.name.normalize("NFC") !== entry.name)
        throw cliError(
          WebCapsuleCliErrorCode.InvalidInput,
          `Path is not NFC: ${logicalPath}`,
        );
      const metadata = await lstat(absolutePath);
      if (metadata.isSymbolicLink())
        throw cliError(
          WebCapsuleCliErrorCode.InvalidInput,
          `Symbolic links are forbidden: ${logicalPath}`,
        );
      if (metadata.isDirectory()) await visit(absolutePath, logicalPath);
      else if (metadata.isFile()) {
        if (result.length >= CAPSULE_LIMITS.fileCount)
          throw cliError(
            WebCapsuleCliErrorCode.LimitExceeded,
            "File count limit exceeded",
          );
        if (metadata.size > CAPSULE_LIMITS.fileBytes)
          throw cliError(
            WebCapsuleCliErrorCode.LimitExceeded,
            `File size limit exceeded: ${logicalPath}`,
          );
        result.push({
          absolutePath,
          logicalPath,
          size: metadata.size,
          device: metadata.dev,
          inode: metadata.ino,
          modifiedMilliseconds: metadata.mtimeMs,
        });
      } else
        throw cliError(
          WebCapsuleCliErrorCode.InvalidInput,
          `Non-regular input is forbidden: ${logicalPath}`,
        );
    }
  }
  await visit(root, "");
  result.sort(byteSort);
  return result;
}

async function publishNoReplace(temp: string, output: string): Promise<void> {
  try {
    await import("node:fs/promises").then(({ link }) => link(temp, output));
    await unlink(temp);
  } catch (error: unknown) {
    if ((error as NodeJS.ErrnoException).code === "EEXIST")
      throw cliError(
        WebCapsuleCliErrorCode.OutputExists,
        `Output already exists: ${output}`,
      );
    throw error;
  }
}

export async function buildCapsule(
  options: BuildOptions,
): Promise<CapsuleManifest> {
  const input = resolve(options.inputDirectory);
  const output = resolve(options.out);
  const inputStat = await stat(input).catch((error: unknown) => {
    throw cliError(
      WebCapsuleCliErrorCode.InvalidInput,
      `Input directory does not exist: ${input}`,
      error,
    );
  });
  if (!inputStat.isDirectory())
    throw cliError(
      WebCapsuleCliErrorCode.InvalidInput,
      `Input is not a directory: ${input}`,
    );
  const outputRelative = relative(input, output);
  if (
    outputRelative === "" ||
    (!outputRelative.startsWith(`..${sep}`) &&
      outputRelative !== ".." &&
      !isAbsolute(outputRelative))
  )
    throw cliError(
      WebCapsuleCliErrorCode.InvalidArgument,
      "Output must not be inside the input directory",
    );
  if (
    await lstat(output).then(
      () => true,
      () => false,
    )
  )
    throw cliError(
      WebCapsuleCliErrorCode.OutputExists,
      `Output already exists: ${output}`,
    );

  const realInput = await realpath(input);
  const timestamp = parseTimestamp(options.createdAt, options.sourceDateEpoch);
  const zipTimestamp = new Date(
    timestamp.date.getUTCFullYear(),
    timestamp.date.getUTCMonth(),
    timestamp.date.getUTCDate(),
    timestamp.date.getUTCHours(),
    timestamp.date.getUTCMinutes(),
    timestamp.date.getUTCSeconds(),
  );
  const sources = await collectFiles(realInput);
  let total = 0;
  const files: CapsuleFileEntry[] = [];
  for (const source of sources) {
    total += source.size;
    if (total > CAPSULE_LIMITS.expandedBytes)
      throw cliError(
        WebCapsuleCliErrorCode.LimitExceeded,
        "Expanded content limit exceeded",
      );
    const handle = await open(source.absolutePath, "r");
    try {
      const before = await handle.stat();
      if (
        !before.isFile() ||
        before.dev !== source.device ||
        before.ino !== source.inode ||
        before.size !== source.size ||
        before.mtimeMs !== source.modifiedMilliseconds
      )
        throw cliError(
          WebCapsuleCliErrorCode.InvalidInput,
          `Source changed during build: ${source.logicalPath}`,
        );
      const hash = createHash("sha256");
      let observed = 0;
      for await (const value of handle.createReadStream({ autoClose: false })) {
        const chunk = Buffer.isBuffer(value) ? value : Buffer.from(value);
        observed += chunk.length;
        if (observed > CAPSULE_LIMITS.fileBytes)
          throw cliError(
            WebCapsuleCliErrorCode.LimitExceeded,
            `File size limit exceeded: ${source.logicalPath}`,
          );
        hash.update(chunk);
      }
      const after = await handle.stat();
      if (
        observed !== source.size ||
        after.size !== before.size ||
        after.mtimeMs !== before.mtimeMs ||
        after.ino !== before.ino ||
        after.dev !== before.dev
      )
        throw cliError(
          WebCapsuleCliErrorCode.InvalidInput,
          `Source changed during hashing: ${source.logicalPath}`,
        );
      source.hash = hash.digest("hex");
    } finally {
      await handle.close();
    }
    const media = lookup(source.logicalPath);
    files.push({
      path: source.logicalPath,
      sha256: source.hash,
      size: source.size,
      mediaType: typeof media === "string" ? media : "application/octet-stream",
    });
  }
  const manifest = parseCapsuleManifest({
    formatVersion: FORMAT_VERSION,
    capsuleId: options.id,
    version: options.version,
    entry: options.entry,
    createdAt: timestamp.text,
    minimumRuntimeVersion: options.minimumRuntimeVersion,
    keyId: options.keyId,
    files,
    policy: {
      network: { mode: "deny" },
      navigation: { externalOrigins: [] },
      bridgeCapabilities: [],
    },
  });

  let privateKey;
  try {
    const pem = await readFile(resolve(options.privateKey), "utf8");
    if (
      !/^-----BEGIN PRIVATE KEY-----\n(?:[A-Za-z0-9+/]{1,64}={0,2}\n)+-----END PRIVATE KEY-----\n$/.test(
        pem,
      )
    )
      throw new Error("not canonical PKCS#8 PEM");
    privateKey = createPrivateKey({ key: pem, format: "pem", type: "pkcs8" });
    if (
      privateKey.type !== "private" ||
      privateKey.asymmetricKeyType !== "ed25519"
    )
      throw new Error("Not an Ed25519 private key");
  } catch (error: unknown) {
    throw cliError(
      WebCapsuleCliErrorCode.InvalidPrivateKey,
      "Private key must be an Ed25519 PKCS#8 PEM key",
      error,
    );
  }

  const manifestBytes = Buffer.from(`${canonicalJson(manifest)}\n`, "utf8");
  const signatureBytes = Buffer.from(
    `${sign(null, createManifestSignaturePayload(manifest), privateKey).toString("base64")}\n`,
    "ascii",
  );
  const outputParent = dirname(output);
  try {
    await mkdir(outputParent, { recursive: true });
  } catch (error: unknown) {
    throw cliError(
      WebCapsuleCliErrorCode.BuildFailed,
      "Cannot create output parent directory",
      error,
    );
  }
  const temporary = join(
    outputParent,
    `.${options.out.split(/[\\/]/).pop() ?? "capsule"}.${randomUUID()}.tmp`,
  );
  let temporaryCreated = false;
  try {
    const handle = await open(temporary, "wx", 0o600);
    await handle.close();
    temporaryCreated = true;
    const zip = new yazl.ZipFile();
    const entryOptions = {
      mtime: zipTimestamp,
      mode: 0o100644,
      compress: true,
      compressionLevel: 9,
      forceDosTimestamp: true,
    };
    zip.addBuffer(manifestBytes, "capsule.json", entryOptions);
    zip.addBuffer(signatureBytes, "capsule.sig", entryOptions);
    const archiveHandles = [];
    try {
      for (const source of sources) {
        const handle = await open(source.absolutePath, "r");
        archiveHandles.push(handle);
        const before = await handle.stat();
        if (
          !before.isFile() ||
          before.dev !== source.device ||
          before.ino !== source.inode ||
          before.size !== source.size ||
          before.mtimeMs !== source.modifiedMilliseconds
        )
          throw cliError(
            WebCapsuleCliErrorCode.InvalidInput,
            `Source changed before archiving: ${source.logicalPath}`,
          );
        zip.addReadStream(
          handle.createReadStream({ autoClose: false }),
          `files/${source.logicalPath}`,
          { ...entryOptions, size: source.size },
        );
      }
      zip.end({ forceZip64Format: false });
      await pipeline(
        zip.outputStream,
        createWriteStream(temporary, { flags: "w", mode: 0o600 }),
      );
      for (let index = 0; index < sources.length; index++) {
        const after = await archiveHandles[index]!.stat();
        const source = sources[index]!;
        if (
          after.dev !== source.device ||
          after.ino !== source.inode ||
          after.size !== source.size ||
          after.mtimeMs !== source.modifiedMilliseconds
        )
          throw cliError(
            WebCapsuleCliErrorCode.InvalidInput,
            `Source changed while archiving: ${source.logicalPath}`,
          );
      }
    } finally {
      await Promise.all(archiveHandles.map((handle) => handle.close()));
    }
    const archiveStat = await stat(temporary);
    if (archiveStat.size > CAPSULE_LIMITS.archiveBytes)
      throw cliError(
        WebCapsuleCliErrorCode.LimitExceeded,
        "Archive size limit exceeded",
      );
    await assertGeneratedArchive(temporary, {
      manifest,
      manifestBytes,
      signatureBytes,
      fileHashes: new Map(files.map((file) => [file.path, file.sha256])),
      timestamp: timestamp.date,
    });
    await publishNoReplace(temporary, output);
    temporaryCreated = false;
    return manifest;
  } catch (error: unknown) {
    if (error instanceof WebCapsuleCliError) throw error;
    throw cliError(
      WebCapsuleCliErrorCode.BuildFailed,
      "Capsule build failed",
      error,
    );
  } finally {
    if (temporaryCreated) await rm(temporary, { force: true });
  }
}
