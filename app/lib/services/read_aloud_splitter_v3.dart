import 'dart:convert';
import 'dart:math' as math;

import 'read_aloud_display_metrics.dart';

enum ReadAloudBoundaryKindV3 {
  originalSentence,
  strongPunctuation,
  clauseComma,
  phraseComma,
  ambiguousComma,
  dependencyClause,
  dependencyPhrase,
  emergency,
}

enum ReadAloudPathStageV3 {
  unchanged,
  punctuation,
  syntax,
  emergency,
}

enum ReadAloudCandidateRoundV3 {
  initial,
  expanded,
}

enum ReadAloudCandidateDiversityV3 {
  score,
  boundaryDistance,
  boundaryCoverage,
}

class DependencyTokenV3 {
  const DependencyTokenV3({
    required this.id,
    required this.text,
    required this.start,
    required this.end,
    required this.upos,
    required this.head,
    required this.deprel,
    this.sourceText,
  });

  /// One-based token id inside the parsed sentence. Zero is reserved for root.
  final int id;
  final String text;
  final int start;
  final int end;
  final String upos;
  final int head;
  final String deprel;
  final String? sourceText;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'start': start,
        'end': end,
        'upos': upos,
        'head': head,
        'deprel': deprel,
        if (sourceText != null) 'sourceText': sourceText,
      };
}

class DependencySentenceV3 {
  const DependencySentenceV3({
    required this.start,
    required this.end,
    required this.tokens,
    this.parseCost,
    this.parseCostPerToken,
  });

  final int start;
  final int end;
  final List<DependencyTokenV3> tokens;
  final double? parseCost;
  final double? parseCostPerToken;
}

class DependencyDocumentV3 {
  const DependencyDocumentV3({
    required this.parserVersion,
    required this.modelSha256,
    required this.sentences,
    required this.healthy,
    this.issues = const [],
  });

  final String parserVersion;
  final String modelSha256;
  final List<DependencySentenceV3> sentences;
  final bool healthy;
  final List<String> issues;
}

abstract interface class ReadAloudSyntaxParserV3 {
  Future<DependencyDocumentV3> parse(String text);
}

class ReadAloudBoundaryCandidateV3 {
  const ReadAloudBoundaryCandidateV3({
    required this.afterWord,
    required this.kind,
    required this.reasons,
    required this.crossedDependencyArcs,
    required this.protectedRelationCrossings,
    required this.risk,
    this.softWarnings = const [],
    this.hardBlocked = false,
    this.hardBlockReasons = const [],
    this.insideQuotedSpeech = false,
    this.quoteSpanWordCount,
    this.quoteEdge,
  });

  /// One-based count of source words on the left side of this boundary.
  final int afterWord;
  final ReadAloudBoundaryKindV3 kind;
  final List<String> reasons;
  final int crossedDependencyArcs;
  final int protectedRelationCrossings;
  final int risk;
  final List<String> softWarnings;
  final bool hardBlocked;
  final List<String> hardBlockReasons;
  final bool insideQuotedSpeech;
  final int? quoteSpanWordCount;
  final String? quoteEdge;

  bool get isPunctuation =>
      kind == ReadAloudBoundaryKindV3.strongPunctuation ||
      kind == ReadAloudBoundaryKindV3.clauseComma ||
      kind == ReadAloudBoundaryKindV3.phraseComma ||
      kind == ReadAloudBoundaryKindV3.ambiguousComma;

  bool get hasActionableSoftWarnings => softWarnings.any(
        (warning) =>
            !isPunctuation ||
            const {
              'surface_possible_antecedent_possessive_separation',
              'surface_parallel_list_item_separation',
              'quote_edge_attribution_only_tail',
            }.contains(warning),
      );

  bool get isEmergency => kind == ReadAloudBoundaryKindV3.emergency;

  Map<String, dynamic> toJson() => {
        'afterWord': afterWord,
        'kind': kind.name,
        'reasons': reasons,
        'crossedDependencyArcs': crossedDependencyArcs,
        'protectedRelationCrossings': protectedRelationCrossings,
        'risk': risk,
        'softWarnings': softWarnings,
        'hardBlocked': hardBlocked,
        'hardBlockReasons': hardBlockReasons,
        'insideQuotedSpeech': insideQuotedSpeech,
        if (quoteSpanWordCount != null)
          'quoteSpanWordCount': quoteSpanWordCount,
        if (quoteEdge != null) 'quoteEdge': quoteEdge,
      };
}

class ReadAloudCandidatePathV3 {
  const ReadAloudCandidatePathV3({
    required this.pathId,
    required this.originalIndex,
    required this.stage,
    required this.boundaries,
    required this.segments,
    required this.wordCounts,
    required this.maxUnpunctuatedWordCounts,
    required this.score,
    required this.round,
    required this.diversity,
  });

  final String pathId;
  final int originalIndex;
  final ReadAloudPathStageV3 stage;
  final List<ReadAloudBoundaryCandidateV3> boundaries;
  final List<String> segments;
  final List<int> wordCounts;
  final List<int> maxUnpunctuatedWordCounts;

  /// Strict lexicographic score. A lower value is always preferred.
  final List<int> score;
  final ReadAloudCandidateRoundV3 round;
  final ReadAloudCandidateDiversityV3 diversity;

  bool get usesNonPunctuation => boundaries.any(
        (boundary) => !boundary.isPunctuation,
      );

  bool get isEmergency =>
      stage == ReadAloudPathStageV3.emergency ||
      boundaries.any((boundary) => boundary.isEmergency);

  Map<String, dynamic> toJson() => {
        'pathId': pathId,
        'originalIndex': originalIndex,
        'stage': stage.name,
        'boundaries': boundaries.map((value) => value.toJson()).toList(),
        'segments': segments,
        'wordCounts': wordCounts,
        'maxUnpunctuatedWordCounts': maxUnpunctuatedWordCounts,
        'score': score,
        'round': round.name,
        'diversity': diversity.name,
        'usesNonPunctuation': usesNonPunctuation,
        'emergency': isEmergency,
      };
}

class ReadAloudOriginalDecisionV3 {
  const ReadAloudOriginalDecisionV3({
    required this.originalIndex,
    required this.source,
    required this.sourceStart,
    required this.sourceEnd,
    required this.parserHealthy,
    required this.parserIssues,
    required this.initialCandidatePaths,
    required this.expandedCandidatePaths,
    required this.boundaryCandidates,
    required this.localPathId,
    this.parseCost,
    this.parseCostPerToken,
  });

  final int originalIndex;
  final String source;
  final int sourceStart;
  final int sourceEnd;
  final bool parserHealthy;
  final List<String> parserIssues;
  final List<ReadAloudCandidatePathV3> initialCandidatePaths;
  final List<ReadAloudCandidatePathV3> expandedCandidatePaths;
  final List<ReadAloudBoundaryCandidateV3> boundaryCandidates;
  final String localPathId;
  final double? parseCost;
  final double? parseCostPerToken;

  List<ReadAloudCandidatePathV3> get candidatePaths => expandedCandidatePaths;

  String get initialCandidateSetHash =>
      ReadAloudSplitterV3.candidateSetHash(initialCandidatePaths);

  String get expandedCandidateSetHash =>
      ReadAloudSplitterV3.candidateSetHash(expandedCandidatePaths);

  ReadAloudCandidatePathV3 get localPath => initialCandidatePaths.firstWhere(
        (path) => path.pathId == localPathId,
      );

  bool get requiresAiReview =>
      localPath.usesNonPunctuation ||
      localPath.boundaries.any(
        (boundary) =>
            boundary.protectedRelationCrossings > 0 ||
            boundary.hasActionableSoftWarnings ||
            boundary.kind == ReadAloudBoundaryKindV3.ambiguousComma,
      );
}

class ReadAloudSplitPlanV3 {
  const ReadAloudSplitPlanV3({
    required this.parserVersion,
    required this.modelSha256,
    required this.parserHealthy,
    required this.parserIssues,
    required this.originals,
  });

  final String parserVersion;
  final String modelSha256;
  final bool parserHealthy;
  final List<String> parserIssues;
  final List<ReadAloudOriginalDecisionV3> originals;

  List<String> get localSentences => originals
      .expand((decision) => decision.localPath.segments)
      .toList(growable: false);

  bool get requiresAiReview =>
      originals.any((decision) => decision.requiresAiReview);
}

class _SourceWordV3 {
  _SourceWordV3(this.text, this.start, this.end);

  final String text;
  final int start;
  final int end;
  final Set<String> upos = <String>{};
  final Set<String> dependencyRelations = <String>{};
  int? quotedSpeechSpanIndex;
  int? quotedSpeechWordCount;
  int? quotedSpeechStartWord;
  int? quotedSpeechEndWord;
}

class _QuoteSpanV3 {
  const _QuoteSpanV3({
    required this.index,
    required this.start,
    required this.end,
    required this.wordCount,
  });

  final int index;
  final int start;

  /// Exclusive offset immediately after the matching closing quote.
  final int end;
  final int wordCount;
}

class _MappedDependencyV3 {
  const _MappedDependencyV3({
    required this.token,
    required this.wordIndex,
    required this.headWordIndex,
  });

  final DependencyTokenV3 token;
  final int wordIndex;
  final int? headWordIndex;
}

class _PathDraftV3 {
  const _PathDraftV3(this.boundaries, this.ends);

  final List<ReadAloudBoundaryCandidateV3> boundaries;
  final List<int> ends;
}

class _DraftSelectionV3 {
  const _DraftSelectionV3({
    required this.draft,
    required this.round,
    required this.diversity,
  });

  final _PathDraftV3 draft;
  final ReadAloudCandidateRoundV3 round;
  final ReadAloudCandidateDiversityV3 diversity;
}

class _CandidatePathRoundsV3 {
  const _CandidatePathRoundsV3({
    required this.initial,
    required this.expanded,
  });

  final List<ReadAloudCandidatePathV3> initial;
  final List<ReadAloudCandidatePathV3> expanded;
}

/// Canonical native V3 sentence planner.
///
/// The V3 identifiers are intentionally retained for storage compatibility.
/// This implementation is syntax-based and must not acquire project semantic
/// word lists. A parser defect is fixed in the parser/model or generic UD
/// handling, never by adding a word, character name, or book-specific phrase.
class ReadAloudSplitterV3 {
  static const version = 'read_aloud_dp_v3';
  static const reviewedVersion = 'reviewed_dp_v3';
  static const solverVersion = 'syntax_solver_v3_6';
  static const hardMaxWords = 30;
  static const preferredMinUnpunctuatedWords = 8;
  static const preferredMaxUnpunctuatedWords = 16;
  static const targetMaxUnpunctuatedWords = 20;
  static const hardMaxUnpunctuatedWords = 30;
  static const maxCandidatePaths = 8;
  static const maxExpandedCandidatePaths = 24;
  static const expandedBeamWidth = 64;
  static const maxCoverageProbeCandidates = 24;
  static const maxCandidateCountForCoverageProbes = hardMaxWords * 3;
  static const defaultFontSizePx = ReadAloudDisplayMetrics.defaultFontSizePx;
  static const defaultMaxLineWidthPx =
      ReadAloudDisplayMetrics.defaultMaxLineWidthPx;

