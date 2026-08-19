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

export interface WebCapsuleRollbackEvent {
  readonly capsuleId: string;
  readonly failedVersion: string;
  readonly restoredVersion: string | null;
  readonly reason: string;
  readonly generation: string;
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
  readonly onRollback?: (
    event: NativeSyntheticEvent<WebCapsuleRollbackEvent>,
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

export interface GetWebCapsuleRuntimeStateOptions {
  readonly capsuleId: string;
  readonly bundledAssetPath: string;
  readonly publicKeys: Readonly<Record<string, string>>;
  readonly runtimeVersion: string;
}

export interface WebCapsuleRuntimeState {
  readonly capsuleId: string;
  readonly activeVersion: string;
  readonly activeHealthy: boolean;
  readonly previousVersion: string | null;
  readonly pending: {
    readonly version: string;
    readonly attempts: string;
  } | null;
  readonly highestSeenVersion: string;
  readonly blockedVersions: readonly string[];
  readonly generation: string;
}

interface NativeUpdateModule {
  installWebCapsuleUpdate(
    options: InstallWebCapsuleUpdateOptions,
  ): Promise<unknown>;
}

interface NativeStateModule {
  getWebCapsuleRuntimeState(
    options: GetWebCapsuleRuntimeStateOptions,
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

export async function getWebCapsuleRuntimeState(
  options: GetWebCapsuleRuntimeStateOptions,
): Promise<WebCapsuleRuntimeState> {
  if (Platform.OS !== "android")
    throw new Error(
      "WEBCAPSULE_ANDROID_ONLY: runtime state is supported only on Android",
    );
  validateBaseOptions(options);
  const module = NativeModules.WebCapsuleState as NativeStateModule | undefined;
  if (module === undefined)
    throw new Error(
      "WEBCAPSULE_NATIVE_MODULE_MISSING: WebCapsuleState is not linked",
    );
  return validateState(await module.getWebCapsuleRuntimeState(options));
}

function validateBaseOptions(options: GetWebCapsuleRuntimeStateOptions): void {
  const exact = [
    "bundledAssetPath",
    "capsuleId",
    "publicKeys",
    "runtimeVersion",
  ];
  if (Object.keys(options).sort().join(",") !== exact.sort().join(","))
    throw new TypeError("WebCapsule state option fields are invalid");
  const values = [
    options.capsuleId,
    options.bundledAssetPath,
    options.runtimeVersion,
  ];
  if (values.some((value) => typeof value !== "string" || value.length === 0))
    throw new TypeError("WebCapsule string options must be non-empty");
  if (
    typeof options.publicKeys !== "object" ||
    options.publicKeys === null ||
    Array.isArray(options.publicKeys) ||
    Object.keys(options.publicKeys).length === 0 ||
    Object.values(options.publicKeys).some(
      (value) => typeof value !== "string" || value.length === 0,
    )
  )
    throw new TypeError("publicKeys must be a non-empty string record");
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

function validateState(value: unknown): WebCapsuleRuntimeState {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    throw new TypeError("Native runtime state must be an object");
  const state = value as Record<string, unknown>;
  const keys = [
    "activeHealthy",
    "activeVersion",
    "blockedVersions",
    "capsuleId",
    "generation",
    "highestSeenVersion",
    "pending",
    "previousVersion",
  ];
  if (
    Object.keys(state).sort().join(",") !== keys.sort().join(",") ||
    typeof state.capsuleId !== "string" ||
    typeof state.activeVersion !== "string" ||
    typeof state.activeHealthy !== "boolean" ||
    (state.previousVersion !== null &&
      typeof state.previousVersion !== "string") ||
    typeof state.highestSeenVersion !== "string" ||
    !Array.isArray(state.blockedVersions) ||
    state.blockedVersions.some((item) => typeof item !== "string") ||
    typeof state.generation !== "string" ||
    !/^(0|[1-9][0-9]*)$/.test(state.generation)
  )
    throw new TypeError("Native runtime state fields are invalid");
  if (state.pending !== null) {
    if (typeof state.pending !== "object" || Array.isArray(state.pending))
      throw new TypeError("Native pending state is invalid");
    const pending = state.pending as Record<string, unknown>;
    if (
      Object.keys(pending).sort().join(",") !== "attempts,version" ||
      typeof pending.version !== "string" ||
      typeof pending.attempts !== "string" ||
      !/^[0-2]$/.test(pending.attempts)
    )
      throw new TypeError("Native pending state is invalid");
  }
  return state as unknown as WebCapsuleRuntimeState;
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
