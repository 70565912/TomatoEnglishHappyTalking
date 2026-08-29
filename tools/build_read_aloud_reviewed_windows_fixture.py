"""Build the self-contained V2 fixture for the 55 reviewed split windows.

This is an offline test-data builder. Case ids and book labels must never be
read by production splitter code. The source parser tokens are copied from the
already-frozen V1 fixture; UDPipe is not called.
"""

from __future__ import annotations

import argparse
import copy
import json
import re
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "app/test/fixtures/read_aloud_splitter_v3_reviewed_windows.json"
SNAPSHOTS = {
    "Alice": ROOT
    / "output/sentence-split-v3/refactor-v3-8-validation/alice-v37-snapshot-full.json",
    "Willows": ROOT
    / "output/sentence-split-v3/refactor-v3-8-validation/willows-v37-snapshot-full.json",
}

TARGET_SPLITS = {
    "Willows-E01-25": (2, " snug"),
    "Willows-E06-23": (1, " and the joys"),
    "Willows-E10-1": (1, " and so intimately"),
    "Willows-E29-6": (0, " in the smartest suit"),
    "Willows-E30-5": (1, " he pulled"),
    "Willows-E33-7": (0, " and pushed"),
    "Willows-E40-25": (2, " before those horrid machines"),
    "Willows-E48-6": (2, " over the stern"),
}

EXPECTED_COUNTS = {
    "Alice-E38-32": [13, 11, 11, 8, 13, 4],
    "Willows-E01-25": [11, 15, 9, 18, 9],
    "Willows-E06-23": [10, 7, 14, 11],
    "Willows-E10-1": [9, 10, 13, 16],
    "Willows-E29-6": [9, 12, 15, 9, 17, 16, 15],
    "Willows-E30-5": [14, 5, 16, 6, 14],
    "Willows-E33-7": [4, 17, 17, 5],
    "Willows-E40-25": [10, 12, 15, 9, 13, 11, 16, 7, 7],
    "Willows-E48-6": [6, 11, 13, 9, 13],
}


def word_count(text: str) -> int:
    # Mirrors source-word semantics closely enough for frozen fixtures: ASCII
    # hyphens/apostrophes stay inside a lexical word, while punctuation and
    # glued quote-close/speaker text form real word boundaries.
    return len(re.findall(r"[^\W_]+(?:[-'’][^\W_]+)*", text, re.UNICODE))


def split_segment(segments: list[str], index: int, right_prefix: str) -> list[str]:
    segment = segments[index]
    offset = segment.index(right_prefix)
    return [
        *segments[:index],
        segment[:offset].rstrip(),
        segment[offset:].lstrip(),
        *segments[index + 1 :],
    ]


def segment_ranges(source: str, segments: list[str]) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    cursor = 0
    for segment in segments:
        start = source.find(segment, cursor)
        if start < 0:
            raise ValueError(f"segment not found after {cursor}: {segment!r}")
        end = start + len(segment)
        ranges.append((start, end))
        cursor = end
    return ranges


def shift_parser_for_insert(
    sentences: list[dict[str, Any]], insert_at: int
) -> list[dict[str, Any]]:
    shifted = copy.deepcopy(sentences)
    for sentence in shifted:
        if sentence["start"] >= insert_at:
            sentence["start"] += 1
        if sentence["end"] > insert_at:
            sentence["end"] += 1
        for token in sentence["tokens"]:
            if token["start"] >= insert_at:
                token["start"] += 1
            if token["end"] > insert_at:
                token["end"] += 1
    return shifted


def make_review_unit(
    *,
    window_id: str,
    segments: list[str],
    boundary_index: int,
    source_scope: str,
) -> dict[str, Any]:
    local_segments = segments[boundary_index : boundary_index + 2]
    return {
        "windowId": window_id,
        "sourceScope": source_scope,
        "targetAfterWord": sum(
            word_count(value) for value in segments[: boundary_index + 1]
        ),
        "expectedSegments": local_segments,
        "expectedWordCounts": [word_count(value) for value in local_segments],
    }


def closest_boundary_indexes(
    *,
    case_start: int,
    ranges: list[tuple[int, int]],
    window_ranges: list[dict[str, int]],
    forced_index: int | None,
) -> list[int]:
    boundary_offsets = [case_start + end for _, end in ranges[:-1]]
    selected: list[int] = []
    for window_index, window in enumerate(window_ranges):
        if forced_index is not None and window_index == 0:
            selected.append(forced_index)
            continue
        center = (window["start"] + window["end"]) / 2

        def rank(index: int) -> tuple[int, float, int]:
            offset = boundary_offsets[index]
            in_window = window["start"] <= offset <= window["end"]
            return (
                1 if index in selected else 0,
                0 if in_window else abs(offset - center),
                index,
            )

        selected.append(min(range(len(boundary_offsets)), key=rank))
    return selected


