import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;

import '../data/models/article_model.dart';
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
  static const _legacyLookupPurposes = <String>[
    cachePurpose,
    legacyFollowCachePurpose,
  ];

  static Future<ListeningAudioMaterialStatus> status(int articleId) async {
    final sentences = await _sentencesForArticle(articleId);
    final missing = <int>[];
    var ready = 0;
    for (var index = 0; index < sentences.length; index += 1) {
      final handles = await cachedFileHandles(
        articleId: articleId,
        text: sentences[index],
      );
      if (handles.isEmpty) {
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
    for (var index = 0; index < sentences.length; index += 1) {
      final sentence = sentences[index];
      if (!overwrite) {
        final cached = await cachedFileHandles(
          articleId: articleId,
          text: sentence,
        );
        if (cached.isNotEmpty) {
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

  static Future<List<TtsFileHandle>> cachedFileHandles({
    required int articleId,
    required String text,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const [];
    }

    final current = await TtsMemoryCacheService.cachedFileHandle(
      text: trimmed,
      voiceType: TtsService.defaultVoiceType,
      preferRequestedVoice: false,
      articleId: articleId,
      cachePurpose: cachePurpose,
    );
    if (current != null) {
      return [current];
    }

    final candidates = await _historicalAudioCandidates(articleId);
    final requestedTokens = _lookupTokens(trimmed);
    if (requestedTokens.isEmpty) {
      return const [];
    }
    final requestedKey = requestedTokens.join(' ');

    for (final candidate in candidates) {
      if (candidate.lookupKey == requestedKey) {
        return [candidate.handle];
      }
    }

    return _coverWithHistoricalCandidates(
      requestedTokens: requestedTokens,
      candidates: candidates,
    );
  }

  static Future<List<String>> _sentencesForArticle(int articleId) async {
    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) {
      throw FormatException('文章不存在（id=$articleId）');
    }
    final article = await _articleWithCurrentSentences(rawArticle);
    return article.sentences
        .map((sentence) => sentence.trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
  }

  static Future<Article> _articleWithCurrentSentences(Article article) async {
    final sentences = NlpService.splitSentences(article.content);
    if (sentences.isEmpty || listEquals(article.sentences, sentences)) {
      return article;
    }

    final id = article.id;
    if (id != null) {
      await DatabaseService.updateArticleSentences(id, sentences);
    }
    return article.copyWith(sentences: sentences);
  }

  static Future<List<_HistoricalAudioCandidate>> _historicalAudioCandidates(
    int articleId,
  ) async {
    final byLookupKey = <String, _HistoricalAudioCandidate>{};
    var order = 0;
    for (final purpose in _legacyLookupPurposes) {
      final entries = await ApiCacheService.getEntriesForArticlePurpose(
        articleId: articleId,
        purpose: purpose,
        limit: 5000,
      );
      for (final entry in entries) {
        final filePath = entry.filePath?.trim() ?? '';
        if (filePath.isEmpty) {
          continue;
        }
        final file = File(filePath);
        if (!await file.exists() || await file.length() <= 0) {
          continue;
        }
        final text = _requestText(entry.requestJson);
        final tokens = _lookupTokens(text);
        if (tokens.isEmpty) {
          continue;
        }
        final lookupKey = tokens.join(' ');
        byLookupKey.putIfAbsent(
          lookupKey,
          () => _HistoricalAudioCandidate(
            handle: TtsFileHandle(key: entry.cacheKey, filePath: filePath),
            lookupKey: lookupKey,
            tokens: tokens,
            order: order,
          ),
        );
        order += 1;
      }
    }
    return byLookupKey.values.toList(growable: false);
  }

  static List<TtsFileHandle> _coverWithHistoricalCandidates({
    required List<String> requestedTokens,
    required List<_HistoricalAudioCandidate> candidates,
  }) {
    final matches = <_HistoricalAudioMatch>[];
    for (final candidate in candidates) {
      if (candidate.tokens.length < 2 ||
          candidate.tokens.length > requestedTokens.length) {
        continue;
      }
      for (final start in _tokenSequenceStarts(
        requestedTokens,
        candidate.tokens,
      )) {
        matches.add(_HistoricalAudioMatch(
          candidate: candidate,
          start: start,
          end: start + candidate.tokens.length,
        ));
      }
    }
    if (matches.isEmpty) {
      return const [];
    }

    matches.sort((a, b) {
      final startCompare = a.start.compareTo(b.start);
      if (startCompare != 0) return startCompare;
      final lengthCompare = b.length.compareTo(a.length);
      if (lengthCompare != 0) return lengthCompare;
      return a.candidate.order.compareTo(b.candidate.order);
    });

    final selected = <_HistoricalAudioMatch>[];
    var cursor = 0;
    var covered = 0;
    for (final match in matches) {
      if (match.end <= cursor || match.start < cursor) {
        continue;
      }
      selected.add(match);
      covered += match.length;
      cursor = match.end;
    }
    if (selected.isEmpty) {
      return const [];
    }

    final coverage = covered / requestedTokens.length;
    final allowedBoundaryGap = requestedTokens.length < 10
        ? 1
        : (requestedTokens.length * 0.15).ceil();
    final leadingGap = selected.first.start;
    final trailingGap = requestedTokens.length - selected.last.end;
    if (coverage < 0.85 ||
        leadingGap > allowedBoundaryGap ||
        trailingGap > allowedBoundaryGap) {
      return const [];
    }
    return selected
        .map((match) => match.candidate.handle)
        .toList(growable: false);
  }

  static Iterable<int> _tokenSequenceStarts(
    List<String> haystack,
    List<String> needle,
  ) sync* {
    if (needle.isEmpty || needle.length > haystack.length) {
      return;
    }
    final maxStart = haystack.length - needle.length;
    for (var start = 0; start <= maxStart; start += 1) {
      var matched = true;
      for (var offset = 0; offset < needle.length; offset += 1) {
        if (haystack[start + offset] != needle[offset]) {
          matched = false;
          break;
        }
      }
      if (matched) {
        yield start;
      }
    }
  }

  static List<String> _lookupTokens(String text) => RegExp(
        r"[a-z0-9]+(?:'[a-z0-9]+)?",
        caseSensitive: false,
      )
          .allMatches(text.toLowerCase())
          .map((match) => match.group(0) ?? '')
          .where((token) => token.isNotEmpty)
          .toList(growable: false);

  static String _requestText(String requestJson) {
    try {
      final decoded = jsonDecode(requestJson);
      if (decoded is Map) {
        return (decoded['text'] ?? '').toString().trim();
      }
    } catch (_) {
      // Ignore malformed historical rows.
    }
    return '';
  }

  static Future<void> Function(
    List<TtsPreloadRequest> requests, {
    void Function(TtsPreloadProgress progress)? onProgress,
  })? _preloadOverrideForTest;
}

class _HistoricalAudioCandidate {
  const _HistoricalAudioCandidate({
    required this.handle,
    required this.lookupKey,
    required this.tokens,
    required this.order,
  });

  final TtsFileHandle handle;
  final String lookupKey;
  final List<String> tokens;
  final int order;
}

class _HistoricalAudioMatch {
  const _HistoricalAudioMatch({
    required this.candidate,
    required this.start,
    required this.end,
  });

  final _HistoricalAudioCandidate candidate;
  final int start;
  final int end;

  int get length => end - start;
}
