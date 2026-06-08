import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/nlp_service.dart';

void main() {
  group('NlpService.splitSentences', () {
    test('returns empty list for empty text', () {
      expect(NlpService.splitSentences('   \n\t  '), isEmpty);
    });

    test('keeps ordinary short sentences', () {
      expect(
        NlpService.splitSentences(
          'Tom finds a bright snack box. He shares it with his team.',
        ),
        [
          'Tom finds a bright snack box.',
          'He shares it with his team.',
        ],
      );
    });

    test('splits long natural sentences into read-aloud chunks', () {
      final chunks = NlpService.splitSentences(
        'Tom walks into the bright library, finds a tiny blue robot beside the big window, and asks it to help him read a funny story before lunch.',
      );

      expect(chunks.length, greaterThan(1));
      expect(chunks.every((chunk) => chunk.split(RegExp(r'\s+')).length <= 22),
          isTrue);
    });

    test('splits long sentences at safe commas and connectors', () {
      final chunks = NlpService.splitSentences(
        'The rocket jumps over the moon, then turns around slowly, because Tom wants everyone to see the shiny snack box before the team goes home.',
      );

      expect(chunks, [
        'The rocket jumps over the moon,',
        'then turns around slowly, because Tom wants everyone to see the shiny snack box before the team goes home.',
      ]);
    });

    test('keeps hyphenated words joined for read-aloud text', () {
      final chunks = NlpService.splitSentences(
        'The well - known mother - in - law smiles at the child.',
      );
      final joined = chunks.join(' ');

      expect(joined, contains('well-known'));
      expect(joined, contains('mother-in-law'));
      expect(joined, isNot(contains('well - known')));
    });

    test('does not split common abbreviations into standalone chunks', () {
      final chunks = NlpService.splitSentences(
        'Dr. Smith met Tom after school. They read a book together.',
      );

      expect(chunks, isNot(contains('Dr.')));
      expect(chunks.first, startsWith('Dr. Smith'));
      expect(chunks.length, 2);
    });

    test('skips imported episode headings before read-aloud text', () {
      final chunks = NlpService.splitSentences(
        'E25\n\n'
        '爱丽丝梦游仙境（原著领读版）- E61\n\n'
        'Alice\'s Adventures in Wonderland - Episod 61\n'
        '"They were learning to draw," the Dormouse went on, '
        'yawning and rubbing its eyes, for it was getting very sleepy.',
      );

      expect(chunks.first, startsWith('"They were learning to draw,"'));
      expect(chunks.join(' '), isNot(contains('爱丽丝')));
      expect(chunks.join(' '), isNot(contains('E25')));
      expect(chunks.join(' '), isNot(contains('Episod 61')));
    });

    test('removes repeated imported headings inside long pasted text', () {
      final chunks = NlpService.splitSentences(
        'Alice was silent.\n\n'
        '爱丽丝梦游仙境（原著领读版）- E62\n\n'
        'Alice\'s Adventures in Wonderland - Episod 62\n\n'
        'Chapter Eight\n'
        'The Queen\'s Croquet - Ground\n\n'
        'A large rose-tree stood near the entrance of the garden.',
      );

      expect(chunks, contains('Alice was silent.'));
      expect(chunks.last, startsWith('A large rose-tree stood'));
      expect(chunks.join(' '), isNot(contains('Croquet - Ground')));
      expect(chunks.join(' '), isNot(contains('Episod 62')));
    });

    test('splits Alice Mad Tea-Party natural sentences into phrase chunks', () {
      final chunks = NlpService.splitSentences(
        'A Mad Tea-Party\n'
        'There was a table set out under a tree in front of the house, '
        'and the March Hare and the Hatter were having tea at it: '
        'a Dormouse was sitting between them, fast asleep, and '
        'the other two were using it as a cushion, resting their elbows on it, '
        'and talking over its head.\n'
        '"Very uncomfortable for the Dormouse," thought Alice: '
        '"only as it\'s asleep, I suppose it doesn\'t mind."\n'
        'The table was a large one, but the three were all crowded together at '
        'one corner of it: "No room! No room!" they cried out when they saw '
        'Alice coming.',
      );

      expect(chunks, [
        'There was a table set out under a tree in front of the house,',
        'and the March Hare and the Hatter were having tea at it:',
        'a Dormouse was sitting between them, fast asleep,',
        'and the other two were using it as a cushion,',
        'resting their elbows on it,',
        'and talking over its head.',
        '"Very uncomfortable for the Dormouse," thought Alice:',
        '"only as it\'s asleep, I suppose it doesn\'t mind."',
        'The table was a large one,',
        'but the three were all crowded together at one corner of it:',
        '"No room! No room!" they cried out when they saw Alice coming.',
      ]);
      expect(chunks.join(' '), isNot(contains('A Mad Tea-Party')));
    });

    test('splits direct speech when a quote follows a phrase without colon',
        () {
      final chunks = NlpService.splitSentences(
        'The table was a large one, but the three were all crowded together at '
        'one corner of it "No room! No room!" they cried out when they saw '
        'Alice coming.',
      );

      expect(chunks, [
        'The table was a large one,',
        'but the three were all crowded together at one corner of it',
        '"No room! No room!" they cried out when they saw Alice coming.',
      ]);
    });

    test('keeps direct command together after an em dash', () {
      final chunks = NlpService.splitSentences(
        '"The Queen will hear you! You see she came rather late, and the Queen said—" '
        '"Get to your places!" shouted the Queen in a voice of thunder, and people began running about in all directions.',
      );

      expect(chunks, isNot(contains('"Get')));
      expect(
        chunks,
        contains(
          '"Get to your places!" shouted the Queen in a voice of thunder,',
        ),
      );
    });
  });
}
