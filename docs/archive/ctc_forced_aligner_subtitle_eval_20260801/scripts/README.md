# CTC Forced Aligner offline subtitle eval

Compare [MahmoudAshraf97/ctc-forced-aligner](https://github.com/MahmoudAshraf97/ctc-forced-aligner) line timings against existing BigASR + DP timelines under the Windows release data root.

This is an **evaluation harness only**. It does not change Flutter `SongSubtitleTimelineService` or `listening.songTimelineGenerate`.

## Setup (Windows)

Use Python 3.13 (avoid the machine default 3.14 launcher):

```powershell
cd F:\TomatoEnglishHappyTalking\tools\eval_ctc_subtitle_align
D:\DevTools\python\Python313\python.exe -m venv .venv
.\.venv\Scripts\python.exe -m pip install -U pip
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

Prerequisites:

- `ffmpeg` on PATH (or App bundled `ffmpeg.exe` available to torchaudio backends)
- First run downloads the MMS alignment model from Hugging Face

## Single song

```powershell
.\.venv\Scripts\python.exe .\align_one.py `
  --audio "F:\...\song.mp3" `
  --lyrics .\reports\sample\lyrics.txt `
  --out-dir .\reports\sample `
  --language eng
```

Outputs:

- `timeline_ctc.json` — same cue schema as product timelines (`lineIndex/startMs/endMs/english/method=ctc`)
- `timeline_ctc.srt`
- `align_meta.json`

## Compare to BigASR baseline

```powershell
.\.venv\Scripts\python.exe .\compare_timelines.py `
  --baseline "F:\...\tomato_api_cache\song-subtitle-timelines\....json" `
  --ctc .\reports\sample\timeline_ctc.json `
  --out-dir .\reports\sample `
  --sample-id my-sample
```

## Batch (default picks)

Default picks from `release\windows\tomato_english_happy_talking`:

- article 66 / E16 Caterpillar (hard case)
- one short English track
- one mid-length English track
- one long English track
- one CJK track if present

```powershell
.\.venv\Scripts\python.exe .\run_batch.py `
  --data-root F:\TomatoEnglishHappyTalking\release\windows\tomato_english_happy_talking `
  --python .\.venv\Scripts\python.exe
```

Optional `--manifest path.json` with either a list of version ids or full sample objects.

Reports land in `reports/<sample_id>/` plus `reports/summary.md`.

## Verdict labels

Relative to BigASR baseline (not human GT):

| Label | Rule |
| --- | --- |
| `replace_candidate` | median `\|Δstart\| ≤ 500ms` and `\|Δstart\| > 5s` lines &lt; 5% |
| `needs_listening_review` | median `\|Δstart\| ≤ 1.5s` |
| `not_direct_replace` | worse / systematic collapse |

## Round 2 (English multi-backend)

```powershell
.\.venv\Scripts\python.exe .\run_round2.py `
  --backends mms,en_wav2vec2,torchaudio_en `
  --reuse-mms-from .\reports
```

- `align_torchaudio_en.py` — torchaudio `WAV2VEC2_ASR_LARGE_LV60K_960H`
- `align_mfa.py` — Montreal Forced Aligner (requires `mfa` on PATH / conda)
- Report: `reports/round2/summary_round2.md`
