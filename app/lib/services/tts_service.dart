import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/config/app_config.dart';

/// TTS 服务 — 直接调用火山引擎 Doubao TTS 2.0 HTTP Chunked API。
/// 未配置或云端失败时抛出 [TtsException]，由 Provider 转成可展示的 UI 状态。

class VoiceInfo {
  final String id;
  final String name;
  final String lang;
  final String gender;
  const VoiceInfo({
    required this.id,
    required this.name,
    required this.lang,
    required this.gender,
  });
}

class TtsException implements Exception {
  const TtsException(this.message);

  final String message;

  @override
  String toString() => message;
}

class TtsService {
  static const _audioTraceEnabled = bool.fromEnvironment(
    'TOMATO_AUDIO_TRACE',
    defaultValue: false,
  );

  static final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

  static const List<VoiceInfo> voices = [
    VoiceInfo(
      id: 'en_female_dacey_uranus_bigtts',
      name: 'Dacey（美式·女）',
      lang: 'en-US',
      gender: 'female',
    ),
    VoiceInfo(
      id: 'en_male_tim_uranus_bigtts',
      name: 'Tim（美式·男）',
      lang: 'en-US',
      gender: 'male',
    ),
    VoiceInfo(
      id: 'en_female_stokie_uranus_bigtts',
      name: 'Stokie（美式·女）',
      lang: 'en-US',
      gender: 'female',
    ),
    VoiceInfo(
      id: 'zh_female_yingyujiaoxue_uranus_bigtts',
      name: 'Tina老师 2.0（中英教学）',
      lang: 'en-GB',
      gender: 'female',
    ),
  ];

  static const _v3Endpoint =
      'https://openspeech.bytedance.com/api/v3/tts/unidirectional';

  /// 合成语音，返回 MP3 字节数据
  static Future<List<int>?> synthesize({
    required String text,
    String voiceType = 'en_female_dacey_uranus_bigtts',
  }) async {
    final trimmedText = text.trim();
    if (trimmedText.isEmpty) {
      throw const TtsException('TTS 文本不能为空');
    }

    final apiKey = await AppConfig.volcApiKey;
    if (apiKey.isEmpty) {
      throw const TtsException('本机加密配置未读取到火山引擎 API Key');
    }

    final ttsResourceId = await AppConfig.volcTtsResourceId;
    if (ttsResourceId.trim().isEmpty) {
      throw const TtsException('本机加密配置未读取到 TTS 2.0 的 Resource ID');
    }

    final configuredSpeakerId = await AppConfig.volcTtsSpeakerId;
    final resolvedSpeakerId = _resolveSpeakerId(
      configuredSpeakerId: configuredSpeakerId,
      requestedVoiceType: voiceType,
    );
    if (resolvedSpeakerId.isEmpty) {
      throw const TtsException('本机加密配置未读取到 TTS 2.0 的 Speaker');
    }

    return _synthesizeV3(
      text: trimmedText,
      speakerId: resolvedSpeakerId,
      apiKey: apiKey,
      resourceId: ttsResourceId,
    );
  }

  static Future<List<int>> _synthesizeV3({
    required String text,
    required String speakerId,
    required String apiKey,
    required String resourceId,
  }) async {
    final requestId = DateTime.now().millisecondsSinceEpoch.toString();

    try {
      _trace(
        'v3 request start id=$requestId speaker=$speakerId textLen=${text.length} resourceId=$resourceId',
      );
      final response = await _dio.post<ResponseBody>(
        _v3Endpoint,
        options: Options(
          headers: {
            'X-Api-Key': apiKey,
            'X-Api-Resource-Id': resourceId,
            'X-Api-Request-Id': requestId,
          },
          responseType: ResponseType.stream,
        ),
        data: {
          'req_params': {
            'text': text,
            'speaker': speakerId,
            'audio_params': {
              'format': 'mp3',
              'sample_rate': 24000,
            },
          },
        },
      );

      final responseBody = response.data;
      if (responseBody == null) {
        throw const TtsException('TTS 2.0 未返回音频流');
      }

      final audioBytes = await _collectChunkedAudio(responseBody);
      if (audioBytes.isEmpty) {
        throw const TtsException('TTS 2.0 未返回音频数据');
      }

      _trace('v3 request success id=$requestId bytes=${audioBytes.length}');

      return audioBytes;
    } on DioException catch (e) {
      _trace('v3 request dioError id=$requestId error=${e.message}');
      throw _mapDioException(
        e,
        fallbackMessage: 'TTS 2.0 网络请求失败，请检查网络或本机语音配置',
      );
    } on FormatException catch (e) {
      debugPrint('[TtsService] invalid v3 audio payload: $e');
      throw const TtsException('TTS 2.0 返回格式异常');
    } on TtsException {
      rethrow;
    } catch (e) {
      debugPrint('[TtsService] v3 synthesize failed: $e');
      throw TtsException('TTS 2.0 合成失败：$e');
    }
  }

