part of 'read_aloud_splitter_v3.dart';

typedef _DependencyGapFactV3 = ({
  int risk,
  bool finiteClauseStart,
  bool pronounClauseStart,
});

final class _AdditiveBoundaryFactV3 {
  const _AdditiveBoundaryFactV3({
    required this.candidate,
    required this.protectedRelationCrossings,
    required this.strongStructuralRisk,
    required this.lengthCriticalStructuralRisk,
    required this.weakPunctuationRisk,
    required this.residualRisk,
  });

  final ReadAloudBoundaryCandidateV3 candidate;
  final int protectedRelationCrossings;
  final int strongStructuralRisk;
  final int lengthCriticalStructuralRisk;
  final int weakPunctuationRisk;
  final int residualRisk;
}

Map<int, _DependencyGapFactV3> _buildDependencyGapFactsV3({
  required List<_SourceWordV3> words,
  required DependencySentenceV3 sentence,
  required List<_MappedDependencyV3> mapped,
}) {
  final risks = <int, int>{};
  final finiteClauseStarts = <int>{};
  final pronounClauseStarts = <int>{};
  final wordByToken = <int, int>{
    for (final dependency in mapped) dependency.token.id: dependency.wordIndex,
  };
  final tokenById = <int, DependencyTokenV3>{
    for (final token in sentence.tokens) token.id: token,
  };
  final uposByWord = <int, Set<String>>{};
  for (final dependency in mapped) {
    uposByWord
        .putIfAbsent(dependency.wordIndex, () => <String>{})
        .add(dependency.token.upos);
  }

  _addPredicateChainRisksV3(risks, words.length, uposByWord);
  _addDependencyComponentRisksV3(
    risks,
    sentence,
    tokenById,
    wordByToken,
  );
  for (final subject in sentence.tokens.where(
    (token) => token.deprel.startsWith('nsubj'),
  )) {
    final subjectWord = wordByToken[subject.id];
    final predicate = tokenById[subject.head];
    final predicateWord = predicate == null ? null : wordByToken[predicate.id];
    if (subject.upos == 'PRON' &&
        subjectWord != null &&
        subjectWord > 0 &&
        predicateWord != null &&
        predicateWord > subjectWord &&
        predicateWord <= subjectWord + 4 &&
        _additivePredicatePosV3.contains(predicate!.upos)) {
      pronounClauseStarts.add(subjectWord);
    }
    final opener = tokenById[subject.id - 1];
    final openerWord = opener == null ? null : wordByToken[opener.id];
    if (subjectWord != null &&
        predicate != null &&
        predicateWord != null &&
        predicateWord > subjectWord &&
        opener != null &&
        openerWord != null &&
        openerWord == subjectWord - 1 &&
        opener.upos == 'ADV' &&
        opener.deprel == 'advmod' &&
        opener.head == predicate.id &&
        (_additivePredicatePosV3.contains(predicate.upos) ||
            sentence.tokens.any(
              (token) => token.head == predicate.id && token.deprel == 'cop',
            ))) {
      finiteClauseStarts.add(openerWord);
    }
  }
  final factWords = <int>{
    ...risks.keys,
    ...finiteClauseStarts,
    ...pronounClauseStarts,
  };
  return {
    for (final word in factWords)
      word: (
        risk: risks[word] ?? 0,
        finiteClauseStart: finiteClauseStarts.contains(word),
        pronounClauseStart: pronounClauseStarts.contains(word),
      ),
  };
}

List<ReadAloudBoundaryCandidateV3> _normalizeStableSyntaxCandidatesV3(
  List<ReadAloudBoundaryCandidateV3> candidates, {
  required List<_SourceWordV3> words,
  required Map<int, _DependencyGapFactV3> dependencyFacts,
}) {
  return [
    for (final candidate in candidates)
      _normalizeStableSyntaxCandidateV3(
        candidate,
        words: words,
        dependencyFact: dependencyFacts[candidate.afterWord],
      ),
  ];
}

ReadAloudBoundaryCandidateV3 _normalizeStableSyntaxCandidateV3(
  ReadAloudBoundaryCandidateV3 candidate, {
  required List<_SourceWordV3> words,
  required _DependencyGapFactV3? dependencyFact,
}) {
  final surfaceKind = _surfaceStableSyntaxKindV3(
    words,
    candidate,
  );
  return _isValidatedStableSyntaxCandidateV3(
    candidate,
    dependencyFact: dependencyFact,
    surfaceKind: surfaceKind,
  )
      ? _validatedStableSyntaxCandidateV3(
          candidate,
          surfaceKind: surfaceKind,
        )
      : candidate;
}

