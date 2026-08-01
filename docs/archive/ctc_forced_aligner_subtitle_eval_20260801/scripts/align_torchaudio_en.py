#!/usr/bin/env python3
"""English forced alignment via torchaudio WAV2VEC2_ASR_LARGE_LV60K_960H + forced_align."""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import traceback
from pathlib import Path

from align_common import (
    aggregate_words_to_lines,
    load_lyric_lines,
    ms,
    normalize_monotonic,
    write_timeline,
)


def _load_waveform_16k(audio_path: Path, sample_rate: int, device: str):
    import torch
    import torchaudio

    # Prefer ffmpeg decode for mp3 consistency with other backends.
    import subprocess

    cmd = [
        "ffmpeg",
        "-nostdin",
        "-threads",
        "0",
        "-i",
        str(audio_path),
        "-f",
        "s16le",
        "-ac",
        "1",
        "-acodec",
        "pcm_s16le",
        "-ar",
        str(sample_rate),
        "-",
    ]
    try:
        out = subprocess.run(cmd, capture_output=True, check=True).stdout
    except FileNotFoundError as exc:
        raise RuntimeError("ffmpeg not found on PATH") from exc
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"ffmpeg failed: {exc.stderr.decode(errors='replace')}") from exc

    waveform = torch.frombuffer(bytearray(out), dtype=torch.int16).float() / 32768.0
    waveform = waveform.unsqueeze(0).to(device)
    return waveform


def align_torchaudio_en(
    audio_path: Path,
    lyric_lines: list[str],
    device: str,
) -> tuple[list[dict], dict]:
    import torch
    import torchaudio
    from torchaudio.pipelines import WAV2VEC2_ASR_LARGE_LV60K_960H as bundle

    t0 = time.perf_counter()
    model = bundle.get_model().to(device).eval()
    labels = bundle.get_labels()
    dictionary = {c: i for i, c in enumerate(labels)}
    blank = 0
    load_s = time.perf_counter() - t0

    t1 = time.perf_counter()
    waveform = _load_waveform_16k(audio_path, bundle.sample_rate, device)
    duration_s = float(waveform.shape[-1]) / float(bundle.sample_rate)

    with torch.inference_mode():
        emissions, _ = model(waveform)
        emissions = torch.log_softmax(emissions, dim=-1)

    # Build character transcript with '|' word separators (torchaudio convention).
    words = []
    for line in lyric_lines:
        for token in re.findall(r"\S+", line):
            cleaned = re.sub(r"[^A-Za-z0-9']+", "", token).upper()
            if cleaned:
                words.append(cleaned)
    if not words:
        raise RuntimeError("No alignable English tokens in lyrics")

    chars: list[str] = []
    for i, word in enumerate(words):
        if i > 0:
            chars.append("|")
        for ch in word:
            if ch not in dictionary:
                # Skip unknown chars rather than fail whole song.
                continue
            chars.append(ch)
    if not chars:
        raise RuntimeError("Transcript collapsed to empty after dictionary filtering")

    targets = torch.tensor([[dictionary[c] for c in chars]], dtype=torch.int32, device="cpu")
    emission_cpu = emissions[0].cpu()
    # forced_align expects [T, C] emission and [L] or [1, L] targets depending on version.
    aligned_tokens, scores = torchaudio.functional.forced_align(
        emission_cpu.unsqueeze(0),
        targets,
        blank=blank,
    )
    token_spans = torchaudio.functional.merge_tokens(aligned_tokens[0], scores[0])

    # Map char spans back into words using '|' separators.
    frame_shift = waveform.shape[-1] / emissions.shape[1] / bundle.sample_rate

    word_timestamps: list[dict] = []
    current_chars: list = []
    for span in token_spans:
        token = labels[span.token]
        if token == "|":
            if current_chars:
                start = current_chars[0].start * frame_shift
                end = current_chars[-1].end * frame_shift
                score = float(
                    sum(float(c.score) for c in current_chars) / max(1, len(current_chars))
                )
                word_timestamps.append({"start": start, "end": end, "score": score, "text": ""})
                current_chars = []
            continue
        if token == "-":
            continue
        current_chars.append(span)
    if current_chars:
        start = current_chars[0].start * frame_shift
        end = current_chars[-1].end * frame_shift
        score = float(sum(float(c.score) for c in current_chars) / max(1, len(current_chars)))
        word_timestamps.append({"start": start, "end": end, "score": score, "text": ""})

    # If word count drifted, still aggregate proportionally onto lyric lines.
    cues = aggregate_words_to_lines(lyric_lines, word_timestamps, method="torchaudio_en")
    duration_ms = ms(duration_s)
    cues = normalize_monotonic(cues, duration_ms)
    align_s = time.perf_counter() - t1
    meta = {
        "backend": "torchaudio_en",
        "model": "WAV2VEC2_ASR_LARGE_LV60K_960H",
        "modelLoadSeconds": round(load_s, 3),
        "alignSeconds": round(align_s, 3),
        "segmentCount": len(word_timestamps),
        "lyricLineCount": len(lyric_lines),
        "device": device,
        "durationMs": duration_ms,
        "frameShiftSec": frame_shift,
    }
    return cues, meta


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True, type=Path)
    parser.add_argument("--lyrics", required=True, type=Path)
    parser.add_argument("--out-dir", required=True, type=Path)
    parser.add_argument("--device", default=None, choices=["cpu", "cuda"])
    parser.add_argument("--article-id", default=0)
    parser.add_argument("--audio-hash", default="")
    parser.add_argument("--lyrics-hash", default="")
    parser.add_argument("--stem", default="timeline_torchaudio_en")
    args = parser.parse_args()

    lyric_lines = load_lyric_lines(args.lyrics)
    try:
        import torch

        device = args.device or ("cuda" if torch.cuda.is_available() else "cpu")
    except Exception:
        device = args.device or "cpu"

    args.out_dir.mkdir(parents=True, exist_ok=True)
    try:
        cues, meta = align_torchaudio_en(args.audio, lyric_lines, device)
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
        source="torchaudio_en",
        stem=args.stem,
    )
    print(json.dumps({"ok": True, **result}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
