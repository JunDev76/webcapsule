import type {
  HostComponent,
  NativeSyntheticEvent,
  ViewProps,
} from "react-native";
import { requireNativeComponent } from "react-native";

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

export const WebCapsuleView: HostComponent<WebCapsuleViewProps> =
  requireNativeComponent<WebCapsuleViewProps>("WebCapsuleView");