bool _isValidatedStableSyntaxCandidateV3(
  ReadAloudBoundaryCandidateV3 candidate, {
  required _DependencyGapFactV3? dependencyFact,
  required ReadAloudBoundaryKindV3? surfaceKind,
}) {
  if (candidate.isPunctuation) return false;
  final isRelativeFront =
      candidate.reasons.contains('surface_relative_clause_front');
  final isConfirmedRightClause =
      candidate.reasons.contains('deferred_stable_right_clause') &&
          (dependencyFact?.finiteClauseStart ?? false);
  final isRecoveredAdjectivalSharedPredicate =
      candidate.reasons.contains('recovered_adjectival_shared_predicate');
  if (!isRelativeFront &&
      !isConfirmedRightClause &&
      !isRecoveredAdjectivalSharedPredicate &&
      surfaceKind == null) {
    return false;
  }
  final allowedWarnings = <String>{
    if (isRelativeFront) ..._additiveRelativeFrontWarningsV3,
    if (surfaceKind == ReadAloudBoundaryKindV3.dependencyClause)
      'surface_adverb_attachment_separation',
    if (surfaceKind == ReadAloudBoundaryKindV3.dependencyPhrase) ...{
      'surface_preposition_attachment_separation',
      'surface_nested_nominal_preposition_separation',
      'surface_auxiliary_adverb_complement_separation',
      'surface_object_predicative_complement_separation',
      'surface_xcomp_predicate_separation',
    },
    if (isRecoveredAdjectivalSharedPredicate)
      'surface_mixed_coordinator_chain_separation',
  };
  return !candidate.softWarnings.any(
    (warning) =>
        _additiveStructuralWarningsV3.contains(warning) &&
        !allowedWarnings.contains(warning),
  );
}

ReadAloudBoundaryCandidateV3 _validatedStableSyntaxCandidateV3(
  ReadAloudBoundaryCandidateV3 candidate, {
  required ReadAloudBoundaryKindV3? surfaceKind,
}) =>
    ReadAloudBoundaryCandidateV3(
      afterWord: candidate.afterWord,
      kind: surfaceKind ?? ReadAloudBoundaryKindV3.dependencyClause,
      reasons: List.unmodifiable([
        ...candidate.reasons.where(
          (reason) =>
              reason != 'ordinary_word_gap' &&
              reason != 'incomplete_constituent_boundary' &&
              !(surfaceKind != null && reason.startsWith('incomplete_')),
        ),
        if (surfaceKind == ReadAloudBoundaryKindV3.dependencyClause)
          'validated_surface_right_clause',
        if (surfaceKind == ReadAloudBoundaryKindV3.dependencyPhrase)
          'validated_surface_phrase_boundary',
        'validated_stable_syntax_boundary',
      ]),
      crossedDependencyArcs: candidate.crossedDependencyArcs,
      protectedRelationCrossings: 0,
      risk: candidate.reasons.contains('surface_relative_clause_front') ? 1 : 0,
      softWarnings: candidate.softWarnings,
      hardBlocked: candidate.hardBlocked,
      hardBlockReasons: candidate.hardBlockReasons,
      insideQuotedSpeech: candidate.insideQuotedSpeech,
      quoteSpanWordCount: candidate.quoteSpanWordCount,
      quoteEdge: candidate.quoteEdge,
      insideParenthetical: candidate.insideParenthetical,
      parenSpanWordCount: candidate.parenSpanWordCount,
      parenEdge: candidate.parenEdge,
    );

