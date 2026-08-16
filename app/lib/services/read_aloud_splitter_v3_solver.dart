part of 'read_aloud_splitter_v3.dart';

class _SourceWordV3 {
  _SourceWordV3(this.text, this.start, this.end);

  final String text;
  final int start;
  final int end;
  final Set<String> upos = <String>{};
  final Set<String> dependencyRelations = <String>{};
  int? strongPausePrefixCount;
  int? quotedSpeechSpanIndex;
  int? quotedSpeechWordCount;
  int? quotedSpeechStartWord;
  int? quotedSpeechEndWord;
  int? parentheticalSpanIndex;
  int? parentheticalWordCount;
  int? parentheticalStartWord;
  int? parentheticalEndWord;
}

extension on Iterable<_MappedDependencyV3> {
  bool hasAnyUpos(Set<String> values) =>
      any((dependency) => values.contains(dependency.token.upos));
}

class _QuoteSpanV3 {
  const _QuoteSpanV3({
    required this.index,
    required this.start,
    required this.end,
    required this.wordCount,
  });

  final int index;
  final int start;

  /// Exclusive offset immediately after the matching closing quote.
  final int end;
  final int wordCount;
}

class _ParenSpanV3 {
  const _ParenSpanV3({
    required this.index,
    required this.start,
    required this.end,
    required this.wordCount,
    required this.nestingDepth,
  });

  final int index;
  final int start;

  /// Exclusive offset immediately after the matching closing parenthesis.
  final int end;
  final int wordCount;

  /// 1 = outermost matched pair in the nesting stack at close time.
  final int nestingDepth;
}

class _MappedDependencyV3 {
  const _MappedDependencyV3({
    required this.token,
    required this.wordIndex,
    required this.headWordIndex,
  });

  final DependencyTokenV3 token;
  final int wordIndex;
  final int? headWordIndex;
}

class _SentenceFactsV3 {
  const _SentenceFactsV3({
    required this.words,
    required this.boundaryCandidates,
    required this.additiveBoundaryFacts,
    required this.mappingIssues,
  });

  final List<_SourceWordV3> words;
  final List<ReadAloudBoundaryCandidateV3> boundaryCandidates;
  final List<_AdditiveBoundaryFactV3> additiveBoundaryFacts;
  final List<String> mappingIssues;
}

class _CandidatePathRoundsV3 {
  const _CandidatePathRoundsV3({
    required this.initial,
    required this.expanded,
  });

  final List<ReadAloudCandidatePathV3> initial;
  final List<ReadAloudCandidatePathV3> expanded;
}

/// Canonical native V3 sentence planner.
///
/// The V3 identifiers are intentionally retained for storage compatibility.
/// This implementation is syntax-based and must not acquire project semantic
/// word lists. A parser defect is fixed in the parser/model or generic UD
/// handling, never by adding a word, character name, or book-specific phrase.
final class _ReadAloudSplitterEngineV3 {
  static const hardMaxWords = ReadAloudSplitterV3.hardMaxWords;
  static const preferredMaxUnpunctuatedWords =
      ReadAloudSplitterV3.preferredMaxUnpunctuatedWords;
  static const targetMaxUnpunctuatedWords =
      ReadAloudSplitterV3.targetMaxUnpunctuatedWords;
  static const hardMaxUnpunctuatedWords =
      ReadAloudSplitterV3.hardMaxUnpunctuatedWords;
  static const defaultFontSizePx = ReadAloudSplitterV3.defaultFontSizePx;
  static const defaultMaxLineWidthPx =
      ReadAloudSplitterV3.defaultMaxLineWidthPx;

  static final RegExp _visiblePause = RegExp(r'[.!?…;:—–,]');
  static final RegExp _inlinePause = RegExp(r'[;:—–,]');
  static final RegExp _boundaryPause = RegExp(r'''[.!?…;:—–,]["'”’)}\]]*$''');
  static final RegExp _strongPunctuation =
      RegExp(r'''[.!?…;:—–]["'”’)}\]]*$''');
  static final RegExp _quotedTerminalPunctuation =
      RegExp(r'''[.!?…]["'”’)}\]]*$''');
  static final RegExp _commaPunctuation = RegExp(r''',["'”’)}\]]*$''');
  static final RegExp _openingQuote = RegExp(r'''^["'“‘]''');
  static final RegExp _whitespace = RegExp(r'\s+');
  static final RegExp _lexicalCharacter =
      RegExp(r'[\p{L}\p{N}]', unicode: true);
  static final RegExp _sourceToken = RegExp(r'\S+');
  static final RegExp _decimalDigit = RegExp(r'\d');
  static final RegExp _edgeLexemePattern = RegExp(r"[a-z]+(?:'[a-z]+)?");
  static final RegExp _nonTerminalTitleAbbreviation = RegExp(
    r'''(?:^|[\s"'“‘])(?:Mr|Mrs|Ms|Dr|Prof|Rev|Capt|Col|Gen|Lt|Sgt|St)\.$''',
    caseSensitive: false,
  );
  static double measureNunitoExtraBoldPx(
    String text, {
    double fontSizePx = defaultFontSizePx,
  }) =>
      ReadAloudDisplayMetrics.measureNunitoExtraBoldPx(
        text,
        fontSizePx: fontSizePx,
      );

  static bool fitsEnglishLine(String text) =>
      measureNunitoExtraBoldPx(text) <= defaultMaxLineWidthPx;

  static int wordCount(String text) => _sourceWords(text).length;

  /// Merges every 1-English-word read-aloud chunk into a neighbor.
  ///
  /// For each singleton, only the local window `[prev, one, next]` is touched:
  /// attach a complete quoted utterance to its following attribution; otherwise
  /// try previous (if any) when `<= 30` words, then next. If both
  /// adjacent chunks are already at the hard maximum, move only the immediately
  /// adjacent word so `30/1` becomes `29/2` (and `30/1/30` becomes
  /// `29/2/30`). No later boundary is cascaded or recomputed.
  static List<String> mergeOneWordChunks(List<String> segments) {
    if (segments.isEmpty) {
      return const [];
    }
    if (segments.length == 1) {
      return List<String>.unmodifiable(segments);
    }
    final result = List<String>.from(segments);
    var index = 0;
    while (index < result.length) {
      if (wordCount(result[index]) != 1) {
        index += 1;
        continue;
      }
      if (result.length == 1) {
        break;
      }
      final hasPrev = index > 0;
      final hasNext = index + 1 < result.length;
      final one = result[index];

      if (hasNext &&
          _openingQuote.hasMatch(one) &&
          _quotedTerminalPunctuation.hasMatch(one)) {
        final joinedNext = _joinChunks(one, result[index + 1]);
        if (wordCount(joinedNext) <= hardMaxWords) {
          result[index] = joinedNext;
          result.removeAt(index + 1);
          continue;
        }
      }
      if (hasPrev) {
        final joinedPrev = _joinChunks(result[index - 1], one);
        if (wordCount(joinedPrev) <= hardMaxWords) {
          result[index - 1] = joinedPrev;
          result.removeAt(index);
          continue;
        }
      }
      if (hasNext) {
        final joinedNext = _joinChunks(one, result[index + 1]);
        if (wordCount(joinedNext) <= hardMaxWords) {
          result[index] = joinedNext;
          result.removeAt(index + 1);
          continue;
        }
      }

      final windowStart = hasPrev ? index - 1 : index;
      final windowEnd = hasNext ? index + 2 : index + 1;
      final repaired = _resolveOneWordWindow(
        result.sublist(windowStart, windowEnd),
      );
      result.replaceRange(windowStart, windowEnd, repaired);
      index = math.max(0, windowStart - 1);
    }

    if (result.length > 1 && result.any((chunk) => wordCount(chunk) == 1)) {
      throw StateError('1-word merge failed to eliminate a singleton');
    }
    if (result.any((chunk) => wordCount(chunk) > hardMaxWords)) {
      throw StateError('1-word merge exceeded the 30-word hard maximum');
    }
    return List<String>.unmodifiable(result);
  }

  static String _joinChunks(String left, String right) =>
      '$left $right'.replaceAll(_whitespace, ' ').trim();

  /// Repairs only the boundary immediately adjacent to a singleton. This is
  /// reached only when a direct merge would produce 31 words.
  static List<String> _resolveOneWordWindow(List<String> window) {
    final joined = window
        .map((chunk) => chunk.trim())
        .where((chunk) => chunk.isNotEmpty)
        .join(' ')
        .replaceAll(_whitespace, ' ')
        .trim();
    final words = _sourceWords(joined);
    final counts = window.map(wordCount).toList(growable: false);
    final singletonIndex = counts.indexOf(1);
    if (words.isEmpty || singletonIndex < 0) {
      throw StateError('Invalid one-word repair window');
    }
    if (counts.any((count) => count > hardMaxWords)) {
      throw StateError('One-word repair received an oversized neighbor');
    }

    final ends = <int>[];
    if (window.length == 2 && singletonIndex == 1 && counts[0] == 30) {
      ends.addAll([29, 31]);
    } else if (window.length == 2 && singletonIndex == 0 && counts[1] == 30) {
      ends.addAll([2, 31]);
    } else if (window.length == 3 &&
        singletonIndex == 1 &&
        counts[0] == 30 &&
        counts[2] == 30) {
      // Prefer the previous chunk, matching the ordinary direct-merge rule.
      ends.addAll([29, 31, 61]);
    } else {
      throw StateError('Unsupported one-word repair window: $counts');
    }

    final output = <String>[];
    var start = 0;
    for (final end in ends) {
      output.add(_segmentText(joined, words, start, end));
      start = end;
    }
    return output;
  }

  static int maxUnpunctuatedWordCount(String text) {
    var run = 0;
    var maximum = 0;
    for (final word in _sourceWords(text)) {
      run += 1;
      if (run > maximum) maximum = run;
      if (_visiblePause.hasMatch(word.text)) run = 0;
    }
    return maximum;
  }

