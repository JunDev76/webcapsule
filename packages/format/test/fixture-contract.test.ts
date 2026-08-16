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
  readonly path?: string;
  readonly value?: string;
  readonly accepted: boolean;
  readonly errorCode?: string;
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

  it.each(contract.fixtures)("matches $id", async (fixture) => {
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
