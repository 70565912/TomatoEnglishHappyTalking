// ignore_for_file: experimental_member_use

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/data/models/article_song_model.dart';
import 'package:tomato_english_happy_talking/data/models/picture_book_model.dart';
import 'package:tomato_english_happy_talking/services/recording_export_service.dart';
import 'package:tomato_english_happy_talking/services/recording_export_utils.dart';
import 'package:tomato_english_happy_talking/services/song_subtitle_timeline_service.dart';
import 'package:tomato_english_happy_talking/services/tts_memory_cache_service.dart';
import 'package:tomato_english_happy_talking/services/tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('strict memory lookup misses without loading disk or remote TTS',
      () async {
    expect(
      await TtsMemoryCacheService.hasInMemory(
        text: 'This sentence has not been preloaded.',
        cachePurpose: 'listening_tts',
        preferRequestedVoice: true,
      ),
      isFalse,
    );
    expect(
      () => TtsMemoryCacheService.requireInMemory(
        text: 'This sentence has not been preloaded.',
        cachePurpose: 'listening_tts',
        preferRequestedVoice: true,
      ),
      throwsA(isA<TtsException>()),
    );
  });

  test('memory MP3 source serves full non-range response from bytes', () async {
    final bytes =
        Uint8List.fromList(List<int>.generate(150000, (i) => i % 251));
    final handle = TtsMemoryHandle(
      key: 'unit',
      bytes: bytes,
      filePath: 'unused.mp3',
    );

    final source = handle.toAudioSource() as StreamAudioSource;
    final response = await source.request(128, 4096);
    final chunks = await response.stream.toList();
    final served = chunks.expand((chunk) => chunk).toList(growable: false);

    expect(response.rangeRequestsSupported, isFalse);
    expect(response.sourceLength, isNull);
    expect(response.offset, isNull);
    expect(response.contentLength, bytes.length);
    expect(served, bytes);
  });

  test('recording export utility profiles stay compact for picture books', () {
    final r720 = RecordingExportUtils.bitrateProfile('1280x720', 'h264');
    final r1080 = RecordingExportUtils.bitrateProfile('1920x1080', 'h265');
    final r1440 = RecordingExportUtils.bitrateProfile('2560x1440', 'h264');

    expect(r720.targetKbps, 2500);
    expect(r720.maxKbps, 4500);
    expect(r1080.targetKbps, 3200);
    expect(r1080.maxKbps, 6500);
    expect(r1440.targetKbps, 9000);
    expect(r1440.maxKbps, 15000);
  });

  test('recording export utility chooses encoders and writes clean srt', () {
    const h264Encoders = '''
 V..... h264_nvenc           NVIDIA NVENC H.264 encoder
 V..... libx264              libx264 H.264 / AVC encoder
''';
    const h265SoftwareOnly = '''
 V..... libx265              libx265 H.265 / HEVC encoder
''';
    const h265HardwareAndSoftware = '''
 V..... hevc_nvenc           NVIDIA NVENC hevc encoder
 V..... libx265              libx265 H.265 / HEVC encoder
''';

    expect(
      RecordingExportUtils.selectEncoder('h264', h264Encoders),
      'h264_nvenc',
    );
    expect(
      RecordingExportUtils.selectEncoder('h265', h265SoftwareOnly),
      'libx265',
    );
    expect(
      RecordingExportUtils.selectEncoder('h265', h264Encoders),
      isNull,
    );
    expect(
      RecordingExportUtils.selectEncoderCandidates(
        'h265',
        h265HardwareAndSoftware,
      ),
      ['hevc_nvenc', 'libx265'],
    );

    final srt = RecordingExportUtils.srtForCues([
      const RecordingSubtitleCue(
        startMs: 0,
        endMs: 1530,
        english: 'Hello <b>Alice</b>!\nAre you ready?',
        chinese: '你好，爱丽丝！',
      ),
    ]);

    expect(srt, contains('1\r\n00:00:00,000 --> 00:00:01,530'));
    expect(srt, contains('Hello Alice! Are you ready?\r\n你好，爱丽丝！'));
    expect(srt, isNot(contains('<b>')));
  });

  test('recording output basename distinguishes listening and song exports',
      () {
    final listeningBaseName = RecordingExportService.outputBaseNameForTest(
      seriesTitle: 'Space Story Series',
      articleTitle: 'Space Snacks',
      exportKind: 'listening',
      subtitleKind: 'srt',
      now: DateTime(2026, 6, 12, 9, 8, 7),
    );
    final songBaseName = RecordingExportService.outputBaseNameForTest(
      seriesTitle: 'Space Story Series',
      articleTitle: 'Space Snacks',
      exportKind: 'song',
      subtitleKind: 'subtitled',
      now: DateTime(2026, 6, 12, 9, 8, 7),
    );

    expect(
      listeningBaseName,
      'Space Story Series - Space Snacks - listening - srt - 20260612-090807',
    );
    expect(
      songBaseName,
      'Space Story Series - Space Snacks - song - subtitled - 20260612-090807',
    );
    expect(listeningBaseName, isNot(contains('bilingual')));
    expect(songBaseName, isNot(contains('bilingual')));
  });

  test('both subtitle video output plan shares collision suffix', () async {
    final temp = await Directory.systemTemp.createTemp(
      'tomato_video_output_plan_test_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final now = DateTime(2026, 6, 12, 9, 8, 7);
    final subtitledDirectory = Directory(
      '${temp.path}${Platform.pathSeparator}subtitled',
    );
    await subtitledDirectory.create(recursive: true);
    final collision = File(
      '${subtitledDirectory.path}${Platform.pathSeparator}'
      'Space Story Series - Space Snacks - listening - subtitled - '
      '20260612-090807.mp4',
    );
    await collision.writeAsBytes([1]);

    final plan = await RecordingExportService.videoOutputPlanForTest(
      directory: temp,
      article: Article(
        id: 42,
        title: 'Space Snacks',
        content: '',
        sentences: const [],
        createdAt: now,
      ),
      series: StorySeries(
        id: 7,
        title: 'Space Story Series',
        createdAt: now,
        updatedAt: now,
      ),
      exportKind: 'listening',
      subtitleMode: RecordingSubtitleMode.both,
      now: now,
    );

    final variants = (plan['variants']! as List).cast<Map<String, dynamic>>();
    expect(
      plan['primaryVideoPath'],
      endsWith(
        '${Platform.pathSeparator}subtitled${Platform.pathSeparator}'
        'Space Story Series - Space Snacks - listening - subtitled - '
        '20260612-090807-2.mp4',
      ),
    );
    expect(
      plan['subtitlePath'],
      endsWith(
        '${Platform.pathSeparator}srt${Platform.pathSeparator}'
        'Space Story Series - Space Snacks - listening - srt - '
        '20260612-090807-2.srt',
      ),
    );
    expect(variants, hasLength(2));
    expect(variants.first, containsPair('kind', 'srt'));
    expect(
      variants.first['videoPath'],
      endsWith(
        '${Platform.pathSeparator}srt${Platform.pathSeparator}'
        'Space Story Series - Space Snacks - listening - srt - '
        '20260612-090807-2.mp4',
      ),
    );
    expect(variants.last, containsPair('kind', 'subtitled'));
    expect(variants.last['subtitlePath'], '');
  });

  test('recording video filename scanner accepts old and subtitle variants',
      () {
    const prefix = 'Space Story Series - Space Snacks';

    expect(
      RecordingExportService.exportedVideoFileNameInfoForTest(
        prefix: prefix,
        fileName: 'Space Story Series - Space Snacks - 20260612-090807.mp4',
      ),
      containsPair('stamp', '20260612-090807'),
    );
    expect(
      RecordingExportService.exportedVideoFileNameInfoForTest(
        prefix: prefix,
        fileName:
            'Space Story Series - Space Snacks - listening - 20260612-090807.mp4',
      ),
      containsPair('exportKind', 'listening'),
    );
    expect(
      RecordingExportService.exportedVideoFileNameInfoForTest(
        prefix: prefix,
        fileName:
            'Space Story Series - Space Snacks - song - subtitled - 20260612-090807-2.mp4',
      ),
      allOf(
        containsPair('exportKind', 'song'),
        containsPair('subtitleKind', 'subtitled'),
        containsPair('stamp', '20260612-090807'),
      ),
    );
  });

  test('recording video scanner includes legacy root and categorized folders',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'tomato_recording_scan_test_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    const prefix = 'Space Story Series - Space Snacks';
    final srtDirectory = Directory(
      '${temp.path}${Platform.pathSeparator}srt',
    );
    final subtitledDirectory = Directory(
      '${temp.path}${Platform.pathSeparator}subtitled',
    );
    await srtDirectory.create(recursive: true);
    await subtitledDirectory.create(recursive: true);
    final legacyRoot = File(
      '${temp.path}${Platform.pathSeparator}'
      '$prefix - listening - 20260612-090807.mp4',
    );
    final srtVideo = File(
      '${srtDirectory.path}${Platform.pathSeparator}'
      '$prefix - song - srt - 20260612-090808.mp4',
    );
    final subtitledVideo = File(
      '${subtitledDirectory.path}${Platform.pathSeparator}'
      '$prefix - song - subtitled - 20260612-090808.mp4',
    );
    await legacyRoot.writeAsBytes([1]);
    await srtVideo.writeAsBytes([1]);
    await subtitledVideo.writeAsBytes([1]);

    final scanned = await RecordingExportService.scanExportedVideoFilesForTest(
      rootDirectory: temp,
      prefix: prefix,
    );
    final scannedPaths = scanned.map((item) => item['path']).toSet();

    expect(scannedPaths, contains(legacyRoot.path));
    expect(scannedPaths, contains(srtVideo.path));
    expect(scannedPaths, contains(subtitledVideo.path));
    expect(
      scanned,
      contains(allOf(
        containsPair('exportKind', 'song'),
        containsPair('subtitleKind', 'srt'),
      )),
    );
    expect(
      scanned,
      contains(allOf(
        containsPair('exportKind', 'song'),
        containsPair('subtitleKind', 'subtitled'),
      )),
    );
  });

  test('song audio export copies bytes and preserves extension with collision',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'tomato_song_audio_export_test_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final sourceBytes = Uint8List.fromList([1, 2, 3, 4, 5, 6]);
    final sourceFile = File('${temp.path}${Platform.pathSeparator}source.flac');
    await sourceFile.writeAsBytes(sourceBytes);
    final outputDirectory =
        Directory('${temp.path}${Platform.pathSeparator}recording-export');
    await outputDirectory.create(recursive: true);
    final mp3Directory = Directory(
      '${outputDirectory.path}${Platform.pathSeparator}mp3',
    );
    await mp3Directory.create(recursive: true);
    final collision = File(
      '${mp3Directory.path}${Platform.pathSeparator}'
      'Space Story Series - Space Snacks - song-audio - 20260612-090807.flac',
    );
    await collision.writeAsBytes([9]);

    final now = DateTime(2026, 6, 12, 9, 8, 7);
    final result = await RecordingExportService.exportSongAudioForTest(
      articleId: 42,
      article: Article(
        id: 42,
        title: 'Space Snacks',
        content: '',
        sentences: const [],
        createdAt: now,
      ),
      series: StorySeries(
        id: 7,
        title: 'Space Story Series',
        createdAt: now,
        updatedAt: now,
      ),
      version: ArticleSongVersion(
        id: 'song-v1',
        audioPath: sourceFile.path,
      ),
      outputDirectory: outputDirectory,
      now: now,
    );

    expect(result.articleId, 42);
    expect(result.versionId, 'song-v1');
    expect(result.sourcePath, sourceFile.path);
    expect(result.outputDirectory, mp3Directory.path);
    expect(
      result.outputPath,
      endsWith(
        '${Platform.pathSeparator}mp3${Platform.pathSeparator}'
        'Space Story Series - Space Snacks - song-audio - '
        '20260612-090807-2.flac',
      ),
    );
    expect(await File(result.outputPath).readAsBytes(), sourceBytes);
  });

  test('recording subtitle mode normalizes settings and output behavior', () {
    expect(RecordingSubtitleMode.parse('').name, 'srt');
    expect(RecordingSubtitleMode.parse('bad-value').name, 'srt');
    expect(RecordingSubtitleMode.parse('burnedIn').writesSrt, isFalse);
    expect(RecordingSubtitleMode.parse('burnedIn').burnsIn, isTrue);
    expect(RecordingSubtitleMode.parse('both').writesSrt, isTrue);
    expect(RecordingSubtitleMode.parse('both').burnsIn, isTrue);
    expect(RecordingPageTransition.parse('pageCurl').name, 'pageCurl');

    final pageCurlSettings = RecordingExportService.normalizeSettingsForTest({
      'codec': 'h265',
      'resolution': '2560x1440',
      'pageTransition': 'pageCurl',
      'subtitleMode': 'both',
    });
    expect(pageCurlSettings, containsPair('pageTransition', 'pageCurl'));
    expect(pageCurlSettings, containsPair('subtitleMode', 'both'));
    expect(
      RecordingExportService.normalizeSettingsForTest({
        'codec': 'unknown',
        'resolution': 'too-big',
        'pageTransition': 'unknown',
        'subtitleMode': 'unknown',
      }),
      containsPair('subtitleMode', 'srt'),
    );
  });

  test('song export timeline keeps cue order and blank subtitle gaps', () {
    final rows = RecordingExportService.songTimelineRowsForTest(
      const SongSubtitleTimeline(
        version: 1,
        articleId: 42,
        audioHash: 'audio',
        lyricsHash: 'lyrics',
        durationMs: 5000,
        source: 'suno',
        cues: [
          SongSubtitleCue(
            lineIndex: 1,
            startMs: 1000,
            endMs: 1600,
            english: 'First chorus take',
          ),
          SongSubtitleCue(
            lineIndex: 1,
            startMs: 3000,
            endMs: 3600,
            english: 'Second chorus take',
          ),
        ],
      ),
    );

    expect(rows.map((row) => row['english']), [
      '',
      'First chorus take',
      '',
      'Second chorus take',
      '',
    ]);
    expect(rows[0], containsPair('startMs', 0));
    expect(rows[0], containsPair('endMs', 1000));
    expect(rows[2], containsPair('startMs', 1600));
    expect(rows[2], containsPair('endMs', 3000));
    expect(rows[4], containsPair('startMs', 3600));
    expect(rows[4], containsPair('endMs', 5000));
  });

  test('hybrid transition rendering limits frame rendering to transition spans',
      () {
    final parts = RecordingExportService.hybridRenderPartsForTest(
      transition: 'slide',
      segments: const [
        {'startMs': 0, 'endMs': 1000, 'pageIndex': 0},
        {'startMs': 1000, 'endMs': 2000, 'pageIndex': 1},
        {'startMs': 2000, 'endMs': 3000, 'pageIndex': 1},
      ],
    );

    expect(parts, [
      {
        'startMs': 0,
        'endMs': 750,
        'durationMs': 750,
        'isTransition': false,
      },
      {
        'startMs': 750,
        'endMs': 1000,
        'durationMs': 250,
        'isTransition': true,
      },
      {
        'startMs': 1000,
        'endMs': 1250,
        'durationMs': 250,
        'isTransition': true,
      },
      {
        'startMs': 1250,
        'endMs': 2000,
        'durationMs': 750,
        'isTransition': false,
      },
      {
        'startMs': 2000,
        'endMs': 3000,
        'durationMs': 1000,
        'isTransition': false,
      },
    ]);
    final transitionMs = parts
        .where((part) => part['isTransition'] == true)
        .fold<int>(0, (sum, part) => sum + (part['durationMs'] as int));
    expect(transitionMs, RecordingExportService.transitionMs);

    final pageCurlParts = RecordingExportService.hybridRenderPartsForTest(
      transition: 'pageCurl',
      segments: const [
        {'startMs': 0, 'endMs': 1000, 'pageIndex': 0},
        {'startMs': 1000, 'endMs': 2000, 'pageIndex': 1},
      ],
    );
    expect(
      pageCurlParts.where((part) => part['isTransition'] == true).length,
      2,
    );
  });

  test('recording export utility estimates mp3 duration from frames', () {
    final bytes = _syntheticMpeg1Layer3Frames(frameCount: 10);
    final durationMs = RecordingExportUtils.estimateMp3DurationMs(bytes);

    expect(durationMs, inInclusiveRange(250, 270));
  });
}

Uint8List _syntheticMpeg1Layer3Frames({required int frameCount}) {
  // MPEG1 Layer III, 128kbps, 44.1kHz. Frame length is 417 bytes.
  final header = <int>[0xFF, 0xFB, 0x90, 0x64];
  const frameLength = 417;
  final bytes = <int>[];
  for (var i = 0; i < frameCount; i += 1) {
    bytes.addAll(header);
    bytes.addAll(List<int>.filled(frameLength - header.length, 0));
  }
  return Uint8List.fromList(bytes);
}
