#!/usr/bin/env python3
"""Shared helpers for subtitle alignment eval backends."""

from __future__ import annotations

import json
import re
import statistics
from pathlib import Path


def ms(seconds: float) -> int:
    return max(0, int(round(float(seconds) * 1000.0)))


def srt_timestamp(ms_value: int) -> str:
    if ms_value < 0:
        ms_value = 0
    hours, rem = divmod(ms_value, 3_600_000)
    minutes, rem = divmod(rem, 60_000)
    seconds, millis = divmod(rem, 1000)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d},{millis:03d}"


def write_srt(cues: list[dict], path: Path) -> None:
    blocks: list[str] = []
    for i, cue in enumerate(cues, start=1):
        start = srt_timestamp(int(cue["startMs"]))
        end = srt_timestamp(int(cue["endMs"]))
        text = str(cue.get("english") or "").strip() or " "
        blocks.append(f"{i}\n{start} --> {end}\n{text}\n")
    path.write_text("\n".join(blocks).rstrip() + "\n", encoding="utf-8")


def load_lyric_lines(path: Path) -> list[str]:
    raw = path.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
    lines = [ln.strip() for ln in raw.splitlines() if ln.strip()]
    if not lines:
        raise SystemExit(f"No lyric lines in {path}")
    return lines


def contains_cjk(text: str) -> bool:
    return any("\u3400" <= ch <= "\u9fff" or "\uf900" <= ch <= "\ufaff" for ch in text)


def normalize_monotonic(cues: list[dict], duration_ms: int) -> list[dict]:
    if not cues:
        return cues
    out: list[dict] = []
    for cue in cues:
        start = int(cue["startMs"])
        end = int(cue["endMs"])
        if end < start:
            end = start
        out.append({**cue, "startMs": start, "endMs": end})

    for i in range(1, len(out)):
        prev = out[i - 1]
        cur = out[i]
        if cur["startMs"] < prev["endMs"]:
            mid = max(prev["startMs"], min(cur["startMs"], prev["endMs"]))
            prev["endMs"] = mid
            cur["startMs"] = mid
        if cur["endMs"] < cur["startMs"]:
            cur["endMs"] = cur["startMs"]

    if duration_ms > 0:
        last = out[-1]
        if last["endMs"] > duration_ms:
            last["endMs"] = duration_ms
        if last["startMs"] > last["endMs"]:
            last["startMs"] = last["endMs"]
    return out


def line_token_count(line: str) -> int:
    tokens = re.findall(r"\S+", line)
    return max(1, len(tokens))


def score_to_confidence(score: float) -> float:
    if score <= 1.0:
        return max(0.0, min(1.0, score))
    return max(0.0, min(1.0, score / 100.0))


def aggregate_words_to_lines(
    lyric_lines: list[str],
    words: list[dict],
    method: str = "ctc",
) -> list[dict]:
    cues: list[dict] = []
    word_i = 0
    expected = [line_token_count(line) for line in lyric_lines]
    total_expected = sum(expected)
    total_words = len(words)

    use_proportional = total_words > 0 and abs(total_words - total_expected) > max(
        2, total_expected * 0.15
    )
    if use_proportional and total_expected > 0:
        raw = [total_words * (n / total_expected) for n in expected]
        counts = [max(1, int(x)) for x in raw]
        while sum(counts) > total_words and any(c > 1 for c in counts):
            for i in range(len(counts) - 1, -1, -1):
                if counts[i] > 1 and sum(counts) > total_words:
                    counts[i] -= 1
        i = 0
        while sum(counts) < total_words:
            counts[i % len(counts)] += 1
            i += 1
        expected = counts

    for i, line in enumerate(lyric_lines):
        n = expected[i] if i < len(expected) else 1
        if word_i >= len(words):
            prev_end = cues[-1]["endMs"] if cues else 0
            cues.append(
                {
                    "lineIndex": i,
                    "startMs": prev_end,
                    "endMs": prev_end,
                    "english": line,
                    "chinese": "",
                    "confidence": 0.0,
                    "method": method,
                }
            )
            continue
        if i == len(lyric_lines) - 1:
            chunk = words[word_i:]
        else:
            chunk = words[word_i : word_i + n]
            if not chunk:
                chunk = [words[word_i]]
        word_i += len(chunk)
        start = float(chunk[0]["start"])
        end = float(chunk[-1]["end"])
        scores_list = [float(w.get("score") or 0) for w in chunk]
        conf = statistics.fmean(scores_list) if scores_list else 0.0
        cues.append(
            {
                "lineIndex": i,
                "startMs": ms(start),
                "endMs": ms(end),
                "english": line,
                "chinese": "",
                "confidence": score_to_confidence(conf),
                "method": method,
            }
        )
    return cues


def write_timeline(
    out_dir: Path,
    cues: list[dict],
    meta: dict,
    *,
    article_id: int | str = 0,
    audio_hash: str = "",
    lyrics_hash: str = "",
    source: str = "eval",
    stem: str = "timeline",
) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)
    duration_ms = int(meta.get("durationMs") or 0)
    timeline = {
        "version": 1,
        "articleId": int(article_id) if str(article_id).isdigit() else 0,
        "audioHash": audio_hash,
        "lyricsHash": lyrics_hash,
        "durationMs": duration_ms,
        "source": source,
        "cues": cues,
        "warnings": [],
        "confidence": (
            sum(float(c.get("confidence") or 0) for c in cues) / len(cues) if cues else 0.0
        ),
        "evalMeta": meta,
    }
    json_path = out_dir / f"{stem}.json"
    srt_path = out_dir / f"{stem}.srt"
    meta_path = out_dir / f"{stem}_meta.json"
    json_path.write_text(json.dumps(timeline, ensure_ascii=False, indent=2), encoding="utf-8")
    write_srt(cues, srt_path)
    meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    return {
        "timelinePath": str(json_path),
        "srtPath": str(srt_path),
        "metaPath": str(meta_path),
        "cueCount": len(cues),
        "durationMs": duration_ms,
        **meta,
    }


def normalize_english_word(token: str) -> str:
    return re.sub(r"[^A-Za-z0-9']+", "", token).upper()
