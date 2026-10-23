"""recall@k on a gold set: jsonl lines {"q": ..., "lang": "ar"|"en", "expect": ["path substring", ...]}.

A hit = any of the top-k chunks comes from a file whose path contains one of the expected substrings
and, if "expect_text" is given, whose text contains it.
"""
import json
from pathlib import Path

from hamsa_brain.index import store


def recall_at_k(db, embedder, pid: str, gold: Path, k: int = 5) -> dict:
    rows = [json.loads(line) for line in gold.read_text().splitlines() if line.strip()]
    by_lang: dict[str, list[int]] = {}
    misses = []
    for row in rows:
        hits = store.search(db, pid, row["q"], embedder.query(row["q"]), k=k)
        ok = any(
            any(e in h["path"] for e in row["expect"])
            and (not row.get("expect_text") or row["expect_text"].lower() in h["text"].lower())
            for h in hits
        )
        by_lang.setdefault(row.get("lang", "?"), []).append(int(ok))
        if not ok:
            misses.append({"q": row["q"], "got": [Path(h["path"]).name for h in hits]})
    total = [x for v in by_lang.values() for x in v]
    return {
        "n": len(total),
        f"recall@{k}": round(sum(total) / len(total), 3),
        **{f"recall@{k}_{lang}": round(sum(v) / len(v), 3) for lang, v in by_lang.items()},
        "misses": misses,
    }


JUDGE_PROMPT = """For each question below you get 5 retrieved passages from a startup's notes.
Say which passage (1-5) actually contains the answer, or 0 if none does. Be strict: the passage must state
the fact asked for, not just mention the topic.
Reply with ONLY a JSON object mapping question number to passage number, e.g. {{"1": 3, "2": 0}}.

{items}"""


def judged_recall(db, embedder, pid: str, gold: Path, k: int = 5, ask=None, batch: int = 10) -> dict:
    """recall@k judged by Claude: any of the top-k passages answers the question (not only the gold chunk)."""
    from hamsa_brain.index.doc2query import _claude, _parse

    ask = ask or _claude
    rows = [json.loads(line) for line in gold.read_text().splitlines() if line.strip()]
    verdicts: list[int] = []
    for i in range(0, len(rows), batch):
        part = rows[i : i + batch]
        items = []
        for n, row in enumerate(part, 1):
            hits = store.search(db, pid, row["q"], embedder.query(row["q"]), k=k)
            passages = "\n".join(f"  ({j}) {h['text'][:700]}" for j, h in enumerate(hits, 1))
            items.append(f"Question {n}: {row['q']}\n{passages}")
        reply = _parse(ask(JUDGE_PROMPT.format(items="\n\n".join(items)), "sonnet"))
        verdicts += [int(bool(int(reply.get(str(n), 0)))) for n in range(1, len(part) + 1)]
    by_lang: dict[str, list[int]] = {}
    for row, v in zip(rows, verdicts):
        by_lang.setdefault(row.get("lang", "?"), []).append(v)
    return {"n": len(rows), f"judged@{k}": round(sum(verdicts) / len(verdicts), 3),
            **{f"judged@{k}_{lang}": round(sum(v) / len(v), 3) for lang, v in by_lang.items()}}
