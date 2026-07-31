import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/data/models/article_sentence_translation_model.dart';
import 'package:tomato_english_happy_talking/features/follow_read/providers/follow_read_provider.dart';
import 'package:tomato_english_happy_talking/services/api_cache_service.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';

void main() {
  late Directory tempDir;
  late Directory previousDirectory;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (_) async => null,
    );
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      null,
    );
  });

  setUp(() async {
    previousDirectory = Directory.current;
    tempDir = await Directory.systemTemp.createTemp('tomato_follow_nav_');
    Directory.current = tempDir;
    await databaseFactory.setDatabasesPath(tempDir.path);
    DatabaseService.setDatabaseDirectoryOverrideForTest(tempDir.path);
    DatabaseService.setRuntimeDataRootOverrideForTest(tempDir.path);
    await DatabaseService.resetForTest();
  });

  tearDown(() async {
    await DatabaseService.resetForTest();
    DatabaseService.setDatabaseDirectoryOverrideForTest(null);
    DatabaseService.setRuntimeDataRootOverrideForTest(null);
    Directory.current = previousDirectory;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('moves silently between visible sentences and restores saved state',
      () async {
    const sentences = ['First sentence.', '', 'Third sentence.'];
    final now = DateTime.utc(2026, 7, 30);
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Follow navigation',
        content: 'First sentence. Third sentence.',
        sentences: sentences,
        createdAt: now,
      ),
    );
    await DatabaseService.saveArticleSentenceTranslations(
      articleId,
      [
        ArticleSentenceTranslation(
          articleId: articleId,
          sentenceIndex: 0,
          englishSentence: sentences[0],
          chineseText: '第一句。',
          source: 'import',
          createdAt: now,
          updatedAt: now,
        ),
        ArticleSentenceTranslation(
          articleId: articleId,
          sentenceIndex: 2,
          englishSentence: sentences[2],
          chineseText: '第三句。',
          source: 'import',
          createdAt: now,
          updatedAt: now,
        ),
      ],
    );
    final recordingPath = await ApiCacheService.saveLatestSentenceRecording(
      articleId: articleId,
      sentenceIndex: 0,
      sentence: sentences[0],
      audioBytes: const [1, 2, 3, 4],
      recognizedText: 'First sentence.',
      resultJson: jsonEncode({
        'overallScore': 92,
        'accuracyScore': 93,
        'fluencyScore': 91,
        'completenessScore': 94,
        'prosodyScore': 90,
        'recognizedText': 'First sentence.',
        'isMock': false,
        'words': const [],
      }),
    );

    final container = ProviderContainer();
    final subscription = container.listen(
      followReadProvider(articleId),
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(() {
      subscription.close();
      container.dispose();
    });

    final initial = await container.read(followReadProvider(articleId).future);
    expect(initial.currentIndex, 0);
    expect(initial.currentTranslation, '第一句。');
    expect(initial.lastRecordingPath, recordingPath);
    expect(initial.lastResult?.overallScore, 92);

    final notifier = container.read(followReadProvider(articleId).notifier);
    await notifier.previousSentence();
    var current = container.read(followReadProvider(articleId)).requireValue;
    expect(current.currentIndex, 0);

    await notifier.nextSentence();
    current = container.read(followReadProvider(articleId)).requireValue;
    expect(current.currentIndex, 2);
    expect(current.currentTranslation, '第三句。');
    expect(current.step, FollowReadStep.idle);
    expect(current.playbackState.name, 'idle');
    expect(current.lastRecordingPath, isNull);
    expect(current.lastResult, isNull);

    await notifier.previousSentence();
    current = container.read(followReadProvider(articleId)).requireValue;
    expect(current.currentIndex, 0);
    expect(current.currentTranslation, '第一句。');
    expect(current.step, FollowReadStep.idle);
    expect(current.playbackState.name, 'idle');
    expect(current.lastRecordingPath, recordingPath);
    expect(current.lastResult?.overallScore, 92);
    expect(current.liveRecognizedText, 'First sentence.');
  });
}