ReadAloudBoundaryKindV3? _surfaceStableSyntaxKindV3(
  List<_SourceWordV3> words,
  ReadAloudBoundaryCandidateV3 candidate,
) {
  final boundary = candidate.afterWord;
  if (boundary <= 0 || boundary >= words.length) {
    return null;
  }
  final leftPos = words[boundary - 1].upos;
  final rightPos = words[boundary].upos;
  if (leftPos.any(const {'NOUN', 'PROPN'}.contains) &&
      (rightPos.contains('AUX') ||
          const {
            'can',
            'could',
            'may',
            'might',
            'must',
            'shall',
            'should',
            'will',
            'would',
          }.contains(_additiveLexemeV3(words[boundary].text)))) {
    return ReadAloudBoundaryKindV3.dependencyClause;
  }
  if (leftPos.any(const {'NOUN', 'PROPN', 'PRON'}.contains) &&
      _additiveCoordinatorsV3.contains(
        _additiveLexemeV3(words[boundary].text),
      ) &&
      words
          .sublist(boundary + 1, math.min(words.length, boundary + 6))
          .any((word) => word.upos.any(const {'NOUN', 'PROPN'}.contains))) {
    return ReadAloudBoundaryKindV3.dependencyPhrase;
  }
  if (leftPos.contains('VERB') &&
          (_isCompactComparativeAdverbialFrontV3(words, boundary) ||
              _isComparativeReferenceClauseFrontV3(words, boundary)) ||
      leftPos.any(const {'NOUN', 'PROPN'}.contains) &&
          rightPos.contains('VERB') &&
          _additiveLexemeV3(words[boundary].text).endsWith('ing') &&
          candidate.reasons.any((reason) => reason.endsWith(':xcomp'))) {
    return ReadAloudBoundaryKindV3.dependencyPhrase;
  }
  if (leftPos.contains('ADV') &&
      rightPos.any(const {'DET', 'PRON', 'NOUN', 'PROPN'}.contains) &&
      (boundary < 2 ||
          !words[boundary - 2].upos.any(const {'AUX', 'SCONJ'}.contains))) {
    final right = words.sublist(
      boundary,
      math.min(words.length, boundary + 7),
    );
    final predicate = right.indexWhere(
      (word) =>
          word.upos.contains('VERB') &&
          !_additiveLexemeV3(word.text).endsWith('ing'),
    );
    final beforePredicate = right.take(math.max(0, predicate));
    if (predicate > 0 &&
        beforePredicate.any(
          (word) => word.upos.any(const {'PRON', 'NOUN', 'PROPN'}.contains),
        ) &&
        !beforePredicate.skip(1).any(
              (word) => word.upos.any(const {'PRON', 'SCONJ'}.contains),
            )) {
      return ReadAloudBoundaryKindV3.dependencyClause;
    }
  }
  if (leftPos.any(const {'NOUN', 'PROPN'}.contains) &&
      rightPos.contains('ADP') &&
      !const {'of', 'than'}.contains(_additiveLexemeV3(words[boundary].text))) {
    // `occurs | to me` is an attached short complement, not a supplemental PP
    // front. Keep the incomplete emergency; do not promote via NOUN|ADP rules.
    if (candidate.reasons.contains(
          'incomplete_attached_prepositional_complement',
        ) &&
        _additiveLexemeV3(words[boundary].text) == 'to' &&
        !_isCompleteSupplementalPrepositionalTailV3(words, boundary)) {
      return null;
    }
    if (words.length - boundary >
            ReadAloudSplitterV3.preferredMaxUnpunctuatedWords &&
        _additiveSupplementalTailPrepositionsV3.contains(
          _additiveLexemeV3(words[boundary].text),
        ) &&
        _hasLaterCompleteSupplementalPrepositionalTailV3(words, boundary)) {
      return null;
    }
    if (_isCompleteSupplementalPrepositionalTailV3(words, boundary)) {
      return ReadAloudBoundaryKindV3.dependencyPhrase;
    }
    final left = words.sublist(math.max(0, boundary - 8), boundary);
    final copula = left.lastIndexWhere((word) => word.upos.contains('AUX'));
    if (copula > 0 &&
        left.take(copula).any(
              (word) => word.upos.any(const {'PRON', 'NOUN', 'PROPN'}.contains),
            ) &&
        !left.skip(copula + 1).any(
              (word) => word.upos.any(
                const {'ADP', 'AUX', 'CCONJ', 'VERB'}.contains,
              ),
            )) {
      return ReadAloudBoundaryKindV3.dependencyPhrase;
    }
    final predicate = left.lastIndexWhere(
      (word) => word.upos.length == 1 && word.upos.contains('VERB'),
    );
    if (predicate >= 0) {
      final tail = left.skip(predicate + 1).toList(growable: false);
      final adposition = tail.indexWhere((word) => word.upos.contains('ADP'));
      bool hasNominal(Iterable<_SourceWordV3> span) => span.any(
            (word) => word.upos.any(const {'PRON', 'NOUN', 'PROPN'}.contains),
          );
      if (adposition > 0 &&
          hasNominal(tail.take(adposition)) &&
          hasNominal(tail.skip(adposition + 1))) {
        return ReadAloudBoundaryKindV3.dependencyPhrase;
      }
    }
  }
  if (!candidate.isEmergency) return null;
  return null;
}

bool _isCompleteSupplementalPrepositionalTailV3(
  List<_SourceWordV3> words,
  int boundary,
) {
  final right = words.sublist(boundary);
  if (!_additiveSupplementalTailPrepositionsV3.contains(
        _additiveLexemeV3(right.first.text),
      ) ||
      right.length < 6 ||
      right.length > ReadAloudSplitterV3.preferredMaxUnpunctuatedWords ||
      right.any((word) => word.upos.any(const {'VERB', 'AUX'}.contains)) ||
      right
              .where(
                (word) =>
                    word.upos.any(const {'NOUN', 'PROPN', 'PRON'}.contains),
              )
              .length <
          2) {
    return false;
  }
  final left = words.sublist(
    math.max(0, boundary - ReadAloudSplitterV3.preferredMaxUnpunctuatedWords),
    boundary,
  );
  return left.any((word) => word.upos.contains('AUX')) &&
      left
              .where(
                (word) =>
                    word.upos.any(const {'NOUN', 'PROPN', 'PRON'}.contains),
              )
              .length >=
          2;
}

