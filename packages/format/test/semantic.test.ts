import { describe, expect, it } from "vitest";

import {
  CAPSULE_LIMITS,
  WebCapsuleErrorCode,
  parseCapsuleManifest,
  parseCapsuleManifestJson,
  parseJsonWithoutDuplicateKeys,
  parseUnsignedUpdateIndex,
  parseUpdateIndex,
} from "../src/index.js";

const hash = "a".repeat(64);
const manifest = {
  formatVersion: 1,
  capsuleId: "com.example.guide",
  version: "1.0.0",
  entry: "index.html",
  createdAt: "2026-08-14T10:00:02Z",
  minimumRuntimeVersion: "1.0.0",
  keyId: "release-1",
  files: [
    { path: "index.html", sha256: hash, size: 12, mediaType: "text/html" },
  ],
  policy: {
    network: { mode: "allowlist", origins: ["https://api.example.com"] },
    navigation: { externalOrigins: ["https://example.com"] },
    bridgeCapabilities: ["storage.read"],
  },
};
const unsignedIndex = {
  schemaVersion: 1,
  capsuleId: "com.example.guide",
  channel: "stable",
  releases: [
    {
      version: "2.0.0",
      url: "https://example.com/2.capsule",
      sha256: hash,
      size: 100,
      minimumRuntimeVersion: "1.0.0",
    },
    {
      version: "1.0.0",
      url: "https://example.com/1.capsule",
      sha256: hash,
      size: 90,
      minimumRuntimeVersion: "1.0.0",
    },
  ],
  keyId: "release-1",
};

function expectCode(action: () => unknown, code: WebCapsuleErrorCode): void {
  try {
    action();
    throw new Error("Expected validation to fail");
  } catch (error: unknown) {
    expect(error).toMatchObject({ code });
  }
}

describe("strict JSON parsing", () => {
  it("rejects duplicate object keys", () => {
    expectCode(
      () => parseJsonWithoutDuplicateKeys('{"a":1,"a":2}'),
      WebCapsuleErrorCode.DuplicateJsonKey,
    );
  });
  it("parses and semantically validates manifest JSON", () => {
    expect(parseCapsuleManifestJson(JSON.stringify(manifest))).toEqual(
      manifest,
    );
  });
});

describe("manifest semantic validation", () => {
  it("accepts a complete exact manifest", () =>
    expect(parseCapsuleManifest(manifest)).toEqual(manifest));
  it.each([
    [
      "fractional timestamp",
      { ...manifest, createdAt: "2026-08-14T10:00:02.000Z" },
      WebCapsuleErrorCode.InvalidTimestamp,
    ],
    [
      "odd timestamp",
      { ...manifest, createdAt: "2026-08-14T10:00:03Z" },
      WebCapsuleErrorCode.InvalidTimestamp,
    ],
    [
      "missing entry",
      { ...manifest, entry: "missing.html" },
      WebCapsuleErrorCode.InvalidManifest,
    ],
    [
      "extra root property",
      { ...manifest, extra: true },
      WebCapsuleErrorCode.InvalidJsonValue,
    ],
    [
      "extra nested property",
      { ...manifest, files: [{ ...manifest.files[0], extra: true }] },
      WebCapsuleErrorCode.InvalidJsonValue,
    ],
    [
      "unordered paths",
      {
        ...manifest,
        entry: "b.html",
        files: [
          { path: "b.html", sha256: hash, size: 1, mediaType: "text/html" },
          { path: "a.html", sha256: hash, size: 1, mediaType: "text/html" },
        ],
      },
      WebCapsuleErrorCode.InvalidOrder,
    ],
    [
      "insecure origin",
      {
        ...manifest,
        policy: {
          ...manifest.policy,
          network: { mode: "allowlist", origins: ["http://api.example.com"] },
        },
      },
      WebCapsuleErrorCode.InvalidUrl,
    ],
    [
      "origin path",
      {
        ...manifest,
        policy: {
          ...manifest.policy,
          navigation: { externalOrigins: ["https://example.com/path"] },
        },
      },
      WebCapsuleErrorCode.InvalidUrl,
    ],
    [
      "duplicate capability",
      {
        ...manifest,
        policy: {
          ...manifest.policy,
          bridgeCapabilities: ["storage.read", "storage.read"],
        },
      },
      WebCapsuleErrorCode.InvalidPolicy,
    ],
  ] as const)("rejects %s", (_name, value, code) =>
    expectCode(() => parseCapsuleManifest(value), code),
  );

  it("enforces total expanded size", () => {
    const value = {
      ...manifest,
      files: Array.from({ length: 6 }, (_, index) => ({
        path: `${index}.bin`,
        sha256: hash,
        size: CAPSULE_LIMITS.fileBytes,
        mediaType: "application/octet-stream",
      })),
      entry: "0.bin",
    };
    expectCode(
      () => parseCapsuleManifest(value),
      WebCapsuleErrorCode.LimitExceeded,
    );
  });
});

describe("update index semantic validation", () => {
  it("accepts exact unsigned builder input", () =>
    expect(parseUnsignedUpdateIndex(unsignedIndex)).toEqual(unsignedIndex));
  it("accepts a standard Base64 64-byte signature", () => {
    const signed = {
      ...unsignedIndex,
      signature: Buffer.alloc(64).toString("base64"),
    };
    expect(parseUpdateIndex(signed)).toEqual(signed);
  });
  const signature = Buffer.alloc(64).toString("base64");
  it.each([
    ["missing signature", unsignedIndex, WebCapsuleErrorCode.InvalidJsonValue],
    [
      "invalid channel",
      { ...unsignedIndex, channel: "Stable Channel", signature },
      WebCapsuleErrorCode.InvalidUpdateIndex,
    ],
    [
      "duplicate versions",
      {
        ...unsignedIndex,
        releases: [unsignedIndex.releases[0], unsignedIndex.releases[0]],
        signature,
      },
      WebCapsuleErrorCode.InvalidUpdateIndex,
    ],
    [
      "ascending releases",
      {
        ...unsignedIndex,
        releases: [...unsignedIndex.releases].reverse(),
        signature,
      },
      WebCapsuleErrorCode.InvalidOrder,
    ],
    [
      "HTTP release",
      {
        ...unsignedIndex,
        releases: [
          { ...unsignedIndex.releases[0], url: "http://example.com/a" },
        ],
        signature,
      },
      WebCapsuleErrorCode.InvalidUrl,
    ],
    [
      "oversized release",
      {
        ...unsignedIndex,
        releases: [
          {
            ...unsignedIndex.releases[0],
            size: CAPSULE_LIMITS.archiveBytes + 1,
          },
        ],
        signature,
      },
      WebCapsuleErrorCode.LimitExceeded,
    ],
    [
      "short signature",
      { ...unsignedIndex, signature: Buffer.alloc(63).toString("base64") },
      WebCapsuleErrorCode.InvalidSignature,
    ],
  ] as const)("rejects %s", (_name, value, code) =>
    expectCode(() => parseUpdateIndex(value), code),
  );

  it("rejects signature as an extra unsigned builder property", () => {
    expectCode(
      () => parseUnsignedUpdateIndex({ ...unsignedIndex, signature }),
      WebCapsuleErrorCode.InvalidJsonValue,
    );
  });
});
