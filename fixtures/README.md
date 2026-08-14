# Shared fixtures

Fixtures are a platform-neutral security contract consumed by TypeScript, Android, and iOS tests.

Each fixture receives a stable ID and an entry in `expected-results.json` containing whether it is accepted and, when rejected, the expected `WebCapsuleErrorCode`. Generated binary capsules must have a documented deterministic generation command.

Large ZIP bombs are not committed. Tests generate bounded archives that exceed test-specific limits while preserving the same validation path.
