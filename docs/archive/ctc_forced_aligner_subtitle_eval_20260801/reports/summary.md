# CTC Forced Aligner vs BigASR Timeline — Eval Summary

Baseline = existing local BigASR + DP `song-subtitle-timelines` (not human ground truth).
CTC = MahmoudAshraf97/ctc-forced-aligner (MMS), word/char align then aggregate to lyric lines.
Device = CPU (torch 2.13+cpu). First model load ~50s; per-song align roughly 1.0–1.1× audio duration on this machine.

## Decision thresholds

- **replace_candidate**: median `|Δstart| ≤ 500ms` and `|Δstart| > 5s` lines < 5%
- **needs_listening_review**: median `|Δstart| ≤ 1.5s` (or hard samples diverge)
- **not_direct_replace**: worse than that, or systematic collapse/stretch

## Samples

| sample | article | title | duration ms | lines | start median | start MAE | ≤500ms % | >5s % | verdict | align s |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |
| external_audio_235f47f106579d38837c220e | 66 | The Caterpillar and Alice (E16) | 310776 | 54 | 105.0 | 154.4 | 98.1 | 0.0 | replace_candidate | 244.8 |
| external_audio_6a5d2508c835f160cd9177c0 | 69 | Sandwich Anthem | 41256 | 13 | 160.0 | 238.2 | 92.3 | 0.0 | replace_candidate | 43.0 |
| external_audio_d53aba491a005fa08d03d4a4 | 54 | The Pool Party | 192264 | 42 | 125.0 | 225.7 | 90.5 | 0.0 | replace_candidate | 168.2 |
| suno_52_1782399736565_1 | 52 | E07 - Am I Still Alice | 377664 | 53 | 1180.0 | 27709.4 | 34.0 | 47.2 | needs_listening_review | 312.9 |
| external_audio_3291eab0503714debebfcbae | 92 | 我是一根葱 (CJK) | 284760 | 51 | 5770.0 | 6377.0 | 3.9 | 62.7 | not_direct_replace | 227.0 |

Per-sample details: `reports/<sample_id>/comparison.md`, `timeline_ctc.json`, `timeline_ctc.srt`.

## Overall recommendation

- English songs: **needs_listening_review** (3/4 agree closely with BigASR; 1 long Suno track diverges badly)
- Chinese / CJK songs: **not_direct_replace** (single local CJK sample median `|Δstart| ≈ 5.8s`)

**Suggestion:** Do **not** replace BigASR API in the product path yet.

- For clean English story/song audio that already matches lyrics closely (E16 / short spoken-sung tracks), CTC can land within ~100–200ms median of BigASR and is a plausible **offline/free fallback** after more listening QA.
- Long Suno tracks with likely instrumental gaps / lyric drift (E07) show catastrophic mid/late-line skew vs BigASR; CTC alone is not safe as the only timing source.
- CJK (MMS + romanize/char) did not track the current BigASR Chinese timeline on the onion sample; keep Volc BigASR `show_utterances` for Chinese.

## Notes

- Agreement with BigASR ≠ absolute lyric-to-audio ground truth; listen to worst lines before any product decision.
- Runtime: CPU-only, ~40s–5min per song here; model is large (HF MMS). Not suitable to ship inside the Flutter EXE without a separate sidecar design.
- Product path (`listening.songTimelineGenerate` / `SongSubtitleTimelineService`) was **not** modified.
- Re-run: see `README.md`. Default picks come from `release/windows/tomato_english_happy_talking`.
