#!/usr/bin/env python3
"""Diff current working-tree splitter replay vs accepted v3.8 r8n16 full books."""

from __future__ import annotations

import json
import re
from collections import Counter
from pathlib import Path

ROOT = Path(r"F:/TomatoEnglishHappyTalking")
OUT = ROOT / "output/sentence-split-v3/attempt-g-20260816"
V38 = ROOT / "output/sentence-split-v3"
WORD_RE = re.compile(r"[A-Za-z0-9]+(?:['’-][A-Za-z0-9]+)*")
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


def load_chapters(paths: list[Path]) -> tuple[dict, str | None]:
    chapters: dict[str, dict] = {}
    solver = None
    for path in paths:
        data = json.loads(path.read_text(encoding="utf-8"))
        solver = (data.get("summary") or {}).get("solverVersion") or solver
        for chapter in data["chapters"]:
            chapters[str(chapter["episode"]).upper()] = chapter
    return chapters, solver


def segs_of(chapter: dict) -> list[list[str]] | None:
    output: list[list[str]] = []
    for original in chapter.get("originals") or []:
        segments = original.get("segments")
        if segments is None:
            segments = original.get("v4AdditiveSegments")
        if segments is None:
            return None
        output.append([str(segment).strip() for segment in segments])
    return output


def cut_view(segments: list[str]) -> str:
    return " | ".join(segments)


def find_suspect_cuts(segments: list[str]) -> list[str]:
    hits: list[str] = []
    for index in range(len(segments) - 1):
        left = WORD_RE.findall(segments[index])
        right = WORD_RE.findall(segments[index + 1])
        if not left or not right:
            continue
        right_word = right[0].lower()
        if right_word in SUSPECT_RIGHT:
            hits.append(f"{left[-1].lower()} | {right_word}")
    return hits


def hard_gate_counts(chapters: dict[str, dict]) -> dict[str, int]:
    issues: Counter[str] = Counter()
    for chapter in chapters.values():
        for original in chapter.get("originals") or []:
            segments = original.get("segments") or []
            word_counts = [len(WORD_RE.findall(segment)) for segment in segments]
            if any(count > 30 for count in word_counts):
                issues["gt30"] += 1
            if any(count > 20 for count in word_counts):
                issues["gt20"] += 1
            if any(count == 1 for count in word_counts):
                issues["one_word"] += 1
    return dict(issues)


def find_text(chapters: dict[str, dict], needle: str) -> list[tuple[str, int, str]]:
    hits: list[tuple[str, int, str]] = []
    for episode, chapter in chapters.items():
        for index, original in enumerate(chapter.get("originals") or []):
            segments = original.get("segments") or []
            joined = " ".join(segments)
            if needle in joined:
                hits.append((episode, index, cut_view(segments)))
    return hits


