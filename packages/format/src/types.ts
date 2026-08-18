import type {
  FORMAT_VERSION,
  UPDATE_INDEX_SCHEMA_VERSION,
} from "./constants.js";

export interface CapsuleFileEntry {
  readonly path: string;
  readonly sha256: string;
  readonly size: number;
  readonly mediaType: string;
}

export interface CapsuleNetworkPolicy {
  readonly mode: "deny" | "allowlist";
  readonly origins?: readonly string[];
}

export interface CapsuleNavigationPolicy {
  readonly externalOrigins: readonly string[];
}

export interface CapsulePolicy {
  readonly network: CapsuleNetworkPolicy;
  readonly navigation: CapsuleNavigationPolicy;
  readonly bridgeCapabilities: readonly string[];
}

export interface CapsuleManifest {
  readonly formatVersion: typeof FORMAT_VERSION;
  readonly capsuleId: string;
  readonly version: string;
  readonly entry: string;
  readonly createdAt: string;
  readonly minimumRuntimeVersion: string;
  readonly keyId: string;
  readonly files: readonly CapsuleFileEntry[];
  readonly policy: CapsulePolicy;
}

export interface UpdateRelease {
  readonly version: string;
  readonly url: string;
  readonly sha256: string;
  readonly size: number;
  readonly minimumRuntimeVersion: string;
}

export interface UnsignedUpdateIndex {
  readonly schemaVersion: typeof UPDATE_INDEX_SCHEMA_VERSION;
  readonly capsuleId: string;
  readonly channel: string;
  readonly releases: readonly UpdateRelease[];
  readonly keyId: string;
}

export interface UpdateIndex extends UnsignedUpdateIndex {
  readonly signature: string;
}

export interface ReadyMessage {
  readonly type: "ready";
  readonly protocolVersion: 1;
  readonly capsuleId: string;
  readonly version: string;
}
