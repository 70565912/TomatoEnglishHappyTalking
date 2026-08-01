/// Split Willows chapter english.txt into Tomato read-aloud chunks via NlpService.
///
/// Run from app/:
///   dart run tool/split_willows_sentences.dart --work "F:/柳林风声/work"
library;

import 'dart:convert';
import 'dart:io';

import 'package:tomato_english_happy_talking/services/nlp_service.dart';

void main(List<String> args) {
  final work = _argValue(args, '--work') ??
      (throw ArgumentError('Required --work path to 柳林风声/work'));
  final workDir = Directory(work);
  if (!workDir.existsSync()) {
    stderr.writeln('Work dir not found: $work');
    exitCode = 1;
    return;
  }

  final episodeDirs = workDir
      .listSync()
      .whereType<Directory>()
      .where((d) => RegExp(r'^E\d{2}$').hasMatch(_basename(d.path)))
      .toList()
    ..sort((a, b) => _basename(a.path).compareTo(_basename(b.path)));

  if (episodeDirs.isEmpty) {
    stderr.writeln('No E## directories under $work');
    exitCode = 1;
    return;
  }

  final chapters = <Map<String, Object?>>[];
  var failCount = 0;
  var warnCount = 0;

  for (final dir in episodeDirs) {
    final episode = _basename(dir.path);
    final englishFile = File('${dir.path}${Platform.pathSeparator}english.txt');
    if (!englishFile.existsSync()) {
      chapters.add({
        'episode': episode,
        'status': 'fail',
        'issues': ['missing_english_txt'],
      });
      failCount += 1;
      continue;
    }

    final english = englishFile.readAsStringSync();
    final sentences = NlpService.splitSentences(english)
        .expand(enforceHardMaxWords)
        .map((sentence) => sentence.trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
    final rows = <Map<String, Object?>>[];
    var maxWords = 0;
    final over30 = <int>[];
    final shortOnes = <int>[];

    for (var i = 0; i < sentences.length; i += 1) {
      final text = sentences[i].trim();
      final wc = _wordCount(text);
      if (wc > maxWords) maxWords = wc;
      if (wc > 30) over30.add(i);
      if (wc > 0 && wc < 4) shortOnes.add(i);
      rows.add({
        'index': i,
        'wordCount': wc,
        'text': text,
      });
    }

    final issues = <String>[];
    final warnings = <String>[];
    if (sentences.isEmpty) issues.add('no_sentences');
    if (over30.isNotEmpty) {
      issues.add('over_30_words:${over30.length}');
    }
    if (shortOnes.length >= 5) {
      warnings.add('many_very_short_chunks:${shortOnes.length}');
    }

    // Round-trip: joining with blank lines should re-split stably enough for review.
    // (Import uses raw english.txt; sentences.txt is the review artifact.)
    final status = issues.isEmpty ? (warnings.isEmpty ? 'ok' : 'warn') : 'fail';
    if (status == 'fail') failCount += 1;
    if (status == 'warn') warnCount += 1;

    final sentencesTxt = StringBuffer();
    for (var i = 0; i < sentences.length; i += 1) {
      sentencesTxt.writeln(sentences[i].trim());
      sentencesTxt.writeln();
    }
    File('${dir.path}${Platform.pathSeparator}sentences.txt')
        .writeAsStringSync('${sentencesTxt.toString().trimRight()}\n');

    final meta = {
      'episode': episode,
      'source': 'english.txt',
      'splitter': 'NlpService.splitSentences',
      'sentenceCount': sentences.length,
      'maxWordCount': maxWords,
      'status': status,
      'issues': issues,
      'warnings': warnings,
      'over30Indexes': over30,
      'sentences': rows,
    };
    File('${dir.path}${Platform.pathSeparator}sentences.json')
        .writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(meta)}\n',
    );

    chapters.add({
      'episode': episode,
      'status': status,
      'sentenceCount': sentences.length,
      'maxWordCount': maxWords,
      'wordCounts': rows.map((r) => r['wordCount']).toList(growable: false),
      'issues': issues,
      'warnings': warnings,
      'previewFirst': sentences.isEmpty ? '' : sentences.first,
      'previewLast': sentences.isEmpty ? '' : sentences.last,
      'over30Samples': over30
          .take(5)
          .map((i) => {
                'index': i,
                'wordCount': rows[i]['wordCount'],
                'text': rows[i]['text']
              })
          .toList(growable: false),
    });

    stdout.writeln(
      '$episode status=$status sentences=${sentences.length} maxWords=$maxWords'
      '${issues.isEmpty ? '' : ' issues=${issues.join(';')}'}',
    );
  }

  final report = {
    'chapterCount': chapters.length,
    'ok': chapters.where((c) => c['status'] == 'ok').length,
    'warn': warnCount,
    'fail': failCount,
    'splitter':
        'package:tomato_english_happy_talking NlpService.splitSentences',
    'hardMaxWords': 30,
    'chapters': chapters,
  };
  File('${workDir.path}${Platform.pathSeparator}sentence-split-report.json')
      .writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(report)}\n');

  final md = StringBuffer()
    ..writeln('# 朗读分句报告')
    ..writeln()
    ..writeln(
        '使用 Tomato `NlpService.splitSentences`（硬上限 30 词）处理 `work/E##/english.txt`。')
    ..writeln()
    ..writeln('- 章节：${report['chapterCount']}')
    ..writeln('- ok：${report['ok']}')
    ..writeln('- warn：${report['warn']}')
    ..writeln('- fail：${report['fail']}')
    ..writeln()
    ..writeln('| 章 | 状态 | 句数 | 最大词数 | 问题 |')
    ..writeln('|---|---|---|---|---|');
  for (final c in chapters) {
    final issues = (c['issues'] as List?)?.join('; ') ?? '';
    final warnings = (c['warnings'] as List?)?.join('; ') ?? '';
    final note = [issues, warnings].where((s) => s.isNotEmpty).join(' / ');
    md.writeln(
      '| ${c['episode']} | ${c['status']} | ${c['sentenceCount']} | ${c['maxWordCount']} | ${note.isEmpty ? '-' : note} |',
    );
  }
  final fails = chapters.where((c) => c['status'] == 'fail');
  if (fails.isNotEmpty) {
    md
      ..writeln()
      ..writeln('## 超限样例')
      ..writeln();
    for (final c in fails) {
      md.writeln('### ${c['episode']}');
      for (final sample in (c['over30Samples'] as List?) ?? const []) {
        final m = sample as Map;
        md.writeln('- [#${m['index']}] (${m['wordCount']} words) ${m['text']}');
      }
      md.writeln();
    }
  }
  File('${workDir.path}${Platform.pathSeparator}sentence-split-report.md')
      .writeAsStringSync(md.toString());

  stdout.writeln(
    'DONE ok=${report['ok']} warn=${report['warn']} fail=${report['fail']} '
    'report=${workDir.path}${Platform.pathSeparator}sentence-split-report.md',
  );
  if (failCount > 0) exitCode = 1;
}

