import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v3.dart';
import 'package:tomato_english_happy_talking/services/udpipe_syntax_parser_v3.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native UDPipe and canonical V3 solver share fixed output',
      (tester) async {
    const source =
        'The committee released the report after investigators had reviewed every interview and checked the records that witnesses submitted during the final week.\n\n'
        'Mole looked up. Rat waved back. Toad laughed loudly.';
    const expected = [
      'The committee released the report after investigators had reviewed every interview',
      'and checked the records that witnesses submitted during the final week.',
      'Mole looked up.',
      'Rat waved back.',
      'Toad laughed loudly.',
    ];

    final document = await UdpipeSyntaxParserV3().parse(source);
    final plan = ReadAloudSplitterV3.plan(
      source: source,
      document: document,
    );

    expect(document.healthy, isTrue, reason: document.issues.join('; '));
    expect(
      document.modelSha256,
      UdpipeSyntaxParserV3.expectedModelSha256,
    );
    expect(ReadAloudSplitterV3.solverVersion, 'syntax_solver_v3_7');
    expect(plan.localSentences, expected);
    expect(plan.originals, hasLength(4));
    expect(
        plan.originals
            .skip(1)
            .every((item) => item.localPath.segments.length == 1),
        isTrue);
  });
}
