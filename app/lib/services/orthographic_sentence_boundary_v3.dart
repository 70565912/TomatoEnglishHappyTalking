import 'read_aloud_splitter_v3.dart';

/// An exact UTF-16 range of one orthographic sentence in the source text.
class OrthographicSentenceRangeV3 {
  const OrthographicSentenceRangeV3({
    required this.start,
    required this.end,
  });

  final int start;
  final int end;

  String textOf(String source) => source.substring(start, end);

  @override
  bool operator ==(Object other) =>
      other is OrthographicSentenceRangeV3 &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'OrthographicSentenceRangeV3($start, $end)';
}

/// Resolves source sentence boundaries without a vocabulary of abbreviations,
/// names, reporting verbs, or book-specific phrases.
///
/// UDPipe supplies token categories and dependency relations, but its tokenizer
/// sentence guesses are deliberately ignored. A quote attribution is joined in
/// a provisional pass and retained in the verified pass only when the parsed
/// tree connects the quoted clause and attribution predicate structurally.
class OrthographicSentenceBoundaryV3 {
  const OrthographicSentenceBoundaryV3._();

  static List<OrthographicSentenceRangeV3> resolve({
    required String source,
    required DependencyDocumentV3 document,
    bool requireVerifiedQuoteAttribution = false,
  }) {
    if (source.isEmpty) return const [];
    final tokens = _flatten(document);
    if (tokens.isEmpty) {
      return [
        OrthographicSentenceRangeV3(
          start: _skipWhitespaceForward(source, 0),
          end: _skipWhitespaceBackward(source, source.length),
        ),
      ];
    }

    final ranges = <OrthographicSentenceRangeV3>[];
    final quoteStack = <String>[];
    var sentenceStart = _skipWhitespaceForward(source, 0);

    void addBoundary(int rawEnd) {
      final end = _skipWhitespaceBackward(source, rawEnd);
      if (end > sentenceStart) {
        ranges.add(
          OrthographicSentenceRangeV3(start: sentenceStart, end: end),
        );
      }
      sentenceStart = _skipWhitespaceForward(source, rawEnd);
    }

    for (var index = 0; index < tokens.length; index += 1) {
      final token = tokens[index];
      if (index > 0 &&
          _containsParagraphBreak(
            source.substring(tokens[index - 1].end, token.start),
          )) {
        // Paragraphs are locked orthographic units. An unmatched quotation in
        // one paragraph must never change how punctuation in the next
        // paragraph is interpreted.
        quoteStack.clear();
      }
      if (_isQuoteToken(source, token)) {
        _updateQuoteStack(quoteStack, source, token);
        continue;
      }
      if (!_isTerminalPunctuation(token)) continue;
      final dotLeaderEnd = _spacedDotLeaderEndIndex(
        source: source,
        tokens: tokens,
        punctuationIndex: index,
      );
      if (dotLeaderEnd != null && index < dotLeaderEnd) continue;

      final insideQuote = quoteStack.isNotEmpty;
      final closingQuoteIndex = insideQuote
          ? _immediateClosingQuoteIndex(
              source: source,
              tokens: tokens,
              punctuationIndex: index,
              expectedQuote: quoteStack.last,
            )
          : null;
      if (closingQuoteIndex == null) {
        if (_hasLowercaseSourceContinuation(
          source: source,
          tokens: tokens,
          punctuationIndex: index,
        )) {
          continue;
        }
        addBoundary(
          insideQuote
              ? token.end
              : _trailingSymbolClusterEnd(
                    source: source,
                    tokens: tokens,
                    punctuationIndex: index,
                  ) ??
                  _outsideClosingDelimiterEnd(
                    source: source,
                    tokens: tokens,
                    punctuationIndex: index,
                  ),
        );
        continue;
      }

      final attribution = _quoteAttribution(
        tokens: tokens,
        punctuationIndex: index,
        closingQuoteIndex: closingQuoteIndex,
      );
      final shouldAttach = _hasLowercaseDependencyContinuation(
            tokens: tokens,
            closingQuoteIndex: closingQuoteIndex,
          ) ||
          attribution != null &&
              (!requireVerifiedQuoteAttribution ||
                  _hasVerifiedQuoteDependency(
                    tokens: tokens,
                    punctuationIndex: index,
                    attribution: attribution,
                  ));
      if (!shouldAttach) {
        addBoundary(
          _closingDelimiterEnd(
            tokens: tokens,
            closingQuoteIndex: closingQuoteIndex,
          ),
        );
      }
    }

    final finalEnd = _skipWhitespaceBackward(source, source.length);
    if (finalEnd > sentenceStart) {
      ranges.add(
        OrthographicSentenceRangeV3(start: sentenceStart, end: finalEnd),
      );
    }
    return _splitAtParagraphBreaks(source, ranges);
  }