bool _hasLaterCompleteSupplementalPrepositionalTailV3(
  List<_SourceWordV3> words,
  int boundary,
) {
  for (var next = boundary + 1; next <= words.length - 6; next += 1) {
    if (words[next - 1].upos.any(const {'NOUN', 'PROPN'}.contains) &&
        words[next].upos.contains('ADP') &&
        _isCompleteSupplementalPrepositionalTailV3(words, next)) {
      return true;
    }
  }
  return false;
}

bool _isCompactComparativeAdverbialFrontV3(
  List<_SourceWordV3> words,
  int boundary,
) {
  if (_additiveLexemeV3(words[boundary].text) != 'as') return false;
  final end = math.min(words.length - 1, boundary + 4);
  for (var secondAs = boundary + 2; secondAs < end; secondAs += 1) {
    if (_additiveLexemeV3(words[secondAs].text) != 'as') continue;
    final middle = words.sublist(boundary + 1, secondAs);
    return middle.every(
          (word) => word.upos.any(const {'ADJ', 'ADV', 'NUM'}.contains),
        ) &&
        words[secondAs + 1].upos.any(const {'ADJ', 'ADV'}.contains);
  }
  return false;
}

bool _isComparativeReferenceClauseFrontV3(
  List<_SourceWordV3> words,
  int boundary,
) {
  if (_additiveLexemeV3(words[boundary].text) != 'as') return false;
  final right = words.sublist(
    boundary + 1,
    math.min(words.length, boundary + 7),
  );
  final predicate = right.indexWhere(
    (word) => word.upos.any(_additivePredicatePosV3.contains),
  );
  return predicate > 0 &&
      right
              .take(predicate)
              .where(
                (word) =>
                    word.upos.any(const {'PRON', 'NOUN', 'PROPN'}.contains),
              )
              .length >=
          2;
}

void _addPredicateChainRisksV3(
  Map<int, int> risks,
  int wordCount,
  Map<int, Set<String>> uposByWord,
) {
  for (final leftWord in uposByWord.keys) {
    if (!(uposByWord[leftWord] ?? const <String>{})
            .any(_additivePredicatePosV3.contains) ||
        leftWord + 1 >= wordCount) {
      continue;
    }
    final boundary = leftWord + 1;
    final scanEnd = math.min(wordCount, boundary + 3);
    for (var word = boundary; word < scanEnd; word += 1) {
      final upos = uposByWord[word] ?? const <String>{};
      if (upos.any(_additivePredicatePosV3.contains)) {
        _addComponentRiskV3(risks, boundary);
        break;
      }
      if (upos.isEmpty ||
          upos.any((value) => !_additivePredicateBridgePosV3.contains(value))) {
        break;
      }
    }
  }
}

void _addDependencyComponentRisksV3(
  Map<int, int> risks,
  DependencySentenceV3 sentence,
  Map<int, DependencyTokenV3> tokenById,
  Map<int, int> wordByToken,
) {
  final preconjHeads = sentence.tokens
      .where((token) => token.deprel == 'cc:preconj')
      .map((token) => token.head)
      .toSet();
  for (final coordinator in sentence.tokens) {
    final boundary = wordByToken[coordinator.id];
    final head = tokenById[coordinator.head];
    final headWord = head == null ? null : wordByToken[head.id];
    final grandHead = head == null ? null : tokenById[head.head];
    final grandHeadWord = grandHead == null ? null : wordByToken[grandHead.id];
    if (boundary != null &&
        boundary > 0 &&
        const {'ADV', 'PART', 'ADP'}.contains(coordinator.upos) &&
        (headWord == boundary - 1 ||
            headWord == boundary + 1 && grandHeadWord == boundary - 1 ||
            coordinator.upos == 'ADP' &&
                headWord != null &&
                headWord > boundary &&
                grandHeadWord != null &&
                grandHeadWord < boundary)) {
      _addComponentRiskV3(risks, boundary);
    }
    if (coordinator.deprel != 'cc' || head == null || boundary == null) {
      continue;
    }
    final coordinatedHeadWord = headWord;
    final prefixesNonPredicateComponent =
        !_additivePredicatePosV3.contains(head.upos) &&
            coordinatedHeadWord != null &&
            coordinatedHeadWord > boundary + 1;
    final closesPreconjPair =
        head.deprel == 'conj' && preconjHeads.contains(head.head);
    final closesPrefixedParticiple = coordinatedHeadWord != null &&
        (head.sourceText ?? head.text).toLowerCase().endsWith('ing') &&
        sentence.tokens.any(
          (token) =>
              token.head == head.id &&
              token.deprel.startsWith('nsubj') &&
              (wordByToken[token.id] ?? -1) > boundary &&
              wordByToken[token.id]! < coordinatedHeadWord,
        );
    if (prefixesNonPredicateComponent ||
        closesPreconjPair ||
        closesPrefixedParticiple) {
      _addComponentRiskV3(risks, boundary);
    }
  }
}

