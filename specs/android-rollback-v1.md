# Android Automatic Rollback v1

## 1. Scope

This specification defines pending-session health outcomes, automatic rollback, and process-crash reconciliation for the Android runtime. It does not define retries, unblock or force APIs, network fallback, installed-version discovery, leases, heartbeats, PID persistence, background scheduling, GC, or iOS behavior.

## 2. Constants

`MAX_PENDING_ATTEMPTS` is exactly 2 and is not configurable. The existing ready timeout remains 15 seconds and stabilization remains 3 seconds.

## 3. State transitions

| State/event                                       | Atomic result                                                                                             |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| pending attempts 0, session selection             | attempts 1; generation + 1                                                                                |
| attempt 1 explicit failure                        | registry unchanged                                                                                        |
| pending attempts 1, session selection             | attempts 2; generation + 1                                                                                |
| attempt 1 or 2 health success                     | active healthy; pending null; generation + 1                                                              |
| attempt 2 explicit failure with complete previous | failed version blocked; previous becomes healthy active; pending/previous null; generation + 1            |
| startup sees attempts 2 with complete previous    | same rollback, without creating a third session                                                           |
| previous incomplete, trusted bundled differs      | bundled independently verified/installed and registered unhealthy with attempts 0; failed version blocked |
| initial bundled version exhausts two attempts     | terminal `NO_RUNNABLE_VERSION`; the same artifact is not retried                                          |

`highestSeenVersion` never decreases. Blocked versions are unique and strictly descending by SemVer precedence. Registry schema version remains 1.

## 4. Failure and lifecycle semantics

Entry/main-frame load failure, invalid ready, ready timeout, stabilization failure, denied fatal navigation/resource state, and renderer death are explicit failures. Application backgrounding is not a failure. Normal detach/destroy does not immediately mutate the registry, does not restore an attempt, and only releases the process-local guard. A later startup reconciles an exhausted attempt.

## 5. Concurrency

Only one pending trial for a capsule may exist in a process. Acquisition failure is `TRIAL_SESSION_IN_PROGRESS`. Healthy sessions remain concurrent. The token is released exactly once on success, explicit failure, detach, destroy, or preparation failure. No storage or OS lock is held for the session lifetime.

Health and rollback use the same capsule lock and exact generation, active version, pending version, and attempt identity. Only one transition can commit; stale callbacks return `SESSION_MISMATCH` and do not emit duplicate terminal events.

## 6. Rollback target

The previous pointer is never accepted without reading its immutable version record and verifying every referenced CAS blob's type, size, and SHA-256. No installed directory scan is permitted. If previous is unusable, only the explicitly configured bundled asset may be independently copied, verified, and immutably installed. Downloaded capsules and network resources are never rollback sources.

## 7. Crash points

A crash before an AtomicFile replacement preserves the old registry; a crash after it exposes the complete new registry. This applies to attempt increment, healthy commit, final rollback, and bundled fallback. A crash after attempt 1 permits attempt 2. A crash after attempt 2 triggers reconciliation before another session is returned.

## 8. Public observation

`onRollback` reports capsule ID, failed version, restored version or null, stable reason code, and decimal generation. `getWebCapsuleRuntimeState` is read-only and returns only bundled-recovered and fully reference-validated state. Generation and attempts are decimal strings. No retry, unblock, force activation, highest-version reset, or installed-version-list API exists.
