# Round 2 — English subtitle aligner comparison

Baseline = local BigASR + DP timelines.
Scope = English only (CJK excluded).
Evaluation axes = **timing quality vs BigASR** + **wall-clock cost (alignSeconds / RTF)**.

## Backends

- `mms`: MMS CTC (round1)
- `en_wav2vec2`: EN Wav2Vec2-Large CTC
- `torchaudio_en`: torchaudio LV60K FA
- `mfa`: Montreal Forced Aligner

## Quality vs BigASR

| sample | mms median/≤500%/verdict | en_wav2vec2 median/≤500%/verdict | torchaudio_en median/≤500%/verdict | mfa median/≤500%/verdict |
| --- | --- | --- | --- | --- |
| external_audio_235f47f106579d38837c220e | 105.0 / 98.1% / replace_candidate | 990.0 / 35.2% / needs_listening_review | 431.5 / 66.7% / replace_candidate | 345.0 / 61.1% / replace_candidate |
| external_audio_6a5d2508c835f160cd9177c0 | 160.0 / 92.3% / replace_candidate | 250.0 / 92.3% / replace_candidate | 267.0 / 92.3% / replace_candidate | 1074.0 / 46.2% / needs_listening_review |
| external_audio_d53aba491a005fa08d03d4a4 | 125.0 / 90.5% / replace_candidate | 605.0 / 38.1% / needs_listening_review | 245.5 / 95.2% / replace_candidate | 380.0 / 61.9% / replace_candidate |
| suno_52_1782399736565_1 | 1180.0 / 34.0% / needs_listening_review | 4550.0 / 9.4% / not_direct_replace | 816.0 / 49.1% / needs_listening_review | ERR:align_failed |

## Runtime (CPU wall clock)

RTF = `alignSeconds / audioDurationSeconds` (lower is better; 1.0 ≈ realtime).
Model load is listed separately; product path should amortize load across songs.

| sample | audio s | backend | align s | load s | RTF |
| --- | ---: | --- | ---: | ---: | ---: |
| external_audio_235f47f106579d38837c220e | 310.8 | mms | 244.805 | 4.833 | 0.79 |
| external_audio_235f47f106579d38837c220e | 310.8 | en_wav2vec2 | 282.8 | 5.936 | 0.91 |
| external_audio_235f47f106579d38837c220e | 310.8 | torchaudio_en | 479.758 | 88.566 | 1.54 |
| external_audio_235f47f106579d38837c220e | 310.8 | mfa | 243.788 | 0.0 | 0.78 |
| external_audio_6a5d2508c835f160cd9177c0 | 41.3 | mms | 42.957 | 5.077 | 1.04 |
| external_audio_6a5d2508c835f160cd9177c0 | 41.3 | en_wav2vec2 | 44.999 | 7.441 | 1.09 |
| external_audio_6a5d2508c835f160cd9177c0 | 41.3 | torchaudio_en | 22.428 | 4.826 | 0.54 |
| external_audio_6a5d2508c835f160cd9177c0 | 41.3 | mfa | 160.275 | 0.0 | 3.88 |
| external_audio_d53aba491a005fa08d03d4a4 | 192.3 | mms | 168.245 | 7.214 | 0.88 |
| external_audio_d53aba491a005fa08d03d4a4 | 192.3 | en_wav2vec2 | 177.887 | 6.788 | 0.93 |
| external_audio_d53aba491a005fa08d03d4a4 | 192.3 | torchaudio_en | 266.495 | 4.992 | 1.39 |
| external_audio_d53aba491a005fa08d03d4a4 | 192.3 | mfa | 2269.545 | 0.0 | 11.8 |
| suno_52_1782399736565_1 | 377.7 | mms | 312.863 | 5.304 | 0.83 |
| suno_52_1782399736565_1 | 377.7 | en_wav2vec2 | 334.119 | 7.881 | 0.88 |
| suno_52_1782399736565_1 | 377.7 | torchaudio_en | 842.779 | 5.885 | 2.23 |
| suno_52_1782399736565_1 | 377.7 | mfa | ERR |  |  |

### Runtime summary by backend

