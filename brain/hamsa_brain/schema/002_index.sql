-- index.sqlite (brain -> Mac). docs/kickoff/06-backend-schema.md
CREATE TABLE IF NOT EXISTS projects (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  doc_globs TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sources (
  id INTEGER PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id),
  path TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  mtime INTEGER,
  UNIQUE(project_id, path)
);
CREATE TABLE IF NOT EXISTS chunks (
  id INTEGER PRIMARY KEY,
  source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
  heading TEXT,
  text TEXT NOT NULL,
  lang TEXT CHECK(lang IN ('ar','en','mixed')),
  ord INTEGER
);
CREATE INDEX IF NOT EXISTS chunks_source ON chunks(source_id);
CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
  heading, text, content='chunks', content_rowid='id', tokenize='unicode61 remove_diacritics 2'
);
-- Raw vectors for the Mac (no sqlite-vec there); chunks_vec is created in code (needs the extension).
CREATE TABLE IF NOT EXISTS chunk_vectors (
  chunk_id INTEGER PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
  embedding BLOB NOT NULL
);
UPDATE schema_version SET version = 2 WHERE version < 2;
