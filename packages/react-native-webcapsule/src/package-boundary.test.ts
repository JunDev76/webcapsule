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

  it("keeps the iOS component, props, and direct events aligned with TypeScript", async () => {
    const [typescript, swift] = await Promise.all([
      readFile(resolve(root, "src/index.ts"), "utf8"),
      readFile(
        resolve(
          root,
          "ios/Sources/WebCapsuleCore/ReactNativeWebCapsuleView.swift",
        ),
        "utf8",
      ),
    ]);
    expect(typescript).toContain(
      'requireNativeComponent<WebCapsuleViewProps>("WebCapsuleView")',
    );
    for (const prop of [
      "capsuleId",
      "bundledAssetPath",
      "publicKeys",
      "runtimeVersion",
    ]) {
      expect(typescript).toContain(`readonly ${prop}:`);
      expect(swift).toContain(`propConfig_${prop}()`);
    }
    for (const event of ["onLoad", "onError", "onRollback"]) {
      expect(typescript).toContain(`readonly ${event}?:`);
      expect(swift).toContain(`propConfig_${event}()`);
      expect(swift).toContain(`var ${event}: RCTDirectEventBlock?`);
    }
  });
});
