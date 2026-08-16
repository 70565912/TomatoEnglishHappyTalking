/// Freezes the pre-refactor V3.7 local solver result after the approved
/// singleton post-processing step. The refactor must reproduce it exactly;
/// the accepted parenthetical behavior is already present in this snapshot.
library;

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v3.dart';

Future<void> main(List<String> args) async {
  final outputPath = _argValue(args, '--output');
  final reportArgs = _argValues(args, '--report');
  if (outputPath == null || reportArgs.isEmpty) {
    throw ArgumentError('Required --output and one or more --report BOOK=PATH');
  }
  final chaptersByBook = <String, List<Map<String, dynamic>>>{};
  final displayNameByBook = <String, String>{};
  final reportsByBook = <String, List<String>>{};
  final solverVersionsByBook = <String, Set<String>>{};
  for (final value in reportArgs) {
    final separator = value.indexOf('=');
    if (separator <= 0 || separator == value.length - 1) {
      throw ArgumentError('Expected BOOK=PATH, got $value');
    }
    final book = value.substring(0, separator);
    final bookKey = book.toLowerCase();
    final path = value.substring(separator + 1);
    final decoded = jsonDecode(await File(path).readAsString(encoding: utf8));
    if (decoded is! Map ||
        decoded['summary'] is! Map ||
        decoded['chapters'] is! List) {
      throw FormatException('Invalid V3.7 report: $path');
    }
    final summary = Map<String, dynamic>.from(decoded['summary'] as Map);
    final chapters = chaptersByBook.putIfAbsent(bookKey, () => []);
    displayNameByBook.putIfAbsent(bookKey, () => book);
    reportsByBook.putIfAbsent(bookKey, () => []).add(File(path).absolute.path);
    solverVersionsByBook
        .putIfAbsent(bookKey, () => <String>{})
        .add(summary['solverVersion']?.toString() ?? '');
    for (final rawChapter in decoded['chapters'] as List) {
      if (rawChapter is! Map || rawChapter['v3LocalSentences'] is! List) {
        continue;
      }
      final episode = rawChapter['episode']?.toString().toUpperCase() ?? '';
      final rawSentences = [
        for (final value in rawChapter['v3LocalSentences'] as List)
          value.toString(),
      ];
      final sentences = ReadAloudSplitterV3.mergeOneWordChunks(rawSentences);
      final source = sentences.map(_canonical).join();
      final digest = await Sha256().hash(utf8.encode(source));
      var offset = 0;
      final boundaries = <int>[];
      for (final sentence in sentences) {
        offset += _canonical(sentence).length;
        boundaries.add(offset);
      }
      chapters.add({
        'episode': episode,
        'canonicalSourceSha256': _hex(digest.bytes),
        'sentenceCount': sentences.length,
        'boundaryCanonicalOffsets': boundaries,
        'sentences': sentences,
      });
    }
  }
  final books = <Map<String, dynamic>>[];
  for (final entry in chaptersByBook.entries) {
    final chapters = entry.value
      ..sort((left, right) =>
          (left['episode'] as String).compareTo(right['episode'] as String));
    final episodes = chapters.map((chapter) => chapter['episode']).toList();
    if (episodes.toSet().length != episodes.length) {
      throw FormatException(
          'Duplicate episode in ${displayNameByBook[entry.key]}');
    }
    final solverVersions = solverVersionsByBook[entry.key]!..remove('');
    if (solverVersions.length != 1) {
      throw FormatException(
        'Expected one solver version for ${displayNameByBook[entry.key]}: '
        '$solverVersions',
      );
    }
    books.add({
      'book': displayNameByBook[entry.key],
      'sourceReports': reportsByBook[entry.key],
      'sourceSolverVersion': solverVersions.single,
      'postProcessor': 'mergeOneWordChunks',
      'chapterCount': chapters.length,
      'sentenceCount': chapters.fold<int>(
        0,
        (total, chapter) => total + (chapter['sentenceCount'] as int),
      ),
      'chapters': chapters,
    });
  }
  final output = File(outputPath);
  await output.parent.create(recursive: true);
  await output.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert({
          'schemaVersion': 'read_aloud_solver_oracle_v1',
          'policy':
              'Refactors must match the pre-refactor V3.7 solver oracle exactly.',
          'books': books,
        })}\n',
    encoding: utf8,
    flush: true,
  );
  stdout.writeln(
    'Solver oracle: ${output.absolute.path}; '
    '${books.length} books; '
    '${books.fold<int>(0, (total, book) => total + (book['chapterCount'] as int))} chapters; '
    '${books.fold<int>(0, (total, book) => total + (book['sentenceCount'] as int))} sentences',
  );
}

String _canonical(String value) => value.replaceAll(RegExp(r'\s+'), '');

String _hex(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

String? _argValue(List<String> args, String name) {
  final index = args.indexOf(name);
  return index < 0 || index + 1 >= args.length ? null : args[index + 1];
}

List<String> _argValues(List<String> args, String name) {
  final values = <String>[];
  for (var index = 0; index < args.length - 1; index += 1) {
    if (args[index] == name) values.add(args[index + 1]);
  }
  return values;
}
