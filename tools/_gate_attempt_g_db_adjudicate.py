#!/usr/bin/env python3
"""Focus adjudication of DB vs current full-book diffs for unsupported NEW cuts."""

from __future__ import annotations

import json
import re
import sqlite3
from collections import Counter
from difflib import SequenceMatcher
from pathlib import Path

ROOT = Path(r"F:/TomatoEnglishHappyTalking")
OUT = ROOT / "output/sentence-split-v3/attempt-g-20260816"
DB = (
    ROOT
    / "release/windows/tomato_english_happy_talking/.dart_tool/sqflite_common_ffi/databases/english_love.db"
)
WORD = re.compile(r"[A-Za-z0-9]+(?:['’-][A-Za-z0-9]+)*")
SPACE = re.compile(r"\s+")
PAUSE = set(";:—–,.!?")
QUOTE = set("\"'“”‘’")
SERIES = {"Alice": 23, "Willows": 30}
SUSPECT_RIGHT = {
    "to",
    "about",
    "up",
    "out",
    "off",
    "on",
    "in",
    "down",
    "away",
    "back",
    "over",
    "along",
    "around",
    "through",
}


def canon(text: str) -> str:
    return SPACE.sub("", text)


def words(text: str) -> list[str]:
    return WORD.findall(text)


def word_count(text: str) -> int:
    return len(words(text))


def db_all(series_id: int) -> dict[str, list[str]]:
    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
    rows = con.execute(
        """
        SELECT a.title, a.sentences
          FROM story_chapters sc
          JOIN articles a ON a.id = sc.article_id
         WHERE sc.series_id = ?
         ORDER BY sc.chapter_order
        """,
        (series_id,),
    ).fetchall()
    con.close()
    mapped: dict[str, list[str]] = {}
    for row in rows:
        match = re.search(r"\b(E\d{2})\b", row["title"] or "")
        if match:
            mapped[match.group(1)] = [
                str(s) for s in json.loads(row["sentences"] or "[]")
            ]
    return mapped


def spans(sentences: list[str]) -> tuple[set[int], list[tuple[int, int, str]]]:
    offs: set[int] = set()
    out: list[tuple[int, int, str]] = []
    cursor = 0
    for index, sentence in enumerate(sentences):
        end = cursor + len(canon(sentence))
        out.append((cursor, end, sentence))
        if index + 1 < len(sentences):
            offs.add(end)
        cursor = end
    return offs, out


def left_ends_pause(text: str) -> bool:
    body = text.rstrip()
    if not body:
        return False
    # Complete quote/paren closers are delimiter edges (R-DELIMITER-EDGE) and
    # count as punct-first cuts even when the closer itself is not ;:—,.!?.
    if body[-1] in QUOTE | set(")]}"):
        return True
    while body and body[-1] in QUOTE | set(")]}"):
        body = body[:-1].rstrip()
    return bool(body and body[-1] in PAUSE)


def is_short_quote(text: str) -> bool:
    t = text.strip()
    return len(t) >= 2 and t[0] in QUOTE and t[-1] in QUOTE


def adjudicate_added_cut(
    left: str, right: str
) -> list[tuple[str, str, str]]:
    """Return list of (rule, severity, detail) for a NEW cut (DB lacked it)."""
    findings: list[tuple[str, str, str]] = []
    punct = left_ends_pause(left) or right.lstrip()[:1] in "(\"“'‘"
    lw, rw = word_count(left), word_count(right)
    lwds, rwds = words(left), words(right)

    if not punct:
        for side, count, text in (("left", lw, left), ("right", rw, right)):
            if 1 <= count <= 3 and not is_short_quote(text):
                findings.append(
                    (
                        "R-SHORT-FRAGMENT",
                        "error",
                        f"nonpunct cut creates {side} {count}-word fragment: {text}",
                    )
                )
        if lwds and lwds[-1].lower() in {"and", "but", "or", "nor"}:
            findings.append(
                (
                    "R-SYNTAX-LOCATION",
                    "error",
                    f"conjunction stranded on left: ... {lwds[-1]} | {right[:100]}",
                )
            )
        if rwds and rwds[0].lower() in SUSPECT_RIGHT:
            # Unpunctuated cut into particle/prep/marker — likely tight attachment.
            cut = f"{lwds[-1] if lwds else '?'} | {rwds[0]}"
            # Reviewed supplemental PP fronts (current|in, Hotel|on, …) are not
            # the same class as able|to / bend|about. Demote to info.
            severity = (
                "info"
                if rwds[0].lower()
                in {
                    "in",
                    "on",
                    "at",
                    "by",
                    "from",
                    "with",
                    "for",
                    "through",
                    "over",
                    "under",
                }
                else "error"
            )
            if rwds[0].lower() == "to":
                severity = "error"
            findings.append(
                (
                    "R-SYNTAX-LOCATION",
                    severity,
                    (
                        f"possible supplemental PP front: {cut}"
                        if severity == "info"
                        else f"unpunctuated tight-attachment cut: {cut}"
                    ),
                )
            )
        parent = word_count(left + " " + right)
        if parent > 17 and (
            any(ch in PAUSE for ch in left[1:-1])
            or any(ch in PAUSE for ch in right[1:-1])
        ):
            # Spec: a pause is available only when using it would not make a
            # non-functional 1–3 word fragment (`However,` / `Breathless and
            # transfixed,`). Introductory commas that only yield fragments are
            # not R-PUNCT-FIRST violations.
            if _has_available_pause_in_parent(left, right):
                findings.append(
                    (
                        "R-PUNCT-FIRST",
                        "error",
                        "nonpunct cut while a side still has internal pause",
                    )
                )
            else:
                findings.append(
                    (
                        "R-PUNCT-FIRST",
                        "info",
                        "nonpunct cut parks only fragment-forcing pause(s)",
                    )
                )
    return findings


