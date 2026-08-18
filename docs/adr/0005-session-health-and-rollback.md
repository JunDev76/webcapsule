# ADR 0005: Session health and rollback

- Status: Accepted

## Decision

Each WebView session is pinned to the complete version selected at creation. Pending content becomes healthy only after a ready message matching protocol, capsule ID, and session version, followed by a stabilization period. Repeated failure blocks the version and restores previous healthy or verified bundled content.

## Consequences

Registry changes never mix resources within a running session. Loading the entry document alone is not evidence of health.

M3 implements the ready and stabilization health commit but not automatic retry, blocking, or rollback coordination. The normative Android M3 timing, matching, and failure behavior is defined in [`specs/android-runtime-v1.md`](../../specs/android-runtime-v1.md).
