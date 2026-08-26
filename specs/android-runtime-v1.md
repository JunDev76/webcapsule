# Android Runtime v1

Status: Draft

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, and MAY are normative.

## 1. Platform and trust boundary

The Android runtime requires API 26 or newer and is compiled with Android SDK 35. The host application determines its target SDK. The runtime MUST NOT provide a compatibility implementation below API 26.

Ed25519 verification MUST use Google Tink only. The runtime MUST select the public key by the manifest `keyId`; it MUST NOT try other keys. JavaScript and CLI verification results are untrusted.

The runtime owns a dedicated native `WebView`. It MUST NOT wrap `react-native-webview`, use `file://`, start a localhost server, or execute an archive directly.

## 2. Bundled source

A bundled source is an Android asset-relative string matching:

```text
webcapsule/<filename>.capsule
```

`<filename>` MUST be one non-empty segment containing only ASCII letters, digits, `.`, `_`, and `-`. It MUST NOT be `.` or `..`. URLs, absolute paths, nested paths below `webcapsule/`, filesystem paths, `content://`, `file://`, and numeric React Native asset IDs are invalid. Capsule ID, version, and key ID MUST come from the independently verified manifest and MUST NOT be inferred from the filename.

The host MUST provide the bundled source and the trusted key map required by that source. There is no implicit default asset.

## 3. Filesystem encoding and layout

The storage root is exactly `<noBackupFilesDir>/webcapsule/v1`. Logical capsule IDs and versions are encoded as lowercase hexadecimal of their NFC UTF-8 bytes. Decoding MUST reject uppercase hex, odd length, invalid UTF-8, non-NFC output, and values whose re-encoding differs.

```text
<root>/
├── blobs/sha256/<h[0:2]>/<h>
├── versions/<hex(capsuleId)>/<hex(version)>/record.json
├── registries/<hex(capsuleId)>.json
├── staging/<operation-uuid>/
└── locks/<hex(capsuleId)>.lock
```

`h` is exactly 64 lowercase hexadecimal SHA-256 characters. Blob and version files are immutable after publication. Temporary files MUST remain under the operation staging directory.

Blob publication uses same-filesystem `Files.createLink(final, staged)` as the atomic create-if-absent publication point, followed by unlinking the staging name. The verified staged blob is `fsync`ed before linking and MUST remain writable by the runtime at that moment: Android enforces `fs.protected_hardlinks`, and the kernel refuses `link()` on a source the caller cannot also write. Mode `0444` is therefore applied to the shared inode immediately after the link succeeds, before the staging name is unlinked; both names observe the same read-only inode. Publication MUST NOT change the mode before linking. An existing destination is reused only after exact no-follow regular-file, size, and SHA-256 verification. Unsupported hard links and cross-device linking are `ATOMIC_PUBLISH_UNSUPPORTED`; copy, replacing rename, and non-atomic fallback are forbidden.

Because the mode change follows the link, a crash between the two leaves a published name whose bytes are already final but whose mode is still writable. A retry MUST settle exactly that state: after the destination is proven byte-identical by no-follow regular-file, size, and SHA-256 verification, a still-writable mode is completed to `0444` and publication proceeds. This completes the last step of an interrupted publication; it MUST NOT alter published content, and any content difference remains `STORAGE_INVARIANT_VIOLATION`. Content-addressed immutability makes the settle idempotent and safe under concurrent installs of the same bytes.

Version directory rename is not a publication primitive. The installer writes and `fsync`s staged `record.json`, writes an explicit operation journal, creates the final version directory with `Files.createDirectory`, and creates a hard link for final `record.json`. The staged record is subject to the same ordering rule: it stays writable while linking and the published record is changed to `0444` immediately afterwards, and an interrupted record publication is settled on retry under the same byte-identity proof. That record link is the sole no-replace publication marker. A crash after directory creation but before record linking leaves an incomplete directory identified only by the persisted staging journal. Recovery may remove exactly that journal-owned empty directory; it MUST NOT scan versions. If the journal is unavailable and an incomplete final directory remains, installation terminates with `STORAGE_INVARIANT_VIOLATION`. v1 makes no parent-directory `fsync` durability claim.

## 4. Immutable version record

`record.json` MUST be UTF-8 canonical JSON with exactly this shape:

