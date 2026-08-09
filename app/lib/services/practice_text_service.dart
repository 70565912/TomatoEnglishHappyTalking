import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/config/app_config.dart';
import '../core/logging/tomato_logger.dart';
import 'read_aloud_splitter_v3.dart';
import 'sentence_split_tuning_budget_v3.dart';
import 'text_generation_service.dart';

class PracticeWordLookup {
  const PracticeWordLookup({
    required this.word,
    required this.phonetic,
    required this.meaning,
    required this.sentenceMeaning,
    required this.source,
  });

  final String word;
  final String phonetic;
  final String meaning;
  final String sentenceMeaning;
  final TextGenerationReplySource source;
}

class PracticeSentenceTranslationBatch {
  const PracticeSentenceTranslationBatch({
    required this.translationsByIndex,
    required this.source,
    this.usage = const TextGenerationUsage(),
  });

  final Map<int, String> translationsByIndex;
  final TextGenerationReplySource source;
  final TextGenerationUsage usage;
}

class PracticeCandidatePathSelectionV3 {
  const PracticeCandidatePathSelectionV3({
    required this.selectedPathIds,
    required this.source,
    required this.remoteAttempts,
    required this.usedLocalFallback,
    required this.fallbackReason,
    required this.usage,
    this.provider,
    this.model,
    this.selectionTrace = const [],
  });

  final Map<int, String> selectedPathIds;
  final TextGenerationReplySource source;
  final int remoteAttempts;
  final bool usedLocalFallback;
  final String? fallbackReason;
  final TextGenerationUsage usage;
  final String? provider;
  final String? model;
  final List<Map<String, dynamic>> selectionTrace;
}

class _CandidatePathResponseV3 {
  const _CandidatePathResponseV3({
    required this.selectedPathIds,
    required this.rejectedOriginalIndexes,
  });

  final Map<int, String> selectedPathIds;
  final Set<int> rejectedOriginalIndexes;
}

class PracticeTextService {
  // Stability budget per Ark request; long source text is chunked, not cut.
  static const _englishPracticePromptChunkTarget = 8000;
  static const _titlePromptInputLimit = 1600;
  static const _sentenceTranslationCachePurpose =
      'article_sentence_translation_batch_v1';
  static const candidatePathReviewCachePurpose =
      'article_split_v3_candidate_path_p7';
  static const _deepSeekCandidatePathReviewCachePurpose =
      'article_split_v3_candidate_path_p8';
  static const sentenceTranslationV3CachePurpose =
      'article_split_translate_v3_translation_v12';
  // Only provider/model pairs that passed the fixed candidate-path tuning gate
  // may make automatic production decisions. Keep weaker models on the
  // deterministic local path even when they are valid for other text tasks.
  static const _validatedCandidateReviewModels = <String>{
    'aliyun_bailian/qwen3.7-max',
    'volcengine/deepseek-v4-flash-ga-260731',
  };
  static const _expandedCompactCandidateReviewModels = <String>{
    'volcengine/deepseek-v4-flash-ga-260731',
  };
  static Set<String>? _validatedCandidateReviewModelsForTest;

  @visibleForTesting
  static void setValidatedCandidateReviewModelsForTest(
    Set<String>? providerModels,
  ) {
    _validatedCandidateReviewModelsForTest = providerModels;
  }

  static Future<PracticeCandidatePathSelectionV3> reviewCandidatePathsV3({
    required ReadAloudSplitPlanV3 plan,
    int? articleId,
    bool allowUnvalidatedModelForTuning = false,
    bool forceRemoteForTuning = false,
    bool forceExpandedCandidatesForTuning = false,
    bool compactCandidatePayloadForTuning = false,
    bool forceP8ProtocolForTuning = false,
    SentenceSplitTuningBudgetV3? tuningBudget,
  }) async {
    final riskOriginals = plan.originals
        .where((decision) => decision.requiresAiReview)
        .toList(growable: false);
    final localSelections = <int, String>{
      for (final decision in plan.originals)
        decision.originalIndex: decision.localPathId,
    };
    if (riskOriginals.isEmpty) {
      return PracticeCandidatePathSelectionV3(
        selectedPathIds: Map.unmodifiable(localSelections),
        source: TextGenerationReplySource.stored,
        remoteAttempts: 0,
        usedLocalFallback: false,
        fallbackReason: null,
        usage: const TextGenerationUsage(),
      );
    }

    final config = await AppConfig.openAiTextConfig;
    final providerModel = '${config.provider}/${config.model}';
    final validatedModels = _validatedCandidateReviewModelsForTest ??
        _validatedCandidateReviewModels;
    if (allowUnvalidatedModelForTuning && tuningBudget == null) {
      throw const FormatException('未配置 50 元硬预算，不得调试未验收的分句模型');
    }
    if (forceRemoteForTuning && !allowUnvalidatedModelForTuning) {
      throw const FormatException('只有受预算保护的调优调用可以跳过分句缓存');
    }
    if (forceExpandedCandidatesForTuning &&
        (!allowUnvalidatedModelForTuning || !forceRemoteForTuning)) {
      throw const FormatException('只有受预算保护的远程调优可以强制首轮使用扩展候选');
    }
    if (compactCandidatePayloadForTuning &&
        (!allowUnvalidatedModelForTuning || !forceRemoteForTuning)) {
      throw const FormatException('只有受预算保护的远程调优可以使用精简候选载荷');
    }
    if (forceP8ProtocolForTuning &&
        (!allowUnvalidatedModelForTuning ||
            !forceRemoteForTuning ||
            tuningBudget == null)) {
      throw const FormatException('只有受预算保护的远程调优可以强制使用 P8 协议');
    }
    if (!validatedModels.contains(providerModel) &&
        !allowUnvalidatedModelForTuning) {
      TomatoLogger.warn(
        category: 'sentence_split',
        event: 'candidate_review.local_fallback',
        articleId: articleId,
        status: 'unvalidated_model',
        data: {
          'provider': config.provider,
          'model': config.model,
          'riskOriginalCount': riskOriginals.length,
        },
      );
      return PracticeCandidatePathSelectionV3(
        selectedPathIds: Map.unmodifiable(localSelections),
        source: TextGenerationReplySource.stored,
        remoteAttempts: 0,
        usedLocalFallback: true,
        fallbackReason: 'unvalidated_provider_model',
        usage: const TextGenerationUsage(),
        provider: config.provider,
        model: config.model,
      );
    }
    final usesProductionP8Protocol =
        _expandedCompactCandidateReviewModels.contains(providerModel);
    final usesP8Protocol = usesProductionP8Protocol || forceP8ProtocolForTuning;
    final candidatePathReviewPurpose = usesP8Protocol
        ? _deepSeekCandidatePathReviewCachePurpose
        : candidatePathReviewCachePurpose;

    return _reviewCandidatePathChunkV3(
      plan: plan,
      riskOriginals: riskOriginals,
      localSelections: localSelections,
      provider: config.provider,
      model: config.model,
      articleId: articleId,
      forceRemoteForTuning: forceRemoteForTuning,
      startWithExpandedCandidates:
          usesP8Protocol || forceExpandedCandidatesForTuning,
      compactCandidatePayload:
          usesP8Protocol || compactCandidatePayloadForTuning,
      candidatePathReviewPurpose: candidatePathReviewPurpose,
      useEnhancedClauseTransitionRule: usesP8Protocol,
      tuningBudget: tuningBudget,
    );
  }

