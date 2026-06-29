# E13 Song ASR Regression Fixture

This fixture documents the saved E13 ASR material used by
`song_subtitle_timeline_service_test.dart`.

Real full diagnostic snapshot kept in this fixture set:

`e13_song_asr_full_20260629_152202.json`

Runtime source diagnostic snapshot:

`F:\TomatoEnglishHappyTalking\release\windows\tomato_english_happy_talking\diagnostics\song-asr-article-63-suno_63_1782637626833_1-20260629-152202.json`

The E13 failure is an optional-parenthetical mismatch. Suno skipped pure
parenthetical source lines such as `(He pronounced it "arrum.")`, while the old
matcher treated a weak nearby `arm`/`arrum` similarity as a sung cue. That stole
time from the following lyric and squeezed line 51 into an unreadable span.

Keep this fixture as a required regression check when changing lyric matching:

- Pure parenthetical lines may be sung by some providers and skipped by others.
- If skipped, they must become boundary cues instead of ASR anchors.
- Line 51 must stay readable and line 52 must keep its own anchor.