```json
{
  "schemaVersion": 1,
  "capsuleId": "com.example.guide",
  "version": "1.0.0",
  "keyId": "release-2027",
  "createdAt": "2026-08-16T10:00:00Z",
  "entry": "index.html",
  "manifestSha256": "<64 lowercase hex>",
  "files": [
    {
      "path": "index.html",
      "sha256": "<64 lowercase hex>",
      "size": 123,
      "mediaType": "text/html"
    }
  ]
}
```

Fields MUST NOT be null. Unknown or missing fields are invalid. `files` MUST be in manifest order and exactly reproduce the verified manifest file set. The record's capsule ID, version, key ID, createdAt, entry, file metadata, and manifest digest MUST equal independently verified values. Each referenced blob MUST exist as a regular file with exactly the declared byte size. Runtime recovery MUST hash each referenced blob before selecting the version as runnable.

A published version directory MUST contain only `record.json`. An already published `(capsuleId, version)` MUST NOT be overwritten or repaired in place. A byte-identical record is an idempotent install result; any difference is `STORAGE_INVARIANT_VIOLATION`.

## 5. Registry

A registry is canonical UTF-8 JSON with exactly this shape:

```json
{
  "schemaVersion": 1,
  "capsuleId": "com.example.guide",
  "generation": 3,
  "active": { "version": "1.0.0", "healthy": true },
  "previous": null,
  "pending": null,
  "highestSeenVersion": "1.0.0",
  "blockedVersions": []
}
```

- `schemaVersion` MUST equal `1`.
- `capsuleId` MUST equal the registry filename's decoded capsule ID.
- `generation` MUST be a non-negative safe integer and MUST increase by exactly one for each committed replacement.
- `active` MUST be non-null and reference a complete runnable version. `healthy` is a boolean.
- `previous` is null or `{ "version": <SemVer> }`; when non-null it MUST reference a complete version designated healthy by the transition that assigned it and MUST differ from `active.version`. Health is registry state, not a property of an immutable version record; strict recovery validates the complete referenced record and blobs but does not reconstruct historical health from storage.
- `pending` is null or `{ "version": <SemVer>, "attempts": <non-negative safe integer> }`. An unhealthy active is a trial: `pending` MUST be non-null and `pending.version` MUST equal `active.version`. A healthy active MUST have `pending=null`. `previous`, when present, MUST differ from both.
- `highestSeenVersion` MUST be valid SemVer and MUST be greater than or equal in SemVer precedence to every referenced or blocked version.
- `blockedVersions` contains unique SemVer strings in descending SemVer precedence and MUST NOT contain active, previous, or pending.

Null is permitted only for `previous` and `pending`. Unknown or missing fields and violated invariants make the registry invalid.

## 6. Locking and durable publication

Operations affecting one capsule MUST acquire its process mutex and then its OS file lock. No operation may acquire locks for two capsule IDs. Within a lock, the fixed order is registry read/recovery, staging, blob publication, version publication, registry replacement, cleanup. Blob/version code MUST NOT acquire the registry lock recursively.

Installation SHALL:

1. Validate the bundled source syntax and open the trusted asset.
2. Create one staging operation.
3. Independently verify archive profile, manifest, Tink Ed25519 signature, limits, paths, sizes, and hashes.
4. Write each blob to staging, flush it, close it, then publish it without replacement to its CAS path. An existing blob MUST be verified for type, size, and SHA-256 before reuse.
5. Write canonical `record.json`, flush and close it, persist the operation journal, create the final directory, then publish only `record.json` by no-replace hard link.
6. Build the next registry value and replace the registry through Android `AtomicFile`; its durable write MUST complete before success is returned.
7. Remove the staging operation.

The registry MUST NOT reference a version before every blob and its immutable record are durable. Failure before registry replacement leaves the prior registry authoritative. Failure after replacement leaves the new complete registry authoritative. Content files MUST never be replaced one by one during activation.

## 7. State transitions

The base runtime transitions are:

```text
no registry + verified bundled install -> active(bundled, healthy=false), pending=bundled attempts=0
initial unhealthy active selected -> pending attempts incremented durably before session creation
healthy active + verified new install -> active=new healthy=false, previous=old, pending=new attempts=0
pending active selected -> pending session attempt incremented
matching ready + 3 s stabilization for initial active -> active unchanged except healthy=true; previous=null; pending=null
matching ready + 3 s stabilization for an active pending trial -> active unchanged except healthy=true; previous remains the prior healthy version; pending=null
```

