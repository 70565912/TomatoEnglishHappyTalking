/// Read-only Willows corpus evaluator for the canonical native/Dart V3
/// sentence splitter.
///
/// Run from app/ after the project model has passed its independent test:
///   dart run tool/split_willows_sentences.dart --work "F:/柳林风声/work"
///
/// This tool never writes the source corpus, App database, TTS, subtitles,
/// videos, or NAS. It emits only review reports under --output.
library;

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:tomato_english_happy_talking/services/practice_input_parser.dart';
import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v3.dart';
import 'package:tomato_english_happy_talking/services/udpipe_raw_pipeline_v3.dart';

Future<void> main(List<String> args) async {
  final work = Directory(
    _argValue(args, '--work') ??
        (throw ArgumentError('Required --work path to 柳林风声/work')),
  );
  if (!work.existsSync()) {
    throw ArgumentError('Willows work directory does not exist: ${work.path}');
  }
  final repository = Directory.current.parent;
  final outputDirectory = Directory(
    _argValue(args, '--output') ??
        '${repository.path}/output/sentence-split-v3/willows-corpus',
  );
  final probe = File(
    _argValue(args, '--probe') ??
        '${repository.path}/build/udpipe-v3-trainer/udpipe_v3_probe.exe',
  );
  final model = File(
    _argValue(args, '--model') ??
        '${repository.path}/app/assets/models/'
            'english-ewt-r2.18-udpipe-v1.4.0.model',
  );
  final inputName = _argValue(args, '--input-name') ?? 'english.txt';
  final selectedEpisode = _argValue(args, '--episode')?.toUpperCase();
  if (!probe.existsSync()) {
    throw ArgumentError('UDPipe probe does not exist: ${probe.path}');
  }
  if (!model.existsSync()) {
    throw ArgumentError('UDPipe model does not exist: ${model.path}');
  }

  final chapterDirectories = work
      .listSync()
      .whereType<Directory>()
      .where(
        (directory) => RegExp(r'^E\d{2}$')
            .hasMatch(_basename(directory.path).toUpperCase()),
      )
      .where(
        (directory) =>
            selectedEpisode == null ||
            _basename(directory.path).toUpperCase() == selectedEpisode,
      )
      .toList(growable: false)
    ..sort((left, right) => left.path.compareTo(right.path));
  if (chapterDirectories.isEmpty) {
    throw ArgumentError(
        'No E01-style chapter directories found in ${work.path}');
  }

  final chapters = <_ChapterSourceV3>[];
  final combined = StringBuffer();
  for (final directory in chapterDirectories) {
    final episode = _basename(directory.path).toUpperCase();
    final input = File('${directory.path}/$inputName');
    if (!input.existsSync()) {
      throw FormatException('$episode missing $inputName');
    }
    final parsed = PracticeInputParser.parse(
      await input.readAsString(encoding: utf8),
    );
    final content = _stripLeadingHeadingParagraph(parsed.englishContent);
    if (content.isEmpty) {
      throw FormatException('$episode has no normalized English body');
    }
    if (combined.isNotEmpty) combined.write('\n\n');
    final start = combined.length;
    combined.write(content);
    final oldSentences = await _readOldSentences(directory);
    chapters.add(
      _ChapterSourceV3(
        episode: episode,
        sourcePath: input.path,
        source: content,
        start: start,
        end: combined.length,
        oldSentences: oldSentences,
      ),
    );
  }

  final source = combined.toString();
  final modelDigest = await Sha256().hash(await model.readAsBytes());
  final modelSha = _hex(modelDigest.bytes);
  final sourceDigest = await Sha256().hash(utf8.encode(source));
  final sourceSha = _hex(sourceDigest.bytes);
  final temp = await Directory.systemTemp.createTemp('willows-v3-corpus-');
  var nativeCalls = 0;
  try {
    final pipeline = await UdpipeRawPipelineV3.parse(
      source: source,
      parserVersion: UdpipeRawPipelineV3.parserVersion,
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
    final document = pipeline.document;
    final plan = ReadAloudSplitterV3.plan(
      source: source,
      document: document,
    );
    final chapterReports = <Map<String, dynamic>>[];
    for (final chapter in chapters) {
      final decisions = plan.originals
          .where(
            (decision) =>
                decision.sourceStart >= chapter.start &&
                decision.sourceEnd <= chapter.end,
          )
          .toList(growable: false);
      final parserSentences = document.sentences
          .where(
            (sentence) =>
                sentence.start >= chapter.start && sentence.end <= chapter.end,
          )
          .toList(growable: false);
      final report = _chapterReport(chapter, decisions, parserSentences);
      chapterReports.add(report);
      await _writeChapterMarkdown(outputDirectory, report);
    }
    final summary = _summary(
      chapterReports,
      sourceSha: sourceSha,
      modelSha: modelSha,
      parserVersion: document.parserVersion,
      nativeCalls: nativeCalls,
    );
    await outputDirectory.create(recursive: true);
    final reportFile = File('${outputDirectory.path}/willows-v3-report.json');
    await reportFile.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({
            'schemaVersion': 'willows_sentence_split_corpus_v3_1',
            'summary': summary,
            'chapters': chapterReports,
          })}\n',
      encoding: utf8,
      flush: true,
    );
    final summaryFile = File('${outputDirectory.path}/README.md');
    await summaryFile.writeAsString(
      _summaryMarkdown(summary),
      encoding: utf8,
      flush: true,
    );
    stdout.writeln('V3 Willows report: ${reportFile.absolute.path}');
    stdout.writeln('V3 Willows summary: ${summaryFile.absolute.path}');
  } finally {
    await temp.delete(recursive: true);
  }
}

