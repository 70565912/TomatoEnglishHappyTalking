import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v2.dart';
import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v3.dart';

void main() {
  final enabled = Platform.environment['TOMATO_RUN_SENTENCE_V2_BASELINE'] == '1';
  test(
    'records the retired V2 splitter against the retained 243 inputs',
    () async {
      final fixture = jsonDecode(
        File('test/fixtures/sentence_split_gold_v3.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final items = (fixture['items'] as List)
          .map((value) => Map<String, dynamic>.from(value as Map))
          .toList(growable: false);
      var exactCount = 0;
      final results = <Map<String, dynamic>>[];
      for (final item in items) {
        final source = item['source'] as String;
        final expected = (item['expectedChunks'] as List)
            .map((value) => value.toString())
            .toList(growable: false);
        final predicted = ReadAloudSplitterV2.splitSentences(source);
        final exact = _sameNormalized(expected, predicted);
        if (exact) exactCount += 1;
        results.add({
          'id': item['id'],
          'episode': item['episode'],
          'source': source,
          'expected': expected,
          'predicted': predicted,
          'exact': exact,
        });
      }
      final repository = Directory.current.parent;
      final output = File(
        Platform.environment['TOMATO_SENTENCE_V2_BASELINE_OUTPUT'] ??
            '${repository.path}/output/sentence-split-v3/'
                'retired-v2-gold-baseline.json',
      );
      await output.parent.create(recursive: true);
      await output.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert({
              'schemaVersion': 'retired_sentence_split_v2_baseline_v1',
              'splitterVersion': ReadAloudSplitterV2.version,
              'itemCount': items.length,
              'exactMatchCount': exactCount,
              'exactMatchRate': exactCount / items.length,
              'results': results,
            })}\n',
        encoding: utf8,
        flush: true,
      );
      expect(results, hasLength(243));
    },
    skip: enabled ? false : 'set TOMATO_RUN_SENTENCE_V2_BASELINE=1',
  );
}

bool _sameNormalized(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (ReadAloudSplitterV3.normalizeForRoundTrip(left[index]) !=
        ReadAloudSplitterV3.normalizeForRoundTrip(right[index])) {
      return false;
    }
  }
  return true;
}
