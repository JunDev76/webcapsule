# Capsule Format v1

Status: Draft

## Container

A capsule is a ZIP archive containing exactly:

```text
capsule.json
capsule.sig
files/<manifest path>
```

Unknown entries, directories, encrypted entries, symbolic links, and special files are rejected. ZIP entry names and manifest paths use UTF-8 and `/` separators. `capsule.json` has a 5 MiB uncompressed limit. `capsule.sig` is exactly 89 bytes: 88 standard Base64 characters encoding a 64-byte Ed25519 signature followed by one LF.

## Manifest

`capsule.json` is UTF-8 JSON with these required fields. Duplicate JSON object keys, missing fields, and additional fields at every object level are rejected:

- `formatVersion`: integer `1`
- `capsuleId`: stable reverse-domain identifier
- `version`: SemVer version
- `entry`: path present in `files`
- `createdAt`: exactly `YYYY-MM-DDTHH:mm:ssZ`; offsets, fractional seconds, invalid calendar values, and odd seconds are rejected
- `minimumRuntimeVersion`: SemVer version
- `keyId`: identifier selected by the host application
- `files`: complete ordered list of content files
- `policy`: network, navigation, and bridge declarations

Each file entry contains exactly `path`, lowercase hexadecimal `sha256`, non-negative integer `size`, and `mediaType`. Unknown filename extensions use `application/octet-stream`; builders must not guess another media type. A file missing from either the manifest or archive causes rejection. `entry` must name a manifest file. File entries are strictly ordered by ascending UTF-8 bytes of `path`.

Network and navigation origins are exact HTTPS origins without paths, queries, fragments, credentials, or trailing slashes. `deny` network policy has only `mode`; `allowlist` has exactly `mode` and `origins`. Origin lists and bridge capability lists contain no duplicates.

## Signing

The signature payload is:

```text
UTF8("WEBCAPSULE-MANIFEST-V1\n") + canonical_json(capsule.json)
```

Ed25519 signs the exact payload bytes. `capsule.sig` contains the standard Base64 encoding of the 64-byte signature followed by one LF. A public key is exactly one canonical `BEGIN PUBLIC KEY` SPKI PEM block and a private key is exactly one canonical `BEGIN PRIVATE KEY` PKCS#8 PEM block. Both require LF line endings, one final LF, and no surrounding whitespace or additional PEM blocks. SHA-256 values are 64 lowercase hexadecimal characters.

Canonical JSON follows RFC 8785 (JCS). Manifest values outside the I-JSON domain are rejected. Implementations must not reproduce cryptographic primitives themselves.

## Deterministic archives

The build timestamp is provided by `--created-at`; only when that option is absent may the builder read `SOURCE_DATE_EPOCH`. If neither exists, the build fails. The current clock is never used. The resulting timestamp must satisfy the exact `createdAt` rule above; there is no rounding or timezone conversion fallback.

ZIP entries are exactly ordered as `capsule.json`, `capsule.sig`, then `files/<path>` by ascending exact UTF-8 bytes of `<path>`. Entry names must round-trip through fatal UTF-8 decoding without byte changes. Compression is DEFLATE level 9. ZIP64, archive comments, entry comments, and central or local extra fields are prohibited. Entries use the Unix regular-file profile with mode `0644`; symlink and special-file modes are rejected. General-purpose flags are exactly UTF-8 (`0x0800`) with optional data descriptor (`0x0008`); every other bit is rejected. With a data descriptor, local CRC and sizes are zero and the validated central values are authoritative; without it local CRC and sizes exactly equal central values. Local and central names, flags, method, and DOS timestamp are identical. The DOS timestamp is the exact UTC `createdAt` value for every entry. Golden tests cover the complete profile.

`build` requires an explicit `--key-id`; it never derives one from a key file or fingerprint. `keygen` prints only the SHA-256 fingerprint of the generated public-key bytes and does not assign a key ID.

## Paths and limits

Paths must be relative NFC-normalized strings. Empty paths or segments, `.`, `..`, leading `/`, trailing `/`, backslash, NUL, control characters, percent-encoded separators, symlinks, duplicate paths, ASCII case-insensitive collisions, and NFC collisions are rejected. V1 case folding maps only ASCII `A` through `Z` to `a` through `z`; non-ASCII case folding is not performed.

Limits:

- capsule: 100 MB
- expanded content: 250 MB
- one file: 50 MB
- files: 10,000

The verifier checks declared and observed sizes while streaming and stops immediately when a limit is exceeded.
