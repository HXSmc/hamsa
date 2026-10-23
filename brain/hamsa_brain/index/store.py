"""index.sqlite: open/migrate, write chunks, hybrid search (BM25 + vector, reciprocal-rank fusion)."""
import json
import sqlite3
import struct
import time
from importlib.resources import files
from pathlib import Path

import numpy as np
import sqlite_vec

from hamsa_brain.index.chunk import detect_lang
from hamsa_brain.index.embed import DIM

RRF_K = 60


def pack(vec: list[float]) -> bytes:
    return struct.pack(f"{len(vec)}f", *vec)


def open_index(path: Path | str) -> sqlite3.Connection:
    db = sqlite3.connect(path)
    db.enable_load_extension(True)
    sqlite_vec.load(db)
    db.enable_load_extension(False)
    db.execute("PRAGMA foreign_keys = ON")
    schema = files("hamsa_brain.schema")
    for name in ("001_init.sql", "002_index.sql", "003_questions.sql"):
        db.executescript(schema.joinpath(name).read_text())
    db.execute(f"CREATE VIRTUAL TABLE IF NOT EXISTS chunks_vec USING vec0(embedding float[{DIM}])")
    return db


def upsert_project(db, pid: str, name: str, globs: list[str]) -> None:
    db.execute(
        "INSERT INTO projects(id, name, doc_globs, updated_at) VALUES (?,?,?,?) "
        "ON CONFLICT(id) DO UPDATE SET name=excluded.name, doc_globs=excluded.doc_globs, updated_at=excluded.updated_at",
        (pid, name, json.dumps(globs), int(time.time())),
    )


def source_sha(db, pid: str, path: str) -> str | None:
    row = db.execute("SELECT sha256 FROM sources WHERE project_id=? AND path=?", (pid, path)).fetchone()
    return row[0] if row else None


def delete_source(db, pid: str, path: str) -> None:
    for (cid,) in db.execute(
        "SELECT c.id FROM chunks c JOIN sources s ON s.id=c.source_id WHERE s.project_id=? AND s.path=?", (pid, path)
    ).fetchall():
        db.execute("INSERT INTO chunks_fts(chunks_fts, rowid, heading, text) SELECT 'delete', id, heading, text FROM chunks WHERE id=?", (cid,))
        db.execute("DELETE FROM chunks_vec WHERE rowid=?", (cid,))
    db.execute("DELETE FROM sources WHERE project_id=? AND path=?", (pid, path))


def write_source(db, pid: str, path: str, sha: str, mtime: int, chunks, vectors) -> None:
    delete_source(db, pid, path)
    sid = db.execute(
        "INSERT INTO sources(project_id, path, sha256, mtime) VALUES (?,?,?,?)", (pid, path, sha, mtime)
    ).lastrowid
    for ch, vec in zip(chunks, vectors, strict=True):
        cid = db.execute(
            "INSERT INTO chunks(source_id, heading, text, lang, ord) VALUES (?,?,?,?,?)",
            (sid, ch.heading, ch.text, ch.lang, ch.ord),
        ).lastrowid
        db.execute("INSERT INTO chunks_fts(rowid, heading, text) VALUES (?,?,?)", (cid, ch.heading, ch.text))
        blob = pack(vec)
        db.execute("INSERT INTO chunks_vec(rowid, embedding) VALUES (?,?)", (cid, blob))
        db.execute("INSERT INTO chunk_vectors(chunk_id, embedding) VALUES (?,?)", (cid, blob))


def write_questions(db, chunk_id: int, qs: list[str], vecs) -> None:
    db.executemany(
        "INSERT INTO chunk_questions(chunk_id, q, lang, embedding) VALUES (?,?,?,?)",
        [(chunk_id, q, detect_lang(q), pack(v)) for q, v in zip(qs, vecs, strict=True)],
    )


def _question_matrix(db, pid: str):
    rows = db.execute(
        "SELECT q.chunk_id, q.embedding FROM chunk_questions q JOIN chunks c ON c.id=q.chunk_id "
        "JOIN sources s ON s.id=c.source_id WHERE s.project_id=?", (pid,)).fetchall()
    if not rows:
        return None, None
    return np.array([r[0] for r in rows]), np.frombuffer(b"".join(r[1] for r in rows), dtype=np.float32).reshape(len(rows), DIM)


def _fts_query(q: str) -> str:
    # OR of quoted tokens: BM25 still ranks chunks matching more terms higher.
    toks = [t for t in "".join(c if c.isalnum() else " " for c in q).split() if len(t) > 1]
    return " OR ".join(f'"{t}"' for t in toks)


def search(db, pid: str, q: str, qvec: list[float], k: int = 5, pool: int = 30) -> list[dict]:
    ranks: dict[int, float] = {}
    fq = _fts_query(q)
    if fq:
        bm25 = db.execute(
            "SELECT f.rowid FROM chunks_fts f JOIN chunks c ON c.id=f.rowid JOIN sources s ON s.id=c.source_id "
            "WHERE chunks_fts MATCH ? AND s.project_id=? ORDER BY bm25(chunks_fts) LIMIT ?",
            (fq, pid, pool),
        ).fetchall()
        for r, (cid,) in enumerate(bm25):
            ranks[cid] = ranks.get(cid, 0) + 1 / (RRF_K + r)
    # vec0 KNN has no join filter, so over-fetch and filter by project after.
    knn = db.execute(
        "SELECT v.rowid FROM chunks_vec v WHERE v.embedding MATCH ? AND k = ?", (pack(qvec), pool * 4)
    ).fetchall()
    in_project = {
        cid
        for (cid,) in db.execute(
            f"SELECT c.id FROM chunks c JOIN sources s ON s.id=c.source_id WHERE s.project_id=? AND c.id IN ({','.join('?' * len(knn)) or 'NULL'})",
            (pid, *[c for (c,) in knn]),
        )
    }
    for r, cid in enumerate([c for (c,) in knn if c in in_project][:pool]):
        ranks[cid] = ranks.get(cid, 0) + 1 / (RRF_K + r)
    # doc2query: nearest generated questions, best rank per chunk.
    qids, qmat = _question_matrix(db, pid)
    if qmat is not None:
        seen: list[int] = []
        for i in np.argsort(-(qmat @ np.asarray(qvec, dtype=np.float32))):
            cid = int(qids[i])
            if cid not in seen:
                seen.append(cid)
            if len(seen) == pool:
                break
        for r, cid in enumerate(seen):
            ranks[cid] = ranks.get(cid, 0) + 1 / (RRF_K + r)
    top = sorted(ranks, key=ranks.get, reverse=True)[:k]
    out = []
    for cid in top:
        path, heading, text = db.execute(
            "SELECT s.path, c.heading, c.text FROM chunks c JOIN sources s ON s.id=c.source_id WHERE c.id=?", (cid,)
        ).fetchone()
        out.append({"chunk_id": cid, "path": path, "heading": heading, "text": text, "score": ranks[cid]})
    return out
