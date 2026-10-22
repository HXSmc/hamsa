"""`hamsa-brain` entry point. Each task adds its subcommand (index, cards, eval, summarize, learn, serve)."""
import argparse
import json
import sys
import time
from pathlib import Path

from hamsa_brain import __version__


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="hamsa-brain")
    p.add_argument("--version", action="version", version=f"hamsa-brain {__version__}")
    sub = p.add_subparsers(dest="cmd")

    idx = sub.add_parser("index", help="build / update index.sqlite").add_subparsers(dest="action", required=True)
    r = idx.add_parser("refresh", help="re-index changed files of a project")
    r.add_argument("--project", required=True)
    r.add_argument("--force", action="store_true", help="re-index every file (after chunk/redact changes)")

    s = sub.add_parser("search", help="hybrid search (debug)")
    s.add_argument("--project", required=True)
    s.add_argument("--k", type=int, default=5)
    s.add_argument("query")

    ev = sub.add_parser("eval", help="quality checks").add_subparsers(dest="action", required=True)
    e = ev.add_parser("retrieval", help="recall@k on a gold jsonl")
    e.add_argument("--set", required=True, type=Path)
    e.add_argument("--project", default="taweed")
    e.add_argument("--k", type=int, default=5)
    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.cmd is None:
        parser.print_help()
        return 0

    from hamsa_brain.config import DATA_DIR, index_path, load_projects
    from hamsa_brain.index import store
    from hamsa_brain.index.embed import E5Embedder

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    db = store.open_index(index_path())

    if args.cmd == "index":
        projects = load_projects()
        if args.project not in projects:
            sys.exit(f"unknown project {args.project!r}; known: {', '.join(projects)}")
        from hamsa_brain.index.refresh import refresh

        t = time.time()
        stats = refresh(projects[args.project], db, E5Embedder(), DATA_DIR / "index" / "pii-report.txt", force=args.force)
        print(json.dumps({**stats, "seconds": round(time.time() - t, 1)}))
    elif args.cmd == "search":
        emb = E5Embedder()
        for h in store.search(db, args.project, args.query, emb.query(args.query), k=args.k):
            print(f"{h['score']:.4f}  {Path(h['path']).name}  [{h['heading']}]\n        {h['text'][:160]!r}")
    elif args.cmd == "eval":
        from hamsa_brain.eval.retrieval import recall_at_k

        res = recall_at_k(db, E5Embedder(), args.project, args.set, args.k)
        for m in res.pop("misses"):
            print(f"MISS {m['q']}  -> {m['got']}", file=sys.stderr)
        print(" ".join(f"{k}={v}" for k, v in res.items()))
    return 0
