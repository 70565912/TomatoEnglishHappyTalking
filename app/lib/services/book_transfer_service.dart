import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as path_lib;
import 'package:sqflite/sqflite.dart';

import '../data/models/article_model.dart';
import '../data/models/article_song_model.dart';
import 'api_cache_service.dart';
import 'database_service.dart';
import 'external_song_import_service.dart';

class BookTransferExportResult {
  const BookTransferExportResult({
    required this.seriesId,
    required this.title,
    required this.outputPath,
    required this.articleCount,
    required this.assetCount,
    required this.warnings,
  });

  final int seriesId;
  final String title;
  final String outputPath;
  final int articleCount;
  final int assetCount;
  final List<String> warnings;

  Map<String, dynamic> toJson() => {
        'cancelled': false,
        'seriesId': seriesId,
        'title': title,
        'outputPath': outputPath,
        'articleCount': articleCount,
        'assetCount': assetCount,
        'warnings': warnings,
      };
}

class BookTransferImportResult {
  const BookTransferImportResult({
    required this.seriesId,
    required this.title,
    required this.articleIds,
    required this.assetCount,
    required this.warnings,
  });

  final int seriesId;
  final String title;
  final List<int> articleIds;
  final int assetCount;
  final List<String> warnings;

  Map<String, dynamic> toJson() => {
        'cancelled': false,
        'seriesId': seriesId,
        'title': title,
        'articleIds': articleIds,
        'articleCount': articleIds.length,
        'assetCount': assetCount,
        'warnings': warnings,
      };
}

class BookTransferService {
  BookTransferService._();

  static const schemaVersion = 1;
  static const packageApp = 'tomato_english_happy_talking';

  static const _jsonEncoder = JsonEncoder.withIndent('  ');
  static const _assetPathKeys = <String>{
    'audioPath',
    'timelinePath',
    'metadataPath',
    'imagePath',
    'filePath',
    'recordingPath',
  };