Map<String, dynamic> _chapterReport(
  _ChapterSourceV3 chapter,
  List<ReadAloudOriginalDecisionV3> decisions,
  List<DependencySentenceV3> parserSentences,
) {
  final localSentences = decisions
      .expand((decision) => decision.localPath.segments)
      .toList(growable: false);
  ReadAloudSplitterV3.validateReviewedSentences(
    chapter.source,
    localSentences,
    requiredBoundaryWordOffsets: _requiredOffsets(decisions),
  );
  var over16Unpunctuated = 0;
  var newUnder8Fragments = 0;
  var nonPunctuationCuts = 0;
  var emergencyCuts = 0;
  for (final decision in decisions) {
    final path = decision.localPath;
    for (final segment in path.segments) {
      if (ReadAloudSplitterV3.maxUnpunctuatedWordCount(segment) > 16) {
        over16Unpunctuated += 1;
      }
    }
    if (path.boundaries.isNotEmpty) {
      newUnder8Fragments += path.wordCounts.where((count) => count < 8).length;
    }
    nonPunctuationCuts +=
        path.boundaries.where((boundary) => !boundary.isPunctuation).length;
    emergencyCuts +=
        path.boundaries.where((boundary) => boundary.isEmergency).length;
  }
  return {
    'episode': chapter.episode,
    'sourcePath': chapter.sourcePath,
    'sourceWordCount': ReadAloudSplitterV3.wordCount(chapter.source),
    'oldSentenceCount': chapter.oldSentences.length,
    'v3OriginalSentenceCount': decisions.length,
    'v3SentenceCount': localSentences.length,
    'v2V3Different': !_sameNormalized(chapter.oldSentences, localSentences),
    'parserHealthy': decisions.every((decision) => decision.parserHealthy),
    'aiReviewOriginalCount':
        decisions.where((decision) => decision.requiresAiReview).length,
    'emergencyOriginalCount':
        decisions.where((decision) => decision.localPath.isEmergency).length,
    'over16UnpunctuatedSegmentCount': over16Unpunctuated,
    'newUnder8FragmentCount': newUnder8Fragments,
    'nonPunctuationCutCount': nonPunctuationCuts,
    'emergencyCutCount': emergencyCuts,
    'oldSentences': chapter.oldSentences,
    'v3LocalSentences': localSentences,
    'parserSentences': [
      for (final sentence in parserSentences)
        {
          'start': sentence.start - chapter.start,
          'end': sentence.end - chapter.start,
          'text': chapter.source.substring(
            sentence.start - chapter.start,
            sentence.end - chapter.start,
          ),
          'parseCost': sentence.parseCost,
          'parseCostPerToken': sentence.parseCostPerToken,
          'tokens': [
            for (final token in sentence.tokens)
              {
                'id': token.id,
                'text': token.text,
                'sourceText': token.sourceText,
                'start': token.start - chapter.start,
                'end': token.end - chapter.start,
                'upos': token.upos,
                'head': token.head,
                'deprel': token.deprel,
              },
          ],
        },
    ],
    'originals': [
      for (final decision in decisions)
        {
          'originalIndex': decision.originalIndex,
          'original': decision.source,
          'sourceStart': decision.sourceStart - chapter.start,
          'sourceEnd': decision.sourceEnd - chapter.start,
          'parserHealthy': decision.parserHealthy,
          'parserIssues': decision.parserIssues,
          'parseCost': decision.parseCost,
          'parseCostPerToken': decision.parseCostPerToken,
          'localPathId': decision.localPathId,
          'requiresAiReview': decision.requiresAiReview,
          'candidatePaths': decision.candidatePaths
              .map((path) => path.toJson())
              .toList(growable: false),
        },
    ],
  };
}

