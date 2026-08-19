# Android Signed Update v1

Status: Draft

This specification is normative for the Android v1 remote update path. It extends `android-runtime-v1.md` and `update-index-v1.md`.

## Public operation

The only public operation is `installWebCapsuleUpdate(options)`. There are no separate check, download, verify, or activate APIs. The operation returns either `installed` or `up-to-date`. Registry `generation` is represented as a decimal string at the React Native boundary; Kotlin registry storage remains a JSON safe integer.

The request explicitly contains capsule ID, bundled asset path, trusted public-key map, runtime version, index URL, channel. No value is inferred.

## Network profile

Both index and release URLs are absolute HTTPS URLs without userinfo or fragments. Android system TLS trust is used without a test or production bypass. `HttpsURLConnection` uses GET, redirect disabled, no retry, caches disabled, a 10 second connect timeout, a 30 second read timeout, and `Accept-Encoding: identity`. Only HTTP 200 is accepted. Range requests, resume, alternative URLs, and network fallback are forbidden.

The update index is at most 1 MiB, strict UTF-8 JSON, and any supplied `Content-Length` must equal observed bytes. A capsule is at most 100 MiB; its observed byte size and SHA-256 must exactly equal its signed release descriptor. Downloads stream to `cacheDir/webcapsule-update/v1/<uuid>/download.capsule`. This temporary namespace is separate from runtime staging and is deleted on every success and failure path.

## Index verification and selection

Android independently rejects duplicate JSON keys and strictly validates the signed update index. The downloaded JSON itself need not be canonical. The unsigned object is JCS canonicalized and verified over `WEBCAPSULE-UPDATE-INDEX-V1\n` plus canonical bytes using the exact `keyId` declared by the index and an exact lookup in the trusted key map and Google Tink Ed25519.

Capsule ID, channel, and key ID must exactly match the request. Releases are strictly descending by SemVer precedence; equivalent precedence, including build-metadata variants, is rejected. Release URLs use the network profile above.

The first release is selected that:

1. has `minimumRuntimeVersion` less than or equal to the runtime version;
2. has a version strictly greater than `highestSeenVersion`; and
3. is not blocked.

If no release matches, the result is `up-to-date`. Selection is never repeated automatically after state changes.

## Concurrency and commit

A process-wide capsule-ID guard rejects concurrent work immediately with `UPDATE_IN_PROGRESS`. The storage lock is held only for the initial recovered snapshot and final commit; it is never held during network I/O.

An existing unhealthy active or pending trial fails with `UPDATE_TRIAL_IN_PROGRESS`. Immediately before installation and registry transition, bundled-only recovery runs and the generation, full registry value, healthy active, no-pending state, active version, and highest-seen version must equal the initial snapshot. Any difference fails with `UPDATE_STATE_CHANGED` and does not reselect a release.

The downloaded capsule is independently verified by `CapsuleVerifier`. Manifest capsule ID and version must exactly equal the expected capsule and selected release. `VersionStore` publishes immutable content. `RegistryStore` then performs one atomic transition:

```text
old: active=old healthy, previous=?, pending=null
new: active=new unhealthy, previous=old, pending=new attempts=0,
     highestSeenVersion=new, generation=old+1
```

Existing sessions retain their immutable old descriptor. The next session selects and attempts the pending version. Rollback, background scheduling, delta/range download, retry, and iOS behavior are outside this specification.
