# ADR 0001: Product boundary

- Status: Accepted

## Decision

WebCapsule packages and runs static WebView content. It does not update React Native JavaScript bundles, native code or modules, permissions, or core application behavior. v1 excludes `file://`, localhost servers, Service Workers, network delta updates, a CDN/dashboard, Flutter, and AI features.

## Consequences

Documentation and APIs must describe WebCapsule as an offline WebView content runtime, not an RN OTA solution. Content-oriented, non-core screens are the recommended use case.
