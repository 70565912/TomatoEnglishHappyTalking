import 'dart:math';

import 'text_generation_service.dart';

class ChatChapterGuideService {
  static const cachePurpose = 'chat_chapter_guide_v1';

  static Future<TextGenerationReply> prepareGuide({
    required String articleTitle,
    required String articleContent,
    required List<String> sentences,
    int? articleId,
  }) {
    final fallback = buildLocalGuide(
      articleTitle: articleTitle,
      articleContent: articleContent,
      sentences: sentences,
    );
    return TextGenerationService.generate(
      turns: guidePromptTurns(
        articleTitle: articleTitle,
        articleContent: articleContent,
        sentences: sentences,
      ),
      cachePurpose: cachePurpose,
      fallbackText: fallback,
      articleId: articleId,
      maxTokens: 1400,
    );
  }

  static List<TextGenerationTurn> guidePromptTurns({
    required String articleTitle,
    required String articleContent,
    required List<String> sentences,
  }) {
    final title =
        articleTitle.trim().isEmpty ? 'Untitled chapter' : articleTitle.trim();
    final chapterText = _chapterTextForRemoteGuide(
      articleContent: articleContent,
      sentences: sentences,
    );
    return [
      const TextGenerationTurn(
        role: 'system',
        content:
            'You analyze complete English story chapters and create compact teaching guides for speaking practice. Return only a concise English guide, not JSON and not the full chapter. Include these exact sections: Chapter summary, Ordered coverage points, Character and setting facts, Completion rubric, Ability assessment cues. Choose the number of Ordered coverage points from the story structure itself: split by natural scene, event, conflict, decision, and ending changes. Do not use a fixed count. Short chapters may need 3-5 points; ordinary chapters often need 6-10; longer chapters may use up to 14 if needed for complete coverage. Keep the guide short enough to reuse in every chat turn. Do not invent events outside the supplied chapter. Some risky classic-story words may be split with hyphens for platform safety filtering; preserve the story fact and keep the split spelling instead of restoring the original risky word.',
      ),
      TextGenerationTurn(
        role: 'user',
        content:
            'Chapter title: $title\n\nComplete chapter text:\n$chapterText\n\nCreate a compact reusable conversation guide from this complete chapter. Decide the Ordered coverage points by semantic story structure, not by a fixed sentence count. Coverage points must stay in chapter order and cover the whole chapter, including the ending and meaning. Do not change story facts. Prefer short phrases over long quotations.',
      ),
    ];
  }

  static String buildLocalGuide({
    required String articleTitle,
    required String articleContent,
    required List<String> sentences,
  }) {
    final title =
        articleTitle.trim().isEmpty ? 'Untitled chapter' : articleTitle.trim();
    final cleanSentences = sentences
        .map((sentence) => sentence.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
    final sourceSentences = cleanSentences.isNotEmpty
        ? cleanSentences
        : _fallbackSentences(articleContent);
    final coverage = _coveragePoints(sourceSentences);
    final summary = sourceSentences.isEmpty
        ? _shorten(_normalizeArticleContent(articleContent), 220)
        : _shorten(sourceSentences.take(3).join(' '), 220);

    return [
      'Chapter summary: $summary',
      'Ordered coverage points:',
      if (coverage.isEmpty)
        '1. Discuss the chapter title "$title", the main event, the ending, and the meaning.'
      else
        ...coverage,
      'Character and setting facts: Use only characters, places, objects, and events named or clearly implied by this chapter.',
      'Completion rubric: Finish only after the learner has discussed the beginning, key events, important choices, ending, and meaning.',
      'Ability assessment cues: Starter = one-word answers; Beginner = short phrases; Elementary = simple sentences; Pre-Intermediate = connected retelling; Intermediate = clear opinions with reasons; Upper-Intermediate = detailed retelling and inference.',
    ].join('\n');
  }

  static List<String> _coveragePoints(List<String> sentences) {
    if (sentences.isEmpty) {
      return const [];
    }
    final pointCount = min(8, max(1, (sentences.length / 3).ceil()));
    final groupSize = (sentences.length / pointCount).ceil();
    final points = <String>[];
    for (var start = 0; start < sentences.length; start += groupSize) {
      final end = min(sentences.length, start + groupSize);
      final snippet = _coverageSnippet(sentences.sublist(start, end));
      points.add(
        '${points.length + 1}. Sentences ${start + 1}-$end: $snippet',
      );
    }
    return points;
  }

  static String _coverageSnippet(List<String> group) {
    final joined = group.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (joined.length <= 180 || group.length <= 1) {
      return _shorten(joined, 180);
    }
    final first = _shorten(group.first, 82);
    final last = _shorten(group.last, 82);
    return '$first ... $last';
  }

  static List<String> _fallbackSentences(String content) {
    final normalized = _normalizeArticleContent(content);
    if (normalized.isEmpty) {
      return const [];
    }
    return normalized
        .split(RegExp(r'(?<=[.!?])\s+'))
        .map((sentence) => sentence.trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
  }

  static String _normalizeArticleContent(String text) =>
      text.replaceAll(RegExp(r'[ \t]+'), ' ').trim();

  static String _chapterTextForRemoteGuide({
    required String articleContent,
    required List<String> sentences,
  }) {
    final content = _normalizeArticleContent(articleContent);
    if (content.isNotEmpty) {
      return content;
    }
    return sentences
        .map((sentence) => sentence.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((sentence) => sentence.isNotEmpty)
        .join(' ');
  }

  static String _shorten(String text, int maxLength) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= maxLength) {
      return normalized;
    }
    return '${normalized.substring(0, maxLength).trim()}...';
  }
}
