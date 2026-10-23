"""Embedding-model shootout on the same chunks + gold set: dense-only and dense+BM25 (RRF) recall@5."""
import json
import time
from pathlib import Path

import numpy as np

from hamsa_brain.config import DATA_DIR
from hamsa_brain.index import store

# query/passage prompts per model family (from each model card)
MODELS = {
    "intfloat/multilingual-e5-small": ("query: ", "passage: "),
    "intfloat/multilingual-e5-base": ("query: ", "passage: "),
    "BAAI/bge-m3": ("", ""),
    "Qwen/Qwen3-Embedding-0.6B": ("Instruct: Given a question asked in a meeting, retrieve the passage that answers it\nQuery: ", ""),
}


def _bm25_ids(db, q: str, pool: int) -> list[int]:
    fq = store._fts_query(q)
    if not fq:
        return []
    return [r for (r,) in db.execute(
        "SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY bm25(chunks_fts) LIMIT ?", (fq, pool))]


def shootout(db, gold: Path, models: list[str], k: int = 5) -> list[dict]:
    from sentence_transformers import SentenceTransformer

    rows = [json.loads(line) for line in gold.read_text().splitlines() if line.strip()]
    chunk_rows = db.execute(
        "SELECT c.id, s.path, c.heading, c.text FROM chunks c JOIN sources s ON s.id=c.source_id ORDER BY c.id").fetchall()
    ids = np.array([r[0] for r in chunk_rows])
    meta = {r[0]: (r[1], r[3]) for r in chunk_rows}
    out = []
    for name in models:
        qp, pp = MODELS[name]
        m = SentenceTransformer(name, device="cpu")
        cache = DATA_DIR / "cache" / (name.replace("/", "__") + f"-{len(ids)}.npy")
        if cache.exists():
            P = np.load(cache)
        else:
            t = time.time()
            P = m.encode([f"{pp}{h}\n{x}" for _, _, h, x in chunk_rows], normalize_embeddings=True, batch_size=16)
            cache.parent.mkdir(parents=True, exist_ok=True)
            np.save(cache, P)
            print(f"{name}: embedded {len(ids)} chunks in {time.time() - t:.0f}s", flush=True)
        t = time.time()
        Q = m.encode([qp + r["q"] for r in rows], normalize_embeddings=True)
        q_ms = (time.time() - t) / len(rows) * 1000
        res = {"model": name, "query_ms_cpu": round(q_ms), "dim": P.shape[1]}
        for mode in ("dense", "hybrid"):
            per_lang: dict[str, list[int]] = {}
            for row, qv in zip(rows, Q):
                dense = ids[np.argsort(-(P @ qv))[:30]].tolist()
                if mode == "dense":
                    top = dense[:k]
                else:
                    sc: dict[int, float] = {}
                    for lst in (dense, _bm25_ids(db, row["q"], 30)):
                        for r, cid in enumerate(lst):
                            sc[cid] = sc.get(cid, 0) + 1 / (store.RRF_K + r)
                    top = sorted(sc, key=sc.get, reverse=True)[:k]
                hit = any(
                    any(e in meta[c][0] for e in row["expect"])
                    and (not row.get("expect_text") or row["expect_text"].lower() in meta[c][1].lower())
                    for c in top)
                per_lang.setdefault(row.get("lang", "?"), []).append(int(hit))
            for lang, v in per_lang.items():
                res[f"{mode}_{lang}"] = round(sum(v) / len(v), 2)
            allv = [x for v in per_lang.values() for x in v]
            res[f"{mode}_all"] = round(sum(allv) / len(allv), 2)
        print(json.dumps(res), flush=True)
        out.append(res)
    return out
