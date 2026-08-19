import type {
  HostComponent,
  NativeSyntheticEvent,
  ViewProps,
} from "react-native";
import { NativeModules, Platform, requireNativeComponent } from "react-native";

export interface WebCapsuleLoadEvent {
  readonly capsuleId: string;
  readonly version: string;
}

export interface WebCapsuleErrorEvent {
  readonly code: string;
  readonly message: string;
}

export interface WebCapsuleViewProps extends ViewProps {
  readonly capsuleId: string;
  readonly bundledAssetPath: string;
  readonly publicKeys: Readonly<Record<string, string>>;
  readonly runtimeVersion: string;
  readonly onLoad?: (event: NativeSyntheticEvent<WebCapsuleLoadEvent>) => void;
  readonly onError?: (
    event: NativeSyntheticEvent<WebCapsuleErrorEvent>,
  ) => void;
}

export interface InstallWebCapsuleUpdateOptions {
  readonly capsuleId: string;
  readonly bundledAssetPath: string;
  readonly publicKeys: Readonly<Record<string, string>>;
  readonly runtimeVersion: string;
  readonly indexUrl: string;
  readonly channel: string;
}

export type InstallWebCapsuleUpdateResult =
  | {
      readonly status: "installed";
      readonly previousVersion: string;
      readonly currentVersion: string;
      readonly highestSeenVersion: string;
      readonly generation: string;
    }
  | {
      readonly status: "up-to-date";
      readonly currentVersion: string;
      readonly highestSeenVersion: string;
      readonly generation: string;
    };

interface NativeUpdateModule {
  installWebCapsuleUpdate(
    options: InstallWebCapsuleUpdateOptions,
  ): Promise<unknown>;
}

export const WebCapsuleView: HostComponent<WebCapsuleViewProps> =
  requireNativeComponent<WebCapsuleViewProps>("WebCapsuleView");

export async function installWebCapsuleUpdate(
  options: InstallWebCapsuleUpdateOptions,
): Promise<InstallWebCapsuleUpdateResult> {
  if (Platform.OS !== "android") {
    throw new Error(
      "WEBCAPSULE_ANDROID_ONLY: updates are supported only on Android",
    );
  }
  validateOptions(options);
  const module = NativeModules.WebCapsuleUpdate as
    NativeUpdateModule | undefined;
  if (module === undefined) {
    throw new Error(
      "WEBCAPSULE_NATIVE_MODULE_MISSING: WebCapsuleUpdate is not linked",
    );
  }
  return validateResult(await module.installWebCapsuleUpdate(options));
}

function validateOptions(options: InstallWebCapsuleUpdateOptions): void {
  const values = [
    options.capsuleId,
    options.bundledAssetPath,
    options.runtimeVersion,
    options.indexUrl,
    options.channel,
  ];
  if (values.some((value) => typeof value !== "string" || value.length === 0)) {
    throw new TypeError("WebCapsule update string options must be non-empty");
  }
  if (
    typeof options.publicKeys !== "object" ||
    options.publicKeys === null ||
    Array.isArray(options.publicKeys) ||
    Object.keys(options.publicKeys).length === 0 ||
    Object.values(options.publicKeys).some(
      (value) => typeof value !== "string" || value.length === 0,
    )
  ) {
    throw new TypeError("publicKeys must be a non-empty string record");
  }
}

function validateResult(value: unknown): InstallWebCapsuleUpdateResult {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    throw new TypeError("Native update result must be an object");
  const result = value as Record<string, unknown>;
  const common = ["currentVersion", "highestSeenVersion", "generation"];
  if (
    common.some(
      (key) => typeof result[key] !== "string" || result[key].length === 0,
    ) ||
    !/^(0|[1-9][0-9]*)$/.test(String(result.generation))
  ) {
    throw new TypeError("Native update result fields are invalid");
  }
  if (
    result.status === "installed" &&
    Object.keys(result).sort().join(",") ===
      ["status", "previousVersion", ...common].sort().join(",") &&
    typeof result.previousVersion === "string" &&
    result.previousVersion.length > 0
  )
    return result as InstallWebCapsuleUpdateResult;
  if (
    result.status === "up-to-date" &&
    Object.keys(result).sort().join(",") ===
      ["status", ...common].sort().join(",")
  )
    return result as InstallWebCapsuleUpdateResult;
  throw new TypeError("Native update result shape is invalid");
}
