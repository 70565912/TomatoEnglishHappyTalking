import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path_lib;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/data/models/article_sentence_translation_model.dart';
import 'package:tomato_english_happy_talking/data/models/picture_book_model.dart';
import 'package:tomato_english_happy_talking/services/api_cache_service.dart';
import 'package:tomato_english_happy_talking/services/aliyun_wanx_image_service.dart';
import 'package:tomato_english_happy_talking/services/content_safety_service.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/listening_audio_material_service.dart';
import 'package:tomato_english_happy_talking/services/nlp_service.dart';
import 'package:tomato_english_happy_talking/services/picture_book_image_service.dart';
import 'package:tomato_english_happy_talking/services/picture_book_service.dart';
import 'package:tomato_english_happy_talking/services/practice_input_parser.dart';
import 'package:tomato_english_happy_talking/services/text_generation_service.dart';
import 'package:tomato_english_happy_talking/services/tts_memory_cache_service.dart';
import 'package:tomato_english_happy_talking/services/tts_service.dart';
import 'package:tomato_english_happy_talking/services/volc_image_service.dart';

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
    tempDir = await Directory.systemTemp.createTemp('tomato_api_cache_test_');
    Directory.current = tempDir;
    await databaseFactory.setDatabasesPath(tempDir.path);
    DatabaseService.setDatabaseDirectoryOverrideForTest(tempDir.path);
    await DatabaseService.resetForTest();
    TextGenerationService.setPostOverrideForTest(null);
    AliyunWanxImageService.setOverridesForTest();
    VolcImageService.setPostOverrideForTest(null);
    ListeningAudioMaterialService.setPreloadOverrideForTest(null);
    AppConfig.resetRuntimeConfigForTest();
  });

  tearDown(() async {
    TextGenerationService.setPostOverrideForTest(null);
    AliyunWanxImageService.setOverridesForTest();
    VolcImageService.setPostOverrideForTest(null);
    ListeningAudioMaterialService.setPreloadOverrideForTest(null);
    AppConfig.resetRuntimeConfigForTest();
    await DatabaseService.resetForTest();
    DatabaseService.setDatabaseDirectoryOverrideForTest(null);
    DatabaseService.setRuntimeDataRootOverrideForTest(null);
    Directory.current = previousDirectory;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
      'creates persistent cache, picture-book, translation, and safety tables at database version 7',
      () async {
    final db = await DatabaseService.database;
    expect(await db.getVersion(), 7);

    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final tableNames = rows.map((row) => row['name']).toSet();

    expect(tableNames, contains('api_cache_entries'));
    expect(tableNames, contains('api_cache_article_refs'));
    expect(tableNames, contains('latest_sentence_recordings'));
    expect(tableNames, contains('story_series'));
    expect(tableNames, contains('story_chapters'));
    expect(tableNames, contains('picture_book_pages'));
    expect(tableNames, contains('article_sentence_translations'));
    expect(tableNames, contains('article_chat_guides'));
    expect(tableNames, contains('content_safety_failures'));
    expect(tableNames, contains('content_safety_rules'));
    expect(tableNames, isNot(contains('story_reference_assets')));
    final seriesColumns = await db.rawQuery('PRAGMA table_info(story_series)');
    final seriesColumnNames = seriesColumns.map((row) => row['name']).toSet();
    expect(seriesColumnNames, contains('description'));
    expect(seriesColumnNames, contains('characters_json'));
    expect(seriesColumnNames, isNot(contains('style_guide_json')));
    expect(seriesColumnNames, isNot(contains('bible_json')));
  });

  test('deletes empty story series and refuses series with chapters', () async {
    final now = DateTime(2026, 1, 1);
    final emptySeries = await PictureBookService.createSeries(
      title: 'Empty Book',
    );
    final filledSeries = await PictureBookService.createSeries(
      title: 'Filled Book',
    );
    final articleId = await _saveArticle('Alice looks at the garden.');
    await DatabaseService.saveStoryChapter(
      StoryChapter(
        seriesId: filledSeries.id!,
        articleId: articleId,
        chapterOrder: 1,
        chapterTitle: 'Chapter One',
        summaryJson: '{}',
        createdAt: now,
        updatedAt: now,
      ),
    );

    expect(
      await DatabaseService.deleteStorySeriesIfEmpty(filledSeries.id!),
      isFalse,
    );
    expect(
        await DatabaseService.getStorySeriesById(filledSeries.id!), isNotNull);

    expect(
      await DatabaseService.deleteStorySeriesIfEmpty(emptySeries.id!),
      isTrue,
    );

    expect(await DatabaseService.getStorySeriesById(emptySeries.id!), isNull);
  });

  test('deletes empty story series with orphan chapter rows', () async {
    final now = DateTime(2026, 1, 1);
    final orphanSeries = await PictureBookService.createSeries(
      title: 'Orphan Book',
    );
    final db = await DatabaseService.database;
    await db.insert(
      'story_chapters',
      StoryChapter(
        seriesId: orphanSeries.id!,
        articleId: 999999,
        chapterOrder: 1,
        chapterTitle: 'Missing Chapter',
        summaryJson: '{}',
        createdAt: now,
        updatedAt: now,
      ).toMap(),
    );

    expect(
      await DatabaseService.deleteStorySeriesIfEmpty(orphanSeries.id!),
      isTrue,
    );
    expect(await DatabaseService.getStorySeriesById(orphanSeries.id!), isNull);
    final orphanRows = await db.query(
      'story_chapters',
      where: 'series_id = ?',
      whereArgs: [orphanSeries.id!],
    );
    expect(orphanRows, isEmpty);
  });

  test('requires explicit user book title for series creation and description',
      () async {
    expect(
      () => PictureBookService.createSeries(title: '   '),
      throwsA(isA<FormatException>()),
    );

    final now = DateTime(2026, 1, 1);
    final article = Article(
      title: 'The Little Gate',
      content: 'Lily opens a little green gate.',
      sentences: const ['Lily opens a little green gate.'],
      createdAt: now,
    );

    await expectLater(
      PictureBookService.suggestBookDescription(
        article: article,
        seriesTitle: '   ',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('suggests draft book description fails when text key is missing',
      () async {
    var textCalled = false;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        textCalled = true;
        return const {};
      },
    );
    final now = DateTime(2026, 1, 1);
    final article = Article(
      title: 'The Little Gate',
      content:
          'Lily opens a little green gate. A rabbit waves from the flowers.',
      sentences: const [
        'Lily opens a little green gate.',
        'A rabbit waves from the flowers.',
      ],
      createdAt: now,
    );
    await expectLater(
      PictureBookService.suggestBookDescription(
        article: article,
        seriesTitle: 'Lily Garden',
      ),
      throwsA(
        isA<TextGenerationException>().having(
          (error) => error.message,
          'message',
          contains('未配置'),
        ),
      ),
    );

    expect(textCalled, isFalse);
  });

  test('deleting an article removes its exclusive cached file', () async {
    final articleId = await _saveArticle('Tom finds a bright snack box.');
    final request = {
      'service': 'unit',
      'text': 'Tom finds a bright snack box.',
    };
    final cacheKey = await ApiCacheService.keyForJson('tts', request);
    final filePath = await ApiCacheService.putFileBytes(
      cacheKey: cacheKey,
      kind: 'tts',
      purpose: 'follow_tts',
      request: request,
      bytes: [1, 2, 3, 4],
      subdirectory: 'tts',
      extension: 'mp3',
      contentType: 'audio/mpeg',
      articleId: articleId,
    );

    expect(await File(filePath).exists(), isTrue);
    await DatabaseService.deleteArticle(articleId);

    expect(await File(filePath).exists(), isFalse);
    final db = await DatabaseService.database;
    final entries = await db.query('api_cache_entries');
    final refs = await db.query('api_cache_article_refs');
    expect(entries, isEmpty);
    expect(refs, isEmpty);
  });

  test('stores cached asset files under the runtime data cache root', () async {
    final request = {'service': 'unit', 'text': 'asset root'};
    final cacheKey = await ApiCacheService.keyForJson('tts', request);

    final filePath = await ApiCacheService.putFileBytes(
      cacheKey: cacheKey,
      kind: 'tts',
      purpose: 'listening_tts',
      request: request,
      bytes: [1, 2, 3],
      subdirectory: 'tts',
      extension: 'mp3',
      contentType: 'audio/mpeg',
    );

    final expectedRoot = path_lib.join(tempDir.path, 'tomato_api_cache');
    expect(
      path_lib.isWithin(expectedRoot, filePath),
      isTrue,
    );
    expect(filePath, isNot(contains('.dart_tool')));
  });

  test('listening audio material status reads local cache only', () async {
    const content = 'Tom waves. He smiles.';
    final articleId = await _saveArticle(
      content,
      sentences: NlpService.splitSentences(content),
    );
    await _writeCachedListeningTts(
      articleId: articleId,
      text: 'Tom waves.',
      bytes: [1, 2, 3],
    );

    final status = await ListeningAudioMaterialService.status(articleId);

    expect(status.total, 2);
    expect(status.ready, 1);
    expect(status.missing, [1]);
    expect(status.status, 'partial');
  });

  test('listening materials keep saved sentence boundaries and translations',
      () async {
    const savedSentence = 'Tom waves. He smiles.';
    final articleId = await _saveArticle(
      savedSentence,
      sentences: [savedSentence],
    );
    await _writeCachedListeningTts(
      articleId: articleId,
      text: savedSentence,
      bytes: [1, 2, 3],
    );
    final now = DateTime(2026, 1, 1);
    await DatabaseService.saveArticleSentenceTranslations(articleId, [
      ArticleSentenceTranslation(
        articleId: articleId,
        sentenceIndex: 0,
        englishSentence: savedSentence,
        chineseText: '汤姆挥手。他笑了。',
        source: 'import',
        createdAt: now,
        updatedAt: now,
      ),
    ]);

    final status = await ListeningAudioMaterialService.status(articleId);
    final article = await DatabaseService.getArticleById(articleId);
    final translations =
        await DatabaseService.getArticleSentenceTranslationsForSentences(
      articleId: articleId,
      sentences: article?.sentences ?? const [],
    );

    expect(status.total, 1);
    expect(status.ready, 1);
    expect(status.missing, isEmpty);
    expect(article?.sentences, [savedSentence]);
    expect(translations, {0: '汤姆挥手。他笑了。'});
  });

  test('listening status accepts historical voice cache for the same sentence',
      () async {
    const sentence = 'Tom waves.';
    final articleId = await _saveArticle(sentence, sentences: [sentence]);
    await _writeHistoricalListeningTts(
      articleId: articleId,
      text: sentence,
      request: {
        'service': 'doubao_tts_2',
        'endpoint': 'https://legacy.example.test/tts',
        'resourceId': 'legacy-resource',
        'speaker': 'legacy_voice',
        'text': sentence,
      },
      bytes: [6, 7, 8],
    );

    final status = await ListeningAudioMaterialService.status(articleId);
    final handle = await ListeningAudioMaterialService.cachedFileHandle(
      text: sentence,
      articleId: articleId,
    );

    expect(status.total, 1);
    expect(status.ready, 1);
    expect(status.missing, isEmpty);
    expect(handle, isNotNull);
    expect(await File(handle!.filePath).readAsBytes(), [6, 7, 8]);
  });

  test(
      'listening audio material generation fills missing and overwrites caches',
      () async {
    const content = 'Tom waves. He smiles.';
    final articleId = await _saveArticle(
      content,
      sentences: NlpService.splitSentences(content),
    );
    await _writeCachedListeningTts(
      articleId: articleId,
      text: 'Tom waves.',
      bytes: [1, 2, 3],
    );
    final legacyFollowPath = await _writeCachedListeningTts(
      articleId: articleId,
      text: 'Legacy follow only.',
      purpose: ListeningAudioMaterialService.legacyFollowCachePurpose,
      bytes: [7, 7, 7],
    );
    final generated = <String>[];
    ListeningAudioMaterialService.setPreloadOverrideForTest((
      requests, {
      onProgress,
    }) async {
      var completed = 0;
      for (final request in requests) {
        generated.add(request.text);
        await _writeCachedListeningTts(
          articleId: articleId,
          text: request.text,
          purpose: request.cachePurpose,
          bytes: [9, 8, 7, completed + 1],
        );
        completed += 1;
        onProgress?.call(TtsPreloadProgress(
          completed: completed,
          total: requests.length,
          failed: 0,
        ));
      }
    });

    final fillMissing = await ListeningAudioMaterialService.generate(
      articleId: articleId,
      overwrite: false,
    );

    expect(fillMissing.requested, 1);
    expect(generated, ['He smiles.']);
    expect(fillMissing.ready, 2);
    expect(fillMissing.missing, isEmpty);
    expect(await File(legacyFollowPath).exists(), isTrue);

    generated.clear();
    final overwrite = await ListeningAudioMaterialService.generate(
      articleId: articleId,
      overwrite: true,
    );

    expect(overwrite.requested, 2);
    expect(generated, ['Tom waves.', 'He smiles.']);
    expect(overwrite.ready, 2);
    expect(overwrite.missing, isEmpty);
    expect(await File(legacyFollowPath).exists(), isFalse);
  });

  test('migrates legacy cached files from the database directory', () async {
    final runtimeRoot = path_lib.join(tempDir.path, 'runtime-root');
    DatabaseService.setRuntimeDataRootOverrideForTest(runtimeRoot);
    const cacheKey = 'tts_legacy_asset';
    final legacyPath = path_lib.join(
      tempDir.path,
      'tomato_api_cache',
      'tts',
      '$cacheKey.mp3',
    );
    await File(legacyPath).parent.create(recursive: true);
    await File(legacyPath).writeAsBytes([7, 8, 9], flush: true);
    final now = DateTime.now().toIso8601String();
    final db = await DatabaseService.database;
    await db.insert('api_cache_entries', {
      'cache_key': cacheKey,
      'kind': 'tts',
      'purpose': 'listening_tts',
      'request_json': '{}',
      'text_value': null,
      'json_value': null,
      'file_path': legacyPath,
      'content_type': 'audio/mpeg',
      'byte_length': 3,
      'source': 'remote',
      'created_at': now,
      'updated_at': now,
      'last_used_at': now,
    });

    final migratedPath = await ApiCacheService.getFilePath(cacheKey);
    final expectedPath = path_lib.join(
      runtimeRoot,
      'tomato_api_cache',
      'tts',
      '$cacheKey.mp3',
    );

    expect(migratedPath, expectedPath);
    expect(await File(expectedPath).readAsBytes(), [7, 8, 9]);
    final rows = await db.query(
      'api_cache_entries',
      columns: ['file_path'],
      where: 'cache_key = ?',
      whereArgs: [cacheKey],
    );
    expect(rows.single['file_path'], expectedPath);
  });

  test('shared cached files survive until the last article is deleted',
      () async {
    final firstArticleId = await _saveArticle('Tom finds a bright snack box.');
    final secondArticleId = await _saveArticle('He shares it with his team.');
    final request = {
      'service': 'unit',
      'text': 'Shared sentence.',
    };
    final cacheKey = await ApiCacheService.keyForJson('tts', request);
    final filePath = await ApiCacheService.putFileBytes(
      cacheKey: cacheKey,
      kind: 'tts',
      purpose: 'listening_tts',
      request: request,
      bytes: [8, 6, 7, 5],
      subdirectory: 'tts',
      extension: 'mp3',
      contentType: 'audio/mpeg',
      articleId: firstArticleId,
    );
    await ApiCacheService.attachArticleRef(
      articleId: secondArticleId,
      cacheKey: cacheKey,
      purpose: 'listening_tts',
    );

    await DatabaseService.deleteArticle(firstArticleId);
    expect(await File(filePath).exists(), isTrue);
    expect(await ApiCacheService.getFilePath(cacheKey), filePath);

    await DatabaseService.deleteArticle(secondArticleId);
    expect(await File(filePath).exists(), isFalse);
    expect(await ApiCacheService.getFilePath(cacheKey), isNull);
  });

  test('finds latest cache entry for an article purpose', () async {
    final articleId = await _saveArticle('Tom sings about a bright snack box.');
    final olderRequest = {'service': 'song', 'version': 1};
    final newerRequest = {'service': 'song', 'version': 2};
    final olderKey = await ApiCacheService.keyForJson(
      'article_song_audio',
      olderRequest,
    );
    final newerKey = await ApiCacheService.keyForJson(
      'article_song_audio',
      newerRequest,
    );
    await ApiCacheService.putFileBytes(
      cacheKey: olderKey,
      kind: 'suno_song',
      purpose: 'article_song_audio_v1',
      request: olderRequest,
      bytes: [1, 2, 3],
      subdirectory: 'music/article_$articleId',
      extension: 'mp3',
      contentType: 'audio/mpeg',
      articleId: articleId,
    );
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final newerPath = await ApiCacheService.putFileBytes(
      cacheKey: newerKey,
      kind: 'suno_song',
      purpose: 'article_song_audio_v1',
      request: newerRequest,
      bytes: [4, 5, 6],
      subdirectory: 'music/article_$articleId',
      extension: 'mp3',
      contentType: 'audio/mpeg',
      articleId: articleId,
    );

    final latest = await ApiCacheService.getLatestEntryForArticlePurpose(
      articleId: articleId,
      purpose: 'article_song_audio_v1',
    );

    expect(latest?.cacheKey, newerKey);
    expect(latest?.filePath, newerPath);

    final entries = await ApiCacheService.getEntriesForArticlePurpose(
      articleId: articleId,
      purpose: 'article_song_audio_v1',
    );
    expect(entries.map((entry) => entry.cacheKey), [newerKey, olderKey]);
  });

  test('stores and removes the latest sentence recording with its article',
      () async {
    final articleId = await _saveArticle('Tom finds a bright snack box.');
    final recordingPath = await ApiCacheService.saveLatestSentenceRecording(
      articleId: articleId,
      sentenceIndex: 0,
      sentence: 'Tom finds a bright snack box.',
      audioBytes: [82, 73, 70, 70, 1, 2, 3],
      recognizedText: 'Tom finds a bright snack box.',
      resultJson: '{"recognizedText":"Tom finds a bright snack box."}',
    );

    final recording = await ApiCacheService.getLatestSentenceRecording(
      articleId: articleId,
      sentenceIndex: 0,
    );
    expect(recording?.recordingPath, recordingPath);
    expect(recording?.recognizedText, 'Tom finds a bright snack box.');

    await DatabaseService.deleteArticle(articleId);
    expect(await File(recordingPath).exists(), isFalse);
    expect(
      await ApiCacheService.getLatestSentenceRecording(
        articleId: articleId,
        sentenceIndex: 0,
      ),
      isNull,
    );
  });

  test(
      'picture-book generation records planning error when text provider key is missing',
      () async {
    final articleId = await _saveArticle(
      'Tom finds a bright snack box. He shares it with his team.',
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(title: 'Space Story');
    final seriesId = series.id;
    if (seriesId == null || article == null) {
      fail('test article and series should be saved');
    }
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: seriesId,
      article: article,
    );

    await PictureBookService.generateForArticle(
      article: article,
      chapter: chapter,
    );

    final state = await PictureBookService.statePayload(articleId);
    expect(state['enabled'], isTrue);
    expect(state['status'], 'error');
    final pages = state['pages'] as List;
    expect(pages, hasLength(1));
    final page = pages.single as Map<String, dynamic>;
    expect(page['status'], 'error');
    expect(
      page['errorMessage'],
      contains('文本提交处理失败：未配置 阿里云百炼 API Key'),
    );
  });

  test(
      'picture-book generation uses one chapter plan text request for all prompts',
      () async {
    _writeImageArkKey(tempDir, 'ark-plan-key-12345678901234567890');
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Test',
        content:
            'Alice walks into the garden. The Queen points at the croquet ground.',
        sentences: const [
          'Alice walks into the garden.',
          'The Queen points at the croquet ground.',
        ],
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
      description:
          'Victorian fantasy picture book; Alice wears a blue dress and white apron.',
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    var textCalls = 0;
    Map<String, dynamic>? textBody;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        textCalls += 1;
        textBody = body;
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'planKind': 'picture_book_chapter_scene_plan_v2',
                  'chapterDescription':
                      'Alice is a curious Victorian girl in a blue dress and white apron. Alice meets the Queen on the croquet-ground.',
                  'scenes': [
                    {
                      'pageIndex': 0,
                      'sentenceStartIndex': 0,
                      'sentenceEndIndex': 0,
                      'sceneDescription': 'Alice walks into the garden.',
                    },
                    {
                      'pageIndex': 1,
                      'sentenceStartIndex': 1,
                      'sentenceEndIndex': 1,
                      'sceneDescription': 'The Queen points ahead.',
                    },
                  ],
                }),
              },
            }
          ],
        };
      },
    );
    Map<String, dynamic>? imageBody;
    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        imageBody = body;
        return {
          'data': [
            {
              'b64_json': base64Encode([137, 80, 78, 71, 1])
            },
            {
              'b64_json': base64Encode([137, 80, 78, 71, 2])
            },
          ],
        };
      },
    );

    await PictureBookService.generateForArticle(
      article: article,
      chapter: chapter,
    );

    expect(textCalls, 1);
    expect(
      textBody?['response_format'],
      {'type': 'json_object'},
    );
    final textMessages = (textBody?['messages'] as List?) ?? const [];
    final planningPrompt = textMessages
        .map((message) => (message as Map)['content']?.toString() ?? '')
        .join('\n')
        .toLowerCase();
    expect(planningPrompt, contains('chapterdescription'));
    expect(planningPrompt, isNot(contains('storybrief')));
    expect(planningPrompt, isNot(contains('chapterbrief')));
    expect(planningPrompt, contains('scenes'));
    expect(planningPrompt, contains('victorian fantasy picture book'));
    expect(planningPrompt, contains('do not repeat character appearance'));
    expect(
      planningPrompt,
      contains('picture-book narrative scene plan'),
    );
    expect(
      planningPrompt,
      contains('convert speech into drawable visible action'),
    );
    expect(
      planningPrompt,
      contains('chapter text is the source prose'),
    );
    expect(
      planningPrompt,
      contains(
          'base chapterdescription and scenedescription on its drawable details'),
    );
    expect(
      planningPrompt,
      contains('convert all direct dialogue'),
    );
    expect(
      planningPrompt,
      contains('into third-person visible-scene narrative'),
    );
    expect(
      planningPrompt,
      contains('prefer visible action, pose, object, spatial relation'),
    );
    expect(
      planningPrompt,
      contains('avoid chaining ask, asks, explain, explains'),
    );
    expect(
      planningPrompt,
      contains('for riddles, songs, shouts, and wordplay'),
    );
    expect(
      planningPrompt,
      contains('do not restate the riddle wording'),
    );
    expect(
      planningPrompt,
      contains('keep source-prose drawable details'),
    );
    expect(
      planningPrompt,
      contains('never write quoted speech'),
    );
    expect(
      planningPrompt,
      contains('speech bubbles'),
    );
    expect(
      planningPrompt,
      contains('before splitting scenes, convert quoted speech'),
    );
    expect(
      planningPrompt,
      contains('decide boundaries by illustration situation'),
    );
    expect(
      planningPrompt,
      contains(
          'place/time, main visual focus group, and central ongoing activity'),
    );
    expect(
      planningPrompt,
      contains("focused characters' main task and its target"),
    );
    expect(
      planningPrompt,
      contains('not each new visible beat'),
    );
    expect(
      planningPrompt,
      contains('those sentence slots must stay in the same scene'),
    );
    expect(
      planningPrompt,
      contains('build scenes by walking numbered sentences in order'),
    );
    expect(
      planningPrompt,
      contains('numbered indexes are coverage anchors only'),
    );
    expect(
      planningPrompt,
      contains('one illustration may cover many consecutive sentences'),
    );
    expect(
      planningPrompt,
      contains('consecutive run of facts, examples, list items'),
    );
    expect(
      planningPrompt,
      contains('same subject in the same time/place frame'),
    );
    expect(
      planningPrompt,
      contains('one central topic block, not one scene per fact'),
    );
    expect(
      planningPrompt,
      contains('render its related details together'),
    );
    expect(
      planningPrompt,
      contains('split that fact/list block only when'),
    );
    expect(
      planningPrompt,
      contains('local fact/list rule must not override'),
    );
    expect(
      planningPrompt,
      contains('sequential movement, object manipulation, discovery, accident'),
    );
    expect(
      planningPrompt,
      contains('do not target a fixed number of scenes'),
    );
    expect(
      planningPrompt,
      contains('consecutive content from the same illustration situation'),
    );
    expect(
      planningPrompt,
      contains(
          'start a new scene only when one axis changes materially enough'),
    );
    expect(
      planningPrompt,
      contains(
          'do not start a new scene for conversation turns, questions, answers'),
    );
    expect(
      planningPrompt,
      contains(
          'riddles, arguments, remarks, jokes, reactions, emotion changes'),
    );
    expect(
      planningPrompt,
      contains('repeated same-type micro-actions'),
    );
    expect(
      planningPrompt,
      contains('cause, immediate result, and direct recovery'),
    );
    expect(
      planningPrompt,
      contains('if a candidate boundary differs only by speech turns'),
    );
    expect(
      planningPrompt,
      contains('must use only events and scene facts from its own'),
    );
    expect(
      planningPrompt,
      contains('preserve who performs each action'),
    );
    expect(
      planningPrompt,
      contains('audit every adjacent scene boundary'),
    );
    expect(
      planningPrompt,
      contains('one shared illustration can represent both ranges'),
    );
    expect(
      planningPrompt,
      contains(
          'dialogue, song, shout, and inner-thought sentences are coverage anchors'),
    );
    expect(
      planningPrompt,
      contains('convert their plot and scene meaning into visible narrative'),
    );
    expect(
      planningPrompt,
      contains('do not replace converted speech with empty meta words only'),
    );
    expect(
      planningPrompt,
      contains('exchange, conversation, discuss, debate'),
    );
    expect(
      planningPrompt,
      contains(
          'dialogue-heavy ranges in one illustration situation must remain one scene'),
    );
    expect(
        planningPrompt, contains('hard validation cap: scenes.length <= 12'));
    expect(
      planningPrompt,
      contains('do not invent splits to approach the cap'),
    );
    expect(
      planningPrompt,
      contains('do not open many one-sentence scenes'),
    );
    expect(
      planningPrompt,
      isNot(contains('keep one continuous tea-table, kitchen, roadside')),
    );
    expect(planningPrompt, isNot(contains('main task of the gathering')));
    expect(planningPrompt, isNot(contains('and visual change')));
    expect(planningPrompt, isNot(contains('continuous story scene')));
    expect(planningPrompt, isNot(contains('mentally delete')));
    expect(planningPrompt, isNot(contains('remove direct dialogue')));
    expect(planningPrompt, isNot(contains('non-dialogue visual prose')));
    expect(
      planningPrompt,
      isNot(contains('do not quote, paraphrase, or summarize speech')),
    );
    expect(planningPrompt, isNot(contains('remove speech/thought content')));
    expect(
      planningPrompt,
      isNot(contains('do not write substitute dialogue-summary words')),
    );
    expect(planningPrompt, isNot(contains('compact')));
    expect(planningPrompt, isNot(contains('major drawable details')));
    expect(planningPrompt, isNot(contains('generic summary beats')));
    expect(planningPrompt, isNot(contains('same visible picture')));
    expect(planningPrompt, isNot(contains('physical picture')));
    expect(planningPrompt, isNot(contains('visible emotional state')));
    expect(
        planningPrompt, isNot(contains('do not summarize dialogue content')));
    expect(planningPrompt, isNot(contains('dialogue-only span')));
    expect(planningPrompt,
        isNot(contains('would make the scenedescription vague')));
    expect(planningPrompt, isNot(contains('detail-rich moments')));
    expect(planningPrompt, isNot(contains('smallest complete scene set')));
    expect(planningPrompt, isNot(contains('merge micro-phases')));
    expect(planningPrompt, isNot(contains('micro-phases')));
    expect(planningPrompt, isNot(contains('weak boundary')));
    expect(planningPrompt, isNot(contains('even if several actions')));
    expect(planningPrompt, isNot(contains('foreground and background action')));
    expect(planningPrompt, isNot(contains('object handoff')));
    expect(planningPrompt, isNot(contains('small ceremony')));
    expect(planningPrompt, isNot(contains('minimum number')));
    expect(planningPrompt, isNot(contains('question, answer')));
    expect(planningPrompt, isNot(contains('typical chapters')));
    expect(planningPrompt, isNot(contains('4-9 scenes')));
    expect(planningPrompt, isNot(contains('for example')));
    expect(planningPrompt, isNot(contains('e.g.')));
    expect(planningPrompt, isNot(contains('such as')));
    expect(planningPrompt, contains('use character names only'));
    expect(planningPrompt, isNot(contains('bailian')));
    expect(planningPrompt, isNot(contains('aliyun')));
    expect(planningPrompt, isNot(contains('qwen')));
    expect(planningPrompt, isNot(contains('audience')));
    expect(planningPrompt, isNot(contains('safety')));
    expect(planningPrompt, isNot(contains('negativeprompt')));
    expect(planningPrompt, isNot(contains('subtitle')));
    expect(planningPrompt, isNot(contains('caption')));
    expect(planningPrompt, isNot(contains('app-rendered')));
    expect(planningPrompt, isNot(contains('open clean space')));
    expect(planningPrompt, isNot(contains('text-free')));
    expect(planningPrompt, isNot(contains('no visible text')));
    expect(
      (imageBody?['sequential_image_generation_options'] as Map)['max_images'],
      2,
    );
    final pages = await DatabaseService.getPictureBookPages(articleId);
    expect(pages, hasLength(2));
    expect(pages.every((page) => page.status == 'ready'), isTrue);
    expect(pages.first.promptJson, contains('blue dress and white apron'));
    final updatedChapter =
        await DatabaseService.getStoryChapterForArticle(articleId);
    expect(updatedChapter?.summaryJson,
        contains('picture_book_chapter_scene_plan_v2'));
  });

  test('Ark image generation sends reference images and reuses cache',
      () async {
    _writeImageArkKey(tempDir, 'ark-image-key-12345678901234567890');
    final referenceFile = File(
      '${tempDir.path}${Platform.pathSeparator}reference.png',
    )..writeAsBytesSync([137, 80, 78, 71, 9, 9, 9]);
    Map<String, dynamic>? seenBody;
    var calls = 0;
    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        calls += 1;
        seenBody = body;
        expect(
          endpoint,
          'https://ark.cn-beijing.volces.com/api/v3/images/generations',
        );
        expect(headers['Authorization'], startsWith('Bearer ark-image-key'));
        return {
          'data': [
            {
              'b64_json': base64Encode([137, 80, 78, 71, 1, 2, 3])
            },
          ],
        };
      },
    );

    final first = await VolcImageService.generatePictureBookImage(
      prompt: 'A warm picture-book scene with a small wooden sign.',
      promptMetadata: const {'unit': true},
      articleId: null,
      seriesId: 7,
      pageIndex: 0,
      referenceImagePaths: [referenceFile.path],
    );

    expect(first.source, VolcImageResultSource.remote);
    expect(first.filePath, isNotNull);
    expect(await File(first.filePath!).exists(), isTrue);
    expect(seenBody?['sequential_image_generation'], 'disabled');
    expect(seenBody?['model'], 'doubao-seedream-5-0-260128');
    expect(seenBody?['size'], '2560x1440');
    expect(seenBody?['output_format'], 'png');
    expect(seenBody?['image'], isA<List>());
    expect((seenBody?['image'] as List).single, startsWith('data:image/png;'));
    expect(calls, 1);

    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        fail('cached picture-book image should not call Ark again');
      },
    );
    final cached = await VolcImageService.generatePictureBookImage(
      prompt: 'A warm picture-book scene with a small wooden sign.',
      promptMetadata: const {'unit': true},
      articleId: null,
      seriesId: 7,
      pageIndex: 0,
      referenceImagePaths: [referenceFile.path],
    );

    expect(cached.source, VolcImageResultSource.cached);
    expect(cached.filePath, first.filePath);
  });

  test('Ark group generation requests sequential picture-book images',
      () async {
    _writeImageArkKey(tempDir, 'ark-group-key-12345678901234567890');
    final referenceFile = File(
      '${tempDir.path}${Platform.pathSeparator}series-reference.png',
    )..writeAsBytesSync([137, 80, 78, 71, 8, 8, 8]);
    Map<String, dynamic>? seenBody;
    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        seenBody = body;
        return {
          'data': [
            {
              'b64_json': base64Encode([137, 80, 78, 71, 1])
            },
            {
              'b64_json': base64Encode([137, 80, 78, 71, 2])
            },
          ],
        };
      },
    );

    final results = await VolcImageService.generatePictureBookImageGroup(
      requests: const [
        VolcImageBatchRequest(
          pageIndex: 0,
          prompt: 'Image one: Alice at a tea table.',
          promptMetadata: {'page': 0},
        ),
        VolcImageBatchRequest(
          pageIndex: 1,
          prompt: 'Image two: Alice listens in the same garden.',
          promptMetadata: {'page': 1},
        ),
      ],
      seriesId: 9,
      referenceImagePaths: [referenceFile.path],
      useSequential: true,
    );

    expect(results, hasLength(2));
    expect(
        results
            .every((result) => result.source == VolcImageResultSource.remote),
        isTrue);
    expect(results.map((result) => result.pageIndex), [0, 1]);
    expect(seenBody?['sequential_image_generation'], 'auto');
    expect(seenBody?['model'], 'doubao-seedream-5-0-260128');
    expect(seenBody?['size'], '2560x1440');
    expect(seenBody?['output_format'], 'png');
    expect(
      seenBody?['sequential_image_generation_options'],
      containsPair('max_images', 2),
    );
    expect(seenBody?['image'], isA<List>());
    expect((seenBody?['prompt'] as String), contains('Image 1:'));
    expect((seenBody?['prompt'] as String), contains('Image 2:'));
    expect((seenBody?['prompt'] as String), contains('Image one:'));
  });

  test('Aliyun Wanx group generation uses async sequential API', () async {
    AppConfig.setRuntimeConfigForTest(
      aiProvider: AppConfig.aiProviderAliyunBailian,
      aliyunBailianApiKey: 'dashscope-group-key-1234567890',
      aliyunBailianApiBaseUrl: 'https://dashscope.example.com/api/v1/',
      aliyunBailianImageModel: 'wan2.7-test',
      aliyunBailianImageSize: '2K',
    );
    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        fail('Aliyun picture-book group generation must not call Volc Ark');
      },
    );
    Map<String, dynamic>? seenBody;
    AliyunWanxImageService.setOverridesForTest(
      post: ({required endpoint, required headers, required body}) async {
        seenBody = body;
        expect(
          endpoint,
          'https://dashscope.example.com/api/v1/services/aigc/image-generation/generation',
        );
        expect(headers['Authorization'], startsWith('Bearer dashscope-group'));
        expect(headers['X-DashScope-Async'], 'enable');
        return {
          'output': {'task_id': 'task-picture-group-1'},
        };
      },
      get: ({required endpoint, required headers}) async {
        expect(
          endpoint,
          'https://dashscope.example.com/api/v1/tasks/task-picture-group-1',
        );
        return {
          'output': {
            'task_status': 'SUCCEEDED',
            'results': [
              {
                'image': 'data:image/png;base64,${base64Encode([
                      137,
                      80,
                      78,
                      71,
                      31
                    ])}',
              },
            ],
          },
        };
      },
    );

    final results = await PictureBookImageService.generatePictureBookImageGroup(
      requests: const [
        VolcImageBatchRequest(
          pageIndex: 0,
          prompt: 'Image one: Alice sees a garden gate.',
          promptMetadata: {'page': 0},
        ),
        VolcImageBatchRequest(
          pageIndex: 1,
          prompt: 'Image two: Alice enters the same garden.',
          promptMetadata: {'page': 1},
        ),
      ],
      seriesId: 21,
      groupPromptOverride: 'Two continuous Alice garden scenes.',
      reusePartialCache: false,
    );

    expect(results, hasLength(2));
    expect(results[0].source, VolcImageResultSource.remote);
    expect(await File(results[0].filePath!).exists(), isTrue);
    expect(results[1].source, VolcImageResultSource.failed);
    expect(results[1].errorMessage, contains('未返回第 2 张图片'));
    expect(seenBody?['model'], 'wan2.7-test');
    expect(seenBody?['parameters'], containsPair('enable_sequential', true));
    expect(seenBody?['parameters'], containsPair('n', 2));
    expect(seenBody?['parameters'], containsPair('size', '2688*1536'));
  });

  test(
      'Aliyun Wanx single image generation uses reference without sequential mode',
      () async {
    AppConfig.setRuntimeConfigForTest(
      aiProvider: AppConfig.aiProviderAliyunBailian,
      aliyunBailianApiKey: 'dashscope-single-key-1234567890',
      aliyunBailianApiBaseUrl: 'https://dashscope.example.com/api/v1/',
      aliyunBailianImageModel: 'wan2.7-test',
      aliyunBailianImageSize: '2K',
    );
    final referenceFile = File(
      '${tempDir.path}${Platform.pathSeparator}wanx-reference.png',
    )..writeAsBytesSync([137, 80, 78, 71, 7, 7, 7]);
    Map<String, dynamic>? seenBody;
    AliyunWanxImageService.setOverridesForTest(
      post: ({required endpoint, required headers, required body}) async {
        seenBody = body;
        return {
          'output': {'task_id': 'task-picture-single-1'},
        };
      },
      get: ({required endpoint, required headers}) async {
        return {
          'output': {
            'task_status': 'SUCCEEDED',
            'results': [
              {
                'image': 'data:image/png;base64,${base64Encode([
                      137,
                      80,
                      78,
                      71,
                      41
                    ])}',
              },
            ],
          },
        };
      },
    );

    final results = await PictureBookImageService.generatePictureBookImageGroup(
      requests: const [
        VolcImageBatchRequest(
          pageIndex: 1,
          prompt: 'Image two: Alice looks back at the same garden.',
          promptMetadata: {'page': 1},
        ),
      ],
      seriesId: 21,
      referenceImagePaths: [referenceFile.path],
      groupPromptOverride: 'Single replacement Alice garden scene.',
      useSequential: false,
      reusePartialCache: false,
    );

    expect(results, hasLength(1));
    expect(results.single.source, VolcImageResultSource.remote);
    expect(seenBody?['parameters'], containsPair('enable_sequential', false));
    expect(seenBody?['parameters'], containsPair('n', 1));
    final messages = ((seenBody?['input'] as Map)['messages'] as List);
    final content = (messages.single as Map)['content'] as List;
    expect((content.first as Map)['image'], startsWith('data:image/png;'));
    expect((content.last as Map)['text'],
        'Single replacement Alice garden scene.');
  });

  test('Aliyun Wanx settings sizes map to landscape API sizes', () {
    expect(AliyunWanxImageService.apiImageSizeForSetting('2K'), '2688*1536');
    expect(AliyunWanxImageService.apiImageSizeForSetting('1K'), '1696*960');
    expect(
      AliyunWanxImageService.apiImageSizeForSetting('2048x1152'),
      '2048*1152',
    );
  });

  test('Aliyun Wanx green net task failure records content safety failure',
      () async {
    AppConfig.setRuntimeConfigForTest(
      aiProvider: AppConfig.aiProviderAliyunBailian,
      aliyunBailianApiKey: 'dashscope-green-net-key-1234567890',
      aliyunBailianApiBaseUrl: 'https://dashscope.example.com/api/v1/',
      aliyunBailianImageModel: 'wan2.7-test',
      aliyunBailianImageSize: '2K',
    );
    AliyunWanxImageService.setOverridesForTest(
      post: ({required endpoint, required headers, required body}) async {
        return {
          'output': {'task_id': 'task-picture-green-net'},
        };
      },
      get: ({required endpoint, required headers}) async {
        return {
          'output': {
            'task_status': 'FAILED',
            'message': 'Green net check failed for output image',
          },
        };
      },
    );

    final results = await PictureBookImageService.generatePictureBookImageGroup(
      requests: const [
        VolcImageBatchRequest(
          pageIndex: 0,
          prompt: 'Image one: Alice follows the White Rabbit.',
          promptMetadata: {'page': 0},
        ),
      ],
      articleId: 33,
      seriesId: 21,
      groupPromptOverride: 'One continuous Alice picture-book scene.',
      reusePartialCache: false,
    );

    expect(results, hasLength(1));
    expect(results.single.source, VolcImageResultSource.failed);
    expect(
      results.single.errorMessage,
      contains('Green net check failed for output image'),
    );
    final db = await DatabaseService.database;
    final failures = await db.query('content_safety_failures');
    final rules = await db.query('content_safety_rules');
    expect(failures, hasLength(1));
    expect(
      failures.single['service_kind'],
      ContentSafetyService.servicePictureBookImage,
    );
    expect(failures.single['purpose'], 'picture_book_image');
    expect(failures.single['article_id'], 33);
    expect(failures.single['error_code'], 'green_net');
    expect(
      failures.single['error_message'],
      contains('Green net check failed for output image'),
    );
    expect(
      failures.single['failed_text'],
      'One continuous Alice picture-book scene.',
    );
    expect(rules, isEmpty);
  });

  test('Ark group generation does not rerun cached pages on retry', () async {
    _writeImageArkKey(tempDir, 'ark-partial-key-12345678901234567890');
    final postedBodies = <Map<String, dynamic>>[];
    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        postedBodies.add(Map<String, dynamic>.from(body));
        if (postedBodies.length == 1) {
          return {
            'data': [
              {
                'b64_json': base64Encode([137, 80, 78, 71, 21])
              },
            ],
          };
        }
        return {
          'data': [
            {
              'b64_json': base64Encode([137, 80, 78, 71, 22])
            },
          ],
        };
      },
    );
    const requests = [
      VolcImageBatchRequest(
        pageIndex: 0,
        prompt: 'Page one picture-book image.',
        promptMetadata: {'page': 0},
      ),
      VolcImageBatchRequest(
        pageIndex: 1,
        prompt: 'Page two picture-book image.',
        promptMetadata: {'page': 1},
      ),
    ];

    final first = await VolcImageService.generatePictureBookImageGroup(
      requests: requests,
      seriesId: 12,
      useSequential: true,
    );
    expect(first.map((result) => result.source), [
      VolcImageResultSource.remote,
      VolcImageResultSource.failed,
    ]);

    final second = await VolcImageService.generatePictureBookImageGroup(
      requests: requests,
      seriesId: 12,
      useSequential: true,
    );
    expect(second.map((result) => result.source), [
      VolcImageResultSource.cached,
      VolcImageResultSource.remote,
    ]);
    expect(postedBodies, hasLength(2));
    expect(postedBodies.first['sequential_image_generation'], 'auto');
    expect(postedBodies.last['sequential_image_generation'], 'disabled');
    expect(postedBodies.last['prompt'], 'Page two picture-book image.');
  });

  test('Ark group generation can force a full sequential retry', () async {
    _writeImageArkKey(tempDir, 'ark-full-retry-key-12345678901234567890');
    final postedBodies = <Map<String, dynamic>>[];
    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        postedBodies.add(Map<String, dynamic>.from(body));
        if (postedBodies.length == 1) {
          return {
            'data': [
              {
                'b64_json': base64Encode([137, 80, 78, 71, 31])
              },
            ],
          };
        }
        return {
          'data': [
            {
              'b64_json': base64Encode([137, 80, 78, 71, 32])
            },
            {
              'b64_json': base64Encode([137, 80, 78, 71, 33])
            },
          ],
        };
      },
    );
    const requests = [
      VolcImageBatchRequest(
        pageIndex: 0,
        prompt: 'Page one picture-book image.',
        promptMetadata: {'page': 0},
      ),
      VolcImageBatchRequest(
        pageIndex: 1,
        prompt: 'Page two picture-book image.',
        promptMetadata: {'page': 1},
      ),
    ];

    final first = await VolcImageService.generatePictureBookImageGroup(
      requests: requests,
      seriesId: 13,
      useSequential: true,
    );
    expect(first.map((result) => result.source), [
      VolcImageResultSource.remote,
      VolcImageResultSource.failed,
    ]);

    final second = await VolcImageService.generatePictureBookImageGroup(
      requests: requests,
      seriesId: 13,
      useSequential: true,
      reusePartialCache: false,
    );

    expect(second.map((result) => result.source), [
      VolcImageResultSource.remote,
      VolcImageResultSource.remote,
    ]);
    expect(postedBodies, hasLength(2));
    expect(postedBodies.last['sequential_image_generation'], 'auto');
    expect(
      postedBodies.last['sequential_image_generation_options'],
      containsPair('max_images', 2),
    );
  });

  test('Ark group cache-only lookup does not post a new image request',
      () async {
    _writeImageArkKey(tempDir, 'ark-cache-only-key-12345678901234567890');
    var postCount = 0;
    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        postCount += 1;
        return {
          'data': [
            {
              'b64_json': base64Encode([137, 80, 78, 71, 41])
            },
            {
              'b64_json': base64Encode([137, 80, 78, 71, 42])
            },
          ],
        };
      },
    );
    const requests = [
      VolcImageBatchRequest(
        pageIndex: 0,
        prompt: 'Page one picture-book image.',
        promptMetadata: {'page': 0},
      ),
      VolcImageBatchRequest(
        pageIndex: 1,
        prompt: 'Page two picture-book image.',
        promptMetadata: {'page': 1},
      ),
    ];

    final generated = await VolcImageService.generatePictureBookImageGroup(
      requests: requests,
      seriesId: 14,
      useSequential: true,
    );
    expect(generated.map((result) => result.source), [
      VolcImageResultSource.remote,
      VolcImageResultSource.remote,
    ]);

    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        postCount += 1;
        throw StateError('cache-only lookup must not post');
      },
    );
    final cached = await VolcImageService.generatePictureBookImageGroup(
      requests: requests,
      seriesId: 14,
      useSequential: true,
      cacheOnly: true,
    );

    expect(cached.map((result) => result.source), [
      VolcImageResultSource.cached,
      VolcImageResultSource.cached,
    ]);
    expect(postCount, 1);
  });

  test('picture-book state recovers ready group pages from cache', () async {
    _writeImageArkKey(tempDir, 'ark-state-recover-key-12345678901234567890');
    var postCount = 0;
    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        postCount += 1;
        return {
          'data': [
            {
              'b64_json': base64Encode([137, 80, 78, 71, 51])
            },
            {
              'b64_json': base64Encode([137, 80, 78, 71, 52])
            },
          ],
        };
      },
    );

    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Cache Recovery',
        content:
            'Alice watches the first scene. Alice walks to the second scene.',
        sentences: const [
          'Alice watches the first scene.',
          'Alice walks to the second scene.',
        ],
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(title: 'Cache Story');
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    final now = DateTime(2026, 1, 1);
    final promptJsons = [
      {
        'prompt':
            'Alice watches the first scene in a continuous picture-book style.',
        'pageIndex': 0,
        'pageCount': 2,
        'promptPolicyVersion': 4,
      },
      {
        'prompt':
            'Alice walks to the second scene in the same picture-book style.',
        'pageIndex': 1,
        'pageCount': 2,
        'promptPolicyVersion': 4,
      },
    ];
    final requests = [
      for (var index = 0; index < promptJsons.length; index += 1)
        VolcImageBatchRequest(
          pageIndex: index,
          prompt: PictureBookService.imagePromptForTest(promptJsons[index]),
          promptMetadata: promptJsons[index],
        ),
    ];

    await VolcImageService.generatePictureBookImageGroup(
      requests: requests,
      articleId: articleId,
      seriesId: series.id,
      useSequential: true,
    );
    for (var index = 0; index < promptJsons.length; index += 1) {
      await DatabaseService.upsertPictureBookPage(
        PictureBookPage(
          articleId: articleId,
          seriesId: series.id,
          pageIndex: index,
          sentenceStartIndex: index,
          sentenceEndIndex: index,
          paragraphText: article.sentences[index],
          promptJson: ApiCacheService.canonicalJson(promptJsons[index]),
          status: 'generating',
          createdAt: now,
          updatedAt: now,
        ),
      );
    }

    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        postCount += 1;
        throw StateError('state recovery must only read cached images');
      },
    );
    final state = await PictureBookService.statePayload(articleId);

    expect(chapter.articleId, articleId);
    expect(postCount, 1);
    expect(state['status'], 'ready');
    final pages = state['pages'] as List;
    expect(pages.map((page) => page['status']), ['ready', 'ready']);
    expect(
      pages.every((page) => (page['imagePath'] as String).isNotEmpty),
      isTrue,
    );
  });

  test(
      'picture-book generation creates storyboard group images without references by default',
      () async {
    _writeImageArkKey(tempDir, 'ark-role-key-12345678901234567890');
    final postedBodies = <Map<String, dynamic>>[];
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'planKind': 'picture_book_chapter_scene_plan_v2',
                  'chapterDescription':
                      'Alice joins a whimsical outdoor tea-party world and watches the March Hare, Hatter, and Dormouse around the same tea table.',
                  'scenes': [
                    {
                      'pageIndex': 0,
                      'sentenceStartIndex': 0,
                      'sentenceEndIndex': 2,
                      'sceneDescription': 'Alice sits near the tea table.',
                    },
                    {
                      'pageIndex': 1,
                      'sentenceStartIndex': 3,
                      'sentenceEndIndex': 5,
                      'sceneDescription':
                          'The Hatter lifts a cup while the Dormouse sleeps.',
                    },
                  ],
                }),
              },
            }
          ],
        };
      },
    );
    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        postedBodies.add(Map<String, dynamic>.from(body));
        final sequential = body['sequential_image_generation'] == 'auto';
        return {
          'data': [
            {
              'b64_json': base64Encode([137, 80, 78, 71, 10])
            },
            if (sequential)
              {
                'b64_json': base64Encode([137, 80, 78, 71, 11])
              },
          ],
        };
      },
    );
    final now = DateTime(2026, 1, 1);
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Alice Tea Test',
        content:
            'Alice sat near the March Hare. The Hatter poured tea for the Dormouse. '
            'Alice looked at the tea table. The March Hare laughed softly. '
            'The Hatter lifted a cup. The Dormouse slept beside them.',
        sentences: const [
          'Alice sat near the March Hare.',
          'The Hatter poured tea for the Dormouse.',
          'Alice looked at the tea table.',
          'The March Hare laughed softly.',
          'The Hatter lifted a cup.',
          'The Dormouse slept beside them.',
        ],
        createdAt: now,
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: 'Alice\'s Adventures in Wonderland',
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );

    await PictureBookService.generateForArticle(
      article: article,
      chapter: chapter,
    );

    final groupBodies = postedBodies
        .where((body) => body['sequential_image_generation'] == 'auto')
        .toList(growable: false);
    expect(groupBodies, hasLength(1));
    expect(postedBodies, hasLength(1));
    expect(postedBodies.single['sequential_image_generation'], 'auto');
    expect(
      postedBodies.single['sequential_image_generation_options'],
      containsPair('max_images', 2),
    );
    expect(postedBodies.single['image'], isNull);
    expect(
      postedBodies.single['prompt'] as String,
      contains('Image 1:'),
    );
    expect(postedBodies.single['prompt'] as String, contains('Image 2:'));
    final state = await PictureBookService.statePayload(articleId);
    expect(state['status'], 'ready');
    final pages = state['pages'] as List;
    expect(pages, hasLength(2));
    expect(pages.first['sentenceStartIndex'], 0);
    expect(pages.first['sentenceEndIndex'], 2);
    expect(pages.last['sentenceStartIndex'], 3);
    expect(pages.last['sentenceEndIndex'], 5);
  });

  test('picture-book image prompt allows natural in-world text', () {
    final prompt = PictureBookService.imagePromptForTest({
      'scene': {
        'sceneDescription':
            'A girl smiles over a glowing map in a warm bedroom picture-book scene, enough open clean space at the bottom edge for app-rendered subtitles.',
      },
    });
    final lower = prompt.toLowerCase();

    expect(prompt, contains('glowing map'));
    expect(lower, isNot(contains('subtitle')));
    expect(lower, isNot(contains('caption')));
    expect(lower, isNot(contains('open clean space')));
    expect(lower, isNot(contains('bottom edge')));
    expect(lower, isNot(contains('app-rendered')));
    expect(lower, isNot(contains('ui overlay')));
    expect(lower, isNot(contains('text-free')));
    expect(lower, isNot(contains('no visible text')));
  });

  test('Ark group prompt removes old subtitle-space wording', () {
    final prompt = VolcImageService.groupPromptForTest(
      const [
        VolcImageBatchRequest(
          pageIndex: 0,
          prompt:
              'Alice stands on the croquet lawn, open clean space for subtitles, gentle colors.',
          promptMetadata: {'page': 0},
        ),
        VolcImageBatchRequest(
          pageIndex: 1,
          prompt:
              'The King hurries away with enough open clean space at the bottom edge for text.',
          promptMetadata: {'page': 1},
        ),
      ],
    );
    final lower = prompt.toLowerCase();

    expect(prompt, contains('natural scene composition'));
    expect(lower, isNot(contains('subtitle')));
    expect(lower, isNot(contains('app-rendered')));
    expect(lower, isNot(contains('open clean space')));
    expect(lower, isNot(contains('bottom edge')));
  });

  test('picture-book image prompt uses any series title without Alice lock-in',
      () {
    final prompt = PictureBookService.imagePromptForTest({
      'scene': {
        'sceneDescription': 'A boy opens a gate into a quiet moonlit garden.',
      },
    });

    expect(prompt, contains('moonlit garden'));
    expect(prompt, isNot(contains('Alice is always')));
    expect(prompt, isNot(contains('Wonderland')));
  });

  test('picture-book image prompt softens unsafe classic story threats', () {
    final prompt = PictureBookService.imagePromptForTest({
      'scene': {
        'sceneDescription':
            'Alice hears that the Duchess is under sentence of execution. The Queen shouts "Off with her head!" while players are fighting for hedgehogs.',
      },
    });
    final lower = prompt.toLowerCase();

    expect(lower, isNot(contains('execution')));
    expect(lower, isNot(contains('off with her head')));
    expect(lower, isNot(contains('fighting')));
    expect(prompt, contains('serious trouble with the Queen'));
    expect(prompt, contains('exaggerated angry command'));
    expect(prompt, contains('scrambling'));
  });

  test('picture-book segmentation creates storyboard image segments', () {
    final sentences = [
      'There was a table set out under a tree in front of the house,',
      'and the March Hare and the Hatter were having tea at it:',
      'a Dormouse was sitting between them, fast asleep,',
      'and the other two were using it as a cushion,',
      'resting their elbows on it,',
      'and talking over its head.',
      '"Very uncomfortable for the Dormouse," thought Alice:',
      '"only as it\'s asleep, I suppose it doesn\'t mind."',
      'The table was a large one,',
      'but the three were all crowded together at one corner of it.',
      '"No room! No room!" they cried out when they saw Alice coming.',
    ];
    final article = Article(
      id: 42,
      title: 'Alice Test',
      content: '''
Chapter Seven
A Mad Tea-Party

There was a table set out under a tree in front of the house,
and the March Hare and the Hatter were having tea at it:
a Dormouse was sitting between them, fast asleep,
and the other two were using it as a cushion, resting their elbows on it,
and talking over its head.
"Very uncomfortable for the Dormouse," thought Alice:
"only as it's asleep, I suppose it doesn't mind."

The table was a large one,
but the three were all crowded together at one corner of it.
"No room! No room!" they cried out when they saw Alice coming.
''',
      sentences: sentences,
      createdAt: DateTime(2026, 1, 1),
    );

    final segments = PictureBookService.pictureSegmentsForTest(article);

    expect(segments, hasLength(greaterThan(1)));
    expect(segments.first['text'], isNot(contains('Chapter Seven')));
    expect(segments.first['sentenceStartIndex'], 0);
    expect(segments.first['text'], contains('There was a table'));
    expect(segments.last['sentenceEndIndex'], 10);
    expect(segments.last['text'], contains('"No room! No room!"'));
  });

  test('picture-book chapter segment keeps full long chapter text', () {
    final paragraphs = List.generate(
      70,
      (index) =>
          'Chapter paragraph $index carries full_story_marker_$index through the picture-book prompt.',
    );
    final article = Article(
      id: 43,
      title: 'Long Picture Chapter',
      content: paragraphs.join('\n\n'),
      sentences: paragraphs,
      createdAt: DateTime(2026, 1, 1),
    );

    final segments = PictureBookService.pictureSegmentsForTest(article);
    expect(segments, hasLength(12));

    final firstText = segments.first['text'] as String;
    final lastText = segments.last['text'] as String;
    expect(firstText, contains('full_story_marker_0'));
    expect(lastText, contains('full_story_marker_69'));
    expect(firstText, isNot(contains('[middle of chapter]')));
    expect(lastText, isNot(contains('[end of chapter]')));
  });

  test('picture-book prompt review keeps raw slots for hidden sentences',
      () async {
    _writeImageArkKey(tempDir, 'ark-hidden-slot-key-12345678901234567890');
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Hidden Slot Chapter',
        content: [
          'Alice notices the little house.',
          'The Duchess rocks the baby.',
          'Smoke fills the kitchen.',
          'The cook throws plates.',
          'Alice catches the baby.',
        ].join(' '),
        sentences: const [
          'Alice notices the little house.',
          '',
          'The Duchess rocks the baby.',
          'Smoke fills the kitchen.',
          'The cook throws plates.',
          '',
          'Alice catches the baby.',
        ],
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
      description: 'A surreal Victorian picture-book world.',
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );

    String submittedBody = '';
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        submittedBody = jsonEncode(body);
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'planKind': 'picture_book_chapter_scene_plan_v2',
                  'chapterDescription':
                      'Alice enters the Duchess kitchen and catches the baby.',
                  'scenes': [
                    {
                      'pageIndex': 0,
                      'sentenceStartIndex': 0,
                      'sentenceEndIndex': 1,
                      'sceneDescription':
                          'Alice stands outside the little house.',
                    },
                    {
                      'pageIndex': 1,
                      'sentenceStartIndex': 2,
                      'sentenceEndIndex': 6,
                      'sceneDescription':
                          'The Duchess kitchen turns chaotic as Alice catches the baby.',
                    },
                  ],
                }),
              },
            }
          ],
        };
      },
    );

    final initialReview = await PictureBookService.promptReviewPayload(
      article: article,
      chapter: chapter,
    );
    final refreshed = await _refreshChapterPlanFromReview(initialReview);
    expect(submittedBody, contains('0. Alice notices the little house.'));
    expect(submittedBody, contains('1. [hidden sentence slot]'));
    expect(submittedBody, contains('2. The Duchess rocks the baby.'));
    expect(submittedBody, contains('5. [hidden sentence slot]'));
    expect(submittedBody, contains('6. Alice catches the baby.'));

    final refreshedScenes = refreshed['scenes'] as List;
    expect((refreshedScenes.first as Map)['sentenceEndIndex'], 1);
    expect((refreshedScenes.last as Map)['sentenceStartIndex'], 2);
    expect((refreshedScenes.last as Map)['sentenceEndIndex'], 6);
    expect(
      (refreshedScenes.last as Map)['paragraphText'],
      contains('Alice catches the baby.'),
    );

    await PictureBookService.savePromptReview(
      reviewId: refreshed['reviewId'].toString(),
      groupPrompt: refreshed['groupPrompt'].toString(),
      bookDescription: refreshed['bookDescription'].toString(),
      bookCharacters: _charactersFromPayload(refreshed['bookCharacters']),
      newCharacters: _charactersFromPayload(refreshed['newCharacters']),
      chapterDescription: refreshed['chapterDescription'].toString(),
      scenes: [
        for (final scene in refreshedScenes)
          Map<String, dynamic>.from(scene as Map),
      ],
    );

    final savedChapter =
        await DatabaseService.getStoryChapterForArticle(articleId);
    final savedSummary =
        jsonDecode(savedChapter?.summaryJson ?? '{}') as Map<String, dynamic>;
    final savedScenes = savedSummary['scenes'] as List;
    expect((savedScenes.last as Map)['sentenceEndIndex'], 6);
  });

  test('picture-book prompt review does not call image API or delete old pages',
      () async {
    _writeImageArkKey(tempDir, 'ark-review-key-12345678901234567890');
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Review Test',
        content:
            'Alice walks into the garden. The Queen points at the croquet ground.',
        sentences: const [
          'Alice walks into the garden.',
          'The Queen points at the croquet ground.',
        ],
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    var textAiCalls = 0;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        textAiCalls += 1;
        throw StateError('opening prompt review should not call text AI');
      },
    );
    var imageCalls = 0;
    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        imageCalls += 1;
        return {'data': const []};
      },
    );
    final now = DateTime(2026, 1, 1);
    await DatabaseService.upsertPictureBookPage(
      PictureBookPage(
        articleId: articleId,
        seriesId: series.id,
        pageIndex: 0,
        sentenceStartIndex: 0,
        sentenceEndIndex: 0,
        paragraphText: 'Old page',
        promptJson: '{}',
        imagePath: 'old.png',
        status: 'ready',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final review = await PictureBookService.promptReviewPayload(
      article: article,
      chapter: chapter,
      regenerate: true,
    );

    expect(review['reviewId']?.toString(), startsWith('pb_$articleId'));
    final groupPrompt = review['groupPrompt']?.toString() ?? '';
    expect(
      groupPrompt,
      contains("Book name: Alice's Adventures in Wonderland"),
    );
    expect(groupPrompt, contains('Image 1:'));
    expect(review['bookDescription'], isA<String>());
    expect(review['chapterDescription'], '');
    final scenes = review['scenes'] as List;
    expect(scenes, hasLength(2));
    expect((scenes.first as Map)['sceneDescription'], '');
    expect((scenes.last as Map)['sceneDescription'], '');
    expect(review.containsKey('characterCards'), isFalse);
    expect(review.containsKey('referenceAssets'), isFalse);
    expect(review.containsKey('styleGuide'), isFalse);
    expect(textAiCalls, 0);
    expect(imageCalls, 0);
    final pages = await DatabaseService.getPictureBookPages(articleId);
    expect(pages, hasLength(1));
    expect(pages.single.paragraphText, 'Old page');
  });

  test(
      'picture-book prompt review recovers local page prompts when chapter plan summary is missing',
      () async {
    _writeImageArkKey(tempDir, 'ark-page-recovery-key-12345678901234567890');
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Recovered Prompt Chapter',
        content:
            'Alice finds a tiny door. Alice follows a golden key into a bright hall.',
        sentences: const [
          'Alice finds a tiny door.',
          'Alice follows a golden key into a bright hall.',
        ],
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
      description:
          'Victorian fantasy picture book; Alice wears a blue dress and white apron.',
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    final now = DateTime(2026, 1, 1);
    final pagePrompts = [
      {
        'planKind': 'picture_book_chapter_scene_plan_v2',
        'chapterDescription':
            'Alice explores a magical hallway and notices clues that lead her onward.',
        'scene': {
          'pageIndex': 0,
          'sentenceStartIndex': 0,
          'sentenceEndIndex': 0,
          'sceneDescription':
              'Alice kneels near a tiny door glowing in the hallway.',
        },
        'groupPrompt': 'Recovered local group prompt.',
        'newCharacters': [
          {
            'name': 'Golden Key',
            'description': 'A small bright golden key with a delicate bow.',
          },
        ],
      },
      {
        'planKind': 'picture_book_chapter_scene_plan_v2',
        'chapterDescription':
            'Alice explores a magical hallway and notices clues that lead her onward.',
        'scene': {
          'pageIndex': 1,
          'sentenceStartIndex': 1,
          'sentenceEndIndex': 1,
          'sceneDescription':
              'Alice follows the golden key through a bright hall.',
        },
        'groupPrompt': 'Recovered local group prompt.',
      },
    ];
    for (var index = 0; index < pagePrompts.length; index += 1) {
      await DatabaseService.upsertPictureBookPage(
        PictureBookPage(
          articleId: articleId,
          seriesId: series.id,
          pageIndex: index,
          sentenceStartIndex: index,
          sentenceEndIndex: index,
          paragraphText: article.sentences[index],
          promptJson: ApiCacheService.canonicalJson(pagePrompts[index]),
          status: 'ready',
          createdAt: now,
          updatedAt: now,
        ),
      );
    }

    var textAiCalls = 0;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        textAiCalls += 1;
        throw StateError('prompt review should recover from local pages');
      },
    );

    final review = await PictureBookService.promptReviewPayload(
      article: article,
      chapter: chapter,
      regenerate: true,
    );

    expect(textAiCalls, 0);
    expect(review['chapterDescription'], contains('magical hallway'));
    final scenes = review['scenes'] as List;
    expect(scenes, hasLength(2));
    expect(
      (scenes[0] as Map)['sceneDescription'],
      contains('tiny door'),
    );
    expect(
      (scenes[1] as Map)['sceneDescription'],
      contains('golden key'),
    );
    final savedChapter =
        await DatabaseService.getStoryChapterForArticle(articleId);
    final savedSummary =
        jsonDecode(savedChapter!.summaryJson) as Map<String, dynamic>;
    expect(savedSummary['planKind'], 'picture_book_chapter_scene_plan_v2');
    expect(savedSummary['chapterDescription'], contains('magical hallway'));
    expect(savedSummary['scenes'], hasLength(2));
  });

  test('picture-book prompt review opens an empty editable draft without AI',
      () async {
    _writeImageArkKey(tempDir, 'ark-local-draft-key-12345678901234567890');
    final sentences = [
      for (var index = 0; index < 16; index += 1)
        'Alice sees clue ${index + 1} in the long hallway.',
    ];
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Local Draft Chapter',
        content: sentences.join(' '),
        sentences: sentences,
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
      description:
          'Victorian fantasy picture book; Alice wears a blue dress and white apron.',
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    final initialSummary =
        jsonDecode(chapter.summaryJson) as Map<String, dynamic>;
    expect(initialSummary.containsKey('summary'), isFalse);
    expect(chapter.summaryJson, isNot(contains('"You promised')));
    expect(chapter.summaryJson, isNot(contains('attend vs. pay attention')));

    var textAiCalls = 0;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        textAiCalls += 1;
        throw StateError('opening prompt review should not call text AI');
      },
    );

    final review = await PictureBookService.promptReviewPayload(
      article: article,
      chapter: chapter,
      regenerate: true,
    );

    expect(textAiCalls, 0);
    expect(review['chapterDescription'], '');
    final scenes = review['scenes'] as List;
    expect(scenes, hasLength(12));
    expect((scenes.first as Map)['sceneDescription'], '');
    expect((scenes.last as Map)['sceneDescription'], '');
    expect((scenes.first as Map)['paragraphText'], contains('clue 1'));
    expect((scenes.last as Map)['paragraphText'], contains('clue 16'));
    expect(await DatabaseService.getPictureBookPages(articleId), isEmpty);

    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        textAiCalls += 1;
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'planKind': 'picture_book_chapter_scene_plan_v2',
                  'chapterDescription':
                      'Alice follows a trail of hallway clues from the first discovery to the final clue.',
                  'scenes': [
                    {
                      'pageIndex': 0,
                      'sentenceStartIndex': 0,
                      'sentenceEndIndex': 7,
                      'sceneDescription':
                          'Alice studies the first hallway clues with growing curiosity.',
                    },
                    {
                      'pageIndex': 1,
                      'sentenceStartIndex': 8,
                      'sentenceEndIndex': 15,
                      'sceneDescription':
                          'Alice reaches the final hallway clues and prepares to move on.',
                    },
                  ],
                }),
              },
            }
          ],
        };
      },
    );

    final refreshed = await _refreshChapterPlanFromReview(review);
    expect(textAiCalls, 1);
    expect(
      refreshed['chapterDescription'],
      'Alice follows a trail of hallway clues from the first discovery to the final clue.',
    );
    final refreshedScenes = refreshed['scenes'] as List;
    expect(refreshedScenes, hasLength(2));
    expect(
      (refreshedScenes.first as Map)['sceneDescription'],
      contains('first hallway clues'),
    );
    expect(
      (refreshedScenes.last as Map)['sceneDescription'],
      contains('final hallway clues'),
    );
  });

  test('picture-book chapter plan uses original prose while excluding dialogue',
      () async {
    _writeImageArkKey(tempDir, 'ark-dialogue-plan-key-12345678901234567890');
    final raw = File(
      path_lib.join(
        previousDirectory.path,
        'test',
        'fixtures',
        'e20_duchess_raw_input.txt',
      ),
    ).readAsStringSync();
    final parsed = PracticeInputParser.parse(raw);
    final sentences = NlpService.splitSentences(parsed.englishContent);
    final storyText = sentences.join(' ');

    expect(parsed.sourceKind, PracticeInputSourceKind.english);
    expect(storyText, contains('Please would you tell me'));
    expect(storyText, contains("It's a Cheshire cat"));
    expect(storyText, contains("don't bother me"));
    expect(storyText, contains('Here! you may nurse it a bit'));

    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'E20 Duchess Dialogue Test',
        content: parsed.englishContent,
        sentences: sentences,
        createdAt: DateTime(2026, 7, 6),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
      description:
          'Victorian fantasy picture book; Alice wears a blue dress and white apron.',
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    final review = await PictureBookService.promptReviewPayload(
      article: article,
      chapter: chapter,
      regenerate: true,
    );

    Map<String, dynamic>? textBody;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        textBody = body;
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'planKind': 'picture_book_chapter_scene_plan_v2',
                  'chapterDescription':
                      'Alice moves through the smoky pepper-filled kitchen as flying cookware, the restless Duchess, the cook, and the strange baby create a tense comic scene that ends with Alice struggling to hold the starfish-shaped child.',
                  'scenes': [
                    {
                      'pageIndex': 0,
                      'sentenceStartIndex': 0,
                      'sentenceEndIndex': sentences.length ~/ 2,
                      'sceneDescription':
                          'Alice stands in the smoky kitchen near the Duchess, the cook, and the grinning cat while pepper hangs in the air and cookware flies across the room.',
                    },
                    {
                      'pageIndex': 1,
                      'sentenceStartIndex': sentences.length ~/ 2 + 1,
                      'sentenceEndIndex': sentences.length - 1,
                      'sceneDescription':
                          'The Duchess flings the baby toward Alice before hurrying away, and Alice catches the queer starfish-shaped child as it snorts and wriggles in her arms.',
                    },
                  ],
                }),
              },
            }
          ],
        };
      },
    );

    final refreshed = await _refreshChapterPlanFromReview(review);
    final textMessages = (textBody?['messages'] as List?) ?? const [];
    final planningPrompt = textMessages
        .map((message) => (message as Map)['content']?.toString() ?? '')
        .join('\n')
        .toLowerCase();

    expect(planningPrompt, contains('please would you tell me'));
    expect(planningPrompt, contains("it's a cheshire cat"));
    expect(planningPrompt, contains("don't bother me"));
    expect(planningPrompt, contains('here! you may nurse it a bit'));
    expect(planningPrompt, contains('chapter text is the source prose'));
    expect(planningPrompt, contains('convert all direct dialogue'));
    expect(planningPrompt, contains('song lyrics'));
    expect(planningPrompt, contains('inner thoughts'));
    expect(planningPrompt, contains('keep source-prose drawable details'));
    expect(
      planningPrompt,
      contains('picture-book narrative scene plan'),
    );
    expect(
      planningPrompt,
      contains('prefer visible action, pose, object, spatial relation'),
    );
    expect(
      planningPrompt,
      contains('before splitting scenes, convert quoted speech'),
    );
    expect(
      planningPrompt,
      contains('decide boundaries by illustration situation'),
    );
    expect(
      planningPrompt,
      contains('if the converted narrative leaves no material change'),
    );
    expect(
      planningPrompt,
      contains('those sentence slots must stay in the same scene'),
    );
    expect(
      planningPrompt,
      contains('one illustration may cover many consecutive sentences'),
    );
    expect(
      planningPrompt,
      contains(
          'start a new scene only when one axis changes materially enough'),
    );
    expect(
      planningPrompt,
      contains(
          'do not start a new scene for conversation turns, questions, answers'),
    );
    expect(
      planningPrompt,
      contains(
          'dialogue, song, shout, and inner-thought sentences are coverage anchors'),
    );
    expect(
      planningPrompt,
      contains('convert their plot and scene meaning into visible narrative'),
    );
    expect(
      planningPrompt,
      contains('do not replace converted speech with empty meta words only'),
    );
    expect(
      planningPrompt,
      contains('exchange, conversation, discuss, debate'),
    );
    expect(
      planningPrompt,
      contains(
          'dialogue-heavy ranges in one illustration situation must remain one scene'),
    );
    expect(
        planningPrompt, contains('hard validation cap: scenes.length <= 12'));
    expect(planningPrompt, isNot(contains('continuous story scene')));
    expect(planningPrompt, isNot(contains('mentally delete')));
    expect(planningPrompt, isNot(contains('remove direct dialogue')));
    expect(planningPrompt, isNot(contains('non-dialogue visual prose')));
    expect(planningPrompt, isNot(contains('remove speech/thought content')));
    expect(
      planningPrompt,
      isNot(contains('do not write substitute dialogue-summary words')),
    );
    expect(planningPrompt, isNot(contains('compact')));
    expect(planningPrompt, isNot(contains('same visible picture')));
    expect(planningPrompt, isNot(contains('physical picture')));
    expect(planningPrompt, isNot(contains('visible emotional state')));
    expect(planningPrompt,
        isNot(contains('preserve every major drawable detail')));
    expect(planningPrompt,
        isNot(contains('important non-dialogue visible details')));
    expect(
        planningPrompt, isNot(contains('do not summarize dialogue content')));
    expect(planningPrompt, isNot(contains('speech-only scene')));
    expect(planningPrompt, isNot(contains('major drawable details')));
    expect(planningPrompt,
        isNot(contains('would make the scenedescription vague')));
    expect(planningPrompt, isNot(contains('split that sentence range')));
    expect(planningPrompt, isNot(contains('dialogue-only span')));
    expect(planningPrompt, isNot(contains('smallest complete scene set')));
    expect(planningPrompt, isNot(contains('merge micro-phases')));
    expect(planningPrompt, isNot(contains('weak boundary')));
    expect(
      planningPrompt,
      isNot(contains('even if several actions or props are mentioned')),
    );

    final groupPrompt = refreshed['groupPrompt'].toString();
    expect(groupPrompt, contains('smoky pepper-filled kitchen'));
    expect(groupPrompt, contains('flying cookware'));
    expect(groupPrompt, contains('starfish-shaped child'));
    expect(groupPrompt, isNot(contains('Please would you tell me')));
    expect(groupPrompt, isNot(contains("It's a Cheshire cat")));
    expect(groupPrompt, isNot(contains('Pig!')));
    expect(groupPrompt, isNot(contains("don't bother me")));
    expect(groupPrompt, isNot(contains('Here! you may nurse it a bit')));
    expect(groupPrompt.toLowerCase(), isNot(contains('exchange')));
    expect(groupPrompt.toLowerCase(), isNot(contains('conversation')));
    expect(groupPrompt.toLowerCase(), isNot(contains('remark')));
  });

  test('picture-book chapter plan preserves E22 tea-party drawable details',
      () async {
    _writeImageArkKey(tempDir, 'ark-e22-tea-plan-key-12345678901234567890');
    final sentences = [
      'She had not gone much farther before she came in sight of the house of the March Hare.',
      'She thought it must be the right house, because the chimneys were shaped like ears and the roof was thatched with fur.',
      'It was so large a house, that she did not like to go nearer till she had nibbled some more of the left-hand bit of mushroom, and raised herself to about two feet high; even then she walked up toward it rather timidly.',
      'There was a table set out under a tree in front of the house.',
      'The March Hare and the Hatter were having tea at it.',
      'A Dormouse was sitting between them, fast asleep, and the other two were using it as a cushion, resting their elbows on it, and talking over its head.',
      'The table was a large one, but the three were all crowded together at one corner of it.',
      '"No room! No room!" they cried out when they saw Alice coming.',
      '"There is plenty of room," said Alice indignantly, and she sat down in a large arm-chair at one end of the table.',
      '"Have some wine," the March Hare said in an encouraging tone.',
      'Alice looked all round the table, but there was nothing on it but tea.',
      'The Hatter had been looking at Alice for some time with great curiosity.',
      'The Hatter opened his eyes very wide on hearing this.',
      '"Why is a raven like a writing-desk?"',
      'The conversation dropped, and the party sat silent for a minute, while Alice thought out all she could remember about ravens and writing-desks.',
    ];

    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'E22 Tea Party Detail Test',
        content: sentences.join('\n'),
        sentences: sentences,
        createdAt: DateTime(2026, 7, 8),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
      description:
          'Victorian fantasy picture book; Alice wears a blue dress and white apron.',
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    final review = await PictureBookService.promptReviewPayload(
      article: article,
      chapter: chapter,
      regenerate: true,
    );

    Map<String, dynamic>? textBody;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        textBody = body;
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'planKind': 'picture_book_chapter_scene_plan_v2',
                  'chapterDescription':
                      'Alice reaches the March Hare house, studies its animal-like architecture, adjusts her size with the mushroom, and enters a detailed outdoor tea-party scene that grows tense and strange before the group falls silent.',
                  'scenes': [
                    {
                      'pageIndex': 0,
                      'sentenceStartIndex': 0,
                      'sentenceEndIndex': 2,
                      'sceneDescription':
                          'Alice faces the March Hare house with chimneys shaped like ears and a fur-thatched roof, holding the mushroom after raising herself to about two feet high and approaching timidly.',
                    },
                    {
                      'pageIndex': 1,
                      'sentenceStartIndex': 3,
                      'sentenceEndIndex': 6,
                      'sceneDescription':
                          'A large tea table stands under a tree in front of the house, with the March Hare and Hatter crowded at one corner while the sleeping Dormouse is used as a cushion beneath their elbows.',
                    },
                    {
                      'pageIndex': 2,
                      'sentenceStartIndex': 7,
                      'sentenceEndIndex': 14,
                      'sceneDescription':
                          'Alice arrives at the oversized table, sits indignantly in a large armchair at one end, finds only tea on the table, while the Hatter watches Alice with great curiosity, Hatter opens eyes wide, and the tea party group sits silently at the table.',
                    },
                  ],
                }),
              },
            }
          ],
        };
      },
    );

    final refreshed = await _refreshChapterPlanFromReview(review);
    final textMessages = (textBody?['messages'] as List?) ?? const [];
    final planningPrompt = textMessages
        .map((message) => (message as Map)['content']?.toString() ?? '')
        .join('\n')
        .toLowerCase();

    expect(planningPrompt, contains('chimneys were shaped like ears'));
    expect(planningPrompt, contains('roof was thatched with fur'));
    expect(planningPrompt, contains('there was nothing on it but tea'));
    expect(planningPrompt, contains('hatter opened his eyes very wide'));
    expect(
      planningPrompt,
      contains('before splitting scenes, convert quoted speech'),
    );
    expect(
      planningPrompt,
      contains('decide boundaries by illustration situation'),
    );
    expect(
      planningPrompt,
      contains('if the converted narrative leaves no material change'),
    );
    expect(
      planningPrompt,
      contains('those sentence slots must stay in the same scene'),
    );
    expect(
      planningPrompt,
      contains('one illustration may cover many consecutive sentences'),
    );
    expect(
      planningPrompt,
      contains('numbered indexes are coverage anchors only'),
    );
    expect(
      planningPrompt,
      contains(
          'start a new scene only when one axis changes materially enough'),
    );
    expect(
      planningPrompt,
      contains(
          'do not start a new scene for conversation turns, questions, answers'),
    );
    expect(
      planningPrompt,
      contains('convert their plot and scene meaning into visible narrative'),
    );
    expect(
      planningPrompt,
      contains('do not replace converted speech with empty meta words only'),
    );
    expect(
      planningPrompt,
      contains('exchange, conversation, discuss, debate'),
    );
    expect(
      planningPrompt,
      contains(
          'dialogue-heavy ranges in one illustration situation must remain one scene'),
    );
    expect(
        planningPrompt, contains('hard validation cap: scenes.length <= 12'));
    expect(planningPrompt, isNot(contains('continuous story scene')));
    expect(planningPrompt, isNot(contains('keep one continuous tea-table')));
    expect(planningPrompt, isNot(contains('mentally delete')));
    expect(planningPrompt, isNot(contains('remove speech/thought content')));
    expect(
      planningPrompt,
      isNot(contains('do not write substitute dialogue-summary words')),
    );
    expect(planningPrompt, isNot(contains('create enough scenes')));
    expect(planningPrompt, isNot(contains('same visible picture')));
    expect(planningPrompt, isNot(contains('physical picture')));
    expect(planningPrompt, isNot(contains('visible emotional state')));
    expect(
        planningPrompt, isNot(contains('do not summarize dialogue content')));
    expect(planningPrompt, isNot(contains('split that sentence range')));
    expect(planningPrompt, isNot(contains('dialogue-only span')));
    expect(planningPrompt, isNot(contains('smallest complete scene set')));
    expect(planningPrompt, isNot(contains('merge micro-phases')));
    expect(planningPrompt, isNot(contains('weak boundary')));

    final scenes = refreshed['scenes'] as List<dynamic>;
    expect(scenes, hasLength(3));
    expect((scenes.last as Map)['sentenceStartIndex'], 7);
    expect((scenes.last as Map)['sentenceEndIndex'], 14);

    final groupPrompt = refreshed['groupPrompt'].toString();
    expect(groupPrompt, contains('chimneys shaped like ears'));
    expect(groupPrompt, contains('fur-thatched roof'));
    expect(groupPrompt, contains('only tea on the table'));
    expect(groupPrompt, contains('Dormouse is used as a cushion'));
    expect(groupPrompt, contains('large armchair'));
    expect(groupPrompt, contains('Hatter opens eyes wide'));
    expect(groupPrompt, isNot(contains('No room')));
    expect(groupPrompt, isNot(contains('Have some wine')));
    expect(groupPrompt, isNot(contains('Why is a raven')));
    expect(groupPrompt.toLowerCase(), isNot(contains('riddle')));
    expect(groupPrompt.toLowerCase(), isNot(contains('debate')));
    expect(groupPrompt.toLowerCase(), isNot(contains('remark')));
    expect(groupPrompt.toLowerCase(), isNot(contains('exchange')));
    expect(groupPrompt.toLowerCase(), isNot(contains('conversation')));
    expect(groupPrompt.toLowerCase(), isNot(contains('question')));
    expect(groupPrompt.toLowerCase(), isNot(contains('answer')));
    expect(groupPrompt.toLowerCase(), isNot(contains('mean')));
  });

  test('picture-book chapter plan keeps full E22 at reasonable scene count',
      () async {
    _writeImageArkKey(tempDir, 'ark-full-e22-plan-key-12345678901234567890');
    final sentences = [
      'Alice was not much surprised at this, she was getting so used to queer things happening.',
      'While she was still looking at the place where it had been, it suddenly appeared again.',
      '"By-the-by, what became of the baby?" said the Cat. "I\'d nearly forgotten to ask."',
      '"It turned into a pig," Alice answered very quietly, just as if the Cat had come back in a natural way.',
      '"I thought it would," said the Cat, and vanished again.',
      'Alice waited a little, half expecting to see it again, but it did not appear, and',
      'after a minute or two she walked on in the direction in which the March Hare was said to live.',
      '"I\'ve seen Hatters before," she said to herself; "the March Hare will be much the most interesting and perhaps as this is May it won\'t be raving mad—',
      'at least not so mad as it was in March."',
      'As she said this, she looked up, and there was the Cat again, sitting on a branch of a tree.',
      '"Did you say pig, or fig?" said the Cat.',
      '"I said pig," replied Alice; "and I wish you wouldn\'t keep appearing and vanishing so suddenly; you make one quite giddy."',
      '"All right," said the Cat; and this time it vanished quite slowly, beginning with the end of the tail,',
      'and ending with the grin, which remained some time after the rest of it had gone.',
      '"Well, I\'ve often seen a cat without a grin," thought Alice; "but a grin without a cat!',
      'It\'s the most curious thing I ever saw in my life!"',
      'She had not gone much farther before she came in sight of the house of the March Hare:',
      'she thought it must be the right house, because the chimneys were shaped like ears and the roof was thatched with fur.',
      'It was so large a house, that she did not like to go nearer till she had nibbled some more of the left-hand bit of mushroom, and raised herself to about two feet high; even then she walked up toward it rather timidly, saying to herself,',
      '"Suppose it should be raving mad after all, I almost wish I\'d gone to see the Hatter instead."',
      'There was a table set out under a tree in front of the house,',
      'and the March Hare and the Hatter were having tea at it:',
      'a Dormouse was sitting between them, fast asleep, and the other two were using it as a cushion,',
      'resting their elbows on it, and talking over its head.',
      '"Very uncomfortable for the Dormouse," thought Alice:"only as it\'s asleep, I suppose it doesn\'t mind."',
      'The table was a large one, but the three were all crowded together at one corner of it:',
      '"No room! No room!" they cried out when they saw Alice coming.',
      '"There\'s plenty of room," said Alice indignantly, and she sat down in a large arm-chair at one end of the table.',
      '"Have some wine," the March Hare said in an encouraging tone.',
      'Alice looked all round the table, but there was nothing on it but tea.',
      '"I don\'t see any wine," she remarked. "There isn\'t any," said the March Hare.',
      '"Then it wasn\'t very civil of you to offer it," said Alice angrily.',
      '"It wasn\'t very civil of you to sit down without being invited," said the March Hare.',
      '"I didn\'t know it was your table," said Alice; "It\'s laid for a great many more than three."',
      '"Your hair wants cutting," said the Hatter.',
      'He had been looking at Alice for some time with great curiosity, and this was his first speech.',
      '"You should learn not to make personal remarks, " Alice said with some severity: "It\'s very rude."',
      'The Hatter opened his eyes very wide on hearing this; but all he said was,',
      '"Why is a raven like a writing-desk?"',
      '"Come, we shall have some fun now!" thought Alice. "I\'m glad they\'ve begun asking riddles—I believe I can guess that," she added aloud.',
      '"Do you mean that you think you can find out the answer to it?" said the March Hare.',
      '"Exactly so," said Alice. "Then you should say what you mean," the March Hare went on.',
      '"I do," Alice hastily replied, "at least—at least I mean what I say—that\'s the same thing, you know."',
      '"Not the same thing a bit!" said the Hatter.',
      '"Why, you might just as well say that \'I see what I eat\' is the same thing as \'I eat what I see!\'"',
      '"You might just as well say," added the March Hare,',
      '"that \'I like what I get\' is the same thing as \'I get what I like!\'"',
      '"You might just as well say," added the Dormouse, who seemed to be talking in his sleep, "that \'I breathe',
      'when I sleep\' is the same thing as \'I sleep when I breathe!\'"',
      '"It is the same thing with you," said the Hatter, and here the conversation dropped, and the party sat silent for a minute,',
      'while Alice thought out all she could remember about ravens and writing-desks, which wasn\'t much.',
      '17.I meant what I said',
      'See?',
      'I meant what I said.',
    ];

    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'E22 Full Scene Plan Regression',
        content: sentences.join('\n'),
        sentences: sentences,
        createdAt: DateTime(2026, 7, 8),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
      description:
          'Victorian fantasy picture book; Alice wears a blue dress and white apron.',
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    final review = await PictureBookService.promptReviewPayload(
      article: article,
      chapter: chapter,
      regenerate: true,
    );

    Map<String, dynamic>? textBody;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        textBody = body;
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'planKind': 'picture_book_chapter_scene_plan_v2',
                  'chapterDescription':
                      'Alice sees the Cheshire Cat reappear and vanish along the path, watches its grin linger in mid-air, reaches the March Hare house, and joins the strange tea table under the tree before the group falls silent.',
                  'scenes': [
                    {
                      'pageIndex': 0,
                      'sentenceStartIndex': 0,
                      'sentenceEndIndex': 4,
                      'sceneDescription':
                          'Alice stands calmly at the spot where the Cheshire Cat vanished; the Cat suddenly appears again nearby, then vanishes once more.',
                    },
                    {
                      'pageIndex': 1,
                      'sentenceStartIndex': 5,
                      'sentenceEndIndex': 8,
                      'sceneDescription':
                          'Alice waits on the path half expecting the Cheshire Cat to return, then walks toward the March Hare home.',
                    },
                    {
                      'pageIndex': 2,
                      'sentenceStartIndex': 9,
                      'sentenceEndIndex': 15,
                      'sceneDescription':
                          'The Cheshire Cat sits on a tree branch above Alice, then vanishes slowly from tail to grin, leaving only the grin floating in mid-air while Alice looks up at it.',
                    },
                    {
                      'pageIndex': 3,
                      'sentenceStartIndex': 16,
                      'sentenceEndIndex': 19,
                      'sceneDescription':
                          'Alice reaches the March Hare house with chimneys shaped like ears and a fur-thatched roof, nibbles the mushroom to become about two feet high, and approaches timidly.',
                    },
                    {
                      'pageIndex': 4,
                      'sentenceStartIndex': 20,
                      'sentenceEndIndex': 24,
                      'sceneDescription':
                          'A large tea table stands under a tree in front of the house; the March Hare and Hatter sit at it with the sleeping Dormouse between them as a cushion beneath their elbows.',
                    },
                    {
                      'pageIndex': 5,
                      'sentenceStartIndex': 25,
                      'sentenceEndIndex': 53,
                      'sceneDescription':
                          'At the large tea table, the three guests remain crowded at one corner while Alice sits in a large armchair at the end; Alice sees only tea on the table, the Hatter watches her with curiosity and opens his eyes wide, and the whole tea party falls silent.',
                    },
                  ],
                }),
              },
            }
          ],
        };
      },
    );

    final refreshed = await _refreshChapterPlanFromReview(review);
    final textMessages = (textBody?['messages'] as List?) ?? const [];
    final planningPrompt = textMessages
        .map((message) => (message as Map)['content']?.toString() ?? '')
        .join('\n')
        .toLowerCase();

    expect(planningPrompt, contains('17.i meant what i said'));
    expect(planningPrompt,
        contains('if the converted narrative leaves no material change'));
    expect(
      planningPrompt,
      contains('those sentence slots must stay in the same scene'),
    );
    expect(
      planningPrompt,
      contains(
          'dialogue-heavy ranges in one illustration situation must remain one scene'),
    );
    expect(
        planningPrompt, contains('hard validation cap: scenes.length <= 12'));
    expect(
      planningPrompt,
      contains('do not invent splits to approach the cap'),
    );
    expect(
      planningPrompt,
      contains('do not replace converted speech with empty meta words only'),
    );
    expect(planningPrompt, isNot(contains('continuous story scene')));
    expect(planningPrompt, isNot(contains('mentally delete')));
    expect(planningPrompt, isNot(contains('use at most 12 scenes')));
    expect(planningPrompt, isNot(contains('compact')));
    expect(planningPrompt, isNot(contains('smallest complete scene set')));

    final scenes = refreshed['scenes'] as List<dynamic>;
    expect(scenes, hasLength(6));
    expect(
      [
        for (final scene in scenes)
          [
            (scene as Map)['sentenceStartIndex'],
            scene['sentenceEndIndex'],
          ],
      ],
      [
        [0, 4],
        [5, 8],
        [9, 15],
        [16, 19],
        [20, 24],
        [25, 53],
      ],
    );

    final groupPrompt = refreshed['groupPrompt'].toString();
    expect(groupPrompt, contains('Cheshire Cat'));
    expect(groupPrompt, contains('grin floating in mid-air'));
    expect(groupPrompt, contains('chimneys shaped like ears'));
    expect(groupPrompt, contains('fur-thatched roof'));
    expect(groupPrompt, contains('sleeping Dormouse'));
    expect(groupPrompt, contains('large armchair'));
    expect(groupPrompt, contains('only tea on the table'));
    expect(groupPrompt, contains('opens his eyes wide'));
    expect(groupPrompt, contains('falls silent'));
    expect(groupPrompt, isNot(contains('No room')));
    expect(groupPrompt, isNot(contains('Have some wine')));
    expect(groupPrompt, isNot(contains('Why is a raven')));
    expect(groupPrompt, isNot(contains('I meant what I said')));
    _expectNoDialogueSummaryWords(groupPrompt);
  });

  test('picture-book prompt review draft rows follow paragraph cap without AI',
      () async {
    _writeImageArkKey(tempDir, 'ark-paragraph-draft-key-12345678901234567890');
    final paragraphs = [
      for (var index = 0; index < 14; index += 1)
        'Paragraph marker ${index + 1} gives Alice a distinct visible beat.',
    ];
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Paragraph Draft Chapter',
        content: paragraphs.join('\n\n'),
        sentences: paragraphs,
        createdAt: DateTime(2026, 1, 2),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
      description: 'Victorian fantasy picture book with Alice as the lead.',
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );

    var textAiCalls = 0;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        textAiCalls += 1;
        throw StateError('opening paragraph draft should not call text AI');
      },
    );

    final review = await PictureBookService.promptReviewPayload(
      article: article,
      chapter: chapter,
      regenerate: true,
    );

    final scenes = review['scenes'] as List;
    expect(textAiCalls, 0);
    expect(review['chapterDescription'], '');
    expect(scenes, hasLength(12));
    expect(
      scenes.every((scene) => (scene as Map)['sceneDescription'] == ''),
      isTrue,
    );
    expect((scenes.first as Map)['sentenceStartIndex'], 0);
    expect((scenes.first as Map)['paragraphText'], contains('marker 1'));
    expect((scenes.last as Map)['sentenceEndIndex'], paragraphs.length - 1);
    expect((scenes.last as Map)['paragraphText'], contains('marker 14'));
    expect(await DatabaseService.getPictureBookPages(articleId), isEmpty);
  });

  test('picture-book prompt review keeps Mouse learning notes out of draft',
      () async {
    _writeImageArkKey(tempDir, 'ark-mouse-refresh-key-12345678901234567890');
    final raw = File(path_lib.join(
      previousDirectory.path,
      'test',
      'fixtures',
      'mouse_sad_tale_with_learning_notes.txt',
    )).readAsStringSync();
    final parsed = PracticeInputParser.parse(raw);
    final sentences = NlpService.splitSentences(parsed.englishContent);
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: "The Mouse's Sad Tale",
        content: parsed.englishContent,
        sentences: sentences,
        createdAt: DateTime(2026, 6, 27),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
      description: 'Victorian Alice storybook world in soft watercolor.',
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );

    var textAiCalls = 0;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        textAiCalls += 1;
        throw StateError('opening Mouse prompt review should not call text AI');
      },
    );

    final review = await PictureBookService.promptReviewPayload(
      article: article,
      chapter: chapter,
      regenerate: true,
    );

    final scenes = review['scenes'] as List;
    const learningNoteNeedles = [
      'attend vs. pay attention',
      'Bill has not been attending',
      '英 [',
      '美 [',
      "lose one's temper",
      'pretext',
    ];

    expect(textAiCalls, 0);
    expect(scenes, isNotEmpty);
    expect(parsed.englishContent, contains('finish his story'));
    expect(review['chapterDescription'], '');
    expect(scenes.every((scene) => (scene as Map)['sceneDescription'] == ''),
        isTrue);
    expect((scenes.last as Map)['sentenceEndIndex'], sentences.length - 1);
    final emptyDraftText = [
      review['chapterDescription']?.toString() ?? '',
      review['groupPrompt']?.toString() ?? '',
      for (final scene in scenes)
        (scene as Map)['sceneDescription']?.toString() ?? '',
    ].join('\n');
    for (final needle in learningNoteNeedles) {
      expect(emptyDraftText, isNot(contains(needle)));
    }

    const mouseChapterDescription =
        'The Mouse recounts his grievance with Fury, storms away after Alice offends him, and Alice looks for his return.';
    final middleSentenceIndex = sentences.length ~/ 2;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        textAiCalls += 1;
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'planKind': 'picture_book_chapter_scene_plan_v2',
                  'chapterDescription': mouseChapterDescription,
                  'scenes': [
                    {
                      'pageIndex': 0,
                      'sentenceStartIndex': 0,
                      'sentenceEndIndex': middleSentenceIndex - 1,
                      'sceneDescription':
                          'The Mouse begins his sad tale while Alice and the birds listen closely.',
                    },
                    {
                      'pageIndex': 1,
                      'sentenceStartIndex': middleSentenceIndex,
                      'sentenceEndIndex': sentences.length - 1,
                      'sceneDescription':
                          'Alice upsets the Mouse, then searches anxiously as he refuses to return.',
                    },
                  ],
                }),
              },
            }
          ],
        };
      },
    );

    final refreshed = await _refreshChapterPlanFromReview(review);
    expect(textAiCalls, 1);
    final refreshedScenes = refreshed['scenes'] as List;
    final draftText = [
      refreshed['chapterDescription']?.toString() ?? '',
      refreshed['groupPrompt']?.toString() ?? '',
      for (final scene in refreshedScenes)
        (scene as Map)['sceneDescription']?.toString() ?? '',
    ].join('\n');
    expect(refreshed['chapterDescription'], mouseChapterDescription);
    expect(
      refreshed['chapterDescription'].toString().trim(),
      isNot(startsWith('"You promised')),
    );
    expect(
      (refreshedScenes.last as Map)['sentenceEndIndex'],
      sentences.length - 1,
    );
    for (final needle in learningNoteNeedles) {
      expect(draftText, isNot(contains(needle)));
    }

    await PictureBookService.savePromptReview(
      reviewId: refreshed['reviewId'].toString(),
      groupPrompt: refreshed['groupPrompt'].toString(),
      bookDescription: refreshed['bookDescription'].toString(),
      bookCharacters: _charactersFromPayload(refreshed['bookCharacters']),
      newCharacters: _charactersFromPayload(refreshed['newCharacters']),
      chapterDescription: refreshed['chapterDescription'].toString(),
      scenes: [
        for (final scene in refreshedScenes)
          Map<String, dynamic>.from(scene as Map),
      ],
    );

    final savedChapter =
        await DatabaseService.getStoryChapterForArticle(articleId);
    final savedSummary = savedChapter?.summaryJson ?? '';
    final savedSummaryJson = jsonDecode(savedSummary) as Map<String, dynamic>;
    final savedScenes = savedSummaryJson['scenes'] as List;
    expect(savedSummaryJson['chapterDescription'], mouseChapterDescription);
    expect(savedSummaryJson.containsKey('summary'), isFalse);
    expect((savedScenes.last as Map)['sentenceEndIndex'], sentences.length - 1);
    for (final needle in learningNoteNeedles) {
      expect(savedSummary, isNot(contains(needle)));
    }
  });

  test(
      'picture-book prompt review does not merge chapter description into book draft',
      () async {
    _writeImageArkKey(tempDir, 'ark-chapter-roster-key-12345678901234567890');
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'The Queen Points',
        content:
            'Alice walks into the garden. The Queen of Hearts points at the White Rabbit.',
        sentences: const [
          'Alice walks into the garden.',
          'The Queen of Hearts points at the White Rabbit.',
        ],
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
      description:
          'Alice is a blonde Victorian girl in a blue dress and white apron.',
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    var textAiCalls = 0;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        textAiCalls += 1;
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'planKind': 'picture_book_chapter_scene_plan_v2',
                  'chapterDescription':
                      'Alice enters the royal garden and sees the Queen command the White Rabbit. The Queen wears a red heart gown and crown; the White Rabbit wears a waistcoat and carries a pocket watch.',
                  'scenes': [
                    {
                      'pageIndex': 0,
                      'sentenceStartIndex': 0,
                      'sentenceEndIndex': 0,
                      'sceneDescription': 'Alice walks into the garden.',
                    },
                    {
                      'pageIndex': 1,
                      'sentenceStartIndex': 1,
                      'sentenceEndIndex': 1,
                      'sceneDescription':
                          'The Queen of Hearts points at the White Rabbit.',
                    },
                  ],
                }),
              },
            }
          ],
        };
      },
    );

    final review = await PictureBookService.promptReviewPayload(
      article: article,
      chapter: chapter,
    );

    expect(review['bookDescription'], isNot(contains('Queen of Hearts')));
    expect(review['bookDescription'], isNot(contains('White Rabbit')));
    expect(review['chapterDescription'], '');
    expect(textAiCalls, 0);
    final refreshed = await _refreshChapterPlanFromReview(review);
    expect(textAiCalls, 1);
    expect(refreshed['chapterDescription'], contains('Queen'));
    expect(refreshed['chapterDescription'], contains('White Rabbit'));
    expect(refreshed['groupPrompt'], contains('Queen of Hearts'));
    final unchangedSeries =
        await DatabaseService.getStorySeriesById(series.id!);
    expect(unchangedSeries?.description, isNot(contains('Queen of Hearts')));

    await PictureBookService.savePromptReview(
      reviewId: refreshed['reviewId'].toString(),
      groupPrompt: refreshed['groupPrompt'].toString(),
      bookDescription: refreshed['bookDescription'].toString(),
      bookCharacters: const [],
      newCharacters: const [],
      chapterDescription: refreshed['chapterDescription'].toString(),
      scenes: [
        for (final scene in refreshed['scenes'] as List)
          Map<String, dynamic>.from(scene as Map),
      ],
    );

    final savedSeries = await DatabaseService.getStorySeriesById(series.id!);
    expect(savedSeries?.description, isNot(contains('Queen of Hearts')));
    expect(savedSeries?.description, isNot(contains('White Rabbit')));
  });

  test('picture-book group prompt keeps full twelve image descriptions',
      () async {
    _writeImageArkKey(tempDir, 'ark-full-prompt-key-12345678901234567890');
    final sentences = [
      for (var i = 0; i < 12; i += 1)
        'Alice meets character ${i + 1} beside a curious Wonderland landmark.',
    ];
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Long Wonderland Chapter',
        content: sentences.join(' '),
        sentences: sentences,
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
      description:
          'Alice is a blonde Victorian girl in a blue dress and white apron; the White Rabbit wears a waistcoat; the Queen of Hearts wears a red heart gown; the Mad Hatter carries tea things.',
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'planKind': 'picture_book_chapter_scene_plan_v2',
                  'chapterDescription':
                      'Alice crosses twelve quick Wonderland moments with recurring characters, including the Gryphon as a golden eagle-lion guardian and the Mock Turtle as a melancholy turtle-calf with a shell collar.',
                  'scenes': [
                    for (var i = 0; i < 12; i += 1)
                      {
                        'pageIndex': i,
                        'sentenceStartIndex': i,
                        'sentenceEndIndex': i,
                        'sceneDescription':
                            'Alice meets character ${i + 1} beside a curious landmark with full untrimmed detail marker ${i + 1}.',
                      },
                  ],
                }),
              },
            }
          ],
        };
      },
    );

    final initialReview = await PictureBookService.promptReviewPayload(
      article: article,
      chapter: chapter,
    );
    final review = await _refreshChapterPlanFromReview(initialReview);
    final prompt = review['groupPrompt'].toString();

    expect(prompt, contains('Image 1:'));
    expect(prompt, contains('Image 12:'));
    expect(prompt, contains('Scene description:'));
    expect(prompt, contains('full untrimmed detail marker 1'));
    expect(prompt, contains('full untrimmed detail marker 12'));
  });

  test(
      'picture-book prompt magic refresh updates draft without image generation',
      () async {
    _writeImageArkKey(tempDir, 'ark-refresh-key-12345678901234567890');
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Refresh Test',
        content:
            'Alice walks into the garden. The Queen points at the croquet ground.',
        sentences: const [
          'Alice walks into the garden.',
          'The Queen points at the croquet ground.',
        ],
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    await _installTwoPageChapterPlanOverride();
    final now = DateTime(2026, 1, 1);
    await DatabaseService.upsertPictureBookPage(
      PictureBookPage(
        articleId: articleId,
        seriesId: series.id,
        pageIndex: 0,
        sentenceStartIndex: 0,
        sentenceEndIndex: 0,
        paragraphText: 'Old page',
        promptJson: '{}',
        imagePath: 'old.png',
        status: 'ready',
        createdAt: now,
        updatedAt: now,
      ),
    );
    final review = await PictureBookService.promptReviewPayload(
      article: article,
      chapter: chapter,
      regenerate: true,
    );

    var imageCalls = 0;
    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        imageCalls += 1;
        return {'data': const []};
      },
    );
    var textCalls = 0;
    String? refreshedBookPrompt;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        textCalls += 1;
        if (textCalls == 1) {
          final messages = (body['messages'] as List?) ?? const <Object?>[];
          refreshedBookPrompt = messages
              .whereType<Map>()
              .map((message) => message['content']?.toString() ?? '')
              .join('\n')
              .toLowerCase();
          return {
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'bookDescription':
                        'Refreshed Victorian watercolor Alice picture book with a consistent blue dress and white pinafore.',
                  }),
                },
              }
            ],
          };
        }
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'planKind': 'picture_book_chapter_scene_plan_v2',
                  'chapterDescription':
                      'Refreshed Alice chapter plan across the garden.',
                  'scenes': [
                    {
                      'pageIndex': 0,
                      'sentenceStartIndex': 0,
                      'sentenceEndIndex': 0,
                      'sceneDescription':
                          'Alice enters the garden path and notices the croquet ground ahead.',
                    },
                    {
                      'pageIndex': 1,
                      'sentenceStartIndex': 1,
                      'sentenceEndIndex': 1,
                      'sceneDescription':
                          'The Queen gestures toward the croquet ground as the scene turns tense.',
                    },
                  ],
                }),
              },
            }
          ],
        };
      },
    );

    final refreshedBook = await PictureBookService.refreshPromptReview(
      reviewId: review['reviewId'].toString(),
      target: 'bookDescription',
      bookDescription:
          'Victorian watercolor Alice picture book. Chapter character additions: temporary narrator in tweed.',
      bookCharacters: const [],
      newCharacters: const [],
      chapterDescription: review['chapterDescription'].toString(),
      scenes: [
        for (final scene in review['scenes'] as List)
          Map<String, dynamic>.from(scene as Map),
      ],
    );

    expect(refreshedBook['bookDescription'], contains('white pinafore'));
    expect(refreshedBook['groupPrompt'], contains('white pinafore'));
    expect(refreshedBook['refreshedTarget'], 'bookDescription');
    expect(
      refreshedBookPrompt,
      contains(
          'write one short natural paragraph that can be saved directly as the book visual-world description'),
    );
    expect(
      refreshedBookPrompt,
      contains(
          'use the reference text only to discover details that belong to the whole book'),
    );
    expect(
      refreshedBookPrompt,
      contains('do not include chapter plot'),
    );
    expect(
      refreshedBookPrompt,
      contains('do not mention internal planning words'),
    );
    expect(refreshedBookPrompt, isNot(contains('role-based')));
    expect(refreshedBookPrompt, isNot(contains('appearance anchors')));
    expect(refreshedBookPrompt, isNot(contains('visual anchors')));
    expect(refreshedBookPrompt, isNot(contains('chapter order')));
    expect(refreshedBookPrompt, isNot(contains('chapter title')));
    expect(refreshedBookPrompt, isNot(contains('current chapterdescription')));
    expect(refreshedBookPrompt, isNot(contains('temporary narrator in tweed')));
    expect(refreshedBookPrompt, isNot(contains('bailian')));
    expect(refreshedBookPrompt, isNot(contains('aliyun')));
    expect(refreshedBookPrompt, isNot(contains('qwen')));

    final refreshed = await PictureBookService.refreshPromptReview(
      reviewId: review['reviewId'].toString(),
      target: 'chapterPlan',
      bookDescription: refreshedBook['bookDescription'].toString(),
      bookCharacters: const [],
      newCharacters: const [],
      chapterDescription: refreshedBook['chapterDescription'].toString(),
      scenes: [
        for (final scene in refreshedBook['scenes'] as List)
          Map<String, dynamic>.from(scene as Map),
      ],
    );

    expect(refreshed['chapterDescription'],
        contains('Refreshed Alice chapter plan'));
    expect(refreshed['bookDescription'], contains('Victorian watercolor'));
    expect(refreshed['groupPrompt'], contains('Refreshed Alice chapter plan'));
    expect(refreshed['groupPrompt'],
        contains('The Queen gestures toward the croquet ground'));
    expect(textCalls, 2);
    expect(imageCalls, 0);
    final pages = await DatabaseService.getPictureBookPages(articleId);
    expect(pages, hasLength(1));
    expect(pages.single.paragraphText, 'Old page');
  });

  test('picture-book prompt save does not submit image generation', () async {
    _writeImageArkKey(tempDir, 'ark-save-prompt-key-12345678901234567890');
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Save Prompt Test',
        content:
            'Alice walks into the garden. The Queen points at the croquet ground.',
        sentences: const [
          'Alice walks into the garden.',
          'The Queen points at the croquet ground.',
        ],
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    await _installTwoPageChapterPlanOverride();
    final now = DateTime(2026, 1, 1);
    await DatabaseService.upsertPictureBookPage(
      PictureBookPage(
        articleId: articleId,
        seriesId: series.id,
        pageIndex: 0,
        sentenceStartIndex: 0,
        sentenceEndIndex: 0,
        paragraphText: 'Old page',
        promptJson: '{}',
        imagePath: 'old.png',
        status: 'ready',
        createdAt: now,
        updatedAt: now,
      ),
    );
    final review = await PictureBookService.promptReviewPayload(
      article: article,
      chapter: chapter,
      regenerate: true,
    );

    var imageCalls = 0;
    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        imageCalls += 1;
        return {'data': const []};
      },
    );

    final saved = await PictureBookService.savePromptReview(
      reviewId: review['reviewId'].toString(),
      groupPrompt: 'Saved only group prompt.',
      bookDescription:
          'Saved Victorian fantasy picture book; Alice wears a blue dress.',
      bookCharacters: const [],
      newCharacters: const [],
      chapterDescription: review['chapterDescription'].toString(),
      scenes: [
        for (final scene in review['scenes'] as List)
          Map<String, dynamic>.from(scene as Map),
      ],
    );

    expect(saved['groupPrompt'], 'Saved only group prompt.');
    expect(saved['bookDescription'], contains('Saved Victorian'));
    expect(imageCalls, 0);
    final pages = await DatabaseService.getPictureBookPages(articleId);
    expect(pages, hasLength(1));
    expect(pages.single.paragraphText, 'Old page');
    final updatedSeries = await DatabaseService.getStorySeriesById(series.id!);
    expect(updatedSeries?.description, contains('blue dress'));
  });

  test('picture-book saved chapter plan survives article rename', () async {
    _writeImageArkKey(tempDir, 'ark-rename-plan-key-12345678901234567890');
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Alice And The Puppy',
        content:
            'Alice walks into the garden. The Queen points at the croquet ground.',
        sentences: const [
          'Alice walks into the garden.',
          'The Queen points at the croquet ground.',
        ],
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    var article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    await _installTwoPageChapterPlanOverride();
    final review = await PictureBookService.promptReviewPayload(
      article: article,
      chapter: chapter,
      regenerate: true,
    );
    final refreshed = await _refreshChapterPlanFromReview(review);
    await PictureBookService.savePromptReview(
      reviewId: refreshed['reviewId'].toString(),
      groupPrompt: refreshed['groupPrompt'].toString(),
      bookDescription: refreshed['bookDescription'].toString(),
      bookCharacters: _charactersFromPayload(refreshed['bookCharacters']),
      newCharacters: _charactersFromPayload(refreshed['newCharacters']),
      chapterDescription: refreshed['chapterDescription'].toString(),
      scenes: [
        for (final scene in refreshed['scenes'] as List)
          Map<String, dynamic>.from(scene as Map),
      ],
    );

    final savedChapter =
        await DatabaseService.getStoryChapterForArticle(articleId);
    final savedSummary =
        jsonDecode(savedChapter!.summaryJson) as Map<String, dynamic>;
    expect(savedSummary.containsKey('contentHash'), isFalse);
    savedSummary['contentHash'] = 'stale-hash-from-legacy-build';
    await DatabaseService.updateStoryChapter(
      savedChapter.copyWith(
        summaryJson: jsonEncode(savedSummary),
        updatedAt: DateTime(2026, 1, 2),
      ),
    );

    await DatabaseService.updateArticleTitle(
      articleId,
      'E15 - Alice And The Puppy',
    );
    article = await DatabaseService.getArticleById(articleId);

    final reopened = await PictureBookService.promptReviewPayload(
      article: article!,
      chapter: savedChapter,
      regenerate: true,
    );
    final reopenedScenes = reopened['scenes'] as List;
    expect(reopenedScenes, hasLength(2));
    expect(
      (reopenedScenes.first as Map)['sceneDescription'],
      'Alice walks into the garden.',
    );
    expect(
      (reopenedScenes.last as Map)['sceneDescription'],
      'The Queen points at the croquet ground.',
    );
    expect(reopened['chapterDescription'], contains('Alice'));
    expect(reopened.containsKey('contentHash'), isFalse);
  });

  test('picture-book prompt review merges new characters only on confirm',
      () async {
    _writeImageArkKey(tempDir, 'ark-character-merge-key-12345678901234567890');
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Character Merge Test',
        content: 'Alice follows the White Rabbit into the garden.',
        sentences: const [
          'Alice follows the White Rabbit into the garden.',
        ],
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
      description: 'Victorian storybook world with whimsical garden colors.',
      characters: const [
        BookCharacter(
          name: 'Alice',
          description: 'Young girl in a blue dress and white apron.',
        ),
      ],
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'planKind': 'picture_book_chapter_scene_plan_v2',
                  'chapterDescription':
                      'Alice follows the White Rabbit through a bright garden path.',
                  'scenes': [
                    {
                      'pageIndex': 0,
                      'sentenceStartIndex': 0,
                      'sentenceEndIndex': 0,
                      'sceneDescription':
                          'Alice follows the White Rabbit into the garden.',
                    },
                  ],
                  'newCharacters': [
                    {
                      'name': 'White Rabbit',
                      'description':
                          'Tall white rabbit with pink eyes and a red waistcoat.',
                    },
                  ],
                }),
              },
            }
          ],
        };
      },
    );

    final initialReview = await PictureBookService.promptReviewPayload(
      article: article,
      chapter: chapter,
    );
    final review = await _refreshChapterPlanFromReview(initialReview);
    expect(review['bookCharacters'], hasLength(1));
    expect(review['relevantCharacters'], hasLength(1));
    expect(review['newCharacters'], hasLength(1));
    expect(review['groupPrompt'], contains('Relevant characters:'));
    expect(review['groupPrompt'], contains('Alice: Young girl'));
    expect(review['groupPrompt'], contains('White Rabbit: Tall white rabbit'));

    await PictureBookService.savePromptReview(
      reviewId: review['reviewId'].toString(),
      groupPrompt: review['groupPrompt'].toString(),
      bookDescription: review['bookDescription'].toString(),
      bookCharacters: const [
        BookCharacter(
          name: 'Alice',
          description: 'Edited Alice description that must remain.',
        ),
      ],
      newCharacters: const [
        BookCharacter(
          name: 'Alice',
          description: 'Duplicate Alice description that must not overwrite.',
        ),
        BookCharacter(
          name: 'White Rabbit',
          description: 'Tall white rabbit with pink eyes and a red waistcoat.',
        ),
      ],
      chapterDescription: review['chapterDescription'].toString(),
      scenes: [
        for (final scene in review['scenes'] as List)
          Map<String, dynamic>.from(scene as Map),
      ],
    );
    final savedSeries = await DatabaseService.getStorySeriesById(series.id!);
    expect(savedSeries?.characters.map((item) => item.name), ['Alice']);

    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        return {
          'data': [
            {
              'b64_json': base64Encode([137, 80, 78, 71, 10])
            },
          ],
        };
      },
    );
    await PictureBookService.confirmPromptReview(
      reviewId: review['reviewId'].toString(),
      groupPrompt: review['groupPrompt'].toString(),
      bookDescription: review['bookDescription'].toString(),
      bookCharacters: const [
        BookCharacter(
          name: 'Alice',
          description: 'Edited Alice description that must remain.',
        ),
      ],
      newCharacters: const [
        BookCharacter(
          name: 'Alice',
          description: 'Duplicate Alice description that must not overwrite.',
        ),
        BookCharacter(
          name: 'White Rabbit',
          description: 'Tall white rabbit with pink eyes and a red waistcoat.',
        ),
      ],
      chapterDescription: review['chapterDescription'].toString(),
      scenes: [
        for (final scene in review['scenes'] as List)
          Map<String, dynamic>.from(scene as Map),
      ],
    );

    final confirmedSeries =
        await DatabaseService.getStorySeriesById(series.id!);
    expect(confirmedSeries?.characters.map((item) => item.name),
        ['Alice', 'White Rabbit']);
    expect(confirmedSeries?.characters.first.description,
        'Edited Alice description that must remain.');
  });

  test('picture-book prompt confirmation submits images only after review',
      () async {
    _writeImageArkKey(tempDir, 'ark-confirm-key-12345678901234567890');
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Confirm Test',
        content:
            'Alice walks into the garden. The Queen points at the croquet ground.',
        sentences: const [
          'Alice walks into the garden.',
          'The Queen points at the croquet ground.',
        ],
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    await _installTwoPageChapterPlanOverride();
    final initialReview = await PictureBookService.promptReviewPayload(
      article: article,
      chapter: chapter,
    );
    final review = await _refreshChapterPlanFromReview(initialReview);
    Map<String, dynamic>? imageBody;
    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        imageBody = body;
        return {
          'data': [
            {
              'b64_json': base64Encode([137, 80, 78, 71, 8])
            },
            {
              'b64_json': base64Encode([137, 80, 78, 71, 9])
            },
          ],
        };
      },
    );

    await PictureBookService.confirmPromptReview(
      reviewId: review['reviewId'].toString(),
      groupPrompt: 'Edited group prompt for confirmed image generation.',
      bookDescription:
          'Victorian fantasy picture book; Alice wears a blue dress and white apron.',
      bookCharacters: const [],
      newCharacters: const [],
      chapterDescription: review['chapterDescription'].toString(),
      scenes: [
        for (final scene in review['scenes'] as List)
          {
            ...Map<String, dynamic>.from(scene as Map),
            'sceneDescription':
                'Edited scene ${(scene['pageIndex'] as num).toInt() + 1} description.',
          },
      ],
    );

    expect(imageBody?['prompt'],
        'Edited group prompt for confirmed image generation.');
    expect(imageBody?.containsKey('image'), isFalse);
    final pages = await DatabaseService.getPictureBookPages(articleId);
    expect(pages, hasLength(2));
    expect(pages.every((page) => page.status == 'ready'), isTrue);
    expect(pages.first.promptJson, contains('Edited scene 1 description.'));
    final updatedSeries = await DatabaseService.getStorySeriesById(series.id!);
    expect(updatedSeries?.description, contains('blue dress and white apron'));
  });

  test(
      'picture-book single-page prompt review opens from existing pages without AI',
      () async {
    _writeImageArkKey(tempDir, 'ark-page-local-key-12345678901234567890');
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Single Page Local Review Test',
        content:
            'Alice walks into the garden. The Queen points at the croquet ground.',
        sentences: const [
          'Alice walks into the garden.',
          'The Queen points at the croquet ground.',
        ],
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    var textAiCalls = 0;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        textAiCalls += 1;
        throw StateError('single-page prompt review should not call text AI');
      },
    );
    final referenceFile = File(
      '${tempDir.path}${Platform.pathSeparator}page-0-reference.png',
    )..writeAsBytesSync([137, 80, 78, 71, 61]);
    final targetFile = File(
      '${tempDir.path}${Platform.pathSeparator}page-1-target.png',
    )..writeAsBytesSync([137, 80, 78, 71, 62]);
    final now = DateTime(2026, 1, 1);
    await DatabaseService.upsertPictureBookPage(
      PictureBookPage(
        articleId: articleId,
        seriesId: series.id,
        pageIndex: 0,
        sentenceStartIndex: 0,
        sentenceEndIndex: 0,
        paragraphText: 'Alice walks into the garden.',
        promptJson: '{}',
        imagePath: referenceFile.path,
        status: 'ready',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await DatabaseService.upsertPictureBookPage(
      PictureBookPage(
        articleId: articleId,
        seriesId: series.id,
        pageIndex: 1,
        sentenceStartIndex: 1,
        sentenceEndIndex: 1,
        paragraphText: 'The Queen points at the croquet ground.',
        promptJson: jsonEncode({
          'chapterDescription': 'A royal garden croquet chapter.',
          'scene': {
            'sceneDescription':
                'The Queen points sternly across the croquet ground.',
          },
          'newCharacters': [
            {
              'name': 'The Queen',
              'description': 'A commanding royal figure.',
            },
          ],
        }),
        imagePath: targetFile.path,
        status: 'ready',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final review = await PictureBookService.pagePromptReviewPayload(
      article: article,
      chapter: chapter,
      pageIndex: 1,
    );

    expect(textAiCalls, 0);
    expect(review['mode'], 'singlePageEdit');
    expect(review['targetPageIndex'], 1);
    expect(review['referencePageIndex'], 1);
    expect(review['referencePageIndexes'], [1]);
    expect(review['referenceOptions'], [0, 1]);
    expect(review['chapterDescription'], 'A royal garden croquet chapter.');
    expect(review['scenes'], hasLength(1));
    expect((review['scenes'] as List).single['sceneDescription'],
        'The Queen points sternly across the croquet ground.');
    expect(review['groupPrompt'], '');
  });

  test('picture-book single-page prompt review replaces only target page',
      () async {
    _writeImageArkKey(tempDir, 'ark-page-review-key-12345678901234567890');
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Single Page Test',
        content:
            'Alice walks into the garden. The Queen points at the croquet ground.',
        sentences: const [
          'Alice walks into the garden.',
          'The Queen points at the croquet ground.',
        ],
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
      description:
          'Victorian fantasy picture book; Alice wears a blue dress and white apron.',
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    await _installTwoPageChapterPlanOverride();
    final referenceFile = File(
      '${tempDir.path}${Platform.pathSeparator}page-0-reference.png',
    )..writeAsBytesSync([137, 80, 78, 71, 51]);
    final now = DateTime(2026, 1, 1);
    await DatabaseService.upsertPictureBookPage(
      PictureBookPage(
        articleId: articleId,
        seriesId: series.id,
        pageIndex: 0,
        sentenceStartIndex: 0,
        sentenceEndIndex: 0,
        paragraphText: 'Alice walks into the garden.',
        promptJson: '{}',
        imagePath: referenceFile.path,
        status: 'ready',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await DatabaseService.upsertPictureBookPage(
      PictureBookPage(
        articleId: articleId,
        seriesId: series.id,
        pageIndex: 1,
        sentenceStartIndex: 1,
        sentenceEndIndex: 1,
        paragraphText: 'The Queen points at the croquet ground.',
        promptJson: '{}',
        imagePath: null,
        status: 'error',
        errorMessage: 'previous single-page failure',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final review = await PictureBookService.pagePromptReviewPayload(
      article: article,
      chapter: chapter,
      pageIndex: 1,
    );

    expect(review['mode'], 'singlePage');
    expect(review['targetPageIndex'], 1);
    expect(review['referencePageIndex'], 0);
    expect(review['referencePageIndexes'], [0]);
    expect(review['referenceOptions'], [0]);
    expect(review['scenes'], hasLength(1));
    expect((review['scenes'] as List).single['pageIndex'], 1);
    expect(review['groupPrompt'], contains('Generate exactly one picture'));
    expect(review['groupPrompt'], contains('Image 2:'));
    expect(review['groupPrompt'], isNot(contains('Image 1:')));

    Map<String, dynamic>? imageBody;
    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        imageBody = body;
        return {
          'data': [
            {
              'b64_json': base64Encode([137, 80, 78, 71, 53])
            },
          ],
        };
      },
    );

    await PictureBookService.confirmPagePromptReview(
      reviewId: review['reviewId'].toString(),
      groupPrompt: 'Edited single-page prompt for Image 2 only.',
      bookDescription: review['bookDescription'].toString(),
      bookCharacters: const [],
      newCharacters: const [],
      chapterDescription: review['chapterDescription'].toString(),
      scenes: [
        for (final scene in review['scenes'] as List)
          {
            ...Map<String, dynamic>.from(scene as Map),
            'sceneDescription': 'Edited only the Queen croquet scene.',
          },
      ],
    );

    expect(imageBody?['sequential_image_generation'], 'disabled');
    expect((imageBody?['image'] as List), hasLength(1));
    expect(imageBody?['prompt'], 'Edited single-page prompt for Image 2 only.');
    final pages = await DatabaseService.getPictureBookPages(articleId);
    expect(pages, hasLength(2));
    expect(pages[0].imagePath, referenceFile.path);
    expect(pages[0].status, 'ready');
    expect(pages[1].status, 'ready');
    expect(pages[1].promptJson, contains('singlePage'));
    expect(
        pages[1].promptJson, contains('Edited only the Queen croquet scene'));

    final updatedChapter =
        await DatabaseService.getStoryChapterForArticle(articleId);
    final summary = jsonDecode(updatedChapter!.summaryJson) as Map;
    final scenes = summary['scenes'] as List;
    expect(scenes, hasLength(2));
    expect(scenes.first['sceneDescription'], 'Alice walks into the garden.');
    expect(scenes.last['sceneDescription'],
        'Edited only the Queen croquet scene.');
  });

  test('picture-book single-page local edit uses instruction prompt', () async {
    _writeImageArkKey(tempDir, 'ark-page-edit-key-12345678901234567890');
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Single Page Local Edit Test',
        content:
            'Alice walks into the garden. The Queen points at the croquet ground.',
        sentences: const [
          'Alice walks into the garden.',
          'The Queen points at the croquet ground.',
        ],
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
      description:
          'Victorian fantasy picture book; Alice wears a blue dress and white apron.',
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    await _installTwoPageChapterPlanOverride();
    final referenceFile = File(
      '${tempDir.path}${Platform.pathSeparator}page-0-edit-ref.png',
    )..writeAsBytesSync([137, 80, 78, 71, 51]);
    final oldTargetFile = File(
      '${tempDir.path}${Platform.pathSeparator}page-1-edit-old.png',
    )..writeAsBytesSync([137, 80, 78, 71, 52]);
    final now = DateTime(2026, 1, 1);
    final originalChapter =
        await DatabaseService.getStoryChapterForArticle(articleId);
    final originalSummary = originalChapter!.summaryJson;
    await DatabaseService.upsertPictureBookPage(
      PictureBookPage(
        articleId: articleId,
        seriesId: series.id,
        pageIndex: 0,
        sentenceStartIndex: 0,
        sentenceEndIndex: 0,
        paragraphText: 'Alice walks into the garden.',
        promptJson: '{}',
        imagePath: referenceFile.path,
        status: 'ready',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await DatabaseService.upsertPictureBookPage(
      PictureBookPage(
        articleId: articleId,
        seriesId: series.id,
        pageIndex: 1,
        sentenceStartIndex: 1,
        sentenceEndIndex: 1,
        paragraphText: 'The Queen points at the croquet ground.',
        promptJson: '{}',
        imagePath: oldTargetFile.path,
        status: 'ready',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final review = await PictureBookService.pagePromptReviewPayload(
      article: article,
      chapter: chapter,
      pageIndex: 1,
    );

    expect(review['mode'], 'singlePageEdit');
    expect(review['referencePageIndex'], 1);
    expect(review['referencePageIndexes'], [1]);
    expect(review['groupPrompt'], '');

    Map<String, dynamic>? imageBody;
    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        imageBody = body;
        return {
          'data': [
            {
              'b64_json': base64Encode([137, 80, 78, 71, 53])
            },
          ],
        };
      },
    );

    await PictureBookService.confirmPagePromptReview(
      reviewId: review['reviewId'].toString(),
      groupPrompt: '将骑士的头盔变为金色，其余保持不变',
      bookDescription: 'should not rewrite book description',
      bookCharacters: const [],
      newCharacters: const [],
      chapterDescription: 'should not rewrite chapter description',
      referencePageIndexes: [1, 0],
      scenes: const [],
    );

    expect(imageBody?['sequential_image_generation'], 'disabled');
    expect((imageBody?['image'] as List), hasLength(2));
    expect(
      imageBody?['prompt'],
      'Edit the reference image(s). Keep everything else unchanged unless specified.\n'
      'Change: 将骑士的头盔变为金色，其余保持不变',
    );
    final pages = await DatabaseService.getPictureBookPages(articleId);
    expect(pages[0].imagePath, referenceFile.path);
    expect(pages[1].status, 'ready');
    expect(pages[1].imagePath, isNot(oldTargetFile.path));
    expect(pages[1].promptJson, contains('singlePageEdit'));
    expect(pages[1].promptJson, contains('将骑士的头盔变为金色'));
    final updatedChapter =
        await DatabaseService.getStoryChapterForArticle(articleId);
    expect(updatedChapter!.summaryJson, originalSummary);
    final updatedSeries = await DatabaseService.getStorySeriesById(series.id!);
    expect(
        updatedSeries!.description, contains('Victorian fantasy picture book'));
  });

  test(
      'picture-book single-page confirm honors multiple selected reference pages',
      () async {
    _writeImageArkKey(tempDir, 'ark-page-refpick-key-12345678901234567890');
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Single Page Reference Pick Test',
        content:
            'Alice walks into the garden. The Queen points at the croquet ground. Alice leaves the garden.',
        sentences: const [
          'Alice walks into the garden.',
          'The Queen points at the croquet ground.',
          'Alice leaves the garden.',
        ],
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    final page0File = File(
      '${tempDir.path}${Platform.pathSeparator}page-0-refpick.png',
    )..writeAsBytesSync([137, 80, 78, 71, 48]);
    final page1File = File(
      '${tempDir.path}${Platform.pathSeparator}page-1-refpick.png',
    )..writeAsBytesSync([137, 80, 78, 71, 49]);
    final page2File = File(
      '${tempDir.path}${Platform.pathSeparator}page-2-refpick.png',
    )..writeAsBytesSync([137, 80, 78, 71, 50]);
    final now = DateTime(2026, 1, 1);
    for (final entry in [
      (0, 0, 0, 'Alice walks into the garden.', page0File.path),
      (1, 1, 1, 'The Queen points at the croquet ground.', page1File.path),
      (2, 2, 2, 'Alice leaves the garden.', page2File.path),
    ]) {
      await DatabaseService.upsertPictureBookPage(
        PictureBookPage(
          articleId: articleId,
          seriesId: series.id,
          pageIndex: entry.$1,
          sentenceStartIndex: entry.$2,
          sentenceEndIndex: entry.$3,
          paragraphText: entry.$4,
          promptJson: '{}',
          imagePath: entry.$5,
          status: 'ready',
          createdAt: now,
          updatedAt: now,
        ),
      );
    }

    final review = await PictureBookService.pagePromptReviewPayload(
      article: article,
      chapter: chapter,
      pageIndex: 2,
    );

    expect(review['mode'], 'singlePageEdit');
    expect(review['targetPageIndex'], 2);
    expect(review['referenceOptions'], [0, 1, 2]);
    expect(review['referencePageIndex'], 2);
    expect(review['referencePageIndexes'], [2]);

    Map<String, dynamic>? imageBody;
    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        imageBody = body;
        return {
          'data': [
            {
              'b64_json': base64Encode([137, 80, 78, 71, 51])
            },
          ],
        };
      },
    );

    await PictureBookService.confirmPagePromptReview(
      reviewId: review['reviewId'].toString(),
      groupPrompt: '把背景换成黄昏天空，角色保持不变',
      bookDescription: review['bookDescription'].toString(),
      bookCharacters: const [],
      newCharacters: const [],
      chapterDescription: review['chapterDescription'].toString(),
      referencePageIndexes: [0, 1],
      scenes: [
        for (final scene in review['scenes'] as List)
          Map<String, dynamic>.from(scene as Map),
      ],
    );

    final referenceDataUris = (imageBody?['image'] as List).cast<String>();
    expect(referenceDataUris, hasLength(2));
    expect(
      imageBody?['prompt'],
      contains('Change: 把背景换成黄昏天空，角色保持不变'),
    );
    expect(
      referenceDataUris[0],
      contains(base64Encode([137, 80, 78, 71, 48])),
    );
    expect(
      referenceDataUris[1],
      contains(base64Encode([137, 80, 78, 71, 49])),
    );
    final pages = await DatabaseService.getPictureBookPages(articleId);
    final savedPrompt = jsonDecode(pages[2].promptJson) as Map<String, dynamic>;
    expect(savedPrompt['mode'], 'singlePageEdit');
    expect(savedPrompt['referencePageIndexes'], [0, 1]);
    expect(savedPrompt['referencePageIndex'], 0);
  });

  test('picture-book single-page confirm accepts target page as reference',
      () async {
    _writeImageArkKey(tempDir, 'ark-page-self-ref-key-12345678901234567890');
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Single Page Self Reference Test',
        content:
            'Alice walks into the garden. The Queen points at the croquet ground. Alice leaves the garden.',
        sentences: const [
          'Alice walks into the garden.',
          'The Queen points at the croquet ground.',
          'Alice leaves the garden.',
        ],
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    await _installTwoPageChapterPlanOverride();
    final page2File = File(
      '${tempDir.path}${Platform.pathSeparator}page-2-self-ref.png',
    )..writeAsBytesSync([137, 80, 78, 71, 50]);
    final now = DateTime(2026, 1, 1);
    for (final entry in [
      (0, 0, 0, 'Alice walks into the garden.', null),
      (1, 1, 1, 'The Queen points at the croquet ground.', null),
      (2, 2, 2, 'Alice leaves the garden.', page2File.path),
    ]) {
      await DatabaseService.upsertPictureBookPage(
        PictureBookPage(
          articleId: articleId,
          seriesId: series.id,
          pageIndex: entry.$1,
          sentenceStartIndex: entry.$2,
          sentenceEndIndex: entry.$3,
          paragraphText: entry.$4,
          promptJson: '{}',
          imagePath: entry.$5,
          status: entry.$5 == null ? 'pending' : 'ready',
          createdAt: now,
          updatedAt: now,
        ),
      );
    }

    final review = await PictureBookService.pagePromptReviewPayload(
      article: article,
      chapter: chapter,
      pageIndex: 2,
    );

    expect(review['referenceOptions'], [2]);
    expect(review['mode'], 'singlePageEdit');
    expect(review['referencePageIndex'], 2);

    Map<String, dynamic>? imageBody;
    VolcImageService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        imageBody = body;
        return {
          'data': [
            {
              'b64_json': base64Encode([137, 80, 78, 71, 51])
            },
          ],
        };
      },
    );

    await PictureBookService.confirmPagePromptReview(
      reviewId: review['reviewId'].toString(),
      groupPrompt: '修正手指数量，其余保持不变',
      bookDescription: review['bookDescription'].toString(),
      bookCharacters: const [],
      newCharacters: const [],
      chapterDescription: review['chapterDescription'].toString(),
      referencePageIndexes: [2],
      scenes: [
        for (final scene in review['scenes'] as List)
          Map<String, dynamic>.from(scene as Map),
      ],
    );

    final referenceDataUris = (imageBody?['image'] as List).cast<String>();
    expect(referenceDataUris, hasLength(1));
    expect(
      referenceDataUris.single,
      contains(base64Encode([137, 80, 78, 71, 50])),
    );
    expect(
      imageBody?['prompt'],
      'Edit the reference image(s). Keep everything else unchanged unless specified.\n'
      'Change: 修正手指数量，其余保持不变',
    );
  });

  test('picture-book single-page review falls back to group when no reference',
      () async {
    _writeImageArkKey(tempDir, 'ark-page-fallback-key-12345678901234567890');
    final articleId = await DatabaseService.saveArticle(
      Article(
        title: 'Single Page Fallback Test',
        content:
            'Alice walks into the garden. The Queen points at the croquet ground.',
        sentences: const [
          'Alice walks into the garden.',
          'The Queen points at the croquet ground.',
        ],
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    final article = await DatabaseService.getArticleById(articleId);
    final series = await PictureBookService.createSeries(
      title: "Alice's Adventures in Wonderland",
    );
    final chapter = await PictureBookService.ensureChapterForArticle(
      seriesId: series.id!,
      article: article!,
    );
    await _installTwoPageChapterPlanOverride();

    final review = await PictureBookService.pagePromptReviewPayload(
      article: article,
      chapter: chapter,
      pageIndex: 1,
    );

    expect(review['mode'], 'group');
    expect(review['regenerate'], isTrue);
    expect(review['scenes'], hasLength(2));
    expect(review.containsKey('targetPageIndex'), isFalse);
    expect(review.containsKey('referencePageIndex'), isFalse);
  });

  test('picture-book cover payload uses the first ready generated image',
      () async {
    final articleId = await _saveArticle('Mia opens a map and smiles.');
    final imageFile = await _writeTestPng(
      tempDir,
      'cover.png',
      width: 1280,
      height: 720,
    );
    final originalDataUri =
        'data:image/png;base64,${base64Encode(await imageFile.readAsBytes())}';
    final now = DateTime(2026, 1, 1);

    await DatabaseService.upsertPictureBookPage(
      PictureBookPage(
        articleId: articleId,
        pageIndex: 0,
        sentenceStartIndex: 0,
        sentenceEndIndex: 0,
        paragraphText: 'Mia opens a map and smiles.',
        promptJson: '{}',
        imagePath: imageFile.path,
        status: 'ready',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final payload = await PictureBookService.coverImagePayloadForArticle(
      articleId,
    );

    expect(payload, isNotNull);
    expect(payload?['coverImagePath'], imageFile.path);
    expect(payload?['coverImageVariant'], 'thumbnail');
    expect(
      payload?['coverImageUri']?.toString(),
      startsWith('data:image/png;base64,'),
    );
    expect(payload?['coverImageUri'], isNot(originalDataUri));

    final thumbnailDirectory =
        await ApiCacheService.cacheDirectory('picture_book_thumbnails');
    final thumbnails = await thumbnailDirectory
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.png'))
        .toList();
    expect(thumbnails, hasLength(1));
  });

  test(
      'picture-book importPageImage replaces page with native 2560x1440 png',
      () async {
    final articleId = await _saveArticle('Mia opens a map and smiles.');
    final series = await PictureBookService.createSeries(title: 'Import Book');
    final now = DateTime(2026, 7, 21);
    final oldFile = await _writeTestPng(
      tempDir,
      'old-page.png',
      width: 640,
      height: 360,
    );
    final oldCacheKey = await ApiCacheService.keyForJson(
      'picture_book_old',
      {'articleId': articleId, 'pageIndex': 0},
    );
    final oldCachedPath = await ApiCacheService.putFileBytes(
      cacheKey: oldCacheKey,
      kind: 'file',
      purpose: 'picture_book_image',
      request: {'kind': 'old'},
      bytes: await oldFile.readAsBytes(),
      subdirectory: 'picture_book',
      extension: 'png',
      contentType: 'image/png',
      articleId: articleId,
    );
    await DatabaseService.upsertPictureBookPage(
      PictureBookPage(
        articleId: articleId,
        seriesId: series.id,
        pageIndex: 0,
        sentenceStartIndex: 0,
        sentenceEndIndex: 0,
        paragraphText: 'Mia opens a map and smiles.',
        promptJson: '{"scene":{"sceneDescription":"Mia opens a map."}}',
        imageCacheKey: oldCacheKey,
        imagePath: oldCachedPath,
        status: 'error',
        errorMessage: 'previous generate failed',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final sourceFile = await _writeTestPng(
      tempDir,
      'import-source.png',
      width: 800,
      height: 600,
    );

    final state = await PictureBookService.importPageImage(
      articleId: articleId,
      pageIndex: 0,
      sourcePath: sourceFile.path,
    );

    expect(state['status'], 'ready');
    final pages = state['pages'] as List;
    expect(pages, hasLength(1));
    final page = pages.single as Map;
    expect(page['status'], 'ready');
    expect(page['errorMessage'], anyOf(isNull, isEmpty));
    final importedPath = (page['imagePath'] as String?)?.trim() ?? '';
    expect(importedPath, isNotEmpty);
    expect(await File(importedPath).exists(), isTrue);
    expect(importedPath, isNot(oldCachedPath));
    expect(await File(oldCachedPath).exists(), isFalse);

    final importedBytes = await File(importedPath).readAsBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(
      Uint8List.fromList(importedBytes),
    );
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      expect(descriptor.width, 2560);
      expect(descriptor.height, 1440);
    } finally {
      descriptor.dispose();
      buffer.dispose();
    }

    final dbPages = await DatabaseService.getPictureBookPages(articleId);
    expect(dbPages.single.status, 'ready');
    expect(dbPages.single.imageCacheKey, isNot(oldCacheKey));
    expect(
      dbPages.single.promptJson,
      contains('Mia opens a map.'),
    );
  });

  test(
      'picture-book importPageImage keeps exact 2560x1440 bytes without re-encode',
      () async {
    final articleId = await _saveArticle('Mia opens a map and smiles.');
    final series = await PictureBookService.createSeries(title: 'Import Exact');
    final now = DateTime(2026, 7, 21);
    await DatabaseService.upsertPictureBookPage(
      PictureBookPage(
        articleId: articleId,
        seriesId: series.id,
        pageIndex: 0,
        sentenceStartIndex: 0,
        sentenceEndIndex: 0,
        paragraphText: 'Mia opens a map and smiles.',
        promptJson: '{}',
        status: 'error',
        errorMessage: 'missing',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final sourceFile = await _writeTestPng(
      tempDir,
      'exact-full.png',
      width: 2560,
      height: 1440,
    );
    final sourceBytes = await sourceFile.readAsBytes();

    final state = await PictureBookService.importPageImage(
      articleId: articleId,
      pageIndex: 0,
      sourcePath: sourceFile.path,
    );

    final page = (state['pages'] as List).single as Map;
    final importedPath = (page['imagePath'] as String?)?.trim() ?? '';
    expect(importedPath, endsWith('.png'));
    expect(await File(importedPath).readAsBytes(), sourceBytes);
  });

  test('picture-book exportChapterImages writes scene files and resolves conflicts',
      () async {
    final articleId = await _saveArticle('Mia opens a map and smiles.');
    final series = await PictureBookService.createSeries(title: 'Export Book');
    final now = DateTime(2026, 7, 21);
    final page0 = await _writeTestPng(
      tempDir,
      'export-page-0.png',
      width: 320,
      height: 180,
    );
    final page1 = await _writeTestPng(
      tempDir,
      'export-page-1.png',
      width: 320,
      height: 180,
    );
    await DatabaseService.upsertPictureBookPage(
      PictureBookPage(
        articleId: articleId,
        seriesId: series.id,
        pageIndex: 0,
        sentenceStartIndex: 0,
        sentenceEndIndex: 0,
        paragraphText: 'Mia opens a map and smiles.',
        promptJson: '{}',
        imagePath: page0.path,
        status: 'ready',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await DatabaseService.upsertPictureBookPage(
      PictureBookPage(
        articleId: articleId,
        seriesId: series.id,
        pageIndex: 1,
        sentenceStartIndex: 0,
        sentenceEndIndex: 0,
        paragraphText: 'Mia opens a map and smiles.',
        promptJson: '{}',
        imagePath: page1.path,
        status: 'ready',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await DatabaseService.upsertPictureBookPage(
      PictureBookPage(
        articleId: articleId,
        seriesId: series.id,
        pageIndex: 2,
        sentenceStartIndex: 0,
        sentenceEndIndex: 0,
        paragraphText: 'Mia opens a map and smiles.',
        promptJson: '{}',
        status: 'error',
        errorMessage: 'failed',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final exportDir =
        Directory(path_lib.join(tempDir.path, 'chapter-export'))
          ..createSync(recursive: true);
    await File(path_lib.join(exportDir.path, '01.png'))
        .writeAsBytes([1, 2, 3], flush: true);

    final conflict = await PictureBookService.exportChapterImages(
      articleId: articleId,
      outputDirectory: exportDir.path,
    );
    expect(conflict['needsConflictResolution'], isTrue);
    expect(conflict['exportedCount'], 0);
    expect(
      (conflict['conflicts'] as List)
          .map((item) => (item as Map)['fileName'])
          .toList(),
      contains('01.png'),
    );
    expect(await File(path_lib.join(exportDir.path, '02.png')).exists(), isFalse);

    final renamed = await PictureBookService.exportChapterImages(
      articleId: articleId,
      outputDirectory: exportDir.path,
      namePrefix: 'v2_',
    );
    expect(renamed['needsConflictResolution'], isFalse);
    expect(renamed['exportedCount'], 2);
    expect(renamed['files'], ['v2_01.png', 'v2_02.png']);
    expect(await File(path_lib.join(exportDir.path, 'v2_01.png')).exists(), isTrue);
    expect(await File(path_lib.join(exportDir.path, 'v2_02.png')).exists(), isTrue);

    final overwritten = await PictureBookService.exportChapterImages(
      articleId: articleId,
      outputDirectory: exportDir.path,
      overwrite: true,
    );
    expect(overwritten['exportedCount'], 2);
    expect(overwritten['files'], ['01.png', '02.png']);
    final overwrittenBytes =
        await File(path_lib.join(exportDir.path, '01.png')).readAsBytes();
    expect(overwrittenBytes, isNot([1, 2, 3]));
  });
}

Future<int> _saveArticle(String content, {List<String>? sentences}) {
  return DatabaseService.saveArticle(
    Article(
      title: 'Test',
      content: content,
      sentences: sentences ?? [content],
      createdAt: DateTime(2026, 1, 1),
    ),
  );
}

Future<String> _writeCachedListeningTts({
  required int articleId,
  required String text,
  required List<int> bytes,
  String purpose = ListeningAudioMaterialService.cachePurpose,
}) async {
  final keys = await TtsService.cacheKeysForText(
    text: text,
    cachePurpose: purpose,
  );
  expect(keys, isNotEmpty);
  final cacheKey = keys.first;
  return ApiCacheService.putFileBytes(
    cacheKey: cacheKey,
    kind: 'tts',
    purpose: purpose,
    request: {'service': 'unit_tts', 'text': text, 'purpose': purpose},
    bytes: bytes,
    subdirectory: 'tts',
    extension: 'mp3',
    contentType: 'audio/mpeg',
    articleId: articleId,
  );
}

Future<String> _writeHistoricalListeningTts({
  required int articleId,
  required String text,
  required Map<String, dynamic> request,
  required List<int> bytes,
  String purpose = ListeningAudioMaterialService.cachePurpose,
}) async {
  final requestWithText = {...request, 'text': text};
  final cacheKey = await ApiCacheService.keyForJson('tts', requestWithText);
  return ApiCacheService.putFileBytes(
    cacheKey: cacheKey,
    kind: 'tts',
    purpose: purpose,
    request: requestWithText,
    bytes: bytes,
    subdirectory: 'tts',
    extension: 'mp3',
    contentType: 'audio/mpeg',
    articleId: articleId,
  );
}

Future<File> _writeTestPng(
  Directory directory,
  String name, {
  required int width,
  required int height,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFF6B35),
  );
  canvas.drawCircle(
    ui.Offset(width * 0.32, height * 0.45),
    height * 0.22,
    ui.Paint()..color = const ui.Color(0xFFFFD54F),
  );
  canvas.drawRect(
    ui.Rect.fromLTWH(width * 0.55, height * 0.18, width * 0.3, height * 0.5),
    ui.Paint()..color = const ui.Color(0xFF1A237E),
  );

  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = byteData?.buffer.asUint8List();
    if (bytes == null || bytes.isEmpty) {
      throw StateError('Failed to create test PNG bytes');
    }
    final file = File(path_lib.join(directory.path, name));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void _writeImageArkKey(Directory _, String key) {
  AppConfig.setRuntimeConfigForTest(
    aiProvider: AppConfig.aiProviderVolcengine,
    volcArkApiKey: key,
  );
}

void _expectNoDialogueSummaryWords(String text) {
  final lower = text.toLowerCase();
  const forbidden = [
    'exchange',
    'conversation',
    'discuss',
    'debate',
    'ask',
    'answer',
    'question',
    'reply',
    'remark',
    'riddle',
    'argue',
    'claim',
    'mean',
    'say',
    'said',
    'offer',
  ];
  for (final word in forbidden) {
    expect(
      lower,
      isNot(matches(RegExp('\\b${RegExp.escape(word)}\\b'))),
      reason: 'scene text should not reintroduce dialogue summary word "$word"',
    );
  }
}

Future<void> _installTwoPageChapterPlanOverride() async {
  TextGenerationService.setPostOverrideForTest(
    ({required endpoint, required headers, required body}) async {
      return {
        'choices': [
          {
            'message': {
              'content': jsonEncode({
                'planKind': 'picture_book_chapter_scene_plan_v2',
                'chapterDescription':
                    'Alice, a curious Victorian girl in a blue dress and white apron, enters a whimsical royal garden and meets the Queen on the croquet-ground in two connected storybook scenes.',
                'scenes': [
                  {
                    'pageIndex': 0,
                    'sentenceStartIndex': 0,
                    'sentenceEndIndex': 0,
                    'sceneDescription': 'Alice walks into the garden.',
                  },
                  {
                    'pageIndex': 1,
                    'sentenceStartIndex': 1,
                    'sentenceEndIndex': 1,
                    'sceneDescription':
                        'The Queen points at the croquet ground.',
                  },
                ],
              }),
            },
          }
        ],
      };
    },
  );
}

Future<Map<String, dynamic>> _refreshChapterPlanFromReview(
  Map<String, dynamic> review,
) {
  return PictureBookService.refreshPromptReview(
    reviewId: review['reviewId'].toString(),
    target: 'chapterPlan',
    bookDescription: review['bookDescription']?.toString() ?? '',
    bookCharacters: _charactersFromPayload(review['bookCharacters']),
    newCharacters: _charactersFromPayload(review['newCharacters']),
    chapterDescription: review['chapterDescription']?.toString() ?? '',
    scenes: [
      for (final scene in (review['scenes'] as List? ?? const []))
        Map<String, dynamic>.from(scene as Map),
    ],
  );
}

List<BookCharacter> _charactersFromPayload(Object? raw) {
  if (raw is! List) {
    return const [];
  }
  return raw
      .map(BookCharacter.fromJson)
      .where(
        (item) =>
            item.name.trim().isNotEmpty && item.description.trim().isNotEmpty,
      )
      .toList(growable: false);
}