  static Future<PracticeCandidatePathSelectionV3> _reviewCandidatePathChunkV3({
    required ReadAloudSplitPlanV3 plan,
    required List<ReadAloudOriginalDecisionV3> riskOriginals,
    required Map<int, String> localSelections,
    required String provider,
    required String model,
    required int? articleId,
    required bool forceRemoteForTuning,
    required bool startWithExpandedCandidates,
    required bool compactCandidatePayload,
    required String candidatePathReviewPurpose,
    required bool useEnhancedClauseTransitionRule,
    required SentenceSplitTuningBudgetV3? tuningBudget,
  }) async {
    Object? lastError;
    final reviewMaxTokens = math.max(256, riskOriginals.length * 64);
    final trace = <Map<String, dynamic>>[];
    var remoteAttempts = 0;
    var combinedUsage = const TextGenerationUsage();

    if (!forceRemoteForTuning) {
      _CandidatePathResponseV3? cachedParsed;
      final cachedTurns = _candidatePathReviewTurns(
        plan,
        riskOriginals,
        expanded: true,
        compactCandidates: compactCandidatePayload,
        contract: candidatePathReviewPurpose,
        useEnhancedClauseTransitionRule: useEnhancedClauseTransitionRule,
      );
      final cachedReply = await TextGenerationService.readStrictCache(
        turns: cachedTurns,
        cachePurpose: candidatePathReviewPurpose,
        articleId: articleId,
        maxTokens: reviewMaxTokens,
        jsonResponse: true,
        temperature: 0,
        disableThinking: true,
        validateText: (text) {
          cachedParsed = _parseCandidatePathSelection(
            text,
            riskOriginals: riskOriginals,
            expanded: true,
          );
          if (cachedParsed!.rejectedOriginalIndexes.isNotEmpty) {
            throw const TextGenerationException(
              'V3.3 扩展候选缓存不能包含 REJECT。',
            );
          }
        },
      );
      if (cachedReply != null && cachedParsed != null) {
        final completed = <int, String>{
          ...localSelections,
          ...cachedParsed!.selectedPathIds,
        };
        ReadAloudSplitterV3.validateSelectedPathIds(plan, completed);
        trace.add({
          'originalIndexes': riskOriginals
              .map((value) => value.originalIndex)
              .toList(growable: false),
          'request': 0,
          'round': 'expanded',
          'source': 'cached',
          'decision': 'selected',
        });
        return PracticeCandidatePathSelectionV3(
          selectedPathIds: Map.unmodifiable(completed),
          source: TextGenerationReplySource.cached,
          remoteAttempts: 0,
          usedLocalFallback: false,
          fallbackReason: null,
          usage: const TextGenerationUsage(),
          provider: cachedReply.provider ?? provider,
          model: cachedReply.model ?? model,
          selectionTrace: List.unmodifiable(trace),
        );
      }
    }

    var expanded = startWithExpandedCandidates;
    for (var requestNumber = 1; requestNumber <= 2; requestNumber += 1) {
      final reviewTurns = _candidatePathReviewTurns(
        plan,
        riskOriginals,
        expanded: expanded,
        compactCandidates: compactCandidatePayload,
        contract: candidatePathReviewPurpose,
        useEnhancedClauseTransitionRule: useEnhancedClauseTransitionRule,
      );
      final reservation = tuningBudget?.reserve(
        provider: provider,
        model: model,
        turns: reviewTurns,
        maxOutputTokens: reviewMaxTokens,
      );
      try {
        _CandidatePathResponseV3? parsed;
        final reply = await TextGenerationService.generateStrict(
          turns: reviewTurns,
          cachePurpose: candidatePathReviewPurpose,
          articleId: articleId,
          maxTokens: reviewMaxTokens,
          receiveTimeout: Duration(
            seconds: math.min(120, 30 + riskOriginals.length * 4),
          ),
          jsonResponse: true,
          temperature: 0,
          disableThinking: true,
          skipCacheRead: forceRemoteForTuning,
          skipCacheWrite: forceRemoteForTuning,
          validateText: (text) {
            parsed = _parseCandidatePathSelection(
              text,
              riskOriginals: riskOriginals,
              expanded: expanded,
            );
          },
          shouldCacheText: (_) =>
              parsed?.rejectedOriginalIndexes.isEmpty ?? false,
        );
        final response = parsed ??
            _parseCandidatePathSelection(
              reply.text,
              riskOriginals: riskOriginals,
              expanded: expanded,
            );
        if (reply.source == TextGenerationReplySource.remote) {
          remoteAttempts += 1;
        }
        combinedUsage = _combineUsage(combinedUsage, reply.usage);
        reservation?.complete(reply);
        trace.add({
          'originalIndexes': riskOriginals
              .map((value) => value.originalIndex)
              .toList(growable: false),
          'request': requestNumber,
          'round': expanded ? 'expanded' : 'initial',
          'source': reply.source.name,
          'decision': response.rejectedOriginalIndexes.isEmpty
              ? 'selected'
              : 'rejected',
          'rejectedOriginalIndexes':
              response.rejectedOriginalIndexes.toList(growable: false)..sort(),
        });
        if (response.rejectedOriginalIndexes.isNotEmpty) {
          if (requestNumber == 1) {
            expanded = true;
            continue;
          }
          lastError = const TextGenerationException(
            'AI 拒绝了 V3.3 扩展候选。',
          );
          break;
        }
        final completed = <int, String>{
          ...localSelections,
          ...response.selectedPathIds,
        };
        ReadAloudSplitterV3.validateSelectedPathIds(plan, completed);
        return PracticeCandidatePathSelectionV3(
          selectedPathIds: Map.unmodifiable(completed),
          source: reply.source,
          remoteAttempts: remoteAttempts,
          usedLocalFallback: false,
          fallbackReason: null,
          usage: combinedUsage,
          provider: reply.provider ?? provider,
          model: reply.model ?? model,
          selectionTrace: List.unmodifiable(trace),
        );
      } catch (error) {
        reservation?.fail();
        remoteAttempts += 1;
        lastError = error;
        trace.add({
          'originalIndexes': riskOriginals
              .map((value) => value.originalIndex)
              .toList(growable: false),
          'request': requestNumber,
          'round': expanded ? 'expanded' : 'initial',
          'source': 'remote_error',
          'decision': 'invalid_or_failed',
          'errorType': error.runtimeType.toString(),
        });
      }
    }

    final lastDecision = trace.isEmpty ? null : trace.last['decision'];
    final fallbackReason = expanded
        ? lastDecision == 'rejected'
            ? 'expanded_candidates_rejected'
            : 'expanded_remote_failed'
        : 'remote_failed_twice';
    TomatoLogger.warn(
      category: 'sentence_split',
      event: 'candidate_review.local_fallback',
      articleId: articleId,
      status: fallbackReason,
      error: lastError?.runtimeType.toString(),
      data: {
        'provider': provider,
        'model': model,
        'riskOriginalCount': riskOriginals.length,
        'attempts': remoteAttempts,
        'message': lastError.toString(),
      },
    );
    return PracticeCandidatePathSelectionV3(
      selectedPathIds: Map.unmodifiable(localSelections),
      source: TextGenerationReplySource.stored,
      remoteAttempts: remoteAttempts,
      usedLocalFallback: true,
      fallbackReason: fallbackReason,
      usage: combinedUsage,
      provider: provider,
      model: model,
      selectionTrace: List.unmodifiable(trace),
    );
  }

