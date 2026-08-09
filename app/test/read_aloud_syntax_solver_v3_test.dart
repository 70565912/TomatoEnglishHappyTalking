import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v3.dart';

void main() {
  group('ReadAloudSplitterV3 syntax solver', () {
    test('keeps every safe original sentence unchanged, including short ones',
        () {
      const source = 'Mole looked up. Rat waved back. Toad laughed loudly.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, const [
          'Mole looked up.',
          'Rat waved back.',
          'Toad laughed loudly.',
        ]),
      );

      expect(plan.localSentences, const [
        'Mole looked up.',
        'Rat waved back.',
        'Toad laughed loudly.',
      ]);
      expect(
        plan.originals.map((value) => value.localPath.stage),
        everyElement(ReadAloudPathStageV3.unchanged),
      );
      expect(plan.requiresAiReview, isFalse);
    });

    test('uses a feasible strong-punctuation path without AI', () {
      final left = _words('left', 18);
      final right = _words('right', 18);
      final source = '$left; $right.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, [source]),
      );

      final selected = plan.originals.single.localPath;
      expect(selected.stage, ReadAloudPathStageV3.punctuation);
      expect(selected.boundaries, hasLength(1));
      expect(
        selected.boundaries.single.kind,
        ReadAloudBoundaryKindV3.strongPunctuation,
      );
      expect(selected.wordCounts, const [18, 18]);
      expect(selected.usesNonPunctuation, isFalse);
      expect(plan.requiresAiReview, isFalse);
    });

    test('accepts a comma before a right-side subject-predicate clause', () {
      final tokens = List.generate(33, (index) => 'word${index + 1}');
      tokens[8] = '${tokens[8]},';
      tokens[19] = '${tokens[19]},';
      tokens[29] = '${tokens[29]},';
      tokens[30] = '"We';
      tokens[31] = 'move!';
      tokens[32] = '${tokens[32]}.';
      final source = tokens.join(' ');
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          [source],
          relationsBySentence: const [
            {
              10: (head: 13, relation: 'cc'),
              12: (head: 13, relation: 'nsubj'),
              13: (head: 3, relation: 'conj'),
              21: (head: 3, relation: 'conj'),
              22: (head: 21, relation: 'nsubj'),
              31: (head: 32, relation: 'nsubj'),
              32: (head: 3, relation: 'acl:relcl'),
            },
          ],
          uposBySentence: const [
            {
              10: 'CCONJ',
              12: 'PRON',
              13: 'VERB',
              21: 'VERB',
              22: 'PRON',
              31: 'PRON',
              32: 'VERB',
            },
          ],
        ),
      );

      final selected = plan.originals.single.localPath;
      expect(selected.stage, ReadAloudPathStageV3.punctuation);
      expect(
        selected.wordCounts,
        anyOf(equals(const [9, 24]), equals(const [20, 13])),
      );
      expect(
          selected.boundaries.single.kind, ReadAloudBoundaryKindV3.clauseComma);
      expect(selected.usesNonPunctuation, isFalse);
      expect(plan.requiresAiReview, isFalse);
      expect(
        plan.originals.single.candidatePaths
            .expand((path) => path.boundaries)
            .any((boundary) => boundary.afterWord == 30),
        isFalse,
      );
    });

    test('uses a complete dependency clause only when punctuation has no path',
        () {
      final source = '${_words('main', 10)} ${_words('clause', 11)}';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          [source],
          relationsBySentence: const [
            {
              11: (head: 10, relation: 'advcl'),
            },
          ],
        ),
      );

      final selected = plan.originals.single.localPath;
      expect(selected.stage, ReadAloudPathStageV3.syntax);
      expect(selected.wordCounts, const [10, 11]);
      expect(
        selected.boundaries.single.kind,
        ReadAloudBoundaryKindV3.dependencyClause,
      );
      expect(selected.boundaries.single.protectedRelationCrossings, 0);
      expect(plan.requiresAiReview, isTrue);
    });

    test('ignores a final punctuation arc when judging a clause boundary', () {
      final source = '${_words('main', 10)} ${_words('clause', 11)}.';
      final words = RegExp(r'\S+').allMatches(source).toList(growable: false);
      final tokens = <DependencyTokenV3>[];
      for (var index = 0; index < words.length; index += 1) {
        final match = words[index];
        final raw = match.group(0)!;
        final text = raw.endsWith('.') ? raw.substring(0, raw.length - 1) : raw;
        tokens.add(
          DependencyTokenV3(
            id: index + 1,
            text: text,
            sourceText: text,
            start: match.start,
            end: match.start + text.length,
            upos: index == 10 ? 'VERB' : 'NOUN',
            head: index == 10 ? 10 : 0,
            deprel: index == 10 ? 'advcl' : 'root',
          ),
        );
      }
      tokens.add(
        DependencyTokenV3(
          id: words.length + 1,
          text: '.',
          sourceText: '.',
          start: source.length - 1,
          end: source.length,
          upos: 'PUNCT',
          head: 10,
          deprel: 'punct',
        ),
      );
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: DependencyDocumentV3(
          parserVersion: 'fake_udpipe_1.4',
          modelSha256: 'fake-model-sha256',
          sentences: [
            DependencySentenceV3(
              start: 0,
              end: source.length,
              tokens: tokens,
            ),
          ],
          healthy: true,
        ),
      );

      final selected = plan.originals.single.localPath;
      expect(selected.stage, ReadAloudPathStageV3.syntax);
      expect(selected.wordCounts, const [10, 11]);
      expect(
        selected.boundaries.single.kind,
        ReadAloudBoundaryKindV3.dependencyClause,
      );
      expect(
        selected.boundaries.single.reasons
            .any((reason) => reason.contains('punct')),
        isFalse,
      );
    });

    test('keeps a protected dependency crossing as high-risk soft evidence',
        () {
      final source = '${_words('left', 10)} ${_words('right', 11)}';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          [source],
          relationsBySentence: const [
            {
              11: (head: 10, relation: 'det'),
            },
          ],
        ),
      );

      final decision = plan.originals.single;
      expect(
        decision.candidatePaths
            .expand((path) => path.boundaries)
            .any((boundary) => boundary.protectedRelationCrossings > 0),
        isTrue,
      );
      expect(
        decision.localPath.boundaries
            .every((boundary) => boundary.protectedRelationCrossings == 0),
        isTrue,
      );
    });

    test('flags a nominal-to-finite-predicate surface boundary as soft risk',
        () {
      final source = _words('word', 21);
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          [source],
          relationsBySentence: const [
            {
              11: (head: 12, relation: 'aux'),
              12: (head: 1, relation: 'conj'),
            },
          ],
          uposBySentence: const [
            {10: 'NOUN', 11: 'AUX', 12: 'VERB'},
          ],
        ),
      );

      final warned = plan.originals.single.candidatePaths
          .expand((path) => path.boundaries)
          .firstWhere((boundary) => boundary.afterWord == 10);
      expect(
        warned.softWarnings,
        contains('surface_possible_subject_predicate_separation'),
      );
      expect(warned.hardBlocked, isFalse);
    });

    test('exposes eight initial and at most twenty-four expanded stable paths',
        () {
      final source = _words('word', 43);
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, [source]),
      );
      final decision = plan.originals.single;

      expect(decision.initialCandidatePaths.length, lessThanOrEqualTo(8));
      expect(decision.expandedCandidatePaths.length, lessThanOrEqualTo(24));
      expect(
        decision.expandedCandidatePaths.length,
        greaterThanOrEqualTo(decision.initialCandidatePaths.length),
      );
      expect(
        decision.candidatePaths.map((path) => path.pathId).toSet(),
        hasLength(decision.candidatePaths.length),
      );
      expect(
        () => ReadAloudSplitterV3.validateSelectedPathIds(
          plan,
          const {0: 'v3_o0_invented'},
        ),
        throwsFormatException,
      );
      final selected = decision.candidatePaths.last;
      expect(
        ReadAloudSplitterV3.applySelectedPathIds(
          plan,
          {0: selected.pathId},
        ),
        selected.segments,
      );
    });

    test('rejects parser offsets that do not reproduce the source', () {
      const source = 'Mole looked up.';
      const invalid = DependencyDocumentV3(
        parserVersion: 'fake_udpipe_1.4',
        modelSha256: 'fake-model-sha256',
        healthy: true,
        sentences: [
          DependencySentenceV3(
            start: 0,
            end: source.length,
            tokens: [
              DependencyTokenV3(
                id: 1,
                text: 'Rat',
                start: 0,
                end: 4,
                upos: 'NOUN',
                head: 0,
                deprel: 'root',
              ),
            ],
          ),
        ],
      );

      expect(
        () => ReadAloudSplitterV3.plan(source: source, document: invalid),
        throwsFormatException,
      );
    });
  });
}