Map<String, dynamic> _summary(
  List<Map<String, dynamic>> chapters, {
  required String sourceSha,
  required String modelSha,
  required String parserVersion,
  required int nativeCalls,
}) {
  int sum(String key) => chapters.fold<int>(
        0,
        (total, chapter) => total + (chapter[key] as int),
      );
  return {
    'sentenceSplitVersion': ReadAloudSplitterV3.version,
    'reviewedVersion': ReadAloudSplitterV3.reviewedVersion,
    'solverVersion': ReadAloudSplitterV3.solverVersion,
    'parserVersion': parserVersion,
    'modelSha256': modelSha,
    'combinedSourceSha256': sourceSha,
    'nativeCalls': nativeCalls,
    'chapterCount': chapters.length,
    'v2V3DifferentChapterCount':
        chapters.where((chapter) => chapter['v2V3Different'] == true).length,
    'parserHealthyChapterCount':
        chapters.where((chapter) => chapter['parserHealthy'] == true).length,
    'sourceWordCount': sum('sourceWordCount'),
    'oldSentenceCount': sum('oldSentenceCount'),
    'v3OriginalSentenceCount': sum('v3OriginalSentenceCount'),
    'v3SentenceCount': sum('v3SentenceCount'),
    'aiReviewOriginalCount': sum('aiReviewOriginalCount'),
    'emergencyOriginalCount': sum('emergencyOriginalCount'),
    'over16UnpunctuatedSegmentCount': sum('over16UnpunctuatedSegmentCount'),
    'newUnder8FragmentCount': sum('newUnder8FragmentCount'),
    'nonPunctuationCutCount': sum('nonPunctuationCutCount'),
    'emergencyCutCount': sum('emergencyCutCount'),
  };
}

