import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/data/models/picture_book_model.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/nlp_service.dart';
import 'package:tomato_english_happy_talking/services/picture_book_service.dart';
import 'package:tomato_english_happy_talking/services/practice_input_parser.dart';
import 'package:tomato_english_happy_talking/services/practice_text_service.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'live picture book generation smoke',
    () async {
      final textPath =
          Platform.environment['TOMATO_PICTURE_SMOKE_TEXT']?.trim() ?? '';
      if (textPath.isEmpty) {
        markTestSkipped('TOMATO_PICTURE_SMOKE_TEXT is not set.');
        return;
      }
      final shouldGenerate =
          Platform.environment['TOMATO_PICTURE_SMOKE_GENERATE'] == '1';
      final strict = Platform.environment['TOMATO_PICTURE_SMOKE_STRICT'] == '1';
      final titleOverride =
          Platform.environment['TOMATO_PICTURE_SMOKE_TITLE']?.trim() ?? '';
      final outputPath =
          Platform.environment['TOMATO_PICTURE_SMOKE_OUTPUT']?.trim() ??
              '../.tmp/live_picture_book_result.json';
      final textFile = File(textPath);
      expect(await textFile.exists(), isTrue, reason: textPath);

      await DatabaseService.resetForTest();
      final rawText = await textFile.readAsString();
      final parsed = PracticeInputParser.parse(rawText);
      var englishContent = parsed.englishContent.trim();
      var source = parsed.sourceKind.name;
      if (!parsed.usesLocalEnglish) {
        final reply = await PracticeTextService.translateToEnglishForPractice(
          content: rawText,
        );
        englishContent = reply.text.trim();
        source = '${parsed.sourceKind.name}/${reply.source.name}';
      }

      final sentences = NlpService.splitSentences(englishContent);
      final articleTitle = titleOverride.isNotEmpty
          ? titleOverride
          : shouldGenerate
              ? 'E27 - The Queen\'s Croquet-Ground live ${DateTime.now().millisecondsSinceEpoch}'
              : 'E27 - The Queen\'s Croquet-Ground';
      final article = Article(
        title: articleTitle,
        content: englishContent,
        sentences: sentences,
        createdAt: DateTime.now(),
      );
      final segments = PictureBookService.pictureSegmentsForTest(article);

      final summary = <String, dynamic>{
        'mode': shouldGenerate ? 'generate' : 'preview',
        'source': source,
        'contentCharacters': englishContent.length,
        'sentenceCount': sentences.length,
        'picturePageCount': segments.length,
        'firstParagraph': englishContent.split(RegExp(r'\n\s*\n+')).first,
        'segments': segments,
      };

      if (shouldGenerate) {
        final series = await _ensureAliceSeries();
        final articleId = await _ensureArticle(article);
        final savedArticle = (await DatabaseService.getArticleById(articleId))!
            .copyWith(content: englishContent, sentences: sentences);
        await DatabaseService.updateArticleContentAndSentences(
          articleId,
          englishContent,
          sentences,
        );
        final chapter = await PictureBookService.ensureChapterForArticle(
          seriesId: series.id!,
          article: savedArticle,
        );
        await PictureBookService.generateForArticle(
          article: savedArticle,
          chapter: chapter,
          onProgress: (state) {
            final pages = state['pages'] as List? ?? const [];
            final ready =
                pages.where((page) => page is Map && page['status'] == 'ready');
            // ignore: avoid_print
            print(
              'LIVE_PICTURE_BOOK_PROGRESS status=${state['status']} ready=${ready.length}/${pages.length}',
            );
          },
        );

        final state = await PictureBookService.statePayload(articleId);
        final refreshedSeries = await DatabaseService.getStorySeriesById(
          series.id!,
        );
        summary.addAll({
          'articleId': articleId,
          'seriesId': series.id,
          'seriesDescription': refreshedSeries?.description ?? '',
          'stateStatus': state['status'],
          'readyPageCount': ((state['pages'] as List?) ?? const [])
              .whereType<Map>()
              .where((page) => page['status'] == 'ready')
              .length,
          'pages': ((state['pages'] as List?) ?? const [])
              .whereType<Map>()
              .map(
                (page) => {
                  'pageIndex': page['pageIndex'],
                  'status': page['status'],
                  'imagePath': page['imagePath'],
                  'errorMessage': page['errorMessage'],
                  'paragraphText': page['paragraphText'],
                },
              )
              .toList(growable: false),
        });
        if (strict) {
          final pages = ((state['pages'] as List?) ?? const [])
              .whereType<Map>()
              .toList(growable: false);
          expect(pages, hasLength(segments.length));
          expect(
            pages.every((page) => page['status'] == 'ready'),
            isTrue,
            reason: const JsonEncoder.withIndent('  ').convert(pages),
          );
          for (final page in pages) {
            final imagePath = page['imagePath']?.toString() ?? '';
            expect(imagePath, isNotEmpty, reason: '$page');
            expect(await File(imagePath).exists(), isTrue, reason: imagePath);
          }
        }
      }

      final outputFile = File(outputPath);
      await outputFile.parent.create(recursive: true);
      await outputFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(summary),
      );
      // ignore: avoid_print
      print('LIVE_PICTURE_BOOK_RESULT=${outputFile.absolute.path}');
    },
    timeout: const Timeout(Duration(minutes: 45)),
  );
}

Future<StorySeries> _ensureAliceSeries() async {
  final seriesList = await DatabaseService.getStorySeries();
  for (final item in seriesList) {
    if (item.title.trim().toLowerCase() ==
        'alice\'s adventures in wonderland') {
      return item;
    }
  }
  return PictureBookService.createSeries(
    title: 'Alice\'s Adventures in Wonderland',
  );
}

Future<int> _ensureArticle(Article article) async {
  final articles = await DatabaseService.getArticles();
  for (final item in articles) {
    if (item.title == article.title) {
      return item.id!;
    }
  }
  return DatabaseService.saveArticle(article);
}
