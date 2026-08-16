#!/usr/bin/env python3
"""Classify reviewed V3.7 -> current V3.7 candidate boundary changes.

The audit is intentionally fail-closed: every changed boundary must be adjacent
to a one-word chunk, inside/on a matched paragraph-local parenthetical span, or
identified as the one-for-one replacement of a selected incomplete boundary,
or a safe newly-added boundary that splits an old >20-word block toward the
comfort range. A diagnostic elsewhere in the same repair window never licenses
companion changes. Any unclassified change exits non-zero. The script reads
reports only and never touches SQLite or media assets.
"""

from __future__ import annotations

import argparse
import collections
import copy
import json
import re
import sys
from pathlib import Path
from typing import Any, Sequence


SPACE_RE = re.compile(r"\s+")
WORD_RE = re.compile(r"[^\W_]+(?:['’\-][^\W_]+)*", re.UNICODE)
PARAGRAPH_BREAK_RE = re.compile(r"(?:\r?\n)[ \t]*(?:\r?\n)+")
INLINE_PAUSES = frozenset(";:—–,")
COMFORT_CONTINUATION_WARNINGS = frozenset(
    {
        "surface_nominal_coordinator_separation",
        "surface_nominal_relative_pronoun_separation",
    }
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument(
        "--candidate",
        required=True,
        action="append",
        type=Path,
        help="V3.7 report; repeat for parallel corpus groups",
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--baseline-constrained-output",
        type=Path,
        help=(
            "Optional review report that overlays only approved atomic changes "
            "onto the reviewed V3.7 baseline. Never writes the database/media."
        ),
    )
    return parser.parse_args()


def canonical(text: str) -> str:
    return SPACE_RE.sub("", text)


def load_report(path: Path) -> dict[str, Any]:
    decoded = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(decoded, dict) or not isinstance(decoded.get("chapters"), list):
        raise ValueError(f"Invalid splitter report: {path}")
    return decoded


def chapter_map(report: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        str(chapter["episode"]).upper(): chapter
        for chapter in report["chapters"]
        if isinstance(chapter, dict) and chapter.get("episode")
    }


def sentence_boundaries(sentences: Sequence[str]) -> tuple[set[int], list[int]]:
    offsets: set[int] = set()
    counts: list[int] = []
    cursor = 0
    for index, sentence in enumerate(sentences):
        counts.append(len(WORD_RE.findall(sentence)))
        cursor += len(canonical(sentence))
        if index + 1 < len(sentences):
            offsets.add(cursor)
    return offsets, counts


def sentence_spans(sentences: Sequence[str]) -> set[tuple[int, int]]:
    spans: set[tuple[int, int]] = set()
    cursor = 0
    for sentence in sentences:
        end = cursor + len(canonical(sentence))
        spans.add((cursor, end))
        cursor = end
    return spans


def sentences_from_canonical_offsets(source: str, offsets: set[int]) -> list[str]:
    """Split source without changing characters, using whitespace-free offsets."""

    ordered = sorted(offsets)
    if not ordered:
        return [source.strip()] if source.strip() else []
    result: list[str] = []
    start = 0
    canonical_cursor = 0
    boundary_index = 0
    for index, char in enumerate(source):
        if not char.isspace():
            canonical_cursor += 1
        while (
            boundary_index < len(ordered)
            and canonical_cursor == ordered[boundary_index]
        ):
            end = index + 1
            chunk = source[start:end].strip()
            if not chunk:
                raise ValueError(f"Empty gated chunk at {ordered[boundary_index]}")
            result.append(chunk)
            start = end
            boundary_index += 1
    if boundary_index != len(ordered):
        raise ValueError(
            f"Cannot map gated offsets {ordered[boundary_index:]} into source"
        )
    tail = source[start:].strip()
    if tail:
        result.append(tail)
    return result


def singleton_adjacent_offsets(sentences: Sequence[str]) -> set[int]:
    offsets, counts = sentence_boundaries(sentences)
    ordered = sorted(offsets)
    return {
        offset
        for index, offset in enumerate(ordered)
        if counts[index] == 1 or counts[index + 1] == 1
    }


def source_word_ends(text: str) -> list[int]:
    """Mirror Dart `_sourceWords` closely enough to map candidate afterWord."""

    ends: list[int] = []
    pending_punctuation_start: int | None = None

    def append_part(start: int, end: int) -> None:
        nonlocal pending_punctuation_start
        if start >= end:
            return
        part = text[start:end]
        if WORD_RE.search(part):
            pending_punctuation_start = None
            ends.append(end)
        elif ends:
            ends[-1] = end
        elif pending_punctuation_start is None:
            pending_punctuation_start = start

    for match in re.finditer(r"\S+", text):
        token = match.group(0)
        part_start = 0
        for offset in range(len(token) - 1):
            punctuation = token[offset]
            remainder = token[offset + 1 :]
            starts_lexical = re.match(r'''^["'“‘(\[]*[^\W_]''', remainder)
            if punctuation not in INLINE_PAUSES or not starts_lexical:
                continue
            previous = token[offset - 1] if offset > 0 else ""
            following = token[offset + 1]
            if (
                punctuation in {",", ":"}
                and previous.isdigit()
                and following.isdigit()
            ):
                continue
            append_part(match.start() + part_start, match.start() + offset + 1)
            part_start = offset + 1
        append_part(match.start() + part_start, match.end())
    return ends


def matched_parenthetical_ranges_in_text(
    text: str, canonical_start: int
) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []

    def scan(start: int, end: int) -> None:
        openings: list[int] = []
        for offset in range(start, end):
            if text[offset] == "(":
                openings.append(offset)
            elif text[offset] == ")" and openings:
                opening = openings.pop()
                edge_end = offset + 1
                while edge_end < end and (
                    text[edge_end].isspace()
                    or text[edge_end] in ";:—–,.!?\"'”’"
                ):
                    edge_end += 1
                ranges.append(
                    (
                        canonical_start + len(canonical(text[:opening])),
                        canonical_start + len(canonical(text[:edge_end])),
                    )
                )

    paragraph_start = 0
    for match in PARAGRAPH_BREAK_RE.finditer(text):
        scan(paragraph_start, match.start())
        paragraph_start = match.end()
    scan(paragraph_start, len(text))
    return ranges


def original_locations(
    chapter: dict[str, Any], source: str
) -> list[tuple[dict[str, Any], str, int]]:
    result: list[tuple[dict[str, Any], str, int]] = []
    canonical_source = canonical(source)
    cursor = 0
    for original in chapter.get("originals") or []:
        if not isinstance(original, dict):
            continue
        original_text = str(original.get("original") or "")
        original_canonical = canonical(original_text)
        original_start = canonical_source.find(original_canonical, cursor)
        if original_start < 0:
            raise ValueError(
                f"{chapter.get('episode')}: cannot locate audited original"
            )
        result.append((original, original_text, original_start))
        cursor = original_start + len(original_canonical)
    return result


def matched_parenthetical_ranges(
    chapter: dict[str, Any], source: str
) -> list[tuple[int, int]]:
    return [
        parenthetical
        for _, original_text, original_start in original_locations(chapter, source)
        for parenthetical in matched_parenthetical_ranges_in_text(
            original_text, original_start
        )
    ]


def incomplete_boundary_offsets(chapter: dict[str, Any], source: str) -> set[int]:
    result: set[int] = set()
    for original, original_text, original_start in original_locations(chapter, source):
        word_ends = source_word_ends(original_text)
        for candidate in original.get("boundaryCandidates") or []:
            if not isinstance(candidate, dict):
                continue
            reasons = candidate.get("reasons") or []
            if "incomplete_constituent_boundary" not in reasons:
                continue
            after_word = int(candidate.get("afterWord") or 0)
            if after_word <= 0 or after_word > len(word_ends):
                continue
            local_end = len(canonical(original_text[: word_ends[after_word - 1]]))
            result.add(original_start + local_end)
    return result


def coordinated_quote_edge_offsets(
    chapter: dict[str, Any], source: str
) -> set[int]:
    """Map product-tagged quote/coordinator boundaries into chapter offsets."""

    result: set[int] = set()
    for original, original_text, original_start in original_locations(chapter, source):
        word_ends = source_word_ends(original_text)
        for candidate in original.get("boundaryCandidates") or []:
            if not isinstance(candidate, dict):
                continue
            reasons = candidate.get("reasons") or []
            if "quote_edge_coordinated_continuation" not in reasons:
                continue
            after_word = int(candidate.get("afterWord") or 0)
            if after_word <= 0 or after_word > len(word_ends):
                continue
            local_end = len(canonical(original_text[: word_ends[after_word - 1]]))
            result.add(original_start + local_end)
    return result


def comfort_split_offsets(
    chapter: dict[str, Any],
    source: str,
    old_sentences: Sequence[str],
    new_sentences: Sequence[str],
) -> set[int]:
    """Return safe candidate offsets that split a reviewed >20-word block.

    This is deliberately narrower than "any new boundary": the candidate must
    be selectable, must not be diagnosed incomplete, must be newly selected
    inside a reviewed V3.7 block over 20 words, and both resulting candidate
    blocks must land at 20 words or below.
    """

    old_offsets, old_counts = sentence_boundaries(old_sentences)
    new_offsets, new_counts = sentence_boundaries(new_sentences)
    old_edges = [0, *sorted(old_offsets), len(canonical(source))]
    new_offset_indexes = {
        offset: index for index, offset in enumerate(sorted(new_offsets))
    }
    eligible: set[int] = set()
    for original, original_text, original_start in original_locations(chapter, source):
        word_ends = source_word_ends(original_text)
        for candidate in original.get("boundaryCandidates") or []:
            if not isinstance(candidate, dict) or candidate.get("hardBlocked"):
                continue
            reasons = set(candidate.get("reasons") or [])
            warnings = set(candidate.get("softWarnings") or [])
            if "incomplete_constituent_boundary" in reasons:
                continue
            # For a non-punctuation comfort split, the right side must expose
            # a syntactically explicit continuation (for example `and ...` or
            # `that ...`). A generic dependency candidate is not sufficient:
            # it can still be `Lay it where | Childhood's dreams ...`.
            if (
                candidate.get("kind")
                not in {
                    "strongPunctuation",
                    "clauseComma",
                    "phraseComma",
                }
                and not warnings.intersection(COMFORT_CONTINUATION_WARNINGS)
            ):
                continue
            after_word = int(candidate.get("afterWord") or 0)
            if after_word <= 0 or after_word > len(word_ends):
                continue
            local_end = len(canonical(original_text[: word_ends[after_word - 1]]))
            offset = original_start + local_end
            new_index = new_offset_indexes.get(offset)
            if new_index is None:
                continue
            if new_counts[new_index] > 20 or new_counts[new_index + 1] > 20:
                continue
            old_index = next(
                (
                    index
                    for index in range(len(old_counts))
                    if old_edges[index] < offset < old_edges[index + 1]
                ),
                None,
            )
            if old_index is not None and old_counts[old_index] > 20:
                eligible.add(offset)

    # A comfort split is a pure insertion into one reviewed sentence block.
    # If the candidate also removes or moves another boundary at either edge
    # or inside that block, accepting only the insertion would synthesize a
    # path that neither the reviewed baseline nor the candidate selected.
    changed = old_offsets ^ new_offsets
    result: set[int] = set()
    for offset in eligible:
        old_index = next(
            index
            for index in range(len(old_counts))
            if old_edges[index] < offset < old_edges[index + 1]
        )
        block_start = old_edges[old_index]
        block_end = old_edges[old_index + 1]
        block_changes = {
            value for value in changed if block_start <= value <= block_end
        }
        if block_changes == {offset}:
            result.add(offset)
    return result


def direct_incomplete_repair_offsets(
    incomplete_offsets: set[int],
    old_offsets: set[int],
    new_offsets: set[int],
    source_length: int,
) -> set[int]:
    """Return only unambiguous one-for-one incomplete-boundary repairs.

    The reviewed V3.7 boundary must itself be diagnosed incomplete. Between
    the nearest unchanged anchors, that single removed boundary must be
    replaced by exactly one new non-incomplete boundary. A 2-for-1, 1-for-2,
    or whole-window rerank is intentionally left unexpected for manual review.
    """

    removed = old_offsets - new_offsets
    added = new_offsets - old_offsets
    stable = sorted({0, source_length} | (old_offsets & new_offsets))
    result: set[int] = set()
    for incomplete in sorted(removed & incomplete_offsets):
        start = max(value for value in stable if value < incomplete)
        end = min(value for value in stable if value > incomplete)
        window_removed = {offset for offset in removed if start < offset < end}
        window_added = {offset for offset in added if start < offset < end}
        if window_removed != {incomplete} or len(window_added) != 1:
            continue
        replacement = next(iter(window_added))
        if replacement in incomplete_offsets:
            continue
        result.update({incomplete, replacement})
    return result


def anchored_change_ranges(
    anchors: Sequence[tuple[int, int]],
    old_offsets: set[int],
    new_offsets: set[int],
    source_length: int,
) -> list[tuple[int, int]]:
    """Bound a structural change by its nearest unchanged sentence edges."""

    changed = old_offsets ^ new_offsets
    stable = sorted({0, source_length} | (old_offsets & new_offsets))
    result: list[tuple[int, int]] = []
    for anchor_start, anchor_end in anchors:
        if not any(anchor_start <= offset <= anchor_end for offset in changed):
            continue
        start = max(value for value in stable if value <= anchor_start)
        end = min(value for value in stable if value >= anchor_end)
        result.append((start, end))
    return result


def classify_chapter(
    baseline: dict[str, Any], candidate: dict[str, Any]
) -> dict[str, Any]:
    old_sentences = [str(value) for value in baseline.get("v3LocalSentences") or []]
    new_sentences = [str(value) for value in candidate.get("v3LocalSentences") or []]
    old_source = " ".join(old_sentences)
    new_source = " ".join(new_sentences)
    if canonical(old_source) != canonical(new_source):
        raise ValueError(f"{candidate.get('episode')}: source round-trip changed")

    old_offsets, _ = sentence_boundaries(old_sentences)
    new_offsets, new_counts = sentence_boundaries(new_sentences)
    changed = sorted(old_offsets ^ new_offsets)
    one_word_offsets = singleton_adjacent_offsets(old_sentences)
    one_word_offsets.update(singleton_adjacent_offsets(new_sentences))
    paren_ranges = matched_parenthetical_ranges(candidate, new_source)
    incomplete_offsets = incomplete_boundary_offsets(candidate, new_source)
    direct_incomplete_offsets = direct_incomplete_repair_offsets(
        incomplete_offsets,
        old_offsets,
        new_offsets,
        len(canonical(new_source)),
    )
    coordinated_quote_offsets = coordinated_quote_edge_offsets(
        candidate, new_source
    )
    comfort_offsets = comfort_split_offsets(
        candidate,
        new_source,
        old_sentences,
        new_sentences,
    )
    classified: list[dict[str, Any]] = []
    unexpected: list[int] = []
    for offset in changed:
        if offset in one_word_offsets:
            reason = "one_word_local_merge"
        elif offset in direct_incomplete_offsets:
            reason = "incomplete_constituent"
        elif offset in coordinated_quote_offsets:
            reason = "coordinated_quote_edge"
        elif offset in comfort_offsets:
            reason = "over_20_comfort_split"
        else:
            reason = "unexpected"
            unexpected.append(offset)
        classified.append({"canonicalOffset": offset, "reason": reason})

    # Fail closed per boundary, not per chapter. Approved target changes keep
    # the candidate state; every unexpected add/remove restores the reviewed
    # V3.7 state. This projection is for review and impact counting only: the
    # overall report still fails while any unexpected change exists.
    gated_offsets = set(old_offsets)
    for change in classified:
        offset = int(change["canonicalOffset"])
        if change["reason"] == "unexpected":
            continue
        if offset in new_offsets:
            gated_offsets.add(offset)
        else:
            gated_offsets.discard(offset)
    gated_sentences = sentences_from_canonical_offsets(new_source, gated_offsets)
    gated_offsets_check, gated_counts = sentence_boundaries(gated_sentences)
    if gated_offsets_check != gated_offsets:
        raise ValueError(f"{candidate.get('episode')}: gated offsets changed")
    if any(count > 30 for count in gated_counts) or (
        len(gated_counts) > 1 and any(count == 1 for count in gated_counts)
    ):
        raise ValueError(
            f"{candidate.get('episode')}: gated invariant failed "
            f"counts={gated_counts}"
        )
    conservative_tts_sentence_count = len(
        sentence_spans(gated_sentences) - sentence_spans(old_sentences)
    )

    oversized = [count for count in new_counts if count > 30]
    singletons = [count for count in new_counts if count == 1]
    if oversized or (len(new_counts) > 1 and singletons):
        raise ValueError(
            f"{candidate.get('episode')}: final invariant failed "
            f"oversized={oversized} singletons={singletons}"
        )
    return {
        "episode": str(candidate.get("episode") or ""),
        "oldSentenceCount": len(old_sentences),
        "newSentenceCount": len(new_sentences),
        "changedBoundaryCount": len(changed),
        "changes": classified,
        "unexpectedOffsets": unexpected,
        "gatedSentences": gated_sentences,
        "gatedChangedBoundaryCount": len(old_offsets ^ gated_offsets),
        "conservativeTtsSentenceCount": conservative_tts_sentence_count,
        "candidateRejected": bool(unexpected),
    }


def main() -> int:
    args = parse_args()
    baseline_report = load_report(args.baseline)
    baseline_version = (baseline_report.get("summary") or {}).get(
        "solverVersion"
    )
    if baseline_version != "syntax_solver_v3_7":
        raise ValueError(
            "Impact baseline must be a reviewed syntax_solver_v3_7 report; "
            f"got {baseline_version!r}"
        )
    baseline = chapter_map(baseline_report)
    candidate_reports = [load_report(path) for path in args.candidate]
    candidate_versions = {
        (report.get("summary") or {}).get("solverVersion")
        for report in candidate_reports
    }
    if candidate_versions != {"syntax_solver_v3_7"}:
        raise ValueError(
            "Every impact candidate must be a syntax_solver_v3_7 report; "
            f"got {sorted(str(value) for value in candidate_versions)}"
        )
    candidate: dict[str, dict[str, Any]] = {}
    for report in candidate_reports:
        for episode, chapter in chapter_map(report).items():
            if episode in candidate:
                raise ValueError(f"Duplicate candidate chapter: {episode}")
            candidate[episode] = chapter
    if baseline.keys() != candidate.keys():
        raise ValueError(
            "Chapter sets differ: "
            f"baseline={sorted(baseline)} candidate={sorted(candidate)}"
        )
    chapters = [
        classify_chapter(baseline[episode], candidate[episode])
        for episode in sorted(candidate)
    ]
    unexpected = sum(len(chapter["unexpectedOffsets"]) for chapter in chapters)
    change_reasons = collections.Counter(
        change["reason"]
        for chapter in chapters
        for change in chapter["changes"]
    )
    output = {
        "schemaVersion": "sentence_split_v3_7_impact_audit_v3",
        "baselineSolverVersion": baseline_version,
        "candidateSolverVersion": sorted(candidate_versions),
        "chapterCount": len(chapters),
        "changedChapterCount": sum(
            chapter["changedBoundaryCount"] > 0 for chapter in chapters
        ),
        "changedBoundaryCount": sum(
            chapter["changedBoundaryCount"] for chapter in chapters
        ),
        "changeReasonCounts": dict(sorted(change_reasons.items())),
        "unexpectedBoundaryCount": unexpected,
        "passed": unexpected == 0,
        "migrationAllowed": unexpected == 0,
        "gatedSentenceCount": sum(
            len(chapter["gatedSentences"]) for chapter in chapters
        ),
        "gatedChangedBoundaryCount": sum(
            chapter["gatedChangedBoundaryCount"] for chapter in chapters
        ),
        "conservativeTtsSentenceCount": sum(
            chapter["conservativeTtsSentenceCount"] for chapter in chapters
        ),
        "rejectedCandidateChapterCount": sum(
            chapter["candidateRejected"] for chapter in chapters
        ),
        "chapters": chapters,
    }
    encoded = json.dumps(output, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    if args.baseline_constrained_output:
        constrained = copy.deepcopy(baseline_report)
        classified_by_episode = {
            chapter["episode"]: chapter for chapter in chapters
        }
        candidate_by_episode = candidate
        constrained_chapters: list[dict[str, Any]] = []
        for baseline_chapter in constrained["chapters"]:
            episode = str(baseline_chapter.get("episode") or "").upper()
            classified_chapter = classified_by_episode[episode]
            candidate_chapter = copy.deepcopy(candidate_by_episode[episode])
            gated = classified_chapter["gatedSentences"]
            candidate_chapter["v3LocalSentences"] = gated
            candidate_chapter["v3SentenceCount"] = len(gated)
            candidate_chapter["baselineConstrained"] = True
            candidate_chapter["rawCandidateRejected"] = classified_chapter[
                "candidateRejected"
            ]
            candidate_chapter["approvedChangedBoundaryCount"] = (
                classified_chapter["gatedChangedBoundaryCount"]
            )
            constrained_chapters.append(candidate_chapter)
        constrained["schemaVersion"] = (
            "sentence_split_v3_7_baseline_constrained_review_v1"
        )
        constrained["chapters"] = constrained_chapters
        constrained_summary = constrained.setdefault("summary", {})
        constrained_summary["baselineConstrained"] = True
        constrained_summary["reviewRequired"] = True
        constrained_summary["migrationAllowed"] = False
        constrained_summary["rawUnexpectedBoundaryCount"] = unexpected
        constrained_summary["approvedChangedBoundaryCount"] = output[
            "gatedChangedBoundaryCount"
        ]
        constrained_summary["conservativeTtsSentenceCount"] = output[
            "conservativeTtsSentenceCount"
        ]
        constrained_summary["v3SentenceCount"] = sum(
            len(chapter["v3LocalSentences"])
            for chapter in constrained_chapters
        )
        constrained_encoded = (
            json.dumps(constrained, ensure_ascii=False, indent=2) + "\n"
        )
        args.baseline_constrained_output.parent.mkdir(
            parents=True, exist_ok=True
        )
        args.baseline_constrained_output.write_text(
            constrained_encoded, encoding="utf-8"
        )
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    print(encoded, end="")
    return 0 if unexpected == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
