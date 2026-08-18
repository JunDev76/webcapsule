# ADR 0004: Storage and atomic activation

- Status: Accepted

## Decision

Verified files are immutable SHA-256-addressed CAS blobs. A durable version record references blobs. Activation atomically replaces a small registry containing active, previous, pending, blocked, highest-seen version, and generation state. Content is never replaced file by file.

## Consequences

Interrupted work leaves the old registry valid or a complete new state. Previous points only to healthy content. Automatic CAS garbage collection is deferred until retention correctness is demonstrated.

The normative Android v1 layout, registry schema, publication order, locking, and bundled-only corruption recovery are defined in [`specs/android-runtime-v1.md`](../../specs/android-runtime-v1.md). Android MUST NOT reconstruct a corrupt registry by scanning installed versions.