  static List<_FlatDependencyTokenV3> _flatten(
    DependencyDocumentV3 document,
  ) {
    final result = <_FlatDependencyTokenV3>[];
    for (var sentenceIndex = 0;
        sentenceIndex < document.sentences.length;
        sentenceIndex += 1) {
      final sentence = document.sentences[sentenceIndex];
      for (final token in sentence.tokens) {
        result.add(
          _FlatDependencyTokenV3(
            sentenceIndex: sentenceIndex,
            token: token,
          ),
        );
      }
    }
    result.sort((left, right) {
      final byStart = left.start.compareTo(right.start);
      return byStart != 0 ? byStart : left.end.compareTo(right.end);
    });
    return result;
  }

  static bool _isTerminalPunctuation(_FlatDependencyTokenV3 token) {
    return RegExp(r'^[.!?\u2026]+$').hasMatch(token.sourceText);
  }

  static int? _spacedDotLeaderEndIndex({
    required String source,
    required List<_FlatDependencyTokenV3> tokens,
    required int punctuationIndex,
  }) {
    if (tokens[punctuationIndex].sourceText != '.') return null;
    var start = punctuationIndex;
    var end = punctuationIndex;
    while (start > 0 &&
        tokens[start - 1].sourceText == '.' &&
        RegExp(r'^\s*$').hasMatch(
            source.substring(tokens[start - 1].end, tokens[start].start))) {
      start -= 1;
    }
    while (end + 1 < tokens.length &&
        tokens[end + 1].sourceText == '.' &&
        RegExp(r'^\s*$').hasMatch(
            source.substring(tokens[end].end, tokens[end + 1].start))) {
      end += 1;
    }
    return end - start + 1 >= 3 ? end : null;
  }

  static bool _hasLowercaseSourceContinuation({
    required String source,
    required List<_FlatDependencyTokenV3> tokens,
    required int punctuationIndex,
  }) {
    for (var index = punctuationIndex + 1; index < tokens.length; index += 1) {
      final gap = source.substring(tokens[index - 1].end, tokens[index].start);
      if (_containsParagraphBreak(gap)) return false;
      final token = tokens[index];
      if (_isSymbolicToken(token) || _isQuoteToken(source, token)) {
        continue;
      }
      final text = token.sourceText;
      return text.isNotEmpty &&
          RegExp(r'[\p{Ll}]', unicode: true).hasMatch(text[0]);
    }
    return false;
  }

  static int _outsideClosingDelimiterEnd({
    required String source,
    required List<_FlatDependencyTokenV3> tokens,
    required int punctuationIndex,
  }) {
    var end = tokens[punctuationIndex].end;
    for (var index = punctuationIndex + 1; index < tokens.length; index += 1) {
      final value = tokens[index].sourceText;
      if (!const {')', ']', '}', '\u201d', '\u2019', '"', "'"}
          .contains(value)) {
        break;
      }
      if (source.substring(end, tokens[index].start).isNotEmpty) break;
      end = tokens[index].end;
    }
    return end;
  }

