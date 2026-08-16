#!/usr/bin/env python3
"""Offline DB-vs-current-splitter diff for Alice + Willows.

Read-only: compares published `articles.sentences` against the latest full
splitter replay reports (r8n16 final). Does not write SQLite, TTS, or media.
"""

from __future__ import annotations

import json
import re
import sqlite3
from collections import Counter
from datetime import datetime, timezone
from difflib import SequenceMatcher
from pathlib import Path

ROOT = Path(r"F:\TomatoEnglishHappyTalking")
DB = (
    ROOT
    / "release"
    / "windows"
    / "tomato_english_happy_talking"
    / ".dart_tool"
    / "sqflite_common_ffi"
    / "databases"
    / "english_love.db"
)
REPORT_ROOT = ROOT / "output" / "sentence-split-v3"
CANDIDATE_FILES = {
    "Alice": [REPORT_ROOT / "production-integration-r8n16-final-full-a.json"],
    "Willows": [
        REPORT_ROOT / "production-integration-r8n16-final-full-w1.json",
        REPORT_ROOT / "production-integration-r8n16-final-full-w2.json",
        REPORT_ROOT / "production-integration-r8n16-final-full-w3.json",
        REPORT_ROOT / "production-integration-r8n16-final-full-w4.json",
    ],
}
SERIES = {"Alice": 23, "Willows": 30}
SPACE_RE = re.compile(r"\s+")
PAUSE_CHARS = set(";:—–,.!?")
QUOTE_CHARS = set("\"'“”‘’")


def canon(text: str) -> str:
    return SPACE_RE.sub("", text)


def boundaries_and_spans(sentences: list[str]):
    offs: set[int] = set()
    spans: list[tuple[int, int, str]] = []
    cursor = 0
    for index, sentence in enumerate(sentences):
        end = cursor + len(canon(sentence))
        spans.append((cursor, end, sentence))
        if index + 1 < len(sentences):
            offs.add(end)
        cursor = end
    return offs, spans, cursor


def char_before_boundary(source: str, canon_off: int) -> str | None:
    count = 0
    last = None
    for ch in source:
        if not ch.isspace():
            count += 1
            last = ch
            if count == canon_off:
                return last
    return last


def is_punct_boundary(source: str, canon_off: int) -> bool:
    ch = char_before_boundary(source, canon_off)
    return bool(ch) and (ch in PAUSE_CHARS or ch in QUOTE_CHARS)


def load_candidates() -> tuple[dict[tuple[str, str], dict], dict[str, dict]]:
    chapters: dict[tuple[str, str], dict] = {}
    meta: dict[str, dict] = {}
    for book, paths in CANDIDATE_FILES.items():
        book_meta = None
        for path in paths:
            data = json.loads(path.read_text(encoding="utf-8"))
            book_meta = data.get("summary") or {}
            for chapter in data["chapters"]:
                episode = str(chapter["episode"]).upper()
                chapters[(book, episode)] = chapter
        meta[book] = {
            **(book_meta or {}),
            "reportFiles": [str(p.relative_to(ROOT)).replace("\\", "/") for p in paths],
        }
    return chapters, meta


def db_articles(series_id: int) -> list[dict]:
    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
    rows = con.execute(
        """
        SELECT a.id AS article_id, a.title, a.sentences, a.sentence_split_version,
               a.content, sc.chapter_order, sc.summary_json
          FROM story_chapters sc
          JOIN articles a ON a.id = sc.article_id
         WHERE sc.series_id = ?
         ORDER BY sc.chapter_order
        """,
        (series_id,),
    ).fetchall()
    out = []
    for row in rows:
        match = re.search(r"\b(E\d{2})\b", row["title"])
        summary = {}
        try:
            summary = json.loads(row["summary_json"] or "{}")
        except json.JSONDecodeError:
            summary = {}
        migration = summary.get("sentenceMigration") or {}
        out.append(
            {
                "articleId": int(row["article_id"]),
                "title": row["title"],
                "episode": match.group(1) if match else None,
                "sentenceSplitVersion": row["sentence_split_version"],
                "migrationSolverVersion": migration.get("solverVersion"),
                "migratedAt": migration.get("migratedAt"),
                "sentences": json.loads(row["sentences"] or "[]"),
                "content": row["content"] or "",
            }
        )
    return out