  static final RegExp _visiblePause = RegExp(r'[.!?…;:—–,]');
  static final RegExp _inlinePause = RegExp(r'[;:—–,]');
  static final RegExp _boundaryPause = RegExp(r'''[.!?…;:—–,]["'”’)}\]]*$''');
  static final RegExp _strongPunctuation = RegExp(r'''[;:—–]["'”’)}\]]*$''');
  static final RegExp _quotedTerminalPunctuation =
      RegExp(r'''[.!?…]["'”’)}\]]*$''');
  static final RegExp _commaPunctuation = RegExp(r''',["'”’)}\]]*$''');
  static final RegExp _nonTerminalTitleAbbreviation = RegExp(
    r'''(?:^|[\s"'“‘])(?:Mr|Mrs|Ms|Dr|Prof|Rev|Capt|Col|Gen|Lt|Sgt|St)\.$''',
    caseSensitive: false,
  );
  static const _protectedRelations = <String>{
    'det',
    'case',
    'aux',
    'cop',
    'mark',
    'cc',
    'compound',
    'compound:prt',
    'fixed',
    'flat',
    'amod',
    'nsubj',
    'csubj',
    'obj',
    'iobj',
    'nummod',
    'nmod:poss',
  };
  static const _clauseRelations = <String>{
    'conj',
    'advcl',
    'ccomp',
    'xcomp',
    'acl',
    'acl:relcl',
    'parataxis',
  };
  static const _phraseRelations = <String>{
    'advmod',
    'appos',
    'dislocated',
    'obl',
    'vocative',
  };
  static const _structuralSoftWarnings = <String>{
    'surface_possible_antecedent_possessive_separation',
    'surface_preposition_attachment_separation',
    'surface_preposition_right_operand_separation',
    'surface_nominal_coordinator_separation',
    'surface_quantifier_numeral_separation',
    'surface_predicate_possessive_object_separation',
    'surface_relative_marker_subject_separation',
    'surface_pronoun_predicate_separation',
    'surface_predicate_complement_marker_separation',
    'surface_predicate_determiner_object_separation',
    'surface_coordinator_right_operand_separation',
    'surface_parallel_list_item_separation',
    'surface_determiner_head_separation',
    'surface_object_relation_separation',
    'surface_subject_predicate_relation_separation',
    'surface_infinitive_marker_predicate_separation',
    'surface_possessive_head_separation',
    'surface_fixed_connector_separation',
    'surface_modifier_head_separation',
    'surface_nominal_relative_pronoun_separation',
    'surface_adverb_attachment_separation',
    'surface_xcomp_predicate_separation',
    'surface_auxiliary_adverb_complement_separation',
    'quote_edge_attribution_only_tail',
  };

  static double measureNunitoExtraBoldPx(
    String text, {
    double fontSizePx = defaultFontSizePx,
  }) =>
      ReadAloudDisplayMetrics.measureNunitoExtraBoldPx(
        text,
        fontSizePx: fontSizePx,
      );

  static bool fitsEnglishLine(String text) =>
      measureNunitoExtraBoldPx(text) <= defaultMaxLineWidthPx;

  static int wordCount(String text) => _sourceWords(text).length;

  static int maxUnpunctuatedWordCount(String text) {
    var run = 0;
    var maximum = 0;
    for (final word in _sourceWords(text)) {
      run += 1;
      if (run > maximum) maximum = run;
      if (_visiblePause.hasMatch(word.text)) run = 0;
    }
    return maximum;
  }

