#!/usr/bin/env python3
"""Build a preliminary DB vs live syntax_solver_v3_9 review for 10+10 chapters.

Read-only: does not write SQLite, TTS, or media.
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
OUT = ROOT / "output" / "sentence-split-v3" / "v3-9-prelim-review-10x10"
SPACE_RE = re.compile(r"\s+")
WORD_RE = re.compile(r"[A-Za-z0-9]+(?:['’-][A-Za-z0-9]+)*")
PAUSE_CHARS = set(";:—–,.!?")
QUOTE_CHARS = set("\"'“”‘’")

SERIES = {"Alice": 23, "Willows": 30}
ALICE_EPS = [
    "E01",
    "E02",
    "E05",
    "E10",
    "E21",
    "E22",
    "E29",
    "E30",
    "E35",
    "E36",
]
WILLOWS_EPS = [
    "E01",
    "E25",
    "E26",
    "E27",
    "E28",
    "E30",
    "E35",
    "E40",
    "E43",
    "E58",
]
WHY = {
    "Alice": {
        "E01": "普通开篇基线",
        "E02": "长括号代表章",
        "E05": "审核长句拆分样例",
        "E10": "括号/逗号审核样例 H004",
        "E21": "审核长句样例",
        "E22": "审核长句样例",
        "E29": "审核短块/长句样例",
        "E30": "长引语多候选代表章",
        "E35": "多候选代表章",
        "E36": "括号开/闭缘审核样例",
    },
    "Willows": {
        "E01": "开篇 + nice, 逗号审核",
        "E25": "并列谓语收口样例 O24",
        "E26": "审核长句样例",
        "E27": "审核长句样例",
        "E28": "审核长句样例",
        "E30": "介词尾语收口样例 O21",
        "E35": "地点/范围介词尾审核",
        "E40": "审核长句样例",
        "E43": "多边界审核样例",
        "E58": "审核长句样例",
    },
}


def canon(text: str) -> str:
    return SPACE_RE.sub("", text)


def word_count(text: str) -> int:
    return len(WORD_RE.findall(text))


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


def classify_boundaries(old: list[str], new: list[str], source: str) -> dict:
    text_for_bounds = (
        source if canon("".join(new)) == canon(source) else "".join(new)
    )
    old_off, _, old_len = boundaries_and_spans(old)
    new_off, _, new_len = boundaries_and_spans(new)
    if old_len != new_len:
        return {
            "status": "source_mismatch",
            "oldLen": old_len,
            "newLen": new_len,
            "addedBoundaries": 0,
            "removedBoundaries": 0,
            "punctBoundaryChanges": 0,
            "nonpunctBoundaryChanges": 0,
        }
    added = sorted(new_off - old_off)
    removed = sorted(old_off - new_off)
    added_punct = sum(1 for off in added if is_punct_boundary(text_for_bounds, off))
    removed_punct = sum(
        1 for off in removed if is_punct_boundary(text_for_bounds, off)
    )
    return {
        "status": "ok",
        "addedBoundaries": len(added),
        "removedBoundaries": len(removed),
        "punctBoundaryChanges": added_punct + removed_punct,
        "nonpunctBoundaryChanges": (len(added) - added_punct)
        + (len(removed) - removed_punct),
    }


def metrics(sentences: list[str]) -> dict:
    counts = [word_count(s) for s in sentences]
    return {
        "count": len(sentences),
        "maxWords": max(counts, default=0),
        "gt20": sum(1 for w in counts if w > 20),
        "gt17": sum(1 for w in counts if w > 17),
        "le16": sum(1 for w in counts if w <= 16),
        "w1to3": sum(1 for w in counts if 1 <= w <= 3),
    }


def load_replay(path: Path) -> tuple[dict, dict[str, dict]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    by_ep = {str(c["episode"]).upper(): c for c in data["chapters"]}
    return data["summary"], by_ep


def db_map(series_id: int, episodes: set[str]) -> dict[str, dict]:
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
    con.close()
    mapped: dict[str, dict] = {}
    for row in rows:
        match = re.search(r"\b(E\d{2})\b", row["title"] or "")
        episode = match.group(1) if match else None
        if episode not in episodes:
            continue
        summary = {}
        try:
            summary = json.loads(row["summary_json"] or "{}")
        except json.JSONDecodeError:
            summary = {}
        migration = summary.get("sentenceMigration") or {}
        sentences = json.loads(row["sentences"] or "[]")
        sentences = [str(s) for s in sentences]
        mapped[episode] = {
            "articleId": int(row["article_id"]),
            "title": row["title"],
            "content": row["content"] or "",
            "sentences": sentences,
            "version": row["sentence_split_version"],
            "migrationSolverVersion": migration.get("solverVersion"),
        }
    return mapped


def change_hunks(old: list[str], new: list[str], source: str) -> list[dict]:
    matcher = SequenceMatcher(a=old, b=new, autojunk=False)
    text_for_bounds = (
        source if canon("".join(new)) == canon(source) else "".join(new)
    )
    old_off, _, _ = boundaries_and_spans(old)
    new_off, _, _ = boundaries_and_spans(new)
    hunks = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        old_span = old[i1:i2]
        new_span = new[j1:j2]
        # Approximate region start/end from full chapter offsets of involved spans.
        region_old_off, region_old_spans, _ = boundaries_and_spans(old)
        region_new_off, region_new_spans, _ = boundaries_and_spans(new)
        if i1 < len(region_old_spans):
            region_start = region_old_spans[i1][0]
        elif j1 < len(region_new_spans):
            region_start = region_new_spans[j1][0]
        else:
            region_start = 0
        if i2 > 0 and i2 - 1 < len(region_old_spans):
            region_end = region_old_spans[i2 - 1][1]
        elif j2 > 0 and j2 - 1 < len(region_new_spans):
            region_end = region_new_spans[j2 - 1][1]
        else:
            region_end = region_start
        local_old = {off for off in old_off if region_start < off < region_end}
        local_new = {off for off in new_off if region_start < off < region_end}
        added = local_new - local_old
        removed = local_old - local_new
        changed = added | removed
        nonpunct = sum(
            1 for off in changed if not is_punct_boundary(text_for_bounds, off)
        )
        kind = "nonpunct" if nonpunct else "punct"
        hunks.append(
            {
                "tag": tag,
                "kind": kind,
                "old": old_span,
                "new": new_span,
                "oldWordCounts": [word_count(s) for s in old_span],
                "newWordCounts": [word_count(s) for s in new_span],
                "oldMax": max((word_count(s) for s in old_span), default=0),
                "newMax": max((word_count(s) for s in new_span), default=0),
                "addedBoundaries": len(added),
                "removedBoundaries": len(removed),
                "nonpunctBoundaryChanges": nonpunct,
            }
        )
    return hunks


def write_book(
    book: str,
    episodes: list[str],
    dbm: dict[str, dict],
    neu: dict[str, dict],
    nsum: dict,
) -> dict:
    book_dir = OUT / "manual-review" / book.lower()
    book_dir.mkdir(parents=True, exist_ok=True)
    chapters_md: list[str] = []
    book_stats = {
        "changedChapters": 0,
        "sentenceDelta": 0,
        "hunkKinds": Counter(),
        "boundaryKinds": Counter(),
        "chapters": [],
    }

    for ep in episodes:
        if ep not in dbm:
            chapters_md.append(f"## {ep}\n\n**缺失 DB 映射**\n")
            continue
        if ep not in neu:
            chapters_md.append(f"## {ep}\n\n**缺失 V3.9 replay**\n")
            continue

        old = dbm[ep]["sentences"]
        new = list(neu[ep]["v3LocalSentences"])
        source = neu[ep].get("source") or dbm[ep]["content"]
        hs = change_hunks(old, new, source)
        boundary = classify_boundaries(old, new, source)
        om = metrics(old)
        nm = metrics(new)
        if hs:
            book_stats["changedChapters"] += 1
        book_stats["sentenceDelta"] += nm["count"] - om["count"]
        for hunk in hs:
            book_stats["hunkKinds"][hunk["kind"]] += 1
        book_stats["boundaryKinds"]["punct"] += boundary.get(
            "punctBoundaryChanges", 0
        )
        book_stats["boundaryKinds"]["nonpunct"] += boundary.get(
            "nonpunctBoundaryChanges", 0
        )

        ch_rec = {
            "episode": ep,
            "why": WHY[book][ep],
            "articleId": dbm[ep]["articleId"],
            "dbVersion": dbm[ep]["version"],
            "migrationSolverVersion": dbm[ep]["migrationSolverVersion"],
            "old": om,
            "new": nm,
            "hunkCount": len(hs),
            "nonpunctHunks": sum(1 for h in hs if h["kind"] == "nonpunct"),
            "punctHunks": sum(1 for h in hs if h["kind"] == "punct"),
            "boundary": boundary,
        }
        book_stats["chapters"].append(ch_rec)

        lines = [
            f"# {book} {ep}",
            "",
            f"- 选取原因：{WHY[book][ep]}",
            f"- DB articleId：{dbm[ep]['articleId']}",
            f"- DB sentence_split_version：`{dbm[ep]['version']}`",
            f"- migration solver：`{dbm[ep]['migrationSolverVersion']}`",
            "- 新算法：`syntax_solver_v3_9`",
            (
                f"- 边界变化：+{boundary.get('addedBoundaries', 0)} / "
                f"-{boundary.get('removedBoundaries', 0)}; "
                f"punct={boundary.get('punctBoundaryChanges', 0)}; "
                f"nonpunct={boundary.get('nonpunctBoundaryChanges', 0)}; "
                f"status={boundary.get('status')}"
            ),
            "",
            "## 规模",
            "",
            "| | DB | V3.9 |",
            "|---|---:|---:|",
            f"| 句段数 | {om['count']} | {nm['count']} |",
            f"| 最大词数 | {om['maxWords']} | {nm['maxWords']} |",
            f"| >20 词块 | {om['gt20']} | {nm['gt20']} |",
            f"| >17 词块 | {om['gt17']} | {nm['gt17']} |",
            f"| ≤16 词块 | {om['le16']} | {nm['le16']} |",
            f"| 1–3 词块 | {om['w1to3']} | {nm['w1to3']} |",
            "",
            f"## 差异块（{len(hs)}）",
            "",
        ]
        if not hs:
            lines.append("_无边界差异（句段序列一致）。_")
        for index, hunk in enumerate(hs, 1):
            lines.extend(
                [
                    f"### H{index:03d} · {hunk['kind']} · {hunk['tag']}",
                    "",
                    f"- 旧词数：{hunk['oldWordCounts']}（max {hunk['oldMax']}）",
                    f"- 新词数：{hunk['newWordCounts']}（max {hunk['newMax']}）",
                    "",
                    "**DB**",
                ]
            )
            for sentence in hunk["old"]:
                lines.append(f"- ({word_count(sentence)}) {sentence}")
            lines.extend(["", "**V3.9**"])
            for sentence in hunk["new"]:
                lines.append(f"- ({word_count(sentence)}) {sentence}")
            lines.append("")
        (book_dir / f"{ep}.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

        chapters_md.append(
            "\n".join(
                [
                    f"## {ep} — {WHY[book][ep]}",
                    "",
                    f"- DB {om['count']} → V3.9 {nm['count']}（Δ{nm['count'] - om['count']:+d}）",
                    (
                        f"- maxWords {om['maxWords']} → {nm['maxWords']}; "
                        f">20: {om['gt20']}→{nm['gt20']}; "
                        f"非标点hunk {ch_rec['nonpunctHunks']}; "
                        f"标点hunk {ch_rec['punctHunks']}; "
                        f"边界 nonpunct={boundary.get('nonpunctBoundaryChanges', 0)} "
                        f"punct={boundary.get('punctBoundaryChanges', 0)}"
                    ),
                    f"- 详见 [`{ep}.md`](./{ep}.md)",
                    "",
                ]
            )
        )

    checklist = [
        f"# {book} · V3.9 初步评审（10章）",
        "",
        f"- 生成时间：{datetime.now(timezone.utc).isoformat()}",
        "- 新算法：`syntax_solver_v3_9`（live replay）",
        "- 基线：本机 DB `articles.sentences`",
        f"- 变化章节：{book_stats['changedChapters']}/10",
        f"- 句段净增：{book_stats['sentenceDelta']:+d}",
        (
            f"- hunk：nonpunct={book_stats['hunkKinds']['nonpunct']}, "
            f"punct={book_stats['hunkKinds']['punct']}"
        ),
        (
            f"- 边界：nonpunct={book_stats['boundaryKinds']['nonpunct']}, "
            f"punct={book_stats['boundaryKinds']['punct']}"
        ),
        "",
        *chapters_md,
    ]
    (book_dir / "CHECKLIST.md").write_text("\n".join(checklist) + "\n", encoding="utf-8")
    return {
        "episodes": episodes,
        "replaySummary": nsum,
        "changedChapters": book_stats["changedChapters"],
        "sentenceDelta": book_stats["sentenceDelta"],
        "hunkKinds": dict(book_stats["hunkKinds"]),
        "boundaryKinds": dict(book_stats["boundaryKinds"]),
        "chapters": book_stats["chapters"],
    }


def main() -> None:
    alice_sum, alice_new = load_replay(OUT / "alice-v3_9-replay-10.json")
    willows_sum, willows_new = load_replay(OUT / "willows-v3_9-replay-10.json")
    if alice_sum.get("solverVersion") != "syntax_solver_v3_9":
        raise SystemExit(f"Alice replay not v3_9: {alice_sum}")
    if willows_sum.get("solverVersion") != "syntax_solver_v3_9":
        raise SystemExit(f"Willows replay not v3_9: {willows_sum}")

    alice_db = db_map(SERIES["Alice"], set(ALICE_EPS))
    willows_db = db_map(SERIES["Willows"], set(WILLOWS_EPS))
    print("Alice DB", sorted(alice_db))
    print("Willows DB", sorted(willows_db))
    missing_a = [ep for ep in ALICE_EPS if ep not in alice_db]
    missing_w = [ep for ep in WILLOWS_EPS if ep not in willows_db]
    if missing_a or missing_w:
        raise SystemExit(f"DB missing Alice={missing_a} Willows={missing_w}")

    summary = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "solverVersion": "syntax_solver_v3_9",
        "baseline": "articles.sentences in english_love.db",
        "mode": "preliminary_10x10_live_replay",
        "books": {
            "Alice": write_book("Alice", ALICE_EPS, alice_db, alice_new, alice_sum),
            "Willows": write_book(
                "Willows", WILLOWS_EPS, willows_db, willows_new, willows_sum
            ),
        },
    }
    (OUT / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    (OUT / "README.md").write_text(
        "\n".join(
            [
                "# V3.9 两书各10章初步评审",
                "",
                "- 新算法：`syntax_solver_v3_9`（`replay_read_aloud_report.dart` 现场回放）",
                "- 基线：DB `english_love.db` 的 `articles.sentences`",
                f"- Alice：{', '.join(ALICE_EPS)}",
                f"- Willows：{', '.join(WILLOWS_EPS)}",
                "",
                "## 入口",
                "",
                "- [Alice CHECKLIST](manual-review/alice/CHECKLIST.md)",
                "- [Willows CHECKLIST](manual-review/willows/CHECKLIST.md)",
                "- [summary.json](summary.json)",
                "",
                "## 机器产物",
                "",
                "- `alice-v3_9-replay-10.json` / `willows-v3_9-replay-10.json`",
                "- 冻结输入：`alice-frozen-10.json` / `willows-frozen-10.json`",
                "",
            ]
        ),
        encoding="utf-8",
    )
    for book, payload in summary["books"].items():
        print(
            book,
            "changed",
            payload["changedChapters"],
            "delta",
            payload["sentenceDelta"],
            "hunks",
            payload["hunkKinds"],
        )
    print("OUT", OUT)


if __name__ == "__main__":
    main()
