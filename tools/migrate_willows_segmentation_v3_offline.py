#!/usr/bin/env python3
"""One-time, offline Willows sentence/translation/image-range migration.

This tool deliberately lives outside the Flutter application.  It never calls
AI, TTS, ASR, image, or Bridge APIs.  Dry-run is the default; --apply requires a
complete validated review set, makes an SQLite backup, and then updates the
book in one transaction.
"""

from __future__ import annotations

import argparse
import datetime as dt
import difflib
import hashlib
import json
import re
import shutil
import sqlite3
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Sequence


REVIEW_SOURCE = "codex_offline_story_translation_v3_6"
REVIEW_SCHEMA_VERSION = 2
SPLIT_VERSION = "reviewed_dp_v3"
SOLVER_VERSION = "syntax_solver_v3_6"
SERIES_TITLE = "The Wind in the Willows"
EPISODE_RE = re.compile(r"\b(E\d{2})\b", re.IGNORECASE)
WORD_RE = re.compile(r"[A-Za-z]+(?:['’\-][A-Za-z]+)*")
WHITESPACE_RE = re.compile(r"\s+")
FORBIDDEN_TRANSLATED_NAMES_RE = re.compile(r"鼹鼠|河鼠|水鼠|海鼠|蛤蟆|蟾蜍|獾先生")
CONFIRMED_SOURCE_DELETIONS: dict[str, dict[str, int | str]] = {
    "E35": {
        # The current Release DB was produced by an older splitter that had
        # already discarded some surrounding quote punctuation.  This is the
        # exact canonical duplicate remaining in that DB.  The corresponding
        # 150-character source selection was independently verified against
        # the book and hashes to the value retained below for audit evidence.
        "characters": 123,
        "sha256": "925dd69fb53059ff5c7ed6000ec4c44f2b82f655f9fcf1c896713775a40b351f",
        "sourceSelectionCharacters": 150,
        "sourceSelectionSha256": "344100f6d6bfd790c9baeb0899e7f5dcd30db03479d9a0c42c416d37db5bf66e",
    },
    "E61": {
        "characters": 373,
        "sha256": "ab82fd9bdb0f325fce6d00fb4a0846301f7e64ee0188fc3b82a619430bfd91e7",
    },
}


@dataclass(frozen=True)
class ReviewRow:
    index: int
    english: str
    chinese: str
    status: str


@dataclass(frozen=True)
class ReviewChapter:
    episode: str
    rows: tuple[ReviewRow, ...]
    canonical_hash: str

    @property
    def sentences(self) -> list[str]:
        return [row.english for row in self.rows]


@dataclass(frozen=True)
class ArticleSnapshot:
    article_id: int
    title: str
    content: str
    sentences: tuple[str, ...]
    split_version: str
    chapter_id: int
    summary_json: str
    pages: tuple[sqlite3.Row, ...]
    translations: tuple[sqlite3.Row, ...]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, help="Path to english_love.db")
    parser.add_argument("--review-root", type=Path, help="Directory containing final/E01.json ... E62.json")
    parser.add_argument("--series-title", default=SERIES_TITLE)
    parser.add_argument("--episodes", default="", help="Comma-separated E01,E02 subset; omitted means all 62")
    parser.add_argument("--output-root", type=Path, help="Migration logs and backup directory")
    parser.add_argument("--apply", action="store_true", help="Apply after validation; default is read-only dry-run")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def compact_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def canonical(text: str) -> str:
    """Ignore whitespace only; punctuation and all lexical characters remain."""
    return WHITESPACE_RE.sub("", text)


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def sentences_hash(sentences: Sequence[str]) -> str:
    return sha256_text(compact_json(list(sentences)))


def episode_from_title(title: str) -> str | None:
    match = EPISODE_RE.search(title)
    return match.group(1).upper() if match else None


def parse_episode_filter(raw: str) -> set[str]:
    episodes = {value.strip().upper() for value in raw.split(",") if value.strip()}
    invalid = sorted(value for value in episodes if not re.fullmatch(r"E\d{2}", value))
    if invalid:
        raise ValueError(f"Invalid episode values: {', '.join(invalid)}")
    return episodes


