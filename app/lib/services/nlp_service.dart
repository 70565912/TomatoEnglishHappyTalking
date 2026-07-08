// NLP 服务 — Dart 本地朗读块分句
//
// ## 设计目标（朗读块，不是语言学“真分句”）
//
// - 输出供听力、跟读、歌曲字幕、绘本句段使用的 **read-aloud chunks**，不是语法分析意义上的句子。
// - 块长度应适合朗读：不过短（避免 1–3 词碎片、悬挂介词尾句），不过长（默认舒适上限约 20 词，硬上限 32 词）。
// - 规则必须 **通用**（引号、破折号、逗号、词数窗口、合并/切分启发式），不得写死单篇文章、章节号或故事专有名词。
// - Web UI `sentenceSplitter.ts` 须与本文件保持同一套常量与行为；回归样本（E10/E11/E12 等）只用于验证，不反向驱动特例逻辑。
//
// 流水线：段落归一化 → 句末标点候选 → 超长块切分 → 续读合并。

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

  /// Preferred read-aloud chunk size window (words).
  static const _targetPhraseMinWords = 10;

  /// Upper bound when choosing a phrase break inside one sentence candidate.
  static const _targetPhraseMaxWords = 24;

  /// Hard ceiling for any merged chunk; never exceed in merge pass.
  static const _hardPhraseMaxWords = 32;

  /// Comfortable ceiling; chunks longer than this keep looking for a break.
  static const _comfortPhraseMaxWords = 20;

  /// Minimum words before treating a connector-led break as valid.
  static const _shortConnectorMinWords = 6;

  /// Inside an open quote, keep reading past `.!?` until at least this many words.
  static const _quoteContinuationMinWords = 14;

  /// Same-utterance tails after `!`/`?` inside quotes (e.g. `Quick, now!`).
  static const _tinyFragmentMaxWords = 5;

  /// Do not break if the remainder is a short preposition-led tail.
  static const _orphanTailMaxWords = 12;

  /// Split [text] into read-aloud chunks for practice, listening, and song lyrics.
  static List<String> splitSentences(String text) {
    final paragraphs = _normalizeArticleParagraphs(text);
    if (paragraphs.isEmpty) return [];

    final allChunks = <String>[];
    for (final paragraph in paragraphs) {
      final chunks = _splitSentenceCandidates(paragraph)
          .expand(_splitLongReadAloudChunk)
          .map((sentence) => sentence.trim())
          .where((sentence) => sentence.isNotEmpty)
          .toList(growable: false);
      allChunks.addAll(_mergeReadAloudContinuations(chunks));
    }
    return allChunks;
  }

  static List<String> _normalizeArticleParagraphs(String text) {
    final lines = text.split(RegExp(r'\r?\n'));
    final paragraphs = <String>[];
    final currentLines = <String>[];

    void flushParagraph() {
      if (currentLines.isEmpty) {
        return;
      }
      final paragraph = _normalizeInWordHyphens(
        currentLines.join(' ').replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim(),
      );
      if (paragraph.isNotEmpty) {
        paragraphs.add(paragraph);
      }
      currentLines.clear();
    }

    for (final rawLine in lines) {
      var line = rawLine.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
      if (line.isEmpty) {
        flushParagraph();
        continue;
      }
      if (_isImportedHeadingLine(line)) {
        continue;
      }
      line = _stripCjkPrefix(line);
      if (line.isNotEmpty && !_isImportedHeadingLine(line)) {
        currentLines.add(_normalizeInWordHyphens(line));
      }
    }
    flushParagraph();

    return paragraphs;
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
      final requiredBreak = _requiredPhraseBreak(trimmed, start);
      if (restWordCount <= _comfortPhraseMaxWords && requiredBreak == null) {
        chunks.add(rest);
        break;
      }

      final breakIndex = requiredBreak ?? _choosePhraseBreak(trimmed, start);
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

  static int _choosePhraseBreak(String text, int start) {
    final breaks = _phraseBreaks(text, start);
    _PhraseBreak? fallbackBeforeHard;
    _PhraseBreak? fallbackStrongBeforeHard;
    _PhraseBreak? bestStrong;
    _PhraseBreak? bestAny;

    for (final phraseBreak in breaks) {
      final current = text.substring(start, phraseBreak.index).trim();
      final count = _wordCount(current);
      if (count > _hardPhraseMaxWords) {
        break;
      }
      if (count >= _shortConnectorMinWords) {
        fallbackBeforeHard = phraseBreak;
        if (phraseBreak.kind == _PhraseBreakKind.strong ||
            phraseBreak.kind == _PhraseBreakKind.directQuote) {
          fallbackStrongBeforeHard = phraseBreak;
        }
      }

      final remainingText = text.substring(phraseBreak.index).trim();
      final remaining = _wordCount(remainingText);
      if (remaining < 4) {
        continue;
      }
      if (_wouldCreateOrphanTail(remainingText)) {
        continue;
      }
      if (count >= _targetPhraseMinWords && count <= _targetPhraseMaxWords) {
        if (phraseBreak.kind == _PhraseBreakKind.strong) {
          if (bestStrong == null ||
              _wordCount(text.substring(start, bestStrong.index).trim()) <
                  count) {
            bestStrong = phraseBreak;
          }
        }
        if (bestAny == null ||
            _wordCount(text.substring(start, bestAny.index).trim()) < count) {
          bestAny = phraseBreak;
        }
      }
    }

    if (bestStrong != null) {
      return bestStrong.index;
    }
    if (bestAny != null) {
      return bestAny.index;
    }
    if (fallbackStrongBeforeHard != null) {
      return fallbackStrongBeforeHard.index;
    }
    if (fallbackBeforeHard != null) {
      return fallbackBeforeHard.index;
    }
    return _wordBoundaryAfterWords(text, start, _targetPhraseMaxWords);
  }

  static int? _requiredPhraseBreak(String text, int start) {
    for (final phraseBreak in _phraseBreaks(text, start)) {
      if (phraseBreak.kind != _PhraseBreakKind.directQuote) {
        continue;
      }
      final current = text.substring(start, phraseBreak.index).trim();
      final remaining = text.substring(phraseBreak.index).trim();
      final currentWords = _wordCount(current);
      // Only force a pre-quote split when the prose before the quote is
      // already a comfortable read-aloud chunk; otherwise earlier punctuation
      // should split the narration first.
      if (currentWords >= _shortConnectorMinWords &&
          currentWords <= _targetPhraseMaxWords &&
          _wordCount(remaining) >= 4) {
        return phraseBreak.index;
      }
    }
    return null;
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
          kind: _PhraseBreakKind.directQuote,
        ));
      }
    }
    breaks.addAll(_connectorBreaks(text, start));
    breaks.sort((a, b) => a.index.compareTo(b.index));
    return breaks;
  }

  static List<_PhraseBreak> _connectorBreaks(String text, int start) {
    final rest = text.substring(start);
    final matches = RegExp(
      r'\s+(?:so that|because|while|when|before|after|although|though)\b',
      caseSensitive: false,
    ).allMatches(rest);
    return [
      for (final match in matches)
        _PhraseBreak(
          index: start + match.start,
          kind: _PhraseBreakKind.connector,
        ),
    ];
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
    if (previous < start) {
      return false;
    }
    if (!RegExp(r'[A-Za-z0-9,;:]').hasMatch(text[previous]) &&
        !_isClosingPunctuation(text[previous])) {
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

  static int _wordBoundaryAfterWords(String text, int start, int count) {
    final matches = RegExp(r"[A-Za-z][A-Za-z'’-]*(?:-[A-Za-z][A-Za-z'’-]*)*")
        .allMatches(text.substring(start))
        .toList(growable: false);
    if (matches.length <= count) {
      return text.length;
    }

    var matchIndex = count - 1;
    var match = matches[matchIndex];
    var end = start + match.start + match.group(0)!.length;
    while (_wouldEndAtProtectedPeriod(text, end) &&
        matchIndex + 1 < matches.length) {
      matchIndex += 1;
      match = matches[matchIndex];
      end = start + match.start + match.group(0)!.length;
    }
    final nextSpace = text.indexOf(' ', end);
    return nextSpace > end ? nextSpace : _consumeClosingPunctuation(text, end);
  }

  static bool _wouldEndAtProtectedPeriod(String text, int wordEnd) {
    var cursor = wordEnd;
    while (cursor < text.length && _isClosingPunctuation(text[cursor])) {
      cursor++;
    }
    if (cursor >= text.length || text[cursor] != '.') {
      return false;
    }
    final before = text.substring(0, wordEnd).trimRight();
    final lastWord = before
        .split(RegExp(r'\s+'))
        .last
        .replaceAll(RegExp(r'["“”’)\]}》]+$'), '')
        .toLowerCase();
    return _abbreviations.contains(lastWord) ||
        RegExp(r'^[a-z]$').hasMatch(lastWord);
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

    final lastWord = words.last
        .replaceAll(RegExp(r'^[\"“”]+'), '')
        .replaceAll(RegExp(r'[.!?。！？"”’)\]}》]+$'), '')
        .toLowerCase();

    return _abbreviations.contains(lastWord) ||
        RegExp(r'^[a-z]$').hasMatch(lastWord);
  }

  static bool _shouldKeepReadingThroughSentenceEnd(
    String current,
    String text,
    int lookahead,
  ) {
    if (_hasUnclosedDoubleQuote(current)) {
      final next = _nextNonWhitespace(text, lookahead);
      if (next >= text.length) {
        return true;
      }
      if (RegExp(r'[a-z]').hasMatch(text[next])) {
        return true;
      }
      final tail = text.substring(lookahead).trim();
      if (_isSameQuoteShortTail(tail)) {
        return true;
      }
      return _wordCount(current) < _quoteContinuationMinWords;
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
      final trimmed = text.trimRight();
      final lastQuote = trimmed.lastIndexOf('"');
      if (lastQuote >= 0) {
        var cursor = lastQuote + 1;
        while (
            cursor < trimmed.length && _isClosingPunctuation(trimmed[cursor])) {
          cursor++;
        }
        if (cursor >= trimmed.length) {
          return false;
        }
      }
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

  static List<String> _mergeReadAloudContinuations(List<String> chunks) {
    final merged = <String>[];
    for (final rawChunk in chunks) {
      final chunk = rawChunk.trim();
      if (chunk.isEmpty) {
        continue;
      }
      if (merged.isNotEmpty && _shouldMergeWithPrevious(merged.last, chunk)) {
        merged[merged.length - 1] =
            '${merged.last} $chunk'.replaceAll(RegExp(r'\s+'), ' ').trim();
      } else {
        merged.add(chunk);
      }
    }
    return _mergeTinyQuoteTails(merged);
  }

  static List<String> _mergeTinyQuoteTails(List<String> chunks) {
    final merged = <String>[];
    for (final rawChunk in chunks) {
      final chunk = rawChunk.trim();
      if (chunk.isEmpty) {
        continue;
      }
      if (merged.isNotEmpty) {
        final previous = merged.last;
        if (_endsWithFinalSentencePunctuation(previous) &&
            _hasUnclosedDoubleQuote(previous) &&
            _wordCount(chunk) <= _tinyFragmentMaxWords &&
            _isSameQuoteShortTail(chunk) &&
            _wordCount('$previous $chunk') <= _hardPhraseMaxWords) {
          merged[merged.length - 1] =
              '$previous $chunk'.replaceAll(RegExp(r'\s+'), ' ').trim();
          continue;
        }
      }
      merged.add(chunk);
    }
    return merged;
  }

  static bool _shouldMergeWithPrevious(String previous, String current) {
    final combinedWords = _wordCount('$previous $current');
    if (combinedWords > _hardPhraseMaxWords) {
      return false;
    }
    if (_hasUnclosedDoubleQuote(previous)) {
      if (_wordCount(current) <= _tinyFragmentMaxWords &&
          _isSameQuoteShortTail(current) &&
          combinedWords <= _hardPhraseMaxWords) {
        return true;
      }
      return combinedWords <= _targetPhraseMaxWords;
    }
    if (_endsWithEmDash(previous)) {
      return _shouldMergeEmDashContinuation(current);
    }
    if (_endsWithDanglingReadAloudPhrase(previous)) {
      return true;
    }
    if (_endsWithShortCommaPhrase(previous)) {
      return combinedWords <= _targetPhraseMaxWords;
    }
    if (_isShortQuotedFragment(previous)) {
      return combinedWords <= _targetPhraseMaxWords;
    }
    if (_startsWithLowercaseConnector(current) &&
        !_endsWithFinalSentencePunctuation(previous)) {
      if (_endsWithStrongPhrasePunctuation(previous) &&
          _wordCount(previous) >= _targetPhraseMinWords) {
        return false;
      }
      return combinedWords <= _targetPhraseMaxWords;
    }
    return false;
  }

  static bool _startsWithLowercaseConnector(String text) {
    return RegExp(
      r'^(?:and|but|or|so|for|yet|then|because|while|when|as|though|although|which|who|that)\b',
    ).hasMatch(text.trim());
  }

  static bool _endsWithEmDash(String text) {
    final trimmed = text.trim();
    return trimmed.endsWith('—') || trimmed.endsWith('–');
  }

  static bool _shouldMergeEmDashContinuation(String current) {
    final currentTrim = current.trim();
    if (currentTrim.isEmpty) {
      return false;
    }
    if (RegExp(r'^["“]').hasMatch(currentTrim)) {
      return true;
    }
    final firstLetter = _leadingContentLetter(currentTrim);
    if (firstLetter != null && RegExp(r'[a-z]').hasMatch(firstLetter)) {
      return _wordCount(currentTrim) < _targetPhraseMinWords;
    }
    if (_wordCount(currentTrim) <= _tinyFragmentMaxWords) {
      return true;
    }
    return false;
  }

  static String? _leadingContentLetter(String text) {
    final match = RegExp(r'[A-Za-z]').firstMatch(text);
    return match?.group(0);
  }

  static bool _isSameQuoteShortTail(String text) {
    final fragment = _sameUtteranceTailPrefix(text);
    if (fragment.isEmpty ||
        _wordCount(fragment) > _tinyFragmentMaxWords ||
        _startsWithNewSpeakerAttribution(fragment)) {
      return false;
    }
    return true;
  }

  static String _sameUtteranceTailPrefix(String text) {
    final trimmed = text.trim();
    for (var i = 0; i < trimmed.length; i++) {
      final ch = trimmed[i];
      if (ch == '"' || ch == '”') {
        return trimmed.substring(0, i + 1).trim();
      }
    }
    return trimmed;
  }

  static bool _startsWithNewSpeakerAttribution(String text) {
    return RegExp(
      r'^(?:said|cried|shouted|asked|thought|answered|replied|muttered|whispered|called|went on)\b',
      caseSensitive: false,
    ).hasMatch(text.trim());
  }

  static bool _wouldCreateOrphanTail(String remaining) {
    final remainingWords = _wordCount(remaining);
    if (remainingWords >= _orphanTailMaxWords) {
      return false;
    }
    return RegExp(
      r'^(?:with|and|in|on|at|to|for|from|into|upon|about|like|as|but|or|so|yet|nor|that|which|who)\s+',
      caseSensitive: false,
    ).hasMatch(remaining.trim());
  }

  static bool _endsWithDanglingReadAloudPhrase(String text) {
    final trimmed = text.trim();
    if (trimmed.endsWith('-') &&
        !trimmed.endsWith('—') &&
        !trimmed.endsWith('–')) {
      return true;
    }
    return RegExp(
      r'\b(?:a|an|the|and|or|but|as|if|to|of|for|with|from|into|upon|about|like|than|that|which|who|what|how|why|where|when|me|my|your|his|her|their|our)\s*["”’)]*$',
      caseSensitive: false,
    ).hasMatch(trimmed);
  }

  static bool _endsWithFinalSentencePunctuation(String text) {
    return RegExp(r'[.!?。！？]["”’)\]}》]*$').hasMatch(text.trim());
  }

  static bool _endsWithStrongPhrasePunctuation(String text) {
    return RegExp(r'[;:—–]["”’)\]}》]*$').hasMatch(text.trim());
  }

  static bool _endsWithShortCommaPhrase(String text) {
    final trimmed = text.trim();
    return _wordCount(trimmed) < _targetPhraseMinWords &&
        RegExp(r',["”’)\]}》]*$').hasMatch(trimmed);
  }

  static bool _isShortQuotedFragment(String text) {
    final trimmed = text.trim();
    if (_wordCount(trimmed) >= _targetPhraseMinWords) {
      return false;
    }
    final startsWithQuote = RegExp(r'''^["'“‘]''').hasMatch(trimmed);
    if (!startsWithQuote) {
      return false;
    }
    return !_endsWithFinalSentencePunctuation(trimmed) ||
        RegExp(r'''[,'"“‘][^"'“”‘’]*[.!?。！？]$''').hasMatch(trimmed);
  }
}

enum _PhraseBreakKind { strong, comma, connector, directQuote }

class _PhraseBreak {
  const _PhraseBreak({
    required this.index,
    required this.kind,
  });

  final int index;
  final _PhraseBreakKind kind;
}