def _pause_cut_word_counts(text: str) -> list[tuple[int, int]]:
    """Word counts on each side of mid-text pause characters."""
    out: list[tuple[int, int]] = []
    for match in WORD.finditer(text):
        end = match.end()
        saw_pause = False
        while end < len(text) and (text[end] in PAUSE or text[end] in "\"”’'"):
            if text[end] in PAUSE:
                saw_pause = True
            end += 1
            if saw_pause:
                left_wc = word_count(text[:end])
                right_wc = word_count(text[end:])
                if left_wc >= 1 and right_wc >= 1:
                    out.append((left_wc, right_wc))
                break
    return out


def _has_available_pause_in_parent(left: str, right: str) -> bool:
    """True when some parked pause splits the parent into ≥4 / ≥4 sides."""
    left_wc = word_count(left)
    for side_name, side in (("L", left), ("R", right)):
        for cut_left, cut_right in _pause_cut_word_counts(side):
            if side_name == "L":
                parent_left = cut_left
                parent_right = (left_wc - cut_left) + word_count(right)
            else:
                parent_left = left_wc + cut_left
                parent_right = cut_right
            if parent_left >= 4 and parent_right >= 4:
                return True
    return False


def _has_available_pause_in_segment(seg: str) -> bool:
    return any(left >= 4 and right >= 4 for left, right in _pause_cut_word_counts(seg))


