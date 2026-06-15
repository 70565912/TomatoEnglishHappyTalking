import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/config/app_config.dart';
import '../core/logging/tomato_logger.dart';
import 'api_cache_service.dart';
import 'content_safety_service.dart';

enum BailianMusicResultSource {
  remote,
  cached,
  skippedNoKey,
  failed,
}

class BailianMusicResult {
  const BailianMusicResult({
    required this.source,
    this.filePath,
    this.cacheKey,
    this.audioUrl,
    this.durationMs,
    this.lyrics,
    this.submittedLyrics,
    this.lyricsCompressed = false,
    this.requestId,
    this.errorMessage,
  });

  final BailianMusicResultSource source;
  final String? filePath;
  final String? cacheKey;
  final String? audioUrl;
  final int? durationMs;
  final String? lyrics;
  final String? submittedLyrics;
  final bool lyricsCompressed;
  final String? requestId;
  final String? errorMessage;
}

class BailianPreparedLyrics {
  const BailianPreparedLyrics({
    required this.text,
    required this.compressed,
  });

  final String text;
  final bool compressed;
}

typedef BailianMusicPostOverride = Future<Object?> Function({
  required String endpoint,
  required Map<String, String> headers,
  required Map<String, dynamic> body,
});

typedef BailianMusicDownloadOverride = Future<List<int>> Function(String url);

