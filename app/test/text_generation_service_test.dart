import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/text_generation_service.dart';

void main() {
  late Directory tempDir;
  late Directory previousDirectory;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    previousDirectory = Directory.current;
    tempDir = await Directory.systemTemp.createTemp('tomato_text_gen_test_');
    Directory.current = tempDir;
    await databaseFactory.setDatabasesPath(tempDir.path);
    DatabaseService.setDatabaseDirectoryOverrideForTest(tempDir.path);
    await DatabaseService.resetForTest();
    TextGenerationService.setPostOverrideForTest(null);
  });

  tearDown(() async {
    TextGenerationService.setPostOverrideForTest(null);
    await DatabaseService.resetForTest();
    DatabaseService.setDatabaseDirectoryOverrideForTest(null);
    Directory.current = previousDirectory;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('posts Ark chat body, parses content, and caches with ark_text kind',
      () async {
    _writeArkConfig(
      key: 'ark-request-key-12345678901234567890',
      model: 'doubao-unit-model',
    );

    String? seenEndpoint;
    Map<String, String>? seenHeaders;
    Map<String, dynamic>? seenBody;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        seenEndpoint = endpoint;
        seenHeaders = headers;
        seenBody = body;
        return jsonEncode({
          'choices': [
            {
              'message': {'content': ' OK from Ark '},
            }
          ],
        });
      },
    );

    final turns = [
      const TextGenerationTurn(role: 'system', content: 'Be brief.'),
      const TextGenerationTurn(role: 'user', content: 'Reply OK only.'),
    ];
    final reply = await TextGenerationService.generate(
      turns: turns,
      cachePurpose: 'unit_ark_request',
      fallbackText: 'fallback',
      maxTokens: 42,
    );

    expect(reply.text, 'OK from Ark');
    expect(reply.source, TextGenerationReplySource.remote);
    expect(
      seenEndpoint,
      'https://ark.cn-beijing.volces.com/api/v3/chat/completions',
    );
    expect(
      seenHeaders,
      containsPair(
          'Authorization', 'Bearer ark-request-key-12345678901234567890'),
    );
    expect(seenHeaders, containsPair('Content-Type', 'application/json'));
    expect(seenBody, containsPair('model', 'doubao-unit-model'));
    expect(seenBody, containsPair('max_tokens', 42));
    expect(seenBody, containsPair('stream', false));
    expect(seenBody?['messages'], [
      {'role': 'system', 'content': 'Be brief.'},
      {'role': 'user', 'content': 'Reply OK only.'},
    ]);

    final db = await DatabaseService.database;
    final rows = await db.query('api_cache_entries');
    expect(rows, hasLength(1));
    expect(rows.single['kind'], 'ark_text');
    expect(rows.single['purpose'], 'unit_ark_request');
    expect(rows.single['cache_key'], startsWith('ark_text_'));

    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        fail('cached Ark text should not call HTTP again');
      },
    );
    final cached = await TextGenerationService.generate(
      turns: turns,
      cachePurpose: 'unit_ark_request',
      fallbackText: 'fallback',
      maxTokens: 42,
    );

    expect(cached.text, 'OK from Ark');
    expect(cached.source, TextGenerationReplySource.cached);
  });

  test('returns fallback without calling HTTP when Ark key is empty', () async {
    var called = false;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        called = true;
        return {};
      },
    );

    final reply = await TextGenerationService.generate(
      turns: const [
        TextGenerationTurn(role: 'user', content: 'Reply OK only.'),
      ],
      cachePurpose: 'unit_no_key',
      fallbackText: 'fallback text',
    );

    expect(called, isFalse);
    expect(reply.text, 'fallback text');
    expect(reply.source, TextGenerationReplySource.mockNoKey);
  });

  test('returns fallback on Ark HTTP error', () async {
    _writeArkConfig(key: 'ark-error-key-12345678901234567890');
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        throw Exception('network failed');
      },
    );

    final reply = await TextGenerationService.generate(
      turns: const [
        TextGenerationTurn(role: 'user', content: 'Reply OK only.'),
      ],
      cachePurpose: 'unit_http_error',
      fallbackText: 'fallback on error',
    );

    expect(reply.text, 'fallback on error');
    expect(reply.source, TextGenerationReplySource.mockOnError);
    expect(reply.errorMessage, contains('network failed'));
  });

  test('records suspected safety failures without caching fallback', () async {
    _writeArkConfig(key: 'ark-safety-key-12345678901234567890');
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        final requestOptions = RequestOptions(path: endpoint);
        throw DioException(
          requestOptions: requestOptions,
          response: Response<Object?>(
            requestOptions: requestOptions,
            statusCode: 400,
          ),
          message: 'Bad request',
        );
      },
    );

    final reply = await TextGenerationService.generate(
      turns: const [
        TextGenerationTurn(
          role: 'user',
          content: 'The Queen shouted, "Off with their heads!"',
        ),
      ],
      cachePurpose: 'unit_safety_failure',
      fallbackText: 'fallback on safety',
      articleId: 12,
    );

    expect(reply.text, 'fallback on safety');
    expect(reply.source, TextGenerationReplySource.mockOnError);
    final db = await DatabaseService.database;
    final failures = await db.query('content_safety_failures');
    final cacheRows = await db.query('api_cache_entries');
    expect(failures, hasLength(1));
    expect(failures.single['failed_text'], contains('heads'));
    expect(failures.single['error_code'], 'http_400');
    expect(cacheRows, isEmpty);
  });

  test('returns fallback on empty Ark message content', () async {
    _writeArkConfig(key: 'ark-empty-key-12345678901234567890');
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        return {
          'choices': [
            {
              'message': {'content': '   '},
            }
          ],
        };
      },
    );

    final reply = await TextGenerationService.generate(
      turns: const [
        TextGenerationTurn(role: 'user', content: 'Reply OK only.'),
      ],
      cachePurpose: 'unit_empty_content',
      fallbackText: 'fallback empty',
    );

    expect(reply.text, 'fallback empty');
    expect(reply.source, TextGenerationReplySource.mockOnError);
  });
}

void _writeArkConfig({
  required String key,
  String model = AppConfig.defaultVolcArkTextModel,
}) {
  final securityDir = Directory('security')..createSync();
  File('${securityDir.path}${Platform.pathSeparator}ark.txt').writeAsStringSync(
    'ARK_API_KEY=$key\n'
    'ARK_TEXT_MODEL=$model\n',
  );
}
