#!/usr/bin/env python3
"""Move recording-export files into type/book folders and rewrite video index paths.

Usage:
  python tools/reorganize_recording_export.py --what-if
  python tools/reorganize_recording_export.py
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sqlite3
import sys
from pathlib import Path
from typing import Any


EXPORT_NAME_RE = re.compile(
    r"^(?P<episode>.+?) - (?P<kind>listening|song-audio|song) - "
    r"(?:(?P<subtitle>srt|subtitled) - )?"
    r"(?P<stamp>\d{8}-\d{6})(?:-\d+)?\.(?P<ext>mp3|mp4|srt)$",
    re.IGNORECASE,
)
KIND_FOLDERS = ("srt", "subtitled", "mp3")
INDEX_FILE_NAME = "recording_video_versions.json"


def parse_args() -> argparse.Namespace:
    workspace = Path(__file__).resolve().parent.parent
    release_root = workspace / "release" / "windows" / "tomato_english_happy_talking"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--export-root",
        type=Path,
        default=release_root / "recording-export",
    )
    parser.add_argument(
        "--database",
        type=Path,
        default=release_root
        / ".dart_tool"
        / "sqflite_common_ffi"
        / "databases"
        / "english_love.db",
    )
    parser.add_argument(
        "--report-path",
        type=Path,
        default=workspace / ".tmp" / "reorganize_recording_export_report.json",
    )
    parser.add_argument("--what-if", action="store_true")
    return parser.parse_args()


def sanitize_file_name(value: str) -> str:
    cleaned = re.sub(r'[<>:"/\\|?*]+', " ", value)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    if not cleaned:
        return "Tomato Recording"
    if len(cleaned) <= 160:
        return cleaned
    return cleaned[:160].strip()


def load_series_titles(database: Path) -> list[str]:
    if not database.is_file():
        raise FileNotFoundError(f"Database not found: {database}")
    uri = database.resolve().as_posix()
    connection = sqlite3.connect(f"file:{uri}?mode=ro", uri=True)
    try:
        rows = connection.execute(
            "SELECT title FROM story_series WHERE TRIM(COALESCE(title, '')) != ''"
        ).fetchall()
    finally:
        connection.close()
    titles = [str(row[0]).strip() for row in rows if str(row[0]).strip()]
    titles.sort(key=len, reverse=True)
    return titles


def split_book_and_article(episode: str, series_titles: list[str]) -> tuple[str, str, bool]:
    for series in series_titles:
        if episode == series:
            return series, series, True
        prefix = f"{series} - "
        if episode.startswith(prefix):
            article = episode[len(prefix) :].strip() or series
            return series, article, True
    return episode, episode, False


def infer_kind(file_name: str, fallback_kind: str) -> str:
    match = EXPORT_NAME_RE.match(file_name)
    if match is None:
        return fallback_kind
    kind = match.group("kind").lower()
    subtitle = (match.group("subtitle") or "").lower()
    extension = match.group("ext").lower()
    if kind == "song-audio" or extension == "mp3":
        return "mp3"
    if subtitle == "subtitled":
        return "subtitled"
    return "srt"


def path_key(path: Path) -> str:
    return os.path.normcase(str(path.resolve()))


def collect_source_files(export_root: Path) -> list[tuple[Path, str]]:
    files: list[tuple[Path, str]] = []
    for kind in KIND_FOLDERS:
        directory = export_root / kind
        if not directory.is_dir():
            continue
        for child in directory.iterdir():
            if child.is_file():
                files.append((child, kind))
    for child in export_root.iterdir():
        if child.is_file() and child.suffix.lower() in {".mp4", ".srt", ".mp3"}:
            files.append((child, infer_kind(child.name, "srt")))
    return files


def plan_moves(
    export_root: Path,
    series_titles: list[str],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    moves: list[dict[str, Any]] = []
    skipped: list[dict[str, Any]] = []
    planned_sources: set[str] = set()
    planned_destinations: set[str] = set()

    for source, kind in collect_source_files(export_root):
        source_key = path_key(source)
        if source_key in planned_sources:
            continue
        match = EXPORT_NAME_RE.match(source.name)
        if match is None:
            skipped.append(
                {
                    "reason": "unrecognized_name",
                    "sourcePath": str(source),
                }
            )
            continue

        episode = match.group("episode").strip()
        book, article, matched = split_book_and_article(episode, series_titles)
        book_folder = sanitize_file_name(book)
        destination_dir = export_root / kind / book_folder
        new_name = article + source.name[len(episode) :]
        destination = destination_dir / new_name
        destination_key = path_key(destination)

        if source_key == destination_key:
            skipped.append(
                {
                    "reason": "already_organized",
                    "sourcePath": str(source),
                }
            )
            continue
        if destination.exists() or destination_key in planned_destinations:
            skipped.append(
                {
                    "reason": "destination_exists",
                    "sourcePath": str(source),
                    "destinationPath": str(destination),
                }
            )
            continue

        planned_sources.add(source_key)
        planned_destinations.add(destination_key)
        moves.append(
            {
                "sourcePath": str(source),
                "destinationPath": str(destination),
                "book": book,
                "article": article,
                "matchedSeries": matched,
                "kind": kind,
            }
        )

        if source.suffix.lower() == ".mp4":
            sidecar = source.with_suffix(".srt")
            if sidecar.is_file():
                sidecar_dest = destination.with_suffix(".srt")
                sidecar_key = path_key(sidecar)
                sidecar_dest_key = path_key(sidecar_dest)
                if sidecar_key in planned_sources:
                    continue
                if sidecar_key == sidecar_dest_key:
                    continue
                if sidecar_dest.exists() or sidecar_dest_key in planned_destinations:
                    skipped.append(
                        {
                            "reason": "destination_exists",
                            "sourcePath": str(sidecar),
                            "destinationPath": str(sidecar_dest),
                        }
                    )
                    continue
                planned_sources.add(sidecar_key)
                planned_destinations.add(sidecar_dest_key)
                moves.append(
                    {
                        "sourcePath": str(sidecar),
                        "destinationPath": str(sidecar_dest),
                        "book": book,
                        "article": article,
                        "matchedSeries": matched,
                        "kind": kind,
                    }
                )

    return moves, skipped


def apply_moves(moves: list[dict[str, Any]]) -> None:
    for item in moves:
        source = Path(item["sourcePath"])
        destination = Path(item["destinationPath"])
        destination.parent.mkdir(parents=True, exist_ok=True)
        source.replace(destination)


def rewrite_video_index(
    index_path: Path,
    moves: list[dict[str, Any]],
    *,
    what_if: bool,
) -> dict[str, Any]:
    if not index_path.is_file():
        return {"updated": 0, "backupPath": "", "missing": True}

    mapping = {
        path_key(Path(item["sourcePath"])): str(Path(item["destinationPath"]))
        for item in moves
    }
    payload = json.loads(index_path.read_text(encoding="utf-8"))
    versions = payload.get("versions")
    if not isinstance(versions, list):
        return {"updated": 0, "backupPath": "", "missing": False}

    updated = 0
    for version in versions:
        if not isinstance(version, dict):
            continue
        changed = False
        for field in ("videoPath", "subtitlePath"):
            raw = str(version.get(field) or "").strip()
            if not raw:
                continue
            replacement = mapping.get(path_key(Path(raw)))
            if replacement is None:
                continue
            version[field] = replacement
            changed = True
        if changed:
            video_path = str(version.get("videoPath") or "").strip()
            if video_path:
                version["title"] = Path(video_path).stem
            updated += 1

    backup_path = ""
    if not what_if and updated > 0:
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_path = str(
            index_path.with_name(
                f"recording_video_versions.backup-before-book-folders-{stamp}.json"
            )
        )
        index_path.replace(backup_path)
        index_path.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    return {
        "updated": updated,
        "backupPath": backup_path,
        "missing": False,
    }


def main() -> int:
    args = parse_args()
    export_root = args.export_root.resolve()
    if not export_root.is_dir():
        raise FileNotFoundError(f"Export directory not found: {export_root}")

    series_titles = load_series_titles(args.database)
    moves, skipped = plan_moves(export_root, series_titles)
    index_preview = rewrite_video_index(
        export_root / INDEX_FILE_NAME,
        moves,
        what_if=True,
    )

    print("=== Reorganize recording-export ===")
    print(f"Export: {export_root}")
    print(f"Database: {args.database}")
    print(f"Series titles: {len(series_titles)}")
    print(f"Mode: {'preview only' if args.what_if else 'apply'}")
    print(f"Pending moves: {len(moves)}")
    print(f"Skipped: {len(skipped)}")
    print(f"Video index rows to update: {index_preview['updated']}")

    books: dict[str, int] = {}
    for item in moves:
        books[item["book"]] = books.get(item["book"], 0) + 1
    for book, count in sorted(books.items(), key=lambda pair: (-pair[1], pair[0])):
        print(f"  {count} -> {book}")

    index_result = index_preview
    if not args.what_if:
        apply_moves(moves)
        index_result = rewrite_video_index(
            export_root / INDEX_FILE_NAME,
            moves,
            what_if=False,
        )
        if index_result["backupPath"]:
            print(f"Index backup: {index_result['backupPath']}")
        print("Moves complete.")
    else:
        print("Preview complete. Re-run without --what-if to move files.")

    report = {
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "exportRoot": str(export_root),
        "database": str(args.database),
        "whatIf": bool(args.what_if),
        "seriesTitles": series_titles,
        "moveCount": len(moves),
        "skippedCount": len(skipped),
        "index": index_result,
        "books": books,
        "moves": moves,
        "skipped": skipped,
    }
    args.report_path.parent.mkdir(parents=True, exist_ok=True)
    args.report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Report: {args.report_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
