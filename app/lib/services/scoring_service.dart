// 发音评分服务 — 已迁移到 RecognitionBasedAssessmentEngine
// 本文件保留基础数据结构供测试使用

class WordScore {
  final String word;
  final double score;
  final String errorType; // None / Mispronunciation / Omission / Insertion
  const WordScore(
      {required this.word, required this.score, required this.errorType});
}

class PronunciationResult {
  final double overallScore;
  final double accuracyScore;
  final double fluencyScore;
  final double completenessScore;
  final double prosodyScore;
  final List<WordScore> words;
  final String recognizedText;
  final bool isMock;

  const PronunciationResult({
    required this.overallScore,
    required this.accuracyScore,
    required this.fluencyScore,
    required this.completenessScore,
    required this.prosodyScore,
    required this.words,
    required this.recognizedText,
    this.isMock = false,
  });
}

PronunciationResult buildMockPronunciationResult(String text) {
  final words = text
      .split(' ')
      .map((w) => WordScore(
            word: w,
            score: 75.0,
            errorType: 'None',
          ))
      .toList();

  return PronunciationResult(
    overallScore: 75,
    accuracyScore: 78,
    fluencyScore: 72,
    completenessScore: 80,
    prosodyScore: 70,
    words: words,
    recognizedText: text,
    isMock: true,
  );
}

abstract class SpeechAssessmentEngine {
  Future<PronunciationResult> assess({
    required List<int> audioBytes,
    required String referenceText,
  });

  Future<String> recognizeSpeech({
    required List<int> audioBytes,
  });
}

class ScoringService {
  /// Deprecated: Follow Read now uses RecognitionBasedAssessmentEngine.
  /// This class is kept for compatibility and testing purposes only.
  static void setEngine(SpeechAssessmentEngine engine) {
    // No-op for backward compatibility
  }

  /// Mock result for testing
  static Future<PronunciationResult> assess({
    required List<int> audioBytes,
    required String referenceText,
  }) async =>
      buildMockPronunciationResult(referenceText);

  /// Mock recognition for testing
  static Future<String> recognizeSpeech({
    required List<int> audioBytes,
  }) async =>
      '';
}
