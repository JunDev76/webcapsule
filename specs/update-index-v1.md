# Update Index v1

Status: Draft

An update index is a UTF-8 JSON document containing exactly `schemaVersion`, `capsuleId`, `channel`, `releases`, `keyId`, and `signature`. Missing fields, additional fields, and duplicate JSON object keys are rejected. `channel` is 1–64 lowercase ASCII letters, digits, `.`, `_`, or `-`, starts with a letter or digit, and is never inferred.

Each release contains exactly `version`, HTTPS `url`, lowercase hexadecimal `sha256`, byte `size`, and `minimumRuntimeVersion`. URLs must be absolute HTTPS URLs without credentials. Sizes must not exceed the 100 MB capsule limit. At least one release is required. Releases are ordered by descending SemVer precedence. Two versions with equal SemVer precedence are duplicates even if their strings differ, including versions that differ only in build metadata; v1 rejects both to eliminate ambiguous ordering.

The only creation interface is `webcapsule index --id <capsule-id> --channel <channel> --key-id <id> --private-key <pkcs8-pem> --release <descriptor.json> [--release <descriptor.json> ...] --out <index.json>`. Each descriptor is a UTF-8 JSON document with exactly the five release fields above. Missing fields, extra fields, and duplicate object keys are rejected. `--key-id` and at least one `--release` are mandatory; the command never reads capsules, contacts URLs, or infers key IDs, releases, versions, hashes, or sizes from keys, filenames, directories, URLs, or existing indexes.

## Signing

The signature is removed from the object before signing. The payload is:

```text
UTF8("WEBCAPSULE-UPDATE-INDEX-V1\n") + canonical_json(index_without_signature)
```

`signature` is standard padded Base64 encoding of exactly 64 Ed25519 signature bytes. URL-safe or unpadded Base64 is rejected. Canonical JSON and key representation follow Capsule Format v1. An unsigned object with exactly all fields except `signature` is valid only as builder input and is never accepted as a downloaded index. The final index file is the canonical JSON encoding of the signed object in UTF-8 followed by exactly one LF byte. Existing output files are never replaced.

## Acceptance

Before downloading a capsule, the runtime verifies the index signature, trusted key ID, expected capsule ID, supported schema, HTTPS URL, release size, runtime compatibility, and SemVer. After download it verifies the declared byte size and SHA-256 before archive verification.

A release lower than `highestSeenVersion` is rejected even when correctly signed. Failed index or release validation must not mutate installed versions or the active registry.

`inspect` reports `"trust": "unverified"` and performs no signature or trust verification. Verification is exclusively the responsibility of `verify`; `inspect` never upgrades its trust label or falls back to verification.
