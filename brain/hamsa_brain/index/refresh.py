"""Walk a project's files, re-index only the ones whose content changed."""
import fnmatch
import glob
import hashlib
import subprocess
from pathlib import Path

from hamsa_brain.config import ALWAYS_EXCLUDE, DATA_DIR, Project
from hamsa_brain.index import store
from hamsa_brain.index.chunk import chunk_markdown
from hamsa_brain.index.pii import redact

TEXT_SUFFIXES = {".md", ".txt"}


def sync_git(p: Project) -> Path | None:
    """Sparse, shallow clone of the project's repo docs (owner's private repo, via gh auth)."""
    if not p.git:
        return None
    dest = DATA_DIR / "sources" / p.id
    if (dest / ".git").exists():
        subprocess.run(["git", "-C", str(dest), "pull", "-q", "--depth", "1"], check=True)
    else:
        dest.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["gh", "repo", "clone", p.git, str(dest), "--", "-q", "--depth", "1", "--filter=blob:none", "--sparse"],
            check=True,
        )
    if p.git_paths:
        subprocess.run(["git", "-C", str(dest), "sparse-checkout", "set", "--no-cone", *p.git_paths], check=True)
    return dest


def _excluded(path: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatch(path, pat) for pat in patterns)


def list_files(p: Project, repo_dir: Path | None) -> list[Path]:
    globs = [str(Path(g).expanduser()) for g in p.include]
    if repo_dir:
        globs += [str(repo_dir / "**" / "*.md")]
    excl = ALWAYS_EXCLUDE + [str(Path(e).expanduser()) for e in p.exclude]
    seen = set()
    for g in globs:
        for f in glob.glob(g, recursive=True):
            fp = Path(f)
            if fp.is_file() and fp.suffix in TEXT_SUFFIXES and not _excluded(f, excl):
                seen.add(fp.resolve())
    return sorted(seen)


def refresh(p: Project, db, embedder, pii_report: Path, force: bool = False) -> dict:
    repo_dir = sync_git(p)
    files = list_files(p, repo_dir)
    store.upsert_project(db, p.id, p.name, p.include)
    stats = {"files": len(files), "changed": 0, "removed": 0, "chunks": 0, "redacted": 0}
    report = []
    keep = set()
    for f in files:
        path = str(f)
        keep.add(path)
        raw = f.read_bytes()
        sha = hashlib.sha256(raw).hexdigest()
        if not force and store.source_sha(db, p.id, path) == sha:
            continue
        chunks = chunk_markdown(raw.decode("utf-8", errors="replace"), f.stem)
        for ch in chunks:
            ch.text, kinds = redact(ch.text)
            ch.heading, hk = redact(ch.heading)
            if kinds or hk:
                report.append(f"{path}\t{','.join(kinds + hk)}")
                stats["redacted"] += len(kinds) + len(hk)
        vectors = embedder.passages([f"{c.heading}\n{c.text}" for c in chunks]) if chunks else []
        store.write_source(db, p.id, path, sha, int(f.stat().st_mtime), chunks, vectors)
        stats["changed"] += 1
        stats["chunks"] += len(chunks)
    for (path,) in db.execute("SELECT path FROM sources WHERE project_id=?", (p.id,)).fetchall():
        if path not in keep:
            store.delete_source(db, p.id, path)
            stats["removed"] += 1
    db.commit()
    pii_report.parent.mkdir(parents=True, exist_ok=True)
    pii_report.write_text("\n".join(report) + ("\n" if report else ""))
    return stats
