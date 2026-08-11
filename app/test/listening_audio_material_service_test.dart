import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/listening_audio_material_service.dart';

void main() {
  group('ListeningAudioMaterialService historical lookup key', () {
    test('ignores punctuation and whitespace outside English words', () {
      final oldKey = ListeningAudioMaterialService.normalizeCacheTextForTest(
        '  "Ho!   ho!"  ',
      );
      final newKey = ListeningAudioMaterialService.normalizeCacheTextForTest(
        'Ho ho',
      );

      expect(newKey, oldKey);
    });

    test('keeps apostrophes and lexical hyphens inside words', () {
      expect(
        ListeningAudioMaterialService.normalizeCacheTextForTest("we'll"),
        isNot(
          ListeningAudioMaterialService.normalizeCacheTextForTest('well'),
        ),
      );
      expect(
        ListeningAudioMaterialService.normalizeCacheTextForTest('shell-fish'),
        isNot(
          ListeningAudioMaterialService.normalizeCacheTextForTest('shell fish'),
        ),
      );
    });

    test('retains whitespace normalization fallback for non-English text', () {
      expect(
        ListeningAudioMaterialService.normalizeCacheTextForTest('你好   世界'),
        ListeningAudioMaterialService.normalizeCacheTextForTest('你好 世界'),
      );
    });
  });
}
