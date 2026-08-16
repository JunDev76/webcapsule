import { describe, expect, it } from "vitest";

import {
  CAPSULE_LIMITS,
  compareVersions,
  WebCapsuleErrorCode,
  assertCapsuleId,
  assertFileSize,
  assertKeyId,
  assertMediaType,
  assertSafePath,
  assertSafePathSet,
  assertSha256,
  assertVersion,
} from "../src/index.js";

function expectCode(action: () => void, code: WebCapsuleErrorCode): void {
  try {
    action();
    throw new Error("Expected validation to fail");
  } catch (error: unknown) {
    expect(error).toMatchObject({ code });
  }
}

describe("identifier validation", () => {
  it("accepts stable capsule and key IDs", () => {
    expect(() => assertCapsuleId("com.example.guide")).not.toThrow();
    expect(() => assertKeyId("release-2026.1")).not.toThrow();
  });

  it("rejects malformed identifiers", () => {
    expectCode(
      () => assertCapsuleId("Example"),
      WebCapsuleErrorCode.InvalidCapsuleId,
    );
    expectCode(
      () => assertKeyId("release key"),
      WebCapsuleErrorCode.InvalidKeyId,
    );
  });
});

describe("field validation", () => {
  it("validates strict SemVer and comparison", () => {
    expect(() => assertVersion("1.2.3-beta.1")).not.toThrow();
    expect(compareVersions("1.2.3", "1.2.2")).toBeGreaterThan(0);
    expectCode(
      () => assertVersion("v1.2.3"),
      WebCapsuleErrorCode.InvalidVersion,
    );
  });

  it("validates lowercase SHA-256 and media types", () => {
    expect(() => assertSha256("a".repeat(64))).not.toThrow();
    expect(() => assertMediaType("text/html")).not.toThrow();
    expectCode(
      () => assertSha256("A".repeat(64)),
      WebCapsuleErrorCode.InvalidHash,
    );
    expectCode(
      () => assertMediaType("html"),
      WebCapsuleErrorCode.InvalidMediaType,
    );
  });

  it("enforces file size limits", () => {
    expect(() => assertFileSize(CAPSULE_LIMITS.fileBytes)).not.toThrow();
    expectCode(
      () => assertFileSize(CAPSULE_LIMITS.fileBytes + 1),
      WebCapsuleErrorCode.LimitExceeded,
    );
  });
});

describe("path validation", () => {
  it.each(["index.html", "assets/app.js", "한글/안내.html"])(
    "accepts %s",
    (path) => expect(() => assertSafePath(path)).not.toThrow(),
  );

  it.each([
    "",
    "/index.html",
    "assets/",
    "../secret",
    "assets/../secret",
    "./index.html",
    "assets\\app.js",
    "assets//app.js",
    "assets/%2fsecret",
    "nul\0path",
    "e\u0301.html",
  ])("rejects %s", (path) => {
    expectCode(() => assertSafePath(path), WebCapsuleErrorCode.InvalidPath);
  });

  it("rejects duplicate and case-colliding path sets", () => {
    expectCode(
      () => assertSafePathSet(["a.js", "a.js"]),
      WebCapsuleErrorCode.DuplicatePath,
    );
    expectCode(
      () => assertSafePathSet(["App.js", "app.js"]),
      WebCapsuleErrorCode.CaseCollision,
    );
    expect(() => assertSafePathSet(["Ä.js", "ä.js"])).not.toThrow();
    expectCode(
      () => assertSafePathSet(["é.html", "e\u0301.html"]),
      WebCapsuleErrorCode.UnicodeCollision,
    );
  });
});
