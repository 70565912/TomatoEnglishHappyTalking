import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path_lib;

typedef TomatoLogJsonProducer = FutureOr<Map<String, dynamic>> Function();

class TomatoLogEntry {
  TomatoLogEntry({
    required this.ts,
    required this.level,
    required this.category,
    required this.event,
    this.message,
    this.flowId,
    this.articleId,
    this.route,
    this.stage,
    this.status,
    this.durationMs,
    this.data,
    this.error,
    this.stack,
  });

  final DateTime ts;
  final String level;
  final String category;
  final String event;
  final String? message;
  final String? flowId;
  final int? articleId;
  final String? route;
  final String? stage;
  final String? status;
  final int? durationMs;
  final Object? data;
  final String? error;
  final String? stack;

  Map<String, dynamic> toJson() => {
        'ts': ts.toIso8601String(),
        'level': level,
        'category': category,
        'event': event,
        'message': message,
        'flowId': flowId,
        'articleId': articleId,
        'route': route,
        'stage': stage,
        'status': status,
        'durationMs': durationMs,
        'data': data,
        'error': error,
        'stack': stack,
      };
}

class TomatoLogSpan {
  TomatoLogSpan._({
    required this.category,
    required this.event,
    required this.flowId,
    this.articleId,
    this.route,
    this.stage,
    this.data,
  }) : _stopwatch = Stopwatch()..start();

  final String category;
  final String event;
  final String flowId;
  final int? articleId;
  final String? route;
  final String? stage;
  final Object? data;
  final Stopwatch _stopwatch;
  bool _completed = false;

  void end({
    String? message,
    String? status = 'success',
    Object? data,
  }) {
    if (_completed) {
      return;
    }
    _completed = true;
    _stopwatch.stop();
    TomatoLogger.info(
      category: category,
      event: '$event.end',
      message: message,
      flowId: flowId,
      articleId: articleId,
      route: route,
      stage: stage,
      status: status,
      durationMs: _stopwatch.elapsedMilliseconds,
      data: data,
    );
  }

  void fail(
    Object error, {
    StackTrace? stackTrace,
    String? message,
    Object? data,
  }) {
    if (_completed) {
      return;
    }
    _completed = true;
    _stopwatch.stop();
    TomatoLogger.error(
      category: category,
      event: '$event.error',
      message: message,
      flowId: flowId,
      articleId: articleId,
      route: route,
      stage: stage,
      status: 'error',
      durationMs: _stopwatch.elapsedMilliseconds,
      data: data,
      error: error,
      stackTrace: stackTrace,
    );
  }
}

class TomatoLogger {
  static const defaultMemoryLimit = 2000;
  static const defaultMaxFileBytes = 5 * 1024 * 1024;
  static const defaultMaxFiles = 10;
  static const defaultRetention = Duration(days: 7);
  static const _logFilePrefix = 'tomato-';
  static const _logFileExtension = '.ndjson';
  static const _desktopDataRootDefine =
      String.fromEnvironment('TOMATO_DESKTOP_DATA_ROOT');
  static const _logLevelDefine = String.fromEnvironment('TOMATO_LOG_LEVEL');
  static const _logCategoriesDefine =
      String.fromEnvironment('TOMATO_LOG_CATEGORIES');

  static const Map<String, int> _levelRanks = {
    'trace': 0,
    'debug': 1,
    'info': 2,
    'warn': 3,
    'error': 4,
    'fatal': 5,
  };

  static final List<TomatoLogEntry> _memory = <TomatoLogEntry>[];
  static final StreamController<TomatoLogEntry> _entryController =
      StreamController<TomatoLogEntry>.broadcast();

  static Directory? _directory;
  static int _memoryLimit = defaultMemoryLimit;
  static int _maxFileBytes = defaultMaxFileBytes;
  static int _maxFiles = defaultMaxFiles;
  static Duration _retention = defaultRetention;
  static String _minLevel = 'info';
  static Set<String> _enabledCategories = const <String>{};
  static DateTime Function() _clock = DateTime.now;
  static File? _activeFile;
  static int _activeBytes = 0;
  static Future<void> _writeTail = Future<void>.value();
  static bool _initialized = false;

