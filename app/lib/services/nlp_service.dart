// NLP 服务 — Dart 本地分句处理
// 无需网络请求，直接在本地通过正则处理英文文章朗读块

class NlpService {
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

  static const _targetPhraseMinWords = 8;
  static const _targetPhraseMaxWords = 16;
  static const _hardPhraseMaxWords = 22;
  static const _shortConnectorMinWords = 5;

  /// Split [text] into natural read-aloud sentences.
  ///
  /// Keep sentence-end boundaries first, then split long Alice-style compound
  /// sentences into shorter read-aloud phrase chunks.
  static List<String> splitSentences(String text) {
    final cleaned = _normalizeArticleText(text);
    if (cleaned.isEmpty) return [];

    return _splitSentenceCandidates(cleaned)
        .expand(_splitLongReadAloudChunk)
        .map((sentence) => sentence.trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
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
        keptLines.add(_normalizeInWordHyphens(line));
      }
    }

    final normalized = _normalizeInWordHyphens(
      keptLines.join(' ').replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim(),
    );
    return normalized;
  }

  static String _normalizeInWordHyphens(String text) => text.replaceAllMapped(
        RegExp(r'([A-Za-z])\s*-\s*([A-Za-z])'),
        (match) => '${match.group(1)!}-${match.group(2)!}',
      );

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

    return _looksLikeStandaloneTitle(normalized, words, isSentenceLike);
  }

  static bool _looksLikeStandaloneTitle(
    String line,
    int wordCount,
    bool isSentenceLike,
  ) {
    if (isSentenceLike || wordCount < 2 || wordCount > 7) {
      return false;
    }
    if (RegExp(r'[,;:!?。！？]').hasMatch(line)) {
      return false;
    }

    final tokens = RegExp(r"[A-Za-z][A-Za-z'’-]*(?:-[A-Za-z][A-Za-z'’-]*)*")
        .allMatches(line)
        .map((match) => match.group(0)!)
        .toList(growable: false);
    if (tokens.length != wordCount) {
      return false;
    }

    return tokens.every(_isTitleWord);
  }

  static bool _isTitleWord(String token) {
    final normalized = token.toLowerCase();
    const smallTitleWords = {
      'a',
      'an',
      'and',
      'as',
      'at',
      'by',
      'for',
      'from',
      'in',
      'of',
      'on',
      'or',
      'the',
      'to',
      'with',
    };
    if (smallTitleWords.contains(normalized)) {
      return true;
    }
    return RegExp(r'^[A-Z]').hasMatch(token);
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

      final currentWithClosers = buffer.toString().trim();
      if (_shouldKeepReadingThroughSentenceEnd(
        currentWithClosers,
        cleaned,
        lookahead,
      )) {
        continue;
      }

      if (lookahead >= cleaned.length || _isWhitespace(cleaned[lookahead])) {
        final sentence = currentWithClosers;
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

  static List<String> _splitLongReadAloudChunk(String sentence) {
    final trimmed = sentence.trim();
    if (trimmed.isEmpty) {
      return [trimmed];
    }

    final chunks = <String>[];
    var start = 0;

    while (start < trimmed.length) {
      final restStart = _nextNonWhitespace(trimmed, start);
      start = restStart;
      final rest = trimmed.substring(start).trim();
      if (rest.isEmpty) {
        break;
      }

      final restWordCount = _wordCount(rest);
      final optionalBreak = _chooseOptionalPhraseBreak(trimmed, start);
      if (restWordCount <= _hardPhraseMaxWords && optionalBreak == null) {
        chunks.add(rest);
        break;
      }

      final breakIndex =
          restWordCount <= _hardPhraseMaxWords && optionalBreak != null
              ? optionalBreak
              : _choosePhraseBreak(trimmed, start);
      if (breakIndex <= start || breakIndex >= trimmed.length) {
        chunks.add(rest);
        break;
      }

      final chunk = trimmed.substring(start, breakIndex).trim();
      if (chunk.isNotEmpty) {
        chunks.add(chunk);
      }
      start = breakIndex;
    }

    return chunks.isEmpty ? [trimmed] : chunks;
  }

  static int? _chooseOptionalPhraseBreak(String text, int start) {
    for (final phraseBreak in _phraseBreaks(text, start)) {
      final current = text.substring(start, phraseBreak.index).trim();
      final count = _wordCount(current);
      final remaining = _wordCount(text.substring(phraseBreak.index).trim());
      if (remaining < 4) {
        continue;
      }

      if (phraseBreak.kind == _PhraseBreakKind.strong &&
          count >= _shortConnectorMinWords) {
        return phraseBreak.index;
      }
      if (count >= _targetPhraseMinWords && count <= _targetPhraseMaxWords) {
        return phraseBreak.index;
      }
      if (count >= _shortConnectorMinWords &&
          _nextChunkStartsWithConnector(text, phraseBreak.index)) {
        return phraseBreak.index;
      }
    }
    return null;
  }

  static int _choosePhraseBreak(String text, int start) {
    final breaks = _phraseBreaks(text, start);
    _PhraseBreak? fallbackBeforeHard;

    for (final phraseBreak in breaks) {
      final current = text.substring(start, phraseBreak.index).trim();
      final count = _wordCount(current);
      if (count > _hardPhraseMaxWords) {
        break;
      }
      fallbackBeforeHard = phraseBreak;

      if (phraseBreak.kind == _PhraseBreakKind.strong &&
          count >= _shortConnectorMinWords) {
        return phraseBreak.index;
      }
      if (count >= _targetPhraseMinWords && count <= _targetPhraseMaxWords) {
        return phraseBreak.index;
      }
      if (count >= _shortConnectorMinWords &&
          _nextChunkStartsWithConnector(text, phraseBreak.index)) {
        return phraseBreak.index;
      }
    }

    if (fallbackBeforeHard != null) {
      return fallbackBeforeHard.index;
    }
    return _wordBoundaryAfterWords(text, start, _targetPhraseMaxWords);
  }

  static List<_PhraseBreak> _phraseBreaks(String text, int start) {
    final breaks = <_PhraseBreak>[];
    for (var index = start; index < text.length; index++) {
      final ch = text[index];
      if (ch == ';' || ch == ':' || ch == '—' || ch == '–') {
        breaks.add(_PhraseBreak(
          index: _consumeClosingPunctuation(text, index + 1),
          kind: _PhraseBreakKind.strong,
        ));
        continue;
      }
      if (ch == ',' &&
          !_hasUnclosedDoubleQuote(text.substring(start, index + 1))) {
        breaks.add(_PhraseBreak(
          index: _consumeClosingPunctuation(text, index + 1),
          kind: _PhraseBreakKind.comma,
        ));
        continue;
      }
      if ((ch == '"' || ch == '“') &&
          _shouldBreakBeforeDirectQuote(text, start, index)) {
        breaks.add(_PhraseBreak(
          index: index,
          kind: _PhraseBreakKind.strong,
        ));
      }
    }
    return breaks;
  }

  static bool _shouldBreakBeforeDirectQuote(
    String text,
    int start,
    int index,
  ) {
    if (index <= start) {
      return false;
    }

    final current = text.substring(start, index).trim();
    if (_wordCount(current) < _shortConnectorMinWords) {
      return false;
    }

    final previous = _previousNonWhitespace(text, index - 1);
    if (previous < start ||
        !RegExp(r'[A-Za-z0-9,;:]').hasMatch(text[previous])) {
      return false;
    }

    final next = _nextNonWhitespace(text, index + 1);
    if (next >= text.length) {
      return false;
    }
    return RegExp(r'[A-Z]').hasMatch(text[next]);
  }

  static int _consumeClosingPunctuation(String text, int index) {
    var cursor = index;
    while (cursor < text.length && _isClosingPunctuation(text[cursor])) {
      cursor++;
    }
    return cursor;
  }

  static bool _nextChunkStartsWithConnector(String text, int index) {
    final rest = text.substring(index).trimLeft();
    return RegExp(
      r'^(?:and|but|or|so|for|yet|then|because|while|when|as|though|although|which|who|that)\b',
      caseSensitive: false,
    ).hasMatch(rest);
  }

  static int _wordBoundaryAfterWords(String text, int start, int count) {
    final matches = RegExp(r"[A-Za-z][A-Za-z'’-]*(?:-[A-Za-z][A-Za-z'’-]*)*")
        .allMatches(text.substring(start))
        .toList(growable: false);
    if (matches.length <= count) {
      return text.length;
    }

    final match = matches[count - 1];
    final end = start + match.start + match.group(0)!.length;
    final nextSpace = text.indexOf(' ', end);
    return nextSpace > end ? nextSpace : end;
  }

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

  static bool _shouldKeepReadingThroughSentenceEnd(
    String current,
    String text,
    int lookahead,
  ) {
    if (_hasUnclosedDoubleQuote(current)) {
      return true;
    }

    final next = _nextNonWhitespace(text, lookahead);
    if (next >= text.length) {
      return false;
    }

    return RegExp(r'[a-z]').hasMatch(text[next]);
  }

  static bool _hasUnclosedDoubleQuote(String text) {
    final straightQuotes = '"'.allMatches(text).length;
    if (straightQuotes.isOdd) {
      return true;
    }

    final openCurlyQuotes = '“'.allMatches(text).length;
    final closeCurlyQuotes = '”'.allMatches(text).length;
    return openCurlyQuotes > closeCurlyQuotes;
  }

  static int _nextNonWhitespace(String text, int start) {
    var index = start;
    while (index < text.length && _isWhitespace(text[index])) {
      index++;
    }
    return index;
  }

  static int _previousNonWhitespace(String text, int start) {
    var index = start;
    while (index >= 0 && _isWhitespace(text[index])) {
      index--;
    }
    return index;
  }
}

enum _PhraseBreakKind { strong, comma }

class _PhraseBreak {
  const _PhraseBreak({
    required this.index,
    required this.kind,
  });

  final int index;
  final _PhraseBreakKind kind;
}
