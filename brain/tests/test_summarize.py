import pytest

from hamsa_brain.summarize.note import Meeting, summarize

REPLY = """Here you go.
## Summary
- Discussed GPU hosting.
## Decisions
- Stay on L4.
## Action items
- [ ] ME: send pricing (Sunday)
## Open questions
None."""


def meeting(**kw):
    base = dict(id="m1", title="Taweed: GPU call", project="taweed", started_at=1792800000, confidential=False,
                claude_allowed=True, segments=[("them", 0, "what GPU do you use?"), ("me", 4000, "L4 in Riyadh")])
    return Meeting(**{**base, **kw})


def test_writes_note_with_sections_and_transcript(tmp_path):
    seen = {}

    def fake(prompt, model):
        seen["prompt"] = prompt
        return REPLY

    p = summarize(meeting(), tmp_path, ask=fake)
    text = p.read_text()
    assert p.name.endswith("Taweed- GPU call.md")
    assert text.startswith("---\ntitle: Taweed: GPU call")
    assert "## Decisions\n- Stay on L4." in text and "Here you go" not in text
    assert "> [00:00] THEM: what GPU do you use?" in text
    assert "English" in seen["prompt"]
    assert summarize(meeting(), tmp_path, ask=fake).name.endswith("(2).md")  # never overwrites


def test_confidential_local_only_skips_claude(tmp_path):
    def boom(prompt, model):
        raise AssertionError("claude must not be called")

    assert summarize(meeting(confidential=True, claude_allowed=False), tmp_path, ask=boom) is None
    assert list(tmp_path.iterdir()) == []


def test_arabic_call_and_missing_section(tmp_path):
    seen = {}

    def fake(prompt, model):
        seen["p"] = prompt
        return "## Summary\n- x"

    m = meeting(segments=[("them", 0, "وش الـGPU اللي تستخدمونه"), ("me", 3000, "عندنا L4 بالرياض")])
    with pytest.raises(ValueError):
        summarize(m, tmp_path, ask=fake)
    assert "Saudi Arabic" in seen["p"]
