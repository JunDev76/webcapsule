# ADR 0003: Archive validation

- Status: Accepted

## Decision

A v1 capsule is a ZIP containing only `capsule.json`, `capsule.sig`, and declared `files/` entries. All paths and sizes are checked before and during streaming extraction. Traversal, absolute paths, backslashes, NUL, symlinks, duplicates, case collisions, Unicode normalization collisions, encryption, and limit violations are rejected.

## Consequences

CLI verification does not replace native verification. No archive data reaches permanent storage until signature, structure, hashes, and limits pass.
