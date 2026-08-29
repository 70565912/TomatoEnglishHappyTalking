import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v3.dart';

void main() {
  test('selects all approved Looking Glass delimiter windows', () {
    final fixture = Map<String, dynamic>.from(
      jsonDecode(
        File(
          'test/fixtures/read_aloud_splitter_v3_looking_glass_delimiters.json',
        ).readAsStringSync(),
      ) as Map,
    );
    expect(
      fixture['schemaVersion'],
      'read_aloud_splitter_v3_looking_glass_delimiters_v1',
    );
    expect(fixture['parserVersion'], 'udpipe-1.4.0');
    expect(
      fixture['modelSha256'],
      'b71fb73473bedbca575bfc927fceb0f6dd53f74493bb9c58a9e77bd28d24a71f',
    );

    final cases = (fixture['cases'] as List)
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList(growable: false);
    expect(cases, hasLength(fixture['caseCount'] as int));
    final windowIds = <String>{};
    final selectionDifferences = <String>[];
    for (final reviewCase in cases) {
      windowIds.addAll(
        (reviewCase['windowIds'] as List).map((value) => value.toString()),
      );
      final source = reviewCase['source'].toString();
      final document = _documentFromFixture(
        reviewCase,
        parserVersion: fixture['parserVersion'].toString(),
        modelSha256: fixture['modelSha256'].toString(),
      );
      late final ReadAloudSplitPlanV3 plan;
      try {
        plan = ReadAloudSplitterV3.plan(
          source: source,
          document: document,
        );
      } on Object catch (error) {
        fail('${reviewCase['caseId']}: $error');
      }
      final expected = (reviewCase['expectedSegments'] as List)
          .map((value) => value.toString())
          .toList(growable: false);
      if (!_sameStrings(plan.localSentences, expected)) {
        selectionDifferences.add(
          '${reviewCase['caseId']}\n'
          'expected=${expected.join(' | ')}\n'
          'actual=${plan.localSentences.join(' | ')}\n'
          '${_delimiterSummary(source, document)}\n${_candidateSummary(plan)}\n'
          '${_pathSummary(plan)}',
        );
      }
      expect(plan.counters.sentenceFactBuilds, plan.originals.length);
      expect(plan.counters.dagSolves, plan.originals.length);
      expect(
        plan.localSentences.join().replaceAll(RegExp(r'\s+'), ''),
        source.replaceAll(RegExp(r'\s+'), ''),
      );
      expect(
        plan.localSentences
            .map(ReadAloudSplitterV3.wordCount)
            .where((count) => count == 1),
        isEmpty,
        reason: reviewCase['caseId'].toString(),
      );
      final selectedBoundaries = plan.originals
          .expand((original) => original.localPath.boundaries)
          .toList(growable: false);
      expect(
        selectedBoundaries.where(
          (boundary) => boundary.kind == ReadAloudBoundaryKindV3.emergency,
        ),
        isEmpty,
        reason: '${reviewCase['caseId']}: emergency fallback',
      );
      expect(
        selectedBoundaries
            .expand(
              (boundary) => [
                ...boundary.reasons,
                ...boundary.softWarnings,
                ...boundary.hardBlockReasons,
              ],
            )
            .where((reason) => reason.contains('unsupported')),
        isEmpty,
        reason: '${reviewCase['caseId']}: unsupported fallback',
      );
    }

    expect(windowIds, hasLength(fixture['windowCount'] as int));
    expect(windowIds, hasLength(15));
    expect(windowIds, contains('SPLIT-LATE-017-NEGATIVE'));
    expect(selectionDifferences, isEmpty);
  });
}

bool _sameStrings(List<String> left, List<String> right) =>
    left.length == right.length &&
    Iterable<int>.generate(left.length)
        .every((index) => left[index] == right[index]);

String _delimiterSummary(String source, DependencyDocumentV3 document) =>
    ReadAloudDelimiterScannerV3.scan(
      source: source,
      tokens: document.sentences.expand((sentence) => sentence.tokens),
    )
        .quoteSpans
        .map((span) => source.substring(span.start, span.end))
        .join(' | ');

String _candidateSummary(ReadAloudSplitPlanV3 plan) => plan.originals
    .expand((original) => original.boundaryCandidates)
    .where((candidate) => candidate.quoteEdge != null)
    .map(
      (candidate) =>
          '${candidate.afterWord}:${candidate.kind.name}:${candidate.quoteEdge}:'
          '${candidate.quoteSpanWordCount}:${candidate.reasons}:'
          '${candidate.softWarnings}:'
          '${candidate.hardBlockReasons}',
    )
    .join(' | ');

String _pathSummary(ReadAloudSplitPlanV3 plan) => plan.originals
    .expand((original) => original.candidatePaths.take(3))
    .map((path) => '${path.segments.join(' / ')} :: ${path.score}')
    .join('\n');

DependencyDocumentV3 _documentFromFixture(
  Map<String, dynamic> reviewCase, {
  required String parserVersion,
  required String modelSha256,
}) {
  final sentences = (reviewCase['parserSentences'] as List)
      .map((value) => Map<String, dynamic>.from(value as Map))
      .map(
        (sentence) => DependencySentenceV3(
          start: (sentence['start'] as num).toInt(),
          end: (sentence['end'] as num).toInt(),
          parseCost: (sentence['parseCost'] as num?)?.toDouble(),
          parseCostPerToken:
              (sentence['parseCostPerToken'] as num?)?.toDouble(),
          tokens: (sentence['tokens'] as List)
              .map((value) => Map<String, dynamic>.from(value as Map))
              .map(
                (token) => DependencyTokenV3(
                  id: (token['id'] as num).toInt(),
                  text: token['text'].toString(),
                  sourceText: token['sourceText']?.toString(),
                  start: (token['start'] as num).toInt(),
                  end: (token['end'] as num).toInt(),
                  upos: token['upos'].toString(),
                  head: (token['head'] as num).toInt(),
                  deprel: token['deprel'].toString(),
                ),
              )
              .toList(growable: false),
        ),
      )
      .toList(growable: false);
  return DependencyDocumentV3(
    parserVersion: parserVersion,
    modelSha256: modelSha256,
    sentences: sentences,
    healthy: true,
  );
}
