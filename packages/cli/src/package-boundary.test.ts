import { readFile, readdir } from "node:fs/promises";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

describe("published package boundary", () => {
  it("contains only dist and cannot package the TEST ONLY private key", async () => {
    const root = resolve(import.meta.dirname, "..");
    const pkg = JSON.parse(
      await readFile(resolve(root, "package.json"), "utf8"),
    ) as { files: string[] };
    expect(pkg.files).toEqual(["dist"]);
    expect(
      (await readdir(root, { recursive: true })).some((path) =>
        path.endsWith("test-only-private.pem"),
      ),
    ).toBe(false);
  });
});
