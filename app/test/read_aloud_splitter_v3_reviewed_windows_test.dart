import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v3.dart';

void main() {
  test('keeps all 55 reviewed Alice and Willows windows supported', () {
    final fixture = Map<String, dynamic>.from(
      jsonDecode(
        File(
          'test/fixtures/read_aloud_splitter_v3_reviewed_windows.json',
        ).readAsStringSync(),
      ) as Map,
    );
    expect(
      fixture['schemaVersion'],
      'read_aloud_splitter_v3_reviewed_windows_v2',
    );
    expect(fixture['parserVersion'], 'udpipe-1.4.0');
    expect(
      fixture['modelSha256'],
      'b71fb73473bedbca575bfc927fceb0f6dd53f74493bb9c58a9e77bd28d24a71f',
    );
    expect(fixture['reviewUnitCount'], 55);
    expect(
      (fixture['supportPolicy'] as Map)['maxExpandedCandidatePaths'],
      ReadAloudSplitterV3.maxExpandedCandidatePaths,
    );

    final cases = (fixture['cases'] as List)
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList(growable: false);
    expect(cases, hasLength(fixture['caseCount'] as int));
    final windowIds = <String>{};
    final unsupportedFullCoverage = <String>[];
    final unavailableReviewUnits = <String>[];
    final selectedEmergencies = <String>[];

    for (final reviewCase in cases) {
      final caseId = reviewCase['caseId'].toString();
      late final Map<String, dynamic> reviewScopeFixture;
      late final ReadAloudSplitPlanV3 reviewScopePlan;
      final caseWindowIds = (reviewCase['windowIds'] as List)
          .map((value) => value.toString())
          .toList(growable: false);
      expect(
        windowIds.intersection(caseWindowIds.toSet()),
        isEmpty,
        reason: '$caseId repeats a reviewed window id',
      );
      windowIds.addAll(caseWindowIds);

      if (reviewCase['reviewStatus'] == 'approved') {
        final plan = _planFromFixture(
          reviewCase,
          parserVersion: fixture['parserVersion'].toString(),
          modelSha256: fixture['modelSha256'].toString(),
        );
        expect(plan.originals, hasLength(1), reason: caseId);
        final expectedSegments = _strings(reviewCase['expectedSegments']);
        final expectedWordCounts = _ints(reviewCase['expectedWordCounts']);
        _expectRuleCompliantSegments(
          reviewCase['source'].toString(),
          expectedSegments,
          expectedWordCounts,
          reason: caseId,
        );
        final decision = plan.originals.single;
        if (!decision.candidateCoverage.supportsWordCounts(
          expectedWordCounts,
        )) {
          unsupportedFullCoverage.add(caseId);
        }
        _expectNormalSelectedPath(
          decision,
          selectedEmergencies: selectedEmergencies,
          label: caseId,
        );
        expect(plan.counters.sentenceFactBuilds, 1, reason: caseId);
        expect(plan.counters.dagSolves, 1, reason: caseId);
        reviewScopeFixture = reviewCase;
        reviewScopePlan = plan;
      } else {
        expect(reviewCase['reviewStatus'], 'source_damage_negative');
        _expectDamagedAliceSourceIsNotGuessed(
          reviewCase,
          parserVersion: fixture['parserVersion'].toString(),
          modelSha256: fixture['modelSha256'].toString(),
        );
        reviewScopeFixture = Map<String, dynamic>.from(
          reviewCase['repairedFixture'] as Map,
        );
        reviewScopePlan = _expectRepairedAliceFixtureSupported(
          reviewCase,
          repaired: reviewScopeFixture,
          parserVersion: fixture['parserVersion'].toString(),
          modelSha256: fixture['modelSha256'].toString(),
          unsupportedFullCoverage: unsupportedFullCoverage,
        );
      }

      final reviewUnits = (reviewCase['reviewUnits'] as List)
          .map((value) => Map<String, dynamic>.from(value as Map))
          .toList(growable: false);
      expect(reviewUnits, hasLength(caseWindowIds.length), reason: caseId);
      for (final unit in reviewUnits) {
        final windowId = unit['windowId'].toString();
        expect(caseWindowIds, contains(windowId), reason: caseId);
        expect(
          unit['sourceScope'],
          reviewCase['reviewStatus'] == 'approved'
              ? 'parentCase'
              : 'repairedFixture',
        );
        final expectedSegments = _strings(unit['expectedSegments']);
        final expectedWordCounts = _ints(unit['expectedWordCounts']);
        _expectRuleCompliantReviewedSegments(
          reviewScopeFixture['source'].toString(),
          expectedSegments,
          expectedWordCounts,
          reason: '$caseId/$windowId',
        );
        final targetAfterWord = (unit['targetAfterWord'] as num).toInt();
        expect(
          reviewScopePlan
              .originals.single.candidateCoverage.reachableBoundaryAfterWords,
          contains(targetAfterWord),
          reason: '$caseId/$windowId',
        );
        if (!_hasMaterializedReviewedBoundary(
          reviewScopePlan,
          targetAfterWord,
        )) {
          unavailableReviewUnits.add(
            '$caseId/$windowId expected=${expectedWordCounts.join('/')} '
            'selected=${reviewScopePlan.originals.map((decision) => decision.localPath.wordCounts.join('/')).join('+')} '
            'candidates=${reviewScopePlan.originals.map((decision) => decision.candidatePaths.length).join('+')} '
            'expectedText=${jsonEncode(expectedSegments)} '
            'selectedText=${jsonEncode(reviewScopePlan.localSentencesBeforePostProcessing)}',
          );
        }
      }
    }

    expect(windowIds, hasLength(fixture['windowCount'] as int));
    expect(windowIds, hasLength(55));
    expect(unsupportedFullCoverage, isEmpty);
    expect(unavailableReviewUnits, isEmpty);
    expect(selectedEmergencies, isEmpty);
  });
}

