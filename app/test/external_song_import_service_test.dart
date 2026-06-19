import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path_lib;
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/data/models/article_song_model.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/external_song_import_service.dart';

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
