import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/services/song_subtitle_timeline_service.dart';
import 'package:tomato_english_happy_talking/services/streaming_asr_service.dart';

List<AsrWordTiming> _e03FixtureWords(String key) {
  final fixture = jsonDecode(
    File('test/fixtures/e03_song_asr_regression_words.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  return _asrWordsFromRows(fixture[key] as List<dynamic>);
}

List<AsrWordTiming> _e03FullAsrWords() {
  final fixture = jsonDecode(
    File('test/fixtures/e03_song_asr_full_20260622_233253.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;
  return _asrWordsFromRows(fixture['words'] as List<dynamic>);
}

Map<String, dynamic> _e07Fixture() {
  return jsonDecode(
    File('test/fixtures/e07_song_asr_full_20260625_233843.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;
}

List<AsrWordTiming> _e07FullAsrWords() {
  final fixture = _e07Fixture();
  return _asrWordsFromRows(fixture['words'] as List<dynamic>);
}

List<String> _e07LyricLines() {
  final fixture = _e07Fixture();
  return (fixture['lyricLines'] as List<dynamic>)
      .map((line) => line as String)
      .toList(growable: false);
}

List<AsrWordTiming> _asrWordsFromRows(List<dynamic> rows) {
  return rows.map((entry) {
    final row = entry as Map<String, dynamic>;
    return AsrWordTiming(
      text: row['text'] as String,
      startMs: row['startMs'] as int,
      endMs: row['endMs'] as int,
    );
  }).toList();
}

const _e03LyricLines = [
  'Down, down, down.',
  'Would the fall never come to an end?',
  '"I wonder how many miles I\'ve fallen by this time?" she said aloud.',
  '"I must be getting somewhere near the center of the earth. Let me see:',
  'that would be four thousand miles down, I think—"',
  '(for, you see, Alice had learned several things of this sort in her lessons in the schoolroom,',
  'and though this was not a very good opportunity for showing off her knowledge,',
  'as there was no one to listen to her,',
  'still it was good practice to say it over) "—',
  'yes, that\'s about the right distance—',
  'but then I wonder what Latitude or Longitude I\'ve got to?"',
  '(Alice had not the slightest idea what Latitude was,',
  'or Longitude either, but she thought they were nice grand words to say.)',
  'Presently she began again.',
  '"I wonder if I shall fall right through the earth! How funny it\'ll seem to come',
  'out among the people that walk with their heads downward! The Antipathies,',
  'I think" (she was rather glad there was no one listening this time, as it didn\'t',
  'sound at all the right word),',
  '"but I shall have to ask them what the name of the country is, you know.',
  'Please, ma\'am, is this New Zealand or Australia?"',
  '(and she tried to courtsey as she spoke—',
  'fancy courtseying as you\'re falling through the air!',
  'Do you think you could manage it?)',
  '"And what an ignorant little girl she\'ll think me for asking! No, it\'ll never do to ask:',
  'perhaps I shall see it written up somewhere."',
  'Down, down, down.',
  'There was nothing else to do,',
  'so Alice soon began talking again.',
  '"Dinah\'ll miss me very much to-night, I should think!"',
  '(Dinah was the cat.)',
  '"I hope they\'ll remember her saucer of milk at tea-time. Dinah, my dear! I wish you',
  'were down here with me! There are no mice in the air,',
  'I\'m afraid, but you might catch a bat,',
  'and that\'s very like a mouse you know. But do cats eat bats, I wonder?"',
  'And here Alice began to get rather sleepy,',
  'and went on saying to herself, in a dreamy sort of way,',
  '"Do cats eat bats? Do cats eat bats?" and sometimes,',
  '"Do bats eat cats?" for, you see,',
  'as she couldn\'t answer either question, it didn\'t much matter which way she put it.',
  'She felt that she was dozing off,',
  'and had just begun to dream that she was walking hand in hand with Dinah,',
  'and was saying to her very earnestly,',
  '"Now, Dinah, tell me the truth:',
  'did you ever eat a bat?" when suddenly, thump! thump! down she came upon a heap',
  'of sticks and dry leaves,',
  'and the fall was over.',
  'Alice was not a bit hurt,',
  'and she jumped up on to her feet in a moment:',
  'she looked up, but it was all dark overhead;',
  'before her was another long passage,',
  'and the White Rabbit was still in sight, hurrying down it.',
  'There was not a moment to be lost:',
  'away went Alice like the wind,',
  'and was just in time to hear it say,',
  'as it turned a corner.',
  '"Oh, my ears and whiskers, how late it\'s getting!"',
  'She was close behind it when she turned the corner,',
  'but the Rabbit was no longer to be seen:',
  'she found herself in a long, low hall,',
  'which was lit up by a row of lamps hanging from the roof.',
];

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

  test('keeps squeezed inferred lyric lines readable', () {
    final timeline = SongSubtitleTimelineService.buildTimeline(
      articleId: 93,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 15000,
      source: 'suno',
      lyricLines: const [
        'Alice was not a bit hurt,',
        'and she jumped up on to her feet in a moment:',
        'she looked up, but it was all dark overhead;',
        'before her was another long passage,',
      ],
      translations: const {},
      words: const [
        AsrWordTiming(text: 'Alice', startMs: 1000, endMs: 1300),
        AsrWordTiming(text: 'was', startMs: 1300, endMs: 1500),
        AsrWordTiming(text: 'not', startMs: 1500, endMs: 1700),
        AsrWordTiming(text: 'a', startMs: 1700, endMs: 1820),
        AsrWordTiming(text: 'bit', startMs: 1820, endMs: 2050),
        AsrWordTiming(text: 'hurt', startMs: 2050, endMs: 2500),
        AsrWordTiming(text: 'and', startMs: 3000, endMs: 3300),
        AsrWordTiming(text: 'she', startMs: 3300, endMs: 3600),
        AsrWordTiming(text: 'jumped', startMs: 3600, endMs: 4050),
        AsrWordTiming(text: 'up', startMs: 4050, endMs: 4300),
        AsrWordTiming(text: 'her', startMs: 9000, endMs: 9300),
        AsrWordTiming(text: 'feet', startMs: 9300, endMs: 9700),
        AsrWordTiming(text: 'moment', startMs: 11800, endMs: 12100),
        AsrWordTiming(text: 'before', startMs: 12400, endMs: 12800),
        AsrWordTiming(text: 'her', startMs: 12800, endMs: 13050),
        AsrWordTiming(text: 'was', startMs: 13050, endMs: 13280),
        AsrWordTiming(text: 'another', startMs: 13280, endMs: 13700),
        AsrWordTiming(text: 'long', startMs: 13700, endMs: 14000),
        AsrWordTiming(text: 'passage', startMs: 14000, endMs: 14500),
      ],
    );

    final squeezed = timeline.cues[2];
    expect(squeezed.method, 'interpolated');
    expect(squeezed.english, 'she looked up, but it was all dark overhead;');
    expect(squeezed.endMs - squeezed.startMs, greaterThanOrEqualTo(1800));
    expect(squeezed.startMs - timeline.cues[1].endMs, lessThanOrEqualTo(100));
    expect(squeezed.endMs, timeline.cues[3].startMs);
  });

  test('redistributes squeezed inferred lyrics at the beginning and end', () {
    final leading = SongSubtitleTimelineService.buildTimeline(
      articleId: 94,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 4000,
      source: 'suno',
      lyricLines: const [
        'Silent opening words arrive.',
        'Alice follows the bright song.',
      ],
      translations: const {},
      words: const [
        AsrWordTiming(text: 'Alice', startMs: 200, endMs: 500),
        AsrWordTiming(text: 'follows', startMs: 500, endMs: 900),
        AsrWordTiming(text: 'bright', startMs: 900, endMs: 1300),
        AsrWordTiming(text: 'song', startMs: 1300, endMs: 1700),
      ],
    );

    expect(leading.cues[0].method, 'estimated');
    expect(leading.cues[0].endMs - leading.cues[0].startMs,
        greaterThanOrEqualTo(850));
    expect(leading.cues[0].endMs, leading.cues[1].startMs);

    final trailing = SongSubtitleTimelineService.buildTimeline(
      articleId: 95,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 4000,
      source: 'suno',
      lyricLines: const [
        'Alice follows the bright song.',
        'Silent ending words arrive.',
      ],
      translations: const {},
      words: const [
        AsrWordTiming(text: 'Alice', startMs: 1000, endMs: 1300),
        AsrWordTiming(text: 'follows', startMs: 1300, endMs: 1600),
        AsrWordTiming(text: 'bright', startMs: 1600, endMs: 2000),
        AsrWordTiming(text: 'song', startMs: 3700, endMs: 3900),
      ],
    );

    expect(trailing.cues[1].method, 'estimated');
    expect(trailing.cues[1].endMs - trailing.cues[1].startMs,
        greaterThanOrEqualTo(850));
    expect(trailing.cues[1].endMs, trailing.durationMs);
  });

  test('keeps E03 line 49 and 50 matched from saved ASR words', () {
    final timeline = SongSubtitleTimelineService.buildTimeline(
      articleId: 96,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 200000,
      source: 'suno',
      lyricLines: const [
        'and she jumped up on to her feet in a moment:',
        'she looked up, but it was all dark overhead;',
        'before her was another long passage,',
      ],
      translations: const {},
      words: _e03FixtureWords('line49_50_words'),
    );

    expect(timeline.cues, hasLength(3));
    expect(timeline.cues[1].method, 'matched');
    expect(timeline.cues[1].startMs, lessThanOrEqualTo(180640));
    expect(timeline.cues[1].endMs - timeline.cues[1].startMs,
        greaterThanOrEqualTo(3000));
    expect(timeline.cues[2].method, 'matched');
    expect(timeline.cues[2].startMs, lessThan(timeline.cues[2].endMs));
  });

  test('extends partially recognized E03 final lyric without using full outro',
      () {
    final timeline = SongSubtitleTimelineService.buildTimeline(
      articleId: 97,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 238056,
      source: 'suno',
      lyricLines: const [
        'which was lit up by a row of lamps hanging from the roof.',
      ],
      translations: const {},
      words: _e03FixtureWords('final_line_words'),
    );

    final cue = timeline.cues.single;
    expect(cue.method, 'partial');
    expect(cue.endMs, greaterThanOrEqualTo(230500));
    expect(cue.endMs, lessThan(232000));
    expect(cue.endMs, lessThan(timeline.durationMs - 1000));
    expect(
      timeline.warnings,
      contains('部分歌词行仅局部匹配 ASR，已按歌词长度补齐时间'),
    );
  });

  test('builds E03 full song timeline from the real ASR fixture', () {
    final timeline = SongSubtitleTimelineService.buildTimeline(
      articleId: 48,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 238056,
      source: 'suno',
      lyricLines: _e03LyricLines,
      translations: const {},
      words: _e03FullAsrWords(),
    );

    final line49 = timeline.cues[48];
    final line50 = timeline.cues[49];
    final finalLine = timeline.cues.last;

    expect(timeline.cues, hasLength(_e03LyricLines.length));
    expect(timeline.confidence, greaterThan(0.9));
    expect(line49.english, 'she looked up, but it was all dark overhead;');
    expect(line49.method, 'matched');
    expect(line49.endMs - line49.startMs, greaterThanOrEqualTo(3000));
    expect(line50.english, 'before her was another long passage,');
    expect(line50.method, 'matched');
    expect(line50.endMs - line50.startMs, greaterThanOrEqualTo(2500));
    expect(finalLine.method, 'partial');
    expect(finalLine.endMs, inInclusiveRange(230500, 232000));
    expect(
      timeline.warnings,
      contains('部分歌词行仅局部匹配 ASR，已按歌词长度补齐时间'),
    );
  });

  test('builds E07 full song timeline without weak-anchor cascade', () {
    final lyricLines = _e07LyricLines();
    final words = _e07FullAsrWords();
    final stopwatch = Stopwatch()..start();
    final timeline = SongSubtitleTimelineService.buildTimeline(
      articleId: 52,
      audioHash: 'audio',
      lyricsHash: 'lyrics',
      durationMs: 377664,
      source: 'suno',
      lyricLines: lyricLines,
      translations: const {},
      words: words,
    );
    stopwatch.stop();

    final fourTimesSix = timeline.cues[8];
    final fourTimesSeven = timeline.cues[9];
    final ohDear = timeline.cues[10];
    final geography = timeline.cues[11];
    final lessons = timeline.cues[15];
    final crocodile = timeline.cues[19];

    expect(timeline.cues, hasLength(lyricLines.length));
    expect(stopwatch.elapsedMilliseconds, lessThan(5000));
    expect(timeline.confidence, greaterThan(0.82));
    expect(fourTimesSix.english, 'and four times six is thirteen,');
    expect(fourTimesSix.method, 'matched');
    expect(fourTimesSix.startMs, inInclusiveRange(57000, 60500));
    expect(fourTimesSix.endMs, lessThan(64000));
    expect(fourTimesSeven.english, 'and four times seven is—');
    expect(fourTimesSeven.method, 'matched');
    expect(fourTimesSeven.startMs, inInclusiveRange(63000, 67000));
    expect(fourTimesSeven.endMs, lessThan(70000));
    expect(ohDear.method, 'matched');
    expect(ohDear.endMs - ohDear.startMs, inInclusiveRange(9000, 18000));
    expect(geography.method, 'matched');
    expect(geography.endMs - geography.startMs, inInclusiveRange(2500, 7000));
    expect(lessons.method, 'matched');
    expect(lessons.endMs - lessons.startMs, greaterThanOrEqualTo(1800));
    expect(crocodile.endMs - crocodile.startMs, greaterThanOrEqualTo(1800));
    for (final cue in timeline.cues.sublist(15, 33)) {
      expect(
        cue.endMs - cue.startMs,
        greaterThanOrEqualTo(900),
        reason: 'E07 line ${cue.lineIndex + 1} must stay readable',
      );
    }
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
