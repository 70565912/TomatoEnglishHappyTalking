import 'dart:math' as math;

// NLP 服务 — Dart 本地分句处理
// 无需网络请求，直接在本地通过正则处理英文文章朗读块

class NlpService {
  static const _targetMinWords = 8;
  static const _targetMaxWords = 14;
  static const _hardMaxWords = 16;
  static const _hardMaxChars = 90;
  static const _minTailWords = 4;

  // Common abbreviations that end with a period (should NOT trigger sentence split)
  static const _abbreviations = {
    'mr',
    'mrs',
    'ms',
    'dr',
    'prof',
    'sr',
    'jr',
    'rev',
    'vs',
    'etc',
    'fig',
    'no',
    'vol',
    'dept',
    'approx',
    'jan',
    'feb',
    'mar',
    'apr',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
    'u.s',
    'u.k',
    'e.g',
    'i.e',
    'a.m',
    'p.m',
    'st',
  };

  /// Split [text] into short read-aloud chunks.
  ///
  /// The splitter keeps natural sentence boundaries first, then breaks long
  /// sentences into standard follow-reading chunks of roughly 8-14 words.
  static List<String> splitSentences(String text) {
    final cleaned = _normalizeArticleText(text);
    if (cleaned.isEmpty) return [];

    final chunks = <String>[];
    for (final sentence in _splitSentenceCandidates(cleaned)) {
      chunks.addAll(_splitReadingChunks(sentence));
    }

    return chunks.where((chunk) => chunk.trim().isNotEmpty).toList();
  }

  static String _normalizeArticleText(String text) {
    final lines = text.split(RegExp(r'\r?\n'));
    final keptLines = <String>[];

    for (final rawLine in lines) {
      var line = rawLine.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
      if (line.isEmpty || _isImportedHeadingLine(line)) {
        continue;
      }
      line = _stripCjkPrefix(line);
      if (line.isNotEmpty && !_isImportedHeadingLine(line)) {
        keptLines.add(line);
      }
    }

    final normalized =
        keptLines.join(' ').replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim();
    return normalized;
  }

  static bool _isImportedHeadingLine(String line) {
    final normalized = line.trim();
    if (normalized.isEmpty) {
      return true;
    }
    if (RegExp(r'^(?:E|EP|Episode)\s*\d+$', caseSensitive: false)
        .hasMatch(normalized)) {
      return true;
    }

    final hasLatin = RegExp(r'[A-Za-z]').hasMatch(normalized);
    final hasCjk = RegExp(r'[\u3400-\u9FFF]').hasMatch(normalized);
    if (hasCjk && !hasLatin) {
      return true;
    }

    final words = _wordCount(normalized);
    final isSentenceLike = RegExp(r'[.!?。！？"”]$').hasMatch(normalized);
    final hasEpisodeMarker =
        RegExp(r'\bEpisod(?:e)?\s*\d+\b', caseSensitive: false)
            .hasMatch(normalized);
    if (hasEpisodeMarker && !isSentenceLike) {
      return true;
    }
    if (hasCjk && hasEpisodeMarker) {
      return true;
    }

    final isChapterHeading =
        RegExp(r'\bChapter\b', caseSensitive: false).hasMatch(normalized) &&
            words <= 8 &&
            !isSentenceLike;
    if (isChapterHeading) {
      return true;
    }

    final looksLikeTitle =
        words <= 7 && !isSentenceLike && RegExp(r'\s-\s').hasMatch(normalized);
    if (looksLikeTitle) {
      return true;
    }

    return false;
  }

  static String _stripCjkPrefix(String line) {
    if (!RegExp(r'[\u3400-\u9FFF]').hasMatch(line) ||
        !RegExp(r'[A-Za-z]').hasMatch(line)) {
      return line;
    }

    final latinMatch = RegExp(r'[A-Za-z]').firstMatch(line);
    if (latinMatch == null) {
      return '';
    }
    return line.substring(latinMatch.start).trimLeft();
  }

  static List<String> _splitSentenceCandidates(String cleaned) {
    final candidates = <String>[];
    final buffer = StringBuffer();

    for (int i = 0; i < cleaned.length; i++) {
      final ch = cleaned[i];
      buffer.write(ch);

      if (!_isSentenceEnd(ch)) {
        continue;
      }
      if (ch == '.' && _isDecimalPoint(cleaned, i)) {
        continue;
      }

      final current = buffer.toString().trim();
      if (ch == '.' && _isProtectedPeriod(current)) {
        continue;
      }

      var lookahead = i + 1;
      while (lookahead < cleaned.length &&
          _isClosingPunctuation(cleaned[lookahead])) {
        buffer.write(cleaned[lookahead]);
        i = lookahead;
        lookahead++;
      }

      if (lookahead >= cleaned.length || _isWhitespace(cleaned[lookahead])) {
        final sentence = buffer.toString().trim();
        if (sentence.isNotEmpty) {
          candidates.add(sentence);
        }
        buffer.clear();

        while (
            lookahead < cleaned.length && _isWhitespace(cleaned[lookahead])) {
          i = lookahead;
          lookahead++;
        }
      }
    }

    final remaining = buffer.toString().trim();
    if (remaining.isNotEmpty) candidates.add(remaining);

    return candidates.isEmpty ? [cleaned] : candidates;
  }

