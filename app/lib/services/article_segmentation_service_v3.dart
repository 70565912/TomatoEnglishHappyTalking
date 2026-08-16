import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../core/logging/tomato_logger.dart';
import '../data/models/article_segmentation_run_model.dart';
import 'practice_text_service.dart';
import 'read_aloud_splitter_v3.dart';
import 'udpipe_syntax_parser_v3.dart';

class ArticleSegmentationResultV3 {
  const ArticleSegmentationResultV3({
    required this.sentences,
    required this.plan,
    required this.selection,
    required this.audit,
  });

  final List<String> sentences;
  final ReadAloudSplitPlanV3 plan;
  final PracticeCandidatePathSelectionV3 selection;
  final ArticleSegmentationRunRecord audit;
}

/// The single production entry point for V3 read-aloud segmentation.
///
/// The browser never proposes boundaries. The parser produces dependency
/// evidence, Dart owns every feasible path and hard constraint, and the text
/// model may only select a path id that Dart already supplied.
class ArticleSegmentationServiceV3 {
  const ArticleSegmentationServiceV3({
    ReadAloudSyntaxParserV3? parser,
  }) : _parser = parser;

  final ReadAloudSyntaxParserV3? _parser;

  Future<ArticleSegmentationResultV3> split(
    String text, {
    int? articleId,
  }) async {
    final source = text.trim();
    if (source.isEmpty) {
      throw const FormatException('V3 分句正文不能为空');
    }

    DependencyDocumentV3 document;
    Object? parserError;
    try {
      document = await (_parser ?? UdpipeSyntaxParserV3()).parse(source);
    } catch (error, stackTrace) {
      parserError = error;
      TomatoLogger.error(
        category: 'sentence_split',
        event: 'parser.emergency_document',
        articleId: articleId,
        error: error,
        stackTrace: stackTrace,
        data: const {
          'visibleFallback': true,
          'legacyWordListFallback': false,
        },
      );
      document = _emergencyDocument(source, error);
    }

    final plan = ReadAloudSplitterV3.plan(
      source: source,
      document: document,
    );
    final selection = await PracticeTextService.reviewCandidatePathsV3(
      plan: plan,
      articleId: articleId,
    );
    final sentencesBeforePostProcessing =
        ReadAloudSplitterV3.selectedSentencesBeforePostProcessing(
      plan,
      selection.selectedPathIds,
    );
    final sentences = List<String>.unmodifiable(
      ReadAloudSplitterV3.mergeOneWordChunks(sentencesBeforePostProcessing),
    );
    ReadAloudSplitterV3.validateReviewedSentences(
      source,
      sentences,
      rejectOneWordChunks: true,
      requiredBoundaryWordOffsets:
          ReadAloudSplitterV3.requiredBoundaryWordOffsetsAfterMerge(
        plan,
        selection.selectedPathIds,
      ),
    );

    final sourceHash = await _sha256(source);
    final audit = ArticleSegmentationRunRecord(
      sourceHash: sourceHash,
      sentenceSplitVersion: ReadAloudSplitterV3.reviewedVersion,
      solverVersion: ReadAloudSplitterV3.solverVersion,
      parserVersion: plan.parserVersion,
      modelSha256: plan.modelSha256,
      parserHealthy: plan.parserHealthy,
      parserIssues: List.unmodifiable([
        ...plan.parserIssues,
        if (parserError != null) 'parser_exception:${parserError.runtimeType}',
      ]),
      candidatePaths: List.unmodifiable([
        for (final decision in plan.originals)
          {
            'originalIndex': decision.originalIndex,
            'sourceStart': decision.sourceStart,
            'sourceEnd': decision.sourceEnd,
            'parserHealthy': decision.parserHealthy,
            'parserIssues': decision.parserIssues,
            'parseCost': decision.parseCost,
            'parseCostPerToken': decision.parseCostPerToken,
            'localPathId': decision.localPathId,
            'initialCandidateSetHash': decision.initialCandidateSetHash,
            'expandedCandidateSetHash': decision.expandedCandidateSetHash,
            'boundaryCandidates': decision.boundaryCandidates
                .map((candidate) => candidate.toJson())
                .toList(growable: false),
            'initialCandidatePaths': decision.initialCandidatePaths
                .map((path) => path.toJson())
                .toList(growable: false),
            'expandedCandidatePaths': decision.expandedCandidatePaths
                .map((path) => path.toJson())
                .toList(growable: false),
          },
      ]),
      sentencesBeforePostProcessing:
          List.unmodifiable(sentencesBeforePostProcessing),
      finalSentences: sentences,
      selectedPaths: Map.unmodifiable(selection.selectedPathIds),
      selectionTrace: List.unmodifiable(selection.selectionTrace),
      aiSource: selection.source.name,
      aiProvider: selection.provider,
      aiModel: selection.model,
      aiRemoteAttempts: selection.remoteAttempts,
      usedLocalFallback: selection.usedLocalFallback,
      fallbackReason: parserError == null
          ? selection.fallbackReason
          : [
              'parser_failed',
              if (selection.fallbackReason != null) selection.fallbackReason!,
            ].join('+'),
      inputTokens: selection.usage.inputTokens,
      outputTokens: selection.usage.outputTokens,
      totalTokens: selection.usage.totalTokens,
      estimatedCostCny: selection.usage.estimatedCostCny,
      createdAt: DateTime.now().toUtc(),
    );
    final parseScores = _finiteParseScores(plan);
    TomatoLogger.info(
      category: 'sentence_split',
      event: 'segmentation.completed',
      articleId: articleId,
      status: selection.usedLocalFallback ? 'emergency' : 'success',
      data: {
        'sentenceSplitVersion': ReadAloudSplitterV3.reviewedVersion,
        'solverVersion': ReadAloudSplitterV3.solverVersion,
        'parserVersion': plan.parserVersion,
        'modelSha256': plan.modelSha256,
        'parserHealthy': plan.parserHealthy,
        'parseCostPerTokenMin': parseScores.isEmpty
            ? null
            : parseScores.reduce((left, right) => left < right ? left : right),
        'parseCostPerTokenMax': parseScores.isEmpty
            ? null
            : parseScores.reduce((left, right) => left > right ? left : right),
        'originalCount': plan.originals.length,
        'sentenceCount': sentences.length,
        'aiSource': selection.source.name,
        'aiProvider': selection.provider,
        'aiModel': selection.model,
        'aiRemoteAttempts': selection.remoteAttempts,
        'fallbackReason': audit.fallbackReason,
        'totalTokens': selection.usage.totalTokens,
        'estimatedCostCny': selection.usage.estimatedCostCny,
      },
    );
    return ArticleSegmentationResultV3(
      sentences: sentences,
      plan: plan,
      selection: selection,
      audit: audit,
    );
  }

