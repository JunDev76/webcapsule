# WebCapsule CLI

`@webcapsule/cli` creates and validates WebCapsule v1 artifacts. It packages an existing static web build directory; it does not crawl remote sites or update a React Native application bundle.

## Install

The package is not published yet. In this repository, build and invoke it with pnpm:

```bash
pnpm install
pnpm --filter @webcapsule/cli build
node packages/cli/dist/index.js --help
```

After publication, the intended project-local invocation is:

```bash
pnpm add -D @webcapsule/cli
pnpm exec webcapsule --help
```

The examples below use `webcapsule` for readability.

## Complete workflow

### 1. Generate a signing key

```bash
webcapsule keygen --out ./keys
```

This creates exactly:

```text
keys/private.pem  # Ed25519 PKCS#8 PEM, mode 0600
keys/public.pem   # Ed25519 SPKI PEM, mode 0644
```

The command does not derive a key ID. Select a stable key ID explicitly and configure the same ID with the corresponding public key in the host application.

If either output file already exists, the command fails without replacing it. There is no force or overwrite option.

> Keep `private.pem` outside applications, capsules, source control, logs, and public build artifacts. Distribute only `public.pem` to applications that trust artifacts signed by this key.

### 2. Build the static web content

First produce a static site directory with the web framework of your choice. The directory must contain regular files only; symbolic links and special files are rejected.

```bash
webcapsule build ./dist \
  --id com.example.guide \
  --version 1.0.0 \
  --entry index.html \
  --minimum-runtime-version 1.0.0 \
  --key-id release-2027 \
  --private-key ./keys/private.pem \
  --created-at 2027-03-01T12:00:00Z \
  --out ./releases/guide-1.0.0.capsule
```

All options shown above are required except `--created-at`. When `--created-at` is omitted, `SOURCE_DATE_EPOCH` is required:

```bash
SOURCE_DATE_EPOCH=1803902400 webcapsule build ./dist \
  --id com.example.guide \
  --version 1.0.0 \
  --entry index.html \
  --minimum-runtime-version 1.0.0 \
  --key-id release-2027 \
  --private-key ./keys/private.pem \
  --out ./releases/guide-1.0.0.capsule
```

Timestamp rules are exact:

- `--created-at`, when present, takes precedence over `SOURCE_DATE_EPOCH`.
- The accepted text format is `YYYY-MM-DDTHH:mm:ssZ`.
- The second must be even because ZIP DOS timestamps have two-second precision.
- `SOURCE_DATE_EPOCH` must be a non-negative base-10 integer representing an even Unix second.
- The timestamp must be representable by ZIP DOS time, from 1980 through 2107.
- If neither timestamp source is provided, the build fails. The current time is never used implicitly.

The builder uses a fixed WebCapsule v1 policy:

```json
{
  "network": { "mode": "deny" },
  "navigation": { "externalOrigins": [] },
  "bridgeCapabilities": []
}
```

It creates deterministic ZIP metadata and publishes the output only after reopening and validating the generated archive. Existing output is never replaced.

### 3. Inspect metadata without establishing trust

```bash
webcapsule inspect ./releases/guide-1.0.0.capsule
webcapsule inspect ./releases/guide-1.0.0.capsule --json
```

JSON output includes:

```json
{
  "trust": "unverified",
  "capsuleId": "com.example.guide",
  "version": "1.0.0",
  "keyId": "release-2027",
  "entry": "index.html",
  "createdAt": "2027-03-01T12:00:00Z",
  "fileCount": 4,
  "declaredBytes": 182930
}
```

`inspect` performs bounded archive and manifest structure checks, including decompression and CRC checks. It does **not** verify the Ed25519 signature or compare content SHA-256 values. Its result must not be treated as trusted or verified.

### 4. Verify the capsule

```bash
webcapsule verify ./releases/guide-1.0.0.capsule \
  --public-key ./keys/public.pem \
  --expected-id com.example.guide \
  --expected-key-id release-2027 \
  --runtime-version 1.0.0 \
  --json
```

Only `--public-key` is required. The expected ID, expected key ID, and runtime version options add explicit host constraints and are recommended in automated release checks.

