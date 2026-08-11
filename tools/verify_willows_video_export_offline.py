#!/usr/bin/env python3
"""Verify one complete Willows listening-video export cohort offline."""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import json
import math
import re
import sqlite3
import subprocess
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


SERIES_TITLE = "The Wind in the Willows"
EPISODE_RE = re.compile(r"\b(E\d{2})\b", re.IGNORECASE)
TIMESTAMP_RE = re.compile(
    r"^(\d{2}):(\d{2}):(\d{2}),(\d{3}) --> "
    r"(\d{2}):(\d{2}):(\d{2}),(\d{3})$"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True, type=Path)
    parser.add_argument("--metadata", required=True, type=Path)
    parser.add_argument("--ffmpeg", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--cutoff", required=True)
    parser.add_argument("--series-title", default=SERIES_TITLE)
    parser.add_argument("--workers", type=int, default=8)
    return parser.parse_args()


def connect_read_only(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    return connection


def parse_datetime(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.removesuffix("Z") + ("+00:00" if value.endswith("Z") else ""))


def clean_subtitle_text(text: str) -> str:
    text = re.sub(r"<[^>]+>", "", text)
    return " ".join(text.replace("\r", " ").replace("\n", " ").replace("\t", " ").split())


def timestamp_ms(groups: tuple[str, ...]) -> int:
    hours, minutes, seconds, millis = (int(value) for value in groups)
    return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis


def parse_srt(path: Path) -> list[dict[str, Any]]:
    text = path.read_text(encoding="utf-8-sig").replace("\r\n", "\n").strip()
    if not text:
        return []
    cues: list[dict[str, Any]] = []
    for block in re.split(r"\n{2,}", text):
        lines = [line.strip() for line in block.splitlines()]
        if len(lines) < 3 or not lines[0].isdigit():
            raise ValueError(f"invalid SRT block: {block[:160]!r}")
        match = TIMESTAMP_RE.fullmatch(lines[1])
        if match is None:
            raise ValueError(f"invalid SRT timestamp: {lines[1]!r}")
        cues.append(
            {
                "number": int(lines[0]),
                "startMs": timestamp_ms(match.groups()[:4]),
                "endMs": timestamp_ms(match.groups()[4:]),
                "english": lines[2],
                "chinese": " ".join(lines[3:]).strip(),
            }
        )
    return cues


def probe_first_frames(ffmpeg: Path, video: Path) -> dict[str, Any]:
    try:
        completed = subprocess.run(
            [
                str(ffmpeg),
                "-v",
                "error",
                "-xerror",
                "-i",
                str(video),
                "-map",
                "0:v:0",
                "-map",
                "0:a:0",
                "-frames:v",
                "1",
                "-frames:a",
                "1",
                "-f",
                "null",
                "-",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"ok": False, "error": str(error)}
    return {
        "ok": completed.returncode == 0,
        "error": completed.stderr.strip() if completed.returncode != 0 else None,
    }


def main() -> int:
    args = parse_args()
    for path in (args.db, args.metadata, args.ffmpeg):
        if not path.is_file():
            raise FileNotFoundError(path)
    cutoff = parse_datetime(args.cutoff)
    workers = max(1, min(args.workers, 16))

    connection = connect_read_only(args.db)
    try:
        article_rows = connection.execute(
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
        articles: dict[int, dict[str, Any]] = {}
        for row in article_rows:
            title = str(row["title"])
            episode_match = EPISODE_RE.search(title)
            if episode_match is None:
                continue
            article_id = int(row["article_id"])
            sentences = [str(value).strip() for value in json.loads(str(row["sentences"]))]
            translation_rows = connection.execute(
                """
                SELECT sentence_index, english_sentence, chinese_text
                  FROM article_sentence_translations
                 WHERE article_id = ?
                 ORDER BY sentence_index
                """,
                (article_id,),
            ).fetchall()
            translations = {
                int(value["sentence_index"]): {
                    "english": str(value["english_sentence"]),
                    "chinese": str(value["chinese_text"]),
                }
                for value in translation_rows
            }
            articles[article_id] = {
                "episode": episode_match.group(1).upper(),
                "title": title,
                "sentences": sentences,
                "translations": translations,
            }
    finally:
        connection.close()

    metadata_payload = json.loads(args.metadata.read_text(encoding="utf-8"))
    all_versions = metadata_payload.get("versions") or []
    cohort = [
        value
        for value in all_versions
        if int(value.get("articleId") or -1) in articles
        and parse_datetime(str(value.get("createdAt") or "1970-01-01")) >= cutoff
    ]
    by_article: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for value in cohort:
        by_article[int(value["articleId"])].append(value)

    errors: list[dict[str, Any]] = []
    chapter_reports: list[dict[str, Any]] = []
    video_paths: dict[Path, dict[str, Any]] = {}
    cue_count = 0
    for article_id, article in sorted(articles.items(), key=lambda item: item[1]["episode"]):
        versions = by_article.get(article_id, [])
        srt_versions = [value for value in versions if str(value.get("subtitlePath") or "").strip()]
        burned_versions = [value for value in versions if not str(value.get("subtitlePath") or "").strip()]
        chapter_error_start = len(errors)
        if len(versions) != 2 or len(srt_versions) != 1 or len(burned_versions) != 1:
            errors.append(
                {
                    "episode": article["episode"],
                    "type": "version_cardinality",
                    "versionCount": len(versions),
                    "srtVersionCount": len(srt_versions),
                    "burnedVersionCount": len(burned_versions),
                }
            )
        for version in versions:
            video_path = Path(str(version.get("videoPath") or ""))
            if not video_path.is_file() or video_path.stat().st_size <= 0:
                errors.append(
                    {
                        "episode": article["episode"],
                        "type": "missing_video",
                        "videoId": version.get("id"),
                        "path": str(video_path),
                    }
                )
                continue
            video_paths[video_path.resolve()] = version
            metadata_size = int(version.get("sizeBytes") or 0)
            if metadata_size != video_path.stat().st_size:
                errors.append(
                    {
                        "episode": article["episode"],
                        "type": "video_size_mismatch",
                        "videoId": version.get("id"),
                        "metadataSize": metadata_size,
                        "actualSize": video_path.stat().st_size,
                    }
                )
            expected = {
                "codec": "h264",
                "resolution": "1920x1080",
                "pageTransition": "pageCurl",
                "droppedFrameCount": 0,
                "encoderName": "h264_nvenc",
            }
            for key, expected_value in expected.items():
                actual = version.get(key)
                if actual != expected_value:
                    errors.append(
                        {
                            "episode": article["episode"],
                            "type": "metadata_mismatch",
                            "videoId": version.get("id"),
                            "field": key,
                            "expected": expected_value,
                            "actual": actual,
                        }
                    )
            if int(version.get("durationMs") or 0) <= 0 or int(version.get("frameCount") or 0) <= 0:
                errors.append(
                    {
                        "episode": article["episode"],
                        "type": "invalid_duration_or_frames",
                        "videoId": version.get("id"),
                    }
                )

        if srt_versions:
            srt_version = srt_versions[0]
            srt_path = Path(str(srt_version.get("subtitlePath") or ""))
            try:
                cues = parse_srt(srt_path)
            except (OSError, UnicodeError, ValueError) as error:
                errors.append(
                    {
                        "episode": article["episode"],
                        "type": "srt_parse_error",
                        "path": str(srt_path),
                        "error": str(error),
                    }
                )
                cues = []
            visible = [
                (index, sentence)
                for index, sentence in enumerate(article["sentences"])
                if sentence.strip()
            ]
            cue_count += len(cues)
            if len(cues) != len(visible):
                errors.append(
                    {
                        "episode": article["episode"],
                        "type": "srt_cue_count",
                        "expected": len(visible),
                        "actual": len(cues),
                    }
                )
            previous_end = 0
            for cue_index, (cue, sentence_item) in enumerate(zip(cues, visible)):
                sentence_index, sentence = sentence_item
                translation = article["translations"].get(sentence_index, {})
                expected_english = clean_subtitle_text(sentence)
                expected_chinese = clean_subtitle_text(str(translation.get("chinese") or ""))
                if cue["number"] != cue_index + 1:
                    errors.append(
                        {
                            "episode": article["episode"],
                            "type": "srt_sequence",
                            "cue": cue_index + 1,
                            "actual": cue["number"],
                        }
                    )
                if cue["startMs"] != previous_end or cue["endMs"] <= cue["startMs"]:
                    errors.append(
                        {
                            "episode": article["episode"],
                            "type": "srt_timing",
                            "cue": cue_index + 1,
                            "previousEndMs": previous_end,
                            "startMs": cue["startMs"],
                            "endMs": cue["endMs"],
                        }
                    )
                previous_end = cue["endMs"]
                if cue["english"] != expected_english:
                    errors.append(
                        {
                            "episode": article["episode"],
                            "type": "srt_english_mismatch",
                            "cue": cue_index + 1,
                            "expected": expected_english,
                            "actual": cue["english"],
                        }
                    )
                if cue["chinese"] != expected_chinese:
                    errors.append(
                        {
                            "episode": article["episode"],
                            "type": "srt_chinese_mismatch",
                            "cue": cue_index + 1,
                            "expected": expected_chinese,
                            "actual": cue["chinese"],
                        }
                    )
            duration_ms = int(srt_version.get("durationMs") or 0)
            if cues and abs(cues[-1]["endMs"] - duration_ms) > 1000:
                errors.append(
                    {
                        "episode": article["episode"],
                        "type": "srt_duration_mismatch",
                        "srtEndMs": cues[-1]["endMs"],
                        "videoDurationMs": duration_ms,
                    }
                )
        if srt_versions and burned_versions:
            duration_difference = abs(
                int(srt_versions[0].get("durationMs") or 0)
                - int(burned_versions[0].get("durationMs") or 0)
            )
            if duration_difference > 1000:
                errors.append(
                    {
                        "episode": article["episode"],
                        "type": "variant_duration_mismatch",
                        "differenceMs": duration_difference,
                    }
                )
        chapter_reports.append(
            {
                "episode": article["episode"],
                "articleId": article_id,
                "sentenceCount": len([value for value in article["sentences"] if value]),
                "versionIds": [value.get("id") for value in versions],
                "errorCount": len(errors) - chapter_error_start,
            }
        )

    probe_results: dict[Path, dict[str, Any]] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {
            executor.submit(probe_first_frames, args.ffmpeg.resolve(), video): video
            for video in video_paths
        }
        for future in concurrent.futures.as_completed(futures):
            video = futures[future]
            probe_results[video] = future.result()
    for video, result in probe_results.items():
        if not result["ok"]:
            version = video_paths[video]
            article = articles[int(version["articleId"])]
            errors.append(
                {
                    "episode": article["episode"],
                    "type": "ffmpeg_decode_error",
                    "videoId": version.get("id"),
                    "path": str(video),
                    "error": result.get("error"),
                }
            )

    total_bytes = sum(path.stat().st_size for path in video_paths)
    total_duration_ms = sum(int(value.get("durationMs") or 0) for value in cohort)
    error_types = Counter(str(value.get("type")) for value in errors)
    generated_at = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    summary = {
        "generatedAt": generated_at,
        "mode": "read_only_offline",
        "seriesTitle": args.series_title,
        "cutoff": args.cutoff,
        "chapterCount": len(articles),
        "versionCount": len(cohort),
        "srtVersionCount": sum(bool(value.get("subtitlePath")) for value in cohort),
        "burnedInVersionCount": sum(not bool(value.get("subtitlePath")) for value in cohort),
        "videoFileCount": len(video_paths),
        "srtCueCount": cue_count,
        "totalBytes": total_bytes,
        "totalDurationMsAcrossBothVariants": total_duration_ms,
        "decodedFirstFrameAndAudioCount": sum(result["ok"] for result in probe_results.values()),
        "droppedFrameCount": sum(int(value.get("droppedFrameCount") or 0) for value in cohort),
        "errorCount": len(errors),
        "errorTypes": dict(sorted(error_types.items())),
        "remoteApiCalls": 0,
        "passed": (
            len(articles) == 62
            and len(cohort) == 124
            and len(video_paths) == 124
            and cue_count == 4673
            and not errors
        ),
    }
    report = {
        "schemaVersion": "willows_listening_video_verification_v1",
        "summary": summary,
        "chapters": chapter_reports,
        "errors": errors,
    }
    args.output_root.mkdir(parents=True, exist_ok=True)
    json_path = args.output_root / "willows-listening-video-verification.json"
    markdown_path = args.output_root / "README.md"
    json_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    markdown_path.write_text(
        "\n".join(
            [
                "# The Wind in the Willows listening video verification",
                "",
                f"- Generated: `{generated_at}`",
                f"- Chapters: **{summary['chapterCount']}**",
                f"- New video versions: **{summary['versionCount']}**",
                f"- Video files: **{summary['videoFileCount']}**",
                f"- SRT cues: **{summary['srtCueCount']}**",
                f"- Decoded first video/audio frames: **{summary['decodedFirstFrameAndAudioCount']}**",
                f"- Dropped frames reported by export: **{summary['droppedFrameCount']}**",
                f"- Errors: **{summary['errorCount']}**",
                f"- Remote API calls: **{summary['remoteApiCalls']}**",
                f"- Passed: **{summary['passed']}**",
                "",
            ]
        ),
        encoding="utf-8",
    )
    print(
        json.dumps(
            {"json": str(json_path.resolve()), "markdown": str(markdown_path.resolve()), **summary},
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
