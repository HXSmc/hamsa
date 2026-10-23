"""Claude writes, offline, the questions each chunk answers (Saudi Arabic + English).

Live search then matches question-to-question in the asker's language, which small on-device embedders
do well, instead of dialect-Arabic question to English prose, which they do badly (T05 shootout).
"""
import json
import subprocess
from concurrent.futures import ThreadPoolExecutor

from hamsa_brain.index import store

MIN_CHARS = 120
BATCH = 25
PROMPT = """You index a startup's internal notes for a live meeting assistant.
For EACH passage below, write the questions an outsider (client, investor, partner) might ask on a call
that this passage answers. Write 2 in English and 2 in spoken Saudi Arabic dialect (e.g. وش، ليش، كم،
عندكم، تقدرون), keeping product and tech terms in English as Saudis say them. Paraphrase; do not copy
phrases. If a passage answers nothing useful (logs, boilerplate, link lists), return [] for it.
Reply with ONLY a JSON object mapping each passage id to its list of questions.

Passages:
"""


def _claude(prompt: str, model: str) -> str:
    out = subprocess.run(
        ["claude", "-p", "--model", model, "--output-format", "json"],
        input=prompt, capture_output=True, text=True, timeout=600, check=True,
    )
    return json.loads(out.stdout)["result"]


def _parse(reply: str) -> dict[str, list[str]]:
    start, end = reply.find("{"), reply.rfind("}")
    return json.loads(reply[start : end + 1]) if start != -1 else {}


def generate(db, pid: str, embedder, model: str = "haiku", workers: int = 4, ask=_claude) -> dict:
    """Generate questions for chunks of `pid` that have none yet. Re-runnable: done chunks are skipped."""
    todo = db.execute(
        "SELECT c.id, c.heading, c.text FROM chunks c JOIN sources s ON s.id=c.source_id "
        "WHERE s.project_id=? AND length(c.text)>=? AND c.id NOT IN (SELECT chunk_id FROM chunk_questions_done) "
        "ORDER BY c.id",
        (pid, MIN_CHARS),
    ).fetchall()
    batches = [todo[i : i + BATCH] for i in range(0, len(todo), BATCH)]

    def run(batch):
        body = "\n\n".join(f"[{cid}] ({heading})\n{text}" for cid, heading, text in batch)
        try:
            return batch, _parse(ask(PROMPT + body, model))
        except (subprocess.SubprocessError, json.JSONDecodeError, KeyError) as e:
            return batch, e

    stats = {"chunks": len(todo), "questions": 0, "failed_batches": 0}
    with ThreadPoolExecutor(workers) as pool:
        for batch, res in pool.map(run, batches):
            if isinstance(res, Exception):
                stats["failed_batches"] += 1
                continue
            for cid, _, _ in batch:
                qs = [q for q in res.get(str(cid), []) if isinstance(q, str) and q.strip()]
                if qs:
                    vecs = embedder.passages_as_queries(qs)
                    store.write_questions(db, cid, qs, vecs)
                    stats["questions"] += len(qs)
                db.execute("INSERT OR IGNORE INTO chunk_questions_done(chunk_id) VALUES (?)", (cid,))
            db.commit()
    return stats
