# ADR 0005: Session health and rollback

- Status: Accepted

## Decision

Each WebView session is pinned to the complete version selected at creation. Pending content becomes healthy only after a ready message matching protocol, capsule ID, and session version, followed by a stabilization period. Repeated failure blocks the version and restores previous healthy or verified bundled content.

## Consequences

Registry changes never mix resources within a running session. Loading the entry document alone is not evidence of health.
