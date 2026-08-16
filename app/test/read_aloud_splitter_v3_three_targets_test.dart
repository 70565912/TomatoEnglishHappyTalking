import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v3.dart';

Map<String, dynamic> _loadFixture(String name) => Map<String, dynamic>.from(
      jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map,
    );

ReadAloudSplitPlanV3 _planFixture(Map<String, dynamic> fixture) {
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
  return ReadAloudSplitterV3.plan(
    source: fixture['source'].toString(),
    document: document,
  );
}

String _cutView(List<String> segments) => segments.join(' | ');

void main() {
  test('baseline/target: E13 keeps door comma path', () {
    final plan = _planFixture(
      _loadFixture('read_aloud_splitter_v3_target_willows_e13.json'),
    );
    final view = _cutView(plan.originals.single.localPath.segments);
    expect(view.contains('door, | painted'), isTrue, reason: view);
    expect(view.contains('seemed | to'), isFalse, reason: view);
  });

  test('baseline/target: E17 must not cut bend about / about easily', () {
    final plan = _planFixture(
      _loadFixture('read_aloud_splitter_v3_target_alice_e17.json'),
    );
    final view = _cutView(plan.originals.single.localPath.segments);
    expect(view.contains('bend | about'), isFalse, reason: view);
    expect(view.contains('about | easily'), isFalse, reason: view);
    expect(view.contains('easily | in'), isFalse, reason: view);
    expect(view.contains('in | any'), isFalse, reason: view);
    expect(view.contains('find | that'), isFalse, reason: view);
    expect(view.contains('direction, |'), isTrue, reason: view);
  });

  test('baseline/target: E16 must not cut legs | up', () {
    final plan = _planFixture(
      _loadFixture('read_aloud_splitter_v3_target_willows_e16.json'),
    );
    final view = _cutView(plan.originals.single.localPath.segments);
    expect(view.contains('legs | up'), isFalse, reason: view);
    expect(view.contains('study | and'), isTrue, reason: view);
    expect(view.contains('face, |'), isTrue, reason: view);
    expect(view.contains('"busy" |'), isFalse, reason: view);
  });
}
