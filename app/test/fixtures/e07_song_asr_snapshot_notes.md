# E07 Song ASR Regression Fixture

This fixture documents the saved E07 ASR material used by
`song_subtitle_timeline_service_test.dart`.

Real full diagnostic snapshot kept in this fixture set:

`e07_song_asr_full_20260625_233843.json`

Runtime source diagnostic snapshot:

`F:\TomatoEnglishHappyTalking\release\windows\tomato_english_happy_talking\diagnostics\song-asr-article-52-suno_52_1782399736565_1-20260625-233843.json`

The E07 failure is a weak-anchor cascade. In the real ASR words, the line
`and four times six is thirteen,` is sung without the leading `and`. The old
matcher searched ahead for that leading `and`, grabbed the next line's
`and four times seven is`, and then pushed the following line onto a later
`and Rome...` phrase. That single wrong anchor produced huge interpolated
cues followed by many 250 ms cues.

Keep this fixture as a required regression check when changing lyric matching:

- Line 9 must anchor around the real `four times six is thirteen` words, even
  though ASR omitted the lyric's leading `and`.
- Line 10 must anchor around the real `and four times seven is` words, not a
  later repeated `and`.
- Lines 11 and 12 must not become 71 s / 35 s interpolated cues.
- The middle inferred region must stay readable and the full build must finish
  quickly enough to guard against the previous matching-timeout regressions.
