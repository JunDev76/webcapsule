# Android support

The M3 Android runtime targets API 26 and newer and compiles against Android SDK 35. The host application owns `targetSdk`.

## React Native architecture

The current package supports React Native 0.76.x legacy architecture only. New Architecture/Fabric support is not implemented and there is no runtime architecture fallback. Hosts must set `newArchEnabled=false` until explicit support is added.

The library provides its own native `WebView`; it does not depend on or wrap `react-native-webview`.

## Required view properties

`WebCapsuleView` requires all of these values without defaults:

- `capsuleId`: exact expected capsule ID
- `bundledAssetPath`: `webcapsule/<filename>.capsule`
- `publicKeys`: exact key-ID-to-SPKI-PEM map
- `runtimeVersion`: explicit runtime SemVer

`onLoad` and `onError` are direct native events. `onLoad` fires exactly once only after a matching ready message and the three-second stabilization interval. `onError` is terminal for that view session and prevents a later `onLoad`.

## Ready bridge

The runtime requires Android System WebView support for `WEB_MESSAGE_LISTENER` and `DOCUMENT_START_SCRIPT`. Unsupported devices fail explicitly with `READY_MESSAGE_INVALID`; there is no `addJavascriptInterface` fallback.

At document start, the runtime defines an immutable `globalThis.__WEBCAPSULE_SESSION__` object containing the exact `type`, `protocolVersion`, `sessionId`, `capsuleId`, and `version`. Capsule code reports readiness from the top-level entry document only:

```js
window.WebCapsuleBridge.postMessage(
  JSON.stringify(globalThis.__WEBCAPSULE_SESSION__),
);
```

The accepted type is exactly `"ready"`. Unknown, missing, duplicate, or incorrectly typed JSON fields fail the session. The message source must be the main frame at exactly `https://webcapsule.local`, and the entry page must already have completed loading.

The ready deadline is 15 seconds from committed session creation using monotonic time. A valid message starts a three-second stabilization interval. Entry-load failure, navigation, an invalid or duplicate ready message, render-process loss, or view teardown prevents a healthy commit. A failure does not trigger rollback or mutate registry state beyond the attempt already recorded before session creation.

The dedicated WebView enables JavaScript and DOM storage and disables file access, content access, mixed content, multiple windows, and third-party cookies. Safe Browsing remains enabled.

## Bundled asset integration

Place the complete signed capsule in the host application only:

```text
android/app/src/main/assets/webcapsule/guide-1.0.0.capsule
```

Pass the exact asset-relative path `webcapsule/guide-1.0.0.capsule`. The package does not accept a filesystem path, URL, `content://` URI, `file://` URI, or numeric React Native asset identifier. The runtime independently verifies and installs the bundled archive before creating a WebView session; it never serves the asset directly.

Public keys are an explicit map from the manifest `keyId` to an Ed25519 SPKI PEM string. Do not bundle a private key. The runtime checks only the key selected by the exact manifest key ID and does not try other registered keys.

## Resource origin and navigation

Installed resources are available only through the pinned origin:

```text
https://webcapsule.local/<capsule-id>/<version>/<manifest-path>
```

Each session snapshots one immutable version record. Registry changes after session creation do not change the blobs served to that WebView. Paths absent from that snapshot, non-canonical percent encoding, encoded separators, another host or port, and another capsule ID or version are denied. There is no SPA fallback, directory-index fallback, alternate-version fallback, `file://` access, localhost server, external navigation, or external subresource access.

## Build and test integration

The Android library uses `minSdk 26` and requires Java 17 for its Gradle build. The host controls `targetSdk`. A release AAR can be checked with:

```bash
pnpm android:assemble
```

JVM tests and API 35 device tests are separate:

```bash
pnpm android:test
pnpm android:connected
```

Device tests copy deterministic signed TEST ONLY capsules and their TEST ONLY public key into generated `androidTest` assets. They are not part of `src/main`, the release AAR, or the npm package. The private test key remains only in the repository fixture generator and is not packaged into an Android artifact.

The API 35 device suite covers the complete bundled install and health flow, JavaScript/CSS/image/JSON resource delivery, document-start session injection, top-frame ready acceptance, iframe ready rejection, the real three-second healthy commit, external navigation and subresource denial, immutable session pinning across a registry change, and isolated test storage. CI runs this suite on an API 35 x86_64 emulator with animations disabled.
