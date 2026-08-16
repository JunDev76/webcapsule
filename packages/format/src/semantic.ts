import {
  CAPSULE_LIMITS,
  FORMAT_VERSION,
  UPDATE_INDEX_SCHEMA_VERSION,
} from "./constants.js";
import { WebCapsuleErrorCode, WebCapsuleFormatError } from "./errors.js";
import { parseJsonWithoutDuplicateKeys } from "./parsers.js";
import type {
  CapsuleFileEntry,
  CapsuleManifest,
  CapsulePolicy,
  UnsignedUpdateIndex,
  UpdateIndex,
  UpdateRelease,
} from "./types.js";
import {
  assertCapsuleId,
  assertFileSize,
  assertKeyId,
  assertMediaType,
  assertSafePath,
  assertSafePathSet,
  assertSha256,
  assertVersion,
  compareVersions,
} from "./validators.js";

const TIMESTAMP_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:(\d{2})Z$/;
const CHANNEL_PATTERN = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const CAPABILITY_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const STANDARD_BASE64_PATTERN = /^(?:[A-Za-z0-9+/]{4}){21}[A-Za-z0-9+/]{2}==$/;

function fail(code: WebCapsuleErrorCode, message: string): never {
  throw new WebCapsuleFormatError(code, message);
}

function object(
  value: unknown,
  keys: readonly string[],
  label: string,
): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    fail(WebCapsuleErrorCode.InvalidJsonValue, `${label} must be an object`);
  }
  const record = value as Record<string, unknown>;
  const actual = Object.keys(record);
  if (
    actual.length !== keys.length ||
    actual.some((key) => !keys.includes(key))
  ) {
    fail(
      WebCapsuleErrorCode.InvalidJsonValue,
      `${label} has missing or extra properties`,
    );
  }
  return record;
}

function string(value: unknown, label: string): string {
  if (typeof value !== "string")
    fail(WebCapsuleErrorCode.InvalidJsonValue, `${label} must be a string`);
  return value;
}

function array(value: unknown, label: string): readonly unknown[] {
  if (!Array.isArray(value))
    fail(WebCapsuleErrorCode.InvalidJsonValue, `${label} must be an array`);
  return value;
}

function integer(value: unknown, label: string): number {
  if (!Number.isSafeInteger(value))
    fail(
      WebCapsuleErrorCode.InvalidJsonValue,
      `${label} must be a safe integer`,
    );
  return value as number;
}

export function assertBuildTimestamp(value: string): void {
  const match = TIMESTAMP_PATTERN.exec(value);
  if (
    match === null ||
    Number(match[1]) % 2 !== 0 ||
    new Date(value).toISOString().replace(".000Z", "Z") !== value
  ) {
    fail(
      WebCapsuleErrorCode.InvalidTimestamp,
      "Timestamp must be a valid YYYY-MM-DDTHH:mm:ssZ value with an even second",
    );
  }
}

function assertHttpsOrigin(value: string): void {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    fail(WebCapsuleErrorCode.InvalidUrl, `Invalid HTTPS origin: ${value}`);
  }
  if (
    url.protocol !== "https:" ||
    url.origin !== value ||
    url.username !== "" ||
    url.password !== ""
  ) {
    fail(WebCapsuleErrorCode.InvalidUrl, `Invalid HTTPS origin: ${value}`);
  }
}

function assertHttpsUrl(value: string): void {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    fail(WebCapsuleErrorCode.InvalidUrl, `Invalid HTTPS URL: ${value}`);
  }
  if (url.protocol !== "https:" || url.username !== "" || url.password !== "")
    fail(WebCapsuleErrorCode.InvalidUrl, `Invalid HTTPS URL: ${value}`);
}

function parseStringArray(
  value: unknown,
  label: string,
  validate: (item: string) => void,
): readonly string[] {
  const result = array(value, label).map((item) => string(item, label));
  const seen = new Set<string>();
  for (const item of result) {
    validate(item);
    if (seen.has(item))
      fail(
        WebCapsuleErrorCode.InvalidPolicy,
        `${label} contains a duplicate value`,
      );
    seen.add(item);
  }
  return result;
}

