#!/usr/bin/env python3
"""Prepare a read-only V3.6 Willows translation review from the live V3.5 DB.

This is a one-time offline tool. It never changes SQLite, calls a remote API,
or touches TTS, pictures, subtitles, or videos. Unchanged sentence slots reuse
the current reviewed Chinese row; changed boundaries are emitted with their
overlapping old bilingual context for human/Codex story translation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
from collections import defaultdict, deque
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


SERIES_TITLE = "The Wind in the Willows"
EPISODE_RE = re.compile(r"\b(E\d{2})\b", re.IGNORECASE)
WHITESPACE_RE = re.compile(r"\s+")


@dataclass(frozen=True)
class OldRow:
    index: int
    english: str
    chinese: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--audit-report", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--series-title", default=SERIES_TITLE)
    return parser.parse_args()


def normalize_whitespace(text: str) -> str:
    return WHITESPACE_RE.sub(" ", text).strip()


def canonical(text: str) -> str:
    return WHITESPACE_RE.sub("", text)


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def sentence_spans(sentences: Iterable[str]) -> tuple[str, list[tuple[int, int]]]:
    stream_parts: list[str] = []
    spans: list[tuple[int, int]] = []
    cursor = 0
    for sentence in sentences:
        normalized = canonical(sentence)
        start = cursor
        cursor += len(normalized)
        stream_parts.append(normalized)
        spans.append((start, cursor))
    return "".join(stream_parts), spans


def connect_read_only(db_path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(db_path.resolve().as_uri() + "?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    return connection


def episode_from_title(title: str) -> str | None:
    match = EPISODE_RE.search(title)
    return match.group(1).upper() if match else None


def load_current_rows(
    connection: sqlite3.Connection,
    series_title: str,
) -> dict[str, tuple[int, str, list[OldRow]]]:
    articles = connection.execute(
        """
        SELECT a.id, a.title, a.sentences
          FROM story_series ss
          JOIN story_chapters sc ON sc.series_id = ss.id
          JOIN articles a ON a.id = sc.article_id
         WHERE ss.title = ?
         ORDER BY sc.chapter_order, a.id
        """,
        (series_title,),
    ).fetchall()
    result: dict[str, tuple[int, str, list[OldRow]]] = {}
    for article in articles:
        episode = episode_from_title(str(article["title"]))
        if episode is None:
            continue
        if episode in result:
            raise ValueError(f"{episode}: duplicate article")
        sentences = json.loads(str(article["sentences"]))
        translations = connection.execute(
            """
            SELECT sentence_index, english_sentence, chinese_text
              FROM article_sentence_translations
             WHERE article_id = ?
             ORDER BY sentence_index
            """,
            (int(article["id"]),),
        ).fetchall()
        if len(sentences) != len(translations):
            raise ValueError(
                f"{episode}: {len(sentences)} sentences but "
                f"{len(translations)} translations"
            )
        rows: list[OldRow] = []
        for index, (english, translation) in enumerate(zip(sentences, translations, strict=True)):
            if (
                int(translation["sentence_index"]) != index
                or str(translation["english_sentence"]) != str(english)
                or not str(translation["chinese_text"]).strip()
            ):
                raise ValueError(f"{episode}: invalid translation row {index}")
            rows.append(
                OldRow(
                    index=index,
                    english=str(english),
                    chinese=str(translation["chinese_text"]).strip(),
                )
            )
        result[episode] = (int(article["id"]), str(article["title"]), rows)
    return result


def main() -> int:
    args = parse_args()
    audit = json.loads(args.audit_report.read_text(encoding="utf-8"))
    if audit.get("summary", {}).get("solverVersion") != "syntax_solver_v3_6":
        raise ValueError("audit report is not syntax_solver_v3_6")
    chapters = {
        str(chapter["episode"]): chapter for chapter in audit.get("chapters", [])
    }
    expected = [f"E{number:02d}" for number in range(1, 63)]
    if sorted(chapters) != expected:
        raise ValueError("audit report does not contain exactly E01-E62")

    with connect_read_only(args.db) as connection:
        current = load_current_rows(connection, args.series_title)
    if sorted(current) != expected:
        raise ValueError("database does not contain exactly E01-E62")

    args.output_root.mkdir(parents=True, exist_ok=True)
    chapter_summaries: list[dict[str, Any]] = []
    changed_rows_all: list[dict[str, Any]] = []
    for episode in expected:
        article_id, title, old_rows = current[episode]
        raw_new_sentences = chapters[episode].get("newSentences")
        if raw_new_sentences is None:
            raw_new_sentences = chapters[episode].get("v3LocalSentences")
        if not isinstance(raw_new_sentences, list) or not raw_new_sentences:
            raise ValueError(f"{episode}: split report has no new sentences")
        new_sentences = [str(value) for value in raw_new_sentences]
        old_stream, old_spans = sentence_spans(row.english for row in old_rows)
        new_stream, new_spans = sentence_spans(new_sentences)
        if old_stream != new_stream:
            raise ValueError(f"{episode}: normalized English stream changed")

        exact_queues: dict[str, deque[OldRow]] = defaultdict(deque)
        for old_row in old_rows:
            exact_queues[normalize_whitespace(old_row.english)].append(old_row)

        rows: list[dict[str, Any]] = []
        reuse_count = 0
        changed_count = 0
        for index, english in enumerate(new_sentences):
            key = normalize_whitespace(english)
            exact = exact_queues[key].popleft() if exact_queues[key] else None
            if exact is not None:
                reuse_count += 1
                rows.append(
                    {
                        "index": index,
                        "english": english,
                        "baselineDisposition": "reuse_candidate",
                        "reviewStatus": "reused_checked",
                        "chinese": exact.chinese,
                        "exactOldIndex": exact.index,
                        "oldContext": [],
                    }
                )
                continue

            changed_count += 1
            start, end = new_spans[index]
            overlaps: list[dict[str, Any]] = []
            for old_row, (old_start, old_end) in zip(old_rows, old_spans, strict=True):
                overlap = max(0, min(end, old_end) - max(start, old_start))
                if overlap:
                    overlaps.append(
                        {
                            "index": old_row.index,
                            "english": old_row.english,
                            "chinese": old_row.chinese,
                            "overlapCharacters": overlap,
                        }
                    )
            row = {
                "index": index,
                "english": english,
                "baselineDisposition": "retranslate",
                "reviewStatus": "pending",
                "chinese": "",
                "exactOldIndex": None,
                "oldContext": overlaps,
            }
            rows.append(row)
            changed_rows_all.append({"episode": episode, **row})

        document = {
            "schemaVersion": 2,
            "episode": episode,
            "articleId": article_id,
            "title": title,
            "sentenceSplitVersion": "reviewed_dp_v3",
            "solverVersion": "syntax_solver_v3_6",
            "source": "codex_offline_story_translation_v3_6",
            "canonicalEnglishSha256": sha256_text(old_stream),
            "rows": rows,
        }
        (args.output_root / f"{episode}.review.json").write_text(
            json.dumps(document, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        chapter_summaries.append(
            {
                "episode": episode,
                "oldSentenceCount": len(old_rows),
                "newSentenceCount": len(new_sentences),
                "reuseCount": reuse_count,
                "changedSentenceCount": changed_count,
            }
        )

    totals = {
        key: sum(int(item[key]) for item in chapter_summaries)
        for key in (
            "oldSentenceCount",
            "newSentenceCount",
            "reuseCount",
            "changedSentenceCount",
        )
    }
    (args.output_root / "summary.json").write_text(
        json.dumps(
            {"schemaVersion": 2, "chapters": chapter_summaries, "totals": totals},
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    (args.output_root / "changed-rows.json").write_text(
        json.dumps(
            {
                "schemaVersion": 2,
                "rowCount": len(changed_rows_all),
                "rows": changed_rows_all,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(json.dumps({"outputRoot": str(args.output_root), **totals}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