Future<void> _writeChapterMarkdown(
  Directory outputDirectory,
  Map<String, dynamic> report,
) async {
  await outputDirectory.create(recursive: true);
  final episode = report['episode'] as String;
  final buffer = StringBuffer()
    ..writeln('# $episode V3 sentence review')
    ..writeln()
    ..writeln('- Original orthographic sentences: '
        '${report['v3OriginalSentenceCount']}')
    ..writeln('- Local V3 sentences: ${report['v3SentenceCount']}')
    ..writeln('- AI-review originals: ${report['aiReviewOriginalCount']}')
    ..writeln('- Emergency originals: ${report['emergencyOriginalCount']}')
    ..writeln('- New fragments below 8 words: '
        '${report['newUnder8FragmentCount']}')
    ..writeln('- Unpunctuated segments above 16 words: '
        '${report['over16UnpunctuatedSegmentCount']}')
    ..writeln()
    ..writeln('| Original | Local path | Words | Stage | AI | Reasons |')
    ..writeln('|---|---|---:|---|---|---|');
  for (final value in report['originals'] as List) {
    final original = Map<String, dynamic>.from(value as Map);
    final paths = original['candidatePaths'] as List;
    final local = Map<String, dynamic>.from(
      paths.firstWhere(
        (path) => (path as Map)['pathId'] == original['localPathId'],
      ) as Map,
    );
    final reasons = (local['boundaries'] as List)
        .expand(
          (boundary) => (boundary as Map)['reasons'] as List,
        )
        .join('; ');
    buffer
      ..write('| ${_markdownCell(original['original'].toString())} ')
      ..write('| ${_markdownCell((local['segments'] as List).join(' / '))} ')
      ..write('| ${(local['wordCounts'] as List).join('/')} ')
      ..write('| ${local['stage']} ')
      ..write('| ${original['requiresAiReview'] == true ? 'yes' : 'no'} ')
      ..writeln('| ${_markdownCell(reasons)} |');
  }
  await File('${outputDirectory.path}/$episode.md').writeAsString(
    buffer.toString(),
    encoding: utf8,
    flush: true,
  );
}

String _summaryMarkdown(Map<String, dynamic> summary) => '''
# Willows V3 local corpus report

- Chapters: ${summary['chapterCount']}
- Parser/model: ${summary['parserVersion']} / `${summary['modelSha256']}`
- V2/V3 different chapters: ${summary['v2V3DifferentChapterCount']}
- Original orthographic sentences: ${summary['v3OriginalSentenceCount']}
- Local V3 sentences: ${summary['v3SentenceCount']}
- AI-review originals: ${summary['aiReviewOriginalCount']}
- Emergency originals: ${summary['emergencyOriginalCount']}
- New fragments below 8 words: ${summary['newUnder8FragmentCount']}
- Unpunctuated segments above 16 words: ${summary['over16UnpunctuatedSegmentCount']}
- Non-punctuation cuts: ${summary['nonPunctuationCutCount']}
- Emergency cuts: ${summary['emergencyCutCount']}

This report is read-only. It does not authorize database, TTS, subtitle,
video, picture mapping, or NAS migration.
''';

Future<List<String>> _readOldSentences(Directory chapter) async {
  final file = File('${chapter.path}/sentences.json');
  if (!file.existsSync()) return const [];
  final decoded = jsonDecode(await file.readAsString(encoding: utf8));
  if (decoded is! Map || decoded['sentences'] is! List) return const [];
  return (decoded['sentences'] as List)
      .whereType<Map>()
      .map((entry) => entry['text']?.toString().trim() ?? '')
      .where((text) => text.isNotEmpty)
      .toList(growable: false);
}

List<int> _requiredOffsets(List<ReadAloudOriginalDecisionV3> decisions) {
  var words = 0;
  return [
    for (final decision in decisions)
      words += ReadAloudSplitterV3.wordCount(decision.source),
  ];
}

String _stripLeadingHeadingParagraph(String content) {
  final paragraphs = content
      .trim()
      .split(RegExp(r'\n\s*\n+'))
      .where((paragraph) => paragraph.trim().isNotEmpty)
      .toList(growable: false);
  if (paragraphs.length > 1 &&
      RegExp(
        r'^(chapter|episode|part|book)\b[^.!?]*$',
        caseSensitive: false,
      ).hasMatch(paragraphs.first.trim())) {
    return paragraphs.skip(1).join('\n\n').trim();
  }
  return content.trim();
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

String _markdownCell(String value) =>
    value.replaceAll('|', r'\|').replaceAll(RegExp(r'\s+'), ' ').trim();

String _hex(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

String _basename(String path) => path.replaceAll('\\', '/').split('/').last;

String? _argValue(List<String> args, String name) {
  final index = args.indexOf(name);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
}

class _ChapterSourceV3 {
  const _ChapterSourceV3({
    required this.episode,
    required this.sourcePath,
    required this.source,
    required this.start,
    required this.end,
    required this.oldSentences,
  });

  final String episode;
  final String sourcePath;
  final String source;
  final int start;
  final int end;
  final List<String> oldSentences;
}