def load_review(path: Path, expected_episode: str) -> ReviewChapter:
    document = json.loads(path.read_text(encoding="utf-8"))
    if (
        document.get("schemaVersion") != REVIEW_SCHEMA_VERSION
        or document.get("episode") != expected_episode
        or document.get("sentenceSplitVersion") != SPLIT_VERSION
        or document.get("solverVersion") != SOLVER_VERSION
        or document.get("source") != REVIEW_SOURCE
        or not isinstance(document.get("rows"), list)
        or not document["rows"]
    ):
        raise ValueError(f"{expected_episode}: invalid final review header")
    rows: list[ReviewRow] = []
    for index, raw in enumerate(document["rows"]):
        english = raw.get("english")
        chinese = raw.get("chinese")
        status = raw.get("reviewStatus")
        if (
            raw.get("index") != index
            or not isinstance(english, str)
            or not english.strip()
            or not isinstance(chinese, str)
            or not chinese.strip()
            or status not in {"reused_checked", "retranslated"}
        ):
            raise ValueError(f"{expected_episode}: invalid reviewed row {index}")
        english = english.strip()
        chinese = chinese.strip()
        if len(WORD_RE.findall(english)) > 30:
            raise ValueError(f"{expected_episode}: row {index} exceeds 30 words")
        validate_names(expected_episode, index, english, chinese)
        rows.append(ReviewRow(index, english, chinese, status))
    canonical_hash = sha256_text(canonical("".join(row.english for row in rows)))
    expected_hash = document.get("canonicalEnglishSha256")
    if isinstance(expected_hash, str) and expected_hash and expected_hash != canonical_hash:
        raise ValueError(f"{expected_episode}: canonical English hash changed after review")
    return ReviewChapter(expected_episode, tuple(rows), canonical_hash)


def validate_names(episode: str, index: int, english: str, chinese: str) -> None:
    # Chinese story prose may naturally carry a named subject forward as a
    # pronoun across adjacent subtitle rows.  The consistency rule forbids
    # switching established names to Chinese aliases; it does not require the
    # English name to be repeated mechanically in every split fragment.
    del english
    if FORBIDDEN_TRANSLATED_NAMES_RE.search(chinese):
        raise ValueError(f"{episode}: row {index} translated a fixed character name")


def connect_read_only(db_path: Path) -> sqlite3.Connection:
    uri = db_path.resolve().as_uri() + "?mode=ro"
    connection = sqlite3.connect(uri, uri=True)
    connection.row_factory = sqlite3.Row
    return connection


def load_series_articles(connection: sqlite3.Connection, series_title: str) -> dict[str, ArticleSnapshot]:
    article_rows = connection.execute(
        """
        SELECT a.id AS article_id, a.title, a.content, a.sentences,
               a.sentence_split_version, sc.id AS chapter_id, sc.summary_json
          FROM story_series ss
          JOIN story_chapters sc ON sc.series_id = ss.id
          JOIN articles a ON a.id = sc.article_id
         WHERE ss.title = ?
         ORDER BY sc.chapter_order, a.id
        """,
        (series_title,),
    ).fetchall()
    snapshots: dict[str, ArticleSnapshot] = {}
    for article in article_rows:
        episode = episode_from_title(str(article["title"]))
        if episode is None:
            continue
        if episode in snapshots:
            raise ValueError(f"{episode}: duplicate article in series")
        decoded = json.loads(article["sentences"])
        if not isinstance(decoded, list) or not decoded:
            raise ValueError(f"{episode}: article sentences are invalid")
        pages = tuple(
            connection.execute(
                "SELECT * FROM picture_book_pages WHERE article_id = ? ORDER BY page_index",
                (article["article_id"],),
            ).fetchall()
        )
        translations = tuple(
            connection.execute(
                "SELECT * FROM article_sentence_translations WHERE article_id = ? ORDER BY sentence_index",
                (article["article_id"],),
            ).fetchall()
        )
        snapshots[episode] = ArticleSnapshot(
            article_id=int(article["article_id"]),
            title=str(article["title"]),
            content=str(article["content"]),
            sentences=tuple(str(value) for value in decoded),
            split_version=str(article["sentence_split_version"]),
            chapter_id=int(article["chapter_id"]),
            summary_json=str(article["summary_json"]),
            pages=pages,
            translations=translations,
        )
    return snapshots