  /// Stable, non-secret fingerprint used by prompt/cache/audit contracts.
  static String candidateSetHash(
    Iterable<ReadAloudCandidatePathV3> paths,
  ) {
    final payload = paths
        .map(
          (path) => jsonEncode({
            'id': path.pathId,
            'segments': path.segments,
            'score': path.score,
          }),
        )
        .join('\n');
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(payload)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static String normalizeForRoundTrip(String text) => text
      .replaceAll(RegExp(r'\r\n?'), '\n')
      .replaceAll(RegExp(r'[‐‑‒]'), '-')
      .replaceAllMapped(
        RegExp(r'([A-Za-z])\s+-\s+(?=[A-Za-z])'),
        (match) => '${match[1]}-',
      )
      .replaceAllMapped(
        RegExp(r'''([—–])(?=[^\s"'”’])'''),
        (match) => '${match[1]} ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAllMapped(
        RegExp(r'([.!?])\s+-(?=[A-Za-z])'),
        (match) => '${match[1]}-',
      )
      .replaceAll(RegExp(r'-\s+'), '-')
      .replaceAllMapped(RegExp(r'([—–])\s+'), (match) => match[1] ?? '')
      .trim();

  /// Compares reviewed sentence blocks with their source while allowing only
  /// whitespace that is introduced or removed at a sentence boundary.
  /// Whitespace and text inside each sentence remain significant.
  static bool isRoundTripEquivalent({
    required String englishContent,
    required List<String> sentences,
  }) =>
      _roundTripMismatch(
        englishContent: englishContent,
        sentences: sentences,
      ) ==
      null;

  static String? _roundTripMismatch({
    required String englishContent,
    required List<String> sentences,
  }) {
    final source = normalizeForRoundTrip(englishContent);
    var cursor = 0;
    for (var index = 0; index < sentences.length; index += 1) {
      final sentence = normalizeForRoundTrip(sentences[index]);
      if (index > 0) {
        final boundaryStart = cursor;
        while (
            cursor < source.length && RegExp(r'\s').hasMatch(source[cursor])) {
          cursor += 1;
        }
        if (cursor == boundaryStart &&
            _isLexicalRoundTripBoundary(source, cursor)) {
          return '第 ${index + 1} 块的句界落在词或缩写内部（正文偏移 $cursor）';
        }
      }
      if (!source.startsWith(sentence, cursor)) {
        final sourceEnd = math.min(source.length, cursor + 120);
        final expectedEnd = math.min(sentence.length, 120);
        return '第 ${index + 1} 块从正文偏移 $cursor 开始不一致；'
            '块=${jsonEncode(sentence.substring(0, expectedEnd))}；'
            '正文=${jsonEncode(source.substring(cursor, sourceEnd))}';
      }
      cursor += sentence.length;
    }
    while (cursor < source.length && RegExp(r'\s').hasMatch(source[cursor])) {
      cursor += 1;
    }
    if (cursor != source.length) {
      final sourceEnd = math.min(source.length, cursor + 120);
      return '末块后仍有正文（偏移 $cursor）；'
          '正文=${jsonEncode(source.substring(cursor, sourceEnd))}';
    }
    return null;
  }

  static bool _isLexicalRoundTripBoundary(String source, int offset) {
    if (offset <= 0 || offset >= source.length) return false;
    bool isAlphaNumeric(String value) =>
        RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(value);
    bool isJoiner(String value) => const {"'", '’', '-'}.contains(value);

    final left = source[offset - 1];
    final right = source[offset];
    final leftContinuesWord = isAlphaNumeric(left) ||
        isJoiner(left) && offset >= 2 && isAlphaNumeric(source[offset - 2]);
    final rightContinuesWord = isAlphaNumeric(right) ||
        isJoiner(right) &&
            offset + 1 < source.length &&
            isAlphaNumeric(source[offset + 1]);
    return leftContinuesWord && rightContinuesWord;
  }

  static ReadAloudSplitPlanV3 plan({
    required String source,
    required DependencyDocumentV3 document,
  }) {
    if (source.trim().isEmpty) {
      throw const FormatException('V3 分句正文不能为空');
    }
    _validateDocument(source, document);
    final quoteSpans = _matchedQuoteSpans(source);
    final parenScan = _scanParentheticalSpans(source);
    final parenSpans = parenScan.spans;
    final parserSentences = _coalesceParserSentencesInsideMatchedDelimiters(
      source,
      _coalesceNonTerminalAbbreviationSentences(
        source,
        document.sentences,
      ),
      quoteSpans,
      parenSpans,
    );
    final originals = <ReadAloudOriginalDecisionV3>[];
    var sentenceFactBuilds = 0;
    var dagSolves = 0;
    for (var index = 0; index < parserSentences.length; index += 1) {
      final parsedSentence = parserSentences[index];
      final parsedSource = source.substring(
        parsedSentence.start,
        parsedSentence.end,
      );
      if (!_lexicalCharacter.hasMatch(parsedSource)) continue;

      var sentenceStart = parsedSentence.start;
      if (originals.isEmpty &&
          source.substring(0, sentenceStart).trim().isNotEmpty) {
        sentenceStart = 0;
      }
      var sentenceEnd = parsedSentence.end;
      for (var trailingIndex = index + 1;
          trailingIndex < parserSentences.length;
          trailingIndex += 1) {
        final trailing = parserSentences[trailingIndex];
        final trailingSource = source.substring(trailing.start, trailing.end);
        if (_sourceWords(trailingSource).isNotEmpty) break;
        sentenceEnd = trailing.end;
      }
      final sentenceSource = source.substring(sentenceStart, sentenceEnd);
      final facts = _buildSentenceFacts(
        sentenceSource: sentenceSource,
        parsedSentence: parsedSentence,
        sentenceStart: sentenceStart,
        quoteSpans: quoteSpans,
        parenSpans: parenSpans,
      );
      sentenceFactBuilds += 1;
      final ranked = const _AdditiveReadAloudLatticeV3().solve(
        source: sentenceSource,
        words: facts.words,
        boundaryFacts: facts.additiveBoundaryFacts,
      );
      dagSolves += 1;
      final pathRounds = _materializeAdditivePathsV3(
        originalIndex: index,
        ranked: ranked,
      );
      if (pathRounds.initial.isEmpty || pathRounds.expanded.isEmpty) {
        throw FormatException('V3 分句无法为第 ${index + 1} 个原句生成可行路径');
      }
      originals.add(
        ReadAloudOriginalDecisionV3(
          originalIndex: index,
          source: sentenceSource,
          sourceStart: sentenceStart,
          sourceEnd: sentenceEnd,
          parserHealthy: document.healthy && facts.mappingIssues.isEmpty,
          parserIssues: List.unmodifiable([
            ...document.issues,
            ...parenScan.issues,
            ...facts.mappingIssues,
          ]),
          initialCandidatePaths: List.unmodifiable(pathRounds.initial),
          expandedCandidatePaths: List.unmodifiable(pathRounds.expanded),
          boundaryCandidates: List.unmodifiable(facts.boundaryCandidates),
          localPathId: pathRounds.initial.first.pathId,
          parseCost: parsedSentence.parseCost,
          parseCostPerToken: parsedSentence.parseCostPerToken,
        ),
      );
    }
    final plan = ReadAloudSplitPlanV3(
      parserVersion: document.parserVersion,
      modelSha256: document.modelSha256,
      parserHealthy: document.healthy &&
          originals.every((decision) => decision.parserHealthy),
      parserIssues: List.unmodifiable([
        ...document.issues,
        ...parenScan.issues,
      ]),
      originals: List.unmodifiable(originals),
      counters: ReadAloudSolverCountersV3(
        sentenceFactBuilds: sentenceFactBuilds,
        dagSolves: dagSolves,
      ),
    );
    final mergedSentences = plan.localSentences;
    validateReviewedSentences(
      source,
      mergedSentences,
      rejectOneWordChunks: true,
      requiredBoundaryWordOffsets: requiredBoundaryWordOffsetsAfterMerge(plan),
    );
    return plan;
  }

  static _SentenceFactsV3 _buildSentenceFacts({
    required String sentenceSource,
    required DependencySentenceV3 parsedSentence,
    required int sentenceStart,
    required List<_QuoteSpanV3> quoteSpans,
    required List<_ParenSpanV3> parenSpans,
  }) {
    final words = _sourceWords(sentenceSource);
    _annotateQuotedSpeechWords(
      words,
      quoteSpans,
      sentenceStart: sentenceStart,
    );
    _annotateParentheticalWords(
      words,
      parenSpans,
      sentenceStart: sentenceStart,
    );
    final mapped = _mapDependencies(
      parsedSentence,
      words,
      sentenceStart: sentenceStart,
    );
    for (final dependency in mapped) {
      words[dependency.wordIndex]
        ..upos.add(dependency.token.upos)
        ..dependencyRelations.add(
          dependency.token.deprel.split(':').first,
        );
    }
    final rawCandidates = _boundaryCandidates(
      sentenceSource,
      words,
      mapped,
      sentenceStart: sentenceStart,
      parserTokens: parsedSentence.tokens,
      quoteSpans: quoteSpans,
      parenSpans: parenSpans,
    );
    final dependencyFacts = _buildDependencyGapFactsV3(
      words: words,
      sentence: parsedSentence,
      mapped: mapped,
    );
    final candidates = _normalizeStableSyntaxCandidatesV3(
      rawCandidates,
      words: words,
      dependencyFacts: dependencyFacts,
    );
    return _SentenceFactsV3(
      words: List.unmodifiable(words),
      boundaryCandidates: List.unmodifiable(candidates),
      additiveBoundaryFacts: List.unmodifiable(
        _buildAdditiveBoundaryFactsV3(
          source: sentenceSource,
          words: words,
          candidates: candidates,
          dependencyFacts: dependencyFacts,
        ),
      ),
      mappingIssues: List.unmodifiable([
        if (mapped.length != parsedSentence.tokens.length)
          'dependency_token_offset_mapping_incomplete',
      ]),
    );
  }

  /// Orthographic original ends that survive the deterministic one-word merge.
  /// The result is derived from selected candidate paths, not from caller-
  /// supplied final sentences, so validation cannot silently waive an arbitrary
  /// parser boundary.
  static List<int> requiredBoundaryWordOffsetsAfterMerge(
      ReadAloudSplitPlanV3 plan,
      [Map<int, String> selectedPathIds = const {}]) {
    final beforeMerge = selectedSentencesBeforePostProcessing(
      plan,
      selectedPathIds,
    );
    return _survivingRequiredBoundaryOffsets(
      plan.originals,
      mergeOneWordChunks(beforeMerge),
    );
  }

  static void validateSelectedPathIds(
    ReadAloudSplitPlanV3 plan,
    Map<int, String> selectedPathIds,
  ) {
    for (final decision in plan.originals) {
      final selected = selectedPathIds[decision.originalIndex];
      if (selected == null) continue;
      if (!decision.candidatePaths.any((path) => path.pathId == selected)) {
        throw FormatException(
          'AI 为原句 ${decision.originalIndex} 返回了未提供的 candidatePathId',
        );
      }
    }
  }

  static List<String> applySelectedPathIds(
    ReadAloudSplitPlanV3 plan,
    Map<int, String> selectedPathIds,
  ) =>
      mergeOneWordChunks(
        selectedSentencesBeforePostProcessing(plan, selectedPathIds),
      );

  static List<String> selectedSentencesBeforePostProcessing(
    ReadAloudSplitPlanV3 plan,
    Map<int, String> selectedPathIds,
  ) {
    validateSelectedPathIds(plan, selectedPathIds);
    return List.unmodifiable(
      plan.originals.expand((decision) {
        final selected =
            selectedPathIds[decision.originalIndex] ?? decision.localPathId;
        return decision.candidatePaths
            .firstWhere((path) => path.pathId == selected)
            .segments;
      }),
    );
  }

  static void _validateDocument(
    String source,
    DependencyDocumentV3 document,
  ) {
    if (document.parserVersion.trim().isEmpty ||
        document.modelSha256.trim().isEmpty) {
      throw const FormatException('句法器版本与模型 SHA-256 不能为空');
    }
    if (document.sentences.isEmpty) {
      throw const FormatException('句法器没有返回原文正字句');
    }
    var cursor = 0;
    for (var index = 0; index < document.sentences.length; index += 1) {
      final sentence = document.sentences[index];
      if (sentence.start < cursor ||
          sentence.end <= sentence.start ||
          sentence.end > source.length) {
        throw FormatException('句法器第 ${index + 1} 个句子 offset 非法');
      }
      if (source.substring(cursor, sentence.start).trim().isNotEmpty) {
        throw FormatException('句法器在第 ${index + 1} 个句子前遗漏了正文');
      }
      cursor = sentence.end;
      var lastTokenStart = sentence.start;
      final tokenIds = <int>{};
      for (final token in sentence.tokens) {
        if (token.id <= 0 ||
            !tokenIds.add(token.id) ||
            token.start < sentence.start ||
            token.end <= token.start ||
            token.end > sentence.end ||
            token.start < lastTokenStart ||
            source.substring(token.start, token.end) !=
                (token.sourceText ?? token.text)) {
          throw FormatException('句法器第 ${index + 1} 个句子的 token offset 非法');
        }
        // Multiword tokens can give several UD words the same exact source
        // range. Only start-order is required; sourceText preserves the
        // original span while text remains the parser form.
        lastTokenStart = token.start;
      }
      for (final token in sentence.tokens) {
        if (token.head < 0 ||
            token.head == token.id ||
            (token.head != 0 && !tokenIds.contains(token.head))) {
          throw FormatException('句法器第 ${index + 1} 个句子的依存 head 非法');
        }
      }
    }
    if (source.substring(cursor).trim().isNotEmpty) {
      throw const FormatException('句法器在末句后遗漏了正文');
    }
  }

  /// UDPipe occasionally treats the period in an English title abbreviation
  /// as an orthographic sentence end (for example `"Mr.` / `Toad ...`). Such
  /// a boundary is inside the name, not a valid subtitle or read-aloud cut.
  /// Rejoin only that parser false boundary. Quote-aware coalescing is applied
  /// separately after this parser repair.
  static List<DependencySentenceV3> _coalesceNonTerminalAbbreviationSentences(
    String source,
    List<DependencySentenceV3> sentences,
  ) {
    final output = <DependencySentenceV3>[];
    var index = 0;
    while (index < sentences.length) {
      final group = <DependencySentenceV3>[sentences[index]];
      while (index + 1 < sentences.length &&
          _nonTerminalTitleAbbreviation.hasMatch(
            source.substring(group.first.start, group.last.end).trimRight(),
          )) {
        index += 1;
        group.add(sentences[index]);
      }
      output.add(_coalesceDependencySentenceGroup(group));
      index += 1;
    }
    return List.unmodifiable(output);
  }

  static DependencySentenceV3 _coalesceDependencySentenceGroup(
    List<DependencySentenceV3> group,
  ) {
    if (group.length == 1) return group.single;

    final tokens = <DependencyTokenV3>[];
    double? parseCost = 0;
    for (final sentence in group) {
      if (sentence.parseCost == null) parseCost = null;
      if (parseCost != null) parseCost += sentence.parseCost!;

      final nextIdByOldId = <int, int>{};
      for (final token in sentence.tokens) {
        nextIdByOldId[token.id] = tokens.length + nextIdByOldId.length + 1;
      }
      for (final token in sentence.tokens) {
        tokens.add(
          DependencyTokenV3(
            id: nextIdByOldId[token.id]!,
            text: token.text,
            start: token.start,
            end: token.end,
            upos: token.upos,
            head: token.head == 0 ? 0 : nextIdByOldId[token.head]!,
            deprel: token.deprel,
            sourceText: token.sourceText,
          ),
        );
      }
    }
    final parseCostPerToken =
        parseCost == null || tokens.isEmpty ? null : parseCost / tokens.length;
    return DependencySentenceV3(
      start: group.first.start,
      end: group.last.end,
      tokens: List.unmodifiable(tokens),
      parseCost: parseCost,
      parseCostPerToken: parseCostPerToken,
    );
  }

  /// Keeps UDPipe's orthographic analysis intact while allowing the read-aloud
  /// solver to compare delimiter-internal and delimiter-external cuts in one
  /// lattice. Only parser boundaries strictly inside a fully matched quote or
  /// parenthetical span are joined.
  static List<DependencySentenceV3>
      _coalesceParserSentencesInsideMatchedDelimiters(
    String source,
    List<DependencySentenceV3> sentences,
    List<_QuoteSpanV3> quoteSpans,
    List<_ParenSpanV3> parenSpans,
  ) {
    final output = <DependencySentenceV3>[];
    var index = 0;
    while (index < sentences.length) {
      final group = <DependencySentenceV3>[sentences[index]];
      while (index + 1 < sentences.length) {
        final boundary = group.last.end;
        final liesInsideMatchedDelimiter = quoteSpans.any(
              (span) => boundary > span.start && boundary < span.end - 1,
            ) ||
            parenSpans.any(
              (span) => boundary > span.start && boundary < span.end - 1,
            );
        if (!liesInsideMatchedDelimiter) break;
        index += 1;
        group.add(sentences[index]);
      }
      output.add(_coalesceDependencySentenceGroup(group));
      index += 1;
    }
    return List.unmodifiable(output);
  }

  /// Finds straight and curly double-quoted speech within each paragraph.
  /// Unmatched quote state is deliberately discarded at paragraph breaks so a
  /// malformed or poetic paragraph cannot absorb later parser sentences.
  static List<_QuoteSpanV3> _matchedQuoteSpans(String source) {
    final spans = <_QuoteSpanV3>[];
    final paragraphBreak = RegExp(r'(?:\r?\n)[ \t]*(?:\r?\n)+');
    var paragraphStart = 0;
    final straightOpenings = <int>[];
    final curlyOpenings = <int>[];

    void scanParagraph(int start, int end) {
      final carriedStraightOpening = straightOpenings.isNotEmpty;
      final carriedCurlyOpening = curlyOpenings.isNotEmpty;
      var sawStraightQuote = false;
      var sawCurlyQuote = false;
      for (var offset = start; offset < end; offset += 1) {
        final character = source[offset];
        if (character == '"') {
          final opens = _straightQuoteOpens(
            source,
            offset,
            paragraphStart: start,
            paragraphEnd: end,
            hasUnclosedQuote: straightOpenings.isNotEmpty,
          );
          if (!sawStraightQuote && carriedStraightOpening && opens) {
            // A new paragraph that starts another quotation does not close an
            // abandoned opening from earlier prose. A closing mark may still
            // complete a quote whose visual layout spans blank lines.
            straightOpenings.clear();
          }
          sawStraightQuote = true;
          if (opens) {
            straightOpenings.add(offset);
          } else if (straightOpenings.isNotEmpty) {
            final straightOpening = straightOpenings.removeLast();
            spans.add(
              _QuoteSpanV3(
                index: spans.length,
                start: straightOpening,
                end: offset + 1,
                wordCount:
                    wordCount(source.substring(straightOpening, offset + 1)),
              ),
            );
          }
        } else if (character == '“') {
          if (!sawCurlyQuote && carriedCurlyOpening) {
            curlyOpenings.clear();
          }
          sawCurlyQuote = true;
          curlyOpenings.add(offset);
        } else if (character == '”' && curlyOpenings.isNotEmpty) {
          sawCurlyQuote = true;
          final curlyOpening = curlyOpenings.removeLast();
          spans.add(
            _QuoteSpanV3(
              index: spans.length,
              start: curlyOpening,
              end: offset + 1,
              wordCount: wordCount(source.substring(curlyOpening, offset + 1)),
            ),
          );
        }
      }
    }

    for (final match in paragraphBreak.allMatches(source)) {
      scanParagraph(paragraphStart, match.start);
      paragraphStart = match.end;
    }
    scanParagraph(paragraphStart, source.length);
    spans.sort((left, right) => left.start.compareTo(right.start));
    return List.unmodifiable([
      for (var index = 0; index < spans.length; index += 1)
        _QuoteSpanV3(
          index: index,
          start: spans[index].start,
          end: spans[index].end,
          wordCount: spans[index].wordCount,
        ),
    ]);
  }

  /// Classifies an ASCII double quote from its surface context instead of
  /// blindly alternating open/close state. Gutenberg prose can begin with the
  /// closing mark of speech started in an omitted paragraph, and can contain
  /// same-mark nested song quotations such as `returns—"Lest ...`. Alternation
  /// would shift every later quote in that paragraph and leave real short
  /// speech unprotected.
  static bool _straightQuoteOpens(
    String source,
    int offset, {
    required int paragraphStart,
    required int paragraphEnd,
    required bool hasUnclosedQuote,
  }) {
    if (offset <= paragraphStart) return true;
    if (offset + 1 >= paragraphEnd) return false;

    final previous = source[offset - 1];
    final next = source[offset + 1];
    final previousIsSpace = previous.trim().isEmpty;
    final nextIsSpace = next.trim().isEmpty;

    // `...!"  "Next...` is a closing mark followed by an opening mark.
    if (!previousIsSpace && nextIsSpace) return false;
    if (previousIsSpace && !nextIsSpace) return true;
    if (next == '"') return false;
    if (previous == '"') return true;

    // Narration commonly introduces speech after a colon or dash. A dash on
    // the right, by contrast, normally continues narration after a closing
    // quote: `song"—then`.
    if ('([{<:—–'.contains(previous)) return true;
    if (')]}>.。,!?;—–'.contains(next)) return false;
    if ('.。,!?;'.contains(previous)) return false;

    // Only genuinely ambiguous word-adjacent marks fall back to stack state.
    return !hasUnclosedQuote;
  }

  static void _annotateQuotedSpeechWords(
    List<_SourceWordV3> words,
    List<_QuoteSpanV3> quoteSpans, {
    required int sentenceStart,
  }) {
    final firstWordBySpan = <int, int>{};
    final lastWordBySpan = <int, int>{};
    final wordCountBySpan = <int, int>{};
    for (var wordIndex = 0; wordIndex < words.length; wordIndex += 1) {
      final word = words[wordIndex];
      final lexical =
          RegExp(r'[\p{L}\p{N}]', unicode: true).firstMatch(word.text);
      if (lexical == null) continue;
      final lexicalOffset = sentenceStart + word.start + lexical.start;
      final span = _innermostQuoteSpanAtOffset(quoteSpans, lexicalOffset);
      if (span == null) continue;
      word.quotedSpeechSpanIndex = span.index;
      firstWordBySpan.putIfAbsent(span.index, () => wordIndex);
      lastWordBySpan[span.index] = wordIndex + 1;
      wordCountBySpan.update(span.index, (count) => count + 1,
          ifAbsent: () => 1);
    }
    for (final word in words) {
      final spanIndex = word.quotedSpeechSpanIndex;
      if (spanIndex == null) continue;
      word.quotedSpeechWordCount = wordCountBySpan[spanIndex];
      word.quotedSpeechStartWord = firstWordBySpan[spanIndex];
      word.quotedSpeechEndWord = lastWordBySpan[spanIndex];
    }
  }

  static void _annotateParentheticalWords(
    List<_SourceWordV3> words,
    List<_ParenSpanV3> parenSpans, {
    required int sentenceStart,
  }) {
    final firstWordBySpan = <int, int>{};
    final lastWordBySpan = <int, int>{};
    final wordCountBySpan = <int, int>{};
    for (var wordIndex = 0; wordIndex < words.length; wordIndex += 1) {
      final word = words[wordIndex];
      final lexical =
          RegExp(r'[\p{L}\p{N}]', unicode: true).firstMatch(word.text);
      if (lexical == null) continue;
      final lexicalOffset = sentenceStart + word.start + lexical.start;
      final span = _innermostParenSpanAtOffset(parenSpans, lexicalOffset);
      if (span == null) continue;
      word.parentheticalSpanIndex = span.index;
      firstWordBySpan.putIfAbsent(span.index, () => wordIndex);
      lastWordBySpan[span.index] = wordIndex + 1;
      wordCountBySpan.update(span.index, (count) => count + 1,
          ifAbsent: () => 1);
    }
    for (final word in words) {
      final spanIndex = word.parentheticalSpanIndex;
      if (spanIndex == null) continue;
      word.parentheticalWordCount = wordCountBySpan[spanIndex];
      word.parentheticalStartWord = firstWordBySpan[spanIndex];
      word.parentheticalEndWord = lastWordBySpan[spanIndex];
    }
  }

  static _QuoteSpanV3? _innermostQuoteSpanAtOffset(
    List<_QuoteSpanV3> quoteSpans,
    int offset,
  ) {
    _QuoteSpanV3? result;
    for (final span in quoteSpans) {
      if (offset <= span.start || offset >= span.end - 1) continue;
      if (result == null ||
          span.start >= result.start && span.end <= result.end) {
        result = span;
      }
    }
    return result;
  }

  /// Stack-matched nestable `(...)` spans. Matching is paragraph-local:
  /// unmatched opens are audited and discarded at a paragraph break, and an
  /// unmatched close is audited without manufacturing a span.
  static ({List<_ParenSpanV3> spans, List<String> issues})
      _scanParentheticalSpans(String source) {
    final spans = <({int start, int end, int wordCount, int nestingDepth})>[];
    final issues = <String>[];
    final paragraphBreak = RegExp(r'(?:\r?\n)[ \t]*(?:\r?\n)+');

    void scanParagraph(int start, int end) {
      final openings = <int>[];
      for (var offset = start; offset < end; offset += 1) {
        final character = source[offset];
        if (character == '(') {
          openings.add(offset);
        } else if (character == ')') {
          if (openings.isEmpty) {
            issues.add('unmatched_parenthesis_close:$offset');
            continue;
          }
          final nestingDepth = openings.length;
          final opening = openings.removeLast();
          spans.add(
            (
              start: opening,
              end: offset + 1,
              wordCount: wordCount(source.substring(opening, offset + 1)),
              nestingDepth: nestingDepth,
            ),
          );
        }
      }
      for (final opening in openings) {
        issues.add('unmatched_parenthesis_open:$opening');
      }
    }

    var paragraphStart = 0;
    for (final match in paragraphBreak.allMatches(source)) {
      scanParagraph(paragraphStart, match.start);
      paragraphStart = match.end;
    }
    scanParagraph(paragraphStart, source.length);

    spans.sort((left, right) => left.start.compareTo(right.start));
    return (
      spans: List.unmodifiable([
        for (var index = 0; index < spans.length; index += 1)
          _ParenSpanV3(
            index: index,
            start: spans[index].start,
            end: spans[index].end,
            wordCount: spans[index].wordCount,
            nestingDepth: spans[index].nestingDepth,
          ),
      ]),
      issues: List.unmodifiable(issues),
    );
  }

  static _ParenSpanV3? _innermostParenSpanAtOffset(
    List<_ParenSpanV3> parenSpans,
    int offset,
  ) {
    _ParenSpanV3? result;
    for (final span in parenSpans) {
      if (offset <= span.start || offset >= span.end - 1) continue;
      if (result == null ||
          span.start >= result.start && span.end <= result.end) {
        result = span;
      }
    }
    return result;
  }

  static List<_SourceWordV3> _sourceWords(String sentence) {
    final words = <_SourceWordV3>[];
    final lexical = _lexicalCharacter;
    final startsLexical = RegExp(
      r'''^["'“‘(\[]*[\p{L}\p{N}]''',
      unicode: true,
    );
    int? pendingPunctuationStart;

    void appendPart(int start, int end) {
      if (start >= end) return;
      final text = sentence.substring(start, end);
      if (lexical.hasMatch(text)) {
        final effectiveStart = pendingPunctuationStart ?? start;
        pendingPunctuationStart = null;
        words.add(
          _SourceWordV3(
            sentence.substring(effectiveStart, end),
            effectiveStart,
            end,
          ),
        );
        return;
      }
      if (words.isNotEmpty) {
        final previous = words.removeLast();
        words.add(
          _SourceWordV3(
            sentence.substring(previous.start, end),
            previous.start,
            end,
          ),
        );
      } else {
        pendingPunctuationStart ??= start;
      }
    }

    for (final match in _sourceToken.allMatches(sentence)) {
      final token = match.group(0)!;
      var partStart = 0;
      for (var offset = 0; offset + 1 < token.length; offset += 1) {
        final punctuation = token[offset];
        // Also split glued terminals before a following capital
        // (`jurors."She` → `jurors."` | `She`) so quote-close stays a cut.
        final isTerminalBeforeLexical =
            RegExp(r'''[.!?…]''').hasMatch(punctuation);
        if (!(_inlinePause.hasMatch(punctuation) || isTerminalBeforeLexical) ||
            !startsLexical.hasMatch(token.substring(offset + 1))) {
          continue;
        }
        final previous = offset > 0 ? token[offset - 1] : '';
        final next = token[offset + 1];
        if (const {',', ':', '.'}.contains(punctuation) &&
            _decimalDigit.hasMatch(previous) &&
            _decimalDigit.hasMatch(next)) {
          continue;
        }
        var partEnd = offset + 1;
        if (punctuation != ':' &&
            partEnd < token.length &&
            _isClosingQuoteAt(sentence, match.start + partEnd)) {
          partEnd += 1;
        }
        appendPart(match.start + partStart, match.start + partEnd);
        partStart = partEnd;
        offset = partEnd - 1;
      }
      appendPart(match.start + partStart, match.end);
    }
    return words;
  }

  static bool _isClosingQuoteAt(String source, int offset) {
    final mark = source[offset];
    if (mark == '”' || mark == '’') return true;
    if (mark != '"') return false;
    var earlierDoubleQuotes = 0;
    for (var index = 0; index < offset; index += 1) {
      if (source[index] == '"') earlierDoubleQuotes += 1;
    }
    return earlierDoubleQuotes.isOdd;
  }

  static List<_MappedDependencyV3> _mapDependencies(
    DependencySentenceV3 sentence,
    List<_SourceWordV3> words, {
    required int sentenceStart,
  }) {
    final wordByTokenId = <int, int>{};
    for (final token in sentence.tokens) {
      final relativeStart = token.start - sentenceStart;
      final relativeEnd = token.end - sentenceStart;
      var wordIndex = words.indexWhere(
        (word) => relativeStart >= word.start && relativeEnd <= word.end,
      );
      if (wordIndex < 0) {
        // UDPipe can keep leading inline punctuation with the lexical token
        // after it (for example `—everything`). The subtitle word lattice
        // deliberately puts the dash on the left chunk, so that parser token
        // spans two lattice words. Attribute it to the word with the greatest
        // alphanumeric overlap; on a tie prefer the word after the pause.
        var bestLexicalOverlap = -1;
        var bestRawOverlap = 0;
        for (var index = 0; index < words.length; index += 1) {
          final word = words[index];
          final overlapStart = math.max(relativeStart, word.start);
          final overlapEnd = math.min(relativeEnd, word.end);
          if (overlapStart >= overlapEnd) continue;
          final overlap = word.text.substring(
            overlapStart - word.start,
            overlapEnd - word.start,
          );
          final lexicalOverlap = RegExp(
            r'[\p{L}\p{N}]',
            unicode: true,
          ).allMatches(overlap).length;
          if (lexicalOverlap > bestLexicalOverlap ||
              lexicalOverlap == bestLexicalOverlap &&
                  overlap.length > bestRawOverlap ||
              lexicalOverlap == bestLexicalOverlap &&
                  overlap.length == bestRawOverlap &&
                  index > wordIndex) {
            bestLexicalOverlap = lexicalOverlap;
            bestRawOverlap = overlap.length;
            wordIndex = index;
          }
        }
      }
      if (wordIndex >= 0) wordByTokenId[token.id] = wordIndex;
    }
    return [
      for (final token in sentence.tokens)
        if (wordByTokenId[token.id] != null)
          _MappedDependencyV3(
            token: token,
            wordIndex: wordByTokenId[token.id]!,
            headWordIndex: token.head == 0 ? null : wordByTokenId[token.head],
          ),
    ];
  }

  static List<ReadAloudBoundaryCandidateV3> _boundaryCandidates(
    String sentence,
    List<_SourceWordV3> words,
    List<_MappedDependencyV3> dependencies, {
    required int sentenceStart,
    required List<DependencyTokenV3> parserTokens,
    required List<_QuoteSpanV3> quoteSpans,
    List<_ParenSpanV3> parenSpans = const [],
    bool applyParentheticalRules = true,
    bool classifyLocalIncompleteConstituents = true,
    bool classifySubjectlessCoordinatedPredicates = false,
  }) {
    final output = <ReadAloudBoundaryCandidateV3>[];
    for (var afterWord = 1; afterWord < words.length; afterWord += 1) {
      final left = words[afterWord - 1].text;
      final right = words[afterWord].text;
      final leftLexeme = _edgeLexeme(left);
      final rightLexeme = _edgeLexeme(right);
      final leftQuoteSpan = words[afterWord - 1].quotedSpeechSpanIndex;
      final rightQuoteSpan = words[afterWord].quotedSpeechSpanIndex;
      final leftParenSpan = applyParentheticalRules
          ? words[afterWord - 1].parentheticalSpanIndex
          : null;
      final rightParenSpan = applyParentheticalRules
          ? words[afterWord].parentheticalSpanIndex
          : null;
      final boundaryOffset = sentenceStart + words[afterWord - 1].end;
      final containingQuoteSpan =
          _innermostQuoteSpanAtOffset(quoteSpans, boundaryOffset);
      final containingParenSpan = applyParentheticalRules
          ? _innermostParenSpanAtOffset(parenSpans, boundaryOffset)
          : null;
      final insideQuotedSpeech = containingQuoteSpan != null;
      final insideParenthetical = containingParenSpan != null;
      final quoteSpanWordCount = containingQuoteSpan?.wordCount ??
          (leftQuoteSpan != null
              ? words[afterWord - 1].quotedSpeechWordCount
              : words[afterWord].quotedSpeechWordCount);
      final parenSpanWordCount = containingParenSpan?.wordCount ??
          (leftParenSpan != null
              ? words[afterWord - 1].parentheticalWordCount
              : words[afterWord].parentheticalWordCount);
      final quoteEdge = insideQuotedSpeech
          ? null
          : leftQuoteSpan != null && rightQuoteSpan != null
              ? 'between_quotes'
              : leftQuoteSpan != null
                  ? 'after_closing'
                  : rightQuoteSpan != null
                      ? 'before_opening'
                      : null;
      final parenEdge = insideParenthetical
          ? null
          : leftParenSpan != null && rightParenSpan != null
              ? 'between_parens'
              : leftParenSpan != null
                  ? 'after_closing'
                  : rightParenSpan != null
                      ? 'before_opening'
                      : null;
      final spanningTokens = parserTokens
          .where(
            (token) =>
                token.start < boundaryOffset && token.end > boundaryOffset,
          )
          .toList(growable: false);
      final hardBlockReasons = <String>[
        if (spanningTokens.isNotEmpty && !_boundaryPause.hasMatch(left))
          'inside_parser_token:${spanningTokens.map((token) => token.id).join(',')}',
        if (!_boundaryPause.hasMatch(left) &&
            const {'and', 'or', 'nor', 'but'}.contains(leftLexeme))
          'inside_coordinator_right_operand',
        if (!_boundaryPause.hasMatch(left) &&
            const {
              'a',
              'an',
              'the',
              'my',
              'your',
              'his',
              'her',
              'its',
              'our',
              'their',
              'whose',
            }.contains(leftLexeme))
          'inside_surface_determiner_head',
        if (!_boundaryPause.hasMatch(left) &&
            leftLexeme == 'there' &&
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
            }.contains(rightLexeme))
          'inside_expletive_predicate',
        if (insideQuotedSpeech &&
            quoteSpanWordCount != null &&
            quoteSpanWordCount <= preferredMaxUnpunctuatedWords)
          'inside_short_complete_quote',
        if (insideParenthetical &&
            parenSpanWordCount != null &&
            parenSpanWordCount <= preferredMaxUnpunctuatedWords)
          'inside_short_complete_parenthetical',
      ];
      final crossings = dependencies.where((dependency) {
        if (dependency.token.deprel.split(':').first == 'punct') {
          return false;
        }
        final head = dependency.headWordIndex;
        if (head == null || head == dependency.wordIndex) return false;
        return (dependency.wordIndex < afterWord) != (head < afterWord);
      }).toList(growable: false);
      final protectedCrossings = crossings.where(
        (dependency) {
          final relation = dependency.token.deprel;
          return _protectedRelations.contains(relation) ||
              _protectedRelations.contains(relation.split(':').first);
        },
      ).length;
      final subtreeRelations = crossings
          .map((dependency) => dependency.token.deprel)
          .where(
            (relation) =>
                _clauseRelations.contains(relation) ||
                _phraseRelations.contains(relation),
          )
          .toList(growable: false);
      final oneLegalSubtreeArc =
          crossings.length == 1 && subtreeRelations.length == 1;
      final oneLegalClauseSubtreeArc = oneLegalSubtreeArc &&
          _clauseRelations.contains(subtreeRelations.single) &&
          (subtreeRelations.single != 'conj' ||
              const {'VERB', 'AUX'}.contains(crossings.single.token.upos));
      final hasClauseSubtreeArc =
          subtreeRelations.any(_clauseRelations.contains);
      final hasPhraseSubtreeArc =
          subtreeRelations.any(_phraseRelations.contains);
      final hasLocalIncompleteConstituent =
          _hasLocalIncompleteConstituentBoundary(afterWord, dependencies);
      final hasSubjectlessCoordinatedPredicate =
          _hasSubjectlessCoordinatedPredicateBoundary(
        afterWord,
        dependencies,
      );
      final hasDeferredSharedPredicate = hasSubjectlessCoordinatedPredicate ||
          const {'and', 'but', 'or'}.contains(rightLexeme) &&
              _hasDeferredSharedPredicateBoundary(
                afterWord,
                dependencies,
              );
      final hasRecoveredAdjectivalSharedPredicate =
          const {'and', 'but', 'or'}.contains(rightLexeme) &&
              _hasDeferredSharedPredicateBoundary(
                afterWord,
                dependencies,
                allowedHeadUpos: const {'ADJ'},
                requireLeftSubject: true,
              );
      final hasDelayedSharedPredicate = _hasDelayedSharedPredicateBoundary(
        afterWord,
        dependencies,
      );
      final hasAttachedPrepositionalComplement =
          _hasAttachedPrepositionalComplementBoundary(
        afterWord,
        dependencies,
        words: words,
      );
      final hasMultiwordAdpositionComplement =
          _hasMultiwordAdpositionComplementBoundary(
        afterWord,
        dependencies,
      );
      final hasAttachedAdverbialComplement =
          _hasAttachedAdverbialComplementBoundary(
        afterWord,
        dependencies,
      );
      final hasIncompleteConstituentBoundary = hasLocalIncompleteConstituent ||
          hasDelayedSharedPredicate ||
          hasAttachedPrepositionalComplement ||
          hasAttachedAdverbialComplement ||
          hasMultiwordAdpositionComplement;
      final hasRightSubjectPredicateClause =
          _hasRightSubjectPredicateClause(afterWord, dependencies);
      final hasCoordinatedRightSubjectPredicateClause =
          _hasCoordinatedRightSubjectPredicateClause(
        afterWord,
        dependencies,
      );
      final hasRecoveredCoordinatedRightSubjectPredicateClause =
          _hasRecoveredCoordinatedRightSubjectPredicateClause(
        afterWord,
        dependencies,
      );
      final leftDependencies = dependencies
          .where((dependency) => dependency.wordIndex == afterWord - 1)
          .toList(growable: false);
      final previousDependencies = dependencies
          .where((dependency) => dependency.wordIndex == afterWord - 2)
          .toList(growable: false);
      final rightDependencies = dependencies
          .where((dependency) => dependency.wordIndex == afterWord)
          .toList(growable: false);
      final nextDependencies = dependencies
          .where((dependency) => dependency.wordIndex == afterWord + 1)
          .toList(growable: false);
      final followingDependencies = dependencies
          .where(
            (dependency) =>
                dependency.wordIndex > afterWord &&
                dependency.wordIndex <= afterWord + 3,
          )
          .toList(growable: false);
      final separatesPronounNominalHead = !_boundaryPause.hasMatch(left) &&
          leftDependencies.hasAnyUpos(const {'PRON', 'DET'}) &&
          rightDependencies.hasAnyUpos(const {'ADJ', 'NOUN', 'PROPN'});
      if (separatesPronounNominalHead) {
        hardBlockReasons.add('inside_surface_determiner_head');
      }
      // Never cut after a case/adposition into its object
      // (`mouths of | their holes`).
      if (!_boundaryPause.hasMatch(left) &&
          leftDependencies.any(
            (dependency) =>
                dependency.token.upos == 'ADP' ||
                dependency.token.deprel.split(':').first == 'case',
          ) &&
          rightDependencies.hasAnyUpos(const {
            'DET',
            'PRON',
            'ADJ',
            'NOUN',
            'PROPN',
            'NUM',
          })) {
        hardBlockReasons.add('inside_prepositional_complement');
      }
      // Perception / report verbs often take a bare clausal complement whose
      // subject starts with a determiner (`heard | the angels tell…`). A right
      // subject–predicate shape must not exempt that tight V|DET attachment.
      if (!_boundaryPause.hasMatch(left) &&
          leftDependencies.hasAnyUpos(const {'VERB', 'AUX'}) &&
          (rightDependencies.hasAnyUpos(const {'DET'}) ||
              const {
                'a',
                'an',
                'the',
                'this',
                'that',
                'these',
                'those',
                'my',
                'your',
                'his',
                'her',
                'its',
                'our',
                'their',
              }.contains(rightLexeme))) {
        hardBlockReasons.add('inside_predicate_determiner_object');
      }
      // Misparsed phrasal particle: UD often tags `go | on listening` as
      // SCONJ/mark + advcl instead of compound:prt. Spec still forbids
      // splitting the particle from the verb. Require a right verbal
      // complement headed by the left verb so true PP fronts
      // (`followed | on bare feet`) stay eligible.
      if (!_boundaryPause.hasMatch(left) &&
          _separatesMisparsedPhrasalVerbParticle(
            afterWord,
            rightLexeme,
            leftDependencies,
            rightDependencies,
            dependencies,
          )) {
        hardBlockReasons.add('inside_misparsed_phrasal_verb_particle');
      }
      final rightClauseMarker = rightDependencies
          .where(
            (dependency) => const {'mark', 'advmod'}
                .contains(dependency.token.deprel.split(':').first),
          )
          .firstOrNull;
      final hasDeferredRightClause = rightClauseMarker != null &&
          _hasDeferredRightSubjectPredicateClause(
            afterWord,
            rightClauseMarker.token.head,
            dependencies,
          );
      final softWarnings = <String>[
        if (separatesPronounNominalHead) 'surface_determiner_head_separation',
        if (leftDependencies.hasAnyUpos(const {'NOUN', 'PROPN', 'PRON'}) &&
            !_boundaryPause.hasMatch(left) &&
            rightDependencies.hasAnyUpos(const {'VERB', 'AUX'}))
          'surface_possible_subject_predicate_separation',
        if (leftDependencies.hasAnyUpos(const {'VERB', 'AUX', 'ADJ'}) &&
            !_boundaryPause.hasMatch(left) &&
            rightDependencies.any(
              (dependency) =>
                  const {'PART', 'SCONJ', 'ADP'}
                      .contains(dependency.token.upos) &&
                  dependency.token.deprel.split(':').first == 'mark',
            ))
          'surface_predicate_infinitive_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.hasAnyUpos(const {'ADJ'}) &&
            rightDependencies.any(
              (dependency) =>
                  const {'PART', 'SCONJ', 'ADP'}.contains(
                    dependency.token.upos,
                  ) &&
                  dependency.token.deprel.split(':').first == 'mark',
            ))
          'surface_adjective_infinitive_complement_separation',
        if (leftDependencies.hasAnyUpos(const {'NOUN', 'PROPN'}) &&
            rightDependencies.any(
              (dependency) =>
                  const {'PRON', 'DET'}.contains(dependency.token.upos) &&
                  dependency.token.deprel == 'nmod:poss',
            ))
          'surface_possible_antecedent_possessive_separation',
        // Retained V3.6 baseline terms. They are intentionally uniform across
        // candidates and therefore do not identify a specific local defect,
        // but removing them changes established tie ordering in long units.
        'surface_possible_subject_predicate_separation',
        'surface_predicate_infinitive_separation',
        if (!_boundaryPause.hasMatch(left) &&
            _attachmentLexemes.contains(rightLexeme) &&
            (rightLexeme == 'of' ||
                leftDependencies.hasAnyUpos(const {
                  'VERB',
                  'AUX',
                  'ADJ',
                  'PRON',
                  'DET',
                  'ADP',
                  'ADV',
                  'NOUN',
                  'PROPN',
                })))
          'surface_preposition_attachment_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (dependency) =>
                  dependency.token.deprel.split(':').first == 'nmod' ||
                  dependency.token.upos == 'NUM' &&
                      dependency.token.deprel.split(':').first == 'conj' &&
                      dependency.headWordIndex != null &&
                      dependency.headWordIndex! < afterWord - 1,
            ) &&
            rightDependencies.hasAnyUpos(const {'ADP'}))
          'surface_nested_nominal_preposition_separation',
        if (!_boundaryPause.hasMatch(left) &&
            (_attachmentLexemes.contains(leftLexeme) &&
                    rightLexeme.isNotEmpty &&
                    !const {'and', 'or', 'nor', 'but'}.contains(rightLexeme) ||
                leftDependencies.any(
                  (dependency) =>
                      dependency.token.deprel.split(':').first == 'case' &&
                      dependency.headWordIndex != null &&
                      dependency.headWordIndex! >= afterWord,
                )))
          'surface_preposition_right_operand_separation',
        if (!_boundaryPause.hasMatch(left) &&
            const {'and', 'or', 'nor', 'but'}.contains(leftLexeme))
          'surface_coordinator_right_operand_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.hasAnyUpos(const {'ADV'}) &&
            const {'and', 'or', 'nor', 'but'}.contains(rightLexeme) &&
            nextDependencies.hasAnyUpos(const {'ADV'}))
          'surface_adverb_coordinator_separation',
        if (!_boundaryPause.hasMatch(left) &&
            previousDependencies.hasAnyUpos(const {'ADV'}) &&
            const {'and', 'or', 'nor', 'but'}.contains(leftLexeme) &&
            rightDependencies.hasAnyUpos(const {'ADV'}))
          'surface_adverb_coordinator_right_operand_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.hasAnyUpos(const {'ADJ'}) &&
            const {'and', 'or', 'nor'}.contains(rightLexeme) &&
            nextDependencies.hasAnyUpos(const {'ADJ'}))
          'surface_modifier_head_separation',
        if (!_boundaryPause.hasMatch(left) &&
            !_attachmentLexemes.contains(rightLexeme) &&
            leftDependencies.any(
              (dependency) =>
                  dependency.token.upos == 'NOUN' &&
                  dependency.token.deprel.split(':').first == 'conj' &&
                  dependency.headWordIndex != null &&
                  dependency.headWordIndex! < afterWord,
            ) &&
            rightDependencies.any(
              (rightDependency) =>
                  rightDependency.token.upos == 'ADP' &&
                  rightDependency.token.deprel.split(':').first == 'case' &&
                  rightDependency.headWordIndex != null &&
                  followingDependencies.any(
                    (dependency) =>
                        dependency.token.upos == 'ADJ' &&
                        dependency.headWordIndex ==
                            rightDependency.headWordIndex,
                  ) &&
                  followingDependencies.any(
                    (dependency) =>
                        const {'NOUN', 'PROPN'}.contains(
                          dependency.token.upos,
                        ) &&
                        dependency.wordIndex == rightDependency.headWordIndex,
                  ),
            ))
          'surface_modifier_head_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (leftDependency) =>
                  leftDependency.token.upos == 'VERB' &&
                  const {'acl', 'xcomp'}.contains(
                    leftDependency.token.deprel.split(':').first,
                  ) &&
                  leftDependency.headWordIndex != null &&
                  leftDependency.headWordIndex! >= afterWord + 1,
            ) &&
            const {'and', 'or', 'nor'}.contains(rightLexeme) &&
            nextDependencies.any(
              (nextDependency) =>
                  nextDependency.token.upos == 'VERB' &&
                  leftDependencies.any(
                    (leftDependency) =>
                        leftDependency.headWordIndex ==
                        nextDependency.wordIndex,
                  ),
            ))
          'surface_modifier_head_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (leftDependency) =>
                  leftDependency.token.upos == 'ADJ' &&
                  leftDependency.headWordIndex != null &&
                  leftDependency.headWordIndex! >= afterWord + 1 &&
                  rightDependencies.any(
                    (rightDependency) =>
                        rightDependency.token.upos == 'ADJ' &&
                        rightDependency.headWordIndex ==
                            leftDependency.headWordIndex,
                  ),
            ))
          'surface_modifier_head_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (dependency) =>
                  dependency.token.upos == 'VERB' &&
                  const {'advcl', 'acl'}.contains(
                    dependency.token.deprel.split(':').first,
                  ),
            ) &&
            const {'and', 'or', 'nor'}.contains(rightLexeme) &&
            nextDependencies.any(
              (dependency) =>
                  dependency.token.upos == 'VERB' &&
                  dependency.token.deprel.split(':').first == 'conj' &&
                  dependency.headWordIndex == afterWord - 1,
            ))
          'surface_modifier_head_separation',
        if (!_boundaryPause.hasMatch(left) &&
            rightDependencies.any(
              (dependency) =>
                  dependency.token.upos == 'VERB' &&
                  dependency.token.deprel.split(':').first == 'acl' &&
                  dependency.headWordIndex != null &&
                  dependency.headWordIndex! < afterWord,
            ))
          'surface_participial_modifier_separation',
        if (!_boundaryPause.hasMatch(left) &&
            ((leftDependencies.hasAnyUpos(const {'DET'}) ||
                        const {'this', 'that', 'these', 'those'}.contains(
                          leftLexeme,
                        )) &&
                    followingDependencies.hasAnyUpos(const {'NOUN', 'PROPN'}) ||
                leftDependencies.hasAnyUpos(const {'DET'}) &&
                    rightDependencies.hasAnyUpos(const {
                      'PRON',
                      'DET',
                      'ADJ',
                      'VERB',
                      'AUX',
                    })))
          'surface_determiner_head_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (leftDependency) =>
                  const {'NOUN', 'PROPN'}.contains(
                    leftDependency.token.upos,
                  ) &&
                  nextDependencies.any(
                    (nextDependency) =>
                        const {'NOUN', 'PROPN'}.contains(
                          nextDependency.token.upos,
                        ) &&
                        nextDependency.token.deprel.split(':').first ==
                            'appos' &&
                        nextDependency.token.head == leftDependency.token.id &&
                        rightDependencies.any(
                          (rightDependency) =>
                              rightDependency.token.upos == 'DET' &&
                              rightDependency.token.head ==
                                  nextDependency.token.id,
                        ),
                  ),
            ))
          'surface_modifier_head_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (dependency) =>
                  dependency.token.deprel == 'nmod:poss' &&
                  dependency.headWordIndex != null &&
                  dependency.headWordIndex! >= afterWord,
            ))
          'surface_possessive_head_separation',
        if (!_boundaryPause.hasMatch(left) &&
            rightDependencies.any(
              (dependency) =>
                  const {'obj', 'iobj'}
                      .contains(dependency.token.deprel.split(':').first) &&
                  dependency.headWordIndex != null &&
                  dependency.headWordIndex! < afterWord,
            ))
          'surface_object_relation_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (dependency) => dependency.token.deprel.split(':').first == 'obj',
            ) &&
            rightDependencies
                .hasAnyUpos(const {'DET', 'NOUN', 'PROPN', 'ADJ', 'VERB'}))
          'surface_object_predicative_complement_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.hasAnyUpos(const {'ADJ', 'ADV'}) &&
            rightDependencies.hasAnyUpos(const {'DET'}) &&
            crossings.any(
              (dependency) => dependency.token.deprel.split(':').first == 'obj',
            ))
          'surface_object_predicative_complement_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (dependency) =>
                  const {'nsubj', 'csubj'}
                      .contains(dependency.token.deprel.split(':').first) &&
                  dependency.headWordIndex != null &&
                  dependency.headWordIndex! >= afterWord,
            ))
          'surface_subject_predicate_relation_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftLexeme == 'to' &&
            rightDependencies.hasAnyUpos(const {'VERB'}))
          'surface_infinitive_marker_predicate_separation',
        if (!_boundaryPause.hasMatch(left) &&
            const {
              'as:if',
              'as:though',
              'even:if',
              'even:though',
              'rather:than',
              'so:that',
              'such:as',
              'that:if',
              'that:when',
              'that:because',
              'that:although',
              'that:though',
              'that:while',
              'half:as',
              'half:so',
              'twice:as',
              'not:as',
              'not:so',
              'ever:so',
              'all:too',
            }.contains('$leftLexeme:$rightLexeme'))
          'surface_fixed_connector_separation',
        if (!_boundaryPause.hasMatch(left) &&
            (leftLexeme == 'as' &&
                    rightDependencies.hasAnyUpos(const {'ADJ', 'ADV'}) ||
                rightLexeme == 'as' &&
                    leftDependencies.hasAnyUpos(const {'ADJ', 'ADV'})))
          'surface_fixed_connector_separation',
        if (!_boundaryPause.hasMatch(left) &&
            (hasAttachedAdverbialComplement ||
                leftDependencies.hasAnyUpos(const {'VERB'}) &&
                    rightLexeme == 'but' &&
                    nextDependencies.hasAnyUpos(const {'PART'}) &&
                    dependencies.any(
                      (dependency) =>
                          dependency.wordIndex == afterWord + 2 &&
                          dependency.token.upos == 'VERB',
                    )))
          'surface_fixed_connector_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (dependency) =>
                  dependency.token.upos == 'ADJ' &&
                      dependency.headWordIndex != null &&
                      dependency.headWordIndex! >= afterWord ||
                  (const {'amod', 'compound'}.contains(
                        dependency.token.deprel.split(':').first,
                      ) &&
                      dependency.headWordIndex != null &&
                      dependency.headWordIndex! >= afterWord),
            ) &&
            rightDependencies.hasAnyUpos(const {'NOUN', 'PROPN', 'VERB'}))
          'surface_modifier_head_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.hasAnyUpos(const {'ADJ'}) &&
            rightDependencies.hasAnyUpos(const {'NOUN', 'PROPN'}))
          'surface_modifier_head_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.hasAnyUpos(const {'ADJ'}) &&
            rightDependencies.any(
              (dependency) =>
                  dependency.token.upos == 'VERB' &&
                  dependency.token.deprel.split(':').first == 'acl' &&
                  dependency.headWordIndex == afterWord - 1,
            ))
          'surface_modifier_head_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.hasAnyUpos(const {'ADJ'}) &&
            rightDependencies.hasAnyUpos(const {'ADJ'}) &&
            followingDependencies.hasAnyUpos(const {'NOUN', 'PROPN'}))
          'surface_modifier_head_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies
                .any((dependency) => dependency.token.upos == 'ADV') &&
            rightDependencies
                .any((dependency) => dependency.token.upos == 'ADV') &&
            nextDependencies
                .any((dependency) => dependency.token.upos == 'ADJ'))
          'surface_modifier_head_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.hasAnyUpos(const {'NOUN', 'PROPN'}) &&
            rightDependencies.hasAnyUpos(const {'PRON'}))
          'surface_nominal_relative_pronoun_separation',
        if (!_boundaryPause.hasMatch(left) &&
            rightDependencies.any(
              (dependency) =>
                  dependency.token.deprel.split(':').first == 'advmod' &&
                  dependency.headWordIndex != null &&
                  dependency.headWordIndex! < afterWord,
            ))
          'surface_adverb_attachment_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (dependency) =>
                  dependency.token.upos == 'ADV' &&
                  dependency.headWordIndex != null &&
                  dependency.headWordIndex! >= afterWord,
            ))
          'surface_adverb_attachment_separation',
        if (!_boundaryPause.hasMatch(left) &&
            rightDependencies.any(
              (dependency) =>
                  dependency.token.deprel.split(':').first == 'xcomp' &&
                  dependency.headWordIndex != null &&
                  dependency.headWordIndex! < afterWord,
            ))
          'surface_xcomp_predicate_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.hasAnyUpos(const {'VERB', 'AUX'}) &&
            rightDependencies.hasAnyUpos(const {'ADV'}) &&
            nextDependencies.hasAnyUpos(const {'VERB', 'AUX', 'ADJ'}))
          'surface_auxiliary_adverb_complement_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.hasAnyUpos(const {'AUX'}) &&
            rightDependencies.hasAnyUpos(const {'ADV'}))
          'surface_auxiliary_adverb_complement_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.hasAnyUpos(const {'VERB', 'AUX'}) &&
            rightDependencies.hasAnyUpos(const {'ADV'}) &&
            dependencies.any(
              (coordinator) =>
                  coordinator.wordIndex > afterWord &&
                  coordinator.wordIndex <= afterWord + 3 &&
                  coordinator.token.upos == 'CCONJ' &&
                  dependencies.any(
                    (adverb) =>
                        adverb.wordIndex > coordinator.wordIndex &&
                        adverb.wordIndex <= afterWord + 4 &&
                        adverb.token.upos == 'ADV',
                  ),
            ))
          'surface_predicate_adverbial_complement_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.hasAnyUpos(const {'ADV'}) &&
            rightDependencies.hasAnyUpos(const {'VERB', 'ADJ'}) &&
            previousDependencies.hasAnyUpos(const {'VERB', 'AUX'}))
          'surface_auxiliary_adverb_complement_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (dependency) =>
                  dependency.token.upos == 'AUX' ||
                  dependency.token.upos == 'VERB' &&
                      rightDependencies.any(
                        (rightDependency) =>
                            rightDependency.token.upos == 'VERB' &&
                            rightDependency.token.deprel.split(':').first ==
                                'conj' &&
                            rightDependency.headWordIndex == afterWord - 1,
                      ),
            ) &&
            rightDependencies.hasAnyUpos(const {'VERB', 'AUX'}))
          'surface_auxiliary_predicate_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.hasAnyUpos(const {'NOUN', 'PROPN', 'PRON'}) &&
            const {'and', 'or', 'nor'}.contains(rightLexeme) &&
            nextDependencies
                .hasAnyUpos(const {'NOUN', 'PROPN', 'PRON', 'DET', 'ADJ'}))
          'surface_nominal_coordinator_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.hasAnyUpos(const {'NOUN', 'PROPN'}) &&
            const {'and', 'or', 'nor'}.contains(rightLexeme) &&
            nextDependencies.any(
              (dependency) =>
                  dependency.token.upos == 'NUM' &&
                  dependency.token.deprel.split(':').first == 'conj' &&
                  dependency.headWordIndex == afterWord - 1,
            ))
          'surface_internal_nominal_coordinator_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.hasAnyUpos(const {'NOUN', 'PROPN'}) &&
            const {'and', 'or', 'nor'}.contains(rightLexeme) &&
            nextDependencies.hasAnyUpos(const {'NOUN', 'PROPN'}) &&
            afterWord + 1 < words.length &&
            _boundaryPause.hasMatch(words[afterWord + 1].text))
          'surface_short_nominal_coordinator_tail',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.any(
              (dependency) =>
                  const {'NOUN', 'PROPN'}.contains(dependency.token.upos) &&
                  dependency.token.deprel.split(':').first == 'conj' &&
                  dependency.headWordIndex != null &&
                  dependency.headWordIndex! < afterWord - 1,
            ) &&
            const {'and', 'or', 'nor'}.contains(rightLexeme) &&
            nextDependencies.any(
              (dependency) =>
                  dependency.token.upos == 'VERB' &&
                  dependency.token.deprel.split(':').first == 'conj' &&
                  dependency.headWordIndex != null &&
                  dependency.headWordIndex! < afterWord - 1,
            ))
          'surface_mixed_coordinator_chain_separation',
        if (!_boundaryPause.hasMatch(left) &&
            const {'all', 'both', 'either', 'neither'}.contains(leftLexeme) &&
            const {
              'one',
              'two',
              'three',
              'four',
              'five',
              'six',
              'seven',
              'eight',
              'nine',
              'ten',
            }.contains(rightLexeme))
          'surface_quantifier_numeral_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.hasAnyUpos(const {'VERB', 'AUX'}) &&
            const {'my', 'your', 'his', 'her', 'its', 'our', 'their'}
                .contains(rightLexeme))
          'surface_predicate_possessive_object_separation',
        if (!_boundaryPause.hasMatch(left) &&
            const {
              'where',
              'wherever',
              'when',
              'whenever',
              'while',
              'which',
              'whichever',
              'who',
              'whoever',
              'whom',
              'whose',
              'whatever',
              'that',
              'if',
              'unless',
              'because',
              'although',
              'though',
              'until',
              'since',
              'before',
              'after',
              'once',
              'as',
            }.contains(leftLexeme) &&
            rightDependencies
                .hasAnyUpos(const {'PRON', 'DET', 'NOUN', 'PROPN'}))
          'surface_relative_marker_subject_separation',
        if (!_boundaryPause.hasMatch(left) &&
            const {
              'i',
              'you',
              'he',
              'she',
              'it',
              'we',
              'they',
              'me',
              'him',
              'her',
              'us',
              'them',
            }.contains(leftLexeme) &&
            rightDependencies.hasAnyUpos(const {'VERB', 'AUX'}))
          'surface_pronoun_predicate_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.hasAnyUpos(const {'VERB', 'AUX'}) &&
            const {
              'that',
              'whether',
              'if',
              'what',
              'how',
              'why',
              'where',
              'when',
              'who',
              'which',
            }.contains(rightLexeme))
          'surface_predicate_complement_marker_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.hasAnyUpos(const {'VERB', 'AUX'}) &&
            rightDependencies.hasAnyUpos(const {'DET'}))
          'surface_predicate_determiner_object_separation',
        if (!_boundaryPause.hasMatch(left) &&
            leftDependencies.hasAnyUpos(const {'AUX'}) &&
            rightDependencies.hasAnyUpos(const {'DET'}))
          'surface_copula_predicative_separation',
        if (_commaPunctuation.hasMatch(left) &&
            !hasRightSubjectPredicateClause &&
            (leftDependencies.hasAnyUpos(const {'ADJ'}) ||
                RegExp(r'(?:ed|en|ful|ing|ive|less|ous)$')
                    .hasMatch(leftLexeme)) &&
            !const {
              'a',
              'an',
              'the',
              'this',
              'that',
              'these',
              'those',
              'and',
              'or',
              'but',
            }.contains(rightLexeme) &&
            !rightDependencies.hasAnyUpos(const {'VERB', 'AUX'}) &&
            !crossings.any(
              (dependency) =>
                  dependency.token.deprel.split(':').first == 'case',
            ) &&
            nextDependencies.hasAnyUpos(const {'NOUN', 'PROPN'}))
          'surface_parallel_list_item_separation',
        if (quoteEdge == 'after_closing' &&
            (!_quotedTerminalPunctuation.hasMatch(left) ||
                words.length - afterWord <= 5 ||
                quoteSpanWordCount == 1 ||
                (quoteSpanWordCount ?? 0) > targetMaxUnpunctuatedWords) &&
            _isAttributionOnlyRightTail(afterWord, dependencies))
          'quote_edge_attribution_only_tail',
      ];
      final protectsQuotedAttribution = _commaPunctuation.hasMatch(left) &&
              RegExp(r'''^["'“‘]''').hasMatch(right) ||
          RegExp(r''',["'”’]$''').hasMatch(left) &&
              RegExp(r'^[a-z]').hasMatch(right);
      final surfaceClosingQuoteCoordinatedPause =
          RegExp(r''',["'”’]$''').hasMatch(left) &&
              const {'and', 'but', 'or', 'nor'}.contains(rightLexeme);
      final allowsSourceClosingQuotePause = quoteEdge == 'after_closing' &&
          _commaPunctuation.hasMatch(left) &&
          ((words[afterWord - 1].quotedSpeechStartWord ?? 0) > 0 ||
              (quoteSpanWordCount ?? 0) >= 6);
      final allowsDeferredOpeningParentheticalPause =
          parenEdge == 'before_opening' && (parenSpanWordCount ?? 0) >= 6;
      final isCompleteParentheticalEdge = parenSpanWordCount != null &&
          const {'before_opening', 'after_closing'}.contains(parenEdge);
      final isCompleteQuoteEdge = quoteSpanWordCount != null &&
          const {'before_opening', 'after_closing', 'between_quotes'}
              .contains(quoteEdge);
      ReadAloudBoundaryKindV3 kind;
      final reasons = <String>[
        if (insideQuotedSpeech) 'inside_quoted_speech',
        if (quoteEdge != null) 'quote_edge:$quoteEdge',
        if (quoteEdge == 'after_closing' &&
            hasCoordinatedRightSubjectPredicateClause)
          'quote_edge_coordinated_continuation',
        if (hasSubjectlessCoordinatedPredicate)
          'incomplete_subjectless_coordinated_predicate',
        if (hasDeferredSharedPredicate) 'deferred_stable_shared_predicate',
        if (hasRecoveredAdjectivalSharedPredicate)
          'recovered_adjectival_shared_predicate',
        if (hasDelayedSharedPredicate) 'incomplete_delayed_shared_predicate',
        if (hasAttachedPrepositionalComplement)
          'incomplete_attached_prepositional_complement',
        if (hasMultiwordAdpositionComplement)
          'incomplete_multiword_adposition_complement',
        if (hasAttachedAdverbialComplement)
          'incomplete_attached_adverbial_complement',
        if (const {'who', 'whom', 'whose', 'which', 'that'}.contains(
              rightLexeme,
            ) &&
            rightDependencies.any(
              (dependency) =>
                  dependency.token.upos == 'PRON' ||
                  rightLexeme == 'whose' && dependency.token.upos == 'DET',
            ) &&
            leftDependencies.hasAnyUpos(const {'NOUN', 'PROPN'}))
          'surface_relative_clause_front',
        if (insideParenthetical) 'inside_parenthetical',
        if (parenEdge != null) 'paren_edge:$parenEdge',
        if (allowsDeferredOpeningParentheticalPause)
          'deferred_stable_parenthetical_edge',
        if (hasDeferredRightClause) 'deferred_stable_right_clause',
      ];
      // Do not offer `change (she knew) | to …` or `change | (she knew) to …`
      // as path edges; both delimiter sides must stay parked with the PP.
      if (parenEdge == 'after_closing' && hasAttachedPrepositionalComplement) {
        hardBlockReasons.add('attached_pp_after_parenthetical_closing');
      }
      if (parenEdge == 'before_opening' &&
          parenSpanWordCount != null &&
          _hasAttachedPrepositionalComplementBoundary(
            afterWord + parenSpanWordCount,
            dependencies,
            words: words,
          )) {
        hardBlockReasons.add('attached_pp_before_parenthetical_opening');
      }
      if (allowsSourceClosingQuotePause) {
        kind = ReadAloudBoundaryKindV3.phraseComma;
        reasons.add('source_closing_quote_comma_pause');
      } else if (protectsQuotedAttribution &&
          (quoteEdge == 'before_opening' ||
              RegExp(r'''^["'“‘]''').hasMatch(right))) {
        kind = ReadAloudBoundaryKindV3.phraseComma;
        reasons.add('source_attribution_before_opening_quote');
      } else if (surfaceClosingQuoteCoordinatedPause) {
        kind = ReadAloudBoundaryKindV3.phraseComma;
        reasons.add('source_closing_quote_coordinated_pause');
      } else if (protectsQuotedAttribution) {
        kind = ReadAloudBoundaryKindV3.emergency;
        reasons.add('protected_quote_attribution_gap');
      } else if (isCompleteParentheticalEdge ||
          isCompleteQuoteEdge ||
          _strongPunctuation.hasMatch(left) ||
          (insideQuotedSpeech || quoteEdge == 'after_closing') &&
              _quotedTerminalPunctuation.hasMatch(left) ||
          parenEdge == 'after_closing' && _boundaryPause.hasMatch(left)) {
        kind = ReadAloudBoundaryKindV3.strongPunctuation;
        reasons.add(
          parenEdge == 'before_opening'
              ? 'source_parenthetical_opening_edge'
              : parenEdge == 'after_closing'
                  ? 'source_parenthetical_closing_edge'
                  : quoteEdge == 'before_opening'
                      ? 'source_quote_opening_edge'
                      : quoteEdge == 'after_closing'
                          ? 'source_quote_closing_edge'
                          : quoteEdge == 'between_quotes'
                              ? 'source_between_quotes_edge'
                              : 'source_strong_punctuation',
        );
      } else if (_commaPunctuation.hasMatch(left) &&
          (oneLegalClauseSubtreeArc ||
              hasRightSubjectPredicateClause ||
              hasCoordinatedRightSubjectPredicateClause ||
              hasRecoveredCoordinatedRightSubjectPredicateClause) &&
          protectedCrossings == 0) {
        kind = ReadAloudBoundaryKindV3.clauseComma;
        reasons.add(
          hasRecoveredCoordinatedRightSubjectPredicateClause
              ? 'dependency_recovered_coordinated_right_subject_predicate_clause_comma'
              : hasCoordinatedRightSubjectPredicateClause
                  ? 'dependency_confirmed_coordinated_right_subject_predicate_clause_comma'
                  : hasRightSubjectPredicateClause
                      ? 'dependency_confirmed_right_subject_predicate_clause_comma'
                      : 'dependency_confirmed_clause_comma',
        );
      } else if (_commaPunctuation.hasMatch(left) &&
          hasPhraseSubtreeArc &&
          protectedCrossings == 0) {
        kind = ReadAloudBoundaryKindV3.phraseComma;
        reasons.add('dependency_confirmed_phrase_comma');
      } else if (_commaPunctuation.hasMatch(left)) {
        kind = ReadAloudBoundaryKindV3.ambiguousComma;
        reasons.add('source_comma_without_confirmed_clause');
      } else if (hasClauseSubtreeArc && protectedCrossings == 0) {
        if ((classifyLocalIncompleteConstituents &&
                hasIncompleteConstituentBoundary) ||
            (classifySubjectlessCoordinatedPredicates &&
                hasSubjectlessCoordinatedPredicate)) {
          kind = ReadAloudBoundaryKindV3.emergency;
          reasons.add('incomplete_constituent_boundary');
        } else {
          kind = ReadAloudBoundaryKindV3.dependencyClause;
          reasons.add(
            oneLegalSubtreeArc
                ? 'complete_dependency_clause_subtree'
                : 'dependency_clause_with_outer_container_arcs',
          );
        }
      } else if (hasPhraseSubtreeArc && protectedCrossings == 0) {
        if ((classifyLocalIncompleteConstituents &&
                hasIncompleteConstituentBoundary) ||
            (classifySubjectlessCoordinatedPredicates &&
                hasSubjectlessCoordinatedPredicate)) {
          kind = ReadAloudBoundaryKindV3.emergency;
          reasons.add('incomplete_constituent_boundary');
        } else {
          kind = ReadAloudBoundaryKindV3.dependencyPhrase;
          reasons.add(
            oneLegalSubtreeArc
                ? 'complete_dependency_phrase_subtree'
                : 'dependency_phrase_with_outer_container_arcs',
          );
        }
      } else {
        kind = ReadAloudBoundaryKindV3.emergency;
        reasons.add(
          crossings.isEmpty
              ? 'dependency_disconnected_or_same_word'
              : 'ordinary_word_gap',
        );
      }
      final rawRisk = protectedCrossings * 1000 +
          math.max(0, crossings.length - 1) * 100 +
          (kind == ReadAloudBoundaryKindV3.ambiguousComma
              ? 5
              : kind == ReadAloudBoundaryKindV3.phraseComma
                  ? 0
                  : kind == ReadAloudBoundaryKindV3.dependencyPhrase
                      ? 10
                      : kind == ReadAloudBoundaryKindV3.emergency
                          ? 20
                          : 0);
      final coordinatedQuoteEdge = quoteEdge == 'after_closing' &&
          hasCoordinatedRightSubjectPredicateClause;
      final risk = coordinatedQuoteEdge
          ? math.max(0, rawRisk - protectedCrossings * 1000 - 200)
          : quoteEdge == 'after_closing' && protectedCrossings == 0
              ? math.max(0, rawRisk - 200)
              : parenEdge == 'after_closing' && protectedCrossings == 0
                  ? math.max(0, rawRisk - 150)
                  : rawRisk;
      output.add(
        ReadAloudBoundaryCandidateV3(
          afterWord: afterWord,
          kind: kind,
          reasons: List.unmodifiable([
            ...reasons,
            if (risk < rawRisk && quoteEdge == 'after_closing')
              'quote_edge_priority',
            if (risk < rawRisk && parenEdge == 'after_closing')
              'paren_edge_priority',
            if (crossings.isNotEmpty)
              'crossing_relations:${crossings.map((value) => value.token.deprel).join(',')}',
          ]),
          crossedDependencyArcs: crossings.length,
          protectedRelationCrossings: protectedCrossings,
          risk: risk,
          softWarnings: List.unmodifiable(softWarnings),
          hardBlocked: hardBlockReasons.isNotEmpty,
          hardBlockReasons: List.unmodifiable(hardBlockReasons),
          insideQuotedSpeech: insideQuotedSpeech,
          quoteSpanWordCount: quoteSpanWordCount,
          quoteEdge: quoteEdge,
          insideParenthetical: insideParenthetical,
          parenSpanWordCount: parenSpanWordCount,
          parenEdge: parenEdge,
        ),
      );
    }
    return output;
  }

  /// Detects direct evidence that the boundary cuts through one constituent.
  /// Only arcs crossing this exact boundary are considered; a complete clause
  /// much farther to the right cannot make an adjacent complement split safe.
  static bool _hasLocalIncompleteConstituentBoundary(
    int afterWord,
    List<_MappedDependencyV3> dependencies,
  ) {
    for (final dependency in dependencies) {
      final head = dependency.headWordIndex;
      if (head == null || head == dependency.wordIndex) continue;
      final crosses = (dependency.wordIndex < afterWord) != (head < afterWord);
      if (!crosses) continue;
      final relation = dependency.token.deprel.split(':').first;
      final fullRelation = dependency.token.deprel;
      if (_protectedRelations.contains(fullRelation) ||
          _protectedRelations.contains(relation)) {
        return true;
      }
      // Right-side adverbial / particle whose head lies on the left of the cut:
      // `bend | about`, `about | easily` (stacked advmod of bend), `blown | out`.
      // Soft incomplete only — raises emergency risk; does not hard-block.
      if (head < afterWord &&
          dependency.wordIndex >= afterWord &&
          (relation == 'advmod' ||
              fullRelation == 'compound:prt' ||
              (relation == 'compound' &&
                  const {'ADP', 'ADV', 'PART'}.contains(dependency.token.upos)))) {
        return true;
      }
      // An open clausal complement inherits its subject from the predicate on
      // the left, so `seemed | quite natural` and `looked | so good` are not
      // closed read-aloud boundaries. Other clause relations retain the
      // established V3.6 treatment.
      if (relation == 'xcomp') {
        if (_hasExplicitContinuationMarker(afterWord, dependencies) &&
            !_isInfinitivalComplementMarkerOfLeftPredicate(
              afterWord,
              dependencies,
            )) {
          continue;
        }
        if (_isStructuredComparativeContinuation(
          afterWord,
          dependency,
          dependencies,
        )) {
          continue;
        }
        return true;
      }
    }
    return false;
  }

  /// A conjunction, subordinator, preposition, relative marker, or comparison
  /// marker at the right edge makes the continuation explicit. Such a block is
  /// not a bare orphan merely because one dependency arc still crosses the
  /// read-aloud boundary.
  static bool _hasExplicitContinuationMarker(
    int afterWord,
    List<_MappedDependencyV3> dependencies,
  ) =>
      dependencies.any(
        (dependency) =>
            dependency.wordIndex == afterWord &&
            (const {'CCONJ', 'SCONJ', 'ADP'}.contains(dependency.token.upos) ||
                const {'cc', 'mark', 'case'}.contains(
                  dependency.token.deprel.split(':').first,
                )),
      );

  /// `go | on listening` when the parser marks particle-shaped `on` as the
  /// mark of a right verbal complement headed by the left verb. True case-PP
  /// fronts (`followed | on bare feet`) do not match: the particle's head is
  /// a noun, not a verb headed by the left predicate.
  static bool _separatesMisparsedPhrasalVerbParticle(
    int afterWord,
    String rightLexeme,
    List<_MappedDependencyV3> leftDependencies,
    List<_MappedDependencyV3> rightDependencies,
    List<_MappedDependencyV3> dependencies,
  ) {
    if (!leftDependencies.hasAnyUpos(const {'VERB', 'AUX'})) return false;
    if (!_phrasalParticleLexemes.contains(rightLexeme)) return false;
    for (final marker in rightDependencies) {
      final relation = marker.token.deprel.split(':').first;
      final looksLikeParticleShell = relation == 'mark' ||
          relation == 'advmod' ||
          const {'ADP', 'PART', 'ADV', 'SCONJ'}.contains(marker.token.upos);
      if (!looksLikeParticleShell) continue;
      final complement = dependencies
          .where((dependency) => dependency.token.id == marker.token.head)
          .firstOrNull;
      if (complement == null || complement.wordIndex < afterWord) continue;
      if (!const {'VERB', 'AUX'}.contains(complement.token.upos)) continue;
      if (complement.headWordIndex != afterWord - 1) continue;
      final complementRelation = complement.token.deprel.split(':').first;
      if (const {'advcl', 'xcomp', 'ccomp'}.contains(complementRelation)) {
        return true;
      }
    }
    return false;
  }

  /// `able | to arrange`, `used | to be`, `occurs | to me`: the infinitival
  /// marker completes the left predicate's open complement and must not waive
  /// the xcomp incomplete-constituent signal.
  static bool _isInfinitivalComplementMarkerOfLeftPredicate(
    int afterWord,
    List<_MappedDependencyV3> dependencies,
  ) {
    final marker = dependencies
        .where(
          (dependency) =>
              dependency.wordIndex == afterWord &&
              dependency.token.deprel.split(':').first == 'mark' &&
              dependency.token.text.toLowerCase() == 'to',
        )
        .firstOrNull;
    if (marker == null) return false;
    final complementId = marker.token.head;
    final complement = dependencies
        .where((dependency) => dependency.token.id == complementId)
        .firstOrNull;
    if (complement == null || complement.wordIndex < afterWord) return false;
    final complementHead = complement.headWordIndex;
    if (complementHead == null || complementHead >= afterWord) return false;
    final relation = complement.token.deprel.split(':').first;
    return relation == 'xcomp' ||
        relation == 'ccomp' ||
        relation == 'advcl' ||
        relation == 'obl';
  }

  /// Allows a pause before a complete comparative complement such as an
  /// adverbial modifier + adjectival xcomp + its own subordinate modifier.
  /// This is dependency topology, not a word-list exception.
  static bool _isStructuredComparativeContinuation(
    int afterWord,
    _MappedDependencyV3 xcomp,
    List<_MappedDependencyV3> dependencies,
  ) {
    if (xcomp.wordIndex <= afterWord ||
        !const {'ADJ', 'ADV'}.contains(xcomp.token.upos)) {
      return false;
    }
    final hasLeadingModifier = dependencies.any(
      (dependency) =>
          dependency.wordIndex == afterWord &&
          dependency.token.head == xcomp.token.id &&
          const {'advmod', 'mark'}.contains(
            dependency.token.deprel.split(':').first,
          ),
    );
    final hasOwnContinuation = dependencies.any(
      (dependency) =>
          dependency.wordIndex > xcomp.wordIndex &&
          dependency.token.head == xcomp.token.id &&
          const {'advcl', 'ccomp'}.contains(
            dependency.token.deprel.split(':').first,
          ),
    );
    return hasLeadingModifier && hasOwnContinuation;
  }

  /// Repairs a parser attachment pattern where a nominal conjunct and its
  /// finite predicate are siblings of an earlier predicate. A cut immediately
  /// before that later predicate would still split the surface subject from
  /// what it predicates, even though UDPipe exposes no direct nsubj crossing.
  static bool _hasDelayedSharedPredicateBoundary(
    int afterWord,
    List<_MappedDependencyV3> dependencies,
  ) {
    final rightPredicate = dependencies.where(
      (dependency) =>
          dependency.wordIndex >= afterWord &&
          // Permit one leading adverb before the delayed predicate, e.g.
          // `view | practically completed ...`. The boundary is still before
          // the predicate phrase and therefore separates the shared nominal
          // subject from what is predicated of it.
          dependency.wordIndex <= afterWord + 2 &&
          const {'VERB', 'AUX'}.contains(dependency.token.upos) &&
          dependency.token.deprel.split(':').first == 'conj' &&
          dependency.token.head > 0,
    );
    for (final predicate in rightPredicate) {
      final sharedNominal = dependencies.any(
        (dependency) =>
            dependency.wordIndex < afterWord &&
            dependency.wordIndex >= math.max(0, afterWord - 20) &&
            const {'NOUN', 'PROPN', 'PRON'}.contains(dependency.token.upos) &&
            dependency.token.deprel.split(':').first == 'conj' &&
            dependency.token.head == predicate.token.head,
      );
      if (sharedNominal) return true;
    }
    return false;
  }

  /// A coordinating marker followed by a predicate that inherits the subject
  /// of an earlier predicate is not a self-contained right-hand read-aloud
  /// unit. Coordinated clauses with their own subject remain legal.
  static bool _hasSubjectlessCoordinatedPredicateBoundary(
    int afterWord,
    List<_MappedDependencyV3> dependencies,
  ) {
    final startsWithCoordinator = dependencies.any(
      (dependency) =>
          dependency.wordIndex == afterWord &&
          dependency.token.upos == 'CCONJ' &&
          dependency.token.deprel.split(':').first == 'cc',
    );
    if (!startsWithCoordinator) return false;
    final rightPredicates = dependencies.where(
      (dependency) =>
          dependency.wordIndex > afterWord &&
          dependency.wordIndex <= afterWord + 2 &&
          const {'VERB', 'AUX'}.contains(dependency.token.upos) &&
          dependency.token.deprel.split(':').first == 'conj' &&
          dependency.headWordIndex != null &&
          dependency.headWordIndex! < afterWord &&
          dependencies.any(
            (head) =>
                head.wordIndex == dependency.headWordIndex &&
                const {'VERB', 'AUX'}.contains(head.token.upos),
          ),
    );
    for (final predicate in rightPredicates) {
      final hasOwnSubject = dependencies.any(
        (dependency) =>
            dependency.wordIndex >= afterWord &&
            dependency.token.head == predicate.token.id &&
            const {'nsubj', 'csubj', 'expl'}.contains(
              dependency.token.deprel.split(':').first,
            ),
      );
      if (!hasOwnSubject) return true;
    }
    return false;
  }

  static bool _hasDeferredSharedPredicateBoundary(
    int afterWord,
    List<_MappedDependencyV3> dependencies, {
    Set<String> allowedHeadUpos = const {'VERB', 'AUX'},
    bool requireLeftSubject = false,
  }) {
    final coordinator = dependencies
        .where(
          (dependency) =>
              dependency.wordIndex == afterWord &&
              dependency.token.upos == 'CCONJ' &&
              dependency.token.deprel.split(':').first == 'cc',
        )
        .firstOrNull;
    if (coordinator == null) return false;
    final predicate = dependencies
        .where(
          (dependency) =>
              dependency.token.id == coordinator.token.head &&
              dependency.wordIndex >= afterWord &&
              dependency.wordIndex <= afterWord + 5 &&
              const {'VERB', 'AUX'}.contains(dependency.token.upos) &&
              dependency.token.deprel.split(':').first == 'conj' &&
              dependency.headWordIndex != null &&
              dependencies.any(
                (head) =>
                    head.wordIndex == dependency.headWordIndex &&
                    allowedHeadUpos.contains(head.token.upos),
              ),
        )
        .firstOrNull;
    if (predicate == null) return false;
    final hasOwnSubject = dependencies.any(
      (dependency) =>
          dependency.wordIndex >= afterWord &&
          dependency.token.head == predicate.token.id &&
          const {'nsubj', 'csubj', 'expl'}.contains(
            dependency.token.deprel.split(':').first,
          ),
    );
    if (hasOwnSubject) return false;
    if (requireLeftSubject) {
      return dependencies.any(
        (dependency) =>
            dependency.wordIndex < afterWord &&
            (dependency.token.head == predicate.token.id ||
                dependency.token.head == coordinator.token.id) &&
            const {'nsubj', 'csubj', 'expl'}.contains(
              dependency.token.deprel.split(':').first,
            ),
      );
    }
    return dependencies.any(
      (dependency) =>
          dependency.wordIndex < afterWord &&
          dependency.wordIndex >= afterWord - preferredMaxUnpunctuatedWords &&
          const {'VERB', 'AUX'}.contains(dependency.token.upos),
    );
  }

  /// A predicate or nominal followed by its attached prepositional complement
  /// is not a safe substitute boundary merely because the parser also exposes
  /// a clause arc. This follows the `anchor <- argument <- case` topology, so
  /// a clause-linking `for`/`as` is unaffected.
  ///
  /// When the token immediately left of the cut is only an adverbial/particle
  /// shell (`easily | in`), look back to the governing predicate. When the cut
  /// closes a parenthetical (`change (she knew) | to …`), look back past that
  /// paren span. Do not look back from ordinary nominals — that would demote
  /// supplemental PP fronts such as `castle | in all…`.
  static bool _hasAttachedPrepositionalComplementBoundary(
    int afterWord,
    List<_MappedDependencyV3> dependencies, {
    List<_SourceWordV3> words = const [],
  }) {
    final immediateLeft = dependencies.where(
      (dependency) => dependency.wordIndex == afterWord - 1,
    );
    final leftIsAdverbialShell = immediateLeft.any(
      (dependency) =>
          const {'ADV', 'PART'}.contains(dependency.token.upos) ||
          dependency.token.deprel.split(':').first == 'advmod' ||
          dependency.token.deprel == 'compound:prt',
    );
    var lookbackStart =
        leftIsAdverbialShell ? math.max(0, afterWord - 4) : afterWord - 1;
    int? closedParenSpan;
    if (words.isNotEmpty && afterWord > 0 && afterWord <= words.length) {
      final leftWord = words[afterWord - 1];
      if (leftWord.parentheticalEndWord == afterWord &&
          leftWord.parentheticalStartWord != null) {
        closedParenSpan = leftWord.parentheticalSpanIndex;
        lookbackStart = math.min(
          lookbackStart,
          math.max(0, leftWord.parentheticalStartWord! - 1),
        );
      }
    }
    final anchors = dependencies.where(
      (dependency) {
        if (dependency.wordIndex < lookbackStart ||
            dependency.wordIndex >= afterWord) {
          return false;
        }
        if (!(const {'VERB', 'AUX', 'NOUN', 'PROPN', 'PRON', 'ADV'}
                .contains(dependency.token.upos) ||
            dependency.token.upos == 'ADJ' &&
                RegExp(r'(?:ed|en|ing)$', caseSensitive: false)
                    .hasMatch(dependency.token.text))) {
          return false;
        }
        if (dependency.wordIndex == afterWord - 1) return true;
        for (final intervening in dependencies) {
          if (intervening.wordIndex <= dependency.wordIndex ||
              intervening.wordIndex >= afterWord) {
            continue;
          }
          if (closedParenSpan != null &&
              intervening.wordIndex < words.length &&
              words[intervening.wordIndex].parentheticalSpanIndex ==
                  closedParenSpan) {
            continue;
          }
          if (const {
            'NOUN',
            'PROPN',
            'PRON',
            'VERB',
            'AUX',
            'SCONJ',
            'CCONJ',
          }.contains(intervening.token.upos)) {
            return false;
          }
        }
        return true;
      },
    );
    for (final anchor in anchors) {
      final rightArguments = dependencies.where(
        (dependency) =>
            dependency.wordIndex >= afterWord &&
            dependency.token.head == anchor.token.id &&
            const {'obl', 'nmod'}.contains(
              dependency.token.deprel.split(':').first,
            ),
      );
      for (final argument in rightArguments) {
        final startsWithCaseMarker = dependencies.any(
          (dependency) =>
              dependency.wordIndex == afterWord &&
              dependency.token.upos == 'ADP' &&
              dependency.token.head == argument.token.id &&
              dependency.token.deprel.split(':').first == 'case',
        );
        if (startsWithCaseMarker) return true;
      }
    }
    // `bring … young ones | to the mouths`: the object noun is not the obl
    // head, but cutting before the verb's case-marked PP still splits an
    // attached complement. Do not treat this as a supplemental PP front.
    final leftObject = dependencies.where(
      (dependency) =>
          dependency.wordIndex == afterWord - 1 &&
          const {'obj', 'iobj'}.contains(
            dependency.token.deprel.split(':').first,
          ),
    );
    for (final object in leftObject) {
      final rightArguments = dependencies.where(
        (dependency) =>
            dependency.wordIndex >= afterWord &&
            dependency.token.head == object.token.head &&
            const {'obl', 'nmod'}.contains(
              dependency.token.deprel.split(':').first,
            ),
      );
      for (final argument in rightArguments) {
        final startsWithCaseMarker = dependencies.any(
          (dependency) =>
              dependency.wordIndex == afterWord &&
              dependency.token.upos == 'ADP' &&
              dependency.token.head == argument.token.id &&
              dependency.token.deprel.split(':').first == 'case',
        );
        if (startsWithCaseMarker) return true;
      }
    }
    // UD often attaches the obl/nmod above the pre-paren predicate
    // (`change (she knew) to …` → clamor.obl → root). After a closed
    // parenthetical, a case-marked PP at the cut is still an attached
    // complement for read-aloud purposes.
    if (closedParenSpan != null) {
      final caseAtCut = dependencies.any(
        (dependency) =>
            dependency.wordIndex == afterWord &&
            dependency.token.upos == 'ADP' &&
            dependency.token.deprel.split(':').first == 'case',
      );
      if (caseAtCut) return true;
    }
    return false;
  }

  /// Detects a cut at the front or inside a multiword adposition such as
  /// `out of its mouth`. UDPipe represents both marker words as `case`
  /// dependents of the same right-hand nominal. A single marker (`for ...`)
  /// remains a legal explicit continuation and is intentionally unaffected.
  static bool _hasMultiwordAdpositionComplementBoundary(
    int afterWord,
    List<_MappedDependencyV3> dependencies,
  ) {
    final rightMarkers = dependencies.where(
      (dependency) =>
          dependency.wordIndex >= afterWord &&
          dependency.wordIndex <= afterWord + 2 &&
          dependency.token.upos == 'ADP' &&
          dependency.token.deprel.split(':').first == 'case',
    );
    for (final marker in rightMarkers) {
      final sameNominalMarkers = dependencies.where(
        (dependency) =>
            dependency.wordIndex >= afterWord &&
            dependency.wordIndex <= afterWord + 2 &&
            dependency.token.upos == 'ADP' &&
            dependency.token.deprel.split(':').first == 'case' &&
            dependency.token.head == marker.token.head,
      );
      if (sameNominalMarkers.length >= 2) return true;
    }
    return false;
  }

  /// Keeps a compact comparative/adverbial phrase together when its marker
  /// starts on the right, for example `much | as possible`. The complete
  /// phrase may still be separated before it (`appear | as much as possible`).
  static bool _hasAttachedAdverbialComplementBoundary(
    int afterWord,
    List<_MappedDependencyV3> dependencies,
  ) {
    final anchors = dependencies.where(
      (dependency) =>
          dependency.wordIndex == afterWord - 1 &&
          const {'ADJ', 'ADV'}.contains(dependency.token.upos),
    );
    for (final anchor in anchors) {
      final rightComplements = dependencies.where(
        (dependency) =>
            dependency.wordIndex > afterWord &&
            dependency.token.head == anchor.token.id &&
            const {'advcl', 'ccomp'}.contains(
              dependency.token.deprel.split(':').first,
            ),
      );
      for (final complement in rightComplements) {
        final startsWithMarker = dependencies.any(
          (dependency) =>
              dependency.wordIndex == afterWord &&
              dependency.token.head == complement.token.id &&
              const {'mark', 'advmod'}.contains(
                dependency.token.deprel.split(':').first,
              ),
        );
        if (startsWithMarker) return true;
      }
    }
    return false;
  }

  static bool _hasRightSubjectPredicateClause(
    int afterWord,
    List<_MappedDependencyV3> dependencies,
  ) {
    for (final predicate in dependencies) {
      final head = predicate.headWordIndex;
      final relation = predicate.token.deprel.split(':').first;
      if (predicate.wordIndex < afterWord ||
          head == null ||
          head >= afterWord ||
          !_clauseRelations.contains(relation) ||
          !const {'VERB', 'AUX'}.contains(predicate.token.upos)) {
        continue;
      }
      final hasRightSubject = dependencies.any((dependent) {
        if (dependent.wordIndex < afterWord ||
            dependent.token.head != predicate.token.id) {
          return false;
        }
        final dependentRelation = dependent.token.deprel.split(':').first;
        return const {'nsubj', 'csubj', 'expl'}.contains(dependentRelation);
      });
      return hasRightSubject;
    }
    return false;
  }

  static bool _hasDeferredRightSubjectPredicateClause(
    int afterWord,
    int predicateTokenId,
    List<_MappedDependencyV3> dependencies,
  ) {
    final predicate = dependencies
        .where(
          (dependency) =>
              dependency.token.id == predicateTokenId &&
              dependency.wordIndex > afterWord &&
              dependency.wordIndex <= afterWord + 5 &&
              _clauseRelations
                  .contains(dependency.token.deprel.split(':').first),
        )
        .firstOrNull;
    if (predicate == null) return false;
    var hasSubject = false;
    var hasCopula = false;
    for (final dependent in dependencies) {
      if (dependent.wordIndex < afterWord ||
          dependent.token.head != predicate.token.id) {
        continue;
      }
      final relation = dependent.token.deprel.split(':').first;
      hasSubject |= const {'nsubj', 'csubj', 'expl'}.contains(relation);
      hasCopula |= relation == 'cop';
    }
    return hasSubject &&
        (const {'VERB', 'AUX'}.contains(predicate.token.upos) ||
            const {'ADJ', 'NOUN', 'PROPN'}.contains(predicate.token.upos) &&
                hasCopula);
  }

  static bool _hasCoordinatedRightSubjectPredicateClause(
    int afterWord,
    List<_MappedDependencyV3> dependencies,
  ) {
    if (!_startsWithCoordinator(afterWord, dependencies)) return false;
    return dependencies.any(
      (dependency) =>
          dependency.wordIndex > afterWord &&
          dependency.wordIndex <= afterWord + 4 &&
          const {'nsubj', 'csubj', 'expl'}.contains(
            dependency.token.deprel.split(':').first,
          ) &&
          dependencies.any(
            (predicate) =>
                predicate.token.id == dependency.token.head &&
                predicate.wordIndex > dependency.wordIndex &&
                const {'VERB', 'AUX'}.contains(predicate.token.upos),
          ),
    );
  }

  static bool _hasRecoveredCoordinatedRightSubjectPredicateClause(
    int afterWord,
    List<_MappedDependencyV3> dependencies,
  ) {
    if (!_startsWithCoordinator(afterWord, dependencies)) return false;
    // Some UD parses attach the coordinated clause's nominal subject as a
    // nominal `conj` of the preceding clause and attach its delayed predicate
    // separately as a verbal `conj`. Treat that paired evidence as the same
    // complete right-side subject/predicate clause.
    final nominalConj = dependencies
        .where(
          (dependency) =>
              dependency.wordIndex > afterWord &&
              dependency.wordIndex <= afterWord + 4 &&
              const {'NOUN', 'PROPN', 'PRON'}.contains(dependency.token.upos) &&
              dependency.token.deprel.split(':').first == 'conj',
        )
        .firstOrNull;
    if (nominalConj == null) return false;
    return dependencies.any(
      (dependency) =>
          dependency.wordIndex > nominalConj.wordIndex &&
          const {'VERB', 'AUX'}.contains(dependency.token.upos) &&
          dependency.token.deprel.split(':').first == 'conj',
    );
  }

  static bool _isAttributionOnlyRightTail(
    int afterWord,
    List<_MappedDependencyV3> dependencies,
  ) {
    // A coordinator at the quote edge opens a coordinated clause or phrase;
    // it is not a reporting tail (`"...!" and the Mole ...`).
    if (_startsWithCoordinator(afterWord, dependencies)) return false;
    final rightPredicates = dependencies
        .where(
          (dependency) =>
              dependency.wordIndex >= afterWord &&
              dependency.token.upos == 'VERB' &&
              !const {'acl', 'advcl', 'ccomp', 'xcomp'}
                  .contains(dependency.token.deprel.split(':').first),
        )
        .map((dependency) => dependency.wordIndex)
        .toSet();
    if (rightPredicates.length != 1) return false;
    return dependencies.any(
      (dependency) =>
          dependency.wordIndex >= afterWord &&
          const {'nsubj', 'csubj', 'expl'}
              .contains(dependency.token.deprel.split(':').first),
    );
  }

  static bool _startsWithCoordinator(
    int afterWord,
    List<_MappedDependencyV3> dependencies,
  ) =>
      dependencies.any(
        (dependency) =>
            dependency.wordIndex == afterWord &&
            dependency.token.upos == 'CCONJ',
      );

  static String _edgeLexeme(String value) {
    final matches = _edgeLexemePattern
        .allMatches(value.toLowerCase())
        .toList(growable: false);
    return matches.isEmpty ? '' : matches.last.group(0)!;
  }

  static String _segmentText(
    String sentence,
    List<_SourceWordV3> words,
    int start,
    int end,
  ) =>
      sentence
          .substring(words[start].start, words[end - 1].end)
          .replaceAll(_whitespace, ' ')
          .trim();

  static List<int> _requiredBoundaryOffsets(
    List<ReadAloudOriginalDecisionV3> originals,
  ) {
    final offsets = <int>[];
    var words = 0;
    for (final original in originals) {
      words += wordCount(original.source);
      offsets.add(words);
    }
    return offsets;
  }

  /// One-word post-merge may absorb an orthographic original boundary; only
  /// require boundaries that still appear after [mergeOneWordChunks].
  static List<int> _survivingRequiredBoundaryOffsets(
    List<ReadAloudOriginalDecisionV3> originals,
    List<String> mergedSentences,
  ) {
    final required = _requiredBoundaryOffsets(originals);
    final actual = <int>{};
    var cumulative = 0;
    for (final sentence in mergedSentences) {
      cumulative += wordCount(sentence);
      actual.add(cumulative);
    }
    return [
      for (final offset in required)
        if (actual.contains(offset)) offset,
    ];
  }

  static void validateReviewedSentences(
    String englishContent,
    List<String> sentences, {
    Iterable<int> requiredBoundaryWordOffsets = const [],
    bool rejectOneWordChunks = false,
  }) {
    if (sentences.isEmpty) {
      throw const FormatException('审核分句不能为空');
    }
    final actualBoundaries = <int>{};
    var cumulativeWords = 0;
    for (var index = 0; index < sentences.length; index += 1) {
      final sentence = sentences[index];
      if (sentence.trim().isEmpty) {
        throw FormatException('审核分句第 ${index + 1} 块为空');
      }
      if (sentence.contains('\n') || sentence.contains('\r')) {
        throw FormatException('审核分句第 ${index + 1} 块含显示换行');
      }
      final count = wordCount(sentence);
      if (rejectOneWordChunks && sentences.length > 1 && count == 1) {
        throw FormatException('审核分句第 ${index + 1} 块仅 1 词，必须局部合并');
      }
      if (count > hardMaxWords) {
        throw FormatException('审核分句第 ${index + 1} 块为 $count 词，超过 30 词硬上限');
      }
      final span = maxUnpunctuatedWordCount(sentence);
      if (span > hardMaxUnpunctuatedWords) {
        throw FormatException(
          '审核分句第 ${index + 1} 块最长无标点连续段为 $span 词，超过 30 词硬上限',
        );
      }
      cumulativeWords += count;
      actualBoundaries.add(cumulativeWords);
    }
    final roundTripMismatch = _roundTripMismatch(
      englishContent: englishContent,
      sentences: sentences,
    );
    if (roundTripMismatch != null) {
      throw FormatException('审核分句规范化拼接与最终英文正文不一致：$roundTripMismatch');
    }
    for (final required in requiredBoundaryWordOffsets) {
      if (required > 0 && !actualBoundaries.contains(required)) {
        throw const FormatException('审核分句跨越了朗读求解单元或段落硬边界');
      }
    }
  }
}