  static bool get isInitialized => _initialized;

  static Directory? get logDirectory => _directory;

  static Stream<TomatoLogEntry> get entries => _entryController.stream;

  static Future<void> initialize({
    Directory? directory,
    int memoryLimit = defaultMemoryLimit,
    int maxFileBytes = defaultMaxFileBytes,
    int maxFiles = defaultMaxFiles,
    Duration retention = defaultRetention,
    String? minLevel,
    Set<String>? categories,
    DateTime Function()? clock,
  }) async {
    _memoryLimit = memoryLimit <= 0 ? defaultMemoryLimit : memoryLimit;
    _maxFileBytes = maxFileBytes <= 0 ? defaultMaxFileBytes : maxFileBytes;
    _maxFiles = maxFiles <= 0 ? defaultMaxFiles : maxFiles;
    _retention = retention;
    _minLevel = _normalizeLevel(
      minLevel ??
          _firstNonEmpty([
            Platform.environment['TOMATO_LOG_LEVEL'],
            _logLevelDefine,
          ]) ??
          'info',
    );
    _enabledCategories = categories ??
        _parseCategories(
          _firstNonEmpty([
            Platform.environment['TOMATO_LOG_CATEGORIES'],
            _logCategoriesDefine,
          ]),
        );
    _clock = clock ?? DateTime.now;
    _directory = directory ?? Directory(_resolveDefaultLogDirectory());
    await _directory!.create(recursive: true);
    await _cleanupOldFiles();
    _initialized = true;
    info(
      category: 'startup',
      event: 'logger.initialized',
      message: 'Tomato logger initialized',
      data: {
        'directory': _directory!.absolute.path,
        'level': _minLevel,
        'categories': _enabledCategories.toList(growable: false),
        'memoryLimit': _memoryLimit,
        'maxFileBytes': _maxFileBytes,
        'maxFiles': _maxFiles,
        'retentionDays': _retention.inDays,
      },
    );
  }

  @visibleForTesting
  static Future<void> resetForTest() async {
    await flush();
    _memory.clear();
    _directory = null;
    _activeFile = null;
    _activeBytes = 0;
    _writeTail = Future<void>.value();
    _memoryLimit = defaultMemoryLimit;
    _maxFileBytes = defaultMaxFileBytes;
    _maxFiles = defaultMaxFiles;
    _retention = defaultRetention;
    _minLevel = 'info';
    _enabledCategories = const <String>{};
    _clock = DateTime.now;
    _initialized = false;
  }

  static TomatoLogSpan span({
    required String category,
    required String event,
    String? flowId,
    int? articleId,
    String? route,
    String? stage,
    Object? data,
  }) {
    final id = flowId ?? _newFlowId(event);
    info(
      category: category,
      event: '$event.start',
      flowId: id,
      articleId: articleId,
      route: route,
      stage: stage,
      status: 'start',
      data: data,
    );
    return TomatoLogSpan._(
      category: category,
      event: event,
      flowId: id,
      articleId: articleId,
      route: route,
      stage: stage,
      data: data,
    );
  }

  static void trace({
    required String category,
    required String event,
    String? message,
    String? flowId,
    int? articleId,
    String? route,
    String? stage,
    String? status,
    int? durationMs,
    Object? data,
    Object? error,
    StackTrace? stackTrace,
    bool force = false,
  }) =>
      log(
        level: 'trace',
        category: category,
        event: event,
        message: message,
        flowId: flowId,
        articleId: articleId,
        route: route,
        stage: stage,
        status: status,
        durationMs: durationMs,
        data: data,
        error: error,
        stackTrace: stackTrace,
        force: force,
      );

  static void debug({
    required String category,
    required String event,
    String? message,
    String? flowId,
    int? articleId,
    String? route,
    String? stage,
    String? status,
    int? durationMs,
    Object? data,
    Object? error,
    StackTrace? stackTrace,
    bool force = false,
  }) =>
      log(
        level: 'debug',
        category: category,
        event: event,
        message: message,
        flowId: flowId,
        articleId: articleId,
        route: route,
        stage: stage,
        status: status,
        durationMs: durationMs,
        data: data,
        error: error,
        stackTrace: stackTrace,
        force: force,
      );

