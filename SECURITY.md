# Security policy

Otto runs AI agents with access to your files, terminals and browser sessions, so we take
security reports seriously.

## Reporting a vulnerability

Please **do not open a public issue**. Report it privately through
[GitHub security advisories](https://github.com/maxtrigify/Otto/security/advisories/new).
Include steps to reproduce, the Otto version, and the impact you expect.

We aim to acknowledge reports within three working days and will keep you updated until
the issue is fixed.

## Scope

In scope: the Otto app, `ottoctl`, the MCP and control-socket surface, the update
mechanism, and the mobile pairing and relay protocols.

The design assumptions are in [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md). In particular,
Otto exposes no public inbound port, treats tool and payload content as data rather than
authorization, and stores credentials only in the macOS Keychain.

## Updates

Release builds are signed and notarized, and update manifests are signed with Ed25519.
Only the public verification key is in this repository.
