#!/usr/bin/env python3
"""Finalize human/Codex V3.6 Willows translations without remote services."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Any


WHITESPACE_RE = re.compile(r"\s+")
WORD_RE = re.compile(r"[A-Za-z]+(?:['’\-][A-Za-z]+)*")
FORBIDDEN_NAMES_RE = re.compile(r"鼹鼠|河鼠|水鼠|海鼠|蛤蟆|蟾蜍|獾先生")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--review-root", type=Path, required=True)
    parser.add_argument("--translations-root", type=Path)
    parser.add_argument("--final-root", type=Path)
    parser.add_argument("--episodes", default="")
    return parser.parse_args()


def canonical(text: str) -> str:
    return WHITESPACE_RE.sub("", text)


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def main() -> int:
    args = parse_args()
    translations_root = args.translations_root or args.review_root / "translations"
    final_root = args.final_root or args.review_root / "final"
    selected = [value.strip().upper() for value in args.episodes.split(",") if value.strip()]
    episodes = selected or [f"E{number:02d}" for number in range(1, 63)]
    final_root.mkdir(parents=True, exist_ok=True)

    summaries: list[dict[str, Any]] = []
    for episode in episodes:
        draft = json.loads(
            (args.review_root / f"{episode}.review.json").read_text(encoding="utf-8")
        )
        decisions = json.loads(
            (translations_root / f"{episode}.json").read_text(encoding="utf-8")
        )
        if (
            draft.get("schemaVersion") != 2
            or draft.get("episode") != episode
            or draft.get("source") != "codex_offline_story_translation_v3_6"
            or decisions.get("episode") != episode
        ):
            raise ValueError(f"{episode}: invalid review header")
        translations = {
            int(index): str(value).strip()
            for index, value in decisions.get("translations", {}).items()
        }
        reviewed_replacements = {
            int(index): str(value).strip()
            for index, value in decisions.get("reviewedReplacements", {}).items()
        }
        changed_indexes = {
            int(row["index"])
            for row in draft["rows"]
            if row["baselineDisposition"] == "retranslate"
        }
        if set(translations) != changed_indexes:
            missing = sorted(changed_indexes - set(translations))
            unexpected = sorted(set(translations) - changed_indexes)
            raise ValueError(
                f"{episode}: translation coverage mismatch; "
                f"missing={missing}, unexpected={unexpected}"
            )
        reusable_indexes = {
            int(row["index"])
            for row in draft["rows"]
            if row["baselineDisposition"] == "reuse_candidate"
        }
        unexpected_replacements = sorted(set(reviewed_replacements) - reusable_indexes)
        if unexpected_replacements:
            raise ValueError(
                f"{episode}: reviewed replacement is not a reuse candidate; "
                f"unexpected={unexpected_replacements}"
            )

        final_rows: list[dict[str, Any]] = []
        for index, row in enumerate(draft["rows"]):
            if int(row["index"]) != index:
                raise ValueError(f"{episode}: row index mismatch at {index}")
            english = str(row["english"]).strip()
            if len(WORD_RE.findall(english)) > 30:
                raise ValueError(f"{episode}: English row {index} exceeds 30 words")
            if row["baselineDisposition"] == "reuse_candidate":
                if index in reviewed_replacements:
                    chinese = reviewed_replacements[index]
                    status = "retranslated"
                else:
                    chinese = str(row["chinese"]).strip()
                    status = "reused_checked"
            else:
                chinese = translations[index]
                status = "retranslated"
            if not chinese:
                raise ValueError(f"{episode}: empty Chinese row {index}")
            if FORBIDDEN_NAMES_RE.search(chinese):
                raise ValueError(f"{episode}: fixed character name changed at {index}")
            final_rows.append(
                {
                    "index": index,
                    "english": english,
                    "chinese": chinese,
                    "reviewStatus": status,
                }
            )

        canonical_hash = sha256_text(canonical("".join(row["english"] for row in final_rows)))
        if canonical_hash != draft["canonicalEnglishSha256"]:
            raise ValueError(f"{episode}: English hash changed")
        output = {
            "schemaVersion": 2,
            "episode": episode,
            "sentenceSplitVersion": "reviewed_dp_v3",
            "solverVersion": "syntax_solver_v3_6",
            "source": "codex_offline_story_translation_v3_6",
            "canonicalEnglishSha256": canonical_hash,
            "rows": final_rows,
        }
        (final_root / f"{episode}.json").write_text(
            json.dumps(output, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        summaries.append(
            {
                "episode": episode,
                "sentenceCount": len(final_rows),
                "reusedChecked": sum(
                    row["reviewStatus"] == "reused_checked" for row in final_rows
                ),
                "retranslated": sum(
                    row["reviewStatus"] == "retranslated" for row in final_rows
                ),
            }
        )

    totals = {
        key: sum(int(item[key]) for item in summaries)
        for key in ("sentenceCount", "reusedChecked", "retranslated")
    }
    (final_root / "summary.json").write_text(
        json.dumps(
            {"schemaVersion": 2, "chapters": summaries, "totals": totals},
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(json.dumps({"episodeCount": len(episodes), **totals}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