  static void info({
    required String category,
    required String event,
    String? message,
    String? flowId,
    int? articleId,
    String? route,
    String? stage,
    String? status,
    int? durationMs,
    Object? data,
  }) =>
      log(
        level: 'info',
        category: category,
        event: event,
        message: message,
        flowId: flowId,
        articleId: articleId,
        route: route,
        stage: stage,
        status: status,
        durationMs: durationMs,
        data: data,
      );

  static void warn({
    required String category,
    required String event,
    String? message,
    String? flowId,
    int? articleId,
    String? route,
    String? stage,
    String? status,
    int? durationMs,
    Object? data,
    Object? error,
    StackTrace? stackTrace,
  }) =>
      log(
        level: 'warn',
        category: category,
        event: event,
        message: message,
        flowId: flowId,
        articleId: articleId,
        route: route,
        stage: stage,
        status: status,
        durationMs: durationMs,
        data: data,
        error: error,
        stackTrace: stackTrace,
      );

  static void error({
    required String category,
    required String event,
    String? message,
    String? flowId,
    int? articleId,
    String? route,
    String? stage,
    String? status,
    int? durationMs,
    Object? data,
    Object? error,
    StackTrace? stackTrace,
  }) =>
      log(
        level: 'error',
        category: category,
        event: event,
        message: message,
        flowId: flowId,
        articleId: articleId,
        route: route,
        stage: stage,
        status: status,
        durationMs: durationMs,
        data: data,
        error: error,
        stackTrace: stackTrace,
      );

  static void fatal({
    required String category,
    required String event,
    String? message,
    Object? data,
    Object? error,
    StackTrace? stackTrace,
  }) =>
      log(
        level: 'fatal',
        category: category,
        event: event,
        message: message,
        data: data,
        error: error,
        stackTrace: stackTrace,
        force: true,
      );

  static void log({
    required String level,
    required String category,
    required String event,
    String? message,
    String? flowId,
    int? articleId,
    String? route,
    String? stage,
    String? status,
    int? durationMs,
    Object? data,
    Object? error,
    StackTrace? stackTrace,
    bool force = false,
  }) {
    final normalizedLevel = _normalizeLevel(level);
    final normalizedCategory = _normalizeToken(category, fallback: 'app');
    if (!force && !_shouldLog(normalizedLevel, normalizedCategory)) {
      return;
    }

    final entry = TomatoLogEntry(
      ts: _clock().toUtc(),
      level: normalizedLevel,
      category: normalizedCategory,
      event: _normalizeToken(event, fallback: 'event'),
      message: _sanitizeString(message),
      flowId: _sanitizeString(flowId),
      articleId: articleId,
      route: _sanitizeString(route),
      stage: _sanitizeString(stage),
      status: _sanitizeString(status),
      durationMs: durationMs,
      data: _sanitizeValue(data),
      error: error == null ? null : _sanitizeString(error.toString()),
      stack: stackTrace == null ? null : _sanitizeString(stackTrace.toString()),
    );
    _addToMemory(entry);
    _entryController.add(entry);
    _enqueueFileWrite(entry);
    if (normalizedLevel == 'error' || normalizedLevel == 'fatal') {
      debugPrint('[TomatoLog][$normalizedCategory] ${entry.event}: '
          '${entry.message ?? entry.error ?? ''}');
    }
  }

  static List<Map<String, dynamic>> recentJson({
    int limit = 200,
    String? level,
    String? category,
    String? since,
  }) =>
      recent(
        limit: limit,
        level: level,
        category: category,
        since: since,
      ).map((entry) => entry.toJson()).toList(growable: false);

