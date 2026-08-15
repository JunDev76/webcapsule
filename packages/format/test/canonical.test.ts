import { describe, expect, it } from "vitest";

import {
  canonicalJson,
  createManifestSignaturePayload,
  createUpdateIndexSignaturePayload,
  WebCapsuleErrorCode,
  WebCapsuleFormatError,
  withoutUpdateIndexSignature,
  type CapsuleManifest,
  type UpdateIndex,
} from "../src/index.js";

const manifest: CapsuleManifest = {
  formatVersion: 1,
  capsuleId: "com.example.guide",
  version: "1.0.0",
  entry: "index.html",
  createdAt: "2026-08-14T00:00:00Z",
  minimumRuntimeVersion: "1.0.0",
  keyId: "release-2026",
  files: [],
  policy: {
    network: { mode: "deny" },
    navigation: { externalOrigins: [] },
    bridgeCapabilities: [],
  },
};

const index: UpdateIndex = {
  schemaVersion: 1,
  capsuleId: "com.example.guide",
  channel: "stable",
  releases: [],
  keyId: "release-2026",
  signature: "A".repeat(88),
};

const decode = (value: Uint8Array): string => new TextDecoder().decode(value);

describe("canonical JSON", () => {
  it("sorts object properties recursively", () => {
    expect(canonicalJson({ z: 1, a: { y: 2, b: 3 } })).toBe(
      '{"a":{"b":3,"y":2},"z":1}',
    );
  });

  it("uses RFC 8785 number serialization", () => {
    expect(canonicalJson({ value: 1e30 })).toBe('{"value":1e+30}');
  });

  it.each([
    { value: Number.NaN },
    { value: undefined },
    { value: 1n },
    { value: new Date("2026-08-14T00:00:00Z") },
  ])("rejects values outside the JSON data model", (value) => {
    expect(() => canonicalJson(value)).toThrowError(WebCapsuleFormatError);
    try {
      canonicalJson(value);
    } catch (error: unknown) {
      expect(error).toMatchObject({
        code: WebCapsuleErrorCode.InvalidJsonValue,
      });
    }
  });

  it("rejects cyclic objects", () => {
    const value: { self?: unknown } = {};
    value.self = value;
    expect(() => canonicalJson(value)).toThrowError(WebCapsuleFormatError);
  });
});

describe("signature payloads", () => {
  it("prefixes canonical manifest bytes with the manifest domain", () => {
    const payload = decode(createManifestSignaturePayload(manifest));
    expect(payload.startsWith("WEBCAPSULE-MANIFEST-V1\n{")).toBe(true);
    expect(payload).toContain('"capsuleId":"com.example.guide"');
  });

  it("omits an update index signature before canonicalization", () => {
    const unsigned = withoutUpdateIndexSignature(index);
    expect(unsigned).not.toHaveProperty("signature");
    expect(decode(createUpdateIndexSignaturePayload(index))).toBe(
      decode(createUpdateIndexSignaturePayload(unsigned)),
    );
  });
});
