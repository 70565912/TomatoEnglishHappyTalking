import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/data/models/article_segmentation_run_model.dart';
import 'package:tomato_english_happy_talking/data/models/article_sentence_translation_model.dart';
import 'package:tomato_english_happy_talking/data/models/picture_book_model.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';

void main() {
  late Directory tempDir;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tomato_split_migration_');
    await databaseFactory.setDatabasesPath(tempDir.path);
    DatabaseService.setDatabaseDirectoryOverrideForTest(tempDir.path);
    DatabaseService.setRuntimeDataRootOverrideForTest(tempDir.path);
    await DatabaseService.resetForTest();
  });

  tearDown(() async {
    await DatabaseService.resetForTest();
    DatabaseService.setDatabaseDirectoryOverrideForTest(null);
    DatabaseService.setRuntimeDataRootOverrideForTest(null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('replaces sentences, translations, and page ranges in one transaction',
      () async {
    final seeded = await _seedArticle();
    const newSentences = <String>[
      'First sentence.',
      'Second sentence;',
      'with a natural continuation.',
      'Third sentence.',
    ];
    final now = DateTime.utc(2026, 8, 8, 16);
    final oldPages =
        await DatabaseService.getPictureBookPages(seeded.articleId);
    final updatedPages = <PictureBookPage>[
      oldPages[0].copyWith(
        sentenceStartIndex: 0,
        sentenceEndIndex: 1,
        paragraphText: newSentences.sublist(0, 2).join(' '),
        promptJson: jsonEncode({
          'scene': {
            'pageIndex': 0,
            'sentenceStartIndex': 0,
            'sentenceEndIndex': 1,
          },
          'sentenceSplitVersion': 'reviewed_dp_v3',
        }),
        updatedAt: now,
      ),
      oldPages[1].copyWith(
        sentenceStartIndex: 2,
        sentenceEndIndex: 3,
        paragraphText: newSentences.sublist(2).join(' '),
        promptJson: jsonEncode({
          'scene': {
            'pageIndex': 1,
            'sentenceStartIndex': 2,
            'sentenceEndIndex': 3,
          },
          'sentenceSplitVersion': 'reviewed_dp_v3',
        }),
        updatedAt: now,
      ),
    ];
    final chapter = (await DatabaseService.getStoryChapterForArticle(
      seeded.articleId,
    ))!;
    final updatedChapter = chapter.copyWith(
      summaryJson: jsonEncode({
        'scenes': [
          {
            'pageIndex': 0,
            'sentenceStartIndex': 0,
            'sentenceEndIndex': 1,
          },
          {
            'pageIndex': 1,
            'sentenceStartIndex': 2,
            'sentenceEndIndex': 3,
          },
        ],
        'sentenceMigration': {'sentenceSplitVersion': 'reviewed_dp_v3'},
      }),
      updatedAt: now,
    );
    final translations = <ArticleSentenceTranslation>[
      for (var index = 0; index < newSentences.length; index += 1)
        ArticleSentenceTranslation(
          articleId: seeded.articleId,
          sentenceIndex: index,
          englishSentence: newSentences[index],
          chineseText: '译文 ${index + 1}',
          source: 'migration_test',
          createdAt: now,
          updatedAt: now,
        ),
    ];

    await DatabaseService.replaceArticleSegmentation(
      articleId: seeded.articleId,
      expectedSentenceSplitVersion: 'reviewed_dp_v2',
      expectedSentences: seeded.oldSentences,
      content: newSentences.join(' '),
      sentences: newSentences,
      sentenceSplitVersion: 'reviewed_dp_v3',
      translations: translations,
      pages: updatedPages,
      chapter: updatedChapter,
    );

    final article = await DatabaseService.getArticleById(seeded.articleId);
    expect(article!.sentences, newSentences);
    expect(article.content, newSentences.join(' '));
    expect(article.sentenceSplitVersion, 'reviewed_dp_v3');
    final storedTranslations =
        await DatabaseService.getArticleSentenceTranslationRows(
      seeded.articleId,
    );
    expect(storedTranslations, hasLength(4));
    expect(storedTranslations[2].englishSentence, newSentences[2]);
    final pages = await DatabaseService.getPictureBookPages(seeded.articleId);
    expect(pages.map((page) => page.imagePath), ['image-0.png', 'image-1.png']);
    expect(pages.map((page) => page.sentenceEndIndex), [1, 3]);
    expect(
      (jsonDecode(pages[1].promptJson)
          as Map<String, dynamic>)['sentenceSplitVersion'],
      'reviewed_dp_v3',
    );
    final storedChapter =
        await DatabaseService.getStoryChapterForArticle(seeded.articleId);
    final summary =
        jsonDecode(storedChapter!.summaryJson) as Map<String, dynamic>;
    expect(summary['sentenceMigration'], isNotNull);
  });

  test('stores the article and reproducible V3 run in one transaction',
      () async {
    final now = DateTime.utc(2026, 8, 8, 19, 30);
    final article = Article(
      title: 'Syntax audit',
      content: 'Mole looked up.',
      sentences: const ['Mole looked up.'],
      sentenceSplitVersion: 'reviewed_dp_v3',
      createdAt: now,
    );
    final run = ArticleSegmentationRunRecord(
      sourceHash: 'source-sha256',
      sentenceSplitVersion: 'reviewed_dp_v3',
      solverVersion: 'syntax_solver_v3_3',
      parserVersion: 'udpipe-1.4.0',
      modelSha256: 'model-sha256',
      parserHealthy: true,
      parserIssues: const [],
      candidatePaths: const [
        {
          'originalIndex': 0,
          'candidatePaths': [
            {'pathId': 'v3_o0_keep'},
          ],
        },
      ],
      selectedPaths: const {0: 'v3_o0_keep'},
      selectionTrace: const [
        {
          'originalIndex': 0,
          'round': 'initial',
          'candidateSetHash': 'initial-hash',
          'response': 'v3_o0_keep',
          'source': 'cache',
        },
      ],
      aiSource: 'stored',
      aiRemoteAttempts: 0,
      usedLocalFallback: false,
      translationSource: 'imported_bilingual',
      createdAt: now,
    );

    final articleId = await DatabaseService.saveArticleWithSegmentationRun(
      article: article,
      segmentationRun: run,
    );

    final rows = await DatabaseService.getArticleSegmentationRuns(articleId);
    expect(rows, hasLength(1));
    expect(rows.single['sentence_split_version'], 'reviewed_dp_v3');
    expect(rows.single['solver_version'], 'syntax_solver_v3_3');
    expect(rows.single['parser_version'], 'udpipe-1.4.0');
    expect(rows.single['model_sha256'], 'model-sha256');
    expect(rows.single['selected_paths_json'], '{"0":"v3_o0_keep"}');
    final candidateAudit = jsonDecode(
      rows.single['candidate_paths_json'] as String,
    ) as Map<String, dynamic>;
    expect(
      candidateAudit['schemaVersion'],
      'article_segmentation_candidate_audit_v3_3',
    );
    expect(candidateAudit['originals'], hasLength(1));
    expect(candidateAudit['selectionTrace'], hasLength(1));
    expect(
      ((candidateAudit['selectionTrace'] as List).single
          as Map<String, dynamic>)['candidateSetHash'],
      'initial-hash',
    );
    expect(rows.single['translation_source'], 'imported_bilingual');
  });

  test('stale sentence guard rolls the entire migration back', () async {
    final seeded = await _seedArticle();
    final pages = await DatabaseService.getPictureBookPages(seeded.articleId);
    final chapter =
        await DatabaseService.getStoryChapterForArticle(seeded.articleId);
    final now = DateTime.utc(2026, 8, 8, 16);

    expect(
      () => DatabaseService.replaceArticleSegmentation(
        articleId: seeded.articleId,
        expectedSentenceSplitVersion: 'reviewed_dp_v2',
        expectedSentences: const ['stale sentence'],
        content: 'Replacement.',
        sentences: const ['Replacement.'],
        sentenceSplitVersion: 'reviewed_dp_v3',
        translations: [
          ArticleSentenceTranslation(
            articleId: seeded.articleId,
            sentenceIndex: 0,
            englishSentence: 'Replacement.',
            chineseText: '替换。',
            source: 'migration_test',
            createdAt: now,
            updatedAt: now,
          ),
        ],
        pages: [
          pages.first.copyWith(
            sentenceStartIndex: 0,
            sentenceEndIndex: 0,
            paragraphText: 'Replacement.',
          ),
          pages.last.copyWith(
            sentenceStartIndex: 0,
            sentenceEndIndex: 0,
            paragraphText: 'Replacement.',
          ),
        ],
        chapter: chapter!,
      ),
      throwsStateError,
    );

    final article = await DatabaseService.getArticleById(seeded.articleId);
    expect(article!.sentences, seeded.oldSentences);
    expect(article.sentenceSplitVersion, 'reviewed_dp_v2');
    expect(
      await DatabaseService.getArticleSentenceTranslationRows(
        seeded.articleId,
      ),
      hasLength(3),
    );
  });
}

Future<({int articleId, List<String> oldSentences})> _seedArticle() async {
  const oldSentences = <String>[
    'First sentence.',
    'Second sentence; with a natural continuation.',
    'Third sentence.',
  ];
  final createdAt = DateTime.utc(2026, 8, 1);
  final articleId = await DatabaseService.saveArticle(
    Article(
      title: 'E01 Migration Test',
      content: oldSentences.join(' '),
      sentences: oldSentences,
      sentenceSplitVersion: 'reviewed_dp_v2',
      createdAt: createdAt,
    ),
  );
  final seriesId = await DatabaseService.saveStorySeries(
    StorySeries(
      title: 'Migration Book',
      description: '',
      createdAt: createdAt,
      updatedAt: createdAt,
    ),
  );
  await DatabaseService.saveStoryChapter(
    StoryChapter(
      seriesId: seriesId,
      articleId: articleId,
      chapterOrder: 1,
      chapterTitle: 'E01 Migration Test',
      summaryJson: jsonEncode({
        'scenes': [
          {
            'pageIndex': 0,
            'sentenceStartIndex': 0,
            'sentenceEndIndex': 1,
          },
          {
            'pageIndex': 1,
            'sentenceStartIndex': 2,
            'sentenceEndIndex': 2,
          },
        ],
      }),
      createdAt: createdAt,
      updatedAt: createdAt,
    ),
  );
  for (var index = 0; index < 2; index += 1) {
    final start = index == 0 ? 0 : 2;
    final end = index == 0 ? 1 : 2;
    await DatabaseService.upsertPictureBookPage(
      PictureBookPage(
        articleId: articleId,
        seriesId: seriesId,
        pageIndex: index,
        sentenceStartIndex: start,
        sentenceEndIndex: end,
        paragraphText: oldSentences.sublist(start, end + 1).join(' '),
        promptJson: jsonEncode({
          'scene': {
            'pageIndex': index,
            'sentenceStartIndex': start,
            'sentenceEndIndex': end,
          },
        }),
        imagePath: 'image-$index.png',
        imageCacheKey: 'image-$index',
        status: 'ready',
        createdAt: createdAt,
        updatedAt: createdAt,
      ),
    );
  }
  await DatabaseService.saveArticleSentenceTranslations(
    articleId,
    [
      for (var index = 0; index < oldSentences.length; index += 1)
        ArticleSentenceTranslation(
          articleId: articleId,
          sentenceIndex: index,
          englishSentence: oldSentences[index],
          chineseText: '旧译文 ${index + 1}',
          source: 'reviewed',
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
    ],
  );
  return (articleId: articleId, oldSentences: oldSentences);
}
