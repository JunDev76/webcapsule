# Shared fixtures

Fixtures are a platform-neutral security contract consumed by TypeScript, Android, and iOS tests.

`expected-results.json` has `schemaVersion: 1` and a `fixtures` array. Every entry has:

- `id`: stable, unique identifier
- `kind`: one of `manifest`, `update-index`, `path`, `archive`, `registry`, `version-record`, `resource-request`, or `ready-message`
- exactly one input locator appropriate to the kind: currently `path` for committed files or `value` for inline path cases
- `accepted`: expected decision
- `errorCode`: required when `accepted` is false and forbidden when true
- `platforms`: non-empty subset of `typescript`, `android`, and `ios`; each listed implementation MUST execute the case

A `path` is relative to this directory and MUST name a committed fixture. Contract entries MUST NOT reserve paths for files that do not exist. Archive and native-runtime cases are added only with their concrete fixture or deterministic bounded generator.

Capsule entries additionally declare `verification.expectedCapsuleId`,
`verification.runtimeVersion`, and a fixture-relative `verification.trustedPublicKey`.
`verification.trustedKeyId` overrides the exact trusted-key map key only for key-ID
failure cases. Both TypeScript and Android runners interpret this same contract.

Run `pnpm fixtures:generate` to regenerate the committed capsule binaries using the
public TEST ONLY fixture key pair. Run `pnpm fixtures:check` to prove regeneration is
byte-identical. The checked-in private key provides no security and must never be used
outside tests.

Large ZIP bombs are not committed. Unit tests inject smaller limits and exercise the
same validation path with bounded files.
