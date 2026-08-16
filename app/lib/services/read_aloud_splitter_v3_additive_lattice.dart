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
    // R-LENGTH-ZONES: complete originals at or under the comfort ceiling keep
    // every internal boundary out of the path — including syntax cuts.
    if (words.length <= ReadAloudSplitterV3.preferredMaxUnpunctuatedWords) {
      final ends = [words.length];
      return [
        _AdditiveSplitPathV3(
          boundaries: const [],
          segments: List.unmodifiable(_additiveSegmentsV3(source, words, ends)),
          wordCounts: List.unmodifiable(_additiveLengthsV3(ends)),
          maxUnpunctuatedWordCounts: List.unmodifiable(
            _additiveUnpunctuatedLengthsV3(words, ends),
          ),
          score: List.unmodifiable(_additiveZeroScoreV3),
        ),
      ];
    }
    final boundaryByEnd = <int, _AdditiveBoundaryFactV3>{
      for (final fact in boundaryFacts) fact.candidate.afterWord: fact,
    };
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
              (!_isAlternativeOpeningDelimiterEdgeV3(fact.candidate) ||
                  // Quote→paren junctions are real pause edges even when the
                  // paren side looks like an opener (`know" | —(pointing…)`).
                  fact.candidate.quoteEdge == 'after_closing') &&
              !_isEmbeddedQuotedNominalPunctuationV3(
                words,
                fact.candidate,
              ) &&
              !_isShortQuotedComplementClosingBeforeContinuationV3(
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
  required List<_SourceWordV3> words,
  required List<_AdditiveBoundaryFactV3> punctuationFacts,
  required List<int> strongPunctuationEnds,
  required Set<int> attributionClosings,
}) {
  final closesAtSyntaxBoundary =
      closingBoundary != null && !closingBoundary.candidate.isPunctuation;
  final skippedStrong = strongPunctuationEnds
      .where(
        (offset) =>
            offset > start &&
            offset < end &&
            !(_isValidatedSyntaxBoundaryV3(openingBoundary) &&
                    offset - start <= 3 ||
                _isValidatedSyntaxBoundaryV3(closingBoundary) &&
                    end - offset <= 3),
      )
      .length;
  final rawInternalPunctuation = punctuationFacts
      .where(
        (fact) =>
            fact.candidate.afterWord > start && fact.candidate.afterWord < end,
      )
      .toList(growable: false);
  final internalPunctuation = rawInternalPunctuation
      .where(
        (fact) =>
            !_isEmbeddedQuotedNominalPunctuationV3(words, fact.candidate) &&
            !_isRedundantOpeningDelimiterEdgeV3(
              fact.candidate,
              segmentEnd: end,
              closingBoundary: closingBoundary,
            ) &&
            !(fact.candidate.kind == ReadAloudBoundaryKindV3.ambiguousComma &&
                openingBoundary?.candidate.quoteEdge == 'after_closing' &&
                fact.candidate.afterWord - start <= 5) &&
            !_isOptionalNominativeAbsoluteCommaV3(words, fact) &&
            // `change (she knew) | to …`: the closer is real punctuation, but
            // parking it is required to keep the attached PP with its verb.
            !_isAttachedPpParentheticalClosingV3(fact),
      )
      .toList(growable: false);
  final opensOnEmergency =
      openingBoundary?.candidate.isEmergency == true;
  final quoteParenJunctionSkip = length > 16
      ? rawInternalPunctuation
          .where(
            (fact) =>
                fact.candidate.quoteEdge == 'after_closing' &&
                fact.candidate.parenEdge == 'before_opening',
          )
          .length
      : 0;
  final skippedPunctuation = internalPunctuation
      .where(
        (fact) =>
            length > 17 ||
            closesAtSyntaxBoundary ||
            // Emergency openings must not park a medial pause inside a
            // mid-length tail (E17: `bend | about` / `easily | in` + comma).
            (sourceWordCount > 20 && length >= 6 && opensOnEmergency) ||
            // Balanced medial commas: do not pressure-split short *originals*
            // (R-LENGTH-ZONES / DB <=16 KEEP). Long sources may still need
            // asyndetic clause commas inside a <=16 punctuation subspan
            // (Willows E30 rusty-key / door).
            ((length > 16 || sourceWordCount > 20) &&
                fact.candidate.afterWord - start >= 6 &&
                end - fact.candidate.afterWord >= 6) ||
            // Syntax openings that park a still-usable clause-join pause
            // (`… murmur, | and …`) must pay — even inside a mid-length span
            // (Willows E58 `position | assigned … murmur,`). Do not broaden to
            // every ≥4/≥4 pause: that collapses reviewed supplemental PP fronts
            // such as `memories | by the fireside;`.
            (openingBoundary != null &&
                !openingBoundary.candidate.isPunctuation &&
                fact.candidate.afterWord - start >= 4 &&
                end - fact.candidate.afterWord >= 4 &&
                _additiveCoordinatorsV3.contains(
                  _additiveLexemeV3(words[fact.candidate.afterWord].text),
                )) ||
            // Alice E38: syntax opening parks a mid-span comma with ≥4/≥4 sides
            // inside a >16 block (`idea | that … jury-box,`).
            (openingBoundary != null &&
                !openingBoundary.candidate.isPunctuation &&
                length > 16 &&
                fact.candidate.afterWord - start >= 4 &&
                end - fact.candidate.afterWord >= 4) ||
            _hasCompleteFiveWordPunctuationTailV3(
              fact,
              words: words,
              end: end,
            ) ||
            // Short comparative/prep tails after a comma (`direction, | like a
            // serpent`) must count as skipped punctuation — otherwise a nearby
            // syntax cut such as `find | that` parks the comma for free.
            _hasCompleteShortAdpositionPunctuationTailV3(
              fact,
              words: words,
              end: end,
            ) ||
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
      .length +
      quoteParenJunctionSkip;
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
  final overload = math.max(0, length - 20);
  // Clause/phrase commas are the R-PUNCT-FIRST edges that must not lose to a
  // nearby syntax cut solely because a 17–20 comma-closed block was charged as
  // "unpunctuated" elasticity (Alice E05 candle/out). Strong terminals keep the
  // elasticity charge so reviewed syntax-before-supplement paths stay stable.
  final closesAtCommaPause = closingBoundary != null &&
      (closingBoundary.candidate.kind == ReadAloudBoundaryKindV3.clauseComma ||
          closingBoundary.candidate.kind ==
              ReadAloudBoundaryKindV3.phraseComma ||
          closingBoundary.candidate.kind ==
              ReadAloudBoundaryKindV3.ambiguousComma);
  final elasticOverload = length >= 17 &&
          length <= 20 &&
          internalPunctuation.isEmpty &&
          !closesAtCommaPause
      ? length - 16
      : 0;
  final isLongSourceCompleteShortClause = sourceWordCount > 20 &&
      length >= 4 &&
      length <= 5 &&
      (closingBoundary?.candidate.isPunctuation == true ||
          closingBoundary?.candidate.quoteEdge == 'before_opening' ||
          end == sourceWordCount &&
              openingBoundary?.candidate.isPunctuation == true);
  final opensAfterClosingQuote = openingBoundary?.candidate.reasons.any(
        (reason) => reason == 'quote_edge:after_closing',
      ) ??
      false;
  // 17–20 sources may close on a punctuation-bounded 4–5 tail when the opening
  // edge itself is low structural risk (v3.8/v3.9 baseline). Do not broaden this
  // into a comma-kind-only trailing-postmodifier exemption — that Attempt D path
  // fixed E13 door in isolation but left confirmed R-SYNTAX-LOCATION cuts.
  final isFlexibleSourceCompleteShortTail = sourceWordCount >= 17 &&
      sourceWordCount <= 20 &&
      end == sourceWordCount &&
      length >= 4 &&
      length <= 5 &&
      openingBoundary?.candidate.isPunctuation == true &&
      openingBoundary!.strongStructuralRisk == 0 &&
      openingBoundary.residualRisk == 0 &&
      !opensAfterClosingQuote;
  // A verified finite-clause front (`doubt | that …`) is a complete 4–5 word
  // unit; do not let its shortfall beat an incomplete emergency such as
  // `able | to` farther right in the same >20 unpunctuated span.
  final isCompleteClauseFrontShort = length >= 4 &&
      length <= 5 &&
      closingBoundary?.candidate.kind ==
          ReadAloudBoundaryKindV3.dependencyClause &&
      (closingBoundary!.candidate.reasons.contains(
            'complete_dependency_clause_subtree',
          ) ||
          closingBoundary.candidate.reasons.contains(
            'validated_surface_right_clause',
          ) ||
          closingBoundary.candidate.reasons.contains(
            'deferred_stable_right_clause',
          ));
  // `direction, | like a serpent` is a complete 3-word adposition tail; without
  // this exemption the fragment score prefers parking the comma after a syntax
  // cut such as `find | that`.
  final isCompleteShortAdpositionTail = length >= 3 &&
      length <= 5 &&
      end == sourceWordCount &&
      openingBoundary?.candidate.isPunctuation == true &&
      words[start].upos.contains('ADP') &&
      words
          .sublist(start + 1, end)
          .any((word) => word.upos.any(const {'NOUN', 'PROPN', 'PRON'}.contains));
  final isCompleteShortClause = isLongSourceCompleteShortClause ||
      isFlexibleSourceCompleteShortTail ||
      isCompleteClauseFrontShort ||
      isCompleteShortAdpositionTail;
  final isStandaloneShortQuote = _isStandaloneShortQuoteV3(
    words,
    start: start,
    end: end,
    sourceWordCount: sourceWordCount,
    closingBoundary: closingBoundary,
    openingBoundary: openingBoundary,
    attributionClosings: attributionClosings,
  );
  // A 2–3 word unit that already closes on a source sentence terminal
  // (`Society!`, `No?`) is a complete spoken beat. Do not pay the short-
  // fragment tax that would push the cut past the terminal onto a later
  // syntax edge (`Society! Now | we…`).
  final isCompleteStrongTerminalShort = length >= 2 &&
      length <= 3 &&
      closingBoundary?.candidate.kind ==
          ReadAloudBoundaryKindV3.strongPunctuation &&
      _additiveQuotedTerminalPauseV3.hasMatch(words[end - 1].text);
  return [
    length <= 3 &&
            !isStandaloneShortQuote &&
            !isCompleteShortAdpositionTail &&
            !isCompleteStrongTerminalShort
        ? (4 - length) * (4 - length)
        : 0,
    length > 20 ? 1 : 0,
    overload * overload,
    skippedStrong,
    skippedPunctuation,
    length >= 4 &&
            length <= 5 &&
            !isCompleteShortClause &&
            !isStandaloneShortQuote
        ? (6 - length) * (6 - length)
        : 0,
    0, // non-punctuation protected crossings
    0, // structural warnings
    closesShortNominalAdpositionPause
        ? 1
        : 0, // weak punctuation structural warnings
    0, // emergency boundary
    elasticOverload * elasticOverload, // 17-20 unpunctuated elasticity
    0, // non-punctuation boundary
    isStandaloneShortQuote
        ? 0
        : shortfall * shortfall + (closesShortBeforePredicate ? 1 : 0),
    0, // residual boundary risk
    0, // prefer closing parenthetical edge when otherwise equal
    0, // boundary count
  ];
}

bool _isValidatedSyntaxBoundaryV3(_AdditiveBoundaryFactV3? boundary) =>
    boundary?.candidate.reasons.contains(
      'validated_stable_syntax_boundary',
    ) ??
    false;

bool _hasCompleteFiveWordPunctuationTailV3(
  _AdditiveBoundaryFactV3 boundary, {
  required List<_SourceWordV3> words,
  required int end,
}) {
  final start = boundary.candidate.afterWord;
  if (end - start != 5 || start >= words.length) return false;
  return words[start].upos.any(_additivePredicatePosV3.contains) ||
      words
          .sublist(start, math.min(end, start + 3))
          .any((word) => word.upos.any(_additivePredicatePosV3.contains));
}

/// Comma followed by a compact adposition-led tail (`like a serpent`). Parking
/// that pause while taking an earlier syntax cut violates R-PUNCT-FIRST; the
/// broader dependencyClause skippedPunctuation charge previously regresses
/// E17 particle paths, so only this adposition-tail shape is charged.
bool _hasCompleteShortAdpositionPunctuationTailV3(
  _AdditiveBoundaryFactV3 boundary, {
  required List<_SourceWordV3> words,
  required int end,
}) {
  final start = boundary.candidate.afterWord;
  final length = end - start;
  if (length < 3 || length > 5 || start >= words.length) return false;
  if (!words[start].upos.contains('ADP')) return false;
  return words
      .sublist(start + 1, end)
      .any((word) => word.upos.any(const {'NOUN', 'PROPN', 'PRON'}.contains));
}

/// Nominative-absolute commas (`Badger, having… breakfast, had…`) are real
/// source pauses but optional under R-PUNCT-FIRST when a later coordination /
/// clause edge is preferred. Not counting them as skippedPunctuation lets the
/// DB path `study | … face, |` compete without hard-blocking early commas.
bool _isOptionalNominativeAbsoluteCommaV3(
  List<_SourceWordV3> words,
  _AdditiveBoundaryFactV3 fact,
) {
  final afterWord = fact.candidate.afterWord;
  if (afterWord <= 0 || afterWord >= words.length) return false;
  final kind = fact.candidate.kind;
  if (kind != ReadAloudBoundaryKindV3.clauseComma &&
      kind != ReadAloudBoundaryKindV3.phraseComma &&
      kind != ReadAloudBoundaryKindV3.ambiguousComma) {
    return false;
  }
  final left = words[afterWord - 1];
  final right = words[afterWord];
  final rightLexeme = right.text.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  if ((rightLexeme == 'having' || rightLexeme == 'being') &&
      left.upos.any(const {'NOUN', 'PROPN', 'PRON'}.contains)) {
    return true;
  }
  if (!right.upos.any(_additivePredicatePosV3.contains) ||
      !left.upos.any(const {'NOUN', 'PROPN'}.contains)) {
    return false;
  }
  final lookbackStart = math.max(0, afterWord - 12);
  for (var index = afterWord - 2; index >= lookbackStart; index--) {
    final lexeme =
        words[index].text.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    if (lexeme == 'having' || lexeme == 'being') return true;
  }
  return false;
}

bool _isAlternativeOpeningDelimiterEdgeV3(
  ReadAloudBoundaryCandidateV3 candidate,
) =>
    candidate.reasons.any(
      const {
        'source_parenthetical_opening_edge',
        'source_quote_opening_edge',
      }.contains,
    );

bool _isRedundantOpeningDelimiterEdgeV3(
  ReadAloudBoundaryCandidateV3 candidate, {
  required int segmentEnd,
  required _AdditiveBoundaryFactV3? closingBoundary,
}) {
  // Quote|paren junctions (`know" | —(pointing…)`) are real R-PUNCT-FIRST /
  // delimiter edges — not a skippable paren opener inside a kept closer.
  if (candidate.quoteEdge == 'after_closing') return false;
  final spanWordCount = candidate.parenSpanWordCount;
  if (candidate.parenEdge != 'before_opening' || spanWordCount == null) {
    return false;
  }
  final matchingClosing = candidate.afterWord + spanWordCount;
  return matchingClosing <= segmentEnd &&
      (matchingClosing < segmentEnd ||
          closingBoundary?.candidate.parenEdge == 'after_closing');
}

bool _isAttachedPpParentheticalClosingV3(_AdditiveBoundaryFactV3 fact) =>
    fact.candidate.parenEdge == 'after_closing' &&
    fact.candidate.reasons.contains(
      'incomplete_attached_prepositional_complement',
    );

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
  if (candidate.quoteEdge == 'after_closing' &&
      candidate.reasons.contains('source_quote_closing_edge') &&
      (candidate.quoteSpanWordCount ?? 0) >= 2 &&
      (candidate.quoteSpanWordCount ?? 0) <= 16 &&
      candidate.quoteSpanWordCount == leftLength &&
      sourceWordCount - offset >= 6) {
    return true;
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

List<int> _additiveBoundaryScoreV3(_AdditiveBoundaryFactV3 fact) {
  final boundary = fact.candidate;
  final nonPunctuation = !boundary.isPunctuation;
  return [
    0,
    0,
    0,
    0,
    0,
    0,
    nonPunctuation ? fact.protectedRelationCrossings : 0,
    fact.strongStructuralRisk + fact.lengthCriticalStructuralRisk,
    fact.weakPunctuationRisk,
    boundary.isEmergency ? 1 : 0,
    0,
    nonPunctuation ? 1 : 0,
    0,
    fact.residualRisk,
    boundary.parenEdge == 'before_opening' &&
            boundary.quoteEdge != 'after_closing' ||
        boundary.quoteEdge == 'before_opening'
        ? 1
        : 0,
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
  final expanded = <ReadAloudCandidatePathV3>[];
  for (var index = 0;
      index < ranked.length &&
          index < ReadAloudSplitterV3.maxExpandedCandidatePaths;
      index += 1) {
    final source = ranked[index];
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
];
