import semver from "semver";

import { CAPSULE_LIMITS } from "./constants.js";
import { WebCapsuleErrorCode, WebCapsuleFormatError } from "./errors.js";

const CAPSULE_ID_PATTERN = /^[a-z0-9]+(?:[.-][a-z0-9]+)+$/;
const KEY_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const MEDIA_TYPE_PATTERN = /^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/i;
const ENCODED_SEPARATOR_PATTERN = /%(?:2f|5c)/i;

function hasControlCharacter(value: string): boolean {
  return [...value].some((character) => {
    const codePoint = character.codePointAt(0);
    return codePoint !== undefined && (codePoint <= 0x1f || codePoint === 0x7f);
  });
}

function fail(code: WebCapsuleErrorCode, message: string): never {
  throw new WebCapsuleFormatError(code, message);
}

export function assertCapsuleId(value: string): void {
  if (value.length > 255 || !CAPSULE_ID_PATTERN.test(value)) {
    fail(WebCapsuleErrorCode.InvalidCapsuleId, `Invalid capsule ID: ${value}`);
  }
}

export function assertKeyId(value: string): void {
  if (!KEY_ID_PATTERN.test(value)) {
    fail(WebCapsuleErrorCode.InvalidKeyId, `Invalid key ID: ${value}`);
  }
}

export function assertVersion(value: string): void {
  if (value.startsWith("v") || semver.parse(value)?.raw !== value) {
    fail(
      WebCapsuleErrorCode.InvalidVersion,
      `Invalid SemVer version: ${value}`,
    );
  }
}

export function compareVersions(left: string, right: string): number {
  assertVersion(left);
  assertVersion(right);
  return semver.compare(left, right);
}

export function assertSha256(value: string): void {
  if (!SHA256_PATTERN.test(value)) {
    fail(
      WebCapsuleErrorCode.InvalidHash,
      "SHA-256 must be lowercase hexadecimal",
    );
  }
}

export function assertMediaType(value: string): void {
  if (!MEDIA_TYPE_PATTERN.test(value)) {
    fail(WebCapsuleErrorCode.InvalidMediaType, `Invalid media type: ${value}`);
  }
}

export function assertSafePath(value: string): void {
  if (
    value.length === 0 ||
    value.startsWith("/") ||
    value.endsWith("/") ||
    value.includes("\\") ||
    hasControlCharacter(value) ||
    ENCODED_SEPARATOR_PATTERN.test(value) ||
    value.normalize("NFC") !== value
  ) {
    fail(WebCapsuleErrorCode.InvalidPath, `Unsafe path: ${value}`);
  }

  const segments = value.split("/");
  if (
    segments.some(
      (segment) => segment === "" || segment === "." || segment === "..",
    )
  ) {
    fail(WebCapsuleErrorCode.InvalidPath, `Unsafe path: ${value}`);
  }
}

export function assertSafePathSet(paths: readonly string[]): void {
  if (paths.length > CAPSULE_LIMITS.fileCount) {
    fail(WebCapsuleErrorCode.LimitExceeded, "File count limit exceeded");
  }

  const exact = new Set<string>();
  const folded = new Map<string, string>();
  const normalized = new Map<string, string>();

  for (const path of paths) {
    const normalizedPath = path.normalize("NFC");
    const normalizedExisting = normalized.get(normalizedPath);
    if (normalizedExisting !== undefined && normalizedExisting !== path) {
      fail(
        WebCapsuleErrorCode.UnicodeCollision,
        `${normalizedExisting} conflicts with ${path}`,
      );
    }
    normalized.set(normalizedPath, path);

    assertSafePath(path);
    if (exact.has(path)) {
      fail(WebCapsuleErrorCode.DuplicatePath, `Duplicate path: ${path}`);
    }
    exact.add(path);

    const foldedPath = path.replace(/[A-Z]/g, (character) =>
      character.toLowerCase(),
    );
    const foldedExisting = folded.get(foldedPath);
    if (foldedExisting !== undefined && foldedExisting !== path) {
      fail(
        WebCapsuleErrorCode.CaseCollision,
        `${foldedExisting} conflicts with ${path}`,
      );
    }
    folded.set(foldedPath, path);
  }
}

export function assertFileSize(size: number): void {
  if (
    !Number.isSafeInteger(size) ||
    size < 0 ||
    size > CAPSULE_LIMITS.fileBytes
  ) {
    fail(WebCapsuleErrorCode.LimitExceeded, `Invalid file size: ${size}`);
  }
}
