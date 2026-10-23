"""Redact personal identifiers before text enters the index (snippets can reach a free-tier LLM)."""
import re

PATTERNS = {
    "iban": re.compile(r"\bSA\d{2}(?:\s?[0-9A-Z]{4}){5}\b"),
    "national_id": re.compile(r"(?<!\w)[12]\d{9}(?!\w)"),  # Saudi ID / Iqama
    "phone": re.compile(r"(?:\+966|00966|\b0)\s?5\d(?:[\s-]?\d){7}\b"),
    "email": re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b"),
}


def redact(text: str) -> tuple[str, list[str]]:
    """Return the redacted text and the kinds found (never the values)."""
    found = []
    for kind, rx in PATTERNS.items():
        text, n = rx.subn("[REDACTED]", text)
        found += [kind] * n
    return text, found
