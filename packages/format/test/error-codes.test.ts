import { describe, expect, it } from "vitest";

import { WebCapsuleErrorCode } from "../src/index.js";

const androidRuntimeCodes = [
  "BUNDLED_SOURCE_INVALID",
  "BUNDLED_CAPSULE_UNAVAILABLE",
  "STORAGE_IO_FAILED",
  "STORAGE_INVARIANT_VIOLATION",
  "REGISTRY_INVALID",
  "REGISTRY_RECOVERY_FAILED",
  "VERSION_RECORD_INVALID",
  "BLOB_MISSING",
  "INSTALL_FAILED",
  "LOCK_FAILED",
  "NO_RUNNABLE_VERSION",
  "SESSION_MISMATCH",
  "RESOURCE_DENIED",
  "ENTRY_LOAD_FAILED",
  "READY_MESSAGE_INVALID",
  "READY_TIMEOUT",
  "STABILIZATION_FAILED",
] as const;

const cliCodes = [
  "OUTPUT_EXISTS",
  "KEY_GENERATION_FAILED",
  "INVALID_ARGUMENT",
  "INVALID_TIMESTAMP",
  "INVALID_INPUT",
  "INVALID_PRIVATE_KEY",
  "INVALID_PUBLIC_KEY",
  "LIMIT_EXCEEDED",
  "BUILD_FAILED",
  "ARCHIVE_INVALID",
  "INVALID_ARCHIVE_PROFILE",
  "SIGNATURE_MISMATCH",
  "HASH_MISMATCH",
  "ID_MISMATCH",
  "KEY_ID_MISMATCH",
  "RUNTIME_INCOMPATIBLE",
] as const;

describe("shared error taxonomy", () => {
  it("keeps Android runtime strings stable", () => {
    const values = new Set<string>(Object.values(WebCapsuleErrorCode));
    expect(androidRuntimeCodes.every((code) => values.has(code))).toBe(true);
  });

  it("contains the existing CLI output strings", () => {
    const values = new Set<string>(Object.values(WebCapsuleErrorCode));
    expect(cliCodes.every((code) => values.has(code))).toBe(true);
  });

  it("contains no duplicate strings", () => {
    const values = Object.values(WebCapsuleErrorCode);
    expect(new Set(values).size).toBe(values.length);
  });
});
