"""T15a: questions the overlay missed (no card, or thumbs-down) become draft cards for the owner to review."""
import json
import sqlite3
import time
from pathlib import Path

from hamsa_brain.cards.build import CARDS_PROMPT, valid_card
from hamsa_brain.index import store
from hamsa_brain.index.doc2query import _claude, _parse

PASSAGES_PER_QUESTION = 5


def missed_questions(live_db: Path, meeting_id: str) -> list[str]:
    db = sqlite3.connect(live_db)
    conf, allowed = db.execute(
        "SELECT confidential, claude_allowed FROM meetings WHERE id=?", (meeting_id,)).fetchone()
    if conf and not allowed:
        return []
    rows = db.execute(
        """SELECT DISTINCT q.text FROM questions q
           LEFT JOIN answer_events a ON a.question_id = q.id
           WHERE q.meeting_id = ? AND (q.matched_card_id IS NULL OR a.rating = -1)""", (meeting_id,)).fetchall()
    return [t for (t,) in rows if t and t.strip()]


def learn(live_db: Path, meeting_id: str, idx, cdb, pid: str, project_name: str, embedder, ask=_claude) -> dict:
    qs = missed_questions(live_db, meeting_id)
    if not qs:
        return {"questions": 0, "drafts": 0}
    passages: dict[int, str] = {}
    for q in qs:
        for h in store.search(idx, pid, q, embedder.query(q), k=PASSAGES_PER_QUESTION):
            passages.setdefault(h["chunk_id"], f"({h['heading']})\n{h['text']}")
    agenda = "Questions that were actually asked and need cards:\n" + "\n".join(f"- {q}" for q in qs)
    body = "\n\n".join(f"[{cid}] {text}" for cid, text in passages.items())
    raw = _parse(ask(CARDS_PROMPT.format(project=project_name, agenda=agenda, passages=body), "sonnet"))
    drafts = [v for c in raw.get("cards", []) if (v := valid_card(c, set(passages)))]
    now = int(time.time())
    for c in drafts:
        cid = cdb.execute(
            "INSERT INTO cards(project_id, question_en, question_ar, paraphrases, answer_en, answer_ar_sa, "
            "source_chunk_ids, status, origin, updated_at) VALUES (?,?,?,?,?,?,?, 'pending_review', 'learned', ?)",
            (pid, c["question_en"], c["question_ar"], json.dumps(c["paraphrases"], ensure_ascii=False),
             c["answer_en"], c["answer_ar_sa"], json.dumps(c["sources"]), now)).lastrowid
        texts = [c["question_en"], c["question_ar"], *c["paraphrases"]]
        for n, v in enumerate(embedder.passages_as_queries(texts)):
            cdb.execute("INSERT INTO card_vectors(card_id, n, embedding) VALUES (?,?,?)", (cid, n, store.pack(v)))
    cdb.commit()
    return {"questions": len(qs), "drafts": len(drafts)}