def main() -> None:
    alice_old, alice_old_solver = load_chapters(
        [V38 / "production-integration-r8n16-final-full-a.json"]
    )
    alice_new, alice_new_solver = load_chapters(
        [OUT / "alice-current-full-replay.json"]
    )
    willows_old, willows_old_solver = load_chapters(
        [
            V38 / f"production-integration-r8n16-final-full-w{index}.json"
            for index in range(1, 5)
        ]
    )
    willows_new, willows_new_solver = load_chapters(
        [OUT / f"willows-current-g{index}.json" for index in range(1, 5)]
    )

    report: dict = {
        "baseline": "syntax_solver_v3_8 (r8n16 final full)",
        "baselineSolvers": {"Alice": alice_old_solver, "Willows": willows_old_solver},
        "candidate": alice_new_solver,
        "candidateSolvers": {"Alice": alice_new_solver, "Willows": willows_new_solver},
        "books": {},
        "sampleDiffs": [],
        "suspectNewCuts": [],
    }
    samples: list[dict] = []
    suspect_new: list[dict] = []

    def diff_book(name: str, old_map: dict, new_map: dict) -> None:
        chapters_changed = 0
        originals_changed = 0
        originals_total = 0
        segments_old = 0
        segments_new = 0
        episodes: list[dict] = []

        for episode in sorted(set(old_map) | set(new_map), key=lambda value: (len(value), value)):
            if episode not in old_map or episode not in new_map:
                episodes.append({"episode": episode, "status": "missing"})
                continue
            old_segments = segs_of(old_map[episode])
            new_segments = segs_of(new_map[episode])
            if old_segments is None or new_segments is None:
                episodes.append({"episode": episode, "status": "missing_originals"})
                continue

            diffs = [
                index
                for index in range(max(len(old_segments), len(new_segments)))
                if index >= len(old_segments)
                or index >= len(new_segments)
                or old_segments[index] != new_segments[index]
            ]
            originals_total += len(old_segments)
            segments_old += sum(len(parts) for parts in old_segments)
            segments_new += sum(len(parts) for parts in new_segments)
            if diffs or len(old_segments) != len(new_segments):
                chapters_changed += 1
                originals_changed += len(diffs)
                episodes.append(
                    {
                        "episode": episode,
                        "changedOriginals": len(diffs),
                        "oldOriginals": len(old_segments),
                        "newOriginals": len(new_segments),
                        "oldSegments": sum(len(parts) for parts in old_segments),
                        "newSegments": sum(len(parts) for parts in new_segments),
                    }
                )
                for index in diffs:
                    if index >= len(old_segments) or index >= len(new_segments):
                        continue
                    sample = {
                        "book": name,
                        "episode": episode,
                        "originalIndex": index,
                        "old": cut_view(old_segments[index]),
                        "new": cut_view(new_segments[index]),
                        "oldWc": [
                            len(WORD_RE.findall(part)) for part in old_segments[index]
                        ],
                        "newWc": [
                            len(WORD_RE.findall(part)) for part in new_segments[index]
                        ],
                    }
                    if len(samples) < 60:
                        samples.append(sample)
                    old_hits = set(find_suspect_cuts(old_segments[index]))
                    for hit in find_suspect_cuts(new_segments[index]):
                        if hit not in old_hits:
                            suspect_new.append(
                                {
                                    "book": name,
                                    "episode": episode,
                                    "originalIndex": index,
                                    "cut": hit,
                                    "new": cut_view(new_segments[index])[:220],
                                    "old": cut_view(old_segments[index])[:220],
                                }
                            )
            else:
                episodes.append({"episode": episode, "changedOriginals": 0})

        report["books"][name] = {
            "chapters": len(old_map),
            "chaptersChanged": chapters_changed,
            "originalsTotal": originals_total,
            "originalsChanged": originals_changed,
            "segmentsOld": segments_old,
            "segmentsNew": segments_new,
            "segmentDelta": segments_new - segments_old,
            "episodes": episodes,
        }
        print(
            f"=== {name} === chapters_changed {chapters_changed}/{len(old_map)} "
            f"originals_changed {originals_changed}/{originals_total} "
            f"segment_delta {segments_new - segments_old} "
            f"({segments_old}->{segments_new})"
        )

    diff_book("Alice", alice_old, alice_new)
    diff_book("Willows", willows_old, willows_new)

    report["candidateHard"] = {
        "Alice": hard_gate_counts(alice_new),
        "Willows": hard_gate_counts(willows_new),
    }
    report["baselineHard"] = {
        "Alice": hard_gate_counts(alice_old),
        "Willows": hard_gate_counts(willows_old),
    }
    report["sampleDiffs"] = samples
    report["suspectNewCuts"] = suspect_new
    report["targets"] = {
        "candle": {
            "v38": find_text(alice_old, "blown out")[:2],
            "current": find_text(alice_new, "blown out")[:2],
        },
        "door": {
            "v38": find_text(willows_old, "painted a dark green")[:2],
            "current": find_text(willows_new, "painted a dark green")[:2],
        },
        "bend_about": {
            "v38": find_text(alice_old, "bend about")[:2],
            "current": find_text(alice_new, "bend about")[:2],
        },
        "legs_up": {
            "v38": find_text(willows_old, "legs up")[:2],
            "current": find_text(willows_new, "legs up")[:2],
        },
    }

    (OUT / "DIFF_VS_V38_SUMMARY.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    lines = [
        "# 当前工作区修正 vs 已提交 syntax_solver_v3_8（R8n16 全书）",
        "",
        "- 基线：`syntax_solver_v3_8`（`production-integration-r8n16-final-full-*.json`）",
        f"- 候选：`{alice_new_solver}` 工作区（含 candle + Attempt D 等未确认补丁）",
        f"- 产物：`{OUT.as_posix()}`",
        "",
        "## 规模",
        "",
        "| 书 | 章变化 | 变化原句 / 原句总数 | 句段 旧→新 | Δ |",
        "|---|---:|---:|---|---:|",
    ]
    for book, body in report["books"].items():
        lines.append(
            f"| {book} | {body['chaptersChanged']}/{body['chapters']} | "
            f"{body['originalsChanged']}/{body['originalsTotal']} | "
            f"{body['segmentsOld']}→{body['segmentsNew']} | "
            f"{body['segmentDelta']:+d} |"
        )

    lines += [
        "",
        "## 硬门禁粗检（含 >20 / >30 / 1 词块的原句数）",
        "",
        f"- V3.8 Alice：{report['baselineHard']['Alice']}",
        f"- 当前 Alice：{report['candidateHard']['Alice']}",
        f"- V3.8 Willows：{report['baselineHard']['Willows']}",
        f"- 当前 Willows：{report['candidateHard']['Willows']}",
        "",
        f"## 相对 v3.8 新出现的可疑紧密附着切（右缘 to/about/up/…）共 {len(suspect_new)} 处",
        "",
    ]
    for item in suspect_new[:50]:
        lines.append(
            f"- **{item['book']} {item['episode']}#{item['originalIndex']}** "
            f"`{item['cut']}`"
        )
        lines.append(f"  - 当前：{item['new']}")
        lines.append(f"  - V3.8：{item['old']}")

    lines += ["", "## 定点目标", ""]
    for key, value in report["targets"].items():
        lines.append(f"### {key}")
        lines.append(f"- V3.8：{value['v38'][:1]}")
        lines.append(f"- 当前：{value['current'][:1]}")
        lines.append("")

    lines += ["## 样本差异（前 25）", ""]
    for sample in samples[:25]:
        lines.append(
            f"### {sample['book']} {sample['episode']} orig "
            f"{sample['originalIndex']}  wc {sample['oldWc']}→{sample['newWc']}"
        )
        lines.append("")
        lines.append(f"- V3.8：{sample['old']}")
        lines.append(f"- 当前：{sample['new']}")
        lines.append("")

    (OUT / "DIFF_VS_V38_SUMMARY.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("suspect_new", len(suspect_new))
    print("wrote", OUT / "DIFF_VS_V38_SUMMARY.md")


if __name__ == "__main__":
    main()