  static Future<BookTransferExportResult> exportSeries({
    required int seriesId,
    required String outputDirectory,
  }) async {
    final outputDir = Directory(outputDirectory.trim());
    if (outputDirectory.trim().isEmpty || !await outputDir.exists()) {
      throw const FormatException('请选择有效的书籍导出目录');
    }

    final db = await DatabaseService.database;
    final seriesRows = await db.query(
      'story_series',
      where: 'id = ?',
      whereArgs: [seriesId],
      limit: 1,
    );
    if (seriesRows.isEmpty) {
      throw FormatException('书籍不存在（id=$seriesId）');
    }

    final warnings = <String>[];
    final assets = _BookTransferAssetCollector(warnings);
    final seriesRow = _mutableRow(seriesRows.first);
    await _replaceFilePathWithAssetRef(
      seriesRow,
      'cover_image_path',
      assets,
      label: 'book cover',
    );

    final chapterRows = (await db.query(
      'story_chapters',
      where: 'series_id = ?',
      whereArgs: [seriesId],
      orderBy: 'chapter_order ASC',
    ))
        .map(_mutableRow)
        .toList(growable: false);
    final articleIds = chapterRows
        .map((row) => (row['article_id'] as num?)?.toInt())
        .whereType<int>()
        .toList(growable: false);

    final articleRows =
        await _queryRowsForValues(db, 'articles', 'id', articleIds);
    final articlesById = <int, Article>{};
    for (final row in articleRows) {
      final article = Article.fromMap(row);
      final id = article.id;
      if (id != null) {
        articlesById[id] = article;
      }
    }

    final translationRows = await _queryRowsForValues(
      db,
      'article_sentence_translations',
      'article_id',
      articleIds,
      orderBy: 'article_id ASC, sentence_index ASC',
    );
    final learningRows = await _queryRowsForValues(
      db,
      'learning_records',
      'article_id',
      articleIds,
      orderBy: 'article_id ASC, created_at ASC',
    );
    final chatGuideRows = await _queryRowsForValues(
      db,
      'article_chat_guides',
      'article_id',
      articleIds,
      orderBy: 'article_id ASC, purpose ASC',
    );
    final pictureRows = await _queryRowsForValues(
      db,
      'picture_book_pages',
      'article_id',
      articleIds,
      orderBy: 'article_id ASC, page_index ASC',
    );
    for (final row in pictureRows) {
      await _replaceFilePathWithAssetRef(
        row,
        'image_path',
        assets,
        label: 'picture page image',
      );
    }

    final recordingRows = await _queryRowsForValues(
      db,
      'latest_sentence_recordings',
      'article_id',
      articleIds,
      orderBy: 'article_id ASC, sentence_index ASC',
    );
    for (final row in recordingRows) {
      await _replaceFilePathWithAssetRef(
        row,
        'recording_path',
        assets,
        label: 'sentence recording',
      );
    }

    final cacheRefRows = await _queryRowsForValues(
      db,
      'api_cache_article_refs',
      'article_id',
      articleIds,
      orderBy: 'article_id ASC, purpose ASC',
    );
    final cacheKeys = <String>{
      for (final row in cacheRefRows) row['cache_key']?.toString() ?? '',
      for (final row in pictureRows) row['image_cache_key']?.toString() ?? '',
    }..removeWhere((key) => key.trim().isEmpty);
    final rawCacheRows = await _queryRowsForValues(
      db,
      'api_cache_entries',
      'cache_key',
      cacheKeys.toList(growable: false),
      orderBy: 'purpose ASC, created_at ASC',
    );
    final cacheRows = <Map<String, dynamic>>[];
    for (final row in rawCacheRows) {
      if ((row['source'] ?? '').toString() != 'remote') {
        warnings.add('Skipped non-remote cache entry ${row['cache_key']}');
        continue;
      }
      await _replaceFilePathWithAssetRef(
        row,
        'file_path',
        assets,
        label: 'cache file',
      );
      row['json_value'] = await _rewriteJsonPathsForExport(
        row['json_value']?.toString(),
        assets,
        label: 'cache metadata',
      );
      cacheRows.add(row);
    }

    final externalSongs = <Map<String, dynamic>>[];
    for (final articleId in articleIds) {
      final article = articlesById[articleId];
      if (article == null) {
        continue;
      }
      final versions = await ExternalSongImportService.loadVersions(article);
      if (versions.isEmpty) {
        continue;
      }
      final versionJson = <Map<String, dynamic>>[];
      for (final version in versions) {
        final json = version.toJson();
        await _replaceJsonFilePathWithAssetRef(
          json,
          'audioPath',
          assets,
          label: 'external song audio',
        );
        await _replaceJsonFilePathWithAssetRef(
          json,
          'timelinePath',
          assets,
          label: 'external song timeline',
        );
        versionJson.add(json);
      }
      externalSongs.add({
        'articleId': articleId,
        'versions': versionJson,
      });
    }

    final archive = Archive();
    final manifest = {
      'app': packageApp,
      'schemaVersion': schemaVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'seriesId': seriesId,
      'title': seriesRow['title'],
      'articleCount': articleRows.length,
      'assetCount': assets.entries.length,
      'warnings': warnings,
      'assets': [
        for (final entry in assets.entries)
          {
            'path': entry.archivePath,
            'sha256': entry.hash,
            'byteLength': entry.bytes.length,
          },
      ],
    };
    _addJsonFile(archive, 'manifest.json', manifest);
    _addJsonFile(archive, 'data/series.json', seriesRow);
    _addJsonFile(archive, 'data/articles.json', articleRows);
    _addJsonFile(archive, 'data/story_chapters.json', chapterRows);
    _addJsonFile(
      archive,
      'data/article_sentence_translations.json',
      translationRows,
    );
    _addJsonFile(archive, 'data/learning_records.json', learningRows);
    _addJsonFile(archive, 'data/article_chat_guides.json', chatGuideRows);
    _addJsonFile(archive, 'data/picture_book_pages.json', pictureRows);
    _addJsonFile(
      archive,
      'data/latest_sentence_recordings.json',
      recordingRows,
    );
    _addJsonFile(archive, 'data/api_cache_entries.json', cacheRows);
    _addJsonFile(archive, 'data/api_cache_article_refs.json', cacheRefRows);
    _addJsonFile(archive, 'data/external_songs.json', externalSongs);
    for (final asset in assets.entries) {
      archive.addFile(
        ArchiveFile(asset.archivePath, asset.bytes.length, asset.bytes),
      );
    }

    final outputPath = await _uniqueExportPath(
      outputDir.path,
      (seriesRow['title'] ?? 'book').toString(),
    );
    final encoded = ZipEncoder().encode(archive);
    await File(outputPath).writeAsBytes(encoded, flush: true);

    return BookTransferExportResult(
      seriesId: seriesId,
      title: (seriesRow['title'] ?? '').toString(),
      outputPath: outputPath,
      articleCount: articleRows.length,
      assetCount: assets.entries.length,
      warnings: List.unmodifiable(warnings),
    );
  }

