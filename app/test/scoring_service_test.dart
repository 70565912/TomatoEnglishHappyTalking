import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/scoring_service.dart';

void main() {
  group('ScoringService (deprecated stub)', () {
    test('assess returns mock result', () async {
      final result = await ScoringService.assess(
        audioBytes: const <int>[1, 2, 3],
        referenceText: 'hello world',
      );

      expect(result.isMock, isTrue);
      expect(result.overallScore, 75);
      expect(result.words, isNotEmpty);
      expect(result.words.first.word, 'hello');
    });

    test('recognizeSpeech returns empty string', () async {
      final text = await ScoringService.recognizeSpeech(
        audioBytes: const <int>[1, 2, 3],
      );

      expect(text, isEmpty);
    });

    test('setEngine is backward-compatible no-op', () async {
      // Should not throw when called
      ScoringService.setEngine(_DummyEngine());

      // Still returns mock result
      final result = await ScoringService.assess(
        audioBytes: const <int>[1, 2, 3],
        referenceText: 'test',
      );

      expect(result.isMock, isTrue);
    });
  });
}

class _DummyEngine implements SpeechAssessmentEngine {
  @override
  Future<PronunciationResult> assess({
    required List<int> audioBytes,
    required String referenceText,
  }) async =>
      throw UnimplementedError();

  @override
  Future<String> recognizeSpeech({required List<int> audioBytes}) async =>
      throw UnimplementedError();
}