def song_article_ids(con: sqlite3.Connection) -> set[int]:
    return {
        int(row[0])
        for row in con.execute(
            """
            SELECT DISTINCT r.article_id
              FROM api_cache_entries e
              JOIN api_cache_article_refs r ON r.cache_key = e.cache_key
              JOIN story_chapters sc ON sc.article_id = r.article_id
             WHERE e.purpose = 'suno_song_subtitle_timeline_v1'
               AND sc.series_id = 23
            """
        )
    }


def change_hunks(old: list[str], new: list[str]) -> list[dict]:
    matcher = SequenceMatcher(a=old, b=new, autojunk=False)
    hunks = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        hunks.append(
            {
                "op": tag,
                "oldStart": i1,
                "oldEnd": i2,
                "newStart": j1,
                "newEnd": j2,
                "old": old[i1:i2],
                "new": new[j1:j2],
            }
        )
    return hunks


def classify_chapter(
    old_visible: list[str],
    new_sents: list[str],
    source: str,
) -> dict:
    text_for_bounds = (
        source if canon("".join(new_sents)) == canon(source) else "".join(new_sents)
    )
    old_off, old_spans, old_len = boundaries_and_spans(old_visible)
    new_off, new_spans, new_len = boundaries_and_spans(new_sents)
    if old_len != new_len:
        return {
            "status": "source_mismatch",
            "oldLen": old_len,
            "newLen": new_len,
        }

    added = sorted(new_off - old_off)
    removed = sorted(old_off - new_off)
    added_punct = sum(1 for off in added if is_punct_boundary(text_for_bounds, off))
    removed_punct = sum(
        1 for off in removed if is_punct_boundary(text_for_bounds, off)
    )
    added_non = len(added) - added_punct
    removed_non = len(removed) - removed_punct

    must_retts: list[int] = []
    for ni, (ns, ne, _nt) in enumerate(new_spans):
        if any(os == ns and oe == ne for os, oe, _ in old_spans):
            continue
        internal_old = [off for off in old_off if ns < off < ne]
        if internal_old:
            if (
                all(is_punct_boundary(text_for_bounds, off) for off in internal_old)
                and any(os == ns for os, _, _ in old_spans)
                and any(oe == ne for _, oe, _ in old_spans)
            ):
                continue
            must_retts.append(ni)
            continue
        parents = [
            (os, oe)
            for os, oe, _ in old_spans
            if os <= ns and ne <= oe and (os, oe) != (ns, ne)
        ]
        if len(parents) == 1:
            os, oe = parents[0]
            cuts = [off for off in new_off if os < off < oe]
            if all(is_punct_boundary(text_for_bounds, off) for off in cuts):
                continue
            must_retts.append(ni)
            continue
        must_retts.append(ni)

    exact_reuse = sum(
        1
        for sentence in old_visible
        if canon(sentence) in {canon(item) for item in new_sents}
    )
    return {
        "status": "ok",
        "addedBoundaries": len(added),
        "removedBoundaries": len(removed),
        "punctBoundaryChanges": added_punct + removed_punct,
        "nonpunctBoundaryChanges": added_non + removed_non,
        "mustReTtsNewSentenceIndexes": must_retts,
        "mustReTtsNewSentenceCount": len(must_retts),
        "exactReusableOldSentenceCount": exact_reuse,
        "exactReusableOldSentenceRatio": round(
            exact_reuse / max(len(old_visible), 1), 4
        ),
    }