  static TextGenerationUsage _combineUsage(
    TextGenerationUsage left,
    TextGenerationUsage right,
  ) {
    final costs = [left.estimatedCostCny, right.estimatedCostCny]
        .whereType<double>()
        .toList(growable: false);
    return TextGenerationUsage(
      inputTokens: left.inputTokens + right.inputTokens,
      outputTokens: left.outputTokens + right.outputTokens,
      totalTokens: left.totalTokens + right.totalTokens,
      estimatedCostCny: costs.isEmpty
          ? null
          : costs.fold<double>(0, (sum, value) => sum + value),
    );
  }

  static Future<TextGenerationReply> translateToChinese({
    required String text,
    int? articleId,
    String cachePurpose = 'translate_to_chinese',
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const TextGenerationReply(
        text: '',
        source: TextGenerationReplySource.remote,
      );
    }
    if (RegExp(r'[\u3400-\u9FFF]').hasMatch(trimmed) &&
        !RegExp(r'[A-Za-z]').hasMatch(trimmed)) {
      return TextGenerationReply(
        text: trimmed,
        source: TextGenerationReplySource.remote,
      );
    }

    final turns = <TextGenerationTurn>[
      const TextGenerationTurn(
        role: 'system',
        content:
            'You are a precise English-to-Chinese translation engine. Return only natural Simplified Chinese. Do not explain.',
      ),
      TextGenerationTurn(
        role: 'user',
        content:
            'Translate this English learning text into natural Simplified Chinese. Keep names readable and return only the translation:\n\n$trimmed',
      ),
    ];

    final reply = await TextGenerationService.generateStrict(
      turns: turns,
      cachePurpose: cachePurpose,
      articleId: articleId,
      maxTokens: 512,
      skipCacheRead: true,
      skipCacheWrite: true,
    );
    final translated = _cleanTranslation(reply.text);
    if (translated.isEmpty) {
      throw const TextGenerationException('文本提交处理失败：AI 未返回有效中文翻译，请重试。');
    }
    return TextGenerationReply(
      text: translated,
      source: reply.source,
      errorMessage: reply.errorMessage,
    );
  }

  static Future<PracticeSentenceTranslationBatch>
      translateSentencesToChineseStrict({
    required Map<int, String> sentencesByIndex,
    int? articleId,
    bool usePersistentCache = false,
    String? cachePurpose,
  }) async {
    final entries = sentencesByIndex.entries
        .map((entry) => MapEntry(entry.key, entry.value.trim()))
        .where((entry) => entry.value.isNotEmpty)
        .toList(growable: false)
      ..sort((a, b) => a.key.compareTo(b.key));
    if (entries.isEmpty) {
      return const PracticeSentenceTranslationBatch(
        translationsByIndex: {},
        source: TextGenerationReplySource.remote,
      );
    }

    // Article creation deliberately uses one strict remote task for sentence
    // translations: it must block save so safety failures can be edited, but it
    // must not fan out into one API call per sentence again.
    final reply = await TextGenerationService.generateStrict(
      turns: _sentenceTranslationPromptTurns(entries),
      cachePurpose: cachePurpose ?? _sentenceTranslationCachePurpose,
      articleId: articleId,
      maxTokens: _sentenceTranslationMaxTokens(entries.length),
      receiveTimeout: _sentenceTranslationReceiveTimeout(entries.length),
      jsonResponse: true,
      skipCacheRead: !usePersistentCache,
      skipCacheWrite: !usePersistentCache,
    );
    final translations = _parseSentenceTranslationBatch(reply.text, entries);
    return PracticeSentenceTranslationBatch(
      translationsByIndex: translations,
      source: reply.source,
      usage: reply.usage,
    );
  }

