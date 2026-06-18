import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/services/content_safety_service.dart';
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
    tempDir = await Directory.systemTemp.createTemp('tomato_safety_test_');
    Directory.current = tempDir;
    await databaseFactory.setDatabasesPath(tempDir.path);
    DatabaseService.setDatabaseDirectoryOverrideForTest(tempDir.path);
    await DatabaseService.resetForTest();
  });

  tearDown(() async {
    await DatabaseService.resetForTest();
    DatabaseService.setDatabaseDirectoryOverrideForTest(null);
    Directory.current = previousDirectory;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('classifies empty HTTP 400 as suspected safety block', () {
    final requestOptions = RequestOptions(path: '/unit');
    final error = DioException(
      requestOptions: requestOptions,
      response: Response<Object?>(
        requestOptions: requestOptions,
        statusCode: 400,
      ),
      message: 'Bad request',
    );

    final result = ContentSafetyService.classifyFailure(error);

    expect(result.suspectedSafetyBlock, isTrue);
    expect(result.statusCode, 400);
    expect(result.errorCode, 'http_400');
  });

  test('records failure snapshots and starts with empty rule state', () async {
    final db = await DatabaseService.database;
    final id = await ContentSafetyService.recordFailure(
      serviceKind: ContentSafetyService.serviceArkText,
      purpose: 'unit_prompt',
      articleId: 3,
      failedText: 'The Queen shouted, "Off with their heads!"',
      errorCode: 'http_400',
      errorMessage: 'HTTP 400',
    );

    expect(id, greaterThan(0));
    final failures = await db.query('content_safety_failures');
    expect(failures, hasLength(1));
    expect(failures.single['failed_hash']?.toString(), isNotEmpty);

    final rules = await db.query('content_safety_rules');
    expect(rules, isEmpty);

    final prepared = await ContentSafetyService.prepareTextForApi(
      'Heads were mentioned before the execution.',
      serviceKind: ContentSafetyService.serviceArkText,
      purpose: 'unit_prompt',
    );
    expect(prepared, 'Heads were mentioned before the execution.');
    expect(prepared, isNot(contains('*')));
  });

  test('does not seed default image rules for unrelated prompts', () async {
    final prepared = await ContentSafetyService.prepareTextForApi(
      'Alice follows the White Rabbit through a bright garden.',
      serviceKind: ContentSafetyService.servicePictureBookImage,
      purpose: 'picture_book_image',
    );

    expect(
      prepared,
      'Alice follows the White Rabbit through a bright garden.',
    );
    final db = await DatabaseService.database;
    final rules = await db.query('content_safety_rules');
    expect(rules, isEmpty);
  });

  test('removes legacy built-in rules without deleting learned rules',
      () async {
    final db = await DatabaseService.database;
    final now = DateTime.now().toIso8601String();
    await db.insert('content_safety_rules', {
      'source_term': 'heads',
      'replacement': 'he-ads',
      'service_kind': '*',
      'purpose_scope': '*',
      'match_type': 'word',
      'confidence': 0.55,
      'enabled': 1,
      'source_failure_id': null,
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('content_safety_rules', {
      'source_term': 'daggers',
      'replacement': 'dag-gers',
      'service_kind': ContentSafetyService.serviceArkText,
      'purpose_scope': ContentSafetyService.purposeAny,
      'match_type': 'word',
      'confidence': 0.9,
      'enabled': 1,
      'source_failure_id': 12,
      'created_at': now,
      'updated_at': now,
    });

    await DatabaseService.resetForTest();
    final reopened = await DatabaseService.database;
    final rules = await reopened.query(
      'content_safety_rules',
      orderBy: 'source_term ASC',
    );

    expect(rules.map((row) => row['source_term']), ['daggers']);
  });

  test('learns word-level replacement after a successful user retry', () async {
    final failureId = await ContentSafetyService.recordFailure(
      serviceKind: ContentSafetyService.serviceArkText,
      purpose: 'unit_prompt',
      failedText: 'The old story word daggers appears here.',
      errorCode: 'http_400',
      errorMessage: 'HTTP 400',
    );

    final learned = await ContentSafetyService.learnRulesFromSuccessfulRetry(
      failureId: failureId,
      successfulText: 'The old story word dag-gers appears here.',
      serviceKind: ContentSafetyService.serviceArkText,
    );

    expect(learned.map((rule) => rule.sourceTerm), contains('daggers'));
    final prepared = await ContentSafetyService.prepareTextForApi(
      'Many daggers are listed.',
      serviceKind: ContentSafetyService.serviceArkText,
      purpose: 'another_prompt',
    );
    expect(prepared, contains('dag-gers'));
  });

  test('does not create a rule from a broad sentence rewrite', () async {
    final failureId = await ContentSafetyService.recordFailure(
      serviceKind: ContentSafetyService.serviceArkText,
      purpose: 'unit_prompt',
      failedText: 'The old story word daggers appears here.',
      errorCode: 'http_400',
      errorMessage: 'HTTP 400',
    );

    final learned = await ContentSafetyService.learnRulesFromSuccessfulRetry(
      failureId: failureId,
      successfulText: 'The child calmly walks through a garden.',
      serviceKind: ContentSafetyService.serviceArkText,
    );

    expect(learned, isEmpty);
    final db = await DatabaseService.database;
    final rules = await db.query(
      'content_safety_rules',
      where: 'source_term = ?',
      whereArgs: ['daggers'],
    );
    expect(rules, isEmpty);
  });
}
