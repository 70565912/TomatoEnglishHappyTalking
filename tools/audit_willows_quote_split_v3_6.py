#!/usr/bin/env python3
"""Read-only V3.6 Willows quote/diff/audio-cache audit.

This one-time tool reads the current Release SQLite database and a previously
generated local splitter report. It never updates SQLite, calls a remote API,
or changes TTS, picture, subtitle, video, or NAS assets.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Sequence


SERIES_TITLE = "The Wind in the Willows"
EPISODE_RE = re.compile(r"\b(E\d{2})\b", re.IGNORECASE)
WORD_RE = re.compile(r"[A-Za-z0-9]+(?:['’\-][A-Za-z0-9]+)*")
WHITESPACE_RE = re.compile(r"\s+")


@dataclass(frozen=True)
class QuoteSpan:
    start: int
    end: int
    word_count: int
    text: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--source-bundle", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--series-title", default=SERIES_TITLE)
    return parser.parse_args()


def canonical(text: str) -> str:
    return WHITESPACE_RE.sub("", text)


def speech_key(text: str) -> str:
    return "\x1f".join(match.group(0) for match in WORD_RE.finditer(text))


def boundaries(sentences: Sequence[str]) -> tuple[list[int], list[tuple[int, int]]]:
    cursor = 0
    ends: list[int] = []
    ranges: list[tuple[int, int]] = []
    for sentence in sentences:
        start = cursor
        cursor += len(canonical(sentence))
        ends.append(cursor)
        ranges.append((start, cursor))
    return ends, ranges


def connect_read_only(path: Path) -> sqlite3.Connection:
    uri = path.resolve().as_uri() + "?mode=ro"
    connection = sqlite3.connect(uri, uri=True)
    connection.row_factory = sqlite3.Row
    return connection


def episode_from_title(title: str) -> str | None:
    match = EPISODE_RE.search(title)
    return match.group(1).upper() if match else None


def load_articles(
    connection: sqlite3.Connection,
    series_title: str,
) -> dict[str, sqlite3.Row]:
    rows = connection.execute(
        """
        SELECT a.id AS article_id, a.title, a.content, a.sentences,
               a.sentence_split_version
          FROM story_series ss
          JOIN story_chapters sc ON sc.series_id = ss.id
          JOIN articles a ON a.id = sc.article_id
         WHERE ss.title = ?
         ORDER BY sc.chapter_order, a.id
        """,
        (series_title,),
    ).fetchall()
    result: dict[str, sqlite3.Row] = {}
    for row in rows:
        episode = episode_from_title(str(row["title"]))
        if episode is None:
            continue
        if episode in result:
            raise ValueError(f"{episode}: duplicate article")
        result[episode] = row
    return result


def reconstruct_parser_source(chapter: dict[str, Any]) -> str:
    parser_sentences = chapter.get("parserSentences") or []
    if not parser_sentences:
        raise ValueError(f"{chapter.get('episode')}: missing parser sentences")
    length = max(int(sentence["end"]) for sentence in parser_sentences)
    source = [" "] * length
    previous_end = 0
    for sentence in parser_sentences:
        start = int(sentence["start"])
        end = int(sentence["end"])
        text = str(sentence["text"])
        if end - start != len(text):
            raise ValueError(f"{chapter.get('episode')}: parser span length mismatch")
        if start - previous_end >= 2:
            source[previous_end] = "\n"
            if previous_end + 1 < start:
                source[previous_end + 1] = "\n"
        source[start:end] = text
        previous_end = end
    return "".join(source)


def canonical_prefix(text: str) -> list[int]:
    prefix = [0]
    count = 0
    for character in text:
        if not character.isspace():
            count += 1
        prefix.append(count)
    return prefix


def quote_spans(text: str) -> tuple[list[QuoteSpan], list[dict[str, Any]]]:
    spans: list[QuoteSpan] = []
    unmatched: list[dict[str, Any]] = []
    paragraph_break = re.compile(r"(?:\r?\n)[ \t]*(?:\r?\n)+")
    paragraph_ranges: list[tuple[int, int]] = []
    paragraph_start = 0
    for match in paragraph_break.finditer(text):
        paragraph_ranges.append((paragraph_start, match.start()))
        paragraph_start = match.end()
    paragraph_ranges.append((paragraph_start, len(text)))
    straight: list[int] = []
    curly: list[int] = []
    for offset, paragraph_end in paragraph_ranges:
        paragraph = text[offset:paragraph_end]
        carried_straight = bool(straight)
        carried_curly = bool(curly)
        saw_straight = False
        saw_curly = False
        for local_index, character in enumerate(paragraph):
            absolute = offset + local_index
            if character == '"':
                opens = straight_quote_opens(
                    text,
                    absolute,
                    paragraph_start=offset,
                    paragraph_end=paragraph_end,
                    has_unclosed_quote=bool(straight),
                )
                if not saw_straight and carried_straight and opens:
                    for opening in straight:
                        unmatched.append(
                            {
                                "quoteType": "straight",
                                "start": opening,
                                "wordCountToParagraphEnd": len(
                                    WORD_RE.findall(text[opening:offset])
                                ),
                                "context": text[opening:offset][:300],
                            }
                        )
                    straight.clear()
                saw_straight = True
                if opens:
                    straight.append(absolute)
                elif straight:
                    opening = straight.pop()
                    value = text[opening : absolute + 1]
                    spans.append(
                        QuoteSpan(opening, absolute + 1, len(WORD_RE.findall(value)), value)
                    )
            elif character == "“":
                if not saw_curly and carried_curly:
                    for opening in curly:
                        unmatched.append(
                            {
                                "quoteType": "curly",
                                "start": opening,
                                "wordCountToParagraphEnd": len(
                                    WORD_RE.findall(text[opening:offset])
                                ),
                                "context": text[opening:offset][:300],
                            }
                        )
                    curly.clear()
                saw_curly = True
                curly.append(absolute)
            elif character == "”" and curly:
                saw_curly = True
                opening = curly.pop()
                value = text[opening : absolute + 1]
                spans.append(
                    QuoteSpan(opening, absolute + 1, len(WORD_RE.findall(value)), value)
                )
    for openings, quote_type in ((straight, "straight"), (curly, "curly")):
        for opening in openings:
            value = text[opening:]
            unmatched.append(
                {
                    "quoteType": quote_type,
                    "start": opening,
                    "wordCountToParagraphEnd": len(WORD_RE.findall(value)),
                    "context": value[:300],
                }
            )
    spans.sort(key=lambda value: value.start)
    return spans, unmatched


def straight_quote_opens(
    text: str,
    index: int,
    *,
    paragraph_start: int,
    paragraph_end: int,
    has_unclosed_quote: bool,
) -> bool:
    """Classify ASCII quotes without relying on fragile odd/even pairing."""
    if index <= paragraph_start:
        return True
    if index + 1 >= paragraph_end:
        return False

    previous = text[index - 1]
    following = text[index + 1]
    previous_is_space = previous.isspace()
    following_is_space = following.isspace()
    if not previous_is_space and following_is_space:
        return False
    if previous_is_space and not following_is_space:
        return True
    if following == '"':
        return False
    if previous == '"':
        return True
    if previous in "([{<:—–":
        return True
    if following in ")]}>.。,!?;—–":
        return False
    if previous in ".。,!?;":
        return False
    return not has_unclosed_quote


def chosen_path(original: dict[str, Any]) -> dict[str, Any]:
    path_id = original["localPathId"]
    for path in original["candidatePaths"]:
        if path["pathId"] == path_id:
            return path
    raise ValueError(f"missing local path {path_id}")


def selected_boundary_metadata(chapter: dict[str, Any]) -> dict[int, dict[str, Any]]:
    result: dict[int, dict[str, Any]] = {}
    cursor = 0
    originals = chapter.get("originals") or []
    for original_index, original in enumerate(originals):
        path = chosen_path(original)
        path_boundaries = list(path.get("boundaries") or [])
        segments = list(path.get("segments") or [])
        for segment_index, segment in enumerate(segments):
            cursor += len(canonical(str(segment)))
            if segment_index < len(path_boundaries):
                result[cursor] = dict(path_boundaries[segment_index])
            elif original_index + 1 < len(originals):
                result.setdefault(
                    cursor,
                    {
                        "kind": "readUnitEdge",
                        "reasons": ["ordinary_read_unit_edge"],
                        "insideQuotedSpeech": False,
                    },
                )
    return result


def changed_regions(
    old_sentences: Sequence[str],
    new_sentences: Sequence[str],
) -> list[dict[str, Any]]:
    old_ends, old_ranges = boundaries(old_sentences)
    new_ends, new_ranges = boundaries(new_sentences)
    if not old_ends or not new_ends or old_ends[-1] != new_ends[-1]:
        raise ValueError("old/new canonical source lengths differ")
    total = old_ends[-1]
    old_set = set(old_ends)
    new_set = set(new_ends)
    anchors = sorted(({0, total} | (old_set & new_set)))
    regions: list[dict[str, Any]] = []
    for start, end in zip(anchors, anchors[1:]):
        old_inside = sorted(value for value in old_set if start < value < end)
        new_inside = sorted(value for value in new_set if start < value < end)
        if old_inside == new_inside:
            continue
        old_indexes = [
            index
            for index, (item_start, item_end) in enumerate(old_ranges)
            if item_start >= start and item_end <= end
        ]
        new_indexes = [
            index
            for index, (item_start, item_end) in enumerate(new_ranges)
            if item_start >= start and item_end <= end
        ]
        regions.append(
            {
                "canonicalStart": start,
                "canonicalEnd": end,
                "oldIndexes": old_indexes,
                "newIndexes": new_indexes,
                "oldInternalBoundaries": old_inside,
                "newInternalBoundaries": new_inside,
            }
        )
    return regions


def audio_cache_for_article(
    connection: sqlite3.Connection,
    article_id: int,
) -> tuple[dict[str, list[dict[str, Any]]], dict[str, list[dict[str, Any]]]]:
    rows = connection.execute(
        """
        SELECT ace.cache_key, ace.request_json, ace.file_path, ace.byte_length,
               ace.source, ace.updated_at
          FROM api_cache_article_refs ref
          JOIN api_cache_entries ace ON ace.cache_key = ref.cache_key
         WHERE ref.article_id = ?
           AND ref.purpose IN ('listening_tts', 'follow_tts')
           AND ace.purpose IN ('listening_tts', 'follow_tts')
        """,
        (article_id,),
    ).fetchall()
    exact: dict[str, list[dict[str, Any]]] = {}
    spoken: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        try:
            request = json.loads(str(row["request_json"]))
        except json.JSONDecodeError:
            continue
        text = request.get("text")
        if not isinstance(text, str) or not text:
            continue
        path = Path(str(row["file_path"])) if row["file_path"] else None
        item = {
            "cacheKey": str(row["cache_key"]),
            "text": text,
            "filePath": str(path) if path else None,
            "fileExists": bool(path and path.is_file()),
            "fileBytes": path.stat().st_size if path and path.is_file() else 0,
            "source": str(row["source"]),
            "updatedAt": str(row["updated_at"]),
        }
        exact.setdefault(text, []).append(item)
        spoken.setdefault(speech_key(text), []).append(item)
    return exact, spoken


def cache_status(
    sentence: str,
    exact: dict[str, list[dict[str, Any]]],
    spoken: dict[str, list[dict[str, Any]]],
) -> dict[str, Any]:
    candidates = exact.get(sentence) or spoken.get(speech_key(sentence)) or []
    usable = [item for item in candidates if item["fileExists"] and item["fileBytes"] > 0]
    match = "exact" if exact.get(sentence) else "speech_sequence" if candidates else "none"
    return {
        "match": match,
        "usable": bool(usable),
        "cacheKeys": [item["cacheKey"] for item in usable],
        "files": [item["filePath"] for item in usable],
        "sources": sorted({item["source"] for item in usable}),
    }


def quote_audit(
    source: str,
    old_boundaries: set[int],
    new_boundaries: set[int],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    prefix = canonical_prefix(source)
    lexical_positions = [
        index for index, character in enumerate(source) if not character.isspace()
    ]
    raw_end_by_canonical = [0] + [index + 1 for index in lexical_positions]
    spans, unmatched = quote_spans(source)
    result: list[dict[str, Any]] = []
    for index, span in enumerate(spans):
        start = prefix[span.start]
        end = prefix[span.end]
        old_internal = sorted(
            value
            for value in old_boundaries
            if span.start < raw_end_by_canonical[value] < span.end - 1
        )
        new_internal = sorted(
            value
            for value in new_boundaries
            if span.start < raw_end_by_canonical[value] < span.end - 1
        )
        if not old_internal and not new_internal:
            continue
        result.append(
            {
                "quoteIndex": index,
                "wordCount": span.word_count,
                "canonicalStart": start,
                "canonicalEnd": end,
                "text": span.text,
                "oldInternalBoundaries": old_internal,
                "newInternalBoundaries": new_internal,
                "shortQuoteViolationAfterV36": span.word_count <= 16 and bool(new_internal),
            }
        )
    return result, unmatched


def compact_context(sentences: Sequence[str], indexes: Sequence[int]) -> str:
    if not indexes:
        return ""
    start = max(0, indexes[0] - 1)
    end = min(len(sentences), indexes[-1] + 2)
    return " | ".join(sentences[start:end])


def markdown_table_cell(value: Any) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ")


def main() -> int:
    args = parse_args()
    report = json.loads(args.report.read_text(encoding="utf-8"))
    source_bundle = json.loads(args.source_bundle.read_text(encoding="utf-8"))
    bundled_sources = {
        str(item["episode"]): str(item["source"])
        for item in source_bundle.get("chapters") or []
    }
    summary = report.get("summary") or {}
    if summary.get("solverVersion") != "syntax_solver_v3_6":
        raise ValueError("report is not syntax_solver_v3_6")
    if summary.get("nativeCalls") != 0:
        raise ValueError("report did not reuse the parsed cache")
    chapters = {item["episode"]: item for item in report.get("chapters") or []}
    connection = connect_read_only(args.db)
    try:
        articles = load_articles(connection, args.series_title)
        expected = [f"E{index:02d}" for index in range(1, 63)]
        if sorted(chapters) != expected or sorted(articles) != expected:
            raise ValueError("report/database chapter coverage is not E01-E62")

        chapter_results: list[dict[str, Any]] = []
        total_old = 0
        total_new = 0
        total_regions = 0
        changed_chapters = 0
        total_reusable = 0
        total_speech_sequence = 0
        total_tts_characters = 0
        total_short_quote_violations = 0
        total_matched_quote_rows = 0
        unmatched_quotes: list[dict[str, Any]] = []

        for episode in expected:
            chapter = chapters[episode]
            article = articles[episode]
            old_sentences_raw = json.loads(str(article["sentences"]))
            old_sentences = [str(value) for value in old_sentences_raw]
            new_sentences = [str(value) for value in chapter["v3LocalSentences"]]
            old_canonical = canonical("".join(old_sentences))
            new_canonical = canonical("".join(new_sentences))
            if old_canonical != new_canonical:
                raise ValueError(f"{episode}: normalized old/new source differs")

            old_ends, _ = boundaries(old_sentences)
            new_ends, _ = boundaries(new_sentences)
            selected_metadata = selected_boundary_metadata(chapter)
            regions = changed_regions(old_sentences, new_sentences)
            source = bundled_sources.get(episode) or reconstruct_parser_source(chapter)
            if canonical(source) != new_canonical:
                raise ValueError(f"{episode}: reconstructed parser source differs")
            quotes, unmatched = quote_audit(source, set(old_ends), set(new_ends))
            for item in unmatched:
                unmatched_quotes.append({"episode": episode, **item})
            total_short_quote_violations += sum(
                1 for item in quotes if item["shortQuoteViolationAfterV36"]
            )
            total_matched_quote_rows += len(quotes)

            exact, spoken = audio_cache_for_article(
                connection, int(article["article_id"])
            )
            new_audio = [cache_status(sentence, exact, spoken) for sentence in new_sentences]
            reusable = sum(1 for status in new_audio if status["usable"])
            speech_sequence = sum(
                1
                for status in new_audio
                if status["usable"] and status["match"] == "speech_sequence"
            )
            tts_characters = sum(
                len(sentence)
                for sentence, status in zip(new_sentences, new_audio)
                if not status["usable"]
            )

            for region_index, region in enumerate(regions, start=1):
                region["regionIndex"] = region_index
                region["oldSentences"] = [
                    old_sentences[index] for index in region["oldIndexes"]
                ]
                region["newSentences"] = [
                    new_sentences[index] for index in region["newIndexes"]
                ]
                region["context"] = compact_context(
                    old_sentences, region["oldIndexes"]
                )
                region["oldAudio"] = [
                    cache_status(old_sentences[index], exact, spoken)
                    for index in region["oldIndexes"]
                ]
                region["newAudio"] = [new_audio[index] for index in region["newIndexes"]]
                region["newCutTypes"] = [
                    {
                        "canonicalOffset": offset,
                        **selected_metadata.get(
                            offset,
                            {
                                "kind": "unknown",
                                "reasons": ["boundary_metadata_not_found"],
                            },
                        ),
                    }
                    for offset in region["newInternalBoundaries"]
                ]
                region["quoteSpans"] = [
                    item
                    for item in quotes
                    if item["canonicalStart"] < region["canonicalEnd"]
                    and item["canonicalEnd"] > region["canonicalStart"]
                ]

            total_old += len(old_sentences)
            total_new += len(new_sentences)
            total_regions += len(regions)
            changed_chapters += int(bool(regions))
            total_reusable += reusable
            total_speech_sequence += speech_sequence
            total_tts_characters += tts_characters
            chapter_results.append(
                {
                    "episode": episode,
                    "articleId": int(article["article_id"]),
                    "title": str(article["title"]),
                    "splitVersion": str(article["sentence_split_version"]),
                    "oldSentenceCount": len(old_sentences),
                    "newSentenceCount": len(new_sentences),
                    "changedRegionCount": len(regions),
                    "matchedQuotesWithBoundaries": quotes,
                    "unmatchedQuotes": unmatched,
                    "newAudioReusableCount": reusable,
                    "newAudioSpeechSequenceReuseCount": speech_sequence,
                    "newAudioSynthesisCount": len(new_sentences) - reusable,
                    "newAudioSynthesisCharacters": tts_characters,
                    "regions": regions,
                }
            )

        output_summary = {
            "generatedAt": dt.datetime.now(dt.timezone.utc)
            .isoformat()
            .replace("+00:00", "Z"),
            "mode": "read_only",
            "solverVersion": summary["solverVersion"],
            "parserVersion": summary["parserVersion"],
            "modelSha256": summary["modelSha256"],
            "combinedSourceSha256": summary["combinedSourceSha256"],
            "nativeCalls": summary["nativeCalls"],
            "chapterCount": len(chapter_results),
            "changedChapterCount": changed_chapters,
            "oldSentenceCount": total_old,
            "newSentenceCount": total_new,
            "changedRegionCount": total_regions,
            "matchedQuoteRowsWithAnyBoundary": total_matched_quote_rows,
            "shortQuoteInternalSelectedCount": total_short_quote_violations,
            "unmatchedQuoteCount": len(unmatched_quotes),
            "newAudioReusableCount": total_reusable,
            "newAudioSpeechSequenceReuseCount": total_speech_sequence,
            "newAudioSynthesisCount": total_new - total_reusable,
            "newAudioSynthesisCharacters": total_tts_characters,
            "translationStatus": "not_started_waiting_for_english_review",
            "pictureMappingStatus": "not_started_waiting_for_english_review",
            "databaseMigrated": False,
            "paidApiCalls": 0,
        }
        args.output_root.mkdir(parents=True, exist_ok=True)
        result = {
            "schemaVersion": "willows_quote_split_audit_v3_6",
            "summary": output_summary,
            "unmatchedQuotes": unmatched_quotes,
            "chapters": chapter_results,
        }
        json_path = args.output_root / "willows-v3-6-quote-diff-audit.json"
        json_path.write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

        markdown = [
            "# 《柳林风声》V3.6 引语分句人工审核清单",
            "",
            f"- 章节：{output_summary['chapterCount']}（变化 {changed_chapters} 章）",
            f"- 句槽：{total_old} -> {total_new}",
            f"- 最小变化区间：{total_regions}",
            f"- 短引语内部已选切点：{total_short_quote_violations}",
            f"- UDPipe 原生调用：{summary['nativeCalls']}",
            f"- 新句音频可复用：{total_reusable}/{total_new}",
            f"- 其中仅标点/空格词序复用：{total_speech_sequence}",
            f"- 暂估待重新合成：{total_new - total_reusable} 句 / {total_tts_characters} 字符",
            "- 翻译、组图映射、数据库、TTS、视频和网盘均未修改。",
            "",
            "## 逐项变化",
            "",
            "| 章节/区间 | 旧句槽 | 新句槽 | 新切点类型 | 引语 | 音频 |",
            "|---|---|---|---|---|---|",
        ]
        for chapter in chapter_results:
            for region in chapter["regions"]:
                cut_types = ", ".join(
                    str(item.get("quoteEdge") or item.get("kind"))
                    for item in region["newCutTypes"]
                ) or "无内部切点"
                quote_info = "; ".join(
                    f"{item['wordCount']}词:{item['text'][:80]}"
                    for item in region["quoteSpans"]
                ) or "-"
                reusable = sum(1 for item in region["newAudio"] if item["usable"])
                markdown.append(
                    "| "
                    + markdown_table_cell(
                        f"{chapter['episode']} #{region['regionIndex']}"
                    )
                    + " | "
                    + markdown_table_cell(" / ".join(region["oldSentences"]))
                    + " | "
                    + markdown_table_cell(" / ".join(region["newSentences"]))
                    + " | "
                    + markdown_table_cell(cut_types)
                    + " | "
                    + markdown_table_cell(quote_info)
                    + " | "
                    + f"{reusable}/{len(region['newAudio'])} 可复用 |"
                )
        markdown_path = args.output_root / "README.md"
        markdown_path.write_text("\n".join(markdown) + "\n", encoding="utf-8")
        print(
            json.dumps(
                {
                    "json": str(json_path.resolve()),
                    "markdown": str(markdown_path.resolve()),
                    **output_summary,
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0
    finally:
        connection.close()


if __name__ == "__main__":
    raise SystemExit(main())
