#!/usr/bin/env python3
"""Verify persisted Willows listening audio without calling remote services."""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import json
import math
import re
import sqlite3
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SERIES_TITLE = "The Wind in the Willows"
EPISODE_RE = re.compile(r"\b(E\d{2})\b", re.IGNORECASE)
TOKEN_RE = re.compile(r"[A-Za-z0-9]+(?:['’\-][A-Za-z0-9]+)*")


@dataclass(frozen=True)
class AudioHandle:
    cache_key: str
    path: Path
    purpose: str
    source: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True, type=Path)
    parser.add_argument("--ffprobe", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--series-title", default=SERIES_TITLE)
    parser.add_argument("--workers", type=int, default=8)
    return parser.parse_args()


def connect_read_only(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    return connection


def normalize_cache_text(text: str) -> str:
    tokens = [match.group(0) for match in TOKEN_RE.finditer(text)]
    if tokens:
        return "\x1f".join(tokens)
    return " ".join(text.strip().split())


def request_text(request_json: str) -> str:
    try:
        decoded = json.loads(request_json)
    except (json.JSONDecodeError, TypeError):
        return ""
    text = decoded.get("text") if isinstance(decoded, dict) else None
    return text if isinstance(text, str) else ""


def resolve_audio_path(raw_path: str, runtime_root: Path) -> Path:
    path = Path(raw_path)
    return path if path.is_absolute() else runtime_root / path


def load_handles(
    connection: sqlite3.Connection,
    article_id: int,
    runtime_root: Path,
) -> dict[str, AudioHandle]:
    handles: dict[str, AudioHandle] = {}
    for purpose in ("listening_tts", "follow_tts"):
        rows = connection.execute(
            """
            SELECT e.cache_key, e.request_json, e.file_path, e.source
              FROM api_cache_article_refs r
              JOIN api_cache_entries e ON e.cache_key = r.cache_key
             WHERE r.article_id = ?
               AND r.purpose = ?
               AND e.purpose = ?
             ORDER BY e.updated_at DESC, e.last_used_at DESC
             LIMIT 5000
            """,
            (article_id, purpose, purpose),
        ).fetchall()
        for row in rows:
            text = request_text(str(row["request_json"]))
            key = normalize_cache_text(text)
            if not key or key in handles or not row["file_path"]:
                continue
            path = resolve_audio_path(str(row["file_path"]), runtime_root)
            if path.is_file() and path.stat().st_size > 0:
                handles[key] = AudioHandle(
                    cache_key=str(row["cache_key"]),
                    path=path.resolve(),
                    purpose=purpose,
                    source=str(row["source"]),
                )
    return handles


def probe_audio(ffprobe: Path, path: Path) -> dict[str, Any]:
    try:
        completed = subprocess.run(
            [
                str(ffprobe),
                "-v",
                "error",
                "-select_streams",
                "a:0",
                "-show_entries",
                "stream=codec_name,duration:format=duration",
                "-of",
                "json",
                str(path),
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=20,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"ok": False, "error": str(error), "durationSeconds": 0.0}
    if completed.returncode != 0:
        return {
            "ok": False,
            "error": completed.stderr.strip() or f"ffprobe exit {completed.returncode}",
            "durationSeconds": 0.0,
        }
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        return {"ok": False, "error": str(error), "durationSeconds": 0.0}
    streams = payload.get("streams") or []
    codec = str(streams[0].get("codec_name") or "") if streams else ""
    raw_durations = [
        (streams[0].get("duration") if streams else None),
        (payload.get("format") or {}).get("duration"),
    ]
    durations: list[float] = []
    for raw_duration in raw_durations:
        try:
            duration = float(raw_duration)
        except (TypeError, ValueError):
            continue
        if math.isfinite(duration):
            durations.append(duration)
    duration_seconds = max(durations, default=0.0)
    ok = bool(codec) and duration_seconds > 0
    return {
        "ok": ok,
        "codec": codec,
        "durationSeconds": duration_seconds,
        "error": None if ok else "missing audio stream or positive duration",
    }


def main() -> int:
    args = parse_args()
    if not args.db.is_file():
        raise FileNotFoundError(args.db)
    if not args.ffprobe.is_file():
        raise FileNotFoundError(args.ffprobe)
    workers = max(1, min(args.workers, 16))
    runtime_root = args.db.resolve().parents[3]
    connection = connect_read_only(args.db)
    try:
        articles = connection.execute(
            """
            SELECT a.id AS article_id, a.title, a.sentences
              FROM story_series ss
              JOIN story_chapters sc ON sc.series_id = ss.id
              JOIN articles a ON a.id = sc.article_id
             WHERE ss.title = ?
             ORDER BY sc.chapter_order, a.id
            """,
            (args.series_title,),
        ).fetchall()
        chapters: list[dict[str, Any]] = []
        selected_paths: dict[Path, dict[str, Any]] = {}
        missing_refs: list[dict[str, Any]] = []
        sentence_ref_count = 0
        for article in articles:
            title = str(article["title"])
            episode_match = EPISODE_RE.search(title)
            if episode_match is None:
                continue
            episode = episode_match.group(1).upper()
            sentences_raw = json.loads(str(article["sentences"]))
            sentences = [str(value).strip() for value in sentences_raw]
            handles = load_handles(connection, int(article["article_id"]), runtime_root)
            chapter_ref_count = 0
            for index, sentence in enumerate(sentences):
                if not sentence:
                    continue
                sentence_ref_count += 1
                chapter_ref_count += 1
                handle = handles.get(normalize_cache_text(sentence))
                if handle is None:
                    missing_refs.append(
                        {
                            "episode": episode,
                            "articleId": int(article["article_id"]),
                            "sentenceIndex": index,
                            "text": sentence,
                        }
                    )
                    continue
                selected_paths.setdefault(
                    handle.path,
                    {
                        "cacheKey": handle.cache_key,
                        "purpose": handle.purpose,
                        "source": handle.source,
                        "references": [],
                    },
                )["references"].append(
                    {
                        "episode": episode,
                        "articleId": int(article["article_id"]),
                        "sentenceIndex": index,
                    }
                )
            chapters.append(
                {
                    "episode": episode,
                    "articleId": int(article["article_id"]),
                    "sentenceReferences": chapter_ref_count,
                }
            )
    finally:
        connection.close()

    probe_results: dict[Path, dict[str, Any]] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {
            executor.submit(probe_audio, args.ffprobe.resolve(), path): path
            for path in selected_paths
        }
        for future in concurrent.futures.as_completed(futures):
            path = futures[future]
            probe_results[path] = future.result()

    invalid_files: list[dict[str, Any]] = []
    total_duration = 0.0
    total_bytes = 0
    codecs: set[str] = set()
    for path, metadata in selected_paths.items():
        result = probe_results[path]
        total_bytes += path.stat().st_size
        if result["ok"]:
            total_duration += float(result["durationSeconds"])
            codecs.add(str(result["codec"]))
            continue
        invalid_files.append(
            {
                "filePath": str(path),
                "cacheKey": metadata["cacheKey"],
                "references": metadata["references"],
                "error": result.get("error"),
            }
        )

    generated_at = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    summary = {
        "generatedAt": generated_at,
        "mode": "read_only_offline",
        "seriesTitle": args.series_title,
        "chapterCount": len(chapters),
        "sentenceReferenceCount": sentence_ref_count,
        "missingReferenceCount": len(missing_refs),
        "uniqueSelectedFileCount": len(selected_paths),
        "validFileCount": len(selected_paths) - len(invalid_files),
        "invalidFileCount": len(invalid_files),
        "totalBytes": total_bytes,
        "totalDurationSeconds": round(total_duration, 3),
        "codecs": sorted(codecs),
        "workers": workers,
        "remoteApiCalls": 0,
        "passed": not missing_refs and not invalid_files and sentence_ref_count == 4673,
    }
    report = {
        "schemaVersion": "willows_listening_audio_verification_v1",
        "summary": summary,
        "chapters": chapters,
        "missingReferences": missing_refs,
        "invalidFiles": invalid_files,
    }
    args.output_root.mkdir(parents=True, exist_ok=True)
    json_path = args.output_root / "willows-listening-audio-verification.json"
    markdown_path = args.output_root / "README.md"
    json_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    markdown_path.write_text(
        "\n".join(
            [
                "# The Wind in the Willows listening audio verification",
                "",
                f"- Generated: `{generated_at}`",
                f"- Chapters: **{summary['chapterCount']}**",
                f"- Sentence references: **{sentence_ref_count}**",
                f"- Missing references: **{len(missing_refs)}**",
                f"- Unique selected files: **{len(selected_paths)}**",
                f"- Valid files: **{summary['validFileCount']}**",
                f"- Invalid files: **{len(invalid_files)}**",
                f"- Total duration: **{summary['totalDurationSeconds']} seconds**",
                f"- Codecs: **{', '.join(summary['codecs']) or 'none'}**",
                f"- Remote API calls: **0**",
                f"- Passed: **{summary['passed']}**",
                "",
            ]
        ),
        encoding="utf-8",
    )
    print(json.dumps({"json": str(json_path.resolve()), "markdown": str(markdown_path.resolve()), **summary}, ensure_ascii=False, indent=2))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
