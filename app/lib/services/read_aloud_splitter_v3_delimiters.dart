part of 'read_aloud_splitter_v3.dart';

enum ReadAloudDelimiterKindV3 {
  straightDoubleQuote,
  curlyDoubleQuote,
  straightSingleQuote,
  curlySingleQuote,
  parenthetical,
}

class ReadAloudDelimiterSpanV3 {
  const ReadAloudDelimiterSpanV3({
    required this.index,
    required this.kind,
    required this.start,
    required this.end,
    required this.wordCount,
    required this.nestingDepth,
  });

  final int index;
  final ReadAloudDelimiterKindV3 kind;
  final int start;

  /// Exclusive UTF-16 offset immediately after the matching closer.
  final int end;
  final int wordCount;
  final int nestingDepth;

  bool get isQuote => kind != ReadAloudDelimiterKindV3.parenthetical;
  bool get isParenthetical => kind == ReadAloudDelimiterKindV3.parenthetical;
}

class ReadAloudDelimiterScanV3 {
  const ReadAloudDelimiterScanV3({
    required this.spans,
    required this.parentheticalIssues,
    required this.quoteIssues,
    required this.unmatchedQuoteOpeningOffsets,
    required this.unmatchedDoubleQuoteOpeningOffsets,
  });

  final List<ReadAloudDelimiterSpanV3> spans;
  final List<String> parentheticalIssues;

  /// Quote issues are diagnostics only. Literary source often starts or ends
  /// inside a multi-paragraph quotation, so they do not make the parser
  /// unhealthy and never manufacture a protective span.
  final List<String> quoteIssues;
  final Set<int> unmatchedQuoteOpeningOffsets;
  final Set<int> unmatchedDoubleQuoteOpeningOffsets;

  List<ReadAloudDelimiterSpanV3> get quoteSpans =>
      List.unmodifiable(spans.where((span) => span.isQuote));

  List<ReadAloudDelimiterSpanV3> get parentheticalSpans =>
      List.unmodifiable(spans.where((span) => span.isParenthetical));

  /// All delimiters remain available for diagnostics, while newly supported
  /// single-quote behavior is activated only where source/parser facts expose
  /// the defect this scanner repairs: adjacent speaker turns, a short outer
  /// single quotation whose nested double quotation ends at the same edge, or
  /// the bounded attribution pattern used by the repaired-source regression.
  /// This keeps ordinary legacy prose stable without a corpus or word
  /// whitelist.
  List<ReadAloudDelimiterSpanV3> behavioralQuoteSpans({
    required String source,
    required Iterable<DependencySentenceV3> parserSentences,
  }) {
    final parserEnds = parserSentences.map((sentence) => sentence.end).toSet();
    final attributionPairSpanIndexes =
        _singleQuoteAttributionPairSpanIndexesV3(source, quoteSpans);
    final doubleSpans = quoteSpans
        .where((span) => !_isSingleQuoteSpanV3(span))
        .toList(growable: false);
    final singles = quoteSpans
        .where((span) =>
            _isSingleQuoteSpanV3(span) &&
            !_isNestedInsideAnyQuoteSpanV3(span, doubleSpans))
        .toList(growable: false);
    final standaloneNestedDoubleIndexes = <int>{
      for (final span in singles)
        if (span.wordCount <= 20 &&
            parserEnds.contains(span.end - 1) &&
            doubleSpans.any(
              (inner) => inner.start > span.start && inner.end == span.end - 1,
            ) &&
            _nextLexicalAfterDelimiterIsUppercaseV3(source, span.end))
          span.index,
    };
    final activeSingleIndexes = <int>{
      ...attributionPairSpanIndexes,
      ...standaloneNestedDoubleIndexes,
      ..._repairSingleQuoteSpanIndexesV3(
        source,
        singles,
        doubleSpans,
        unmatchedDoubleQuoteOpeningOffsets,
      ),
    };
    return List.unmodifiable(quoteSpans.where(
      (span) =>
          !_isSingleQuoteSpanV3(span) ||
          activeSingleIndexes.contains(span.index),
    ));
  }

