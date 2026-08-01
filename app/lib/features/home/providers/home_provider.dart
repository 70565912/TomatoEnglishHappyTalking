import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/practice/listening_sentence_visibility.dart';
import '../../../data/models/article_model.dart';
import '../../../services/database_service.dart';

part 'home_provider.g.dart';

@riverpod
Future<List<Article>> articleList(ArticleListRef ref) async {
  final articles = await DatabaseService.getArticles();
  return articles.map((article) {
    final storedSentences = article.sentences
        .map((sentence) => sentence.trim())
        .toList(growable: false);
    final hasAnyStored = storedSentences.isNotEmpty;
    final hasVisible = visibleSentenceCount(storedSentences) > 0;
    if (hasVisible) {
      return article.copyWith(sentences: storedSentences);
    }
    if (hasAnyStored) {
      return article.copyWith(sentences: storedSentences);
    }
    // Persisted sentence boundaries are immutable for existing articles.
    // Incomplete legacy rows must be explicitly rebuilt instead of silently
    // receiving the current splitter's boundaries while they are being read.
    return article;
  }).toList(growable: false);
}
