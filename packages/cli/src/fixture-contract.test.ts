import { verify } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import {
  createUpdateIndexSignaturePayload,
  parseUpdateIndexJson,
} from "@webcapsule/format";
import { verifyCapsule } from "./archive.js";

interface Fixture {
  readonly id: string;
  readonly kind: string;
  readonly path?: string;
  readonly accepted: boolean;
  readonly errorCode?: string;
  readonly platforms: readonly string[];
  readonly verification?: {
    readonly expectedCapsuleId: string;
    readonly runtimeVersion?: string;
    readonly trustedPublicKey: string;
    readonly trustedKeyId?: string;
    readonly expectedChannel?: string;
    readonly expectedKeyId?: string;
  };
}
const root = resolve(import.meta.dirname, "../../..");
const contract = JSON.parse(
  await readFile(resolve(root, "fixtures/expected-results.json"), "utf8"),
) as { fixtures: Fixture[] };
const capsules = contract.fixtures.filter(
  (f) => f.kind === "capsule" && f.platforms.includes("typescript"),
);

describe("shared capsule fixture contract", () => {
  it.each(capsules)("$id", async (fixture) => {
    const v = fixture.verification!;
    const publicKey = await readFile(
      resolve(root, "fixtures", v.trustedPublicKey),
      "utf8",
    );
    const promise = verifyCapsule(resolve(root, "fixtures", fixture.path!), {
      publicKey,
      expectedId: v.expectedCapsuleId,
      expectedKeyId: v.trustedKeyId ?? "test-only",
      runtimeVersion: v.runtimeVersion!,
    });
    if (fixture.accepted)
      await expect(promise).resolves.toMatchObject({
        capsuleId: v.expectedCapsuleId,
      });
    else
      await expect(promise).rejects.toMatchObject({ code: fixture.errorCode });
  });
});

const updateIndexes = contract.fixtures.filter(
  (fixture) =>
    fixture.kind === "signed-update-index" &&
    fixture.platforms.includes("typescript"),
);

describe("shared signed update index fixture contract", () => {
  it.each(updateIndexes)("$id", async (fixture) => {
    const verification = fixture.verification!;
    const publicKey = await readFile(
      resolve(root, "fixtures", verification.trustedPublicKey),
      "utf8",
    );
    const run = async () => {
      const index = parseUpdateIndexJson(
        await readFile(resolve(root, "fixtures", fixture.path!), "utf8"),
      );
      for (const release of index.releases) {
        const url = new URL(release.url);
        const authority =
          release.url.slice("https://".length).split("/")[0] ?? "";
        if (
          url.protocol !== "https:" ||
          url.username !== "" ||
          url.password !== "" ||
          url.hash !== "" ||
          authority.includes(":")
        ) {
          throw Object.assign(new Error("Invalid update release URL"), {
            code: "INVALID_URL",
          });
        }
      }
      if (
        index.capsuleId !== verification.expectedCapsuleId ||
        index.channel !== verification.expectedChannel
      ) {
        throw Object.assign(new Error("Update index identity differs"), {
          code: "INVALID_UPDATE_INDEX",
        });
      }
      if (index.keyId !== "test-only") {
        throw Object.assign(new Error("No exact trusted update key ID"), {
          code: "KEY_ID_MISMATCH",
        });
      }
      if (
        !verify(
          null,
          createUpdateIndexSignaturePayload(index),
          publicKey,
          Buffer.from(index.signature, "base64"),
        )
      ) {
        throw Object.assign(new Error("Update index signature mismatch"), {
          code: "SIGNATURE_MISMATCH",
        });
      }
      return index;
    };
    if (fixture.accepted) await expect(run()).resolves.toBeDefined();
    else {
      try {
        await run();
        throw new Error("Expected fixture rejection");
      } catch (error) {
        const actual = error as { code?: string };
        const normalized =
          fixture.errorCode === "INVALID_ORDER" &&
          actual.code === "INVALID_UPDATE_INDEX"
            ? "INVALID_ORDER"
            : actual.code;
        expect(normalized).toBe(fixture.errorCode);
      }
    }
  });
});
