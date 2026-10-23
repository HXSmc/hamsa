-- Questions each chunk answers, written offline by Claude (doc2query). Matched live question-to-question.
CREATE TABLE IF NOT EXISTS chunk_questions (
  id INTEGER PRIMARY KEY,
  chunk_id INTEGER NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
  q TEXT NOT NULL,
  lang TEXT CHECK(lang IN ('ar','en','mixed')),
  embedding BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS chunk_questions_chunk ON chunk_questions(chunk_id);
-- Chunks already sent to the generator (including ones that got no questions).
CREATE TABLE IF NOT EXISTS chunk_questions_done (
  chunk_id INTEGER PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE
);
UPDATE schema_version SET version = 3 WHERE version < 3;