void _addComponentRiskV3(Map<int, int> risks, int boundary) {
  risks.update(boundary, (value) => value + 1, ifAbsent: () => 1);
}

List<_AdditiveBoundaryFactV3> _buildAdditiveBoundaryFactsV3({
  required String source,
  required List<_SourceWordV3> words,
  required List<ReadAloudBoundaryCandidateV3> candidates,
  required Map<int, _DependencyGapFactV3> dependencyFacts,
}) =>
    [
      for (final candidate in candidates)
        if ((!candidate.hardBlocked ||
                _isSurfaceQuoteOpeningPauseV3(source, words, candidate)) &&
            !_isHardBlockedSurfaceBoundaryV3(
              source,
              words,
              candidate,
            ) &&
            !_isTightStrongBehindSyntaxHoldV3(candidate, candidates))
          _buildAdditiveBoundaryFactV3(
            candidate,
            isFiniteClauseStart:
                dependencyFacts[candidate.afterWord]?.finiteClauseStart ??
                    false,
            isPronounClauseStart:
                dependencyFacts[candidate.afterWord]?.pronounClauseStart ??
                    false,
            componentRisk: dependencyFacts[candidate.afterWord]?.risk ?? 0,
            punctuationContinuationRisk: _punctuationContinuationRiskV3(
              words,
              candidate,
            ),
            coordinatorBeforeNearbyStrongRisk:
                _coordinatorBeforeNearbyStrongRiskV3(
              words,
              candidate,
              candidates,
            ),
          ),
    ];

/// `Ah! now | they` — a non-punct cut one/two words after a strong beat.
bool _isTightStrongBehindSyntaxHoldV3(
  ReadAloudBoundaryCandidateV3 candidate,
  List<ReadAloudBoundaryCandidateV3> candidates,
) {
  if (candidate.isPunctuation) return false;
  final after = candidate.afterWord;
  return candidates.any(
    (other) =>
        other.kind == ReadAloudBoundaryKindV3.strongPunctuation &&
        after > other.afterWord &&
        after - other.afterWord <= 2,
  );
}

/// Bare coordinator / relative / light-participle cuts that leave a pause
/// nearby lose to cutting at that pause (R-PUNCT-FIRST).
/// Lookahead: `Duchess | and …—`, `idea | that …,`, `watermen | applying …,`
/// Lookbehind: `pop! … sunlight | and`, `moment— … | which`
/// Supplemental PP fronts (`memories | by the fireside;`) stay unpenalized.
int _coordinatorBeforeNearbyStrongRiskV3(
  List<_SourceWordV3> words,
  ReadAloudBoundaryCandidateV3 candidate,
  List<ReadAloudBoundaryCandidateV3> candidates,
) {
  if (candidate.isPunctuation || candidate.afterWord >= words.length) {
    return 0;
  }
  final right = _additiveLexemeV3(words[candidate.afterWord].text);
  final rightIsPivot = const {
        'and',
        'or',
        'but',
        'nor',
        'that',
        'which',
        'who',
        'whom',
        'without',
        'with',
      }.contains(right) ||
      (words[candidate.afterWord].upos.contains('VERB') &&
          right.endsWith('ing'));
  final after = candidate.afterWord;
  final tightStrongBehind = candidates.any(
    (other) =>
        other.kind == ReadAloudBoundaryKindV3.strongPunctuation &&
        after > other.afterWord &&
        after - other.afterWord <= 2,
  );
  // Bare syntax holds like `Ah! now | they` must not outrank the strong beat.
  if (tightStrongBehind && !candidate.isPunctuation) {
    return 4;
  }
  if (!rightIsPivot && !tightStrongBehind) return 0;
  final lookAhead = right.endsWith('ing') ||
          const {'that', 'which', 'who', 'whom'}.contains(right)
      ? 16
      : 8;
  final hasNearbyAhead = candidates.any(
    (other) =>
        other.isPunctuation &&
        other.afterWord > after &&
        other.afterWord - after <= lookAhead,
  );
  final hasStrongBehind = candidates.any(
    (other) =>
        other.kind == ReadAloudBoundaryKindV3.strongPunctuation &&
        other.afterWord < after &&
        after - other.afterWord <= 8,
  );
  return hasNearbyAhead || hasStrongBehind || tightStrongBehind ? 2 : 0;
}

