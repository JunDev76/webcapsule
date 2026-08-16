import {
  createHash,
  createPublicKey,
  verify as verifySignature,
} from "node:crypto";
import { open, stat } from "node:fs/promises";

import {
  CAPSULE_LIMITS,
  WebCapsuleFormatError,
  assertCapsuleId,
  assertKeyId,
  assertSafePath,
  assertSafePathSet,
  assertVersion,
  canonicalJson,
  compareVersions,
  createManifestSignaturePayload,
  parseCapsuleManifestJson,
  type CapsuleManifest,
} from "@webcapsule/format";
import yauzl, { type Entry, type ZipFile } from "yauzl";

import { WebCapsuleCliError, WebCapsuleCliErrorCode } from "./errors.js";

export const MANIFEST_BYTES_LIMIT = 5 * 1024 * 1024;
export const SIGNATURE_BYTES = 89;
const ENTRY_OVERHEAD = 2;
const UTF8 = new TextDecoder("utf-8", { fatal: true });
const ALLOWED_FLAGS = 0x800 | 0x008;
const LOCAL_HEADER_BYTES = 30;

interface RawEntry extends Entry {
  readonly fileNameRaw: Buffer;
  readonly extraFieldRaw: Buffer;
  readonly fileCommentRaw: Buffer;
}
export interface ArchiveSummary {
  readonly trust: "unverified";
  readonly capsuleId: string;
  readonly version: string;
  readonly keyId: string;
  readonly entry: string;
  readonly createdAt: string;
  readonly fileCount: number;
  readonly declaredBytes: number;
}
export interface VerifyOptions {
  readonly publicKey: string;
  readonly expectedId?: string;
  readonly expectedKeyId?: string;
  readonly runtimeVersion?: string;
}
export interface ExpectedArchive {
  readonly manifest: CapsuleManifest;
  readonly manifestBytes: Buffer;
  readonly signatureBytes: Buffer;
  readonly fileHashes: ReadonlyMap<string, string>;
  readonly timestamp: Date;
}
type ReadMode = "inspect" | "verify";

