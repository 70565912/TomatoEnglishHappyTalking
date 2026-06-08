import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/data/models/picture_book_model.dart';
import 'package:tomato_english_happy_talking/services/api_cache_service.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/picture_book_service.dart';
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
    VolcImageService.setPostOverrideForTest(null);
  });

  tearDown(() async {
    VolcImageService.setPostOverrideForTest(null);
    await DatabaseService.resetForTest();
    DatabaseService.setDatabaseDirectoryOverrideForTest(null);
    Directory.current = previousDirectory;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
      'creates persistent cache, picture-book, translation, and safety tables at database version 6',
      () async {
    final db = await DatabaseService.database;
    expect(await db.getVersion(), 6);

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
    expect(tableNames, contains('story_reference_assets'));
    expect(tableNames, contains('article_sentence_translations'));
    expect(tableNames, contains('content_safety_failures'));
    expect(tableNames, contains('content_safety_rules'));
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

  test('picture-book generation skips image calls when Ark key is missing',
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
    expect(state['status'], 'skipped');
    final pages = state['pages'] as List;
    expect(pages, isNotEmpty);
    expect(pages.first['status'], 'skipped');
    expect(pages.first['imageUri'], isNull);
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

  test(
      'picture-book generation creates one chapter image without references by default',
      () async {
    _writeImageArkKey(tempDir, 'ark-role-key-12345678901234567890');
    final postedBodies = <Map<String, dynamic>>[];
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

    final refs = await DatabaseService.getStoryReferenceAssets(series.id!);
    expect(refs, isEmpty);

    final groupBodies = postedBodies
        .where((body) => body['sequential_image_generation'] == 'auto')
        .toList(growable: false);
    expect(groupBodies, isEmpty);
    expect(postedBodies, hasLength(1));
    expect(postedBodies.single['sequential_image_generation'], 'disabled');
    expect(postedBodies.single['image'], isNull);
    expect(
      postedBodies.single['prompt'] as String,
      contains('single image for the whole chapter'),
    );
    final state = await PictureBookService.statePayload(articleId);
    expect(state['status'], 'ready');
    final pages = state['pages'] as List;
    expect(pages, hasLength(1));
    expect(pages.single['sentenceStartIndex'], 0);
    expect(pages.single['sentenceEndIndex'], 5);
  });

  test('picture-book image prompt allows natural visible text', () {
    final prompt = PictureBookService.imagePromptForTest({
      'prompt':
          'A girl smiles over a glowing map in a warm bedroom picture-book scene.',
      'negativePrompt': 'avoid scary details',
      'seriesTitle': 'Alice\'s Adventures in Wonderland',
      'styleGuide': {
        'visualStyle': 'warm English picture book illustration',
      },
    });

    expect(prompt, contains('single image for the whole chapter'));
    expect(prompt, contains('NATURAL TEXT POLICY'));
    expect(prompt, contains('visible text is allowed'));
    expect(prompt, contains('BOOK TITLE / SERIES TITLE'));
    expect(prompt, contains('Alice\'s Adventures in Wonderland'));
    expect(
        prompt,
        contains(
            'one illustrated chapter image from the book or story series'));
    expect(prompt,
        contains('Use the book title "Alice\'s Adventures in Wonderland"'));
    expect(prompt, contains('saved series bible'));
    expect(prompt, contains('current chapter story'));
    expect(prompt, contains('Do not import unrelated characters'));
    expect(prompt, contains('Avoid modern classroom'));
    expect(prompt,
        isNot(contains('Alice is always the same classic storybook girl')));
    expect(prompt, isNot(contains('Do not turn Alice into a modern student')));
    expect(prompt, isNot(contains('no typography')));
    expect(prompt, isNot(contains('All visible surfaces are simple color')));
  });

  test('picture-book image prompt uses any series title without Alice lock-in',
      () {
    final prompt = PictureBookService.imagePromptForTest({
      'prompt': 'A boy opens a gate into a quiet moonlit garden.',
      'seriesTitle': 'The Secret Garden',
      'styleGuide': {
        'visualStyle': 'warm English picture book illustration',
      },
    });

    expect(prompt, contains('BOOK TITLE / SERIES TITLE: The Secret Garden'));
    expect(
      prompt,
      contains(
        'one illustrated chapter image from the book or story series "The Secret Garden"',
      ),
    );
    expect(prompt, contains('Use the book title "The Secret Garden"'));
    expect(prompt, isNot(contains('Alice is always')));
    expect(prompt, isNot(contains('Wonderland')));
  });

  test('picture-book image prompt softens unsafe classic story threats', () {
    final prompt = PictureBookService.imagePromptForTest({
      'prompt':
          'Alice hears that the Duchess is under sentence of execution. The Queen shouts "Off with her head!" while players are fighting for hedgehogs.',
      'seriesTitle': 'Alice\'s Adventures in Wonderland',
      'styleGuide': {
        'visualStyle': 'warm English picture book illustration',
      },
    });
    final lower = prompt.toLowerCase();

    expect(lower, isNot(contains('execution')));
    expect(lower, isNot(contains('off with her head')));
    expect(lower, isNot(contains('fighting')));
    expect(prompt, contains('harmless theatrical royal anger'));
    expect(prompt, contains('serious trouble with the Queen'));
    expect(prompt, contains('exaggerated angry command'));
    expect(prompt, contains('scrambling'));
  });

  test('picture-book segmentation creates one chapter-level image segment', () {
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

    expect(segments, hasLength(1));
    expect(segments.first['text'], isNot(contains('Chapter Seven')));
    expect(segments.first['sentenceStartIndex'], 0);
    expect(segments.first['sentenceEndIndex'], 10);
    expect(segments.first['text'], contains('There was a table'));
    expect(segments.first['text'], contains('"No room! No room!"'));
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
    expect(segments, hasLength(1));

    final text = segments.single['text'] as String;
    expect(text, contains('full_story_marker_0'));
    expect(text, contains('full_story_marker_35'));
    expect(text, contains('full_story_marker_69'));
    expect(text, isNot(contains('[middle of chapter]')));
    expect(text, isNot(contains('[end of chapter]')));
  });

  test('picture-book cover payload uses the first ready generated image',
      () async {
    final articleId = await _saveArticle('Mia opens a map and smiles.');
    final imageFile = File('${tempDir.path}${Platform.pathSeparator}cover.png')
      ..writeAsBytesSync([137, 80, 78, 71, 1, 2, 3]);
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
    expect(
      payload?['coverImageUri']?.toString(),
      startsWith('data:image/png;base64,'),
    );
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

void _writeImageArkKey(Directory root, String key) {
  File('${root.path}${Platform.pathSeparator}ark.txt').writeAsStringSync(
    'ARK_API_KEY=$key\n',
  );
}