int _punctuationContinuationRiskV3(
  List<_SourceWordV3> words,
  ReadAloudBoundaryCandidateV3 candidate,
) {
  final boundary = candidate.afterWord;
  if (!candidate.isPunctuation || boundary <= 0 || boundary >= words.length) {
    return 0;
  }
  final leftPos = words[boundary - 1].upos;
  final rightPos = words[boundary].upos;
  if (candidate.quoteEdge == 'before_opening') return 0;
  if (_isEmbeddedQuotedNominalPunctuationV3(words, candidate)) return 1;
  if (candidate.kind == ReadAloudBoundaryKindV3.phraseComma &&
      rightPos.contains('ADP')) {
    final rightContext = words.sublist(
      boundary,
      math.min(words.length, boundary + 12),
    );
    if (leftPos.any(const {'ADV', 'VERB', 'AUX'}.contains) &&
        !rightContext
            .take(5)
            .any((word) => word.upos.any(_additivePredicatePosV3.contains))) {
      return 1;
    }
    if (leftPos.any(const {'NOUN', 'PROPN'}.contains) &&
        rightContext.any((word) => word.upos.contains('AUX'))) {
      return 1;
    }
  }
  // Short quote/paren closers before a participial or adjectival continuation
  // are weak relative to a following comma (`"Mole End" | painted,` /
  // `(he thought) | poor and clumsy,`).
  if ((candidate.quoteEdge == 'after_closing' &&
          (candidate.quoteSpanWordCount ?? 0) <= 2) ||
      (candidate.parenEdge == 'after_closing' &&
          (candidate.parenSpanWordCount ?? 0) <= 3)) {
    if (rightPos.any(const {'VERB', 'ADJ', 'ADV'}.contains)) return 2;
  }
  return 0;
}

bool _isEmbeddedQuotedNominalPunctuationV3(
  List<_SourceWordV3> words,
  ReadAloudBoundaryCandidateV3 candidate,
) {
  final boundary = candidate.afterWord;
  if (candidate.kind != ReadAloudBoundaryKindV3.strongPunctuation ||
      !candidate.insideQuotedSpeech ||
      candidate.quoteEdge != null ||
      boundary <= 0 ||
      boundary + 1 >= words.length ||
      !RegExp(r'''[.!?]["'”’]$''').hasMatch(words[boundary - 1].text) ||
      !words[boundary].upos.contains('CCONJ')) {
    return false;
  }
  final right = words.sublist(
    boundary + 1,
    math.min(words.length, boundary + 5),
  );
  return right.any(
        (word) => word.upos.any(const {'NOUN', 'PROPN'}.contains),
      ) &&
      !right.any((word) => word.upos.any(_additivePredicatePosV3.contains));
}

/// Short quoted complements (`"busy"`, `"Mole End"`) followed by a PP or
/// participial continuation must not force a strong-pause cut
/// (`"Mole End" | painted`). They remain optional edges.
bool _isShortQuotedComplementClosingBeforeContinuationV3(
  List<_SourceWordV3> words,
  ReadAloudBoundaryCandidateV3 candidate,
) {
  if (candidate.quoteEdge != 'after_closing') return false;
  if ((candidate.quoteSpanWordCount ?? 0) > 2) return false;
  final afterWord = candidate.afterWord;
  if (afterWord >= words.length) return false;
  final right = words[afterWord];
  return right.upos.contains('ADP') ||
      right.upos.any(const {'VERB', 'ADJ', 'ADV'}.contains);
}

bool _isSurfaceQuoteOpeningPauseV3(
  String source,
  List<_SourceWordV3> words,
  ReadAloudBoundaryCandidateV3 candidate,
) {
  final afterWord = candidate.afterWord;
  return candidate.kind == ReadAloudBoundaryKindV3.strongPunctuation &&
      candidate.hardBlockReasons.contains('inside_short_complete_quote') &&
      afterWord > 0 &&
      afterWord < words.length &&
      RegExp(r'''[:]["'“‘]$''').hasMatch(
        source.substring(words[afterWord - 1].start, words[afterWord - 1].end),
      );
}

