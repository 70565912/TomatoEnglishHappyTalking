import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:tomato_english_happy_talking/core/logging/tomato_logger.dart';

void main() {
  test('filters by level/category and keeps a bounded memory ring', () async {
    final directory = await Directory.systemTemp.createTemp('tomato_logs_');
    addTearDown(() async {
      await TomatoLogger.resetForTest();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    await TomatoLogger.initialize(
      directory: directory,
      memoryLimit: 2,
      minLevel: 'info',
    );

    TomatoLogger.debug(category: 'qa', event: 'hidden_debug');
    TomatoLogger.info(category: 'qa', event: 'first');
    TomatoLogger.warn(category: 'qa', event: 'second');
    TomatoLogger.error(category: 'bridge', event: 'third');

    final logs = TomatoLogger.recentJson(limit: 10);
    expect(logs.map((entry) => entry['event']), ['second', 'third']);
    expect(
      TomatoLogger.recentJson(level: 'error').map((entry) => entry['event']),
      ['third'],
    );
    expect(
      TomatoLogger.recentJson(category: 'qa').map((entry) => entry['event']),
      ['second'],
    );
  });

  test('writes NDJSON and redacts secrets, long text, and absolute paths',
      () async {
    final directory = await Directory.systemTemp.createTemp('tomato_logs_');
    addTearDown(() async {
      await TomatoLogger.resetForTest();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    await TomatoLogger.initialize(
      directory: directory,
      minLevel: 'trace',
    );
    TomatoLogger.info(
      category: 'config',
      event: 'redaction_probe',
      data: {
        'Authorization': 'Bearer secret-token-12345678901234567890',
        'filePath': r'F:\TomatoEnglishHappyTalking\security\ark.txt',
        'lyrics': 'la ' * 250,
      },
    );
    await TomatoLogger.flush();

    final text = await _readLogFiles(directory);
    expect(text, contains('"category":"config"'));
    expect(text, contains('[redacted]'));
    expect(text, contains('[path:ark.txt]'));
    expect(text, contains('[truncated length='));
    expect(text, isNot(contains('secret-token-12345678901234567890')));
    expect(text, isNot(contains(r'F:\TomatoEnglishHappyTalking\security')));

    final firstLine = LineSplitter.split(text).firstWhere(
      (line) => line.trim().isNotEmpty,
    );
    expect(jsonDecode(firstLine), isA<Map<String, dynamic>>());
  });

  test('rotates log files and removes files outside retention window',
      () async {
    final directory = await Directory.systemTemp.createTemp('tomato_logs_');
    addTearDown(() async {
      await TomatoLogger.resetForTest();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    final oldFile = File(path.join(directory.path, 'tomato-old.ndjson'))
      ..writeAsStringSync('{"old":true}\n');
    await oldFile.setLastModified(DateTime.utc(2020));

    await TomatoLogger.initialize(
      directory: directory,
      maxFileBytes: 420,
      maxFiles: 2,
      retention: const Duration(days: 7),
      clock: () => DateTime.utc(2026, 6, 13),
    );
    expect(await oldFile.exists(), isFalse);

    for (var i = 0; i < 40; i++) {
      TomatoLogger.info(
        category: 'qa',
        event: 'rotation_probe',
        message: 'entry $i ${'x' * 100}',
      );
    }
    await TomatoLogger.flush();

    final files = await _logFiles(directory);
    expect(files.length, lessThanOrEqualTo(2));
    expect(files, isNotEmpty);
  });

  test('span writes start and error entries with duration and stack', () async {
    final directory = await Directory.systemTemp.createTemp('tomato_logs_');
    addTearDown(() async {
      await TomatoLogger.resetForTest();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    await TomatoLogger.initialize(directory: directory);
    final span = TomatoLogger.span(
      category: 'qa',
      event: 'probe',
      flowId: 'flow-1',
      data: {'apiKey': 'secret-token-123456789012'},
    );
    span.fail(StateError('boom'), stackTrace: StackTrace.current);
    await TomatoLogger.flush();

    final events = TomatoLogger.recentJson(category: 'qa', limit: 10);
    expect(events.map((entry) => entry['event']),
        containsAll(['probe.start', 'probe.error']));
    final errorEntry =
        events.firstWhere((entry) => entry['event'] == 'probe.error');
    expect(errorEntry['flowId'], 'flow-1');
    expect(errorEntry['status'], 'error');
    expect(errorEntry['durationMs'], isA<int>());
    expect(errorEntry['stack'], isNotNull);
  });
}

Future<String> _readLogFiles(Directory directory) async {
  final files = await _logFiles(directory);
  final chunks = <String>[];
  for (final file in files) {
    chunks.add(await file.readAsString());
  }
  return chunks.join('\n');
}

Future<List<File>> _logFiles(Directory directory) async {
  final files = await directory
      .list()
      .where(
        (entity) =>
            entity is File &&
            path.basename(entity.path).startsWith('tomato-') &&
            path.basename(entity.path).endsWith('.ndjson'),
      )
      .cast<File>()
      .toList();
  files.sort((left, right) => left.path.compareTo(right.path));
  return files;
}
