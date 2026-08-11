import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v3.dart';

void main() {
  final fixture = jsonDecode(
    File('test/fixtures/read_aloud_splitter_v3_cases.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final cases =
      (fixture['cases'] as List<dynamic>).cast<Map<String, dynamic>>();

  group('ReadAloudSplitterV3 native validator', () {
    for (final testCase in cases) {
      test('accepts Web fixture ${testCase['id']}', () {
        final input = testCase['input'] as String;
        final expected = (testCase['expected'] as List<dynamic>).cast<String>();
        expect(
          () => ReadAloudSplitterV3.validateReviewedSentences(input, expected),
          returnsNormally,
        );
      });
    }

    test('accepts all 243 fixed Web v3 gold expectations', () {
      final fixedGold = jsonDecode(
        File('test/fixtures/sentence_split_gold_v3.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final items =
          (fixedGold['items'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(items, hasLength(243));
      for (final item in items) {
        final expected =
            (item['expectedChunks'] as List<dynamic>).cast<String>();
        expect(
          () => ReadAloudSplitterV3.validateReviewedSentences(
            item['source'] as String,
            expected,
          ),
          returnsNormally,
          reason: item['id'] as String,
        );
      }
    });

    test('retains every retired Web splitter input in the V3 inventory', () {
      final historical = jsonDecode(
        File('test/fixtures/historical_web_sentence_cases_v3.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      final items =
          (historical['cases'] as List<dynamic>).cast<Map<String, dynamic>>();

      expect(items, hasLength(10));
      for (final item in items) {
        expect((item['source'] as String).trim(), isNotEmpty,
            reason: item['id'] as String);
        expect(item['invariants'], isNotEmpty, reason: item['id'] as String);
      }
    });

    test('enforces word, unpunctuated, round-trip, and original boundaries',
        () {
      final reviewableSpan =
          List.generate(21, (index) => 'word${index + 1}').join(' ');
      expect(
        () => ReadAloudSplitterV3.validateReviewedSentences(
          reviewableSpan,
          [reviewableSpan],
        ),
        returnsNormally,
      );
      final overSpan =
          List.generate(31, (index) => 'word${index + 1}').join(' ');
      expect(
        () =>
            ReadAloudSplitterV3.validateReviewedSentences(overSpan, [overSpan]),
        throwsFormatException,
      );
      expect(
        () => ReadAloudSplitterV3.validateReviewedSentences(
          'Mole looked up. Rat waved back. Toad laughed loudly.',
          ['Mole looked up. Rat waved back.', 'Toad laughed loudly.'],
          requiredBoundaryWordOffsets: const [3, 6, 9],
        ),
        throwsFormatException,
      );
      expect(
        () => ReadAloudSplitterV3.validateReviewedSentences(
          'Mole looked up. Rat waved back. Toad laughed loudly.',
          ['Mole looked up.', 'Rat waved back.', 'Toad laughed loudly.'],
          requiredBoundaryWordOffsets: const [3, 6, 9],
        ),
        returnsNormally,
      );
    });

    test('treats whitespace inserted only at sentence boundaries as equal', () {
      expect(
        ReadAloudSplitterV3.isRoundTripEquivalent(
          englishContent:
              'The Rat cried, "You fellows!—At least—I beg pardon."',
          sentences: const [
            'The Rat cried, "You fellows!',
            '—At least—I beg pardon."',
          ],
        ),
        isTrue,
      );
      expect(
        () => ReadAloudSplitterV3.validateReviewedSentences(
          'The Rat cried, "You fellows!—At least—I beg pardon."',
          const [
            'The Rat cried, "You fellows!',
            '—At least—I beg pardon."',
          ],
        ),
        returnsNormally,
      );
      expect(
        () => ReadAloudSplitterV3.validateReviewedSentences(
          'They answered, \'Mr. Toad.\'" There was more.',
          const [
            "They answered, 'Mr. Toad.'",
            '"',
            'There was more.',
          ],
        ),
        returnsNormally,
      );
    });

    test('still rejects changed text and boundaries inside lexical words', () {
      expect(
        () => ReadAloudSplitterV3.validateReviewedSentences(
          'The Mole waited.',
          const ['The Mole waved.'],
        ),
        throwsFormatException,
      );
      expect(
        () => ReadAloudSplitterV3.validateReviewedSentences(
          'The Mole waited.',
          const ['The Mo', 'le waited.'],
        ),
        throwsFormatException,
      );
      expect(
        () => ReadAloudSplitterV3.validateReviewedSentences(
          "The Mole didn't wait.",
          const ["The Mole didn", "'t wait."],
        ),
        throwsFormatException,
      );
    });

    test('punctuation-only tokens do not consume the English word budget', () {
      expect(ReadAloudSplitterV3.wordCount('"'), 0);
      expect(ReadAloudSplitterV3.wordCount('... — "'), 0);
      expect(ReadAloudSplitterV3.wordCount('Mole said, "Hello!"'), 3);

      const source = 'Mole called, \'Stop!\' " Then Rat turned around.';
      expect(
        () => ReadAloudSplitterV3.validateReviewedSentences(
          source,
          const [
            'Mole called, \'Stop!\' "',
            'Then Rat turned around.',
          ],
          requiredBoundaryWordOffsets: const [3, 7],
        ),
        returnsNormally,
      );
    });

    test('glued em dashes remain punctuation boundaries, not one word', () {
      expect(ReadAloudSplitterV3.wordCount('one—two three'), 3);
      expect(
        ReadAloudSplitterV3.maxUnpunctuatedWordCount('one—two three'),
        2,
      );
      expect(
        ReadAloudSplitterV3.isRoundTripEquivalent(
          englishContent: 'one—two three.',
          sentences: const ['one—', 'two three.'],
        ),
        isTrue,
      );
    });
  });
}
