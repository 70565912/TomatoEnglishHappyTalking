import 'chapter_story_outline_service.dart';
import 'text_generation_service.dart';

class ChatChapterGuideService {
  static const cachePurpose = ChapterStoryOutlineService.cachePurpose;

  static Future<TextGenerationReply> prepareGuide({
    required String articleTitle,
    required String articleContent,
    required List<String> sentences,
    int? articleId,
  }) async {
    final outline = await ChapterStoryOutlineService.prepareOutline(
      articleTitle: articleTitle,
      articleContent: articleContent,
      sentences: sentences,
      articleId: articleId,
    );
    return TextGenerationReply(
      text: outline.toConversationGuide(articleTitle: articleTitle),
      source: outline.source,
      errorMessage: outline.errorMessage,
    );
  }

  static List<TextGenerationTurn> guidePromptTurns({
    required String articleTitle,
    required String articleContent,
    required List<String> sentences,
  }) =>
      ChapterStoryOutlineService.outlinePromptTurns(
        articleTitle: articleTitle,
        articleContent: articleContent,
        sentences: sentences,
      );

  static String buildLocalGuide({
    required String articleTitle,
    required String articleContent,
    required List<String> sentences,
  }) {
    final outline = ChapterStoryOutlineService.buildLocalOutline(
      articleTitle: articleTitle,
      articleContent: articleContent,
      sentences: sentences,
    );
    return outline.toConversationGuide(articleTitle: articleTitle);
  }
}
