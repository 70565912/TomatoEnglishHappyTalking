import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path_lib;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/data/models/article_sentence_translation_model.dart';
import 'package:tomato_english_happy_talking/data/models/article_song_model.dart';
import 'package:tomato_english_happy_talking/data/models/learning_record_model.dart';
import 'package:tomato_english_happy_talking/data/models/picture_book_model.dart';
import 'package:tomato_english_happy_talking/services/api_cache_service.dart';
import 'package:tomato_english_happy_talking/services/book_transfer_service.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/external_song_import_service.dart';

void main() {
  late Directory tempDir;
  late Directory exportDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tomato_book_transfer_');
    exportDir = Directory(path_lib.join(tempDir.path, 'exports'));
    await exportDir.create(recursive: true);
    await databaseFactory.setDatabasesPath(
      path_lib.join(tempDir.path, 'databases'),
    );
    DatabaseService.setDatabaseDirectoryOverrideForTest(
      path_lib.join(tempDir.path, 'databases'),
    );
    DatabaseService.setRuntimeDataRootOverrideForTest(
      path_lib.join(tempDir.path, 'runtime'),
    );
    await DatabaseService.resetForTest();
  });

  tearDown(() async {
    await DatabaseService.resetForTest();
    DatabaseService.setDatabaseDirectoryOverrideForTest(null);
    DatabaseService.setRuntimeDataRootOverrideForTest(null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('exports a portable zip without videos or absolute paths', () async {
    final sample = await _createSampleBook();

    final result = await BookTransferService.exportSeries(
      seriesId: sample.seriesId,
      outputDirectory: exportDir.path,
    );

    expect(result.outputPath, endsWith('.zip'));
    expect(result.articleCount, 1);
    expect(result.assetCount, greaterThanOrEqualTo(3));

    final archive = _decodeZip(result.outputPath);
    final names = archive.files.map((file) => file.name).toSet();
    expect(names, contains('manifest.json'));
    expect(names, contains('data/series.json'));
    expect(names, contains('data/articles.json'));
    expect(names, contains('data/external_songs.json'));
    expect(names.any((name) => name.contains('recording-export')), isFalse);

    final jsonText = archive.files
        .where((file) => file.isFile && file.name.endsWith('.json'))
        .map((file) => utf8.decode(file.content))
        .join('\n');
    expect(jsonText, isNot(contains(tempDir.path)));
    expect(jsonText, isNot(contains('volc_speech_api_key')));
    expect(jsonText, isNot(contains('content_safety_rules')));

    final externalSongs = _jsonList(archive, 'data/external_songs.json');
    expect(externalSongs, hasLength(1));
    expect(
      jsonEncode(externalSongs),
      contains(ExternalSongImportService.source),
    );
  });

  test('imports a book as a new copy and restores book assets', () async {
    final sample = await _createSampleBook();
    final export = await BookTransferService.exportSeries(
      seriesId: sample.seriesId,
      outputDirectory: exportDir.path,
    );

    final imported = await BookTransferService.importSeriesArchive(
      filePath: export.outputPath,
    );

    expect(imported.seriesId, isNot(sample.seriesId));
    expect(imported.title, 'Migrating Book（导入）');
    expect(imported.articleIds, hasLength(1));
    expect(imported.articleIds.single, isNot(sample.articleId));

    final db = await DatabaseService.database;
    final chapters = await db.query(
      'story_chapters',
      where: 'series_id = ?',
      whereArgs: [imported.seriesId],
    );
    expect(chapters, hasLength(1));

    final pages = await db.query(
      'picture_book_pages',
      where: 'article_id = ?',
      whereArgs: [imported.articleIds.single],
    );
    expect(pages, hasLength(1));
    final imagePath = pages.single['image_path'] as String?;
    expect(imagePath, isNotNull);
    expect(await File(imagePath!).exists(), isTrue);
    expect(imagePath, isNot(contains('recording-export')));

    final recording = await ApiCacheService.getLatestSentenceRecording(
      articleId: imported.articleIds.single,
      sentenceIndex: 0,
    );
    expect(recording, isNotNull);
    expect(await File(recording!.recordingPath).exists(), isTrue);

    final article =
        await DatabaseService.getArticleById(imported.articleIds.single);
    final externalVersions =
        await ExternalSongImportService.loadVersions(article!);
    expect(externalVersions, hasLength(1));
    expect(await File(externalVersions.single.audioPath).exists(), isTrue);
  });

  test('warns and keeps exporting when optional assets are missing', () async {
    final sample = await _createSampleBook();
    final db = await DatabaseService.database;
    await db.update(
      'picture_book_pages',
      {'image_path': path_lib.join(tempDir.path, 'missing-picture.png')},
      where: 'article_id = ?',
      whereArgs: [sample.articleId],
    );

    final result = await BookTransferService.exportSeries(
      seriesId: sample.seriesId,
      outputDirectory: exportDir.path,
    );

    expect(await File(result.outputPath).exists(), isTrue);
    expect(result.warnings, isNotEmpty);
    expect(result.warnings.join('\n'), contains('Missing optional'));
  });

  test('rejects invalid zip before inserting imported rows', () async {
    final sample = await _createSampleBook();
    final badZip = File(path_lib.join(tempDir.path, 'bad.zip'));
    await badZip.writeAsBytes([1, 2, 3], flush: true);

    await expectLater(
      BookTransferService.importSeriesArchive(filePath: badZip.path),
      throwsA(anything),
    );

    final db = await DatabaseService.database;
    final seriesCount = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM story_series'),
    );
    final articleCount = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM articles'),
    );
    expect(seriesCount, 1);
    expect(articleCount, 1);
    expect(sample.seriesId, greaterThan(0));
  });
}

