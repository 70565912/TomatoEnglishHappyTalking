import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/tts_service.dart';

void main() {
  group('TtsService text candidates', () {
    test('adds readable English fallback for imported mixed heading text', () {
      final candidates = TtsService.synthesisTextCandidatesForTest(
        'E25 爱丽丝梦游仙境（原著领读版）- E61 '
        'Alice\'s Adventures in Wonderland - Episod 61 '
        '"They were learning',
      );

      expect(candidates.length, 2);
      expect(candidates.first, contains('爱丽丝'));
      expect(candidates.last, '"They were learning');
      expect(candidates.last, isNot(contains('E25')));
      expect(candidates.last, isNot(contains('爱丽丝')));
    });

    test('keeps ordinary English text unchanged', () {
      final candidates = TtsService.synthesisTextCandidatesForTest(
        'Tom finds a bright snack box.',
      );

      expect(candidates, ['Tom finds a bright snack box.']);
    });

    test('keeps hyphenated words joined before synthesis', () {
      final candidates = TtsService.synthesisTextCandidatesForTest(
        'A well - known mother - in - law arrives.',
      );

      expect(candidates, ['A well-known mother-in-law arrives.']);
    });
  });
}
