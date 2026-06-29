import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../data/models/article_model.dart';
import '../../../services/database_service.dart';
import '../../../services/nlp_service.dart';

part 'home_provider.g.dart';

@riverpod
Future<List<Article>> articleList(ArticleListRef ref) async {
  final articles = await DatabaseService.getArticles();
  return articles.map((article) {
    final storedSentences = article.sentences
        .map((sentence) => sentence.trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
    if (storedSentences.isNotEmpty) {
      return article.copyWith(sentences: storedSentences);
    }
    // Saved sentences are the material boundary. Only synthesize an in-memory
    // fallback for incomplete rows; rebuilding sentences requires rebuilding
    // the article and its generated materials.
    final fallback = NlpService.splitSentences(article.content);
    return fallback.isEmpty ? article : article.copyWith(sentences: fallback);
  }).toList(growable: false);
}
