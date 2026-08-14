# Capsule Format v1

Status: Draft

## Container

A capsule is a ZIP archive containing exactly:

```text
capsule.json
capsule.sig
files/<manifest path>
```

Unknown entries, directory entries not implied by files, encrypted entries, and symbolic links are rejected. ZIP entry names and manifest paths use UTF-8 and `/` separators.

## Manifest

`capsule.json` is UTF-8 JSON with these required fields:

- `formatVersion`: integer `1`
- `capsuleId`: stable reverse-domain identifier
- `version`: SemVer version
- `entry`: path present in `files`
- `createdAt`: RFC 3339 UTC timestamp
- `minimumRuntimeVersion`: SemVer version
- `keyId`: identifier selected by the host application
- `files`: complete ordered list of content files
- `policy`: network, navigation, and bridge declarations

Each file entry contains `path`, lowercase hexadecimal `sha256`, non-negative integer `size`, and `mediaType`. A file missing from either the manifest or archive causes rejection.

## Signing

The signature payload is:

```text
UTF8("WEBCAPSULE-MANIFEST-V1\n") + canonical_json(capsule.json)
```

Ed25519 signs the exact payload bytes. `capsule.sig` contains the standard Base64 encoding of the 64-byte signature followed by one LF. Public and private keys use PKCS#8/SPKI PEM encoding. SHA-256 values are 64 lowercase hexadecimal characters.

Canonical JSON follows RFC 8785 (JCS). Manifest values outside the I-JSON domain are rejected. Implementations must not reproduce cryptographic primitives themselves.

## Deterministic archives

Files are ordered by UTF-8 byte order of their archive names. Archive timestamps are taken from explicit `createdAt` or `SOURCE_DATE_EPOCH`, normalized to a ZIP-representable UTC value. Extra fields, comments, platform-specific attributes, and nondeterministic metadata are omitted. Compression settings are fixed by the CLI specification and covered by golden tests.

## Paths and limits

Paths must be relative NFC-normalized strings. Empty paths or segments, `.`, `..`, leading `/`, trailing `/`, backslash, NUL, control characters, percent-encoded separators, symlinks, duplicate paths, case-fold collisions, and NFC collisions are rejected.

Limits:

- capsule: 100 MB
- expanded content: 250 MB
- one file: 50 MB
- files: 10,000

The verifier checks declared and observed sizes while streaming and stops immediately when a limit is exceeded.
