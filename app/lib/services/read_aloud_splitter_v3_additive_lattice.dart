part of 'read_aloud_splitter_v3.dart';

/// Exact top-K solver over an additive word-position DAG.
///
/// Facts are built before this call. The solver neither scans dependency trees
/// nor reruns a repair window, so every orthographic sentence has one bounded
/// solve regardless of how many candidate boundaries it contains.
final class _AdditiveReadAloudLatticeV3 {
  const _AdditiveReadAloudLatticeV3();

  List<_AdditiveSplitPathV3> solve({
    required String source,
    required List<_SourceWordV3> words,
    required List<_AdditiveBoundaryFactV3> boundaryFacts,
  }) {
    if (words.isEmpty) return const [];
    final boundaryByEnd = <int, _AdditiveBoundaryFactV3>{
      for (final fact in boundaryFacts) fact.candidate.afterWord: fact,
    };
    final comfortable21Starts = _comfortable21StartsV3(
      words.length,
      boundaryFacts,
    );
    final punctuationFacts = boundaryFacts
        .where((fact) => fact.candidate.isPunctuation)
        .toList(growable: false);
    final attributionClosings = _quoteAttributionClosingsV3(
      boundaryFacts,
      words,
    );
    final strongPunctuationFacts = boundaryFacts
        .where(
          (fact) =>
              fact.candidate.kind ==
                  ReadAloudBoundaryKindV3.strongPunctuation &&
              !_isEmbeddedQuotedNominalPunctuationV3(
                words,
                fact.candidate,
              ) &&
              !attributionClosings.contains(fact.candidate.afterWord),
        )
        .toList(growable: false);
    final strongPunctuationEnds = [
      ...strongPunctuationFacts.expand((fact) sync* {
        final end = fact.candidate.afterWord;
        yield end;
        final quotedTerminal = fact.candidate.insideQuotedSpeech &&
            (fact.candidate.quoteSpanWordCount ?? 0) > 16 &&
            _additiveQuotedTerminalPauseV3.hasMatch(words[end - 1].text) &&
            !strongPunctuationFacts.any(
              (previous) => previous.candidate.afterWord == end - 1,
            );
        if (quotedTerminal ||
            fact.candidate.quoteEdge == 'before_opening' &&
                (fact.candidate.quoteSpanWordCount ?? 0) >= 6) {
          yield end;
        }
      }),
      for (final fact in punctuationFacts)
        if (fact.candidate.kind != ReadAloudBoundaryKindV3.strongPunctuation &&
            fact.candidate.quoteEdge == 'before_opening' &&
            (fact.candidate.quoteSpanWordCount ?? 0) > 16)
          fact.candidate.afterWord,
    ];

    final bestFrom =
        List.generate(words.length + 1, (_) => <_AdditiveDraftV3>[]);
    bestFrom[words.length] = const [
      _AdditiveDraftV3([], [], _additiveZeroScoreV3),
    ];
    for (var start = words.length - 1; start >= 0; start -= 1) {
      final drafts = <_AdditiveDraftV3>[];
      final maximumEnd = math.min(
        words.length,
        start + ReadAloudSplitterV3.hardMaxWords,
      );
      for (var end = start + 1; end <= maximumEnd; end += 1) {
        final closesSource = end == words.length;
        final boundaryFact = closesSource ? null : boundaryByEnd[end];
        if (!closesSource && boundaryFact == null) continue;
        final segmentScore = _additiveSegmentScoreV3(
          length: end - start,
          start: start,
          end: end,
          sourceWordCount: words.length,
          openingBoundary: start == 0 ? null : boundaryByEnd[start],
          closingBoundary: boundaryFact,
          comfortable21Starts: comfortable21Starts,
          words: words,
          punctuationFacts: punctuationFacts,
          strongPunctuationEnds: strongPunctuationEnds,
          attributionClosings: attributionClosings,
        );
        final edgeScore = _additiveScoreV3(
          segmentScore,
          boundaryFact == null
              ? _additiveZeroScoreV3
              : _additiveBoundaryScoreV3(boundaryFact),
        );
        for (final suffix in bestFrom[end]) {
          drafts.add(
            _AdditiveDraftV3(
              boundaryFact == null
                  ? suffix.boundaries
                  : [boundaryFact.candidate, ...suffix.boundaries],
              [end, ...suffix.ends],
              _additiveScoreV3(edgeScore, suffix.score),
            ),
          );
        }
      }
      drafts.sort(_compareAdditiveDraftsV3);
      bestFrom[start] = _retainDiverseAdditiveDraftsV3(drafts);
    }

    return [
      for (final draft in bestFrom[0])
        _AdditiveSplitPathV3(
          boundaries: List.unmodifiable(draft.boundaries),
          segments: List.unmodifiable(
            _additiveSegmentsV3(source, words, draft.ends),
          ),
          wordCounts: List.unmodifiable(_additiveLengthsV3(draft.ends)),
          maxUnpunctuatedWordCounts: List.unmodifiable(
            _additiveUnpunctuatedLengthsV3(words, draft.ends),
          ),
          score: List.unmodifiable(draft.score),
        ),
    ];
  }
}

