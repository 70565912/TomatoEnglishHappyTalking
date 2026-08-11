import 'dart:math' as math;

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

    test('keeps a twenty-word sentence without an internal pause unchanged',
        () {
      final source = '${_words('word', 20)}.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, [source]),
      );

      expect(plan.localSentences, [source]);
      expect(
        plan.originals.single.localPath.stage,
        ReadAloudPathStageV3.unchanged,
      );
    });

    test('splits seventeen to twenty words at a qualified clause comma', () {
      final tokens = List.generate(17, (index) => 'word${index + 1}');
      tokens[7] = '${tokens[7]},';
      tokens[16] = '${tokens[16]}.';
      final source = tokens.join(' ');
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          [source],
          relationsBySentence: const [
            {
              9: (head: 10, relation: 'nsubj'),
              10: (head: 1, relation: 'conj'),
            },
          ],
          uposBySentence: const [
            {9: 'NOUN', 10: 'VERB'},
          ],
        ),
      );

      expect(plan.localSentences.map(ReadAloudSplitterV3.wordCount), [8, 9]);
      expect(
        plan.originals.single.localPath.boundaries.single.kind,
        ReadAloudBoundaryKindV3.clauseComma,
      );
    });

    test('does not split a seventeen-word list at ambiguous commas', () {
      final tokens = List.generate(17, (index) => 'item${index + 1}');
      tokens[3] = '${tokens[3]},';
      tokens[7] = '${tokens[7]},';
      tokens[11] = '${tokens[11]},';
      tokens[16] = '${tokens[16]}.';
      final source = tokens.join(' ');
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, [source]),
      );

      expect(plan.localSentences, [source]);
      expect(
        plan.originals.single.candidatePaths
            .expand((path) => path.boundaries)
            .where(
              (boundary) =>
                  boundary.kind == ReadAloudBoundaryKindV3.ambiguousComma,
            ),
        isNotEmpty,
      );
    });

    test('eliminates a near-limit 8/29 path before minimizing cuts', () {
      final tokens = List.generate(37, (index) => 'word${index + 1}');
      tokens[7] = '${tokens[7]},';
      tokens[29] = '${tokens[29]},';
      tokens[36] = '${tokens[36]}.';
      final source = tokens.join(' ');
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          [source],
          relationsBySentence: const [
            {
              5: (head: 27, relation: 'advcl'),
              31: (head: 27, relation: 'advcl'),
            },
          ],
          uposBySentence: const [
            {5: 'VERB', 27: 'VERB', 31: 'VERB'},
          ],
        ),
      );

      final counts = plan.originals.single.localPath.wordCounts;
      expect(counts, isNot(const [8, 29]));
      expect(counts.reduce(math.max), lessThanOrEqualTo(22));
    });

    test('does not hard-block punctuation glued to the next parser token', () {
      final left = _words('left', 18);
      final right = _words('right', 12);
      final source = '$left—$right.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, [source]),
      );

      expect(
        plan.originals.single.localPath.wordCounts,
        const [18, 12],
      );
      expect(
        plan.originals.single.localPath.boundaries.single.kind,
        ReadAloudBoundaryKindV3.strongPunctuation,
      );
      expect(
        plan.originals.single.localPath.boundaries.single.hardBlocked,
        isFalse,
      );
    });

    test('keeps punctuation-only parser sentences attached to prior text', () {
      const source = 'First words.—" Both animals nodded gravely.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const ['First words.', '—"', 'Both animals nodded gravely.'],
        ),
      );

      expect(plan.originals, hasLength(2));
      expect(
        plan.localSentences,
        const ['First words.—"', 'Both animals nodded gravely.'],
      );
      expect(
        ReadAloudSplitterV3.isRoundTripEquivalent(
          englishContent: source,
          sentences: plan.localSentences,
        ),
        isTrue,
      );
    });

    test('maps a UDPipe token that keeps a leading em dash', () {
      const source = 'leaves thrusting—everything happy.';
      final dash = source.indexOf('—');
      final happy = source.indexOf('happy');
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: DependencyDocumentV3(
          parserVersion: 'fake_udpipe_1.4',
          modelSha256: 'fake-model-sha256',
          healthy: true,
          sentences: [
            DependencySentenceV3(
              start: 0,
              end: source.length,
              tokens: [
                const DependencyTokenV3(
                  id: 1,
                  text: 'leaves',
                  start: 0,
                  end: 6,
                  upos: 'NOUN',
                  head: 2,
                  deprel: 'nsubj',
                ),
                DependencyTokenV3(
                  id: 2,
                  text: 'thrusting',
                  start: 7,
                  end: dash,
                  upos: 'VERB',
                  head: 0,
                  deprel: 'root',
                ),
                DependencyTokenV3(
                  id: 3,
                  text: '—everything',
                  start: dash,
                  end: happy - 1,
                  upos: 'PRON',
                  head: 2,
                  deprel: 'obj',
                ),
                DependencyTokenV3(
                  id: 4,
                  text: 'happy',
                  start: happy,
                  end: source.length - 1,
                  upos: 'ADJ',
                  head: 2,
                  deprel: 'xcomp',
                ),
                const DependencyTokenV3(
                  id: 5,
                  text: '.',
                  start: source.length - 1,
                  end: source.length,
                  upos: 'PUNCT',
                  head: 2,
                  deprel: 'punct',
                ),
              ],
            ),
          ],
        ),
      );

      expect(plan.parserHealthy, isTrue);
      expect(plan.originals.single.parserIssues, isEmpty);
      expect(plan.localSentences, const [source]);
    });

    test('maps a punctuation-only UDPipe token across an em-dash pause', () {
      const source = 'Toad"—(great applause).';
      final dash = source.indexOf('—');
      final great = source.indexOf('great');
      final applause = source.indexOf('applause');
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: DependencyDocumentV3(
          parserVersion: 'fake_udpipe_1.4',
          modelSha256: 'fake-model-sha256',
          healthy: true,
          sentences: [
            DependencySentenceV3(
              start: 0,
              end: source.length,
              tokens: [
                const DependencyTokenV3(
                  id: 1,
                  text: 'Toad',
                  start: 0,
                  end: 4,
                  upos: 'PROPN',
                  head: 4,
                  deprel: 'nsubj',
                ),
                const DependencyTokenV3(
                  id: 2,
                  text: '"',
                  start: 4,
                  end: 5,
                  upos: 'PUNCT',
                  head: 4,
                  deprel: 'punct',
                ),
                DependencyTokenV3(
                  id: 3,
                  text: '—(',
                  start: dash,
                  end: great,
                  upos: 'PUNCT',
                  head: 4,
                  deprel: 'punct',
                ),
                DependencyTokenV3(
                  id: 4,
                  text: 'great',
                  start: great,
                  end: applause - 1,
                  upos: 'ADJ',
                  head: 0,
                  deprel: 'root',
                ),
                DependencyTokenV3(
                  id: 5,
                  text: 'applause',
                  start: applause,
                  end: source.length - 2,
                  upos: 'NOUN',
                  head: 4,
                  deprel: 'obj',
                ),
                const DependencyTokenV3(
                  id: 6,
                  text: ').',
                  start: source.length - 2,
                  end: source.length,
                  upos: 'PUNCT',
                  head: 4,
                  deprel: 'punct',
                ),
              ],
            ),
          ],
        ),
      );

      expect(plan.parserHealthy, isTrue);
      expect(plan.originals.single.parserIssues, isEmpty);
      expect(plan.localSentences, const [source]);
    });

    test('rejects meaningless four-word fragments before crossing evidence',
        () {
      final tokens = List.generate(40, (index) => 'word${index + 1}');
      for (final position in const [13, 20, 24, 28, 32]) {
        tokens[position - 1] = '${tokens[position - 1]},';
      }
      tokens[39] = '${tokens[39]}.';
      final source = tokens.join(' ');
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          [source],
          relationsBySentence: const [
            {
              13: (head: 14, relation: 'nsubj'),
            },
          ],
          uposBySentence: const [
            {13: 'NOUN', 14: 'VERB'},
          ],
        ),
      );

      final counts = plan.originals.single.localPath.wordCounts;
      expect(counts, everyElement(greaterThan(5)));
      expect(counts.reduce(math.max), lessThanOrEqualTo(20));
      expect(
        plan.originals.single.candidatePaths.any(
          (path) =>
              path.wordCounts.length == 3 &&
              path.wordCounts[0] == 13 &&
              path.wordCounts[1] == 19 &&
              path.wordCounts[2] == 8,
        ),
        isTrue,
      );
    });

    test('does not manufacture a one-to-three-word trailing exclamation', () {
      final tokens = List.generate(23, (index) => 'word${index + 1}');
      tokens[6] = '${tokens[6]},';
      tokens[20] = '${tokens[20]},';
      tokens[22] = '${tokens[22]}!';
      final source = tokens.join(' ');
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          [source],
          relationsBySentence: const [
            {
              8: (head: 9, relation: 'nsubj'),
              9: (head: 1, relation: 'conj'),
              22: (head: 23, relation: 'nsubj'),
              23: (head: 1, relation: 'conj'),
            },
          ],
          uposBySentence: const [
            {8: 'NOUN', 9: 'VERB', 22: 'NOUN', 23: 'VERB'},
          ],
        ),
      );

      expect(plan.originals.single.localPath.wordCounts, const [7, 16]);
    });

    test('uses all qualified E61 commas to optimize reading chunks', () {
      const source =
          'When the other animals came back to luncheon, very boisterous and breezy after a morning on the river, the Mole, whose conscience had been pricking him, looked doubtfully at Toad, expecting to find him sulky or depressed.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              4: (head: 5, relation: 'nsubj'),
              5: (head: 27, relation: 'advcl'),
              20: (head: 27, relation: 'nsubj'),
              21: (head: 22, relation: 'nmod:poss'),
              25: (head: 20, relation: 'acl:relcl'),
              31: (head: 27, relation: 'advcl'),
            },
          ],
          uposBySentence: const [
            {
              4: 'NOUN',
              5: 'VERB',
              20: 'NOUN',
              21: 'PRON',
              22: 'NOUN',
              25: 'VERB',
              27: 'VERB',
              31: 'VERB',
            },
          ],
        ),
      );

      expect(
        plan.originals.single.localPath.wordCounts,
        const [8, 10, 12, 7],
      );
      expect(
        plan.localSentences,
        const [
          'When the other animals came back to luncheon,',
          'very boisterous and breezy after a morning on the river,',
          'the Mole, whose conscience had been pricking him, looked doubtfully at Toad,',
          'expecting to find him sulky or depressed.',
        ],
      );
      final rejectedAntecedentBoundary = plan.originals.single.candidatePaths
          .expand((path) => path.boundaries)
          .firstWhere((boundary) => boundary.afterWord == 20);
      expect(
        rejectedAntecedentBoundary.softWarnings,
        contains('surface_possible_antecedent_possessive_separation'),
      );
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

    test('flags lexical attachment gaps missed by a dependency tree', () {
      final tokens = List.generate(32, (index) => 'word${index + 1}');
      tokens[4] = 'pail';
      tokens[5] = 'of';
      tokens[9] = 'all';
      tokens[10] = 'three';
      tokens[14] = 'wherever';
      tokens[15] = 'they';
      tokens[19] = 'allowed';
      tokens[20] = 'his';
      tokens[21] = 'grudging,';
      tokens[22] = 'timid';
      tokens[23] = 'excursionists.';
      final source = tokens.join(' ');
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          [source],
          uposBySentence: const [
            {
              20: 'VERB',
              21: 'DET',
              23: 'ADJ',
              24: 'NOUN',
              25: 'NOUN',
              26: 'PRON',
              27: 'AUX',
              28: 'ADV',
            },
          ],
        ),
      );
      final boundaries = {
        for (final boundary in plan.originals.single.boundaryCandidates)
          boundary.afterWord: boundary,
      };

      expect(
        boundaries[5]!.softWarnings,
        contains('surface_preposition_attachment_separation'),
      );
      expect(
        boundaries[10]!.softWarnings,
        contains('surface_quantifier_numeral_separation'),
      );
      expect(
        boundaries[15]!.softWarnings,
        contains('surface_relative_marker_subject_separation'),
      );
      expect(
        boundaries[20]!.softWarnings,
        contains('surface_predicate_possessive_object_separation'),
      );
      expect(
        boundaries[20]!.softWarnings,
        contains('surface_predicate_determiner_object_separation'),
      );
      expect(
        boundaries[21]!.softWarnings,
        contains('surface_determiner_head_separation'),
      );
      expect(
        boundaries[22]!.softWarnings,
        contains('surface_parallel_list_item_separation'),
      );
      expect(
        boundaries[23]!.softWarnings,
        contains('surface_modifier_head_separation'),
      );
      expect(
        boundaries[25]!.softWarnings,
        contains('surface_nominal_relative_pronoun_separation'),
      );
      expect(
        boundaries[27]!.softWarnings,
        contains('surface_auxiliary_adverb_complement_separation'),
      );
    });

    test('flags explicit subject, object, and infinitive relation gaps', () {
      final tokens = List.generate(24, (index) => 'word${index + 1}');
      tokens[11] = 'began';
      tokens[12] = 'working';
      tokens[16] = 'wandering';
      tokens[17] = 'back';
      tokens[18] = 'to';
      tokens[20] = 'as';
      tokens[21] = 'if';
      tokens[22] = 'his';
      tokens[23] = 'dulled.';
      final source = tokens.join(' ');
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          [source],
          relationsBySentence: const [
            {
              10: (head: 11, relation: 'nsubj'),
              11: (head: 1, relation: 'conj'),
              13: (head: 12, relation: 'xcomp'),
              16: (head: 15, relation: 'obj'),
              18: (head: 17, relation: 'advmod'),
              19: (head: 20, relation: 'mark'),
              20: (head: 1, relation: 'xcomp'),
              23: (head: 24, relation: 'nmod:poss'),
            },
          ],
          uposBySentence: const [
            {
              10: 'NOUN',
              11: 'VERB',
              12: 'VERB',
              13: 'VERB',
              15: 'VERB',
              16: 'PRON',
              17: 'VERB',
              18: 'ADV',
              19: 'PART',
              20: 'VERB',
              23: 'PRON',
              24: 'ADJ',
            },
          ],
        ),
      );
      final boundaries = {
        for (final boundary in plan.originals.single.candidatePaths
            .expand((path) => path.boundaries))
          boundary.afterWord: boundary,
      };

      expect(
        boundaries[10]!.softWarnings,
        contains('surface_subject_predicate_relation_separation'),
      );
      expect(
        boundaries[12]!.softWarnings,
        contains('surface_xcomp_predicate_separation'),
      );
      expect(
        boundaries[15]!.softWarnings,
        contains('surface_object_relation_separation'),
      );
      expect(
        boundaries[17]!.softWarnings,
        contains('surface_adverb_attachment_separation'),
      );
      expect(
        boundaries[19]!.softWarnings,
        contains('surface_infinitive_marker_predicate_separation'),
      );
      expect(
        boundaries[21]!.softWarnings,
        contains('surface_fixed_connector_separation'),
      );
      expect(
        plan.originals.single.localPath.boundaries
            .map((boundary) => boundary.afterWord),
        isNot(contains(23)),
      );
    });

    test('keeps a complement marker with its nested subordinate clause', () {
      final tokens = List.generate(25, (index) => 'word${index + 1}');
      tokens[8] = 'that';
      tokens[9] = 'if';
      tokens[24] = '${tokens[24]}.';
      final source = tokens.join(' ');
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, [source]),
      );
      final warned = plan.originals.single.candidatePaths
          .expand((path) => path.boundaries)
          .firstWhere((boundary) => boundary.afterWord == 9);

      expect(
        warned.softWarnings,
        contains('surface_fixed_connector_separation'),
      );
      expect(
        plan.originals.single.localPath.boundaries
            .map((boundary) => boundary.afterWord),
        isNot(contains(9)),
      );
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

    test('repairs UDPipe sentence breaks after title abbreviations', () {
      const source =
          'He answered, "Mr. Toad has changed his mind. Dr. Badger agrees."';
      final document = _document(
        source,
        const [
          'He answered, "Mr.',
          'Toad has changed his mind.',
          'Dr.',
          'Badger agrees."',
        ],
      );

      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: document,
      );

      expect(plan.localSentences, isNot(contains('He answered, "Mr.')));
      expect(plan.localSentences, isNot(contains('Dr.')));
      expect(
        ReadAloudSplitterV3.isRoundTripEquivalent(
          englishContent: source,
          sentences: plan.localSentences,
        ),
        isTrue,
      );
    });

    test('keeps the complete Onion-sauce cry and cuts after its quote', () {
      const source =
          '"Onion-sauce! Onion-sauce!" he remarked jeeringly, and was gone before they could think of a thoroughly satisfactory reply.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [
            '"Onion-sauce!',
            'Onion-sauce!" he remarked jeeringly, and was gone before they could think of a thoroughly satisfactory reply.',
          ],
        ),
      );

      expect(plan.localSentences, const [
        '"Onion-sauce! Onion-sauce!"',
        'he remarked jeeringly, and was gone before they could think of a thoroughly satisfactory reply.',
      ]);
      expect(plan.originals, hasLength(1));
      final blocked = plan.originals.single.boundaryCandidates
          .firstWhere((candidate) => candidate.afterWord == 1);
      expect(blocked.insideQuotedSpeech, isTrue);
      expect(blocked.quoteSpanWordCount, 2);
      expect(blocked.hardBlocked, isTrue);
      expect(blocked.hardBlockReasons, contains('inside_short_complete_quote'));
      final selected = plan.originals.single.localPath.boundaries.single;
      expect(selected.quoteEdge, 'after_closing');
      expect(selected.insideQuotedSpeech, isFalse);
    });

    test('keeps both Up we go cries and prefers the closing quote edge', () {
      const source =
          'working busily with his little paws and muttering to himself, "Up we go! Up we go!" till at last, pop! his snout came out into the sunlight and he found himself';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [
            'working busily with his little paws and muttering to himself, "Up we go!',
            'Up we go!" till at last, pop! his snout came out into the sunlight and he found himself',
          ],
        ),
      );

      expect(plan.localSentences, const [
        'working busily with his little paws and muttering to himself, "Up we go! Up we go!"',
        'till at last, pop! his snout came out into the sunlight and he found himself',
      ]);
      expect(
        plan.originals.first.localPath.boundaries.single.quoteEdge,
        'after_closing',
      );
    });

    test('hard-blocks all internal cuts in matched quotes up to sixteen words',
        () {
      for (final quoteMarks in const [('"', '"'), ('“', '”')]) {
        final source =
            '${quoteMarks.$1}Ratty! Ratty! Come back at once, dear Rat!${quoteMarks.$2} Mole waited outside.';
        final firstParserSentence = '${quoteMarks.$1}Ratty!';
        final plan = ReadAloudSplitterV3.plan(
          source: source,
          document: _document(
            source,
            [
              firstParserSentence,
              'Ratty! Come back at once, dear Rat!${quoteMarks.$2} Mole waited outside.',
            ],
          ),
        );

        expect(plan.originals, hasLength(1));
        final internal = plan.originals.single.boundaryCandidates
            .where((candidate) => candidate.insideQuotedSpeech);
        expect(internal, isNotEmpty);
        expect(
            internal,
            everyElement(predicate<ReadAloudBoundaryCandidateV3>(
              (candidate) =>
                  candidate.hardBlocked &&
                  candidate.hardBlockReasons
                      .contains('inside_short_complete_quote'),
            )));
        expect(
          plan.localSentences.join(' '),
          isNot(contains('${quoteMarks.$1}Ratty! Ratty! |')),
        );
      }
    });

    test('does not treat a quote-leading em dash as an external quote edge',
        () {
      const source =
          'The dreamer lay on his back at the bottom of the boat, his heels in the air. "—about in boats—or with boats," the Rat went on composedly, picking himself up with a pleasant laugh.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, const [source]),
      );

      final blocked = plan.originals.single.boundaryCandidates.firstWhere(
        (candidate) =>
            candidate.quoteSpanWordCount == 6 &&
            candidate.hardBlockReasons.contains('inside_short_complete_quote'),
      );
      expect(blocked.insideQuotedSpeech, isTrue);
      expect(blocked.quoteEdge, isNull);
      expect(
        plan.localSentences.any((sentence) => sentence.endsWith('"—')),
        isFalse,
      );
    });

    test('allows ordinary punctuation splitting inside a seventeen-word quote',
        () {
      final quoteWords = List.generate(17, (index) => 'word${index + 1}');
      quoteWords[7] = '${quoteWords[7]}!';
      quoteWords[16] = '${quoteWords[16]}!';
      final source = '"${quoteWords.join(' ')}"';
      final first = '"${quoteWords.take(8).join(' ')}';
      final second = '${quoteWords.skip(8).join(' ')}"';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, [first, second]),
      );

      expect(plan.localSentences.map(ReadAloudSplitterV3.wordCount), [8, 9]);
      final selected = plan.originals.single.localPath.boundaries.single;
      expect(selected.insideQuotedSpeech, isTrue);
      expect(selected.quoteSpanWordCount, 17);
      expect(selected.hardBlocked, isFalse);
    });

    test('uses quote-internal punctuation when a long quote needs it', () {
      final quoteWords = List.generate(35, (index) => 'word${index + 1}');
      quoteWords[17] = '${quoteWords[17]};';
      quoteWords[34] = '${quoteWords[34]}.';
      final source = '“${quoteWords.join(' ')}”';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, [source]),
      );

      expect(plan.localSentences.map(ReadAloudSplitterV3.wordCount), [18, 17]);
      expect(
        plan.originals.single.localPath.boundaries.single.insideQuotedSpeech,
        isTrue,
      );
      expect(
        plan.localSentences.map(ReadAloudSplitterV3.wordCount),
        everyElement(lessThanOrEqualTo(30)),
      );
    });

    test('does not merge parser sentences across adjacent matched quotes', () {
      const source = '"Ratty! Ratty!" "Mole! Mole!" They both listened.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, const [
          '"Ratty! Ratty!"',
          '"Mole! Mole!"',
          'They both listened.',
        ]),
      );

      expect(plan.originals, hasLength(3));
      expect(plan.localSentences, const [
        '"Ratty! Ratty!"',
        '"Mole! Mole!"',
        'They both listened.',
      ]);
    });

    test('keeps a short attribution tail attached to its quote', () {
      final quoteWords = List.generate(14, (index) => 'word${index + 1}');
      quoteWords[13] = '${quoteWords[13]}.';
      final source = '"${quoteWords.join(' ')}" he said quietly.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          [source],
          relationsBySentence: const [
            {
              15: (head: 16, relation: 'nsubj'),
              16: (head: 0, relation: 'root'),
              17: (head: 16, relation: 'advmod'),
            },
          ],
          uposBySentence: const [
            {15: 'PRON', 16: 'VERB', 17: 'ADV'},
          ],
        ),
      );

      expect(plan.localSentences, [source]);
      final quoteEdge = plan.originals.single.boundaryCandidates
          .firstWhere((candidate) => candidate.quoteEdge == 'after_closing');
      expect(
        quoteEdge.softWarnings,
        contains('quote_edge_attribution_only_tail'),
      );
    });

    test('does not coalesce unmatched quotes across a paragraph break', () {
      const source =
          '"Look here! Still open.\n\nNext paragraph continues normally.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, const [
          '"Look here!',
          'Still open.',
          'Next paragraph continues normally.',
        ]),
      );

      expect(plan.originals, hasLength(3));
      expect(plan.localSentences, const [
        '"Look here!',
        'Still open.',
        'Next paragraph continues normally.',
      ]);
    });

    test('protects a nested short quote after an earlier unmatched opening',
        () {
      const source =
          '"Earlier words stay open. Narration ends. "O, my!" he gasped.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, const [
          '"Earlier words stay open.',
          'Narration ends. "',
          'O, my!"',
          'he gasped.',
        ]),
      );

      expect(plan.originals, hasLength(3));
      expect(
        plan.localSentences,
        isNot(contains('Narration ends. "')),
      );
      expect(
        plan.localSentences.join(' '),
        contains('"O, my!"'),
      );
    });

    test('coalesces a parser line break inside a two-token quoted list', () {
      const source = '"coldtonguecoldham—  cresssodawater—" The Mole listened.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, const [
          '"coldtonguecoldham—',
          'cresssodawater—"',
          'The Mole listened.',
        ]),
      );

      expect(plan.originals, hasLength(2));
      expect(plan.localSentences.first, '"coldtonguecoldham— cresssodawater—"');
    });

    test('keeps a matched short quote intact across a blank layout line', () {
      const source =
          '"coldtonguecoldham—\n\ncresssodawater—" The Mole listened.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, const [
          '"coldtonguecoldham—',
          'cresssodawater—"',
          'The Mole listened.',
        ]),
      );

      expect(plan.originals, hasLength(2));
      expect(plan.localSentences.first, '"coldtonguecoldham— cresssodawater—"');
    });

    test('uses the innermost complete quote when same-mark speech is nested',
        () {
      const source =
          '"The Rat began to sing—"Lest limbs be reddened and rent!" Then he paused for a long while."';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, const [
          '"The Rat began to sing—"Lest limbs be reddened and rent!',
          '" Then he paused for a long while."',
        ]),
      );

      final nestedCandidates = plan.originals.single.boundaryCandidates.where(
        (candidate) => candidate.quoteSpanWordCount == 6,
      );
      expect(nestedCandidates, isNotEmpty);
      expect(
        nestedCandidates,
        everyElement(
          isA<ReadAloudBoundaryCandidateV3>()
              .having((candidate) => candidate.hardBlocked, 'hardBlocked', true)
              .having(
                (candidate) => candidate.hardBlockReasons,
                'hardBlockReasons',
                contains('inside_short_complete_quote'),
              ),
        ),
      );
    });

    test('bounds coverage-path probes for a very long quotation', () {
      final words = List.generate(
        120,
        (index) =>
            (index + 1) % 10 == 0 ? 'word${index + 1};' : 'word${index + 1}',
      );
      final source = '"${words.join(' ')}"';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, [source]),
      );

      expect(plan.originals.single.boundaryCandidates.length, greaterThan(24));
      expect(
          plan.originals.single.candidatePaths.length, lessThanOrEqualTo(24));
      expect(
        plan.localSentences.map(ReadAloudSplitterV3.wordCount),
        everyElement(lessThanOrEqualTo(30)),
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
