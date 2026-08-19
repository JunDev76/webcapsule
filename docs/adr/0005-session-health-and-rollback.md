# ADR 0005: Session health and rollback

- Status: Accepted

## Decision

Each WebView session is pinned to the complete version selected at creation. Pending content becomes healthy only after a ready message matching protocol, capsule ID, and session version, followed by a stabilization period. Repeated failure blocks the version and restores previous healthy or verified bundled content.

## Consequences

Registry changes never mix resources within a running session. Loading the entry document alone is not evidence of health.

Android permits exactly two durable pending attempts. The first explicit failure preserves pending state; the second blocks the failed version and atomically restores a completely revalidated previous version. A process crash after the second attempt is reconciled before another session. If previous storage is unusable, only the explicitly trusted bundled capsule may be independently verified and registered as a new unhealthy trial. The initial bundled artifact is not retried after exhausting both attempts.

The normative timing and matching behavior is defined in [`specs/android-runtime-v1.md`](../../specs/android-runtime-v1.md); the rollback state machine is defined in [`specs/android-rollback-v1.md`](../../specs/android-rollback-v1.md).
