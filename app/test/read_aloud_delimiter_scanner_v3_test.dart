import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v3.dart';

void main() {
  group('ReadAloudDelimiterScannerV3', () {
    test('matches straight and curly quotes plus parentheses in one scan', () {
      const source =
          'He said “outer ‘inner’ words” and then \'plain words\' (aside).';
      final scan = ReadAloudDelimiterScannerV3.scan(
        source: source,
        tokens: _document(source).sentences.single.tokens,
      );

      expect(
        scan.spans.map((span) => source.substring(span.start, span.end)),
        containsAll(<String>[
          '“outer ‘inner’ words”',
          '‘inner’',
          "'plain words'",
          '(aside)',
        ]),
      );
      expect(scan.parentheticalIssues, isEmpty);
    });

    test('keeps close and open marks on opposite sides of speaker edges', () {
      for (final source in <String>[
        '‘First voice.’‘Second voice.’',
        '‘First voice.’ ‘Second voice.’',
        "'First voice.''Second voice.'",
        "'First voice.' 'Second voice.'",
      ]) {
        final scan = ReadAloudDelimiterScannerV3.scan(
          source: source,
          tokens: _document(source).sentences.single.tokens,
        );
        final quotes = scan.quoteSpans;
        expect(quotes, hasLength(2), reason: source);
        expect(
          source.substring(quotes.first.start, quotes.first.end),
          anyOf('‘First voice.’', "'First voice.'"),
          reason: source,
        );
        expect(
          source.substring(quotes.last.start, quotes.last.end),
          anyOf('‘Second voice.’', "'Second voice.'"),
          reason: source,
        );
      }
    });

    test('does not pair apostrophes, elisions, or paragraph damage', () {
      const source =
          "don't she's Alice's dogs' ’Twas 'em\n\n'broken paragraph\n\nstill broken'";
      final scan = ReadAloudDelimiterScannerV3.scan(
        source: source,
        tokens: _document(source).sentences.expand((value) => value.tokens),
      );

      expect(scan.quoteSpans, isEmpty);
      expect(scan.quoteIssues, isNotEmpty);
    });

    test('records the real glued ASCII punctuation token shape', () {
      const source = "'Of course,' Alice said.''And next,' she added.";
      final document = _document(
        source,
        tokenSurfaces: const [
          "'Of",
          "course,'",
          'Alice',
          "said.''",
          'And',
          "next,'",
          'she',
          'added.',
        ],
      );
      final scan = ReadAloudDelimiterScannerV3.scan(
        source: source,
        tokens: document.sentences.single.tokens,
      );

      expect(
        scan.quoteSpans.map((span) => source.substring(span.start, span.end)),
        containsAll(<String>["'Of course,'", "'And next,'"]),
      );
    });
  });

  group('v3.9 delimiter regression windows', () {
    test('C14 keeps each complete passenger quotation intact', () {
      const source =
          "saying ‘She must go by post, as she's got a head on her’ ‘She must be sent as a message by the telegraph’";
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source),
      );

      expect(
        plan.localSentences,
        const [
          "saying ‘She must go by post, as she's got a head on her’",
          '‘She must be sent as a message by the telegraph’',
        ],
        reason: _candidateSummary(plan),
      );
    });

    test('C32 retains the comma split and adds the adjacent speaker split', () {
      const source =
          '‘It\'s called “wabe,” you know, because it goes a long way before it, and a long way behind it’‘And a long way beyond it on each side,’ Alice added.';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source),
      );

      expect(
        plan.localSentences,
        const [
          '‘It\'s called “wabe,” you know, because it goes a long way before it,',
          'and a long way behind it’',
          '‘And a long way beyond it on each side,’ Alice added.',
        ],
        reason: _candidateSummary(plan),
      );
    });

    test('repaired C26 source owns each quote edge without guessing damage',
        () {
      const source =
          '‘but I\'ll tell you what—’ she added, as a sudden thought struck her. ‘I\'ll follow it up tomorrow.’';
      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: _document(source),
      );

      expect(
        plan.localSentences,
        <String>[
          '‘but I\'ll tell you what—’ she added, as a sudden thought struck her.',
          '‘I\'ll follow it up tomorrow.’',
        ],
        reason: _candidateSummary(plan),
      );
    });
  });
}

String _candidateSummary(ReadAloudSplitPlanV3 plan) =>
    plan.originals.single.boundaryCandidates
        .where((candidate) => candidate.quoteEdge != null)
        .map(
          (candidate) =>
              '${candidate.afterWord}:${candidate.kind.name}:${candidate.quoteEdge}:'
              '${candidate.quoteSpanWordCount}:${candidate.hardBlockReasons}',
        )
        .join('\n');

DependencyDocumentV3 _document(
  String source, {
  List<String>? tokenSurfaces,
}) {
  final surfaces = tokenSurfaces ??
      RegExp(r'\S+')
          .allMatches(source)
          .map((match) => match.group(0)!)
          .toList();
  final tokens = <DependencyTokenV3>[];
  var cursor = 0;
  for (var index = 0; index < surfaces.length; index += 1) {
    final surface = surfaces[index];
    final start = source.indexOf(surface, cursor);
    if (start < 0) throw StateError('Token not found after $cursor: $surface');
    final end = start + surface.length;
    tokens.add(
      DependencyTokenV3(
        id: index + 1,
        text: surface,
        sourceText: surface,
        start: start,
        end: end,
        upos: RegExp(r'''^[.!?,;:"'“”‘’()]+$''').hasMatch(surface)
            ? 'PUNCT'
            : 'NOUN',
        head: 0,
        deprel: 'root',
      ),
    );
    cursor = end;
  }
  return DependencyDocumentV3(
    parserVersion: 'real-shape-fixture',
    modelSha256: 'fixture-model',
    sentences: [
      DependencySentenceV3(
        start: tokens.first.start,
        end: tokens.last.end,
        tokens: tokens,
      ),
    ],
    healthy: true,
  );
}