  /// Stable, non-secret fingerprint used by prompt/cache/audit contracts.
  static String candidateSetHash(
    Iterable<ReadAloudCandidatePathV3> paths,
  ) {
    final payload = paths
        .map(
          (path) => jsonEncode({
            'id': path.pathId,
            'segments': path.segments,
            'score': path.score,
          }),
        )
        .join('\n');
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(payload)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static String normalizeForRoundTrip(String text) => text
      .replaceAll(RegExp(r'\r\n?'), '\n')
      .replaceAll(RegExp(r'[‐‑‒]'), '-')
      .replaceAllMapped(
        RegExp(r'([A-Za-z])\s+-\s+(?=[A-Za-z])'),
        (match) => '${match[1]}-',
      )
      .replaceAllMapped(
        RegExp(r'''([—–])(?=[^\s"'”’])'''),
        (match) => '${match[1]} ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAllMapped(
        RegExp(r'([.!?])\s+-(?=[A-Za-z])'),
        (match) => '${match[1]}-',
      )
      .replaceAll(RegExp(r'-\s+'), '-')
      .replaceAllMapped(RegExp(r'([—–])\s+'), (match) => match[1] ?? '')
      .trim();

  /// Compares reviewed sentence blocks with their source while allowing only
  /// whitespace that is introduced or removed at a sentence boundary.
  /// Whitespace and text inside each sentence remain significant.
  static bool isRoundTripEquivalent({
    required String englishContent,
    required List<String> sentences,
  }) =>
      _roundTripMismatch(
        englishContent: englishContent,
        sentences: sentences,
      ) ==
      null;

  static String? _roundTripMismatch({
    required String englishContent,
    required List<String> sentences,
  }) {
    final source = normalizeForRoundTrip(englishContent);
    var cursor = 0;
    for (var index = 0; index < sentences.length; index += 1) {
      final sentence = normalizeForRoundTrip(sentences[index]);
      if (index > 0) {
        final boundaryStart = cursor;
        while (
            cursor < source.length && RegExp(r'\s').hasMatch(source[cursor])) {
          cursor += 1;
        }
        if (cursor == boundaryStart &&
            _isLexicalRoundTripBoundary(source, cursor)) {
          return '第 ${index + 1} 块的句界落在词或缩写内部（正文偏移 $cursor）';
        }
      }
      if (!source.startsWith(sentence, cursor)) {
        final sourceEnd = math.min(source.length, cursor + 120);
        final expectedEnd = math.min(sentence.length, 120);
        return '第 ${index + 1} 块从正文偏移 $cursor 开始不一致；'
            '块=${jsonEncode(sentence.substring(0, expectedEnd))}；'
            '正文=${jsonEncode(source.substring(cursor, sourceEnd))}';
      }
      cursor += sentence.length;
    }
    while (cursor < source.length && RegExp(r'\s').hasMatch(source[cursor])) {
      cursor += 1;
    }
    if (cursor != source.length) {
      final sourceEnd = math.min(source.length, cursor + 120);
      return '末块后仍有正文（偏移 $cursor）；'
          '正文=${jsonEncode(source.substring(cursor, sourceEnd))}';
    }
    return null;
  }

  static bool _isLexicalRoundTripBoundary(String source, int offset) {
    if (offset <= 0 || offset >= source.length) return false;
    bool isAlphaNumeric(String value) =>
        RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(value);
    bool isJoiner(String value) => const {"'", '’', '-'}.contains(value);

    final left = source[offset - 1];
    final right = source[offset];
    final leftContinuesWord = isAlphaNumeric(left) ||
        isJoiner(left) && offset >= 2 && isAlphaNumeric(source[offset - 2]);
    final rightContinuesWord = isAlphaNumeric(right) ||
        isJoiner(right) &&
            offset + 1 < source.length &&
            isAlphaNumeric(source[offset + 1]);
    return leftContinuesWord && rightContinuesWord;
  }

  static ReadAloudSplitPlanV3 plan({
    required String source,
    required DependencyDocumentV3 document,
  }) {
    if (source.trim().isEmpty) {
      throw const FormatException('V3 分句正文不能为空');
    }
    _validateDocument(source, document);
    final quoteSpans = _matchedQuoteSpans(source);
    final parserSentences = _coalesceParserSentencesInsideMatchedQuotes(
      source,
      _coalesceNonTerminalAbbreviationSentences(
        source,
        document.sentences,
      ),
      quoteSpans,
    );
    final originals = <ReadAloudOriginalDecisionV3>[];
    for (var index = 0; index < parserSentences.length; index += 1) {
      final parsedSentence = parserSentences[index];
      final parsedSource = source.substring(
        parsedSentence.start,
        parsedSentence.end,
      );
      if (_sourceWords(parsedSource).isEmpty) continue;

      var sentenceStart = parsedSentence.start;
      if (originals.isEmpty &&
          source.substring(0, sentenceStart).trim().isNotEmpty) {
        sentenceStart = 0;
      }
      var sentenceEnd = parsedSentence.end;
      for (var trailingIndex = index + 1;
          trailingIndex < parserSentences.length;
          trailingIndex += 1) {
        final trailing = parserSentences[trailingIndex];
        final trailingSource = source.substring(trailing.start, trailing.end);
        if (_sourceWords(trailingSource).isNotEmpty) break;
        sentenceEnd = trailing.end;
      }
      final sentenceSource = source.substring(sentenceStart, sentenceEnd);
      final words = _sourceWords(sentenceSource);
      _annotateQuotedSpeechWords(
        words,
        quoteSpans,
        sentenceStart: sentenceStart,
      );
      final mapped = _mapDependencies(
        parsedSentence,
        words,
        sentenceStart: sentenceStart,
      );
      for (final dependency in mapped) {
        words[dependency.wordIndex]
          ..upos.add(dependency.token.upos)
          ..dependencyRelations.add(
            dependency.token.deprel.split(':').first,
          );
      }
      final mappingIssues = <String>[
        if (mapped.length != parsedSentence.tokens.length)
          'dependency_token_offset_mapping_incomplete',
      ];
      final candidates = _boundaryCandidates(
        sentenceSource,
        words,
        mapped,
        sentenceStart: sentenceStart,
        parserTokens: parsedSentence.tokens,
        quoteSpans: quoteSpans,
      );
      final pathRounds = _candidatePaths(
        originalIndex: index,
        sentence: sentenceSource,
        words: words,
        candidates: candidates,
        parserHealthy: document.healthy && mappingIssues.isEmpty,
      );
      if (pathRounds.initial.isEmpty || pathRounds.expanded.isEmpty) {
        throw FormatException('V3 分句无法为第 ${index + 1} 个原句生成可行路径');
      }
      originals.add(
        ReadAloudOriginalDecisionV3(
          originalIndex: index,
          source: sentenceSource,
          sourceStart: sentenceStart,
          sourceEnd: sentenceEnd,
          parserHealthy: document.healthy && mappingIssues.isEmpty,
          parserIssues: List.unmodifiable([
            ...document.issues,
            ...mappingIssues,
          ]),
          initialCandidatePaths: List.unmodifiable(pathRounds.initial),
          expandedCandidatePaths: List.unmodifiable(pathRounds.expanded),
          boundaryCandidates: List.unmodifiable(candidates),
          localPathId: pathRounds.initial.first.pathId,
          parseCost: parsedSentence.parseCost,
          parseCostPerToken: parsedSentence.parseCostPerToken,
        ),
      );
    }
    final plan = ReadAloudSplitPlanV3(
      parserVersion: document.parserVersion,
      modelSha256: document.modelSha256,
      parserHealthy: document.healthy &&
          originals.every((decision) => decision.parserHealthy),
      parserIssues: List.unmodifiable(document.issues),
      originals: List.unmodifiable(originals),
    );
    validateReviewedSentences(
      source,
      plan.localSentences,
      requiredBoundaryWordOffsets: _requiredBoundaryOffsets(originals),
    );
    return plan;
  }

  static void validateSelectedPathIds(
    ReadAloudSplitPlanV3 plan,
    Map<int, String> selectedPathIds,
  ) {
    for (final decision in plan.originals) {
      final selected = selectedPathIds[decision.originalIndex];
      if (selected == null) continue;
      if (!decision.candidatePaths.any((path) => path.pathId == selected)) {
        throw FormatException(
          'AI 为原句 ${decision.originalIndex} 返回了未提供的 candidatePathId',
        );
      }
    }
  }

  static List<String> applySelectedPathIds(
    ReadAloudSplitPlanV3 plan,
    Map<int, String> selectedPathIds,
  ) {
    validateSelectedPathIds(plan, selectedPathIds);
    return plan.originals.expand((decision) {
      final selected =
          selectedPathIds[decision.originalIndex] ?? decision.localPathId;
      return decision.candidatePaths
          .firstWhere((path) => path.pathId == selected)
          .segments;
    }).toList(growable: false);
  }

  static void _validateDocument(
    String source,
    DependencyDocumentV3 document,
  ) {
    if (document.parserVersion.trim().isEmpty ||
        document.modelSha256.trim().isEmpty) {
      throw const FormatException('句法器版本与模型 SHA-256 不能为空');
    }
    if (document.sentences.isEmpty) {
      throw const FormatException('句法器没有返回原文正字句');
    }
    var cursor = 0;
    for (var index = 0; index < document.sentences.length; index += 1) {
      final sentence = document.sentences[index];
      if (sentence.start < cursor ||
          sentence.end <= sentence.start ||
          sentence.end > source.length) {
        throw FormatException('句法器第 ${index + 1} 个句子 offset 非法');
      }
      if (source.substring(cursor, sentence.start).trim().isNotEmpty) {
        throw FormatException('句法器在第 ${index + 1} 个句子前遗漏了正文');
      }
      cursor = sentence.end;
      var lastTokenStart = sentence.start;
      final tokenIds = <int>{};
      for (final token in sentence.tokens) {
        if (token.id <= 0 ||
            !tokenIds.add(token.id) ||
            token.start < sentence.start ||
            token.end <= token.start ||
            token.end > sentence.end ||
            token.start < lastTokenStart ||
            source.substring(token.start, token.end) !=
                (token.sourceText ?? token.text)) {
          throw FormatException('句法器第 ${index + 1} 个句子的 token offset 非法');
        }
        // Multiword tokens can give several UD words the same exact source
        // range. Only start-order is required; sourceText preserves the
        // original span while text remains the parser form.
        lastTokenStart = token.start;
      }
      for (final token in sentence.tokens) {
        if (token.head < 0 ||
            token.head == token.id ||
            (token.head != 0 && !tokenIds.contains(token.head))) {
          throw FormatException('句法器第 ${index + 1} 个句子的依存 head 非法');
        }
      }
    }
    if (source.substring(cursor).trim().isNotEmpty) {
      throw const FormatException('句法器在末句后遗漏了正文');
    }
  }

  /// UDPipe occasionally treats the period in an English title abbreviation
  /// as an orthographic sentence end (for example `"Mr.` / `Toad ...`). Such
  /// a boundary is inside the name, not a valid subtitle or read-aloud cut.
  /// Rejoin only that parser false boundary. Quote-aware coalescing is applied
  /// separately after this parser repair.
  static List<DependencySentenceV3> _coalesceNonTerminalAbbreviationSentences(
    String source,
    List<DependencySentenceV3> sentences,
  ) {
    final output = <DependencySentenceV3>[];
    var index = 0;
    while (index < sentences.length) {
      final group = <DependencySentenceV3>[sentences[index]];
      while (index + 1 < sentences.length &&
          _nonTerminalTitleAbbreviation.hasMatch(
            source.substring(group.first.start, group.last.end).trimRight(),
          )) {
        index += 1;
        group.add(sentences[index]);
      }
      output.add(_coalesceDependencySentenceGroup(group));
      index += 1;
    }
    return List.unmodifiable(output);
  }

  static DependencySentenceV3 _coalesceDependencySentenceGroup(
    List<DependencySentenceV3> group,
  ) {
    if (group.length == 1) return group.single;

    final tokens = <DependencyTokenV3>[];
    double? parseCost = 0;
    for (final sentence in group) {
      if (sentence.parseCost == null) parseCost = null;
      if (parseCost != null) parseCost += sentence.parseCost!;

      final nextIdByOldId = <int, int>{};
      for (final token in sentence.tokens) {
        nextIdByOldId[token.id] = tokens.length + nextIdByOldId.length + 1;
      }
      for (final token in sentence.tokens) {
        tokens.add(
          DependencyTokenV3(
            id: nextIdByOldId[token.id]!,
            text: token.text,
            start: token.start,
            end: token.end,
            upos: token.upos,
            head: token.head == 0 ? 0 : nextIdByOldId[token.head]!,
            deprel: token.deprel,
            sourceText: token.sourceText,
          ),
        );
      }
    }
    final parseCostPerToken =
        parseCost == null || tokens.isEmpty ? null : parseCost / tokens.length;
    return DependencySentenceV3(
      start: group.first.start,
      end: group.last.end,
      tokens: List.unmodifiable(tokens),
      parseCost: parseCost,
      parseCostPerToken: parseCostPerToken,
    );
  }

  /// Keeps UDPipe's orthographic analysis intact while allowing the read-aloud
  /// solver to compare quote-internal and quote-external cuts in one lattice.
  /// Only parser boundaries strictly inside a fully matched quote are joined.
  static List<DependencySentenceV3> _coalesceParserSentencesInsideMatchedQuotes(
    String source,
    List<DependencySentenceV3> sentences,
    List<_QuoteSpanV3> quoteSpans,
  ) {
    final output = <DependencySentenceV3>[];
    var index = 0;
    while (index < sentences.length) {
      final group = <DependencySentenceV3>[sentences[index]];
      while (index + 1 < sentences.length) {
        final boundary = group.last.end;
        final liesInsideMatchedQuote = quoteSpans.any(
          (span) => boundary > span.start && boundary < span.end - 1,
        );
        if (!liesInsideMatchedQuote) break;
        index += 1;
        group.add(sentences[index]);
      }
      output.add(_coalesceDependencySentenceGroup(group));
      index += 1;
    }
    return List.unmodifiable(output);
  }

  /// Finds straight and curly double-quoted speech within each paragraph.
  /// Unmatched quote state is deliberately discarded at paragraph breaks so a
  /// malformed or poetic paragraph cannot absorb later parser sentences.
  static List<_QuoteSpanV3> _matchedQuoteSpans(String source) {
    final spans = <_QuoteSpanV3>[];
    final paragraphBreak = RegExp(r'(?:\r?\n)[ \t]*(?:\r?\n)+');
    var paragraphStart = 0;
    final straightOpenings = <int>[];
    final curlyOpenings = <int>[];

    void scanParagraph(int start, int end) {
      final carriedStraightOpening = straightOpenings.isNotEmpty;
      final carriedCurlyOpening = curlyOpenings.isNotEmpty;
      var sawStraightQuote = false;
      var sawCurlyQuote = false;
      for (var offset = start; offset < end; offset += 1) {
        final character = source[offset];
        if (character == '"') {
          final opens = _straightQuoteOpens(
            source,
            offset,
            paragraphStart: start,
            paragraphEnd: end,
            hasUnclosedQuote: straightOpenings.isNotEmpty,
          );
          if (!sawStraightQuote && carriedStraightOpening && opens) {
            // A new paragraph that starts another quotation does not close an
            // abandoned opening from earlier prose. A closing mark may still
            // complete a quote whose visual layout spans blank lines.
            straightOpenings.clear();
          }
          sawStraightQuote = true;
          if (opens) {
            straightOpenings.add(offset);
          } else if (straightOpenings.isNotEmpty) {
            final straightOpening = straightOpenings.removeLast();
            spans.add(
              _QuoteSpanV3(
                index: spans.length,
                start: straightOpening,
                end: offset + 1,
                wordCount:
                    wordCount(source.substring(straightOpening, offset + 1)),
              ),
            );
          }
        } else if (character == '“') {
          if (!sawCurlyQuote && carriedCurlyOpening) {
            curlyOpenings.clear();
          }
          sawCurlyQuote = true;
          curlyOpenings.add(offset);
        } else if (character == '”' && curlyOpenings.isNotEmpty) {
          sawCurlyQuote = true;
          final curlyOpening = curlyOpenings.removeLast();
          spans.add(
            _QuoteSpanV3(
              index: spans.length,
              start: curlyOpening,
              end: offset + 1,
              wordCount: wordCount(source.substring(curlyOpening, offset + 1)),
            ),
          );
        }
      }
    }

    for (final match in paragraphBreak.allMatches(source)) {
      scanParagraph(paragraphStart, match.start);
      paragraphStart = match.end;
    }
    scanParagraph(paragraphStart, source.length);
    spans.sort((left, right) => left.start.compareTo(right.start));
    return List.unmodifiable([
      for (var index = 0; index < spans.length; index += 1)
        _QuoteSpanV3(
          index: index,
          start: spans[index].start,
          end: spans[index].end,
          wordCount: spans[index].wordCount,
        ),
    ]);
  }

  /// Classifies an ASCII double quote from its surface context instead of
  /// blindly alternating open/close state. Gutenberg prose can begin with the
  /// closing mark of speech started in an omitted paragraph, and can contain
  /// same-mark nested song quotations such as `returns—"Lest ...`. Alternation
  /// would shift every later quote in that paragraph and leave real short
  /// speech unprotected.
  static bool _straightQuoteOpens(
    String source,
    int offset, {
    required int paragraphStart,
    required int paragraphEnd,
    required bool hasUnclosedQuote,
  }) {
    if (offset <= paragraphStart) return true;
    if (offset + 1 >= paragraphEnd) return false;

    final previous = source[offset - 1];
    final next = source[offset + 1];
    final previousIsSpace = previous.trim().isEmpty;
    final nextIsSpace = next.trim().isEmpty;

    // `...!"  "Next...` is a closing mark followed by an opening mark.
    if (!previousIsSpace && nextIsSpace) return false;
    if (previousIsSpace && !nextIsSpace) return true;
    if (next == '"') return false;
    if (previous == '"') return true;

    // Narration commonly introduces speech after a colon or dash. A dash on
    // the right, by contrast, normally continues narration after a closing
    // quote: `song"—then`.
    if ('([{<:—–'.contains(previous)) return true;
    if (')]}>.。,!?;—–'.contains(next)) return false;
    if ('.。,!?;'.contains(previous)) return false;

    // Only genuinely ambiguous word-adjacent marks fall back to stack state.
    return !hasUnclosedQuote;
  }

  static void _annotateQuotedSpeechWords(
    List<_SourceWordV3> words,
    List<_QuoteSpanV3> quoteSpans, {
    required int sentenceStart,
  }) {
    final firstWordBySpan = <int, int>{};
    final lastWordBySpan = <int, int>{};
    final wordCountBySpan = <int, int>{};
    for (var wordIndex = 0; wordIndex < words.length; wordIndex += 1) {
      final word = words[wordIndex];
      final lexical =
          RegExp(r'[\p{L}\p{N}]', unicode: true).firstMatch(word.text);
      if (lexical == null) continue;
      final lexicalOffset = sentenceStart + word.start + lexical.start;
      final span = _innermostQuoteSpanAtOffset(quoteSpans, lexicalOffset);
      if (span == null) continue;
      word.quotedSpeechSpanIndex = span.index;
      firstWordBySpan.putIfAbsent(span.index, () => wordIndex);
      lastWordBySpan[span.index] = wordIndex + 1;
      wordCountBySpan.update(span.index, (count) => count + 1,
          ifAbsent: () => 1);
    }
    for (final word in words) {
      final spanIndex = word.quotedSpeechSpanIndex;
      if (spanIndex == null) continue;
      word.quotedSpeechWordCount = wordCountBySpan[spanIndex];
      word.quotedSpeechStartWord = firstWordBySpan[spanIndex];
      word.quotedSpeechEndWord = lastWordBySpan[spanIndex];
    }
  }

  static _QuoteSpanV3? _innermostQuoteSpanAtOffset(
    List<_QuoteSpanV3> quoteSpans,
    int offset,
  ) {
    _QuoteSpanV3? result;
    for (final span in quoteSpans) {
      if (offset <= span.start || offset >= span.end - 1) continue;
      if (result == null ||
          span.start >= result.start && span.end <= result.end) {
        result = span;
      }
    }
    return result;
  }

  static List<_SourceWordV3> _sourceWords(String sentence) {
    final words = <_SourceWordV3>[];
    final lexical = RegExp(r'[\p{L}\p{N}]', unicode: true);
    final startsLexical = RegExp(
      r'''^["'“‘(\[]*[\p{L}\p{N}]''',
      unicode: true,
    );
    int? pendingPunctuationStart;

    void appendPart(int start, int end) {
      if (start >= end) return;
      final text = sentence.substring(start, end);
      if (lexical.hasMatch(text)) {
        final effectiveStart = pendingPunctuationStart ?? start;
        pendingPunctuationStart = null;
        words.add(
          _SourceWordV3(
            sentence.substring(effectiveStart, end),
            effectiveStart,
            end,
          ),
        );
        return;
      }
      if (words.isNotEmpty) {
        final previous = words.removeLast();
        words.add(
          _SourceWordV3(
            sentence.substring(previous.start, end),
            previous.start,
            end,
          ),
        );
      } else {
        pendingPunctuationStart ??= start;
      }
    }

    for (final match in RegExp(r'\S+').allMatches(sentence)) {
      final token = match.group(0)!;
      var partStart = 0;
      for (var offset = 0; offset + 1 < token.length; offset += 1) {
        final punctuation = token[offset];
        if (!_inlinePause.hasMatch(punctuation) ||
            !startsLexical.hasMatch(token.substring(offset + 1))) {
          continue;
        }
        final previous = offset > 0 ? token[offset - 1] : '';
        final next = token[offset + 1];
        if (const {',', ':'}.contains(punctuation) &&
            RegExp(r'\d').hasMatch(previous) &&
            RegExp(r'\d').hasMatch(next)) {
          continue;
        }
        appendPart(match.start + partStart, match.start + offset + 1);
        partStart = offset + 1;
      }
      appendPart(match.start + partStart, match.end);
    }
    return words;
  }

  static List<_MappedDependencyV3> _mapDependencies(
    DependencySentenceV3 sentence,
    List<_SourceWordV3> words, {
    required int sentenceStart,
  }) {
    final wordByTokenId = <int, int>{};
    for (final token in sentence.tokens) {
      final relativeStart = token.start - sentenceStart;
      final relativeEnd = token.end - sentenceStart;
      var wordIndex = words.indexWhere(
        (word) => relativeStart >= word.start && relativeEnd <= word.end,
      );
      if (wordIndex < 0) {
        // UDPipe can keep leading inline punctuation with the lexical token
        // after it (for example `—everything`). The subtitle word lattice
        // deliberately puts the dash on the left chunk, so that parser token
        // spans two lattice words. Attribute it to the word with the greatest
        // alphanumeric overlap; on a tie prefer the word after the pause.
        var bestLexicalOverlap = -1;
        var bestRawOverlap = 0;
        for (var index = 0; index < words.length; index += 1) {
          final word = words[index];
          final overlapStart = math.max(relativeStart, word.start);
          final overlapEnd = math.min(relativeEnd, word.end);
          if (overlapStart >= overlapEnd) continue;
          final overlap = word.text.substring(
            overlapStart - word.start,
            overlapEnd - word.start,
          );
          final lexicalOverlap = RegExp(
            r'[\p{L}\p{N}]',
            unicode: true,
          ).allMatches(overlap).length;
          if (lexicalOverlap > bestLexicalOverlap ||
              lexicalOverlap == bestLexicalOverlap &&
                  overlap.length > bestRawOverlap ||
              lexicalOverlap == bestLexicalOverlap &&
                  overlap.length == bestRawOverlap &&
                  index > wordIndex) {
            bestLexicalOverlap = lexicalOverlap;
            bestRawOverlap = overlap.length;
            wordIndex = index;
          }
        }
      }
      if (wordIndex >= 0) wordByTokenId[token.id] = wordIndex;
    }
    return [
      for (final token in sentence.tokens)
        if (wordByTokenId[token.id] != null)
          _MappedDependencyV3(
            token: token,
            wordIndex: wordByTokenId[token.id]!,
            headWordIndex: token.head == 0 ? null : wordByTokenId[token.head],
          ),
    ];
  }

  static List<ReadAloudBoundaryCandidateV3> _boundaryCandidates(
    String sentence,
    List<_SourceWordV3> words,
    List<_MappedDependencyV3> dependencies, {
    required int sentenceStart,
    required List<DependencyTokenV3> parserTokens,
    required List<_QuoteSpanV3> quoteSpans,
  }) {
    final output = <ReadAloudBoundaryCandidateV3>[];
    for (var afterWord = 1; afterWord < words.length; afterWord += 1) {
      final left = words[afterWord - 1].text;
      final leftQuoteSpan = words[afterWord - 1].quotedSpeechSpanIndex;
      final rightQuoteSpan = words[afterWord].quotedSpeechSpanIndex;
      final boundaryOffset = sentenceStart + words[afterWord - 1].end;
      final containingQuoteSpan =
          _innermostQuoteSpanAtOffset(quoteSpans, boundaryOffset);
      final insideQuotedSpeech = containingQuoteSpan != null;
      final quoteSpanWordCount = containingQuoteSpan?.wordCount ??
          (leftQuoteSpan != null
              ? words[afterWord - 1].quotedSpeechWordCount
              : words[afterWord].quotedSpeechWordCount);
      final quoteEdge = insideQuotedSpeech
          ? null
          : leftQuoteSpan != null && rightQuoteSpan != null
              ? 'between_quotes'
              : leftQuoteSpan != null
                  ? 'after_closing'
                  : rightQuoteSpan != null
                      ? 'before_opening'
                      : null;
      final spanningTokens = parserTokens
          .where(
            (token) =>
                token.start < boundaryOffset && token.end > boundaryOffset,
          )
          .toList(growable: false);
      final hardBlockReasons = <String>[
        if (spanningTokens.isNotEmpty && !_boundaryPause.hasMatch(left))
          'inside_parser_token:${spanningTokens.map((token) => token.id).join(',')}',
        if (insideQuotedSpeech &&
            quoteSpanWordCount != null &&
            quoteSpanWordCount <= preferredMaxUnpunctuatedWords)
          'inside_short_complete_quote',
      ];
      final crossings = dependencies.where((dependency) {
        if (dependency.token.deprel.split(':').first == 'punct') {
          return false;
        }
        final head = dependency.headWordIndex;
        if (head == null || head == dependency.wordIndex) return false;
        return (dependency.wordIndex < afterWord) != (head < afterWord);
      }).toList(growable: false);
      final protectedCrossings = crossings.where(
        (dependency) {
          final relation = dependency.token.deprel;
          return _protectedRelations.contains(relation) ||
              _protectedRelations.contains(relation.split(':').first);
        },
      ).length;
      final subtreeRelations = crossings
          .map((dependency) => dependency.token.deprel)
          .where(
            (relation) =>
                _clauseRelations.contains(relation) ||
                _phraseRelations.contains(relation),
          )
          .toList(growable: false);
      final oneLegalSubtreeArc =
          crossings.length == 1 && subtreeRelations.length == 1;
      final oneLegalClauseSubtreeArc = oneLegalSubtreeArc &&
          _clauseRelations.contains(subtreeRelations.single) &&
          (subtreeRelations.single != 'conj' ||
              const {'VERB', 'AUX'}.contains(crossings.single.token.upos));
      final hasClauseSubtreeArc =
          subtreeRelations.any(_clauseRelations.contains);
      final hasPhraseSubtreeArc =
          subtreeRelations.any(_phraseRelations.contains);
      final hasRightSubjectPredicateClause =
          _hasRightSubjectPredicateClause(afterWord, dependencies);
      final leftDependencies = dependencies
          .where((dependency) => dependency.wordIndex == afterWord - 1)
          .toList(growable: false);
      final rightDependencies = dependencies
          .where((dependency) => dependency.wordIndex == afterWord)
          .toList(growable: false);
      final right = words[afterWord].text;
      final leftLexeme = _edgeLexeme(left);
      final rightLexeme = _edgeLexeme(right);
      final nextDependencies = dependencies
          .where((dependency) => dependency.wordIndex == afterWord + 1)
          .toList(growable: false);
      final softWarnings = <String>[
        if (leftDependencies.any(
              (dependency) => const {'NOUN', 'PROPN', 'PRON'}
                  .contains(dependency.token.upos),
            ) &&
            !_boundaryPause.hasMatch(left) &&
            rightDependencies.any(
              (dependency) =>
                  const {'VERB', 'AUX'}.contains(dependency.token.upos),
            ))
          'surface_possible_subject_predicate_separation',
        if (leftDependencies.any(
              (dependency) =>
                  const {'VERB', 'AUX'}.contains(dependency.token.upos),
            ) &&
            !_boundaryPause.hasMatch(left) &&
            rightDependencies.any(
              (dependency) =>
                  const {'PART', 'SCONJ', 'ADP'}
                      .contains(dependency.token.upos) &&
                  dependency.token.deprel.split(':').first == 'mark',
            ))
          'surface_predicate_infinitive_separation',
        if (leftDependencies.any(
              (dependency) =>
                  const {'NOUN', 'PROPN'}.contains(dependency.token.upos),
            ) &&
            rightDependencies.any(
              (dependency) =>
                  const {'PRON', 'DET'}.contains(dependency.token.upos) &&
                  dependency.token.deprel == 'nmod:poss',
            ))
          'surface_possible_antecedent_possessive_separation',
        'surface_possible_subject_predicate_separation',
        'surface_predicate_infinitive_separation',
        if (!_boundaryPause.hasMatch(left) &&
            const {
              'of',
              'in',
              'on',
              'at',
              'by',
              'with',
              'from',
              'to',
              'for',
              'between',
              'beneath',
              'under',
              'over',
              'round',
              'through',
              'into',
              'upon',
              'across',
              'like',
            }.contains(rightLexeme) &&
            (rightLexeme == 'of' ||
                leftDependencies.any(
                  (dependency) => const {
                    'VERB',
                    'AUX',
                    'ADJ',
                    'PRON',
                    'DET',
                    'ADP',
                    'ADV',
                  }.contains(dependency.token.upos),
                )))
          'surface_preposition_attachment_separation',
        if (!_boundaryPause.hasMatch(left) &&
            const {
              'of',
              'in',
              'on',
              'at',
              'by',
              'with',
              'from',
              'to',
              'for',
              'between',
              'beneath',
              'under',
              'over',
              'round',
              'through',
              'into',
              'upon',
              'across',
              'like',
            }.contains(leftLexeme) &&
            rightDependencies.any(
              (dependency) => dependency.token.upos != 'PUNCT',
            ))
          'surface_preposition_right_operand_separation',
        if (!_boundaryPause.hasMatch(left) &&
            const {'and', 'or', 'nor', 'but'}.contains(leftLexeme) &&
            rightDependencies.any(
              (dependency) => const {
                'NOUN',
                'PROPN',
                'PRON',
                'DET',
                'ADJ',
                'VERB',
                'AUX',
              }.contains(dependency.token.upos),
            ))
          'surface_coordinator_right_operand_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (dependency) => dependency.token.upos == 'DET',
            ) &&
            rightDependencies.any(
              (dependency) => const {
                'NOUN',
                'PROPN',
                'PRON',
                'DET',
                'ADJ',
                'VERB',
                'AUX',
              }.contains(dependency.token.upos),
            ))
          'surface_determiner_head_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (dependency) =>
                  dependency.token.deprel == 'nmod:poss' &&
                  dependency.headWordIndex != null &&
                  dependency.headWordIndex! >= afterWord,
            ))
          'surface_possessive_head_separation',
        if (!_boundaryPause.hasMatch(left) &&
            rightDependencies.any(
              (dependency) =>
                  const {'obj', 'iobj'}
                      .contains(dependency.token.deprel.split(':').first) &&
                  dependency.headWordIndex != null &&
                  dependency.headWordIndex! < afterWord,
            ))
          'surface_object_relation_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (dependency) =>
                  const {'nsubj', 'csubj'}
                      .contains(dependency.token.deprel.split(':').first) &&
                  dependency.headWordIndex != null &&
                  dependency.headWordIndex! >= afterWord,
            ))
          'surface_subject_predicate_relation_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftLexeme == 'to' &&
            rightDependencies.any(
              (dependency) => dependency.token.upos == 'VERB',
            ))
          'surface_infinitive_marker_predicate_separation',
        if (!_boundaryPause.hasMatch(left) &&
            const {
              'as:if',
              'as:though',
              'even:if',
              'even:though',
              'rather:than',
              'so:that',
              'such:as',
              'that:if',
              'that:when',
              'that:because',
              'that:although',
              'that:though',
              'that:while',
            }.contains('$leftLexeme:$rightLexeme'))
          'surface_fixed_connector_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (dependency) =>
                  dependency.token.upos == 'ADJ' ||
                  (const {'amod', 'compound'}.contains(
                        dependency.token.deprel.split(':').first,
                      ) &&
                      dependency.headWordIndex != null &&
                      dependency.headWordIndex! >= afterWord),
            ) &&
            rightDependencies.any(
              (dependency) =>
                  const {'NOUN', 'PROPN'}.contains(dependency.token.upos),
            ))
          'surface_modifier_head_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (dependency) =>
                  const {'NOUN', 'PROPN'}.contains(dependency.token.upos),
            ) &&
            rightDependencies.any(
              (dependency) => dependency.token.upos == 'PRON',
            ))
          'surface_nominal_relative_pronoun_separation',
        if (!_boundaryPause.hasMatch(left) &&
            rightDependencies.any(
              (dependency) =>
                  dependency.token.deprel.split(':').first == 'advmod' &&
                  dependency.headWordIndex != null &&
                  dependency.headWordIndex! < afterWord,
            ))
          'surface_adverb_attachment_separation',
        if (!_boundaryPause.hasMatch(left) &&
            rightDependencies.any(
              (dependency) =>
                  dependency.token.deprel.split(':').first == 'xcomp' &&
                  dependency.headWordIndex != null &&
                  dependency.headWordIndex! < afterWord,
            ))
          'surface_xcomp_predicate_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (dependency) => dependency.token.upos == 'AUX',
            ) &&
            rightDependencies.any(
              (dependency) => dependency.token.upos == 'ADV',
            ))
          'surface_auxiliary_adverb_complement_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (dependency) => const {'NOUN', 'PROPN', 'PRON'}
                  .contains(dependency.token.upos),
            ) &&
            const {'and', 'or', 'nor'}.contains(rightLexeme) &&
            nextDependencies.any(
              (dependency) => const {'NOUN', 'PROPN', 'PRON', 'DET', 'ADJ'}
                  .contains(dependency.token.upos),
            ))
          'surface_nominal_coordinator_separation',
        if (!_boundaryPause.hasMatch(left) &&
            const {'all', 'both', 'either', 'neither'}.contains(leftLexeme) &&
            const {
              'one',
              'two',
              'three',
              'four',
              'five',
              'six',
              'seven',
              'eight',
              'nine',
              'ten',
            }.contains(rightLexeme))
          'surface_quantifier_numeral_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (dependency) =>
                  const {'VERB', 'AUX'}.contains(dependency.token.upos),
            ) &&
            const {'my', 'your', 'his', 'her', 'its', 'our', 'their'}
                .contains(rightLexeme))
          'surface_predicate_possessive_object_separation',
        if (!_boundaryPause.hasMatch(left) &&
            const {
              'where',
              'wherever',
              'when',
              'whenever',
              'while',
              'which',
              'whichever',
              'who',
              'whoever',
              'whom',
              'whose',
              'whatever',
              'that',
              'if',
              'unless',
              'because',
              'although',
              'though',
              'until',
              'since',
              'before',
              'after',
              'once',
              'as',
            }.contains(leftLexeme) &&
            rightDependencies.any(
              (dependency) => const {'PRON', 'DET', 'NOUN', 'PROPN'}
                  .contains(dependency.token.upos),
            ))
          'surface_relative_marker_subject_separation',
        if (!_boundaryPause.hasMatch(left) &&
            const {
              'i',
              'you',
              'he',
              'she',
              'it',
              'we',
              'they',
              'me',
              'him',
              'her',
              'us',
              'them',
            }.contains(leftLexeme) &&
            rightDependencies.any(
              (dependency) =>
                  const {'VERB', 'AUX'}.contains(dependency.token.upos),
            ))
          'surface_pronoun_predicate_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (dependency) =>
                  const {'VERB', 'AUX'}.contains(dependency.token.upos),
            ) &&
            const {'that', 'whether', 'if'}.contains(rightLexeme))
          'surface_predicate_complement_marker_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (dependency) =>
                  const {'VERB', 'AUX'}.contains(dependency.token.upos),
            ) &&
            rightDependencies.any(
              (dependency) => dependency.token.upos == 'DET',
            ))
          'surface_predicate_determiner_object_separation',
        if (_commaPunctuation.hasMatch(left) &&
            !hasRightSubjectPredicateClause &&
            (leftDependencies.any(
                  (dependency) => dependency.token.upos == 'ADJ',
                ) ||
                RegExp(r'(?:ed|en|ful|ing|ive|less|ous)$')
                    .hasMatch(leftLexeme)) &&
            !const {
              'a',
              'an',
              'the',
              'this',
              'that',
              'these',
              'those',
              'and',
              'or',
              'but',
            }.contains(rightLexeme) &&
            nextDependencies.any(
              (dependency) =>
                  const {'NOUN', 'PROPN'}.contains(dependency.token.upos),
            ))
          'surface_parallel_list_item_separation',
        if (quoteEdge == 'after_closing' &&
            _isAttributionOnlyRightTail(afterWord, dependencies))
          'quote_edge_attribution_only_tail',
      ];
      final protectsQuotedAttribution = _commaPunctuation.hasMatch(left) &&
              RegExp(r'''^["'“‘]''').hasMatch(right) ||
          RegExp(r''',["'”’]$''').hasMatch(left) &&
              RegExp(r'^[a-z]').hasMatch(right);
      ReadAloudBoundaryKindV3 kind;
      final reasons = <String>[
        if (insideQuotedSpeech) 'inside_quoted_speech',
        if (quoteEdge != null) 'quote_edge:$quoteEdge',
      ];
      if (protectsQuotedAttribution) {
        kind = ReadAloudBoundaryKindV3.emergency;
        reasons.add('protected_quote_attribution_gap');
      } else if (_strongPunctuation.hasMatch(left) ||
          (insideQuotedSpeech || quoteEdge == 'after_closing') &&
              _quotedTerminalPunctuation.hasMatch(left)) {
        kind = ReadAloudBoundaryKindV3.strongPunctuation;
        reasons.add('source_strong_punctuation');
      } else if (_commaPunctuation.hasMatch(left) &&
          (oneLegalClauseSubtreeArc || hasRightSubjectPredicateClause) &&
          protectedCrossings == 0) {
        kind = ReadAloudBoundaryKindV3.clauseComma;
        reasons.add(
          hasRightSubjectPredicateClause
              ? 'dependency_confirmed_right_subject_predicate_clause_comma'
              : 'dependency_confirmed_clause_comma',
        );
      } else if (_commaPunctuation.hasMatch(left) &&
          hasPhraseSubtreeArc &&
          protectedCrossings == 0) {
        kind = ReadAloudBoundaryKindV3.phraseComma;
        reasons.add('dependency_confirmed_phrase_comma');
      } else if (_commaPunctuation.hasMatch(left)) {
        kind = ReadAloudBoundaryKindV3.ambiguousComma;
        reasons.add('source_comma_without_confirmed_clause');
      } else if (hasClauseSubtreeArc && protectedCrossings == 0) {
        kind = ReadAloudBoundaryKindV3.dependencyClause;
        reasons.add(
          oneLegalSubtreeArc
              ? 'complete_dependency_clause_subtree'
              : 'dependency_clause_with_outer_container_arcs',
        );
      } else if (hasPhraseSubtreeArc && protectedCrossings == 0) {
        kind = ReadAloudBoundaryKindV3.dependencyPhrase;
        reasons.add(
          oneLegalSubtreeArc
              ? 'complete_dependency_phrase_subtree'
              : 'dependency_phrase_with_outer_container_arcs',
        );
      } else {
        kind = ReadAloudBoundaryKindV3.emergency;
        reasons.add(
          crossings.isEmpty
              ? 'dependency_disconnected_or_same_word'
              : 'ordinary_word_gap',
        );
      }
      final rawRisk = protectedCrossings * 1000 +
          math.max(0, crossings.length - 1) * 100 +
          (kind == ReadAloudBoundaryKindV3.ambiguousComma
              ? 5
              : kind == ReadAloudBoundaryKindV3.phraseComma
                  ? 0
                  : kind == ReadAloudBoundaryKindV3.dependencyPhrase
                      ? 10
                      : kind == ReadAloudBoundaryKindV3.emergency
                          ? 20
                          : 0);
      final risk = quoteEdge == 'after_closing' && protectedCrossings == 0
          ? math.max(0, rawRisk - 200)
          : rawRisk;
      output.add(
        ReadAloudBoundaryCandidateV3(
          afterWord: afterWord,
          kind: kind,
          reasons: List.unmodifiable([
            ...reasons,
            if (risk < rawRisk) 'quote_edge_priority',
            if (crossings.isNotEmpty)
              'crossing_relations:${crossings.map((value) => value.token.deprel).join(',')}',
          ]),
          crossedDependencyArcs: crossings.length,
          protectedRelationCrossings: protectedCrossings,
          risk: risk,
          softWarnings: List.unmodifiable(softWarnings),
          hardBlocked: hardBlockReasons.isNotEmpty,
          hardBlockReasons: List.unmodifiable(hardBlockReasons),
          insideQuotedSpeech: insideQuotedSpeech,
          quoteSpanWordCount: quoteSpanWordCount,
          quoteEdge: quoteEdge,
        ),
      );
    }
    return output;
  }

  static bool _hasRightSubjectPredicateClause(
    int afterWord,
    List<_MappedDependencyV3> dependencies,
  ) {
    for (final predicate in dependencies) {
      final head = predicate.headWordIndex;
      final relation = predicate.token.deprel.split(':').first;
      if (predicate.wordIndex < afterWord ||
          head == null ||
          head >= afterWord ||
          !_clauseRelations.contains(relation) ||
          !const {'VERB', 'AUX'}.contains(predicate.token.upos)) {
        continue;
      }
      final hasRightSubject = dependencies.any((dependent) {
        if (dependent.wordIndex < afterWord ||
            dependent.token.head != predicate.token.id) {
          return false;
        }
        final dependentRelation = dependent.token.deprel.split(':').first;
        return const {'nsubj', 'csubj', 'expl'}.contains(dependentRelation);
      });
      return hasRightSubject;
    }
    return false;
  }

  static bool _isAttributionOnlyRightTail(
    int afterWord,
    List<_MappedDependencyV3> dependencies,
  ) {
    final rightPredicates = dependencies
        .where(
          (dependency) =>
              dependency.wordIndex >= afterWord &&
              dependency.token.upos == 'VERB' &&
              !const {'acl', 'advcl', 'ccomp', 'xcomp'}
                  .contains(dependency.token.deprel.split(':').first),
        )
        .map((dependency) => dependency.wordIndex)
        .toSet();
    if (rightPredicates.length != 1) return false;
    return dependencies.any(
      (dependency) =>
          dependency.wordIndex >= afterWord &&
          const {'nsubj', 'csubj', 'expl'}
              .contains(dependency.token.deprel.split(':').first),
    );
  }

  static String _edgeLexeme(String value) {
    final matches = RegExp(r"[a-z]+(?:'[a-z]+)?")
        .allMatches(value.toLowerCase())
        .toList(growable: false);
    return matches.isEmpty ? '' : matches.last.group(0)!;
  }

  static _CandidatePathRoundsV3 _candidatePaths({
    required int originalIndex,
    required String sentence,
    required List<_SourceWordV3> words,
    required List<ReadAloudBoundaryCandidateV3> candidates,
    required bool parserHealthy,
  }) {
    final count = words.length;
    if (count <= preferredMaxUnpunctuatedWords) {
      final path = _pathFromDraft(
        originalIndex: originalIndex,
        sentence: sentence,
        words: words,
        selection: _DraftSelectionV3(
          draft: _PathDraftV3(const [], [count]),
          round: ReadAloudCandidateRoundV3.initial,
          diversity: ReadAloudCandidateDiversityV3.score,
        ),
      );
      return _CandidatePathRoundsV3(initial: [path], expanded: [path]);
    }

    final punctuation = candidates
        .where((candidate) => candidate.isPunctuation && !candidate.hardBlocked)
        .toList(growable: false);
    final punctuationControlsReadingLoad = count > targetMaxUnpunctuatedWords &&
        _hasFeasiblePunctuationControlPath(
          sentence,
          words,
          punctuation,
        );
    if (count <= targetMaxUnpunctuatedWords || punctuationControlsReadingLoad) {
      final punctuationDrafts = _enumeratePaths(
        sentence,
        words,
        punctuation,
        limitPerState: maxExpandedCandidatePaths,
      );
      final ranked = punctuationDrafts.toList(growable: false)
        ..sort(
          (left, right) => _compareLexicographic(
            _draftScore(sentence, words, left),
            _draftScore(sentence, words, right),
          ),
        );
      if (ranked.isEmpty) {
        throw StateError(
          'V3.6 punctuation lattice has no feasible path '
          '(parserHealthy=$parserHealthy)',
        );
      }
      final expanded = <ReadAloudCandidatePathV3>[];
      for (var index = 0;
          index < ranked.length && index < maxExpandedCandidatePaths;
          index += 1) {
        expanded.add(
          _pathFromDraft(
            originalIndex: originalIndex,
            sentence: sentence,
            words: words,
            selection: _DraftSelectionV3(
              draft: ranked[index],
              round: index < maxCandidatePaths
                  ? ReadAloudCandidateRoundV3.initial
                  : ReadAloudCandidateRoundV3.expanded,
              diversity: ReadAloudCandidateDiversityV3.score,
            ),
          ),
        );
      }
      final initial = expanded
          .where((path) => path.round == ReadAloudCandidateRoundV3.initial)
          .toList(growable: false);
      return _CandidatePathRoundsV3(initial: initial, expanded: expanded);
    }

    final safeCandidates = candidates
        .where((candidate) => !candidate.hardBlocked)
        .toList(growable: false);
    final draftPool = <String, _PathDraftV3>{};
    void addDrafts(Iterable<_PathDraftV3> drafts) {
      for (final draft in drafts) {
        draftPool.putIfAbsent(_draftKey(draft), () => draft);
      }
    }

    final baseDrafts = _enumeratePaths(
      sentence,
      words,
      safeCandidates,
      limitPerState: count > maxCandidateCountForCoverageProbes
          ? maxExpandedCandidatePaths
          : expandedBeamWidth,
    );
    addDrafts(baseDrafts);
    for (final candidate in _coverageProbeCandidates(safeCandidates)) {
      addDrafts(
        _enumeratePaths(
          sentence,
          words,
          safeCandidates,
          limitPerState: 1,
          requiredAfterWord: candidate.afterWord,
        ),
      );
    }
    final ranked = draftPool.values.toList(growable: false)
      ..sort(
        (left, right) => _compareLexicographic(
          _draftScore(sentence, words, left),
          _draftScore(sentence, words, right),
        ),
      );
    if (ranked.isEmpty) {
      throw StateError(
        'V3.6 candidate lattice has no feasible path '
        '(parserHealthy=$parserHealthy)',
      );
    }

    final initialDrafts =
        ranked.take(maxCandidatePaths).toList(growable: false);
    final selected = <_DraftSelectionV3>[
      for (final draft in initialDrafts)
        _DraftSelectionV3(
          draft: draft,
          round: ReadAloudCandidateRoundV3.initial,
          diversity: ReadAloudCandidateDiversityV3.score,
        ),
    ];
    final selectedKeys = initialDrafts.map(_draftKey).toSet();
    final remaining = ranked
        .where((draft) => !selectedKeys.contains(_draftKey(draft)))
        .toList(growable: true);

    for (var count = 0; count < 8 && remaining.isNotEmpty; count += 1) {
      remaining.sort((left, right) {
        final cutCount =
            left.boundaries.length.compareTo(right.boundaries.length);
        if (cutCount != 0) return cutCount;
        final distance = _minimumBoundaryDistance(right, selected) -
            _minimumBoundaryDistance(left, selected);
        if (distance != 0) return distance;
        return _compareLexicographic(
          _draftScore(sentence, words, left),
          _draftScore(sentence, words, right),
        );
      });
      final draft = remaining.removeAt(0);
      selected.add(
        _DraftSelectionV3(
          draft: draft,
          round: ReadAloudCandidateRoundV3.expanded,
          diversity: ReadAloudCandidateDiversityV3.boundaryDistance,
        ),
      );
      selectedKeys.add(_draftKey(draft));
    }

    final coveredBoundaries = selected
        .expand((selection) => selection.draft.boundaries)
        .map((boundary) => boundary.afterWord)
        .toSet();
    final uncoveredBoundaries = safeCandidates
        .map((candidate) => candidate.afterWord)
        .toSet()
      ..removeAll(coveredBoundaries);
    for (var count = 0;
        count < 8 && remaining.isNotEmpty && uncoveredBoundaries.isNotEmpty;
        count += 1) {
      remaining.sort((left, right) {
        final rightCoverage = _newBoundaryCoverage(right, uncoveredBoundaries);
        final leftCoverage = _newBoundaryCoverage(left, uncoveredBoundaries);
        final coverage = rightCoverage.compareTo(leftCoverage);
        if (coverage != 0) return coverage;
        return _compareLexicographic(
          _draftScore(sentence, words, left),
          _draftScore(sentence, words, right),
        );
      });
      final draft = remaining.first;
      if (_newBoundaryCoverage(draft, uncoveredBoundaries) == 0) break;
      remaining.removeAt(0);
      selected.add(
        _DraftSelectionV3(
          draft: draft,
          round: ReadAloudCandidateRoundV3.expanded,
          diversity: ReadAloudCandidateDiversityV3.boundaryCoverage,
        ),
      );
      uncoveredBoundaries.removeAll(
        draft.boundaries.map((boundary) => boundary.afterWord),
      );
      selectedKeys.add(_draftKey(draft));
    }
    for (final draft in remaining) {
      if (selected.length >= maxExpandedCandidatePaths) break;
      selected.add(
        _DraftSelectionV3(
          draft: draft,
          round: ReadAloudCandidateRoundV3.expanded,
          diversity: ReadAloudCandidateDiversityV3.score,
        ),
      );
    }

    final expanded = selected
        .take(maxExpandedCandidatePaths)
        .map(
          (selection) => _pathFromDraft(
            originalIndex: originalIndex,
            sentence: sentence,
            words: words,
            selection: selection,
          ),
        )
        .toList(growable: false);
    final initial = expanded
        .where((path) => path.round == ReadAloudCandidateRoundV3.initial)
        .take(maxCandidatePaths)
        .toList(growable: false);
    return _CandidatePathRoundsV3(initial: initial, expanded: expanded);
  }

  /// Linear-size reachability check used before the expensive punctuation-only
  /// path enumeration. The old implementation enumerated a full beam merely to
  /// discover that punctuation could not keep a long quote at 20 words or
  /// below, then discarded that beam and ran the syntax lattice again.
  static bool _hasFeasiblePunctuationControlPath(
    String sentence,
    List<_SourceWordV3> words,
    List<ReadAloudBoundaryCandidateV3> punctuation,
  ) {
    final byEnd = <int, ReadAloudBoundaryCandidateV3>{
      for (final candidate in punctuation)
        if (candidate.protectedRelationCrossings == 0)
          candidate.afterWord: candidate,
    };
    final memo = <int, bool>{};

    bool solve(int start) {
      final cached = memo[start];
      if (cached != null) return cached;
      final maximumEnd = math.min(
        words.length,
        start + targetMaxUnpunctuatedWords,
      );
      for (var end = start + 1; end <= maximumEnd; end += 1) {
        if (end < words.length && !byEnd.containsKey(end)) continue;
        final oneSegment = _PathDraftV3(const [], [end]);
        if (_unreadableShortFragmentPenalty(
              sentence,
              words,
              oneSegment,
              startWord: start,
            ) !=
            0) {
          continue;
        }
        if (end == words.length || solve(end)) {
          memo[start] = true;
          return true;
        }
      }
      memo[start] = false;
      return false;
    }

    return solve(0);
  }

  /// Expanded review output is capped at 24 paths, so re-running the complete
  /// DP once for every boundary in a hundreds-of-words quotation adds no useful
  /// audit coverage. Keep every boundary in [boundaryCandidates], but probe a
  /// bounded mix of quote edges, low-risk punctuation, and positions spread
  /// across the full unit.
  static List<ReadAloudBoundaryCandidateV3> _coverageProbeCandidates(
    List<ReadAloudBoundaryCandidateV3> candidates,
  ) {
    if (candidates.length > maxCandidateCountForCoverageProbes) {
      return const [];
    }
    if (candidates.length <= maxCoverageProbeCandidates) return candidates;

    final selected = <int, ReadAloudBoundaryCandidateV3>{};
    final prioritized = candidates.toList(growable: false)
      ..sort((left, right) {
        final quoteEdge = (left.quoteEdge == null ? 1 : 0)
            .compareTo(right.quoteEdge == null ? 1 : 0);
        if (quoteEdge != 0) return quoteEdge;
        final punctuation =
            (left.isPunctuation ? 0 : 1).compareTo(right.isPunctuation ? 0 : 1);
        if (punctuation != 0) return punctuation;
        final protected = left.protectedRelationCrossings
            .compareTo(right.protectedRelationCrossings);
        if (protected != 0) return protected;
        final risk = left.risk.compareTo(right.risk);
        if (risk != 0) return risk;
        return left.afterWord.compareTo(right.afterWord);
      });
    for (final candidate in prioritized.take(maxCandidatePaths)) {
      selected[candidate.afterWord] = candidate;
    }

    final ordered = candidates.toList(growable: false)
      ..sort((left, right) => left.afterWord.compareTo(right.afterWord));
    final spreadSlots = maxCoverageProbeCandidates - selected.length;
    for (var slot = 0; slot < spreadSlots; slot += 1) {
      final index = spreadSlots == 1
          ? ordered.length ~/ 2
          : (slot * (ordered.length - 1) / (spreadSlots - 1)).round();
      selected[ordered[index].afterWord] = ordered[index];
    }
    for (final candidate in prioritized) {
      if (selected.length >= maxCoverageProbeCandidates) break;
      selected.putIfAbsent(candidate.afterWord, () => candidate);
    }

    final result = selected.values.toList(growable: false)
      ..sort((left, right) => left.afterWord.compareTo(right.afterWord));
    return result;
  }

  static List<_PathDraftV3> _enumeratePaths(
    String sentence,
    List<_SourceWordV3> words,
    List<ReadAloudBoundaryCandidateV3> candidates, {
    required int limitPerState,
    int? requiredAfterWord,
  }) {
    final byEnd = <int, ReadAloudBoundaryCandidateV3>{
      for (final candidate in candidates) candidate.afterWord: candidate,
    };
    final memo = <String, List<_PathDraftV3>>{};
    final scoreCache = <String, List<int>>{};

    List<int> score(int start, _PathDraftV3 draft) => scoreCache.putIfAbsent(
          '$start:${_draftKey(draft)}',
          () => _draftScore(sentence, words, draft, startWord: start),
        );

    int compare(int start, _PathDraftV3 left, _PathDraftV3 right) =>
        _compareLexicographic(score(start, left), score(start, right));

    void trimWorkingSet(int start, List<_PathDraftV3> values) {
      final workingLimit = math.max(limitPerState * 4, limitPerState + 8);
      if (values.length <= workingLimit) return;
      values.sort((left, right) => compare(start, left, right));
      values.removeRange(limitPerState * 2, values.length);
    }

    List<_PathDraftV3> solve(int start, bool hasRequiredBoundary) {
      final memoKey = '$start:${hasRequiredBoundary ? 1 : 0}';
      final cached = memo[memoKey];
      if (cached != null) return cached;
      final result = <_PathDraftV3>[];
      final maximumEnd = math.min(words.length, start + hardMaxWords);
      for (var end = start + 1; end <= maximumEnd; end += 1) {
        final segment = _segmentText(sentence, words, start, end);
        if (maxUnpunctuatedWordCount(segment) > hardMaxUnpunctuatedWords) {
          continue;
        }
        if (end == words.length) {
          if (requiredAfterWord == null || hasRequiredBoundary) {
            result.add(_PathDraftV3(const [], [end]));
          }
          continue;
        }
        final boundary = byEnd[end];
        if (boundary == null) continue;
        final nextHasRequired = hasRequiredBoundary || end == requiredAfterWord;
        for (final suffix in solve(end, nextHasRequired)) {
          result.add(
            _PathDraftV3(
              [boundary, ...suffix.boundaries],
              [end, ...suffix.ends],
            ),
          );
        }
        trimWorkingSet(start, result);
      }
      result.sort((left, right) => compare(start, left, right));
      final limited = result.take(limitPerState).toList(growable: false);
      memo[memoKey] = limited;
      return limited;
    }

    return solve(0, false);
  }

  static ReadAloudCandidatePathV3 _pathFromDraft({
    required int originalIndex,
    required String sentence,
    required List<_SourceWordV3> words,
    required _DraftSelectionV3 selection,
  }) {
    final draft = selection.draft;
    final segments = <String>[];
    final counts = <int>[];
    final spans = <int>[];
    var start = 0;
    for (final end in draft.ends) {
      final text = _segmentText(sentence, words, start, end);
      segments.add(text);
      counts.add(end - start);
      spans.add(maxUnpunctuatedWordCount(text));
      start = end;
    }
    final pathKey = draft.boundaries.isEmpty
        ? 'keep'
        : draft.boundaries
            .map((boundary) =>
                '${boundary.afterWord}${_kindCode(boundary.kind)}')
            .join('_');
    return ReadAloudCandidatePathV3(
      pathId: 'v3_o${originalIndex}_'
          '${selection.round == ReadAloudCandidateRoundV3.initial ? 'r1' : 'r2'}_'
          '$pathKey',
      originalIndex: originalIndex,
      stage: _stageForDraft(draft),
      boundaries: List.unmodifiable(draft.boundaries),
      segments: List.unmodifiable(segments),
      wordCounts: List.unmodifiable(counts),
      maxUnpunctuatedWordCounts: List.unmodifiable(spans),
      score: List.unmodifiable(_draftScore(sentence, words, draft)),
      round: selection.round,
      diversity: selection.diversity,
    );
  }

  static ReadAloudPathStageV3 _stageForDraft(_PathDraftV3 draft) {
    if (draft.boundaries.isEmpty) return ReadAloudPathStageV3.unchanged;
    if (draft.boundaries.every((boundary) => boundary.isPunctuation)) {
      return ReadAloudPathStageV3.punctuation;
    }
    if (draft.boundaries.every((boundary) => !boundary.isEmergency)) {
      return ReadAloudPathStageV3.syntax;
    }
    return ReadAloudPathStageV3.emergency;
  }

  static String _draftKey(_PathDraftV3 draft) => draft.ends.join(',');

  static int _minimumBoundaryDistance(
    _PathDraftV3 draft,
    List<_DraftSelectionV3> selected,
  ) {
    if (selected.isEmpty) return draft.boundaries.length;
    final boundaries = draft.boundaries.map((value) => value.afterWord).toSet();
    var minimum = 1 << 30;
    for (final other in selected) {
      final otherBoundaries =
          other.draft.boundaries.map((value) => value.afterWord).toSet();
      final difference = boundaries.difference(otherBoundaries).length +
          otherBoundaries.difference(boundaries).length;
      minimum = math.min(minimum, difference);
    }
    return minimum;
  }

  static int _newBoundaryCoverage(
    _PathDraftV3 draft,
    Set<int> uncovered,
  ) =>
      draft.boundaries
          .where((boundary) => uncovered.contains(boundary.afterWord))
          .length;

  static List<int> _draftScore(
    String sentence,
    List<_SourceWordV3> words,
    _PathDraftV3 draft, {
    int startWord = 0,
  }) {
    var nonPunctuationProtectedCrossings = 0;
    var punctuationProtectedCrossings = 0;
    var boundaryNaturalnessRisk = 0;
    var structuralWarningRisk = 0;
    var softWarningRisk = 0;
    var insideQuotedSpeechBoundaryCount = 0;
    for (final boundary in draft.boundaries) {
      if (boundary.insideQuotedSpeech) {
        insideQuotedSpeechBoundaryCount += 1;
      }
      if (boundary.isPunctuation) {
        punctuationProtectedCrossings += boundary.protectedRelationCrossings;
      } else {
        nonPunctuationProtectedCrossings += boundary.protectedRelationCrossings;
      }
      boundaryNaturalnessRisk += math.max(
        0,
        boundary.risk - boundary.protectedRelationCrossings * 1000,
      );
      if (!boundary.isPunctuation) boundaryNaturalnessRisk += 5;
      for (final warning in boundary.softWarnings) {
        if (boundary.isPunctuation &&
            !const {
              'surface_possible_antecedent_possessive_separation',
              'surface_parallel_list_item_separation',
              'quote_edge_attribution_only_tail',
            }.contains(warning)) {
          continue;
        }
        if (_structuralSoftWarnings.contains(warning)) {
          structuralWarningRisk += 1;
        } else {
          softWarningRisk += 5;
        }
      }
    }
    var start = startWord;
    var criticalLengthCount = 0;
    var severeLengthCount = 0;
    var overTwentyCount = 0;
    var seventeenToTwentyCount = 0;
    var readingLoadPenalty = 0;
    var shortFragmentPenalty = 0;
    var preferredSpanPenalty = 0;
    final lengths = <int>[];
    for (final end in draft.ends) {
      final length = end - start;
      lengths.add(length);
      if (length >= 28) criticalLengthCount += 1;
      if (length >= 25) severeLengthCount += 1;
      if (length >= 21) overTwentyCount += 1;
      if (length >= 17) seventeenToTwentyCount += 1;
      readingLoadPenalty += _readingLoadPenalty(length);
      if (length < preferredMinUnpunctuatedWords) {
        final delta = preferredMinUnpunctuatedWords - length;
        shortFragmentPenalty += delta * delta;
      }
      final span = maxUnpunctuatedWordCount(
        _segmentText(sentence, words, start, end),
      );
      if (span < preferredMinUnpunctuatedWords) {
        final delta = preferredMinUnpunctuatedWords - span;
        preferredSpanPenalty += delta * delta;
      } else if (span > preferredMaxUnpunctuatedWords) {
        final delta = span - preferredMaxUnpunctuatedWords;
        preferredSpanPenalty += delta * delta;
      }
      start = end;
    }
    final minLength = lengths.reduce(math.min);
    final maxLength = lengths.reduce(math.max);
    final balancePenalty = maxLength - minLength;
    return [
      _unreadableShortFragmentPenalty(
        sentence,
        words,
        draft,
        startWord: startWord,
      ),
      criticalLengthCount,
      severeLengthCount,
      structuralWarningRisk,
      nonPunctuationProtectedCrossings,
      overTwentyCount,
      boundaryNaturalnessRisk,
      punctuationProtectedCrossings,
      seventeenToTwentyCount,
      insideQuotedSpeechBoundaryCount,
      softWarningRisk,
      maxLength,
      readingLoadPenalty,
      shortFragmentPenalty,
      preferredSpanPenalty,
      draft.boundaries.length,
      balancePenalty,
    ];
  }

  static int _readingLoadPenalty(int length) {
    if (length <= preferredMaxUnpunctuatedWords) return 0;
    final excess = length - preferredMaxUnpunctuatedWords;
    return excess * excess;
  }

  static int _unreadableShortFragmentPenalty(
    String sentence,
    List<_SourceWordV3> words,
    _PathDraftV3 draft, {
    int startWord = 0,
  }) {
    var start = startWord;
    var penalty = 0;
    for (final end in draft.ends) {
      final length = end - start;
      if (length <= 5) {
        final text = _segmentText(sentence, words, start, end).trim();
        final isCompleteShortQuotedSpeech =
            _isCompleteShortQuotedSpeechSegment(words, start, end);
        final hasSelfContainedPause =
            RegExp(r'''[.!?…;:]["'”’)}\]]*$''').hasMatch(text);
        final hasSelfContainedPredicate =
            _hasSelfContainedShortPredicate(words, start, end);
        if (!isCompleteShortQuotedSpeech &&
            (length <= 3 ||
                !hasSelfContainedPause ||
                !hasSelfContainedPredicate)) {
          final delta = 6 - length;
          penalty += delta * delta;
        }
      }
      start = end;
    }
    return penalty;
  }

  static bool _isCompleteShortQuotedSpeechSegment(
    List<_SourceWordV3> words,
    int start,
    int end,
  ) {
    if (start < 0 || end <= start || end > words.length) return false;
    final first = words[start];
    final spanIndex = first.quotedSpeechSpanIndex;
    final wordCount = first.quotedSpeechWordCount;
    if (spanIndex == null ||
        wordCount == null ||
        wordCount > preferredMaxUnpunctuatedWords ||
        first.quotedSpeechStartWord != start ||
        first.quotedSpeechEndWord != end) {
      return false;
    }
    return words
        .sublist(start, end)
        .every((word) => word.quotedSpeechSpanIndex == spanIndex);
  }

  static bool _hasSelfContainedShortPredicate(
    List<_SourceWordV3> words,
    int start,
    int end,
  ) {
    final segmentWords = words.sublist(start, end);
    final hasPredicate = segmentWords.any(
      (word) => word.upos.any(const {'VERB', 'AUX'}.contains),
    );
    final hasSubject = segmentWords.any(
      (word) => word.dependencyRelations.any(
        const {'nsubj', 'csubj', 'expl'}.contains,
      ),
    );
    if (hasPredicate && hasSubject) return true;

    final first = segmentWords.first;
    final startsWithImperativeVerb = first.upos.contains('VERB') &&
        !first.dependencyRelations.any(
          const {'acl', 'advcl', 'ccomp', 'xcomp'}.contains,
        );
    return startsWithImperativeVerb;
  }

  static int _compareLexicographic(List<int> left, List<int> right) {
    final length = math.min(left.length, right.length);
    for (var index = 0; index < length; index += 1) {
      final comparison = left[index].compareTo(right[index]);
      if (comparison != 0) return comparison;
    }
    return left.length.compareTo(right.length);
  }

  static String _segmentText(
    String sentence,
    List<_SourceWordV3> words,
    int start,
    int end,
  ) =>
      sentence
          .substring(words[start].start, words[end - 1].end)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

  static String _kindCode(ReadAloudBoundaryKindV3 kind) => switch (kind) {
        ReadAloudBoundaryKindV3.originalSentence => 'o',
        ReadAloudBoundaryKindV3.strongPunctuation => 'p',
        ReadAloudBoundaryKindV3.clauseComma => 'c',
        ReadAloudBoundaryKindV3.phraseComma => 'm',
        ReadAloudBoundaryKindV3.ambiguousComma => 'a',
        ReadAloudBoundaryKindV3.dependencyClause => 'd',
        ReadAloudBoundaryKindV3.dependencyPhrase => 'f',
        ReadAloudBoundaryKindV3.emergency => 'e',
      };

  static List<int> _requiredBoundaryOffsets(
    List<ReadAloudOriginalDecisionV3> originals,
  ) {
    final offsets = <int>[];
    var words = 0;
    for (final original in originals) {
      words += wordCount(original.source);
      offsets.add(words);
    }
    return offsets;
  }

  static void validateReviewedSentences(
    String englishContent,
    List<String> sentences, {
    Iterable<int> requiredBoundaryWordOffsets = const [],
  }) {
    if (sentences.isEmpty) {
      throw const FormatException('审核分句不能为空');
    }
    final actualBoundaries = <int>{};
    var cumulativeWords = 0;
    for (var index = 0; index < sentences.length; index += 1) {
      final sentence = sentences[index];
      if (sentence.trim().isEmpty) {
        throw FormatException('审核分句第 ${index + 1} 块为空');
      }
      if (sentence.contains('\n') || sentence.contains('\r')) {
        throw FormatException('审核分句第 ${index + 1} 块含显示换行');
      }
      final count = wordCount(sentence);
      if (count > hardMaxWords) {
        throw FormatException('审核分句第 ${index + 1} 块为 $count 词，超过 30 词硬上限');
      }
      final span = maxUnpunctuatedWordCount(sentence);
      if (span > hardMaxUnpunctuatedWords) {
        throw FormatException(
          '审核分句第 ${index + 1} 块最长无标点连续段为 $span 词，超过 30 词硬上限',
        );
      }
      cumulativeWords += count;
      actualBoundaries.add(cumulativeWords);
    }
    final roundTripMismatch = _roundTripMismatch(
      englishContent: englishContent,
      sentences: sentences,
    );
    if (roundTripMismatch != null) {
      throw FormatException('审核分句规范化拼接与最终英文正文不一致：$roundTripMismatch');
    }
    for (final required in requiredBoundaryWordOffsets) {
      if (required > 0 && !actualBoundaries.contains(required)) {
        throw const FormatException('审核分句跨越了朗读求解单元或段落硬边界');
      }
    }
  }
}
