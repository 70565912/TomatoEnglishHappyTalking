#!/usr/bin/env python3
"""Build the checked-in Looking Glass delimiter regression fixture.

The parser report and Tomato database are opened read-only. The fixture keeps
the report's exact source characters and parser tokens while taking only the
already approved sentence boundaries from articles.sentences.
"""

from __future__ import annotations

import json
import re
import sqlite3
from pathlib import Path


ROOT = Path(r"F:\TomatoEnglishHappyTalking")
REPORT = Path(
    r"F:\英文绘本制作\爱丽丝镜中奇遇记\work\sentence-translation-v3"
    r"\raw\_tomato-tool-report\willows-v3-report.json"
)
DATABASE = (
    ROOT
    / "release"
    / "windows"
    / "tomato_english_happy_talking"
    / ".dart_tool"
    / "sqflite_common_ffi"
    / "databases"
    / "english_love.db"
)
OUTPUT = ROOT / "app" / "test" / "fixtures" / "read_aloud_splitter_v3_looking_glass_delimiters.json"

# 002 and 005 are deliberately excluded because their saved source is damaged.
TARGETS = {
    "SPLIT-LATE-001": ("E14", "must go by post"),
    "SPLIT-LATE-003": ("E16", "burning in brandy"),
    "SPLIT-LATE-004": ("E24", "no pleasing it"),
    "SPLIT-LATE-006": ("E29", "very own mouth"),
    "SPLIT-LATE-007": ("E30", "How old are you"),
    "SPLIT-LATE-008": ("E31", "smiled contemptuously"),
    "SPLIT-LATE-009": ("E32", "begin broiling things"),
    "SPLIT-LATE-010": ("E32", "a long way behind it"),
    "SPLIT-LATE-011": ("E32", "great deal of trouble"),
    "SPLIT-LATE-012": ("E33", "because..."),
    "SPLIT-LATE-013": ("E33", "gets easier further on"),
    "SPLIT-LATE-014": ("E33", "messenger for anything"),
    "SPLIT-LATE-015": ("E43", "Haddocks' Eyes"),
    "SPLIT-LATE-016": ("E44", "I give thee all"),
    "SPLIT-LATE-017-NEGATIVE": ("E52", "edge of the tureen"),
}

# Minimal windows are insufficient when the reviewed mark closes or opens a
# quote whose mate is in a nearby parser original. These ranges retain the full
# matched single-quote context without loading an entire chapter.
CONTEXT_RANGES = {
    "SPLIT-LATE-004": (6, 9),
    "SPLIT-LATE-006": (40, 43),
    "SPLIT-LATE-008": (37, 42),
    "SPLIT-LATE-009": (21, 25),
    "SPLIT-LATE-012": (15, 20),
    "SPLIT-LATE-013": (15, 20),
    "SPLIT-LATE-014": (28, 34),
    "SPLIT-LATE-015": (29, 32),
}

EXPECTED_SEGMENTS_BY_WINDOW = {
    "SPLIT-LATE-004": [
        "'It's out of temper, I think.",
        "I've pinned it here, and I've pinned it there, but there's no pleasing it!'",
        "'It can't go straight, you know, if you pin it all on one side,'",
        "Alice said, as she gently put it right for her;",
        "'and, dear me, what a state your hair is in!'",
    ],
    "SPLIT-LATE-006": [
        "'If I did fall,' he went on,",
        "'the King has promised me, ah, you may turn pale, if you like!",
        "You didn't think I was going to say that, did you?",
        "The King has promised me with his very own mouth— to—to—'",
        "'To send all his horses and all his men,' Alice interrupted, rather unwisely.",
    ],
}


def canonical(value: str) -> str:
    return re.sub(r"\s+", "", value).translate(
        str.maketrans({"‘": "'", "’": "'", "“": '"', "”": '"'})
    )


def has_balanced_single_delimiters(value: str) -> bool:
    delimiter_count = 0
    inside_double = False
    inside_single = False
    for offset, character in enumerate(value):
        before = value[offset - 1] if offset > 0 else ""
        after = value[offset + 1] if offset + 1 < len(value) else ""
        if character == '"':
            inside_double = not inside_double
            continue
        if character != "'":
            continue
        if before.isalnum() and after.isalnum():
            continue
        if (
            before.lower() == "s"
            and (not after or after.isspace())
            and (not inside_single or inside_double)
        ):
            continue
        if inside_double and before.isalnum() and (not after or after.isspace()):
            continue
        delimiter_count += 1
        inside_single = not inside_single
    return delimiter_count % 2 == 0


def database_sentences() -> dict[str, list[str]]:
    connection = sqlite3.connect(f"file:{DATABASE}?mode=ro", uri=True)
    rows = connection.execute(
        """
        SELECT a.title, a.sentences
          FROM story_chapters sc
          JOIN articles a ON a.id = sc.article_id
         WHERE sc.series_id = 33
         ORDER BY sc.chapter_order
        """
    ).fetchall()
    connection.close()
    output: dict[str, list[str]] = {}
    for title, sentences in rows:
        match = re.match(r"C(\d{2})\b", title or "")
        if match:
            output[f"E{match.group(1)}"] = [str(v) for v in json.loads(sentences)]
    return output


def matching_slots(source: str, sentences: list[str]) -> list[str]:
    wanted = canonical(source)
    for start in range(len(sentences)):
        combined = ""
        for end in range(start, len(sentences)):
            combined += canonical(sentences[end])
            if combined == wanted:
                return sentences[start : end + 1]
            if len(combined) >= len(wanted) or not wanted.startswith(combined):
                break
    raise ValueError(f"No approved DB sentence range matches: {source}")