def validate_old_rows(snapshot: ArticleSnapshot, episode: str) -> None:
    if len(snapshot.translations) != len(snapshot.sentences):
        raise ValueError(f"{episode}: old translation count does not match sentences")
    for index, row in enumerate(snapshot.translations):
        if (
            int(row["sentence_index"]) != index
            or str(row["english_sentence"]) != snapshot.sentences[index]
            or not str(row["chinese_text"]).strip()
        ):
            raise ValueError(f"{episode}: invalid old translation row {index}")
    if not snapshot.pages:
        raise ValueError(f"{episode}: picture-book pages are missing")
    expected_start = 0
    for index, page in enumerate(snapshot.pages):
        start = int(page["sentence_start_index"])
        end = int(page["sentence_end_index"])
        if int(page["page_index"]) != index or start != expected_start or end < start:
            raise ValueError(f"{episode}: invalid picture-book page range {index}")
        expected_start = end + 1
    if expected_start != len(snapshot.sentences):
        raise ValueError(f"{episode}: picture-book pages do not cover all old sentences")


def source_projection(
    old_text: str, new_text: str, episode: str
) -> tuple[
    list[tuple[str, int, int, int, int]],
    list[dict[str, Any]],
    list[dict[str, Any]],
]:
    old_stream = canonical(old_text)
    new_stream = canonical(new_text)
    matcher = difflib.SequenceMatcher(a=old_stream, b=new_stream, autojunk=False)
    opcodes = matcher.get_opcodes()
    deletions: list[dict[str, Any]] = []
    punctuation_edits: list[dict[str, Any]] = []
    for tag, old_start, old_end, new_start, new_end in opcodes:
        if tag == "equal":
            continue
        old_fragment = old_stream[old_start:old_end]
        new_fragment = new_stream[new_start:new_end]
        if not any(character.isalnum() for character in old_fragment + new_fragment):
            punctuation_edits.append(
                {
                    "tag": tag,
                    "oldStart": old_start,
                    "oldEnd": old_end,
                    "newStart": new_start,
                    "newEnd": new_end,
                    "old": old_fragment,
                    "new": new_fragment,
                }
            )
            continue
        if tag != "delete":
            old_context = old_stream[max(0, old_start - 40) : min(len(old_stream), old_end + 40)]
            new_context = new_stream[max(0, new_start - 40) : min(len(new_stream), new_end + 40)]
            raise ValueError(
                f"{episode}: reviewed English is not the old source with whitespace/deletions only "
                f"({tag} old[{old_start}:{old_end}]={old_stream[old_start:old_end]!r} "
                f"new[{new_start}:{new_end}]={new_stream[new_start:new_end]!r}; "
                f"oldContext={old_context!r}; newContext={new_context!r})"
            )
        deleted = old_fragment
        deletions.append(
            {
                "start": old_start,
                "end": old_end,
                "characters": len(deleted),
                "sha256": sha256_text(deleted),
            }
        )
    confirmation = CONFIRMED_SOURCE_DELETIONS.get(episode)
    if deletions:
        if confirmation is None or len(deletions) != 1:
            raise ValueError(f"{episode}: unexpected source characters would be deleted")
        actual = deletions[0]
        if (
            actual["characters"] != confirmation["characters"]
            or actual["sha256"] != confirmation["sha256"]
        ):
            raise ValueError(
                f"{episode}: source deletion is not the confirmed duplicate "
                f"(actual={actual!r}; expected={confirmation!r}; "
                f"actualText={old_stream[actual['start']:actual['end']]!r})"
            )
    return opcodes, deletions, punctuation_edits


