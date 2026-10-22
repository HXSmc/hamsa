-- Single source of the data contract (docs/kickoff/06-backend-schema.md). Tables are added by the owning task.
CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
INSERT INTO schema_version (version) SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_version);