List<_AdditiveDraftV3> _retainDiverseAdditiveDraftsV3(
  List<_AdditiveDraftV3> ranked,
) {
  const limit = ReadAloudSplitterV3.maxExpandedCandidatePaths;
  if (ranked.length <= limit) return ranked;
  final selected = ranked.take(limit).toList(growable: true);
  final firstEndCounts = <int, int>{};
  final minimumBoundaryCounts = <int, int>{};
  for (final draft in selected) {
    firstEndCounts.update(
      draft.ends.first,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
    minimumBoundaryCounts.update(
      draft.ends.first,
      (count) => math.min(count, draft.boundaries.length),
      ifAbsent: () => draft.boundaries.length,
    );
  }
  for (final draft in ranked.skip(limit)) {
    final firstEnd = draft.ends.first;
    if (firstEndCounts.containsKey(firstEnd)) continue;
    var replacement = -1;
    for (var index = selected.length - 1;
        index >= ReadAloudSplitterV3.maxCandidatePaths;
        index -= 1) {
      final selectedFirstEnd = selected[index].ends.first;
      if (firstEndCounts[selectedFirstEnd]! > 1 &&
          selected[index].boundaries.length >
              minimumBoundaryCounts[selectedFirstEnd]!) {
        replacement = index;
        break;
      }
    }
    if (replacement < 0) break;
    final replacedFirstEnd = selected[replacement].ends.first;
    firstEndCounts[replacedFirstEnd] = firstEndCounts[replacedFirstEnd]! - 1;
    selected[replacement] = draft;
    firstEndCounts[firstEnd] = 1;
    minimumBoundaryCounts[firstEnd] = draft.boundaries.length;
  }
  selected.sort(_compareAdditiveDraftsV3);
  return selected;
}

List<int> _additiveSegmentScoreV3({
  required int length,
  required int start,
  required int end,
  required int sourceWordCount,
  required _AdditiveBoundaryFactV3? openingBoundary,
  required _AdditiveBoundaryFactV3? closingBoundary,
  required Int32List? comfortable21Starts,
  required List<_SourceWordV3> words,
  required List<_AdditiveBoundaryFactV3> punctuationFacts,
  required List<int> strongPunctuationEnds,
  required Set<int> attributionClosings,
}) {
  final skippedStrong = strongPunctuationEnds
      .where((offset) => offset > start && offset < end)
      .length;
  final closesAtSyntaxBoundary =
      closingBoundary != null && !closingBoundary.candidate.isPunctuation;
  final rawInternalPunctuation = punctuationFacts
      .where(
        (fact) =>
            fact.candidate.afterWord > start && fact.candidate.afterWord < end,
      )
      .toList(growable: false);
  final isFlatAmbiguousList = _isFlatAmbiguousListV3(
    rawInternalPunctuation,
    start: start,
    end: end,
  );
  final internalPunctuation = rawInternalPunctuation
      .where(
        (fact) =>
            !_isTightModifierCommaV3(words, fact.candidate) &&
            !_isEmbeddedQuotedNominalPunctuationV3(words, fact.candidate) &&
            (fact.candidate.kind != ReadAloudBoundaryKindV3.ambiguousComma ||
                !isFlatAmbiguousList &&
                    !(openingBoundary?.candidate.quoteEdge == 'after_closing' &&
                        fact.candidate.afterWord - start <= 5) ||
                start == 0 &&
                    fact.candidate.afterWord == 3 &&
                    sourceWordCount > 20 &&
                    !fact.candidate.insideQuotedSpeech &&
                    !fact.candidate.insideParenthetical),
      )
      .toList(growable: false);
  final skippedPunctuation = length >= 17 || closesAtSyntaxBoundary
      ? internalPunctuation.length
      : internalPunctuation
          .where(
            (fact) =>
                _isPriorityQuotePauseV3(
                  fact.candidate,
                  start: start,
                  end: end,
                  sourceWordCount: sourceWordCount,
                  attributionClosings: attributionClosings,
                ) ||
                _replacesRiskyAmbiguousPauseV3(
                  openingBoundary,
                  fact,
                  punctuationFacts: punctuationFacts,
                  start: start,
                  end: end,
                ),
          )
          .length;
  final shortfall = math.max(0, 8 - length);
  final closesShortNominalAdpositionPause = length < 8 &&
      closingBoundary?.candidate.kind == ReadAloudBoundaryKindV3.phraseComma &&
      words[end - 1].upos.any(const {'NOUN', 'PROPN'}.contains) &&
      words[end].upos.contains('ADP') &&
      !words
          .sublist(end, math.min(words.length, end + 5))
          .any((word) => word.upos.any(_additivePredicatePosV3.contains));
  final closesShortBeforePredicate = length < 8 &&
      (closingBoundary?.candidate.kind == ReadAloudBoundaryKindV3.clauseComma ||
          closingBoundary?.candidate.kind ==
              ReadAloudBoundaryKindV3.phraseComma ||
          closingBoundary?.candidate.kind ==
              ReadAloudBoundaryKindV3.ambiguousComma) &&
      words[end].upos.any(_additivePredicatePosV3.contains);
  final overload = math.max(0, length - 16);
  final qualifiedOverload = sourceWordCount <= 20 && internalPunctuation.isEmpty
      ? 0
      : overload * overload;
  final hasComfortableSyntaxBoundary = length == 21 &&
      comfortable21Starts != null &&
      comfortable21Starts[start] > 0;
  final isIntroductoryPause = sourceWordCount > 20 &&
      start == 0 &&
      length == 3 &&
      closingBoundary?.candidate.insideQuotedSpeech == false &&
      closingBoundary?.candidate.insideParenthetical == false &&
      (closingBoundary?.candidate.kind == ReadAloudBoundaryKindV3.phraseComma ||
          closingBoundary?.candidate.kind ==
              ReadAloudBoundaryKindV3.ambiguousComma);
  final isLongSourceCompleteShortClause = sourceWordCount > 20 &&
      length >= 4 &&
      length <= 5 &&
      (closingBoundary?.candidate.kind == ReadAloudBoundaryKindV3.clauseComma ||
          closingBoundary?.candidate.kind ==
              ReadAloudBoundaryKindV3.strongPunctuation ||
          closingBoundary?.candidate.quoteEdge == 'before_opening' ||
          end == sourceWordCount &&
              openingBoundary?.candidate.isPunctuation == true);
  final opensAfterClosingQuote = openingBoundary?.candidate.reasons.any(
        (reason) => reason == 'quote_edge:after_closing',
      ) ??
      false;
  final isFlexibleSourceCompleteShortTail = sourceWordCount >= 17 &&
      sourceWordCount <= 20 &&
      end == sourceWordCount &&
      length >= 4 &&
      length <= 5 &&
      openingBoundary?.candidate.isPunctuation == true &&
      openingBoundary!.strongStructuralRisk == 0 &&
      openingBoundary.residualRisk == 0 &&
      !opensAfterClosingQuote;
  final isCompleteShortClause =
      isLongSourceCompleteShortClause || isFlexibleSourceCompleteShortTail;
  final isStandaloneShortQuote = _isStandaloneShortQuoteV3(
    words,
    start: start,
    end: end,
    sourceWordCount: sourceWordCount,
    closingBoundary: closingBoundary,
    openingBoundary: openingBoundary,
    attributionClosings: attributionClosings,
  );
  return [
    length <= 3 && !isIntroductoryPause && !isStandaloneShortQuote
        ? (4 - length) * (4 - length)
        : 0,
    length >= 4 &&
            length <= 5 &&
            !isCompleteShortClause &&
            !isStandaloneShortQuote
        ? (6 - length) * (6 - length)
        : 0,
    0, // non-punctuation protected crossings
    0, // structural warnings
    skippedStrong,
    length >= 28 ? 1 : 0,
    skippedPunctuation,
    closesShortNominalAdpositionPause
        ? 1
        : 0, // weak punctuation structural warnings
    length >= 25 ? 1 : 0,
    length >= 22 || hasComfortableSyntaxBoundary ? 1 : 0,
    0, // emergency boundary
    0, // non-punctuation boundary
    length >= 17 && internalPunctuation.isNotEmpty ? 1 : 0,
    qualifiedOverload,
    isStandaloneShortQuote
        ? 0
        : shortfall * shortfall + (closesShortBeforePredicate ? 1 : 0),
    0, // residual boundary risk
    0, // boundary count
  ];
}

bool _isFlatAmbiguousListV3(
  List<_AdditiveBoundaryFactV3> punctuation, {
  required int start,
  required int end,
}) {
  if (punctuation.length < 3 ||
      punctuation.any(
        (fact) => fact.candidate.kind != ReadAloudBoundaryKindV3.ambiguousComma,
      )) {
    return false;
  }
  var previous = start;
  for (final fact in punctuation) {
    if (fact.candidate.afterWord - previous < 4) return false;
    previous = fact.candidate.afterWord;
  }
  return end - previous >= 4;
}

bool _isPriorityQuotePauseV3(
  ReadAloudBoundaryCandidateV3 candidate, {
  required int start,
  required int end,
  required int sourceWordCount,
  required Set<int> attributionClosings,
}) {
  if (sourceWordCount <= 16) return false;
  final offset = candidate.afterWord;
  final leftLength = offset - start;
  final rightLength = end - offset;
  if (candidate.quoteEdge == 'before_opening') {
    return (candidate.quoteSpanWordCount ?? 0) >= 6 &&
        leftLength >= 6 &&
        rightLength >= 6;
  }
  return candidate.quoteEdge == 'after_closing' &&
      !attributionClosings.contains(offset) &&
      candidate.reasons.contains('source_closing_quote_comma_pause') &&
      candidate.quoteSpanWordCount == leftLength &&
      leftLength >= 6 &&
      rightLength >= 5 &&
      sourceWordCount - offset >= 8;
}

Set<int> _quoteAttributionClosingsV3(
  List<_AdditiveBoundaryFactV3> boundaryFacts,
  List<_SourceWordV3> words,
) {
  final output = <int>{};
  int? closing;
  int? surfaceClosing;
  for (final fact in boundaryFacts) {
    final candidate = fact.candidate;
    if (closing != null && candidate.afterWord - closing > 8) closing = null;
    if (surfaceClosing != null && candidate.afterWord - surfaceClosing > 8) {
      surfaceClosing = null;
    }
    if (candidate.quoteEdge == 'after_closing') {
      closing = candidate.afterWord;
    } else if (candidate.quoteEdge == 'before_opening' && closing != null) {
      output.add(closing);
      closing = null;
    }
    if (candidate.kind != ReadAloudBoundaryKindV3.strongPunctuation) {
      continue;
    }
    if (surfaceClosing != null &&
        candidate.afterWord > surfaceClosing &&
        candidate.afterWord < words.length &&
        _additiveOpeningQuoteWordV3.hasMatch(words[candidate.afterWord].text)) {
      output.add(surfaceClosing);
      surfaceClosing = null;
    }
    if (_additiveClosingQuoteTerminalV3
        .hasMatch(words[candidate.afterWord - 1].text)) {
      surfaceClosing = candidate.afterWord;
    }
  }
  return output;
}

bool _replacesRiskyAmbiguousPauseV3(
  _AdditiveBoundaryFactV3? openingBoundary,
  _AdditiveBoundaryFactV3 candidate, {
  required List<_AdditiveBoundaryFactV3> punctuationFacts,
  required int start,
  required int end,
}) {
  final offset = candidate.candidate.afterWord;
  final previousQualified = punctuationFacts
      .where(
        (fact) =>
            fact.candidate.afterWord < start &&
            fact.candidate.kind != ReadAloudBoundaryKindV3.ambiguousComma,
      )
      .fold<int>(0, (latest, fact) => fact.candidate.afterWord);
  return openingBoundary?.candidate.kind ==
          ReadAloudBoundaryKindV3.ambiguousComma &&
      openingBoundary!.residualRisk > 0 &&
      (candidate.candidate.kind == ReadAloudBoundaryKindV3.clauseComma ||
          candidate.candidate.kind ==
              ReadAloudBoundaryKindV3.strongPunctuation) &&
      previousQualified >= 8 &&
      offset - previousQualified >= 8 &&
      offset - previousQualified <= 16 &&
      offset - start >= 4 &&
      end - offset >= 6;
}

bool _isStandaloneShortQuoteV3(
  List<_SourceWordV3> words, {
  required int start,
  required int end,
  required int sourceWordCount,
  required _AdditiveBoundaryFactV3? openingBoundary,
  required _AdditiveBoundaryFactV3? closingBoundary,
  required Set<int> attributionClosings,
}) {
  final length = end - start;
  if (length < 2 ||
      length > 5 ||
      closingBoundary?.candidate.quoteEdge != 'after_closing' ||
      closingBoundary?.candidate.quoteSpanWordCount != length ||
      attributionClosings.contains(end)) {
    return false;
  }
  return (openingBoundary?.candidate.quoteEdge == 'before_opening' ||
          sourceWordCount >= 17) &&
      words.sublist(start, end).any(
            (word) => RegExp(r'''[.!?]["'”’]*$''').hasMatch(word.text),
          );
}

final _additiveQuotedTerminalPauseV3 =
    RegExp(r'''[.!?…]["'”’)}\]]*[—–-]?["'”’)}\]]*$''');
final _additiveClosingQuoteTerminalV3 = RegExp(r'''[.!?]["'”’]+[—–-]?$''');
final _additiveOpeningQuoteWordV3 = RegExp(r'''^["'“‘]''');

Int32List? _comfortable21StartsV3(
  int wordCount,
  List<_AdditiveBoundaryFactV3> boundaryFacts,
) {
  if (wordCount < 21) return null;
  final counts = Int32List(wordCount - 20);
  for (final fact in boundaryFacts) {
    final boundary = fact.candidate;
    if (boundary.isPunctuation ||
        boundary.isEmergency ||
        boundary.protectedRelationCrossings > 0 ||
        fact.strongStructuralRisk > 0 ||
        fact.lengthCriticalStructuralRisk > 0 ||
        fact.residualRisk > 0) {
      continue;
    }
    final firstStart = math.max(0, boundary.afterWord - 15);
    final lastStart = math.min(wordCount - 21, boundary.afterWord - 6);
    if (firstStart > lastStart) continue;
    counts[firstStart] += 1;
    if (lastStart + 1 < counts.length) counts[lastStart + 1] -= 1;
  }
  var active = 0;
  for (var start = 0; start < counts.length; start += 1) {
    active += counts[start];
    counts[start] = active;
  }
  return counts;
}

List<int> _additiveBoundaryScoreV3(_AdditiveBoundaryFactV3 fact) {
  final boundary = fact.candidate;
  final nonPunctuation = !boundary.isPunctuation;
  return [
    0,
    0,
    nonPunctuation ? fact.protectedRelationCrossings : 0,
    fact.strongStructuralRisk,
    0,
    0,
    0,
    fact.weakPunctuationRisk,
    0,
    fact.lengthCriticalStructuralRisk,
    boundary.isEmergency ? 1 : 0,
    nonPunctuation ? 1 : 0,
    0,
    0,
    0,
    fact.residualRisk,
    1,
  ];
}

int _compareAdditiveDraftsV3(
  _AdditiveDraftV3 left,
  _AdditiveDraftV3 right,
) {
  for (var index = 0; index < left.score.length; index += 1) {
    final comparison = left.score[index].compareTo(right.score[index]);
    if (comparison != 0) return comparison;
  }
  final edgeCount = math.min(left.ends.length, right.ends.length);
  for (var index = 0; index < edgeCount; index += 1) {
    final comparison = left.ends[index].compareTo(right.ends[index]);
    if (comparison != 0) return comparison;
  }
  return left.ends.length.compareTo(right.ends.length);
}

List<int> _additiveScoreV3(List<int> left, List<int> right) => [
      for (var index = 0; index < left.length; index += 1)
        left[index] + right[index],
    ];

List<String> _additiveSegmentsV3(
  String source,
  List<_SourceWordV3> words,
  List<int> ends,
) {
  final output = <String>[];
  var start = 0;
  for (final end in ends) {
    output.add(
      _ReadAloudSplitterEngineV3._segmentText(source, words, start, end),
    );
    start = end;
  }
  return output;
}

List<int> _additiveLengthsV3(List<int> ends) {
  final output = <int>[];
  var start = 0;
  for (final end in ends) {
    output.add(end - start);
    start = end;
  }
  return output;
}

List<int> _additiveUnpunctuatedLengthsV3(
  List<_SourceWordV3> words,
  List<int> ends,
) {
  final output = <int>[];
  var start = 0;
  for (final end in ends) {
    var run = 0;
    var maximum = 0;
    for (var word = start; word < end; word += 1) {
      run += 1;
      maximum = math.max(maximum, run);
      if (_ReadAloudSplitterEngineV3._visiblePause.hasMatch(words[word].text)) {
        run = 0;
      }
    }
    output.add(maximum);
    start = end;
  }
  return output;
}

_CandidatePathRoundsV3 _materializeAdditivePathsV3({
  required int originalIndex,
  required List<_AdditiveSplitPathV3> ranked,
}) {
  final stable = ranked
      .where(
        (path) => path.boundaries.every(
          (boundary) =>
              !boundary.reasons.contains('incomplete_constituent_boundary'),
        ),
      )
      .toList(growable: false);
  final eligible = stable.isEmpty ? ranked : stable;
  final expanded = <ReadAloudCandidatePathV3>[];
  for (var index = 0;
      index < eligible.length &&
          index < ReadAloudSplitterV3.maxExpandedCandidatePaths;
      index += 1) {
    final source = eligible[index];
    final round = index < ReadAloudSplitterV3.maxCandidatePaths
        ? ReadAloudCandidateRoundV3.initial
        : ReadAloudCandidateRoundV3.expanded;
    final pathKey = source.boundaries.isEmpty
        ? 'keep'
        : source.boundaries
            .map(
              (boundary) =>
                  '${boundary.afterWord}${_additiveKindCodeV3(boundary.kind)}',
            )
            .join('_');
    expanded.add(
      ReadAloudCandidatePathV3(
        pathId: 'v3_o${originalIndex}_'
            '${round == ReadAloudCandidateRoundV3.initial ? 'r1' : 'r2'}_'
            '$pathKey',
        originalIndex: originalIndex,
        stage: _additiveStageV3(source.boundaries),
        boundaries: source.boundaries,
        segments: source.segments,
        wordCounts: source.wordCounts,
        maxUnpunctuatedWordCounts: source.maxUnpunctuatedWordCounts,
        score: source.score,
        round: round,
        diversity: ReadAloudCandidateDiversityV3.score,
      ),
    );
  }
  return _CandidatePathRoundsV3(
    initial: expanded
        .where((path) => path.round == ReadAloudCandidateRoundV3.initial)
        .toList(growable: false),
    expanded: expanded,
  );
}

ReadAloudPathStageV3 _additiveStageV3(
  List<ReadAloudBoundaryCandidateV3> boundaries,
) {
  if (boundaries.isEmpty) return ReadAloudPathStageV3.unchanged;
  if (boundaries.every((boundary) => boundary.isPunctuation)) {
    return ReadAloudPathStageV3.punctuation;
  }
  if (boundaries.every((boundary) => !boundary.isEmergency)) {
    return ReadAloudPathStageV3.syntax;
  }
  return ReadAloudPathStageV3.emergency;
}

String _additiveKindCodeV3(ReadAloudBoundaryKindV3 kind) => switch (kind) {
      ReadAloudBoundaryKindV3.originalSentence => 'o',
      ReadAloudBoundaryKindV3.strongPunctuation => 'p',
      ReadAloudBoundaryKindV3.clauseComma => 'c',
      ReadAloudBoundaryKindV3.phraseComma => 'm',
      ReadAloudBoundaryKindV3.ambiguousComma => 'a',
      ReadAloudBoundaryKindV3.dependencyClause => 'd',
      ReadAloudBoundaryKindV3.dependencyPhrase => 'f',
      ReadAloudBoundaryKindV3.emergency => 'e',
    };

final class _AdditiveSplitPathV3 {
  const _AdditiveSplitPathV3({
    required this.boundaries,
    required this.segments,
    required this.wordCounts,
    required this.maxUnpunctuatedWordCounts,
    required this.score,
  });

  final List<ReadAloudBoundaryCandidateV3> boundaries;
  final List<String> segments;
  final List<int> wordCounts;
  final List<int> maxUnpunctuatedWordCounts;
  final List<int> score;
}

final class _AdditiveDraftV3 {
  const _AdditiveDraftV3(this.boundaries, this.ends, this.score);

  final List<ReadAloudBoundaryCandidateV3> boundaries;
  final List<int> ends;
  final List<int> score;
}

const _additiveZeroScoreV3 = <int>[
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
];
