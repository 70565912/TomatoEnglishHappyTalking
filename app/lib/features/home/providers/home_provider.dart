import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../data/models/article_model.dart';
import '../../../services/database_service.dart';

part 'home_provider.g.dart';

@riverpod
Future<List<Article>> articleList(ArticleListRef ref) async {
  return DatabaseService.getArticles();
}
