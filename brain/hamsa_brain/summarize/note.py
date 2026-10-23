"""T14: after the call, Claude turns the transcript into a vault note (no time limit)."""
import datetime as dt
import re
import sqlite3
from dataclasses import dataclass
from pathlib import Path

from hamsa_brain.index.chunk import detect_lang
from hamsa_brain.index.doc2query import _claude

VAULT_MEETINGS = Path("~/Desktop/ObsidianVault/Meetings").expanduser()
SECTIONS = ("Summary", "Decisions", "Action items", "Open questions")

PROMPT = """Write meeting notes from this call transcript. "ME" is the owner; "THEM" is the other side.
Write in {lang}. Keep product names, numbers and tech terms exactly as said.
Use exactly these markdown sections, in order, nothing before the first one:
## Summary
(5-8 bullet points: what was discussed and where it landed)
## Decisions
(bullets; "None." if none)
## Action items
(checkbox bullets "- [ ] who: what (by when, if said)"; "None." if none)
## Open questions
(questions asked that were not answered, or need follow-up; "None." if none)

Meeting: {title}
Transcript:
{transcript}"""


@dataclass
class Meeting:
    id: str
    title: str
    project: str | None
    started_at: int
    confidential: bool
    claude_allowed: bool
    segments: list[tuple[str, int, str]]  # (channel, t_start_ms, text)


def load_meeting(live_db: Path, meeting_id: str) -> Meeting:
    db = sqlite3.connect(live_db)
    row = db.execute(
        "SELECT id, title, project_id, started_at, confidential, claude_allowed FROM meetings WHERE id=?", (meeting_id,)
    ).fetchone()
    if not row:
        raise KeyError(meeting_id)
    segs = db.execute(
        "SELECT channel, t_start_ms, text FROM segments WHERE meeting_id=? AND is_final=1 ORDER BY t_start_ms", (meeting_id,)
    ).fetchall()
    return Meeting(row[0], row[1] or "Call", row[2], row[3], bool(row[4]), bool(row[5]), segs)


def transcript_text(segments) -> str:
    return "\n".join(f"[{ms // 60000:02d}:{ms // 1000 % 60:02d}] {ch.upper()}: {text}" for ch, ms, text in segments)


def main_language(text: str) -> str:
    return "Saudi Arabic (white dialect)" if detect_lang(text) == "ar" else "English"


def summarize(m: Meeting, out_dir: Path = VAULT_MEETINGS, ask=_claude) -> Path | None:
    """Writes the note and returns its path; None when the meeting is confidential and Claude is not allowed."""
    if m.confidential and not m.claude_allowed:
        return None
    text = transcript_text(m.segments)
    spoken = " ".join(t for _, _, t in m.segments)  # labels like "THEM:" would skew detection to English
    reply = ask(PROMPT.format(lang=main_language(spoken), title=m.title, transcript=text), "sonnet")
    body = reply[reply.find("## Summary"):] if "## Summary" in reply else reply
    missing = [s for s in SECTIONS if f"## {s}" not in body]
    if missing:
        raise ValueError(f"summary missing sections: {missing}")
    day = dt.datetime.fromtimestamp(m.started_at).strftime("%Y-%m-%d")
    safe = re.sub(r"[\\/:*?\"<>|]", "-", m.title).strip() or "Call"
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{day} {safe}.md"
    n = 2
    while path.exists():  # never overwrite an earlier note of the same name
        path = out_dir / f"{day} {safe} ({n}).md"
        n += 1
    front = "\n".join([
        "---", f"title: {m.title}", f"date: {day}", f"project: {m.project or ''}", "tags: [meeting, hamsa]",
        f"hamsa_meeting: {m.id}", "---", "",
    ])
    fold = "\n".join(f"> {line}" for line in text.splitlines())
    path.write_text(f"{front}# {m.title}\n\n{body.strip()}\n\n> [!note]- Transcript\n{fold}\n")
    return path