  static List<TomatoLogEntry> recent({
    int limit = 200,
    String? level,
    String? category,
    String? since,
  }) {
    final normalizedLimit = limit <= 0 ? 200 : limit.clamp(1, 2000);
    final minLevel =
        level == null || level.trim().isEmpty ? null : _normalizeLevel(level);
    final categories = _parseCategories(category);
    final sinceTime = since == null ? null : DateTime.tryParse(since);
    final selected = _memory.where((entry) {
      if (minLevel != null &&
          (_levelRanks[entry.level] ?? 2) < (_levelRanks[minLevel] ?? 2)) {
        return false;
      }
      if (categories.isNotEmpty && !categories.contains(entry.category)) {
        return false;
      }
      if (sinceTime != null && entry.ts.isBefore(sinceTime.toUtc())) {
        return false;
      }
      return true;
    }).toList(growable: false);
    final start = selected.length > normalizedLimit
        ? selected.length - normalizedLimit
        : 0;
    return selected.sublist(start);
  }

  static bool matches(
    TomatoLogEntry entry, {
    String? level,
    String? category,
    String? since,
  }) {
    final minLevel =
        level == null || level.trim().isEmpty ? null : _normalizeLevel(level);
    final categories = _parseCategories(category);
    final sinceTime = since == null ? null : DateTime.tryParse(since);
    if (minLevel != null &&
        (_levelRanks[entry.level] ?? 2) < (_levelRanks[minLevel] ?? 2)) {
      return false;
    }
    if (categories.isNotEmpty && !categories.contains(entry.category)) {
      return false;
    }
    if (sinceTime != null && entry.ts.isBefore(sinceTime.toUtc())) {
      return false;
    }
    return true;
  }

  static Future<List<Map<String, dynamic>>> logFilesJson() async {
    final directory = _directory;
    if (directory == null || !await directory.exists()) {
      return const <Map<String, dynamic>>[];
    }
    final files = await _logFiles();
    return Future.wait(files.map((file) async {
      final stat = await file.stat();
      return {
        'name': path_lib.basename(file.path),
        'path': file.absolute.path,
        'bytes': stat.size,
        'modifiedAt': stat.modified.toUtc().toIso8601String(),
      };
    }));
  }

  static Future<Map<String, dynamic>> exportDiagnostics({
    TomatoLogJsonProducer? environment,
    TomatoLogJsonProducer? snapshot,
  }) async {
    await flush();
    final root = _directory ?? Directory(_resolveDefaultLogDirectory());
    await root.create(recursive: true);
    final exportDir = Directory(
      path_lib.join(root.path, 'exports', 'tomato-diagnostics-${_stamp()}'),
    );
    await exportDir.create(recursive: true);

    Future<void> writeJson(String name, Object payload) async {
      await File(path_lib.join(exportDir.path, name)).writeAsString(
        const JsonEncoder.withIndent('  ').convert(_sanitizeValue(payload)),
        flush: true,
      );
    }

    final envPayload = <String, dynamic>{
      'createdAt': _clock().toUtc().toIso8601String(),
      'platform': Platform.operatingSystem,
      'resolvedExecutable': Platform.resolvedExecutable,
      'logDirectory': root.absolute.path,
      'logLevel': _minLevel,
      'enabledCategories': _enabledCategories.toList(growable: false),
    };
    if (environment != null) {
      try {
        envPayload['app'] = await environment();
      } catch (error) {
        envPayload['appError'] = error.toString();
      }
    }
    await writeJson('environment.json', envPayload);

    if (snapshot != null) {
      try {
        await writeJson('snapshot.json', await snapshot());
      } catch (error, stackTrace) {
        await writeJson('snapshot-error.json', {
          'error': error.toString(),
          'stack': stackTrace.toString(),
        });
      }
    }

    final recentFile = File(path_lib.join(exportDir.path, 'recent.ndjson'));
    await recentFile.writeAsString(
      recent(limit: _memoryLimit)
          .map((entry) => jsonEncode(entry.toJson()))
          .join('\n'),
      flush: true,
    );

    final copied = <String>[];
    for (final file in await _logFiles()) {
      final target =
          path_lib.join(exportDir.path, path_lib.basename(file.path));
      await file.copy(target);
      copied.add(path_lib.basename(target));
    }
    info(
      category: 'qa',
      event: 'logs.exported',
      message: 'Diagnostic log export created',
      data: {'path': exportDir.absolute.path, 'fileCount': copied.length},
    );
    return {
      'path': exportDir.absolute.path,
      'files': [
        'environment.json',
        if (snapshot != null) 'snapshot.json',
        'recent.ndjson',
        ...copied,
      ],
    };
  }

