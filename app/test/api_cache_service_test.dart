import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path_lib;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/data/models/picture_book_model.dart';
import 'package:tomato_english_happy_talking/services/api_cache_service.dart';
import 'package:tomato_english_happy_talking/services/aliyun_wanx_image_service.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/picture_book_image_service.dart';
import 'package:tomato_english_happy_talking/services/picture_book_service.dart';
import 'package:tomato_english_happy_talking/services/text_generation_service.dart';
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
    AppConfig.resetRuntimeConfigForTest();
  });

  tearDown(() async {
    TextGenerationService.setPostOverrideForTest(null);
    AliyunWanxImageService.setOverridesForTest();
    VolcImageService.setPostOverrideForTest(null);
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
    expect(tableNames, contains('content_safety_failures'));
    expect(tableNames, contains('content_safety_rules'));
    expect(tableNames, isNot(contains('story_reference_assets')));
    final seriesColumns = await db.rawQuery('PRAGMA table_info(story_series)');
    final seriesColumnNames = seriesColumns.map((row) => row['name']).toSet();
    expect(seriesColumnNames, contains('description'));
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

  test(
      'suggests draft book description with local fallback when Ark key is missing',
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
    final chapter = StoryChapter(
      seriesId: 0,
      articleId: 0,
      chapterOrder: 1,
      chapterTitle: article.title,
      summaryJson: '{}',
      createdAt: now,
      updatedAt: now,
    );

    final description = await PictureBookService.suggestBookDescription(
      article: article,
      chapter: chapter,
      seriesTitle: 'Lily Garden',
    );

    expect(textCalled, isFalse);
    expect(description, contains('Lily Garden'));
    expect(description, contains('picture-book world'));
    expect(description, contains('Lily opens a little green gate'));
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
                  'planKind': 'picture_book_chapter_plan_v4',
                  'storyBrief':
                      'Alice is a curious Victorian girl in a blue dress and white apron.',
                  'chapterBrief':
                      'Alice meets the Queen on the croquet-ground.',
                  'scenes': [
                    {
                      'pageIndex': 0,
                      'sentenceStartIndex': 0,
                      'sentenceEndIndex': 0,
                      'title': 'Alice Enters',
                      'story': 'Alice walks into the garden.',
                      'visual':
                          'Alice in the same blue dress enters a royal garden.',
                    },
                    {
                      'pageIndex': 1,
                      'sentenceStartIndex': 1,
                      'sentenceEndIndex': 1,
                      'title': 'Queen Points',
                      'story': 'The Queen points ahead.',
                      'visual':
                          'Alice in the same blue dress watches the Queen point.',
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
    expect(planningPrompt, contains('storybrief'));
    expect(planningPrompt, contains('chapterbrief'));
    expect(planningPrompt, contains('scenes'));
    expect(planningPrompt, contains('victorian fantasy picture book'));
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
    expect(pages.first.promptJson, contains('same blue dress'));
    final updatedChapter =
        await DatabaseService.getStoryChapterForArticle(articleId);
    expect(
        updatedChapter?.summaryJson, contains('picture_book_chapter_plan_v4'));
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
    expect(
      (seenBody?['prompt'] as String),
      contains('match the assigned scene action'),
    );
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
    expect(seenBody?['parameters'], containsPair('size', '2K'));
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
                  'planKind': 'picture_book_chapter_plan_v4',
                  'storyBrief':
                      'Alice joins a whimsical outdoor tea-party world.',
                  'chapterBrief':
                      'Alice watches the March Hare, Hatter, and Dormouse around the same tea table.',
                  'scenes': [
                    {
                      'pageIndex': 0,
                      'sentenceStartIndex': 0,
                      'sentenceEndIndex': 2,
                      'title': 'Alice arrives',
                      'story': 'Alice sits near the tea table.',
                      'visual':
                          'Alice approaches the March Hare and Hatter at the tea table.',
                    },
                    {
                      'pageIndex': 1,
                      'sentenceStartIndex': 3,
                      'sentenceEndIndex': 5,
                      'title': 'The table continues',
                      'story':
                          'The Hatter lifts a cup while the Dormouse sleeps.',
                      'visual':
                          'The Hatter lifts a cup and the Dormouse sleeps beside the same table.',
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

  test('picture-book image prompt allows natural story-world text', () {
    final prompt = PictureBookService.imagePromptForTest({
      'scene': {
        'title': 'Glowing Map',
        'story': 'A girl smiles over a glowing map.',
        'visual':
            'A girl smiles over a glowing map in a warm bedroom picture-book scene, enough open clean space at the bottom edge for app-rendered subtitles.',
      },
    });
    final lower = prompt.toLowerCase();

    expect(prompt, contains('natural scene composition'));
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

    expect(prompt, contains('Generate a coherent sequence of full-frame 16:9'));
    expect(prompt, contains('match the assigned scene action'));
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
        'title': 'Moonlit Gate',
        'story': 'A boy opens a gate into a quiet moonlit garden.',
        'visual': 'A boy opens a gate into a quiet moonlit garden.',
      },
    });

    expect(prompt, contains('moonlit garden'));
    expect(prompt, isNot(contains('Alice is always')));
    expect(prompt, isNot(contains('Wonderland')));
  });

  test('picture-book image prompt softens unsafe classic story threats', () {
    final prompt = PictureBookService.imagePromptForTest({
      'scene': {
        'title': 'Queen Shouts',
        'story': 'Alice hears that the Duchess is under sentence of execution.',
        'visual':
            'The Queen shouts "Off with her head!" while players are fighting for hedgehogs.',
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
    await _installTwoPageChapterPlanOverride();
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
    expect(review['groupPrompt']?.toString(), contains('Image 1:'));
    expect(review['bookDescription'], isA<String>());
    expect(review['storyBrief'], contains('Alice'));
    expect(review['chapterBrief'], contains('Queen'));
    expect(review['scenes'], isA<List>());
    expect(review.containsKey('characterCards'), isFalse);
    expect(review.containsKey('referenceAssets'), isFalse);
    expect(review.containsKey('styleGuide'), isFalse);
    expect(imageCalls, 0);
    final pages = await DatabaseService.getPictureBookPages(articleId);
    expect(pages, hasLength(1));
    expect(pages.single.paragraphText, 'Old page');
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
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        textCalls += 1;
        if (textCalls == 1) {
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
                  'storyBrief':
                      'Refreshed Alice story world with a consistent blue dress and garden mood.',
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
      bookDescription: 'Victorian watercolor Alice picture book.',
      storyBrief: review['storyBrief'].toString(),
      chapterBrief: review['chapterBrief'].toString(),
      scenes: [
        for (final scene in review['scenes'] as List)
          Map<String, dynamic>.from(scene as Map),
      ],
    );

    expect(refreshedBook['bookDescription'], contains('white pinafore'));
    expect(refreshedBook['groupPrompt'], contains('white pinafore'));
    expect(refreshedBook['refreshedTarget'], 'bookDescription');

    final refreshed = await PictureBookService.refreshPromptReview(
      reviewId: review['reviewId'].toString(),
      target: 'storyBrief',
      bookDescription: refreshedBook['bookDescription'].toString(),
      storyBrief: refreshedBook['storyBrief'].toString(),
      chapterBrief: refreshedBook['chapterBrief'].toString(),
      scenes: [
        for (final scene in refreshedBook['scenes'] as List)
          Map<String, dynamic>.from(scene as Map),
      ],
    );

    expect(refreshed['storyBrief'], contains('Refreshed Alice story world'));
    expect(refreshed['bookDescription'], contains('Victorian watercolor'));
    expect(refreshed['groupPrompt'], contains('Refreshed Alice story world'));
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
      storyBrief: review['storyBrief'].toString(),
      chapterBrief: review['chapterBrief'].toString(),
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
    final review = await PictureBookService.promptReviewPayload(
      article: article,
      chapter: chapter,
    );
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
      storyBrief: review['storyBrief'].toString(),
      chapterBrief: review['chapterBrief'].toString(),
      scenes: [
        for (final scene in review['scenes'] as List)
          {
            ...Map<String, dynamic>.from(scene as Map),
            'visual':
                'Edited scene ${(scene['pageIndex'] as num).toInt() + 1} visual.',
          },
      ],
    );

    expect(imageBody?['prompt'],
        'Edited group prompt for confirmed image generation.');
    expect(imageBody?.containsKey('image'), isFalse);
    final pages = await DatabaseService.getPictureBookPages(articleId);
    expect(pages, hasLength(2));
    expect(pages.every((page) => page.status == 'ready'), isTrue);
    expect(pages.first.promptJson, contains('Edited scene 1 visual.'));
    final updatedSeries = await DatabaseService.getStorySeriesById(series.id!);
    expect(updatedSeries?.description, contains('blue dress and white apron'));
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
                'planKind': 'picture_book_chapter_plan_v4',
                'storyBrief':
                    'Alice, a curious Victorian girl in a blue dress and white apron, enters a whimsical royal garden.',
                'chapterBrief':
                    'Alice meets the Queen on the croquet-ground in two connected storybook scenes.',
                'scenes': [
                  {
                    'pageIndex': 0,
                    'sentenceStartIndex': 0,
                    'sentenceEndIndex': 0,
                    'title': 'Alice Enters',
                    'story': 'Alice walks into the garden.',
                    'visual': 'Alice in a blue dress enters the garden.',
                  },
                  {
                    'pageIndex': 1,
                    'sentenceStartIndex': 1,
                    'sentenceEndIndex': 1,
                    'title': 'Queen Points',
                    'story': 'The Queen points at the croquet ground.',
                    'visual': 'The Queen points in the same garden.',
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
