import 'article_model.dart';
import 'picture_book_model.dart';

/// The only article shape allowed in library list, ready and patch payloads.
///
/// Keep this as a dedicated type rather than calling [Article.toMap]: a prior
/// regression serialized article bodies, sentence arrays and image data into a
/// QA response larger than 60 MB. Full text belongs to `article.fullText` and
/// images belong to `pictureBook.pageImage`.
class ArticleSummary {
  const ArticleSummary({
    required this.id,
    required this.title,
    required this.sentenceSplitVersion,
    required this.sentenceCount,
    required this.visibleSentenceCount,
    required this.createdAt,
    required this.averageScore,
    required this.pictureBookEnabled,
    this.seriesId,
    this.seriesTitle,
    this.chapterOrder,
    this.coverPageIndex,
    this.coverRevision,
  });

  factory ArticleSummary.fromArticle(
    Article article, {
    required int visibleSentenceCount,
    double averageScore = 0,
  }) =>
      ArticleSummary(
        id: article.id,
        title: article.title,
        sentenceSplitVersion: article.sentenceSplitVersion,
        sentenceCount: article.sentences.length,
        visibleSentenceCount: visibleSentenceCount,
        createdAt: article.createdAt,
        averageScore: averageScore,
        pictureBookEnabled: false,
      );

  final int? id;
  final String title;
  final String sentenceSplitVersion;
  final int sentenceCount;
  final int visibleSentenceCount;
  final DateTime createdAt;
  final double averageScore;
  final bool pictureBookEnabled;
  final int? seriesId;
  final String? seriesTitle;
  final int? chapterOrder;
  final int? coverPageIndex;
  final String? coverRevision;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'sentenceSplitVersion': sentenceSplitVersion,
        'sentenceCount': sentenceCount,
        'visibleSentenceCount': visibleSentenceCount,
        'createdAt': createdAt.toIso8601String(),
        'averageScore': averageScore,
        'pictureBookEnabled': pictureBookEnabled,
        if (seriesId != null) 'seriesId': seriesId,
        if (seriesTitle != null) 'seriesTitle': seriesTitle,
        if (chapterOrder != null) 'chapterOrder': chapterOrder,
        'coverPageIndex': coverPageIndex,
        'coverRevision': coverRevision,
      };
}

/// Strict delta returned by every library mutation and emitted as
/// `library.patch`.
///
/// A mutation must never return or broadcast the whole library. Article
/// creation intentionally emits an early patch after the body is persisted and
/// a final patch after chapter/planning work, so a resumable partial save stays
/// visible without reintroducing an all-library response.
class LibraryPatch {
  const LibraryPatch({
    this.upsertArticles = const [],
    this.removeArticleIds = const [],
    this.upsertSeries = const [],
    this.removeSeriesIds = const [],
  });

  final List<Map<String, dynamic>> upsertArticles;
  final List<int> removeArticleIds;
  final List<StorySeries> upsertSeries;
  final List<int> removeSeriesIds;

  Map<String, dynamic> toJson() => {
        'upsertArticles': upsertArticles,
        'removeArticleIds': removeArticleIds,
        'upsertSeries': upsertSeries.map((item) => item.toJson()).toList(),
        'removeSeriesIds': removeSeriesIds,
      };
}
