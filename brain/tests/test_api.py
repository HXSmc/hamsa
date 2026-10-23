import sqlite3
import time

from fastapi.testclient import TestClient

from hamsa_brain.api.app import create_app, load_or_create_token

TOKEN = "t0ken"
H = {"Authorization": f"Bearer {TOKEN}"}


def client(tmp_path, runner=lambda kind, params: {"kind": kind, **params}):
    return TestClient(create_app(TOKEN, runner, data_dir=tmp_path))


def test_auth_required(tmp_path):
    c = client(tmp_path)
    assert c.get("/healthz").status_code == 401
    assert c.get("/healthz", headers={"Authorization": "Bearer nope"}).status_code == 401
    assert c.get("/healthz", headers=H).json() == {"ok": True}
    assert c.get("/sync/index.sqlite").status_code == 401


def test_jobs_run_and_report(tmp_path):
    def runner(kind, params):
        if params["project"] == "bad":
            raise RuntimeError("boom")
        return {"cards": 3}

    c = client(tmp_path, runner)
    ok = c.post("/cards/build?project=taweed&agenda=GPU", headers=H).json()
    bad = c.post("/index/refresh?project=bad", headers=H).json()
    for _ in range(50):
        if all(c.get(f"/jobs/{j['id']}", headers=H).json()["status"] in ("done", "failed") for j in (ok, bad)):
            break
        time.sleep(0.05)
    assert c.get(f"/jobs/{ok['id']}", headers=H).json()["result"] == {"cards": 3}
    assert "boom" in c.get(f"/jobs/{bad['id']}", headers=H).json()["error"]


def test_sync_snapshot_and_etag(tmp_path):
    db = sqlite3.connect(tmp_path / "cards.sqlite")
    db.execute("CREATE TABLE t(x)")
    db.commit()
    c = client(tmp_path)
    assert c.get("/sync/../token", headers=H).status_code == 404
    r = c.get("/sync/cards.sqlite", headers=H)
    assert r.status_code == 200 and r.content.startswith(b"SQLite format 3")
    again = c.get("/sync/cards.sqlite", headers={**H, "If-None-Match": r.headers["etag"]})
    assert again.status_code == 304


def test_token_created_private(tmp_path):
    p = tmp_path / "cfg" / "token"
    tok = load_or_create_token(p)
    assert len(tok) > 30 and oct(p.stat().st_mode)[-3:] == "600"
    assert load_or_create_token(p) == tok
