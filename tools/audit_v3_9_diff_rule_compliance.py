#!/usr/bin/env python3
"""Rule audit of DB→V3.9 split differences for the 20 prelim chapters.

Judges only against docs/read_aloud_sentence_split_spec.md rule IDs.
Read-only.
"""

from __future__ import annotations

import json
import re
import sqlite3
from collections import Counter
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
PAUSE = set(";:—–,.!?")
QUOTE = set("\"'“”‘’")
SERIES = {"Alice": 23, "Willows": 30}
BOOK_EPS = {
    "Alice": [
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
    ],
    "Willows": [
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
    ],
}


def canon(text: str) -> str:
    return SPACE_RE.sub("", text)


def words(text: str) -> list[str]:
    return WORD_RE.findall(text)


def word_count(text: str) -> int:
    return len(words(text))


def is_short_quote(text: str) -> bool:
    t = text.strip()
    if len(t) < 2:
        return False
    return t[0] in QUOTE and t[-1] in QUOTE


def has_internal_pause(text: str) -> bool:
    # Visible pause punctuation not at the very end (ignore trailing closers).
    body = text.rstrip()
    if not body:
        return False
    i = len(body) - 1
    while i >= 0 and (
        body[i].isspace()
        or body[i] in QUOTE
        or body[i] in PAUSE
        or body[i] in ")]}"
    ):
        i -= 1
    scan = body[: i + 1]
    return any(ch in PAUSE or ch in "()[]" for ch in scan)


def pause_inside_outside_parens(text: str) -> bool:
    """True if pause exists outside (...) spans (approx depth scan)."""
    depth = 0
    body = text.rstrip()
    i = len(body) - 1
    while i >= 0 and (
        body[i].isspace()
        or body[i] in QUOTE
        or body[i] in PAUSE
        or body[i] in ")]}"
    ):
        i -= 1
    for ch in body[: i + 1]:
        if ch == "(":
            depth += 1
        elif ch == ")" and depth:
            depth -= 1
        elif depth == 0 and (ch in PAUSE or ch in "—–"):
            return True
    return False


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


def char_before(source: str, off: int) -> str | None:
    n = 0
    last = None
    for ch in source:
        if not ch.isspace():
            n += 1
            last = ch
            if n == off:
                return last
    return last


def is_punct_boundary(source: str, off: int) -> bool:
    ch = char_before(source, off)
    return bool(ch) and (ch in PAUSE or ch in QUOTE or ch in ")]}")


def db_map(series_id: int, episodes: set[str]) -> dict[str, dict]:
    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
    rows = con.execute(
        """
        SELECT a.id AS article_id, a.title, a.sentences, a.content, sc.summary_json
          FROM story_chapters sc
          JOIN articles a ON a.id = sc.article_id
         WHERE sc.series_id = ?
         ORDER BY sc.chapter_order
        """,
        (series_id,),
    ).fetchall()
    con.close()
    mapped = {}
    for row in rows:
        m = re.search(r"\b(E\d{2})\b", row["title"] or "")
        if not m or m.group(1) not in episodes:
            continue
        mapped[m.group(1)] = {
            "articleId": int(row["article_id"]),
            "sentences": [str(s) for s in json.loads(row["sentences"] or "[]")],
            "content": row["content"] or "",
        }
    return mapped


def load_replay(path: Path):
    data = json.loads(path.read_text(encoding="utf-8"))
    return {str(c["episode"]).upper(): c for c in data["chapters"]}


def left_right_at_cut(segments: list[str], cut_index: int) -> tuple[str, str]:
    # cut_index is after segment cut_index (0-based boundary between segments)
    return segments[cut_index], segments[cut_index + 1]


