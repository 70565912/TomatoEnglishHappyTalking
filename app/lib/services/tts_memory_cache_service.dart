// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

import '../core/config/app_config.dart';
import 'api_cache_service.dart';
import 'tts_service.dart';

class TtsMemoryHandle {
  const TtsMemoryHandle({
    required this.key,
    required this.bytes,
    required this.filePath,
  });

  final String key;
  final Uint8List bytes;
  final String filePath;

  AudioSource toAudioSource({Object? tag}) => _MemoryMp3AudioSource(
        bytes,
        tag: tag,
      );
}

class TtsPreloadProgress {
  const TtsPreloadProgress({
    required this.completed,
    required this.total,
    required this.failed,
  });

  final int completed;
  final int total;
  final int failed;
}

class TtsPreloadRequest {
  const TtsPreloadRequest({
    required this.text,
    required this.voiceType,
    required this.preferRequestedVoice,
    required this.cachePurpose,
    this.articleId,
  });

  final String text;
  final String voiceType;
  final bool preferRequestedVoice;
  final String cachePurpose;
  final int? articleId;
}

class TtsMemoryCacheService {
  static const defaultConcurrency = 2;
  static final Map<String, TtsMemoryHandle> _cache = {};
  static final Map<String, Future<TtsMemoryHandle>> _pending = {};
  static final Map<int, Set<String>> _articleKeys = {};

  static Future<TtsMemoryHandle> load({
    required String text,
    String voiceType = TtsService.defaultVoiceType,
    bool preferRequestedVoice = false,
    int? articleId,
    String cachePurpose = 'tts',
    bool forceRefresh = false,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const TtsException('TTS 文本不能为空');
    }

    final key = await _key(
      text: trimmed,
      voiceType: voiceType,
      preferRequestedVoice: preferRequestedVoice,
      cachePurpose: cachePurpose,
    );
    final cached = forceRefresh ? null : _cache[key];
    if (cached != null) {
      _rememberArticleKey(articleId, key);
      return cached;
    }

    final pending = forceRefresh ? null : _pending[key];
    if (pending != null) {
      final handle = await pending;
      _rememberArticleKey(articleId, key);
      return handle;
    }
    if (forceRefresh) {
      _cache.remove(key);
      _pending.remove(key);
    }

    final future = () async {
      final path = await TtsService.synthesizeToCachedFile(
        text: trimmed,
        voiceType: voiceType,
        preferRequestedVoice: preferRequestedVoice,
        articleId: articleId,
        cachePurpose: cachePurpose,
        forceRefresh: forceRefresh,
      );
      final bytes = await File(path).readAsBytes();
      if (bytes.isEmpty) {
        throw const TtsException('TTS 缓存音频为空');
      }
      final handle = TtsMemoryHandle(
        key: key,
        bytes: Uint8List.fromList(bytes),
        filePath: path,
      );
      _cache[key] = handle;
      _rememberArticleKey(articleId, key);
      return handle;
    }();

    _pending[key] = future;
    try {
      return await future;
    } finally {
      if (_pending[key] == future) {
        _pending.remove(key);
      }
    }
  }