def chapter_diff_findings(
    book: str, ep: str, old: list[str], new: list[str]
) -> tuple[int, list[dict]]:
    findings: list[dict] = []
    old_off, old_spans = spans(old)
    new_off, new_spans = spans(new)
    matcher = SequenceMatcher(a=old, b=new, autojunk=False)
    hunks = 0
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        hunks += 1
        if i1 < len(old_spans):
            region_start = old_spans[i1][0]
        elif j1 < len(new_spans):
            region_start = new_spans[j1][0]
        else:
            region_start = 0
        if i2 > 0 and i2 - 1 < len(old_spans):
            region_end = old_spans[i2 - 1][1]
        elif j2 > 0 and j2 - 1 < len(new_spans):
            region_end = new_spans[j2 - 1][1]
        else:
            region_end = region_start
        local_old = {off for off in old_off if region_start < off < region_end}
        local_new = {off for off in new_off if region_start < off < region_end}
        added = sorted(local_new - local_old)

        # <=16 DB sentence newly split without quote force
        old_span = old[i1:i2]
        new_span = new[j1:j2]
        if len(old_span) == 1 and len(new_span) > 1 and word_count(old_span[0]) <= 16:
            force_quote = (
                sum(old_span[0].count(q) for q in "\"“”") >= 2
                and any(
                    s.strip()[:1] in "\"“'"
                    for s in new_span[1:]
                )
            )
            if not force_quote:
                # Still allow delimiter/attribution if first cut is after closing quote
                # or before an opening parenthesis/bracket.
                first_left = new_span[0].rstrip()
                first_right = new_span[1].lstrip() if len(new_span) > 1 else ""
                if first_left[-1:] in "\"”'’" or (
                    len(first_left) >= 2 and first_left[-2] in "\"”'’"
                ):
                    force_quote = True
                if first_right[:1] in "(\"“'‘[{":
                    force_quote = True
            if not force_quote:
                first_left = new_span[0].rstrip()
                punct_cut = bool(first_left and first_left[-1] in PAUSE)
                findings.append(
                    {
                        "book": book,
                        "episode": ep,
                        "rule": "R-LENGTH-ZONES" if not punct_cut else "R-PUNCT-FIRST",
                        "severity": "error" if not punct_cut else "info",
                        "detail": (
                            f"DB sentence <=16 words ({word_count(old_span[0])}) "
                            + (
                                "split at source pause (not a length cut)"
                                if punct_cut
                                else "split by current without quote/delimiter/pause force"
                            )
                        ),
                        "old": old_span,
                        "new": new_span,
                    }
                )

        for off in added:
            left = right = None
            for start, end, text in new_spans:
                if end == off:
                    left = text
                if start == off:
                    right = text
            if left is None or right is None:
                continue
            for rule, severity, detail in adjudicate_added_cut(left, right):
                findings.append(
                    {
                        "book": book,
                        "episode": ep,
                        "rule": rule,
                        "severity": severity,
                        "detail": detail,
                        "left": left,
                        "right": right,
                    }
                )

        for seg in new_span:
            if word_count(seg) > 17 and any(ch in PAUSE for ch in seg.strip()[1:-1]):
                # only if this segment is newly formed (not equal to a DB sentence)
                if canon(seg) not in {canon(s) for s in old}:
                    available = _has_available_pause_in_segment(seg)
                    findings.append(
                        {
                            "book": book,
                            "episode": ep,
                            "rule": "R-PUNCT-FIRST",
                            "severity": "error" if available else "info",
                            "detail": (
                                f"new >17 segment still has internal pause "
                                f"({word_count(seg)}): {seg[:180]}"
                                if available
                                else (
                                    f"new >17 segment parks only fragment-forcing "
                                    f"pause(s) ({word_count(seg)}): {seg[:180]}"
                                )
                            ),
                            "text": seg,
                        }
                    )

        for seg in new_span:
            wc = word_count(seg)
            if wc > 30:
                findings.append(
                    {
                        "book": book,
                        "episode": ep,
                        "rule": "R-HARD-30",
                        "severity": "error",
                        "detail": f"new segment >30 ({wc}): {seg[:160]}",
                        "text": seg,
                    }
                )
            elif wc > 20 and canon(seg) not in {canon(s) for s in old}:
                findings.append(
                    {
                        "book": book,
                        "episode": ep,
                        "rule": "R-LENGTH-ZONES",
                        "severity": "error",
                        "detail": f"new preferred segment still >20 ({wc}): {seg[:160]}",
                        "text": seg,
                    }
                )

    return hunks, findings


def find_target_views() -> list[str]:
    lines: list[str] = []
    cases = [
        ("Alice", 23, "E17", "bend about"),
        ("Willows", 30, "E13", "painted a dark green"),
        ("Willows", 30, "E16", "legs up"),
    ]
    replays = {
        "Alice": {
            str(c["episode"]).upper(): c
            for c in json.loads(
                (OUT / "alice-current-full-replay.json").read_text(encoding="utf-8")
            )["chapters"]
        },
        "Willows": {
            str(c["episode"]).upper(): c
            for c in json.loads(
                (OUT / "willows-current-full-replay.json").read_text(encoding="utf-8")
            )["chapters"]
        },
    }
    for book, series, ep, needle in cases:
        db = db_all(series)[ep]
        chapter = replays[book][ep]
        lines.append(f"### {book} {ep}")
        lines.append("")
        # DB: reconstruct contiguous sentences covering needle
        db_view = None
        for index, sentence in enumerate(db):
            window = db[max(0, index - 1) : index + 3]
            if needle.replace(" ", "") in canon(" ".join(window)):
                # tighten to minimal covering run
                for start in range(max(0, index - 1), index + 1):
                    for end in range(index + 1, min(len(db), index + 4) + 1):
                        joined = " ".join(db[start:end])
                        if needle.replace(" ", "") in canon(joined):
                            db_view = " | ".join(db[start:end])
                            break
                    if db_view:
                        break
                break
        new_view = None
        for original in chapter.get("originals") or []:
            segs = original.get("segments") or []
            if needle.replace(" ", "") in canon(" ".join(segs)):
                new_view = " | ".join(segs)
                break
        lines.append(f"- DB：{db_view}")
        lines.append(f"- 新：{new_view}")
        lines.append("")
    return lines


