/// Replays a frozen V3 report through the current splitter without reparsing.
///
/// The report supplies only the historical source spans and dependency tokens;
/// its stored V3 sentence result is never passed to the production solver.
library;

import 'dart:convert';
import 'dart:io';

import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v3.dart';

Future<void> main(List<String> args) async {
  final reportPath = _argValue(args, '--report');
  final outputPath = _argValue(args, '--output');
  if (reportPath == null || outputPath == null) {
    throw ArgumentError('Required --report and --output paths');
  }
  final selectedEpisodes = (_argValue(args, '--episodes') ?? '')
      .split(',')
      .map((value) => value.trim().toUpperCase())
      .where((value) => value.isNotEmpty)
      .toSet();
  final includeCandidates = args.contains('--include-boundary-candidates');
  final includePaths = args.contains('--include-candidate-paths');
  final includeCandidateResult = args.contains('--candidate-output') ||
      args.contains('--experimental-additive');
  final includeDecisions = args.contains('--include-decisions') ||
      includeCandidates ||
      includePaths ||
      includeCandidateResult;
  final decoded = jsonDecode(
    await File(reportPath).readAsString(encoding: utf8),
  );
  if (decoded is! Map ||
      decoded['summary'] is! Map ||
      decoded['chapters'] is! List) {
    throw FormatException('Invalid frozen splitter report: $reportPath');
  }
  final summary = Map<String, dynamic>.from(decoded['summary'] as Map);
  final parserVersion = summary['parserVersion']?.toString() ?? '';
  final modelSha256 = summary['modelSha256']?.toString() ?? '';
  if (parserVersion.isEmpty || modelSha256.isEmpty) {
    throw const FormatException('Frozen report has no parser fingerprint');
  }

  final stopwatch = Stopwatch()..start();
  var sentenceFactBuilds = 0;
  var dagSolves = 0;
  final outputChapters = <Map<String, dynamic>>[];
  for (final rawChapter in decoded['chapters'] as List) {
    if (rawChapter is! Map) continue;
    final chapter = Map<String, dynamic>.from(rawChapter);
    final episode = chapter['episode']?.toString().toUpperCase() ?? '';
    if (episode.isEmpty ||
        selectedEpisodes.isNotEmpty && !selectedEpisodes.contains(episode)) {
      continue;
    }
    final source = _reconstructSource(chapter, episode: episode);
    final document = _dependencyDocument(
      chapter,
      episode: episode,
      source: source,
      parserVersion: parserVersion,
      modelSha256: modelSha256,
    );
    final chapterWatch = Stopwatch()..start();
    final plan = ReadAloudSplitterV3.plan(source: source, document: document);
    chapterWatch.stop();
    if (plan.counters.sentenceFactBuilds != plan.originals.length ||
        plan.counters.dagSolves != plan.originals.length) {
      throw StateError(
        '$episode violated one-fact/one-DAG invariant: '
        '${plan.counters.toJson()} for ${plan.originals.length} originals',
      );
    }
    sentenceFactBuilds += plan.counters.sentenceFactBuilds;
    dagSolves += plan.counters.dagSolves;
    outputChapters.add({
      'episode': episode,
      'source': source,
      'v3LocalSentences': plan.localSentences,
      if (includeCandidateResult) ...{
        // Historical field names are retained so existing comparison reports
        // can read the production candidate without a second solver.
        'v4AdditiveLocalSentences': plan.localSentences,
        'v4AdditiveElapsedMicroseconds': chapterWatch.elapsedMicroseconds,
      },
      'solverCounters': plan.counters.toJson(),
      if (includeDecisions)
        'originals': [
          for (final decision in plan.originals)
            {
              'originalIndex': decision.originalIndex,
              'original': decision.source,
              'localPathId': decision.localPathId,
              'segments': decision.localPath.segments,
              'wordCounts': decision.localPath.wordCounts,
              'score': decision.localPath.score,
              'boundaries': [
                for (final boundary in decision.localPath.boundaries)
                  boundary.toJson(),
              ],
              if (includeCandidateResult) ...{
                'v4AdditiveSegments': decision.localPath.segments,
                'v4AdditiveWordCounts': decision.localPath.wordCounts,
                'v4AdditiveScore': decision.localPath.score,
                'v4AdditiveBoundaries': [
                  for (final boundary in decision.localPath.boundaries)
                    boundary.toJson(),
                ],
              },
              if (includeCandidates)
                'boundaryCandidates': [
                  for (final boundary in decision.boundaryCandidates)
                    boundary.toJson(),
                ],
              if (includePaths)
                'candidatePaths': [
                  for (final path in decision.candidatePaths)
                    {
                      'segments': path.segments,
                      'wordCounts': path.wordCounts,
                      'afterWords': [
                        for (final boundary in path.boundaries)
                          boundary.afterWord,
                      ],
                      'score': path.score,
                    },
                ],
            },
        ],
      'elapsedMicroseconds': chapterWatch.elapsedMicroseconds,
    });
    stdout.writeln(
      '$episode ${plan.localSentences.length} sentences '
      '${chapterWatch.elapsedMilliseconds} ms',
    );
  }
  stopwatch.stop();
  final output = File(outputPath);
  await output.parent.create(recursive: true);
  await output.writeAsString(
    '${jsonEncode({
          'schemaVersion': 'read_aloud_replay_v1',
          'summary': {
            'solverVersion': ReadAloudSplitterV3.solverVersion,
            'parserVersion': parserVersion,
            'modelSha256': modelSha256,
            'chapterCount': outputChapters.length,
            'elapsedMicroseconds': stopwatch.elapsedMicroseconds,
            'sentenceFactBuilds': sentenceFactBuilds,
            'dagSolves': dagSolves,
          },
          'chapters': outputChapters,
        })}\n',
    encoding: utf8,
    flush: true,
  );
  stdout.writeln(
    'Replay report: ${output.absolute.path} '
    '(${stopwatch.elapsedMilliseconds} ms)',
  );
}

