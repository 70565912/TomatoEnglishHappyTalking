import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/minimax_music_service.dart';
import 'package:tomato_english_happy_talking/services/text_generation_service.dart';

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
    tempDir = await Directory.systemTemp.createTemp('tomato_minimax_test_');
    Directory.current = tempDir;
    await databaseFactory.setDatabasesPath(tempDir.path);
    DatabaseService.setDatabaseDirectoryOverrideForTest(tempDir.path);
    await DatabaseService.resetForTest();
    MiniMaxMusicService.setPostOverrideForTest(null);
    TextGenerationService.setPostOverrideForTest(null);
  });

  tearDown(() async {
    MiniMaxMusicService.setPostOverrideForTest(null);
    TextGenerationService.setPostOverrideForTest(null);
    await DatabaseService.resetForTest();
    DatabaseService.setDatabaseDirectoryOverrideForTest(null);
    Directory.current = previousDirectory;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('posts MiniMax music request and reuses cached MP3', () async {
    _writeMiniMaxConfig();
    final article = await _saveArticle(
      'Alice sees a bright garden. She sings with the cards.',
    );
    var postCount = 0;
    Map<String, String>? seenHeaders;
    Map<String, dynamic>? seenBody;
    MiniMaxMusicService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        postCount += 1;
        seenHeaders = headers;
        seenBody = body;
        return {
          'data': {
            'audio': '4944330102',
            'status': 2,
          },
          'extra_info': {
            'music_duration': 12345,
          },
          'base_resp': {
            'status_code': 0,
            'status_msg': 'success',
          },
        };
      },
    );

    final result = await MiniMaxMusicService.generateSong(
      article: article,
      stylePrompt: 'bright children musical, whimsical',
      compressLyricsIfNeeded: false,
    );

    expect(result.state.status, 'ready');
    expect(result.state.source, 'minimax');
    expect(await File(result.state.audioPath!).exists(), isTrue);
    expect(postCount, 1);
    expect(
      seenHeaders,
      containsPair(
        'Authorization',
        'Bearer minimax-key-123456789012345678901234',
      ),
    );
    expect(seenBody, containsPair('model', MiniMaxMusicService.model));
    expect(seenBody, containsPair('output_format', 'hex'));
    expect(seenBody?['lyrics'], contains('Alice sees a bright garden.'));

    MiniMaxMusicService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        fail('cached song should not call MiniMax again');
      },
    );
    final cached = await MiniMaxMusicService.generateSong(
      article: article,
      stylePrompt: 'bright children musical, whimsical',
      compressLyricsIfNeeded: false,
    );

    expect(cached.state.status, 'ready');
    expect(cached.state.source, 'minimax');
    expect(cached.state.audioPath, result.state.audioPath);
  });

  test('refuses over-limit lyrics until compression is explicitly allowed',
      () async {
    _writeMiniMaxConfig();
    final article = await _saveArticle(
      List.filled(900, 'Alice follows the song through the garden.').join(' '),
    );
    var called = false;
    MiniMaxMusicService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        called = true;
        return {};
      },
    );

    await expectLater(
      MiniMaxMusicService.generateSong(
        article: article,
        stylePrompt: 'storybook pop',
        compressLyricsIfNeeded: false,
      ),
      throwsA(isA<MiniMaxMusicException>()),
    );
    expect(called, isFalse);
  });

  test('compresses over-limit lyrics before MiniMax generation', () async {
    _writeMiniMaxConfig();
    _writeArkConfig();
    final article = await _saveArticle(
      List.filled(900, 'Alice follows the song through the garden.').join(' '),
    );
    const compressedLyrics =
        '[Verse]\nAlice walks and wonders.\n[Chorus]\nSing through the garden.';
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        return jsonEncode({
          'choices': [
            {
              'message': {'content': compressedLyrics},
            }
          ],
        });
      },
    );
    Map<String, dynamic>? seenBody;
    MiniMaxMusicService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        seenBody = body;
        return {
          'data': {
            'audio': '4944330102',
            'status': 2,
          },
          'base_resp': {
            'status_code': 0,
            'status_msg': 'success',
          },
        };
      },
    );

    final result = await MiniMaxMusicService.generateSong(
      article: article,
      stylePrompt: 'storybook pop',
      compressLyricsIfNeeded: true,
    );

    expect(result.lyricsCompressed, isTrue);
    expect(result.lyrics, compressedLyrics);
    expect(seenBody?['lyrics'], compressedLyrics);
  });
}

Future<Article> _saveArticle(String content) async {
  final sentences = content
      .split(RegExp(r'(?<=[.!?])\s+'))
      .map((sentence) => sentence.trim())
      .where((sentence) => sentence.isNotEmpty)
      .toList(growable: false);
  final article = Article(
    title: 'Song Story',
    content: content,
    sentences: sentences,
    createdAt: DateTime(2026, 1, 1),
  );
  final id = await DatabaseService.saveArticle(article);
  return article.copyWith(id: id);
}

void _writeMiniMaxConfig() {
  final securityDir = Directory('security')..createSync();
  File('${securityDir.path}${Platform.pathSeparator}MiniMax.txt')
      .writeAsStringSync(
    'MINIMAX_API_KEY=minimax-key-123456789012345678901234\n',
  );
}

void _writeArkConfig() {
  final securityDir = Directory('security')..createSync();
  File('${securityDir.path}${Platform.pathSeparator}ark.txt').writeAsStringSync(
    'ARK_API_KEY=ark-key-123456789012345678901234\n'
    'ARK_TEXT_MODEL=${AppConfig.defaultVolcArkTextModel}\n',
  );
}
