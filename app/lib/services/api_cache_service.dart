import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as path_lib;
import 'package:sqflite/sqflite.dart';

import 'database_service.dart';

class ApiCacheEntry {
  const ApiCacheEntry({
    required this.cacheKey,
    required this.kind,
    required this.purpose,
    required this.requestJson,
    this.textValue,
    this.jsonValue,
    this.filePath,
    this.contentType,
    this.byteLength,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
    required this.lastUsedAt,
  });

  final String cacheKey;
  final String kind;
  final String purpose;
  final String requestJson;
  final String? textValue;
  final String? jsonValue;
  final String? filePath;
  final String? contentType;
  final int? byteLength;
  final String source;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime lastUsedAt;

  factory ApiCacheEntry.fromMap(Map<String, dynamic> map) => ApiCacheEntry(
        cacheKey: map['cache_key'] as String,
        kind: map['kind'] as String,
        purpose: map['purpose'] as String,
        requestJson: map['request_json'] as String,
        textValue: map['text_value'] as String?,
        jsonValue: map['json_value'] as String?,
        filePath: map['file_path'] as String?,
        contentType: map['content_type'] as String?,
        byteLength: (map['byte_length'] as num?)?.toInt(),
        source: map['source'] as String,
        createdAt: DateTime.parse(map['created_at'] as String),
        updatedAt: DateTime.parse(map['updated_at'] as String),
        lastUsedAt: DateTime.parse(map['last_used_at'] as String),
      );
}

class CachedSentenceRecording {
  const CachedSentenceRecording({
    required this.articleId,
    required this.sentenceIndex,
    required this.sentence,
    required this.recordingPath,
    required this.audioHash,
    required this.recognizedText,
    required this.resultJson,
    required this.createdAt,
    required this.updatedAt,
  });

  final int articleId;
  final int sentenceIndex;
  final String sentence;
  final String recordingPath;
  final String audioHash;
  final String recognizedText;
  final String resultJson;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory CachedSentenceRecording.fromMap(Map<String, dynamic> map) =>
      CachedSentenceRecording(
        articleId: map['article_id'] as int,
        sentenceIndex: map['sentence_index'] as int,
        sentence: map['sentence'] as String,
        recordingPath: map['recording_path'] as String,
        audioHash: map['audio_hash'] as String,
        recognizedText: map['recognized_text'] as String,
        resultJson: map['result_json'] as String,
        createdAt: DateTime.parse(map['created_at'] as String),
        updatedAt: DateTime.parse(map['updated_at'] as String),
      );
}

class ApiCacheService {
  static final _sha256 = Sha256();

  static Future<String> keyForJson(
    String namespace,
    Map<String, dynamic> request,
  ) async {
    final canonical = canonicalJson(request);
    final hash = await hashUtf8(canonical);
    return '${_safeNamespace(namespace)}_$hash';
  }

  static Future<String> keyForBytes(
    String namespace,
    List<int> bytes,
  ) async {
    final hash = await hashBytes(bytes);
    return '${_safeNamespace(namespace)}_$hash';
  }

  static String canonicalJson(Object? value) =>
      jsonEncode(_canonicalize(value));

  static Future<String> hashUtf8(String text) => hashBytes(utf8.encode(text));

