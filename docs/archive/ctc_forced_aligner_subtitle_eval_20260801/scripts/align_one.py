#!/usr/bin/env python3
"""Align one audio + lyric lines with MahmoudAshraf97/ctc-forced-aligner."""

from __future__ import annotations

import argparse
import json
import sys
import time
import traceback
from pathlib import Path

from align_common import (
    aggregate_words_to_lines,
    contains_cjk,
    load_lyric_lines,
    ms,
    normalize_monotonic,
    write_timeline,
)


def infer_language(text: str, explicit: str | None) -> str:
    if explicit:
        return explicit
    return "cmn" if contains_cjk(text) else "eng"


def sanitize_for_en_letter_ctc(lines: list[str]) -> list[str]:
    """Normalize punctuation that breaks letter-vocab CTC token matching."""
    import re

    out: list[str] = []
    for line in lines:
        s = (
            line.replace("—", " ")
            .replace("–", " ")
            .replace("−", " ")
            .replace("'", "'")
            .replace("'", "'")
            .replace(""", '"')
            .replace(""", '"')
        )
        s = re.sub(r"[^A-Za-z0-9'\s]+", " ", s)
        s = re.sub(r"\s+", " ", s).strip()
        out.append(s if s else "a")
    return out


def align_ctc(
    audio_path: Path,
    lyric_lines: list[str],
    language: str,
    device: str,
    batch_size: int,
    romanize: bool,
    model_path: str,
    method: str,
) -> tuple[list[dict], dict]:
    import torch
    from ctc_forced_aligner import (
        generate_emissions,
        get_alignments,
        get_spans,
        load_alignment_model,
        load_audio,
        postprocess_results,
        preprocess_text,
    )

    dtype = torch.float16 if device == "cuda" else torch.float32
    t0 = time.perf_counter()
    alignment_model, alignment_tokenizer = load_alignment_model(
        device,
        model_path=model_path,
        dtype=dtype,
    )
    load_s = time.perf_counter() - t0

    t1 = time.perf_counter()
    audio_waveform = load_audio(str(audio_path), alignment_model.dtype, alignment_model.device)
    duration_s = float(audio_waveform.shape[-1]) / 16000.0

    align_language = "chi" if language in ("cmn", "chi", "zho") else language
    split_size = "char" if align_language == "chi" else "word"
    # Display cues keep original lyric_lines; letter-vocab EN models need ASCII-ish transcript.
    align_lines = (
        sanitize_for_en_letter_ctc(lyric_lines)
        if align_language == "eng" and not romanize
        else lyric_lines
    )
    text = " ".join(align_lines)

    emissions, stride = generate_emissions(
        alignment_model,
        audio_waveform,
        batch_size=batch_size,
    )
    tokens_starred, text_starred = preprocess_text(
        text,
        romanize=romanize,
        language=align_language,
        split_size=split_size,
        star_frequency="edges",
    )
    segments, scores, blank_token = get_alignments(
        emissions,
        tokens_starred,
        alignment_tokenizer,
    )
    spans = get_spans(tokens_starred, segments, blank_token)
    timestamps = postprocess_results(text_starred, spans, stride, scores)
    align_s = time.perf_counter() - t1

    cues = aggregate_words_to_lines(lyric_lines, timestamps, method=method)
    duration_ms = ms(duration_s)
    cues = normalize_monotonic(cues, duration_ms)
    meta = {
        "backend": method,
        "model": model_path,
        "modelLoadSeconds": round(load_s, 3),
        "alignSeconds": round(align_s, 3),
        "segmentCount": len(timestamps) if isinstance(timestamps, list) else 0,
        "lyricLineCount": len(lyric_lines),
        "splitSize": split_size,
        "device": device,
        "language": align_language,
        "romanize": romanize,
        "durationMs": duration_ms,
    }
    return cues, meta


def main() -> int:
    parser = argparse.ArgumentParser(description="CTC forced-align one song to lyric lines")
    parser.add_argument("--audio", required=True, type=Path)
    parser.add_argument("--lyrics", required=True, type=Path)
    parser.add_argument("--out-dir", required=True, type=Path)
    parser.add_argument("--language", default=None)
    parser.add_argument("--device", default=None, choices=["cpu", "cuda"])
    parser.add_argument("--batch-size", type=int, default=4)
    parser.add_argument("--romanize", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument(
        "--model",
        default="MahmoudAshraf/mms-300m-1130-forced-aligner",
        help="Hugging Face CTC model id",
    )
    parser.add_argument("--method", default="ctc", help="method tag written into cues")
    parser.add_argument("--stem", default="timeline_ctc")
    parser.add_argument("--article-id", default=0)
    parser.add_argument("--source", default="ctc_eval")
    parser.add_argument("--audio-hash", default="")
    parser.add_argument("--lyrics-hash", default="")
    args = parser.parse_args()

    if not args.audio.is_file():
        raise SystemExit(f"Audio not found: {args.audio}")
    if not args.lyrics.is_file():
        raise SystemExit(f"Lyrics not found: {args.lyrics}")

    lyric_lines = load_lyric_lines(args.lyrics)
    language = infer_language("\n".join(lyric_lines), args.language)

    try:
        import torch

        device = args.device or ("cuda" if torch.cuda.is_available() else "cpu")
    except Exception:
        device = args.device or "cpu"

    args.out_dir.mkdir(parents=True, exist_ok=True)
    try:
        cues, meta = align_ctc(
            audio_path=args.audio,
            lyric_lines=lyric_lines,
            language=language,
            device=device,
            batch_size=args.batch_size,
            romanize=args.romanize,
            model_path=args.model,
            method=args.method,
        )
    except Exception as exc:
        (args.out_dir / "align_error.txt").write_text(
            f"{type(exc).__name__}: {exc}\n\n{traceback.format_exc()}",
            encoding="utf-8",
        )
        print(f"ALIGN_FAILED: {exc}", file=sys.stderr)
        return 1

    result = write_timeline(
        args.out_dir,
        cues,
        meta,
        article_id=args.article_id,
        audio_hash=args.audio_hash,
        lyrics_hash=args.lyrics_hash,
        source=args.source,
        stem=args.stem,
    )
    print(json.dumps({"ok": True, **result}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
