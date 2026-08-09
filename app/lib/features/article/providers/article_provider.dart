import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../data/models/article_model.dart';
import '../../../services/article_segmentation_service_v3.dart';
import '../../../services/database_service.dart';
import '../../../services/practice_input_parser.dart';
import '../../../services/practice_text_service.dart';
import '../../../services/read_aloud_splitter_v3.dart';

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
    if (state.content.trim().isEmpty) {
      state = state.copyWith(error: '请填写文章内容');
      return false;
    }

    state = state.copyWith(isSaving: true, clearError: true);

    try {
      final parsedInput = PracticeInputParser.parse(state.content);
      final englishContent = parsedInput.usesLocalEnglish
          ? parsedInput.englishContent
          : (await PracticeTextService.translateToEnglishForPractice(
              content: state.content,
            ))
              .text
              .trim();
      final segmentation =
          await const ArticleSegmentationServiceV3().split(englishContent);
      final sentences = segmentation.sentences;
      if (sentences.isEmpty) {
        state = state.copyWith(
          isSaving: false,
          error: '文章内容需要能转换为英文练习句子',
        );
        return false;
      }

      final requestedTitle = state.title.trim();
      final title = requestedTitle.isNotEmpty
          ? requestedTitle
          : parsedInput.titleCandidate.trim().isNotEmpty
              ? parsedInput.titleCandidate.trim()
              : (await PracticeTextService.suggestArticleTitle(
                  content: englishContent,
                ))
                  .text
                  .trim();
      final article = Article(
        title: title,
        content: englishContent,
        sentences: sentences,
        sentenceSplitVersion: ReadAloudSplitterV3.reviewedVersion,
        createdAt: DateTime.now(),
      );

      await DatabaseService.saveArticleWithSegmentationRun(
        article: article,
        segmentationRun: segmentation.audit,
      );
      state = const ArticleFormState(); // reset form
      return true;
    } catch (error) {
      state = state.copyWith(
        isSaving: false,
        error: error.toString(),
      );
      return false;
    }
  }
}