  static Future<String> hashBytes(List<int> bytes) async {
    final hash = await _sha256.hash(bytes);
    return hash.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static Future<ApiCacheEntry?> getEntry(
    String cacheKey, {
    int? articleId,
    String? purpose,
  }) async {
    final db = await DatabaseService.database;
    final rows = await db.query(
      'api_cache_entries',
      where: 'cache_key = ?',
      whereArgs: [cacheKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }

    var entry = ApiCacheEntry.fromMap(rows.first);
    final filePath = entry.filePath;
    if (filePath != null && filePath.trim().isNotEmpty) {
      final resolvedPath = await migrateLegacyCacheFileIfNeeded(filePath);
      if (!await File(resolvedPath).exists()) {
        await db.delete(
          'api_cache_entries',
          where: 'cache_key = ?',
          whereArgs: [cacheKey],
        );
        return null;
      }
      if (resolvedPath != filePath) {
        await db.update(
          'api_cache_entries',
          {
            'file_path': resolvedPath,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'cache_key = ?',
          whereArgs: [cacheKey],
        );
        entry = ApiCacheEntry.fromMap({
          ...rows.first,
          'file_path': resolvedPath,
          'updated_at': DateTime.now().toIso8601String(),
        });
      }
    }

    await touch(cacheKey);
    await attachArticleRef(
      articleId: articleId,
      cacheKey: cacheKey,
      purpose: purpose ?? entry.purpose,
    );
    return entry;
  }

  static Future<String?> getText(
    String cacheKey, {
    int? articleId,
    String? purpose,
  }) async {
    final entry = await getEntry(
      cacheKey,
      articleId: articleId,
      purpose: purpose,
    );
    return entry?.textValue;
  }

  static Future<String?> getFilePath(
    String cacheKey, {
    int? articleId,
    String? purpose,
  }) async {
    final entry = await getEntry(
      cacheKey,
      articleId: articleId,
      purpose: purpose,
    );
    return entry?.filePath;
  }

  static Future<ApiCacheEntry?> getLatestEntryForArticlePurpose({
    required int articleId,
    required String purpose,
    int limit = 20,
  }) async {
    final entries = await getEntriesForArticlePurpose(
      articleId: articleId,
      purpose: purpose,
      limit: limit,
    );
    return entries.isEmpty ? null : entries.first;
  }

  static Future<List<ApiCacheEntry>> getEntriesForArticlePurpose({
    required int articleId,
    required String purpose,
    int limit = 80,
  }) async {
    final db = await DatabaseService.database;
    final rows = await db.rawQuery(
      '''
      SELECT e.*
      FROM api_cache_article_refs r
      JOIN api_cache_entries e ON e.cache_key = r.cache_key
      WHERE r.article_id = ? AND r.purpose = ? AND e.purpose = ?
      ORDER BY e.updated_at DESC, e.last_used_at DESC
      LIMIT ?
      ''',
      [articleId, purpose, purpose, limit],
    );
    final entries = <ApiCacheEntry>[];
    for (final row in rows) {
      final cacheKey = row['cache_key']?.toString() ?? '';
      if (cacheKey.isEmpty) {
        continue;
      }
      final entry = await getEntry(
        cacheKey,
        articleId: articleId,
        purpose: purpose,
      );
      if (entry != null) {
        entries.add(entry);
      }
    }
    return entries;
  }

  static Future<void> putText({
    required String cacheKey,
    required String kind,
    required String purpose,
    required Map<String, dynamic> request,
    required String textValue,
    int? articleId,
    String source = 'remote',
  }) async {
    if (textValue.trim().isEmpty || source != 'remote') {
      return;
    }
    await _putEntry(
      cacheKey: cacheKey,
      kind: kind,
      purpose: purpose,
      request: request,
      textValue: textValue,
      source: source,
      articleId: articleId,
    );
  }

  static Future<void> putJson({
    required String cacheKey,
    required String kind,
    required String purpose,
    required Map<String, dynamic> request,
    required Map<String, dynamic> jsonValue,
    int? articleId,
    String source = 'remote',
  }) async {
    if (source != 'remote') {
      return;
    }
    await _putEntry(
      cacheKey: cacheKey,
      kind: kind,
      purpose: purpose,
      request: request,
      jsonValue: canonicalJson(jsonValue),
      source: source,
      articleId: articleId,
    );
  }

  static Future<String> putFileBytes({
    required String cacheKey,
    required String kind,
    required String purpose,
    required Map<String, dynamic> request,
    required List<int> bytes,
    required String subdirectory,
    required String extension,
    required String contentType,
    int? articleId,
    String source = 'remote',
  }) async {
    if (bytes.isEmpty || source != 'remote') {
      throw StateError('Only non-empty remote file cache entries can be saved');
    }

    final dir = await cacheDirectory(subdirectory);
    final normalizedExtension = extension.replaceFirst(RegExp(r'^\.'), '');
    final filePath = path_lib.join(dir.path, '$cacheKey.$normalizedExtension');
    await File(filePath).writeAsBytes(bytes, flush: true);
    await _putEntry(
      cacheKey: cacheKey,
      kind: kind,
      purpose: purpose,
      request: request,
      filePath: filePath,
      contentType: contentType,
      byteLength: bytes.length,
      source: source,
      articleId: articleId,
    );
    return filePath;
  }

  static Future<void> touch(String cacheKey) async {
    final db = await DatabaseService.database;
    await db.update(
      'api_cache_entries',
      {'last_used_at': DateTime.now().toIso8601String()},
      where: 'cache_key = ?',
      whereArgs: [cacheKey],
    );
  }

  static Future<void> attachArticleRef({
    required int? articleId,
    required String cacheKey,
    required String purpose,
  }) async {
    if (articleId == null) {
      return;
    }
    final now = DateTime.now().toIso8601String();
    final db = await DatabaseService.database;
    await db.insert(
      'api_cache_article_refs',
      {
        'article_id': articleId,
        'cache_key': cacheKey,
        'purpose': purpose,
        'created_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Future<void> attachExistingJsonCache({
    required String namespace,
    required String purpose,
    required Map<String, dynamic> request,
    required int articleId,
  }) async {
    final cacheKey = await keyForJson(namespace, request);
    final entry = await getEntry(cacheKey);
    if (entry == null) {
      return;
    }
    await attachArticleRef(
      articleId: articleId,
      cacheKey: cacheKey,
      purpose: purpose,
    );
  }

  static Future<void> deleteArticleRefsAndUnusedFiles(int articleId) async {
    final db = await DatabaseService.database;
    final rows = await db.query(
      'api_cache_article_refs',
      columns: ['cache_key'],
      where: 'article_id = ?',
      whereArgs: [articleId],
    );
    final keys = rows
        .map((row) => row['cache_key']?.toString() ?? '')
        .where((key) => key.isNotEmpty)
        .toSet();
    await db.delete(
      'api_cache_article_refs',
      where: 'article_id = ?',
      whereArgs: [articleId],
    );

    for (final key in keys) {
      final refCount = Sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COUNT(*) FROM api_cache_article_refs WHERE cache_key = ?',
              [key],
            ),
          ) ??
          0;
      if (refCount > 0) {
        continue;
      }
      final entry = await getEntry(key);
      final filePath = entry?.filePath;
      await db.delete(
        'api_cache_entries',
        where: 'cache_key = ?',
        whereArgs: [key],
      );
      if (filePath != null && filePath.isNotEmpty) {
        try {
          final file = File(filePath);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {
          // Best-effort cleanup.
        }
      }
    }
  }

  static Future<void> deleteArticleRefsAndUnusedFilesForPurposes(
    int articleId, {
    required Set<String> purposes,
  }) async {
    if (purposes.isEmpty) {
      return;
    }
    final db = await DatabaseService.database;
    final placeholders = List.filled(purposes.length, '?').join(',');
    final rows = await db.query(
      'api_cache_article_refs',
      columns: ['cache_key'],
      where: 'article_id = ? AND purpose IN ($placeholders)',
      whereArgs: [articleId, ...purposes],
    );
    final keys = rows
        .map((row) => row['cache_key']?.toString() ?? '')
        .where((key) => key.isNotEmpty)
        .toSet();
    if (keys.isEmpty) {
      return;
    }

    await db.delete(
      'api_cache_article_refs',
      where: 'article_id = ? AND purpose IN ($placeholders)',
      whereArgs: [articleId, ...purposes],
    );

    for (final key in keys) {
      final refCount = Sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COUNT(*) FROM api_cache_article_refs WHERE cache_key = ?',
              [key],
            ),
          ) ??
          0;
      if (refCount > 0) {
        continue;
      }
      final entry = await getEntry(key);
      final filePath = entry?.filePath;
      await db.delete(
        'api_cache_entries',
        where: 'cache_key = ?',
        whereArgs: [key],
      );
      if (filePath != null && filePath.isNotEmpty) {
        try {
          final file = File(filePath);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {
          // Best-effort cleanup.
        }
      }
    }
  }

  static Future<void> deleteEntriesByKeys(Set<String> cacheKeys) async {
    final keys = cacheKeys
        .map((key) => key.trim())
        .where((key) => key.isNotEmpty)
        .toSet();
    if (keys.isEmpty) {
      return;
    }

    final db = await DatabaseService.database;
    for (final key in keys) {
      final rows = await db.query(
        'api_cache_entries',
        columns: ['file_path'],
        where: 'cache_key = ?',
        whereArgs: [key],
        limit: 1,
      );
      final filePath =
          rows.isEmpty ? null : rows.first['file_path']?.toString();
      await db.delete(
        'api_cache_article_refs',
        where: 'cache_key = ?',
        whereArgs: [key],
      );
      await db.delete(
        'api_cache_entries',
        where: 'cache_key = ?',
        whereArgs: [key],
      );
      if (filePath != null && filePath.isNotEmpty) {
        try {
          final file = File(filePath);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {
          // Best-effort cache cleanup.
        }
      }
    }
  }

  static Future<String> saveLatestSentenceRecording({
    required int articleId,
    required int sentenceIndex,
    required String sentence,
    required List<int> audioBytes,
    required String recognizedText,
    required String resultJson,
  }) async {
    if (audioBytes.isEmpty) {
      return '';
    }

    final audioHash = await hashBytes(audioBytes);
    final dir = await cacheDirectory(
      path_lib.join('recordings', 'article_$articleId'),
    );
    final recordingPath =
        path_lib.join(dir.path, 'sentence_${sentenceIndex}_$audioHash.wav');
    final db = await DatabaseService.database;
    final previousRows = await db.query(
      'latest_sentence_recordings',
      where: 'article_id = ? AND sentence_index = ?',
      whereArgs: [articleId, sentenceIndex],
      limit: 1,
    );
    final previousPath = previousRows.isEmpty
        ? ''
        : previousRows.first['recording_path']?.toString() ?? '';
    final createdAt = previousRows.isEmpty
        ? DateTime.now()
        : DateTime.parse(previousRows.first['created_at'] as String);
    final now = DateTime.now();

    await File(recordingPath).writeAsBytes(audioBytes, flush: true);
    await db.insert(
      'latest_sentence_recordings',
      {
        'article_id': articleId,
        'sentence_index': sentenceIndex,
        'sentence': sentence,
        'recording_path': recordingPath,
        'audio_hash': audioHash,
        'recognized_text': recognizedText,
        'result_json': resultJson,
        'created_at': createdAt.toIso8601String(),
        'updated_at': now.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    if (previousPath.isNotEmpty && previousPath != recordingPath) {
      try {
        final previousFile = File(previousPath);
        if (await previousFile.exists()) {
          await previousFile.delete();
        }
      } catch (_) {
        // The new recording is already saved; stale-file cleanup is best effort.
      }
    }
    return recordingPath;
  }

  static Future<CachedSentenceRecording?> getLatestSentenceRecording({
    required int articleId,
    required int sentenceIndex,
  }) async {
    final db = await DatabaseService.database;
    final rows = await db.query(
      'latest_sentence_recordings',
      where: 'article_id = ? AND sentence_index = ?',
      whereArgs: [articleId, sentenceIndex],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }

    final recording = CachedSentenceRecording.fromMap(rows.first);
    if (!await File(recording.recordingPath).exists()) {
      await db.delete(
        'latest_sentence_recordings',
        where: 'article_id = ? AND sentence_index = ?',
        whereArgs: [articleId, sentenceIndex],
      );
      return null;
    }
    return recording;
  }

  static Future<Directory> cacheDirectory(String subdirectory) async {
    final dir = Directory(
      path_lib.join(
        await DatabaseService.runtimeDataRoot,
        'tomato_api_cache',
        subdirectory,
      ),
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<String> migrateLegacyCacheFileIfNeeded(
    String filePath,
  ) async {
    final trimmed = filePath.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }

    final databaseCacheRoot = path_lib.join(
      await DatabaseService.databaseDirectory,
      'tomato_api_cache',
    );
    final runtimeCacheRoot = path_lib.join(
      await DatabaseService.runtimeDataRoot,
      'tomato_api_cache',
    );
    if (_sameOrWithin(runtimeCacheRoot, trimmed) ||
        !_sameOrWithin(databaseCacheRoot, trimmed)) {
      return trimmed;
    }

    final relativePath = path_lib.relative(trimmed, from: databaseCacheRoot);
    final targetPath = path_lib.join(runtimeCacheRoot, relativePath);
    final source = File(trimmed);
    final target = File(targetPath);
    if (!await source.exists()) {
      return await target.exists() ? target.path : trimmed;
    }

    await target.parent.create(recursive: true);
    if (!await target.exists()) {
      await source.copy(target.path);
    }
    return target.path;
  }

  static bool _sameOrWithin(String parent, String child) {
    final normalizedParent =
        path_lib.normalize(path_lib.absolute(parent)).toLowerCase();
    final normalizedChild =
        path_lib.normalize(path_lib.absolute(child)).toLowerCase();
    return path_lib.equals(normalizedParent, normalizedChild) ||
        path_lib.isWithin(normalizedParent, normalizedChild);
  }

  static Future<void> _putEntry({
    required String cacheKey,
    required String kind,
    required String purpose,
    required Map<String, dynamic> request,
    String? textValue,
    String? jsonValue,
    String? filePath,
    String? contentType,
    int? byteLength,
    required String source,
    int? articleId,
  }) async {
    final db = await DatabaseService.database;
    final now = DateTime.now();
    final existing = await db.query(
      'api_cache_entries',
      columns: ['created_at'],
      where: 'cache_key = ?',
      whereArgs: [cacheKey],
      limit: 1,
    );
    final createdAt = existing.isEmpty
        ? now
        : DateTime.parse(existing.first['created_at'] as String);
    await db.insert(
      'api_cache_entries',
      {
        'cache_key': cacheKey,
        'kind': kind,
        'purpose': purpose,
        'request_json': canonicalJson(request),
        'text_value': textValue,
        'json_value': jsonValue,
        'file_path': filePath,
        'content_type': contentType,
        'byte_length': byteLength,
        'source': source,
        'created_at': createdAt.toIso8601String(),
        'updated_at': now.toIso8601String(),
        'last_used_at': now.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await attachArticleRef(
      articleId: articleId,
      cacheKey: cacheKey,
      purpose: purpose,
    );
  }

  static String _safeNamespace(String namespace) =>
      namespace.replaceAll(RegExp(r'[^A-Za-z0-9_]+'), '_').toLowerCase();

  static Object? _canonicalize(Object? value) {
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    if (value is Map) {
      final sortedKeys = value.keys.map((key) => key.toString()).toList()
        ..sort();
      return {
        for (final key in sortedKeys) key: _canonicalize(value[key]),
      };
    }
    if (value is Iterable) {
      return value.map(_canonicalize).toList(growable: false);
    }
    return value.toString();
  }
}
