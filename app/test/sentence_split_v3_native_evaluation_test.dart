import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v3.dart';
import 'package:tomato_english_happy_talking/services/udpipe_syntax_parser_v3.dart';

void main() {
  final enabled = Platform.environment['TOMATO_RUN_SENTENCE_V3_EVAL'] == '1';

  test('keeps all five human-reviewed Doubao Lite paths rejected', () {
    const reviewedApprovedReferences = <String, List<String>>{
      'technical_gateway_retry': [
        'The client retries the request when the gateway closes the connection',
        'before the server has returned a complete response to the original operation.',
      ],
      'legal_tenant_hearing': [
        'A tenant who receives a written notice may request a hearing',
        'before the authority begins any action that could terminate the tenancy.',
      ],
      'learner_presentation': [
        'Although Maria had practiced the presentation several times',
        'she spoke slowly enough for every student in the crowded room to understand her main argument.',
      ],
      'instructions_filter_replacement': [
        'Before replacing the filter disconnect the machine from its power supply',
        'and wait until every moving component has come to a complete stop.',
      ],
    };
    final fixture = jsonDecode(
      File(
        'test/fixtures/sentence_split_v3_ai_tuning_cases.json',
      ).readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(fixture['schemaVersion'], 'sentence_split_ai_tuning_cases_v3_2');
    final review = Map<String, dynamic>.from(fixture['humanReview'] as Map);
    expect(
      review['decision'],
      'keep_existing_approved_references_and_reject_all_five_disputed_doubao_lite_paths',
    );
    expect(review['rejectedPathCount'], 5);

    var rejectedPathCount = 0;
    final items = (fixture['items'] as List)
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList(growable: false);
    for (final item in items) {
      final approved = (item['approvedChunks'] as List)
          .map(
            (path) => (path as List)
                .map((chunk) => chunk.toString())
                .toList(growable: false),
          )
          .toList(growable: false);
      final reviewedApproved = reviewedApprovedReferences[item['id']];
      if (reviewedApproved != null) {
        expect(
          approved,
          hasLength(1),
          reason: '${item['id']} must not gain another approved alternative',
        );
        expect(
          _sameNormalized(approved.single, reviewedApproved),
          isTrue,
          reason: '${item['id']} must retain the confirmed approved reference',
        );
      }
      final rejectedValue = item['humanRejectedChunks'];
      if (rejectedValue is! List) continue;
      expect(
        item['humanReviewRationale'].toString().trim(),
        isNotEmpty,
        reason: '${item['id']} must retain the human-review rationale',
      );
      for (final pathValue in rejectedValue) {
        final rejected = (pathValue as List)
            .map((chunk) => chunk.toString())
            .toList(growable: false);
        rejectedPathCount += 1;
        expect(
          rejected.every((chunk) => chunk.trim().isNotEmpty),
          isTrue,
          reason: '${item['id']} contains an empty rejected chunk',
        );
        expect(
          approved.any((path) => _sameNormalized(path, rejected)),
          isFalse,
          reason: '${item['id']} rejected path must not become approved',
        );
        expect(
          ReadAloudSplitterV3.normalizeForRoundTrip(rejected.join(' ')),
          ReadAloudSplitterV3.normalizeForRoundTrip(item['source'].toString()),
          reason: '${item['id']} rejected path must still preserve the source',
        );
      }
    }
    expect(rejectedPathCount, 5);
  });

  test(
    'evaluates the native V3 pipeline against all retained gold inputs',
    () async {
      final repository = Directory.current.parent;
      final probe = File(
        Platform.environment['TOMATO_UDPIPE_PROBE'] ??
            '${repository.path}/build/udpipe-v3-trainer/udpipe_v3_probe.exe',
      );
      final model = File(
        Platform.environment['TOMATO_UDPIPE_MODEL'] ??
            '${repository.path}/build/udpipe-reference/english-ewt-ud-2.5-191206.udpipe',
      );
      final output = File(
        Platform.environment['TOMATO_SENTENCE_V3_EVAL_OUTPUT'] ??
            '${repository.path}/output/sentence-split-v3/native-gold-evaluation.json',
      );
      expect(probe.existsSync(), isTrue, reason: probe.path);
      expect(model.existsSync(), isTrue, reason: model.path);

      final fixture = jsonDecode(
        File('test/fixtures/sentence_split_gold_v3.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final allItems = (fixture['items'] as List)
          .map((value) => Map<String, dynamic>.from(value as Map))
          .toList(growable: false);
      final requestedStart = int.tryParse(
            Platform.environment['TOMATO_SENTENCE_V3_EVAL_START'] ?? '',
          ) ??
          0;
      final requestedCount = int.tryParse(
        Platform.environment['TOMATO_SENTENCE_V3_EVAL_COUNT'] ?? '',
      );
      final startIndex = requestedStart.clamp(0, allItems.length);
      final endIndex = requestedCount == null
          ? allItems.length
          : (startIndex + requestedCount).clamp(startIndex, allItems.length);
      final items = allItems.sublist(startIndex, endIndex);
      final digest = await Sha256().hash(await model.readAsBytes());
      final modelSha = digest.bytes
          .map((value) => value.toRadixString(16).padLeft(2, '0'))
          .join();
      var nativeCalls = 0;
      final temp = await Directory.systemTemp.createTemp('tomato-v3-eval-');
      try {
        Future<String> provider({
          required text,
          required presegmented,
        }) async {
          nativeCalls += 1;
          final input = File('${temp.path}/input-$nativeCalls.txt');
          await input.writeAsString(text, encoding: utf8, flush: true);
          final process = await Process.run(
            probe.path,
            [
              model.path,
              input.path,
              if (presegmented) '--presegmented',
            ],
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          if (process.exitCode != 0) {
            throw StateError('UDPipe probe failed: ${process.stderr}');
          }
          return process.stdout.toString();
        }

        final results = <Map<String, dynamic>>[];
        var exactMatches = 0;
        var parserHealthy = true;
        var originalSentenceCount = 0;
        var outputSentenceCount = 0;
        var aiReviewOriginalCount = 0;
        var emergencyOriginalCount = 0;
        var expectedPathAvailableCount = 0;
        var localMismatchButExpectedPathAvailableCount = 0;
        String? parserVersion;
        final batchSize = int.tryParse(
              Platform.environment['TOMATO_SENTENCE_V3_EVAL_BATCH_SIZE'] ?? '',
            ) ??
            20;
        expect(batchSize, greaterThan(0));
        for (var start = 0; start < items.length; start += batchSize) {
          final end = (start + batchSize).clamp(0, items.length);
          // ignore: avoid_print
          print(
            'starting retained gold inputs '
            '${startIndex + start + 1}-${startIndex + end}/'
            '${allItems.length}',
          );
          final batch = await _evaluateBatch(
            items: items.sublist(start, end),
            modelSha: modelSha,
            provider: provider,
          );
          results.addAll(batch.results);
          exactMatches += batch.exactMatches;
          parserHealthy = parserHealthy && batch.parserHealthy;
          parserVersion ??= batch.parserVersion;
          originalSentenceCount += batch.originalSentenceCount;
          outputSentenceCount += batch.outputSentenceCount;
          aiReviewOriginalCount += batch.aiReviewOriginalCount;
          emergencyOriginalCount += batch.emergencyOriginalCount;
          expectedPathAvailableCount += batch.expectedPathAvailableCount;
          localMismatchButExpectedPathAvailableCount +=
              batch.localMismatchButExpectedPathAvailableCount;
          // Visible progress prevents a long native benchmark from looking
          // hung in CI or the desktop command runner.
          // ignore: avoid_print
          print(
            'evaluated ${startIndex + end}/${allItems.length} retained gold '
            'inputs',
          );
        }
        final report = {
          'schemaVersion': 'sentence_split_native_evaluation_v3_2',
          'modelSha256': modelSha,
          'parserVersion': parserVersion,
          'solverVersion': ReadAloudSplitterV3.solverVersion,
          'nativeCalls': nativeCalls,
          'fixtureItemCount': allItems.length,
          'rangeStart': startIndex,
          'rangeEnd': endIndex,
          'itemCount': items.length,
          'exactMatchCount': exactMatches,
          'exactMatchRate': items.isEmpty ? 0 : exactMatches / items.length,
          'parserHealthy': parserHealthy,
          'originalSentenceCount': originalSentenceCount,
          'outputSentenceCount': outputSentenceCount,
          'aiReviewOriginalCount': aiReviewOriginalCount,
          'emergencyOriginalCount': emergencyOriginalCount,
          'expectedPathAvailableCount': expectedPathAvailableCount,
          'expectedPathAvailableRate':
              items.isEmpty ? 0 : expectedPathAvailableCount / items.length,
          'localMismatchButExpectedPathAvailableCount':
              localMismatchButExpectedPathAvailableCount,
          'results': results,
        };
        await output.parent.create(recursive: true);
        await output.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(report)}\n',
          encoding: utf8,
          flush: true,
        );
        expect(parserHealthy, isTrue);
        expect(outputSentenceCount, greaterThan(0));
      } finally {
        await temp.delete(recursive: true);
      }
    },
    skip: enabled ? false : 'set TOMATO_RUN_SENTENCE_V3_EVAL=1',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<_BatchEvaluationV3> _evaluateBatch({
  required List<Map<String, dynamic>> items,
  required String modelSha,
  required UdpipeRawParseProviderV3 provider,
}) async {
  final combined = StringBuffer();
  final itemRanges = <({int start, int end})>[];
  for (final item in items) {
    if (combined.isNotEmpty) combined.write('\n\n');
    final start = combined.length;
    combined.write(item['source'] as String);
    itemRanges.add((start: start, end: combined.length));
  }
  final source = combined.toString();
  final document = await UdpipeSyntaxParserV3.parseRawPipelineForTest(
    source: source,
    modelSha256: modelSha,
    provider: provider,
  );
  final results = <Map<String, dynamic>>[];
  var exactMatches = 0;
  var expectedPathAvailableCount = 0;
  var localMismatchButExpectedPathAvailableCount = 0;
  var parserHealthy = document.healthy;
  var originalSentenceCount = 0;
  var outputSentenceCount = 0;
  var aiReviewOriginalCount = 0;
  var emergencyOriginalCount = 0;
  for (var index = 0; index < items.length; index += 1) {
    final item = items[index];
    final range = itemRanges[index];
    final itemSource = item['source'] as String;
    final itemDocument = _sliceEvaluationDocument(
      document,
      start: range.start,
      end: range.end,
    );
    late final ReadAloudSplitPlanV3 plan;
    try {
      plan = ReadAloudSplitterV3.plan(
        source: itemSource,
        document: itemDocument,
      );
    } on FormatException catch (error) {
      throw FormatException(
        '$error; item=${item['id']}; source=${jsonEncode(itemSource)}; '
        'parsedRanges='
        '${itemDocument.sentences.map((value) => '${value.start}-${value.end}').join(',')}',
      );
    }
    final decisions = plan.originals;
    parserHealthy = parserHealthy && plan.parserHealthy;
    originalSentenceCount += plan.originals.length;
    outputSentenceCount += plan.localSentences.length;
    aiReviewOriginalCount +=
        plan.originals.where((value) => value.requiresAiReview).length;
    emergencyOriginalCount +=
        plan.originals.where((value) => value.localPath.isEmergency).length;
    final predicted = decisions
        .expand((decision) => decision.localPath.segments)
        .toList(growable: false);
    final expected = (item['expectedChunks'] as List)
        .map((value) => value.toString())
        .toList(growable: false);
    final approvedPaths = item['approvedChunks'] is List
        ? (item['approvedChunks'] as List)
            .map(
              (path) => (path as List)
                  .map((value) => value.toString())
                  .toList(growable: false),
            )
            .toList(growable: false)
        : <List<String>>[expected];
    final exact = approvedPaths.any(
      (approved) => _sameNormalized(approved, predicted),
    );
    final expectedPathAvailable = approvedPaths.any(
      (approved) => _expectedPathAvailable(
        expected: approved,
        decisions: decisions,
      ),
    );
    if (exact) exactMatches += 1;
    if (expectedPathAvailable) expectedPathAvailableCount += 1;
    if (!exact && expectedPathAvailable) {
      localMismatchButExpectedPathAvailableCount += 1;
    }
    results.add({
      'id': item['id'],
      'episode': item['episode'],
      'source': item['source'],
      'expected': expected,
      'approvedPaths': approvedPaths,
      'predicted': predicted,
      'exact': exact,
      'expectedPathAvailable': expectedPathAvailable,
      'originals': decisions
          .map(
            (decision) => {
              'source': decision.source,
              'parserHealthy': decision.parserHealthy,
              'parserIssues': decision.parserIssues,
              'parseCost': decision.parseCost,
              'parseCostPerToken': decision.parseCostPerToken,
              'localPathId': decision.localPathId,
              'candidatePaths': decision.candidatePaths
                  .map(
                    (path) => {
                      'pathId': path.pathId,
                      'stage': path.stage.name,
                      'segments': path.segments,
                      'wordCounts': path.wordCounts,
                      'boundaries': path.boundaries
                          .map(
                            (boundary) => {
                              'afterWord': boundary.afterWord,
                              'kind': boundary.kind.name,
                              'risk': boundary.risk,
                              'crossedDependencyArcs':
                                  boundary.crossedDependencyArcs,
                              'protectedRelationCrossings':
                                  boundary.protectedRelationCrossings,
                              'reasons': boundary.reasons,
                              'softWarnings': boundary.softWarnings,
                            },
                          )
                          .toList(growable: false),
                    },
                  )
                  .toList(growable: false),
            },
          )
          .toList(growable: false),
    });
  }
  return _BatchEvaluationV3(
    results: results,
    exactMatches: exactMatches,
    parserHealthy: parserHealthy,
    parserVersion: document.parserVersion,
    originalSentenceCount: originalSentenceCount,
    outputSentenceCount: outputSentenceCount,
    aiReviewOriginalCount: aiReviewOriginalCount,
    emergencyOriginalCount: emergencyOriginalCount,
    expectedPathAvailableCount: expectedPathAvailableCount,
    localMismatchButExpectedPathAvailableCount:
        localMismatchButExpectedPathAvailableCount,
  );
}

DependencyDocumentV3 _sliceEvaluationDocument(
  DependencyDocumentV3 document, {
  required int start,
  required int end,
}) {
  final sentences = document.sentences
      .where((sentence) => sentence.start >= start && sentence.end <= end)
      .map(
        (sentence) => DependencySentenceV3(
          start: sentence.start - start,
          end: sentence.end - start,
          parseCost: sentence.parseCost,
          parseCostPerToken: sentence.parseCostPerToken,
          tokens: [
            for (final token in sentence.tokens)
              DependencyTokenV3(
                id: token.id,
                text: token.text,
                sourceText: token.sourceText,
                start: token.start - start,
                end: token.end - start,
                upos: token.upos,
                head: token.head,
                deprel: token.deprel,
              ),
          ],
        ),
      )
      .toList(growable: false);
  if (sentences.isEmpty) {
    throw const FormatException(
      'Native evaluation item contains no parser sentence',
    );
  }
  return DependencyDocumentV3(
    parserVersion: document.parserVersion,
    modelSha256: document.modelSha256,
    sentences: sentences,
    healthy: document.healthy,
    issues: document.issues,
  );
}

class _BatchEvaluationV3 {
  const _BatchEvaluationV3({
    required this.results,
    required this.exactMatches,
    required this.parserHealthy,
    required this.parserVersion,
    required this.originalSentenceCount,
    required this.outputSentenceCount,
    required this.aiReviewOriginalCount,
    required this.emergencyOriginalCount,
    required this.expectedPathAvailableCount,
    required this.localMismatchButExpectedPathAvailableCount,
  });

  final List<Map<String, dynamic>> results;
  final int exactMatches;
  final bool parserHealthy;
  final String parserVersion;
  final int originalSentenceCount;
  final int outputSentenceCount;
  final int aiReviewOriginalCount;
  final int emergencyOriginalCount;
  final int expectedPathAvailableCount;
  final int localMismatchButExpectedPathAvailableCount;
}

bool _expectedPathAvailable({
  required List<String> expected,
  required List<ReadAloudOriginalDecisionV3> decisions,
}) {
  final expectedEnds = <int>{};
  var expectedWordOffset = 0;
  for (final segment in expected) {
    expectedWordOffset += ReadAloudSplitterV3.wordCount(segment);
    expectedEnds.add(expectedWordOffset);
  }

  var originalWordOffset = 0;
  for (final decision in decisions) {
    final originalEnd =
        originalWordOffset + ReadAloudSplitterV3.wordCount(decision.source);
    final targetEnds = expectedEnds
        .where(
          (value) => value > originalWordOffset && value <= originalEnd,
        )
        .toSet();
    final hasCandidate = decision.candidatePaths.any((path) {
      final candidateEnds = <int>{};
      var cursor = originalWordOffset;
      for (final count in path.wordCounts) {
        cursor += count;
        candidateEnds.add(cursor);
      }
      return candidateEnds.length == targetEnds.length &&
          candidateEnds.containsAll(targetEnds);
    });
    if (!hasCandidate) return false;
    originalWordOffset = originalEnd;
  }
  return originalWordOffset == expectedWordOffset;
}

bool _sameNormalized(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (ReadAloudSplitterV3.normalizeForRoundTrip(left[index]) !=
        ReadAloudSplitterV3.normalizeForRoundTrip(right[index])) {
      return false;
    }
  }
  return true;
}