void _expectDamagedAliceSourceIsNotGuessed(
  Map<String, dynamic> reviewCase, {
  required String parserVersion,
  required String modelSha256,
}) {
  final plan = _planFromFixture(
    reviewCase,
    parserVersion: parserVersion,
    modelSha256: modelSha256,
  );
  expect(plan.originals, hasLength(1));
  final damagedSource = reviewCase['source'].toString();
  expect(damagedSource, contains('!"she'));
  expect(
    _segmentsFollowSource(
      damagedSource,
      plan.localSentencesBeforePostProcessing,
    ),
    isTrue,
  );
  expect(
    plan.originals.single.candidateCoverage.supportsWordCounts(
      _ints(reviewCase['damagedReferenceWordCounts']),
    ),
    isFalse,
  );
  expect(
    plan.originals.single.boundaryCandidates.any(
      (boundary) =>
          boundary.hardBlocked &&
          boundary.hardBlockReasons.contains(
            'inside_surface_determiner_head',
          ),
    ),
    isTrue,
  );
}

ReadAloudSplitPlanV3 _expectRepairedAliceFixtureSupported(
  Map<String, dynamic> reviewCase, {
  required Map<String, dynamic> repaired,
  required String parserVersion,
  required String modelSha256,
  required List<String> unsupportedFullCoverage,
}) {
  final plan = _planFromFixture(
    repaired,
    parserVersion: parserVersion,
    modelSha256: modelSha256,
  );
  expect(plan.originals, hasLength(1));
  final expectedSegments = _strings(repaired['expectedSegments']);
  final expectedWordCounts = _ints(repaired['expectedWordCounts']);
  _expectRuleCompliantSegments(
    repaired['source'].toString(),
    expectedSegments,
    expectedWordCounts,
    reason: '${reviewCase['caseId']}/repaired',
  );
  final decision = plan.originals.single;
  if (!decision.candidateCoverage.supportsWordCounts(expectedWordCounts)) {
    unsupportedFullCoverage.add('${reviewCase['caseId']}/repaired');
  }
  return plan;
}

