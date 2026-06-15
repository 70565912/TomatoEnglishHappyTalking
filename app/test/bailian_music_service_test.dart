import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/services/bailian_music_service.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';

void main() {
  late Directory tempDir;
  late Directory previousDirectory;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    previousDirectory = Directory.current;
    tempDir = await Directory.systemTemp.createTemp('tomato_bailian_music_');
    Directory.current = tempDir;
    await databaseFactory.setDatabasesPath(tempDir.path);
    DatabaseService.setDatabaseDirectoryOverrideForTest(tempDir.path);
    await DatabaseService.resetForTest();
    AppConfig.resetRuntimeConfigForTest();
    BailianMusicService.setPostOverrideForTest(null);
    BailianMusicService.setDownloadOverrideForTest(null);
  });

  tearDown(() async {
    BailianMusicService.setPostOverrideForTest(null);
    BailianMusicService.setDownloadOverrideForTest(null);
    AppConfig.resetRuntimeConfigForTest();
    await DatabaseService.resetForTest();
    DatabaseService.setDatabaseDirectoryOverrideForTest(null);
    Directory.current = previousDirectory;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('posts fun-music lyrics, downloads audio, and saves cache entry',
      () async {
    AppConfig.setRuntimeConfigForTest(
      aliyunBailianApiKey: 'bailian-music-key-123456',
      aliyunBailianMusicModel: 'fun-music-test',
    );

    String? seenEndpoint;
    Map<String, String>? seenHeaders;
    Map<String, dynamic>? seenBody;
    String? downloadedUrl;
    BailianMusicService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        seenEndpoint = endpoint;
        seenHeaders = headers;
        seenBody = body;
        return {
          'request_id': 'req-mock',
          'output': {
            'audio': {'url': 'https://example.com/mock-song.mp3'},
            'extra_info': {'lyrics': 'hello\nworld'},
          },
          'usage': {'duration': 12.5},
        };
      },
    );
    BailianMusicService.setDownloadOverrideForTest((url) async {
      downloadedUrl = url;
      return List<int>.filled(2048, 7);
    });

    final result = await BailianMusicService.generateFromLyrics(
      lyrics: 'Hello\nworld',
      title: 'Song Title',
      articleId: 88,
    );

    expect(result.source, BailianMusicResultSource.remote);
    expect(result.audioUrl, 'https://example.com/mock-song.mp3');
    expect(result.durationMs, 12500);
    expect(result.requestId, 'req-mock');
    expect(result.filePath, isNotEmpty);
    expect(await File(result.filePath!).exists(), isTrue);
    expect(downloadedUrl, 'https://example.com/mock-song.mp3');
    expect(seenEndpoint, BailianMusicService.endpoint);
    expect(seenHeaders,
        containsPair('Authorization', 'Bearer bailian-music-key-123456'));
    expect(seenBody?['model'], 'fun-music-test');
    expect(seenBody?['input'], containsPair('lyrics', 'Hello\nworld'));

    final db = await DatabaseService.database;
    final rows = await db.query('api_cache_entries');
    expect(rows, hasLength(1));
    expect(rows.single['kind'], 'bailian_fun_music');
    expect(rows.single['purpose'], BailianMusicService.cachePurpose);
    expect(rows.single['file_path'], result.filePath);
  });

  test('compresses long story prose into song-like lyrics before posting',
      () async {
    AppConfig.setRuntimeConfigForTest(
      aliyunBailianApiKey: 'bailian-music-key-123456',
      aliyunBailianMusicModel: 'fun-music-test',
    );

    Map<String, dynamic>? seenBody;
    BailianMusicService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        seenBody = body;
        return {
          'request_id': 'req-compressed',
          'output': {
            'audio': {'url': 'https://example.com/compressed-song.mp3'},
          },
          'usage': {'duration': 18},
        };
      },
    );
    BailianMusicService.setDownloadOverrideForTest((url) async {
      return List<int>.filled(2048, 9);
    });
    final longStory = List<String>.generate(
      24,
      (index) =>
          'Alice follows a curious path through the garden and talks with friend number $index.',
    ).join('\n');

    final result = await BailianMusicService.generateFromLyrics(
      lyrics: longStory,
      title: 'E01 - All In The Golden Afternoon',
      articleId: 89,
    );

    final input = seenBody?['input'] as Map<String, dynamic>?;
    final postedLyrics = input?['lyrics']?.toString() ?? '';
    expect(result.source, BailianMusicResultSource.remote);
    expect(result.lyricsCompressed, isTrue);
    expect(result.submittedLyrics, postedLyrics);
    expect(postedLyrics, contains('All In The Golden'));
    expect(postedLyrics, isNot(contains('friend number 23')));
    expect(postedLyrics.split('\n').where((line) => line.trim().isNotEmpty),
        hasLength(12));
  });
}
