import 'package:flutter/foundation.dart' show visibleForTesting;

import 'text_generation_service.dart';

enum RealtimeReplySource {
  remote,
  cached,
  mockNoKey,
  mockOnError,
}

class RealtimeChatTurn {
  const RealtimeChatTurn({required this.role, required this.content});

  final String role;
  final String content;

  Map<String, String> toJson() => {
        'role': role,
        'content': content,
      };
}

class RealtimeReply {
  const RealtimeReply({
    required this.text,
    required this.source,
    this.errorMessage,
  });

  final String text;
  final RealtimeReplySource source;
  final String? errorMessage;
}

class RealtimeVoiceService {
  static const String _systemPrompt =
      'You are a friendly and encouraging English teacher named Emma. '
      'Use the cached compact chapter teaching guide as the source. Ask one '
      'question at a time and keep each response concise. Guide the learner '
      'through the chapter from beginning to end. When the learner has '
      'discussed the main events, ending, and meaning of the chapter, stop '
      'asking new questions and give a short practice summary plus an English '
      'ability level. Every assistant response must end with these metadata '
      'lines exactly: '
      '[[TOMATO_CHAPTER_DONE: yes/no]] '
      '[[TOMATO_ABILITY_LEVEL: Starter|Beginner|Elementary|Pre-Intermediate|Intermediate|Upper-Intermediate]] '
      '[[TOMATO_SUMMARY: one short summary when done, otherwise empty]].';

  static Future<RealtimeReply> startSession({
    required String chapterGuide,
    String articleTitle = '',
    int? articleId,
  }) async {
    final chapterContext = chapterGuideTurn(
      chapterGuide: chapterGuide,
      articleTitle: articleTitle,
    );
    final turns = <RealtimeChatTurn>[
      conversationSystemTurn(),
      chapterContext,
      const RealtimeChatTurn(
        role: 'user',
        content:
            'Please greet me briefly and ask your first question about the beginning of this chapter.',
      ),
    ];

    return _query(
      turns,
      cachePurpose: 'chat_start',
      articleId: articleId,
    );
  }

  static Future<RealtimeReply> reply({
    required List<RealtimeChatTurn> history,
    required String userMessage,
    required int questionCount,
    bool forceChapterCompletion = false,
    int? articleId,
  }) async {
    final turns = <RealtimeChatTurn>[
      ...history,
      RealtimeChatTurn(role: 'user', content: userMessage),
      if (forceChapterCompletion)
        const RealtimeChatTurn(
          role: 'user',
          content:
              'This is the final turn. If any chapter part is still uncovered, briefly cover it now. Then end the practice with a summary, an ability level, and TOMATO_CHAPTER_DONE: yes.',
        )
      else
        const RealtimeChatTurn(
          role: 'user',
          content:
              'Decide whether the learner has now discussed the chapter beginning, key events, ending, and meaning. If yes, finish with a practice summary and ability level. If no, ask exactly one next question about an uncovered part.',
        ),
    ];

    return _query(
      turns,
      cachePurpose: 'chat_reply',
      articleId: articleId,
    );
  }

  static RealtimeChatTurn conversationSystemTurn() =>
      const RealtimeChatTurn(role: 'system', content: _systemPrompt);

  static RealtimeChatTurn chapterGuideTurn({
    required String chapterGuide,
    String articleTitle = '',
  }) {
    final title =
        articleTitle.trim().isEmpty ? 'Untitled chapter' : articleTitle.trim();
    final guide = _normalizeChapterGuide(chapterGuide);
    return RealtimeChatTurn(
      role: 'user',
      content:
          'Chapter title: $title\n\nCached compact teaching guide:\n$guide\n\nConversation goal: help the learner understand and retell the whole chapter using this guide. Cover the story in order: beginning, important events, character choices, ending, and meaning. Do not invent events outside the guide. Do not finish until the guide coverage points have been discussed or the final-turn instruction is given.',
    );
  }

  @visibleForTesting
  static String chapterGuidePromptForTest({
    required String chapterGuide,
    String articleTitle = '',
  }) =>
      chapterGuideTurn(
        chapterGuide: chapterGuide,
        articleTitle: articleTitle,
      ).content;

  static Future<RealtimeReply> _query(
    List<RealtimeChatTurn> turns, {
    String? fallbackText,
    required String cachePurpose,
    int? articleId,
  }) async {
    final reply = await TextGenerationService.generate(
      turns: turns
          .map((turn) =>
              TextGenerationTurn(role: turn.role, content: turn.content))
          .toList(growable: false),
      cachePurpose: cachePurpose,
      fallbackText: fallbackText ?? _mockResponse(),
      articleId: articleId,
      maxTokens: 700,
    );
    return RealtimeReply(
      text: reply.text,
      source: _mapSource(reply.source),
      errorMessage: reply.errorMessage,
    );
  }

  static RealtimeReplySource _mapSource(TextGenerationReplySource source) {
    switch (source) {
      case TextGenerationReplySource.remote:
        return RealtimeReplySource.remote;
      case TextGenerationReplySource.cached:
        return RealtimeReplySource.cached;
      case TextGenerationReplySource.mockNoKey:
        return RealtimeReplySource.mockNoKey;
      case TextGenerationReplySource.mockOnError:
        return RealtimeReplySource.mockOnError;
    }
  }

  static String _normalizeChapterGuide(String text) =>
      text.replaceAll(RegExp(r'[ \t]+'), ' ').trim();

  static String _mockResponse() =>
      "That's interesting! What do you think is the most important idea in this article?";
}