The initial bundled version is not declared healthy until the same ready and stabilization procedure completes. Automatic failure, blocking, rollback, and exhausted-attempt recovery follow [`android-rollback-v1.md`](android-rollback-v1.md). Entry-load failure, invalid ready, timeout, or stabilization failure never reverses the attempt committed before session creation.

## 8. Startup recovery and fault outcomes

Recovery MUST run while holding the capsule lock:

1. Let `AtomicFile` restore its backup according to its API.
2. Strictly parse and validate the registry and every referenced version record.
3. Verify the type, size, and SHA-256 of every referenced CAS blob.
4. Delete incomplete staging operations.
5. Select the registry's active version only if all invariants hold.
6. If any registry/reference/blob check fails or no registry exists, independently reverify the explicitly configured trusted bundled asset and create a new registry from it.
7. If bundled revalidation or publication fails, return `REGISTRY_RECOVERY_FAILED` or `BUNDLED_CAPSULE_UNAVAILABLE`; no version is runnable.

The runtime MUST NOT scan installed versions, choose the greatest or newest directory, infer state from filesystem timestamps, repair a corrupt registry from partial fields, execute raw bundled content, or use network content as recovery.

| Fault point                                          | Required restart result                                                                |
| ---------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Asset read or archive verification                   | Prior registry remains authoritative; staging removed                                  |
| Blob staging/write/fsync                             | Prior registry remains authoritative; incomplete staging removed                       |
| Blob publish                                         | Existing complete blobs may remain unreferenced; prior registry remains authoritative  |
| Version record staging/write/fsync                   | Prior registry remains authoritative; incomplete staging removed                       |
| Final version directory creation before record link  | Journal recovery removes only the owned empty directory                                |
| Version record hard-link publication                 | Complete unreferenced version may remain; runtime MUST NOT discover/select it          |
| Before registry replacement                          | Prior registry remains authoritative                                                   |
| During registry replacement                          | `AtomicFile` yields either prior or complete next registry                             |
| After registry replacement                           | Complete next registry is authoritative                                                |
| Corrupt registry or referenced record/blob           | Trusted bundled asset is independently reverified; installed-version scan is forbidden |
| Corrupt or unavailable bundled asset during recovery | No runnable session; explicit recovery error                                           |

## 9. Session descriptor and pinning

A session descriptor is immutable and contains exactly: random session ID, capsule ID, version, entry path, version-record digest, registry generation selected at creation, and creation monotonic time. Creation MUST validate the selected record and blobs under lock. Later registry changes MUST NOT alter the descriptor or any resource served to that session.

A session MUST use only its descriptor's version record. Missing or changed records/blobs terminate the request with `STORAGE_INVARIANT_VIOLATION`; another installed or bundled version MUST NOT be substituted.

## 10. Origin and resource requests

The sole content origin is `https://webcapsule.local`. The URL shape is:

```text
https://webcapsule.local/<encoded-capsule-id>/<encoded-version>/<content-path>
```

Capsule ID and version are each UTF-8 percent-encoded as one segment. Encoding MUST use uppercase hexadecimal escapes and MUST leave only RFC 3986 unreserved bytes literal. The handler MUST reject credentials, a port, a non-HTTPS scheme, another host, malformed escapes, encoded `/` or `\`, and extra/missing prefix segments.

The handler percent-decodes each component exactly once. Decoded ID and version MUST exactly equal the pinned descriptor. The content path is decoded exactly once and validated by the shared safe-path rules. Query is ignored for lookup; fragment is absent from HTTP requests. Directory index, SPA, extension, version, network, and bundled fallbacks are forbidden.

Only a path declared in the pinned version record is served. The response MIME type is the declared `mediaType`; it MUST NOT be inferred. Successful responses use status 200 and exact content length. Invalid or undeclared requests use a non-content response and `RESOURCE_DENIED`; storage corruption uses `STORAGE_INVARIANT_VIOLATION`.

## 11. WebView policy

The dedicated WebView MUST enable JavaScript and DOM storage because capsule applications require them. It MUST disable file access, content access, file-URL universal access, mixed content, multiple windows, and third-party cookies. Safe Browsing MUST remain enabled. Debugging MUST NOT be enabled by the library.

All top-level navigation outside the pinned entry origin/path is denied. New windows, downloads, external intents, permission requests, geolocation, HTTP authentication, client certificates, and SSL-error bypass are denied. Every HTTP(S) subresource outside `https://webcapsule.local` is denied. The runtime MUST NOT honor manifest network allowlists in M3. WebView cache MUST NOT be treated as a source of truth; resource authorization always passes through the pinned native handler.

