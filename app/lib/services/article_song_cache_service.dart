import 'dart:convert';
import 'dart:io';

import 'package:tomato_english_happy_talking/data/models/article_song_model.dart';
import 'package:tomato_english_happy_talking/services/api_cache_service.dart';

class SongCacheEntryMatch {
  const SongCacheEntryMatch({
    required this.entry,
    required this.metadata,
    required this.version,
  });

  final ApiCacheEntry entry;
  final Map<String, dynamic> metadata;
  final ArticleSongVersion version;
}

class ArticleSongCacheService {
  static Map<String, dynamic> decodeJsonObject(String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) {
      return <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    } catch (_) {
      // Fall through to empty metadata.
    }
    return <String, dynamic>{};
  }

  static Map<String, dynamic> decodeRequest(ApiCacheEntry entry) =>
      decodeJsonObject(entry.requestJson);

  static List<ArticleSongVersion> versionsFromMetadata(
    Map<String, dynamic> metadata,
  ) {
    final rawVersions = metadata['versions'];
    if (rawVersions is! List) {
      return const [];
    }
    return rawVersions
        .map(ArticleSongVersion.fromJson)
        .whereType<ArticleSongVersion>()
        .toList(growable: false);
  }

  static Future<List<ArticleSongVersion>> loadAllCachedVersions({
    required int articleId,
    required String purpose,
  }) async {
    final entries = await ApiCacheService.getEntriesForArticlePurpose(
      articleId: articleId,
      purpose: purpose,
      limit: 100,
    );
    final versions = <ArticleSongVersion>[];
    for (final entry in entries) {
      if ((entry.jsonValue ?? '').trim().isEmpty) {
        continue;
      }
      versions.addAll(
        versionsFromMetadata(decodeJsonObject(entry.jsonValue)),
      );
    }
    return versions;
  }

  static Future<SongCacheEntryMatch?> findEntryForVersion({
    required int articleId,
    required String versionId,
    required String purpose,
  }) async {
    final normalizedVersionId = versionId.trim();
    if (normalizedVersionId.isEmpty) {
      return null;
    }
    final entries = await ApiCacheService.getEntriesForArticlePurpose(
      articleId: articleId,
      purpose: purpose,
      limit: 100,
    );
    for (final entry in entries) {
      final metadata = decodeJsonObject(entry.jsonValue);
      for (final version in versionsFromMetadata(metadata)) {
        if (version.id == normalizedVersionId) {
          return SongCacheEntryMatch(
            entry: entry,
            metadata: metadata,
            version: version,
          );
        }
      }
    }
    return null;
  }

  static Future<ApiCacheEntry?> findEntryForLyricsHash({
    required int articleId,
    required String purpose,
    required String lyricsHash,
  }) async {
    final normalizedHash = lyricsHash.trim();
    if (normalizedHash.isEmpty) {
      return null;
    }
    final entries = await ApiCacheService.getEntriesForArticlePurpose(
      articleId: articleId,
      purpose: purpose,
      limit: 100,
    );
    for (final entry in entries) {
      final request = decodeRequest(entry);
      final requestHash = (request['lyricsHash'] ?? '').toString().trim();
      if (requestHash == normalizedHash) {
        return entry;
      }
      final metadata = decodeJsonObject(entry.jsonValue);
      final metadataHash = (metadata['lyricsHash'] ?? '').toString().trim();
      if (metadataHash == normalizedHash) {
        return entry;
      }
    }
    return null;
  }

  static String? metadataPathFromEntry(
    ApiCacheEntry entry,
    Map<String, dynamic> metadata,
  ) {
    final fromMetadata = (metadata['metadataPath'] ?? '').toString().trim();
    if (fromMetadata.isNotEmpty) {
      return fromMetadata;
    }
    return null;
  }

  static Future<void> updateEntryMetadata({
    required ApiCacheEntry entry,
    required Map<String, dynamic> metadata,
    required String kind,
    required String purpose,
    required int articleId,
  }) async {
    final metadataPath = metadataPathFromEntry(entry, metadata);
    if (metadataPath != null) {
      await File(metadataPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(metadata),
        flush: true,
      );
    }
    final request = decodeRequest(entry);
    await ApiCacheService.putJson(
      cacheKey: entry.cacheKey,
      kind: kind,
      purpose: purpose,
      request: request,
      jsonValue: metadata,
      articleId: articleId,
    );
  }

  static Future<void> removeEntryAndMetadata(ApiCacheEntry entry) async {
    final metadata = decodeJsonObject(entry.jsonValue);
    final metadataPath = metadataPathFromEntry(entry, metadata);
    await ApiCacheService.deleteEntriesByKeys({entry.cacheKey});
    if (metadataPath != null) {
      await _deleteFileIfExists(metadataPath);
    }
  }

  static Future<bool> removeVersionFromArticleCache({
    required int articleId,
    required String versionId,
    required String purpose,
    required String kind,
  }) async {
    final match = await findEntryForVersion(
      articleId: articleId,
      versionId: versionId,
      purpose: purpose,
    );
    if (match == null) {
      return false;
    }
    final remainingVersions = versionsFromMetadata(match.metadata)
        .where((version) => version.id != versionId)
        .toList(growable: false);
    if (remainingVersions.isEmpty) {
      await removeEntryAndMetadata(match.entry);
      return true;
    }
    var normalizedRemaining = remainingVersions;
    if (!normalizedRemaining.any((version) => version.isDefault)) {
      normalizedRemaining = [
        normalizedRemaining.first.copyWith(isDefault: true),
        ...normalizedRemaining.skip(1),
      ];
    }
    final selected = normalizedRemaining.firstWhere(
      (version) => version.isDefault,
      orElse: () => normalizedRemaining.first,
    );
    final updatedMetadata = Map<String, dynamic>.from(match.metadata)
      ..['versions'] =
          normalizedRemaining.map((version) => version.toJson()).toList()
      ..['audioPath'] = selected.audioPath
      ..['songUrl'] = selected.songUrl
      ..['downloadComplete'] = normalizedRemaining.isNotEmpty;
    await updateEntryMetadata(
      entry: match.entry,
      metadata: updatedMetadata,
      kind: kind,
      purpose: purpose,
      articleId: articleId,
    );
    return true;
  }

  static Future<bool> updateVersionInArticleCache({
    required int articleId,
    required ArticleSongVersion updated,
    required String purpose,
    required String kind,
  }) async {
    final match = await findEntryForVersion(
      articleId: articleId,
      versionId: updated.id,
      purpose: purpose,
    );
    if (match == null) {
      return false;
    }
    final nextVersions = versionsFromMetadata(match.metadata)
        .map(
          (version) => version.id == updated.id ? updated : version,
        )
        .toList(growable: false);
    final updatedMetadata = Map<String, dynamic>.from(match.metadata)
      ..['versions'] = nextVersions.map((version) => version.toJson()).toList();
    await updateEntryMetadata(
      entry: match.entry,
      metadata: updatedMetadata,
      kind: kind,
      purpose: purpose,
      articleId: articleId,
    );
    return true;
  }

  static Future<void> setDefaultVersionInArticleCaches({
    required int articleId,
    required String versionId,
    required String purpose,
    required String kind,
  }) async {
    final normalizedVersionId = versionId.trim();
    if (normalizedVersionId.isEmpty) {
      return;
    }
    final entries = await ApiCacheService.getEntriesForArticlePurpose(
      articleId: articleId,
      purpose: purpose,
      limit: 100,
    );
    for (final entry in entries) {
      final metadata = decodeJsonObject(entry.jsonValue);
      final versions = versionsFromMetadata(metadata);
      if (versions.isEmpty) {
        continue;
      }
      var touched = false;
      final nextVersions = versions.map((version) {
        final selected = version.id == normalizedVersionId;
        if (version.isDefault != selected) {
          touched = true;
        }
        return version.copyWith(isDefault: selected);
      }).toList(growable: false);
      if (!touched) {
        continue;
      }
      final updatedMetadata = Map<String, dynamic>.from(metadata)
        ..['versions'] =
            nextVersions.map((version) => version.toJson()).toList();
      await updateEntryMetadata(
        entry: entry,
        metadata: updatedMetadata,
        kind: kind,
        purpose: purpose,
        articleId: articleId,
      );
    }
  }

  static Future<void> _deleteFileIfExists(String path) async {
    final normalized = path.trim();
    if (normalized.isEmpty) {
      return;
    }
    try {
      final file = File(normalized);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best-effort cleanup.
    }
  }
}
