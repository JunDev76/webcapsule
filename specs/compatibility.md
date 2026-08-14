# WebCapsule v1 Compatibility Profile

Status: Draft

## Origins

- Android: `https://webcapsule.local/<capsuleId>/<version>/<path>` through `WebViewAssetLoader`
- iOS: `webcapsule://<capsuleId>/<version>/<path>` through `WKURLSchemeHandler`

No TCP listener is created. `file://` is unsupported.

## Content requirements

Content should use relative URLs. Service Workers are unsupported. Every served resource must exist in the session manifest. MIME types come from validated manifest entries. Query strings do not participate in file lookup; fragments are never sent to the resource handler.

Request paths are percent-decoded exactly once and then subjected to the same path validation as archive entries. Encoded separators, malformed escapes, NUL, traversal, and paths outside the selected capsule/version are rejected.

External network and top-level navigation are denied unless the host explicitly approves an origin also requested by the manifest. SPA fallback is not part of the initial v1 implementation and may only be added as an explicit policy.

## Session behavior

The runtime selects one complete version when creating a WebView. Registry changes do not alter that session. Platform differences in origin APIs must be represented in fixtures and documented rather than hidden with a local HTTP server.
