import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/song_subtitle_timeline_service.dart';
import 'package:tomato_english_happy_talking/services/streaming_asr_service.dart';

void main() {
  test('builds matched timeline from exact ASR word timings', () {
    final timeline = SongSubtitleTimelineService.buildTimeline(
      articleId: 7,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 5000,
      source: 'suno',
      lyricLines: const [
        'Alice follows the song.',
        'The garden waits for her.',
      ],
      translations: const {
        0: '爱丽丝跟着歌曲。',
        1: '花园在等她。',
      },
      words: const [
        AsrWordTiming(text: 'Alice', startMs: 400, endMs: 800),
        AsrWordTiming(text: 'follows', startMs: 800, endMs: 1250),
        AsrWordTiming(text: 'the', startMs: 1250, endMs: 1400),
        AsrWordTiming(text: 'song', startMs: 1400, endMs: 1900),
        AsrWordTiming(text: 'The', startMs: 2200, endMs: 2450),
        AsrWordTiming(text: 'garden', startMs: 2450, endMs: 2950),
        AsrWordTiming(text: 'waits', startMs: 2950, endMs: 3400),
        AsrWordTiming(text: 'for', startMs: 3400, endMs: 3600),
        AsrWordTiming(text: 'her', startMs: 3600, endMs: 3950),
      ],
    );

    expect(timeline.cues, hasLength(2));
    expect(timeline.cues.first.method, 'matched');
    expect(timeline.cues.first.english, 'Alice follows the song.');
    expect(timeline.cues.first.chinese, '爱丽丝跟着歌曲。');
    expect(timeline.cues.first.startMs, 0);
    expect(timeline.cues.first.endMs, timeline.cues[1].startMs);
    expect(timeline.confidence, greaterThan(0.8));
  });

  test('uses fuzzy word matching for sung ASR near-misses', () {
    final timeline = SongSubtitleTimelineService.buildTimeline(
      articleId: 8,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 4000,
      source: 'suno',
      lyricLines: const ['The queen is in the light.'],
      translations: const {},
      words: const [
        AsrWordTiming(text: 'the', startMs: 500, endMs: 700),
        AsrWordTiming(text: 'green', startMs: 700, endMs: 1200),
        AsrWordTiming(text: 'is', startMs: 1200, endMs: 1400),
        AsrWordTiming(text: 'in', startMs: 1400, endMs: 1600),
        AsrWordTiming(text: 'the', startMs: 1600, endMs: 1800),
        AsrWordTiming(text: 'night', startMs: 1800, endMs: 2400),
      ],
    );

    expect(timeline.cues.single.method, 'matched');
    expect(timeline.cues.single.confidence, greaterThan(0.55));
  });

  test('interpolates missing lyric lines between matched anchors', () {
    final timeline = SongSubtitleTimelineService.buildTimeline(
      articleId: 9,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 9000,
      source: 'suno',
      lyricLines: const [
        'First line finds a tune.',
        'Silent middle words arrive.',
        'Last line ends the song.',
      ],
      translations: const {},
      words: const [
        AsrWordTiming(text: 'first', startMs: 1000, endMs: 1400),
        AsrWordTiming(text: 'line', startMs: 1400, endMs: 1800),
        AsrWordTiming(text: 'finds', startMs: 1800, endMs: 2200),
        AsrWordTiming(text: 'tune', startMs: 2200, endMs: 2600),
        AsrWordTiming(text: 'last', startMs: 7000, endMs: 7350),
        AsrWordTiming(text: 'line', startMs: 7350, endMs: 7700),
        AsrWordTiming(text: 'ends', startMs: 7700, endMs: 8150),
        AsrWordTiming(text: 'song', startMs: 8150, endMs: 8500),
      ],
    );

    expect(timeline.cues[0].method, 'matched');
    expect(timeline.cues[1].method, 'interpolated');
    expect(timeline.cues[2].method, 'matched');
    expect(timeline.cues[1].startMs, timeline.cues[0].endMs);
    expect(timeline.cues[1].endMs, timeline.cues[2].startMs);
  });

  test('falls back to weighted continuous cues when no words match', () {
    final timeline = SongSubtitleTimelineService.buildTimeline(
      articleId: 10,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 6000,
      source: 'suno',
      lyricLines: const [
        'One line.',
        'Another longer singing line.',
      ],
      translations: const {},
      words: const [],
    );

    expect(timeline.cues, hasLength(2));
    expect(timeline.cues.every((cue) => cue.method == 'fallback'), isTrue);
    expect(timeline.cues.first.startMs, 0);
    expect(timeline.cues.first.endMs, timeline.cues.last.startMs);
    expect(timeline.cues.last.endMs, 6000);
  });

  test('parses BigASR utterance word timestamps', () {
    final result = StreamingAsrService.timelineResultFromPayloadForTest({
      'audio_info': {'duration': 3696},
      'result': {
        'text': 'Alice sings.',
        'utterances': [
          {
            'definite': true,
            'start_time': 100,
            'end_time': 900,
            'text': 'Alice',
            'words': [
              {'text': 'Alice', 'start_time': 100, 'end_time': 900},
            ],
          },
          {
            'definite': true,
            'start_time': 950,
            'end_time': 1500,
            'text': 'sings',
            'words': [
              {'text': 'sings', 'start_time': 950, 'end_time': 1500},
            ],
          },
        ],
      },
    });

    expect(result, isNotNull);
    expect(result!.durationMs, 3696);
    expect(result.words.map((word) => word.text), ['Alice', 'sings']);
    expect(result.words.last.endMs, 1500);
  });

  test('writes monotonic SRT with original lyrics and translations', () {
    final timeline = SongSubtitleTimelineService.buildTimeline(
      articleId: 11,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 4500,
      source: 'suno',
      lyricLines: const [
        'Tom finds a bright snack box.',
        'He shares it with his team.',
      ],
      translations: const {
        0: '汤姆发现了一个明亮的零食盒。',
        1: '他把它分享给自己的队友。',
      },
      words: const [
        AsrWordTiming(text: 'Tom', startMs: 500, endMs: 700),
        AsrWordTiming(text: 'finds', startMs: 700, endMs: 950),
        AsrWordTiming(text: 'bright', startMs: 1200, endMs: 1650),
        AsrWordTiming(text: 'snack', startMs: 1650, endMs: 2100),
        AsrWordTiming(text: 'box', startMs: 2100, endMs: 2400),
        AsrWordTiming(text: 'He', startMs: 2600, endMs: 2800),
        AsrWordTiming(text: 'shares', startMs: 2800, endMs: 3250),
        AsrWordTiming(text: 'team', startMs: 3600, endMs: 3950),
      ],
    );

    final srt = SongSubtitleTimelineService.srtForTimeline(timeline);

    expect(srt, contains('Tom finds a bright snack box.'));
    expect(srt, contains('汤姆发现了一个明亮的零食盒。'));
    expect(srt, contains('He shares it with his team.'));
    expect(srt, contains('00:00:00,080 --> 00:00:02,180'));
    expect(srt, contains('00:00:02,180 --> 00:00:04,500'));
    expect(timeline.cues.first.endMs, timeline.cues.last.startMs);
    expect(timeline.cues.last.endMs, 4500);
  });

  test('collapses implausibly short trailing lyrics without vocal anchors', () {
    final timeline = SongSubtitleTimelineService.buildTimeline(
      articleId: 12,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 10000,
      source: 'suno',
      lyricLines: const [
        'First line matches clearly.',
        'Second line also matches.',
        'Third line must be estimated.',
        'Fourth line must be estimated.',
        'Fifth line must be estimated.',
      ],
      translations: const {},
      words: const [
        AsrWordTiming(text: 'First', startMs: 1000, endMs: 1400),
        AsrWordTiming(text: 'line', startMs: 1400, endMs: 1750),
        AsrWordTiming(text: 'matches', startMs: 1750, endMs: 2300),
        AsrWordTiming(text: 'clearly', startMs: 2300, endMs: 2800),
        AsrWordTiming(text: 'Second', startMs: 8800, endMs: 9100),
        AsrWordTiming(text: 'line', startMs: 9100, endMs: 9350),
        AsrWordTiming(text: 'also', startMs: 9350, endMs: 9600),
        AsrWordTiming(text: 'matches', startMs: 9600, endMs: 9900),
      ],
    );

    expect(timeline.cues, hasLength(2));
    expect(timeline.cues.last.lineIndex, 1);
    expect(timeline.cues.last.endMs, 10000);
    for (var i = 0; i < timeline.cues.length; i += 1) {
      final cue = timeline.cues[i];
      expect(cue.endMs, lessThanOrEqualTo(timeline.durationMs));
      expect(cue.endMs, greaterThan(cue.startMs));
      if (i > 0) {
        expect(cue.startMs, timeline.cues[i - 1].endMs);
      }
    }
    expect(timeline.warnings.join('\n'), contains('尾部 3 行歌词缺少可靠人声匹配'));
  });

  test('rejects incomplete song timelines before caching', () {
    final timeline = SongSubtitleTimelineService.buildTimeline(
      articleId: 13,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 10000,
      source: 'suno',
      lyricLines: const [
        'First line matches clearly.',
        'Second line also matches.',
        'Third line is missing from the song.',
        'Fourth line is missing from the song.',
        'Fifth line is missing from the song.',
      ],
      translations: const {},
      words: const [
        AsrWordTiming(text: 'First', startMs: 1000, endMs: 1400),
        AsrWordTiming(text: 'line', startMs: 1400, endMs: 1750),
        AsrWordTiming(text: 'matches', startMs: 1750, endMs: 2300),
        AsrWordTiming(text: 'clearly', startMs: 2300, endMs: 2800),
        AsrWordTiming(text: 'Second', startMs: 8800, endMs: 9100),
        AsrWordTiming(text: 'line', startMs: 9100, endMs: 9350),
        AsrWordTiming(text: 'also', startMs: 9350, endMs: 9600),
        AsrWordTiming(text: 'matches', startMs: 9600, endMs: 9900),
      ],
    );

    expect(
      () => SongSubtitleTimelineService.validateTimelineCompleteness(
        timeline,
        5,
      ),
      throwsA(
        isA<SongSubtitleTimelineException>().having(
          (error) => error.message,
          'message',
          contains('只覆盖到 2/5 行'),
        ),
      ),
    );
  });
}
