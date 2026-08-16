/// Production read-aloud chunk splitter (`read_aloud_dp_v3` / syntax_solver_v3_9).
///
/// Each orthographic sentence builds one immutable fact set and runs one
/// bounded DAG solve. Rules live in `docs/read_aloud_sentence_split_spec.md`.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'read_aloud_display_metrics.dart';

part 'read_aloud_splitter_v3_solver.dart';
part 'read_aloud_splitter_v3_facts.dart';
part 'read_aloud_splitter_v3_additive_facts.dart';
part 'read_aloud_splitter_v3_additive_lattice.dart';

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
    this.insideParenthetical = false,
    this.parenSpanWordCount,
    this.parenEdge,
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
  final bool insideParenthetical;
  final int? parenSpanWordCount;
  final String? parenEdge;

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
        'insideParenthetical': insideParenthetical,
        if (parenSpanWordCount != null)
          'parenSpanWordCount': parenSpanWordCount,
        if (parenEdge != null) 'parenEdge': parenEdge,
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
    this.counters = const ReadAloudSolverCountersV3(),
  });

  final String parserVersion;
  final String modelSha256;
  final bool parserHealthy;
  final List<String> parserIssues;
  final List<ReadAloudOriginalDecisionV3> originals;
  final ReadAloudSolverCountersV3 counters;

  List<String> get localSentencesBeforePostProcessing => originals
      .expand((decision) => decision.localPath.segments)
      .toList(growable: false);

  List<String> get localSentences => ReadAloudSplitterV3.mergeOneWordChunks(
        localSentencesBeforePostProcessing,
      );

  bool get requiresAiReview =>
      originals.any((decision) => decision.requiresAiReview);
}

class ReadAloudSolverCountersV3 {
  const ReadAloudSolverCountersV3({
    this.sentenceFactBuilds = 0,
    this.dagSolves = 0,
  });

  final int sentenceFactBuilds;
  final int dagSolves;

  Map<String, int> toJson() => {
        'sentenceFactBuilds': sentenceFactBuilds,
        'dagSolves': dagSolves,
      };
}

/// Stable public API for the V3 read-aloud splitter.
///
/// Implementation details live in the private engine part so callers cannot
/// depend on repair phases or scoring internals during the behavior-equivalent
/// refactor.
class ReadAloudSplitterV3 {
  static const version = 'read_aloud_dp_v3';
  static const reviewedVersion = 'reviewed_dp_v3';
  static const solverVersion = 'syntax_solver_v3_9';
  static const hardMaxWords = 30;
  static const preferredMinUnpunctuatedWords = 8;
  static const preferredMaxUnpunctuatedWords = 16;
  static const targetMaxUnpunctuatedWords = 20;
  static const hardMaxUnpunctuatedWords = 30;
  static const maxCandidatePaths = 8;
  static const maxExpandedCandidatePaths = 24;
  static const defaultFontSizePx = ReadAloudDisplayMetrics.defaultFontSizePx;
  static const defaultMaxLineWidthPx =
      ReadAloudDisplayMetrics.defaultMaxLineWidthPx;

  static double measureNunitoExtraBoldPx(
    String text, {
    double fontSizePx = defaultFontSizePx,
  }) =>
      _ReadAloudSplitterEngineV3.measureNunitoExtraBoldPx(
        text,
        fontSizePx: fontSizePx,
      );

  static bool fitsEnglishLine(String text) =>
      _ReadAloudSplitterEngineV3.fitsEnglishLine(text);

  static int wordCount(String text) =>
      _ReadAloudSplitterEngineV3.wordCount(text);

  static List<String> mergeOneWordChunks(List<String> segments) =>
      _ReadAloudSplitterEngineV3.mergeOneWordChunks(segments);

  static int maxUnpunctuatedWordCount(String text) =>
      _ReadAloudSplitterEngineV3.maxUnpunctuatedWordCount(text);

  static String candidateSetHash(
    Iterable<ReadAloudCandidatePathV3> paths,
  ) =>
      _ReadAloudSplitterEngineV3.candidateSetHash(paths);

  static String normalizeForRoundTrip(String text) =>
      _ReadAloudSplitterEngineV3.normalizeForRoundTrip(text);

  static bool isRoundTripEquivalent({
    required String englishContent,
    required List<String> sentences,
  }) =>
      _ReadAloudSplitterEngineV3.isRoundTripEquivalent(
        englishContent: englishContent,
        sentences: sentences,
      );

  static ReadAloudSplitPlanV3 plan({
    required String source,
    required DependencyDocumentV3 document,
  }) =>
      _ReadAloudSplitterEngineV3.plan(source: source, document: document);

  static List<int> requiredBoundaryWordOffsetsAfterMerge(
    ReadAloudSplitPlanV3 plan, [
    Map<int, String> selectedPathIds = const {},
  ]) =>
      _ReadAloudSplitterEngineV3.requiredBoundaryWordOffsetsAfterMerge(
        plan,
        selectedPathIds,
      );

  static void validateSelectedPathIds(
    ReadAloudSplitPlanV3 plan,
    Map<int, String> selectedPathIds,
  ) =>
      _ReadAloudSplitterEngineV3.validateSelectedPathIds(
        plan,
        selectedPathIds,
      );

  static List<String> applySelectedPathIds(
    ReadAloudSplitPlanV3 plan,
    Map<int, String> selectedPathIds,
  ) =>
      _ReadAloudSplitterEngineV3.applySelectedPathIds(plan, selectedPathIds);

  static List<String> selectedSentencesBeforePostProcessing(
    ReadAloudSplitPlanV3 plan,
    Map<int, String> selectedPathIds,
  ) =>
      _ReadAloudSplitterEngineV3.selectedSentencesBeforePostProcessing(
        plan,
        selectedPathIds,
      );

  static void validateReviewedSentences(
    String englishContent,
    List<String> sentences, {
    Iterable<int> requiredBoundaryWordOffsets = const [],
    bool rejectOneWordChunks = false,
  }) =>
      _ReadAloudSplitterEngineV3.validateReviewedSentences(
        englishContent,
        sentences,
        requiredBoundaryWordOffsets: requiredBoundaryWordOffsets,
        rejectOneWordChunks: rejectOneWordChunks,
      );
}