  Set<int> behavioralUnmatchedQuoteOpeningOffsets({
    required String source,
    required Iterable<DependencySentenceV3> parserSentences,
    required List<ReadAloudDelimiterSpanV3> activeQuoteSpans,
  }) {
    if (unmatchedQuoteOpeningOffsets.isEmpty) return const {};
    final doubleSpans = quoteSpans
        .where((span) => !_isSingleQuoteSpanV3(span))
        .toList(growable: false);
    final activeSingles =
        activeQuoteSpans.where(_isSingleQuoteSpanV3).toList(growable: false);
    final singlesBeforeNestedDouble = quoteSpans.where(
      (span) =>
          _isSingleQuoteSpanV3(span) &&
          doubleSpans.any(
            (inner) => inner.start > span.start && inner.end == span.end - 1,
          ),
    );
    return Set.unmodifiable(
      unmatchedQuoteOpeningOffsets.where(
        (offset) =>
            !doubleSpans.any(
              (span) => offset > span.start && offset < span.end - 1,
            ) &&
            (_adjacentSingleQuoteOffsetsV3(source).contains(offset) ||
                activeSingles.any((span) {
                  if (span.end > offset) return false;
                  return _isBoundedTerminalAttributionGapV3(
                    source.substring(span.end, offset),
                  );
                }) ||
                singlesBeforeNestedDouble.any((span) {
                  if (span.end > offset) return false;
                  return _isBoundedTerminalAttributionGapV3(
                    source.substring(span.end, offset),
                  );
                })),
      ),
    );
  }
}

Set<int> _repairSingleQuoteSpanIndexesV3(
  String source,
  List<ReadAloudDelimiterSpanV3> singles,
  List<ReadAloudDelimiterSpanV3> doubleSpans,
  Set<int> unmatchedDoubleOpeningOffsets,
) {
  final result = <int>{};
  final propagationSeeds = <ReadAloudDelimiterSpanV3>[];
  final singleEndingAt = <int, ReadAloudDelimiterSpanV3>{
    for (final span in singles) span.end - 1: span,
  };
  final singleStartingAt = <int, ReadAloudDelimiterSpanV3>{
    for (final span in singles) span.start: span,
  };
  final pairs = <({
    int leftOffset,
    int rightOffset,
    ReadAloudDelimiterSpanV3? left,
    ReadAloudDelimiterSpanV3? right,
  })>[];
  bool isSingleQuote(String value) => const {"'", '‘', '’'}.contains(value);
  bool isUnsafe(ReadAloudDelimiterSpanV3 span) =>
      unmatchedDoubleOpeningOffsets.any(
        (offset) => offset > span.start && offset < span.end - 1,
      );
  for (var leftOffset = 0; leftOffset < source.length; leftOffset += 1) {
    if (!isSingleQuote(source[leftOffset])) continue;
    var rightOffset = leftOffset + 1;
    while (rightOffset < source.length &&
        const {' ', '\t'}.contains(source[rightOffset])) {
      rightOffset += 1;
    }
    if (rightOffset >= source.length || !isSingleQuote(source[rightOffset])) {
      continue;
    }
    final left = singleEndingAt[leftOffset];
    final right = singleStartingAt[rightOffset];
    if (left == null && right == null ||
        left != null && isUnsafe(left) ||
        right != null && isUnsafe(right)) {
      continue;
    }
    pairs.add((
      leftOffset: leftOffset,
      rightOffset: rightOffset,
      left: left,
      right: right,
    ));
    final glued = rightOffset == leftOffset + 1;
    final curlyPair = left?.kind == ReadAloudDelimiterKindV3.curlySingleQuote &&
        right?.kind == ReadAloudDelimiterKindV3.curlySingleQuote;
    final endingNestedDouble = left == null
        ? null
        : doubleSpans
            .where(
              (inner) => inner.start > left.start && inner.end == left.end - 1,
            )
            .firstOrNull;
    final leftClosesNestedDouble = left != null &&
        endingNestedDouble != null &&
        RegExp(r'[.!?]').hasMatch(
          source.substring(left.start + 1, endingNestedDouble.start),
        );
    final missingLeftSpan = left == null && right != null;
    if (glued || curlyPair || leftClosesNestedDouble || missingLeftSpan) {
      if (left != null) result.add(left.index);
      if (right != null) {
        result.add(right.index);
        if (missingLeftSpan ||
            leftClosesNestedDouble &&
                right.end >= 2 &&
                source[right.end - 2] == ',') {
          propagationSeeds.add(right);
        }
      }
    }
  }
  for (var index = 0; index + 1 < pairs.length; index += 1) {
    final first = pairs[index];
    final second = pairs[index + 1];
    if (first.right == null || first.right != second.left) continue;
    if (first.left == null ||
        second.left == null ||
        RegExp(r'''[.!?"”]''').hasMatch(source[first.left!.end - 2]) ||
        RegExp(r'''[.!?"”]''').hasMatch(source[second.left!.end - 2])) {
      continue;
    }
    for (final span in [first.left, first.right, second.right]) {
      if (span != null) result.add(span.index);
    }
  }
  final orderedSingles = [...singles]
    ..sort((left, right) => left.start.compareTo(right.start));
  for (final seed in propagationSeeds) {
    final next =
        orderedSingles.where((span) => span.start >= seed.end).firstOrNull;
    if (next != null &&
        _isBoundedTerminalAttributionGapV3(
          source.substring(seed.end, next.start),
        )) {
      result.add(next.index);
    }
  }
  return result;
}

