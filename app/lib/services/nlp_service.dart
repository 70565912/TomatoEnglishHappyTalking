// NLP 服务 — Dart 本地分句处理
// 无需网络请求，直接在本地通过正则处理英文文章分句

class NlpService {
  // Common abbreviations that end with a period (should NOT trigger sentence split)
  static const _abbreviations = {
    'mr', 'mrs', 'ms', 'dr', 'prof', 'sr', 'jr', 'rev',
    'vs', 'etc', 'fig', 'no', 'vol', 'dept', 'approx',
    'jan', 'feb', 'mar', 'apr', 'jun', 'jul', 'aug',
    'sep', 'oct', 'nov', 'dec',
    'u.s', 'u.k', 'e.g', 'i.e', 'a.m', 'p.m', 'st',
  };

  /// Split [text] into English sentences.
  /// Returns a non-empty list; if no boundary found, returns [text] as one sentence.
  static List<String> splitSentences(String text) {
    final cleaned = text.replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim();
    if (cleaned.isEmpty) return [];

    final sentences = <String>[];
    final buffer = StringBuffer();

    for (int i = 0; i < cleaned.length; i++) {
      final ch = cleaned[i];
      buffer.write(ch);

      // Sentence boundary: . ! ? followed by space + uppercase letter or quote
      if ((ch == '.' || ch == '!' || ch == '?') && i + 2 < cleaned.length) {
        final next = cleaned[i + 1];
        final afterNext = cleaned[i + 2];

        if (next == ' ' && RegExp(r'[A-Z"(]').hasMatch(afterNext)) {
          final current = buffer.toString().trim();
          final words = current.split(RegExp(r'\s+'));
          final lastWord =
              words.last.replaceAll(RegExp(r'[.!?]+$'), '').toLowerCase();

          // Skip split if it's an abbreviation or single initial
          if (!_abbreviations.contains(lastWord) && lastWord.length > 1) {
            if (current.isNotEmpty) sentences.add(current);
            buffer.clear();
            i++; // skip the space
          }
        }
      }
    }

    final remaining = buffer.toString().trim();
    if (remaining.isNotEmpty) sentences.add(remaining);

    return sentences.isEmpty ? [cleaned] : sentences;
  }
}
