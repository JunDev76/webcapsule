# Update Index v1

Status: Draft

An update index is a UTF-8 JSON document containing `schemaVersion`, `capsuleId`, `channel`, `releases`, `keyId`, and `signature`.

Each release contains `version`, HTTPS `url`, lowercase hexadecimal `sha256`, byte `size`, and `minimumRuntimeVersion`. Releases are ordered by descending SemVer precedence and versions are unique.

## Signing

The signature is removed from the object before signing. The payload is:

```text
UTF8("WEBCAPSULE-UPDATE-INDEX-V1\n") + canonical_json(index_without_signature)
```

`signature` is standard Base64 Ed25519 output. Canonical JSON and key representation follow Capsule Format v1.

## Acceptance

Before downloading a capsule, the runtime verifies the index signature, trusted key ID, expected capsule ID, supported schema, HTTPS URL, release size, runtime compatibility, and SemVer. After download it verifies the declared byte size and SHA-256 before archive verification.

A release lower than `highestSeenVersion` is rejected even when correctly signed. Failed index or release validation must not mutate installed versions or the active registry.
