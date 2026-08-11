import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v3.dart';
import 'package:tomato_english_happy_talking/services/udpipe_syntax_parser_v3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled = Platform.environment['TOMATO_RUN_SENTENCE_V3_HOLDOUT'] == '1';

  test(
    'matches sixty frozen EWT holdout expectations',
    () async {
      final repository = Directory.current.parent;
      final conllu = File(
        '${repository.path}/tools/sentence_split_v3/training/'
        'ud_english_ewt_r2_18/en_ewt-ud-test.conllu',
      );
      final probe = File(
        Platform.environment['TOMATO_UDPIPE_PROBE'] ??
            '${repository.path}/build/udpipe-v3-trainer/udpipe_v3_probe.exe',
      );
      final model = File(
        Platform.environment['TOMATO_UDPIPE_MODEL'] ??
            '${repository.path}/app/assets/models/'
                'english-ewt-r2.18-udpipe-v1.4.0.model',
      );
      final output = File(
        Platform.environment['TOMATO_SENTENCE_V3_HOLDOUT_OUTPUT'] ??
            '${repository.path}/output/sentence-split-v3/'
                'holdout-ewt-v3-6.json',
      );
      expect(conllu.existsSync(), isTrue, reason: conllu.path);
      expect(probe.existsSync(), isTrue, reason: probe.path);
      expect(model.existsSync(), isTrue, reason: model.path);

      final samples = _frozenSamples(conllu.readAsLinesSync());
      expect(samples, hasLength(60));
      expect(samples.map((value) => value.genre).toSet(), hasLength(5));
      final source = samples.map((value) => value.text).join('\n\n');
      final digest = await Sha256().hash(await model.readAsBytes());
      final modelSha = digest.bytes
          .map((value) => value.toRadixString(16).padLeft(2, '0'))
          .join();
      final temp = await Directory.systemTemp.createTemp('tomato-v3-holdout-');
      try {
        var nativeCalls = 0;
        final document = await UdpipeSyntaxParserV3.parseRawPipelineForTest(
          source: source,
          modelSha256: modelSha,
          provider: ({required text, required presegmented}) async {
            nativeCalls += 1;
            final input = File('${temp.path}/parse-$nativeCalls.txt');
            await input.writeAsString(text, encoding: utf8, flush: true);
            final result = await Process.run(
              probe.path,
              [model.path, input.path, if (presegmented) '--presegmented'],
              stdoutEncoding: utf8,
              stderrEncoding: utf8,
            );
            if (result.exitCode != 0) {
              throw StateError('UDPipe probe failed: ${result.stderr}');
            }
            return result.stdout.toString();
          },
        );
        final plan = ReadAloudSplitterV3.plan(
          source: source,
          document: document,
        );
        final results = <Map<String, dynamic>>[];
        var cursor = 0;
        var passed = 0;
        for (final sample in samples) {
          final start = source.indexOf(sample.text, cursor);
          final end = start + sample.text.length;
          final decisions = plan.originals
              .where(
                (decision) =>
                    decision.sourceStart >= start && decision.sourceEnd <= end,
              )
              .toList(growable: false);
          final predicted = decisions
              .expand((decision) => decision.localPath.segments)
              .toList(growable: false);
          final expected =
              _v36ExpectedSegments[sample.text] ?? <String>[sample.text];
          final exact = predicted.length == expected.length &&
              List.generate(
                predicted.length,
                (index) =>
                    ReadAloudSplitterV3.normalizeForRoundTrip(
                      predicted[index],
                    ) ==
                    ReadAloudSplitterV3.normalizeForRoundTrip(expected[index]),
              ).every((matches) => matches);
          if (exact) passed += 1;
          results.add({
            'genre': sample.genre,
            'documentId': sample.documentId,
            'source': sample.text,
            'expected': expected,
            'predicted': predicted,
            'exact': exact,
          });
          cursor = end;
        }
        await output.parent.create(recursive: true);
        await output.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert({
                'schemaVersion': 'sentence_split_holdout_ewt_v3_2',
                'selection': 'first_12_safe_sentences_per_ewt_genre',
                'solverVersion': ReadAloudSplitterV3.solverVersion,
                'parserVersion': document.parserVersion,
                'modelSha256': modelSha,
                'caseCount': samples.length,
                'passedCount': passed,
                'passRate': passed / samples.length,
                'remoteCalls': 0,
                'results': results,
              })}\n',
          encoding: utf8,
          flush: true,
        );
        expect(passed, samples.length, reason: output.path);
      } finally {
        if (await temp.exists()) await temp.delete(recursive: true);
      }
    },
    skip: enabled ? false : 'set TOMATO_RUN_SENTENCE_V3_HOLDOUT=1',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

const _v36ExpectedSegments = <String, List<String>>{
  '"...there is no companion quite so devoted, so communicative, so loving and so mesmerizing as a rat."':
      [
    '"...there is no companion quite so devoted,',
    'so communicative, so loving and so mesmerizing as a rat."',
  ],
};

class _HoldoutSampleV3 {
  const _HoldoutSampleV3({
    required this.genre,
    required this.documentId,
    required this.text,
  });

  final String genre;
  final String documentId;
  final String text;
}

List<_HoldoutSampleV3> _frozenSamples(List<String> lines) {
  const genres = {'answers', 'email', 'newsgroup', 'reviews', 'weblog'};
  final counts = {for (final genre in genres) genre: 0};
  final result = <_HoldoutSampleV3>[];
  var documentId = '';
  for (final line in lines) {
    if (line.startsWith('# newdoc id = ')) {
      documentId = line.substring('# newdoc id = '.length).trim();
      continue;
    }
    if (!line.startsWith('# text = ')) continue;
    final text = line.substring('# text = '.length).trim();
    final genre = documentId.split('-').first;
    if (!genres.contains(genre) || counts[genre]! >= 12) continue;
    final words = ReadAloudSplitterV3.wordCount(text);
    if (words < 8 || words > 20) continue;
    if (ReadAloudSplitterV3.maxUnpunctuatedWordCount(text) > 20) continue;
    result.add(
      _HoldoutSampleV3(
        genre: genre,
        documentId: documentId,
        text: text,
      ),
    );
    counts[genre] = counts[genre]! + 1;
    if (counts.values.every((value) => value == 12)) break;
  }
  return result;
}
