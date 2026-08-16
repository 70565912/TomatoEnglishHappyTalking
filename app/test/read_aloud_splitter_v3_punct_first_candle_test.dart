import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v3.dart';

void main() {
  test(
    'prefers clause comma after blown out over syntax cut after candle',
    () {
      final fixture = Map<String, dynamic>.from(
        jsonDecode(
          File(
            'test/fixtures/read_aloud_splitter_v3_punct_first_candle.json',
          ).readAsStringSync(),
        ) as Map,
      );
      final source = fixture['source'].toString();
      final expected = (fixture['expectedSegments'] as List)
          .map((value) => value.toString())
          .toList(growable: false);
      final document = DependencyDocumentV3(
        parserVersion: fixture['parserVersion'].toString(),
        modelSha256: fixture['modelSha256'].toString(),
        healthy: true,
        sentences: (fixture['sentences'] as List)
            .map((value) => Map<String, dynamic>.from(value as Map))
            .map(
              (sentence) => DependencySentenceV3(
                start: (sentence['start'] as num).toInt(),
                end: (sentence['end'] as num).toInt(),
                tokens: (sentence['tokens'] as List)
                    .map((value) => Map<String, dynamic>.from(value as Map))
                    .map(
                      (token) => DependencyTokenV3(
                        id: (token['id'] as num).toInt(),
                        text: token['text'].toString(),
                        start: (token['start'] as num).toInt(),
                        end: (token['end'] as num).toInt(),
                        upos: token['upos'].toString(),
                        head: (token['head'] as num).toInt(),
                        deprel: token['deprel'].toString(),
                      ),
                    )
                    .toList(growable: false),
              ),
            )
            .toList(growable: false),
      );

      final plan = ReadAloudSplitterV3.plan(
        source: source,
        document: document,
      );
      final decision = plan.originals.single;
      expect(decision.localPath.segments, expected);
      expect(
        decision.localPath.boundaries.single.kind,
        ReadAloudBoundaryKindV3.clauseComma,
      );
      expect(decision.localPath.usesNonPunctuation, isFalse);
      expect(plan.counters.sentenceFactBuilds, 1);
      expect(plan.counters.dagSolves, 1);
    },
  );
}
