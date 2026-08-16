import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/article_segmentation_service_v3.dart';
import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('canonical service chooses a punctuation path without remote AI',
      () async {
    const source =
        'One two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen; seventeen eighteen nineteen twenty twenty-one twenty-two twenty-three twenty-four twenty-five twenty-six twenty-seven twenty-eight twenty-nine thirty thirty-one thirty-two.';
    final service = ArticleSegmentationServiceV3(
      parser: _FixedParser(_documentFor(source, healthy: true)),
    );

    final result = await service.split(source);

    expect(result.sentences, const [
      'One two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen;',
      'seventeen eighteen nineteen twenty twenty-one twenty-two twenty-three twenty-four twenty-five twenty-six twenty-seven twenty-eight twenty-nine thirty thirty-one thirty-two.',
    ]);
    expect(result.plan.originals.single.localPath.stage,
        ReadAloudPathStageV3.punctuation);
    expect(result.selection.remoteAttempts, 0);
    expect(result.audit.sentenceSplitVersion, 'reviewed_dp_v3');
    expect(result.audit.solverVersion, 'syntax_solver_v3_8');
    expect(result.audit.parserHealthy, isTrue);
    expect(result.audit.selectedPaths.values.single, startsWith('v3_o0_r1_'));
  });

  test('parser failure is explicit and never silently uses a legacy word list',
      () async {
    const source = 'Mole looked up. Rat waved back.';
    const service = ArticleSegmentationServiceV3(parser: _ThrowingParser());

    final result = await service.split(source);

    expect(result.sentences, const ['Mole looked up.', 'Rat waved back.']);
    expect(result.audit.parserHealthy, isFalse);
    expect(result.audit.fallbackReason, contains('parser_failed'));
    expect(result.audit.parserIssues, contains('parser_unavailable'));
    expect(
      result.audit.candidatePaths.every(
        (entry) => entry['parserHealthy'] == false,
      ),
      isTrue,
    );
  });

  test('surviving-boundary contract accepts one-word merge across originals',
      () async {
    const flood =
        'A moment, and he had caught it again; and with it this time came recollection in fullest flood.';
    const home = 'Home!';
    const next = 'That was what they meant.';
    const source = '$flood $home $next';
    final service = ArticleSegmentationServiceV3(
      parser: _FixedParser(
        _documentForSentences(source, const [flood, home, next]),
      ),
    );

    final result = await service.split(source);

    expect(
      result.sentences
          .where((chunk) => ReadAloudSplitterV3.wordCount(chunk) == 1),
      isEmpty,
    );
    expect(
      result.sentences.any((chunk) => chunk.endsWith('flood. Home!')),
      isTrue,
    );
    expect(
      () => ReadAloudSplitterV3.validateReviewedSentences(
        source,
        result.sentences,
        requiredBoundaryWordOffsets:
            ReadAloudSplitterV3.requiredBoundaryWordOffsetsAfterMerge(
          result.plan,
          result.selection.selectedPathIds,
        ),
      ),
      returnsNormally,
    );
  });
}

class _FixedParser implements ReadAloudSyntaxParserV3 {
  const _FixedParser(this.document);

  final DependencyDocumentV3 document;

  @override
  Future<DependencyDocumentV3> parse(String text) async => document;
}

class _ThrowingParser implements ReadAloudSyntaxParserV3 {
  const _ThrowingParser();

  @override
  Future<DependencyDocumentV3> parse(String text) async {
    throw StateError('model unavailable');
  }
}

DependencyDocumentV3 _documentFor(String source, {required bool healthy}) {
  final matches = RegExp(r'\S+').allMatches(source).toList(growable: false);
  return DependencyDocumentV3(
    parserVersion: 'test-udpipe-1.4.0',
    modelSha256: 'test-model-sha256',
    healthy: healthy,
    sentences: [
      DependencySentenceV3(
        start: 0,
        end: source.length,
        tokens: [
          for (final indexed in matches.indexed)
            DependencyTokenV3(
              id: indexed.$1 + 1,
              text: indexed.$2.group(0)!,
              start: indexed.$2.start,
              end: indexed.$2.end,
              upos: 'X',
              head: 0,
              deprel: 'dep',
            ),
        ],
      ),
    ],
  );
}

DependencyDocumentV3 _documentForSentences(
  String source,
  List<String> sentences,
) {
  final parsed = <DependencySentenceV3>[];
  var cursor = 0;
  for (final sentence in sentences) {
    final start = source.indexOf(sentence, cursor);
    if (start < 0) {
      throw StateError('Test sentence not found: $sentence');
    }
    final end = start + sentence.length;
    final tokens = <DependencyTokenV3>[];
    var id = 0;
    for (final match in RegExp(r'\S+').allMatches(sentence)) {
      id += 1;
      tokens.add(
        DependencyTokenV3(
          id: id,
          text: match.group(0)!,
          start: start + match.start,
          end: start + match.end,
          upos: 'X',
          head: 0,
          deprel: 'dep',
        ),
      );
    }
    parsed.add(
      DependencySentenceV3(
        start: start,
        end: end,
        tokens: tokens,
      ),
    );
    cursor = end;
  }
  return DependencyDocumentV3(
    parserVersion: 'test-udpipe-1.4.0',
    modelSha256: 'test-model-sha256',
    healthy: true,
    sentences: parsed,
  );
}
