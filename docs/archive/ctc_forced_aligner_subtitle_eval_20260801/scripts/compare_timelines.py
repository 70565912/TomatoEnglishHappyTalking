#!/usr/bin/env python3
"""Compare BigASR baseline timeline vs CTC timeline cue-by-cue."""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path


def load_timeline(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not isinstance(data.get("cues"), list):
        raise SystemExit(f"Invalid timeline JSON: {path}")
    return data


def percentile(sorted_vals: list[float], p: float) -> float:
    if not sorted_vals:
        return 0.0
    if len(sorted_vals) == 1:
        return float(sorted_vals[0])
    k = (len(sorted_vals) - 1) * (p / 100.0)
    f = int(k)
    c = min(f + 1, len(sorted_vals) - 1)
    if f == c:
        return float(sorted_vals[f])
    return float(sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f))


def summarize_abs(values: list[float]) -> dict:
    if not values:
        return {
            "count": 0,
            "mae": 0.0,
            "median": 0.0,
            "p90": 0.0,
            "max": 0.0,
        }
    ordered = sorted(values)
    return {
        "count": len(values),
        "mae": round(statistics.fmean(values), 1),
        "median": round(statistics.median(values), 1),
        "p90": round(percentile(ordered, 90), 1),
        "max": round(max(values), 1),
    }


def compare(baseline: dict, ctc: dict) -> dict:
    base_cues = list(baseline.get("cues") or [])
    ctc_cues = list(ctc.get("cues") or [])
    n = min(len(base_cues), len(ctc_cues))
    rows: list[dict] = []
    abs_start: list[float] = []
    abs_end: list[float] = []
    abs_dur: list[float] = []
    within_300 = within_500 = within_1000 = 0
    collapse_or_stretch = 0
    bad_5s = 0

    for i in range(n):
        b = base_cues[i]
        c = ctc_cues[i]
        b_start = int(b.get("startMs") or 0)
        b_end = int(b.get("endMs") or 0)
        c_start = int(c.get("startMs") or 0)
        c_end = int(c.get("endMs") or 0)
        b_dur = max(0, b_end - b_start)
        c_dur = max(0, c_end - c_start)
        d_start = c_start - b_start
        d_end = c_end - b_end
        d_dur = c_dur - b_dur
        a_start = abs(d_start)
        a_end = abs(d_end)
        a_dur = abs(d_dur)
        abs_start.append(float(a_start))
        abs_end.append(float(a_end))
        abs_dur.append(float(a_dur))
        if a_start <= 300:
            within_300 += 1
        if a_start <= 500:
            within_500 += 1
        if a_start <= 1000:
            within_1000 += 1
        if a_start > 5000:
            bad_5s += 1
        ratio_flag = False
        if b_dur > 0 and (c_dur / b_dur > 2.0 or b_dur / max(c_dur, 1) > 2.0):
            ratio_flag = True
        if a_start > 5000 or ratio_flag:
            collapse_or_stretch += 1
        rows.append(
            {
                "lineIndex": i,
                "english": str(b.get("english") or c.get("english") or "")[:120],
                "baselineStartMs": b_start,
                "baselineEndMs": b_end,
                "ctcStartMs": c_start,
                "ctcEndMs": c_end,
                "deltaStartMs": d_start,
                "deltaEndMs": d_end,
                "deltaDurMs": d_dur,
                "absStartMs": a_start,
                "absEndMs": a_end,
                "collapseOrStretch": bool(a_start > 5000 or ratio_flag),
            }
        )

    def pct(count: int) -> float:
        return round(100.0 * count / n, 1) if n else 0.0

    worst = sorted(rows, key=lambda r: r["absStartMs"], reverse=True)[:10]
    return {
        "baselineCueCount": len(base_cues),
        "ctcCueCount": len(ctc_cues),
        "comparedLines": n,
        "cueCountMismatch": len(base_cues) != len(ctc_cues),
        "baselineDurationMs": baseline.get("durationMs"),
        "ctcDurationMs": ctc.get("durationMs"),
        "start": summarize_abs(abs_start),
        "end": summarize_abs(abs_end),
        "durationDelta": summarize_abs(abs_dur),
        "within300MsPct": pct(within_300),
        "within500MsPct": pct(within_500),
        "within1000MsPct": pct(within_1000),
        "absStartOver5sPct": pct(bad_5s),
        "absStartOver5sCount": bad_5s,
        "collapseOrStretchCount": collapse_or_stretch,
        "collapseOrStretchPct": pct(collapse_or_stretch),
        "worstLines": worst,
        "rows": rows,
    }