bool _nextLexicalAfterDelimiterIsUppercaseV3(String source, int offset) {
  while (offset < source.length && source[offset].trim().isEmpty) {
    offset += 1;
  }
  if (offset >= source.length) return false;
  final character = source[offset];
  return RegExp(r'[\p{Lu}]', unicode: true).hasMatch(character);
}

bool _isBoundedTerminalAttributionGapV3(String gap) =>
    gap.isNotEmpty &&
    !gap.contains(RegExp(r'\r?\n\s*\r?\n')) &&
    !gap.contains(RegExp(r'''["'“”‘’]''')) &&
    RegExp(r'[.!?]\s*$').hasMatch(gap) &&
    ReadAloudSplitterV3.wordCount(gap) <= 8;

bool _isNestedInsideAnyQuoteSpanV3(
  ReadAloudDelimiterSpanV3 span,
  List<ReadAloudDelimiterSpanV3> containers,
) =>
    containers.any(
      (container) => container.start < span.start && container.end > span.end,
    );

Set<int> _singleQuoteAttributionPairSpanIndexesV3(
  String source,
  List<ReadAloudDelimiterSpanV3> quoteSpans,
) {
  final singles = quoteSpans.where(_isSingleQuoteSpanV3).toList()
    ..sort((left, right) => left.start.compareTo(right.start));
  final result = <int>{};
  for (var index = 0; index + 1 < singles.length; index += 1) {
    final left = singles[index];
    final right = singles[index + 1];
    if (left.kind != ReadAloudDelimiterKindV3.curlySingleQuote ||
        right.kind != ReadAloudDelimiterKindV3.curlySingleQuote ||
        left.end > right.start ||
        left.end < 2) {
      continue;
    }
    final gap = source.substring(left.end, right.start);
    final closesOnDash = const {'—', '–', '-'}.contains(source[left.end - 2]);
    if (!closesOnDash ||
        gap.contains(RegExp(r'\r?\n\s*\r?\n')) ||
        !RegExp(r'[.!?]\s*$').hasMatch(gap) ||
        ReadAloudSplitterV3.wordCount(gap) > 12) {
      continue;
    }
    result
      ..add(left.index)
      ..add(right.index);
  }
  return result;
}

bool _isSingleQuoteSpanV3(ReadAloudDelimiterSpanV3 span) =>
    span.kind == ReadAloudDelimiterKindV3.straightSingleQuote ||
    span.kind == ReadAloudDelimiterKindV3.curlySingleQuote;

Set<int> _adjacentSingleQuoteOffsetsV3(String source) {
  final result = <int>{};
  bool isSingleQuote(String value) => const {"'", '‘', '’'}.contains(value);
  for (var left = 0; left < source.length; left += 1) {
    if (!isSingleQuote(source[left])) continue;
    var right = left + 1;
    while (right < source.length && const {' ', '\t'}.contains(source[right])) {
      right += 1;
    }
    if (right < source.length && isSingleQuote(source[right])) {
      result
        ..add(left)
        ..add(right);
    }
  }
  return result;
}

/// Paragraph-local authoritative delimiter matcher used by both orthographic
/// sentence resolution and the read-aloud lattice.
///
/// It deliberately recognizes only surface and parser punctuation facts. It
/// has no vocabulary, speaker, title, sentence, or corpus exceptions.
class ReadAloudDelimiterScannerV3 {
  const ReadAloudDelimiterScannerV3._();

