#!/usr/bin/env python3
"""Estimate which NEW segments need TTS retake after adopting current splitter.

Baseline: DB articles.sentences (Alice=23, Willows=30).
Candidate: attempt-g full-book replay (syntax_solver_v3_9).

Recovery model (user):
- Exact text / exact span → reuse TTS.
- Concatenate consecutive DB clips → merge audio.
- Trim a DB clip only at punctuation/delimiter edges, then optionally
  merge neighbors → punct/ASR cut + merge (no TTS).
- Only when a needed trim lands on an *unpunctuated* interior offset,
  or coverage is impossible → retake TTS.

Read-only.
"""

from __future__ import annotations

import json
import re
import sqlite3
from collections import Counter
from pathlib import Path

ROOT = Path(r"F:/TomatoEnglishHappyTalking")
OUT = ROOT / "output/sentence-split-v3/attempt-g-20260816/tts-retake-vs-db"
DB = (
    ROOT
    / "release/windows/tomato_english_happy_talking"
    / ".dart_tool/sqflite_common_ffi/databases/english_love.db"
)
REPLAY = {
    "Alice": OUT.parent / "alice-current-full-replay.json",
    "Willows": OUT.parent / "willows-current-full-replay.json",
}
SERIES = {"Alice": 23, "Willows": 30}
SPACE = re.compile(r"\s+")
WORD = re.compile(r"[A-Za-z0-9]+(?:['’-][A-Za-z0-9]+)*")
PAUSE = set(";:—–,.!?")
QUOTE = set("\"'“”‘’")
CLOSERS = QUOTE | set(")]}")


def canon(text: str) -> str:
    return SPACE.sub("", text)


def norm_text(text: str) -> str:
    return SPACE.sub(" ", text.strip())


def words(text: str) -> list[str]:
    return WORD.findall(text)


def left_ends_punct(text: str) -> bool:
    body = text.rstrip()
    if not body:
        return False
    if body[-1] in CLOSERS:
        return True
    while body and body[-1] in CLOSERS:
        body = body[:-1].rstrip()
    return bool(body and body[-1] in PAUSE)


def spans(sentences: list[str]) -> list[tuple[int, int, str]]:
    out: list[tuple[int, int, str]] = []
    cursor = 0
    for sentence in sentences:
        end = cursor + len(canon(sentence))
        out.append((cursor, end, sentence))
        cursor = end
    return out


def take_canon_prefix(text: str, canon_len: int) -> str:
    """Prefix of text whose canon() length is exactly canon_len."""
    if canon_len <= 0:
        return ""
    built = []
    n = 0
    for ch in text:
        if not ch.isspace():
            if n >= canon_len:
                break
            n += 1
        built.append(ch)
        if n >= canon_len and not ch.isspace():
            # include trailing spaces after reaching length? keep as-is
            pass
    # Ensure exact: may need to stop when n hits canon_len
    out = []
    n = 0
    for ch in text:
        if ch.isspace():
            if n == 0:
                continue
            if n >= canon_len:
                break
            out.append(ch)
            continue
        if n >= canon_len:
            break
        out.append(ch)
        n += 1
    return "".join(out)


def punct_trim_ok(text: str, span_start: int, trim_at: int) -> bool:
    """True if absolute canon offset trim_at is a punct edge inside this span."""
    if trim_at <= span_start:
        return True
    left = take_canon_prefix(text, trim_at - span_start)
    return left_ends_punct(left)


def db_chapters(series_id: int) -> dict[str, list[str]]:
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


