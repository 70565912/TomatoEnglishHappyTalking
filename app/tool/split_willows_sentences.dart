/// Read-only Willows corpus evaluator for the canonical native/Dart V3
/// sentence splitter.
///
/// Run from app/ after the project model has passed its independent test:
///   dart run tool/split_willows_sentences.dart --work "F:/柳林风声/work"
///
/// Re-score a previously parsed corpus without running UDPipe again:
///   dart run tool/split_willows_sentences.dart \
///     --work "F:/柳林风声/work" \
///     --parsed-report "../output/sentence-split-v3/previous/willows-v3-report.json"
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
  final sourceFromSentences = args.contains('--source-from-sentences');
  final sourceBundlePath = _argValue(args, '--source-bundle');
  final sourceBundle = sourceBundlePath == null
      ? const <String, Map<String, dynamic>>{}
      : await _readSourceBundle(File(sourceBundlePath));
  final parsedReportPath = _argValue(args, '--parsed-report');
  final selectedEpisode = _argValue(args, '--episode')?.toUpperCase();
  final selectedEpisodes = (_argValue(args, '--episodes') ?? '')
      .split(',')
      .map((value) => value.trim().toUpperCase())
      .where((value) => value.isNotEmpty)
      .toSet();
  if (parsedReportPath == null && !probe.existsSync()) {
    throw ArgumentError('UDPipe probe does not exist: ${probe.path}');
  }
  if (parsedReportPath == null && !model.existsSync()) {
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
            (selectedEpisode == null && selectedEpisodes.isEmpty) ||
            _basename(directory.path).toUpperCase() == selectedEpisode ||
            selectedEpisodes.contains(_basename(directory.path).toUpperCase()),
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
    final bundled = sourceBundle[episode];
    final oldSentences = bundled == null
        ? await _readOldSentences(directory)
        : (bundled['sentences'] as List)
            .map((value) => value.toString())
            .toList(growable: false);
    if (bundled == null && !sourceFromSentences && !input.existsSync()) {
      throw FormatException('$episode missing $inputName');
    }
    if ((sourceFromSentences || bundled != null) && oldSentences.isEmpty) {
      throw FormatException('$episode has no persisted sentences source');
    }
    final content = bundled != null
        ? bundled['source'].toString()
        : sourceFromSentences
            ? oldSentences.join(' ')
            : _stripLeadingHeadingParagraph(
                PracticeInputParser.parse(
                  await input.readAsString(encoding: utf8),
                ).englishContent,
              );
    if (content.isEmpty) {
      throw FormatException('$episode has no normalized English body');
    }
    if (combined.isNotEmpty) combined.write('\n\n');
    final start = combined.length;
    combined.write(content);
    chapters.add(
      _ChapterSourceV3(
        episode: episode,
        sourcePath: bundled != null
            ? File(sourceBundlePath!).absolute.path
            : sourceFromSentences
                ? '${directory.path}/sentences.json'
                : input.path,
        source: content,
        start: start,
        end: combined.length,
        oldSentences: oldSentences,
      ),
    );
  }

  final source = combined.toString();
  final sourceDigest = await Sha256().hash(utf8.encode(source));
  final sourceSha = _hex(sourceDigest.bytes);
  if (args.contains('--fingerprint-only')) {
    stdout.writeln(
      jsonEncode({
        'chapterCount': chapters.length,
        'combinedSourceSha256': sourceSha,
        'sourceCharacterCount': source.length,
      }),
    );
    return;
  }
  var modelSha = '';
  var parserVersion = UdpipeRawPipelineV3.parserVersion;
  String? reusedParsedReport;
  var nativeCalls = 0;
  DependencyDocumentV3 document;
  Directory? temp;
  try {
    if (parsedReportPath != null) {
      final parsed = await _loadParsedDocumentFromReport(
        reportFile: File(parsedReportPath),
        chapters: chapters,
        sourceSha256: sourceSha,
        requireCombinedSourceFingerprint:
            selectedEpisode == null && selectedEpisodes.isEmpty,
      );
      document = parsed.document;
      modelSha = document.modelSha256;
      parserVersion = document.parserVersion;
      reusedParsedReport = File(parsedReportPath).absolute.path;
    } else {
      final modelDigest = await Sha256().hash(await model.readAsBytes());
      modelSha = _hex(modelDigest.bytes);
      temp = await Directory.systemTemp.createTemp('willows-v3-corpus-');
      final pipeline = await UdpipeRawPipelineV3.parse(
        source: source,
        parserVersion: parserVersion,
        modelSha256: modelSha,
        provider: ({required text, required presegmented}) async {
          nativeCalls += 1;
          final input = File('${temp!.path}/parse-$nativeCalls.txt');
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
      document = pipeline.document;
    }
    final chapterReports = <Map<String, dynamic>>[];
    for (final chapter in chapters) {
      final chapterDocument = _sliceDocumentForChapter(document, chapter);
      final plan = ReadAloudSplitterV3.plan(
        source: chapter.source,
        document: chapterDocument,
      );
      final report = _chapterReport(
        chapter,
        plan.originals,
        chapterDocument.sentences,
        offsetsAreLocal: true,
      );
      chapterReports.add(report);
      await _writeChapterMarkdown(outputDirectory, report);
    }
    final summary = _summary(
      chapterReports,
      sourceSha: sourceSha,
      modelSha: modelSha,
      parserVersion: parserVersion,
      nativeCalls: nativeCalls,
      reusedParsedReport: reusedParsedReport,
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
    if (temp != null) await temp.delete(recursive: true);
  }
}

Future<_ParsedReportDocumentV3> _loadParsedDocumentFromReport({
  required File reportFile,
  required List<_ChapterSourceV3> chapters,
  required String sourceSha256,
  required bool requireCombinedSourceFingerprint,
}) async {
  if (!reportFile.existsSync()) {
    throw ArgumentError('Parsed report does not exist: ${reportFile.path}');
  }
  final decoded = jsonDecode(await reportFile.readAsString(encoding: utf8));
  if (decoded is! Map ||
      decoded['summary'] is! Map ||
      decoded['chapters'] is! List) {
    throw FormatException(
        'Parsed report schema is invalid: ${reportFile.path}');
  }
  final summary = Map<String, dynamic>.from(decoded['summary'] as Map);
  final reportSourceSha = summary['combinedSourceSha256']?.toString() ?? '';
  if (requireCombinedSourceFingerprint && reportSourceSha != sourceSha256) {
    throw FormatException(
      'Parsed report source fingerprint does not match current corpus: '
      'report=$reportSourceSha current=$sourceSha256',
    );
  }
  final parserVersion = summary['parserVersion']?.toString() ?? '';
  final modelSha256 = summary['modelSha256']?.toString() ?? '';
  if (parserVersion.isEmpty || modelSha256.isEmpty) {
    throw const FormatException(
        'Parsed report has no parser/model fingerprint');
  }
  final reportChapters = <String, Map<String, dynamic>>{
    for (final value in decoded['chapters'] as List)
      if (value is Map && value['episode'] != null)
        value['episode'].toString().toUpperCase():
            Map<String, dynamic>.from(value),
  };
  final sentences = <DependencySentenceV3>[];
  for (final chapter in chapters) {
    final report = reportChapters[chapter.episode];
    if (report == null || report['parserSentences'] is! List) {
      throw FormatException(
        'Parsed report has no parser sentences for ${chapter.episode}',
      );
    }
    for (final value in report['parserSentences'] as List) {
      if (value is! Map || value['tokens'] is! List) {
        throw FormatException(
          'Parsed report sentence is invalid for ${chapter.episode}',
        );
      }
      final sentence = Map<String, dynamic>.from(value);
      final localStart = sentence['start'] as int;
      final localEnd = sentence['end'] as int;
      if (localStart < 0 ||
          localEnd <= localStart ||
          localEnd > chapter.source.length) {
        throw FormatException(
          'Parsed report span is invalid for ${chapter.episode}: '
          '$localStart..$localEnd',
        );
      }
      final expectedText = sentence['text']?.toString() ?? '';
      final actualText = chapter.source.substring(localStart, localEnd);
      if (expectedText != actualText) {
        throw FormatException(
          'Parsed report text does not match ${chapter.episode} at '
          '$localStart..$localEnd',
        );
      }
      sentences.add(
        DependencySentenceV3(
          start: chapter.start + localStart,
          end: chapter.start + localEnd,
          parseCost: (sentence['parseCost'] as num?)?.toDouble(),
          parseCostPerToken:
              (sentence['parseCostPerToken'] as num?)?.toDouble(),
          tokens: [
            for (final tokenValue in sentence['tokens'] as List)
              if (tokenValue is Map)
                DependencyTokenV3(
                  id: tokenValue['id'] as int,
                  text: tokenValue['text'].toString(),
                  sourceText: tokenValue['sourceText']?.toString(),
                  start: chapter.start + (tokenValue['start'] as int),
                  end: chapter.start + (tokenValue['end'] as int),
                  upos: tokenValue['upos'].toString(),
                  head: tokenValue['head'] as int,
                  deprel: tokenValue['deprel'].toString(),
                ),
          ],
        ),
      );
    }
  }
  if (sentences.isEmpty) {
    throw const FormatException('Parsed report contains no parser sentences');
  }
  final document = DependencyDocumentV3(
    parserVersion: parserVersion,
    modelSha256: modelSha256,
    sentences: List.unmodifiable(sentences),
    healthy: true,
  );
  return _ParsedReportDocumentV3(document);
}

DependencyDocumentV3 _sliceDocumentForChapter(
  DependencyDocumentV3 document,
  _ChapterSourceV3 chapter,
) {
  final sentences = <DependencySentenceV3>[];
  for (final sentence in document.sentences) {
    if (sentence.start < chapter.start || sentence.end > chapter.end) continue;
    sentences.add(
      DependencySentenceV3(
        start: sentence.start - chapter.start,
        end: sentence.end - chapter.start,
        parseCost: sentence.parseCost,
        parseCostPerToken: sentence.parseCostPerToken,
        tokens: [
          for (final token in sentence.tokens)
            DependencyTokenV3(
              id: token.id,
              text: token.text,
              sourceText: token.sourceText,
              start: token.start - chapter.start,
              end: token.end - chapter.start,
              upos: token.upos,
              head: token.head,
              deprel: token.deprel,
            ),
        ],
      ),
    );
  }
  if (sentences.isEmpty) {
    throw FormatException('${chapter.episode} contains no parser sentences');
  }
  return DependencyDocumentV3(
    parserVersion: document.parserVersion,
    modelSha256: document.modelSha256,
    sentences: List.unmodifiable(sentences),
    healthy: document.healthy,
    issues: document.issues,
  );
}

Map<String, dynamic> _chapterReport(
    _ChapterSourceV3 chapter,
    List<ReadAloudOriginalDecisionV3> decisions,
    List<DependencySentenceV3> parserSentences,
    {bool offsetsAreLocal = false}) {
  final localSentences = ReadAloudSplitterV3.mergeOneWordChunks(
    decisions
        .expand((decision) => decision.localPath.segments)
        .toList(growable: false),
  );
  // Build a minimal plan-shaped offset check via surviving originals ∩ merged.
  final required = <int>[];
  var words = 0;
  for (final decision in decisions) {
    words += ReadAloudSplitterV3.wordCount(decision.source);
    required.add(words);
  }
  final actual = <int>{};
  var cumulative = 0;
  for (final sentence in localSentences) {
    cumulative += ReadAloudSplitterV3.wordCount(sentence);
    actual.add(cumulative);
  }
  ReadAloudSplitterV3.validateReviewedSentences(
    chapter.source,
    localSentences,
    rejectOneWordChunks: true,
    requiredBoundaryWordOffsets: [
      for (final offset in required)
        if (actual.contains(offset)) offset,
    ],
  );
  var over16Unpunctuated = 0;
  var newUnder8Fragments = 0;
  var nonPunctuationCuts = 0;
  var emergencyCuts = 0;
  var shortQuoteInternalCandidateCount = 0;
  var shortQuoteInternalSelectedCount = 0;
  var insideQuotedSpeechCutCount = 0;
  var quoteEdgeCutCount = 0;
  for (final decision in decisions) {
    final path = decision.localPath;
    shortQuoteInternalCandidateCount += decision.boundaryCandidates
        .where(
          (candidate) =>
              candidate.insideQuotedSpeech &&
              (candidate.quoteSpanWordCount ?? 1000000) <=
                  ReadAloudSplitterV3.preferredMaxUnpunctuatedWords,
        )
        .length;
    shortQuoteInternalSelectedCount += path.boundaries
        .where(
          (candidate) =>
              candidate.insideQuotedSpeech &&
              (candidate.quoteSpanWordCount ?? 1000000) <=
                  ReadAloudSplitterV3.preferredMaxUnpunctuatedWords,
        )
        .length;
    insideQuotedSpeechCutCount += path.boundaries
        .where((candidate) => candidate.insideQuotedSpeech)
        .length;
    quoteEdgeCutCount += path.boundaries
        .where((candidate) => candidate.quoteEdge != null)
        .length;
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
    'shortQuoteInternalCandidateCount': shortQuoteInternalCandidateCount,
    'shortQuoteInternalSelectedCount': shortQuoteInternalSelectedCount,
    'insideQuotedSpeechCutCount': insideQuotedSpeechCutCount,
    'quoteEdgeCutCount': quoteEdgeCutCount,
    'oldSentences': chapter.oldSentences,
    'v3LocalSentences': localSentences,
    'parserSentences': [
      for (final sentence in parserSentences)
        {
          'start':
              offsetsAreLocal ? sentence.start : sentence.start - chapter.start,
          'end': offsetsAreLocal ? sentence.end : sentence.end - chapter.start,
          'text': chapter.source.substring(
            offsetsAreLocal ? sentence.start : sentence.start - chapter.start,
            offsetsAreLocal ? sentence.end : sentence.end - chapter.start,
          ),
          'parseCost': sentence.parseCost,
          'parseCostPerToken': sentence.parseCostPerToken,
          'tokens': [
            for (final token in sentence.tokens)
              {
                'id': token.id,
                'text': token.text,
                'sourceText': token.sourceText,
                'start':
                    offsetsAreLocal ? token.start : token.start - chapter.start,
                'end': offsetsAreLocal ? token.end : token.end - chapter.start,
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
          'sourceStart': offsetsAreLocal
              ? decision.sourceStart
              : decision.sourceStart - chapter.start,
          'sourceEnd': offsetsAreLocal
              ? decision.sourceEnd
              : decision.sourceEnd - chapter.start,
          'parserHealthy': decision.parserHealthy,
          'parserIssues': decision.parserIssues,
          'parseCost': decision.parseCost,
          'parseCostPerToken': decision.parseCostPerToken,
          'localPathId': decision.localPathId,
          'requiresAiReview': decision.requiresAiReview,
          'boundaryCandidates': decision.boundaryCandidates
              .map((candidate) => candidate.toJson())
              .toList(growable: false),
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
  String? reusedParsedReport,
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
    if (reusedParsedReport != null) 'reusedParsedReport': reusedParsedReport,
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
    'shortQuoteInternalCandidateCount': sum('shortQuoteInternalCandidateCount'),
    'shortQuoteInternalSelectedCount': sum('shortQuoteInternalSelectedCount'),
    'insideQuotedSpeechCutCount': sum('insideQuotedSpeechCutCount'),
    'quoteEdgeCutCount': sum('quoteEdgeCutCount'),
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
- Short-quote internal candidates: ${summary['shortQuoteInternalCandidateCount']}
- Short-quote internal selected cuts: ${summary['shortQuoteInternalSelectedCount']}
- Selected quote-internal cuts: ${summary['insideQuotedSpeechCutCount']}
- Selected quote-edge cuts: ${summary['quoteEdgeCutCount']}

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

Future<Map<String, Map<String, dynamic>>> _readSourceBundle(File file) async {
  if (!file.existsSync()) {
    throw ArgumentError('Source bundle does not exist: ${file.path}');
  }
  final decoded = jsonDecode(await file.readAsString(encoding: utf8));
  if (decoded is! Map || decoded['chapters'] is! List) {
    throw FormatException('Source bundle schema is invalid: ${file.path}');
  }
  final output = <String, Map<String, dynamic>>{};
  for (final value in decoded['chapters'] as List) {
    if (value is! Map ||
        value['episode'] == null ||
        value['sentences'] is! List) {
      throw FormatException('Source bundle chapter is invalid: ${file.path}');
    }
    final chapter = Map<String, dynamic>.from(value);
    final episode = chapter['episode'].toString().toUpperCase();
    final sentences = (chapter['sentences'] as List)
        .map((item) => item.toString())
        .toList(growable: false);
    final source = chapter['source']?.toString() ?? '';
    if (sentences.isEmpty ||
        source.isEmpty ||
        !ReadAloudSplitterV3.isRoundTripEquivalent(
          englishContent: source,
          sentences: sentences,
        )) {
      throw FormatException('$episode source bundle does not round-trip');
    }
    if (output.putIfAbsent(episode, () => chapter) != chapter) {
      throw FormatException('Duplicate source bundle episode: $episode');
    }
  }
  return Map.unmodifiable(output);
}

String _stripLeadingHeadingParagraph(String content) {
  final paragraphs = content
      .trim()
      .split(RegExp(r'\n\s*\n+'))
      .where((paragraph) => paragraph.trim().isNotEmpty)
      .toList(growable: false);
  if (paragraphs.length > 1 &&
      RegExp(
        r'^(chapter|episode|part|book)\b[^\r\n]*$',
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

class _ParsedReportDocumentV3 {
  const _ParsedReportDocumentV3(this.document);

  final DependencyDocumentV3 document;
}
