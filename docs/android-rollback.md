# Android rollback

Android trials are deliberately bounded. A newly installed or bundled capsule receives at most two sessions. Each session consumes its attempt before the WebView starts, so a process crash cannot grant another attempt.

- The first explicit failure leaves the pending version available for its second trial.
- The second failure blocks that version and atomically restores a fully verified healthy previous version.
- If the second process dies, the next startup performs the same reconciliation before creating a WebView.
- If previous storage is damaged, only the configured bundled capsule can be independently verified and registered as a new unhealthy trial.
- If the initial bundled capsule itself exhausts both attempts, the runtime reports `NO_RUNNABLE_VERSION`.

A normal view detach only releases the in-process trial guard. It does not count as an explicit failure and does not refund the durable attempt.

## Events

```tsx
<WebCapsuleView
  {...props}
  onRollback={({ nativeEvent }) => {
    console.log(nativeEvent.failedVersion);
    console.log(nativeEvent.restoredVersion);
    console.log(nativeEvent.reason);
  }}
/>
```

A final explicit failure emits `onError` and then one committed `onRollback`. A successful trial emits `onLoad`. Stale callbacks do not mutate state or emit another terminal event.

## State inspection

```ts
const state = await getWebCapsuleRuntimeState({
  capsuleId,
  bundledAssetPath,
  publicKeys,
  runtimeVersion,
});
```

The call is read-only. It performs bundled-only recovery and validates registry references before returning. The options object requires exactly `capsuleId`, `bundledAssetPath`, `publicKeys`, and `runtimeVersion`; missing, additional, null, or incorrectly typed values are rejected. `generation` and `pending.attempts` are decimal strings. Native failures preserve their stable error code in the rejected promise. There are no public retry, unblock, force, reset, or installed-version-list operations.

## Process restart acceptance

CI runs two separate instrumentation invocations for each restart scenario. The first invocation durably records attempt 1 or attempt 2 and exits normally; the second invocation starts a new target process and verifies the persisted state or performs exhausted-pending reconciliation. This is a deterministic process-boundary simulation, not a kill in the middle of an `AtomicFile` instruction. JVM fault tests inject failures at the meaningful registry write points, while Android instrumentation separately verifies the real `AtomicFile` and hard-link behavior.

The normative state machine and failure rules are in [`../specs/android-rollback-v1.md`](../specs/android-rollback-v1.md).