| backend | songs ok | mean align s | mean RTF | max RTF |
| --- | ---: | ---: | ---: | ---: |
| mms | 4 | 192.2 | 0.88 | 1.04 |
| en_wav2vec2 | 4 | 210.0 | 0.95 | 1.09 |
| torchaudio_en | 4 | 402.9 | 1.43 | 2.23 |
| mfa | 3 | 891.2 | 5.49 | 11.8 |

## Detailed quality metrics

| sample | backend | start median | start MAE | ≤500ms % | >5s % | verdict | align s | RTF |
| --- | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| external_audio_235f47f106579d38837c220e | mms | 105.0 | 154.4 | 98.1 | 0.0 | replace_candidate | 244.805 | 0.79 |
| external_audio_235f47f106579d38837c220e | en_wav2vec2 | 990.0 | 1095.2 | 35.2 | 0.0 | needs_listening_review | 282.8 | 0.91 |
| external_audio_235f47f106579d38837c220e | torchaudio_en | 431.5 | 470.0 | 66.7 | 0.0 | replace_candidate | 479.758 | 1.54 |
| external_audio_235f47f106579d38837c220e | mfa | 345.0 | 612.4 | 61.1 | 1.9 | replace_candidate | 243.788 | 0.78 |
| external_audio_6a5d2508c835f160cd9177c0 | mms | 160.0 | 238.2 | 92.3 | 0.0 | replace_candidate | 42.957 | 1.04 |
| external_audio_6a5d2508c835f160cd9177c0 | en_wav2vec2 | 250.0 | 347.4 | 92.3 | 0.0 | replace_candidate | 44.999 | 1.09 |
| external_audio_6a5d2508c835f160cd9177c0 | torchaudio_en | 267.0 | 340.3 | 92.3 | 0.0 | replace_candidate | 22.428 | 0.54 |
| external_audio_6a5d2508c835f160cd9177c0 | mfa | 1074.0 | 1396.5 | 46.2 | 7.7 | needs_listening_review | 160.275 | 3.88 |
| external_audio_d53aba491a005fa08d03d4a4 | mms | 125.0 | 225.7 | 90.5 | 0.0 | replace_candidate | 168.245 | 0.88 |
| external_audio_d53aba491a005fa08d03d4a4 | en_wav2vec2 | 605.0 | 813.3 | 38.1 | 0.0 | needs_listening_review | 177.887 | 0.93 |
| external_audio_d53aba491a005fa08d03d4a4 | torchaudio_en | 245.5 | 303.4 | 95.2 | 0.0 | replace_candidate | 266.495 | 1.39 |
| external_audio_d53aba491a005fa08d03d4a4 | mfa | 380.0 | 664.8 | 61.9 | 0.0 | replace_candidate | 2269.545 | 11.8 |
| suno_52_1782399736565_1 | mms | 1180.0 | 27709.4 | 34.0 | 47.2 | needs_listening_review | 312.863 | 0.83 |
| suno_52_1782399736565_1 | en_wav2vec2 | 4550.0 | 29569.1 | 9.4 | 49.1 | not_direct_replace | 334.119 | 0.88 |
| suno_52_1782399736565_1 | torchaudio_en | 816.0 | 27274.7 | 49.1 | 45.3 | needs_listening_review | 842.779 | 2.23 |
| suno_52_1782399736565_1 | mfa |  |  |  |  | align_failed |  |  |

## Recommendation

- Best quality×speed among runnable backends: **mms** (MMS CTC (round1)) — replace_candidate 3/4, avg median |Δstart|=392.5ms, mean RTF=0.88.
- MFA mean RTF≈5.49 (mean align≈891.2s) — too slow for interactive creation-center use; treat as research-only unless batched offline.
- **Suggestion:** Promising offline English backend on quality, but keep BigASR for hard Suno tracks and as fallback when local RTF/quality gates fail.
- MFA partially failed on some samples (Windows temp DB lock / long jobs). Successful MFA songs still show high RTF and are included above.

## Notes

- Metrics are agreement with BigASR, not human ground truth.
- BigASR wall-clock was not re-measured here (timelines reused from cache); product comparison should also log live BigASR latency separately.
- Product Flutter path was not modified.