def project_old_position(position: int, opcodes: Sequence[tuple[str, int, int, int, int]]) -> int:
    projected = 0
    for opcode_index, (tag, old_start, old_end, new_start, new_end) in enumerate(opcodes):
        if position < old_start:
            return new_start
        if tag == "insert":
            if position == old_start:
                return new_end
            projected = new_end
            continue
        if position <= old_end:
            if tag == "equal":
                if position == old_end and opcode_index + 1 < len(opcodes):
                    next_tag, next_old_start, _next_old_end, _next_new_start, next_new_end = (
                        opcodes[opcode_index + 1]
                    )
                    if next_tag == "insert" and next_old_start == position:
                        return next_new_end
                return new_start + (position - old_start)
            if position == old_end:
                return new_end
            return new_start
        projected = new_end
    return projected


def cumulative_ends(sentences: Sequence[str]) -> list[int]:
    result: list[int] = []
    total = 0
    for sentence in sentences:
        total += len(canonical(sentence))
        result.append(total)
    return result


def align_page_ranges(
    old_sentences: Sequence[str],
    new_sentences: Sequence[str],
    pages: Sequence[sqlite3.Row],
    opcodes: Sequence[tuple[str, int, int, int, int]],
) -> tuple[list[tuple[int, int]], list[dict[str, int]]]:
    if len(new_sentences) < len(pages):
        raise ValueError("There are fewer new sentences than picture-book pages")
    old_ends = cumulative_ends(old_sentences)
    new_ends = cumulative_ends(new_sentences)
    targets = [
        project_old_position(old_ends[int(page["sentence_end_index"])], opcodes)
        for page in pages[:-1]
    ]
    if not targets:
        return [(0, len(new_sentences) - 1)], []

    states: list[dict[int, tuple[int, int | None]]] = []
    for boundary, target in enumerate(targets):
        current: dict[int, tuple[int, int | None]] = {}
        minimum_cut = boundary
        maximum_cut = len(new_sentences) - (len(pages) - boundary)
        for cut in range(minimum_cut, maximum_cut + 1):
            shift = abs(new_ends[cut] - target)
            if boundary == 0:
                current[cut] = (shift, None)
                continue
            candidates = [
                (cost + shift, previous_cut)
                for previous_cut, (cost, _parent) in states[boundary - 1].items()
                if previous_cut < cut
            ]
            if candidates:
                current[cut] = min(candidates, key=lambda item: (item[0], item[1]))
        if not current:
            raise ValueError(f"No valid image mapping at boundary {boundary}")
        states.append(current)

    final_cut = min(states[-1], key=lambda cut: (states[-1][cut][0], cut))
    cuts = [final_cut]
    for boundary in range(len(states) - 1, 0, -1):
        parent = states[boundary][cuts[-1]][1]
        if parent is None:
            raise AssertionError("Missing image-range parent")
        cuts.append(parent)
    cuts.reverse()
    ranges: list[tuple[int, int]] = []
    mapping: list[dict[str, int]] = []
    start = 0
    for page_index in range(len(pages)):
        end = cuts[page_index] if page_index < len(cuts) else len(new_sentences) - 1
        ranges.append((start, end))
        if page_index < len(targets):
            mapping.append(
                {
                    "pageIndex": page_index,
                    "oldProjectedEnd": targets[page_index],
                    "newEnd": new_ends[end],
                    "shiftCharacters": abs(new_ends[end] - targets[page_index]),
                }
            )
        start = end + 1
    return ranges, mapping


