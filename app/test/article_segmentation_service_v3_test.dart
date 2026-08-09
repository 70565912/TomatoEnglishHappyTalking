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
    expect(result.audit.solverVersion, 'syntax_solver_v3_3');
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
