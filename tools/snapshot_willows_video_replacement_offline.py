#!/usr/bin/env python3
"""Snapshot exact old/new Willows video IDs before changing defaults or deleting."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import shutil
import sqlite3
from pathlib import Path
from typing import Any


SERIES_TITLE = "The Wind in the Willows"
EPISODE_RE = re.compile(r"\b(E\d{2})\b", re.IGNORECASE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True, type=Path)
    parser.add_argument("--metadata", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--cutoff", required=True)
    parser.add_argument("--expected-old-version-count", type=int, default=128)
    parser.add_argument("--series-title", default=SERIES_TITLE)
    return parser.parse_args()


def parse_datetime(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value)


def file_details(path_text: str) -> dict[str, Any]:
    path = Path(path_text)
    return {
        "path": str(path),
        "exists": path.is_file(),
        "sizeBytes": path.stat().st_size if path.is_file() else 0,
    }


def main() -> int:
    args = parse_args()
    cutoff = parse_datetime(args.cutoff)
    connection = sqlite3.connect(args.db.resolve().as_uri() + "?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    try:
        rows = connection.execute(
            """
            SELECT a.id AS article_id, a.title
              FROM story_series ss
              JOIN story_chapters sc ON sc.series_id = ss.id
              JOIN articles a ON a.id = sc.article_id
             WHERE ss.title = ?
             ORDER BY sc.chapter_order, a.id
            """,
            (args.series_title,),
        ).fetchall()
    finally:
        connection.close()
    articles: dict[int, dict[str, Any]] = {}
    for row in rows:
        title = str(row["title"])
        match = EPISODE_RE.search(title)
        if match is None:
            continue
        articles[int(row["article_id"])] = {
            "episode": match.group(1).upper(),
            "title": title,
        }

    payload = json.loads(args.metadata.read_text(encoding="utf-8"))
    versions = [
        value
        for value in payload.get("versions") or []
        if int(value.get("articleId") or -1) in articles
    ]
    old_versions = [
        value for value in versions if parse_datetime(str(value["createdAt"])) < cutoff
    ]
    new_versions = [
        value for value in versions if parse_datetime(str(value["createdAt"])) >= cutoff
    ]

    old_by_article: dict[int, list[dict[str, Any]]] = {}
    new_by_article: dict[int, list[dict[str, Any]]] = {}
    for article_id in articles:
        old_by_article[article_id] = [
            value for value in old_versions if int(value["articleId"]) == article_id
        ]
        new_by_article[article_id] = [
            value for value in new_versions if int(value["articleId"]) == article_id
        ]

    chapters: list[dict[str, Any]] = []
    mapping_errors: list[dict[str, Any]] = []
    for article_id, article in sorted(articles.items(), key=lambda item: item[1]["episode"]):
        old_items = old_by_article[article_id]
        new_items = new_by_article[article_id]
        old_defaults = [value for value in old_items if value.get("isDefault")]
        target_default: dict[str, Any] | None = None
        if len(old_defaults) == 1:
            old_default_is_srt = bool(str(old_defaults[0].get("subtitlePath") or "").strip())
            candidates = [
                value
                for value in new_items
                if bool(str(value.get("subtitlePath") or "").strip()) == old_default_is_srt
            ]
            if len(candidates) == 1:
                target_default = candidates[0]
        if len(old_items) != 2 or len(new_items) != 2 or len(old_defaults) != 1 or target_default is None:
            mapping_errors.append(
                {
                    "episode": article["episode"],
                    "oldVersionCount": len(old_items),
                    "newVersionCount": len(new_items),
                    "oldDefaultCount": len(old_defaults),
                    "hasTargetDefault": target_default is not None,
                }
            )
        chapters.append(
            {
                "episode": article["episode"],
                "articleId": article_id,
                "title": article["title"],
                "oldDefaultId": old_defaults[0]["id"] if len(old_defaults) == 1 else None,
                "oldDefaultKind": (
                    "srt"
                    if len(old_defaults) == 1 and old_defaults[0].get("subtitlePath")
                    else "subtitled"
                    if len(old_defaults) == 1
                    else None
                ),
                "newDefaultId": target_default["id"] if target_default is not None else None,
                "newDefaultKind": (
                    "srt"
                    if target_default is not None and target_default.get("subtitlePath")
                    else "subtitled"
                    if target_default is not None
                    else None
                ),
                "oldVersionIds": [value["id"] for value in old_items],
                "newVersionIds": [value["id"] for value in new_items],
            }
        )

    delete_targets = []
    for value in sorted(
        old_versions,
        key=lambda item: (articles[int(item["articleId"])]["episode"], item["id"]),
    ):
        article = articles[int(value["articleId"])]
        delete_targets.append(
            {
                "id": value["id"],
                "articleId": int(value["articleId"]),
                "episode": article["episode"],
                "kind": "srt" if value.get("subtitlePath") else "subtitled",
                "wasDefault": bool(value.get("isDefault")),
                "video": file_details(str(value.get("videoPath") or "")),
                "subtitle": (
                    file_details(str(value["subtitlePath"]))
                    if value.get("subtitlePath")
                    else None
                ),
            }
        )

    expected_count_matches = len(delete_targets) == args.expected_old_version_count
    summary = {
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "seriesTitle": args.series_title,
        "cutoff": args.cutoff,
        "chapterCount": len(articles),
        "oldVersionCount": len(old_versions),
        "newVersionCount": len(new_versions),
        "oldDefaultCount": sum(bool(value.get("isDefault")) for value in old_versions),
        "newDefaultCountBeforeReplacement": sum(
            bool(value.get("isDefault")) for value in new_versions
        ),
        "expectedOldVersionCount": args.expected_old_version_count,
        "expectedOldVersionCountMatches": expected_count_matches,
        "mappingErrorCount": len(mapping_errors),
        "replacementMappingReady": len(mapping_errors) == 0,
        "deletionAuthorizedByCountGate": expected_count_matches and not mapping_errors,
    }
    report = {
        "schemaVersion": "willows_video_replacement_snapshot_v1",
        "summary": summary,
        "chapters": chapters,
        "mappingErrors": mapping_errors,
        "deleteTargets": delete_targets,
    }
    args.output_root.mkdir(parents=True, exist_ok=True)
    snapshot_path = args.output_root / "willows-video-replacement-snapshot.json"
    metadata_backup_path = args.output_root / "recording_video_versions.before-replacement.json"
    snapshot_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    shutil.copy2(args.metadata, metadata_backup_path)
    print(
        json.dumps(
            {
                "snapshot": str(snapshot_path.resolve()),
                "metadataBackup": str(metadata_backup_path.resolve()),
                **summary,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0 if summary["replacementMappingReady"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
