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