String _words(String prefix, int count) =>
    List.generate(count, (index) => '$prefix${index + 1}').join(' ');

DependencyDocumentV3 _document(
  String source,
  List<String> sentences, {
  List<Map<int, ({int head, String relation})>> relationsBySentence = const [],
  List<Map<int, String>> uposBySentence = const [],
}) {
  final parsed = <DependencySentenceV3>[];
  var sourceCursor = 0;
  for (var sentenceIndex = 0;
      sentenceIndex < sentences.length;
      sentenceIndex += 1) {
    final sentence = sentences[sentenceIndex];
    final sentenceStart = source.indexOf(sentence, sourceCursor);
    if (sentenceStart < 0) {
      throw StateError('Test sentence not found in source: $sentence');
    }
    final relations = sentenceIndex < relationsBySentence.length
        ? relationsBySentence[sentenceIndex]
        : const <int, ({int head, String relation})>{};
    final upos = sentenceIndex < uposBySentence.length
        ? uposBySentence[sentenceIndex]
        : const <int, String>{};
    final tokens = <DependencyTokenV3>[];
    var id = 0;
    for (final match in RegExp(r'\S+').allMatches(sentence)) {
      id += 1;
      final relation = relations[id];
      tokens.add(
        DependencyTokenV3(
          id: id,
          text: match.group(0)!,
          start: sentenceStart + match.start,
          end: sentenceStart + match.end,
          upos: upos[id] ?? 'NOUN',
          head: relation?.head ?? 0,
          deprel: relation?.relation ?? 'root',
        ),
      );
    }
    parsed.add(
      DependencySentenceV3(
        start: sentenceStart,
        end: sentenceStart + sentence.length,
        tokens: tokens,
      ),
    );
    sourceCursor = sentenceStart + sentence.length;
  }
  return DependencyDocumentV3(
    parserVersion: 'fake_udpipe_1.4',
    modelSha256: 'fake-model-sha256',
    sentences: parsed,
    healthy: true,
  );
}
