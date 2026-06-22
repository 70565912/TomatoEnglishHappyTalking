import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/services/song_subtitle_timeline_service.dart';
import 'package:tomato_english_happy_talking/services/streaming_asr_service.dart';

void main() {
  test('cueAtPosition returns null during subtitle gaps', () {
    const timeline = SongSubtitleTimeline(
      version: 1,
      articleId: 7,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 5000,
      source: 'suno',
      cues: [
        SongSubtitleCue(
          lineIndex: 0,
          startMs: 1000,
          endMs: 1500,
          english: 'First line',
        ),
        SongSubtitleCue(
          lineIndex: 1,
          startMs: 2500,
          endMs: 3000,
          english: 'Second line',
        ),
      ],
    );

    expect(SongSubtitleTimelineService.cueAtPosition(timeline, 999), isNull);
    expect(
      SongSubtitleTimelineService.cueAtPosition(timeline, 1200)?.lineIndex,
      0,
    );
    expect(SongSubtitleTimelineService.cueAtPosition(timeline, 2000), isNull);
    expect(
      SongSubtitleTimelineService.cueAtPosition(timeline, 2600)?.lineIndex,
      1,
    );
    expect(SongSubtitleTimelineService.cueAtPosition(timeline, 3200), isNull);
  });

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
    expect(timeline.cues.first.startMs, 220);
    expect(timeline.cues.first.endMs, 1940);
    expect(timeline.cues.first.endMs, lessThan(timeline.cues[1].startMs));
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
    expect(timeline.cues[1].startMs, greaterThan(timeline.cues[0].endMs));
    expect(timeline.cues[1].endMs, timeline.cues[2].startMs);
  });

  test('keeps original lyrics for mismatched interpolated song subtitles', () {
    final timeline = SongSubtitleTimelineService.buildTimeline(
      articleId: 90,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 9000,
      source: 'external_audio',
      lyricLines: const [
        'Opening melody starts now.',
        'Completely different article sentence.',
        'Last line ends the song.',
      ],
      translations: const {
        1: '这句中文不应复用。',
      },
      words: const [
        AsrWordTiming(text: 'opening', startMs: 1000, endMs: 1400),
        AsrWordTiming(text: 'melody', startMs: 1400, endMs: 1800),
        AsrWordTiming(text: 'starts', startMs: 1800, endMs: 2200),
        AsrWordTiming(text: 'now', startMs: 2200, endMs: 2600),
        AsrWordTiming(text: 'the', startMs: 3600, endMs: 3850),
        AsrWordTiming(text: 'singer', startMs: 3850, endMs: 4300),
        AsrWordTiming(text: 'adds', startMs: 4300, endMs: 4700),
        AsrWordTiming(text: 'a', startMs: 4700, endMs: 4850),
        AsrWordTiming(text: 'new', startMs: 4850, endMs: 5200),
        AsrWordTiming(text: 'refrain', startMs: 5200, endMs: 5700),
        AsrWordTiming(text: 'last', startMs: 7000, endMs: 7350),
        AsrWordTiming(text: 'line', startMs: 7350, endMs: 7700),
        AsrWordTiming(text: 'ends', startMs: 7700, endMs: 8150),
        AsrWordTiming(text: 'song', startMs: 8150, endMs: 8500),
      ],
    );

    expect(timeline.cues[1].method, 'interpolated');
    expect(timeline.cues[1].english, 'Completely different article sentence.');
    expect(timeline.cues[1].chinese, '这句中文不应复用。');
    expect(timeline.cues[1].startMs, greaterThan(timeline.cues[0].endMs));
    expect(timeline.cues[1].endMs, timeline.cues[2].startMs);
    expect(timeline.warnings, isNot(contains('部分字幕文字已按 ASR 识别内容替换')));
  });

  test('does not add ASR-only cues between repeated sung lyric anchors', () {
    final timeline = SongSubtitleTimelineService.buildTimeline(
      articleId: 91,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 12000,
      source: 'suno',
      lyricLines: const [
        'Silver boats drift softly.',
        'Golden afternoon shines bright.',
        'Homeward bells are ringing.',
      ],
      translations: const {
        0: '银色小船轻轻漂过。',
        1: '金色午后闪闪发亮。',
        2: '归家的铃声响起。',
      },
      words: const [
        AsrWordTiming(text: 'Silver', startMs: 500, endMs: 900),
        AsrWordTiming(text: 'boats', startMs: 900, endMs: 1300),
        AsrWordTiming(text: 'drift', startMs: 1300, endMs: 1700),
        AsrWordTiming(text: 'softly', startMs: 1700, endMs: 2100),
        AsrWordTiming(text: 'Golden', startMs: 2600, endMs: 3100),
        AsrWordTiming(text: 'afternoon', startMs: 3100, endMs: 3700),
        AsrWordTiming(text: 'shines', startMs: 3700, endMs: 4100),
        AsrWordTiming(text: 'bright', startMs: 4100, endMs: 4500),
        AsrWordTiming(text: 'repeat', startMs: 5000, endMs: 5300),
        AsrWordTiming(text: 'the', startMs: 5300, endMs: 5480),
        AsrWordTiming(text: 'chorus', startMs: 5480, endMs: 5900),
        AsrWordTiming(text: 'one', startMs: 5900, endMs: 6200),
        AsrWordTiming(text: 'more', startMs: 6200, endMs: 6500),
        AsrWordTiming(text: 'time', startMs: 6500, endMs: 6800),
        AsrWordTiming(text: 'Golden', startMs: 7200, endMs: 7700),
        AsrWordTiming(text: 'afternoon', startMs: 7700, endMs: 8300),
        AsrWordTiming(text: 'shines', startMs: 8300, endMs: 8700),
        AsrWordTiming(text: 'bright', startMs: 8700, endMs: 9100),
        AsrWordTiming(text: 'Homeward', startMs: 9500, endMs: 10000),
        AsrWordTiming(text: 'bells', startMs: 10000, endMs: 10400),
        AsrWordTiming(text: 'are', startMs: 10400, endMs: 10650),
        AsrWordTiming(text: 'ringing', startMs: 10650, endMs: 11100),
      ],
    );

    expect(timeline.cues.map((cue) => cue.lineIndex), [0, 1, 2]);
    expect(timeline.cues.every((cue) => cue.method == 'matched'), isTrue);
    expect(timeline.cues.map((cue) => cue.english), [
      'Silver boats drift softly.',
      'Golden afternoon shines bright.',
      'Homeward bells are ringing.',
    ]);
    expect(
      timeline.warnings,
      isNot(contains('ASR 检测到重复唱段，已为重复歌词生成额外字幕')),
    );
    expect(
      () => SongSubtitleTimelineService.validateTimelineCompleteness(
        timeline,
        3,
      ),
      returnsNormally,
    );
  });

  test('ignores ASR-only repeated lyric gaps', () {
    final timeline = SongSubtitleTimelineService.buildTimeline(
      articleId: 92,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 12000,
      source: 'suno',
      lyricLines: const [
        'Silver boats drift softly.',
        'Golden afternoon shines bright.',
        'Homeward bells are ringing.',
      ],
      translations: const {},
      words: const [
        AsrWordTiming(
            text: 'Silver', startMs: 500, endMs: 900, confidence: 0.9),
        AsrWordTiming(
            text: 'boats', startMs: 900, endMs: 1300, confidence: 0.9),
        AsrWordTiming(
            text: 'drift', startMs: 1300, endMs: 1700, confidence: 0.9),
        AsrWordTiming(
            text: 'softly', startMs: 1700, endMs: 2100, confidence: 0.9),
        AsrWordTiming(
            text: 'Golden', startMs: 2600, endMs: 3100, confidence: 0.9),
        AsrWordTiming(
            text: 'afternoon', startMs: 3100, endMs: 3700, confidence: 0.9),
        AsrWordTiming(
            text: 'shines', startMs: 3700, endMs: 4100, confidence: 0.9),
        AsrWordTiming(
            text: 'bright', startMs: 4100, endMs: 4500, confidence: 0.9),
        AsrWordTiming(
            text: 'garbled', startMs: 5000, endMs: 5400, confidence: 0.2),
        AsrWordTiming(
            text: 'uncertain', startMs: 5400, endMs: 5900, confidence: 0.2),
        AsrWordTiming(
            text: 'lyrics', startMs: 5900, endMs: 6400, confidence: 0.2),
        AsrWordTiming(
            text: 'Golden', startMs: 7200, endMs: 7700, confidence: 0.9),
        AsrWordTiming(
            text: 'afternoon', startMs: 7700, endMs: 8300, confidence: 0.9),
        AsrWordTiming(
            text: 'shines', startMs: 8300, endMs: 8700, confidence: 0.9),
        AsrWordTiming(
            text: 'bright', startMs: 8700, endMs: 9100, confidence: 0.9),
        AsrWordTiming(
            text: 'Homeward', startMs: 9500, endMs: 10000, confidence: 0.9),
        AsrWordTiming(
            text: 'bells', startMs: 10000, endMs: 10400, confidence: 0.9),
        AsrWordTiming(
            text: 'are', startMs: 10400, endMs: 10650, confidence: 0.9),
        AsrWordTiming(
            text: 'ringing', startMs: 10650, endMs: 11100, confidence: 0.9),
      ],
    );

    expect(timeline.cues.map((cue) => cue.lineIndex), [0, 1, 2]);
    expect(
        timeline.cues.any((cue) => cue.english == 'Garbled uncertain lyrics'),
        isFalse);
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
              {
                'text': 'Alice',
                'start_time': 100,
                'end_time': 900,
                'confidence': 0.86,
              },
            ],
          },
          {
            'definite': true,
            'start_time': 950,
            'end_time': 1500,
            'text': 'sings',
            'words': [
              {
                'text': 'sings',
                'start_time': 950,
                'end_time': 1500,
                'score': 91,
              },
            ],
          },
        ],
      },
    });

    expect(result, isNotNull);
    expect(result!.durationMs, 3696);
    expect(result.words.map((word) => word.text), ['Alice', 'sings']);
    expect(result.words.last.endMs, 1500);
    expect(result.words.first.confidence, closeTo(0.86, 0.001));
    expect(result.words.last.confidence, closeTo(0.91, 0.001));
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
    expect(srt, contains('00:00:00,320 --> 00:00:02,340'));
    expect(srt, contains('00:00:02,420 --> 00:00:04,270'));
    expect(timeline.cues.first.endMs, lessThan(timeline.cues.last.startMs));
    expect(timeline.cues.last.endMs, 4270);
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
        expect(cue.startMs, greaterThan(timeline.cues[i - 1].endMs));
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

  test('keeps Aliyun MP3 direct and transcodes unsupported Volc formats', () {
    final mp3Format =
        SongSubtitleTimelineService.audioFormatFromMimeTypeForTest(
      SongSubtitleTimelineService.audioMimeTypeForPathForTest('song.mp3'),
    );
    final m4aFormat =
        SongSubtitleTimelineService.audioFormatFromMimeTypeForTest(
      SongSubtitleTimelineService.audioMimeTypeForPathForTest('song.m4a'),
    );

    expect(mp3Format, 'mp3');
    expect(
      SongSubtitleTimelineService.providerSupportsOriginalAudioForTest(
        provider: AppConfig.aiProviderAliyunBailian,
        audioFormat: mp3Format,
      ),
      isTrue,
    );
    expect(
      SongSubtitleTimelineService.providerSupportsOriginalAudioForTest(
        provider: AppConfig.aiProviderVolcengine,
        audioFormat: mp3Format,
      ),
      isFalse,
    );
    expect(m4aFormat, 'aac');
    expect(
      SongSubtitleTimelineService.providerSupportsOriginalAudioForTest(
        provider: AppConfig.aiProviderVolcengine,
        audioFormat: m4aFormat,
      ),
      isFalse,
    );
  });

  test('rejects stale timeline files without current alignment version',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'tomato_stale_song_timeline_',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final file = File('${directory.path}/timeline.json');
    await file.writeAsString(jsonEncode({
      'version': 1,
      'articleId': 1,
      'audioHash': 'audio',
      'lyricsHash': 'lyrics',
      'durationMs': 1000,
      'source': 'suno',
      'cues': const [],
    }));

    final raw = await SongSubtitleTimelineService.readTimeline(file.path);
    expect(raw.alignmentVersion, 0);
    expect(SongSubtitleTimelineService.isCurrentTimeline(raw), isFalse);
    await expectLater(
      SongSubtitleTimelineService.readCurrentTimeline(file.path),
      throwsA(
        isA<SongSubtitleTimelineException>().having(
          (error) => error.message,
          'message',
          SongSubtitleTimelineService.staleTimelineMessage,
        ),
      ),
    );
  });
}