  static Future<TextGenerationReply> translateToEnglishForPractice({
    required String content,
    int? articleId,
  }) =>
      translateToEnglishForPracticeStrict(
        content: content,
        articleId: articleId,
      );

  static Future<TextGenerationReply> translateToEnglishForPracticeStrict({
    required String content,
    int? articleId,
  }) async {
    final trimmed = _normalizeEnglishWordJoiners(content.trim());
    if (trimmed.isEmpty) {
      return const TextGenerationReply(
        text: '',
        source: TextGenerationReplySource.remote,
      );
    }
    if (!_containsChineseText(trimmed)) {
      return TextGenerationReply(
        text: _normalizeInWordHyphens(
          trimmed.replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim(),
        ),
        source: TextGenerationReplySource.remote,
      );
    }

    final outputs = <String>[];
    final sources = <TextGenerationReplySource>[];
    for (final chunk in _splitPracticePromptChunks(trimmed)) {
      final prompt = _englishPracticePrompt(chunk);
      final reply = await TextGenerationService.generateStrict(
        turns: prompt.turns,
        cachePurpose: 'translate_to_english_practice',
        articleId: articleId,
        maxTokens: 1600,
        receiveTimeout: const Duration(seconds: 90),
        skipCacheRead: true,
        skipCacheWrite: true,
      );
      final cleaned = _cleanRequiredEnglishPracticeArticle(reply.text);
      outputs.add(cleaned);
      sources.add(reply.source);
    }

    final text = outputs.join('\n\n').trim();
    if (text.isEmpty) {
      throw const TextGenerationException(
        '文本提交处理失败：AI 未返回可保存的英文正文，请重试。',
      );
    }
    return TextGenerationReply(
      text: text,
      source: _combineTextGenerationSources(sources),
    );
  }

  static Future<PracticeWordLookup> lookupWordForLearning({
    required String word,
    required String sentence,
    int? articleId,
  }) async {
    final normalizedWord = _normalizeLookupWord(word);
    if (normalizedWord.isEmpty) {
      throw const FormatException('请选择要查询的英文单词。');
    }

    final normalizedSentence =
        sentence.replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim();
    final turns = <TextGenerationTurn>[
      const TextGenerationTurn(
        role: 'system',
        content:
            'You are a concise English vocabulary helper for Chinese-speaking children. Return only valid compact JSON with keys word, phonetic, meaning, sentenceMeaning. Use Simplified Chinese for meaning and sentenceMeaning. Phonetic should be IPA when possible.',
      ),
      TextGenerationTurn(
        role: 'user',
        content:
            'Word: $normalizedWord\nSentence: $normalizedSentence\nReturn JSON only. meaning is the common Chinese meanings. sentenceMeaning is the meaning of this word in this exact sentence.',
      ),
    ];

    final reply = await TextGenerationService.generateStrict(
      turns: turns,
      cachePurpose: 'word_lookup',
      articleId: articleId,
      maxTokens: 256,
      jsonResponse: true,
      skipCacheRead: true,
      skipCacheWrite: true,
    );
    final parsed = _parseRequiredWordLookupJson(reply.text);
    return PracticeWordLookup(
      word: parsed['word'] ?? normalizedWord,
      phonetic: parsed['phonetic']!,
      meaning: parsed['meaning']!,
      sentenceMeaning: parsed['sentenceMeaning']!,
      source: reply.source,
    );
  }

  static Future<TextGenerationReply> suggestArticleTitle({
    required String content,
    int? articleId,
  }) async {
    final trimmed = content.replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim();
    if (trimmed.isEmpty) {
      throw const FormatException('文章内容为空，无法生成标题。');
    }

    final turns = _articleTitlePrompt(trimmed);
    final reply = await TextGenerationService.generateStrict(
      turns: turns,
      cachePurpose: 'suggest_article_title',
      articleId: articleId,
      maxTokens: 64,
      skipCacheRead: true,
      skipCacheWrite: true,
    );
    return TextGenerationReply(
      text: cleanArticleTitle(reply.text),
      source: reply.source,
      errorMessage: reply.errorMessage,
    );
  }

  /// Normalize a model-returned article title into a short English practice title.
  static String cleanArticleTitle(String text) =>
      _cleanRequiredArticleTitle(text);

  static List<TextGenerationTurn> _articleTitlePrompt(String text) {
    final excerpt = text.length > _titlePromptInputLimit
        ? text.substring(0, _titlePromptInputLimit)
        : text;
    return <TextGenerationTurn>[
      const TextGenerationTurn(
        role: 'system',
        content:
            "You create short English titles for children English practice tasks. Return only the title, 2 to 5 words, title case. Keep necessary apostrophes such as Mother's. Do not add trailing punctuation.",
      ),
      TextGenerationTurn(
        role: 'user',
        content:
            'Create one short English title for this article. Return only the title:\n\n$excerpt',
      ),
    ];
  }

  static List<TextGenerationTurn> _sentenceTranslationPromptTurns(
    List<MapEntry<int, String>> entries,
  ) {
    final payload = jsonEncode({
      'sentences': [
        for (final entry in entries)
          {
            'index': entry.key,
            'english': entry.value,
          },
      ],
    });
    return <TextGenerationTurn>[
      const TextGenerationTurn(
        role: 'system',
        content:
            'You are a precise English-to-Chinese translation engine. Return only valid compact JSON shaped as {"translations":[{"index":0,"chinese":"..."}]}. Preserve every input index exactly once. Use natural Simplified Chinese. Do not explain.',
      ),
      TextGenerationTurn(
        role: 'user',
        content:
            'Translate each English sentence into Simplified Chinese for subtitle display. Keep the same indexes, do not omit or merge items, and return JSON only.\n\n$payload',
      ),
    ];
  }