function parsePolicy(value: unknown): CapsulePolicy {
  const policy = object(
    value,
    ["network", "navigation", "bridgeCapabilities"],
    "policy",
  );
  const networkValue = policy.network;
  if (
    networkValue === null ||
    typeof networkValue !== "object" ||
    Array.isArray(networkValue)
  )
    fail(WebCapsuleErrorCode.InvalidPolicy, "policy.network must be an object");
  const networkRecord = networkValue as Record<string, unknown>;
  const mode = string(networkRecord.mode, "policy.network.mode");
  let network: CapsulePolicy["network"];
  if (mode === "deny") {
    object(networkValue, ["mode"], "policy.network");
    network = { mode: "deny" };
  } else if (mode === "allowlist") {
    object(networkValue, ["mode", "origins"], "policy.network");
    network = {
      mode: "allowlist",
      origins: parseStringArray(
        networkRecord.origins,
        "policy.network.origins",
        assertHttpsOrigin,
      ),
    };
  } else fail(WebCapsuleErrorCode.InvalidPolicy, "Unknown network policy mode");

  const navigation = object(
    policy.navigation,
    ["externalOrigins"],
    "policy.navigation",
  );
  const externalOrigins = parseStringArray(
    navigation.externalOrigins,
    "policy.navigation.externalOrigins",
    assertHttpsOrigin,
  );
  const bridgeCapabilities = parseStringArray(
    policy.bridgeCapabilities,
    "policy.bridgeCapabilities",
    (capability) => {
      if (!CAPABILITY_PATTERN.test(capability))
        fail(
          WebCapsuleErrorCode.InvalidPolicy,
          `Invalid bridge capability: ${capability}`,
        );
    },
  );
  return { network, navigation: { externalOrigins }, bridgeCapabilities };
}

function parseFile(value: unknown): CapsuleFileEntry {
  const file = object(
    value,
    ["path", "sha256", "size", "mediaType"],
    "file entry",
  );
  const path = string(file.path, "file.path");
  assertSafePath(path);
  const sha256 = string(file.sha256, "file.sha256");
  assertSha256(sha256);
  const size = integer(file.size, "file.size");
  assertFileSize(size);
  const mediaType = string(file.mediaType, "file.mediaType");
  assertMediaType(mediaType);
  return { path, sha256, size, mediaType };
}

export function parseCapsuleManifest(value: unknown): CapsuleManifest {
  const manifest = object(
    value,
    [
      "formatVersion",
      "capsuleId",
      "version",
      "entry",
      "createdAt",
      "minimumRuntimeVersion",
      "keyId",
      "files",
      "policy",
    ],
    "manifest",
  );
  if (manifest.formatVersion !== FORMAT_VERSION)
    fail(
      WebCapsuleErrorCode.UnsupportedFormatVersion,
      "Unsupported manifest formatVersion",
    );
  const capsuleId = string(manifest.capsuleId, "capsuleId");
  assertCapsuleId(capsuleId);
  const version = string(manifest.version, "version");
  assertVersion(version);
  const entry = string(manifest.entry, "entry");
  assertSafePath(entry);
  const createdAt = string(manifest.createdAt, "createdAt");
  assertBuildTimestamp(createdAt);
  const minimumRuntimeVersion = string(
    manifest.minimumRuntimeVersion,
    "minimumRuntimeVersion",
  );
  assertVersion(minimumRuntimeVersion);
  const keyId = string(manifest.keyId, "keyId");
  assertKeyId(keyId);
  const files = array(manifest.files, "files").map(parseFile);
  assertSafePathSet(files.map((file) => file.path));
  for (let index = 1; index < files.length; index += 1) {
    if (
      Buffer.compare(
        Buffer.from(files[index - 1]!.path),
        Buffer.from(files[index]!.path),
      ) >= 0
    )
      fail(
        WebCapsuleErrorCode.InvalidOrder,
        "Manifest files must be in ascending UTF-8 byte order",
      );
  }
  if (!files.some((file) => file.path === entry))
    fail(
      WebCapsuleErrorCode.InvalidManifest,
      "entry must reference a manifest file",
    );
  const total = files.reduce((sum, file) => sum + file.size, 0);
  if (!Number.isSafeInteger(total) || total > CAPSULE_LIMITS.expandedBytes)
    fail(WebCapsuleErrorCode.LimitExceeded, "Expanded content limit exceeded");
  return {
    formatVersion: FORMAT_VERSION,
    capsuleId,
    version,
    entry,
    createdAt,
    minimumRuntimeVersion,
    keyId,
    files,
    policy: parsePolicy(manifest.policy),
  };
}

