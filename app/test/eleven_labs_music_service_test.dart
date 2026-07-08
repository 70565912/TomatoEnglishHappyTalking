import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/eleven_labs_music_service.dart';

void main() {
  late Directory tempDir;
  late Directory previousDirectory;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    previousDirectory = Directory.current;
    tempDir = await Directory.systemTemp.createTemp('tomato_eleven_music_');
    Directory.current = tempDir;
    await databaseFactory.setDatabasesPath(tempDir.path);
    DatabaseService.setDatabaseDirectoryOverrideForTest(tempDir.path);
    DatabaseService.setRuntimeDataRootOverrideForTest(tempDir.path);
    await DatabaseService.resetForTest();
    AppConfig.resetRuntimeConfigForTest();
    ElevenLabsMusicService.setPostOverrideForTest(null);
  });

  tearDown(() async {
    ElevenLabsMusicService.setPostOverrideForTest(null);
    AppConfig.resetRuntimeConfigForTest();
    await DatabaseService.resetForTest();
    DatabaseService.setDatabaseDirectoryOverrideForTest(null);
    DatabaseService.setRuntimeDataRootOverrideForTest(null);
    Directory.current = previousDirectory;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('posts music prompt, saves mp3 cache, and reuses cached result',
      () async {
    AppConfig.setRuntimeConfigForTest(
      elevenLabsApiKey: 'eleven-music-key-123456',
      elevenLabsBaseUrl: 'https://api.elevenlabs.test',
      elevenLabsMusicModel: 'music_v2',
      elevenLabsMusicOutputFormat: 'mp3_44100_128',
    );

    var calls = 0;
    String? seenEndpoint;
    Map<String, String>? seenHeaders;
    Map<String, dynamic>? seenBody;
    ElevenLabsMusicService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        calls += 1;
        seenEndpoint = endpoint;
        seenHeaders = headers;
        seenBody = body;
        return ElevenLabsMusicPostResult(
          bytes: List<int>.filled(2048, 11),
          songId: 'song-eleven-1',
        );
      },
    );

    final result = await ElevenLabsMusicService.generateFromLyrics(
      lyrics: 'Hello world\nWe sing and learn',
      title: 'Song Title',
      articleId: 91,
    );
    final cached = await ElevenLabsMusicService.generateFromLyrics(
      lyrics: 'Hello world\nWe sing and learn',
      title: 'Song Title',
      articleId: 91,
    );

    expect(calls, 1);
    expect(result.source, ElevenLabsMusicResultSource.remote);
    expect(cached.source, ElevenLabsMusicResultSource.cached);
    expect(cached.filePath, result.filePath);
    expect(result.songId, 'song-eleven-1');
    expect(result.filePath, isNotEmpty);
    expect(await File(result.filePath!).exists(), isTrue);
    expect(seenEndpoint,
        'https://api.elevenlabs.test/v1/music?output_format=mp3_44100_128');
    expect(seenHeaders, containsPair('xi-api-key', 'eleven-music-key-123456'));
    expect(seenHeaders, containsPair('Content-Type', 'application/json'));
    expect(seenBody?['model_id'], 'music_v2');
    expect(seenBody?['force_instrumental'], isFalse);
    expect(seenBody?['prompt'], contains('Song Title'));
    expect(seenBody?['prompt'], contains('Hello world'));

    final db = await DatabaseService.database;
    final rows = await db.query('api_cache_entries');
    expect(rows, hasLength(1));
    expect(rows.single['kind'], 'elevenlabs_music');
    expect(rows.single['purpose'], ElevenLabsMusicService.cachePurpose);
    expect(rows.single['file_path'], result.filePath);
  });

  test('does not call remote API when key is missing', () async {
    var called = false;
    ElevenLabsMusicService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        called = true;
        return ElevenLabsMusicPostResult(bytes: List<int>.filled(2048, 1));
      },
    );

    final result = await ElevenLabsMusicService.generateFromLyrics(
      lyrics: 'Hello world',
      title: 'No Key Song',
      articleId: 92,
    );

    expect(result.source, ElevenLabsMusicResultSource.skippedNoKey);
    expect(result.errorMessage, contains('ElevenLabs API Key'));
    expect(called, isFalse);
  });
}