def update_json_ranges(
    snapshot: ArticleSnapshot,
    ranges: Sequence[tuple[int, int]],
    previous_hash: str,
    now: str,
) -> tuple[list[str], str]:
    page_prompts: list[str] = []
    for page, (start, end) in zip(snapshot.pages, ranges, strict=True):
        try:
            prompt = json.loads(str(page["prompt_json"]))
        except json.JSONDecodeError as error:
            raise ValueError(f"{snapshot.title}: page {page['page_index']} prompt JSON is invalid") from error
        scene = prompt.get("scene")
        if not isinstance(scene, dict) or scene.get("pageIndex") != int(page["page_index"]):
            raise ValueError(f"{snapshot.title}: page {page['page_index']} prompt scene is invalid")
        scene["sentenceStartIndex"] = start
        scene["sentenceEndIndex"] = end
        prompt["scene"] = scene
        prompt["sentenceSplitVersion"] = SPLIT_VERSION
        page_prompts.append(compact_json(prompt))

    try:
        summary = json.loads(snapshot.summary_json)
    except json.JSONDecodeError as error:
        raise ValueError(f"{snapshot.title}: chapter summary JSON is invalid") from error
    scenes = summary.get("scenes")
    if not isinstance(scenes, list) or len(scenes) != len(ranges):
        raise ValueError(f"{snapshot.title}: summary scene count differs from picture pages")
    seen: set[int] = set()
    for scene in scenes:
        if not isinstance(scene, dict) or not isinstance(scene.get("pageIndex"), int):
            raise ValueError(f"{snapshot.title}: invalid summary scene")
        page_index = scene["pageIndex"]
        if page_index in seen or not 0 <= page_index < len(ranges):
            raise ValueError(f"{snapshot.title}: invalid summary pageIndex {page_index}")
        seen.add(page_index)
        scene["sentenceStartIndex"], scene["sentenceEndIndex"] = ranges[page_index]
    if seen != set(range(len(ranges))):
        raise ValueError(f"{snapshot.title}: summary page indexes are incomplete")
    summary["sentenceMigration"] = {
        "sentenceSplitVersion": SPLIT_VERSION,
        "solverVersion": SOLVER_VERSION,
        "source": REVIEW_SOURCE,
        "previousSentencesSha256": previous_hash,
        "migratedAt": now,
        "ttsRegenerated": False,
    }
    return page_prompts, compact_json(summary)


def media_fingerprint(pages: Sequence[sqlite3.Row]) -> str:
    fields = [
        {
            "id": int(page["id"]),
            "pageIndex": int(page["page_index"]),
            "imageCacheKey": page["image_cache_key"],
            "imagePath": page["image_path"],
            "status": page["status"],
            "errorMessage": page["error_message"],
            "createdAt": page["created_at"],
        }
        for page in pages
    ]
    return sha256_text(compact_json(fields))


def prepare_chapter(snapshot: ArticleSnapshot, review: ReviewChapter) -> dict[str, Any]:
    validate_old_rows(snapshot, review.episode)
    new_sentences = review.sentences
    old_text = "".join(snapshot.sentences)
    new_text = "".join(new_sentences)
    opcodes, deletions, punctuation_edits = source_projection(
        old_text, new_text, review.episode
    )
    if sha256_text(canonical(new_text)) != review.canonical_hash:
        raise AssertionError(f"{review.episode}: review hash changed during preparation")
    ranges, mapping = align_page_ranges(snapshot.sentences, new_sentences, snapshot.pages, opcodes)
    previous_hash = sentences_hash(snapshot.sentences)
    now = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    page_prompts, summary_json = update_json_ranges(snapshot, ranges, previous_hash, now)
    old_exact: dict[tuple[str, str], list[sqlite3.Row]] = {}
    for row in snapshot.translations:
        key = (str(row["english_sentence"]), str(row["chinese_text"]))
        old_exact.setdefault(key, []).append(row)
    translation_rows: list[dict[str, Any]] = []
    reused = 0
    retranslated = 0
    for row in review.rows:
        old = None
        if row.status == "reused_checked":
            queue = old_exact.get((row.english, row.chinese), [])
            # The manual review baseline is the archived V2 bilingual text.
            # A live database may already contain an intermediate V3 split, so
            # an approved reuse need not be a whole-row match in that database.
            # Preserve the old timestamp only when an exact live row exists.
            old = queue.pop(0) if queue else None
            reused += 1
        else:
            retranslated += 1
        translation_rows.append(
            {
                "article_id": snapshot.article_id,
                "sentence_index": row.index,
                "english_sentence": row.english,
                "chinese_text": row.chinese,
                "source": (
                    f"migrated_exact_current:{old['source']}"
                    if old is not None
                    else f"{REVIEW_SOURCE}:{row.status}"
                ),
                "created_at": str(old["created_at"]) if old is not None else now,
                "updated_at": now,
            }
        )
    shifts = [item["shiftCharacters"] for item in mapping]
    return {
        "episode": review.episode,
        "articleId": snapshot.article_id,
        "title": snapshot.title,
        "expectedSentences": list(snapshot.sentences),
        "expectedSentencesJson": compact_json(list(snapshot.sentences)),
        "previousSentencesSha256": previous_hash,
        "previousSplitVersion": snapshot.split_version,
        "sentences": new_sentences,
        "sentencesJson": compact_json(new_sentences),
        "content": " ".join(new_sentences),
        "translations": translation_rows,
        "oldRanges": [
            (int(page["sentence_start_index"]), int(page["sentence_end_index"]))
            for page in snapshot.pages
        ],
        "ranges": ranges,
        "pagePrompts": page_prompts,
        "summaryJson": summary_json,
        "chapterId": snapshot.chapter_id,
        "now": now,
        "sourceDeletions": deletions,
        "punctuationNormalizationEdits": punctuation_edits,
        "removedSourceCharacters": sum(item["characters"] for item in deletions),
        "reusedTranslations": reused,
        "retranslatedTranslations": retranslated,
        "mapping": mapping,
        "mappingTotalShiftCharacters": sum(shifts),
        "mappingMaxShiftCharacters": max(shifts, default=0),
        "mediaFingerprint": media_fingerprint(snapshot.pages),
    }


