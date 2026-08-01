#!/usr/bin/env python3
"""Batch-select local songs, run CTC align, compare to BigASR timelines, write summary."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent
DEFAULT_DATA_ROOT = Path(
    r"F:\TomatoEnglishHappyTalking\release\windows\tomato_english_happy_talking"
)


def contains_cjk(text: str) -> bool:
    return any("\u3400" <= ch <= "\u9fff" or "\uf900" <= ch <= "\ufaff" for ch in text)


def resolve_timeline_path(data_root: Path, timeline_path: str | None) -> Path | None:
    if not timeline_path:
        return None
    p = Path(timeline_path)
    if p.is_file():
        return p
    cand = data_root / "tomato_api_cache" / "song-subtitle-timelines" / p.name
    if cand.is_file():
        return cand
    return None


def lyrics_from_version(version: dict, timeline: dict) -> str:
    submitted = (version.get("submittedLyrics") or "").strip()
    if submitted:
        return submitted
    cues = timeline.get("cues") or []
    return "\n".join(str(c.get("english") or "") for c in cues).strip()


def collect_candidates(data_root: Path) -> list[dict]:
    seen: set[str] = set()
    out: list[dict] = []

    def add(item: dict) -> None:
        vid = str(item["id"])
        if vid in seen:
            return
        seen.add(vid)
        out.append(item)

    for meta_path in sorted((data_root / "suno-music").glob("*.json")):
        try:
            data = json.loads(meta_path.read_text(encoding="utf-8"))
        except Exception:
            continue
        for version in data.get("versions") or []:
            if not isinstance(version, dict):
                continue
            vid = version.get("id")
            if not vid:
                continue
            audio = version.get("audioPath") or ""
            if not audio or not Path(audio).is_file():
                continue
            timeline_path = resolve_timeline_path(data_root, version.get("timelinePath"))
            if timeline_path is None and version.get("timelineStatus") != "ready":
                continue
            if timeline_path is None:
                continue
            try:
                timeline = json.loads(timeline_path.read_text(encoding="utf-8"))
            except Exception:
                continue
            lyrics = lyrics_from_version(version, timeline)
            if not lyrics.strip():
                continue
            add(
                {
                    "id": vid,
                    "articleId": data.get("articleId") or timeline.get("articleId"),
                    "title": version.get("title") or data.get("articleTitle") or vid,
                    "audioPath": audio,
                    "timelinePath": str(timeline_path),
                    "lyrics": lyrics,
                    "cueCount": len(timeline.get("cues") or []),
                    "durationMs": int(timeline.get("durationMs") or 0),
                    "cjk": contains_cjk(lyrics),
                    "source": version.get("source") or data.get("provider") or "suno",
                    "audioHash": timeline.get("audioHash") or "",
                    "lyricsHash": timeline.get("lyricsHash") or version.get("lyricsHash") or "",
                }
            )

    ext_root = data_root / "song-assets" / "external_audio"
    if ext_root.is_dir():
        for art_dir in sorted(ext_root.glob("article_*")):
            mp3s = list(art_dir.glob("*.mp3"))
            for meta_path in art_dir.glob("*.json"):
                try:
                    data = json.loads(meta_path.read_text(encoding="utf-8"))
                except Exception:
                    continue
                versions = data.get("versions")
                if not isinstance(versions, list):
                    versions = [data] if isinstance(data, dict) else []
                for version in versions:
                    if not isinstance(version, dict):
                        continue
                    vid = version.get("id") or meta_path.stem
                    audio = version.get("audioPath") or ""
                    if not audio or not Path(audio).is_file():
                        audio = str(mp3s[0]) if mp3s else ""
                    if not audio or not Path(audio).is_file():
                        continue
                    timeline_path = resolve_timeline_path(data_root, version.get("timelinePath"))
                    if timeline_path is None:
                        continue
                    try:
                        timeline = json.loads(timeline_path.read_text(encoding="utf-8"))
                    except Exception:
                        continue
                    lyrics = lyrics_from_version(version, timeline)
                    if not lyrics.strip():
                        continue
                    add(
                        {
                            "id": vid,
                            "articleId": art_dir.name.replace("article_", ""),
                            "title": version.get("title") or art_dir.name,
                            "audioPath": audio,
                            "timelinePath": str(timeline_path),
                            "lyrics": lyrics,
                            "cueCount": len(timeline.get("cues") or []),
                            "durationMs": int(timeline.get("durationMs") or 0),
                            "cjk": contains_cjk(lyrics),
                            "source": "external_audio",
                            "audioHash": timeline.get("audioHash") or "",
                            "lyricsHash": timeline.get("lyricsHash") or version.get("lyricsHash") or "",
                        }
                    )
    return out


def default_picks(candidates: list[dict]) -> list[dict]:
    picks: list[dict] = []
    ids: set[str] = set()

    def take(item: dict) -> None:
        if item["id"] in ids:
            return
        ids.add(item["id"])
        picks.append(item)

    for c in candidates:
        if str(c["articleId"]) == "66" or "235f47f1" in str(c["id"]):
            take(c)
            break

    by_dur = sorted([c for c in candidates if c["durationMs"] > 0], key=lambda x: x["durationMs"])
    for c in by_dur:
        if c["durationMs"] < 180_000:
            take(c)
            break
    for c in by_dur:
        if 180_000 <= c["durationMs"] < 280_000:
            take(c)
            break
    for c in reversed(by_dur):
        if c["durationMs"] >= 280_000:
            take(c)
            break
    for c in candidates:
        if c["cjk"]:
            take(c)
            break
    return picks


def load_manifest(path: Path, candidates: list[dict]) -> list[dict]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(raw, dict) and isinstance(raw.get("samples"), list):
        items = raw["samples"]
    elif isinstance(raw, list):
        items = raw
    else:
        raise SystemExit(f"Unsupported manifest format: {path}")

    by_id = {c["id"]: c for c in candidates}
    selected: list[dict] = []
    for item in items:
        if isinstance(item, str):
            if item not in by_id:
                raise SystemExit(f"Manifest id not found: {item}")
            selected.append(by_id[item])
            continue
        if not isinstance(item, dict):
            raise SystemExit(f"Bad manifest entry: {item!r}")
        if item.get("id") and item["id"] in by_id and "audioPath" not in item:
            base = dict(by_id[item["id"]])
            base.update({k: v for k, v in item.items() if v is not None})
            selected.append(base)
            continue
        # Fully specified entry
        audio = item.get("audioPath")
        timeline = item.get("timelinePath")
        lyrics = item.get("lyrics")
        if not audio or not timeline:
            raise SystemExit(f"Manifest entry needs audioPath+timelinePath or known id: {item}")
        if lyrics is None:
            tl = json.loads(Path(timeline).read_text(encoding="utf-8"))
            lyrics = "\n".join(str(c.get("english") or "") for c in (tl.get("cues") or []))
        selected.append(
            {
                "id": item.get("id") or Path(audio).stem,
                "articleId": item.get("articleId") or 0,
                "title": item.get("title") or Path(audio).stem,
                "audioPath": audio,
                "timelinePath": timeline,
                "lyrics": lyrics,
                "cueCount": item.get("cueCount") or 0,
                "durationMs": item.get("durationMs") or 0,
                "cjk": contains_cjk(str(lyrics)),
                "source": item.get("source") or "manifest",
                "audioHash": item.get("audioHash") or "",
                "lyricsHash": item.get("lyricsHash") or "",
            }
        )
    return selected


def run_cmd(cmd: list[str], cwd: Path) -> dict:
    proc = subprocess.run(
        cmd,
        cwd=str(cwd),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    stdout = (proc.stdout or "").strip()
    stderr = (proc.stderr or "").strip()
    parsed = None
    if stdout:
        # Last JSON line
        for line in reversed(stdout.splitlines()):
            line = line.strip()
            if line.startswith("{") and line.endswith("}"):
                try:
                    parsed = json.loads(line)
                    break
                except json.JSONDecodeError:
                    continue
    return {
        "returncode": proc.returncode,
        "stdout": stdout,
        "stderr": stderr,
        "json": parsed,
    }


def write_summary(reports_dir: Path, results: list[dict], cjk_tested: bool) -> Path:
    lines = [
        "# CTC Forced Aligner vs BigASR Timeline — Eval Summary",
        "",
        "Baseline = existing local BigASR + DP `song-subtitle-timelines` (not human ground truth).",
        "CTC = MahmoudAshraf97/ctc-forced-aligner (MMS), word/char align then aggregate to lyric lines.",
        "",
        "## Decision thresholds",
        "",
        "- **replace_candidate**: median `|Δstart| ≤ 500ms` and `|Δstart| > 5s` lines < 5%",
        "- **needs_listening_review**: median `|Δstart| ≤ 1.5s` (or hard samples diverge)",
        "- **not_direct_replace**: worse than that, or systematic collapse/stretch",
        "",
        "## Samples",
        "",
        "| sample | article | duration ms | lines | start median | start MAE | ≤500ms % | >5s % | verdict | align s |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |",
    ]

    verdicts: list[str] = []
    for r in results:
        m = r.get("metrics") or {}
        start = m.get("start") or {}
        lines.append(
            "| {id} | {article} | {dur} | {n} | {med} | {mae} | {w500} | {over5} | {verdict} | {align} |".format(
                id=r.get("id"),
                article=r.get("articleId"),
                dur=r.get("durationMs"),
                n=m.get("comparedLines", ""),
                med=start.get("median", ""),
                mae=start.get("mae", ""),
                w500=m.get("within500MsPct", ""),
                over5=m.get("absStartOver5sPct", ""),
                verdict=r.get("verdict", r.get("error", "failed")),
                align=(r.get("alignMeta") or {}).get("alignSeconds", ""),
            )
        )
        if r.get("verdict"):
            verdicts.append(r["verdict"])

    lines.extend(["", "## Overall recommendation", ""])

    en_results = [r for r in results if not r.get("cjk") and r.get("verdict")]
    zh_results = [r for r in results if r.get("cjk") and r.get("verdict")]

    def bucket(vs: list[str]) -> str:
        if not vs:
            return "no_data"
        if all(v == "replace_candidate" for v in vs):
            return "replace_candidate"
        if any(v == "not_direct_replace" for v in vs):
            return "not_direct_replace"
        return "needs_listening_review"

    en_bucket = bucket([r["verdict"] for r in en_results])
    zh_bucket = bucket([r["verdict"] for r in zh_results]) if cjk_tested else "not_tested"

    lines.append(f"- English songs: **{en_bucket}**")
    lines.append(f"- Chinese / CJK songs: **{zh_bucket}**")
    lines.append("")

    if en_bucket == "replace_candidate" and zh_bucket in ("replace_candidate", "not_tested"):
        if zh_bucket == "not_tested":
            lines.append(
                "**Suggestion:** English looks like a replace candidate vs BigASR baseline, "
                "but CJK was not tested on this machine set — do not drop BigASR for Chinese yet."
            )
        else:
            lines.append(
                "**Suggestion:** CTC is a replace candidate for the evaluated set; "
                "next step is a product integration design (sidecar), not yet wired into Flutter."
            )
    elif en_bucket == "needs_listening_review" or zh_bucket == "needs_listening_review":
        lines.append(
            "**Suggestion:** Do not replace BigASR yet. Use listening review on worst lines; "
            "CTC may still help as a free offline fallback after tuning."
        )
    else:
        lines.append(
            "**Suggestion:** Do not replace BigASR API based on this eval. "
            "Keep cloud word timings + DP as the primary path."
        )

    lines.extend(
        [
            "",
            "## Notes",
            "",
            "- This compares agreement with BigASR timelines, not absolute lyric-to-audio truth.",
            "- Runtime/memory are recorded per sample under each `reports/<id>/align_meta.json`.",
            "- Product path (`listening.songTimelineGenerate`) was not modified.",
            "",
        ]
    )

    path = reports_dir / "summary.md"
    path.write_text("\n".join(lines), encoding="utf-8")
    summary_json = {
        "englishVerdict": en_bucket,
        "cjkVerdict": zh_bucket,
        "samples": results,
    }
    (reports_dir / "summary.json").write_text(
        json.dumps(summary_json, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return path


def ensure_ffmpeg_on_path(data_root: Path) -> str | None:
    """Prefer app-bundled ffmpeg.exe so load_audio works without system PATH."""
    candidates = [
        data_root / "ffmpeg.exe",
        Path(r"F:\TomatoEnglishHappyTalking\release\windows\tomato_english_happy_talking\ffmpeg.exe"),
        Path(r"F:\TomatoEnglishHappyTalking\app\windows\ffmpeg.exe"),
    ]
    for cand in candidates:
        if cand.is_file():
            os.environ["PATH"] = str(cand.parent) + os.pathsep + os.environ.get("PATH", "")
            return str(cand)
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-root", type=Path, default=DEFAULT_DATA_ROOT)
    parser.add_argument("--reports-dir", type=Path, default=ROOT / "reports")
    parser.add_argument("--manifest", type=Path, default=None)
    parser.add_argument("--python", type=Path, default=None, help="Interpreter with ctc-forced-aligner installed")
    parser.add_argument("--device", default=None, choices=["cpu", "cuda"])
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args()

    ffmpeg = ensure_ffmpeg_on_path(args.data_root)
    if ffmpeg:
        print(f"Using ffmpeg: {ffmpeg}", flush=True)
    else:
        print("WARN: bundled ffmpeg.exe not found; relying on PATH", flush=True)

    py = str(args.python or sys.executable)
    candidates = collect_candidates(args.data_root)
    if args.manifest:
        samples = load_manifest(args.manifest, candidates)
    else:
        samples = default_picks(candidates)

    if args.limit > 0:
        samples = samples[: args.limit]

    args.reports_dir.mkdir(parents=True, exist_ok=True)
    manifest_out = args.reports_dir / "selected_samples.json"
    manifest_out.write_text(
        json.dumps(
            {
                "samples": [
                    {k: v for k, v in s.items() if k != "lyrics"}
                    | {"lyricsPreview": (s.get("lyrics") or "")[:160]}
                    for s in samples
                ]
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )

    results: list[dict] = []
    for sample in samples:
        sample_id = str(sample["id"])
        safe_id = "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in sample_id)
        out_dir = args.reports_dir / safe_id
        out_dir.mkdir(parents=True, exist_ok=True)
        lyrics_path = out_dir / "lyrics.txt"
        lyrics_text = (sample["lyrics"] or "").replace("\r\n", "\n").replace("\r", "\n")
        lyrics_path.write_text(lyrics_text.rstrip() + "\n", encoding="utf-8")

        align_cmd = [
            py,
            str(ROOT / "align_one.py"),
            "--audio",
            str(sample["audioPath"]),
            "--lyrics",
            str(lyrics_path),
            "--out-dir",
            str(out_dir),
            "--article-id",
            str(sample.get("articleId") or 0),
            "--source",
            str(sample.get("source") or "eval"),
            "--audio-hash",
            str(sample.get("audioHash") or ""),
            "--lyrics-hash",
            str(sample.get("lyricsHash") or ""),
            "--language",
            "cmn" if sample.get("cjk") else "eng",
        ]
        if args.device:
            align_cmd.extend(["--device", args.device])

        print(f"=== ALIGN {sample_id} ===", flush=True)
        align_res = run_cmd(align_cmd, ROOT)
        (out_dir / "align_stdout.txt").write_text(align_res["stdout"], encoding="utf-8")
        (out_dir / "align_stderr.txt").write_text(align_res["stderr"], encoding="utf-8")
        if align_res["returncode"] != 0:
            results.append(
                {
                    "id": sample_id,
                    "articleId": sample.get("articleId"),
                    "title": sample.get("title"),
                    "durationMs": sample.get("durationMs"),
                    "cjk": bool(sample.get("cjk")),
                    "error": "align_failed",
                    "stderr": align_res["stderr"][-2000:],
                }
            )
            continue

        ctc_path = out_dir / "timeline_ctc.json"
        compare_cmd = [
            py,
            str(ROOT / "compare_timelines.py"),
            "--baseline",
            str(sample["timelinePath"]),
            "--ctc",
            str(ctc_path),
            "--out-dir",
            str(out_dir),
            "--sample-id",
            sample_id,
        ]
        print(f"=== COMPARE {sample_id} ===", flush=True)
        cmp_res = run_cmd(compare_cmd, ROOT)
        (out_dir / "compare_stdout.txt").write_text(cmp_res["stdout"], encoding="utf-8")
        (out_dir / "compare_stderr.txt").write_text(cmp_res["stderr"], encoding="utf-8")
        if cmp_res["returncode"] != 0 or not cmp_res["json"]:
            results.append(
                {
                    "id": sample_id,
                    "articleId": sample.get("articleId"),
                    "title": sample.get("title"),
                    "durationMs": sample.get("durationMs"),
                    "cjk": bool(sample.get("cjk")),
                    "error": "compare_failed",
                    "stderr": cmp_res["stderr"][-2000:],
                }
            )
            continue

        comparison = json.loads((out_dir / "comparison.json").read_text(encoding="utf-8"))
        align_meta = {}
        meta_path = out_dir / "align_meta.json"
        if meta_path.is_file():
            align_meta = json.loads(meta_path.read_text(encoding="utf-8"))
        results.append(
            {
                "id": sample_id,
                "articleId": sample.get("articleId"),
                "title": sample.get("title"),
                "durationMs": sample.get("durationMs"),
                "cjk": bool(sample.get("cjk")),
                "verdict": comparison.get("verdict"),
                "metrics": comparison.get("metrics"),
                "alignMeta": align_meta,
                "reportDir": str(out_dir),
            }
        )

    cjk_tested = any(r.get("cjk") and r.get("verdict") for r in results)
    summary_path = write_summary(args.reports_dir, results, cjk_tested=cjk_tested)
    print(f"SUMMARY {summary_path}", flush=True)
    return 0 if all(r.get("verdict") for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
