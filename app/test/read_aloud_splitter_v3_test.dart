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

  group('V3.7 one-word post-merge', () {
    test('merges Willows E21 Home! into the previous chunk', () {
      const prev =
          'A moment, and he had caught it again; and with it this time came recollection in fullest flood.';
      const home = 'Home!';
      const next =
          'That was what they meant, those caressing appeals, those soft touches wafted through the air,';
      final merged = ReadAloudSplitterV3.mergeOneWordChunks(const [
        prev,
        home,
        next,
      ]);
      expect(merged, isNot(contains(home)));
      expect(merged.any((chunk) => chunk.endsWith('flood. Home!')), isTrue);
      expect(
        merged.where((chunk) => ReadAloudSplitterV3.wordCount(chunk) == 1),
        isEmpty,
      );
    });

    test('merges Willows E46 Free! into the previous chunk', () {
      const prev = 'first and best thing of all, that he was free!';
      const free = 'Free!';
      const next = 'The word and the thought alone were worth fifty blankets.';
      final merged = ReadAloudSplitterV3.mergeOneWordChunks(const [
        prev,
        free,
        next,
      ]);
      expect(merged, isNot(contains(free)));
      expect(merged.any((chunk) => chunk.contains('free! Free!')), isTrue);
      expect(
        merged.where((chunk) => ReadAloudSplitterV3.wordCount(chunk) == 1),
        isEmpty,
      );
    });

    test('merges Willows E50 No. into the previous chunk', () {
      const prev = 'Or Kitchener?';
      const no = 'No.';
      const next = 'It was Mr. Toad.';
      final merged = ReadAloudSplitterV3.mergeOneWordChunks(const [
        prev,
        no,
        next,
      ]);
      expect(
          merged,
          equals(const [
            'Or Kitchener? No.',
            'It was Mr. Toad.',
          ]));
    });

    test('leading one-word chunk merges into the next chunk', () {
      expect(
        ReadAloudSplitterV3.mergeOneWordChunks(const [
          'Home!',
          'That was the place.',
        ]),
        equals(const ['Home! That was the place.']),
      );
    });

    test('consecutive one-word chunks are resolved in the same local window',
        () {
      expect(
        ReadAloudSplitterV3.mergeOneWordChunks(const [
          'Home!',
          'No.',
          'Stop.',
          'The story continues here.',
        ]),
        equals(const [
          'Home! No. Stop.',
          'The story continues here.',
        ]),
      );
    });

    test('30-word previous plus Home! merges into the next neighbor', () {
      final long = '${List.generate(30, (i) => 'w$i').join(' ')}.';
      expect(ReadAloudSplitterV3.wordCount(long), 30);
      final merged = ReadAloudSplitterV3.mergeOneWordChunks([
        long,
        'Home!',
        'Next sentence continues here.',
      ]);
      expect(
        merged.where((chunk) => ReadAloudSplitterV3.wordCount(chunk) == 1),
        isEmpty,
      );
      expect(merged, isNot(contains('Home!')));
      expect(
        merged.any((chunk) => chunk.startsWith('Home! Next')),
        isTrue,
      );
      expect(merged.first, long);
    });

    test('window re-split absorbs trailing Home! when there is no next chunk',
        () {
      final long = List.generate(30, (i) => 'w$i').join(' ');
      expect(ReadAloudSplitterV3.wordCount(long), 30);
      final merged = ReadAloudSplitterV3.mergeOneWordChunks([
        long,
        'Home!',
      ]);
      expect(
        merged.where((chunk) => ReadAloudSplitterV3.wordCount(chunk) == 1),
        isEmpty,
      );
      expect(merged, isNot(contains('Home!')));
      expect(
        merged.every(
          (chunk) =>
              ReadAloudSplitterV3.wordCount(chunk) <=
              ReadAloudSplitterV3.hardMaxWords,
        ),
        isTrue,
      );
      expect(
        merged.map(ReadAloudSplitterV3.wordCount),
        const [29, 2],
      );
      expect(merged.last, endsWith('Home!'));
    });

    test('tight both-side window keeps no singleton under hard max', () {
      final left = List.generate(30, (i) => 'L$i').join(' ');
      final right = List.generate(30, (i) => 'R$i').join(' ');
      final merged = ReadAloudSplitterV3.mergeOneWordChunks([
        left,
        'No.',
        right,
      ]);
      expect(
        merged.where((chunk) => ReadAloudSplitterV3.wordCount(chunk) == 1),
        isEmpty,
      );
      expect(
        merged.every(
          (chunk) =>
              ReadAloudSplitterV3.wordCount(chunk) <=
              ReadAloudSplitterV3.hardMaxWords,
        ),
        isTrue,
      );
      expect(
        merged.map(ReadAloudSplitterV3.wordCount),
        const [29, 2, 30],
      );
    });

    test('final validation rejects an unmerged singleton in release code', () {
      expect(
        () => ReadAloudSplitterV3.validateReviewedSentences(
          'Before this. Home!',
          const ['Before this.', 'Home!'],
          rejectOneWordChunks: true,
        ),
        throwsFormatException,
      );
    });
  });
}
