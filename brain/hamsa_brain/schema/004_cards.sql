-- cards.sqlite (brain -> Mac): prepared answers. docs/kickoff/06-backend-schema.md
CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
INSERT INTO schema_version (version) SELECT 4 WHERE NOT EXISTS (SELECT 1 FROM schema_version);
CREATE TABLE IF NOT EXISTS cards (
  id INTEGER PRIMARY KEY,
  project_id TEXT NOT NULL,
  question_en TEXT NOT NULL,
  question_ar TEXT NOT NULL,
  paraphrases TEXT NOT NULL,          -- JSON list
  answer_en TEXT NOT NULL,
  answer_ar_sa TEXT NOT NULL,
  source_chunk_ids TEXT NOT NULL,     -- JSON list, >= 1 (index.sqlite chunks.id)
  status TEXT NOT NULL CHECK(status IN ('active','pending_review','retired')),
  origin TEXT NOT NULL CHECK(origin IN ('predicted','learned','manual')),
  uses INTEGER NOT NULL DEFAULT 0,
  thumbs_up INTEGER NOT NULL DEFAULT 0,
  thumbs_down INTEGER NOT NULL DEFAULT 0,
  version INTEGER NOT NULL DEFAULT 1,
  updated_at INTEGER NOT NULL,
  CHECK(json_array_length(source_chunk_ids) >= 1)
);
CREATE INDEX IF NOT EXISTS cards_project_status ON cards(project_id, status);
CREATE TABLE IF NOT EXISTS card_vectors (
  card_id INTEGER NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
  n INTEGER NOT NULL,                 -- 0 question_en, 1 question_ar, 2.. paraphrases (max 12)
  embedding BLOB NOT NULL,            -- 384 x float32, prefix "query: "
  PRIMARY KEY(card_id, n)
);
