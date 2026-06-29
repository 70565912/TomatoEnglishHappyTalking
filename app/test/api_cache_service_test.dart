import 'dart:convert';
import 'dart:io';
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
    final articleId = await _saveArticle('Tom waves. He smiles.');
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

  test(
      'listening audio material keeps old platform voice and split chunks usable',
      () async {
    const sentence = 'Tom waves and smiles, then he runs to the garden.';
    final articleId = await _saveArticle(sentence);
    final firstPath = await _writeHistoricalCachedTts(
      articleId: articleId,
      text: 'Tom waves and smiles,',
      purpose: ListeningAudioMaterialService.cachePurpose,
      request: {
        'service': 'aliyun_cosyvoice',
        'voice': 'loongabby_v3',
        'text': 'Tom waves and smiles,',
      },
      bytes: [1, 2, 3],
    );
    final secondPath = await _writeHistoricalCachedTts(
      articleId: articleId,
      text: 'then he runs to the garden.',
      purpose: ListeningAudioMaterialService.legacyFollowCachePurpose,
      request: {
        'service': 'doubao_tts_2',
        'speaker': 'zh_female_vv_uranus_bigtts',
        'text': 'then he runs to the garden.',
      },
      bytes: [4, 5, 6],
    );

    final status = await ListeningAudioMaterialService.status(articleId);
    final handles = await ListeningAudioMaterialService.cachedFileHandles(
      articleId: articleId,
      text: sentence,
    );
    final generate = await ListeningAudioMaterialService.generate(
      articleId: articleId,
      overwrite: false,
    );

    expect(status.total, 1);
    expect(status.ready, 1);
    expect(status.missing, isEmpty);
    expect(handles.map((handle) => handle.filePath), [firstPath, secondPath]);
    expect(generate.requested, 0);
    expect(generate.ready, 1);
  });

  test('article translations survive sentence chunk changes', () async {
    const sentence = 'Tom waves and smiles, then he runs to the garden.';
    final articleId = await _saveArticle(sentence);
    final now = DateTime(2026, 1, 1);
    await DatabaseService.saveArticleSentenceTranslations(articleId, [
      ArticleSentenceTranslation(
        articleId: articleId,
        sentenceIndex: 0,
        englishSentence: 'Tom waves and smiles,',
        chineseText: '汤姆挥手微笑，',
        source: 'imported',
        createdAt: now,
        updatedAt: now,
      ),
      ArticleSentenceTranslation(
        articleId: articleId,
        sentenceIndex: 1,
        englishSentence: 'then he runs to the garden.',
        chineseText: '然后他跑向花园。',
        source: 'imported',
        createdAt: now,
        updatedAt: now,
      ),
    ]);

    final batch =
        await DatabaseService.getArticleSentenceTranslationsForSentences(
      articleId: articleId,
      sentences: [sentence],
    );
    final single = await DatabaseService.getArticleSentenceTranslation(
      articleId,
      0,
      sentence,
    );

    expect(batch, {0: '汤姆挥手微笑，然后他跑向花园。'});
    expect(single, '汤姆挥手微笑，然后他跑向花园。');
  });

  test(
      'listening audio material generation fills missing and overwrites caches',
      () async {
    final articleId = await _saveArticle('Tom waves. He smiles.');
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
      contains('main visual story beats of the chapter'),
    );
    expect(
      planningPrompt,
      contains('numbered sentences are coverage anchors'),
    );
    expect(
      planningPrompt,
      contains('not scene candidates'),
    );
    expect(
      planningPrompt,
      contains('compact but complete set of illustrations'),
    );
    expect(
      planningPrompt,
      contains('balance compactness and completeness'),
    );
    expect(
      planningPrompt,
      contains('avoid over-merging unrelated phases'),
    );
    expect(
      planningPrompt,
      contains('avoid over-splitting consecutive beats'),
    );
    expect(
      planningPrompt,
      contains('do not decide the scene count from text length'),
    );
    expect(
      planningPrompt,
      contains('extreme upper bound, not a target'),
    );
    expect(
      planningPrompt,
      contains('genuinely different visual beats'),
    );
    expect(
      planningPrompt,
      contains('a scene boundary is valid only when'),
    );
    expect(
      planningPrompt,
      contains('clear visual boundary reason'),
    );
    expect(
      planningPrompt,
      contains('location change, time jump, main character group change'),
    );
    expect(
      planningPrompt,
      contains(
          'story purpose change, major visible state change, or an action result'),
    );
    expect(
      planningPrompt,
      contains(
          'create a new scene only when the main visual story beat changes for one of those visual boundary reasons'),
    );
    expect(
      planningPrompt,
      contains('use the smallest complete scene set'),
    );
    expect(
      planningPrompt,
      contains('continuous action chain in one location'),
    );
    expect(
      planningPrompt,
      contains('same location, same character group, and same story purpose'),
    );
    expect(
      planningPrompt,
      contains('non-composable visual change'),
    );
    expect(
      planningPrompt,
      contains(
          'not from narration order, dialogue turns, or small sequential steps'),
    );
    expect(
      planningPrompt,
      contains(
          'one coherent composition with foreground and background action'),
    );
    expect(
      planningPrompt,
      contains('one dominant drawable composition'),
    );
    expect(
      planningPrompt,
      contains('not a sequence of separate visible states'),
    );
    expect(
      planningPrompt,
      contains('do not split narrative micro-phases'),
    );
    expect(
      planningPrompt,
      contains('same immediate visual outcome'),
    );
    expect(
      planningPrompt,
      contains('a boundary is weak when neighboring parts share'),
    );
    expect(
      planningPrompt,
      contains('one stable composition'),
    );
    expect(
      planningPrompt,
      contains('dialogue turns, decision steps, brief responses'),
    );
    expect(
      planningPrompt,
      contains('not scene boundaries unless they create a new'),
    );
    expect(
      planningPrompt,
      contains('do not merge distant story phases only to reduce the count'),
    );
    expect(
      planningPrompt,
      contains('brief visible transitions still deserve their own scene'),
    );
    expect(
      planningPrompt,
      contains('run the final audit in this order'),
    );
    expect(
      planningPrompt,
      contains(
          'split any scene that mixes multiple non-composable compositions'),
    );
    expect(
      planningPrompt,
      contains('merge neighboring scenes whose boundary is only'),
    );
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
    expect(review['mode'], 'singlePage');
    expect(review['targetPageIndex'], 1);
    expect(review['referencePageIndex'], 0);
    expect(review['chapterDescription'], 'A royal garden croquet chapter.');
    expect(review['scenes'], hasLength(1));
    expect((review['scenes'] as List).single['sceneDescription'],
        'The Queen points sternly across the croquet ground.');
    expect(review['groupPrompt'],
        contains('The Queen points sternly across the croquet ground.'));
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
    final oldTargetFile = File(
      '${tempDir.path}${Platform.pathSeparator}page-1-old.png',
    )..writeAsBytesSync([137, 80, 78, 71, 52]);
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

    expect(review['mode'], 'singlePage');
    expect(review['targetPageIndex'], 1);
    expect(review['referencePageIndex'], 0);
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
    expect(pages[1].imagePath, isNot(oldTargetFile.path));
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
}

Future<int> _saveArticle(String content) {
  return DatabaseService.saveArticle(
    Article(
      title: 'Test',
      content: content,
      sentences: [content],
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

Future<String> _writeHistoricalCachedTts({
  required int articleId,
  required String text,
  required String purpose,
  required Map<String, dynamic> request,
  required List<int> bytes,
}) async {
  final cacheKey = await ApiCacheService.keyForJson('tts', request);
  return ApiCacheService.putFileBytes(
    cacheKey: cacheKey,
    kind: 'tts',
    purpose: purpose,
    request: {
      ...request,
      'text': text,
    },
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
