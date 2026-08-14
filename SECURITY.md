# Security Policy

## Supported versions

WebCapsule is pre-release software. Security support begins with the first published release.

## Reporting a vulnerability

Do not open a public issue for an undisclosed vulnerability. Report it privately through GitHub Security Advisories on `JunDev76/webcapsule`. Include affected versions, reproduction steps, impact, and any suggested remediation.

The maintainer will acknowledge a report within 7 days and coordinate disclosure after a fix is available. Never include private signing keys or sensitive capsule content in a report.

## Security boundary

Read `specs/security-model.md` before deployment. WebCapsule does not make untrusted web content safe to grant arbitrary native capabilities, and it does not protect a compromised host application or signing key.