  static List<String> _splitReadingChunks(String sentence) {
    final tokens = sentence
        .split(RegExp(r'\s+'))
        .map((token) => token.trim())
        .where((token) => token.isNotEmpty)
        .toList(growable: false);

    if (tokens.isEmpty) {
      return [];
    }
    if (_isReadableLength(tokens, sentence)) {
      return [sentence.trim()];
    }

    final chunks = <String>[];
    var start = 0;
    while (start < tokens.length) {
      final end = _chooseChunkEnd(tokens, start);
      chunks.add(tokens.sublist(start, end).join(' ').trim());
      start = end;
    }

    return _mergeTinyChunks(chunks);
  }

  static int _chooseChunkEnd(List<String> tokens, int start) {
    final remaining = tokens.length - start;
    final remainingText = tokens.sublist(start).join(' ');
    if (remaining <= _hardMaxWords && remainingText.length <= _hardMaxChars) {
      return tokens.length;
    }

    final hardEnd = math.min(start + _hardMaxWords, tokens.length);
    final minEnd = math.min(start + _targetMinWords, tokens.length);

    for (var end = hardEnd; end > minEnd; end--) {
      if (_chunkText(tokens, start, end).length > _hardMaxChars) {
        continue;
      }
      if (_isClauseBreak(tokens[end - 1])) {
        return _avoidTinyTail(tokens, start, end);
      }
    }

    for (var end = math.min(start + _targetMaxWords, tokens.length);
        end > minEnd;
        end--) {
      if (_chunkText(tokens, start, end).length > _hardMaxChars) {
        continue;
      }
      if (end < tokens.length && _isConnector(tokens[end])) {
        return _avoidTinyTail(tokens, start, end);
      }
      if (_isConnector(tokens[end - 1]) && end - start > _targetMinWords) {
        return _avoidTinyTail(tokens, start, end);
      }
    }

    var end = math.min(start + _targetMaxWords, tokens.length);
    while (
        end > minEnd && _chunkText(tokens, start, end).length > _hardMaxChars) {
      end--;
    }
    if (end <= start) {
      return math.min(start + _hardMaxWords, tokens.length);
    }
    return _avoidTinyTail(tokens, start, end);
  }

  static int _avoidTinyTail(List<String> tokens, int start, int end) {
    final tailWords = tokens.length - end;
    if (tailWords == 0 || tailWords >= _minTailWords) {
      return end;
    }

    final expandedText = _chunkText(tokens, start, tokens.length);
    if (tokens.length - start <= _hardMaxWords + 2 &&
        expandedText.length <= _hardMaxChars + 16) {
      return tokens.length;
    }

    final shortened =
        math.max(start + _targetMinWords, end - (_minTailWords - tailWords));
    return shortened > start ? shortened : end;
  }

  static List<String> _mergeTinyChunks(List<String> chunks) {
    final merged = <String>[];
    for (final chunk in chunks) {
      if (merged.isNotEmpty && _wordCount(chunk) < _minTailWords) {
        final previous = merged.removeLast();
        final joined = '$previous $chunk'.trim();
        if (_wordCount(joined) <= _hardMaxWords + 2 &&
            joined.length <= _hardMaxChars + 16) {
          merged.add(joined);
          continue;
        }
        merged
          ..add(previous)
          ..add(chunk);
        continue;
      }
      merged.add(chunk);
    }
    return merged;
  }

  static bool _isReadableLength(List<String> tokens, String text) =>
      tokens.length <= _hardMaxWords && text.length <= _hardMaxChars;

  static String _chunkText(List<String> tokens, int start, int end) =>
      tokens.sublist(start, end).join(' ');

  static int _wordCount(String text) => text
      .split(RegExp(r'\s+'))
      .where((token) => token.trim().isNotEmpty)
      .length;

  static bool _isSentenceEnd(String ch) =>
      ch == '.' ||
      ch == '!' ||
      ch == '?' ||
      ch == '。' ||
      ch == '！' ||
      ch == '？';

  static bool _isWhitespace(String ch) => RegExp(r'\s').hasMatch(ch);

  static bool _isClosingPunctuation(String ch) => '\'"”’)]}》'.contains(ch);

  static bool _isDecimalPoint(String text, int index) {
    if (index == 0 || index + 1 >= text.length) {
      return false;
    }
    return RegExp(r'\d').hasMatch(text[index - 1]) &&
        RegExp(r'\d').hasMatch(text[index + 1]);
  }

  static bool _isProtectedPeriod(String current) {
    final words = current.split(RegExp(r'\s+'));
    if (words.isEmpty) {
      return false;
    }

    final lastWord =
        words.last.replaceAll(RegExp(r'[.!?。！？"”’)\]}》]+$'), '').toLowerCase();

    return _abbreviations.contains(lastWord) ||
        RegExp(r'^[a-z]$').hasMatch(lastWord);
  }

  static bool _isClauseBreak(String token) =>
      RegExp(r'[,;:，；：]$').hasMatch(token) ||
      token.endsWith('—') ||
      token.endsWith('–');

  static bool _isConnector(String token) {
    final normalized =
        token.replaceAll(RegExp(r'^[^A-Za-z]+|[^A-Za-z]+$'), '').toLowerCase();
    return {
      'and',
      'but',
      'or',
      'so',
      'then',
      'because',
      'when',
      'while',
      'after',
      'before',
      'if',
      'that',
      'which',
      'who',
      'where',
    }.contains(normalized);
  }
}
