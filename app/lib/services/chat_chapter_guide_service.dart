import 'api_cache_service.dart';
import 'database_service.dart';
import 'text_generation_service.dart';

class ChatChapterGuideService {
  static const cachePurpose = 'chapter_dialogue_guide_v2';
  static const _maxGuidePoints = 8;

  static Future<TextGenerationReply> prepareGuide({
    required String articleTitle,
    required String articleContent,
    required List<String> sentences,
    int? articleId,
  }) async {
    final contentHash = await _contentHashFor(
      articleTitle: articleTitle,
      articleContent: articleContent,
      sentences: sentences,
    );
    if (articleId != null) {
      final stored = await DatabaseService.getArticleChatGuide(
        articleId: articleId,
        purpose: cachePurpose,
        contentHash: contentHash,
      );
      if (stored != null) {
        return TextGenerationReply(
          text: stored,
          source: TextGenerationReplySource.stored,
        );
      }
    }

    final reply = await TextGenerationService.generateStrict(
      turns: guidePromptTurns(
        articleTitle: articleTitle,
        articleContent: articleContent,
        sentences: sentences,
      ),
      cachePurpose: cachePurpose,
      articleId: articleId,
      maxTokens: 1600,
      skipCacheRead: true,
      skipCacheWrite: true,
    );
    if (articleId != null) {
      await DatabaseService.saveArticleChatGuide(
        articleId: articleId,
        purpose: cachePurpose,
        contentHash: contentHash,
        guideText: reply.text,
      );
    }
    return reply;
  }

  static List<TextGenerationTurn> guidePromptTurns({
    required String articleTitle,
    required String articleContent,
    required List<String> sentences,
  }) {
    return [
      const TextGenerationTurn(
        role: 'system',
        content:
            'Create a compact English conversation guide for one chapter. Return plain text only.',
      ),
      TextGenerationTurn(
        role: 'user',
        content: [
          'Chapter title: ${articleTitle.trim()}',
          '',
          'Rules:',
          '- Use the full chapter below.',
          '- Group the story by paragraphs or major story turns.',
          '- Do not create one point per sentence.',
          '- Keep at most $_maxGuidePoints ordered coverage points.',
          '- Include the ending.',
          '- Keep the guide concise.',
          '',
          'Required format:',
          'Chapter summary: ...',
          'Ordered coverage points:',
          '1. ...',
          'Completion rubric: ...',
          'Ability assessment cues: ...',
          '',
          'Numbered chapter sentences:',
          _numberedSentences(articleContent, sentences),
        ].join('\n'),
      ),
    ];
  }

  static String _numberedSentences(
      String articleContent, List<String> sentences) {
    final cleanSentences = _cleanSentences(articleContent, sentences);
    if (cleanSentences.isEmpty) {
      return articleContent.replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    return [
      for (var index = 0; index < cleanSentences.length; index += 1)
        '$index. ${cleanSentences[index]}',
    ].join('\n');
  }

  static List<String> _cleanSentences(
    String articleContent,
    List<String> sentences,
  ) {
    final clean = sentences
        .map((sentence) => sentence.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
    if (clean.isNotEmpty) {
      return clean;
    }
    final normalized = articleContent.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) {
      return const [];
    }
    return normalized
        .split(RegExp(r'(?<=[.!?])\s+'))
        .map((sentence) => sentence.trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
  }

  static Future<String> _contentHashFor({
    required String articleTitle,
    required String articleContent,
    required List<String> sentences,
  }) {
    final payload = ApiCacheService.canonicalJson({
      'purpose': cachePurpose,
      'articleTitle': articleTitle.trim(),
      'articleContent': articleContent.trim(),
      'sentences': _cleanSentences(articleContent, sentences),
      'maxGuidePoints': _maxGuidePoints,
    });
    return ApiCacheService.hashUtf8(payload);
  }
}
