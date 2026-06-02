import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../data/models/article_model.dart';
import '../../../services/database_service.dart';
import '../../../services/nlp_service.dart';

part 'home_provider.g.dart';

@riverpod
Future<List<Article>> articleList(ArticleListRef ref) async {
  final articles = await DatabaseService.getArticles();
  final normalized = <Article>[];
  for (final article in articles) {
    final sentences = NlpService.splitSentences(article.content);
    if (sentences.isEmpty || listEquals(article.sentences, sentences)) {
      normalized.add(article);
      continue;
    }

    final id = article.id;
    if (id != null) {
      await DatabaseService.updateArticleSentences(id, sentences);
    }
    normalized.add(article.copyWith(sentences: sentences));
  }
  return normalized;
}
