import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/data/models/library_bridge_model.dart';
import 'package:tomato_english_happy_talking/features/web_shell/web_bridge_protocol.dart';

void main() {
  ArticleSummary summary(int id) => ArticleSummary.fromArticle(
        Article(
          id: id,
          title: 'Chapter $id',
          content: 'private body ${'x' * 10000}',
          sentences: ['private sentence ${'y' * 1000}'],
          createdAt: DateTime.utc(2026, 8, 2),
        ),
        visibleSentenceCount: 1,
        averageScore: 88,
      );

  test('ArticleSummary cannot serialize bodies, sentence arrays, or images',
      () {
    final encoded = jsonEncode(summary(1).toJson());

    expect(encoded, isNot(contains('private body')));
    expect(encoded, isNot(contains('private sentence')));
    expect(encoded, isNot(contains('"content"')));
    expect(encoded, isNot(contains('"sentences"')));
    expect(encoded, isNot(contains('coverImagePath')));
    expect(encoded, isNot(contains('coverImageUri')));
    expect(encoded, isNot(contains('seriesDescription')));
    expect(encoded, isNot(contains('chapterDescription')));
    expect(encoded, isNot(contains('data:image/')));
  });

  test('LibraryPatch always exposes exactly the four delta collections', () {
    final patch = LibraryPatch(
      upsertArticles: [summary(2).toJson()],
      removeArticleIds: const [1],
    ).toJson();

    expect(
      patch.keys.toSet(),
      {
        'upsertArticles',
        'removeArticleIds',
        'upsertSeries',
        'removeSeriesIds',
      },
    );
    expect(jsonEncode(patch), isNot(contains('private body')));
  });

  test('non-image bridge fixtures stay within strict response budgets', () {
    final summaries = [for (var id = 1; id <= 2000; id++) summary(id).toJson()];
    final listPayload = {'articles': summaries, 'series': const []};
    final fullTextPayload = {
      'article': summary(1).toJson(),
      'bookTitle': 'Book',
      'items': [
        for (var index = 0; index < 200; index++)
          {
            'index': index,
            'english': 'e' * 700,
            'chinese': '中' * 100,
          },
      ],
    };
    final mutationPatch = LibraryPatch(
      upsertArticles: summaries.take(100).toList(),
    ).toJson();
    final importPatch = LibraryPatch(
      upsertArticles: summaries.take(1000).toList(),
    ).toJson();
    final snapshot = {
      'images': [
        for (var index = 0; index < 100; index++)
          {
            'src': {
              'kind': 'data',
              'length': 40000000,
              'preview': 'data:image/png;base64,',
            },
            'naturalWidth': 1280,
            'naturalHeight': 720,
            'complete': true,
          },
      ],
    };

    expect(estimateJsonChars(listPayload), lessThanOrEqualTo(1024 * 1024));
    expect(estimateJsonChars(snapshot), lessThanOrEqualTo(1024 * 1024));
    expect(estimateJsonChars(fullTextPayload), lessThanOrEqualTo(256 * 1024));
    expect(estimateJsonChars(mutationPatch), lessThanOrEqualTo(128 * 1024));
    expect(estimateJsonChars(importPatch), lessThanOrEqualTo(512 * 1024));
  });
}
