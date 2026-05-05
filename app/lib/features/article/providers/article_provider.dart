import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../data/models/article_model.dart';
import '../../../services/database_service.dart';
import '../../../services/nlp_service.dart';

part 'article_provider.g.dart';

class ArticleFormState {
  const ArticleFormState({
    this.title = '',
    this.content = '',
    this.isSaving = false,
    this.error,
  });

  final String title;
  final String content;
  final bool isSaving;
  final String? error;

  ArticleFormState copyWith({
    String? title,
    String? content,
    bool? isSaving,
    String? error,
    bool clearError = false,
  }) =>
      ArticleFormState(
        title: title ?? this.title,
        content: content ?? this.content,
        isSaving: isSaving ?? this.isSaving,
        error: clearError ? null : (error ?? this.error),
      );
}

@riverpod
class ArticleForm extends _$ArticleForm {
  @override
  ArticleFormState build() => const ArticleFormState();

  void setTitle(String value) =>
      state = state.copyWith(title: value, clearError: true);

  void setContent(String value) =>
      state = state.copyWith(content: value, clearError: true);

  Future<bool> save() async {
    if (state.title.trim().isEmpty) {
      state = state.copyWith(error: '请填写文章标题');
      return false;
    }
    if (state.content.trim().isEmpty) {
      state = state.copyWith(error: '请填写文章内容');
      return false;
    }

    state = state.copyWith(isSaving: true, clearError: true);

    final sentences = NlpService.splitSentences(state.content);
    final article = Article(
      title: state.title.trim(),
      content: state.content.trim(),
      sentences: sentences,
      createdAt: DateTime.now(),
    );

    await DatabaseService.saveArticle(article);
    state = const ArticleFormState(); // reset form
    return true;
  }
}