function archiveError(message: string, cause?: unknown): WebCapsuleCliError {
  if (cause instanceof WebCapsuleFormatError)
    return new WebCapsuleCliError(
      cause.code as unknown as WebCapsuleCliErrorCode,
      message,
      { cause },
    );
  return new WebCapsuleCliError(
    WebCapsuleCliErrorCode.InvalidArchiveProfile,
    message,
    cause === undefined ? undefined : { cause },
  );
}
function openZip(path: string): Promise<ZipFile> {
  return new Promise((resolve, reject) =>
    yauzl.open(
      path,
      {
        lazyEntries: true,
        decodeStrings: true,
        validateEntrySizes: true,
        strictFileNames: true,
        autoClose: false,
      },
      (error, zip) =>
        error || !zip
          ? reject(archiveError("Cannot open capsule archive", error))
          : resolve(zip),
    ),
  );
}
function decodeRawName(entry: RawEntry): string {
  let name: string;
  try {
    name = UTF8.decode(entry.fileNameRaw);
  } catch (error) {
    throw archiveError("ZIP entry name is not valid UTF-8", error);
  }
  if (!Buffer.from(name, "utf8").equals(entry.fileNameRaw))
    throw archiveError("ZIP entry name is not exact UTF-8");
  if (name !== entry.fileName)
    throw archiveError("ZIP entry decoded name is inconsistent");
  return name;
}
function dosTimestamp(date: Date): { time: number; day: number } {
  return {
    time:
      (date.getUTCSeconds() >>> 1) |
      (date.getUTCMinutes() << 5) |
      (date.getUTCHours() << 11),
    day:
      date.getUTCDate() |
      ((date.getUTCMonth() + 1) << 5) |
      ((date.getUTCFullYear() - 1980) << 9),
  };
}
async function assertLocalHeader(
  handle: Awaited<ReturnType<typeof open>>,
  archiveSize: number,
  entry: RawEntry,
  expectedTimestamp?: { time: number; day: number },
): Promise<void> {
  const offset = entry.relativeOffsetOfLocalHeader;
  if (
    !Number.isSafeInteger(offset) ||
    offset < 0 ||
    offset + LOCAL_HEADER_BYTES > archiveSize
  )
    throw archiveError("Local header offset is outside archive bounds");
  const header = Buffer.alloc(LOCAL_HEADER_BYTES);
  const result = await handle.read(header, 0, header.length, offset);
  if (
    result.bytesRead !== header.length ||
    header.readUInt32LE(0) !== 0x04034b50
  )
    throw archiveError("Invalid local file header signature");
  const flags = header.readUInt16LE(6);
  const method = header.readUInt16LE(8);
  const time = header.readUInt16LE(10);
  const day = header.readUInt16LE(12);
  const nameLength = header.readUInt16LE(26);
  const extraLength = header.readUInt16LE(28);
  if (
    flags !== entry.generalPurposeBitFlag ||
    method !== entry.compressionMethod
  )
    throw archiveError("Local and central ZIP profile differs");
  if (extraLength !== 0 || nameLength !== entry.fileNameRaw.length)
    throw archiveError("Local ZIP name/extra lengths are invalid");
  if (offset + LOCAL_HEADER_BYTES + nameLength > archiveSize)
    throw archiveError("Local file name is outside archive bounds");
  const name = Buffer.alloc(nameLength);
  const nameRead = await handle.read(
    name,
    0,
    nameLength,
    offset + LOCAL_HEADER_BYTES,
  );
  if (nameRead.bytesRead !== nameLength || !name.equals(entry.fileNameRaw))
    throw archiveError("Local and central file names differ");
  if (
    expectedTimestamp &&
    (time !== expectedTimestamp.time || day !== expectedTimestamp.day)
  )
    throw archiveError("ZIP timestamp does not match manifest createdAt");
  const descriptor = (flags & 0x008) !== 0;
  const crc = header.readUInt32LE(14);
  const compressed = header.readUInt32LE(18);
  const expanded = header.readUInt32LE(22);
  if (descriptor) {
    if (crc !== 0 || compressed !== 0 || expanded !== 0)
      throw archiveError("Data-descriptor local fields must be zero");
  } else if (
    crc !== entry.crc32 ||
    compressed !== entry.compressedSize ||
    expanded !== entry.uncompressedSize
  )
    throw archiveError("Local and central CRC/sizes differ");
}
function updateCrc32(crc: number, chunk: Buffer): number {
  let value = crc;
  for (const byte of chunk) {
    value ^= byte;
    for (let bit = 0; bit < 8; bit++)
      value = (value >>> 1) ^ (value & 1 ? 0xedb88320 : 0);
  }
  return value;
}
function consumeEntry(
  zip: ZipFile,
  entry: Entry,
  maximum: number,
  hashContent: boolean,
): Promise<{ bytes: Buffer; size: number; hash?: string }> {
  return new Promise((resolve, reject) =>
    zip.openReadStream(entry, (error, stream) => {
      if (error || !stream)
        return reject(
          archiveError(`Cannot read archive entry: ${entry.fileName}`, error),
        );
      const chunks: Buffer[] = [];
      const hash = hashContent ? createHash("sha256") : undefined;
      let size = 0;
      let crc = 0xffffffff;
      let settled = false;
      const fail = (reason: unknown) => {
        if (!settled) {
          settled = true;
          reject(
            reason instanceof Error
              ? reason
              : archiveError("Archive stream failed", reason),
          );
        }
      };
      stream.on("data", (value: Buffer) => {
        const chunk = Buffer.isBuffer(value) ? value : Buffer.from(value);
        size += chunk.length;
        if (size > maximum)
          stream.destroy(
            archiveError(`Archive entry exceeds limit: ${entry.fileName}`),
          );
        else {
          chunks.push(chunk);
          crc = updateCrc32(crc, chunk);
          hash?.update(chunk);
        }
      });
      stream.once("error", (reason) =>
        fail(
          archiveError(
            `Cannot consume archive entry: ${entry.fileName}`,
            reason,
          ),
        ),
      );
      stream.once("end", () => {
        if (!settled) {
          if ((crc ^ 0xffffffff) >>> 0 !== entry.crc32) {
            fail(archiveError(`Archive entry CRC mismatch: ${entry.fileName}`));
            return;
          }
          settled = true;
          resolve({
            bytes: Buffer.concat(chunks, size),
            size,
            ...(hash === undefined ? {} : { hash: hash.digest("hex") }),
          });
        }
      });
    }),
  );
}
function assertCentralProfile(entry: RawEntry): string {
  const name = decodeRawName(entry);
  if (
    entry.generalPurposeBitFlag !== 0x800 &&
    entry.generalPurposeBitFlag !== ALLOWED_FLAGS
  )
    throw archiveError(`Forbidden general-purpose ZIP flags: ${name}`);
  if (
    entry.isEncrypted() ||
    entry.compressionMethod !== 8 ||
    name.endsWith("/")
  )
    throw archiveError(
      `Entry must be an unencrypted regular DEFLATE file: ${name}`,
    );
  if (
    entry.extraFieldRaw.length !== 0 ||
    entry.fileCommentRaw.length !== 0 ||
    entry.versionNeededToExtract >= 45
  )
    throw archiveError(`Forbidden ZIP metadata: ${name}`);
  if (
    entry.compressedSize === 0xffffffff ||
    entry.uncompressedSize === 0xffffffff
  )
    throw archiveError(`ZIP64 is forbidden: ${name}`);
  const platform = entry.versionMadeBy >>> 8;
  const mode = entry.externalFileAttributes >>> 16;
  if (
    platform !== 3 ||
    (mode & 0o170000) !== 0o100000 ||
    (mode & 0o777) !== 0o644
  )
    throw archiveError(`Entry platform/mode profile is invalid: ${name}`);
  return name;
}
function parseMetadata(
  manifestBytes: Buffer,
  signatureBytes: Buffer,
): CapsuleManifest {
  if (
    manifestBytes.length === 0 ||
    manifestBytes.length > MANIFEST_BYTES_LIMIT ||
    manifestBytes.at(-1) !== 10 ||
    manifestBytes.at(-2) === 10
  )
    throw archiveError(
      "capsule.json must have exactly one final LF and fit its bound",
    );
  let text: string;
  try {
    text = UTF8.decode(manifestBytes);
  } catch (error) {
    throw archiveError("capsule.json is not exact UTF-8", error);
  }
  let manifest: CapsuleManifest;
  try {
    manifest = parseCapsuleManifestJson(text);
  } catch (error) {
    throw archiveError("capsule.json is invalid", error);
  }
  if (
    !manifestBytes.equals(Buffer.from(`${canonicalJson(manifest)}\n`, "utf8"))
  )
    throw archiveError("capsule.json is not canonical");
  if (
    signatureBytes.length !== SIGNATURE_BYTES ||
    !/^[A-Za-z0-9+/]{86}==\n$/.test(signatureBytes.toString("ascii"))
  )
    throw archiveError("capsule.sig encoding is invalid");
  return manifest;
}
async function readArchive(
  path: string,
  mode: ReadMode,
): Promise<{ manifest: CapsuleManifest; signature: Buffer }> {
  const archiveStat = await stat(path).catch((error) => {
    throw archiveError("Capsule does not exist", error);
  });
  if (!archiveStat.isFile() || archiveStat.size > CAPSULE_LIMITS.archiveBytes)
    throw archiveError("Capsule archive size is invalid");
  const handle = await open(path, "r").catch((error) => {
    throw archiveError("Cannot read capsule", error);
  });
  let zip: ZipFile | undefined;
  try {
    zip = await openZip(path);
    const entries: RawEntry[] = [];
    await new Promise<void>((resolve, reject) => {
      let settled = false;
      const fail = (error: unknown) => {
        if (settled) return;
        settled = true;
        zip?.close();
        reject(
          error instanceof WebCapsuleCliError
            ? error
            : archiveError("Cannot enumerate capsule", error),
        );
      };
      zip!.once("error", fail);
      zip!.once("end", () => {
        if (!settled) {
          settled = true;
          resolve();
        }
      });
      zip!.on("entry", (value: Entry) => {
        if (settled) return;
        if (entries.length >= CAPSULE_LIMITS.fileCount + ENTRY_OVERHEAD)
          return fail(
            new WebCapsuleCliError(
              WebCapsuleCliErrorCode.LimitExceeded,
              "Archive entry count limit exceeded",
            ),
          );
        entries.push(value as RawEntry);
        zip!.readEntry();
      });
      zip!.readEntry();
    });
    if (zip.comment !== "") throw archiveError("Archive comment is forbidden");
    const names = entries.map(assertCentralProfile);
    for (const name of names) assertSafePath(name);
    if (
      entries.length < 2 ||
      names[0] !== "capsule.json" ||
      names[1] !== "capsule.sig"
    )
      throw archiveError("Metadata entries or order are invalid");
    assertSafePathSet(names.slice(2));
    const metadata = await Promise.all([
      consumeEntry(zip, entries[0]!, MANIFEST_BYTES_LIMIT, false),
      consumeEntry(zip, entries[1]!, SIGNATURE_BYTES, false),
    ]);
    const manifest = parseMetadata(metadata[0].bytes, metadata[1].bytes);
    const expected = [
      "capsule.json",
      "capsule.sig",
      ...manifest.files.map((file) => `files/${file.path}`),
    ];
    if (
      expected.length !== names.length ||
      expected.some((name, index) => name !== names[index])
    )
      throw archiveError(
        "Archive content set or byte order does not match manifest",
      );
    const expectedDos = dosTimestamp(new Date(manifest.createdAt));
    let expanded = metadata[0].size + metadata[1].size;
    for (let index = 0; index < entries.length; index++) {
      const entry = entries[index]!;
      await assertLocalHeader(handle, archiveStat.size, entry, expectedDos);
      if (index < 2) continue;
      const file = manifest.files[index - 2]!;
      if (entry.uncompressedSize !== file.size)
        throw archiveError(`Declared size differs: ${file.path}`);
      const consumed = await consumeEntry(
        zip,
        entry,
        CAPSULE_LIMITS.fileBytes,
        mode === "verify",
      );
      expanded += consumed.size;
      if (
        expanded > CAPSULE_LIMITS.expandedBytes ||
        consumed.size !== file.size
      )
        throw archiveError(
          `Expanded content limit/size mismatch: ${file.path}`,
        );
      if (mode === "verify" && consumed.hash !== file.sha256)
        throw new WebCapsuleCliError(
          WebCapsuleCliErrorCode.HashMismatch,
          `Content hash mismatch: ${file.path}`,
        );
    }
    return { manifest, signature: metadata[1].bytes.subarray(0, 88) };
  } finally {
    zip?.close();
    await handle.close();
  }
}
function summary(manifest: CapsuleManifest): ArchiveSummary {
  return {
    trust: "unverified",
    capsuleId: manifest.capsuleId,
    version: manifest.version,
    keyId: manifest.keyId,
    entry: manifest.entry,
    createdAt: manifest.createdAt,
    fileCount: manifest.files.length,
    declaredBytes: manifest.files.reduce((sum, file) => sum + file.size, 0),
  };
}
export async function inspectCapsule(path: string): Promise<ArchiveSummary> {
  return summary((await readArchive(path, "inspect")).manifest);
}
function parseExactPublicKey(pem: string) {
  if (
    !/^-----BEGIN PUBLIC KEY-----\n(?:[A-Za-z0-9+/]{1,64}={0,2}\n)+-----END PUBLIC KEY-----\n$/.test(
      pem,
    )
  )
    throw new WebCapsuleCliError(
      WebCapsuleCliErrorCode.InvalidPublicKey,
      "Public key must be one canonical SPKI PUBLIC KEY PEM block",
    );
  try {
    const key = createPublicKey({ key: pem, format: "pem", type: "spki" });
    if (key.asymmetricKeyType !== "ed25519") throw new Error("not Ed25519");
    return key;
  } catch (cause) {
    throw new WebCapsuleCliError(
      WebCapsuleCliErrorCode.InvalidPublicKey,
      "Public key must be an Ed25519 SPKI PEM key",
      { cause },
    );
  }
}
export async function verifyCapsule(
  path: string,
  options: VerifyOptions,
): Promise<ArchiveSummary> {
  try {
    if (options.expectedId !== undefined) assertCapsuleId(options.expectedId);
    if (options.expectedKeyId !== undefined) assertKeyId(options.expectedKeyId);
    if (options.runtimeVersion !== undefined)
      assertVersion(options.runtimeVersion);
  } catch (cause) {
    throw new WebCapsuleCliError(
      WebCapsuleCliErrorCode.InvalidArgument,
      "Verification option is invalid",
      { cause },
    );
  }
  const { manifest, signature } = await readArchive(path, "verify");
  if (
    options.expectedId !== undefined &&
    manifest.capsuleId !== options.expectedId
  )
    throw new WebCapsuleCliError(
      WebCapsuleCliErrorCode.IdMismatch,
      "Capsule ID does not match expected ID",
    );
  if (
    options.expectedKeyId !== undefined &&
    manifest.keyId !== options.expectedKeyId
  )
    throw new WebCapsuleCliError(
      WebCapsuleCliErrorCode.KeyIdMismatch,
      "Key ID does not match expected key ID",
    );
  if (
    options.runtimeVersion !== undefined &&
    compareVersions(options.runtimeVersion, manifest.minimumRuntimeVersion) < 0
  )
    throw new WebCapsuleCliError(
      WebCapsuleCliErrorCode.RuntimeIncompatible,
      "Runtime version is incompatible",
    );
  const key = parseExactPublicKey(options.publicKey);
  if (
    !verifySignature(
      null,
      createManifestSignaturePayload(manifest),
      key,
      Buffer.from(signature.toString("ascii"), "base64"),
    )
  )
    throw new WebCapsuleCliError(
      WebCapsuleCliErrorCode.SignatureMismatch,
      "Manifest signature verification failed",
    );
  return summary(manifest);
}
export async function assertGeneratedArchive(
  path: string,
  expected: ExpectedArchive,
): Promise<void> {
  const result = await readArchive(path, "verify");
  if (
    !Buffer.from(`${canonicalJson(result.manifest)}\n`).equals(
      expected.manifestBytes,
    ) ||
    !result.signature.equals(expected.signatureBytes.subarray(0, 88))
  )
    throw archiveError("Generated metadata self-check failed");
  if (
    result.manifest.createdAt !==
    expected.timestamp.toISOString().replace(".000Z", "Z")
  )
    throw archiveError("Generated timestamp self-check failed");
  for (const file of result.manifest.files)
    if (expected.fileHashes.get(file.path) !== file.sha256)
      throw archiveError(`Generated hash self-check failed: ${file.path}`);
}
