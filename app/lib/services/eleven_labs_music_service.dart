import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/config/app_config.dart';
import '../core/logging/tomato_logger.dart';
import 'api_cache_service.dart';
import 'bailian_music_service.dart';
import 'content_safety_service.dart';

enum ElevenLabsMusicResultSource {
  remote,
  cached,
  skippedNoKey,
  failed,
}

class ElevenLabsMusicResult {
  const ElevenLabsMusicResult({
    required this.source,
    this.filePath,
    this.cacheKey,
    this.songId,
    this.submittedLyrics,
    this.lyricsCompressed = false,
    this.errorMessage,
  });

  final ElevenLabsMusicResultSource source;
  final String? filePath;
  final String? cacheKey;
  final String? songId;
  final String? submittedLyrics;
  final bool lyricsCompressed;
  final String? errorMessage;
}

typedef ElevenLabsMusicPostOverride = Future<ElevenLabsMusicPostResult>
    Function({
  required String endpoint,
  required Map<String, String> headers,
  required Map<String, dynamic> body,
});

class ElevenLabsMusicPostResult {
  const ElevenLabsMusicPostResult({
    required this.bytes,
    this.songId,
  });

  final List<int> bytes;
  final String? songId;
}

class ElevenLabsMusicService {
  static const cachePurpose = 'elevenlabs_music_song';
  static const _cacheNamespace = 'elevenlabs_music';

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 45),
      receiveTimeout: const Duration(minutes: 10),
    ),
  );

  static ElevenLabsMusicPostOverride? _postOverrideForTest;

  @visibleForTesting
  static void setPostOverrideForTest(ElevenLabsMusicPostOverride? override) {
    _postOverrideForTest = override;
  }

  static Future<ElevenLabsMusicResult> generateFromLyrics({
    required String lyrics,
    required String title,
    int? articleId,
    int? musicLengthMs,
    bool forceInstrumental = false,
  }) async {
    final trimmedLyrics = lyrics.trim();
    if (trimmedLyrics.isEmpty) {
      return const ElevenLabsMusicResult(
        source: ElevenLabsMusicResultSource.failed,
        errorMessage: '歌词为空，无法调用 ElevenLabs Music。',
      );
    }

    final apiKey = await AppConfig.elevenLabsApiKey;
    if (apiKey.trim().isEmpty) {
      return const ElevenLabsMusicResult(
        source: ElevenLabsMusicResultSource.skippedNoKey,
        errorMessage: '未配置 ElevenLabs API Key，请先在设置中配置。',
      );
    }

    final preparedDraft = BailianMusicService.prepareLyricsForGeneration(
      lyrics: trimmedLyrics,
      title: title,
    );
    final submittedLyrics = await ContentSafetyService.prepareTextForApi(
      preparedDraft.text,
      serviceKind: ContentSafetyService.serviceElevenLabsMusic,
      purpose: cachePurpose,
    );
    final model = await AppConfig.elevenLabsMusicModel;
    final outputFormat = await AppConfig.elevenLabsMusicOutputFormat;
    final prompt = _musicPrompt(title: title, lyrics: submittedLyrics);
    final request = _cacheRequest(
      model: model,
      outputFormat: outputFormat,
      prompt: prompt,
      submittedLyrics: submittedLyrics,
      title: title,
      musicLengthMs: musicLengthMs,
      forceInstrumental: forceInstrumental,
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
      return ElevenLabsMusicResult(
        source: ElevenLabsMusicResultSource.cached,
        filePath: cachedPath,
        cacheKey: cacheKey,
        submittedLyrics: submittedLyrics,
        lyricsCompressed: preparedDraft.compressed,
      );
    }

    try {
      final endpoint = '${await AppConfig.elevenLabsBaseUrl}/v1/music'
          '?output_format=${Uri.encodeQueryComponent(outputFormat)}';
      final body = <String, dynamic>{
        'prompt': prompt,
        'model_id': model,
        'force_instrumental': forceInstrumental,
        if (musicLengthMs != null) 'music_length_ms': musicLengthMs,
      };
      final result = await _postMusic(
        endpoint: endpoint,
        apiKey: apiKey,
        body: body,
      );
      if (result.bytes.length < 1024) {
        throw FormatException(
          'ElevenLabs Music 音频内容过小：${result.bytes.length} bytes',
        );
      }
      final filePath = await ApiCacheService.putFileBytes(
        cacheKey: cacheKey,
        kind: _cacheNamespace,
        purpose: cachePurpose,
        request: request,
        bytes: result.bytes,
        subdirectory: 'music',
        extension: _extensionForOutput(outputFormat),
        contentType: _contentTypeForOutput(outputFormat),
        articleId: articleId,
      );
      await ContentSafetyService.learnRulesFromLatestSuccessfulRetry(
        serviceKind: ContentSafetyService.serviceElevenLabsMusic,
        purpose: cachePurpose,
        articleId: articleId,
        successfulText: submittedLyrics,
      );
      return ElevenLabsMusicResult(
        source: ElevenLabsMusicResultSource.remote,
        filePath: filePath,
        cacheKey: cacheKey,
        songId: result.songId,
        submittedLyrics: submittedLyrics,
        lyricsCompressed: preparedDraft.compressed,
      );
    } catch (error, stackTrace) {
      final safety = ContentSafetyService.classifyFailure(error);
      if (safety.suspectedSafetyBlock) {
        await ContentSafetyService.recordFailure(
          serviceKind: ContentSafetyService.serviceElevenLabsMusic,
          purpose: cachePurpose,
          articleId: articleId,
          failedText: submittedLyrics,
          errorCode: safety.errorCode,
          errorMessage: safety.message,
        );
      }
      TomatoLogger.error(
        category: 'elevenlabs',
        event: 'music.generate.failed',
        articleId: articleId,
        data: {
          'model': model,
          'lyricsLength': submittedLyrics.length,
          'lyricsCompressed': preparedDraft.compressed,
          'outputFormat': outputFormat,
        },
        error: _errorSummary(error),
        stackTrace: stackTrace,
      );
      return ElevenLabsMusicResult(
        source: ElevenLabsMusicResultSource.failed,
        cacheKey: cacheKey,
        submittedLyrics: submittedLyrics,
        lyricsCompressed: preparedDraft.compressed,
        errorMessage: _errorSummary(error),
      );
    }
  }

  static Future<ElevenLabsMusicPostResult> _postMusic({
    required String endpoint,
    required String apiKey,
    required Map<String, dynamic> body,
  }) async {
    final headers = {
      'xi-api-key': apiKey,
      'Content-Type': 'application/json',
    };
    final override = _postOverrideForTest;
    if (override != null) {
      return override(endpoint: endpoint, headers: headers, body: body);
    }
    final response = await _dio.post<List<int>>(
      endpoint,
      options: Options(
        headers: headers,
        responseType: ResponseType.bytes,
        validateStatus: (_) => true,
        connectTimeout: const Duration(seconds: 45),
        receiveTimeout: const Duration(minutes: 10),
      ),
      data: body,
    );
    final statusCode = response.statusCode ?? 0;
    if (statusCode < 200 || statusCode >= 300) {
      throw FormatException(
        'ElevenLabs Music 请求失败 HTTP $statusCode：${_remoteErrorMessage(response.data)}',
      );
    }
    return ElevenLabsMusicPostResult(
      bytes: response.data ?? const <int>[],
      songId: response.headers.value('song-id'),
    );
  }

  static Map<String, dynamic> _cacheRequest({
    required String model,
    required String outputFormat,
    required String prompt,
    required String submittedLyrics,
    required String title,
    required int? musicLengthMs,
    required bool forceInstrumental,
  }) =>
      {
        'service': 'elevenlabs_music',
        'provider': AppConfig.songProviderElevenLabsMusic,
        'model': model,
        'outputFormat': outputFormat,
        'title': title,
        'prompt': prompt,
        'submittedLyrics': submittedLyrics,
        'musicLengthMs': musicLengthMs,
        'forceInstrumental': forceInstrumental,
      };

  static String _musicPrompt({
    required String title,
    required String lyrics,
  }) {
    final normalizedTitle =
        title.trim().isEmpty ? 'English story' : title.trim();
    final normalizedLyrics = lyrics.trim();
    final prompt = [
      'Create a warm child-friendly English learning song for "$normalizedTitle".',
      'Use clear lead vocals, simple melody, gentle pop storybook energy, and natural English pronunciation.',
      'Use these lyrics as the song words:',
      normalizedLyrics,
    ].join('\n');
    if (prompt.length <= 4100) {
      return prompt;
    }
    return '${prompt.substring(0, 4090).trimRight()}\n...';
  }

  static String _extensionForOutput(String outputFormat) {
    final normalized = outputFormat.trim().toLowerCase();
    if (normalized.startsWith('wav')) {
      return 'wav';
    }
    return 'mp3';
  }

  static String _contentTypeForOutput(String outputFormat) {
    return _extensionForOutput(outputFormat) == 'wav'
        ? 'audio/wav'
        : 'audio/mpeg';
  }

  static String _remoteErrorMessage(Object? payload) {
    if (payload is List<int>) {
      final text = utf8.decode(payload, allowMalformed: true).trim();
      if (text.isEmpty) {
        return '';
      }
      try {
        final decoded = jsonDecode(text);
        final message = _messageFromJsonValue(decoded);
        if (message != null && message.isNotEmpty) {
          return message;
        }
      } catch (_) {
        // Keep the original response text when it is not JSON.
      }
      return text;
    }
    final message = _messageFromJsonValue(payload);
    if (message != null && message.isNotEmpty) {
      return message;
    }
    return payload?.toString() ?? '未知错误';
  }

  static String? _messageFromJsonValue(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    if (value is Map) {
      final map = value.map((key, item) => MapEntry(key.toString(), item));
      final detail = _messageFromJsonValue(map['detail']);
      if (detail != null && detail.isNotEmpty) {
        return detail;
      }
      final status = _messageFromJsonValue(map['status']);
      final code = _messageFromJsonValue(map['code']);
      final type = _messageFromJsonValue(map['type']);
      final message = _messageFromJsonValue(map['message']) ??
          _messageFromJsonValue(map['msg']) ??
          _messageFromJsonValue(map['error']);
      final label = status ?? code ?? type;
      if (label != null && message != null) {
        return '$label: $message';
      }
      return message ?? label;
    }
    return value.toString().trim();
  }

  static String _errorSummary(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      final statusPart = status == null ? '' : ' HTTP $status';
      final serverMessage = _remoteErrorMessage(error.response?.data).trim();
      if (serverMessage.isNotEmpty && serverMessage != '未知错误') {
        return 'ElevenLabs Music 网络请求失败$statusPart：$serverMessage';
      }
      return 'ElevenLabs Music 网络请求失败$statusPart：${error.message}';
    }
    return error
        .toString()
        .replaceFirst(RegExp(r'^FormatException:\s*'), '')
        .trim();
  }
}
