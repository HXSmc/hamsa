import json
import sqlite3

from hamsa_brain.cards.build import open_cards
from hamsa_brain.index import store
from hamsa_brain.index.refresh import refresh
from hamsa_brain.learn.loop import learn, missed_questions
from test_index import FakeEmbedder, make_vault, project


def live_db(tmp_path, confidential=0, allowed=1):
    p = tmp_path / "live.sqlite"
    db = sqlite3.connect(p)
    db.executescript("""
        CREATE TABLE meetings(id TEXT, confidential INT, claude_allowed INT);
        CREATE TABLE questions(id INTEGER PRIMARY KEY, meeting_id TEXT, text TEXT, matched_card_id INT);
        CREATE TABLE answer_events(id INTEGER PRIMARY KEY, question_id INT, rating INT);
    """)
    db.execute("INSERT INTO meetings VALUES ('m1', ?, ?)", (confidential, allowed))
    db.executemany("INSERT INTO questions VALUES (?,?,?,?)", [
        (1, "m1", "which GPU do you run", None),      # no card -> learn
        (2, "m1", "كم السعر", 7),                      # card matched but thumbs down -> learn
        (3, "m1", "who are you", 8),                   # card matched and fine -> skip
    ])
    db.executemany("INSERT INTO answer_events(question_id, rating) VALUES (?,?)", [(2, -1), (3, 1)])
    db.commit()
    return p


def test_missed_questions(tmp_path):
    assert sorted(missed_questions(live_db(tmp_path), "m1")) == ["which GPU do you run", "كم السعر"]
    local_only = tmp_path / "local-only"
    local_only.mkdir()
    assert missed_questions(live_db(local_only, confidential=1, allowed=0), "m1") == []


def test_learn_writes_pending_review_cards(tmp_path):
    v = make_vault(tmp_path)
    idx = store.open_index(tmp_path / "index.sqlite")
    emb = FakeEmbedder()
    emb.passages_as_queries = emb.passages
    refresh(project(v), idx, emb, tmp_path / "pii.txt")
    gpu = idx.execute("SELECT id FROM chunks WHERE text LIKE '%L4%'").fetchone()[0]

    def fake(prompt, model):
        assert "which GPU do you run" in prompt
        return json.dumps({"cards": [{"question_en": "Which GPU?", "question_ar": "وش الـGPU؟", "paraphrases": [],
                                      "answer_en": "L4.", "answer_ar_sa": "L4.", "sources": [gpu]}]})

    cdb = open_cards(tmp_path / "cards.sqlite")
    res = learn(live_db(tmp_path), "m1", idx, cdb, "taweed", "Taweed", emb, ask=fake)
    assert res == {"questions": 2, "drafts": 1}
    assert cdb.execute("SELECT status, origin FROM cards").fetchall() == [("pending_review", "learned")]
