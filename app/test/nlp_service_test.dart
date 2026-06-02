import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/nlp_service.dart';

void main() {
  int wordCount(String text) =>
      text.split(RegExp(r'\s+')).where((word) => word.trim().isNotEmpty).length;

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

    test('splits long sentences into standard reading chunks', () {
      final chunks = NlpService.splitSentences(
        'Tom walks into the bright library, finds a tiny blue robot beside the big window, and asks it to help him read a funny story before lunch.',
      );

      expect(chunks.length, greaterThan(1));
      expect(chunks.every((chunk) => wordCount(chunk) <= 18), isTrue);
      expect(chunks.every((chunk) => chunk.length <= 106), isTrue);
    });

    test('uses comma and connector boundaries for long read-aloud text', () {
      final chunks = NlpService.splitSentences(
        'The rocket jumps over the moon, then turns around slowly, because Tom wants everyone to see the shiny snack box before the team goes home.',
      );

      expect(chunks.length, greaterThan(1));
      expect(
          chunks.first.endsWith(',') || chunks.first.contains(' then'), isTrue);
      expect(chunks.every((chunk) => wordCount(chunk) <= 18), isTrue);
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
  });
}