_AdditiveBoundaryFactV3 _buildAdditiveBoundaryFactV3(
  ReadAloudBoundaryCandidateV3 candidate, {
  required bool isFiniteClauseStart,
  required bool isPronounClauseStart,
  required int componentRisk,
  required int punctuationContinuationRisk,
  int coordinatorBeforeNearbyStrongRisk = 0,
}) {
  final allowedRelativeWarnings = <String>{
    if (candidate.reasons.contains('surface_relative_clause_front'))
      ..._additiveRelativeFrontWarningsV3,
    if (candidate.reasons.contains('validated_surface_right_clause'))
      'surface_adverb_attachment_separation',
    if (candidate.reasons.contains('validated_surface_phrase_boundary')) ...{
      'surface_preposition_attachment_separation',
      'surface_nested_nominal_preposition_separation',
      'surface_auxiliary_adverb_complement_separation',
      'surface_object_predicative_complement_separation',
      'surface_xcomp_predicate_separation',
    },
    if (candidate.reasons.contains('deferred_stable_shared_predicate') ||
        candidate.reasons.contains('recovered_adjectival_shared_predicate'))
      'surface_mixed_coordinator_chain_separation',
  };
  final actionableWarnings = candidate.softWarnings
      .where(
        (warning) =>
            (_additiveStructuralWarningsV3.contains(warning) &&
                    !allowedRelativeWarnings.contains(warning) ||
                candidate.isPunctuation &&
                    _additivePunctuationWarningsV3.contains(warning)) &&
            !(candidate.quoteEdge == 'before_opening' &&
                warning == 'surface_possible_antecedent_possessive_separation'),
      )
      .toList(growable: false);
  final weakPunctuationWarningRisk = candidate.isPunctuation
      ? actionableWarnings
          .where(_additiveWeakPunctuationWarningsV3.contains)
          .length
      : 0;
  final weakPunctuationRisk =
      weakPunctuationWarningRisk + punctuationContinuationRisk;
  final apposLengthCriticalRisk = !candidate.isPunctuation &&
          candidate.reasons.contains('complete_dependency_phrase_subtree') &&
          candidate.reasons.contains('crossing_relations:appos')
      ? actionableWarnings
          .where(
            (warning) => warning == 'surface_modifier_head_separation',
          )
          .length
      : 0;
  final pronounClauseAdverbRisk = !candidate.isPunctuation &&
          candidate.kind == ReadAloudBoundaryKindV3.dependencyClause &&
          isPronounClauseStart &&
          actionableWarnings.length == 1
      ? actionableWarnings
          .where(
            (warning) => warning == 'surface_adverb_attachment_separation',
          )
          .length
      : 0;
  final lengthCriticalStructuralRisk =
      apposLengthCriticalRisk + pronounClauseAdverbRisk;
  final isStructuredQuoteEmergency = candidate.reasons.any(
    (reason) =>
        reason.startsWith('quote_edge:') ||
        reason == 'protected_quote_attribution_gap',
  );
  final isConfirmedDeferredClause = candidate.isEmergency &&
      candidate.reasons.contains('deferred_stable_right_clause') &&
      isFiniteClauseStart;
  final fallbackEmergencyRisk = candidate.isEmergency &&
          !isStructuredQuoteEmergency &&
          !isConfirmedDeferredClause
      ? 1
      : 0;
  // Parenthetical closer before an attached PP (`change (she knew) | to …`)
  // stays a delimiter edge, but must not outrank keeping the complement with
  // its governing predicate.
  final parenCloseSplitsAttachedPp = candidate.parenEdge == 'after_closing' &&
      candidate.reasons.contains(
        'incomplete_attached_prepositional_complement',
      );
  return _AdditiveBoundaryFactV3(
    candidate: candidate,
    protectedRelationCrossings:
        isConfirmedDeferredClause ? 0 : candidate.protectedRelationCrossings,
    strongStructuralRisk: actionableWarnings.length -
        weakPunctuationWarningRisk -
        lengthCriticalStructuralRisk +
        fallbackEmergencyRisk +
        (parenCloseSplitsAttachedPp ? 2 : 0) +
        coordinatorBeforeNearbyStrongRisk +
        (candidate.isPunctuation ||
                candidate.reasons.contains('validated_stable_syntax_boundary')
            ? 0
            : componentRisk),
    lengthCriticalStructuralRisk: lengthCriticalStructuralRisk,
    weakPunctuationRisk: weakPunctuationRisk,
    residualRisk: math.max(
      0,
      candidate.risk - candidate.protectedRelationCrossings * 1000,
    ),
  );
}

bool _isHardBlockedSurfaceBoundaryV3(
  String source,
  List<_SourceWordV3> words,
  ReadAloudBoundaryCandidateV3 candidate,
) {
  final afterWord = candidate.afterWord;
  if (afterWord <= 0 || afterWord >= words.length) return false;
  final leftWord = words[afterWord - 1];
  final rightWord = words[afterWord];
  final leftText = source.substring(leftWord.start, leftWord.end);
  final rightText = source.substring(rightWord.start, rightWord.end);
  final left = _additiveLexemeV3(leftText);
  final right = _additiveLexemeV3(rightText);
  // Closing quotes may sit on the left word, in the inter-word gap, or glued to
  // the right token (`know" —(pointing…)`). Quote→paren junctions are real
  // delimiter edges even when the glyph is not on the left word alone.
  final closingQuoteVisible = RegExp(r'''["'”’][,;:.!?—–-]*$''')
          .hasMatch(leftText.trimRight()) ||
      RegExp(r'''["'”’]''').hasMatch(
        source.substring(leftWord.end, rightWord.start),
      ) ||
      RegExp(r'''^["'”’]''').hasMatch(rightText.trimLeft()) ||
      candidate.parenEdge == 'before_opening';
  return candidate.quoteEdge == 'after_closing' && !closingQuoteVisible ||
      _isElongationBoundaryV3(source, words, afterWord) ||
      _additiveTitleAbbreviationV3.hasMatch(leftText.trim()) ||
      _additiveCoordinatorsV3.contains(left) &&
          RegExp(r''',["'”’)}\]]*$''').hasMatch(leftText) ||
      left == 'not' && right == 'to' ||
      afterWord > 1 &&
          _additiveLexemeV3(words[afterWord - 2].text) == 'same' &&
          right == 'as';
}