  static Future<void> flush() => _writeTail;

  static String _resolveDefaultLogDirectory() {
    final explicitLogDir = Platform.environment['TOMATO_LOG_DIR']?.trim() ?? '';
    if (explicitLogDir.isNotEmpty) {
      return path_lib.normalize(path_lib.absolute(explicitLogDir));
    }

    final dataRoot = _firstNonEmpty([
      Platform.environment['TOMATO_DESKTOP_DATA_ROOT'],
      _desktopDataRootDefine,
    ]);
    if (dataRoot != null) {
      return path_lib.join(
          path_lib.normalize(path_lib.absolute(dataRoot)), 'logs');
    }

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return path_lib.join(
        File(Platform.resolvedExecutable).parent.absolute.path,
        'logs',
      );
    }

    return path_lib.join(
      Directory.systemTemp.absolute.path,
      'tomato_english_happy_talking',
      'logs',
    );
  }

  static void _addToMemory(TomatoLogEntry entry) {
    _memory.add(entry);
    while (_memory.length > _memoryLimit) {
      _memory.removeAt(0);
    }
  }

  static void _enqueueFileWrite(TomatoLogEntry entry) {
    if (!_initialized || _directory == null) {
      return;
    }
    final line = '${jsonEncode(entry.toJson())}\n';
    _writeTail = _writeTail.catchError((_) {}).then((_) async {
      await _ensureActiveFile(utf8.encode(line).length);
      final file = _activeFile;
      if (file == null) {
        return;
      }
      await file.writeAsString(line, mode: FileMode.append, flush: false);
      _activeBytes += utf8.encode(line).length;
    }).catchError((Object error) {
      debugPrint('[TomatoLogger] file write failed: $error');
    });
  }

  static Future<void> _ensureActiveFile(int nextBytes) async {
    final directory = _directory;
    if (directory == null) {
      return;
    }
    await directory.create(recursive: true);
    final active = _activeFile;
    if (active != null &&
        await active.exists() &&
        _activeBytes + nextBytes <= _maxFileBytes) {
      return;
    }

    if (active != null && await active.exists()) {
      final stat = await active.stat();
      if (stat.size + nextBytes <= _maxFileBytes) {
        _activeBytes = stat.size;
        return;
      }
    }

    _activeFile = File(path_lib.join(
        directory.path, '$_logFilePrefix${_stamp()}$_logFileExtension'));
    _activeBytes = 0;
    await _cleanupOldFiles();
  }

  static Future<void> _cleanupOldFiles() async {
    final files = await _logFiles();
    final now = _clock();
    for (final file in files) {
      final stat = await file.stat();
      if (now.difference(stat.modified) > _retention) {
        try {
          await file.delete();
        } catch (_) {
          // Best-effort cleanup; active or locked files can be retried later.
        }
      }
    }

    final remaining = await _logFiles();
    if (remaining.length <= _maxFiles) {
      return;
    }
    final extra = remaining.take(remaining.length - _maxFiles);
    for (final file in extra) {
      try {
        await file.delete();
      } catch (_) {
        // Best-effort cleanup; active or locked files can be retried later.
      }
    }
  }

  static Future<List<File>> _logFiles() async {
    final directory = _directory;
    if (directory == null || !await directory.exists()) {
      return <File>[];
    }
    final files = await directory
        .list()
        .where((entity) =>
            entity is File &&
            path_lib.basename(entity.path).startsWith(_logFilePrefix) &&
            path_lib.basename(entity.path).endsWith(_logFileExtension))
        .cast<File>()
        .toList();
    files.sort((left, right) => left.path.compareTo(right.path));
    return files;
  }

  static bool _shouldLog(String level, String category) {
    final levelRank = _levelRanks[level] ?? _levelRanks['info']!;
    final minRank = _levelRanks[_minLevel] ?? _levelRanks['info']!;
    if (levelRank < minRank) {
      return false;
    }
    return _enabledCategories.isEmpty || _enabledCategories.contains(category);
  }

  static String _normalizeLevel(String value) {
    final normalized = value.trim().toLowerCase();
    return _levelRanks.containsKey(normalized) ? normalized : 'info';
  }

  static String _normalizeToken(String value, {required String fallback}) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      return fallback;
    }
    return normalized.length > 80 ? normalized.substring(0, 80) : normalized;
  }

  static Set<String> _parseCategories(String? value) {
    final raw = (value ?? '').trim();
    if (raw.isEmpty) {
      return const <String>{};
    }
    return raw
        .split(RegExp(r'[,;|\s]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet();
  }

  static Object? _sanitizeValue(Object? value, {String? key, int depth = 0}) {
    if (_isSensitiveKey(key)) {
      return '[redacted]';
    }
    if (value == null || value is num || value is bool) {
      return value;
    }
    if (value is DateTime) {
      return value.toUtc().toIso8601String();
    }
    if (value is String) {
      return _sanitizeString(value);
    }
    if (depth >= 5) {
      return '[max-depth]';
    }
    if (value is Map) {
      return value.map(
        (rawKey, rawValue) {
          final childKey = rawKey.toString();
          return MapEntry(
            childKey,
            _sanitizeValue(rawValue, key: childKey, depth: depth + 1),
          );
        },
      );
    }
    if (value is Iterable) {
      final list = value
          .take(50)
          .map((item) => _sanitizeValue(item, depth: depth + 1))
          .toList(growable: false);
      if (value.length > 50) {
        return {
          'items': list,
          'truncated': true,
          'length': value.length,
        };
      }
      return list;
    }
    return _sanitizeString(value.toString());
  }

  static bool _isSensitiveKey(String? key) {
    final normalized = (key ?? '').toLowerCase();
    if (normalized.isEmpty) {
      return false;
    }
    return RegExp(
      r'(api[_-]?key|authorization|bearer|cookie|token|secret|password|credential)',
    ).hasMatch(normalized);
  }

  static String? _sanitizeString(String? value) {
    if (value == null) {
      return null;
    }
    var text = value;
    text = text.replaceAll(
      RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]{12,}', caseSensitive: false),
      'Bearer [redacted]',
    );
    text = text.replaceAll(
      RegExp(
          r'(X-Api-Key|api[_-]?key|authorization|cookie|token|secret)\s*[:=]\s*[^,\s;}]+',
          caseSensitive: false),
      r'$1=[redacted]',
    );
    text = text.replaceAllMapped(
      RegExp(r'[A-Za-z]:\\[^\s"<>|]+'),
      (match) => '[path:${_basenameFromPath(match.group(0)!)}]',
    );
    text = text.replaceAllMapped(
      RegExp(r'/(?:Users|home|tmp|var|mnt)/[^\s"<>|]+'),
      (match) => '[path:${_basenameFromPath(match.group(0)!)}]',
    );
    if (text.length <= 500) {
      return text;
    }
    return '${text.substring(0, 240)}...'
        '[truncated length=${text.length} hash=${_hashString(text)}]...'
        '${text.substring(text.length - 120)}';
  }

  static String _basenameFromPath(String value) {
    final normalized = value.replaceAll('\\', '/');
    final parts = normalized.split('/');
    return parts.isEmpty || parts.last.isEmpty ? 'file' : parts.last;
  }

  static String _hashString(String value) {
    var hash = 0x811c9dc5;
    for (final codeUnit in value.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static String _newFlowId(String event) =>
      '${event.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '-')}-${_clock().microsecondsSinceEpoch}';

  static String _stamp() => _clock()
      .toUtc()
      .toIso8601String()
      .replaceAll(RegExp(r'[:.]'), '-')
      .replaceAll('Z', 'z');

  static String? _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      final trimmed = value?.trim() ?? '';
      if (trimmed.isNotEmpty) {
        return trimmed;
      }
    }
    return null;
  }
}