  static int? _trailingSymbolClusterEnd({
    required String source,
    required List<_FlatDependencyTokenV3> tokens,
    required int punctuationIndex,
  }) {
    var end = tokens[punctuationIndex].end;
    var symbolCharacters = 0;
    for (var index = punctuationIndex + 1; index < tokens.length; index += 1) {
      final gap = source.substring(tokens[index - 1].end, tokens[index].start);
      if (_containsParagraphBreak(gap)) break;
      final token = tokens[index];
      if (!_isSymbolicToken(token)) break;
      // A closing quote belongs to the sentence, but a following opening
      // quote may begin the next sentence. Quote handling below has enough
      // source context to distinguish them; an emoticon-style symbol cluster
      // does not. Also allow whitespace only before the first symbol, as in
      // `Great! :)`, never between separate punctuation groups.
      if (_isQuoteToken(source, token)) break;
      if (symbolCharacters > 0 && gap.isNotEmpty) break;
      if (_isTerminalPunctuation(token)) break;
      symbolCharacters += token.sourceText.runes.length;
      end = token.end;
    }
    return symbolCharacters >= 2 ? end : null;
  }

  static int _closingDelimiterEnd({
    required List<_FlatDependencyTokenV3> tokens,
    required int closingQuoteIndex,
  }) {
    var end = tokens[closingQuoteIndex].end;
    for (var index = closingQuoteIndex + 1; index < tokens.length; index += 1) {
      if (!const {')', ']', '}'}.contains(tokens[index].sourceText)) break;
      end = tokens[index].end;
    }
    return end;
  }

  static bool _isQuoteToken(
    String source,
    _FlatDependencyTokenV3 token,
  ) {
    if (!const {'"', "'", '\u201c', '\u201d', '\u2018', '\u2019'}
        .contains(token.sourceText)) {
      return false;
    }
    if (token.sourceText == "'") {
      final before = token.start > 0 ? source[token.start - 1] : '';
      final after = token.end < source.length ? source[token.end] : '';
      if (_isAlphaNumeric(before) && _isAlphaNumeric(after)) return false;
    }
    return true;
  }

  static bool _isAlphaNumeric(String value) =>
      value.isNotEmpty &&
      RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(value);

  static bool _isSymbolicToken(_FlatDependencyTokenV3 token) =>
      token.upos == 'PUNCT' ||
      token.upos == 'SYM' ||
      !RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(token.sourceText);

  static void _updateQuoteStack(
    List<String> stack,
    String source,
    _FlatDependencyTokenV3 token,
  ) {
    final quote = token.sourceText;
    if (quote == '\u201c' || quote == '\u2018') {
      stack.add(quote);
      return;
    }
    if (quote == '\u201d' || quote == '\u2019') {
      final expected = quote == '\u201d' ? '\u201c' : '\u2018';
      if (stack.isNotEmpty && stack.last == expected) stack.removeLast();
      return;
    }
    final before = token.start > 0 ? source[token.start - 1] : '';
    final after = token.end < source.length ? source[token.end] : '';
    final looksOpening = _isAlphaNumeric(after) &&
        (before.isEmpty || RegExp(r'[\s\(\[\{]').hasMatch(before));
    final looksClosing = _isAlphaNumeric(before) &&
            (after.isEmpty || RegExp(r'[\s.,;:!?\)\]\}]').hasMatch(after)) ||
        RegExp(r'[,.;:!?\)\]\}]').hasMatch(before) &&
            (after.isEmpty || RegExp(r'\s').hasMatch(after));
    if (looksOpening && !looksClosing) {
      stack.add(quote);
      return;
    }
    if (looksClosing && !looksOpening) {
      if (stack.isNotEmpty && stack.last == quote) stack.removeLast();
      return;
    }
    if (stack.isNotEmpty && stack.last == quote) {
      stack.removeLast();
    } else {
      stack.add(quote);
    }
  }

