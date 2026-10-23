"""T05b: convert intfloat/multilingual-e5-small (the brain's embedder) to Core ML for the Mac.

Output (git-ignored, ~240 MB, regenerate instead of committing):
  mac/Models/e5-small/E5Small.mlmodelc   compiled model, fp16, ANE-friendly
  mac/Models/e5-small/tokenizer.json, tokenizer_config.json, config.json   XLM-R SentencePiece (Unigram) tokenizer

Regenerate (macOS, ~2 GB RAM, ~5 min):
  uv venv -p 3.12 /tmp/e5venv
  VIRTUAL_ENV=/tmp/e5venv uv pip install "coremltools==9.0" "torch==2.7.0" "transformers<5" numpy huggingface_hub
  /tmp/e5venv/bin/python mac/Models/convert_e5.py

The model takes `input_ids` (1, L) for L in BUCKETS, padded with <pad>=1, and returns `embedding` (1, 384):
mask-weighted mean pooling over non-pad tokens, then L2 normalize, same as sentence-transformers
(modules.json: Transformer -> Pooling(mean) -> Normalize). The caller adds the "query: " / "passage: " prefix.
"""
import shutil
import subprocess
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from huggingface_hub import snapshot_download
from transformers import AutoModel

MODEL = "intfloat/multilingual-e5-small"  # must match brain/hamsa_brain/index/embed.py MODEL
PAD = 1
BUCKETS = [16, 32, 64, 128, 256, 512]
OUT = Path(__file__).resolve().parent / "e5-small"


class E5(torch.nn.Module):
    def __init__(self, bert):
        super().__init__()
        self.bert = bert

    def forward(self, input_ids):
        mask = (input_ids != PAD).to(torch.float32)  # (1, L)
        emb = self.bert.embeddings(input_ids=input_ids, token_type_ids=torch.zeros_like(input_ids))
        # Additive mask built by hand: HF's finfo.min becomes -inf in fp16 and NaNs padded rows.
        ext = (1.0 - mask)[:, None, None, :] * -1e4
        h = emb
        for layer in self.bert.encoder.layer:
            h = layer(h, attention_mask=ext)[0]
        m = mask[:, :, None]
        pooled = (h * m).sum(1) / m.sum(1).clamp(min=1.0)
        return pooled / pooled.norm(dim=-1, keepdim=True).clamp(min=1e-6)


def main() -> None:
    # Optional argv[1]: an already-downloaded snapshot folder.
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(snapshot_download(
        MODEL, allow_patterns=["*.json", "model.safetensors", "1_Pooling/*"], ignore_patterns=["onnx/*"]))
    OUT.mkdir(exist_ok=True)
    for f in ("tokenizer.json", "tokenizer_config.json", "config.json", "special_tokens_map.json"):
        shutil.copy(src / f, OUT / f)

    bert = AutoModel.from_pretrained(src, attn_implementation="eager").eval()
    model = E5(bert).eval()
    ids = torch.tensor([[0, 3293, 12, 1622, 2] + [PAD] * 11])
    with torch.no_grad():
        ref = model(ids)
        traced = torch.jit.trace(model, ids)

    shape = ct.EnumeratedShapes(shapes=[(1, n) for n in BUCKETS], default=(1, BUCKETS[0]))
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input_ids", shape=shape, dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        minimum_deployment_target=ct.target.macOS14,
        convert_to="mlprogram",
    )
    out = ml.predict({"input_ids": ids.numpy().astype(np.int32)})["embedding"]
    cos = float((out * ref.numpy()).sum())
    print(f"traced-vs-coreml cosine on a probe: {cos:.5f}")
    if cos < 0.99:
        sys.exit("conversion drifted, not writing the model")

    pkg = OUT / "E5Small.mlpackage"
    shutil.rmtree(pkg, ignore_errors=True)
    ml.save(str(pkg))
    compiled = OUT / "E5Small.mlmodelc"
    shutil.rmtree(compiled, ignore_errors=True)
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(pkg), str(OUT)], check=True)
    shutil.rmtree(pkg)
    print(f"wrote {compiled}")


if __name__ == "__main__":
    main()