def load_chapter_sources() -> dict[tuple[str, str], str]:
    output: dict[tuple[str, str], str] = {}
    for book, path in SNAPSHOTS.items():
        payload = json.loads(path.read_text(encoding="utf-8"))
        for chapter in payload["chapters"]:
            output[(book, chapter["episode"])] = chapter["source"]
    return output


def build(payload: dict[str, Any]) -> dict[str, Any]:
    chapter_sources = load_chapter_sources()
    payload["schemaVersion"] = "read_aloud_splitter_v3_reviewed_windows_v2"
    payload["reviewUnitCount"] = payload["windowCount"]
    payload["supportPolicy"] = {
        "fullCase": "same_dag_normal_coverage",
        "reviewUnit": "materialized_candidate_path",
        "normalMaxWords": 20,
        "maxExpandedCandidatePaths": 24,
    }

    review_unit_count = 0
    for case in payload["cases"]:
        case_id = case["caseId"]
        original_segments = list(
            case.get("expectedSegments", case.get("damagedReferenceSegments", []))
        )

        if case_id == "Alice-E38-32":
            malformed_source = case["source"]
            needle = '!"she'
            insert_at = malformed_source.index(needle) + 2
            repaired_source = malformed_source[:insert_at] + " " + malformed_source[insert_at:]
            repaired_parser = shift_parser_for_insert(case["parserSentences"], insert_at)
            repaired_segments = list(original_segments)
            repaired_segments[0] = repaired_segments[0].replace('!"she', '!" she')
            repaired_segments = split_segment(repaired_segments, 3, " that they")
            counts = [word_count(value) for value in repaired_segments]
            if counts != EXPECTED_COUNTS[case_id]:
                raise ValueError(f"{case_id} counts {counts}")
            case["reviewStatus"] = "source_damage_negative"
            case["damagedReferenceSegments"] = original_segments
            if "damagedReferenceWordCounts" not in case:
                case["damagedReferenceWordCounts"] = case["expectedWordCounts"]
            case.pop("expectedSegments", None)
            case.pop("expectedWordCounts", None)
            case["repairedFixture"] = {
                "source": repaired_source,
                "expectedSegments": repaired_segments,
                "expectedWordCounts": counts,
                "parserSentences": repaired_parser,
            }
            boundary_index = 3
            case["reviewUnits"] = [
                make_review_unit(
                    window_id=case["windowIds"][0],
                    segments=repaired_segments,
                    boundary_index=boundary_index,
                    source_scope="repairedFixture",
                )
            ]
            review_unit_count += 1
            continue

        segments = original_segments
        forced_index = None
        if case_id in TARGET_SPLITS:
            index, prefix = TARGET_SPLITS[case_id]
            normalized_prefix = prefix.strip()
            already_split = (
                index + 1 < len(segments)
                and segments[index + 1].startswith(normalized_prefix)
            )
            if not already_split:
                segments = split_segment(segments, index, prefix)
            forced_index = index
            counts = [word_count(value) for value in segments]
            if counts != EXPECTED_COUNTS[case_id]:
                raise ValueError(f"{case_id} counts {counts}")
        case["expectedSegments"] = segments
        case["expectedWordCounts"] = [word_count(value) for value in segments]

        case["reviewStatus"] = "approved"
        chapter_source = chapter_sources[(case["book"], case["episode"])]
        starts = [
            match.start()
            for match in re.finditer(re.escape(case["source"]), chapter_source)
        ]
        if len(starts) != 1:
            raise ValueError(f"{case_id} source occurrences: {starts}")
        ranges = segment_ranges(case["source"], segments)
        boundary_indexes = closest_boundary_indexes(
            case_start=starts[0],
            ranges=ranges,
            window_ranges=case["windowRanges"],
            forced_index=forced_index,
        )
        case["reviewUnits"] = [
            make_review_unit(
                window_id=window_id,
                segments=segments,
                boundary_index=boundary_index,
                source_scope="parentCase",
            )
            for window_id, boundary_index in zip(case["windowIds"], boundary_indexes)
        ]
        review_unit_count += len(case["reviewUnits"])

    if review_unit_count != payload["windowCount"]:
        raise ValueError(
            f"review unit count {review_unit_count} != {payload['windowCount']}"
        )
    return payload


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    original_text = FIXTURE.read_text(encoding="utf-8")
    payload = build(json.loads(original_text))
    generated = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"
    if args.check:
        if generated != original_text:
            raise SystemExit("reviewed-window fixture is not up to date")
        return
    FIXTURE.write_text(generated, encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