  static Future<BookTransferImportResult> importSeriesArchive({
    required String filePath,
  }) async {
    final sourceFile = File(filePath.trim());
    if (filePath.trim().isEmpty || !await sourceFile.exists()) {
      throw const FormatException('请选择有效的书籍导入 zip 文件');
    }

    final reader = _BookTransferArchiveReader(
      ZipDecoder().decodeBytes(await sourceFile.readAsBytes()),
    );
    final manifest = reader.readJsonMap('manifest.json');
    if (manifest['app'] != packageApp) {
      throw const FormatException('这不是 Tomato English 的书籍迁移包');
    }
    if ((manifest['schemaVersion'] as num?)?.toInt() != schemaVersion) {
      throw FormatException('不支持的书籍迁移包版本：${manifest['schemaVersion']}');
    }

    final seriesRow = reader.readJsonMap('data/series.json');
    final articleRows = reader.readJsonList('data/articles.json');
    final chapterRows = reader.readJsonList('data/story_chapters.json');
    final translationRows =
        reader.readJsonList('data/article_sentence_translations.json');
    final learningRows = reader.readJsonList('data/learning_records.json');
    final chatGuideRows = reader.readJsonList('data/article_chat_guides.json');
    final pictureRows = reader.readJsonList('data/picture_book_pages.json');
    final recordingRows =
        reader.readJsonList('data/latest_sentence_recordings.json');
    final cacheRows = reader.readJsonList('data/api_cache_entries.json');
    final cacheRefRows =
        reader.readJsonList('data/api_cache_article_refs.json');
    final externalSongs = reader.readJsonList('data/external_songs.json');

    final runtimeRoot = await DatabaseService.runtimeDataRoot;
    final importRoot = Directory(path_lib.join(
      runtimeRoot,
      'book-transfer-assets',
      'import_${DateTime.now().millisecondsSinceEpoch}',
    ));
    final warnings = <String>[
      for (final item in (manifest['warnings'] is List
          ? manifest['warnings'] as List
          : const []))
        item.toString(),
    ];
    var copiedAssetCount = 0;
    var importedSeriesId = 0;
    var importedTitle = '';
    final importedArticleIds = <int>[];

    try {
      final db = await DatabaseService.database;
      await db.transaction((txn) async {
        final originalSeriesId = (seriesRow['id'] as num?)?.toInt();
        final title = await _resolveImportedSeriesTitle(
          txn,
          (seriesRow['title'] ?? 'Imported Book').toString(),
        );
        importedTitle = title;
        final now = DateTime.now().toIso8601String();
        final importedSeriesRow = Map<String, Object?>.from(seriesRow)
          ..remove('id')
          ..['title'] = title
          ..['updated_at'] = now;
        importedSeriesRow['cover_image_path'] = await _restoreAssetRef(
          reader: reader,
          value: importedSeriesRow['cover_image_path'],
          targetDirectory: importRoot,
          counter: () => copiedAssetCount += 1,
        );
        importedSeriesId = await txn.insert('story_series', importedSeriesRow);

        final articleIdMap = <int, int>{};
        for (final rawRow in articleRows) {
          final oldArticleId = (rawRow['id'] as num?)?.toInt();
          final row = Map<String, Object?>.from(rawRow)..remove('id');
          final newArticleId = await txn.insert('articles', row);
          if (oldArticleId != null) {
            articleIdMap[oldArticleId] = newArticleId;
          }
          importedArticleIds.add(newArticleId);
        }

        int? mappedArticleId(Object? oldValue) {
          final oldId = (oldValue as num?)?.toInt();
          if (oldId == null) {
            return null;
          }
          return articleIdMap[oldId];
        }

        for (final rawRow in chapterRows) {
          final articleId = mappedArticleId(rawRow['article_id']);
          if (articleId == null) {
            warnings.add('Skipped chapter with missing article mapping');
            continue;
          }
          final row = Map<String, Object?>.from(rawRow)
            ..remove('id')
            ..['series_id'] = importedSeriesId
            ..['article_id'] = articleId;
          await txn.insert('story_chapters', row);
        }

        for (final rawRow in translationRows) {
          final articleId = mappedArticleId(rawRow['article_id']);
          if (articleId == null) continue;
          final row = Map<String, Object?>.from(rawRow)
            ..['article_id'] = articleId;
          await txn.insert(
            'article_sentence_translations',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }

        for (final rawRow in learningRows) {
          final articleId = mappedArticleId(rawRow['article_id']);
          if (articleId == null) continue;
          final row = Map<String, Object?>.from(rawRow)
            ..remove('id')
            ..['article_id'] = articleId;
          await txn.insert('learning_records', row);
        }

        for (final rawRow in chatGuideRows) {
          final articleId = mappedArticleId(rawRow['article_id']);
          if (articleId == null) continue;
          final row = Map<String, Object?>.from(rawRow)
            ..['article_id'] = articleId;
          await txn.insert(
            'article_chat_guides',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }

        for (final rawRow in pictureRows) {
          final articleId = mappedArticleId(rawRow['article_id']);
          if (articleId == null) continue;
          final row = Map<String, Object?>.from(rawRow)
            ..remove('id')
            ..['article_id'] = articleId
            ..['series_id'] = importedSeriesId;
          row['image_path'] = await _restoreAssetRef(
            reader: reader,
            value: row['image_path'],
            targetDirectory: importRoot,
            counter: () => copiedAssetCount += 1,
          );
          await txn.insert(
            'picture_book_pages',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }

        for (final rawRow in recordingRows) {
          final articleId = mappedArticleId(rawRow['article_id']);
          if (articleId == null) continue;
          final targetDirectory = await ApiCacheService.cacheDirectory(
            path_lib.join('recordings', 'article_$articleId'),
          );
          final row = Map<String, Object?>.from(rawRow)
            ..['article_id'] = articleId;
          row['recording_path'] = await _restoreAssetRef(
            reader: reader,
            value: row['recording_path'],
            targetDirectory: targetDirectory,
            counter: () => copiedAssetCount += 1,
          );
          await txn.insert(
            'latest_sentence_recordings',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }

        for (final rawRow in cacheRows) {
          final row = Map<String, Object?>.from(rawRow);
          row['file_path'] = await _restoreAssetRef(
            reader: reader,
            value: row['file_path'],
            targetDirectory: importRoot,
            counter: () => copiedAssetCount += 1,
          );
          row['request_json'] = _rewriteJsonIds(
            row['request_json']?.toString(),
            articleIdMap,
            originalSeriesId,
            importedSeriesId,
          );
          row['json_value'] = await _rewriteJsonForImport(
            row['json_value']?.toString(),
            reader,
            importRoot,
            articleIdMap,
            originalSeriesId,
            importedSeriesId,
            counter: () => copiedAssetCount += 1,
          );
          await txn.insert(
            'api_cache_entries',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }

        for (final rawRow in cacheRefRows) {
          final articleId = mappedArticleId(rawRow['article_id']);
          if (articleId == null) continue;
          final row = Map<String, Object?>.from(rawRow)
            ..['article_id'] = articleId;
          await txn.insert(
            'api_cache_article_refs',
            row,
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }

        for (final rawSong in externalSongs) {
          final oldArticleId = (rawSong['articleId'] as num?)?.toInt();
          final articleId =
              oldArticleId == null ? null : articleIdMap[oldArticleId];
          if (articleId == null) {
            continue;
          }
          final articleRow = articleRows.firstWhere(
            (row) => (row['id'] as num?)?.toInt() == oldArticleId,
            orElse: () => const <String, dynamic>{},
          );
          if (articleRow.isEmpty) {
            continue;
          }
          final article = Article.fromMap({
            ...articleRow,
            'id': articleId,
          });
          final versions = <ArticleSongVersion>[];
          final rawVersions = rawSong['versions'];
          if (rawVersions is! List) {
            continue;
          }
          final externalDirectory = Directory(path_lib.join(
            runtimeRoot,
            'song-assets',
            ExternalSongImportService.source,
            'article_$articleId',
          ));
          await externalDirectory.create(recursive: true);
          for (final rawVersion in rawVersions) {
            if (rawVersion is! Map) {
              continue;
            }
            final versionJson =
                rawVersion.map((key, value) => MapEntry(key.toString(), value));
            versionJson['audioPath'] = await _restoreAssetRef(
              reader: reader,
              value: versionJson['audioPath'],
              targetDirectory: externalDirectory,
              counter: () => copiedAssetCount += 1,
            );
            versionJson['timelinePath'] = await _restoreAssetRef(
              reader: reader,
              value: versionJson['timelinePath'],
              targetDirectory: externalDirectory,
              counter: () => copiedAssetCount += 1,
            );
            final version = ArticleSongVersion.fromJson(versionJson);
            if (version != null && version.audioPath.trim().isNotEmpty) {
              versions.add(version);
            }
          }
          await ExternalSongImportService.saveVersions(
            article: article,
            versions: versions,
          );
        }
      });
    } catch (_) {
      if (await importRoot.exists()) {
        await importRoot.delete(recursive: true);
      }
      rethrow;
    }

    return BookTransferImportResult(
      seriesId: importedSeriesId,
      title: importedTitle,
      articleIds: List.unmodifiable(importedArticleIds),
      assetCount: copiedAssetCount,
      warnings: List.unmodifiable(warnings),
    );
  }

  static Future<List<Map<String, dynamic>>> _queryRowsForValues(
    Database db,
    String table,
    String column,
    Iterable<Object?> values, {
    String? orderBy,
  }) async {
    final cleanValues = values
        .where((value) => value != null && value.toString().trim().isNotEmpty)
        .toList(growable: false);
    if (cleanValues.isEmpty) {
      return <Map<String, dynamic>>[];
    }
    final placeholders = List.filled(cleanValues.length, '?').join(',');
    final maps = await db.query(
      table,
      where: '$column IN ($placeholders)',
      whereArgs: cleanValues,
      orderBy: orderBy,
    );
    return maps.map(_mutableRow).toList(growable: false);
  }

  static Future<String> _resolveImportedSeriesTitle(
    Transaction txn,
    String requestedTitle,
  ) async {
    final baseTitle =
        requestedTitle.trim().isEmpty ? 'Imported Book' : requestedTitle.trim();
    final existingRows = await txn.query(
      'story_series',
      columns: ['title'],
    );
    final existingTitles = existingRows
        .map((row) => row['title']?.toString().trim().toLowerCase() ?? '')
        .where((title) => title.isNotEmpty)
        .toSet();
    if (!existingTitles.contains(baseTitle.toLowerCase())) {
      return baseTitle;
    }
    final firstCopy = '$baseTitle（导入）';
    if (!existingTitles.contains(firstCopy.toLowerCase())) {
      return firstCopy;
    }
    var index = 2;
    while (true) {
      final candidate = '$baseTitle（导入 $index）';
      if (!existingTitles.contains(candidate.toLowerCase())) {
        return candidate;
      }
      index += 1;
    }
  }

  static Future<String?> _restoreAssetRef({
    required _BookTransferArchiveReader reader,
    required Object? value,
    required Directory targetDirectory,
    required void Function() counter,
  }) async {
    final ref = value?.toString().trim() ?? '';
    if (ref.isEmpty) {
      return null;
    }
    if (!_isArchiveAssetRef(ref)) {
      throw FormatException('Invalid asset reference in book package: $ref');
    }
    final bytes = reader.readFileBytes(ref);
    await targetDirectory.create(recursive: true);
    final fileName = _safeAssetFileName(path_lib.basename(ref));
    final target = File(path_lib.join(targetDirectory.path, fileName));
    if (!await target.exists()) {
      await target.writeAsBytes(bytes, flush: true);
      counter();
    }
    return target.path;
  }

  static Future<void> _replaceFilePathWithAssetRef(
    Map<String, dynamic> row,
    String key,
    _BookTransferAssetCollector assets, {
    required String label,
  }) async {
    final ref = await assets.addPath(row[key]?.toString(), label: label);
    row[key] = ref;
  }

  static Future<void> _replaceJsonFilePathWithAssetRef(
    Map<String, dynamic> row,
    String key,
    _BookTransferAssetCollector assets, {
    required String label,
  }) async {
    if (!row.containsKey(key)) {
      return;
    }
    row[key] = await assets.addPath(row[key]?.toString(), label: label);
  }

  static Future<String?> _rewriteJsonPathsForExport(
    String? text,
    _BookTransferAssetCollector assets, {
    required String label,
  }) async {
    final decoded = _decodeJson(text);
    if (decoded == null) {
      return text;
    }
    final rewritten = await _rewriteValuePathsForExport(decoded, assets, label);
    return jsonEncode(rewritten);
  }

  static Future<Object?> _rewriteValuePathsForExport(
    Object? value,
    _BookTransferAssetCollector assets,
    String label,
  ) async {
    if (value is List) {
      return [
        for (final item in value)
          await _rewriteValuePathsForExport(item, assets, label),
      ];
    }
    if (value is Map) {
      final next = <String, dynamic>{};
      for (final entry in value.entries) {
        final key = entry.key.toString();
        if (_assetPathKeys.contains(key)) {
          next[key] =
              await assets.addPath(entry.value?.toString(), label: label);
        } else {
          next[key] = await _rewriteValuePathsForExport(
            entry.value,
            assets,
            label,
          );
        }
      }
      return next;
    }
    return value;
  }

  static Future<String?> _rewriteJsonForImport(
    String? text,
    _BookTransferArchiveReader reader,
    Directory targetDirectory,
    Map<int, int> articleIdMap,
    int? oldSeriesId,
    int newSeriesId, {
    required void Function() counter,
  }) async {
    final decoded = _decodeJson(text);
    if (decoded == null) {
      return text;
    }
    final restored = await _rewriteValueForImport(
      decoded,
      reader,
      targetDirectory,
      articleIdMap,
      oldSeriesId,
      newSeriesId,
      counter: counter,
    );
    return jsonEncode(restored);
  }

  static Future<Object?> _rewriteValueForImport(
    Object? value,
    _BookTransferArchiveReader reader,
    Directory targetDirectory,
    Map<int, int> articleIdMap,
    int? oldSeriesId,
    int newSeriesId, {
    required void Function() counter,
  }) async {
    if (value is List) {
      return [
        for (final item in value)
          await _rewriteValueForImport(
            item,
            reader,
            targetDirectory,
            articleIdMap,
            oldSeriesId,
            newSeriesId,
            counter: counter,
          ),
      ];
    }
    if (value is Map) {
      final next = <String, dynamic>{};
      for (final entry in value.entries) {
        final key = entry.key.toString();
        final entryValue = entry.value;
        if (_assetPathKeys.contains(key)) {
          next[key] = await _restoreAssetRef(
            reader: reader,
            value: entryValue,
            targetDirectory: targetDirectory,
            counter: counter,
          );
        } else if (key == 'articleId' || key == 'article_id') {
          next[key] = _mappedId(entryValue, articleIdMap) ?? entryValue;
        } else if (key == 'seriesId' || key == 'series_id') {
          final oldId = (entryValue as num?)?.toInt();
          next[key] =
              oldId == null || oldId == oldSeriesId ? newSeriesId : entryValue;
        } else {
          next[key] = await _rewriteValueForImport(
            entryValue,
            reader,
            targetDirectory,
            articleIdMap,
            oldSeriesId,
            newSeriesId,
            counter: counter,
          );
        }
      }
      return next;
    }
    return value;
  }

  static String? _rewriteJsonIds(
    String? text,
    Map<int, int> articleIdMap,
    int? oldSeriesId,
    int newSeriesId,
  ) {
    final decoded = _decodeJson(text);
    if (decoded == null) {
      return text;
    }
    return jsonEncode(
      _rewriteValueIds(decoded, articleIdMap, oldSeriesId, newSeriesId),
    );
  }

  static Object? _rewriteValueIds(
    Object? value,
    Map<int, int> articleIdMap,
    int? oldSeriesId,
    int newSeriesId,
  ) {
    if (value is List) {
      return [
        for (final item in value)
          _rewriteValueIds(item, articleIdMap, oldSeriesId, newSeriesId),
      ];
    }
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): () {
            final key = entry.key.toString();
            final entryValue = entry.value;
            if (key == 'articleId' || key == 'article_id') {
              return _mappedId(entryValue, articleIdMap) ?? entryValue;
            }
            if (key == 'seriesId' || key == 'series_id') {
              final oldId = (entryValue as num?)?.toInt();
              return oldId == null || oldId == oldSeriesId
                  ? newSeriesId
                  : entryValue;
            }
            return _rewriteValueIds(
              entryValue,
              articleIdMap,
              oldSeriesId,
              newSeriesId,
            );
          }(),
      };
    }
    return value;
  }

  static int? _mappedId(Object? value, Map<int, int> idMap) {
    final id = (value as num?)?.toInt();
    return id == null ? null : idMap[id];
  }

  static Object? _decodeJson(String? text) {
    final raw = text?.trim() ?? '';
    if (raw.isEmpty) {
      return null;
    }
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  static void _addJsonFile(Archive archive, String name, Object? value) {
    archive.addFile(ArchiveFile.string(name, _jsonEncoder.convert(value)));
  }

  static Map<String, dynamic> _mutableRow(Map<String, Object?> row) =>
      row.map((key, value) => MapEntry(key, value));

  static Future<String> _uniqueExportPath(
    String outputDirectory,
    String title,
  ) async {
    final safeTitle = _safeFileName(title.trim().isEmpty ? 'book' : title);
    var path = path_lib.join(outputDirectory, '$safeTitle.zip');
    var index = 2;
    while (await File(path).exists()) {
      path = path_lib.join(outputDirectory, '$safeTitle ($index).zip');
      index += 1;
    }
    return path;
  }

  static String _safeFileName(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) {
      return 'book';
    }
    return cleaned.length > 80 ? cleaned.substring(0, 80).trim() : cleaned;
  }

  static String _safeAssetFileName(String value) {
    final cleaned = _safeFileName(value);
    return cleaned.isEmpty ? 'asset.bin' : cleaned;
  }

  static bool _isArchiveAssetRef(String value) {
    final normalized = value.replaceAll('\\', '/');
    return normalized.startsWith('assets/') &&
        !normalized.contains('/../') &&
        !normalized.startsWith('../') &&
        !path_lib.isAbsolute(normalized);
  }
}

class _BookTransferAsset {
  const _BookTransferAsset({
    required this.archivePath,
    required this.hash,
    required this.bytes,
  });

  final String archivePath;
  final String hash;
  final Uint8List bytes;
}

class _BookTransferAssetCollector {
  _BookTransferAssetCollector(this.warnings);

  final List<String> warnings;
  final Map<String, _BookTransferAsset> _byHash =
      <String, _BookTransferAsset>{};
  final Map<String, String> _pathToRef = <String, String>{};

  List<_BookTransferAsset> get entries =>
      List.unmodifiable(_byHash.values.toList(growable: false));

  Future<String?> addPath(String? rawPath, {required String label}) async {
    final filePath = rawPath?.trim() ?? '';
    if (filePath.isEmpty) {
      return null;
    }
    if (_pathToRef.containsKey(filePath)) {
      return _pathToRef[filePath];
    }
    final file = File(filePath);
    if (!await file.exists()) {
      warnings.add(
        'Missing optional $label file: ${path_lib.basename(filePath)}',
      );
      return null;
    }
    final bytes = Uint8List.fromList(await file.readAsBytes());
    final hash = await ApiCacheService.hashBytes(bytes);
    final extension = path_lib.extension(filePath);
    final baseName = BookTransferService._safeFileName(
      path_lib.basenameWithoutExtension(filePath),
    );
    final archivePath = 'assets/${hash.substring(0, 24)}_$baseName$extension';
    final existing = _byHash[hash];
    if (existing == null) {
      _byHash[hash] = _BookTransferAsset(
        archivePath: archivePath,
        hash: hash,
        bytes: bytes,
      );
      _pathToRef[filePath] = archivePath;
      return archivePath;
    }
    _pathToRef[filePath] = existing.archivePath;
    return existing.archivePath;
  }
}

class _BookTransferArchiveReader {
  _BookTransferArchiveReader(Archive archive) {
    for (final file in archive.files) {
      final name = file.name.replaceAll('\\', '/');
      if (file.isFile && !name.contains('/../') && !name.startsWith('../')) {
        _files[name] = file;
      }
    }
  }

  final Map<String, ArchiveFile> _files = <String, ArchiveFile>{};

  Map<String, dynamic> readJsonMap(String path) {
    final decoded = _readJson(path);
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    throw FormatException('Invalid JSON object in $path');
  }

  List<Map<String, dynamic>> readJsonList(String path) {
    final decoded = _readJson(path);
    if (decoded is! List) {
      throw FormatException('Invalid JSON list in $path');
    }
    return decoded
        .whereType<Map>()
        .map((row) => row.map((key, value) => MapEntry(key.toString(), value)))
        .toList(growable: false);
  }

  Uint8List readFileBytes(String path) {
    final normalized = path.replaceAll('\\', '/');
    final file = _files[normalized];
    if (file == null) {
      throw FormatException('Missing asset in book package: $normalized');
    }
    return file.content;
  }

  Object? _readJson(String path) {
    final file = _files[path];
    if (file == null) {
      throw FormatException('Missing $path in book package');
    }
    return jsonDecode(utf8.decode(file.content));
  }
}