  static int? _immediateClosingQuoteIndex({
    required String source,
    required List<_FlatDependencyTokenV3> tokens,
    required int punctuationIndex,
    required String expectedQuote,
  }) {
    for (var index = punctuationIndex + 1; index < tokens.length; index += 1) {
      final token = tokens[index];
      final gap = source.substring(tokens[index - 1].end, token.start);
      if (gap.contains(RegExp(r'\r?\n\s*\r?\n'))) return null;
      if (_isQuoteToken(source, token) &&
          _closesQuote(token.sourceText, expectedQuote)) {
        return index;
      }
      if (token.upos != 'PUNCT' && token.upos != 'SYM') return null;
      if (!_isClosingDelimiter(token.sourceText)) return null;
    }
    return null;
  }

  static bool _closesQuote(String candidate, String expected) {
    if (expected == '\u201c') return candidate == '\u201d';
    if (expected == '\u2018') return candidate == '\u2019';
    return candidate == expected;
  }

  static bool _isClosingDelimiter(String value) =>
      const {')', ']', '}', '\u201d', '\u2019', '"', "'"}.contains(value);

  /// A lower-case non-predicate immediately after a closing quotation is an
  /// orthographic continuation only when its dependency head is a following
  /// predicate. This uses casing and tree structure, not a connective or
  /// reporting-verb vocabulary. A following predicate itself is left to
  /// dependency-verified attribution handling.
  static bool _hasLowercaseDependencyContinuation({
    required List<_FlatDependencyTokenV3> tokens,
    required int closingQuoteIndex,
  }) {
    for (var index = closingQuoteIndex + 1; index < tokens.length; index += 1) {
      final token = tokens[index];
      if (token.upos == 'PUNCT' || token.upos == 'SYM') continue;
      final text = token.sourceText;
      if (text.isEmpty || _isPredicate(token)) return false;
      final first = text[0];
      if (!RegExp(r'[\p{Ll}]', unicode: true).hasMatch(first)) return false;
      final headIndex = _findHeadIndex(tokens, index);
      if (headIndex == null || headIndex <= closingQuoteIndex) return false;
      if (_isPredicate(tokens[headIndex])) return true;
      for (var cursor = index; cursor < tokens.length; cursor += 1) {
        if (_isTerminalPunctuation(tokens[cursor])) break;
        final candidate = tokens[cursor];
        if (candidate.upos == 'PUNCT' || candidate.upos == 'SYM') continue;
        final dependentHead =
            candidate.head > 0 ? _findHeadIndex(tokens, cursor) : null;
        if (dependentHead != null && dependentHead > closingQuoteIndex) {
          return true;
        }
      }
      return false;
    }
    return false;
  }

  static _QuoteAttributionV3? _quoteAttribution({
    required List<_FlatDependencyTokenV3> tokens,
    required int punctuationIndex,
    required int closingQuoteIndex,
  }) {
    if (closingQuoteIndex + 1 < tokens.length &&
        const {'"', '\u201c', '\u2018'}
            .contains(tokens[closingQuoteIndex + 1].sourceText)) {
      return null;
    }
    final following = <int>[];
    for (var index = closingQuoteIndex + 1;
        index < tokens.length &&
            following.length < ReadAloudSplitterV3.hardMaxWords;
        index += 1) {
      final token = tokens[index];
      if (_isTerminalPunctuation(token)) break;
      if (token.upos != 'PUNCT' && token.upos != 'SYM') {
        following.add(index);
      }
    }
    if (following.isEmpty) return null;

    final first = tokens[following.first];
    if (first.upos == 'CCONJ') {
      if (first.sourceText.isNotEmpty &&
          RegExp(r'[A-Z]').hasMatch(first.sourceText[0])) {
        return null;
      }
      for (final predicateIndex in following.skip(1)) {
        if (_isPredicate(tokens[predicateIndex])) {
          return _QuoteAttributionV3(
            predicateIndex: predicateIndex,
            quoteStartSearchIndex: _quoteContentStart(
              tokens,
              punctuationIndex,
            ),
            coordinated: true,
          );
        }
      }
    }
    if (first.deprel.startsWith('nsubj')) {
      final predicateIndex = _findHeadIndex(tokens, following.first);
      if (predicateIndex != null && _isPredicate(tokens[predicateIndex])) {
        return _QuoteAttributionV3(
          predicateIndex: predicateIndex,
          quoteStartSearchIndex: _quoteContentStart(tokens, punctuationIndex),
        );
      }
    }
    if (_isPredicate(first)) {
      for (final subjectIndex in following.skip(1)) {
        final subject = tokens[subjectIndex];
        if (_isNominalClauseArgument(subject) &&
            subject.sentenceIndex == first.sentenceIndex &&
            subject.head == first.id) {
          return _QuoteAttributionV3(
            predicateIndex: following.first,
            quoteStartSearchIndex: _quoteContentStart(tokens, punctuationIndex),
          );
        }
      }
      return _QuoteAttributionV3(
        predicateIndex: following.first,
        quoteStartSearchIndex: _quoteContentStart(
          tokens,
          punctuationIndex,
        ),
      );
    }
    for (final predicateIndex in following.skip(1)) {
      if (_isPredicate(tokens[predicateIndex])) {
        return _QuoteAttributionV3(
          predicateIndex: predicateIndex,
          quoteStartSearchIndex: _quoteContentStart(
            tokens,
            punctuationIndex,
          ),
        );
      }
    }
    return null;
  }