def source_segments(source: str, approved: list[str]) -> list[str]:
    cumulative_lengths: list[int] = []
    total = 0
    for sentence in approved:
        total += len(canonical(sentence))
        cumulative_lengths.append(total)
    if total != len(canonical(source)):
        raise ValueError("Approved boundaries do not cover source")

    ends: list[int] = []
    canonical_count = 0
    target_index = 0
    for offset, character in enumerate(source, start=1):
        if not character.isspace():
            canonical_count += 1
        if canonical_count == cumulative_lengths[target_index]:
            ends.append(offset)
            target_index += 1
            if target_index == len(cumulative_lengths):
                break
    output: list[str] = []
    start = 0
    for end in ends:
        output.append(source[start:end].strip())
        start = end
        while start < len(source) and source[start].isspace():
            start += 1
    return output


def rebase_parser_sentences(
    chapter: dict, source_start: int, source_end: int
) -> list[dict]:
    selected = [
        sentence
        for sentence in chapter["parserSentences"]
        if int(sentence["start"]) >= source_start
        and int(sentence["end"]) <= source_end
    ]
    if not selected:
        raise ValueError(f"No parser sentence for {chapter['episode']} original")
    output = []
    for sentence in selected:
        output.append(
            {
                "start": int(sentence["start"]) - source_start,
                "end": int(sentence["end"]) - source_start,
                "parseCost": sentence.get("parseCost"),
                "parseCostPerToken": sentence.get("parseCostPerToken"),
                "tokens": [
                    {
                        **token,
                        "start": int(token["start"]) - source_start,
                        "end": int(token["end"]) - source_start,
                    }
                    for token in sentence["tokens"]
                ],
            }
        )
    return output


def source_window(
    chapter: dict,
    original_index: int,
    approved: list[str],
    fixed_range: tuple[int, int] | None = None,
) -> tuple[int, int, int, int, str, list[str]]:
    originals = chapter["originals"]
    if fixed_range is not None:
        ranges = [fixed_range]
    else:
        ranges = [
            (start_index, start_index + size)
            for size in range(1, 7)
            for start_index in range(
                max(0, original_index - size + 1),
                min(original_index, len(originals) - size) + 1,
            )
        ]
    for start_index, end_index in ranges:
            selected = originals[start_index:end_index]
            source_start = int(selected[0]["sourceStart"])
            source_end = int(selected[-1]["sourceEnd"])
            pieces = [str(selected[0]["original"])]
            for previous, current in zip(selected, selected[1:]):
                gap = int(current["sourceStart"]) - int(previous["sourceEnd"])
                pieces.append(" " * max(0, gap))
                pieces.append(str(current["original"]))
            source = "".join(pieces)
            try:
                slots = matching_slots(source, approved)
            except ValueError:
                continue
            if len(slots) >= 2 and has_balanced_single_delimiters(source):
                return (
                    start_index,
                    end_index,
                    source_start,
                    source_end,
                    source,
                    slots,
                )
    raise ValueError(
        f"No <=6-original window matches approved DB around "
        f"{chapter['episode']}/{original_index}"
    )


def main() -> None:
    report = json.loads(REPORT.read_text(encoding="utf-8"))
    chapters = {chapter["episode"]: chapter for chapter in report["chapters"]}
    approved_by_chapter = database_sentences()
    cases_by_original: dict[tuple[str, int, int], dict] = {}

    for window_id, (episode, needle) in TARGETS.items():
        chapter = chapters[episode]
        matches = [
            (index, original)
            for index, original in enumerate(chapter["originals"])
            if needle.lower() in original["original"].lower()
        ]
        if len(matches) != 1:
            raise ValueError(f"{window_id}: expected one original, got {len(matches)}")
        original_index, _ = matches[0]
        (
            start_index,
            end_index,
            source_start,
            source_end,
            source,
            approved,
        ) = source_window(
            chapter,
            original_index,
            approved_by_chapter[episode],
            fixed_range=CONTEXT_RANGES.get(window_id),
        )
        key = (episode, start_index, end_index)
        if key not in cases_by_original:
            cases_by_original[key] = {
                "caseId": f"LookingGlass-{episode}-{start_index}-{end_index - 1}",
                "episode": episode,
                "sourceOriginalIndexes": list(range(start_index, end_index)),
                "windowIds": [],
                "source": source,
                "expectedSegments": EXPECTED_SEGMENTS_BY_WINDOW.get(
                    window_id,
                    source_segments(source, approved),
                ),
                "parserSentences": rebase_parser_sentences(
                    chapter,
                    source_start,
                    source_end,
                ),
            }
        cases_by_original[key]["windowIds"].append(window_id)

    # Word counts are populated by the Dart test using the production counter;
    # keeping only the exact expected strings avoids a second Python tokenizer.
    output = {
        "schemaVersion": "read_aloud_splitter_v3_looking_glass_delimiters_v1",
        "parserVersion": report["summary"]["parserVersion"],
        "modelSha256": report["summary"]["modelSha256"],
        "windowCount": len(TARGETS),
        "caseCount": len(cases_by_original),
        "cases": list(cases_by_original.values()),
    }
    OUTPUT.write_text(
        json.dumps(output, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    print(f"wrote {OUTPUT}")
    print(f"windows={output['windowCount']} cases={output['caseCount']}")


if __name__ == "__main__":
    main()