  static final RegExp _alphaNumeric = RegExp(
    r'[\p{L}\p{N}]',
    unicode: true,
  );
  static final RegExp _paragraphBreak = RegExp(r'(?:\r?\n)[ \t]*(?:\r?\n)+');

  static ReadAloudDelimiterScanV3 scan({
    required String source,
    Iterable<DependencyTokenV3> tokens = const <DependencyTokenV3>[],
  }) {
    final punctuationQuoteOffsets = <int>{};
    final possessiveApostropheOffsets = <int>{};
    for (final token in tokens) {
      final recordsQuotePunctuation = token.upos == 'PUNCT';
      final recordsPossessive = token.upos == 'PART' && token.deprel == 'case';
      if (!recordsQuotePunctuation && !recordsPossessive) continue;
      final start = token.start < 0
          ? 0
          : token.start > source.length
              ? source.length
              : token.start;
      final end = token.end < start
          ? start
          : token.end > source.length
              ? source.length
              : token.end;
      for (var offset = start; offset < end; offset += 1) {
        final character = source[offset];
        if (recordsQuotePunctuation && _isQuoteCharacter(character)) {
          punctuationQuoteOffsets.add(offset);
        }
        if ((character == "'" || character == '’') && recordsPossessive) {
          possessiveApostropheOffsets.add(offset);
        }
      }
    }

    final rawSpans = <_RawDelimiterSpanV3>[];
    final parentheticalIssues = <String>[];
    final quoteIssues = <String>[];
    final unmatchedQuoteOpeningOffsets = <int>{};
    final unmatchedDoubleQuoteOpeningOffsets = <int>{};
    final straightDouble = <int>[];
    final curlyDouble = <int>[];

    void scanParagraph(int paragraphStart, int paragraphEnd) {
      final straightSingle = <int>[];
      final curlySingle = <int>[];
      final parentheses = <int>[];
      final carriedStraightDouble = straightDouble.isNotEmpty;
      final carriedCurlyDouble = curlyDouble.isNotEmpty;
      var sawStraightDouble = false;
      var sawCurlyDouble = false;

      int nestingDepth() =>
          straightDouble.length +
          straightSingle.length +
          curlyDouble.length +
          curlySingle.length +
          parentheses.length;

      void closeSpan(
        List<int> openings,
        int offset,
        ReadAloudDelimiterKindV3 kind,
      ) {
        if (openings.isEmpty) return;
        final depth = nestingDepth();
        final opening = openings.removeLast();
        rawSpans.add(
          _RawDelimiterSpanV3(
            kind: kind,
            start: opening,
            end: offset + 1,
            nestingDepth: depth,
          ),
        );
      }

      for (var offset = paragraphStart; offset < paragraphEnd; offset += 1) {
        final character = source[offset];
        switch (character) {
          case '(':
            parentheses.add(offset);
            continue;
          case ')':
            if (parentheses.isEmpty) {
              parentheticalIssues.add('unmatched_parenthesis_close:$offset');
            } else {
              closeSpan(
                parentheses,
                offset,
                ReadAloudDelimiterKindV3.parenthetical,
              );
            }
            continue;
          case '“':
            if (!sawCurlyDouble && carriedCurlyDouble) {
              curlyDouble.clear();
            }
            sawCurlyDouble = true;
            curlyDouble.add(offset);
            continue;
          case '”':
            sawCurlyDouble = true;
            if (curlyDouble.isEmpty) {
              quoteIssues.add('unmatched_curly_double_quote_close:$offset');
            } else {
              closeSpan(
                curlyDouble,
                offset,
                ReadAloudDelimiterKindV3.curlyDoubleQuote,
              );
            }
            continue;
          case '‘':
            curlySingle.add(offset);
            continue;
          case '’':
            if (_isInternalApostrophe(source, offset)) continue;
            if (_isPluralPossessiveApostrophe(
              source,
              offset,
              hasSingleQuoteOpening: curlySingle.isNotEmpty,
              insideDoubleQuote:
                  straightDouble.isNotEmpty || curlyDouble.isNotEmpty,
              parserSaysPossessive:
                  possessiveApostropheOffsets.contains(offset),
            )) {
              continue;
            }
            if (curlySingle.isEmpty) {
              // A bare right single quote is lexical (`’Twas`, elision, or a
              // possessive) unless a real left curly opener exists.
              continue;
            }
            closeSpan(
              curlySingle,
              offset,
              ReadAloudDelimiterKindV3.curlySingleQuote,
            );
            continue;
          case '"':
            final opens = _sameMarkQuoteOpens(
              source,
              offset,
              paragraphStart: paragraphStart,
              paragraphEnd: paragraphEnd,
              hasUnclosedQuote: straightDouble.isNotEmpty,
              mark: '"',
            );
            if (!sawStraightDouble && carriedStraightDouble && opens) {
              straightDouble.clear();
            }
            sawStraightDouble = true;
            if (opens) {
              straightDouble.add(offset);
            } else if (straightDouble.isNotEmpty) {
              closeSpan(
                straightDouble,
                offset,
                ReadAloudDelimiterKindV3.straightDoubleQuote,
              );
            } else {
              quoteIssues.add('unmatched_straight_double_quote_close:$offset');
            }
            continue;
          case "'":
            if (_isInternalApostrophe(source, offset)) continue;
            final hasOpening = straightSingle.isNotEmpty;
            final parserSaysPunctuation =
                punctuationQuoteOffsets.contains(offset);
            if (_isPluralPossessiveApostrophe(
              source,
              offset,
              hasSingleQuoteOpening: hasOpening,
              insideDoubleQuote:
                  straightDouble.isNotEmpty || curlyDouble.isNotEmpty,
              parserSaysPossessive:
                  possessiveApostropheOffsets.contains(offset),
            )) {
              continue;
            }
            if (!hasOpening &&
                _isLikelyLexicalSingleApostrophe(
                  source,
                  offset,
                  paragraphStart: paragraphStart,
                  paragraphEnd: paragraphEnd,
                  parserSaysPunctuation: parserSaysPunctuation,
                )) {
              continue;
            }
            final opens = _sameMarkQuoteOpens(
              source,
              offset,
              paragraphStart: paragraphStart,
              paragraphEnd: paragraphEnd,
              hasUnclosedQuote: hasOpening,
              mark: "'",
            );
            if (opens) {
              straightSingle.add(offset);
            } else if (hasOpening) {
              closeSpan(
                straightSingle,
                offset,
                ReadAloudDelimiterKindV3.straightSingleQuote,
              );
            } else if (parserSaysPunctuation) {
              quoteIssues.add('unmatched_straight_single_quote_close:$offset');
            }
            continue;
        }
      }

      for (final opening in parentheses) {
        parentheticalIssues.add('unmatched_parenthesis_open:$opening');
      }
      for (final opening in straightSingle) {
        quoteIssues.add('unmatched_quote_open:$opening');
        if (punctuationQuoteOffsets.contains(opening)) {
          unmatchedQuoteOpeningOffsets.add(opening);
        }
      }
      for (final opening in curlySingle) {
        quoteIssues.add('unmatched_quote_open:$opening');
        unmatchedQuoteOpeningOffsets.add(opening);
      }
    }

    final paragraphBreaks = _paragraphBreak.allMatches(source).toList();
    var paragraphStart = 0;
    for (final match in paragraphBreaks) {
      scanParagraph(paragraphStart, match.start);
      paragraphStart = match.end;
    }
    scanParagraph(paragraphStart, source.length);
    for (final opening in [...straightDouble, ...curlyDouble]) {
      quoteIssues.add('unmatched_quote_open:$opening');
      unmatchedDoubleQuoteOpeningOffsets.add(opening);
    }

    final acceptedRawSpans = <({_RawDelimiterSpanV3 span, int wordCount})>[];
    for (final span in rawSpans) {
      final wordCount = ReadAloudSplitterV3.wordCount(
        source.substring(span.start, span.end),
      );
      final crossesBlankParagraph = paragraphBreaks.any(
        (breakMatch) =>
            breakMatch.start > span.start && breakMatch.end < span.end,
      );
      final isDoubleQuote =
          span.kind == ReadAloudDelimiterKindV3.straightDoubleQuote ||
              span.kind == ReadAloudDelimiterKindV3.curlyDoubleQuote;
      if (isDoubleQuote && crossesBlankParagraph && wordCount < 4) {
        quoteIssues.add('unmatched_cross_paragraph_quote:${span.start}');
        unmatchedDoubleQuoteOpeningOffsets.add(span.start);
        continue;
      }
      acceptedRawSpans.add((span: span, wordCount: wordCount));
    }
    acceptedRawSpans.sort((left, right) {
      final byStart = left.span.start.compareTo(right.span.start);
      return byStart != 0 ? byStart : right.span.end.compareTo(left.span.end);
    });
    final spans = <ReadAloudDelimiterSpanV3>[
      for (var index = 0; index < acceptedRawSpans.length; index += 1)
        ReadAloudDelimiterSpanV3(
          index: index,
          kind: acceptedRawSpans[index].span.kind,
          start: acceptedRawSpans[index].span.start,
          end: acceptedRawSpans[index].span.end,
          wordCount: acceptedRawSpans[index].wordCount,
          nestingDepth: acceptedRawSpans[index].span.nestingDepth,
        ),
    ];
    return ReadAloudDelimiterScanV3(
      spans: List.unmodifiable(spans),
      parentheticalIssues: List.unmodifiable(parentheticalIssues),
      quoteIssues: List.unmodifiable(quoteIssues),
      unmatchedQuoteOpeningOffsets:
          Set.unmodifiable(unmatchedQuoteOpeningOffsets),
      unmatchedDoubleQuoteOpeningOffsets:
          Set.unmodifiable(unmatchedDoubleQuoteOpeningOffsets),
    );
  }

