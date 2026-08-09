import 'dart:convert';
import 'dart:math' as math;

import 'read_aloud_display_metrics.dart';

enum ReadAloudBoundaryKindV3 {
  originalSentence,
  strongPunctuation,
  clauseComma,
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

  bool get isPunctuation =>
      kind == ReadAloudBoundaryKindV3.strongPunctuation ||
      kind == ReadAloudBoundaryKindV3.clauseComma;

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

  bool get requiresAiReview => localPath.usesNonPunctuation;
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
  const _SourceWordV3(this.text, this.start, this.end);

  final String text;
  final int start;
  final int end;
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
  static const solverVersion = 'syntax_solver_v3_3';
  static const hardMaxWords = 30;
  static const preferredMinUnpunctuatedWords = 8;
  static const preferredMaxUnpunctuatedWords = 16;
  static const hardMaxUnpunctuatedWords = 20;
  static const maxCandidatePaths = 8;
  static const maxExpandedCandidatePaths = 24;
  static const expandedBeamWidth = 64;
  static const defaultFontSizePx = ReadAloudDisplayMetrics.defaultFontSizePx;
  static const defaultMaxLineWidthPx =
      ReadAloudDisplayMetrics.defaultMaxLineWidthPx;

  static final RegExp _visiblePause = RegExp(r'[.!?…;:—–,]');
  static final RegExp _strongPunctuation = RegExp(r'''[;:—–]["'”’)}\]]*$''');
  static final RegExp _commaPunctuation = RegExp(r''',["'”’)}\]]*$''');
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

  static int wordCount(String text) =>
      text.trim().isEmpty ? 0 : text.trim().split(RegExp(r'\s+')).length;

