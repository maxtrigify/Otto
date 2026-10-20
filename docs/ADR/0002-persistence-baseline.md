# ADR 0002: SQLite-backed workspace snapshots

- Status: Accepted for foundation slice
- Date: 2026-08-01

## Decision

Muse stores the authoritative workspace snapshot in SQLite behind an actor. Migration version 1 creates the migration ledger and atomic snapshot table. The snapshot payload is Codable JSON inside SQLite so the early domain model can evolve quickly without spreading storage concerns into the UI.

The next persistence iteration will normalise canvases, nodes, agent sessions, runs, and audit events into their planned tables. Snapshot decoding remains useful for crash-safe restoration fixtures and migration testing.

## Consequences

- Writes are serialized off the main actor and use SQLite transaction guarantees.
- The UI never reads or writes database records directly.
- Schema migration is versioned from the first runnable build.
- The initial schema is intentionally transitional rather than pretending the complete v1 data model is settled.