  static int _quoteContentStart(
    List<_FlatDependencyTokenV3> tokens,
    int punctuationIndex,
  ) {
    for (var index = punctuationIndex - 1; index >= 0; index -= 1) {
      final value = tokens[index].sourceText;
      if (const {'"', '\u201c', '\u2018'}.contains(value)) return index + 1;
      if (_isTerminalPunctuation(tokens[index])) return index + 1;
    }
    return 0;
  }

  static bool _hasVerifiedQuoteDependency({
    required List<_FlatDependencyTokenV3> tokens,
    required int punctuationIndex,
    required _QuoteAttributionV3 attribution,
  }) {
    final predicate = tokens[attribution.predicateIndex];
    final firstFollowingLexical = _firstLexicalIndexAfter(
      tokens,
      punctuationIndex,
    );
    final firstFollowingText = firstFollowingLexical == null
        ? ''
        : tokens[firstFollowingLexical].sourceText;
    final allowsLooseAttachment = attribution.coordinated ||
        firstFollowingLexical == attribution.predicateIndex ||
        firstFollowingText.isNotEmpty &&
            RegExp(r'[\p{Ll}]', unicode: true).hasMatch(firstFollowingText[0]);
    for (var index = attribution.quoteStartSearchIndex;
        index <= punctuationIndex;
        index += 1) {
      final quoted = tokens[index];
      if (quoted.sentenceIndex != predicate.sentenceIndex) continue;
      final relation = quoted.deprel.split(':').first;
      if (quoted.head == predicate.id && relation == 'ccomp') {
        return true;
      }
      if (quoted.head == predicate.id &&
          allowsLooseAttachment &&
          const {'parataxis', 'conj'}.contains(relation)) {
        return true;
      }
      final predicateRelation = predicate.deprel.split(':').first;
      if (allowsLooseAttachment &&
          predicate.head == quoted.id &&
          const {'parataxis', 'conj'}.contains(predicateRelation)) {
        return true;
      }
      if (attribution.coordinated &&
          quoted.head > 0 &&
          quoted.head == predicate.head &&
          relation == 'conj' &&
          predicateRelation == 'conj') {
        return true;
      }
      if (allowsLooseAttachment &&
          quoted.upos != 'PUNCT' &&
          quoted.upos != 'SYM' &&
          _reachesPredicate(
            tokens: tokens,
            tokenIndex: index,
            predicateIndex: attribution.predicateIndex,
          )) {
        return true;
      }
    }
    return false;
  }

  static int? _firstLexicalIndexAfter(
    List<_FlatDependencyTokenV3> tokens,
    int punctuationIndex,
  ) {
    for (var index = punctuationIndex + 1; index < tokens.length; index += 1) {
      final token = tokens[index];
      if (token.upos != 'PUNCT' && token.upos != 'SYM') return index;
    }
    return null;
  }