A successful JSON result has this shape:

```json
{
  "verified": true,
  "capsuleId": "com.example.guide",
  "version": "1.0.0",
  "keyId": "release-2027",
  "entry": "index.html",
  "createdAt": "2027-03-01T12:00:00Z",
  "fileCount": 4,
  "declaredBytes": 182930
}
```

`verify` checks the archive profile, paths and limits, canonical manifest, Ed25519 signature, exact manifest/archive file set, every observed file size, and every file SHA-256 value. It does not install or activate the capsule.

### 5. Create a signed update index

Create one strict release descriptor per capsule:

```json
{
  "version": "1.0.0",
  "url": "https://example.com/guide/guide-1.0.0.capsule",
  "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "size": 182930,
  "minimumRuntimeVersion": "1.0.0"
}
```

Then sign the index:

```bash
webcapsule index \
  --id com.example.guide \
  --channel stable \
  --key-id release-2027 \
  --private-key ./keys/private.pem \
  --release ./releases/1.0.0.json \
  --release ./releases/1.1.0.json \
  --out ./releases/stable.json
```

At least one `--release` is required. Every descriptor must provide all five fields and no additional fields. URLs must use HTTPS. The command does not read a capsule or contact a URL to infer missing release information.

Releases are sorted by descending SemVer precedence. Versions with equivalent precedence, including versions differing only in build metadata, are rejected as ambiguous duplicates. Existing index output is never replaced.

## Output and errors

Normal machine-readable output is written to stdout when `--json` is supported. Expected failures are written to stderr in this form:

```text
ERROR_CODE: explanation
```

The process exits with a non-zero status on failure. Stable CLI error codes include:

| Code                      | Meaning                                                                      |
| ------------------------- | ---------------------------------------------------------------------------- |
| `OUTPUT_EXISTS`           | A protected output path already exists.                                      |
| `INVALID_ARGUMENT`        | A command option or explicit verification constraint is invalid.             |
| `INVALID_TIMESTAMP`       | The build timestamp does not satisfy the exact v1 rules.                     |
| `INVALID_INPUT`           | An input directory, file, or release descriptor is unavailable or forbidden. |
| `INVALID_PRIVATE_KEY`     | The key is not one canonical Ed25519 PKCS#8 PEM block.                       |
| `INVALID_PUBLIC_KEY`      | The key is not one canonical Ed25519 SPKI PEM block.                         |
| `LIMIT_EXCEEDED`          | An archive, file, expanded-size, or entry-count limit was exceeded.          |
| `INVALID_ARCHIVE_PROFILE` | The ZIP or metadata does not match the WebCapsule v1 profile.                |
| `SIGNATURE_MISMATCH`      | The manifest signature is invalid for the supplied public key.               |
| `HASH_MISMATCH`           | An observed content hash does not match the manifest.                        |
| `ID_MISMATCH`             | The capsule ID differs from `--expected-id`.                                 |
| `KEY_ID_MISMATCH`         | The key ID differs from `--expected-key-id`.                                 |
| `RUNTIME_INCOMPATIBLE`    | The requested runtime does not meet the minimum version.                     |

Format validation may also return stable codes such as `INVALID_PATH`, `DUPLICATE_PATH`, `CASE_COLLISION`, `DUPLICATE_JSON_KEY`, or `INVALID_VERSION`.

## Security notes

- Treat all capsules, manifests, release descriptors, and update indexes as untrusted input.
- Run `verify`, not `inspect`, before distributing or installing a capsule.
- Protect the signing key independently from the public artifact host.
- A successful CLI verification establishes artifact integrity for the supplied key and constraints. It does not grant web content native capabilities or make arbitrary web content safe.
- WebCapsule v1 downloads complete `.capsule` files. CAS in the native runtime is for installed-storage deduplication, not network delta updates.

See also:

- [`../specs/capsule-format-v1.md`](../specs/capsule-format-v1.md)
- [`../specs/update-index-v1.md`](../specs/update-index-v1.md)
- [`../specs/security-model.md`](../specs/security-model.md)
- [`../SECURITY.md`](../SECURITY.md)