export function parseUpdateRelease(value: unknown): UpdateRelease {
  const release = object(
    value,
    ["version", "url", "sha256", "size", "minimumRuntimeVersion"],
    "release",
  );
  const version = string(release.version, "release.version");
  assertVersion(version);
  const url = string(release.url, "release.url");
  assertHttpsUrl(url);
  const sha256 = string(release.sha256, "release.sha256");
  assertSha256(sha256);
  const size = integer(release.size, "release.size");
  if (size < 0 || size > CAPSULE_LIMITS.archiveBytes)
    fail(WebCapsuleErrorCode.LimitExceeded, "Invalid release archive size");
  const minimumRuntimeVersion = string(
    release.minimumRuntimeVersion,
    "release.minimumRuntimeVersion",
  );
  assertVersion(minimumRuntimeVersion);
  return { version, url, sha256, size, minimumRuntimeVersion };
}

function parseIndex(value: unknown, signed: false): UnsignedUpdateIndex;
function parseIndex(value: unknown, signed: true): UpdateIndex;
function parseIndex(
  value: unknown,
  signed: boolean,
): UnsignedUpdateIndex | UpdateIndex {
  const keys = signed
    ? [
        "schemaVersion",
        "capsuleId",
        "channel",
        "releases",
        "keyId",
        "signature",
      ]
    : ["schemaVersion", "capsuleId", "channel", "releases", "keyId"];
  const index = object(value, keys, "update index");
  if (index.schemaVersion !== UPDATE_INDEX_SCHEMA_VERSION)
    fail(
      WebCapsuleErrorCode.InvalidUpdateIndex,
      "Unsupported update index schemaVersion",
    );
  const capsuleId = string(index.capsuleId, "capsuleId");
  assertCapsuleId(capsuleId);
  const channel = string(index.channel, "channel");
  if (!CHANNEL_PATTERN.test(channel))
    fail(WebCapsuleErrorCode.InvalidUpdateIndex, "Invalid update channel");
  const releases = array(index.releases, "releases").map(parseUpdateRelease);
  if (releases.length === 0)
    fail(
      WebCapsuleErrorCode.InvalidUpdateIndex,
      "Update index must contain at least one release",
    );
  for (let position = 1; position < releases.length; position += 1) {
    const comparison = compareVersions(
      releases[position - 1]!.version,
      releases[position]!.version,
    );
    if (comparison === 0)
      fail(
        WebCapsuleErrorCode.InvalidUpdateIndex,
        "Duplicate SemVer-equivalent release version",
      );
    if (comparison < 0)
      fail(
        WebCapsuleErrorCode.InvalidOrder,
        "Releases must be ordered by descending SemVer precedence",
      );
  }
  const keyId = string(index.keyId, "keyId");
  assertKeyId(keyId);
  const unsigned = {
    schemaVersion: UPDATE_INDEX_SCHEMA_VERSION,
    capsuleId,
    channel,
    releases,
    keyId,
  };
  if (!signed) return unsigned;
  const signature = string(index.signature, "signature");
  if (
    !STANDARD_BASE64_PATTERN.test(signature) ||
    Buffer.from(signature, "base64").length !== 64
  )
    fail(
      WebCapsuleErrorCode.InvalidSignature,
      "signature must be standard Base64 encoding of 64 bytes",
    );
  return { ...unsigned, signature };
}

export function parseUnsignedUpdateIndex(value: unknown): UnsignedUpdateIndex {
  return parseIndex(value, false);
}

export function parseUpdateIndex(value: unknown): UpdateIndex {
  return parseIndex(value, true);
}

export function parseCapsuleManifestJson(text: string): CapsuleManifest {
  return parseCapsuleManifest(parseJsonWithoutDuplicateKeys(text));
}

export function parseUpdateReleaseJson(text: string): UpdateRelease {
  return parseUpdateRelease(parseJsonWithoutDuplicateKeys(text));
}

export function parseUnsignedUpdateIndexJson(
  text: string,
): UnsignedUpdateIndex {
  return parseUnsignedUpdateIndex(parseJsonWithoutDuplicateKeys(text));
}

export function parseUpdateIndexJson(text: string): UpdateIndex {
  return parseUpdateIndex(parseJsonWithoutDuplicateKeys(text));
}