def load_replay(path: Path) -> dict[str, list[str]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    out: dict[str, list[str]] = {}
    for chapter in data["chapters"]:
        ep = str(chapter["episode"]).upper()
        segs: list[str] = []
        for original in chapter.get("originals") or []:
            segs.extend(str(s) for s in (original.get("segments") or []))
        out[ep] = segs
    return out


def recover_new_span(
    ns: int,
    ne: int,
    ntext: str,
    old_spans: list[tuple[int, int, str]],
) -> tuple[str, str, list[int]]:
    """Return (kind, reason, old_indexes) for one new span."""
    # Exact text reuse (TTS cache is text-keyed).
    for oi, (os, oe, otext) in enumerate(old_spans):
        if norm_text(otext) == norm_text(ntext):
            return "reuse_exact", "identical sentence text in DB chapter", [oi]

    # Overlapping consecutive old spans covering [ns,ne] exactly.
    overlapping = [
        i
        for i, (os, oe, _) in enumerate(old_spans)
        if not (oe <= ns or os >= ne)
    ]
    if not overlapping:
        return "retake_tts", "no overlapping DB span", []
    if overlapping != list(range(overlapping[0], overlapping[-1] + 1)):
        return "retake_tts", "non-consecutive DB coverage", overlapping

    first, last = overlapping[0], overlapping[-1]
    os0, oe0, ot0 = old_spans[first]
    os1, oe1, ot1 = old_spans[last]

    if os0 > ns or oe1 < ne:
        return "retake_tts", "DB spans do not cover new span", overlapping
    # First/last may extend outside; middles must be fully inside.
    for mid in overlapping[1:-1] if len(overlapping) > 2 else []:
        ms, me, _ = old_spans[mid]
        if ms < ns or me > ne:
            return "retake_tts", "middle DB span not fully inside new", overlapping

    used_trim = False
    # Left trim of first old span
    if ns > os0:
        if not punct_trim_ok(ot0, os0, ns):
            return (
                "retake_tts",
                f"unpunctuated left trim of DB[{first}]",
                [first],
            )
        used_trim = True
    # Right trim of last old span
    if ne < oe1:
        if not punct_trim_ok(ot1, os1, ne):
            return (
                "retake_tts",
                f"unpunctuated right trim of DB[{last}]",
                [last],
            )
        used_trim = True
    # If first==last and both ends match → exact span
    if first == last and ns == os0 and ne == oe0:
        return "reuse_exact", "identical span", [first]

    if first == last:
        # Pure split piece of one DB sentence
        return (
            "split_punct_audio",
            f"punct/ASR piece of DB[{first}]",
            [first],
        )

    if used_trim:
        return (
            "split_merge_audio",
            f"punct trim + merge DB[{first}..{last}]",
            list(range(first, last + 1)),
        )
    return (
        "merge_audio",
        f"concat DB[{first}..{last}] ({last - first + 1} clips)",
        list(range(first, last + 1)),
    )


def classify_chapter(
    book: str,
    episode: str,
    old_sents: list[str],
    new_sents: list[str],
) -> dict:
    if canon("".join(old_sents)) != canon("".join(new_sents)):
        raise SystemExit(f"canon mismatch {book} {episode}")

    old_spans = spans(old_sents)
    new_spans = spans(new_sents)

    items = []
    counts: Counter[str] = Counter()
    for ni, (ns, ne, ntext) in enumerate(new_spans):
        kind, reason, old_indexes = recover_new_span(ns, ne, ntext, old_spans)
        entry = {
            "book": book,
            "episode": episode,
            "newIndex": ni,
            "text": ntext,
            "wordCount": len(words(ntext)),
            "kind": kind,
            "reason": reason,
            "oldIndexes": old_indexes,
        }
        counts[kind] += 1
        items.append(entry)

    old_cuts = {end for (_, end, _) in old_spans[:-1]} if len(old_spans) > 1 else set()
    new_cuts = {end for (_, end, _) in new_spans[:-1]} if len(new_spans) > 1 else set()
    added = sorted(new_cuts - old_cuts)
    removed = sorted(old_cuts - new_cuts)

    def cut_punct(cut: int, span_list: list[tuple[int, int, str]]) -> bool:
        for _, e, text in span_list:
            if e == cut:
                return left_ends_punct(text)
        return False

    added_punct = sum(1 for c in added if cut_punct(c, new_spans))
    removed_punct = sum(1 for c in removed if cut_punct(c, old_spans))

    return {
        "book": book,
        "episode": episode,
        "oldCount": len(old_sents),
        "newCount": len(new_sents),
        "counts": dict(counts),
        "cuts": {
            "added": len(added),
            "addedPunct": added_punct,
            "addedNonpunct": len(added) - added_punct,
            "removed": len(removed),
            "removedPunct": removed_punct,
            "removedNonpunct": len(removed) - removed_punct,
        },
        "retake": [x for x in items if x["kind"] == "retake_tts"],
        "items": items,
    }


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    book_reports = []
    all_retake = []
    totals: Counter[str] = Counter()
    cut_totals: Counter[str] = Counter()

    for book, series_id in SERIES.items():
        dbm = db_chapters(series_id)
        replay = load_replay(REPLAY[book])
        chapters = []
        for ep in sorted(set(dbm) | set(replay), key=lambda x: (len(x), x)):
            if ep not in dbm or ep not in replay:
                raise SystemExit(f"missing chapter {book} {ep}")
            result = classify_chapter(book, ep, dbm[ep], replay[ep])
            chapters.append(
                {
                    k: result[k]
                    for k in (
                        "book",
                        "episode",
                        "oldCount",
                        "newCount",
                        "counts",
                        "cuts",
                        "retake",
                    )
                }
            )
            for k, v in result["counts"].items():
                totals[k] += v
            for k, v in result["cuts"].items():
                cut_totals[k] += v
            all_retake.extend(result["retake"])
            (OUT / f"{book.lower()}_{ep}.json").write_text(
                json.dumps(result, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
        book_reports.append({"book": book, "chapters": chapters})

    no_tts = (
        totals.get("reuse_exact", 0)
        + totals.get("merge_audio", 0)
        + totals.get("split_punct_audio", 0)
        + totals.get("split_merge_audio", 0)
    )
    new_total = sum(totals.values())
    retake = totals.get("retake_tts", 0)

    summary = {
        "baseline": "DB articles.sentences",
        "candidate": "syntax_solver_v3_9 attempt-g full replay",
        "policy": {
            "reuse_exact": "same text/span → keep TTS",
            "merge_audio": "concat whole DB clips",
            "split_punct_audio": "piece of one DB clip trimmed only at punct edges",
            "split_merge_audio": "punct trim of edge clips + merge neighbors",
            "retake_tts": "needs unpunctuated interior trim → re-synthesize",
        },
        "totals": dict(totals),
        "cutTotals": {
            k: cut_totals[k]
            for k in (
                "added",
                "addedPunct",
                "addedNonpunct",
                "removed",
                "removedPunct",
                "removedNonpunct",
            )
        },
        "retakeCount": retake,
        "recoverableWithoutTts": no_tts,
        "retakePctOfNew": round(100.0 * retake / max(1, new_total), 2),
        "books": book_reports,
        "retakeSamples": all_retake[:100],
    }
    (OUT / "SUMMARY.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    (OUT / "RETAKE_ALL.json").write_text(
        json.dumps(all_retake, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    lines = [
        "# 换用新分句后的 TTS 重做估算（Alice + Willows）",
        "",
        "- 旧分句：DB `articles.sentences`（听力材料实际绑定）",
        "- 新分句：`attempt-g` 全量回放 `syntax_solver_v3_9`",
        "- 口径：带标点切点可用 **合并音频 / ASR·标点切割**；**仅无标点切点上的修剪**才计重做 TTS",
        "",
        "## 新句分类合计",
        "",
        "| 类别 | 句数 | 说明 |",
        "|---|---:|---|",
        f"| `reuse_exact` | {totals.get('reuse_exact', 0)} | 文本与库内相同，直接复用 |",
        f"| `merge_audio` | {totals.get('merge_audio', 0)} | 整段旧句拼接 |",
        f"| `split_punct_audio` | {totals.get('split_punct_audio', 0)} | 单旧句按标点/引号缘切开 |",
        f"| `split_merge_audio` | {totals.get('split_merge_audio', 0)} | 标点修剪边段 + 合并邻句 |",
        f"| **`retake_tts`** | **{retake}** | **需重新 TTS（无标点切点）** |",
        f"| 新句合计 | {new_total} | |",
        "",
        f"**需重做 TTS：** {retake} / {new_total} = "
        f"**{100.0 * retake / max(1, new_total):.1f}%**",
        "",
        f"**无需重做（复用/合并/标点切割）：** {no_tts} / {new_total} = "
        f"**{100.0 * no_tts / max(1, new_total):.1f}%**",
        "",
        "## 切点差分（辅助）",
        "",
        "| 切点 | 数量 |",
        "|---|---:|",
        f"| 新增（标点） | {cut_totals['addedPunct']} |",
        f"| 新增（无标点） | {cut_totals['addedNonpunct']} |",
        f"| 删除（标点） | {cut_totals['removedPunct']} |",
        f"| 删除（无标点） | {cut_totals['removedNonpunct']} |",
        "",
        "删除切点一般靠合并消化；新增无标点切点才会迫使相关新句重做 TTS。",
        "",
        "## 分书",
        "",
    ]
    for book_report in book_reports:
        book = book_report["book"]
        c: Counter[str] = Counter()
        retake_eps = []
        old_n = new_n = 0
        for ch in book_report["chapters"]:
            for k, v in ch["counts"].items():
                c[k] += v
            old_n += ch["oldCount"]
            new_n += ch["newCount"]
            if ch["counts"].get("retake_tts"):
                retake_eps.append(f"{ch['episode']}×{ch['counts']['retake_tts']}")
        lines += [
            f"### {book}",
            "",
            f"- 旧句 {old_n} → 新句 {new_n}",
            f"- 复用 {c.get('reuse_exact', 0)} / 合并 {c.get('merge_audio', 0)} / "
            f"标点切 {c.get('split_punct_audio', 0)} / "
            f"标点切+合并 {c.get('split_merge_audio', 0)} / "
            f"**重做 {c.get('retake_tts', 0)}** "
            f"({100.0 * c.get('retake_tts', 0) / max(1, new_n):.1f}%)",
            f"- 有重做的章数：{len(retake_eps)}；明细：{', '.join(retake_eps)}",
            "",
        ]

    lines += ["## 重做句样例（最多 40）", ""]
    for item in all_retake[:40]:
        preview = SPACE.sub(" ", item["text"]).strip()
        if len(preview) > 120:
            preview = preview[:117] + "..."
        lines.append(
            f"- **{item['book']} {item['episode']}#{item['newIndex']}** "
            f"({item['wordCount']}w) {item['reason']}: {preview}"
        )
    lines += [
        "",
        "## 产物",
        "",
        "- `SUMMARY.json` / `RETAKE_ALL.json`",
        "- 分章：`alice_E*.json` / `willows_E*.json`",
        "- 脚本：`tools/_estimate_tts_retake_vs_db.py`",
        "",
    ]
    (OUT / "README.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(
        f"retake={retake} recoverable={no_tts} new_total={new_total} "
        f"retake%={100.0 * retake / max(1, new_total):.1f}"
    )
    print(dict(totals))
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