def apply_chapter(connection: sqlite3.Connection, item: dict[str, Any]) -> None:
    article_id = item["articleId"]
    current = connection.execute(
        "SELECT sentences, sentence_split_version FROM articles WHERE id = ?", (article_id,)
    ).fetchone()
    if current is None or str(current["sentences"]) != item["expectedSentencesJson"]:
        raise RuntimeError(f"{item['episode']}: article sentences changed after validation")
    changed = connection.execute(
        """
        UPDATE articles
           SET content = ?, sentences = ?, sentence_split_version = ?
         WHERE id = ? AND sentences = ? AND sentence_split_version = ?
        """,
        (
            item["content"],
            item["sentencesJson"],
            SPLIT_VERSION,
            article_id,
            item["expectedSentencesJson"],
            item["previousSplitVersion"],
        ),
    ).rowcount
    if changed != 1:
        raise RuntimeError(f"{item['episode']}: guarded article update failed")
    connection.execute("DELETE FROM article_sentence_translations WHERE article_id = ?", (article_id,))
    connection.executemany(
        """
        INSERT INTO article_sentence_translations
          (article_id, sentence_index, english_sentence, chinese_text, source, created_at, updated_at)
        VALUES
          (:article_id, :sentence_index, :english_sentence, :chinese_text, :source, :created_at, :updated_at)
        """,
        item["translations"],
    )
    for page_index, ((start, end), prompt_json) in enumerate(
        zip(item["ranges"], item["pagePrompts"], strict=True)
    ):
        paragraph = " ".join(item["sentences"][start : end + 1])
        changed = connection.execute(
            """
            UPDATE picture_book_pages
               SET sentence_start_index = ?, sentence_end_index = ?,
                   paragraph_text = ?, prompt_json = ?, updated_at = ?
             WHERE article_id = ? AND page_index = ?
            """,
            (start, end, paragraph, prompt_json, item["now"], article_id, page_index),
        ).rowcount
        if changed != 1:
            raise RuntimeError(f"{item['episode']}: page {page_index} update failed")
    changed = connection.execute(
        "UPDATE story_chapters SET summary_json = ?, updated_at = ? WHERE id = ? AND article_id = ?",
        (item["summaryJson"], item["now"], item["chapterId"], article_id),
    ).rowcount
    if changed != 1:
        raise RuntimeError(f"{item['episode']}: chapter update failed")


