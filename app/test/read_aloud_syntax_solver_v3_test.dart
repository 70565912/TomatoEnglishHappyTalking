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
      expect(plan.counters.sentenceFactBuilds, plan.originals.length);
      expect(plan.counters.dagSolves, plan.originals.length);
      expect(plan.requiresAiReview, isFalse);
    });

    test('V3.7 merges a trailing one-word original into the previous chunk',
        () {
      const source =
          'A moment, and he had caught it again; and with it this time came recollection in fullest flood. Home! That was what they meant.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, const [
          'A moment, and he had caught it again; and with it this time came recollection in fullest flood.',
          'Home!',
          'That was what they meant.',
        ]),
      );

      expect(plan.localSentences, isNot(contains('Home!')));
      expect(
        plan.localSentences.any((chunk) => chunk.endsWith('flood. Home!')),
        isTrue,
      );
      expect(
        plan.localSentences
            .where((chunk) => ReadAloudSplitterV3.wordCount(chunk) == 1),
        isEmpty,
      );
    });

    test('V3.7 Willows E09 keeps the reviewed 15/11 punctuation split', () {
      const source =
          'He seemed, by all accounts, to be such an important personage and, though rarely visible, to make his unseen influence felt by everybody about the place.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              1: (head: 2, relation: 'nsubj'),
              7: (head: 2, relation: 'xcomp'),
              11: (head: 7, relation: 'obj'),
              12: (head: 17, relation: 'cc'),
              13: (head: 15, relation: 'mark'),
              14: (head: 15, relation: 'advmod'),
              15: (head: 11, relation: 'acl'),
              16: (head: 17, relation: 'mark'),
              17: (head: 7, relation: 'conj'),
              20: (head: 21, relation: 'nsubj'),
              21: (head: 17, relation: 'xcomp'),
              23: (head: 21, relation: 'obl'),
              26: (head: 23, relation: 'nmod'),
            },
          ],
          uposBySentence: const [
            {
              1: 'PRON',
              2: 'VERB',
              7: 'AUX',
              11: 'NOUN',
              12: 'CCONJ',
              13: 'SCONJ',
              14: 'ADV',
              15: 'ADJ',
              16: 'PART',
              17: 'VERB',
              20: 'NOUN',
              21: 'VERB',
              23: 'PRON',
              26: 'NOUN',
            },
          ],
        ),
      );

      expect(plan.localSentences, const [
        'He seemed, by all accounts, to be such an important personage and, though rarely visible,',
        'to make his unseen influence felt by everybody about the place.',
      ]);
      expect(plan.originals.single.localPath.wordCounts, const [15, 11]);
      expect(plan.originals.single.localPath.stage,
          ReadAloudPathStageV3.punctuation);
    });

    test(
        'V3.7 Alice E02 parenthetical prefers 6/12/9 and never cuts seemed|quite',
        () {
      const source =
          '(When she thought it over afterward, it occurred to her that she ought to have wondered at this, but at the time it all seemed quite natural); but when the Rabbit actually took a watch out of its waistcoat-pocket, and looked at it, and then hurried on, Alice started to her feet, for it flashed across her mind that she had never before seen a rabbit with either a waistcoat-pocket or a watch to take out of it, and, burning with curiosity she ran across the field after it, and was just in time to see it pop down a large rabbit-hole under the hedge.';
      // Relations recreate the V3.6 failure mode: an advcl/xcomp arc across
      // "seemed | quite natural" that must not win once paren-gated.
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              7: (head: 8, relation: 'nsubj'),
              8: (head: 3, relation: 'advcl'),
              23: (head: 25, relation: 'nsubj'),
              25: (head: 8, relation: 'conj'),
              27: (head: 25, relation: 'xcomp'),
              31: (head: 33, relation: 'nsubj'),
              33: (head: 25, relation: 'advcl'),
            },
          ],
          uposBySentence: const [
            {
              3: 'VERB',
              7: 'PRON',
              8: 'VERB',
              23: 'PRON',
              25: 'VERB',
              26: 'ADV',
              27: 'ADJ',
              31: 'PROPN',
              33: 'VERB',
            },
          ],
        ),
      );

      final selected = plan.originals.single.localPath;
      expect(selected.wordCounts.take(3), const [6, 12, 9]);
      expect(selected.segments[2], endsWith('natural);'));
      expect(
        selected.segments.any(
          (segment) =>
              segment.trimLeft().startsWith('quite natural') ||
              segment.contains('seemed ') && !segment.contains('quite natural'),
        ),
        isFalse,
        reason: 'must not cut seemed|quite natural',
      );
      final afterSeemed = selected.boundaries
          .where((boundary) => boundary.afterWord == 25)
          .toList(growable: false);
      expect(afterSeemed, isEmpty);
      expect(
        plan.originals.single.candidatePaths.every(
          (path) => path.boundaries.every(
            (boundary) =>
                !boundary.reasons.contains('incomplete_constituent_boundary'),
          ),
        ),
        isTrue,
        reason: 'AI must not be offered a path with the known bad cut',
      );
      final afterSeemedCandidate = plan.originals.single.boundaryCandidates
          .firstWhere((candidate) => candidate.afterWord == 25);
      expect(afterSeemedCandidate.kind, ReadAloudBoundaryKindV3.emergency);
      expect(
        afterSeemedCandidate.reasons,
        contains('incomplete_constituent_boundary'),
      );
      final closing = plan.originals.single.boundaryCandidates
          .firstWhere((candidate) => candidate.afterWord == 27);
      expect(closing.parenEdge, 'after_closing');
      expect(closing.kind, ReadAloudBoundaryKindV3.strongPunctuation);
    });

    test('V3.7 hard-blocks cuts inside a short matched parenthetical', () {
      const source =
          'She paused (which was very likely true) before answering.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, const [source]),
      );
      final inside = plan.originals.single.boundaryCandidates.where(
        (candidate) => candidate.insideParenthetical,
      );
      expect(inside, isNotEmpty);
      expect(
        inside.every((candidate) => candidate.hardBlocked),
        isTrue,
      );
      expect(
        inside.every(
          (candidate) => candidate.hardBlockReasons
              .contains('inside_short_complete_parenthetical'),
        ),
        isTrue,
      );
    });

    test('V3.7 coalesces parser sentences inside a short parenthetical', () {
      const source = 'She remembered (It was late. We left.) before dawn.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, const [
          'She remembered (It was late.',
          'We left.) before dawn.',
        ]),
      );

      expect(plan.originals, hasLength(1));
      expect(plan.localSentences, const [source]);
      expect(
        plan.originals.single.boundaryCandidates
            .where((candidate) => candidate.insideParenthetical)
            .every((candidate) => candidate.hardBlocked),
        isTrue,
      );
    });

    test('V3.7 allows ordinary punctuation inside a 17-word parenthetical', () {
      const source =
          'She recalled (one two three four five six seven eight, nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen) before leaving.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, const [source]),
      );

      final comma = plan.originals.single.boundaryCandidates
          .firstWhere((candidate) => candidate.afterWord == 10);
      expect(comma.insideParenthetical, isTrue);
      expect(comma.parenSpanWordCount, 17);
      expect(comma.hardBlocked, isFalse);
    });

    test('V3.7 uses the innermost nested parenthetical span', () {
      const source =
          'She recalled (one two three (very small aside) four five six seven eight nine ten eleven twelve thirteen fourteen) before leaving.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, const [source]),
      );

      final nested = plan.originals.single.boundaryCandidates.firstWhere(
        (candidate) =>
            candidate.insideParenthetical && candidate.parenSpanWordCount == 3,
      );
      expect(nested.hardBlocked, isTrue);
      expect(
        nested.hardBlockReasons,
        contains('inside_short_complete_parenthetical'),
      );
    });

    test('V3.7 audits unmatched parentheses without cross-paragraph pairing',
        () {
      const first = 'He began (unfinished words here.';
      const second = 'Later words close) and continue.';
      const source = '$first\n\n$second';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, const [first, second]),
      );

      expect(plan.originals, hasLength(2));
      expect(
        plan.parserIssues.any(
          (issue) => issue.startsWith('unmatched_parenthesis_open:'),
        ),
        isTrue,
      );
      expect(
        plan.parserIssues.any(
          (issue) => issue.startsWith('unmatched_parenthesis_close:'),
        ),
        isTrue,
      );
      expect(
        plan.originals
            .expand((decision) => decision.boundaryCandidates)
            .any((candidate) => candidate.insideParenthetical),
        isFalse,
      );
    });

    test('V3.7 marks incomplete non-punct cuts as emergency', () {
      // Long enough that KEEP is impossible; no commas inside the paren, so
      // syntax is considered — but "seemed|quite" lacks closure.
      const source =
          '(When she thought it over afterward it occurred to her that she ought to have wondered at this but at the time it all seemed quite natural);';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              27: (head: 25, relation: 'xcomp'),
            },
          ],
          uposBySentence: const [
            {
              25: 'VERB',
              26: 'ADV',
              27: 'ADJ',
            },
          ],
        ),
      );
      final afterSeemed = plan.originals.single.boundaryCandidates
          .firstWhere((candidate) => candidate.afterWord == 25);
      expect(afterSeemed.isPunctuation, isFalse);
      expect(
        afterSeemed.reasons,
        contains('incomplete_constituent_boundary'),
      );
      expect(afterSeemed.kind, ReadAloudBoundaryKindV3.emergency);
      expect(
        plan.originals.single.localPath.segments.any(
          (segment) => segment.trimLeft().startsWith('quite natural'),
        ),
        isFalse,
      );
    });

    test(
        'V3.7 local closure ignores an unrelated complete clause farther right',
        () {
      const source =
          'They looked so good tonight while all the guests nearby waited quietly and the musicians continued playing softly through the long dinner.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              4: (head: 2, relation: 'xcomp'),
              9: (head: 11, relation: 'nsubj'),
              11: (head: 2, relation: 'advcl'),
            },
          ],
          uposBySentence: const [
            {
              1: 'PRON',
              2: 'VERB',
              3: 'ADV',
              4: 'ADJ',
              9: 'NOUN',
              11: 'VERB',
            },
          ],
        ),
      );

      final afterLooked = plan.originals.single.boundaryCandidates
          .firstWhere((candidate) => candidate.afterWord == 2);
      expect(afterLooked.kind, ReadAloudBoundaryKindV3.emergency);
      expect(
        afterLooked.reasons,
        contains('incomplete_constituent_boundary'),
      );
    });

    test('V3.9 ranks incomplete recovery paths without a hidden post-filter',
        () {
      final source = _words('word', 45);
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          [source],
          relationsBySentence: const [
            {
              16: (head: 1, relation: 'xcomp'),
              31: (head: 1, relation: 'advcl'),
            },
          ],
          uposBySentence: const [
            {1: 'VERB', 16: 'VERB', 31: 'VERB'},
          ],
        ),
      );

      final selectedAfterWords = plan.originals.single.localPath.boundaries
          .map((boundary) => boundary.afterWord)
          .toList(growable: false);
      expect(
        plan.originals.single.boundaryCandidates
            .firstWhere((candidate) => candidate.afterWord == 15)
            .reasons,
        contains('incomplete_constituent_boundary'),
      );
      expect(
        selectedAfterWords,
        const [16, 29],
        reason: 'only the defective 15-word cut may move; 29 stays anchored',
      );
      expect(
        plan.originals.single.localPath.boundaries.every(
          (boundary) =>
              !boundary.reasons.contains('incomplete_constituent_boundary'),
        ),
        isTrue,
      );
      expect(
        plan.originals.single.candidatePaths.any(
          (path) => path.boundaries.any(
            (boundary) =>
                boundary.reasons.contains('incomplete_constituent_boundary'),
          ),
        ),
        isTrue,
        reason: 'R-SINGLE-SCORE keeps auditable alternatives in the ranking',
      );
    });

    test('V3.7 parenthetical scoring cannot split a phrasal particle', () {
      const source =
          'She did it so quickly that the poor little juror (it was Bill, the Lizard) could not make out at all what had become of it; so, after waiting quietly, everyone looked around the room and wondered what happened next.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {19: (head: 18, relation: 'compound:prt')},
          ],
          uposBySentence: const [
            {18: 'VERB', 19: 'ADP'},
          ],
        ),
      );

      final afterMake = plan.originals.single.boundaryCandidates
          .firstWhere((candidate) => candidate.afterWord == 18);
      expect(afterMake.protectedRelationCrossings, 1);
      expect(
        plan.originals.single.localPath.boundaries
            .map((boundary) => boundary.afterWord),
        isNot(contains(18)),
      );
    });

    test(
        'hard-blocks misparsed phrasal particle go|on before verbal complement',
        () {
      // >20 unpunctuated words force a cut; UD-style mark+advcl must not win
      // over keeping `go on listening` together (Willows E32 pattern).
      const source =
          'He wanted only to hear that thin clear little voice once more and go on listening to it for ever afterwards without another pause.';
      // Words: 1He 2wanted 3only 4to 5hear 6that 7thin 8clear 9little 10voice
      // 11once 12more 13and 14go 15on 16listening 17to 18it 19for 20ever
      // 21afterwards 22without 23another 24pause
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              1: (head: 2, relation: 'nsubj'),
              2: (head: 0, relation: 'root'),
              4: (head: 5, relation: 'mark'),
              5: (head: 2, relation: 'xcomp'),
              6: (head: 10, relation: 'det'),
              7: (head: 10, relation: 'amod'),
              8: (head: 10, relation: 'amod'),
              9: (head: 10, relation: 'amod'),
              10: (head: 5, relation: 'obj'),
              11: (head: 12, relation: 'advmod'),
              12: (head: 5, relation: 'advmod'),
              13: (head: 14, relation: 'cc'),
              14: (head: 5, relation: 'conj'),
              15: (head: 16, relation: 'mark'),
              16: (head: 14, relation: 'advcl'),
              17: (head: 18, relation: 'case'),
              18: (head: 16, relation: 'obl'),
            },
          ],
          uposBySentence: const [
            {
              1: 'PRON',
              2: 'VERB',
              4: 'PART',
              5: 'VERB',
              6: 'DET',
              7: 'ADJ',
              8: 'ADJ',
              9: 'ADJ',
              10: 'NOUN',
              11: 'ADV',
              12: 'ADV',
              13: 'CCONJ',
              14: 'VERB',
              15: 'SCONJ',
              16: 'VERB',
              17: 'ADP',
              18: 'PRON',
            },
          ],
        ),
      );

      final afterGo = plan.originals.single.boundaryCandidates
          .firstWhere((candidate) => candidate.afterWord == 14);
      expect(afterGo.hardBlocked, isTrue);
      expect(
        afterGo.hardBlockReasons,
        contains('inside_misparsed_phrasal_verb_particle'),
      );
      expect(
        plan.localSentences.any(
          (segment) =>
              segment.trimLeft().toLowerCase().startsWith('on listening'),
        ),
        isFalse,
      );
      expect(
        plan.localSentences
            .any((segment) => segment.contains('go on listening')),
        isTrue,
      );
    });

    test(
        'does not hard-block verb|on when on is a true PP case of a noun',
        () {
      const source =
          'After that short rest the tired traveller followed on bare feet through several quiet rooms and corridors without another word.';
      // Words: 1After 2that 3short 4rest 5the 6tired 7traveller 8followed
      // 9on 10bare 11feet ...
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              7: (head: 8, relation: 'nsubj'),
              8: (head: 0, relation: 'root'),
              9: (head: 11, relation: 'case'),
              10: (head: 11, relation: 'amod'),
              11: (head: 8, relation: 'obl'),
            },
          ],
          uposBySentence: const [
            {
              7: 'NOUN',
              8: 'VERB',
              9: 'ADP',
              10: 'ADJ',
              11: 'NOUN',
            },
          ],
        ),
      );

      final afterFollowed = plan.originals.single.boundaryCandidates
          .firstWhere((candidate) => candidate.afterWord == 8);
      expect(
        afterFollowed.hardBlockReasons,
        isNot(contains('inside_misparsed_phrasal_verb_particle')),
      );
    });

    test(
        'V3.7 negative: no-paren E61 and syntax-clause snapshots stay V3.6-stable',
        () {
      // E61 luncheon — punctuation path must remain unchanged.
      const e61 =
          'When the other animals came back to luncheon, very boisterous and breezy after a morning on the river, the Mole, whose conscience had been pricking him, looked doubtfully at Toad, expecting to find him sulky or depressed.';
      final e61Plan = ReadAloudSplitterV3.plan(
        source: e61,
        document: _document(
          e61,
          const [e61],
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
        e61Plan.originals.single.localPath.wordCounts,
        const [8, 10, 12, 7],
      );
      expect(e61Plan.originals.single.localPath.stage,
          ReadAloudPathStageV3.punctuation);

      // Unpunctuated 21-word unit still uses a dependency clause when needed.
      final bare = '${_words('main', 10)} ${_words('clause', 11)}';
      final barePlan = ReadAloudSplitterV3.plan(
        source: bare,
        document: _document(
          bare,
          [bare],
          relationsBySentence: const [
            {
              11: (head: 10, relation: 'advcl'),
            },
          ],
        ),
      );
      expect(barePlan.originals.single.localPath.stage,
          ReadAloudPathStageV3.syntax);
      expect(barePlan.originals.single.localPath.wordCounts, const [10, 11]);
      expect(
        barePlan.originals.single.localPath.boundaries.single.kind,
        ReadAloudBoundaryKindV3.dependencyClause,
      );
    });

    test('keeps a twenty-word sentence when no safe parser pause exists', () {
      final source = '${_words('word', 20)}.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, [source]),
      );

      expect(plan.localSentences, [source]);
      expect(plan.originals.single.localPath.boundaries, isEmpty);
    });

    test('splits more than seventeen words at a qualified clause comma', () {
      final tokens = List.generate(18, (index) => 'word${index + 1}');
      tokens[7] = '${tokens[7]},';
      tokens[17] = '${tokens[17]}.';
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

      expect(plan.localSentences.map(ReadAloudSplitterV3.wordCount), [8, 10]);
      expect(
        plan.originals.single.localPath.boundaries.single.kind,
        ReadAloudBoundaryKindV3.clauseComma,
      );
    });

    test('allows a four-word complete clause before a single comma cut', () {
      const source =
          'He quickened his pace, telling himself calmly not to imagine trouble because there would otherwise be no end to his worries.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              1: (head: 2, relation: 'nsubj'),
              3: (head: 4, relation: 'nmod:poss'),
              4: (head: 2, relation: 'obj'),
              5: (head: 2, relation: 'advcl'),
            },
          ],
          uposBySentence: const [
            {1: 'PRON', 2: 'VERB', 3: 'PRON', 4: 'NOUN', 5: 'VERB'},
          ],
        ),
      );

      expect(plan.localSentences.first, 'He quickened his pace,');
      expect(
        plan.localSentences.map(ReadAloudSplitterV3.wordCount),
        everyElement(lessThanOrEqualTo(20)),
      );
      expect(
        plan.localSentences.any((sentence) => sentence.endsWith('there')),
        isFalse,
        reason: 'R-SYNTAX-LOCATION keeps expletive there with its predicate',
      );
      expect(
        plan.originals.single.localPath.boundaries.first.kind,
        ReadAloudBoundaryKindV3.clauseComma,
      );
    });

    test('prefers an internal clause comma after an established pause', () {
      const source =
          'In a little while, however, she again heard a little pattering of footsteps in the distance, and she looked up eagerly, half hoping that the Mouse had changed his mind and was coming back to finish his story.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              6: (head: 8, relation: 'nsubj'),
              17: (head: 19, relation: 'cc'),
              18: (head: 19, relation: 'nsubj'),
              19: (head: 8, relation: 'conj'),
              23: (head: 19, relation: 'advcl'),
              24: (head: 28, relation: 'mark'),
              26: (head: 28, relation: 'nsubj'),
              27: (head: 28, relation: 'aux'),
              28: (head: 23, relation: 'ccomp'),
              31: (head: 33, relation: 'cc'),
              32: (head: 33, relation: 'aux'),
              33: (head: 28, relation: 'conj'),
            },
          ],
          uposBySentence: const [
            {
              6: 'PRON',
              8: 'VERB',
              17: 'CCONJ',
              18: 'PRON',
              19: 'VERB',
              23: 'VERB',
              24: 'SCONJ',
              26: 'NOUN',
              27: 'AUX',
              28: 'VERB',
              31: 'CCONJ',
              32: 'AUX',
              33: 'VERB',
            },
          ],
        ),
      );

      expect(plan.localSentences.take(2), const [
        'In a little while, however, she again heard a little pattering of footsteps in the distance,',
        'and she looked up eagerly,',
      ]);
      expect(
        plan.localSentences.map(ReadAloudSplitterV3.wordCount),
        everyElement(lessThanOrEqualTo(20)),
      );
      expect(
        plan.localSentences.any((sentence) => sentence.endsWith('his')),
        isFalse,
        reason: 'R-SYNTAX-LOCATION keeps possessives with their head',
      );
      expect(
        plan.originals.single.localPath.boundaries.take(2).map(
              (boundary) => boundary.kind,
            ),
        everyElement(ReadAloudBoundaryKindV3.clauseComma),
      );
    });

    test('does not replace a stronger pause with a later comma', () {
      const source =
          'The travelers carried supplies and blankets and tools for every possible delay; and they lost all their money, and lost their way, while searching for the road that would finally lead them home.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              2: (head: 3, relation: 'nsubj'),
              13: (head: 15, relation: 'cc'),
              14: (head: 15, relation: 'nsubj'),
              19: (head: 20, relation: 'cc'),
              20: (head: 15, relation: 'conj'),
              23: (head: 24, relation: 'mark'),
              24: (head: 15, relation: 'advcl'),
            },
          ],
          uposBySentence: const [
            {
              2: 'NOUN',
              3: 'VERB',
              13: 'CCONJ',
              14: 'PRON',
              15: 'VERB',
              19: 'CCONJ',
              20: 'VERB',
              23: 'SCONJ',
              24: 'VERB',
            },
          ],
        ),
      );

      expect(
        plan.localSentences.first,
        'The travelers carried supplies and blankets and tools for every possible delay;',
      );
      expect(
        plan.localSentences.any((sentence) => sentence.contains('; and')),
        isFalse,
      );
    });

    test('splits a seventeen-word list at a source comma', () {
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

      expect(
        plan.localSentences.map(ReadAloudSplitterV3.wordCount),
        const [8, 9],
      );
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
        everyElement(lessThanOrEqualTo(20)),
      );
      expect(
        plan.originals.single.localPath.boundaries
            .firstWhere((boundary) => boundary.afterWord == 18)
            .kind,
        ReadAloudBoundaryKindV3.strongPunctuation,
      );
      expect(
        plan.originals.single.localPath.boundaries
            .firstWhere((boundary) => boundary.afterWord == 18)
            .hardBlocked,
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
      final rejectedAntecedentBoundary = plan
          .originals.single.boundaryCandidates
          .firstWhere((boundary) => boundary.afterWord == 20);
      expect(
        rejectedAntecedentBoundary.softWarnings,
        contains('surface_possible_antecedent_possessive_separation'),
      );
    });

    test('terminal punctuation outranks a surface possessive warning', () {
      const source =
          '"The old traveler promised that henceforth he would become a very different creature. My patient friends would never need to blush for him again."';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              3: (head: 4, relation: 'nsubj'),
              5: (head: 9, relation: 'mark'),
              7: (head: 9, relation: 'nsubj'),
              8: (head: 9, relation: 'aux'),
              9: (head: 4, relation: 'ccomp'),
              10: (head: 13, relation: 'det'),
              12: (head: 13, relation: 'amod'),
              13: (head: 9, relation: 'obj'),
              14: (head: 16, relation: 'nmod:poss'),
              16: (head: 19, relation: 'nsubj'),
              19: (head: 0, relation: 'root'),
            },
          ],
          uposBySentence: const [
            {
              3: 'NOUN',
              4: 'VERB',
              5: 'SCONJ',
              7: 'PRON',
              8: 'AUX',
              9: 'VERB',
              10: 'DET',
              12: 'ADJ',
              13: 'NOUN',
              14: 'DET',
              16: 'NOUN',
              19: 'VERB',
            },
          ],
        ),
      );

      expect(plan.localSentences, const [
        '"The old traveler promised that henceforth he would become a very different creature.',
        'My patient friends would never need to blush for him again."',
      ]);
      expect(
        plan.originals.single.localPath.boundaries.single.softWarnings,
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
      expect(
        selected.boundaries
            .firstWhere((boundary) => boundary.afterWord == 18)
            .kind,
        ReadAloudBoundaryKindV3.strongPunctuation,
      );
      expect(selected.wordCounts, everyElement(lessThanOrEqualTo(20)));
      expect(
        plan.requiresAiReview,
        isFalse,
        reason: 'the 18/18 source-semicolon path is fully compliant',
      );
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
      expect(selected.wordCounts, const [9, 11, 13]);
      expect(
        selected.boundaries.map((boundary) => boundary.kind),
        everyElement(ReadAloudBoundaryKindV3.clauseComma),
      );
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
      final tokens = List.generate(50, (index) => 'word${index + 1}');
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
      tokens[32] = 'desperate';
      tokens[33] = 'and';
      tokens[34] = 'dangerous';
      tokens[35] = 'fellow';
      tokens[36] = 'this';
      tokens[37] = 'otherwise';
      tokens[38] = 'clear';
      tokens[39] = 'case';
      tokens[40] = 'quietly';
      tokens[41] = 'humbled';
      tokens[42] = 'sort';
      tokens[43] = 'or';
      tokens[44] = 'kind,';
      tokens[45] = 'swung';
      tokens[46] = 'and';
      tokens[47] = 'dandled';
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
              33: 'ADJ',
              34: 'CCONJ',
              35: 'ADJ',
              36: 'NOUN',
              37: 'DET',
              38: 'ADV',
              39: 'ADJ',
              40: 'NOUN',
              41: 'ADV',
              42: 'VERB',
              43: 'NOUN',
              44: 'CCONJ',
              45: 'NOUN',
              46: 'NOUN',
              47: 'CCONJ',
              48: 'VERB',
            },
          ],
          relationsBySentence: const [
            {
              41: (head: 42, relation: 'advmod'),
              46: (head: 40, relation: 'conj'),
              48: (head: 39, relation: 'conj'),
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
      expect(
        boundaries[33]!.softWarnings,
        contains('surface_modifier_head_separation'),
      );
      expect(
        boundaries[37]!.softWarnings,
        contains('surface_determiner_head_separation'),
      );
      expect(
        boundaries[41]!.softWarnings,
        contains('surface_adverb_attachment_separation'),
      );
      expect(
        boundaries[43]!.softWarnings,
        contains('surface_short_nominal_coordinator_tail'),
      );
      expect(
        boundaries[46]!.softWarnings,
        contains('surface_mixed_coordinator_chain_separation'),
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
        for (final boundary in plan.originals.single.boundaryCandidates)
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
      final warned = plan.originals.single.boundaryCandidates
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
        decision.candidatePaths.map((path) => path.score),
        everyElement(everyElement(greaterThanOrEqualTo(0))),
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

    test('keeps both Up we go cries and uses both source quote edges', () {
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
        'working busily with his little paws and muttering to himself,',
        '"Up we go! Up we go!"',
        'till at last, pop!',
        'his snout came out into the sunlight and he found himself',
      ]);
      expect(
        plan.originals.first.localPath.boundaries.map(
          (boundary) => boundary.quoteEdge,
        ),
        containsAll(const ['before_opening', 'after_closing']),
      );
    });

    test('classifies a source comma before a long opening quote directly', () {
      const source =
          '"To my mind," observed the Chairman of the Bench of Magistrates cheerfully, "the only difficulty that presents itself in this otherwise very clear case is, how we can possibly make it sufficiently hot for the incorrigible rogue and hardened ruffian whom we see cowering in the dock before us."';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, [source]),
      );

      final deferred = plan.originals.single.boundaryCandidates.firstWhere(
        (candidate) => candidate.quoteEdge == 'before_opening',
      );
      expect(deferred.kind, ReadAloudBoundaryKindV3.phraseComma);
      expect(
        deferred.reasons,
        contains('source_attribution_before_opening_quote'),
      );
      expect(
        plan.originals.single.localPath.boundaries.any(
          (candidate) => candidate.reasons
              .contains('source_attribution_before_opening_quote'),
        ),
        isTrue,
      );
    });

    test('adds an opening-parenthesis pause only inside the stable long block',
        () {
      const source =
          'The judge, by the way, was the King, and as he wore his crown over the wig (look at the frontispiece if you want to see how he did it), he did not look at all comfortable, and it was certainly not becoming.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, const [source]),
      );

      final opening = plan.originals.single.boundaryCandidates.firstWhere(
        (candidate) => candidate.parenEdge == 'before_opening',
      );
      expect(
        opening.reasons,
        contains('deferred_stable_parenthetical_edge'),
      );
      expect(opening.parenSpanWordCount, 13);
    });

    test('splits a stable long block before a complete copular time clause',
        () {
      const source =
          'and so intimately into the insides of things as on that winter day when Nature was deep in her annual slumber';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              1: (head: 17, relation: 'cc'),
              2: (head: 3, relation: 'advmod'),
              3: (head: 0, relation: 'root'),
              4: (head: 6, relation: 'case'),
              5: (head: 6, relation: 'det'),
              6: (head: 3, relation: 'obl'),
              7: (head: 8, relation: 'case'),
              8: (head: 6, relation: 'nmod'),
              9: (head: 17, relation: 'mark'),
              10: (head: 13, relation: 'case'),
              11: (head: 13, relation: 'det'),
              12: (head: 13, relation: 'compound'),
              13: (head: 17, relation: 'obl'),
              14: (head: 17, relation: 'advmod'),
              15: (head: 17, relation: 'nsubj'),
              16: (head: 17, relation: 'cop'),
              17: (head: 3, relation: 'conj'),
              18: (head: 21, relation: 'case'),
              19: (head: 21, relation: 'nmod:poss'),
              20: (head: 21, relation: 'amod'),
              21: (head: 17, relation: 'obl'),
            },
          ],
          uposBySentence: const [
            {
              1: 'CCONJ',
              3: 'ADV',
              6: 'NOUN',
              8: 'NOUN',
              13: 'NOUN',
              14: 'ADV',
              15: 'PROPN',
              16: 'AUX',
              17: 'ADJ',
              21: 'NOUN',
            },
          ],
        ),
      );

      expect(plan.localSentences, const [
        'and so intimately into the insides of things as on that winter day',
        'when Nature was deep in her annual slumber',
      ]);
      expect(plan.originals.single.localPath.wordCounts, const [13, 8]);
    });

    test('recovers bounded surface clauses when dependency attachments are bad',
        () {
      const modifierSource =
          'The sunshine struck hot on his fur, soft breezes caressed his heated brow, and after the seclusion of the cellarage he had lived in so long the carol of happy birds fell on his dulled hearing almost like a shout.';
      final modifierPlan = ReadAloudSplitterV3.plan(
        source: modifierSource,
        document: _document(
          modifierSource,
          const [modifierSource],
          uposBySentence: const [
            {
              3: 'VERB',
              10: 'VERB',
              22: 'AUX',
              23: 'VERB',
              26: 'ADV',
              27: 'DET',
              28: 'NOUN',
              32: 'VERB',
            },
          ],
        ),
      );

      expect(
        modifierPlan.localSentences.map(ReadAloudSplitterV3.wordCount),
        everyElement(lessThanOrEqualTo(20)),
      );
      expect(
        modifierPlan.localSentences.any(
          (sentence) => sentence.endsWith('seclusion of the'),
        ),
        isFalse,
      );

      const copularSource =
          'The rusty key creaked in the lock, the great door clanged behind them; and Toad was a helpless prisoner in the remotest dungeon of the best-guarded keep of the stoutest castle in all the length and breadth of Merry England.';
      final copularPlan = ReadAloudSplitterV3.plan(
        source: copularSource,
        document: _document(
          copularSource,
          const [copularSource],
          uposBySentence: const [
            {
              3: 'NOUN',
              4: 'VERB',
              10: 'NOUN',
              11: 'VERB',
              13: 'PRON',
              14: 'CCONJ',
              15: 'PROPN',
              16: 'AUX',
              17: 'DET',
              18: 'ADJ',
              19: 'NOUN',
              20: 'ADP',
            },
          ],
        ),
      );

      expect(
        copularPlan.localSentences.map(ReadAloudSplitterV3.wordCount),
        everyElement(lessThanOrEqualTo(20)),
      );
      expect(
        copularPlan.localSentences.any(
          (sentence) => sentence.endsWith('behind them;'),
        ),
        isTrue,
        reason: 'R-PUNCT-FIRST keeps the source semicolon',
      );
      expect(
        copularPlan.localSentences.any((sentence) => sentence.endsWith('the')),
        isFalse,
        reason: 'R-SYNTAX-LOCATION keeps a determiner with its head',
      );
    });

    test('does not promote adjective-head or adjective-complement gaps', () {
      const modifierSource =
          'The patient guide spoke very softly while the unusually happy children played beside the river and watched the bright clouds drift slowly above them.';
      final modifierPlan = ReadAloudSplitterV3.plan(
        source: modifierSource,
        document: _document(
          modifierSource,
          const [modifierSource],
          uposBySentence: const [
            {4: 'VERB', 6: 'ADV', 10: 'ADJ', 11: 'NOUN', 12: 'VERB'},
          ],
        ),
      );
      final modifierBoundary = modifierPlan.originals.single.boundaryCandidates
          .firstWhere((candidate) => candidate.afterWord == 10);
      expect(
        modifierBoundary.reasons,
        isNot(contains('validated_surface_right_clause')),
      );

      const complementSource =
          'The cautious child was afraid of the distant thunder that rolled across the valley while the evening rain fell steadily around the house.';
      final complementPlan = ReadAloudSplitterV3.plan(
        source: complementSource,
        document: _document(
          complementSource,
          const [complementSource],
          uposBySentence: const [
            {3: 'NOUN', 4: 'AUX', 5: 'ADJ', 6: 'ADP'},
          ],
        ),
      );
      final complementBoundary = complementPlan
          .originals.single.boundaryCandidates
          .firstWhere((candidate) => candidate.afterWord == 5);
      expect(
        complementBoundary.reasons,
        isNot(contains('validated_surface_adposition_boundary')),
      );

      const coordinatedModifierSource =
          'The patient reader tried to remember all the fine and biting things that he had seen during the long journey through the quiet forest before nightfall.';
      final coordinatedModifierPlan = ReadAloudSplitterV3.plan(
        source: coordinatedModifierSource,
        document: _document(
          coordinatedModifierSource,
          const [coordinatedModifierSource],
          relationsBySentence: const [
            {
              10: (head: 11, relation: 'cc'),
              11: (head: 9, relation: 'conj'),
            },
          ],
          uposBySentence: const [
            {4: 'VERB', 9: 'ADJ', 10: 'CCONJ', 11: 'VERB', 12: 'NOUN'},
          ],
        ),
      );
      final coordinatedModifierBoundary = coordinatedModifierPlan
          .originals.single.boundaryCandidates
          .firstWhere((candidate) => candidate.afterWord == 9);
      expect(
        coordinatedModifierBoundary.reasons,
        isNot(contains('recovered_adjectival_shared_predicate')),
      );
    });

    test('allows a complete coordinated noun item before a relative tail', () {
      const source =
          'how we can possibly make it sufficiently hot for the incorrigible rogue and hardened ruffian whom we see cowering in the dock before us';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              1: (head: 5, relation: 'advmod'),
              2: (head: 5, relation: 'nsubj'),
              3: (head: 5, relation: 'aux'),
              4: (head: 5, relation: 'advmod'),
              5: (head: 0, relation: 'root'),
              6: (head: 5, relation: 'obj'),
              7: (head: 8, relation: 'advmod'),
              8: (head: 5, relation: 'xcomp'),
              9: (head: 12, relation: 'case'),
              10: (head: 12, relation: 'det'),
              11: (head: 12, relation: 'amod'),
              12: (head: 5, relation: 'obl'),
              13: (head: 15, relation: 'cc'),
              14: (head: 15, relation: 'amod'),
              15: (head: 12, relation: 'conj'),
              16: (head: 15, relation: 'nsubj'),
              17: (head: 18, relation: 'nsubj'),
              18: (head: 16, relation: 'acl:relcl'),
              19: (head: 18, relation: 'xcomp'),
              20: (head: 22, relation: 'case'),
              21: (head: 22, relation: 'det'),
              22: (head: 19, relation: 'obl'),
              23: (head: 24, relation: 'case'),
              24: (head: 19, relation: 'obl'),
            },
          ],
          uposBySentence: const [
            {
              2: 'PRON',
              3: 'AUX',
              5: 'VERB',
              6: 'PRON',
              8: 'ADJ',
              12: 'NOUN',
              15: 'NOUN',
              16: 'PRON',
              17: 'PRON',
              18: 'VERB',
              19: 'VERB',
              22: 'NOUN',
              24: 'PRON',
            },
          ],
        ),
      );

      expect(
        plan.localSentences.map(ReadAloudSplitterV3.wordCount),
        everyElement(lessThanOrEqualTo(20)),
      );
      expect(
        plan.localSentences.any((sentence) => sentence.endsWith('and')),
        isFalse,
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

      expect(
        plan.localSentences.map(ReadAloudSplitterV3.wordCount),
        everyElement(lessThanOrEqualTo(20)),
      );
      expect(
        plan.originals.single.localPath.boundaries
            .where((boundary) => boundary.insideQuotedSpeech),
        isNotEmpty,
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

    test('uses an embedded closing quote comma as the source pause', () {
      const source =
          'There was no label this time with the words "DRINK ME," but nevertheless she uncorked it and put it to her lips.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, const [source]),
      );

      expect(plan.localSentences, const [
        'There was no label this time with the words "DRINK ME,"',
        'but nevertheless she uncorked it and put it to her lips.',
      ]);
      expect(
        plan.originals.single.localPath.boundaries.single.reasons,
        contains('source_closing_quote_comma_pause'),
      );
    });

    test('uses a long quoted-speech comma before its attribution', () {
      const source =
          '"Oh, it\'s all very well to talk," said the Mole rather pettishly, he being new to a river and riverside life and its ways.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source, const [source]),
      );

      expect(plan.localSentences.first, '"Oh, it\'s all very well to talk,"');
      expect(
        plan.originals.single.localPath.boundaries.first.reasons,
        contains('source_closing_quote_comma_pause'),
      );
    });

    test('releases only a stable medium terminal quote from a long attribution',
        () {
      for (final quoteWordCount in const [1, 14, 21]) {
        final quoteWords = List.generate(
          quoteWordCount,
          (index) => 'word${index + 1}',
        );
        quoteWords[quoteWordCount - 1] = '${quoteWords[quoteWordCount - 1]}!';
        final quote = '"${quoteWords.join(' ')}"';
        final source =
            '$quote the narrator replied in a calm and measured voice.';
        final subject = quoteWordCount + 2;
        final predicate = quoteWordCount + 3;
        final plan = ReadAloudSplitterV3.plan(
          source: source,
          document: _document(
            source,
            [source],
            relationsBySentence: [
              {
                subject: (head: predicate, relation: 'nsubj'),
                predicate: (head: 0, relation: 'root'),
              },
            ],
            uposBySentence: [
              {subject: 'NOUN', predicate: 'VERB'},
            ],
          ),
        );
        final quoteEdge = plan.originals.single.boundaryCandidates
            .firstWhere((candidate) => candidate.quoteEdge == 'after_closing');

        if (quoteWordCount == 14) {
          expect(
            quoteEdge.softWarnings,
            isNot(contains('quote_edge_attribution_only_tail')),
          );
          expect(plan.localSentences, [
            quote,
            'the narrator replied in a calm and measured voice.',
          ]);
        } else {
          expect(
            quoteEdge.softWarnings,
            contains('quote_edge_attribution_only_tail'),
          );
        }
      }
    });

    test('splits a quote before a coordinated clause with its own subject', () {
      const source =
          '"Now then, step lively!" and the Mole to his surprise and rapture found himself actually seated in the stern of a real boat.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              5: (head: 6, relation: 'cc'),
              7: (head: 12, relation: 'nsubj'),
              12: (head: 3, relation: 'conj'),
            },
          ],
          uposBySentence: const [
            {3: 'VERB', 5: 'CCONJ', 7: 'NOUN', 12: 'VERB'},
          ],
        ),
      );

      expect(plan.localSentences.first, '"Now then, step lively!"');
      final quoteEdge = plan.originals.single.boundaryCandidates
          .firstWhere((candidate) => candidate.quoteEdge == 'after_closing');
      expect(
        quoteEdge.softWarnings,
        isNot(contains('quote_edge_attribution_only_tail')),
      );
      expect(
        quoteEdge.reasons,
        contains('quote_edge_coordinated_continuation'),
      );
    });

    test('promotes a quote edge when a coordinated conj has its own subject',
        () {
      const source =
          'The Dodo called out, "The race is over!" and they all crowded round it, panting, and asking who had won.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              2: (head: 3, relation: 'nsubj'),
              9: (head: 12, relation: 'cc'),
              10: (head: 12, relation: 'nsubj'),
              12: (head: 3, relation: 'conj'),
            },
          ],
          uposBySentence: const [
            {2: 'NOUN', 3: 'VERB', 9: 'CCONJ', 10: 'PRON', 12: 'VERB'},
          ],
        ),
      );

      final quoteEdge = plan.originals.single.boundaryCandidates
          .firstWhere((candidate) => candidate.quoteEdge == 'after_closing');
      expect(
        quoteEdge.reasons,
        contains('quote_edge_coordinated_continuation'),
      );
      expect(quoteEdge.risk, lessThan(quoteEdge.crossedDependencyArcs * 1000));
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

    test('keeps visible quote punctuation when malformed quotes cannot pair',
        () {
      const openingSource =
          'The patient witness waited until the final answer was completely clear, "Alice replied so eagerly that everyone in the crowded room turned to listen.';
      final openingPlan = ReadAloudSplitterV3.plan(
        source: openingSource,
        document: _document(openingSource, const [openingSource]),
      );
      final openingPause =
          openingPlan.originals.single.boundaryCandidates.firstWhere(
        (candidate) => candidate.reasons
            .contains('source_attribution_before_opening_quote'),
      );
      expect(openingPause.kind, ReadAloudBoundaryKindV3.phraseComma);

      const closingSource =
          'Alice could see that one juror did not know how to spell"stupid,"and that he had to ask his neighbor to tell him before the trial continued.';
      final closingPlan = ReadAloudSplitterV3.plan(
        source: closingSource,
        document: _document(closingSource, const [closingSource]),
      );
      final closingPause =
          closingPlan.originals.single.boundaryCandidates.firstWhere(
        (candidate) => candidate.reasons
            .contains('source_closing_quote_coordinated_pause'),
      );
      expect(closingPause.kind, ReadAloudBoundaryKindV3.phraseComma);
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

    test('V3.7 tight target prefers the complete coordinated noun tail', () {
      const source =
          'It was high time to go for the pool was getting quite crowded with the birds and animals that had fallen into it: there was a Duck and a Dodo, a Lory and an Eaglet, and several other curious creatures.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              1: (head: 4, relation: 'nsubj'),
              2: (head: 4, relation: 'cop'),
              4: (head: 11, relation: 'nsubj'),
              6: (head: 4, relation: 'acl'),
              7: (head: 9, relation: 'case'),
              9: (head: 6, relation: 'obl'),
              10: (head: 11, relation: 'aux'),
              12: (head: 13, relation: 'advmod'),
              13: (head: 11, relation: 'xcomp'),
              14: (head: 16, relation: 'case'),
              16: (head: 13, relation: 'obl'),
              17: (head: 18, relation: 'cc'),
              18: (head: 16, relation: 'conj'),
              19: (head: 21, relation: 'nsubj'),
              20: (head: 21, relation: 'aux'),
              21: (head: 16, relation: 'acl:relcl'),
              22: (head: 23, relation: 'case'),
              23: (head: 21, relation: 'obl'),
              24: (head: 25, relation: 'expl'),
              25: (head: 11, relation: 'parataxis'),
              27: (head: 25, relation: 'nsubj'),
              28: (head: 30, relation: 'cc'),
              30: (head: 27, relation: 'conj'),
              32: (head: 27, relation: 'conj'),
              35: (head: 11, relation: 'conj'),
              40: (head: 11, relation: 'conj'),
            },
          ],
          uposBySentence: const [
            {
              1: 'PRON',
              2: 'AUX',
              4: 'NOUN',
              6: 'VERB',
              7: 'ADP',
              9: 'NOUN',
              10: 'AUX',
              11: 'VERB',
              12: 'ADV',
              13: 'ADJ',
              14: 'ADP',
              16: 'NOUN',
              17: 'CCONJ',
              18: 'NOUN',
              19: 'PRON',
              20: 'AUX',
              21: 'VERB',
              22: 'ADP',
              23: 'PRON',
              24: 'PRON',
              25: 'VERB',
              27: 'NOUN',
              28: 'CCONJ',
              30: 'NOUN',
              32: 'NOUN',
              35: 'NOUN',
              40: 'NOUN',
            },
          ],
        ),
      );

      expect(
        plan.localSentences.map(ReadAloudSplitterV3.wordCount),
        everyElement(lessThanOrEqualTo(20)),
      );
      expect(
        plan.localSentences.any((sentence) => sentence.endsWith('pool')),
        isTrue,
        reason: 'a complete nominal subject may precede its finite predicate',
      );
      expect(
        plan.originals.single.boundaryCandidates
            .firstWhere((candidate) => candidate.afterWord == 13)
            .reasons,
        contains('incomplete_attached_prepositional_complement'),
        reason: '`crowded | with the birds` cuts its attached complement',
      );
    });

    test('V3.9 does not manufacture a three-word introductory fragment', () {
      const source =
          'Breathless and transfixed, the Mole stopped rowing as the liquid run of that glad piping broke on him like a wave, caught him up, and possessed him utterly.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              1: (head: 6, relation: 'nsubj'),
              2: (head: 3, relation: 'cc'),
              3: (head: 1, relation: 'conj'),
              4: (head: 5, relation: 'det'),
              5: (head: 6, relation: 'nsubj'),
              6: (head: 16, relation: 'conj'),
              7: (head: 16, relation: 'xcomp'),
              8: (head: 11, relation: 'case'),
              9: (head: 11, relation: 'det'),
              10: (head: 11, relation: 'amod'),
              11: (head: 7, relation: 'obl'),
              12: (head: 15, relation: 'case'),
              13: (head: 15, relation: 'det'),
              14: (head: 15, relation: 'amod'),
              15: (head: 11, relation: 'nmod'),
              17: (head: 18, relation: 'case'),
              18: (head: 16, relation: 'obl'),
              19: (head: 21, relation: 'case'),
              20: (head: 21, relation: 'det'),
              21: (head: 16, relation: 'obl'),
              22: (head: 16, relation: 'parataxis'),
              23: (head: 22, relation: 'obj'),
              24: (head: 22, relation: 'compound:prt'),
              25: (head: 26, relation: 'cc'),
              26: (head: 16, relation: 'conj'),
              27: (head: 26, relation: 'obj'),
              28: (head: 26, relation: 'advmod'),
            },
          ],
          uposBySentence: const [
            {
              1: 'NOUN',
              2: 'CCONJ',
              3: 'VERB',
              4: 'DET',
              5: 'NOUN',
              6: 'VERB',
              7: 'VERB',
              8: 'ADP',
              9: 'DET',
              10: 'ADJ',
              11: 'NOUN',
              12: 'ADP',
              13: 'DET',
              14: 'ADJ',
              15: 'NOUN',
              16: 'VERB',
              17: 'ADP',
              18: 'PRON',
              19: 'ADP',
              20: 'DET',
              21: 'NOUN',
              22: 'VERB',
              23: 'PRON',
              24: 'ADP',
              25: 'CCONJ',
              26: 'VERB',
              27: 'PRON',
              28: 'ADV',
            },
          ],
        ),
      );

      expect(
        plan.localSentences.map(ReadAloudSplitterV3.wordCount),
        everyElement(lessThanOrEqualTo(20)),
      );
      expect(
        plan.localSentences.first,
        isNot('Breathless and transfixed,'),
        reason: 'R-SHORT-FRAGMENT rejects the three-word modifier fragment',
      );
    });

    test('V3.7 permits explicit coordinated continuations', () {
      const subjectless =
          'The careful witness calmly completed the difficult matter and left little further for anyone in the crowded courtroom to discuss afterward today.';
      final subjectlessPlan = ReadAloudSplitterV3.plan(
        source: subjectless,
        document: _document(
          subjectless,
          const [subjectless],
          relationsBySentence: const [
            {
              3: (head: 5, relation: 'nsubj'),
              9: (head: 10, relation: 'cc'),
              10: (head: 5, relation: 'conj'),
            },
          ],
          uposBySentence: const [
            {3: 'NOUN', 5: 'VERB', 9: 'CCONJ', 10: 'VERB'},
          ],
        ),
      );
      expect(
        subjectlessPlan.originals.single.boundaryCandidates
            .firstWhere((candidate) => candidate.afterWord == 8)
            .reasons,
        contains('deferred_stable_shared_predicate'),
      );
      expect(subjectlessPlan.localSentences, const [
        'The careful witness calmly completed the difficult matter',
        'and left little further for anyone in the crowded courtroom to discuss afterward today.',
      ]);

      const independent =
          'The careful witness calmly completed the difficult matter and the clerk left quietly for the crowded courtroom after the long interview ended.';
      final independentPlan = ReadAloudSplitterV3.plan(
        source: independent,
        document: _document(
          independent,
          const [independent],
          relationsBySentence: const [
            {
              3: (head: 5, relation: 'nsubj'),
              9: (head: 12, relation: 'cc'),
              11: (head: 12, relation: 'nsubj'),
              12: (head: 5, relation: 'conj'),
            },
          ],
          uposBySentence: const [
            {
              3: 'NOUN',
              5: 'VERB',
              9: 'CCONJ',
              11: 'NOUN',
              12: 'VERB',
            },
          ],
        ),
      );
      expect(
        independentPlan.originals.single.boundaryCandidates
            .firstWhere((candidate) => candidate.afterWord == 8)
            .reasons,
        isNot(contains('deferred_stable_shared_predicate')),
      );
    });

    test('uses a source adjective comma when a long block needs splitting', () {
      const source =
          'The thoughtful builder carefully planned a nice, snug dwelling place for the quiet animal beside the peaceful river during the long summer afternoon.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              3: (head: 5, relation: 'nsubj'),
              7: (head: 10, relation: 'amod'),
              8: (head: 10, relation: 'amod'),
              9: (head: 10, relation: 'compound'),
              10: (head: 5, relation: 'obj'),
              11: (head: 14, relation: 'case'),
              12: (head: 14, relation: 'det'),
              13: (head: 14, relation: 'amod'),
              14: (head: 5, relation: 'obl'),
            },
          ],
          uposBySentence: const [
            {
              3: 'NOUN',
              5: 'VERB',
              7: 'ADJ',
              8: 'ADJ',
              9: 'NOUN',
              10: 'NOUN',
              11: 'ADP',
              12: 'DET',
              13: 'ADJ',
              14: 'NOUN',
            },
          ],
        ),
      );

      expect(
        plan.originals.single.localPath.boundaries
            .map((boundary) => boundary.afterWord),
        contains(7),
      );
      expect(
        plan.originals.single.localPath.boundaries
            .firstWhere((boundary) => boundary.afterWord == 7)
            .isPunctuation,
        isTrue,
      );
    });

    test('allows a complete coordinated item before its conjunction', () {
      const source =
          'The careful visitor quietly considered what a nice, snug dwelling-place it would make for an animal with few wants and fond of a peaceful riverside residence above flood level today.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              3: (head: 5, relation: 'nsubj'),
              6: (head: 13, relation: 'obj'),
              7: (head: 10, relation: 'det'),
              8: (head: 10, relation: 'amod'),
              9: (head: 10, relation: 'amod'),
              10: (head: 13, relation: 'nsubj'),
              11: (head: 13, relation: 'nsubj'),
              12: (head: 13, relation: 'aux'),
              13: (head: 5, relation: 'ccomp'),
              14: (head: 16, relation: 'case'),
              15: (head: 16, relation: 'det'),
              16: (head: 13, relation: 'obl'),
              17: (head: 19, relation: 'case'),
              18: (head: 19, relation: 'amod'),
              19: (head: 16, relation: 'nmod'),
              20: (head: 21, relation: 'cc'),
              21: (head: 19, relation: 'conj'),
              22: (head: 26, relation: 'case'),
              26: (head: 21, relation: 'obl'),
              30: (head: 13, relation: 'conj'),
            },
          ],
          uposBySentence: const [
            {
              3: 'NOUN',
              5: 'VERB',
              6: 'PRON',
              7: 'DET',
              8: 'ADJ',
              9: 'ADJ',
              10: 'NOUN',
              11: 'PRON',
              12: 'AUX',
              13: 'VERB',
              14: 'ADP',
              15: 'DET',
              16: 'NOUN',
              17: 'ADP',
              18: 'ADJ',
              19: 'NOUN',
              20: 'CCONJ',
              21: 'VERB',
              22: 'ADP',
              26: 'NOUN',
              30: 'VERB',
            },
          ],
        ),
      );
      final candidate = plan.originals.single.boundaryCandidates
          .firstWhere((boundary) => boundary.afterWord == 19);

      expect(
        candidate.reasons,
        isNot(contains('deferred_stable_shared_predicate')),
      );
      expect(
        plan.originals.single.localPath.boundaries
            .map((boundary) => boundary.afterWord),
        contains(19),
      );
    });

    test('can split between complete coordinated nominal objects', () {
      const source =
          'The workers must get all the furniture and baggage and stores moved out of this building before the machines begin working around the fields.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              2: (head: 4, relation: 'nsubj'),
              3: (head: 4, relation: 'aux'),
              7: (head: 4, relation: 'obj'),
              8: (head: 9, relation: 'cc'),
              9: (head: 7, relation: 'conj'),
              10: (head: 11, relation: 'cc'),
              11: (head: 9, relation: 'conj'),
              12: (head: 4, relation: 'xcomp'),
              14: (head: 16, relation: 'case'),
              16: (head: 12, relation: 'obl'),
              17: (head: 20, relation: 'mark'),
              19: (head: 20, relation: 'nsubj'),
              20: (head: 12, relation: 'advcl'),
              21: (head: 20, relation: 'xcomp'),
            },
          ],
          uposBySentence: const [
            {
              2: 'NOUN',
              3: 'AUX',
              4: 'VERB',
              7: 'NOUN',
              8: 'CCONJ',
              9: 'NOUN',
              10: 'CCONJ',
              11: 'NOUN',
              12: 'VERB',
              14: 'ADP',
              16: 'NOUN',
              17: 'SCONJ',
              19: 'NOUN',
              20: 'VERB',
              21: 'VERB',
            },
          ],
        ),
      );

      expect(
        plan.originals.single.boundaryCandidates
            .firstWhere((boundary) => boundary.afterWord == 9)
            .softWarnings,
        contains('surface_nominal_coordinator_separation'),
      );
      expect(
        plan.originals.single.localPath.boundaries
            .map((boundary) => boundary.afterWord),
        contains(9),
      );
    });

    test('allows a verified predicate after a coordinated nominal object', () {
      const source =
          'The visitor will go to a carpenter or a mason and arrange for the broken cart to be fetched and mended and put right today.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              2: (head: 4, relation: 'nsubj'),
              3: (head: 4, relation: 'aux'),
              5: (head: 7, relation: 'case'),
              7: (head: 4, relation: 'obl'),
              8: (head: 10, relation: 'cc'),
              10: (head: 7, relation: 'conj'),
              11: (head: 12, relation: 'cc'),
              12: (head: 4, relation: 'conj'),
              13: (head: 16, relation: 'case'),
              16: (head: 12, relation: 'obl'),
              19: (head: 16, relation: 'acl'),
              20: (head: 21, relation: 'cc'),
              21: (head: 19, relation: 'conj'),
              22: (head: 23, relation: 'cc'),
              23: (head: 19, relation: 'conj'),
            },
          ],
          uposBySentence: const [
            {
              2: 'NOUN',
              3: 'AUX',
              4: 'VERB',
              5: 'ADP',
              7: 'NOUN',
              8: 'CCONJ',
              10: 'NOUN',
              11: 'CCONJ',
              12: 'VERB',
              13: 'ADP',
              16: 'NOUN',
              19: 'VERB',
              20: 'CCONJ',
              21: 'VERB',
              22: 'CCONJ',
              23: 'VERB',
            },
          ],
        ),
      );
      final candidate = plan.originals.single.boundaryCandidates
          .firstWhere((boundary) => boundary.afterWord == 10);

      expect(
        candidate.reasons,
        contains('deferred_stable_shared_predicate'),
      );
      expect(candidate.softWarnings,
          contains('surface_mixed_coordinator_chain_separation'));
      expect(
        plan.originals.single.localPath.boundaries
            .map((boundary) => boundary.afterWord),
        contains(10),
      );
    });

    test('recovers a supplemental PP after a complete verbal phrase', () {
      const source =
          'The animals knew Badger had retired to his study and settled himself in an arm-chair with his legs up on another chair for the evening.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              2: (head: 3, relation: 'nsubj'),
              4: (head: 6, relation: 'nsubj'),
              5: (head: 6, relation: 'aux'),
              6: (head: 3, relation: 'ccomp'),
              7: (head: 9, relation: 'case'),
              9: (head: 6, relation: 'obl'),
              10: (head: 11, relation: 'cc'),
              11: (head: 6, relation: 'conj'),
              12: (head: 11, relation: 'obj'),
              13: (head: 15, relation: 'case'),
              15: (head: 11, relation: 'obl'),
              16: (head: 22, relation: 'case'),
              18: (head: 22, relation: 'nmod:poss'),
              22: (head: 15, relation: 'nmod'),
              23: (head: 25, relation: 'case'),
              25: (head: 22, relation: 'nmod'),
            },
          ],
          uposBySentence: const [
            {
              2: 'NOUN',
              3: 'VERB',
              4: 'PROPN',
              5: 'AUX',
              6: 'VERB',
              7: 'ADP',
              9: 'NOUN',
              10: 'CCONJ',
              11: 'VERB',
              12: 'PRON',
              13: 'ADP',
              15: 'NOUN',
              16: 'ADP',
              18: 'NOUN',
              19: 'ADP',
              20: 'ADP',
              22: 'NOUN',
              23: 'ADP',
              25: 'NOUN',
            },
          ],
        ),
      );
      final candidate = plan.originals.single.boundaryCandidates
          .firstWhere((boundary) => boundary.afterWord == 15);

      expect(candidate.kind, ReadAloudBoundaryKindV3.dependencyPhrase);
      expect(
        candidate.reasons,
        contains('validated_surface_phrase_boundary'),
      );
    });

    test('keeps an embedded quoted catchphrase inside its nominal list', () {
      const source =
          '"The sentries were on the look-out, of course, with their guns and their \'Who comes there?\' and all the rest of their nonsense."';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          uposBySentence: const [
            {
              2: 'NOUN',
              3: 'AUX',
              6: 'NOUN',
              7: 'ADP',
              8: 'NOUN',
              9: 'ADP',
              11: 'NOUN',
              12: 'CCONJ',
              13: 'DET',
              14: 'PRON',
              15: 'VERB',
              16: 'NOUN',
              17: 'CCONJ',
              18: 'DET',
              19: 'DET',
              20: 'NOUN',
            },
          ],
        ),
      );

      expect(
        plan.originals.single.localPath.boundaries
            .map((boundary) => boundary.afterWord),
        isNot(contains(16)),
      );
      expect(plan.localSentences, const [
        '"The sentries were on the look-out, of course,',
        'with their guns and their \'Who comes there?\' and all the rest of their nonsense."',
      ]);
    });

    test('V3.7 keeps comparative phrase internals but permits its front edge',
        () {
      const source =
          'They carefully helped the nervous visitor to make her aunt appear as much as possible the victim of circumstances over which she had no control today.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              12: (head: 13, relation: 'advmod'),
              13: (head: 11, relation: 'xcomp'),
              14: (head: 15, relation: 'mark'),
              15: (head: 13, relation: 'advcl'),
            },
          ],
          uposBySentence: const [
            {
              9: 'PRON',
              10: 'NOUN',
              11: 'VERB',
              12: 'ADV',
              13: 'ADJ',
              14: 'ADV',
              15: 'ADJ',
            },
          ],
        ),
      );
      final boundaries = plan.originals.single.boundaryCandidates;
      expect(
        boundaries.firstWhere((candidate) => candidate.afterWord == 11).reasons,
        isNot(contains('incomplete_constituent_boundary')),
      );
      expect(
        boundaries.firstWhere((candidate) => candidate.afterWord == 13).reasons,
        contains('incomplete_constituent_boundary'),
      );
      final pronounNominalBoundary =
          boundaries.firstWhere((candidate) => candidate.afterWord == 9);
      expect(pronounNominalBoundary.hardBlocked, isTrue);
      expect(
        pronounNominalBoundary.hardBlockReasons,
        contains('inside_surface_determiner_head'),
      );
      expect(
        pronounNominalBoundary.softWarnings,
        contains('surface_determiner_head_separation'),
      );
      expect(plan.localSentences, const [
        'They carefully helped the nervous visitor to make her aunt appear',
        'as much as possible the victim of circumstances over which she had no control today.',
      ]);
    });

    test('V3.7 permits a prepositional continuation after a complete clause',
        () {
      const source =
          'The magistrates considered how they could make the sentence sufficiently hot for the incorrigible rogue and hardened ruffian waiting quietly before them.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              10: (head: 11, relation: 'advmod'),
              11: (head: 7, relation: 'xcomp'),
              12: (head: 15, relation: 'case'),
              15: (head: 11, relation: 'obl'),
            },
          ],
          uposBySentence: const [
            {7: 'VERB', 10: 'ADV', 11: 'ADJ', 12: 'ADP', 15: 'NOUN'},
          ],
        ),
      );

      final afterHot = plan.originals.single.boundaryCandidates
          .firstWhere((candidate) => candidate.afterWord == 11);
      expect(
        afterHot.reasons,
        isNot(contains('incomplete_constituent_boundary')),
      );
      expect(
        plan.originals.single.candidatePaths.any(
          (path) => path.boundaries.any(
            (boundary) => boundary.afterWord == 11,
          ),
        ),
        isTrue,
      );
    });

    test('E37 keeps the relative front and splits its shared predicate tail',
        () {
      const source =
          'The old lady had been prepared beforehand for the interview, and the sight of certain gold sovereigns that Toad had thoughtfully placed on the table in full view practically completed the matter and left little further to discuss.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              3: (head: 6, relation: 'nsubj:pass'),
              4: (head: 6, relation: 'aux'),
              5: (head: 6, relation: 'aux:pass'),
              7: (head: 6, relation: 'advmod'),
              8: (head: 10, relation: 'case'),
              9: (head: 10, relation: 'det'),
              10: (head: 6, relation: 'obl'),
              11: (head: 13, relation: 'cc'),
              12: (head: 13, relation: 'det'),
              13: (head: 6, relation: 'conj'),
              14: (head: 17, relation: 'case'),
              15: (head: 17, relation: 'amod'),
              16: (head: 17, relation: 'compound'),
              17: (head: 13, relation: 'nmod'),
              18: (head: 20, relation: 'obj'),
              19: (head: 20, relation: 'nsubj'),
              20: (head: 17, relation: 'acl:relcl'),
              21: (head: 22, relation: 'advmod'),
              22: (head: 20, relation: 'xcomp'),
              23: (head: 25, relation: 'case'),
              24: (head: 25, relation: 'det'),
              25: (head: 22, relation: 'obl'),
              26: (head: 28, relation: 'case'),
              27: (head: 28, relation: 'amod'),
              28: (head: 25, relation: 'nmod'),
              29: (head: 30, relation: 'advmod'),
              30: (head: 6, relation: 'conj'),
              31: (head: 32, relation: 'det'),
              32: (head: 30, relation: 'obj'),
              33: (head: 34, relation: 'cc'),
              34: (head: 30, relation: 'conj'),
              35: (head: 34, relation: 'obj'),
              36: (head: 38, relation: 'advmod'),
              37: (head: 38, relation: 'mark'),
              38: (head: 34, relation: 'advcl'),
            },
          ],
          uposBySentence: const [
            {
              1: 'DET',
              2: 'ADJ',
              3: 'NOUN',
              4: 'AUX',
              5: 'AUX',
              6: 'VERB',
              7: 'ADV',
              8: 'ADP',
              9: 'DET',
              10: 'NOUN',
              11: 'CCONJ',
              12: 'DET',
              13: 'NOUN',
              14: 'ADP',
              15: 'ADJ',
              16: 'NOUN',
              17: 'NOUN',
              18: 'PRON',
              19: 'PROPN',
              20: 'VERB',
              21: 'ADV',
              22: 'VERB',
              23: 'ADP',
              24: 'DET',
              25: 'NOUN',
              26: 'ADP',
              27: 'ADJ',
              28: 'NOUN',
              29: 'ADV',
              30: 'VERB',
              31: 'DET',
              32: 'NOUN',
              33: 'CCONJ',
              34: 'VERB',
              35: 'ADJ',
              36: 'ADV',
              37: 'PART',
              38: 'VERB',
            },
          ],
        ),
      );

      expect(plan.localSentences, const [
        'The old lady had been prepared beforehand for the interview,',
        'and the sight of certain gold sovereigns',
        'that Toad had thoughtfully placed on the table in full view practically completed the matter',
        'and left little further to discuss.',
      ]);
      expect(
        plan.originals.single.localPath.boundaries
            .map((boundary) => boundary.afterWord),
        const [10, 17, 32],
      );
    });

    test('prefers the source comma closing a relative clause', () {
      const source =
          'Mole, who with gentle strokes was just keeping the boat moving while he scanned the banks with care, looked at him with curiosity.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              1: (head: 19, relation: 'nsubj'),
              2: (head: 8, relation: 'nsubj'),
              8: (head: 1, relation: 'acl:relcl'),
              13: (head: 14, relation: 'nsubj'),
              14: (head: 8, relation: 'advcl'),
              19: (head: 0, relation: 'root'),
            },
          ],
          uposBySentence: const [
            {
              1: 'PROPN',
              2: 'PRON',
              8: 'VERB',
              13: 'PRON',
              14: 'VERB',
              19: 'VERB',
            },
          ],
        ),
      );

      expect(
        plan.originals.single.localPath.boundaries
            .map((boundary) => boundary.afterWord),
        contains(18),
        reason: 'R-PUNCT-FIRST keeps the relative-clause closing comma',
      );
      expect(
        plan.localSentences.map(ReadAloudSplitterV3.wordCount),
        everyElement(lessThanOrEqualTo(20)),
      );
      expect(
        plan.localSentences.any((sentence) => sentence.endsWith('scanned')),
        isFalse,
        reason: 'R-SYNTAX-LOCATION keeps the direct object with its verb',
      );
    });

    test('splits before but never after a coordinated adverb continuation', () {
      const source =
          'The country lay bare around him, and he thought that he had never seen so far and so intimately into the insides of things as on that winter day.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(
          source,
          const [source],
          relationsBySentence: const [
            {
              2: (head: 3, relation: 'nsubj'),
              3: (head: 0, relation: 'root'),
              8: (head: 9, relation: 'nsubj'),
              9: (head: 3, relation: 'conj'),
              11: (head: 14, relation: 'nsubj'),
              12: (head: 14, relation: 'aux'),
              13: (head: 14, relation: 'advmod'),
              14: (head: 9, relation: 'ccomp'),
              15: (head: 16, relation: 'advmod'),
              16: (head: 14, relation: 'advmod'),
              17: (head: 19, relation: 'cc'),
              18: (head: 19, relation: 'advmod'),
              19: (head: 16, relation: 'conj'),
            },
          ],
          uposBySentence: const [
            {
              2: 'NOUN',
              3: 'VERB',
              7: 'CCONJ',
              8: 'PRON',
              9: 'VERB',
              11: 'PRON',
              12: 'AUX',
              13: 'ADV',
              14: 'VERB',
              15: 'ADV',
              16: 'ADV',
              17: 'CCONJ',
              18: 'ADV',
              19: 'ADV',
            },
          ],
        ),
      );

      final candidates = plan.originals.single.boundaryCandidates;
      expect(
        candidates
            .firstWhere((candidate) => candidate.afterWord == 14)
            .softWarnings,
        contains('surface_predicate_adverbial_complement_separation'),
      );
      expect(
        candidates
            .firstWhere((candidate) => candidate.afterWord == 16)
            .softWarnings,
        contains('surface_adverb_coordinator_separation'),
      );
      expect(
        candidates
            .firstWhere((candidate) => candidate.afterWord == 17)
            .softWarnings,
        contains('surface_adverb_coordinator_right_operand_separation'),
      );
      expect(
        plan.originals.single.localPath.boundaries.map(
          (boundary) => boundary.afterWord,
        ),
        contains(16),
      );
      expect(
        plan.originals.single.localPath.boundaries.map(
          (boundary) => boundary.afterWord,
        ),
        isNot(contains(anyOf(14, 17))),
      );
    });

    test('V3.9 matches the reviewed punctuation and delimiter boundaries', () {
      const parentheticalTail =
          'and it sat for a long time with one finger pressed upon its forehead (the position in which you usually see Shakespeare, in the pictures of him),';
      final parentheticalTailPlan = ReadAloudSplitterV3.plan(
        source: parentheticalTail,
        document: _document(parentheticalTail, const [parentheticalTail]),
      );
      expect(
          parentheticalTailPlan.localSentences,
          const [
            'and it sat for a long time with one finger pressed upon its forehead',
            '(the position in which you usually see Shakespeare, in the pictures of him),',
          ],
          reason: 'R-PUNCT-FIRST / Alice-E10-H004');

      const embeddedParenthetical =
          'She did it so quickly that the poor little juror (it was Bill, the Lizard) could not make out at all what had become of it;';
      final embeddedParentheticalPlan = ReadAloudSplitterV3.plan(
        source: embeddedParenthetical,
        document: _document(
          embeddedParenthetical,
          const [embeddedParenthetical],
        ),
      );
      expect(
          embeddedParentheticalPlan.localSentences,
          const [
            'She did it so quickly that the poor little juror (it was Bill, the Lizard)',
            'could not make out at all what had become of it;',
          ],
          reason: 'R-DELIMITER-EDGE / Alice-E36-H007');

      const terminalParenthetical =
          'and as he wore his crown over the wig (look at the frontispiece if you want to see how he did it),';
      final terminalParentheticalPlan = ReadAloudSplitterV3.plan(
        source: terminalParenthetical,
        document: _document(
          terminalParenthetical,
          const [terminalParenthetical],
        ),
      );
      expect(
          terminalParentheticalPlan.localSentences,
          const [
            'and as he wore his crown over the wig',
            '(look at the frontispiece if you want to see how he did it),',
          ],
          reason: 'R-DELIMITER-EDGE / Alice-E36-H002');

      const adjectiveComma =
          'and dreamily he fell to considering what a nice, snug dwelling-place it would make for an animal with few wants and fond of a bijou riverside residence,';
      final adjectiveCommaPlan = ReadAloudSplitterV3.plan(
        source: adjectiveComma,
        document: _document(adjectiveComma, const [adjectiveComma]),
      );
      expect(
        adjectiveCommaPlan.localSentences.first,
        'and dreamily he fell to considering what a nice,',
        reason: 'R-PUNCT-FIRST / Willows-E01-H011',
      );
      expect(
        adjectiveCommaPlan.localSentences.map(ReadAloudSplitterV3.wordCount),
        everyElement(lessThanOrEqualTo(20)),
      );
    });

    test('V3.9 matches the reviewed safe syntax boundaries', () {
      const harvest =
          'and what sort of harvest an animal of spirit might hope to bring home from it to warm his latter days with gallant memories by the fireside; for my life, I confess to you,';
      final harvestPlan = ReadAloudSplitterV3.plan(
        source: harvest,
        document: _document(
          harvest,
          const [harvest],
          uposBySentence: const [
            {
              1: 'CCONJ',
              5: 'NOUN',
              7: 'NOUN',
              9: 'NOUN',
              10: 'AUX',
              11: 'VERB',
              18: 'VERB',
              19: 'DET',
              21: 'NOUN',
              22: 'ADP',
              24: 'NOUN',
              25: 'ADP',
              27: 'NOUN',
              28: 'ADP',
              29: 'DET',
              30: 'NOUN',
              31: 'PRON',
              32: 'VERB',
              33: 'ADP',
              34: 'PRON',
            },
          ],
        ),
      );
      expect(
          harvestPlan.localSentences,
          const [
            'and what sort of harvest an animal of spirit',
            'might hope to bring home from it to warm his latter days with gallant memories',
            'by the fireside; for my life, I confess to you,',
          ],
          reason: 'R-SYNTAX-LOCATION / Willows-E43-H003');

      const outerWorld =
          'and knew that all the grim darkness of a medieval fortress lay between him and the outer world of sunshine and well-metalled high roads where he had lately been so happy,';
      final outerWorldPlan = ReadAloudSplitterV3.plan(
        source: outerWorld,
        document: _document(outerWorld, const [outerWorld]),
      );
      expect(
          outerWorldPlan.localSentences,
          const [
            'and knew that all the grim darkness of a medieval fortress lay between him',
            'and the outer world of sunshine',
            'and well-metalled high roads where he had lately been so happy,',
          ],
          reason: 'R-SYNTAX-LOCATION / Willows-E35-H001');
    });

    test('V3.9 matches the final two reviewed safe syntax boundaries', () {
      const sharedPredicate =
          'But it was good to think he had this to come back to, this place which was all his own, these things which were so glad to see him again and could always be counted upon for the same simple welcome.';
      final sharedPredicatePlan = ReadAloudSplitterV3.plan(
        source: sharedPredicate,
        document: _document(
          sharedPredicate,
          const [sharedPredicate],
          relationsBySentence: const [
            {
              22: (head: 31, relation: 'nsubj'),
              28: (head: 26, relation: 'advcl'),
              31: (head: 35, relation: 'cc'),
              35: (head: 4, relation: 'conj'),
            },
          ],
          uposBySentence: const [
            {
              4: 'ADJ',
              22: 'NOUN',
              26: 'ADJ',
              28: 'VERB',
              31: 'CCONJ',
              32: 'AUX',
              35: 'VERB',
            },
          ],
        ),
      );
      expect(
          sharedPredicatePlan.localSentences,
          const [
            'But it was good to think he had this to come back to,',
            'this place which was all his own,',
            'these things which were so glad to see him again',
            'and could always be counted upon for the same simple welcome.',
          ],
          reason: 'R-SYNTAX-LOCATION / Willows-E25-O24');

      const supplementalTail =
          'The rusty key creaked in the lock, the great door clanged behind them; and Toad was a helpless prisoner in the remotest dungeon of the best-guarded keep of the stoutest castle in all the length and breadth of Merry England.';
      final supplementalTailPlan = ReadAloudSplitterV3.plan(
        source: supplementalTail,
        document: _document(
          supplementalTail,
          const [supplementalTail],
          relationsBySentence: const [
            {
              15: (head: 19, relation: 'nsubj'),
              16: (head: 19, relation: 'cop'),
              19: (head: 10, relation: 'conj'),
              20: (head: 23, relation: 'case'),
              21: (head: 23, relation: 'det'),
              22: (head: 23, relation: 'amod'),
              23: (head: 19, relation: 'nmod'),
              24: (head: 27, relation: 'case'),
              25: (head: 27, relation: 'det'),
              26: (head: 27, relation: 'amod'),
              27: (head: 23, relation: 'nmod'),
              28: (head: 31, relation: 'case'),
              29: (head: 31, relation: 'det'),
              30: (head: 31, relation: 'amod'),
              31: (head: 27, relation: 'nmod'),
              32: (head: 35, relation: 'case'),
              33: (head: 35, relation: 'det:predet'),
              34: (head: 35, relation: 'det'),
              35: (head: 31, relation: 'nmod'),
              36: (head: 37, relation: 'cc'),
              37: (head: 35, relation: 'conj'),
              38: (head: 40, relation: 'case'),
              39: (head: 40, relation: 'compound'),
              40: (head: 37, relation: 'nmod'),
            },
          ],
          uposBySentence: const [
            {
              10: 'NOUN',
              15: 'PROPN',
              16: 'AUX',
              19: 'NOUN',
              20: 'ADP',
              23: 'NOUN',
              24: 'ADP',
              25: 'DET',
              26: 'ADJ',
              27: 'NOUN',
              28: 'ADP',
              29: 'DET',
              30: 'ADJ',
              31: 'NOUN',
              32: 'ADP',
              33: 'DET',
              34: 'DET',
              35: 'NOUN',
              36: 'CCONJ',
              37: 'NOUN',
              38: 'ADP',
              39: 'PROPN',
              40: 'PROPN',
            },
          ],
        ),
      );
      expect(
          supplementalTailPlan.localSentences,
          const [
            'The rusty key creaked in the lock,',
            'the great door clanged behind them;',
            'and Toad was a helpless prisoner in the remotest dungeon of the best-guarded keep of the stoutest castle',
            'in all the length and breadth of Merry England.',
          ],
          reason: 'R-SYNTAX-LOCATION / Willows-E30-O21');
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
