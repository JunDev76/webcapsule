# WebCapsule

> An open-source WebView runtime that packages web screens inside React Native apps into signed single `.capsule` files — running them offline instantly, with safe updates, atomic activation, and automatic rollback.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Android%20%7C%20iOS-green.svg)](#platform-support)
[![Status](https://img.shields.io/badge/status-pre--release-orange.svg)](#status)

**English** · [한국어](README.ko.md)

---

## Why WebCapsule

Some screens in React Native apps are built as remote WebViews for development speed and instant deployment. But:

1. The first visit downloads HTML, JS, CSS and images over the network — **loading is slow**.
2. With no or unstable network, **the screen does not open**.
3. A server or CDN outage **becomes an app-screen outage**.
4. Guaranteeing **compatibility** between web content and app versions is hard.
5. Verifying the integrity of and **rolling back** misdeployed content is hard.
6. Service Worker caches **do not exist before the first visit** and cannot guarantee a baseline version at install time.

WebCapsule solves this by turning web build output into **verifiable offline execution units**.

### What WebCapsule ships

HTML, CSS, JavaScript, images and fonts, static assets needed by the WebView, manifest, integrity information, and permission declarations.

### What WebCapsule does not ship

React Native application JS bundles, Hermes/JSC bundles, native code and dynamic libraries, RN components and native modules, new OS permissions. **WebCapsule is not an RN OTA solution.** It does not update the whole app — it manages independent WebView content inside an app as an offline-executable, verifiable, recoverable unit.

---

## Key features

- **Signed offline execution unit** — A `.capsule` is a ZIP container; per-file SHA-256 and an Ed25519 manifest signature verify every byte.
- **Offline-first** — A capsule bundled with the app is verified and installed, then runs instantly with no network. No localhost HTTP server, no `file://` access.
- **Static-hosted updates** — Deploy updates with static HTTPS only (GitHub Pages, S3, Cloudflare R2). No WebCapsule backend required.
- **Atomic activation** — Content files are never replaced one by one. Only the active pointer in a small registry is swapped atomically.
- **Automatic rollback** — A new version stays pending until it passes a `ready` handshake; on failure it recovers to the previous healthy version.
- **Storage deduplication (CAS)** — Identical files across versions are stored once. (This is disk savings, not network delta downloads.)
- **Transparent trust model** — Private keys live only in the build environment; apps embed public keys only. Verification logic is implemented natively and never trusts JS validation results.
- **Open format** — A Format v1 specification independent of any implementation lives in `specs/`.

---

## Quick start

### 1. Generate keys and build a capsule with the CLI

```bash
pnpm add -D @webcapsule/cli

# Generate an Ed25519 signing key pair
webcapsule keygen --out ./keys

# Web build output directory -> signed capsule
webcapsule build ./dist \
  --id com.example.guide \
  --version 1.0.0 \
  --entry index.html \
  --minimum-runtime-version 1.0.0 \
  --key-id release-2027 \
  --private-key ./keys/private.pem \
  --out guide-1.0.0.capsule

# Verify signature, hashes, and format
webcapsule verify guide-1.0.0.capsule \
  --public-key ./keys/public.pem \
  --expected-id com.example.guide \
  --expected-key-id release-2027 \
  --runtime-version 1.0.0

# Inspect metadata (no trust established)
webcapsule inspect guide-1.0.0.capsule

# Create a signed update index
webcapsule index \
  --id com.example.guide \
  --channel stable \
  --key-id release-2027 \
  --private-key ./keys/private.pem \
  --release release-1.1.0.json \
  --out stable.json
```

Any web framework works. WebCapsule takes the **build output directory** of React, Vue, Svelte, or plain static HTML. Remote site crawling is not supported.

### 2. Integrate with a React Native app

```bash
pnpm add @webcapsule/react-native
```

```tsx
import { WebCapsuleView } from "@webcapsule/react-native";

export function GuideScreen() {
  return (
    <WebCapsuleView
      style={{ flex: 1 }}
      capsuleId="com.example.guide"
      bundledAssetPath="WebCapsule/guide-1.0.0.capsule"
      publicKeys={{ "release-2027": PUBLIC_KEY }}
      runtimeVersion="1.0.0"
      onLoad={({ nativeEvent }) => console.log("loaded", nativeEvent.version)}
      onError={({ nativeEvent }) => console.error(nativeEvent.code, nativeEvent.message)}
      onRollback={({ nativeEvent }) =>
        console.log(`rollback ${nativeEvent.failedVersion} -> ${nativeEvent.restoredVersion ?? "bundled"}`)
      }
    />
  );
}
```

### 3. Apply updates

```ts
import { installWebCapsuleUpdate, getWebCapsuleRuntimeState } from "@webcapsule/react-native";

// Verify and install a new capsule from a signed static-hosted index, in the background
const result = await installWebCapsuleUpdate({
  capsuleId: "com.example.guide",
  bundledAssetPath: "WebCapsule/guide-1.0.0.capsule",
  publicKeys: { "release-2027": PUBLIC_KEY },
  runtimeVersion: "1.0.0",
  indexUrl: "https://example.com/guide/stable.json",
  channel: "stable",
});

if (result.status === "installed") {
  console.log(`${result.previousVersion} -> ${result.currentVersion}`);
}

// Query runtime state (active / previous / pending / blocked)
const state = await getWebCapsuleRuntimeState({
  capsuleId: "com.example.guide",
  bundledAssetPath: "WebCapsule/guide-1.0.0.capsule",
  publicKeys: { "release-2027": PUBLIC_KEY },
  runtimeVersion: "1.0.0",
});
```

---

## Runtime flow

1. A capsule bundled with the app is verified and installed.
2. The WebView opens the active local version instantly.
3. Update checks run in the background.
4. A new capsule is downloaded to a temporary area.
5. Signature, file hashes, format, and runtime compatibility are verified.
6. On success it is stored in a staging state.
7. Activation is atomic on the next WebView start or an explicit request.
8. When the new content sends a `ready` signal it is confirmed healthy.
9. On failure the previous healthy version is restored.

```
ABSENT -> DOWNLOADING -> VERIFIED -> STAGED -> PENDING -> HEALTHY
                                                            | failure
                                          FAILED / BLOCKED -> ROLLED_BACK
```

---

## `.capsule` format v1

```
guide-1.0.0.capsule (ZIP)
|- capsule.json     # manifest (Ed25519 signature target)
|- capsule.sig      # 64-byte Ed25519 signature (Base64 + LF)
`- files/
    |- index.html
    `- assets/
        |- app.js
        |- app.css
        `- logo.webp
```

- The manifest declares per-file `sha256`, `size`, `mediaType`, and a `policy` (network, navigation, bridge).
- Signature payload: `UTF8("WEBCAPSULE-MANIFEST-V1\n") + canonical_json(capsule.json)` (RFC 8785 JCS)
- Update indexes carry a separate Ed25519 signature (`WEBCAPSULE-UPDATE-INDEX-V1\n` payload).
- Builds are deterministic — the same input and key produce identical capsule bytes.

### Security limits

- Paths: reject `..`, absolute paths, backslashes, symlinks, NUL, Unicode NFC collisions, and case collisions.
- Sizes: 100 MB capsule · 250 MB expanded · 50 MB per file · 10,000 files.
- Reject ZIP bombs, path traversal, duplicate or missing files, and manifest mismatch.
- Replay protection via a recorded `highestSeenVersion`.
- No activation before signature and hash verification complete.

Full specifications live in [`specs/`](specs/).

---

## Architecture

```
@webcapsule/react-native
       |
       |-- React API (WebCapsuleView, installWebCapsuleUpdate, getWebCapsuleRuntimeState)
       `-- Native WebCapsule Runtime
            |-- Downloader
            |-- Archive Verifier (StrictZipReader)
            |-- Ed25519 / SHA-256 Verifier
            |-- Content-Addressed Store (CAS)
            |-- Version Registry (active / previous / pending)
            |-- Atomic Activator
            |-- Recovery Manager
            `-- WebView Resource Handler
```

- **Android** — Kotlin, `WebViewAssetLoader` (`https://webcapsule.local/...`)
- **iOS** — Swift, `WKURLSchemeHandler` (`webcapsule://...`)

Shared compatibility rules: prefer relative URLs, forbid `file://` access, no Service Worker in v1, external network denied by default.

---

## Monorepo layout

```
webcapsule/
|- packages/
|   |- format/                     # @webcapsule/format — manifest types, JSON Schema, canonicalization
|   |- cli/                         # @webcapsule/cli — keygen, build, inspect, verify, index
|   `-- react-native-webcapsule/    # @webcapsule/react-native — RN component + native runtime
|       |- src/                     # TypeScript API
|       |- android/                 # Kotlin runtime
|       `-- ios/Sources/WebCapsuleCore/  # Swift runtime
|- examples/
|   |- rn-demo/                     # RN demo app
|   `-- capsule-content/            # sample web content (bundled-v1, updated-v2, broken-v3)
|- specs/                           # public specs (capsule-format-v1, update-index-v1, security-model, ...)
|- fixtures/                        # valid and malicious test vectors (cross-platform)
|- docs/adr/                        # Architecture Decision Records (0001-0006)
`-- scripts/
```

---

## Development

Requirements: Node.js 22 LTS and pnpm 10.

```bash
pnpm install
pnpm format:check
pnpm lint
pnpm typecheck
pnpm test          # tests across all packages
pnpm build

# Android
pnpm android:compile
pnpm android:test
pnpm android:assemble

# iOS
pnpm ios:test

# Demo
pnpm demo:build-content   # build sample capsules
pnpm demo:start           # start Metro
pnpm demo:ios             # run the iOS demo
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution guide and [SECURITY.md](SECURITY.md) for the security policy.

---

## Status

**Pre-release.** The API may change before stabilization. v1.0.0 success criteria are in `packages/plan.md` §20.

### Platform support

| Platform | Status |
| --- | --- |
| Android | Implemented (Kotlin, WebViewAssetLoader) |
| iOS | Implemented (Swift, WKURLSchemeHandler) |

### Roadmap (out of v1 scope)

Flutter SDK, file-level remote delta downloads, key revocation and advanced rotation, release channels and staged rollout, native bridge capability extensions, shared native core. A self-hosted CDN, management web dashboard, user accounts, and AI features are not planned.

---

## Documentation

- Project plan: [`packages/plan.md`](packages/plan.md)
- Format specs: [`specs/capsule-format-v1.md`](specs/capsule-format-v1.md), [`specs/update-index-v1.md`](specs/update-index-v1.md)
- Security model: [`specs/security-model.md`](specs/security-model.md)
- Compatibility: [`specs/compatibility.md`](specs/compatibility.md)
- Decision records: [`docs/adr/`](docs/adr/)
- CLI docs: [`docs/cli.md`](docs/cli.md)

---

## License

[MIT License](LICENSE) · Copyright (c) 2026 JunDev76

Third-party dependency licenses are recorded in [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md), all OSI-approved.