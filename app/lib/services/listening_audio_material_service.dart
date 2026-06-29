import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'api_cache_service.dart';
import 'database_service.dart';
import 'nlp_service.dart';
import 'tts_memory_cache_service.dart';
import 'tts_service.dart';

class ListeningAudioMaterialStatus {
  const ListeningAudioMaterialStatus({
    required this.articleId,
    required this.total,
    required this.ready,
    required this.missing,
    this.failed = 0,
  });

  final int articleId;
  final int total;
  final int ready;
  final List<int> missing;
  final int failed;

  String get status {
    if (total <= 0) {
      return 'empty';
    }
    if (ready >= total && missing.isEmpty && failed == 0) {
      return 'ready';
    }
    if (ready <= 0) {
      return 'missing';
    }
    return failed > 0 ? 'partial_error' : 'partial';
  }

  Map<String, dynamic> toJson() => {
        'articleId': articleId,
        'total': total,
        'ready': ready,
        'missing': missing,
        'failed': failed,
        'status': status,
      };
}

class ListeningAudioMaterialGenerateResult
    extends ListeningAudioMaterialStatus {
  const ListeningAudioMaterialGenerateResult({
    required super.articleId,
    required super.total,
    required super.ready,
    required super.missing,
    required super.failed,
    required this.requested,
    required this.overwrite,
  });

  final int requested;
  final bool overwrite;

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'requested': requested,
        'overwrite': overwrite,
      };
}

class ListeningAudioMaterialService {
  static const cachePurpose = 'listening_tts';
  static const legacyFollowCachePurpose = 'follow_tts';
  static const missingMaterialMessage = '需要先在创作中心生成听力材料';

  static Future<ListeningAudioMaterialStatus> status(int articleId) async {
    final sentences = await _sentencesForArticle(articleId);
    final missing = <int>[];
    var ready = 0;
    Map<String, TtsFileHandle>? historicalHandles;

    for (var index = 0; index < sentences.length; index += 1) {
      final handle = await _cachedFileHandle(
        text: sentences[index],
        articleId: articleId,
        historicalHandles: () async {
          return historicalHandles ??=
              await _historicalFileHandlesByText(articleId: articleId);
        },
      );
      if (handle == null) {
        missing.add(index);
      } else {
        ready += 1;
      }
    }
    return ListeningAudioMaterialStatus(
      articleId: articleId,
      total: sentences.length,
      ready: ready,
      missing: missing,
    );
  }

  static Future<ListeningAudioMaterialGenerateResult> generate({
    required int articleId,
    required bool overwrite,
    void Function(TtsPreloadProgress progress)? onProgress,
  }) async {
    final sentences = await _sentencesForArticle(articleId);
    if (overwrite) {
      await ApiCacheService.deleteArticleRefsAndUnusedFilesForPurposes(
        articleId,
        purposes: {cachePurpose, legacyFollowCachePurpose},
      );
      TtsMemoryCacheService.releaseArticle(articleId);
    }

    final requests = <TtsPreloadRequest>[];
    Map<String, TtsFileHandle>? historicalHandles;
    for (var index = 0; index < sentences.length; index += 1) {
      final sentence = sentences[index];
      if (!overwrite) {
        final cached = await _cachedFileHandle(
          text: sentence,
          articleId: articleId,
          historicalHandles: () async {
            return historicalHandles ??=
                await _historicalFileHandlesByText(articleId: articleId);
          },
        );
        if (cached != null) {
          continue;
        }
      }
      requests.add(TtsPreloadRequest(
        text: sentence,
        voiceType: TtsService.defaultVoiceType,
        preferRequestedVoice: false,
        cachePurpose: cachePurpose,
        articleId: articleId,
      ));
    }

    var failed = 0;
    if (requests.isEmpty) {
      onProgress?.call(
        TtsPreloadProgress(completed: 0, total: 0, failed: failed),
      );
    } else {
      final override = _preloadOverrideForTest;
      if (override != null) {
        await override(
          requests,
          onProgress: (progress) {
            failed = progress.failed;
            onProgress?.call(progress);
          },
        );
      } else {
        await TtsMemoryCacheService.preload(
          requests,
          onProgress: (progress) {
            failed = progress.failed;
            onProgress?.call(progress);
          },
        );
      }
    }

    final current = await status(articleId);
    return ListeningAudioMaterialGenerateResult(
      articleId: articleId,
      total: current.total,
      ready: current.ready,
      missing: current.missing,
      failed: failed,
      requested: requests.length,
      overwrite: overwrite,
    );
  }

