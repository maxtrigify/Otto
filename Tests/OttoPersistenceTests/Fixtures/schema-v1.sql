CREATE TABLE schema_migrations (
  version INTEGER PRIMARY KEY,
  applied_at TEXT NOT NULL
);
INSERT INTO schema_migrations(version, applied_at) VALUES (1, '2025-01-01T00:00:00Z');
CREATE TABLE workspace_snapshots (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  payload BLOB NOT NULL,
  updated_at TEXT NOT NULL
);
