#!/usr/bin/env python3
"""Fail when regenerated splitter reports drift from published sentence slots."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


SPACE_RE = re.compile(r"\s+")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--fixture",
        type=Path,
        default=Path("app/test/fixtures/read_aloud_splitter_v3_published_behavior.json"),
    )
    parser.add_argument(
        "--report",
        action="append",
        required=True,
        metavar="BOOK=PATH",
        help="Regenerated whole-book report. Repeat for each book.",
    )
    parser.add_argument("--json-output", type=Path)
    return parser.parse_args()


def canonical(text: str) -> str:
    return SPACE_RE.sub("", text)


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def load_object(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"Expected a JSON object: {path}")
    return value


def sentence_boundaries(sentences: list[str]) -> tuple[str, list[int]]:
    pieces = [canonical(sentence) for sentence in sentences]
    source = "".join(pieces)
    boundaries: list[int] = []
    offset = 0
    for piece in pieces:
        offset += len(piece)
        boundaries.append(offset)
    return source, boundaries


def boundary_is_inside_parenthetical(source: str, offset: int) -> bool:
    """Return whether a canonical boundary falls strictly inside paired parens."""
    depth = 0
    for index, character in enumerate(source):
        if character == "(":
            depth += 1
        elif character == ")" and depth > 0:
            depth -= 1
        if index + 1 == offset:
            return depth > 0
        if index + 1 > offset:
            break
    return False


def _chapter_map(chapters: Any, *, source: str) -> dict[str, dict[str, Any]]:
    if not isinstance(chapters, list):
        raise ValueError(f"Missing chapters list: {source}")
    output: dict[str, dict[str, Any]] = {}
    for raw in chapters:
        if not isinstance(raw, dict):
            raise ValueError(f"Invalid chapter object: {source}")
        episode = str(raw.get("episode") or "").upper()
        if not episode or episode in output:
            raise ValueError(f"Missing or duplicate episode {episode!r}: {source}")
        output[episode] = raw
    return output


def compare_book(
    *,
    book: str,
    expected_book: dict[str, Any],
    report: dict[str, Any],
) -> dict[str, Any]:
    expected_chapters = _chapter_map(
        expected_book.get("chapters"), source=f"fixture:{book}"
    )
    actual_chapters = _chapter_map(report.get("chapters"), source=f"report:{book}")
    missing = sorted(set(expected_chapters) - set(actual_chapters))
    extra = sorted(set(actual_chapters) - set(expected_chapters))
    differences: list[dict[str, Any]] = []

    for episode in sorted(set(expected_chapters) & set(actual_chapters)):
        expected = expected_chapters[episode]
        actual = actual_chapters[episode]
        expected_sentences = [str(value) for value in expected.get("sentences") or []]
        actual_sentences = [str(value) for value in actual.get("v3LocalSentences") or []]
        expected_source, expected_boundaries = sentence_boundaries(expected_sentences)
        actual_source, actual_boundaries = sentence_boundaries(actual_sentences)
        expected_hash = str(expected.get("canonicalSourceSha256") or "")

        source_matches = (
            expected_hash == sha256_text(expected_source)
            and expected_source == actual_source
        )
        if source_matches and expected_sentences == actual_sentences:
            continue

        removed = sorted(set(expected_boundaries) - set(actual_boundaries))
        added = sorted(set(actual_boundaries) - set(expected_boundaries))
        outside = [
            offset
            for offset in [*removed, *added]
            if not boundary_is_inside_parenthetical(expected_source, offset)
        ] if source_matches else []
        differences.append(
            {
                "episode": episode,
                "sourceMatches": source_matches,
                "expectedSentenceCount": len(expected_sentences),
                "actualSentenceCount": len(actual_sentences),
                "removedBoundaryOffsets": removed,
                "addedBoundaryOffsets": added,
                "outsideParentheticalBoundaryOffsets": outside,
                "sentenceTextMatches": expected_sentences == actual_sentences,
            }
        )

    return {
        "book": book,
        "expectedChapterCount": len(expected_chapters),
        "actualChapterCount": len(actual_chapters),
        "missingEpisodes": missing,
        "extraEpisodes": extra,
        "differentChapterCount": len(differences),
        "outsideParentheticalDifferentChapterCount": sum(
            bool(item["outsideParentheticalBoundaryOffsets"])
            or not item["sourceMatches"]
            or (
                not item["sentenceTextMatches"]
                and not item["removedBoundaryOffsets"]
                and not item["addedBoundaryOffsets"]
            )
            for item in differences
        ),
        "differences": differences,
    }


def verify(
    fixture: dict[str, Any], reports: dict[str, dict[str, Any]]
) -> dict[str, Any]:
    if fixture.get("schemaVersion") != "read_aloud_published_behavior_v1":
        raise ValueError("Unsupported published behavior fixture schema")
    raw_books = fixture.get("books")
    if not isinstance(raw_books, list):
        raise ValueError("Fixture has no books list")
    expected_books = {
        str(value.get("book") or "").casefold(): value
        for value in raw_books
        if isinstance(value, dict)
    }
    missing_books = sorted(set(expected_books) - set(reports))
    extra_books = sorted(set(reports) - set(expected_books))
    books = [
        compare_book(
            book=str(expected_books[key].get("book") or key),
            expected_book=expected_books[key],
            report=reports[key],
        )
        for key in sorted(set(expected_books) & set(reports))
    ]
    passed = not missing_books and not extra_books and all(
        not item["missingEpisodes"]
        and not item["extraEpisodes"]
        and item["differentChapterCount"] == 0
        for item in books
    )
    return {
        "passed": passed,
        "policy": "exact_published_behavior_only",
        "missingBooks": missing_books,
        "extraBooks": extra_books,
        "books": books,
    }


def main() -> int:
    args = parse_args()
    reports: dict[str, dict[str, Any]] = {}
    for raw in args.report:
        if "=" not in raw:
            raise ValueError(f"Expected BOOK=PATH, got {raw!r}")
        book, raw_path = raw.split("=", 1)
        key = book.casefold()
        if not key or key in reports:
            raise ValueError(f"Missing or duplicate report book: {book!r}")
        reports[key] = load_object(Path(raw_path))
    result = verify(load_object(args.fixture), reports)
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
        print(f"behavior baseline verification error: {error}", file=sys.stderr)
        raise SystemExit(2)
