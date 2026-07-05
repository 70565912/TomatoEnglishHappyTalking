#!/usr/bin/env python3
"""Restore E15 (article 65) AI 6-scene plan from backup summary_json."""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

DB = Path(
    r"F:\TomatoEnglishHappyTalking\release\windows\tomato_english_happy_talking"
    r"\.dart_tool\sqflite_common_ffi\databases\english_love.db"
)
BACKUP_SUMMARY = Path(r"F:\TomatoEnglishHappyTalking\tmp_e15_restore_summary.json")
ARTICLE_ID = 65


def main() -> None:
    summary = json.loads(BACKUP_SUMMARY.read_text(encoding="utf-8-sig"))
    summary.pop("contentHash", None)
    scenes = summary.get("scenes") or []
    if len(scenes) != 6:
        raise SystemExit(f"expected 6 scenes, got {len(scenes)}")
    for scene in scenes:
        if not str(scene.get("sceneDescription", "")).strip():
            raise SystemExit(f"scene {scene.get('pageIndex')} has empty description")

    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row
    try:
        article = conn.execute(
            "SELECT title FROM articles WHERE id = ?", (ARTICLE_ID,)
        ).fetchone()
        if article is None:
            raise SystemExit(f"article {ARTICLE_ID} not found")
        summary["title"] = article["title"]

        summary_text = json.dumps(summary, ensure_ascii=False, separators=(",", ":"))
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]
        conn.execute(
            """
            UPDATE story_chapters
            SET summary_json = ?, updated_at = ?
            WHERE article_id = ?
            """,
            (summary_text, now, ARTICLE_ID),
        )

        page_rows = conn.execute(
            "SELECT page_index FROM picture_book_pages WHERE article_id = ? ORDER BY page_index",
            (ARTICLE_ID,),
        ).fetchall()
        conn.execute(
            "DELETE FROM picture_book_pages WHERE article_id = ?", (ARTICLE_ID,)
        )

        cache_keys = [
            row["cache_key"]
            for row in conn.execute(
                """
                SELECT cache_key FROM api_cache_article_refs
                WHERE article_id = ? AND purpose = 'picture_book_image'
                """,
                (ARTICLE_ID,),
            ).fetchall()
        ]
        conn.execute(
            """
            DELETE FROM api_cache_article_refs
            WHERE article_id = ? AND purpose = 'picture_book_image'
            """,
            (ARTICLE_ID,),
        )
        for key in cache_keys:
            ref_count = conn.execute(
                "SELECT COUNT(*) FROM api_cache_article_refs WHERE cache_key = ?",
                (key,),
            ).fetchone()[0]
            if ref_count:
                continue
            entry = conn.execute(
                "SELECT file_path FROM api_cache_entries WHERE cache_key = ?",
                (key,),
            ).fetchone()
            conn.execute(
                "DELETE FROM api_cache_entries WHERE cache_key = ?", (key,)
            )
            if entry and entry["file_path"]:
                path = Path(entry["file_path"])
                if path.is_file():
                    path.unlink()

        conn.commit()
        print("restored_summary_scenes", len(scenes))
        print("deleted_pages", len(page_rows), [r["page_index"] for r in page_rows])
        print("deleted_cache_refs", len(cache_keys))
        print("article_title", summary["title"])
        for scene in scenes:
            print(
                f"scene {scene['pageIndex']}: "
                f"{scene['sentenceStartIndex']}-{scene['sentenceEndIndex']}: "
                f"{scene['sceneDescription'][:80]}..."
            )
    finally:
        conn.close()


if __name__ == "__main__":
    main()