  static List<TextGenerationTurn> _candidatePathReviewTurns(
    ReadAloudSplitPlanV3 plan,
    List<ReadAloudOriginalDecisionV3> riskOriginals, {
    required bool expanded,
    bool compactCandidates = false,
    required String contract,
    required bool useEnhancedClauseTransitionRule,
  }) {
    final clauseTransitionRule = useEnhancedClauseTransitionRule
        ? 'When the sentence starts with a dependent marker and later reaches the explicit subject of the main clause, the boundary at that clause transition dominates any later split inside the main clause. The fronted dependent unit must include all words attached to its predicate before the boundary. Do not leave a post-predicate time, frequency, degree, or complement phrase at the start of the main clause. Do not split a main-clause predicate or degree modifier from a following infinitival complement that completes its meaning.'
        : 'When the sentence starts with a dependent marker and later reaches the explicit subject of the main clause, the fronted dependent unit must include all words attached to its predicate before the boundary. Do not leave a post-predicate time, frequency, degree, or complement phrase at the start of the main clause.';
    final payload = {
      'contract': contract,
      'parserVersion': plan.parserVersion,
      'parserModelSha256': plan.modelSha256,
      'solverVersion': ReadAloudSplitterV3.solverVersion,
      'originals': [
        for (final decision in riskOriginals)
          _candidateOriginalPayload(
            decision,
            expanded: expanded,
            compact: compactCandidates,
          ),
      ],
    };
    return [
      TextGenerationTurn(
        role: 'system',
        content:
            '''You review English read-aloud segmentation for arbitrary books and article types.

The program has already enforced every hard constraint and has supplied complete candidate paths. Select exactly one supplied candidatePathId for each originalIndex. You must not rewrite the original, invent a path, add a boundary, return token positions, merge original sentences, or translate text.

Judge natural spoken syntax and meaning. Apply these priorities in order:
1. Choose the fewest boundaries that produce complete, natural spoken units. Never add a second boundary when one natural boundary already satisfies the supplied path.
2. Every unit must preserve subject-predicate and predicate-complement structure. Never put a subject or noun phrase at the end of one unit when its finite verb or auxiliary starts the next unit. Never detach a required object, complement, infinitive, or tightly attached modifier from its predicate.
3. Keep each clause introducer with the clause it introduces. A boundary normally goes before a coordinator or subordinating marker, never after it or inside its clause. Prefer a boundary before a parallel coordinated predicate or adverbial clause over detaching a restrictive relative clause from the noun it identifies.
4. $clauseTransitionRule
5. Do not end a unit after an auxiliary, copula, transitive predicate awaiting its complement, infinitive marker, preposition, determiner, possessive, adjective modifying the next noun, compound/name part, phrasal particle, or fixed relation. Do not begin a unit with a stranded complement or modifier.
6. The parser evidence is fallible. Treat stage, totalBoundaryRisk, and dependencyReasons only as soft evidence; they must never override the English text. Check every softWarnings entry explicitly. A path with surface_possible_subject_predicate_separation is unacceptable when the nominal at the end of the left unit is the subject of the verb or auxiliary starting the right unit. A path with surface_predicate_infinitive_separation is unacceptable when the right unit completes the predicate on the left.
7. Among the paths that remain grammatically natural, choose minimumBoundaryCount first. Among equally grammatical paths with the same boundary count, a path with shortFragmentCount 0 strictly dominates a path with one or more fragments under 8 words. A short fragment is acceptable only when every natural path with that boundary count has one, or when grammar itself requires the short unit. This is a short-fragment guard, not a request to balance lengths.
8. Do not split a predicate from an immediately following dependent clause when that clause supplies the endpoint, condition, or circumstance needed to complete the instruction or action. In a coordinated construction, prefer the boundary before the parallel coordinated predicate over a boundary between that predicate and its required condition. Prefer stage "syntax" over "emergency" only when their spoken syntax is equally natural. Do not detach a short restrictive relative clause merely to make lengths look balanced. Length balance is the last consideration.

Return REJECT for an originalIndex when every supplied path violates any rule above or only offers a clearly inferior short fragment while a missing boundary would be required. REJECT is the correct answer in that case; the program will supply a broader second-round list.

If none of the supplied paths is natural, return the exact reserved value "REJECT" as candidatePathId for that originalIndex. Do not use REJECT merely because multiple paths are acceptable.

Return only compact JSON with this exact shape:
{"items":[{"originalIndex":0,"candidatePathId":"provided-id"}]}
Every requested originalIndex must appear exactly once. No other keys.''',
      ),
      TextGenerationTurn(
        role: 'user',
        content: jsonEncode(payload),
      ),
    ];
  }

  static Map<String, dynamic> _candidateOriginalPayload(
    ReadAloudOriginalDecisionV3 decision, {
    required bool expanded,
    bool compact = false,
  }) {
    final paths = expanded
        ? decision.expandedCandidatePaths
        : decision.initialCandidatePaths;
    final minimumBoundaryCount =
        paths.map((path) => path.boundaries.length).reduce(math.min);
    return {
      'originalIndex': decision.originalIndex,
      'original': decision.source,
      'candidateRound': expanded ? 'expanded' : 'initial',
      'candidateSetHash': expanded
          ? decision.expandedCandidateSetHash
          : decision.initialCandidateSetHash,
      'minimumBoundaryCount': minimumBoundaryCount,
      'candidatePaths': [
        for (final path in paths)
          {
            'candidatePathId': path.pathId,
            'segments': path.segments,
            'segmentCount': path.segments.length,
            'boundaryCount': path.boundaries.length,
            'isMinimumBoundaryCount':
                path.boundaries.length == minimumBoundaryCount,
            'shortFragmentCount':
                path.wordCounts.where((count) => count < 8).length,
            'wordCounts': path.wordCounts,
            if (!compact) ...{
              'stage': path.stage.name,
              'totalBoundaryRisk': path.boundaries.fold<int>(
                0,
                (sum, boundary) => sum + boundary.risk,
              ),
              'maxUnpunctuatedWordCounts': path.maxUnpunctuatedWordCounts,
              'boundaries': [
                for (final boundary in path.boundaries)
                  {
                    'kind': boundary.kind.name,
                    'afterWord': boundary.afterWord,
                    'dependencyReasons': boundary.reasons,
                    'softWarnings': boundary.softWarnings,
                    'risk': boundary.risk,
                  },
              ],
            },
          },
      ],
    };
  }

