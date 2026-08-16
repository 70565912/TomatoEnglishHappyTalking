#!/usr/bin/env python3
"""Require exact whole-book equivalence with the pre-refactor V3.7 solver."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from verify_read_aloud_behavior_baseline import (
    canonical,
    load_object,
    sentence_boundaries,
    sha256_text,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--oracle",
        type=Path,
        default=Path("app/test/fixtures/read_aloud_splitter_v3_solver_oracle.json"),
    )
    parser.add_argument(
        "--report",
        action="append",
        required=True,
        metavar="BOOK=PATH",
    )
    parser.add_argument("--json-output", type=Path)
    return parser.parse_args()


def matched_parenthetical_spans(source: str) -> list[tuple[int, int]]:
    stack: list[int] = []
    spans: list[tuple[int, int]] = []
    for index, character in enumerate(source):
        if character == "(":
            stack.append(index)
        elif character == ")" and stack:
            spans.append((stack.pop(), index + 1))
    return spans


def boundary_is_inside_matched_parenthetical(source: str, offset: int) -> bool:
    for start, end in matched_parenthetical_spans(source):
        # The parenthetical repair owns the two attachment edges as well as
        # punctuation lexically attached to the closing parenthesis. It must
        # not consume any following word: `(aside); | but ...` is in scope,
        # while `(aside) could not make | out ...` is not.
        attached_end = end
        while attached_end < len(source) and source[attached_end] in ",;:.!?\"'”’":
            attached_end += 1
        if start <= offset <= attached_end:
            return True
    return False


def chapter_map(chapters: Any, *, label: str) -> dict[str, dict[str, Any]]:
    if not isinstance(chapters, list):
        raise ValueError(f"Missing chapters list: {label}")
    result: dict[str, dict[str, Any]] = {}
    for value in chapters:
        if not isinstance(value, dict):
            raise ValueError(f"Invalid chapter: {label}")
        episode = str(value.get("episode") or "").upper()
        if not episode or episode in result:
            raise ValueError(f"Missing or duplicate episode {episode!r}: {label}")
        result[episode] = value
    return result


def verify_scope(
    oracle: dict[str, Any], reports: dict[str, dict[str, Any]]
) -> dict[str, Any]:
    if oracle.get("schemaVersion") != "read_aloud_solver_oracle_v1":
        raise ValueError("Unsupported solver oracle schema")
    raw_books = oracle.get("books")
    if not isinstance(raw_books, list):
        raise ValueError("Oracle has no books list")
    expected_books = {
        str(value.get("book") or "").casefold(): value
        for value in raw_books
        if isinstance(value, dict)
    }
    missing_books = sorted(set(expected_books) - set(reports))
    extra_books = sorted(set(reports) - set(expected_books))
    book_results: list[dict[str, Any]] = []
    for key in sorted(set(expected_books) & set(reports)):
        book = str(expected_books[key].get("book") or key)
        expected_chapters = chapter_map(
            expected_books[key].get("chapters"), label=f"oracle:{book}"
        )
        actual_chapters = chapter_map(
            reports[key].get("chapters"), label=f"report:{book}"
        )
        differences: list[dict[str, Any]] = []
        for episode in sorted(set(expected_chapters) & set(actual_chapters)):
            expected = expected_chapters[episode]
            actual = actual_chapters[episode]
            expected_sentences = [str(value) for value in expected.get("sentences") or []]
            actual_sentences = [str(value) for value in actual.get("v3LocalSentences") or []]
            expected_source, expected_boundaries = sentence_boundaries(expected_sentences)
            actual_source, actual_boundaries = sentence_boundaries(actual_sentences)
            source_matches = (
                expected_source == actual_source
                and str(expected.get("canonicalSourceSha256") or "")
                == sha256_text(expected_source)
            )
            if source_matches and expected_sentences == actual_sentences:
                continue
            removed = sorted(set(expected_boundaries) - set(actual_boundaries))
            added = sorted(set(actual_boundaries) - set(expected_boundaries))
            changed = [*removed, *added]
            outside = (
                [
                    offset
                    for offset in changed
                    if not boundary_is_inside_matched_parenthetical(
                        expected_source, offset
                    )
                ]
                if source_matches
                else changed
            )
            if not changed and expected_sentences != actual_sentences:
                outside = [-1]
            differences.append(
                {
                    "episode": episode,
                    "sourceMatches": source_matches,
                    "expectedSentenceCount": len(expected_sentences),
                    "actualSentenceCount": len(actual_sentences),
                    "removedBoundaryOffsets": removed,
                    "addedBoundaryOffsets": added,
                    "outsideParentheticalBoundaryOffsets": outside,
                }
            )
        missing_episodes = sorted(set(expected_chapters) - set(actual_chapters))
        extra_episodes = sorted(set(actual_chapters) - set(expected_chapters))
        outside_count = sum(
            bool(value["outsideParentheticalBoundaryOffsets"])
            or not value["sourceMatches"]
            for value in differences
        )
        book_results.append(
            {
                "book": book,
                "expectedChapterCount": len(expected_chapters),
                "actualChapterCount": len(actual_chapters),
                "missingEpisodes": missing_episodes,
                "extraEpisodes": extra_episodes,
                "differentChapterCount": len(differences),
                "parentheticalOnlyDifferentChapterCount": len(differences)
                - outside_count,
                "outsideParentheticalDifferentChapterCount": outside_count,
                "differences": differences,
            }
        )
    passed = not missing_books and not extra_books and all(
        not book["missingEpisodes"]
        and not book["extraEpisodes"]
        and book["differentChapterCount"] == 0
        for book in book_results
    )
    return {
        "passed": passed,
        "policy": "pre_refactor_v3_7_exact_equivalence",
        "missingBooks": missing_books,
        "extraBooks": extra_books,
        "books": book_results,
    }


def main() -> int:
    args = parse_args()
    reports: dict[str, dict[str, Any]] = {}
    for value in args.report:
        if "=" not in value:
            raise ValueError(f"Expected BOOK=PATH, got {value!r}")
        book, path = value.split("=", 1)
        key = book.casefold()
        if not key or key in reports:
            raise ValueError(f"Missing or duplicate report book: {book!r}")
        reports[key] = load_object(Path(path))
    result = verify_scope(load_object(args.oracle), reports)
    payload = json.dumps(result, ensure_ascii=False, indent=2)
    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(payload + "\n", encoding="utf-8")
    print(payload)
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"refactor scope verification error: {error}", file=sys.stderr)
        raise SystemExit(2)
