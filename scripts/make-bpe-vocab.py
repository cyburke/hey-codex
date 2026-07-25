#!/usr/bin/env python3
"""Writes bpe.vocab next to a model's bpe.model.

The keyword spotter needs its keywords as model tokens, and the encoder that
produces them (ssentencepiece, inside the sherpa-onnx library) reads a text
vocabulary rather than the sentencepiece protobuf that models ship. This converts
one to the other with official sentencepiece, so the tokens the app produces are
the tokens sentencepiece would produce.

    pip install sentencepiece
    python3 scripts/make-bpe-vocab.py Models/<model-dir>
"""
import sys
from pathlib import Path

import sentencepiece as spm


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    model_dir = Path(sys.argv[1])
    bpe_model = model_dir / "bpe.model"
    if not bpe_model.exists():
        print(f"no bpe.model in {model_dir}")
        return 1

    sp = spm.SentencePieceProcessor(model_file=str(bpe_model))
    out = model_dir / "bpe.vocab"
    with out.open("w", encoding="utf-8") as f:
        for i in range(sp.get_piece_size()):
            f.write(f"{sp.id_to_piece(i)}\t{sp.get_score(i)}\n")
    print(f"wrote {out} ({sp.get_piece_size()} pieces)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
