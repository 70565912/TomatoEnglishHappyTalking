import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path_lib;
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/data/models/article_song_model.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/external_song_import_service.dart';
import 'package:tomato_english_happy_talking/services/song_subtitle_timeline_service.dart';

void main() {
  late Directory tempDir;

  final article = Article(
    id: 7,
    title: 'Song Chapter',
    content: 'Hello song.',
    sentences: ['Hello song.'],
    createdAt: DateTime(2026, 1, 1),
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tomato_external_song_');
    DatabaseService.setRuntimeDataRootOverrideForTest(tempDir.path);
  });

  tearDown(() async {
    DatabaseService.setRuntimeDataRootOverrideForTest(null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<Duration?> probe(String _) async =>
      const Duration(milliseconds: 42000);

  Future<File> sourceFile(String name, List<int> bytes) async {
    final directory = Directory(path_lib.join(tempDir.path, 'imports'));
    await directory.create(recursive: true);
    final file = File(path_lib.join(directory.path, name));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  test('parses ffmpeg duration output for imported mp3 files', () {
    final duration = ExternalSongImportService.parseFfmpegDurationForTest('''
Input #0, mp3, from "Alice's Adventures in.mp3":
  Duration: 00:05:08.66, start: 0.023021, bitrate: 197 kb/s
  Stream #0:0: Audio: mp3, 48000 Hz, stereo, fltp, 197 kb/s
''');

    expect(duration?.inMilliseconds, 308660);
  });
  test('copies external audio into persistent article song assets', () async {
    final source = await sourceFile('chapter-song.mp3', [1, 2, 3, 4]);

    final version = await ExternalSongImportService.importFile(
      article: article,
      sourcePath: source.path,
      lyrics: 'Hello song.',
      durationProbe: probe,
    );

    expect(version.source, ExternalSongImportService.source);
    expect(version.title, 'chapter-song');
    expect(version.durationMs, 42000);
    expect(version.submittedLyrics, 'Hello song.');
    expect(version.timelineStatus, 'missing');
    expect(version.isDefault, isTrue);
    expect(await File(version.audioPath).exists(), isTrue);
    expect(
        version.audioPath,
        contains(path_lib.join(
          'song-assets',
          ExternalSongImportService.source,
          'article_7',
        )));

    final state = await ExternalSongImportService.loadState(article);
    expect(state?.versions, hasLength(1));
    expect(state?.versions.single.id, version.id);
    expect(state?.metadataPath, isNotEmpty);
  });

  test('stores custom Chinese submittedLyrics for imported audio', () async {
    final source = await sourceFile('我是一根葱.mp3', [5, 6, 7, 8]);
    const chineseLyrics = '我是一根葱\n我骄傲';

    final version = await ExternalSongImportService.importFile(
      article: article,
      sourcePath: source.path,
      lyrics: chineseLyrics,
      durationProbe: probe,
    );

    expect(version.title, '我是一根葱');
    expect(version.submittedLyrics, chineseLyrics);
    expect(version.timelineStatus, 'missing');
  });

  test('dedupes repeated imports by audio content hash', () async {
    final first = await sourceFile('first.mp3', [9, 8, 7, 6]);
    final second = await sourceFile('second.mp3', [9, 8, 7, 6]);

    final firstVersion = await ExternalSongImportService.importFile(
      article: article,
      sourcePath: first.path,
      lyrics: 'Hello song.',
      durationProbe: probe,
    );
    final secondVersion = await ExternalSongImportService.importFile(
      article: article,
      sourcePath: second.path,
      lyrics: 'Hello song.',
      durationProbe: probe,
    );

    expect(secondVersion.id, firstVersion.id);
    expect(secondVersion.audioPath, firstVersion.audioPath);
    final versions = await ExternalSongImportService.loadVersions(article);
    expect(versions, hasLength(1));
    final articleDir = File(firstVersion.audioPath).parent;
    final audioFiles = articleDir.listSync().whereType<File>().where((file) {
      final name = path_lib.basename(file.path);
      return name.startsWith('external_audio_') && !name.endsWith('.json');
    }).toList();
    expect(audioFiles, hasLength(1));
  });

  test('can persist imported versions without a source-local default',
      () async {
    final first = await sourceFile('first-defaultless.mp3', [10, 11, 12, 13]);
    final second = await sourceFile('second-defaultless.mp3', [20, 21, 22, 23]);

    final firstVersion = await ExternalSongImportService.importFile(
      article: article,
      sourcePath: first.path,
      lyrics: 'Hello song.',
      durationProbe: probe,
    );
    final secondVersion = await ExternalSongImportService.importFile(
      article: article,
      sourcePath: second.path,
      lyrics: 'Hello song.',
      durationProbe: probe,
    );

    await ExternalSongImportService.saveVersions(
      article: article,
      versions: [
        firstVersion.copyWith(isDefault: false),
        secondVersion.copyWith(isDefault: false),
      ],
      requireDefault: false,
    );

    final defaultlessVersions = await ExternalSongImportService.loadVersions(
      article,
      requireDefault: false,
    );
    expect(defaultlessVersions, hasLength(2));
    expect(defaultlessVersions.any((version) => version.isDefault), isFalse);

    final defaultlessState = await ExternalSongImportService.loadState(
      article,
      requireDefault: false,
    );
    expect(defaultlessState?.versions.any((version) => version.isDefault),
        isFalse);

    final defaultedVersions = await ExternalSongImportService.loadVersions(
      article,
    );
    expect(defaultedVersions.first.isDefault, isTrue);
    expect(
        defaultedVersions.skip(1).any((version) => version.isDefault), isFalse);
  });

  test('restores metadata and filters missing imported files', () async {
    final source = await sourceFile('restore.wav', [5, 4, 3, 2]);
    final version = await ExternalSongImportService.importFile(
      article: article,
      sourcePath: source.path,
      lyrics: 'Hello song.',
      durationProbe: probe,
    );

    expect(await ExternalSongImportService.loadVersions(article), hasLength(1));
    await File(version.audioPath).delete();

    final restored = await ExternalSongImportService.loadVersions(article);
    expect(restored, isEmpty);
    final state = await ExternalSongImportService.loadState(article);
    expect(state, isNull);
  });

  test('marks old imported timeline files as stale instead of ready', () async {
    final source = await sourceFile('old-timeline.mp3', [6, 7, 8, 9]);
    final version = await ExternalSongImportService.importFile(
      article: article,
      sourcePath: source.path,
      lyrics: 'Hello song.',
      durationProbe: probe,
    );
    final timelineFile = File(path_lib.join(tempDir.path, 'old_timeline.json'));
    await timelineFile.writeAsString('{"version":1,"cues":[]}', flush: true);
    await ExternalSongImportService.saveVersions(
      article: article,
      versions: [
        version.copyWith(
          timelinePath: timelineFile.path,
          timelineStatus: 'ready',
          timelineConfidence: 0.8,
        ),
      ],
    );

    final loaded = await ExternalSongImportService.loadVersions(article);

    expect(loaded.single.timelinePath, timelineFile.path);
    expect(loaded.single.timelineStatus, 'stale');
    expect(loaded.single.timelineConfidence, isNull);
    expect(
      loaded.single.timelineError,
      SongSubtitleTimelineService.staleTimelineMessage,
    );
  });

  test('deletes imported audio and timeline assets for a version', () async {
    final source = await sourceFile('with-timeline.mp3', [1, 1, 2, 3]);
    final version = await ExternalSongImportService.importFile(
      article: article,
      sourcePath: source.path,
      lyrics: 'Hello song.',
      durationProbe: probe,
    );
    final timelineFile = File(path_lib.join(tempDir.path, 'timeline.json'));
    await timelineFile.writeAsString('{"cues":[]}', flush: true);
    final versionWithTimeline = version.copyWith(
      timelinePath: timelineFile.path,
      timelineStatus: 'ready',
    );
    await ExternalSongImportService.saveVersions(
      article: article,
      versions: [versionWithTimeline],
    );

    await ExternalSongImportService.deleteVersionAssets(versionWithTimeline);
    await ExternalSongImportService.saveVersions(
      article: article,
      versions: const <ArticleSongVersion>[],
    );

    expect(await File(version.audioPath).exists(), isFalse);
    expect(await timelineFile.exists(), isFalse);
    expect(await ExternalSongImportService.loadVersions(article), isEmpty);
  });
}