String _reconstructSource(
  Map<String, dynamic> chapter, {
  required String episode,
}) {
  final originals = chapter['originals'];
  final parserSentences = chapter['parserSentences'];
  if (originals is! List || parserSentences is! List) {
    throw FormatException('$episode has no replayable source spans');
  }
  var sourceLength = 0;
  for (final collection in [originals, parserSentences]) {
    for (final raw in collection) {
      if (raw is! Map) continue;
      final endKey = collection == originals ? 'sourceEnd' : 'end';
      final end = raw[endKey];
      if (end is int && end > sourceLength) sourceLength = end;
    }
  }
  if (sourceLength <= 0) {
    throw FormatException('$episode has an empty replay source');
  }
  final units = List<int>.filled(sourceLength, -1);

  void place(String text, int start, int end, String label) {
    final textUnits = text.codeUnits;
    if (start < 0 || end != start + textUnits.length || end > units.length) {
      throw FormatException('$episode invalid $label span $start..$end');
    }
    for (var index = 0; index < textUnits.length; index += 1) {
      final target = start + index;
      final existing = units[target];
      if (existing >= 0 && existing != textUnits[index]) {
        throw FormatException('$episode conflicting $label text at $target');
      }
      units[target] = textUnits[index];
    }
  }

  for (final raw in originals) {
    if (raw is! Map) continue;
    place(
      raw['original']?.toString() ?? '',
      raw['sourceStart'] as int,
      raw['sourceEnd'] as int,
      'original',
    );
  }
  for (final raw in parserSentences) {
    if (raw is! Map) continue;
    place(
      raw['text']?.toString() ?? '',
      raw['start'] as int,
      raw['end'] as int,
      'parser sentence',
    );
  }
  return String.fromCharCodes(
    units.map((value) => value < 0 ? 0x20 : value),
  );
}

DependencyDocumentV3 _dependencyDocument(
  Map<String, dynamic> chapter, {
  required String episode,
  required String source,
  required String parserVersion,
  required String modelSha256,
}) {
  final rawSentences = chapter['parserSentences'];
  if (rawSentences is! List) {
    throw FormatException('$episode has no parser sentences');
  }
  final sentences = <DependencySentenceV3>[];
  for (final raw in rawSentences) {
    if (raw is! Map || raw['tokens'] is! List) {
      throw FormatException('$episode has an invalid parser sentence');
    }
    final sentence = Map<String, dynamic>.from(raw);
    final start = sentence['start'] as int;
    final end = sentence['end'] as int;
    final expected = sentence['text']?.toString() ?? '';
    if (start < 0 ||
        end > source.length ||
        source.substring(start, end) != expected) {
      throw FormatException(
          '$episode parser sentence mismatch at $start..$end');
    }
    sentences.add(
      DependencySentenceV3(
        start: start,
        end: end,
        parseCost: (sentence['parseCost'] as num?)?.toDouble(),
        parseCostPerToken: (sentence['parseCostPerToken'] as num?)?.toDouble(),
        tokens: [
          for (final rawToken in sentence['tokens'] as List)
            if (rawToken is Map)
              DependencyTokenV3(
                id: rawToken['id'] as int,
                text: rawToken['text'].toString(),
                sourceText: rawToken['sourceText']?.toString(),
                start: rawToken['start'] as int,
                end: rawToken['end'] as int,
                upos: rawToken['upos'].toString(),
                head: rawToken['head'] as int,
                deprel: rawToken['deprel'].toString(),
              ),
        ],
      ),
    );
  }
  return DependencyDocumentV3(
    parserVersion: parserVersion,
    modelSha256: modelSha256,
    sentences: List.unmodifiable(sentences),
    healthy: chapter['parserHealthy'] != false,
  );
}

String? _argValue(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}
