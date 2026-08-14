# ADR 0002: Signing and canonicalization

- Status: Accepted

## Decision

Capsule manifests and update indexes use RFC 8785 JSON Canonicalization Scheme and domain-separated Ed25519 signatures. SHA-256 identifies content. Keys use PKCS#8/SPKI PEM, signatures use standard Base64, and hashes use lowercase hexadecimal.

## Consequences

TypeScript, Kotlin, and Swift implementations must pass shared byte-level golden fixtures. Cryptographic primitives are provided by reviewed libraries or platform APIs, never custom implementations.