Future<_SampleBook> _createSampleBook() async {
  final runtimeRoot = await DatabaseService.runtimeDataRoot;
  final articleId = await DatabaseService.saveArticle(
    Article(
      title: 'Chapter One',
      content: 'Hello book. We sing together.',
      sentences: const ['Hello book.', 'We sing together.'],
      createdAt: DateTime(2026, 1, 1),
    ),
  );
  final article = (await DatabaseService.getArticleById(articleId))!;
  final seriesId = await DatabaseService.saveStorySeries(
    StorySeries(
      title: 'Migrating Book',
      description: 'A book used for transfer tests.',
      characters: const [
        BookCharacter(name: 'Tom', description: 'A cheerful learner.'),
      ],
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
    ),
  );
  await DatabaseService.saveStoryChapter(
    StoryChapter(
      seriesId: seriesId,
      articleId: articleId,
      chapterOrder: 1,
      chapterTitle: article.title,
      summaryJson: '{"chapterDescription":"Transfer chapter"}',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
    ),
  );
  await DatabaseService.saveArticleSentenceTranslations(articleId, [
    ArticleSentenceTranslation(
      articleId: articleId,
      sentenceIndex: 0,
      englishSentence: 'Hello book.',
      chineseText: '你好，书。',
      source: 'imported',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    ),
  ]);
  await DatabaseService.saveLearningRecord(
    LearningRecord(
      articleId: articleId,
      sentence: 'Hello book.',
      overallScore: 88,
      accuracyScore: 90,
      fluencyScore: 86,
      completenessScore: 89,
      prosodyScore: 87,
      createdAt: DateTime(2026, 1, 3),
    ),
  );
  await DatabaseService.saveArticleChatGuide(
    articleId: articleId,
    purpose: 'chapter_chat_guide_v1',
    contentHash: 'chat-hash',
    guideText: 'Ask about the song in the book.',
  );

  final pictureFile = File(path_lib.join(runtimeRoot, 'picture.png'));
  await pictureFile.parent.create(recursive: true);
  await pictureFile.writeAsBytes([10, 11, 12, 13], flush: true);
  await DatabaseService.upsertPictureBookPage(
    PictureBookPage(
      articleId: articleId,
      seriesId: seriesId,
      pageIndex: 0,
      sentenceStartIndex: 0,
      sentenceEndIndex: 0,
      paragraphText: 'Hello book.',
      promptJson: '{"sceneDescription":"Tom waves."}',
      imageCacheKey: 'picture_cache_key',
      imagePath: pictureFile.path,
      status: 'ready',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
    ),
  );

  await ApiCacheService.putFileBytes(
    cacheKey: 'picture_cache_key',
    kind: 'picture_book_image',
    purpose: 'picture_book_image_v1',
    request: {'articleId': articleId, 'seriesId': seriesId},
    bytes: [20, 21, 22],
    subdirectory: 'picture_book_images',
    extension: 'png',
    contentType: 'image/png',
    articleId: articleId,
  );
  await ApiCacheService.saveLatestSentenceRecording(
    articleId: articleId,
    sentenceIndex: 0,
    sentence: 'Hello book.',
    audioBytes: [30, 31, 32, 33],
    recognizedText: 'Hello book.',
    resultJson: '{"score":88}',
  );

  final importedSong = File(path_lib.join(runtimeRoot, 'source-song.mp3'));
  await importedSong.writeAsBytes([40, 41, 42, 43], flush: true);
  final externalVersion = await ExternalSongImportService.importFile(
    article: article,
    sourcePath: importedSong.path,
    lyrics: 'Hello book.\nWe sing together.',
    durationProbe: (_) async => const Duration(seconds: 8),
  );
  final timelineFile = File(path_lib.join(runtimeRoot, 'song-timeline.json'));
  await timelineFile.writeAsString('{"cues":[]}', flush: true);
  await ExternalSongImportService.saveVersions(
    article: article,
    versions: [
      externalVersion.copyWith(
        timelinePath: timelineFile.path,
        timelineStatus: 'ready',
      ),
    ],
  );

  final generatedVideo = File(path_lib.join(
    runtimeRoot,
    'recording-export',
    'chapter-video.mp4',
  ));
  await generatedVideo.parent.create(recursive: true);
  await generatedVideo.writeAsBytes([99, 98, 97], flush: true);

  return _SampleBook(seriesId: seriesId, articleId: articleId);
}

Archive _decodeZip(String path) =>
    ZipDecoder().decodeBytes(File(path).readAsBytesSync());

List<dynamic> _jsonList(Archive archive, String path) {
  final file = archive.files.firstWhere((item) => item.name == path);
  return jsonDecode(utf8.decode(file.content)) as List<dynamic>;
}

class _SampleBook {
  const _SampleBook({
    required this.seriesId,
    required this.articleId,
  });

  final int seriesId;
  final int articleId;
}