## 12. Ready and healthy commit

The only accepted bridge message is strict JSON with exactly:

```json
{
  "type": "ready",
  "protocolVersion": 1,
  "sessionId": "<session id>",
  "capsuleId": "com.example.guide",
  "version": "1.0.0"
}
```

Unknown/missing fields, duplicate keys, non-string identifiers, another message type, or protocol version other than integer `1` are invalid. All identifiers MUST exactly match the pinned live session. Messages from another frame, origin, session, capsule, or version MUST be rejected. Entry completion and a matching ready message are independent conditions and MAY arrive in either order: page scripts cannot observe the native page-finished callback, so no arrival order is required of capsule content. A ready message that arrives before entry completion is retained and evaluated under the same source and identity rules; it is not a failure by itself. A second ready message MUST be rejected as a duplicate regardless of order. Entry load failure MUST fail the session even when a valid ready already arrived.

The ready deadline is exactly 15 seconds measured with Android monotonic time from committed session attempt. Once both entry completion and a matching ready are satisfied, the later of the two starts an exact 3-second stabilization interval. Navigation, render-process death, entry load failure, or fatal bridge error during that interval fails stabilization. On success, the runtime atomically commits the registry transition in section 7. Wall-clock changes MUST NOT affect either interval.

## 13. Shared error strings

TypeScript exports these values from `WebCapsuleErrorCode`; Kotlin MUST define and emit the identical uppercase strings. Existing format and CLI codes remain part of the same taxonomy.

| String                        | Android use                                                     |
| ----------------------------- | --------------------------------------------------------------- |
| `BUNDLED_SOURCE_INVALID`      | Bundled asset-relative input violates section 2                 |
| `BUNDLED_CAPSULE_UNAVAILABLE` | Required trusted bundled asset cannot be opened or verified     |
| `STORAGE_IO_FAILED`           | Explicit filesystem operation fails                             |
| `ATOMIC_PUBLISH_UNSUPPORTED`  | Filesystem rejects required no-replace atomic move              |
| `STORAGE_INVARIANT_VIOLATION` | Immutable record/blob violates its contract                     |
| `UNSAFE_STORAGE_LAYOUT`       | Symlink or unexpected staging/root layout makes recovery unsafe |
| `REGISTRY_INVALID`            | Registry syntax, schema, or invariant is invalid                |
| `REGISTRY_RECOVERY_FAILED`    | Required bundled-only recovery cannot establish a registry      |
| `VERSION_RECORD_INVALID`      | Version record syntax/schema/content is invalid                 |
| `BLOB_MISSING`                | A referenced CAS blob is absent                                 |
| `INSTALL_FAILED`              | Verified installation cannot complete                           |
| `LOCK_FAILED`                 | Required process or file lock cannot be acquired                |
| `NO_RUNNABLE_VERSION`         | No validated active version can be selected                     |
| `SESSION_MISMATCH`            | Request or ready identity differs from the pinned session       |
| `RESOURCE_DENIED`             | Origin, navigation, network, or undeclared resource is denied   |
| `ENTRY_LOAD_FAILED`           | The pinned entry document does not complete successfully        |
| `READY_MESSAGE_INVALID`       | Ready JSON/schema/protocol is invalid                           |
| `READY_TIMEOUT`               | No matching ready arrives within 15 seconds                     |
| `STABILIZATION_FAILED`        | Fatal failure occurs during the 3-second interval               |
| `TRIAL_SESSION_IN_PROGRESS`   | Another pending trial is active in this process                 |
| `ROLLBACK_TARGET_UNAVAILABLE` | Neither previous nor trusted bundled content is runnable        |
| `ROLLBACK_FAILED`             | An exact rollback transition or bundled fallback cannot commit  |

## 14. M3 exclusions

The runtime does not implement staged rollout, CAS garbage collection, iOS, public retry/unblock/force controls, Service Workers, network allowlists, native capability bridges beyond ready, SPA fallback, directory-index fallback, or migration from another storage schema. Remote update behavior is specified separately in [`android-update-v1.md`](android-update-v1.md).
