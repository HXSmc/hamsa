"""Embeddings. The Mac uses the same model (CoreML) so vectors stay comparable (T05b parity)."""
from typing import Protocol

MODEL = "intfloat/multilingual-e5-small"
DIM = 384


class Embedder(Protocol):
    def passages(self, texts: list[str]) -> list[list[float]]: ...
    def query(self, text: str) -> list[float]: ...


class E5Embedder:
    def __init__(self, model: str = MODEL):
        from sentence_transformers import SentenceTransformer  # heavy import, only when used

        self.m = SentenceTransformer(model, device="cpu")

    def passages(self, texts: list[str]) -> list[list[float]]:
        return self.m.encode([f"passage: {t}" for t in texts], normalize_embeddings=True, batch_size=32).tolist()

    def query(self, text: str) -> list[float]:
        return self.m.encode(f"query: {text}", normalize_embeddings=True).tolist()

    def passages_as_queries(self, texts: list[str]) -> list[list[float]]:
        """Generated questions are matched question-to-question, so they get the query prefix too."""
        return self.m.encode([f"query: {t}" for t in texts], normalize_embeddings=True, batch_size=64).tolist()