bool _isElongationBoundaryV3(
  String source,
  List<_SourceWordV3> words,
  int afterWord,
) {
  if (afterWord <= 0 || afterWord >= words.length) return false;
  final left = words[afterWord - 1];
  final right = words[afterWord];
  if (left.end != right.start || left.end - left.start < 2) return false;
  final dash = source[left.end - 1];
  if (dash != '—' && dash != '–') return false;
  // Only block true stutter elongations (`W—What`, `a—a`). A full word before
  // the dash (`moment—that`) can share a letter with the next word without
  // being an elongation compound.
  final coreLen = left.end - left.start - 1;
  if (coreLen > 2) return false;
  final beforeDash = source[left.end - 2].toLowerCase();
  final afterDash = source[right.start].toLowerCase();
  return beforeDash == afterDash &&
      RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(beforeDash);
}

String _additiveLexemeV3(String text) {
  final matches =
      RegExp(r"[a-z]+(?:'[a-z]+)?", caseSensitive: false).allMatches(text);
  return matches.isEmpty ? '' : matches.last.group(0)!.toLowerCase();
}

final RegExp _additiveTitleAbbreviationV3 = RegExp(
  r'''(?:^|["'“‘(\[])(?:Mr|Mrs|Ms|Dr|Prof|Rev|Capt|Col|Gen|Lt|Sgt|St)\.$''',
  caseSensitive: false,
);

const _additivePredicatePosV3 = <String>{'VERB', 'AUX'};
const _additivePredicateBridgePosV3 = <String>{'ADV', 'PART', 'AUX'};
const _additiveCoordinatorsV3 = <String>{'and', 'or', 'nor', 'but'};
const _additiveSupplementalTailPrepositionsV3 = <String>{
  'in',
  'on',
  'at',
  'by',
  'near',
  'beyond',
  'within',
  'outside',
  'inside',
  'throughout',
  'across',
  'along',
  'around',
};
const _additivePunctuationWarningsV3 = <String>{
  'surface_possible_antecedent_possessive_separation',
  'surface_parallel_list_item_separation',
  'quote_edge_attribution_only_tail',
};
const _additiveWeakPunctuationWarningsV3 = _additivePunctuationWarningsV3;
const _additiveRelativeFrontWarningsV3 = <String>{
  'surface_nominal_relative_pronoun_separation',
  'surface_relative_marker_subject_separation',
};
const _additiveStructuralWarningsV3 = <String>{
  'surface_possible_antecedent_possessive_separation',
  'surface_preposition_attachment_separation',
  'surface_preposition_right_operand_separation',
  'surface_quantifier_numeral_separation',
  'surface_predicate_possessive_object_separation',
  'surface_relative_marker_subject_separation',
  'surface_pronoun_predicate_separation',
  'surface_predicate_complement_marker_separation',
  'surface_coordinator_right_operand_separation',
  'surface_parallel_list_item_separation',
  'surface_determiner_head_separation',
  'surface_object_relation_separation',
  'surface_subject_predicate_relation_separation',
  'surface_infinitive_marker_predicate_separation',
  'surface_adjective_infinitive_complement_separation',
  'surface_possessive_head_separation',
  'surface_fixed_connector_separation',
  'surface_modifier_head_separation',
  'surface_participial_modifier_separation',
  'surface_internal_nominal_coordinator_separation',
  'surface_short_nominal_coordinator_tail',
  'surface_mixed_coordinator_chain_separation',
  'surface_nominal_relative_pronoun_separation',
  'surface_adverb_attachment_separation',
  'surface_xcomp_predicate_separation',
  'surface_auxiliary_adverb_complement_separation',
  'surface_predicate_adverbial_complement_separation',
  'surface_auxiliary_predicate_separation',
  'surface_nested_nominal_preposition_separation',
  'surface_object_predicative_complement_separation',
  'surface_copula_predicative_separation',
  'surface_adverb_coordinator_separation',
  'surface_adverb_coordinator_right_operand_separation',
  'quote_edge_attribution_only_tail',
};