  static _CandidatePathResponseV3 _parseCandidatePathSelection(
    String text, {
    required List<ReadAloudOriginalDecisionV3> riskOriginals,
    required bool expanded,
  }) {
    final decodedValue = _decodeJsonValue(text);
    if (decodedValue is! Map) {
      throw const TextGenerationException(
        'AI 候选路径复核失败：响应不是 JSON object。',
      );
    }
    final decoded = Map<String, dynamic>.from(decodedValue);
    if (decoded.length != 1 || decoded['items'] is! List) {
      throw const TextGenerationException(
        'AI 候选路径复核失败：响应只能包含 items 数组。',
      );
    }
    final items = decoded['items'] as List;
    final requiredIndexes =
        riskOriginals.map((decision) => decision.originalIndex).toSet();
    final output = <int, String>{};
    final rejected = <int>{};
    for (var position = 0; position < items.length; position += 1) {
      final raw = items[position];
      if (raw is! Map) {
        throw TextGenerationException(
          'AI 候选路径复核失败：items 第 ${position + 1} 项不是 object。',
        );
      }
      final item = Map<String, dynamic>.from(raw);
      if (item.length != 2 ||
          !item.containsKey('originalIndex') ||
          !item.containsKey('candidatePathId')) {
        throw TextGenerationException(
          'AI 候选路径复核失败：items 第 ${position + 1} 项字段不符合固定协议。',
        );
      }
      final originalIndex = item['originalIndex'];
      final pathId = item['candidatePathId']?.toString().trim() ?? '';
      if (originalIndex is! int ||
          !requiredIndexes.contains(originalIndex) ||
          pathId.isEmpty ||
          output.containsKey(originalIndex)) {
        throw TextGenerationException(
          'AI 候选路径复核失败：items 第 ${position + 1} 项索引或 pathId 非法。',
        );
      }
      output[originalIndex] = pathId;
      if (pathId == 'REJECT') {
        rejected.add(originalIndex);
        continue;
      }
      final decision = riskOriginals.firstWhere(
        (value) => value.originalIndex == originalIndex,
      );
      final allowed = expanded
          ? decision.expandedCandidatePaths
          : decision.initialCandidatePaths;
      if (!allowed.any((path) => path.pathId == pathId)) {
        throw TextGenerationException(
          'AI 候选路径复核失败：originalIndex=$originalIndex 返回了未提供的 pathId。',
        );
      }
    }
    if (output.keys.toSet().length != requiredIndexes.length ||
        !output.keys.toSet().containsAll(requiredIndexes)) {
      throw const TextGenerationException(
        'AI 候选路径复核失败：未逐一选择所有高风险原句。',
      );
    }
    return _CandidatePathResponseV3(
      selectedPathIds: Map.unmodifiable(
        Map<int, String>.from(output)
          ..removeWhere((_, value) => value == 'REJECT'),
      ),
      rejectedOriginalIndexes: Set.unmodifiable(rejected),
    );
  }

  static int _sentenceTranslationMaxTokens(int sentenceCount) {
    final raw = 768 + sentenceCount * 96;
    return raw.clamp(1024, 12000).toInt();
  }

  static Duration _sentenceTranslationReceiveTimeout(int sentenceCount) {
    final rawSeconds = 90 + sentenceCount * 2;
    return Duration(seconds: rawSeconds.clamp(90, 240).toInt());
  }

  static Map<int, String> _parseSentenceTranslationBatch(
    String text,
    List<MapEntry<int, String>> expectedEntries,
  ) {
    final decoded = _decodeJsonValue(text);
    final translations = <int, String>{};

    void addTranslation(Object? rawIndex, Object? rawValue) {
      final index = _jsonInt(rawIndex);
      if (index == null) {
        return;
      }
      final value = rawValue is Map
          ? rawValue['chinese'] ??
              rawValue['chineseText'] ??
              rawValue['translation']
          : rawValue;
      final chinese = _cleanTranslation(value?.toString() ?? '');
      if (chinese.isEmpty || chinese.startsWith('中文翻译暂不可用')) {
        return;
      }
      translations[index] = chinese;
    }

    void parseList(Object? value) {
      if (value is! List) {
        return;
      }
      for (final item in value) {
        if (item is Map) {
          addTranslation(
            item['index'] ?? item['sentenceIndex'] ?? item['id'],
            item['chinese'] ?? item['chineseText'] ?? item['translation'],
          );
        }
      }
    }

    void parseMap(Object? value) {
      if (value is! Map) {
        return;
      }
      for (final entry in value.entries) {
        addTranslation(entry.key, entry.value);
      }
    }

    if (decoded is List) {
      parseList(decoded);
    } else if (decoded is Map) {
      final body =
          decoded['translations'] ?? decoded['sentences'] ?? decoded['items'];
      parseList(body);
      parseMap(body);
      if (translations.isEmpty) {
        parseMap(decoded);
      }
    }

    final missing = <int>[
      for (final entry in expectedEntries)
        if (!translations.containsKey(entry.key)) entry.key,
    ];
    if (missing.isNotEmpty) {
      throw TextGenerationException(
        '文本提交处理失败：AI 未返回完整中文对照（缺少第 ${missing.first + 1} 句），请重试。',
      );
    }
    return {
      for (final entry in expectedEntries) entry.key: translations[entry.key]!,
    };
  }

  static Object? _decodeJsonValue(String text) {
    final raw = text.trim();
    if (raw.isEmpty) {
      return null;
    }
    try {
      return jsonDecode(raw);
    } catch (_) {
      // Continue with a tolerant extraction below.
    }

    Object? trySlice(int start, int end) {
      if (start < 0 || end <= start) {
        return null;
      }
      try {
        return jsonDecode(raw.substring(start, end + 1));
      } catch (_) {
        return null;
      }
    }

    final object = trySlice(raw.indexOf('{'), raw.lastIndexOf('}'));
    if (object != null) {
      return object;
    }
    return trySlice(raw.indexOf('['), raw.lastIndexOf(']'));
  }

