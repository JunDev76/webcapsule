# ADR 0004: Storage and atomic activation

- Status: Accepted

## Decision

Verified files are immutable SHA-256-addressed CAS blobs. A durable version record references blobs. Activation atomically replaces a small registry containing active, previous, pending, blocked, highest-seen version, and generation state. Content is never replaced file by file.

## Consequences

Interrupted work leaves the old registry valid or a complete new state. Previous points only to healthy content. Automatic CAS garbage collection is deferred until retention correctness is demonstrated.
