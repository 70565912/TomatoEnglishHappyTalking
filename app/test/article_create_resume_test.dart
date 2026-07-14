import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/data/models/article_sentence_translation_model.dart';
import 'package:tomato_english_happy_talking/features/web_shell/web_bridge_protocol.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/picture_book_service.dart';

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
        await Directory.systemTemp.createTemp('tomato_article_create_resume_');
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

  test('upsertArticleSentenceTranslations keeps other sentence rows', () async {
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Resume Chapter',
        content: 'Hello world. Goodbye world.',
        sentences: const ['Hello world.', 'Goodbye world.'],
        createdAt: DateTime.utc(2026, 7, 14),
      ),
    );
    final now = DateTime.utc(2026, 7, 14);
    await DatabaseService.upsertArticleSentenceTranslations(articleId, [
      ArticleSentenceTranslation(
        articleId: articleId,
        sentenceIndex: 0,
        englishSentence: 'Hello world.',
        chineseText: '你好世界。',
        source: 'imported',
        createdAt: now,
        updatedAt: now,
      ),
    ]);
    await DatabaseService.upsertArticleSentenceTranslations(articleId, [
      ArticleSentenceTranslation(
        articleId: articleId,
        sentenceIndex: 1,
        englishSentence: 'Goodbye world.',
        chineseText: '再见世界。',
        source: 'generated_batch_at_create',
        createdAt: now,
        updatedAt: now,
      ),
    ]);

    final rows =
        await DatabaseService.getArticleSentenceTranslationsForSentences(
      articleId: articleId,
      sentences: const ['Hello world.', 'Goodbye world.'],
    );
    expect(rows[0], '你好世界。');
    expect(rows[1], '再见世界。');
  });

  test('ArticleCreateResumeException exposes bridge resume data', () {
    const error = ArticleCreateResumeException(
      message: '译文失败。正文已写入书库，再次保存将继续补齐。',
      resumeArticleId: 42,
      failedPhase: 'translations',
      article: {'id': 42, 'title': 'Resume Chapter'},
    );
    final response = BridgeResponse.error(
      id: 'req-1',
      type: 'article.create.error',
      message: error.toString(),
      data: error.toBridgeData(),
    );
    expect(response['ok'], isFalse);
    final err = response['error'] as Map<String, dynamic>;
    expect(err['message'], contains('正文已写入书库'));
    final data = err['data'] as Map<String, dynamic>;
    expect(data['resumeArticleId'], 42);
    expect(data['failedPhase'], 'translations');
  });

  test('readPersistedChapterPlan skips empty scene plans', () {
    final plan = PictureBookService.readPersistedChapterPlan(
      summaryJson: '''
{
  "planKind": "picture_book_chapter_scene_plan_v2",
  "chapterDescription": "Coastal talk.",
  "scenes": [
    {
      "pageIndex": 0,
      "sentenceStartIndex": 0,
      "sentenceEndIndex": 1,
      "sceneDescription": "Alice listens by the rock."
    }
  ],
  "newCharacters": []
}
''',
      sentenceCount: 2,
    );
    expect(plan, isNotNull);
    expect(plan!.scenes, hasLength(1));

    final empty = PictureBookService.readPersistedChapterPlan(
      summaryJson: '''
{
  "planKind": "picture_book_chapter_scene_plan_v2",
  "chapterDescription": "Coastal talk.",
  "scenes": [
    {
      "pageIndex": 0,
      "sentenceStartIndex": 0,
      "sentenceEndIndex": 1,
      "sceneDescription": ""
    }
  ],
  "newCharacters": []
}
''',
      sentenceCount: 2,
    );
    expect(empty, isNull);
  });
}