  static bool _sameMarkQuoteOpens(
    String source,
    int offset, {
    required int paragraphStart,
    required int paragraphEnd,
    required bool hasUnclosedQuote,
    required String mark,
  }) {
    if (offset <= paragraphStart) return true;
    if (offset + 1 >= paragraphEnd) return false;

    final previous = source[offset - 1];
    final next = source[offset + 1];
    final previousIsSpace = previous.trim().isEmpty;
    final nextIsSpace = next.trim().isEmpty;

    if (!previousIsSpace && nextIsSpace) return false;
    if (previousIsSpace && !nextIsSpace) return true;
    if (next == mark) return false;
    if (previous == mark) return true;
    if ('([{<:—–'.contains(previous)) return true;
    if (')]}>.。,!?;—–'.contains(next)) return false;
    if ('.。,!?;'.contains(previous)) return false;
    return !hasUnclosedQuote;
  }

  static bool _isInternalApostrophe(String source, int offset) {
    if (offset <= 0 || offset + 1 >= source.length) return false;
    return _alphaNumeric.hasMatch(source[offset - 1]) &&
        _alphaNumeric.hasMatch(source[offset + 1]);
  }

  static bool _isLikelyLexicalSingleApostrophe(
    String source,
    int offset, {
    required int paragraphStart,
    required int paragraphEnd,
    required bool parserSaysPunctuation,
  }) {
    if (parserSaysPunctuation) return false;
    final previous = offset > paragraphStart ? source[offset - 1] : '';
    final next = offset + 1 < paragraphEnd ? source[offset + 1] : '';
    // A trailing apostrophe with no active opener is a possessive/elision, not
    // a quote closer. A leading apostrophe is allowed as a tentative opener;
    // if it is really `'em`/`'tis` it will be discarded when no reliable
    // paragraph-local closer is found.
    return previous.isNotEmpty &&
        _alphaNumeric.hasMatch(previous) &&
        (next.isEmpty ||
            next.trim().isEmpty ||
            RegExp(r'[.,;:!?]').hasMatch(next));
  }

  static bool _isPluralPossessiveApostrophe(
    String source,
    int offset, {
    required bool hasSingleQuoteOpening,
    required bool insideDoubleQuote,
    required bool parserSaysPossessive,
  }) {
    if (offset <= 0 || source[offset - 1].toLowerCase() != 's') return false;
    final next = offset + 1 < source.length ? source[offset + 1] : '';
    return (next.isEmpty || next.trim().isEmpty) &&
        (!hasSingleQuoteOpening || insideDoubleQuote || parserSaysPossessive);
  }

  static bool _isQuoteCharacter(String value) =>
      const {'"', "'", '“', '”', '‘', '’'}.contains(value);
}

class _RawDelimiterSpanV3 {
  const _RawDelimiterSpanV3({
    required this.kind,
    required this.start,
    required this.end,
    required this.nestingDepth,
  });

  final ReadAloudDelimiterKindV3 kind;
  final int start;
  final int end;
  final int nestingDepth;
}
