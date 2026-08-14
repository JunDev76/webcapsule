# ADR 0006: Platform resource handlers

- Status: Accepted

## Decision

Android serves local content through `WebViewAssetLoader` on `https://webcapsule.local`. iOS serves it through `WKURLSchemeHandler` on `webcapsule://`. v1 does not create a localhost HTTP server. Relative resources form the common compatibility profile.

## Consequences

Platform origin differences are documented and tested with shared fixtures. Service Workers are unsupported, and manifest-declared resources are the only local responses.
