#!/usr/bin/env python3
"""Build a human-readable V3.7 baseline/raw/constrained comparison list.

This is a read-only report generator. It groups every changed raw boundary into
the smallest interval bounded by boundaries shared by the reviewed baseline and
the raw candidate. It never writes SQLite, media, or TTS data.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any, Iterable


SPACE_RE = re.compile(r"\s+")
WORD_RE = re.compile(r"[^\W_]+(?:['’\-][^\W_]+)*", re.UNICODE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--book", required=True)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--candidate", required=True, action="append", type=Path)
    parser.add_argument("--constrained", required=True, type=Path)
    parser.add_argument("--raw-impact", required=True, type=Path)
    parser.add_argument("--constrained-impact", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def load(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"Expected object in {path}")
    return value


def chapter_map(report: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        str(chapter["episode"]).upper(): chapter
        for chapter in report.get("chapters") or []
        if isinstance(chapter, dict) and chapter.get("episode")
    }


def canonical(text: str) -> str:
    return SPACE_RE.sub("", text)


def sentence_ranges(sentences: Iterable[Any]) -> list[tuple[int, int, str]]:
    result: list[tuple[int, int, str]] = []
    start = 0
    for value in sentences:
        text = str(value)
        end = start + len(canonical(text))
        result.append((start, end, text))
        start = end
    return result


def boundary_offsets(ranges: list[tuple[int, int, str]]) -> set[int]:
    if not ranges:
        return {0}
    return {0, *(end for _, end, _ in ranges)}


def segments_in(
    ranges: list[tuple[int, int, str]], left: int, right: int
) -> list[str]:
    return [
        text
        for start, end, text in ranges
        if start >= left and end <= right and end > left and start < right
    ]


def word_count(text: str) -> int:
    return len(WORD_RE.findall(text))


def decision_label(offsets: list[int], approved: set[int]) -> str:
    kept = sum(offset in approved for offset in offsets)
    if kept == len(offsets):
        return "全部放行"
    if kept == 0:
        return "全部拒绝，保持旧 V3.7"
    return f"部分放行（{kept}/{len(offsets)}）"


def format_segments(label: str, segments: list[str]) -> list[str]:
    lines = [f"- **{label}**"]
    for index, text in enumerate(segments, start=1):
        lines.append(f"  {index}. `{word_count(text)}词` {text}")
    return lines


def main() -> int:
    args = parse_args()
    baseline = chapter_map(load(args.baseline))
    raw: dict[str, dict[str, Any]] = {}
    for path in args.candidate:
        for episode, chapter in chapter_map(load(path)).items():
            if episode in raw:
                raise ValueError(f"Duplicate raw chapter {episode}")
            raw[episode] = chapter
    constrained = chapter_map(load(args.constrained))
    raw_impact_report = load(args.raw_impact)
    constrained_impact_report = load(args.constrained_impact)
    raw_impact = chapter_map(raw_impact_report)
    constrained_impact = chapter_map(constrained_impact_report)
    if not (baseline.keys() == raw.keys() == constrained.keys()):
        raise ValueError("Baseline/raw/constrained chapter sets differ")

    approved_offsets = {
        episode: {
            int(change["canonicalOffset"])
            for change in chapter.get("changes") or []
        }
        for episode, chapter in constrained_impact.items()
    }
    lines = [
        f"# {args.book} V3.7 新算法分句人工审核对比",
        "",
        "本报告比较：已审核旧 V3.7、原始新算法输出、冻结门禁后的实际候选。",
        "原始新算法中的 `unexpected` 只供审核，当前不得迁移；实际候选只保留门禁放行的原子变化。",
        "",
        "## 汇总",
        "",
        f"- 章节数：{raw_impact_report.get('chapterCount', 0)}",
        f"- 原始变化章节：{raw_impact_report.get('changedChapterCount', 0)}",
        f"- 原始变化边界：{raw_impact_report.get('changedBoundaryCount', 0)}",
        f"- 原始 unexpected：{raw_impact_report.get('unexpectedBoundaryCount', 0)}",
        f"- 实际候选变化边界：{constrained_impact_report.get('changedBoundaryCount', 0)}",
        f"- 实际候选 unexpected：{constrained_impact_report.get('unexpectedBoundaryCount', 0)}",
        f"- 保守 TTS 句数：{constrained_impact_report.get('conservativeTtsSentenceCount', 0)}",
        "",
        "## 章节索引",
        "",
        "| 章节 | 最小变化窗 | 原始边界变化 | 放行 | unexpected |",
        "|---|---:|---:|---:|---:|",
    ]
    windows_by_episode: dict[
        str,
        list[tuple[int, int, list[dict[str, Any]], list[int]]],
    ] = {}
    for episode in sorted(raw):
        changes = list(raw_impact.get(episode, {}).get("changes") or [])
        if not changes:
            continue
        old_ranges = sentence_ranges(baseline[episode].get("v3LocalSentences") or [])
        new_ranges = sentence_ranges(raw[episode].get("v3LocalSentences") or [])
        old_source = "".join(canonical(text) for _, _, text in old_ranges)
        new_source = "".join(canonical(text) for _, _, text in new_ranges)
        if old_source != new_source:
            raise ValueError(f"{episode}: source round-trip changed")
        common = sorted(boundary_offsets(old_ranges) & boundary_offsets(new_ranges))
        grouped: dict[tuple[int, int], list[dict[str, Any]]] = {}
        for change in changes:
            offset = int(change["canonicalOffset"])
            left = max(value for value in common if value < offset)
            right = min(value for value in common if value > offset)
            grouped.setdefault((left, right), []).append(change)
        windows = []
        for (left, right), grouped_changes in sorted(grouped.items()):
            offsets = sorted(int(change["canonicalOffset"]) for change in grouped_changes)
            windows.append((left, right, grouped_changes, offsets))
        windows_by_episode[episode] = windows
        approved = approved_offsets.get(episode, set())
        unexpected = sum(
            change.get("reason") == "unexpected" for change in changes
        )
        lines.append(
            f"| {episode} | {len(windows)} | {len(changes)} | "
            f"{sum(int(change['canonicalOffset']) in approved for change in changes)} | "
            f"{unexpected} |"
        )

    lines.extend(["", "## 逐项对比", ""])
    item = 0
    for episode in sorted(windows_by_episode):
        old_ranges = sentence_ranges(baseline[episode].get("v3LocalSentences") or [])
        new_ranges = sentence_ranges(raw[episode].get("v3LocalSentences") or [])
        gated_ranges = sentence_ranges(
            constrained[episode].get("v3LocalSentences") or []
        )
        approved = approved_offsets.get(episode, set())
        for left, right, changes, offsets in windows_by_episode[episode]:
            item += 1
            reasons = ", ".join(
                f"{change['canonicalOffset']}:{change['reason']}"
                for change in changes
            )
            lines.extend(
                [
                    f"### {item:03d} · {episode} · {decision_label(offsets, approved)}",
                    "",
                    f"- 规范化字符窗：`{left}–{right}`",
                    f"- 变化边界：{reasons}",
                    *format_segments("旧 V3.7", segments_in(old_ranges, left, right)),
                    *format_segments("原始新算法", segments_in(new_ranges, left, right)),
                    *format_segments(
                        "门禁后实际候选", segments_in(gated_ranges, left, right)
                    ),
                    "",
                    "- 人工结论：`待审核`",
                    "",
                ]
            )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    print(
        json.dumps(
            {
                "book": args.book,
                "chaptersWithChanges": len(windows_by_episode),
                "reviewWindows": item,
                "output": str(args.output.resolve()),
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
