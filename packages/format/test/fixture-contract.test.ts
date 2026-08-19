import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import {
  WebCapsuleErrorCode,
  assertSafePath,
  parseCapsuleManifestJson,
  parseUpdateIndexJson,
} from "../src/index.js";

interface FixtureCase {
  readonly id: string;
  readonly kind: string;
  readonly path?: string;
  readonly value?: string;
  readonly accepted: boolean;
  readonly errorCode?: string;
  readonly platforms: readonly string[];
}
interface FixtureContract {
  readonly schemaVersion: number;
  readonly fixtures: readonly FixtureCase[];
}

const fixtureRoot = resolve(import.meta.dirname, "../../../fixtures");
const contract = JSON.parse(
  await readFile(resolve(fixtureRoot, "expected-results.json"), "utf8"),
) as FixtureContract;

describe("shared fixture contract", () => {
  it("uses the supported contract version", () => {
    expect(contract.schemaVersion).toBe(1);
  });

  it("has stable, executable contract metadata", () => {
    const ids = new Set<string>();
    for (const fixture of contract.fixtures) {
      expect(ids.has(fixture.id)).toBe(false);
      ids.add(fixture.id);
      expect([
        "manifest",
        "update-index",
        "signed-update-index",
        "path",
        "archive",
        "capsule",
        "registry",
        "version-record",
        "resource-request",
        "ready-message",
      ]).toContain(fixture.kind);
      expect(fixture.platforms.length).toBeGreaterThan(0);
      expect(fixture.platforms).toContain("typescript");
      expect(fixture.path === undefined).not.toBe(fixture.value === undefined);
      expect(fixture.accepted ? fixture.errorCode : undefined).toBeUndefined();
      if (!fixture.accepted) expect(fixture.errorCode).toBeDefined();
    }
  });

  it.each(
    contract.fixtures.filter(
      (fixture) =>
        fixture.kind !== "capsule" && fixture.kind !== "signed-update-index",
    ),
  )("matches $id", async (fixture) => {
    const run = async () => {
      if (fixture.value !== undefined) return assertSafePath(fixture.value);
      if (fixture.path === undefined) throw new Error("fixture has no input");
      const text = await readFile(resolve(fixtureRoot, fixture.path), "utf8");
      return fixture.id.includes("update-index")
        ? parseUpdateIndexJson(text)
        : parseCapsuleManifestJson(text);
    };
    if (fixture.accepted) await expect(run()).resolves.toBeDefined();
    else
      await expect(run()).rejects.toMatchObject({
        code: fixture.errorCode as WebCapsuleErrorCode,
      });
  });
});