  static int? _jsonInt(Object? value) {
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim());
    }
    return null;
  }

  static ({List<TextGenerationTurn> turns}) _englishPracticePrompt(
    String text,
  ) {
    final trimmed = _normalizeEnglishWordJoiners(text.trim());

    if (_containsEnglishText(trimmed)) {
      return (
        turns: <TextGenerationTurn>[
          const TextGenerationTurn(
            role: 'system',
            content:
                'You prepare English practice story prose from mixed learning material. Keep only the story content in original order. If the story prose is already English, preserve the original English prose and do not rewrite it. If the story content is Chinese and no English story prose is present, translate only that story content into natural English. Remove lesson introductions, headings, dates, authors, explanations, expansion notes, culture cards, vocabulary lists, phonetics, examples, Chinese translations, metadata, and teacher instructions. Return only the final English story prose.',
          ),
          TextGenerationTurn(
            role: 'user',
            content:
                'Extract the story from this mixed learning text. Keep original English story prose when present; if the story is only in Chinese, translate it to English. Remove all non-story material and return only English story prose with normal spacing and punctuation:\n\n$trimmed',
          ),
        ],
      );
    }

    return (
      turns: <TextGenerationTurn>[
        const TextGenerationTurn(
          role: 'system',
          content:
              'You translate Chinese story text into clear natural English for children speaking practice. Return only the English article. Use short, speakable sentences. Do not explain.',
        ),
        TextGenerationTurn(
          role: 'user',
          content:
              'Translate this Chinese learning story into English practice text. Keep the meaning, use natural English, and return only English:\n\n$trimmed',
        ),
      ],
    );
  }

  @visibleForTesting
  static ({List<TextGenerationTurn> turns}) englishPracticePromptForTest(
    String text,
  ) =>
      _englishPracticePrompt(text);

  static List<String> _splitPracticePromptChunks(String text) {
    final trimmed = text.trim();
    if (trimmed.length <= _englishPracticePromptChunkTarget) {
      return [trimmed];
    }

    final paragraphs = trimmed
        .split(RegExp(r'\n\s*\n+'))
        .map((paragraph) => paragraph.trim())
        .where((paragraph) => paragraph.isNotEmpty)
        .toList(growable: false);
    if (paragraphs.length <= 1) {
      return _splitOversizedText(trimmed);
    }

    final chunks = <String>[];
    final buffer = StringBuffer();
    for (final paragraph in paragraphs) {
      if (paragraph.length > _englishPracticePromptChunkTarget) {
        if (buffer.isNotEmpty) {
          chunks.add(buffer.toString().trim());
          buffer.clear();
        }
        chunks.addAll(_splitOversizedText(paragraph));
        continue;
      }

      final separatorLength = buffer.isEmpty ? 0 : 2;
      if (buffer.length + separatorLength + paragraph.length >
          _englishPracticePromptChunkTarget) {
        chunks.add(buffer.toString().trim());
        buffer.clear();
      }
      if (buffer.isNotEmpty) {
        buffer.write('\n\n');
      }
      buffer.write(paragraph);
    }
    if (buffer.isNotEmpty) {
      chunks.add(buffer.toString().trim());
    }
    return chunks;
  }

  static List<String> _splitOversizedText(String text) {
    final chunks = <String>[];
    for (var start = 0; start < text.length;) {
      var end = (start + _englishPracticePromptChunkTarget)
          .clamp(
            0,
            text.length,
          )
          .toInt();
      if (end < text.length) {
        final safeBreak = text.lastIndexOf(RegExp(r'[。！？.!?；;]\s*'), end);
        if (safeBreak > start + (_englishPracticePromptChunkTarget ~/ 2)) {
          end = safeBreak + 1;
        }
      }
      chunks.add(text.substring(start, end).trim());
      start = end;
    }
    return chunks.where((chunk) => chunk.isNotEmpty).toList(growable: false);
  }

  static TextGenerationReplySource _combineTextGenerationSources(
    List<TextGenerationReplySource> sources,
  ) {
    if (sources.isEmpty) {
      throw const TextGenerationException(
        '文本提交处理失败：AI 未返回可保存的英文正文，请重试。',
      );
    }
    if (sources.contains(TextGenerationReplySource.remote)) {
      return TextGenerationReplySource.remote;
    }
    if (sources.contains(TextGenerationReplySource.cached)) {
      return TextGenerationReplySource.cached;
    }
    if (sources.contains(TextGenerationReplySource.stored)) {
      return TextGenerationReplySource.stored;
    }
    throw StateError('Unexpected non-strict text generation source.');
  }

  static String _extractEnglishStoryText(String text) {
    final lines = text
        .replaceAll(RegExp(r'[“”]'), '"')
        .replaceAll(RegExp(r'[‘’]'), "'")
        .split(RegExp(r'[\r\n]+|[。！？；;]+'));
    final kept = <String>[];
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty ||
          RegExp(
            r'^(title|heading|chapter|中文|翻译|译文|词汇|单词|注释|讲解|解析|vocabulary|note|notes|summary)\s*[:：]',
            caseSensitive: false,
          ).hasMatch(line)) {
        continue;
      }
      final englishWords =
          RegExp(r"[A-Za-z][A-Za-z'\-]*").allMatches(line).length;
      if (englishWords < 3) {
        continue;
      }
      final chineseChars = RegExp(r'[\u3400-\u9FFF]').allMatches(line).length;
      if (chineseChars > englishWords * 2) {
        continue;
      }
      final englishLine = line
          .replaceAll(RegExp(r'[\u3400-\u9FFF]+'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (englishLine.isNotEmpty) {
        kept.add(englishLine);
      }
    }

    if (kept.isNotEmpty) {
      return _normalizeInWordHyphens(kept.join(' '));
    }

    final stripped = text
        .replaceAll(RegExp(r'[\u3400-\u9FFF]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return _normalizeInWordHyphens(stripped);
  }

  static Map<String, String> _parseRequiredWordLookupJson(String text) {
    final trimmed = text.trim();
    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const TextGenerationException('单词查询失败：AI 未返回有效单词解释，请重试。');
    }

    try {
      final decoded = jsonDecode(trimmed.substring(start, end + 1));
      if (decoded is! Map) {
        throw const FormatException('word lookup response is not an object');
      }
      final parsed = {
        'word': _jsonString(decoded['word']),
        'phonetic': _jsonString(decoded['phonetic']),
        'meaning': _jsonString(decoded['meaning']),
        'sentenceMeaning': _jsonString(decoded['sentenceMeaning']),
      };
      if (parsed.values.any((value) => value.trim().isEmpty)) {
        throw const FormatException('word lookup response has empty fields');
      }
      return parsed;
    } catch (error) {
      if (error is TextGenerationException) {
        rethrow;
      }
      throw const TextGenerationException('单词查询失败：AI 未返回有效单词解释，请重试。');
    }
  }

  static String _jsonString(Object? value) {
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
    return '';
  }

  static String _cleanTranslation(String text) {
    var cleaned = text.trim();
    cleaned = cleaned.replaceAll(
      RegExp(r'^(中文翻译|翻译|译文)\s*[:：]\s*'),
      '',
    );
    cleaned = cleaned.replaceAll(RegExp(r'^["“]|["”]$'), '').trim();
    return cleaned;
  }

  static String _cleanEnglishPracticeArticle(String text) {
    var cleaned = text.trim();
    cleaned = cleaned.replaceAll(
      RegExp(
        r'^(english article|english text|translation|译文|英文)\s*[:：]\s*',
        caseSensitive: false,
      ),
      '',
    );
    cleaned = cleaned.replaceAll(RegExp(r'[‘’]'), "'");
    cleaned = cleaned.replaceAll(RegExp(r'^["“]|["”]$'), '').trim();
    cleaned = _normalizeInWordHyphens(cleaned);
    if (_containsChineseText(cleaned) && _containsEnglishText(cleaned)) {
      cleaned = _extractEnglishStoryText(cleaned);
    }
    return cleaned;
  }

  static String _cleanRequiredEnglishPracticeArticle(String text) {
    final cleaned = _cleanEnglishPracticeArticle(text).trim();
    if (cleaned.isEmpty ||
        (_containsChineseText(cleaned) && !_containsEnglishText(cleaned))) {
      throw const TextGenerationException(
        '文本提交处理失败：AI 未返回可保存的英文正文，请重试。',
      );
    }
    return cleaned;
  }

  static String _cleanRequiredArticleTitle(String text) {
    var cleaned = text
        .split(RegExp(r'[\r\n]'))
        .first
        .replaceAll(RegExp(r'["“”]'), '')
        .replaceAll(RegExp(r'[‘’]'), "'")
        .replaceFirst(
          RegExp(r'^(title|标题)\s*[:：]\s*', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'[.!?。！？]+$'), '')
        .trim();
    cleaned = _normalizeEnglishWordJoiners(cleaned);
    if (cleaned.isEmpty) {
      throw const TextGenerationException('标题生成失败：AI 未返回有效标题，请重试。');
    }

    final words = cleaned.split(RegExp(r'\s+')).where((word) {
      return RegExp(r'[A-Za-z]').hasMatch(word);
    }).toList(growable: false);
    if (words.isEmpty) {
      throw const TextGenerationException('标题生成失败：AI 未返回有效英文标题，请重试。');
    }

    cleaned = words.take(5).map(_titleCaseWord).join(' ');
    cleaned = _restoreCommonTitlePossessives(cleaned);
    if (cleaned.isEmpty) {
      throw const TextGenerationException('标题生成失败：AI 未返回有效标题，请重试。');
    }
    return cleaned;
  }

  static String _normalizeInWordHyphens(String text) => text.replaceAllMapped(
        RegExp(r'([A-Za-z])\s*-\s*([A-Za-z])'),
        (match) => '${match.group(1)!}-${match.group(2)!}',
      );

  static String _normalizeEnglishWordJoiners(String text) =>
      _normalizeInWordHyphens(text).replaceAllMapped(
        RegExp(r"([A-Za-z])\s*'\s*([A-Za-z])"),
        (match) => "${match.group(1)!}'${match.group(2)!}",
      );

  static bool _containsChineseText(String text) =>
      RegExp(r'[\u3400-\u9FFF]').hasMatch(text);

  static bool _containsEnglishText(String text) =>
      RegExp(r'[A-Za-z]').hasMatch(text);

  static String _normalizeLookupWord(String word) => word
      .replaceAll(RegExp(r'[‘’]'), "'")
      .replaceAll(RegExp(r'^[^A-Za-z]+|[^A-Za-z]+$'), '')
      .trim();

  static String _restoreCommonTitlePossessives(String title) {
    return title
        .replaceAll(RegExp(r"\bMothers\b"), "Mother's")
        .replaceAll(RegExp(r"\bFathers\b"), "Father's")
        .replaceAll(RegExp(r"\bChildrens\b"), "Children's")
        .replaceAll(RegExp(r"\bPeoples\b"), "People's");
  }

  static String _titleCaseWord(String word) {
    final titleWord = word
        .replaceAll(RegExp(r'[‘’]'), "'")
        .replaceAll(RegExp(r"[^A-Za-z'\-]"), '');
    if (titleWord.isEmpty) {
      return word;
    }
    return titleWord.split('-').map(_titleCaseHyphenPart).join('-');
  }

  static String _titleCaseHyphenPart(String part) {
    final pieces = part.split("'");
    if (pieces.isEmpty) {
      return part;
    }

    final first = _capitalizeAsciiWord(pieces.first);
    if (pieces.length == 1) {
      return first;
    }

    final suffixes = pieces.skip(1).map((piece) => piece.toLowerCase());
    return ([first, ...suffixes]).join("'");
  }

  static String _capitalizeAsciiWord(String word) {
    if (word.isEmpty) {
      return word;
    }
    if (word.length == 1) {
      return word.toUpperCase();
    }
    return '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}';
  }
}
