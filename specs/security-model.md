# Security Model

Status: Draft

## Trust boundary

The capsule archive, update index, ZIP metadata, manifest JSON, WebView request paths, and bridge messages are untrusted. JavaScript validation results are never trusted by native runtimes. The host application embeds trusted public keys; private keys never enter the application or capsule.

## Invariants

1. An unverified version never becomes active.
2. Active references a complete manifest and all referenced blobs.
3. Previous references only a healthy version.
4. A WebView session reads only its selected version and declared files.
5. No archive or request path escapes its content root.
6. Failed pending content recovers to previous healthy or verified bundled content.

## Installation

Installation proceeds through a temporary download, streaming limits, archive/signature/hash verification, immutable CAS writes, durable version record, and atomic registry replacement. Failure before registry replacement leaves the prior registry intact. Startup removes incomplete temporary state.

The registry records `active`, `previous`, `pending`, `highestSeenVersion`, blocked versions, and a monotonic `generation`. Content files are never replaced in place.

## WebView

`file://`, localhost servers, new windows, undeclared resources, external top-level navigation, and external network access are denied by default. Android uses `WebViewAssetLoader`; iOS uses `WKURLSchemeHandler`.

A WebView session is pinned to one version. Ready messages must match protocol version, capsule ID, and the pinned version. Manifest capabilities and host approvals are intersected; v1 exposes only readiness and host-approved user messages.

## Explicit non-goals

WebCapsule does not update React Native bundles, native code, native modules, permissions, or core application behavior. It is not a defense against a compromised host application, build machine, trusted private key, or operating system.