def verdict_for_sample(metrics: dict) -> str:
    median = float(metrics["start"]["median"])
    over5 = float(metrics["absStartOver5sPct"])
    if median <= 500 and over5 < 5:
        return "replace_candidate"
    if median <= 1500:
        return "needs_listening_review"
    return "not_direct_replace"


def render_markdown(sample_id: str, metrics: dict, verdict: str) -> str:
    lines = [
        f"# Comparison: {sample_id}",
        "",
        f"- Compared lines: {metrics['comparedLines']} "
        f"(baseline {metrics['baselineCueCount']}, ctc {metrics['ctcCueCount']})",
        f"- Start MAE / median / P90 / max (ms): "
        f"{metrics['start']['mae']} / {metrics['start']['median']} / "
        f"{metrics['start']['p90']} / {metrics['start']['max']}",
        f"- End MAE / median / P90 / max (ms): "
        f"{metrics['end']['mae']} / {metrics['end']['median']} / "
        f"{metrics['end']['p90']} / {metrics['end']['max']}",
        f"- |Δstart| within 300 / 500 / 1000 ms: "
        f"{metrics['within300MsPct']}% / {metrics['within500MsPct']}% / {metrics['within1000MsPct']}%",
        f"- |Δstart| > 5s: {metrics['absStartOver5sCount']} ({metrics['absStartOver5sPct']}%)",
        f"- Collapse/stretch flags: {metrics['collapseOrStretchCount']} "
        f"({metrics['collapseOrStretchPct']}%)",
        f"- Verdict: **{verdict}**",
        "",
        "## Worst 10 lines by |Δstart|",
        "",
        "| line | Δstart ms | base start | ctc start | text |",
        "| ---: | ---: | ---: | ---: | --- |",
    ]
    for row in metrics["worstLines"]:
        text = row["english"].replace("|", "\\|")
        lines.append(
            f"| {row['lineIndex']} | {row['deltaStartMs']} | {row['baselineStartMs']} | "
            f"{row['ctcStartMs']} | {text} |"
        )
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--ctc", required=True, type=Path)
    parser.add_argument("--out-dir", required=True, type=Path)
    parser.add_argument("--sample-id", default="sample")
    args = parser.parse_args()

    baseline = load_timeline(args.baseline)
    ctc = load_timeline(args.ctc)
    metrics = compare(baseline, ctc)
    verdict = verdict_for_sample(metrics)
    payload = {
        "sampleId": args.sample_id,
        "baselinePath": str(args.baseline),
        "ctcPath": str(args.ctc),
        "verdict": verdict,
        "metrics": {k: v for k, v in metrics.items() if k != "rows"},
        "rows": metrics["rows"],
    }

    args.out_dir.mkdir(parents=True, exist_ok=True)
    json_path = args.out_dir / "comparison.json"
    md_path = args.out_dir / "comparison.md"
    json_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    md_path.write_text(render_markdown(args.sample_id, metrics, verdict), encoding="utf-8")
    print(
        json.dumps(
            {
                "ok": True,
                "sampleId": args.sample_id,
                "verdict": verdict,
                "startMedianMs": metrics["start"]["median"],
                "startMaeMs": metrics["start"]["mae"],
                "within500MsPct": metrics["within500MsPct"],
                "absStartOver5sPct": metrics["absStartOver5sPct"],
                "comparisonJson": str(json_path),
                "comparisonMd": str(md_path),
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
