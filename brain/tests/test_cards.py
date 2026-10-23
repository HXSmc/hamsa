import json

from hamsa_brain.cards.build import build, open_cards, stats, valid_card
from hamsa_brain.index import store
from hamsa_brain.index.refresh import refresh
from test_index import FakeEmbedder, make_vault, project


def test_valid_card_rejects_unsourced_and_monolingual():
    good = {"question_en": "q", "question_ar": "س", "answer_en": "a", "answer_ar_sa": "ج", "sources": [3, 99]}
    assert valid_card(good, {3})["sources"] == [3]
    assert valid_card({**good, "sources": [99]}, {3}) is None
    assert valid_card({**good, "answer_ar_sa": " "}, {3}) is None


def test_build_writes_sourced_bilingual_cards(tmp_path):
    v = make_vault(tmp_path)
    idx = store.open_index(tmp_path / "index.sqlite")
    emb = FakeEmbedder()
    emb.passages_as_queries = emb.passages
    refresh(project(v), idx, emb, tmp_path / "pii.txt")
    gpu = idx.execute("SELECT id FROM chunks WHERE text LIKE '%L4%'").fetchone()[0]

    def fake(prompt, model):
        if model == "haiku":
            return json.dumps({"topics": ["GPU infra", "pricing"]})
        assert f"[{gpu}]" in prompt
        return json.dumps({"cards": [
            {"question_en": "Which GPU?", "question_ar": "وش الـGPU؟", "paraphrases": ["what hardware"],
             "answer_en": "L4 in Riyadh.", "answer_ar_sa": "L4 بالرياض.", "sources": [gpu]},
            {"question_en": "Made up?", "question_ar": "؟", "answer_en": "x", "answer_ar_sa": "x", "sources": [12345]},
        ]})

    cdb = open_cards(tmp_path / "cards.sqlite")
    res = build(idx, cdb, "taweed", "Taweed", "GPU call", emb, ask=fake)
    assert res["cards"] == 1
    assert stats(cdb, "taweed") == {"cards": 1, "bilingual": "100%", "sources": "100%"}
    assert cdb.execute("SELECT count(*) FROM card_vectors").fetchone()[0] == 3
    build(idx, cdb, "taweed", "Taweed", "GPU call", emb, ask=fake)  # rebuild replaces, not duplicates
    assert stats(cdb, "taweed")["cards"] == 1
