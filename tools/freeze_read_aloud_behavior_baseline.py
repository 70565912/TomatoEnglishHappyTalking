#!/usr/bin/env python3
"""Freeze compact sentence-slot goldens from reviewed whole-book reports."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Any


SPACE_RE = re.compile(r"\s+")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--report",
        action="append",
        required=True,
        metavar="BOOK=PATH",
        help="Reviewed splitter report. Repeat for each book.",
    )
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def canonical(text: str) -> str:
    return SPACE_RE.sub("", text)


def load(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or not isinstance(value.get("chapters"), list):
        raise ValueError(f"Invalid splitter report: {path}")
    return value


def main() -> int:
    args = parse_args()
    books: list[dict[str, Any]] = []
    for value in args.report:
        if "=" not in value:
            raise ValueError(f"Expected BOOK=PATH, got {value!r}")
        book, raw_path = value.split("=", 1)
        path = Path(raw_path)
        report = load(path)
        summary = report.get("summary") or {}
        chapters = []
        for chapter in report["chapters"]:
            episode = str(chapter.get("episode") or "").upper()
            sentences = [str(item) for item in chapter.get("v3LocalSentences") or []]
            joined = "".join(canonical(item) for item in sentences)
            boundaries: list[int] = []
            offset = 0
            for sentence in sentences:
                offset += len(canonical(sentence))
                boundaries.append(offset)
            chapters.append(
                {
                    "episode": episode,
                    "canonicalSourceSha256": hashlib.sha256(
                        joined.encode("utf-8")
                    ).hexdigest(),
                    "sentenceCount": len(sentences),
                    "boundaryCanonicalOffsets": boundaries,
                    "sentences": sentences,
                }
            )
        books.append(
            {
                "book": book,
                "sourceReport": path.as_posix(),
                "solverVersion": summary.get("solverVersion"),
                "parserVersion": summary.get("parserVersion"),
                "modelSha256": summary.get("modelSha256"),
                "chapterCount": len(chapters),
                "sentenceCount": sum(item["sentenceCount"] for item in chapters),
                "chapters": chapters,
            }
        )
    output = {
        "schemaVersion": "read_aloud_published_behavior_v1",
        "policy": (
            "Behavior-preserving refactors must match every boundary. "
            "Only explicitly reviewed parenthetical defects may update this file."
        ),
        "books": books,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(output, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        json.dumps(
            {
                "output": str(args.output.resolve()),
                "books": len(books),
                "chapters": sum(book["chapterCount"] for book in books),
                "sentences": sum(book["sentenceCount"] for book in books),
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