def chapter_markdown(payload: dict) -> str:
    lines = [
        f"# {payload['episode']} — {payload['title']}",
        "",
        f"- articleId: `{payload['articleId']}`",
        f"- DB version: `{payload['sentenceSplitVersion']}`"
        + (
            f" (migration solver `{payload.get('migrationSolverVersion')}`)"
            if payload.get("migrationSolverVersion")
            else ""
        ),
        f"- candidate sentences: **{payload['newSentenceCount']}**"
        f" (was **{payload['oldSentenceCount']}** visible)",
        f"- boundary +{payload['classification']['addedBoundaries']}"
        f" / -{payload['classification']['removedBoundaries']}"
        f"; punct={payload['classification']['punctBoundaryChanges']}"
        f"; nonpunct={payload['classification']['nonpunctBoundaryChanges']}",
        f"- must re-TTS new sentences: **{payload['classification']['mustReTtsNewSentenceCount']}**",
        f"- exact old-sentence text reuse: "
        f"{payload['classification']['exactReusableOldSentenceCount']}/"
        f"{payload['oldSentenceCount']}"
        f" ({payload['classification']['exactReusableOldSentenceRatio']:.1%})",
    ]
    if payload.get("hasSongTimeline"):
        lines.append("- song timeline present: **yes** (video remapping required after apply)")
    lines.extend(["", "## Change hunks", ""])
    if not payload["hunks"]:
        lines.append("_No sentence-list differences._")
    for index, hunk in enumerate(payload["hunks"], start=1):
        lines.append(
            f"### Hunk {index}: `{hunk['op']}` "
            f"old[{hunk['oldStart']}:{hunk['oldEnd']}] → "
            f"new[{hunk['newStart']}:{hunk['newEnd']}]"
        )
        if hunk["old"]:
            lines.append("")
            lines.append("Old:")
            for item in hunk["old"]:
                lines.append(f"- {item}")
        if hunk["new"]:
            lines.append("")
            lines.append("New:")
            for item in hunk["new"]:
                lines.append(f"- {item}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def write_book(
    out_dir: Path,
    book: str,
    articles: list[dict],
    candidates: dict[tuple[str, str], dict],
    meta: dict,
    song_aids: set[int],
) -> dict:
    book_dir = out_dir / book.lower()
    chapters_dir = book_dir / "chapters"
    chapters_dir.mkdir(parents=True, exist_ok=True)

    chapter_payloads = []
    missing = []
    mismatch = []
    for article in articles:
        episode = article["episode"]
        key = (book, episode)
        if key not in candidates:
            missing.append(article)
            continue
        cand = candidates[key]
        old_visible = [s for s in article["sentences"] if str(s).strip()]
        new_sents = list(cand["v3LocalSentences"])
        source = cand.get("source") or "".join(new_sents)
        classification = classify_chapter(old_visible, new_sents, source)
        if classification["status"] != "ok":
            mismatch.append({"episode": episode, **classification})
            continue
        payload = {
            "book": book,
            "episode": episode,
            "articleId": article["articleId"],
            "title": article["title"],
            "sentenceSplitVersion": article["sentenceSplitVersion"],
            "migrationSolverVersion": article.get("migrationSolverVersion"),
            "migratedAt": article.get("migratedAt"),
            "oldSentenceCount": len(old_visible),
            "newSentenceCount": len(new_sents),
            "oldSentences": old_visible,
            "newSentences": new_sents,
            "hiddenSlotCount": sum(
                1 for s in article["sentences"] if not str(s).strip()
            ),
            "hasSongTimeline": article["articleId"] in song_aids,
            "classification": classification,
            "hunks": change_hunks(old_visible, new_sents),
            "changed": bool(
                classification["addedBoundaries"]
                or classification["removedBoundaries"]
            ),
        }
        chapter_payloads.append(payload)
        (chapters_dir / f"{episode}.json").write_text(
            json.dumps(payload, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        (chapters_dir / f"{episode}.md").write_text(
            chapter_markdown(payload),
            encoding="utf-8",
        )

    changed = [c for c in chapter_payloads if c["changed"]]
    summary = {
        "book": book,
        "seriesId": SERIES[book],
        "candidateMeta": meta,
        "chapterCount": len(chapter_payloads),
        "missingCandidateChapters": [
            {"episode": a.get("episode"), "title": a["title"]} for a in missing
        ],
        "sourceMismatchChapters": mismatch,
        "changedChapterCount": len(changed),
        "unchangedChapterCount": len(chapter_payloads) - len(changed),
        "oldVisibleSentences": sum(c["oldSentenceCount"] for c in chapter_payloads),
        "newSentences": sum(c["newSentenceCount"] for c in chapter_payloads),
        "boundaryChanges": sum(
            c["classification"]["addedBoundaries"]
            + c["classification"]["removedBoundaries"]
            for c in chapter_payloads
        ),
        "punctBoundaryChanges": sum(
            c["classification"]["punctBoundaryChanges"] for c in chapter_payloads
        ),
        "nonpunctBoundaryChanges": sum(
            c["classification"]["nonpunctBoundaryChanges"] for c in chapter_payloads
        ),
        "mustReTtsNewSentences": sum(
            c["classification"]["mustReTtsNewSentenceCount"] for c in chapter_payloads
        ),
        "chaptersNeedingAnyReTts": sum(
            1
            for c in chapter_payloads
            if c["classification"]["mustReTtsNewSentenceCount"] > 0
        ),
        "chaptersPunctOnlyChanges": sum(
            1
            for c in changed
            if c["classification"]["nonpunctBoundaryChanges"] == 0
        ),
        "songChaptersChanged": [
            {
                "episode": c["episode"],
                "articleId": c["articleId"],
                "title": c["title"],
                "mustReTts": c["classification"]["mustReTtsNewSentenceCount"],
                "nonpunct": c["classification"]["nonpunctBoundaryChanges"],
                "punct": c["classification"]["punctBoundaryChanges"],
            }
            for c in changed
            if c["hasSongTimeline"]
        ],
        "chapters": [
            {
                "episode": c["episode"],
                "articleId": c["articleId"],
                "title": c["title"],
                "old": c["oldSentenceCount"],
                "new": c["newSentenceCount"],
                "added": c["classification"]["addedBoundaries"],
                "removed": c["classification"]["removedBoundaries"],
                "punct": c["classification"]["punctBoundaryChanges"],
                "nonpunct": c["classification"]["nonpunctBoundaryChanges"],
                "mustReTts": c["classification"]["mustReTtsNewSentenceCount"],
                "reuseRatio": c["classification"]["exactReusableOldSentenceRatio"],
                "hasSongTimeline": c["hasSongTimeline"],
                "hunkCount": len(c["hunks"]),
            }
            for c in chapter_payloads
        ],
    }

    (book_dir / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    index_lines = [
        f"# {book} DB → current splitter offline diff",
        "",
        f"- chapters compared: **{summary['chapterCount']}**",
        f"- changed chapters: **{summary['changedChapterCount']}**",
        f"- sentences: {summary['oldVisibleSentences']} → {summary['newSentences']}",
        f"- boundary changes: {summary['boundaryChanges']} "
        f"(punct {summary['punctBoundaryChanges']}, "
        f"nonpunct {summary['nonpunctBoundaryChanges']})",
        f"- must re-TTS new sentences (estimate): **{summary['mustReTtsNewSentences']}** "
        f"across {summary['chaptersNeedingAnyReTts']} chapters",
        f"- punct-only changed chapters: {summary['chaptersPunctOnlyChanges']}",
        "",
        "| Episode | Old→New | +/− bounds | punct/nonpunct | must re-TTS | reuse | song |",
        "|---|---:|---:|---:|---:|---:|:---:|",
    ]
    for row in summary["chapters"]:
        index_lines.append(
            f"| [{row['episode']}](chapters/{row['episode']}.md) | "
            f"{row['old']}→{row['new']} | +{row['added']}/-{row['removed']} | "
            f"{row['punct']}/{row['nonpunct']} | {row['mustReTts']} | "
            f"{row['reuseRatio']:.0%} | {'Y' if row['hasSongTimeline'] else ''} |"
        )
    (book_dir / "README.md").write_text("\n".join(index_lines) + "\n", encoding="utf-8")
    return summary


def main() -> int:
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%MZ")
    out_dir = REPORT_ROOT / f"db-vs-current-splitter-diff-{stamp}"
    out_dir.mkdir(parents=True, exist_ok=True)

    candidates, meta = load_candidates()
    product_solver_version = "syntax_solver_v3_8"
    candidate_solver_labels = {
        book_meta.get("solverVersion") for book_meta in meta.values()
    }
    if candidate_solver_labels != {product_solver_version}:
        raise RuntimeError(
            "Candidate report solver labels must match the current product solver: "
            f"expected {product_solver_version}, got "
            f"{sorted(str(label) for label in candidate_solver_labels)}"
        )
    con = sqlite3.connect(DB)
    song_aids = song_article_ids(con)

    books = {}
    for book, series_id in SERIES.items():
        articles = db_articles(series_id)
        books[book] = write_book(
            out_dir,
            book,
            articles,
            candidates,
            meta[book],
            song_aids if book == "Alice" else set(),
        )

    combined = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "mode": "offline_readonly",
        "database": str(DB),
        "baseline": "DB articles.sentences (reviewed_dp_v3 / migration solver often syntax_solver_v3_6)",
        "candidate": "production-integration-r8n16-final-full-*.json",
        "candidateSolverLabel": meta["Alice"].get("solverVersion"),
        "productSolverConst": product_solver_version,
        "note": (
            "Candidate report labels match the current product solver const. "
            "This report does not write the database."
        ),
        "books": {
            name: {
                k: v
                for k, v in summary.items()
                if k not in {"chapters", "candidateMeta"}
            }
            | {"candidateMeta": summary["candidateMeta"]}
            for name, summary in books.items()
        },
    }
    (out_dir / "summary.json").write_text(
        json.dumps(combined, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    readme = [
        "# Alice + Willows offline splitter diff (DB → current)",
        "",
        f"- generated: `{combined['generatedAt']}`",
        f"- mode: **read-only** (no DB / TTS / media writes)",
        f"- baseline: published DB `reviewed_dp_v3` sentences",
        f"- candidate: `{combined['candidate']}` "
        f"(report label `{combined['candidateSolverLabel']}`; "
        f"product const `{combined['productSolverConst']}`)",
        "",
        "## Totals",
        "",
        "| Book | Chapters changed | Sentences old→new | Boundary Δ | punct / nonpunct | must re-TTS |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for book, summary in books.items():
        readme.append(
            f"| [{book}]({book.lower()}/README.md) | "
            f"{summary['changedChapterCount']}/{summary['chapterCount']} | "
            f"{summary['oldVisibleSentences']}→{summary['newSentences']} | "
            f"{summary['boundaryChanges']} | "
            f"{summary['punctBoundaryChanges']}/{summary['nonpunctBoundaryChanges']} | "
            f"{summary['mustReTtsNewSentences']} |"
        )
    readme.extend(
        [
            "",
            "## Review gate",
            "",
            "1. Open each book `README.md` and spot-check high `mustReTts` / low reuse chapters.",
            "2. Confirm English freeze before translation / picture remap / TTS / export.",
            "3. Alice songs: every changed chapter with a timeline needs song-video re-export after page remap; "
            "do not treat BigASR as required — use current `asr_provider` / `volc_asr_model` only if regenerating timelines.",
            "",
            "## Outputs",
            "",
            "- `summary.json` — machine totals",
            "- `alice/` / `willows/` — per-book summary + `chapters/Exx.md|json`",
            "",
        ]
    )
    (out_dir / "README.md").write_text("\n".join(readme), encoding="utf-8")
    print(out_dir)
    print(json.dumps(combined["books"], ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
