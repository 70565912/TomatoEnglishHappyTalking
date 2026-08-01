#!/usr/bin/env python3
"""Montreal Forced Aligner backend for English lyric-line timing eval."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import time
import traceback
import wave
from pathlib import Path

from align_common import (
    aggregate_words_to_lines,
    load_lyric_lines,
    ms,
    normalize_monotonic,
    write_timeline,
)


def find_mfa() -> str | None:
    found = shutil.which("mfa")
    if found:
        return found
    candidates = [
        Path(r"D:\DevTools\miniconda3\envs\mfa\Scripts\mfa.exe"),
        Path.home() / "miniconda3" / "envs" / "mfa" / "Scripts" / "mfa.exe",
        Path.home() / "Miniconda3" / "envs" / "mfa" / "Scripts" / "mfa.exe",
    ]
    for cand in candidates:
        if cand.is_file():
            return str(cand)
    return None


def audio_duration_ms(wav_path: Path) -> int:
    with wave.open(str(wav_path), "rb") as wf:
        frames = wf.getnframes()
        rate = wf.getframerate()
        return ms(frames / float(rate))


def ensure_wav_16k(audio_path: Path, out_wav: Path) -> Path:
    out_wav.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg",
        "-y",
        "-nostdin",
        "-i",
        str(audio_path),
        "-ac",
        "1",
        "-ar",
        "16000",
        str(out_wav),
    ]
    subprocess.run(cmd, check=True, capture_output=True)
    return out_wav


def parse_textgrid_words(textgrid_path: Path) -> list[dict]:
    """Minimal TextGrid word-tier parser (IntervalTier named words/word)."""
    text = textgrid_path.read_text(encoding="utf-8", errors="replace")
    # Prefer long-text format intervals.
    words: list[dict] = []
    # Find tiers; MFA english usually has "words" tier.
    tier_pat = re.compile(
        r'name\s*=\s*"(words|word)"\s*'
        r"xmin\s*=\s*([0-9.]+)\s*"
        r"xmax\s*=\s*([0-9.]+)\s*"
        r"intervals:\s*size\s*=\s*(\d+)\s*"
        r"(.*?)\n\s*item\s*\[\d+\]\s*:",
        re.IGNORECASE | re.DOTALL,
    )
    m = tier_pat.search(text + "\n    item [999]:")
    body = None
    if m:
        body = m.group(5)
    else:
        # Fallback: first IntervalTier body with text labels that look like words
        alt = re.search(
            r'class\s*=\s*"IntervalTier".*?intervals:\s*size\s*=\s*\d+\s*(.*?)(?:item\s*\[\d+\]:|\Z)',
            text,
            re.IGNORECASE | re.DOTALL,
        )
        body = alt.group(1) if alt else text

    interval_pat = re.compile(
        r"intervals\s*\[\d+\]\s*:\s*"
        r"xmin\s*=\s*([0-9.]+)\s*"
        r"xmax\s*=\s*([0-9.]+)\s*"
        r'text\s*=\s*"(.*?)"',
        re.IGNORECASE | re.DOTALL,
    )
    for xmin, xmax, label in interval_pat.findall(body or ""):
        label = label.strip()
        if not label or label in ("", "<unk>", "sp", "sil", "silence"):
            continue
        words.append(
            {
                "start": float(xmin),
                "end": float(xmax),
                "score": 1.0,
                "text": label,
            }
        )
    return words


def align_mfa(
    audio_path: Path,
    lyric_lines: list[str],
    work_dir: Path,
    dictionary: str = "english_us_mfa",
    acoustic: str = "english_mfa",
) -> tuple[list[dict], dict]:
    mfa = find_mfa()
    if not mfa:
        raise RuntimeError("mfa CLI not found on PATH")

    work_dir.mkdir(parents=True, exist_ok=True)
    corpus = work_dir / "corpus"
    output = work_dir / "aligned"
    if corpus.exists():
        shutil.rmtree(corpus)
    if output.exists():
        shutil.rmtree(output)
    corpus.mkdir(parents=True)
    output.mkdir(parents=True)

    wav_path = ensure_wav_16k(audio_path, corpus / "utt.wav")
    lab_path = corpus / "utt.lab"
    # MFA expects whitespace-separated words in .lab
    tokens: list[str] = []
    for line in lyric_lines:
        for tok in re.findall(r"[A-Za-z0-9']+", line):
            tokens.append(tok)
    if not tokens:
        raise RuntimeError("No MFA-alignable tokens")
    lab_path.write_text(" ".join(tokens) + "\n", encoding="utf-8")

    t0 = time.perf_counter()
    # Ensure models present (no-op if already downloaded).
    subprocess.run([mfa, "model", "download", "dictionary", dictionary], check=False, capture_output=True)
    subprocess.run([mfa, "model", "download", "acoustic", acoustic], check=False, capture_output=True)
    subprocess.run([mfa, "model", "download", "g2p", dictionary], check=False, capture_output=True)

    temp_dir = work_dir / "mfa_temp"
    if temp_dir.exists():
        shutil.rmtree(temp_dir, ignore_errors=True)
    temp_dir.mkdir(parents=True, exist_ok=True)

    cmd = [
        mfa,
        "align",
        str(corpus),
        dictionary,
        acoustic,
        str(output),
        "--clean",
        "--final_clean",
        "--single_speaker",
        "--temporary_directory",
        str(temp_dir),
        "--beam",
        "100",
        "--retry_beam",
        "400",
    ]
    # Try G2P for OOVs if supported.
    cmd_g2p = cmd + ["--g2p_model_path", dictionary]
    proc = subprocess.run(cmd_g2p, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if proc.returncode != 0:
        proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    align_s = time.perf_counter() - t0
    (work_dir / "mfa_stdout.txt").write_text(proc.stdout or "", encoding="utf-8")
    (work_dir / "mfa_stderr.txt").write_text(proc.stderr or "", encoding="utf-8")
    if proc.returncode != 0:
        raise RuntimeError(f"mfa align failed ({proc.returncode}): {(proc.stderr or '')[-1500:]}")

    textgrids = list(output.rglob("*.TextGrid"))
    if not textgrids:
        raise RuntimeError("mfa produced no TextGrid")
    words = parse_textgrid_words(textgrids[0])
    if not words:
        raise RuntimeError(f"No words parsed from {textgrids[0]}")

    duration_ms = audio_duration_ms(wav_path)
    cues = aggregate_words_to_lines(lyric_lines, words, method="mfa")
    cues = normalize_monotonic(cues, duration_ms)
    meta = {
        "backend": "mfa",
        "model": f"{dictionary}+{acoustic}",
        "modelLoadSeconds": 0.0,
        "alignSeconds": round(align_s, 3),
        "segmentCount": len(words),
        "lyricLineCount": len(lyric_lines),
        "device": "cpu",
        "durationMs": duration_ms,
        "textgrid": str(textgrids[0]),
    }
    return cues, meta


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True, type=Path)
    parser.add_argument("--lyrics", required=True, type=Path)
    parser.add_argument("--out-dir", required=True, type=Path)
    parser.add_argument("--article-id", default=0)
    parser.add_argument("--audio-hash", default="")
    parser.add_argument("--lyrics-hash", default="")
    parser.add_argument("--stem", default="timeline_mfa")
    args = parser.parse_args()

    lyric_lines = load_lyric_lines(args.lyrics)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    try:
        cues, meta = align_mfa(args.audio, lyric_lines, args.out_dir / "mfa_work")
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
        source="mfa",
        stem=args.stem,
    )
    print(json.dumps({"ok": True, **result}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