  static Future<List<int>> _collectChunkedAudio(
      ResponseBody responseBody) async {
    final audioBytes = <int>[];
    var sawTerminalSuccess = false;
    var packetCount = 0;
    var audioPacketCount = 0;

    await for (final line in utf8.decoder.bind(responseBody.stream).transform(
          const LineSplitter(),
        )) {
      final trimmedLine = line.trim();
      if (trimmedLine.isEmpty) {
        continue;
      }

      final decoded = jsonDecode(trimmedLine);
      if (decoded is! Map) {
        continue;
      }

      packetCount += 1;
      final packet = Map<String, dynamic>.from(decoded);
      final audioBase64 = packet['data'] as String?;
      if (audioBase64 != null && audioBase64.isNotEmpty) {
        audioPacketCount += 1;
        audioBytes.addAll(base64.decode(audioBase64));
      }

      final code = _parsePacketCode(packet['code']);
      if (code == 20000000) {
        sawTerminalSuccess = true;
        continue;
      }

      final errorMessage =
          packet['message'] ?? packet['msg'] ?? packet['error'];
      if (audioBase64 == null &&
          errorMessage != null &&
          errorMessage.toString().isNotEmpty) {
        final codeLabel = code != null
            ? '（code=$code，${errorMessage.toString()}）'
            : '：${errorMessage.toString()}';
        throw TtsException('TTS 2.0 请求失败$codeLabel');
      }
    }

    if (audioBytes.isEmpty && !sawTerminalSuccess) {
      throw const TtsException('TTS 2.0 响应为空');
    }

    _trace(
      'v3 stream packets=$packetCount audioPackets=$audioPacketCount '
      'bytes=${audioBytes.length} terminalSuccess=$sawTerminalSuccess',
    );

    return audioBytes;
  }

  static TtsException _mapDioException(
    DioException exception, {
    required String fallbackMessage,
  }) {
    final responseData = exception.response?.data;
    String? serverMessage;

    if (responseData is Map) {
      final candidate = responseData['message'] ??
          responseData['msg'] ??
          responseData['error'];
      if (candidate != null) {
        serverMessage = candidate.toString();
      }
    } else if (responseData is String && responseData.trim().isNotEmpty) {
      serverMessage = responseData.trim();
    }

    debugPrint(
      '[TtsService] request failed: ${exception.message}; status=${exception.response?.statusCode}',
    );

    if (serverMessage != null && serverMessage.isNotEmpty) {
      return TtsException('TTS 网络请求失败：$serverMessage');
    }
    return TtsException(fallbackMessage);
  }

  static int? _parsePacketCode(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  static String _resolveSpeakerId({
    required String configuredSpeakerId,
    required String requestedVoiceType,
  }) {
    final trimmedConfiguredSpeakerId = configuredSpeakerId.trim();
    if (trimmedConfiguredSpeakerId.isNotEmpty) {
      return trimmedConfiguredSpeakerId;
    }

    final trimmedRequestedVoiceType = requestedVoiceType.trim();
    if (trimmedRequestedVoiceType.isEmpty) {
      return '';
    }

    final isPresetSpeaker =
        voices.any((voice) => voice.id == trimmedRequestedVoiceType);
    if (!isPresetSpeaker) {
      return '';
    }

    return trimmedRequestedVoiceType;
  }

  static void _trace(String message) {
    if (!_audioTraceEnabled) {
      return;
    }
    debugPrint('[TtsTrace] $message');
  }
}