String? _argValue(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i < 0 || i + 1 >= args.length) return null;
  return args[i + 1];
}

String _basename(String path) {
  final parts = path.replaceAll('\\', '/').split('/');
  return parts.isEmpty ? path : parts.last;
}

int _wordCount(String text) {
  // Match NlpService / AGENTS: whitespace-separated tokens.
  return text
      .split(RegExp(r'\s+'))
      .where((token) => token.trim().isNotEmpty)
      .length;
}

/// Force-split leftovers that NlpService left above the 30-word AGENTS ceiling.
Iterable<String> enforceHardMaxWords(String sentence) sync* {
  const hardMax = 30;
  const preferMin = 8;
  const preferMax = 24;
  var rest = sentence.trim();
  if (rest.isEmpty) return;

  while (_wordCount(rest) > hardMax) {
    final breakAt = _findHardBreak(rest, preferMin, preferMax, hardMax);
    if (breakAt <= 0 || breakAt >= rest.length) {
      // Absolute last resort: cut at hardMax words.
      final cut = _cutAfterWords(rest, hardMax);
      final left = rest.substring(0, cut).trim();
      final right = rest.substring(cut).trim();
      if (left.isEmpty || right.isEmpty) {
        yield rest;
        return;
      }
      yield left;
      rest = right;
      continue;
    }
    final left = rest.substring(0, breakAt).trim();
    final right = rest.substring(breakAt).trim();
    if (left.isEmpty) {
      yield rest;
      return;
    }
    yield left;
    rest = right;
  }
  if (rest.isNotEmpty) yield rest;
}

int _findHardBreak(String text, int preferMin, int preferMax, int hardMax) {
  int? bestPrefer;
  int? bestAny;
  int? bestBeforeHard;

  void consider(int index) {
    if (index <= 0 || index >= text.length) return;
    final left = text.substring(0, index).trimRight();
    final right = text.substring(index).trimLeft();
    final leftWords = _wordCount(left);
    final rightWords = _wordCount(right);
    if (leftWords < preferMin || rightWords < 3) return;
    if (leftWords > hardMax) return;
    bestBeforeHard = index;
    if (leftWords <= preferMax) {
      bestAny = index;
      if (leftWords >= preferMin) {
        bestPrefer = index;
      }
    }
  }

  // Prefer sentence-ish and comma/semicolon pauses.
  for (final match in RegExp(r'''[!?;:—–]["”’')\]]*\s+''').allMatches(text)) {
    consider(match.end);
  }
  for (final match in RegExp(r''',\s+''').allMatches(text)) {
    consider(match.end);
  }
  // Connector / clause boundaries.
  final connectors = RegExp(
    r'''\s+(?=and\s|but\s|or\s|which\s|who\s|when\s|where\s|while\s|before\s|after\s|though\s|although\s|because\s|if\s|that\s|with\s)''',
    caseSensitive: false,
  );
  for (final match in connectors.allMatches(text)) {
    consider(match.start);
  }

  return bestPrefer ?? bestAny ?? bestBeforeHard ?? -1;
}

int _cutAfterWords(String text, int wordLimit) {
  final matches = RegExp(r'\S+').allMatches(text).toList(growable: false);
  if (matches.length <= wordLimit) return text.length;
  return matches[wordLimit - 1].end;
}
