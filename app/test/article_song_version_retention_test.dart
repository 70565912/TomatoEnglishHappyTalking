import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/data/models/article_song_model.dart';
import 'package:tomato_english_happy_talking/services/api_cache_service.dart';
import 'package:tomato_english_happy_talking/services/article_song_cache_service.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';

const _sunoSongPurpose = 'article_suno_song_v1';

void main() {
  late Directory tempDir;
  late Directory previousDirectory;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    previousDirectory = Directory.current;
    tempDir =
        await Directory.systemTemp.createTemp('tomato_song_retention_test_');
    Directory.current = tempDir;
    await databaseFactory.setDatabasesPath(tempDir.path);
    DatabaseService.setDatabaseDirectoryOverrideForTest(tempDir.path);
    DatabaseService.setRuntimeDataRootOverrideForTest(tempDir.path);
    await DatabaseService.resetForTest();
    AppConfig.resetRuntimeConfigForTest();
  });

  tearDown(() async {
    AppConfig.resetRuntimeConfigForTest();
    await DatabaseService.resetForTest();
    DatabaseService.setDatabaseDirectoryOverrideForTest(null);
    DatabaseService.setRuntimeDataRootOverrideForTest(null);
    Directory.current = previousDirectory;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('loads all cached song versions regardless of lyrics hash', () async {
    final articleId = await _saveArticle(['Line one.', 'Line two.']);
    final oldHash = await ApiCacheService.hashUtf8('Line one.\nLine two.');
    final newHash = await ApiCacheService.hashUtf8('Line one.');
    await _putSunoCacheEntry(
      articleId: articleId,
      lyricsHash: oldHash,
      versions: [
        ArticleSongVersion(
          id: 'suno_old_v1',
          audioPath: await _writeTempMp3('old_v1'),
          title: 'Old lyrics song',
          lyricsHash: oldHash,
        ),
      ],
    );
    await _putSunoCacheEntry(
      articleId: articleId,
      lyricsHash: newHash,
      versions: [
        ArticleSongVersion(
          id: 'suno_new_v1',
          audioPath: await _writeTempMp3('new_v1'),
          title: 'New lyrics song',
          lyricsHash: newHash,
        ),
      ],
    );

    final versions = await ArticleSongCacheService.loadAllCachedVersions(
      articleId: articleId,
      purpose: _sunoSongPurpose,
    );

    expect(versions.map((version) => version.id), containsAll(['suno_old_v1', 'suno_new_v1']));
  });

  test('removeVersionFromArticleCache deletes files and cache row when last version',
      () async {
    final articleId = await _saveArticle(['Only one line.']);
    final lyricsHash = await ApiCacheService.hashUtf8('Only one line.');
    final audioPath = await _writeTempMp3('single');
    final metadataPath = await _writeMetadataFile(
      articleId: articleId,
      lyricsHash: lyricsHash,
      versions: [
        ArticleSongVersion(
          id: 'suno_single_v1',
          audioPath: audioPath,
          title: 'Single',
          lyricsHash: lyricsHash,
        ),
      ],
    );
    final request = {
      'version': 1,
      'provider': 'suno',
      'articleId': articleId,
      'lyricsHash': lyricsHash,
    };
    final cacheKey = await ApiCacheService.keyForJson('article_suno_song', request);
    await ApiCacheService.putJson(
      cacheKey: cacheKey,
      kind: 'suno_music',
      purpose: _sunoSongPurpose,
      request: request,
      jsonValue: {
        'provider': 'suno',
        'articleId': articleId,
        'lyricsHash': lyricsHash,
        'metadataPath': metadataPath,
        'versions': [
          {
            'id': 'suno_single_v1',
            'audioPath': audioPath,
            'title': 'Single',
            'lyricsHash': lyricsHash,
          },
        ],
      },
      articleId: articleId,
    );

    final removed = await ArticleSongCacheService.removeVersionFromArticleCache(
      articleId: articleId,
      versionId: 'suno_single_v1',
      purpose: _sunoSongPurpose,
      kind: 'suno_music',
    );

    expect(removed, isTrue);
    expect(await File(audioPath).exists(), isTrue);
    expect(await File(metadataPath).exists(), isFalse);
    final entries = await ApiCacheService.getEntriesForArticlePurpose(
      articleId: articleId,
      purpose: _sunoSongPurpose,
    );
    expect(entries, isEmpty);
  });

  test('soft-hidden lyrics hash change keeps prior cache readable', () async {
    final articleId = await _saveArticle(['Alpha.', 'Beta.', 'Gamma.']);
    final fullHash =
        await ApiCacheService.hashUtf8('Alpha.\nBeta.\nGamma.');
    await _putSunoCacheEntry(
      articleId: articleId,
      lyricsHash: fullHash,
      versions: [
        ArticleSongVersion(
          id: 'suno_full_v1',
          audioPath: await _writeTempMp3('full'),
          title: 'Full lyrics',
          lyricsHash: fullHash,
        ),
      ],
    );

    await DatabaseService.updateArticleContentAndSentences(
      articleId,
      'Alpha. Gamma.',
      ['Alpha.', '', 'Gamma.'],
    );
    final hiddenHash = await ApiCacheService.hashUtf8('Alpha.\nGamma.');
    expect(hiddenHash, isNot(fullHash));

    final versions = await ArticleSongCacheService.loadAllCachedVersions(
      articleId: articleId,
      purpose: _sunoSongPurpose,
    );
    expect(versions.single.id, 'suno_full_v1');
    expect(versions.single.lyricsHash, fullHash);
    expect(hiddenHash, isNot(versions.single.lyricsHash));
  });
}

Future<int> _saveArticle(List<String> sentences) async {
  return DatabaseService.saveArticle(
    Article(
      title: 'Song retention sample',
      content: sentences.where((sentence) => sentence.trim().isNotEmpty).join(' '),
      sentences: sentences,
      createdAt: DateTime.utc(2026, 7, 5),
    ),
  );
}

Future<String> _writeTempMp3(String label) async {
  final root = await DatabaseService.runtimeDataRoot;
  final dir = Directory('$root/suno-music');
  await dir.create(recursive: true);
  final path = '${dir.path}/test_$label.mp3';
  await File(path).writeAsBytes([0, 1, 2, 3, 4], flush: true);
  return path;
}

Future<String> _writeMetadataFile({
  required int articleId,
  required String lyricsHash,
  required List<ArticleSongVersion> versions,
}) async {
  final root = await DatabaseService.runtimeDataRoot;
  final dir = Directory('$root/suno-music');
  await dir.create(recursive: true);
  final path = '${dir.path}/article_${articleId}_suno_test.json';
  await File(path).writeAsString(
    jsonEncode({
      'provider': 'suno',
      'articleId': articleId,
      'lyricsHash': lyricsHash,
      'metadataPath': path,
      'versions': versions.map((version) => version.toJson()).toList(),
    }),
    flush: true,
  );
  return path;
}

Future<void> _putSunoCacheEntry({
  required int articleId,
  required String lyricsHash,
  required List<ArticleSongVersion> versions,
}) async {
  final metadataPath = await _writeMetadataFile(
    articleId: articleId,
    lyricsHash: lyricsHash,
    versions: versions,
  );
  final request = {
    'version': 1,
    'provider': 'suno',
    'articleId': articleId,
    'lyricsHash': lyricsHash,
  };
  final cacheKey = await ApiCacheService.keyForJson('article_suno_song', request);
  await ApiCacheService.putJson(
    cacheKey: cacheKey,
    kind: 'suno_music',
    purpose: _sunoSongPurpose,
    request: request,
    jsonValue: {
      'provider': 'suno',
      'articleId': articleId,
      'lyricsHash': lyricsHash,
      'metadataPath': metadataPath,
      'versions': versions.map((version) => version.toJson()).toList(),
    },
    articleId: articleId,
  );
}
