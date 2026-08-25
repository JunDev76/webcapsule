import { readFile, readdir } from "node:fs/promises";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const root = resolve(import.meta.dirname, "..");

describe("React Native package boundary", () => {
  it("publishes only runtime sources and excludes test credentials", async () => {
    const pkg = JSON.parse(
      await readFile(resolve(root, "package.json"), "utf8"),
    ) as { files: string[] };
    expect(pkg.files).toEqual([
      "android/build.gradle",
      "android/consumer-rules.pro",
      "android/gradle.properties",
      "android/src/main",
      "dist",
      "ios/Sources/WebCapsuleCore",
      "react-native-webcapsule.podspec",
      "react-native.config.js",
    ]);
    const paths = await readdir(root, { recursive: true });
    expect(pkg.files.some((path) => path.includes("androidTest"))).toBe(false);
    expect(paths.some((path) => path.endsWith("test-only-private.pem"))).toBe(
      false,
    );
  });
});