  static int maxUnpunctuatedWordCount(String text) {
    final tokens =
        text.trim().split(RegExp(r'\s+')).where((token) => token.isNotEmpty);
    var run = 0;
    var maximum = 0;
    for (final token in tokens) {
      run += 1;
      if (run > maximum) maximum = run;
      if (_visiblePause.hasMatch(token)) run = 0;
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

  static ReadAloudSplitPlanV3 plan({
    required String source,
    required DependencyDocumentV3 document,
  }) {
    if (source.trim().isEmpty) {
      throw const FormatException('V3 分句正文不能为空');
    }
    _validateDocument(source, document);
    final originals = <ReadAloudOriginalDecisionV3>[];
    for (var index = 0; index < document.sentences.length; index += 1) {
      final parsedSentence = document.sentences[index];
      final sentenceSource = source.substring(
        parsedSentence.start,
        parsedSentence.end,
      );
      final words = _sourceWords(sentenceSource);
      if (words.isEmpty) continue;
      final mapped = _mapDependencies(
        parsedSentence,
        words,
        sentenceStart: parsedSentence.start,
      );
      final mappingIssues = <String>[
        if (mapped.length != parsedSentence.tokens.length)
          'dependency_token_offset_mapping_incomplete',
      ];
      final candidates = _boundaryCandidates(
        sentenceSource,
        words,
        mapped,
        sentenceStart: parsedSentence.start,
        parserTokens: parsedSentence.tokens,
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
          sourceStart: parsedSentence.start,
          sourceEnd: parsedSentence.end,
          parserHealthy: document.healthy && mappingIssues.isEmpty,
          parserIssues: List.unmodifiable([
            ...document.issues,
            ...mappingIssues,
          ]),
          initialCandidatePaths: List.unmodifiable(pathRounds.initial),
          expandedCandidatePaths: List.unmodifiable(pathRounds.expanded),
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

  static List<_SourceWordV3> _sourceWords(String sentence) => [
        for (final match in RegExp(r'\S+').allMatches(sentence))
          _SourceWordV3(match.group(0)!, match.start, match.end),
      ];

  static List<_MappedDependencyV3> _mapDependencies(
    DependencySentenceV3 sentence,
    List<_SourceWordV3> words, {
    required int sentenceStart,
  }) {
    final wordByTokenId = <int, int>{};
    for (final token in sentence.tokens) {
      final relativeStart = token.start - sentenceStart;
      final relativeEnd = token.end - sentenceStart;
      final wordIndex = words.indexWhere(
        (word) => relativeStart >= word.start && relativeEnd <= word.end,
      );
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
  }) {
    final output = <ReadAloudBoundaryCandidateV3>[];
    for (var afterWord = 1; afterWord < words.length; afterWord += 1) {
      final left = words[afterWord - 1].text;
      final boundaryOffset = sentenceStart + words[afterWord - 1].end;
      final spanningTokens = parserTokens
          .where(
            (token) =>
                token.start < boundaryOffset && token.end > boundaryOffset,
          )
          .toList(growable: false);
      final hardBlockReasons = <String>[
        if (spanningTokens.isNotEmpty)
          'inside_parser_token:${spanningTokens.map((token) => token.id).join(',')}',
      ];
      final crossings = dependencies.where((dependency) {
        if (dependency.token.deprel.split(':').first == 'punct') {
          return false;
        }
        final head = dependency.headWordIndex;
        if (head == null || head == dependency.wordIndex) return false;
        return (dependency.wordIndex < afterWord) != (head < afterWord);
      }).toList(growable: false);
      final protectedCrossings = crossings
          .where(
            (dependency) =>
                _protectedRelations.contains(dependency.token.deprel),
          )
          .length;
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
      final softWarnings = <String>[
        if (leftDependencies.any(
              (dependency) => const {'NOUN', 'PROPN', 'PRON'}
                  .contains(dependency.token.upos),
            ) &&
            rightDependencies.any(
              (dependency) =>
                  const {'VERB', 'AUX'}.contains(dependency.token.upos),
            ))
          'surface_possible_subject_predicate_separation',
        if (leftDependencies.any(
              (dependency) =>
                  const {'VERB', 'AUX'}.contains(dependency.token.upos),
            ) &&
            rightDependencies.any(
              (dependency) =>
                  dependency.token.upos == 'PART' &&
                  dependency.token.deprel.split(':').first == 'mark',
            ))
          'surface_predicate_infinitive_separation',
      ];
      final protectsQuotedAttribution = _commaPunctuation.hasMatch(left) &&
          RegExp(r'''^["'“‘]''').hasMatch(words[afterWord].text);
      ReadAloudBoundaryKindV3 kind;
      final reasons = <String>[];
      if (protectsQuotedAttribution) {
        kind = ReadAloudBoundaryKindV3.emergency;
        reasons.add('protected_quote_attribution_gap');
      } else if (_strongPunctuation.hasMatch(left)) {
        kind = ReadAloudBoundaryKindV3.strongPunctuation;
        reasons.add('source_strong_punctuation');
      } else if (_commaPunctuation.hasMatch(left) &&
          (oneLegalSubtreeArc &&
                  _clauseRelations.contains(subtreeRelations.single) ||
              hasRightSubjectPredicateClause) &&
          protectedCrossings == 0) {
        kind = ReadAloudBoundaryKindV3.clauseComma;
        reasons.add(
          hasRightSubjectPredicateClause
              ? 'dependency_confirmed_right_subject_predicate_clause_comma'
              : 'dependency_confirmed_clause_comma',
        );
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
      final risk = protectedCrossings * 1000 +
          math.max(0, crossings.length - 1) * 100 +
          (kind == ReadAloudBoundaryKindV3.ambiguousComma
              ? 5
              : kind == ReadAloudBoundaryKindV3.dependencyPhrase
                  ? 10
                  : kind == ReadAloudBoundaryKindV3.emergency
                      ? 20
                      : 0);
      output.add(
        ReadAloudBoundaryCandidateV3(
          afterWord: afterWord,
          kind: kind,
          reasons: List.unmodifiable([
            ...reasons,
            if (crossings.isNotEmpty)
              'crossing_relations:${crossings.map((value) => value.token.deprel).join(',')}',
          ]),
          crossedDependencyArcs: crossings.length,
          protectedRelationCrossings: protectedCrossings,
          risk: risk,
          softWarnings: List.unmodifiable(softWarnings),
          hardBlocked: hardBlockReasons.isNotEmpty,
          hardBlockReasons: List.unmodifiable(hardBlockReasons),
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

  static _CandidatePathRoundsV3 _candidatePaths({
    required int originalIndex,
    required String sentence,
    required List<_SourceWordV3> words,
    required List<ReadAloudBoundaryCandidateV3> candidates,
    required bool parserHealthy,
  }) {
    final count = words.length;
    if (count <= hardMaxWords &&
        maxUnpunctuatedWordCount(sentence) <= hardMaxUnpunctuatedWords) {
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
    final punctuationDrafts = _enumeratePaths(
      sentence,
      words,
      punctuation,
      limitPerState: maxCandidatePaths,
    );
    if (punctuationDrafts.isNotEmpty) {
      final paths = punctuationDrafts
          .take(maxCandidatePaths)
          .map(
            (draft) => _pathFromDraft(
              originalIndex: originalIndex,
              sentence: sentence,
              words: words,
              selection: _DraftSelectionV3(
                draft: draft,
                round: ReadAloudCandidateRoundV3.initial,
                diversity: ReadAloudCandidateDiversityV3.score,
              ),
            ),
          )
          .toList(growable: false)
        ..sort(_comparePaths);
      return _CandidatePathRoundsV3(initial: paths, expanded: paths);
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
      limitPerState: expandedBeamWidth,
    );
    addDrafts(baseDrafts);
    for (final candidate in safeCandidates) {
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
        'V3.3 candidate lattice has no feasible path '
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

    List<int> score(_PathDraftV3 draft) => scoreCache.putIfAbsent(
          _draftKey(draft),
          () => _draftScore(sentence, words, draft),
        );

    int compare(_PathDraftV3 left, _PathDraftV3 right) =>
        _compareLexicographic(score(left), score(right));

    void trimWorkingSet(List<_PathDraftV3> values) {
      final workingLimit = math.max(limitPerState * 4, limitPerState + 8);
      if (values.length <= workingLimit) return;
      values.sort(compare);
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
        trimWorkingSet(result);
      }
      result.sort(compare);
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
    _PathDraftV3 draft,
  ) {
    var dependencyRisk = 0;
    for (final boundary in draft.boundaries) {
      dependencyRisk += boundary.risk;
    }
    var start = 0;
    var shortFragmentPenalty = 0;
    var preferredSpanPenalty = 0;
    final lengths = <int>[];
    for (final end in draft.ends) {
      final length = end - start;
      lengths.add(length);
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
      dependencyRisk,
      draft.boundaries.length,
      shortFragmentPenalty,
      preferredSpanPenalty,
      balancePenalty,
    ];
  }

  static int _comparePaths(
    ReadAloudCandidatePathV3 left,
    ReadAloudCandidatePathV3 right,
  ) {
    final score = _compareLexicographic(left.score, right.score);
    if (score != 0) return score;
    return left.pathId.compareTo(right.pathId);
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
      sentence.substring(words[start].start, words[end - 1].end).trim();

  static String _kindCode(ReadAloudBoundaryKindV3 kind) => switch (kind) {
        ReadAloudBoundaryKindV3.originalSentence => 'o',
        ReadAloudBoundaryKindV3.strongPunctuation => 'p',
        ReadAloudBoundaryKindV3.clauseComma => 'c',
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
          '审核分句第 ${index + 1} 块最长无标点连续段为 $span 词，超过 20 词硬上限',
        );
      }
      cumulativeWords += count;
      actualBoundaries.add(cumulativeWords);
    }
    if (normalizeForRoundTrip(sentences.join(' ')) !=
        normalizeForRoundTrip(englishContent)) {
      throw const FormatException('审核分句规范化拼接与最终英文正文不一致');
    }
    for (final required in requiredBoundaryWordOffsets) {
      if (required > 0 && !actualBoundaries.contains(required)) {
        throw const FormatException('审核分句跨越了原文句号、问号或感叹号句界');
      }
    }
  }
}
