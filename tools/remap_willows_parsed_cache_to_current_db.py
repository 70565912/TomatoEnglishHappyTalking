#!/usr/bin/env python3
"""Remap a cached Willows UDPipe report onto current persisted English text.

The operation is read-only for SQLite and never invokes UDPipe or a remote API.
Only source deletions are accepted; insertions/replacements stop the tool.
Outputs are an audit-only parser cache and a current-DB source bundle.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import re
import sqlite3
from pathlib import Path
from typing import Any


SERIES_TITLE = "The Wind in the Willows"
EPISODE_RE = re.compile(r"\b(E\d{2})\b", re.IGNORECASE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True, type=Path)
    parser.add_argument("--parsed-report", required=True, type=Path)
    parser.add_argument("--output-report", required=True, type=Path)
    parser.add_argument("--output-bundle", required=True, type=Path)
    parser.add_argument("--series-title", default=SERIES_TITLE)
    return parser.parse_args()


def connect_read_only(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    return connection


def canonical(text: str) -> str:
    return "".join(character for character in text if not character.isspace())


def canonical_prefix(text: str) -> list[int]:
    result = [0]
    count = 0
    for character in text:
        if not character.isspace():
            count += 1
        result.append(count)
    return result


def raw_boundaries_by_canonical(text: str) -> tuple[list[int], list[int]]:
    raw_positions = [index for index, value in enumerate(text) if not value.isspace()]
    starts = raw_positions + [len(text)]
    ends = [0] + [index + 1 for index in raw_positions]
    return starts, ends


def reconstruct_source(chapter: dict[str, Any]) -> str:
    sentences = chapter["parserSentences"]
    length = max(int(sentence["end"]) for sentence in sentences)
    source = [" "] * length
    for sentence in sentences:
        start = int(sentence["start"])
        end = int(sentence["end"])
        text = str(sentence["text"])
        if end - start != len(text):
            raise ValueError(f"{chapter['episode']}: parser span length mismatch")
        source[start:end] = text
    return "".join(source)


def load_articles(
    connection: sqlite3.Connection,
    series_title: str,
) -> dict[str, dict[str, Any]]:
    rows = connection.execute(
        """
        SELECT a.id, a.title, a.sentences, a.sentence_split_version
          FROM story_series ss
          JOIN story_chapters sc ON sc.series_id = ss.id
          JOIN articles a ON a.id = sc.article_id
         WHERE ss.title = ?
         ORDER BY sc.chapter_order, a.id
        """,
        (series_title,),
    ).fetchall()
    result: dict[str, dict[str, Any]] = {}
    for row in rows:
        match = EPISODE_RE.search(str(row["title"]))
        if match is None:
            continue
        episode = match.group(1).upper()
        sentences = [str(value) for value in json.loads(str(row["sentences"]))]
        result[episode] = {
            "articleId": int(row["id"]),
            "title": str(row["title"]),
            "splitVersion": str(row["sentence_split_version"]),
            "sentences": sentences,
            "source": " ".join(sentences),
        }
    return result


def deletion_boundary_map(old: str, new: str, episode: str) -> tuple[list[int], list[dict[str, Any]]]:
    matcher = difflib.SequenceMatcher(None, old, new, autojunk=False)
    mapping: list[int | None] = [None] * (len(old) + 1)
    deletions: list[dict[str, Any]] = []
    for tag, old_start, old_end, new_start, new_end in matcher.get_opcodes():
        if tag == "equal":
            for offset in range(old_start, old_end + 1):
                mapping[offset] = new_start + (offset - old_start)
        elif tag == "delete":
            for offset in range(old_start, old_end + 1):
                mapping[offset] = new_start
            deleted = old[old_start:old_end]
            deletions.append(
                {
                    "episode": episode,
                    "oldCanonicalStart": old_start,
                    "oldCanonicalEnd": old_end,
                    "characters": len(deleted),
                    "text": deleted,
                    "sha256": hashlib.sha256(deleted.encode("utf-8")).hexdigest(),
                }
            )
        else:
            raise ValueError(
                f"{episode}: parser cache remap permits deletions only; found {tag} "
                f"old={old[old_start:old_end]!r} new={new[new_start:new_end]!r}"
            )
    last = 0
    result: list[int] = []
    for index, value in enumerate(mapping):
        if value is None:
            value = last
        if value < last:
            raise ValueError(f"{episode}: non-monotonic mapping at {index}")
        result.append(value)
        last = value
    return result, deletions


def remap_chapter(
    chapter: dict[str, Any],
    target: dict[str, Any],
) -> tuple[dict[str, Any], list[dict[str, Any]], str]:
    episode = str(chapter["episode"])
    old_source = reconstruct_source(chapter)
    old_canonical = canonical(old_source)
    new_canonical = canonical(str(target["source"]))
    boundary_map, deletions = deletion_boundary_map(
        old_canonical, new_canonical, episode
    )
    deleted_offsets = {
        offset
        for deletion in deletions
        for offset in range(
            int(deletion["oldCanonicalStart"]),
            int(deletion["oldCanonicalEnd"]),
        )
    }
    canonical_offset = 0
    retained: list[str] = []
    for character in old_source:
        if character.isspace():
            retained.append(character)
            continue
        if canonical_offset not in deleted_offsets:
            retained.append(character)
        canonical_offset += 1
    new_source = "".join(retained)
    if canonical(new_source) != new_canonical:
        raise ValueError(f"{episode}: paragraph-preserving remap changed source")
    old_prefix = canonical_prefix(old_source)
    target_raw_starts, target_raw_ends = raw_boundaries_by_canonical(new_source)

    def map_raw_boundary(old_raw_offset: int, *, is_end: bool = False) -> int:
        old_offset = old_prefix[old_raw_offset]
        new_offset = boundary_map[old_offset]
        return (target_raw_ends if is_end else target_raw_starts)[new_offset]

    remapped_sentences: list[dict[str, Any]] = []
    for sentence in chapter["parserSentences"]:
        sentence_start = map_raw_boundary(int(sentence["start"]))
        sentence_end = map_raw_boundary(int(sentence["end"]), is_end=True)
        if sentence_end <= sentence_start:
            continue
        old_tokens = [dict(token) for token in sentence["tokens"]]
        surviving: list[tuple[dict[str, Any], int, int]] = []
        for token in old_tokens:
            start = map_raw_boundary(int(token["start"]))
            end = map_raw_boundary(int(token["end"]), is_end=True)
            if end <= start:
                continue
            surviving.append((token, start, end))
        if not surviving:
            continue

        surviving_ids = {int(token["id"]) for token, _, _ in surviving}
        by_id = {int(token["id"]): token for token in old_tokens}

        def surviving_head(token: dict[str, Any]) -> int:
            head = int(token["head"])
            visited: set[int] = set()
            while head != 0 and head not in surviving_ids:
                if head in visited or head not in by_id:
                    return 0
                visited.add(head)
                head = int(by_id[head]["head"])
            return head

        next_id = {
            int(token["id"]): index
            for index, (token, _, _) in enumerate(surviving, start=1)
        }
        tokens: list[dict[str, Any]] = []
        for token, start, end in surviving:
            head = surviving_head(token)
            tokens.append(
                {
                    "id": next_id[int(token["id"])],
                    "text": str(token["text"]),
                    "sourceText": new_source[start:end],
                    "start": start,
                    "end": end,
                    "upos": str(token["upos"]),
                    "head": 0 if head == 0 else next_id[head],
                    "deprel": str(token["deprel"]),
                }
            )

        start = min(sentence_start, tokens[0]["start"])
        end = max(sentence_end, tokens[-1]["end"])
        while start < end and new_source[start].isspace():
            start += 1
        while end > start and new_source[end - 1].isspace():
            end -= 1
        remapped_sentences.append(
            {
                "start": start,
                "end": end,
                "text": new_source[start:end],
                "parseCost": sentence.get("parseCost"),
                "parseCostPerToken": sentence.get("parseCostPerToken"),
                "tokens": tokens,
            }
        )

    cursor = 0
    for index, sentence in enumerate(remapped_sentences):
        if sentence["start"] < cursor:
            raise ValueError(f"{episode}: remapped parser sentences overlap at {index}")
        if new_source[cursor : sentence["start"]].strip():
            raise ValueError(f"{episode}: parser source gap before sentence {index}")
        cursor = int(sentence["end"])
    if new_source[cursor:].strip():
        raise ValueError(f"{episode}: parser source gap after final sentence")

    return (
        {
            "episode": episode,
            "sourcePath": "current_release_db_source_bundle",
            "parserSentences": remapped_sentences,
        },
        deletions,
        new_source,
    )


def main() -> int:
    args = parse_args()
    parsed = json.loads(args.parsed_report.read_text(encoding="utf-8"))
    connection = connect_read_only(args.db)
    try:
        articles = load_articles(connection, args.series_title)
    finally:
        connection.close()
    expected = [f"E{index:02d}" for index in range(1, 63)]
    parsed_chapters = {item["episode"]: item for item in parsed["chapters"]}
    if sorted(articles) != expected or sorted(parsed_chapters) != expected:
        raise ValueError("database/parser report coverage is not E01-E62")

    output_chapters: list[dict[str, Any]] = []
    deletions: list[dict[str, Any]] = []
    bundle_chapters: list[dict[str, Any]] = []
    combined: list[str] = []
    for episode in expected:
        remapped, chapter_deletions, current_source = remap_chapter(
            parsed_chapters[episode], articles[episode]
        )
        output_chapters.append(remapped)
        deletions.extend(chapter_deletions)
        bundle_chapters.append(
            {"episode": episode, **articles[episode], "source": current_source}
        )
        combined.append(current_source)

    combined_source = "\n\n".join(combined)
    summary = {
        "sentenceSplitVersion": "read_aloud_dp_v3",
        "reviewedVersion": "reviewed_dp_v3",
        "solverVersion": "syntax_solver_v3_6_cache_input",
        "parserVersion": parsed["summary"]["parserVersion"],
        "modelSha256": parsed["summary"]["modelSha256"],
        "combinedSourceSha256": hashlib.sha256(
            combined_source.encode("utf-8")
        ).hexdigest(),
        "nativeCalls": 0,
        "chapterCount": 62,
        "sourceCharacterCount": len(combined_source),
        "confirmedCurrentDbSourceDeletions": deletions,
    }
    args.output_report.parent.mkdir(parents=True, exist_ok=True)
    args.output_bundle.parent.mkdir(parents=True, exist_ok=True)
    args.output_report.write_text(
        json.dumps(
            {
                "schemaVersion": "willows_current_db_parsed_cache_v3_6",
                "summary": summary,
                "chapters": output_chapters,
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )
        + "\n",
        encoding="utf-8",
    )
    args.output_bundle.write_text(
        json.dumps(
            {
                "schemaVersion": "willows_current_db_source_bundle_v1",
                "summary": summary,
                "chapters": bundle_chapters,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(
        json.dumps(
            {
                "outputReport": str(args.output_report.resolve()),
                "outputBundle": str(args.output_bundle.resolve()),
                "combinedSourceSha256": summary["combinedSourceSha256"],
                "nativeCalls": 0,
                "deletions": deletions,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