def audit_chapter(book: str, ep: str, old: list[str], chapter: dict) -> dict:
    new = list(chapter["v3LocalSentences"])
    source = chapter.get("source") or "".join(new)
    findings: list[dict] = []
    stats = Counter()

    # Global output checks on V3.9 chapter result
    if canon("".join(new)) != canon(source) and canon("".join(new)) != canon(
        "".join(old)
    ):
        # Prefer source if present
        if canon("".join(new)) != canon(source):
            findings.append(
                {
                    "severity": "R-FIDELITY",
                    "severity": "error",
                    "where": f"{book}/{ep}",
                    "detail": "V3.9 sentences do not round-trip to chapter source",
                }
            )

    for i, seg in enumerate(new):
        wc = word_count(seg)
        if wc > 30:
            findings.append(
                {
                    "rule": "R-HARD-30",
                    "severity": "error",
                    "where": f"{book}/{ep}#{i}",
                    "detail": "segment has " + str(wc) + " words: " + seg[:120],
                }
            )
        elif wc > 20:
            findings.append(
                {
                    "rule": "R-LENGTH-ZONES",
                    "severity": "error",
                    "where": f"{book}/{ep}#{i}",
                    "detail": "preferred segment still >20 words (" + str(wc) + "): " + seg[:160],
                }
            )
        if wc == 1 and canon(source) != canon(seg):
            findings.append(
                {
                    "rule": "R-SHORT-FRAGMENT",
                    "severity": "error",
                    "where": f"{book}/{ep}#{i}",
                    "detail": f"1-word slot: {seg}",
                }
            )
        if 1 <= wc <= 3 and not is_short_quote(seg):
            # May still be functional (imperative etc.); mark for review unless
            # it is an unchanged DB sentence (not introduced by the diff).
            if canon(seg) not in {canon(s) for s in old}:
                findings.append(
                    {
                        "rule": "R-SHORT-FRAGMENT",
                        "severity": "warn",
                        "where": f"{book}/{ep}#{i}",
                        "detail": f"new 1–3 word non-quote segment ({wc}): {seg}",
                        "text": seg,
                    }
                )

    # Original-level decision checks (preferred path)
    for original in chapter.get("originals") or []:
        segs = list(original.get("segments") or [])
        wcs = [word_count(s) for s in segs]
        ow = word_count(original.get("original") or "")
        for bi, b in enumerate(original.get("boundaries") or []):
            kind = str(b.get("kind") or "")
            if kind == "emergency" or b.get("isEmergency"):
                findings.append(
                    {
                        "rule": "R-SYNTAX-LOCATION",
                        "severity": "error",
                        "where": f"{book}/{ep}/O{original.get('originalIndex')}",
                        "detail": "emergency boundary afterWord=" + str(b.get("afterWord")) + ": " + (original.get("original") or "")[:160],
                    }
                )
            reasons = [str(x) for x in (b.get("reasons") or [])]
            if any("emergency" in r.lower() for r in reasons):
                findings.append(
                    {
                        "rule": "R-SYNTAX-LOCATION",
                        "severity": "error",
                        "where": f"{book}/{ep}/O{original.get('originalIndex')}",
                        "detail": f"emergency-tagged reasons {reasons}",
                    }
                )

        # >17 with internal pause should not remain as a single preferred segment
        for si, seg in enumerate(segs):
            wc = word_count(seg)
            if wc > 17 and has_internal_pause(seg):
                findings.append(
                    {
                        "rule": "R-PUNCT-FIRST",
                        "severity": "error",
                        "where": f"{book}/{ep}/O{original.get('originalIndex')}#{si}",
                        "detail": ">17 segment still has internal pause (" + str(wc) + "): " + seg[:180],
                    }
                )

        # <=16 original should not be length-split into multiple segments
        if ow <= 16 and len(segs) > 1:
            # Allowed if delimiter/quote rules force; still flag for human if no punct kinds
            kinds = [str(b.get("kind") or "") for b in (original.get("boundaries") or [])]
            punctish = {
                "strongPunctuation",
                "clauseComma",
                "phraseComma",
                "delimiterOpen",
                "delimiterClose",
                "quoteEdge",
            }
            if not any(k in punctish for k in kinds):
                findings.append(
                    {
                        "rule": "R-LENGTH-ZONES",
                        "severity": "warn",
                        "where": f"{book}/{ep}/O{original.get('originalIndex')}",
                        "detail": f"<=16 original ({ow}) split without punct/delimiter boundary kinds {kinds}: {segs}",
                    }
                )

    # Diff hunks: inspect newly introduced cuts
    matcher = SequenceMatcher(a=old, b=new, autojunk=False)
    old_off, old_spans, _ = boundaries_and_spans(old)
    new_off, new_spans, new_len = boundaries_and_spans(new)
    text_for_bounds = source if canon("".join(new)) == canon(source) else "".join(new)

    hunk_index = 0
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        hunk_index += 1
        old_span = old[i1:i2]
        new_span = new[j1:j2]
        stats["hunks"] += 1

        # Region bounds
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
        removed = sorted(local_old - local_new)

        # Single DB sentence <=16 split into multiple: length-zone over-split
        # unless quote/delimiter structure clearly forces it.
        if len(old_span) == 1 and len(new_span) > 1:
            ow = word_count(old_span[0])
            if ow <= 16:
                joined_new = " ".join(new_span)
                force_quote = (
                    old_span[0].count('"') + old_span[0].count("“") + old_span[0].count("”")
                    >= 2
                    and any(
                        s.strip().startswith('"')
                        or s.strip().startswith("“")
                        or s.strip().startswith("'")
                        for s in new_span[1:]
                    )
                )
                severity = "warn" if force_quote else "error"
                findings.append(
                    {
                        "rule": "R-LENGTH-ZONES",
                        "severity": severity,
                        "where": f"{book}/{ep}/H{hunk_index:03d}",
                        "detail": (
                            "DB sentence <=16 words ("
                            + str(ow)
                            + ") was split by V3.9"
                            + (" (possible quote-structure)" if force_quote else "")
                        ),
                        "old": old_span,
                        "new": new_span,
                    }
                )
                stats["split_le16"] += 1

        for off in added:
            punct = is_punct_boundary(text_for_bounds, off)
            # Delimiter/quote edges: opener may sit on the right span start.
            left = right = None
            for ns, ne, nt in new_spans:
                if ne == off:
                    left = nt
                if ns == off:
                    right = nt
            if right is not None:
                rs = right.lstrip()
                if rs[:1] in "(\"“'‘":
                    punct = True
            if left is not None:
                ls = left.rstrip()
                if ls[-1:] in ")\"”'’" or (
                    len(ls) >= 2 and ls[-1] in PAUSE and ls[-2] in ")\"”'’"
                ):
                    punct = True
            stats["added_punct" if punct else "added_nonpunct"] += 1
            if left is None or right is None:
                continue
            lw, rw = word_count(left), word_count(right)
            # Nonpunct cut that creates 1-3 non-quote fragment
            if not punct:
                for side, sw, st in (("left", lw, left), ("right", rw, right)):
                    if 1 <= sw <= 3 and not is_short_quote(st):
                        findings.append(
                            {
                                "rule": "R-SHORT-FRAGMENT",
                                "severity": "error",
                                "where": f"{book}/{ep}/H{hunk_index:03d}",
                                "detail": f"nonpunct cut creates {side} {sw}-word fragment: {st}",
                                "left": left,
                                "right": right,
                            }
                        )
                # Nonpunct cut with both sides <6 can be weak for coordinate/syntax rules
                if lw < 6 or rw < 6:
                    findings.append(
                        {
                            "rule": "R-SYNTAX-LOCATION",
                            "severity": "warn",
                            "where": f"{book}/{ep}/H{hunk_index:03d}",
                            "detail": f"nonpunct cut with side <6 words ({lw}|{rw})",
                            "left": left,
                            "right": right,
                        }
                    )
                joined = left.rstrip() + " " + right.lstrip()
                parent_wc = word_count(joined)
                # If a side still has unused pause *outside* parentheses, and the
                # cut itself is nonpunct, that can violate punct-first for >17 parents.
                if parent_wc > 17 and not punct:
                    if pause_inside_outside_parens(left) or pause_inside_outside_parens(
                        right
                    ):
                        findings.append(
                            {
                                "rule": "R-PUNCT-FIRST",
                                "severity": "error",
                                "where": f"{book}/{ep}/H{hunk_index:03d}",
                                "detail": "nonpunct cut while a side still contains unused pause punctuation outside parentheses",
                                "left": left,
                                "right": right,
                            }
                        )

            # Coordinating conjunction should stay with right block
            rwds = words(right)
            if rwds and rwds[0].lower() not in {
                "and",
                "but",
                "or",
                "nor",
                "so",
                "yet",
            }:
                # check left ends with bare conj
                lwds = words(left)
                if lwds and lwds[-1].lower() in {"and", "but", "or", "nor"}:
                    findings.append(
                        {
                            "rule": "R-SYNTAX-LOCATION",
                            "severity": "error",
                            "where": f"{book}/{ep}/H{hunk_index:03d}",
                            "detail": f"coordinating conjunction left on left block: ... {lwds[-1]} | {right[:80]}",
                            "left": left,
                            "right": right,
                        }
                    )

        # New segments in hunk with >17 and internal pause
        for seg in new_span:
            if word_count(seg) > 17 and has_internal_pause(seg):
                findings.append(
                    {
                        "rule": "R-PUNCT-FIRST",
                        "severity": "error",
                        "where": f"{book}/{ep}/H{hunk_index:03d}",
                        "detail": "new segment >17 with internal pause (" + str(word_count(seg)) + "): " + seg[:180],
                        "text": seg,
                    }
                )

    return {
        "book": book,
        "episode": ep,
        "stats": dict(stats),
        "findings": findings,
        "oldCount": len(old),
        "newCount": len(new),
    }


