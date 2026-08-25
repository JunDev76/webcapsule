import { beforeEach, describe, expect, it, vi } from "vitest";

const nativeInstall = vi.fn();
const reactNative = {
  NativeModules: {
    WebCapsuleUpdate: { installWebCapsuleUpdate: nativeInstall },
  },
  Platform: { OS: "android" },
  requireNativeComponent: vi.fn(() => "WebCapsuleView"),
};
vi.mock("react-native", () => reactNative);

const options = {
  capsuleId: "com.example.fixture",
  bundledAssetPath: "webcapsule/v1.capsule",
  publicKeys: { release: "pem" },
  runtimeVersion: "1.0.0",
  indexUrl: "https://example.com/index.json",
  channel: "stable",
} as const;

describe("installWebCapsuleUpdate", () => {
  beforeEach(() => {
    nativeInstall.mockReset();
    reactNative.Platform.OS = "android";
    reactNative.NativeModules.WebCapsuleUpdate = {
      installWebCapsuleUpdate: nativeInstall,
    };
  });

  it("forwards exact options and validates installed result", async () => {
    const result = {
      status: "installed",
      previousVersion: "1.0.0",
      currentVersion: "2.0.0",
      highestSeenVersion: "2.0.0",
      generation: "3",
    };
    nativeInstall.mockResolvedValue(result);
    const { installWebCapsuleUpdate } = await import("./index.js");
    await expect(installWebCapsuleUpdate(options)).resolves.toEqual(result);
    expect(nativeInstall).toHaveBeenCalledWith(options);
  });

  it("accepts exact up-to-date result", async () => {
    const result = {
      status: "up-to-date",
      currentVersion: "1.0.0",
      highestSeenVersion: "1.0.0",
      generation: "2",
    };
    nativeInstall.mockResolvedValue(result);
    const { installWebCapsuleUpdate } = await import("./index.js");
    await expect(installWebCapsuleUpdate(options)).resolves.toEqual(result);
  });

  it("forwards exact options on iOS", async () => {
    const result = {
      status: "up-to-date",
      currentVersion: "1.0.0",
      highestSeenVersion: "1.0.0",
      generation: "2",
    };
    reactNative.Platform.OS = "ios";
    nativeInstall.mockResolvedValue(result);
    const { installWebCapsuleUpdate } = await import("./index.js");
    await expect(installWebCapsuleUpdate(options)).resolves.toEqual(result);
    expect(nativeInstall).toHaveBeenCalledWith(options);
  });

  it("rejects unsupported platforms and missing native module", async () => {
    const { installWebCapsuleUpdate } = await import("./index.js");
    reactNative.Platform.OS = "web";
    await expect(installWebCapsuleUpdate(options)).rejects.toThrow(
      "WEBCAPSULE_UNSUPPORTED_PLATFORM",
    );
    reactNative.Platform.OS = "ios";
    // @ts-expect-error exercising a missing native module
    reactNative.NativeModules.WebCapsuleUpdate = undefined;
    await expect(installWebCapsuleUpdate(options)).rejects.toThrow(
      "WEBCAPSULE_NATIVE_MODULE_MISSING",
    );
  });

  it("rejects malformed native results and preserves native errors", async () => {
    const { installWebCapsuleUpdate } = await import("./index.js");
    nativeInstall.mockResolvedValue({
      status: "installed",
      currentVersion: "2.0.0",
    });
    await expect(installWebCapsuleUpdate(options)).rejects.toThrow(
      "Native update result",
    );
    const nativeError = Object.assign(new Error("timeout"), {
      code: "NETWORK_TIMEOUT",
    });
    nativeInstall.mockRejectedValue(nativeError);
    await expect(installWebCapsuleUpdate(options)).rejects.toBe(nativeError);
  });
});
