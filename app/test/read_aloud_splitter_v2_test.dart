import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v2.dart';

void main() {
  group('ReadAloudSplitterV2 reviewed validation', () {
    test('accepts exact reviewed round-trip and rejects display newlines', () {
      const content =
          'The Mole could hardly sit still. He knew what the row was about.';
      const sentences = [
        'The Mole could hardly sit still.',
        'He knew what the row was about.',
      ];
      expect(
        () => ReadAloudSplitterV2.validateReviewedSentences(content, sentences),
        returnsNormally,
      );
      expect(
        () => ReadAloudSplitterV2.validateReviewedSentences(
          'Chapter 1: The River Bank\n\n$content',
          sentences,
        ),
        returnsNormally,
      );
      expect(
        () => ReadAloudSplitterV2.validateReviewedSentences(
          content,
          const [
            'The Mole could\nhardly sit still.',
            'He knew what the row was about.'
          ],
        ),
        throwsFormatException,
      );
    });

    test('rejects over-30 and non-equivalent text but allows visual wrapping',
        () {
      final over30 = List.filled(31, 'word').join(' ');
      expect(
        () => ReadAloudSplitterV2.validateReviewedSentences(over30, [over30]),
        throwsFormatException,
      );
      final overWidth = List.filled(20, 'WWWWWWWWWW').join(' ');
      expect(
        () => ReadAloudSplitterV2.validateReviewedSentences(
            overWidth, [overWidth]),
        returnsNormally,
      );
      expect(
        () => ReadAloudSplitterV2.validateReviewedSentences(
          'Mole walks home.',
          const ['Mole walks away.'],
        ),
        throwsFormatException,
      );
    });
  });

  test('native fallback uses global DP and the 30-word constraint', () {
    final chunks = ReadAloudSplitterV2.splitSentences(
      'The Mole understood what the row was about, and he could hardly sit still while the only idle dog watched from the doorway.',
    );
    expect(chunks, isNotEmpty);
    expect(chunks.every((chunk) => ReadAloudSplitterV2.wordCount(chunk) <= 30),
        isTrue);
    expect(chunks.join('\n'), isNot(contains('what the row\nwas about')));
    expect(chunks.join('\n'), isNot(contains('could hardly\nsit')));
  });

  test(
      'native fallback avoids connective tails and lowercase interjection cuts',
      () {
    final relative = ReadAloudSplitterV2.splitSentences(
      'Something up above was calling him imperiously, and he made for the steep little tunnel which answered in his case to the gravelled carriage-drive owned by animals whose residences are nearer to the sun and air.',
    );
    expect(relative, isNot(contains('and air.')));

    final interjection = ReadAloudSplitterV2.splitSentences(
      '"Up we go! Up we go!" till at last, pop! his snout came out into the sunlight and he found himself rolling in the warm grass of a great meadow.',
    );
    expect(interjection.join('\n'), isNot(contains('pop!\nhis snout')));
  });

  test('native fallback merges short quoted dialogue continuations', () {
    final chunks = ReadAloudSplitterV2.splitSentences(
      'It was small wonder, then, that he suddenly flung down his brush on the floor, said, "Bother!" and "O blow!" and also "Hang spring-cleaning!" and bolted out of the house without even waiting to put on his coat.',
    );
    expect(
      chunks.any((chunk) => chunk.contains(
          '"Bother!" and "O blow!" and also "Hang spring-cleaning!"')),
      isTrue,
    );
    expect(chunks, isNot(contains('"Bother!"')));
  });

  test('native fallback merges comma-ended fragments and short lists', () {
    final description = ReadAloudSplitterV2.splitSentences(
      'He led the way to the stable-yard accordingly, the Rat following with a most mistrustful expression; and there, drawn out of the coach-house into the open, they saw a gipsy caravan, shining with newness, painted a canary-yellow picked out with green, and red wheels.',
    );
    expect(
      description,
      contains(
        'they saw a gipsy caravan, shining with newness, painted a canary-yellow picked out with green, and red wheels.',
      ),
    );
    expect(
      ReadAloudSplitterV2.splitSentences('Camps, villages, towns, cities!'),
      ['Camps, villages, towns, cities!'],
    );
  });

  test('native fallback merges complete short sentences toward 15 words', () {
    const source = 'Mole looked up. Rat waved back. Toad laughed loudly.';
    expect(ReadAloudSplitterV2.splitSentences(source), [source]);
  });

  test('native fallback tolerates 22 words and splits 23 at punctuation', () {
    const comfortable =
        'Mole cleaned the dusty room and packed every brush neatly away. Rat opened the round window and called him toward the sunshine.';
    expect(ReadAloudSplitterV2.wordCount(comfortable), 22);
    expect(ReadAloudSplitterV2.splitSentences(comfortable), [comfortable]);

    const excessive =
        'Mole cleaned the dusty room and packed every brush neatly away. Rat opened the round window and called him into the sunshine outside.';
    expect(ReadAloudSplitterV2.wordCount(excessive), 23);
    expect(
      ReadAloudSplitterV2.splitSentences(excessive),
      [
        'Mole cleaned the dusty room and packed every brush neatly away.',
        'Rat opened the round window and called him into the sunshine outside.',
      ],
    );
  });

  test('article map defaults old rows to legacy and persists explicit v2', () {
    final old = Article.fromMap({
      'id': 1,
      'title': 'Old',
      'content': 'Old article.',
      'sentences': '["Old article."]',
      'created_at': '2026-08-01T00:00:00.000Z',
    });
    expect(old.sentenceSplitVersion, Article.legacySentenceSplitVersion);

    final v2 = old.copyWith(sentenceSplitVersion: ReadAloudSplitterV2.version);
    expect(v2.toMap()['sentence_split_version'], ReadAloudSplitterV2.version);
  });
}
