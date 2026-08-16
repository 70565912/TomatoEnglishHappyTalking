#!/usr/bin/env python3
"""DB vs current Attempt E+F full-book rule audit (syntax_solver_v3_9).

Compares articles.sentences to live full-book replay and adjudicates NEW-side
differences against docs/read_aloud_sentence_split_spec.md via the shared
audit_v3_9 helpers. Read-only.
"""

from __future__ import annotations

import importlib.util
import json
import re
import sqlite3
from collections import Counter
from pathlib import Path

ROOT = Path(r"F:\TomatoEnglishHappyTalking")
OUT = ROOT / "output" / "sentence-split-v3" / "attempt-g-20260816"
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
SERIES = {"Alice": 23, "Willows": 30}


def load_audit_module():
    path = ROOT / "tools" / "audit_v3_9_diff_rule_compliance.py"
    spec = importlib.util.spec_from_file_location("audit_v39", path)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


def db_all(series_id: int) -> dict[str, dict]:
    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
    rows = con.execute(
        """
        SELECT a.title, a.sentences, a.content
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
        if not match:
            continue
        mapped[match.group(1)] = {
            "sentences": [str(s) for s in json.loads(row["sentences"] or "[]")],
            "content": row["content"] or "",
        }
    return mapped


def main() -> None:
    audit = load_audit_module()
    alice = audit.load_replay(OUT / "alice-current-full-replay.json")
    willows = audit.load_replay(OUT / "willows-current-full-replay.json")

    reports = []
    all_findings = []
    for book, replay in (("Alice", alice), ("Willows", willows)):
        dbm = db_all(SERIES[book])
        for ep, chapter in sorted(replay.items()):
            if ep not in dbm:
                raise SystemExit(f"missing DB map for {book} {ep}")
            result = audit.audit_chapter(book, ep, dbm[ep]["sentences"], chapter)
            for finding in result["findings"]:
                detail = str(finding.get("detail") or "")
                finding["detail"] = detail.replace("V3.9", "current")
            reports.append(result)
            all_findings.extend(result["findings"])

    by_sev = Counter(f["severity"] for f in all_findings)
    by_rule_sev = Counter((f["rule"], f["severity"]) for f in all_findings)
    errors = [f for f in all_findings if f["severity"] == "error"]
    warns = [f for f in all_findings if f["severity"] == "warn"]

    # Scale of DB vs new sentence differences
    changed_chapters = 0
    changed_slots = 0
    for report in reports:
        if report.get("hunks") or report.get("stats", {}).get("hunks"):
            changed_chapters += 1
        changed_slots += int((report.get("stats") or {}).get("hunks") or 0)

    # Prefer fields from chapter audit return shape
    hunk_total = 0
    for report in reports:
        hunk_total += int((report.get("stats") or Counter()).get("hunks") or 0)

    payload = {
        "candidate": "syntax_solver_v3_9 + Attempt E/F",
        "baseline": "DB articles.sentences",
        "severityCounts": dict(by_sev),
        "ruleSeverityCounts": {
            f"{rule}|{sev}": count for (rule, sev), count in sorted(by_rule_sev.items())
        },
        "errorCount": len(errors),
        "warnCount": len(warns),
        "hunkTotal": hunk_total,
        "chapterReports": len(reports),
        "errors": errors,
        "warns": warns[:200],
        "reports": reports,
    }
    (OUT / "rule_audit.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    lines = [
        "# DB vs Attempt E+F 全书规则审计",
        "",
        "- 基线：DB `articles.sentences`",
        "- 候选：当前工作区 `syntax_solver_v3_9`（含 Attempt E/F + candle）",
        "- 回放：`alice-current-full-replay.json` / `willows-current-full-replay.json`",
        "- 裁决：`tools/audit_v3_9_diff_rule_compliance.py`（规范规则编号）",
        "",
        "## 规模",
        "",
        f"- 章报告数：{len(reports)}",
        f"- 差异 hunk 合计：{hunk_total}",
        "",
        "## 裁决汇总",
        "",
        f"- error：**{len(errors)}**",
        f"- warn：{len(warns)}",
        "",
        "### 按规则 × 严重度",
        "",
    ]
    for (rule, sev), count in sorted(by_rule_sev.items(), key=lambda x: (-x[1], x[0][0], x[0][1])):
        lines.append(f"- `{rule}` / {sev}: {count}")

    lines.extend(["", "## ERROR 清单（新侧不支持/违规嫌疑）", ""])
    if not errors:
        lines.append("（无 error）")
    for index, finding in enumerate(errors, start=1):
        lines.append(
            f"### {index}. `{finding.get('rule')}` · {finding.get('where')}"
        )
        lines.append("")
        lines.append(f"- {finding.get('detail')}")
        if finding.get("old") is not None:
            lines.append(f"- DB：{finding.get('old')}")
        if finding.get("new") is not None:
            lines.append(f"- 新：{finding.get('new')}")
        if finding.get("left") is not None:
            lines.append(f"- L：{finding.get('left')}")
        if finding.get("right") is not None:
            lines.append(f"- R：{finding.get('right')}")
        lines.append("")

    lines.extend(
        [
            "## 结论",
            "",
            (
                "**FAIL**：新侧仍有 error 级不支持/违规切法，需继续修正。"
                if errors
                else "**PASS（代理裁决）**：相对 DB 的不同点中，未发现 error 级规范违规；warn 见 JSON。"
            ),
            "",
            "机器摘要：`rule_audit.json`",
            "",
        ]
    )
    (OUT / "RULE_AUDIT.md").write_text("\n".join(lines), encoding="utf-8")
    print("errors", len(errors), "warns", len(warns), "hunks", hunk_total)
    print("wrote", OUT / "RULE_AUDIT.md")


if __name__ == "__main__":
    main()