def verify_after(connection: sqlite3.Connection, item: dict[str, Any]) -> None:
    article = connection.execute(
        "SELECT content, sentences, sentence_split_version FROM articles WHERE id = ?",
        (item["articleId"],),
    ).fetchone()
    if (
        article is None
        or str(article["sentences"]) != item["sentencesJson"]
        or str(article["content"]) != item["content"]
        or str(article["sentence_split_version"]) != SPLIT_VERSION
    ):
        raise RuntimeError(f"{item['episode']}: article read-back failed")
    translations = connection.execute(
        "SELECT sentence_index, english_sentence, chinese_text FROM article_sentence_translations "
        "WHERE article_id = ? ORDER BY sentence_index",
        (item["articleId"],),
    ).fetchall()
    expected = [(row["sentence_index"], row["english_sentence"], row["chinese_text"]) for row in item["translations"]]
    actual = [(int(row[0]), str(row[1]), str(row[2])) for row in translations]
    if actual != expected:
        raise RuntimeError(f"{item['episode']}: translation read-back failed")
    pages = connection.execute(
        "SELECT * FROM picture_book_pages WHERE article_id = ? ORDER BY page_index",
        (item["articleId"],),
    ).fetchall()
    if media_fingerprint(pages) != item["mediaFingerprint"]:
        raise RuntimeError(f"{item['episode']}: image/media fields changed")
    actual_ranges = [(int(page["sentence_start_index"]), int(page["sentence_end_index"])) for page in pages]
    if actual_ranges != item["ranges"]:
        raise RuntimeError(f"{item['episode']}: picture range read-back failed")
    for page_index, page in enumerate(pages):
        start, end = item["ranges"][page_index]
        expected_paragraph = " ".join(item["sentences"][start : end + 1])
        if (
            str(page["paragraph_text"]) != expected_paragraph
            or str(page["prompt_json"]) != item["pagePrompts"][page_index]
        ):
            raise RuntimeError(f"{item['episode']}: picture metadata read-back failed")
    chapter = connection.execute(
        "SELECT summary_json FROM story_chapters WHERE id = ? AND article_id = ?",
        (item["chapterId"], item["articleId"]),
    ).fetchone()
    if chapter is None or str(chapter["summary_json"]) != item["summaryJson"]:
        raise RuntimeError(f"{item['episode']}: chapter summary read-back failed")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def create_backup(db_path: Path, backup_path: Path) -> None:
    backup_path.parent.mkdir(parents=True, exist_ok=True)
    source = connect_read_only(db_path)
    try:
        destination = sqlite3.connect(backup_path)
        try:
            source.backup(destination)
        finally:
            destination.close()
    finally:
        source.close()
    if not backup_path.exists() or backup_path.stat().st_size == 0:
        raise RuntimeError("SQLite backup was not created")


def summarize(prepared: Sequence[dict[str, Any]]) -> dict[str, Any]:
    internal_boundaries = [
        boundary
        for item in prepared
        for boundary in item["mapping"]
    ]
    return {
        "chapters": len(prepared),
        "oldSentences": sum(len(item["expectedSentences"]) for item in prepared),
        "newSentences": sum(len(item["sentences"]) for item in prepared),
        "reusedTranslations": sum(item["reusedTranslations"] for item in prepared),
        "retranslatedTranslations": sum(item["retranslatedTranslations"] for item in prepared),
        "removedSourceCharacters": sum(item["removedSourceCharacters"] for item in prepared),
        "punctuationNormalizationEdits": sum(
            len(item["punctuationNormalizationEdits"]) for item in prepared
        ),
        "picturePages": sum(len(item["ranges"]) for item in prepared),
        "pictureInternalBoundaries": len(internal_boundaries),
        "pictureExactBoundaries": sum(
            1 for boundary in internal_boundaries if boundary["shiftCharacters"] == 0
        ),
        "pictureShiftedBoundaries": sum(
            1 for boundary in internal_boundaries if boundary["shiftCharacters"] > 0
        ),
        "mappingTotalShiftCharacters": sum(item["mappingTotalShiftCharacters"] for item in prepared),
        "mappingMaxShiftCharacters": max(
            (item["mappingMaxShiftCharacters"] for item in prepared), default=0
        ),
        "ttsRegenerated": False,
        "remoteApiCalls": 0,
    }


