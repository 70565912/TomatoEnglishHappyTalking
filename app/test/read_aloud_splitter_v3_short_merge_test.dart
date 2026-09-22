// Acceptance tests for short source merging and one-pass constrained solving.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v3.dart';

void main() {
  final fixture = jsonDecode(
    File('test/fixtures/read_aloud_short_merge_contract_20260922.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

  test('acceptance inventory contains all 16 + 5 + 5 reviewed cases', () {
    expect(cases.where((item) => item['role'] == 'merge'), hasLength(16));
    expect(cases.where((item) => item['role'] == 'stable'), hasLength(5));
    expect(cases.where((item) => item['role'] == 'mandatory'), hasLength(5));
    expect(cases.map((item) => item['id']).toSet(), hasLength(26));
    for (final item in cases) {
      final input = (item['input'] as List).cast<String>();
      expect(input, isNotEmpty);
      expect(input.every((value) => value.trim().isNotEmpty), isTrue);
      if (item['expected'] case final List expected) {
        _expectFinalFloorAndFidelity(input, expected.cast<String>());
      } else {
        expect(ReadAloudSplitterV3.wordCount(item['target'] as String), 3);
      }
    }
  });

  group('mandatory short merge: reviewed source-unit examples', () {
    for (final item in cases) {
      test('${item['id']} ${item['role']}', () {
        final input = (item['input'] as List).cast<String>();
        final actual = _split(input);
        _expectFinalFloorAndFidelity(input, actual);
        if (item['expected'] case final List expected) {
          expect(actual, expected.cast<String>());
        } else {
          expect(actual, isNot(contains(item['target'])));
        }
      });
    }
  });

  group('mandatory short merge: thresholds and singleton products', () {
    for (final short in ['Wait!', 'Come here.', 'Please come here.']) {
      for (final leading in [true, false]) {
        test('${ReadAloudSplitterV3.wordCount(short)} words, leading=$leading',
            () {
          const neighbor = 'The children waited by the garden gate.';
          final input = leading ? [short, neighbor] : [neighbor, short];
          final actual = _split(input);
          _expectFinalFloorAndFidelity(input, actual);
          expect(actual, [input.join(' ')]);
        });
      }
    }

    test('exactly four words remain when already compliant', () {
      // The goal specifies fewer than four; exactly four is compliant.
      const input = ['Please wait over here.', 'The children opened the gate.'];
      expect(ReadAloudSplitterV3.wordCount(input.first), 4);
      expect(_split(input), input);
    });

    for (final input in <List<String>>[
      ['Home!', 'No.', 'Stop.', 'The story continues here.'],
      ['Or Kitchener?', 'No.', 'It was Mr. Toad.'],
      ['One.', 'Two.', 'Three.', 'Four.'],
      ['Go!', 'Come here.', 'The children waited outside.'],
    ]) {
      test('does not freeze undersized singleton products: ${input.first}', () {
        final actual = _split(input);
        _expectFinalFloorAndFidelity(input, actual);
      });
    }

    for (final short in ['Wait!', 'Come here.', 'Please come here.']) {
      test(
          'a whole input of ${ReadAloudSplitterV3.wordCount(short)} words '
          'cannot be reported as a compliant result', () {
        expect(
          () => _split([short]),
          throwsA(isA<Exception>().having(
            (error) => error.toString(),
            'diagnostic',
            isNotEmpty,
          )),
        );
      });
    }

    test('preserves unaffected outer chunks and the caller input', () {
      const input = [
        'The sun was shining over the garden.',
        'The children waited by the gate.',
        'Come here.',
        'Their mother opened the window upstairs.',
        'The birds were singing in the trees.',
      ];
      final actual = _split(input);
      _expectFinalFloorAndFidelity(input, actual);
      expect(actual.first, input.first);
      expect(actual.last, input.last);
      expect(input[2], 'Come here.');
      expect(_split(actual), actual);
    });
  });

  group('mandatory short merge: apply original length zones after absorption',
      () {
    // Controlled lexical counts exercise the final-pipeline length contract.
    // These tokens are NOT evidence of natural-language parser correctness.
    // The source-semicolon is deliberately available on both sides of >=4 words.
    for (final total in [16, 17, 18, 20, 21, 30, 31]) {
      test('$total words with a usable source semicolon after absorption', () {
        final tokens = _tokens(total);
        tokens[7] = '${tokens[7]};';
        if (total > 24) tokens[15] = '${tokens[15]};';
        final input = [tokens.take(total - 1).join(' '), tokens.last];
        expect(ReadAloudSplitterV3.wordCount(input.join(' ')), total);
        final actual = _split(input);
        _expectFinalFloorAndFidelity(input, actual);

        if (total <= 16) {
          expect(actual, [input.join(' ')]);
        } else if (total == 17) {
          // Elastic: neither KEEP nor splitting is unconditionally required.
          expect(actual.map(ReadAloudSplitterV3.wordCount),
              everyElement(lessThanOrEqualTo(17)));
        } else {
          expect(actual.length, greaterThan(1),
              reason: 'R-LENGTH-ZONES: <=30 alone is not acceptance');
          expect(actual.map(ReadAloudSplitterV3.wordCount),
              everyElement(lessThanOrEqualTo(20)));
          expect(actual.take(actual.length - 1).every((s) => s.endsWith(';')),
              isTrue,
              reason: 'R-PUNCT-FIRST: use available source punctuation');
        }
      });
    }

    for (final total in [17, 18, 20]) {
      test('$total unpunctuated words are elastic, not a blanket 17-word cap',
          () {
        final tokens = _tokens(total);
        final input = [tokens.take(total - 1).join(' '), tokens.last];
        final actual = _split(input);
        _expectFinalFloorAndFidelity(input, actual);
        // The syntax-backed KEEP/split distinction is tested separately below.
        expect(actual.map(ReadAloudSplitterV3.wordCount),
            everyElement(lessThanOrEqualTo(20)));
      });
    }

    for (final size in [1, 2, 3]) {
      test('30/$size/30 never leaves a short repair product', () {
        final input = [
          _tokens(30, prefix: 'left').join(' '),
          _tokens(size, prefix: 'short').join(' '),
          _tokens(30, prefix: 'right').join(' '),
        ];
        final actual = _split(input);
        _expectFinalFloorAndFidelity(input, actual);
        // This assertion is only the floor/cap/fidelity contract. Natural
        // safe-cut quality is covered by syntax fixtures, not made-up tokens.
      });
    }
  });

  group('original length-zone solver evidence', () {
    for (final total in [16, 17, 18, 20]) {
      test('protected unpunctuated $total-word span is not forced to split',
          () {
        final source = _tokens(total).join(' ');
        final plan = _syntheticPlan(source, protectAllGaps: true);
        expect(plan.localSentences, [source]);
      });
    }

    for (final total in [21, 30]) {
      test('unpunctuated $total words must split at an available clause', () {
        final source = _tokens(total).join(' ');
        final plan = _syntheticPlan(source, clauseStart: 11);
        final decision = plan.originals.single;
        expect(plan.localSentences.length, greaterThan(1));
        expect(plan.localSentences.map(ReadAloudSplitterV3.wordCount),
            everyElement(inInclusiveRange(4, 20)));
        expect(decision.localPath.usesNonPunctuation, isTrue);
        expect(decision.localPath.stage, isNot(ReadAloudPathStageV3.emergency));
      });
    }
  });

  group('merge before solving: one fact build and one DAG per merged unit', () {
    test('coalesces short input units before either unit is solved', () {
      final plan = _planFor(['Mole looked up.', 'Rat waved back.']);
      expect(plan.originals, hasLength(1));
      expect(plan.counters.sentenceFactBuilds, 1);
      expect(plan.counters.dagSolves, 1);
      expect(plan.localSentences, ['Mole looked up. Rat waved back.']);
    });

    test('coalesces a short chain without repeated split and merge passes', () {
      final plan = _planFor(
          ['Mole looked up.', 'Rat waved back.', 'Toad laughed loudly.']);
      expect(plan.originals, hasLength(1));
      expect(plan.counters.sentenceFactBuilds, 1);
      expect(plan.counters.dagSolves, 1);
      _expectFinalFloorAndFidelity(
        ['Mole looked up.', 'Rat waved back.', 'Toad laughed loudly.'],
        plan.localSentences,
      );
    });

    test('dense short chains close comfortable units before a large DAG grows',
        () {
      final input = List.filled(100, 'Mole looked up.');
      final plan = _planFor(input);
      expect(plan.originals.length, greaterThan(1));
      expect(
          plan.originals.map((unit) => unit.candidateCoverage.sourceWordCount),
          everyElement(inInclusiveRange(4, 16)));
      expect(plan.counters.dagSolves, plan.originals.length);
      expect(plan.counters.sentenceFactBuilds, plan.originals.length);
      _expectFinalFloorAndFidelity(input, plan.localSentences);
    });

    test('local and selected-path exits expose the same final legal chunks',
        () {
      final input = ['Mole looked up.', 'Rat waved back.'];
      final plan = _planFor(input);
      final selected = {
        for (final decision in plan.originals)
          decision.originalIndex: decision.localPathId,
      };
      final result = ReadAloudSplitterV3.applySelectedPathIds(plan, selected);
      expect(result, plan.localSentences);
      _expectFinalFloorAndFidelity(input, result);
      expect(plan.counters.dagSolves, 1);
    });
  });

  group('all exits and paragraph protection', () {
    test('every selectable path and coverage edge meets the minimum', () {
      final source = _tokens(45).join(' ');
      final plan = _planFor([source, 'Come here.']);
      for (final decision in plan.originals) {
        for (final path in decision.candidatePaths) {
          expect(path.wordCounts, everyElement(inInclusiveRange(4, 30)));
          final selected = ReadAloudSplitterV3.applySelectedPathIds(
              plan, {decision.originalIndex: path.pathId});
          _expectFinalFloorAndFidelity([source, 'Come here.'], selected);
        }
        for (final edge in decision.candidateCoverage.reachableSegmentEdges) {
          expect(edge.endWord - edge.startWord, inInclusiveRange(4, 20));
        }
      }
      expect(plan.counters.dagSolves, 1);
    });

    test('short paragraphs merge within the article across line breaks', () {
      for (final separator in ['\n', '\r\n', '\n\n']) {
        final plan = _planFor(['Come here.', 'The children waited outside.'],
            separator: separator);
        expect(
            plan.localSentences, ['Come here. The children waited outside.']);
        expect(plan.counters.dagSolves, 1);
      }
      expect(() => _split(['Come here.']), throwsFormatException);
      // A failed call does not leave shared planner state behind.
      expect(_split(['Come here.', 'The children waited outside.']),
          ['Come here. The children waited outside.']);
    });

    test('compliant paragraph boundaries remain mandatory', () {
      const originals = [
        'The children waited outside.',
        'Their mother opened the gate.'
      ];
      final plan = _planFor(originals, separator: '\n\n');
      expect(plan.localSentences, originals);
      expect(plan.originals, hasLength(2));
      expect(
          () => ReadAloudSplitterV3.validateReviewedSentences(
              originals.join(' '), [originals.join(' ')],
              requiredBoundaryWordOffsets:
                  ReadAloudSplitterV3.requiredBoundaryWordOffsets(plan)),
          throwsFormatException);
    });
  });

  group('production final validation: minimum and absolute cap', () {
    for (final short in ['Wait!', 'Come here.', 'Please come here.']) {
      test('rejects ${ReadAloudSplitterV3.wordCount(short)}-word final chunk',
          () {
        const other = 'The children waited by the gate.';
        expect(
          () => ReadAloudSplitterV3.validateReviewedSentences(
            '$other $short',
            [other, short],
            enforceMinimumWords: true,
          ),
          throwsFormatException,
        );
      });
    }
    test('rejects 31 words even when all words and punctuation round-trip', () {
      final source = _tokens(31).join(' ');
      expect(
        () => ReadAloudSplitterV3.validateReviewedSentences(source, [source]),
        throwsFormatException,
      );
    });
  });
}

void _expectFinalFloorAndFidelity(List<String> input, List<String> actual) {
  expect(actual, isNotEmpty);
  expect(
    ReadAloudSplitterV3.isRoundTripEquivalent(
      englishContent: input.join(' '),
      sentences: actual,
    ),
    isTrue,
    reason: 'R-FIDELITY: preserve source words, punctuation and order',
  );
  expect(actual.map(ReadAloudSplitterV3.wordCount),
      everyElement(inInclusiveRange(4, 30)),
      reason: 'Mandatory minimum and absolute cap; length-zone checks are '
          'additional assertions, not replaced by this interval');
}

List<String> _tokens(int count, {String prefix = 'word'}) =>
    List.generate(count, (index) => '$prefix${index + 1}');

// This adapter invokes the real planner, not the legacy post-merge helper.
// The injected parser boundaries are input units, not mandated final cuts.
List<String> _split(List<String> input) => _planFor(input).localSentences;

// Synthetic UD topology for deterministic rule tests, following existing
// syntax-solver test patterns. It does not claim to be a native parser result.
ReadAloudSplitPlanV3 _syntheticPlan(
  String source, {
  bool protectAllGaps = false,
  int? clauseStart,
}) =>
    _planFor([source],
        protectAllGaps: protectAllGaps, clauseStart: clauseStart);

ReadAloudSplitPlanV3 _planFor(
  List<String> originals, {
  String separator = ' ',
  bool protectAllGaps = false,
  int? clauseStart,
}) {
  final source = originals.join(separator);
  final sentences = <DependencySentenceV3>[];
  var offset = 0;
  for (final original in originals) {
    final matches = RegExp(r'\S+').allMatches(original).toList();
    sentences.add(DependencySentenceV3(
      start: offset,
      end: offset + original.length,
      tokens: [
        for (var i = 0; i < matches.length; i++)
          DependencyTokenV3(
            id: i + 1,
            text: matches[i].group(0)!,
            start: offset + matches[i].start,
            end: offset + matches[i].end,
            upos: 'NOUN',
            head: protectAllGaps && i + 1 < matches.length
                ? i + 2
                : i + 1 == clauseStart
                    ? i
                    : 0,
            deprel: protectAllGaps && i + 1 < matches.length
                ? 'fixed'
                : i + 1 == clauseStart
                    ? 'advcl'
                    : 'root',
          ),
      ],
    ));
    offset += original.length + separator.length;
  }
  return ReadAloudSplitterV3.plan(
    source: source,
    document: DependencyDocumentV3(
      parserVersion: 'synthetic-short-merge-contract',
      modelSha256: 'synthetic-no-model',
      healthy: true,
      sentences: sentences,
    ),
  );
}
