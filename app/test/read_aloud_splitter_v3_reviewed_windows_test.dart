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
      'read_aloud_splitter_v3_reviewed_windows_v1',
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
    final isolatedUnavailablePaths = <String>[];
    final isolatedSelectionDifferences = <String>[];
    for (final reviewCase in cases) {
      final caseWindowIds = (reviewCase['windowIds'] as List)
          .map((value) => value.toString())
          .toList(growable: false);
      expect(
        windowIds.intersection(caseWindowIds.toSet()),
        isEmpty,
        reason: '${reviewCase['caseId']} repeats a reviewed window id',
      );
      windowIds.addAll(caseWindowIds);

      final source = reviewCase['source'].toString();
      final document = _documentFromFixture(
        reviewCase,
        parserVersion: fixture['parserVersion'].toString(),
        modelSha256: fixture['modelSha256'].toString(),
      );
      expect(document.sentences.first.start, 0);
      expect(document.sentences.last.end, source.length);

      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: document,
      );
      expect(
        plan.originals,
        hasLength(1),
        reason: '${reviewCase['caseId']} must remain one reviewed original',
      );
      final decision = plan.originals.single;
      final expectedSegments = (reviewCase['expectedSegments'] as List)
          .map((value) => value.toString())
          .toList(growable: false);
      final expectedWordCounts = (reviewCase['expectedWordCounts'] as List)
          .map((value) => (value as num).toInt())
          .toList(growable: false);
      final approvedPath = decision.candidatePaths
          .where((path) => _sameStrings(path.segments, expectedSegments))
          .firstOrNull;
      if (approvedPath == null) {
        isolatedUnavailablePaths.add(reviewCase['caseId'].toString());
      } else {
        expect(approvedPath.wordCounts, expectedWordCounts);
      }
      if (!_sameStrings(decision.localPath.segments, expectedSegments)) {
        isolatedSelectionDifferences.add(reviewCase['caseId'].toString());
      }
      expect(plan.counters.sentenceFactBuilds, 1);
      expect(plan.counters.dagSolves, 1);
    }

    expect(windowIds, hasLength(fixture['windowCount'] as int));
    expect(windowIds, hasLength(55));
    expect(isolatedUnavailablePaths, isEmpty);
    // The approved nested-dialogue path is now available in isolation, but the
    // surrounding chapter quote stack is still required to select it.
    expect(isolatedSelectionDifferences, const ['Alice-E30-8']);
  });
}

bool _sameStrings(List<String> left, List<String> right) =>
    left.length == right.length &&
    Iterable<int>.generate(left.length)
        .every((index) => left[index] == right[index]);

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
