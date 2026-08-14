# Contributing to WebCapsule

## Development

Requirements: Node.js 22 LTS and pnpm 10.

```bash
pnpm install
pnpm format:check
pnpm lint
pnpm typecheck
pnpm test
pnpm build
```

Use one issue and one branch for each focused change. Include tests with behavior changes, especially valid and malicious fixtures for security validation. Keep public format types in `@webcapsule/format` and do not trust JavaScript validation in native code.

## Scope

Read `packages/plan.md`, the specifications, and ADRs before proposing a feature. React Native bundle OTA, native code updates, localhost servers, `file://`, CDN/dashboard services, Flutter, AI, and network delta downloads are outside v1.

## Pull requests

Explain the problem, implementation boundary, tests, security impact, and documentation changes. Confirm that dependencies use OSI-approved licenses and update `THIRD_PARTY_LICENSES.md` when adding one.
