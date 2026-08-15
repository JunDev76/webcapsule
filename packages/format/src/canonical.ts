import canonicalize from "canonicalize";

import {
  MANIFEST_SIGNATURE_DOMAIN,
  UPDATE_INDEX_SIGNATURE_DOMAIN,
} from "./constants.js";
import { WebCapsuleErrorCode, WebCapsuleFormatError } from "./errors.js";
import type {
  CapsuleManifest,
  UnsignedUpdateIndex,
  UpdateIndex,
} from "./types.js";

const encoder = new TextEncoder();

function assertJsonValue(value: unknown, ancestors: Set<object>): void {
  if (
    value === null ||
    typeof value === "string" ||
    typeof value === "boolean"
  ) {
    return;
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new WebCapsuleFormatError(
        WebCapsuleErrorCode.InvalidJsonValue,
        "Canonical JSON numbers must be finite",
      );
    }
    return;
  }
  if (typeof value !== "object") {
    throw new WebCapsuleFormatError(
      WebCapsuleErrorCode.InvalidJsonValue,
      "Value is outside the JSON data model",
    );
  }
  if (ancestors.has(value)) {
    throw new WebCapsuleFormatError(
      WebCapsuleErrorCode.InvalidJsonValue,
      "Canonical JSON cannot contain cycles",
    );
  }

  ancestors.add(value);
  if (Array.isArray(value)) {
    for (const item of value) {
      assertJsonValue(item, ancestors);
    }
  } else {
    const prototype: object | null = Object.getPrototypeOf(value) as
      object | null;
    if (prototype !== Object.prototype && prototype !== null) {
      throw new WebCapsuleFormatError(
        WebCapsuleErrorCode.InvalidJsonValue,
        "Canonical JSON objects must be plain objects",
      );
    }
    for (const item of Object.values(value)) {
      assertJsonValue(item, ancestors);
    }
  }
  ancestors.delete(value);
}

export function canonicalJson(value: unknown): string {
  try {
    assertJsonValue(value, new Set<object>());
    const result = canonicalize(value);
    if (result === undefined) {
      throw new WebCapsuleFormatError(
        WebCapsuleErrorCode.InvalidJsonValue,
        "Value cannot be represented as canonical JSON",
      );
    }
    return result;
  } catch (error: unknown) {
    if (error instanceof WebCapsuleFormatError) {
      throw error;
    }
    throw new WebCapsuleFormatError(
      WebCapsuleErrorCode.InvalidJsonValue,
      "Value cannot be represented as canonical JSON",
    );
  }
}

export function createManifestSignaturePayload(
  manifest: CapsuleManifest,
): Uint8Array {
  return encoder.encode(MANIFEST_SIGNATURE_DOMAIN + canonicalJson(manifest));
}

export function withoutUpdateIndexSignature(
  index: UpdateIndex,
): UnsignedUpdateIndex {
  return {
    schemaVersion: index.schemaVersion,
    capsuleId: index.capsuleId,
    channel: index.channel,
    releases: index.releases,
    keyId: index.keyId,
  };
}

export function createUpdateIndexSignaturePayload(
  index: UnsignedUpdateIndex | UpdateIndex,
): Uint8Array {
  const unsigned =
    "signature" in index ? withoutUpdateIndexSignature(index) : index;
  return encoder.encode(
    UPDATE_INDEX_SIGNATURE_DOMAIN + canonicalJson(unsigned),
  );
}