  @visibleForTesting
  static void setPreloadOverrideForTest(
    Future<void> Function(
      List<TtsPreloadRequest> requests, {
      void Function(TtsPreloadProgress progress)? onProgress,
    })? override,
  ) {
    _preloadOverrideForTest = override;
  }

  static Future<TtsFileHandle?> cachedFileHandle({
    required String text,
    required int? articleId,
    String voiceType = TtsService.defaultVoiceType,
    bool preferRequestedVoice = false,
  }) async {
    return _cachedFileHandle(
      text: text,
      articleId: articleId,
      voiceType: voiceType,
      preferRequestedVoice: preferRequestedVoice,
      historicalHandles: articleId == null
          ? null
          : () => _historicalFileHandlesByText(articleId: articleId),
    );
  }

  static Future<TtsFileHandle?> _cachedFileHandle({
    required String text,
    required int? articleId,
    String voiceType = TtsService.defaultVoiceType,
    bool preferRequestedVoice = false,
    Future<Map<String, TtsFileHandle>> Function()? historicalHandles,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final current = await TtsMemoryCacheService.cachedFileHandle(
      text: trimmed,
      voiceType: voiceType,
      preferRequestedVoice: preferRequestedVoice,
      articleId: articleId,
      cachePurpose: cachePurpose,
    );
    if (current != null || articleId == null) {
      return current;
    }

    final handles = await historicalHandles?.call();
    if (handles == null || handles.isEmpty) {
      return null;
    }
    return handles[_normalizeCacheText(trimmed)];
  }

  static Future<List<String>> _sentencesForArticle(int articleId) async {
    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) {
      throw FormatException('文章不存在（id=$articleId）');
    }
    // Saved article sentences are the generated-material contract. Re-splitting
    // an existing article here would orphan already persisted TTS, subtitles,
    // and translations; sentence changes must happen by rebuilding the article.
    final storedSentences = rawArticle.sentences
        .map((sentence) => sentence.trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
    if (storedSentences.isNotEmpty) {
      return storedSentences;
    }

    return NlpService.splitSentences(rawArticle.content)
        .map((sentence) => sentence.trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
  }

  static Future<Map<String, TtsFileHandle>> _historicalFileHandlesByText({
    required int articleId,
  }) async {
    final handles = <String, TtsFileHandle>{};
    for (final purpose in const {cachePurpose, legacyFollowCachePurpose}) {
      final entries = await ApiCacheService.getEntriesForArticlePurpose(
        articleId: articleId,
        purpose: purpose,
        limit: 5000,
      );
      for (final entry in entries) {
        final cachedText = _normalizeCacheText(_requestText(entry.requestJson));
        if (cachedText.isEmpty || handles.containsKey(cachedText)) {
          continue;
        }
        final filePath = entry.filePath?.trim();
        if (filePath == null || filePath.isEmpty) {
          continue;
        }
        final file = File(filePath);
        if (await file.exists() && await file.length() > 0) {
          handles[cachedText] = TtsFileHandle(
            key: entry.cacheKey,
            filePath: filePath,
          );
        }
      }
    }
    return handles;
  }

  static String _requestText(String requestJson) {
    try {
      final decoded = jsonDecode(requestJson);
      if (decoded is Map<String, dynamic>) {
        final text = decoded['text'];
        return text is String ? text : '';
      }
      if (decoded is Map) {
        final text = decoded['text'];
        return text is String ? text : '';
      }
    } catch (_) {
      return '';
    }
    return '';
  }

  static String _normalizeCacheText(String text) =>
      text.trim().replaceAll(RegExp(r'\s+'), ' ');

  static Future<void> Function(
    List<TtsPreloadRequest> requests, {
    void Function(TtsPreloadProgress progress)? onProgress,
  })? _preloadOverrideForTest;
}