def main() -> None:
    alice = load_replay(OUT / "alice-v3_9-replay-10.json")
    willows = load_replay(OUT / "willows-v3_9-replay-10.json")
    replays = {"Alice": alice, "Willows": willows}
    reports = []
    all_findings = []
    for book, eps in BOOK_EPS.items():
        dbm = db_map(SERIES[book], set(eps))
        for ep in eps:
            result = audit_chapter(book, ep, dbm[ep]["sentences"], replays[book][ep])
            reports.append(result)
            all_findings.extend(result["findings"])

    by_sev = Counter(f["severity"] for f in all_findings)
    by_rule = Counter(f["rule"] for f in all_findings)
    errors = [f for f in all_findings if f["severity"] == "error"]
    warns = [f for f in all_findings if f["severity"] == "warn"]

    lines = [
        "# V3.9 vs DB 差异切点规则审核（20章）",
        "",
        "- 裁决依据：`docs/read_aloud_sentence_split_spec.md` 规则编号",
        "- 新侧：`syntax_solver_v3_9` live replay",
        "- 基线：DB `articles.sentences`",
        "",
        "## 总览",
        "",
        f"- findings：error={by_sev['error']}, warn={by_sev['warn']}",
        f"- 按规则：{dict(by_rule)}",
        "",
    ]

    if not errors and not warns:
        lines.append("**未发现相对规范的 error/warn。**")
    else:
        if errors:
            lines.extend(["## Error（疑似未按规则）", ""])
            for i, f in enumerate(errors, 1):
                lines.append(f"### E{i:03d} · `{f['rule']}` · {f['where']}")
                lines.append("")
                lines.append(f"- {f['detail']}")
                if f.get("old"):
                    lines.append("- DB:")
                    for s in f["old"]:
                        lines.append(f"  - {s}")
                if f.get("new"):
                    lines.append("- V3.9:")
                    for s in f["new"]:
                        lines.append(f"  - {s}")
                if f.get("left") is not None:
                    lines.append(f"- left: {f['left']}")
                    lines.append(f"- right: {f['right']}")
                if f.get("text"):
                    lines.append(f"- text: {f['text']}")
                lines.append("")
        if warns:
            lines.extend(["## Warn（需人工确认是否功能块豁免）", ""])
            for i, f in enumerate(warns, 1):
                lines.append(f"### W{i:03d} · `{f['rule']}` · {f['where']}")
                lines.append("")
                lines.append(f"- {f['detail']}")
                if f.get("left") is not None:
                    lines.append(f"- left: {f['left']}")
                    lines.append(f"- right: {f['right']}")
                if f.get("text"):
                    lines.append(f"- text: {f['text']}")
                lines.append("")

    lines.extend(["## 分章统计", "", "| 书 | 章 | hunks | +punct | +nonpunct | errors | warns |", "|---|---|---:|---:|---:|---:|---:|"])
    for r in reports:
        ef = sum(1 for f in r["findings"] if f["severity"] == "error")
        wf = sum(1 for f in r["findings"] if f["severity"] == "warn")
        st = r["stats"]
        lines.append(
            f"| {r['book']} | {r['episode']} | {st.get('hunks', 0)} | "
            f"{st.get('added_punct', 0)} | {st.get('added_nonpunct', 0)} | {ef} | {wf} |"
        )
    lines.append("")

    out_path = OUT / "RULE_AUDIT.md"
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    payload = {
        "errorCount": by_sev["error"],
        "warnCount": by_sev["warn"],
        "byRule": dict(by_rule),
        "errors": errors,
        "warns": warns,
        "chapters": [
            {
                "book": r["book"],
                "episode": r["episode"],
                "stats": r["stats"],
                "findingCount": len(r["findings"]),
            }
            for r in reports
        ],
    }
    (OUT / "rule_audit.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"errors={by_sev['error']} warns={by_sev['warn']} byRule={dict(by_rule)}")
    print(f"wrote {out_path}")
    for f in errors[:30]:
        print("ERR", f["rule"], f["where"], f["detail"][:120])
    for f in warns[:20]:
        print("WARN", f["rule"], f["where"], f["detail"][:120])


if __name__ == "__main__":
    main()
