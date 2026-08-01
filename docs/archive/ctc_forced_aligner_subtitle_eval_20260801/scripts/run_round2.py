#!/usr/bin/env python3
"""Round-2 English comparison: BigASR vs MMS vs EN-Wav2Vec2 CTC vs torchaudio EN vs MFA."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

from compare_timelines import compare, verdict_for_sample
from run_batch import (
    DEFAULT_DATA_ROOT,
    collect_candidates,
    default_picks,
    ensure_ffmpeg_on_path,
    load_manifest,
)


ROOT = Path(__file__).resolve().parent

BACKENDS = [
    {
        "id": "mms",
        "label": "MMS CTC (round1)",
        "stem": "timeline_mms",
        "builder": "ctc",
        "model": "MahmoudAshraf/mms-300m-1130-forced-aligner",
        "romanize": True,
        "method": "mms",
    },
    {
        "id": "en_wav2vec2",
        "label": "EN Wav2Vec2-Large CTC",
        "stem": "timeline_en_wav2vec2",
        "builder": "ctc",
        "model": "facebook/wav2vec2-large-960h-lv60-self",
        "romanize": False,
        "method": "en_wav2vec2",
    },
    {
        "id": "torchaudio_en",
        "label": "torchaudio LV60K FA",
        "stem": "timeline_torchaudio_en",
        "builder": "torchaudio_en",
    },
    {
        "id": "mfa",
        "label": "Montreal Forced Aligner",
        "stem": "timeline_mfa",
        "builder": "mfa",
    },
]


def run_cmd(cmd: list[str], cwd: Path, env: dict | None = None) -> dict:
    proc = subprocess.run(
        cmd,
        cwd=str(cwd),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=env,
    )
    stdout = (proc.stdout or "").strip()
    stderr = (proc.stderr or "").strip()
    parsed = None
    for line in reversed(stdout.splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                parsed = json.loads(line)
                break
            except json.JSONDecodeError:
                continue
    return {"returncode": proc.returncode, "stdout": stdout, "stderr": stderr, "json": parsed}


def english_default_samples(candidates: list[dict]) -> list[dict]:
    picks = default_picks(candidates)
    return [s for s in picks if not s.get("cjk")]


def align_backend(
    py: str,
    backend: dict,
    sample: dict,
    out_dir: Path,
    device: str | None,
    env: dict,
) -> dict:
    lyrics_path = out_dir / "lyrics.txt"
    if not lyrics_path.is_file():
        text = (sample.get("lyrics") or "").replace("\r\n", "\n").replace("\r", "\n")
        lyrics_path.write_text(text.rstrip() + "\n", encoding="utf-8")

    common = [
        "--audio",
        str(sample["audioPath"]),
        "--lyrics",
        str(lyrics_path),
        "--out-dir",
        str(out_dir),
        "--article-id",
        str(sample.get("articleId") or 0),
        "--audio-hash",
        str(sample.get("audioHash") or ""),
        "--lyrics-hash",
        str(sample.get("lyricsHash") or ""),
        "--stem",
        backend["stem"],
    ]

    if backend["builder"] == "ctc":
        cmd = [
            py,
            str(ROOT / "align_one.py"),
            *common,
            "--language",
            "eng",
            "--model",
            backend["model"],
            "--method",
            backend["method"],
            "--source",
            backend["id"],
        ]
        if backend.get("romanize"):
            cmd.append("--romanize")
        else:
            cmd.append("--no-romanize")
        if device:
            cmd.extend(["--device", device])
    elif backend["builder"] == "torchaudio_en":
        cmd = [py, str(ROOT / "align_torchaudio_en.py"), *common]
        if device:
            cmd.extend(["--device", device])
    elif backend["builder"] == "mfa":
        cmd = [py, str(ROOT / "align_mfa.py"), *common]
    else:
        raise ValueError(backend["builder"])

    print(f"=== ALIGN {sample['id']} / {backend['id']} ===", flush=True)
    return run_cmd(cmd, ROOT, env=env)


def write_round2_summary(reports_dir: Path, matrix: list[dict], backends_run: list[dict]) -> Path:
    sample_ids = []
    for row in matrix:
        if row["sampleId"] not in sample_ids:
            sample_ids.append(row["sampleId"])

    lines = [
        "# Round 2 — English subtitle aligner comparison",
        "",
        "Baseline = local BigASR + DP timelines.",
        "Scope = English only (CJK excluded).",
        "Evaluation axes = **timing quality vs BigASR** + **wall-clock cost (alignSeconds / RTF)**.",
        "",
        "## Backends",
        "",
    ]
    for b in backends_run:
        lines.append(f"- `{b['id']}`: {b['label']}")
    lines.extend(["", "## Quality vs BigASR", ""])

    header = "| sample | " + " | ".join(b["id"] + " median/≤500%/verdict" for b in backends_run) + " |"
    sep = "| --- | " + " | ".join("---" for _ in backends_run) + " |"
    lines.extend([header, sep])

    by_sample: dict[str, dict[str, dict]] = {sid: {} for sid in sample_ids}
    for row in matrix:
        by_sample[row["sampleId"]][row["backend"]] = row

    for sid in sample_ids:
        cells = [sid]
        for b in backends_run:
            row = by_sample[sid].get(b["id"])
            if not row:
                cells.append("missing")
                continue
            if row.get("error"):
                cells.append(f"ERR:{row['error']}")
                continue
            m = row.get("metrics") or {}
            start = m.get("start") or {}
            cells.append(
                f"{start.get('median','')} / {m.get('within500MsPct','')}% / {row.get('verdict')}"
            )
        lines.append("| " + " | ".join(cells) + " |")

    lines.extend(
        [
            "",
            "## Runtime (CPU wall clock)",
            "",
            "RTF = `alignSeconds / audioDurationSeconds` (lower is better; 1.0 ≈ realtime).",
            "Model load is listed separately; product path should amortize load across songs.",
            "",
            "| sample | audio s | backend | align s | load s | RTF |",
            "| --- | ---: | --- | ---: | ---: | ---: |",
        ]
    )
    for sid in sample_ids:
        for b in backends_run:
            row = by_sample[sid].get(b["id"]) or {}
            meta = row.get("alignMeta") or {}
            audio_ms = row.get("audioDurationMs")
            if audio_ms is None:
                # fall back from metrics baseline duration if present
                audio_ms = (row.get("metrics") or {}).get("baselineDurationMs")
            audio_s = round(float(audio_ms) / 1000.0, 1) if audio_ms else ""
            if row.get("error"):
                lines.append(f"| {sid} | {audio_s} | {b['id']} | ERR |  |  |")
                continue
            align_s = meta.get("alignSeconds")
            load_s = meta.get("modelLoadSeconds")
            rtf = ""
            if align_s is not None and audio_ms:
                rtf = round(float(align_s) / (float(audio_ms) / 1000.0), 2)
            lines.append(
                f"| {sid} | {audio_s} | {b['id']} | {align_s if align_s is not None else ''} | "
                f"{load_s if load_s is not None else ''} | {rtf} |"
            )

    # Backend runtime aggregates
    lines.extend(["", "### Runtime summary by backend", ""])
    lines.append("| backend | songs ok | mean align s | mean RTF | max RTF |")
    lines.append("| --- | ---: | ---: | ---: | ---: |")
    for b in backends_run:
        ok_rows = [r for r in matrix if r.get("backend") == b["id"] and r.get("verdict")]
        align_vals = []
        rtf_vals = []
        for r in ok_rows:
            meta = r.get("alignMeta") or {}
            align_s = meta.get("alignSeconds")
            audio_ms = r.get("audioDurationMs") or (r.get("metrics") or {}).get("baselineDurationMs")
            if align_s is None:
                continue
            align_vals.append(float(align_s))
            if audio_ms:
                rtf_vals.append(float(align_s) / (float(audio_ms) / 1000.0))
        if not align_vals:
            lines.append(f"| {b['id']} | 0 |  |  |  |")
            continue
        mean_align = round(sum(align_vals) / len(align_vals), 1)
        mean_rtf = round(sum(rtf_vals) / len(rtf_vals), 2) if rtf_vals else ""
        max_rtf = round(max(rtf_vals), 2) if rtf_vals else ""
        lines.append(f"| {b['id']} | {len(align_vals)} | {mean_align} | {mean_rtf} | {max_rtf} |")

    lines.extend(["", "## Detailed quality metrics", ""])
    lines.append(
        "| sample | backend | start median | start MAE | ≤500ms % | >5s % | verdict | align s | RTF |"
    )
    lines.append("| --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: |")
    for row in matrix:
        if row.get("error"):
            lines.append(
                f"| {row['sampleId']} | {row['backend']} |  |  |  |  | {row['error']} |  |  |"
            )
            continue
        m = row.get("metrics") or {}
        start = m.get("start") or {}
        meta = row.get("alignMeta") or {}
        align_s = meta.get("alignSeconds", "")
        audio_ms = row.get("audioDurationMs") or m.get("baselineDurationMs")
        rtf = ""
        if align_s != "" and align_s is not None and audio_ms:
            rtf = round(float(align_s) / (float(audio_ms) / 1000.0), 2)
        lines.append(
            "| {sid} | {backend} | {med} | {mae} | {w500} | {over5} | {verdict} | {align} | {rtf} |".format(
                sid=row["sampleId"],
                backend=row["backend"],
                med=start.get("median", ""),
                mae=start.get("mae", ""),
                w500=m.get("within500MsPct", ""),
                over5=m.get("absStartOver5sPct", ""),
                verdict=row.get("verdict"),
                align=align_s,
                rtf=rtf,
            )
        )

    # Recommendation
    lines.extend(["", "## Recommendation", ""])

    def backend_scores(backend_id: str) -> dict:
        rows = [r for r in matrix if r.get("backend") == backend_id and r.get("verdict")]
        if not rows:
            return {"n": 0}
        replace = sum(1 for r in rows if r["verdict"] == "replace_candidate")
        review = sum(1 for r in rows if r["verdict"] == "needs_listening_review")
        bad = sum(1 for r in rows if r["verdict"] == "not_direct_replace")
        medians = [float((r.get("metrics") or {}).get("start", {}).get("median") or 0) for r in rows]
        rtfs = []
        aligns = []
        for r in rows:
            meta = r.get("alignMeta") or {}
            align_s = meta.get("alignSeconds")
            audio_ms = r.get("audioDurationMs") or (r.get("metrics") or {}).get("baselineDurationMs")
            if align_s is not None:
                aligns.append(float(align_s))
                if audio_ms:
                    rtfs.append(float(align_s) / (float(audio_ms) / 1000.0))
        return {
            "n": len(rows),
            "replace": replace,
            "review": review,
            "bad": bad,
            "median_of_medians": round(sum(medians) / len(medians), 1) if medians else None,
            "mean_rtf": round(sum(rtfs) / len(rtfs), 2) if rtfs else None,
            "mean_align_s": round(sum(aligns) / len(aligns), 1) if aligns else None,
        }

    scored = [(b, backend_scores(b["id"])) for b in backends_run]
    usable = [(b, s) for b, s in scored if s.get("n")]
    if usable:
        # Prefer quality first, then speed (lower mean RTF).
        usable.sort(
            key=lambda pair: (
                -pair[1].get("replace", 0),
                pair[1].get("bad", 99),
                pair[1].get("median_of_medians") or 9e9,
                pair[1].get("mean_rtf") if pair[1].get("mean_rtf") is not None else 9e9,
            )
        )
        best_b, best_s = usable[0]
        lines.append(
            f"- Best quality×speed among runnable backends: **{best_b['id']}** "
            f"({best_b['label']}) — replace_candidate {best_s['replace']}/{best_s['n']}, "
            f"avg median |Δstart|={best_s['median_of_medians']}ms, "
            f"mean RTF={best_s['mean_rtf']}."
        )
        # Explicit MFA speed note if present and slow
        mfa_s = next((s for b, s in scored if b["id"] == "mfa"), None)
        if mfa_s and mfa_s.get("mean_rtf") and mfa_s["mean_rtf"] >= 2.0:
            lines.append(
                f"- MFA mean RTF≈{mfa_s['mean_rtf']} (mean align≈{mfa_s['mean_align_s']}s) — "
                "too slow for interactive creation-center use; treat as research-only unless "
                "batched offline."
            )
        if best_s["replace"] == best_s["n"] and best_s["n"] >= 3 and (best_s.get("mean_rtf") or 99) <= 1.5:
            lines.append(
                "- **Suggestion:** English-only path can trial this backend as BigASR replacement "
                "candidate when RTF stays near realtime, with outlier fallback to BigASR."
            )
        elif best_s["replace"] >= 1 and best_s["bad"] == 0:
            lines.append(
                "- **Suggestion:** Promising offline English backend on quality, but keep BigASR "
                "for hard Suno tracks and as fallback when local RTF/quality gates fail."
            )
        else:
            lines.append(
                "- **Suggestion:** Do not fully replace BigASR yet; keep cloud timings as primary "
                "and treat the best local backend as experimental fallback."
            )
    else:
        lines.append("- No backend produced comparable results.")

    mfa_rows = [r for r in matrix if r.get("backend") == "mfa"]
    if mfa_rows and all(r.get("error") for r in mfa_rows):
        lines.append(
            "- MFA did not run successfully in this environment (see per-sample `align_error.txt`). "
            "Install via conda-forge (`montreal-forced-aligner` + kaldi) and re-run `--backends mfa`."
        )
    elif any(r.get("error") for r in mfa_rows):
        lines.append(
            "- MFA partially failed on some samples (Windows temp DB lock / long jobs). "
            "Successful MFA songs still show high RTF and are included above."
        )

    lines.extend(
        [
            "",
            "## Notes",
            "",
            "- Metrics are agreement with BigASR, not human ground truth.",
            "- BigASR wall-clock was not re-measured here (timelines reused from cache); "
              "product comparison should also log live BigASR latency separately.",
            "- Product Flutter path was not modified.",
            "",
        ]
    )

    path = reports_dir / "summary_round2.md"
    path.write_text("\n".join(lines), encoding="utf-8")
    (reports_dir / "summary_round2.json").write_text(
        json.dumps({"backends": backends_run, "matrix": matrix}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-root", type=Path, default=DEFAULT_DATA_ROOT)
    parser.add_argument("--reports-dir", type=Path, default=ROOT / "reports" / "round2")
    parser.add_argument("--manifest", type=Path, default=None)
    parser.add_argument("--python", type=Path, default=None)
    parser.add_argument("--device", default="cpu", choices=["cpu", "cuda"])
    parser.add_argument(
        "--backends",
        default="mms,en_wav2vec2,torchaudio_en,mfa",
        help="Comma-separated backend ids",
    )
    parser.add_argument(
        "--reuse-mms-from",
        type=Path,
        default=ROOT / "reports",
        help="If set, copy round1 MMS timelines when sample ids match",
    )
    args = parser.parse_args()

    env = os.environ.copy()
    ffmpeg = ensure_ffmpeg_on_path(args.data_root)
    if ffmpeg:
        print(f"Using ffmpeg: {ffmpeg}", flush=True)
        env["PATH"] = str(Path(ffmpeg).parent) + os.pathsep + env.get("PATH", "")

    py = str(args.python or sys.executable)
    candidates = collect_candidates(args.data_root)
    if args.manifest:
        samples = load_manifest(args.manifest, candidates)
    else:
        samples = english_default_samples(candidates)

    wanted = {x.strip() for x in args.backends.split(",") if x.strip()}
    backends = [b for b in BACKENDS if b["id"] in wanted]
    if not backends:
        raise SystemExit(f"No backends selected from {wanted}")

    args.reports_dir.mkdir(parents=True, exist_ok=True)
    matrix: list[dict] = []

    for sample in samples:
        sample_id = str(sample["id"])
        safe_id = "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in sample_id)
        sample_dir = args.reports_dir / safe_id
        sample_dir.mkdir(parents=True, exist_ok=True)
        lyrics_path = sample_dir / "lyrics.txt"
        text = (sample.get("lyrics") or "").replace("\r\n", "\n").replace("\r", "\n")
        lyrics_path.write_text(text.rstrip() + "\n", encoding="utf-8")
        baseline = Path(sample["timelinePath"])

        for backend in backends:
            be_dir = sample_dir / backend["id"]
            be_dir.mkdir(parents=True, exist_ok=True)
            # share lyrics
            if not (be_dir / "lyrics.txt").exists():
                (be_dir / "lyrics.txt").write_text(lyrics_path.read_text(encoding="utf-8"), encoding="utf-8")

            timeline_path = be_dir / f"{backend['stem']}.json"
            reused = False
            if backend["id"] == "mms" and args.reuse_mms_from:
                prev = args.reuse_mms_from / safe_id / "timeline_ctc.json"
                if prev.is_file():
                    timeline_path.write_text(prev.read_text(encoding="utf-8"), encoding="utf-8")
                    meta_src = args.reuse_mms_from / safe_id / "align_meta.json"
                    if meta_src.is_file():
                        (be_dir / f"{backend['stem']}_meta.json").write_text(
                            meta_src.read_text(encoding="utf-8"), encoding="utf-8"
                        )
                    reused = True
                    print(f"=== REUSE MMS {sample_id} ===", flush=True)

            if not reused:
                align_res = align_backend(py, backend, sample, be_dir, args.device, env)
                (be_dir / "align_stdout.txt").write_text(align_res["stdout"], encoding="utf-8")
                (be_dir / "align_stderr.txt").write_text(align_res["stderr"], encoding="utf-8")
                if align_res["returncode"] != 0 or not timeline_path.is_file():
                    matrix.append(
                        {
                            "sampleId": sample_id,
                            "backend": backend["id"],
                            "error": "align_failed",
                            "stderr": (align_res["stderr"] or "")[-2000:],
                            "audioDurationMs": sample.get("durationMs"),
                        }
                    )
                    continue

            baseline_data = json.loads(baseline.read_text(encoding="utf-8"))
            ctc_data = json.loads(timeline_path.read_text(encoding="utf-8"))
            metrics = compare(baseline_data, ctc_data)
            verdict = verdict_for_sample(metrics)
            align_meta = {}
            meta_path = be_dir / f"{backend['stem']}_meta.json"
            if meta_path.is_file():
                align_meta = json.loads(meta_path.read_text(encoding="utf-8"))
            elif (be_dir / "align_meta.json").is_file():
                align_meta = json.loads((be_dir / "align_meta.json").read_text(encoding="utf-8"))

            comparison = {
                "sampleId": sample_id,
                "backend": backend["id"],
                "verdict": verdict,
                "metrics": {k: v for k, v in metrics.items() if k != "rows"},
            }
            (be_dir / "comparison.json").write_text(
                json.dumps(comparison, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
            matrix.append(
                {
                    "sampleId": sample_id,
                    "title": sample.get("title"),
                    "backend": backend["id"],
                    "verdict": verdict,
                    "metrics": comparison["metrics"],
                    "alignMeta": align_meta,
                    "reused": reused,
                    "audioDurationMs": sample.get("durationMs"),
                }
            )

    summary = write_round2_summary(args.reports_dir, matrix, backends)
    print(f"SUMMARY {summary}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
