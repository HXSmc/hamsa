import hashlib
import json

from hamsa_brain.config import Project
from hamsa_brain.eval.retrieval import recall_at_k
from hamsa_brain.index import store
from hamsa_brain.index.chunk import MAX_CHARS, chunk_markdown
from hamsa_brain.index.embed import DIM
from hamsa_brain.index.pii import redact
from hamsa_brain.index.refresh import refresh


class FakeEmbedder:
    """Deterministic bag-of-words hash vectors: no model download in tests."""

    def _vec(self, text):
        v = [0.0] * DIM
        for tok in text.lower().split():
            v[int(hashlib.md5(tok.encode()).hexdigest(), 16) % DIM] += 1.0
        n = sum(x * x for x in v) ** 0.5 or 1.0
        return [x / n for x in v]

    def passages(self, texts):
        return [self._vec(t) for t in texts]

    def query(self, text):
        return self._vec(text)


def make_vault(tmp_path):
    v = tmp_path / "vault"
    (v / "Projects" / "Taweed").mkdir(parents=True)
    (v / "Secrets").mkdir()
    (v / "Projects" / "Taweed.md").write_text(
        "---\ntags: [x]\n---\n# Infra\n## GPU\nTaweed runs inference on an L4 GPU in Riyadh.\n"
        "Contact 0551234567 or ali@example.com, ID 1012345678, IBAN SA03 8000 0000 6080 1016 7519.\n"
        "# Pricing\nالسعر ١٥٠ ريال للمطالبة الواحدة\n"
    )
    (v / "Projects" / "Taweed.md.bak4").write_text("# Old\nstale backup GPU A100\n")
    (v / "Secrets" / "Projects.md").write_text("# Keys\nGPU api key sk-should-never-be-indexed\n")
    return v


def project(v):
    return Project(id="taweed", name="Taweed", include=[f"{v}/**/*.md", f"{v}/**/*.bak4"])


def test_chunker_keeps_headings_and_size():
    md = "# A\n## B\n" + ("word " * 400) + "\n\n# C\nshort"
    chunks = chunk_markdown(md, "Doc")
    assert all(len(c.text) <= MAX_CHARS for c in chunks)
    assert chunks[0].heading == "Doc > A > B"
    assert chunks[-1].heading == "Doc > C" and chunks[-1].text == "short"


def test_redact_kinds():
    text, kinds = redact("call +966 55 123 4567, id 2123456789")
    assert "4567" not in text and "2123456789" not in text
    assert sorted(kinds) == ["national_id", "phone"]
    assert redact("task t1729876543 done")[1] == []


def test_refresh_excludes_secrets_and_backups_and_redacts(tmp_path):
    v = make_vault(tmp_path)
    db = store.open_index(tmp_path / "index.sqlite")
    report = tmp_path / "pii.txt"
    stats = refresh(project(v), db, FakeEmbedder(), report)
    paths = [p for (p,) in db.execute("SELECT path FROM sources")]
    assert paths == [str(v / "Projects" / "Taweed.md")]
    alltext = " ".join(t for (t,) in db.execute("SELECT text FROM chunks"))
    for raw in ("0551234567", "ali@example.com", "1012345678", "SA03 8000"):
        assert raw not in alltext
    assert "sk-should-never" not in alltext
    assert stats["redacted"] == 4 and "Taweed.md" in report.read_text()
    # second run: nothing changed
    assert refresh(project(v), db, FakeEmbedder(), report)["changed"] == 0
    assert db.execute("SELECT count(*) FROM chunk_vectors").fetchone()[0] == stats["chunks"]


def test_search_and_recall(tmp_path):
    v = make_vault(tmp_path)
    db = store.open_index(tmp_path / "index.sqlite")
    emb = FakeEmbedder()
    refresh(project(v), db, emb, tmp_path / "pii.txt")
    hits = store.search(db, "taweed", "which GPU does Taweed use", emb.query("which GPU does Taweed use"))
    assert "L4" in hits[0]["text"]
    gold = tmp_path / "gold.jsonl"
    gold.write_text(
        json.dumps({"q": "what GPU", "lang": "en", "expect": ["Taweed.md"], "expect_text": "L4"}) + "\n"
        + json.dumps({"q": "كم السعر", "lang": "ar", "expect": ["Taweed.md"], "expect_text": "ريال"}) + "\n"
    )
    res = recall_at_k(db, emb, "taweed", gold, k=5)
    assert res["recall@5"] == 1.0 and res["n"] == 2
