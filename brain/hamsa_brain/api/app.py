"""Brain HTTP API (T07). Bound to the Tailscale IP only; every route needs the bearer token."""
import hmac
import secrets
import sqlite3
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response
from fastapi.responses import FileResponse

from hamsa_brain import config

TOKEN_PATH = Path("~/.config/hamsa/token").expanduser()
SYNC_FILES = {"index.sqlite", "cards.sqlite"}


def load_or_create_token(path: Path = TOKEN_PATH) -> str:
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch(mode=0o600)
        path.write_text(secrets.token_urlsafe(32))
    return path.read_text().strip()


def snapshot(src: Path, dest: Path) -> Path:
    """Consistent copy via the SQLite backup API, refreshed only when the source changed."""
    if not dest.exists() or dest.stat().st_mtime_ns < src.stat().st_mtime_ns:
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_suffix(".tmp")
        with sqlite3.connect(src) as s, sqlite3.connect(tmp) as d:
            s.backup(d)
        tmp.replace(dest)
    return dest


def create_app(token: str, runner=None, data_dir: Path | None = None) -> FastAPI:
    """`runner(kind, params) -> dict` does the heavy work; injected so tests need no models or Claude."""
    data = data_dir or config.DATA_DIR
    app = FastAPI(title="hamsa-brain", docs_url=None, redoc_url=None, openapi_url=None)
    pool = ThreadPoolExecutor(1)  # heavy jobs run one at a time
    jobs: dict[str, dict] = {}

    def auth(authorization: str = Header(default="")):
        if not hmac.compare_digest(authorization.encode(), f"Bearer {token}".encode()):
            raise HTTPException(401, "unauthorized")

    def submit(kind: str, params: dict) -> dict:
        jid = uuid.uuid4().hex[:12]
        jobs[jid] = {"id": jid, "kind": kind, "status": "queued"}

        def work():
            jobs[jid]["status"] = "running"
            try:
                jobs[jid].update(status="done", result=runner(kind, params))
            except Exception as e:  # report, never crash the server
                jobs[jid].update(status="failed", error=f"{type(e).__name__}: {e}")

        pool.submit(work)
        return jobs[jid]

    @app.get("/healthz", dependencies=[Depends(auth)])
    def healthz():
        return {"ok": True}

    @app.post("/index/refresh", dependencies=[Depends(auth)])
    def index_refresh(project: str):
        return submit("index", {"project": project})

    @app.post("/cards/build", dependencies=[Depends(auth)])
    def cards_build(project: str, agenda: str = ""):
        return submit("cards", {"project": project, "agenda": agenda})

    @app.get("/jobs/{jid}", dependencies=[Depends(auth)])
    def job(jid: str):
        if jid not in jobs:
            raise HTTPException(404, "no such job")
        return jobs[jid]

    @app.get("/sync/{name}", dependencies=[Depends(auth)])
    def sync(name: str, request: Request):
        if name not in SYNC_FILES:
            raise HTTPException(404, "unknown file")
        src = data / name
        if not src.exists():
            raise HTTPException(404, "not built yet")
        out = snapshot(src, data / "export" / name)
        st = out.stat()
        etag = f'"{st.st_mtime_ns:x}-{st.st_size:x}"'
        if request.headers.get("if-none-match") == etag:
            return Response(status_code=304, headers={"ETag": etag})
        return FileResponse(out, media_type="application/vnd.sqlite3", headers={"ETag": etag})

    return app


def default_runner(kind: str, params: dict) -> dict:
    from hamsa_brain.cards.build import build, open_cards
    from hamsa_brain.index import store
    from hamsa_brain.index.embed import E5Embedder
    from hamsa_brain.index.refresh import refresh

    proj = config.load_projects()[params["project"]]
    idx = store.open_index(config.index_path())
    emb = E5Embedder()
    if kind == "index":
        return refresh(proj, idx, emb, config.DATA_DIR / "index" / "pii-report.txt")
    if kind == "cards":
        refresh(proj, idx, emb, config.DATA_DIR / "index" / "pii-report.txt")  # cards from fresh notes
        return build(idx, open_cards(config.DATA_DIR / "cards.sqlite"), proj.id, proj.name, params["agenda"], emb)
    raise ValueError(kind)