  static List<double> _finiteParseScores(ReadAloudSplitPlanV3 plan) =>
      plan.originals
          .map((decision) => decision.parseCostPerToken)
          .whereType<double>()
          .where((value) => value.isFinite)
          .toList(growable: false);

  static Future<String> _sha256(String value) async {
    final digest = await Sha256().hash(utf8.encode(value));
    return digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static DependencyDocumentV3 _emergencyDocument(
    String source,
    Object error,
  ) {
    final spans = _orthographicEmergencySpans(source);
    return DependencyDocumentV3(
      parserVersion: '${UdpipeSyntaxParserV3.parserVersion}-unavailable',
      modelSha256: UdpipeSyntaxParserV3.expectedModelSha256,
      sentences: [
        for (final span in spans)
          DependencySentenceV3(
            start: span.$1,
            end: span.$2,
            tokens: [
              for (final indexed in RegExp(r'\S+')
                  .allMatches(
                    source.substring(span.$1, span.$2),
                  )
                  .indexed)
                DependencyTokenV3(
                  id: indexed.$1 + 1,
                  text: indexed.$2.group(0)!,
                  sourceText: indexed.$2.group(0)!,
                  start: span.$1 + indexed.$2.start,
                  end: span.$1 + indexed.$2.end,
                  upos: 'X',
                  head: 0,
                  deprel: 'dep',
                ),
            ],
          ),
      ],
      healthy: false,
      issues: [
        'parser_unavailable',
        'parser_exception:${error.runtimeType}',
        'emergency_orthographic_boundaries',
      ],
    );
  }

  /// Parser-failure-only boundary recovery. It intentionally has no lexical,
  /// book, character or phrase exceptions. Every use is persisted as an
  /// emergency run and must remain visible to QA.
  static List<(int, int)> _orthographicEmergencySpans(String source) {
    final result = <(int, int)>[];
    var start = 0;
    var index = 0;
    while (index < source.length) {
      final code = source.codeUnitAt(index);
      final isTerminal = code == 0x21 || code == 0x3F || code == 0x2E;
      final isDecimalPeriod = code == 0x2E &&
          index > 0 &&
          index + 1 < source.length &&
          _isDigit(source.codeUnitAt(index - 1)) &&
          _isDigit(source.codeUnitAt(index + 1));
      if (!isTerminal || isDecimalPeriod) {
        index += 1;
        continue;
      }
      var end = index + 1;
      while (end < source.length && _isClosingPunctuation(source[end])) {
        end += 1;
      }
      final next = _nextNonWhitespace(source, end);
      if (next == source.length || next > end) {
        final trimmedStart = _nextNonWhitespace(source, start);
        if (trimmedStart < end) result.add((trimmedStart, end));
        start = end;
      }
      index = end;
    }
    final trailingStart = _nextNonWhitespace(source, start);
    if (trailingStart < source.length) {
      result.add((trailingStart, source.length));
    }
    if (result.isEmpty) result.add((0, source.length));
    return result;
  }

  static int _nextNonWhitespace(String source, int start) {
    var index = start;
    while (index < source.length && source[index].trim().isEmpty) {
      index += 1;
    }
    return index;
  }

  static bool _isDigit(int code) => code >= 0x30 && code <= 0x39;

  static bool _isClosingPunctuation(String character) =>
      '"\'”’)}]'.contains(character);
}
