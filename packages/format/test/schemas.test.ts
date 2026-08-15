import { describe, expect, it } from "vitest";

import { capsuleManifestSchema, updateIndexSchema } from "../src/index.js";

describe("public JSON schemas", () => {
  it("publish stable schema IDs and strict roots", () => {
    expect(capsuleManifestSchema.$id).toBe(
      "urn:webcapsule:schema:capsule-manifest:v1",
    );
    expect(capsuleManifestSchema.additionalProperties).toBe(false);
    expect(updateIndexSchema.$id).toBe("urn:webcapsule:schema:update-index:v1");
    expect(updateIndexSchema.additionalProperties).toBe(false);
  });
});