  static bool _reachesPredicate({
    required List<_FlatDependencyTokenV3> tokens,
    required int tokenIndex,
    required int predicateIndex,
  }) {
    final predicate = tokens[predicateIndex];
    var cursor = tokenIndex;
    final visited = <int>{};
    while (visited.add(cursor)) {
      final token = tokens[cursor];
      if (token.sentenceIndex != predicate.sentenceIndex || token.head <= 0) {
        return false;
      }
      if (token.head == predicate.id) return true;
      final headIndex = _findHeadIndex(tokens, cursor);
      if (headIndex == null) return false;
      cursor = headIndex;
    }
    return false;
  }

  static int? _findHeadIndex(
    List<_FlatDependencyTokenV3> tokens,
    int tokenIndex,
  ) {
    final token = tokens[tokenIndex];
    if (token.head <= 0) return null;
    for (var index = tokenIndex;
        index < tokens.length &&
            tokens[index].sentenceIndex == token.sentenceIndex;
        index += 1) {
      if (tokens[index].id == token.head) return index;
    }
    for (var index = tokenIndex - 1;
        index >= 0 && tokens[index].sentenceIndex == token.sentenceIndex;
        index -= 1) {
      if (tokens[index].id == token.head) return index;
    }
    return null;
  }

  static bool _isPredicate(_FlatDependencyTokenV3 token) =>
      token.upos == 'VERB' || token.upos == 'AUX';

  static bool _isNominalClauseArgument(_FlatDependencyTokenV3 token) {
    if (!const {'NOUN', 'PROPN', 'PRON'}.contains(token.upos)) return false;
    final relation = token.deprel.split(':').first;
    return relation == 'nsubj' || relation == 'obj';
  }

  static List<OrthographicSentenceRangeV3> _splitAtParagraphBreaks(
    String source,
    List<OrthographicSentenceRangeV3> ranges,
  ) {
    final result = <OrthographicSentenceRangeV3>[];
    final paragraphBreak = RegExp(r'(?:\r?\n)[\t ]*(?:\r?\n)+');
    for (final range in ranges) {
      var start = range.start;
      for (final match in paragraphBreak.allMatches(
        source.substring(range.start, range.end),
      )) {
        final breakStart = range.start + match.start;
        final breakEnd = range.start + match.end;
        final end = _skipWhitespaceBackward(source, breakStart);
        if (end > start) {
          result.add(OrthographicSentenceRangeV3(start: start, end: end));
        }
        start = _skipWhitespaceForward(source, breakEnd);
      }
      if (range.end > start) {
        result.add(
          OrthographicSentenceRangeV3(start: start, end: range.end),
        );
      }
    }
    return result;
  }

  static bool _containsParagraphBreak(String value) =>
      RegExp(r'(?:\r?\n)[\t ]*(?:\r?\n)+').hasMatch(value);

  static int _skipWhitespaceForward(String source, int start) {
    var cursor = start.clamp(0, source.length);
    while (cursor < source.length && RegExp(r'\s').hasMatch(source[cursor])) {
      cursor += 1;
    }
    return cursor;
  }

  static int _skipWhitespaceBackward(String source, int end) {
    var cursor = end.clamp(0, source.length);
    while (cursor > 0 && RegExp(r'\s').hasMatch(source[cursor - 1])) {
      cursor -= 1;
    }
    return cursor;
  }
}

class _FlatDependencyTokenV3 {
  const _FlatDependencyTokenV3({
    required this.sentenceIndex,
    required this.token,
  });

  final int sentenceIndex;
  final DependencyTokenV3 token;

  int get id => token.id;
  String get sourceText => token.sourceText ?? token.text;
  int get start => token.start;
  int get end => token.end;
  String get upos => token.upos;
  int get head => token.head;
  String get deprel => token.deprel;
}

class _QuoteAttributionV3 {
  const _QuoteAttributionV3({
    required this.predicateIndex,
    required this.quoteStartSearchIndex,
    this.coordinated = false,
  });

  final int predicateIndex;
  final int quoteStartSearchIndex;
  final bool coordinated;
}