class BailianMusicService {
  static const endpoint =
      'https://dashscope.aliyuncs.com/api/v1/services/audio/music/generation';
  static const cachePurpose = 'bailian_fun_music_song';
  static const _cacheNamespace = 'bailian_fun_music';

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(minutes: 8),
    ),
  );

  static BailianMusicPostOverride? _postOverrideForTest;
  static BailianMusicDownloadOverride? _downloadOverrideForTest;

  @visibleForTesting
  static void setPostOverrideForTest(BailianMusicPostOverride? override) {
    _postOverrideForTest = override;
  }

  @visibleForTesting
  static void setDownloadOverrideForTest(
      BailianMusicDownloadOverride? override) {
    _downloadOverrideForTest = override;
  }

  static Future<BailianMusicResult> generateFromLyrics({
    required String lyrics,
    required String title,
    int? articleId,
    String? prompt,
    String gender = 'female',
    String format = 'mp3',
    bool enableAigcWatermark = false,
  }) async {
    final trimmedLyrics = lyrics.trim();
    if (trimmedLyrics.isEmpty) {
      return const BailianMusicResult(
        source: BailianMusicResultSource.failed,
        errorMessage: '歌词为空，无法调用百炼 fun-music。',
      );
    }

    final apiKey = await AppConfig.aliyunBailianApiKey;
    if (apiKey.trim().isEmpty) {
      return const BailianMusicResult(
        source: BailianMusicResultSource.skippedNoKey,
        errorMessage: '未配置阿里云百炼 API Key，请先在设置中配置。',
      );
    }

    final model = await AppConfig.aliyunBailianMusicModel;
    final preparedDraft = prepareLyricsForGeneration(
      lyrics: trimmedLyrics,
      title: title,
    );
    final preparedLyrics = await ContentSafetyService.prepareTextForApi(
      preparedDraft.text,
      serviceKind: ContentSafetyService.serviceBailianFunMusic,
      purpose: cachePurpose,
    );
    final normalizedFormat = _normalizeFormat(format);
    final request = _cacheRequest(
      model: model,
      lyrics: preparedLyrics,
      title: title,
      prompt: prompt,
      gender: gender,
      format: normalizedFormat,
      enableAigcWatermark: enableAigcWatermark,
    );
    final cacheKey = await ApiCacheService.keyForJson(
      _cacheNamespace,
      request,
    );
    final cachedPath = await ApiCacheService.getFilePath(
      cacheKey,
      articleId: articleId,
      purpose: cachePurpose,
    );
    if (cachedPath != null && cachedPath.trim().isNotEmpty) {
      return BailianMusicResult(
        source: BailianMusicResultSource.cached,
        filePath: cachedPath,
        cacheKey: cacheKey,
        submittedLyrics: preparedLyrics,
        lyricsCompressed: preparedDraft.compressed,
      );
    }

    try {
      final body = _requestBody(
        model: model,
        lyrics: preparedLyrics,
        prompt: prompt,
        gender: gender,
        format: normalizedFormat,
        enableAigcWatermark: enableAigcWatermark,
      );
      final responseData = await _postJson(apiKey: apiKey, body: body);
      final audioUrl = _extractAudioUrl(responseData);
      if (audioUrl.isEmpty) {
        throw const FormatException('百炼 fun-music 未返回 audio.url');
      }
      final bytes = await _downloadAudioBytes(audioUrl);
      if (bytes.length < 1024) {
        throw FormatException('百炼 fun-music 音频下载内容过小：${bytes.length} bytes');
      }
      final filePath = await ApiCacheService.putFileBytes(
        cacheKey: cacheKey,
        kind: _cacheNamespace,
        purpose: cachePurpose,
        request: request,
        bytes: bytes,
        subdirectory: 'music',
        extension: normalizedFormat,
        contentType: _contentTypeFor(normalizedFormat),
        articleId: articleId,
      );
      await ContentSafetyService.learnRulesFromLatestSuccessfulRetry(
        serviceKind: ContentSafetyService.serviceBailianFunMusic,
        purpose: cachePurpose,
        articleId: articleId,
        successfulText: preparedLyrics,
      );
      return BailianMusicResult(
        source: BailianMusicResultSource.remote,
        filePath: filePath,
        cacheKey: cacheKey,
        audioUrl: audioUrl,
        durationMs: _extractDurationMs(responseData),
        lyrics: _extractGeneratedLyrics(responseData),
        submittedLyrics: preparedLyrics,
        lyricsCompressed: preparedDraft.compressed,
        requestId: _extractRequestId(responseData),
      );
    } catch (error, stackTrace) {
      final safety = ContentSafetyService.classifyFailure(error);
      if (safety.suspectedSafetyBlock) {
        await ContentSafetyService.recordFailure(
          serviceKind: ContentSafetyService.serviceBailianFunMusic,
          purpose: cachePurpose,
          articleId: articleId,
          failedText: preparedLyrics,
          errorCode: safety.errorCode,
          errorMessage: safety.message,
        );
      }
      TomatoLogger.error(
        category: 'bailian',
        event: 'music.generate.failed',
        articleId: articleId,
        data: {
          'model': model,
          'lyricsLength': preparedLyrics.length,
          'lyricsCompressed': preparedDraft.compressed,
          'promptProvided': prompt?.trim().isNotEmpty == true,
          'format': normalizedFormat,
        },
        error: _errorSummary(error),
        stackTrace: stackTrace,
      );
      debugPrint('[BailianMusicService] generation failed: $error');
      return BailianMusicResult(
        source: BailianMusicResultSource.failed,
        cacheKey: cacheKey,
        submittedLyrics: preparedLyrics,
        lyricsCompressed: preparedDraft.compressed,
        errorMessage: _errorSummary(error),
      );
    }
  }

  static BailianPreparedLyrics prepareLyricsForGeneration({
    required String lyrics,
    required String title,
  }) {
    final normalized = _normalizeLyricsText(lyrics);
    if (_looksLikeAcceptableLyrics(normalized)) {
      return BailianPreparedLyrics(text: normalized, compressed: false);
    }
    final theme = _songTheme(title, normalized);
    final lines = <String>[
      '$theme, shining bright',
      'We sing the story into light',
      'Step by step, we learn the way',
      'Happy voices guide the day',
      '',
      '$theme, sing it again',
      'Every word becomes a friend',
      '$theme, clear and true',
      'English dreams are waiting too',
      '',
      'Turn the page and hear the sound',
      'Little wonders all around',
      'Read the line and let it flow',
      'In our song the story grows',
    ];
    return BailianPreparedLyrics(
      text: lines.join('\n').trim(),
      compressed: true,
    );
  }

  static bool _looksLikeAcceptableLyrics(String value) {
    if (value.isEmpty || value.length > 1200) {
      return false;
    }
    final lines = value
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.length > 16) {
      return false;
    }
    if (lines.any((line) => line.length > 110)) {
      return false;
    }
    if (lines.length <= 2 && value.length <= 260) {
      return true;
    }
    return lines.length >= 4;
  }

  static String _normalizeLyricsText(String value) {
    return value
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n')
        .trim();
  }

  static String _songTheme(String title, String lyrics) {
    final candidates = <String>[title, lyrics]
        .map((value) => value
            .replaceAll(RegExp(r'\bE\d+\b', caseSensitive: false), ' ')
            .replaceAll(RegExp(r'\bpart\s+\d+\b', caseSensitive: false), ' ')
            .replaceAll(RegExp(r'chapter\s+\w+', caseSensitive: false), ' ')
            .replaceAll(RegExp(r'[^A-Za-z0-9 ]+'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    final raw = candidates.isNotEmpty ? candidates.first : 'Story time';
    final words = raw
        .split(' ')
        .where((word) => word.length > 1)
        .take(4)
        .toList(growable: false);
    return words.isEmpty ? 'Story time' : words.join(' ');
  }

  static Map<String, dynamic> _cacheRequest({
    required String model,
    required String lyrics,
    required String title,
    required String? prompt,
    required String gender,
    required String format,
    required bool enableAigcWatermark,
  }) =>
      {
        'service': _cacheNamespace,
        'endpoint': endpoint,
        'model': model,
        'title': title.trim(),
        'lyrics': lyrics,
        if (prompt?.trim().isNotEmpty == true) 'prompt': prompt!.trim(),
        'gender': gender.trim().isEmpty ? 'female' : gender.trim(),
        'format': format,
        'enable_aigc_watermark': enableAigcWatermark,
      };

  static Map<String, dynamic> _requestBody({
    required String model,
    required String lyrics,
    required String? prompt,
    required String gender,
    required String format,
    required bool enableAigcWatermark,
  }) =>
      {
        'model': model,
        'input': {
          'lyrics': lyrics,
          if (prompt?.trim().isNotEmpty == true) 'prompt': prompt!.trim(),
          'gender': gender.trim().isEmpty ? 'female' : gender.trim(),
          'format': format,
          'enable_aigc_watermark': enableAigcWatermark,
        },
      };

  static Future<Object?> _postJson({
    required String apiKey,
    required Map<String, dynamic> body,
  }) async {
    final headers = <String, String>{
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
    };
    final override = _postOverrideForTest;
    if (override != null) {
      return override(endpoint: endpoint, headers: headers, body: body);
    }

    final response = await _dio.post<Object?>(
      endpoint,
      data: body,
      options: Options(
        headers: headers,
        responseType: ResponseType.json,
        validateStatus: (_) => true,
      ),
    );
    final statusCode = response.statusCode ?? 0;
    if (statusCode < 200 || statusCode >= 300) {
      throw FormatException(
        'HTTP $statusCode ${_extractRemoteErrorMessage(response.data)}',
      );
    }
    return response.data;
  }

  static Future<List<int>> _downloadAudioBytes(String url) async {
    final override = _downloadOverrideForTest;
    if (override != null) {
      return override(url);
    }
    final response = await _dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    return response.data ?? const <int>[];
  }

  static String _extractAudioUrl(Object? responseData) {
    final root = _asMap(responseData);
    final output = _asMap(root['output']);
    final audio = _asMap(output['audio']);
    return (audio['url'] ?? '').toString().trim();
  }

  static int? _extractDurationMs(Object? responseData) {
    final root = _asMap(responseData);
    final usage = _asMap(root['usage']);
    final seconds = usage['duration'];
    if (seconds is num) {
      return (seconds * 1000).round();
    }
    return null;
  }

  static String? _extractGeneratedLyrics(Object? responseData) {
    final root = _asMap(responseData);
    final output = _asMap(root['output']);
    final extraInfo = _asMap(output['extra_info']);
    final lyrics = (extraInfo['lyrics'] ?? '').toString().trim();
    return lyrics.isEmpty ? null : lyrics;
  }

  static String? _extractRequestId(Object? responseData) {
    final root = _asMap(responseData);
    final requestId = (root['request_id'] ?? '').toString().trim();
    return requestId.isEmpty ? null : requestId;
  }

  static Map<String, dynamic> _asMap(Object? value) {
    final decoded = value is String ? jsonDecode(value) : value;
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    }
    return const <String, dynamic>{};
  }

  static String _normalizeFormat(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized == 'wav' ? 'wav' : 'mp3';
  }

  static String _contentTypeFor(String format) =>
      format == 'wav' ? 'audio/wav' : 'audio/mpeg';

  static String _extractRemoteErrorMessage(Object? data) {
    final root = _asMap(data);
    if (root.isEmpty) {
      return data?.toString() ?? '';
    }
    final message = (root['message'] ?? root['error'] ?? root['code'] ?? '')
        .toString()
        .trim();
    return message.isEmpty ? root.toString() : message;
  }

  static String _errorSummary(Object error) {
    if (error is FormatException) {
      return error.message;
    }
    if (error is DioException) {
      final status = error.response?.statusCode;
      final data = error.response?.data;
      return 'DioException status=$status message=${error.message} body=${data ?? ''}';
    }
    return error.toString();
  }
}
