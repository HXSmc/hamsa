"""Heading-aware markdown chunking: each chunk keeps the heading path it sits under."""
import re
from dataclasses import dataclass

MAX_CHARS = 800
_HEADING = re.compile(r"^(#{1,6})\s+(.*)$")
_ARABIC = re.compile(r"[؀-ۿ]")
_LATIN = re.compile(r"[A-Za-z]")


@dataclass
class Chunk:
    heading: str
    text: str
    lang: str
    ord: int


def detect_lang(text: str) -> str:
    ar, en = len(_ARABIC.findall(text)), len(_LATIN.findall(text))
    if ar and en and min(ar, en) / max(ar, en) > 0.2:
        return "mixed"
    return "ar" if ar > en else "en"


def _strip_frontmatter(md: str) -> str:
    if md.startswith("---\n"):
        end = md.find("\n---", 4)
        if end != -1:
            return md[end + 4 :]
    return md


def _split_long(block: str) -> list[str]:
    """Split on blank lines, then lines, then hard-cut, so no piece exceeds MAX_CHARS."""
    out, cur = [], ""
    for para in re.split(r"\n\s*\n", block):
        for piece in [para] if len(para) <= MAX_CHARS else para.splitlines():
            while len(piece) > MAX_CHARS:
                out.append(piece[:MAX_CHARS])
                piece = piece[MAX_CHARS:]
            if cur and len(cur) + len(piece) + 2 > MAX_CHARS:
                out.append(cur)
                cur = ""
            cur = f"{cur}\n\n{piece}" if cur else piece
    if cur:
        out.append(cur)
    return [p.strip() for p in out if p.strip()]


def chunk_markdown(md: str, title: str) -> list[Chunk]:
    path: list[str] = []
    sections: list[tuple[str, list[str]]] = [(title, [])]
    for line in _strip_frontmatter(md).splitlines():
        m = _HEADING.match(line)
        if m:
            level = len(m.group(1))
            path = path[: level - 1] + [m.group(2).strip()]
            sections.append((" > ".join([title, *path]), []))
        else:
            sections[-1][1].append(line)
    chunks = []
    for heading, lines in sections:
        for piece in _split_long("\n".join(lines)):
            chunks.append(Chunk(heading, piece, detect_lang(piece), len(chunks)))
    return chunks
