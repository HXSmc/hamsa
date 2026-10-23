"""T06: before a meeting, Claude predicts likely questions and writes short sourced answers (cards).

1. Claude (haiku) turns the meeting title/agenda + project overview into ~15 search topics.
2. Hybrid search pulls the passages for those topics (index.sqlite).
3. Claude (sonnet) writes bilingual cards from those passages, citing passage ids.
4. Cards without a valid source, or missing a language, are dropped. No unsourced answers.
"""
import json
import sqlite3
import time
from importlib.resources import files
from pathlib import Path

from hamsa_brain.index import store
from hamsa_brain.index.doc2query import _claude, _parse

MAX_PARAPHRASES = 10
PER_TOPIC = 6
N_TOPICS = 25  # 15 gave 47 cards for Taweed (T06 target >= 50)
BATCH = 40

TOPICS_PROMPT = """You prepare a founder for a video call about their project "{project}".
Meeting: {agenda}
Project overview (excerpt):
{overview}

List {n_topics} short search queries covering what the other side will most likely ask (technical, product,
security, pricing, status). Mix English and spoken Saudi Arabic. Reply with ONLY a JSON object:
{{"topics": ["...", ...]}}"""

CARDS_PROMPT = """You write answer cards a founder glances at during a live call about "{project}".
Meeting: {agenda}
From the passages below, write cards for the questions the other side is most likely to ask.
Rules:
- Only facts stated in the passages. Each card cites the passage ids it uses in "sources" (>= 1).
- answer_en: max 3 short lines, plain words, numbers exact.
- answer_ar_sa: same facts in spoken Saudi (white dialect) Arabic, product/tech terms kept in English.
- question_en / question_ar: how a person would actually ask it (question_ar in Saudi dialect).
- paraphrases: 4-6 other ways to ask it, both languages.
- Skip passages that are logs, boilerplate or out of date notes. Do not repeat a question.
Reply with ONLY a JSON object: {{"cards": [{{"question_en": "", "question_ar": "", "paraphrases": [],
"answer_en": "", "answer_ar_sa": "", "sources": [id, ...]}}]}}

Passages:
{passages}"""


def open_cards(path: Path | str) -> sqlite3.Connection:
    db = sqlite3.connect(path)
    db.execute("PRAGMA foreign_keys = ON")
    db.executescript(files("hamsa_brain.schema").joinpath("004_cards.sql").read_text())
    return db


def _overview(idx, pid: str, chars: int = 4000) -> str:
    rows = idx.execute(
        "SELECT c.text FROM chunks c JOIN sources s ON s.id=c.source_id WHERE s.project_id=? "
        "ORDER BY length(s.path), c.ord LIMIT 12", (pid,)).fetchall()
    return "\n\n".join(t for (t,) in rows)[:chars]


def collect_passages(idx, pid: str, topics: list[str], embedder) -> dict[int, str]:
    out: dict[int, str] = {}
    for t in topics:
        for h in store.search(idx, pid, t, embedder.query(t), k=PER_TOPIC):
            out.setdefault(h["chunk_id"], f"({h['heading']})\n{h['text']}")
    return out


def valid_card(c: dict, allowed: set[int]) -> dict | None:
    need = ("question_en", "question_ar", "answer_en", "answer_ar_sa")
    if not all(isinstance(c.get(k), str) and c[k].strip() for k in need):
        return None
    src = [int(s) for s in c.get("sources", []) if str(s).isdigit() and int(s) in allowed]
    if not src:
        return None
    paras = [p for p in c.get("paraphrases", []) if isinstance(p, str) and p.strip()][:MAX_PARAPHRASES]
    return {**{k: c[k].strip() for k in need}, "paraphrases": paras, "sources": sorted(set(src))}


def build(idx, cdb, pid: str, project_name: str, agenda: str, embedder, ask=_claude) -> dict:
    agenda = agenda or f"General call about {project_name}"
    topics = _parse(ask(TOPICS_PROMPT.format(project=project_name, agenda=agenda, overview=_overview(idx, pid), n_topics=N_TOPICS), "haiku")).get("topics", [])
    passages = collect_passages(idx, pid, [agenda, *topics], embedder)
    ids = list(passages)
    cards, failed = [], 0
    for i in range(0, len(ids), BATCH):
        batch = ids[i : i + BATCH]
        body = "\n\n".join(f"[{cid}] {passages[cid]}" for cid in batch)
        try:
            raw = _parse(ask(CARDS_PROMPT.format(project=project_name, agenda=agenda, passages=body), "sonnet"))
        except Exception:  # one bad batch must not lose the rest
            failed += 1
            continue
        cards += [v for c in raw.get("cards", []) if (v := valid_card(c, set(batch)))]
    # Replace previous predicted cards; learned/manual cards stay.
    cdb.execute("DELETE FROM cards WHERE project_id=? AND origin='predicted'", (pid,))
    now = int(time.time())
    for c in cards:
        cid = cdb.execute(
            "INSERT INTO cards(project_id, question_en, question_ar, paraphrases, answer_en, answer_ar_sa, "
            "source_chunk_ids, status, origin, updated_at) VALUES (?,?,?,?,?,?,?, 'active', 'predicted', ?)",
            (pid, c["question_en"], c["question_ar"], json.dumps(c["paraphrases"], ensure_ascii=False),
             c["answer_en"], c["answer_ar_sa"], json.dumps(c["sources"]), now)).lastrowid
        texts = [c["question_en"], c["question_ar"], *c["paraphrases"]]
        for n, v in enumerate(embedder.passages_as_queries(texts)):
            cdb.execute("INSERT INTO card_vectors(card_id, n, embedding) VALUES (?,?,?)", (cid, n, store.pack(v)))
    cdb.commit()
    return {"topics": len(topics), "passages": len(ids), "cards": len(cards), "failed_batches": failed}


def stats(cdb, pid: str) -> dict:
    rows = cdb.execute(
        "SELECT question_en, question_ar, answer_en, answer_ar_sa, source_chunk_ids FROM cards "
        "WHERE project_id=? AND status='active'", (pid,)).fetchall()
    n = len(rows) or 1
    bilingual = sum(1 for r in rows if all(x.strip() for x in r[:4]))
    sourced = sum(1 for r in rows if json.loads(r[4]))
    return {"cards": len(rows), "bilingual": f"{100 * bilingual // n}%", "sources": f"{100 * sourced // n}%"}
