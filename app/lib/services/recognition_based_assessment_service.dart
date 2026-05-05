import 'dart:math';

import 'scoring_service.dart';
import 'streaming_asr_service.dart';

/// Recognition-based pronunciation assessment engine
/// Uses BigASR for speech recognition, then computes heuristic scoring
/// based on text matching, coverage, and timing (if available).
class RecognitionBasedAssessmentEngine implements SpeechAssessmentEngine {
  @override
  Future<PronunciationResult> assess({
    required List<int> audioBytes,
    required String referenceText,
  }) async {
    final recognizedText = await StreamingAsrService.recognize(
      audioBytes: audioBytes,
    );

    return _computeScores(referenceText, recognizedText);
  }

  @override
  Future<String> recognizeSpeech({required List<int> audioBytes}) async =>
      StreamingAsrService.recognize(audioBytes: audioBytes);

  PronunciationResult _computeScores(String refText, String recognized) {
    final refWords = refText.toLowerCase().split(RegExp(r'\s+'));
    final recWords = recognized.toLowerCase().split(RegExp(r'\s+'));

    // Calculate word-level accuracy using Longest Common Subsequence
    final lcs = _longestCommonSubsequence(refWords, recWords);
    final matchedCount = lcs.length;
    final totalWords = refWords.length;
    final recognizedWords = recWords.length;

    // Accuracy: matched words / total words in reference
    final accuracyScore = totalWords > 0
        ? (matchedCount / totalWords * 100).clamp(0, 100).toDouble()
        : 0.0;

    // Completeness: how much of the reference was covered
    final completenessScore = totalWords > 0
        ? (matchedCount / totalWords * 100).clamp(0, 100).toDouble()
        : 0.0;

    // Fluency: penalty for too short or too long recognition
    // Ideal ratio is 0.8 ~ 1.2 of reference length
    final lengthRatio = totalWords > 0
        ? (recognizedWords.toDouble() / totalWords.toDouble()).clamp(0.3, 1.5)
        : 0.3;
    final fluencyScore = (100 * (1.0 - (lengthRatio - 1.0).abs() * 0.3))
        .clamp(0, 100)
        .toDouble();

    // Prosody: placeholder, set same as fluency
    final prosodyScore = fluencyScore;

    // Overall: average of accuracy, completeness, fluency
    final overallScore =
        (accuracyScore + completenessScore + fluencyScore) / 3.0;

    // Build word scores
    final wordScores = <WordScore>[];
    for (var i = 0; i < refWords.length; i++) {
      final word = refWords[i];
      final isMatched = recWords.contains(word);
      final score = isMatched ? 90.0 : 40.0;
      final errorType = isMatched ? 'None' : 'Omission';

      wordScores.add(WordScore(
        word: word,
        score: score,
        errorType: errorType,
      ));
    }

    return PronunciationResult(
      overallScore: overallScore.clamp(0, 100),
      accuracyScore: accuracyScore,
      fluencyScore: fluencyScore,
      completenessScore: completenessScore,
      prosodyScore: prosodyScore,
      words: wordScores,
      recognizedText: recognized,
      isMock: false,
    );
  }

  /// Compute longest common subsequence using dynamic programming
  List<String> _longestCommonSubsequence(List<String> a, List<String> b) {
    final m = a.length;
    final n = b.length;

    // DP table
    final dp = List<List<int>>.generate(
      m + 1,
      (_) => List<int>.filled(n + 1, 0),
    );

    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        if (a[i - 1] == b[j - 1]) {
          dp[i][j] = dp[i - 1][j - 1] + 1;
        } else {
          dp[i][j] = max(dp[i - 1][j], dp[i][j - 1]);
        }
      }
    }

    // Backtrack to find actual subsequence
    var i = m;
    var j = n;
    final result = <String>[];

    while (i > 0 && j > 0) {
      if (a[i - 1] == b[j - 1]) {
        result.add(a[i - 1]);
        i--;
        j--;
      } else if (dp[i - 1][j] > dp[i][j - 1]) {
        i--;
      } else {
        j--;
      }
    }

    return result.reversed.toList();
  }
}