  static Future<bool> hasInMemory({
    required String text,
    String voiceType = TtsService.defaultVoiceType,
    bool preferRequestedVoice = false,
    String cachePurpose = 'tts',
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    final key = await _key(
      text: trimmed,
      voiceType: voiceType,
      preferRequestedVoice: preferRequestedVoice,
      cachePurpose: cachePurpose,
    );
    return _cache.containsKey(key);
  }

  static Future<TtsMemoryHandle> requireInMemory({
    required String text,
    String voiceType = TtsService.defaultVoiceType,
    bool preferRequestedVoice = false,
    int? articleId,
    String cachePurpose = 'tts',
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const TtsException('TTS 文本不能为空');
    }
    final key = await _key(
      text: trimmed,
      voiceType: voiceType,
      preferRequestedVoice: preferRequestedVoice,
      cachePurpose: cachePurpose,
    );
    final handle = _cache[key];
    if (handle == null) {
      throw const TtsException('音频尚未完成内存预加载');
    }
    _rememberArticleKey(articleId, key);
    return handle;
  }

  static Future<void> preload(
    List<TtsPreloadRequest> requests, {
    int concurrency = defaultConcurrency,
    void Function(TtsPreloadProgress progress)? onProgress,
  }) async {
    final clean = requests
        .where((request) => request.text.trim().isNotEmpty)
        .toList(growable: false);
    final total = clean.length;
    if (total == 0) {
      onProgress?.call(
        const TtsPreloadProgress(completed: 0, total: 0, failed: 0),
      );
      return;
    }

    var next = 0;
    var completed = 0;
    var failed = 0;
    final workerCount = concurrency.clamp(1, total).toInt();

    Future<void> worker() async {
      while (true) {
        final index = next;
        next += 1;
        if (index >= total) {
          return;
        }
        final request = clean[index];
        try {
          await load(
            text: request.text,
            voiceType: request.voiceType,
            preferRequestedVoice: request.preferRequestedVoice,
            articleId: request.articleId,
            cachePurpose: request.cachePurpose,
          );
        } catch (_) {
          failed += 1;
        } finally {
          completed += 1;
          onProgress?.call(
            TtsPreloadProgress(
              completed: completed,
              total: total,
              failed: failed,
            ),
          );
        }
      }
    }

    await Future.wait([for (var i = 0; i < workerCount; i += 1) worker()]);
  }

  static void releaseArticle(int articleId) {
    final keys = _articleKeys.remove(articleId);
    if (keys == null) {
      return;
    }
    for (final key in keys) {
      _cache.remove(key);
    }
  }

  static Future<void> evictForText({
    required String text,
    String voiceType = TtsService.defaultVoiceType,
    bool preferRequestedVoice = false,
    int? articleId,
    String cachePurpose = 'tts',
    bool deleteDiskCache = false,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final key = await _key(
      text: trimmed,
      voiceType: voiceType,
      preferRequestedVoice: preferRequestedVoice,
      cachePurpose: cachePurpose,
    );
    _cache.remove(key);
    _pending.remove(key);
    if (articleId != null) {
      _articleKeys[articleId]?.remove(key);
    }
    if (!deleteDiskCache) {
      return;
    }
    final diskKeys = await TtsService.cacheKeysForText(
      text: trimmed,
      voiceType: voiceType,
      preferRequestedVoice: preferRequestedVoice,
      cachePurpose: cachePurpose,
    );
    await ApiCacheService.deleteEntriesByKeys(diskKeys);
  }

  static Future<String> _key({
    required String text,
    required String voiceType,
    required bool preferRequestedVoice,
    required String cachePurpose,
  }) async {
    final speakerKey = preferRequestedVoice
        ? 'preferred'
        : (await AppConfig.volcTtsSpeakerId).trim();
    return [
      cachePurpose,
      voiceType.trim(),
      speakerKey,
      _stableTextHash(text),
    ].join(':');
  }

  static void _rememberArticleKey(int? articleId, String key) {
    if (articleId == null) {
      return;
    }
    (_articleKeys[articleId] ??= <String>{}).add(key);
  }

  static int _stableTextHash(String text) {
    var hash = 0x811c9dc5;
    for (final codeUnit in text.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }
}

class _MemoryMp3AudioSource extends StreamAudioSource {
  _MemoryMp3AudioSource(this.bytes, {super.tag});

  static const _chunkSize = 64 * 1024;

  final Uint8List bytes;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    // Windows Media Foundation can keep tiny proxy-backed MP3 range streams
    // open after EOF. These TTS clips are already fully in memory, so serve the
    // whole clip as a simple non-range response and let the player close it.
    const resolvedStart = 0;
    final resolvedEnd = bytes.length;
    return StreamAudioResponse(
      rangeRequestsSupported: false,
      sourceLength: null,
      contentLength: resolvedEnd - resolvedStart,
      offset: null,
      stream: _streamBytes(resolvedStart, resolvedEnd),
      contentType: 'audio/mpeg',
    );
  }

  Stream<List<int>> _streamBytes(int start, int end) async* {
    var offset = start;
    while (offset < end) {
      final next = (offset + _chunkSize).clamp(offset, end).toInt();
      yield Uint8List.sublistView(bytes, offset, next);
      offset = next;
    }
  }
}