void _expectRuleCompliantSegments(
  String source,
  List<String> segments,
  List<int> wordCounts, {
  required String reason,
}) {
  expect(segments, hasLength(wordCounts.length), reason: reason);
  expect(
    _segmentsFollowSource(source, segments),
    isTrue,
    reason: '$reason must reconstruct the source',
  );
  for (var index = 0; index < segments.length; index += 1) {
    expect(
      ReadAloudSplitterV3.wordCount(segments[index]),
      wordCounts[index],
      reason: '$reason segment ${index + 1}',
    );
    expect(wordCounts[index], inInclusiveRange(2, 20), reason: reason);
  }
}

void _expectRuleCompliantReviewedSegments(
  String source,
  List<String> segments,
  List<int> wordCounts, {
  required String reason,
}) {
  expect(segments, hasLength(wordCounts.length), reason: reason);
  expect(
    _segmentsAppearInSource(source, segments),
    isTrue,
    reason: '$reason must be a consecutive source window',
  );
  for (var index = 0; index < segments.length; index += 1) {
    expect(
      ReadAloudSplitterV3.wordCount(segments[index]),
      wordCounts[index],
      reason: '$reason segment ${index + 1}',
    );
    expect(wordCounts[index], inInclusiveRange(2, 20), reason: reason);
  }
}

void _expectNormalSelectedPath(
  ReadAloudOriginalDecisionV3 decision, {
  required List<String> selectedEmergencies,
  required String label,
}) {
  if (decision.localPath.isEmergency ||
      decision.localPath.boundaries.any(
        (boundary) => boundary.hardBlocked || boundary.isEmergency,
      )) {
    selectedEmergencies.add(label);
  }
  expect(
    decision.localPath.wordCounts,
    everyElement(inInclusiveRange(2, 20)),
    reason: label,
  );
  expect(
    decision.candidatePaths.length,
    lessThanOrEqualTo(ReadAloudSplitterV3.maxExpandedCandidatePaths),
    reason: label,
  );
}

bool _hasMaterializedReviewedBoundary(
  ReadAloudSplitPlanV3 plan,
  int targetAfterWord,
) {
  for (final decision in plan.originals) {
    for (final path in decision.candidatePaths) {
      if (path.boundaries.any(
        (boundary) => boundary.afterWord == targetAfterWord,
      )) {
        return true;
      }
    }
  }
  return false;
}

List<String> _strings(Object? value) =>
    (value as List).map((item) => item.toString()).toList(growable: false);

List<int> _ints(Object? value) => (value as List)
    .map((item) => (item as num).toInt())
    .toList(growable: false);

bool _segmentsFollowSource(String source, List<String> segments) {
  var cursor = 0;
  for (final segment in segments) {
    while (cursor < source.length && RegExp(r'\s').hasMatch(source[cursor])) {
      cursor += 1;
    }
    if (!source.startsWith(segment, cursor)) return false;
    cursor += segment.length;
  }
  while (cursor < source.length && RegExp(r'\s').hasMatch(source[cursor])) {
    cursor += 1;
  }
  return cursor == source.length;
}

bool _segmentsAppearInSource(String source, List<String> segments) {
  if (segments.isEmpty) return false;
  final firstStart = source.indexOf(segments.first);
  if (firstStart < 0) return false;
  var cursor = firstStart;
  for (final segment in segments) {
    while (cursor < source.length && RegExp(r'\s').hasMatch(source[cursor])) {
      cursor += 1;
    }
    if (!source.startsWith(segment, cursor)) return false;
    cursor += segment.length;
  }
  return true;
}

ReadAloudSplitPlanV3 _planFromFixture(
  Map<String, dynamic> sourceFixture, {
  required String parserVersion,
  required String modelSha256,
}) {
  final source = sourceFixture['source'].toString();
  final document = _documentFromFixture(
    sourceFixture,
    parserVersion: parserVersion,
    modelSha256: modelSha256,
  );
  expect(document.sentences.first.start, 0);
  expect(document.sentences.last.end, source.length);
  return ReadAloudSplitterV3.plan(source: source, document: document);
}

DependencyDocumentV3 _documentFromFixture(
  Map<String, dynamic> sourceFixture, {
  required String parserVersion,
  required String modelSha256,
}) {
  final sentences = (sourceFixture['parserSentences'] as List)
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