def run_self_test() -> None:
    old_stream = "abcDUPdef"
    new_stream = "abcdef"
    matcher = difflib.SequenceMatcher(a=old_stream, b=new_stream, autojunk=False)
    opcodes = matcher.get_opcodes()
    assert project_old_position(3, opcodes) == 3
    assert project_old_position(6, opcodes) == 3
    assert project_old_position(9, opcodes) == 6
    inserted = difflib.SequenceMatcher(a="abcdef", b="abc...def", autojunk=False).get_opcodes()
    assert project_old_position(3, inserted) == 6
    assert project_old_position(6, inserted) == 9
    assert canonical("A  B\nC") == "ABC"
    assert len(WORD_RE.findall("house—but it wasn't Mole's")) == 5


def main() -> int:
    args = parse_args()
    if args.self_test:
        run_self_test()
        print("migrate_willows_segmentation_v3_offline.py: self-test PASS")
        return 0
    if args.db is None or args.review_root is None:
        raise ValueError("--db and --review-root are required unless --self-test is used")
    db_path = args.db.resolve()
    review_root = args.review_root.resolve()
    if not db_path.is_file():
        raise FileNotFoundError(db_path)
    if not review_root.is_dir():
        raise FileNotFoundError(review_root)
    requested = parse_episode_filter(args.episodes)
    expected = sorted(requested or {f"E{number:02d}" for number in range(1, 63)})
    output_root = (args.output_root or (review_root.parent / "migration-runs")).resolve()
    run_id = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")

    connection = connect_read_only(db_path)
    try:
        snapshots = load_series_articles(connection, args.series_title)
        missing_articles = [episode for episode in expected if episode not in snapshots]
        if missing_articles:
            raise ValueError(f"Missing series articles: {', '.join(missing_articles)}")
        reviews = {
            episode: load_review(review_root / f"{episode}.json", episode)
            for episode in expected
        }
        prepared = [prepare_chapter(snapshots[episode], reviews[episode]) for episode in expected]
    finally:
        connection.close()

    log: dict[str, Any] = {
        "schemaVersion": 1,
        "runId": run_id,
        "mode": "apply" if args.apply else "dry-run",
        "database": str(db_path),
        "seriesTitle": args.series_title,
        "reviewRoot": str(review_root),
        "sentenceSplitVersion": SPLIT_VERSION,
        "solverVersion": SOLVER_VERSION,
        "summary": summarize(prepared),
        "chapters": [
            {
                key: item[key]
                for key in (
                    "episode",
                    "articleId",
                    "title",
                    "previousSentencesSha256",
                    "previousSplitVersion",
                    "removedSourceCharacters",
                    "sourceDeletions",
                    "punctuationNormalizationEdits",
                    "reusedTranslations",
                    "retranslatedTranslations",
                    "mappingTotalShiftCharacters",
                    "mappingMaxShiftCharacters",
                    "mapping",
                    "oldRanges",
                    "ranges",
                    "mediaFingerprint",
                )
            }
            | {
                "previousSentenceCount": len(item["expectedSentences"]),
                "sentenceCount": len(item["sentences"]),
                "pageCount": len(item["ranges"]),
            }
            for item in prepared
        ],
        "startedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
    }

    if args.apply:
        output_root.mkdir(parents=True, exist_ok=True)
        backup_path = output_root / "backups" / f"{db_path.stem}.{run_id}.before.db"
        create_backup(db_path, backup_path)
        log["backup"] = str(backup_path)
        connection = sqlite3.connect(db_path)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        try:
            connection.execute("BEGIN IMMEDIATE")
            for item in prepared:
                apply_chapter(connection, item)
            for item in prepared:
                verify_after(connection, item)
            connection.commit()
        except BaseException:
            connection.rollback()
            raise
        finally:
            connection.close()
        log["completedAt"] = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
        log["status"] = "applied_and_verified"
    else:
        log["status"] = "dry_run_validated"
        log["completedAt"] = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")

    log_path = output_root / f"{run_id}.{'apply' if args.apply else 'dry-run'}.json"
    write_json(log_path, log)
    print(json.dumps({"log": str(log_path), **log["summary"]}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, FileNotFoundError, RuntimeError, sqlite3.Error, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
