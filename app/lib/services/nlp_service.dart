import 'read_aloud_splitter_v2.dart';

/// Legacy offline entry for old persisted content and callers that have no V3
/// dependency document. It must never be labelled as V3; new article creation
/// runs the canonical native Dart V3 service and only exposes its result to the
/// Web UI through the typed bridge.
class NlpService {
  static List<String> splitSentences(String text) {
    // V2 also normalizes imported headings and word joiners, but it used to
    // merge neighbouring short sentences. Reconstruct the normalized stream,
    // lock typographic sentence terminals, then let V2 operate only inside an
    // individual original sentence. No semantic cut vocabulary is maintained
    // here; canonical V3 generation remains in ArticleSegmentationServiceV3.
    final normalized =
        ReadAloudSplitterV2.splitSentences(text).join(' ').trim();
    if (normalized.isEmpty) return const [];
    return _splitOrthographicUnits(normalized)
        .expand(_splitInsideOriginalSentence)
        .toList(growable: false);
  }

  static List<String> _splitOrthographicUnits(String text) {
    final output = <String>[];
    var start = 0;
    for (var index = 0; index < text.length; index += 1) {
      final character = text[index];
      if ((character == '—' || character == '–') &&
          _startsQuotedBlock(text.substring(start, index).trimLeft())) {
        var quoteEnd = index + 1;
        while (quoteEnd < text.length && _isClosingDelimiter(text[quoteEnd])) {
          quoteEnd += 1;
        }
        var nextBlock = quoteEnd;
        while (nextBlock < text.length && _isWhitespace(text[nextBlock])) {
          nextBlock += 1;
        }
        if (nextBlock < text.length && '"“'.contains(text[nextBlock])) {
          _addUnit(output, text.substring(start, quoteEnd));
          start = nextBlock;
          index = nextBlock - 1;
          continue;
        }
      }
      if (character != '.' && character != '?' && character != '!') continue;
      if (character == '.' &&
          index > 0 &&
          index + 1 < text.length &&
          _isDigit(text[index - 1]) &&
          _isDigit(text[index + 1])) {
        continue;
      }

      var end = index + 1;
      while (end < text.length && _isClosingDelimiter(text[end])) {
        end += 1;
      }
      var next = end;
      while (next < text.length && _isWhitespace(text[next])) {
        next += 1;
      }
      if (next >= text.length) {
        _addUnit(output, text.substring(start));
        start = text.length;
        break;
      }

      // Structural abbreviation/initial guard: a one- or two-letter token
      // before a period followed by a capitalized token is not a sentence end.
      // This is deliberately generic, not a growing abbreviation word list.
      if (character == '.' &&
          _precedingAsciiTokenLength(text, index) <= 2 &&
          _precedingAsciiTokenStartsUpper(text, index) &&
          _isAsciiUpper(text[next])) {
        continue;
      }

      final consumedClosingDelimiter = end > index + 1;
      if (consumedClosingDelimiter && _isAsciiLower(text[next])) {
        // Lowercase quote attribution: `"Wait." she said`.
        continue;
      }
      if (!_canStartSentence(text[next])) continue;
      _addUnit(output, text.substring(start, end));
      start = next;
      index = next - 1;
    }
    if (start < text.length) _addUnit(output, text.substring(start));
    return output;
  }

  static void _addUnit(List<String> output, String value) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) output.add(trimmed);
  }

  static int _precedingAsciiTokenLength(String text, int periodIndex) {
    var cursor = periodIndex - 1;
    var length = 0;
    while (cursor >= 0 && _isAsciiLetter(text[cursor])) {
      length += 1;
      cursor -= 1;
    }
    return length;
  }

  static bool _precedingAsciiTokenStartsUpper(String text, int periodIndex) {
    var cursor = periodIndex - 1;
    while (cursor >= 0 && _isAsciiLetter(text[cursor])) {
      cursor -= 1;
    }
    final start = cursor + 1;
    return start < periodIndex && _isAsciiUpper(text[start]);
  }

  static List<String> _splitInsideOriginalSentence(String sentence) {
    final normalized = sentence.trim();
    if (normalized.isEmpty) return const [];
    // Avoid a legacy heading-detector edge case on tiny quoted sentences.
    if (normalized.split(RegExp(r'\s+')).length <= 2) return [normalized];
    final chunks = ReadAloudSplitterV2.splitSentences(normalized);
    final output = <String>[];
    for (final raw in chunks) {
      final chunk = raw.trim();
      if (chunk.isEmpty) continue;
      if (output.isNotEmpty &&
          RegExp(r'''[—–]["'”’]\s*$''').hasMatch(output.last) &&
          !RegExp(r'''^["“]''').hasMatch(output.last) &&
          RegExp(r'''^["'“‘]''').hasMatch(chunk)) {
        output[output.length - 1] = '${output.last} $chunk';
      } else {
        output.add(chunk);
      }
    }
    return output;
  }

  static bool _isClosingDelimiter(String value) => '"\'”’)}]'.contains(value);

  static bool _startsQuotedBlock(String value) =>
      value.isNotEmpty && '"“'.contains(value[0]);

  static bool _canStartSentence(String value) =>
      _isAsciiUpper(value) || '"\'“‘(['.contains(value);

  static bool _isAsciiLetter(String value) =>
      _isAsciiUpper(value) || _isAsciiLower(value);

  static bool _isAsciiUpper(String value) =>
      value.codeUnitAt(0) >= 65 && value.codeUnitAt(0) <= 90;

  static bool _isAsciiLower(String value) =>
      value.codeUnitAt(0) >= 97 && value.codeUnitAt(0) <= 122;

  static bool _isDigit(String value) =>
      value.codeUnitAt(0) >= 48 && value.codeUnitAt(0) <= 57;

  static bool _isWhitespace(String value) => RegExp(r'\s').hasMatch(value);
}
