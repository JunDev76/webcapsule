import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
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
    readonly runtimeVersion: string;
    readonly trustedPublicKey: string;
    readonly trustedKeyId?: string;
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
      runtimeVersion: v.runtimeVersion,
    });
    if (fixture.accepted)
      await expect(promise).resolves.toMatchObject({
        capsuleId: v.expectedCapsuleId,
      });
    else
      await expect(promise).rejects.toMatchObject({ code: fixture.errorCode });
  });
});
