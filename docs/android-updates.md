# Android signed updates

Android exposes one high-level operation. It verifies and selects a signed index, downloads the complete capsule, independently verifies it, installs immutable content, and registers the version for the next trial session.

```ts
import { installWebCapsuleUpdate } from "@webcapsule/react-native";

const result = await installWebCapsuleUpdate({
  capsuleId: "com.example.guide",
  bundledAssetPath: "webcapsule/guide-v1.capsule",
  publicKeys: { "release-2027": PUBLIC_KEY_PEM },
  runtimeVersion: "1.0.0",
  indexUrl: "https://updates.example.com/guide/stable.json",
  channel: "stable",
});
```

`result.status` is `installed` or `up-to-date`. Versions and `generation` are strings; generation is a decimal string to preserve the registry safe integer exactly across the React Native boundary. An installed update does not alter an existing pinned WebView session. The next session trials the new version.

The call is Android-only and requires the legacy `WebCapsuleUpdate` native module to be linked. It performs no redirect, retry, resume, range request, background scheduling, or alternative release fallback. A concurrent call for the same capsule fails with `UPDATE_IN_PROGRESS`; an existing trial fails with `UPDATE_TRIAL_IN_PROGRESS`; a storage-state change during network I/O fails with `UPDATE_STATE_CHANGED`.

Both index and capsule URLs use system-trusted HTTPS. The index is limited to 1 MiB and capsules to 100 MiB. Capsule downloads are complete archives; CAS only removes duplicate installed blobs and is not a network delta mechanism.