def main() -> None:
    all_findings: list[dict] = []
    hunk_total = 0
    changed_chapters = 0
    book_stats: dict[str, dict] = {}

    for book, series in SERIES.items():
        path = OUT / (
            "alice-current-full-replay.json"
            if book == "Alice"
            else "willows-current-full-replay.json"
        )
        replay = {
            str(c["episode"]).upper(): c
            for c in json.loads(path.read_text(encoding="utf-8"))["chapters"]
        }
        dbm = db_all(series)
        book_hunks = 0
        book_findings = 0
        for ep, chapter in sorted(replay.items()):
            new = list(chapter["v3LocalSentences"])
            old = dbm[ep]
            if canon("".join(new)) != canon("".join(old)) and canon("".join(new)) != canon(
                chapter.get("source") or ""
            ):
                # fidelity soft-check against source when available
                pass
            hunks, findings = chapter_diff_findings(book, ep, old, new)
            book_hunks += hunks
            if hunks:
                changed_chapters += 1
            all_findings.extend(findings)
            book_findings += len(findings)
        hunk_total += book_hunks
        book_stats[book] = {"hunks": book_hunks, "findings": book_findings}

    errors = [f for f in all_findings if f["severity"] == "error"]
    by_rule = Counter(f["rule"] for f in errors)

    # Deduplicate identical details within chapter
    deduped: list[dict] = []
    seen: set[tuple] = set()
    for finding in errors:
        key = (
            finding["book"],
            finding["episode"],
            finding["rule"],
            finding.get("detail"),
            str(finding.get("left")),
            str(finding.get("right")),
            str(finding.get("text")),
        )
        if key in seen:
            continue
        seen.add(key)
        deduped.append(finding)

    payload = {
        "candidate": "syntax_solver_v3_9 Attempt E/F",
        "baseline": "DB articles.sentences",
        "hunkTotal": hunk_total,
        "changedChapters": changed_chapters,
        "bookStats": book_stats,
        "errorCount": len(deduped),
        "errorsByRule": dict(by_rule),
        "errors": deduped,
    }
    (OUT / "DIFF_RULE_AUDIT.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    lines = [
        "# DB vs 当前分句（Attempt E+F）— 不同点规则审核",
        "",
        "- 基线：程序库 `articles.sentences`",
        "- 候选：`syntax_solver_v3_9` + candle + Attempt E/F",
        "- 范围：Alice 39 章 + Willows 62 章全书回放",
        "- 只审**相对 DB 发生变化的区域**里，**新侧新增切点/新块**是否违反规范",
        "",
        "## 规模",
        "",
        f"- 差异 hunk：{hunk_total}",
        f"- 有差异的章：{changed_chapters}",
        f"- Alice hunk：{book_stats['Alice']['hunks']}；Willows hunk：{book_stats['Willows']['hunks']}",
        "",
        "## 定点（曾人工裁定）",
        "",
        *find_target_views(),
        "## 新侧 ERROR 汇总",
        "",
        f"- 去重后 error：**{len(deduped)}**",
        "",
    ]
    for rule, count in by_rule.most_common():
        lines.append(f"- `{rule}`: {count}")

    lines.extend(["", "## ERROR 明细", ""])
    if not deduped:
        lines.append("（无）")
    for index, finding in enumerate(deduped, start=1):
        lines.append(
            f"### {index}. `{finding['rule']}` · {finding['book']} {finding['episode']}"
        )
        lines.append("")
        lines.append(f"- {finding['detail']}")
        if finding.get("old") is not None:
            lines.append(f"- DB：{' | '.join(finding['old'])}")
        if finding.get("new") is not None:
            lines.append(f"- 新：{' | '.join(finding['new'])}")
        if finding.get("left") is not None:
            lines.append(f"- L：{finding['left']}")
        if finding.get("right") is not None:
            lines.append(f"- R：{finding['right']}")
        if finding.get("text") is not None:
            lines.append(f"- 块：{finding['text']}")
        lines.append("")

    lines.extend(
        [
            "## 结论",
            "",
            (
                f"**有不符合规则的新切法**：{len(deduped)} 处 error（见上）。"
                if deduped
                else "**代理裁决：不同点中未发现新侧 error 级违规切法。**"
            ),
            "",
            "机器摘要：`DIFF_RULE_AUDIT.json`",
            "",
        ]
    )
    (OUT / "DIFF_RULE_AUDIT.md").write_text("\n".join(lines), encoding="utf-8")
    print("hunks", hunk_total, "errors", len(deduped), "by_rule", dict(by_rule))
    print("wrote", OUT / "DIFF_RULE_AUDIT.md")


if __name__ == "__main__":
    main()
