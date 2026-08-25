import { beforeEach, describe, expect, it, vi } from "vitest";

const nativeState = vi.fn();
const reactNative = {
  NativeModules: {
    WebCapsuleState: { getWebCapsuleRuntimeState: nativeState },
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
} as const;

const state = {
  capsuleId: "com.example.fixture",
  activeVersion: "2.0.0",
  activeHealthy: false,
  previousVersion: "1.0.0",
  pending: { version: "2.0.0", attempts: "1" },
  highestSeenVersion: "2.0.0",
  blockedVersions: [],
  generation: "4",
};

describe("getWebCapsuleRuntimeState", () => {
  beforeEach(() => {
    nativeState.mockReset();
    reactNative.Platform.OS = "android";
    reactNative.NativeModules.WebCapsuleState = {
      getWebCapsuleRuntimeState: nativeState,
    };
  });

  it("forwards exact options and accepts the exact state shape", async () => {
    nativeState.mockResolvedValue(state);
    const { getWebCapsuleRuntimeState } = await import("./index.js");
    await expect(getWebCapsuleRuntimeState(options)).resolves.toEqual(state);
    expect(nativeState).toHaveBeenCalledWith(options);
  });

  it("rejects malformed state and option shapes", async () => {
    const { getWebCapsuleRuntimeState } = await import("./index.js");
    nativeState.mockResolvedValue({ ...state, extra: true });
    await expect(getWebCapsuleRuntimeState(options)).rejects.toThrow(
      "runtime state",
    );
    await expect(
      getWebCapsuleRuntimeState({ ...options, extra: true } as typeof options),
    ).rejects.toThrow("option fields");
  });

  it("forwards exact options on iOS", async () => {
    reactNative.Platform.OS = "ios";
    nativeState.mockResolvedValue(state);
    const { getWebCapsuleRuntimeState } = await import("./index.js");
    await expect(getWebCapsuleRuntimeState(options)).resolves.toEqual(state);
    expect(nativeState).toHaveBeenCalledWith(options);
  });

  it("rejects unsupported platform and missing module", async () => {
    const { getWebCapsuleRuntimeState } = await import("./index.js");
    reactNative.Platform.OS = "web";
    await expect(getWebCapsuleRuntimeState(options)).rejects.toThrow(
      "WEBCAPSULE_UNSUPPORTED_PLATFORM",
    );
    reactNative.Platform.OS = "ios";
    // @ts-expect-error exercising missing linkage
    reactNative.NativeModules.WebCapsuleState = undefined;
    await expect(getWebCapsuleRuntimeState(options)).rejects.toThrow(
      "WEBCAPSULE_NATIVE_MODULE_MISSING",
    );
  });
});
