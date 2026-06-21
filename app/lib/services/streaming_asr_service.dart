import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../core/config/app_config.dart';
import '../core/logging/tomato_logger.dart';
import 'api_cache_service.dart';

enum AsrFailureType {
  emptyAudio,
  missingApiKey,
  connectFailed,
  timeout,
  emptyResult,
  unknown,
}

class AsrException implements Exception {
  const AsrException(this.type, this.message);

  final AsrFailureType type;
  final String message;

  @override
  String toString() => message;
}

class AsrWordTiming {
  const AsrWordTiming({
    required this.text,
    required this.startMs,
    required this.endMs,
    this.confidence,
  });

  final String text;
  final int startMs;
  final int endMs;
  final double? confidence;

  Map<String, dynamic> toJson() => {
        'text': text,
        'startMs': startMs,
        'endMs': endMs,
        if (confidence != null) 'confidence': confidence,
      };
}

class AsrUtteranceTiming {
  const AsrUtteranceTiming({
    required this.text,
    required this.startMs,
    required this.endMs,
    required this.definite,
    required this.words,
  });

  final String text;
  final int startMs;
  final int endMs;
  final bool definite;
  final List<AsrWordTiming> words;

  Map<String, dynamic> toJson() => {
        'text': text,
        'startMs': startMs,
        'endMs': endMs,
        'definite': definite,
        'words': words.map((word) => word.toJson()).toList(),
      };
}

class AsrTimelineResult {
  const AsrTimelineResult({
    required this.text,
    required this.utterances,
    required this.raw,
    this.durationMs,
  });

  final String text;
  final List<AsrUtteranceTiming> utterances;
  final Map<String, dynamic> raw;
  final int? durationMs;

  List<AsrWordTiming> get words =>
      utterances.expand((utterance) => utterance.words).toList(growable: false);

  Map<String, dynamic> toJson() => {
        'text': text,
        'durationMs': durationMs,
        'utterances':
            utterances.map((utterance) => utterance.toJson()).toList(),
        'raw': raw,
      };
}

class StreamingAsrService {
  static const _audioTraceEnabled = bool.fromEnvironment(
    'TOMATO_AUDIO_TRACE',
    defaultValue: false,
  );

  // BigASR SAUC (stream upload) endpoint from docs/大模型流式语音识别API.md.
  static const _endpoint =
      'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream';
  static const _liveEndpoint =
      'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel';
  static const _chunkSize = 8 * 1024;
  static const _aliyunAudioDataLimit = 10 * 1024 * 1024;

  static const _protocolVersionAndHeader = 0x11; // v1 + 4-byte header
  static const _reservedByte = 0x00;

  static const _messageTypeFullClientRequest = 0x1;
  static const _messageTypeAudioOnlyRequest = 0x2;
  static const _messageTypeFullServerResponse = 0x9;
  static const _messageTypeError = 0xF;

  static const _serializationNone = 0x0;
  static const _serializationJson = 0x1;

  static const _compressionGzip = 0x1;

  static const _resourceIds = <String>[
    'volc.seedasr.sauc.duration',
    'volc.bigasr.sauc.duration',
    'volc.seedasr.sauc.concurrent',
    'volc.bigasr.sauc.concurrent',
  ];

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 30),
    ),
  );

  static Future<String> recognize({
    required List<int> audioBytes,
    int? articleId,
    String cachePurpose = 'asr_recognize',
    String audioMimeType = 'audio/wav',
  }) async {
    if (audioBytes.isEmpty) {
      throw const AsrException(AsrFailureType.emptyAudio, '录音为空，无法识别');
    }
    if (await AppConfig.aiProvider == AppConfig.aiProviderAliyunBailian) {
      return _recognizeAliyun(
        audioBytes: audioBytes,
        articleId: articleId,
        cachePurpose: cachePurpose,
        audioMimeType: audioMimeType,
      );
    }

    final audioFormat = _audioFormatFromMimeType(audioMimeType);
    final normalizedMimeType = _normalizeAudioMimeType(audioMimeType);
    final audioHash = await ApiCacheService.hashBytes(audioBytes);
    final cacheRequest = {
      'service': 'bigasr',
      'endpoint': _endpoint,
      'audioFormat': audioFormat,
      'audioMimeType': normalizedMimeType,
      if (audioFormat == 'wav' || audioFormat == 'pcm') ...{
        'sampleRate': 16000,
        'bits': 16,
        'channel': 1,
      },
      'language': 'en-US',
      'audioHash': audioHash,
    };
    final cacheKey = await ApiCacheService.keyForJson('asr', cacheRequest);
    final cachedText = await ApiCacheService.getText(
      cacheKey,
      articleId: articleId,
      purpose: cachePurpose,
    );
    if (cachedText != null && cachedText.trim().isNotEmpty) {
      return cachedText.trim();
    }

    final apiKey = await AppConfig.volcBigAsrApiKey;
    if (apiKey.trim().isEmpty) {
      throw const AsrException(
        AsrFailureType.missingApiKey,
        '未配置火山语音 API Key，请在设置的云服务中配置。',
      );
    }

    WebSocket? socket;
    final requestId = _newRequestId();
    try {
      _trace('connect requestId=$requestId bytes=${audioBytes.length}');
      socket = await _connectSocket(
        endpoint: _endpoint,
        apiKey: apiKey,
        requestId: requestId,
      );

      socket.add(_buildFullClientRequestFrame(audioFormat: audioFormat));

      var offset = 0;
      while (offset < audioBytes.length) {
        final end = min(offset + _chunkSize, audioBytes.length);
        final chunk = audioBytes.sublist(offset, end);
        final isLast = end >= audioBytes.length;

        socket.add(_buildAudioOnlyFrame(
          audioChunk: chunk,
          isLast: isLast,
        ));

        offset = end;
      }

      final completer = Completer<String>();
      final textBuffer = StringBuffer();
      final subscription = socket.listen((dynamic event) {
        final packet = _parseServerPacket(event);
        if (packet == null) {
          return;
        }

        if (packet.messageType == _messageTypeError) {
          if (!completer.isCompleted) {
            completer.completeError(
              AsrException(
                AsrFailureType.unknown,
                packet.errorMessage ?? 'BigASR 返回协议错误',
              ),
            );
          }
          return;
        }

        final delta = _extractText(packet.payloadMap);
        if (delta != null && delta.trim().isNotEmpty) {
          textBuffer
            ..clear()
            ..write(delta.trim());
          _trace('delta requestId=$requestId textLen=${delta.trim().length}');
        }

        if (packet.isTerminal && !completer.isCompleted) {
          _trace('terminalFrame requestId=$requestId');
          completer.complete(textBuffer.toString());
        }
      }, onDone: () {
        if (!completer.isCompleted) {
          completer.complete(textBuffer.toString());
        }
      }, onError: (Object error) {
        if (!completer.isCompleted) {
          completer.completeError(
            AsrException(
              AsrFailureType.unknown,
              'BigASR 连接中断：$error',
            ),
          );
        }
      });

      try {
        final recognized = await completer.future.timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw const AsrException(
            AsrFailureType.timeout,
            'BigASR 识别超时，请稍后重试',
          ),
        );

        if (recognized.trim().isEmpty) {
          throw const AsrException(
            AsrFailureType.emptyResult,
            'BigASR 未返回识别结果，请检查网络或本机语音配置',
          );
        }

        _trace(
            'success requestId=$requestId textLen=${recognized.trim().length}');
        final trimmedRecognized = recognized.trim();
        await ApiCacheService.putText(
          cacheKey: cacheKey,
          kind: 'asr',
          purpose: cachePurpose,
          request: cacheRequest,
          textValue: trimmedRecognized,
          articleId: articleId,
        );
        return trimmedRecognized;
      } finally {
        await subscription.cancel();
      }
    } on AsrException {
      rethrow;
    } on WebSocketException catch (e) {
      _trace('websocketError requestId=$requestId error=$e');
      throw AsrException(
        AsrFailureType.connectFailed,
        'BigASR 连接失败：$e',
      );
    } catch (e) {
      _trace('unknownError requestId=$requestId error=$e');
      throw AsrException(
        AsrFailureType.unknown,
        'BigASR 识别失败：$e',
      );
    } finally {
      await socket?.close();
    }
  }

  static Future<String> _recognizeAliyun({
    required List<int> audioBytes,
    int? articleId,
    String cachePurpose = 'asr_recognize',
    required String audioMimeType,
  }) async {
    final audioHash = await ApiCacheService.hashBytes(audioBytes);
    final endpoint = '${await AppConfig.aliyunBailianBaseUrl}/chat/completions';
    final model = await AppConfig.aliyunBailianAsrModel;
    final cacheRequest = {
      'service': 'aliyun_qwen_asr',
      'endpoint': endpoint,
      'model': model,
      'audioFormat': _audioFormatFromMimeType(audioMimeType),
      'audioMimeType': audioMimeType,
      if (_audioFormatFromMimeType(audioMimeType) == 'wav') ...{
        'sampleRate': 16000,
        'bits': 16,
        'channel': 1,
      },
      'language': 'en-US',
      'audioHash': audioHash,
    };
    final cacheKey = await ApiCacheService.keyForJson('asr', cacheRequest);
    final cachedText = await ApiCacheService.getText(
      cacheKey,
      articleId: articleId,
      purpose: cachePurpose,
    );
    if (cachedText != null && cachedText.trim().isNotEmpty) {
      return cachedText.trim();
    }

    final text = await _postAliyunAsr(
      audioBytes: audioBytes,
      audioMimeType: audioMimeType,
      endpoint: endpoint,
      model: model,
    );
    await ApiCacheService.putText(
      cacheKey: cacheKey,
      kind: 'asr',
      purpose: cachePurpose,
      request: cacheRequest,
      textValue: text,
      articleId: articleId,
    );
    return text;
  }

  static Future<AsrTimelineResult> _recognizeAliyunWithTimeline({
    required List<int> audioBytes,
    required String audioMimeType,
  }) async {
    final endpoint = '${await AppConfig.aliyunBailianBaseUrl}/chat/completions';
    final model = await AppConfig.aliyunBailianAsrModel;
    final text = await _postAliyunAsr(
      audioBytes: audioBytes,
      audioMimeType: audioMimeType,
      endpoint: endpoint,
      model: model,
    );
    return AsrTimelineResult(
      text: text,
      utterances: const [],
      raw: {
        'provider': AppConfig.aiProviderAliyunBailian,
        'model': model,
        'endpoint': endpoint,
        'audioFormat': _audioFormatFromMimeType(audioMimeType),
        'audioMimeType': audioMimeType,
      },
      durationMs: null,
    );
  }

  static Future<String> _postAliyunAsr({
    required List<int> audioBytes,
    required String audioMimeType,
    required String endpoint,
    required String model,
  }) async {
    final apiKey = await AppConfig.aliyunBailianApiKey;
    if (apiKey.trim().isEmpty) {
      throw const AsrException(
        AsrFailureType.missingApiKey,
        '未配置阿里云百炼 API Key，请在设置的云服务中配置。',
      );
    }
    final normalizedMimeType = _normalizeAudioMimeType(audioMimeType);
    final dataUri =
        'data:$normalizedMimeType;base64,${base64.encode(audioBytes)}';
    if (dataUri.length > _aliyunAudioDataLimit) {
      throw const AsrException(
        AsrFailureType.unknown,
        '阿里云 Qwen-ASR 音频 Base64 后超过 10MB 输入限制，请压缩音频或缩短后重试',
      );
    }
    try {
      final response = await _dio.post<Object?>(
        endpoint,
        data: {
          'model': model,
          'messages': [
            {
              'role': 'user',
              'content': [
                {
                  'type': 'input_audio',
                  'input_audio': {'data': dataUri},
                },
              ],
            },
          ],
          'stream': false,
          'asr_options': {
            'enable_itn': false,
            'language': 'en',
          },
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          responseType: ResponseType.json,
          validateStatus: (_) => true,
        ),
      );
      final statusCode = response.statusCode ?? 0;
      if (statusCode < 200 || statusCode >= 300) {
        throw AsrException(
          AsrFailureType.unknown,
          '阿里云 Qwen-ASR 请求失败 HTTP $statusCode：${_remoteErrorMessage(response.data)}',
        );
      }
      final text = _extractAliyunAsrText(response.data);
      if (text.trim().isEmpty) {
        throw const AsrException(
          AsrFailureType.emptyResult,
          '阿里云 Qwen-ASR 未返回识别结果',
        );
      }
      return text.trim();
    } on DioException catch (e) {
      throw AsrException(
        AsrFailureType.connectFailed,
        '阿里云 Qwen-ASR 网络请求失败：${e.message}',
      );
    } on AsrException {
      rethrow;
    } catch (e) {
      throw AsrException(
        AsrFailureType.unknown,
        '阿里云 Qwen-ASR 识别失败：$e',
      );
    }
  }

  static Future<AsrTimelineResult> recognizeWithTimeline({
    required List<int> audioBytes,
    String audioMimeType = 'audio/wav',
  }) async {
    if (audioBytes.isEmpty) {
      throw const AsrException(AsrFailureType.emptyAudio, '音频为空，无法识别');
    }
    if (await AppConfig.aiProvider == AppConfig.aiProviderAliyunBailian) {
      return _recognizeAliyunWithTimeline(
        audioBytes: audioBytes,
        audioMimeType: audioMimeType,
      );
    }

    final apiKey = await AppConfig.volcBigAsrApiKey;
    if (apiKey.trim().isEmpty) {
      throw const AsrException(
        AsrFailureType.missingApiKey,
        '未配置火山语音 API Key，请在设置的云服务中配置。',
      );
    }

    WebSocket? socket;
    final requestId = _newRequestId();
    try {
      _trace(
        'timeline connect requestId=$requestId bytes=${audioBytes.length}',
      );
      socket = await _connectSocket(
        endpoint: _endpoint,
        apiKey: apiKey,
        requestId: requestId,
      );

      final audioFormat = _audioFormatFromMimeType(audioMimeType);
      socket.add(_buildFullClientRequestFrame(
        audioFormat: audioFormat,
        enablePunc: false,
        showUtterances: true,
      ));

      var offset = 0;
      while (offset < audioBytes.length) {
        final end = min(offset + _chunkSize, audioBytes.length);
        final chunk = audioBytes.sublist(offset, end);
        final isLast = end >= audioBytes.length;

        socket.add(_buildAudioOnlyFrame(
          audioChunk: chunk,
          isLast: isLast,
        ));

        offset = end;
      }

      final completer = Completer<AsrTimelineResult>();
      Map<String, dynamic>? latestPayload;
      final subscription = socket.listen((dynamic event) {
        final packet = _parseServerPacket(event);
        if (packet == null) {
          return;
        }

        if (packet.messageType == _messageTypeError) {
          if (!completer.isCompleted) {
            completer.completeError(
              AsrException(
                AsrFailureType.unknown,
                packet.errorMessage ?? 'BigASR 返回协议错误',
              ),
            );
          }
          return;
        }

        final payload = packet.payloadMap;
        if (payload != null) {
          latestPayload = payload;
        }

        if (packet.isTerminal && !completer.isCompleted) {
          final result = _extractTimelineResult(latestPayload ?? payload);
          if (result == null || result.text.trim().isEmpty) {
            completer.completeError(
              const AsrException(
                AsrFailureType.emptyResult,
                'BigASR 未返回可用于字幕时间线的识别结果',
              ),
            );
            return;
          }
          completer.complete(result);
        }
      }, onDone: () {
        if (!completer.isCompleted) {
          final result = _extractTimelineResult(latestPayload);
          if (result == null || result.text.trim().isEmpty) {
            completer.completeError(
              const AsrException(
                AsrFailureType.emptyResult,
                'BigASR 未返回可用于字幕时间线的识别结果',
              ),
            );
            return;
          }
          completer.complete(result);
        }
      }, onError: (Object error) {
        if (!completer.isCompleted) {
          completer.completeError(
            AsrException(
              AsrFailureType.unknown,
              'BigASR 连接中断：$error',
            ),
          );
        }
      });

      try {
        final estimatedSeconds = max(1, audioBytes.length ~/ 32000);
        final timeoutSeconds = max(60, min(300, estimatedSeconds + 90));
        final result = await completer.future.timeout(
          Duration(seconds: timeoutSeconds),
          onTimeout: () => throw const AsrException(
            AsrFailureType.timeout,
            'BigASR 歌曲字幕识别超时，请稍后重试',
          ),
        );
        if (result.words.isEmpty) {
          throw const AsrException(
            AsrFailureType.emptyResult,
            'BigASR 未返回词级时间，无法生成歌曲字幕',
          );
        }
        return result;
      } finally {
        await subscription.cancel();
      }
    } on AsrException {
      rethrow;
    } on WebSocketException catch (e) {
      _trace('timeline websocketError requestId=$requestId error=$e');
      throw AsrException(
        AsrFailureType.connectFailed,
        'BigASR 连接失败：$e',
      );
    } catch (e) {
      _trace('timeline unknownError requestId=$requestId error=$e');
      throw AsrException(
        AsrFailureType.unknown,
        'BigASR 歌曲字幕识别失败：$e',
      );
    } finally {
      await socket?.close();
    }
  }

  static Future<String> recognizeLive({
    required Stream<List<int>> audioChunks,
    void Function(String text)? onPartial,
  }) async {
    if (await AppConfig.aiProvider == AppConfig.aiProviderAliyunBailian) {
      return _recognizeLiveAliyun(
        audioChunks: audioChunks,
        onPartial: onPartial,
      );
    }
    final apiKey = await AppConfig.volcBigAsrApiKey;
    if (apiKey.trim().isEmpty) {
      throw const AsrException(
        AsrFailureType.missingApiKey,
        '未配置火山语音 API Key，请在设置的云服务中配置。',
      );
    }

    WebSocket? socket;
    final requestId = _newRequestId();
    var sentAudio = false;
    try {
      _trace('live connect requestId=$requestId');
      socket = await _connectSocket(
        endpoint: _liveEndpoint,
        apiKey: apiKey,
        requestId: requestId,
      );

      socket.add(_buildFullClientRequestFrame(audioFormat: 'pcm'));

      final completer = Completer<String>();
      final textBuffer = StringBuffer();
      final subscription = socket.listen((dynamic event) {
        final packet = _parseServerPacket(event);
        if (packet == null) {
          return;
        }

        if (packet.messageType == _messageTypeError) {
          if (!completer.isCompleted) {
            completer.completeError(
              AsrException(
                AsrFailureType.unknown,
                packet.errorMessage ?? 'BigASR 返回协议错误',
              ),
            );
          }
          return;
        }

        final delta = _extractText(packet.payloadMap);
        if (delta != null && delta.trim().isNotEmpty) {
          final text = delta.trim();
          textBuffer
            ..clear()
            ..write(text);
          onPartial?.call(text);
          _trace('live delta requestId=$requestId textLen=${text.length}');
        }

        if (packet.isTerminal && !completer.isCompleted) {
          _trace('live terminalFrame requestId=$requestId');
          completer.complete(textBuffer.toString());
        }
      }, onDone: () {
        if (!completer.isCompleted) {
          completer.complete(textBuffer.toString());
        }
      }, onError: (Object error) {
        if (!completer.isCompleted) {
          completer.completeError(
            AsrException(
              AsrFailureType.unknown,
              'BigASR 连接中断：$error',
            ),
          );
        }
      });

      try {
        List<int>? pendingChunk;
        await for (final chunk in audioChunks) {
          if (chunk.isEmpty) {
            continue;
          }
          if (pendingChunk != null) {
            socket.add(_buildAudioOnlyFrame(
              audioChunk: pendingChunk,
              isLast: false,
            ));
            sentAudio = true;
          }
          pendingChunk = chunk;
        }

        if (pendingChunk != null) {
          socket.add(_buildAudioOnlyFrame(
            audioChunk: pendingChunk,
            isLast: true,
          ));
          sentAudio = true;
        }

        if (!sentAudio) {
          throw const AsrException(AsrFailureType.emptyAudio, '录音为空，无法识别');
        }

        final recognized = await completer.future.timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw const AsrException(
            AsrFailureType.timeout,
            'BigASR 识别超时，请稍后重试',
          ),
        );

        if (recognized.trim().isEmpty) {
          throw const AsrException(
            AsrFailureType.emptyResult,
            'BigASR 未返回识别结果，请检查网络或本机语音配置',
          );
        }

        _trace(
          'live success requestId=$requestId textLen=${recognized.trim().length}',
        );
        return recognized.trim();
      } finally {
        await subscription.cancel();
      }
    } on AsrException {
      rethrow;
    } on WebSocketException catch (e) {
      _trace('live websocketError requestId=$requestId error=$e');
      throw AsrException(
        AsrFailureType.connectFailed,
        'BigASR 连接失败：$e',
      );
    } catch (e) {
      _trace('live unknownError requestId=$requestId error=$e');
      throw AsrException(
        AsrFailureType.unknown,
        'BigASR 识别失败：$e',
      );
    } finally {
      await socket?.close();
    }
  }

  static Future<String> _recognizeLiveAliyun({
    required Stream<List<int>> audioChunks,
    void Function(String text)? onPartial,
  }) async {
    final apiKey = await AppConfig.aliyunBailianApiKey;
    if (apiKey.trim().isEmpty) {
      throw const AsrException(
        AsrFailureType.missingApiKey,
        '未配置阿里云百炼 API Key，请在设置的云服务中配置。',
      );
    }

    WebSocket? socket;
    var sentAudio = false;
    try {
      socket = await WebSocket.connect(
        await AppConfig.aliyunRealtimeAsrEndpoint,
        headers: <String, String>{
          'Authorization': 'Bearer $apiKey',
          'user-agent': 'TomatoEnglishHappyTalking',
        },
      );
      socket.add(jsonEncode({
        'type': 'session.update',
        'session': {
          'input_audio_format': 'pcm16',
          'turn_detection': null,
          'input_audio_transcription': {
            'language': 'en',
          },
        },
      }));

      final completer = Completer<String>();
      final textBuffer = StringBuffer();
      final subscription = socket.listen((dynamic event) {
        final payload = _jsonEvent(event);
        if (payload.isEmpty) {
          return;
        }
        final type = payload['type']?.toString() ?? '';
        if (type == 'error') {
          if (!completer.isCompleted) {
            completer.completeError(
              AsrException(
                AsrFailureType.unknown,
                '阿里云实时 ASR 返回错误：${_remoteErrorMessage(payload)}',
              ),
            );
          }
          return;
        }
        if (type.endsWith('.text') || type.endsWith('.completed')) {
          final text = _transcriptionTextFromEvent(payload);
          if (text.trim().isNotEmpty) {
            textBuffer
              ..clear()
              ..write(text.trim());
            onPartial?.call(text.trim());
          }
        }
        if (type == 'session.finished' && !completer.isCompleted) {
          completer.complete(textBuffer.toString());
        }
      }, onDone: () {
        if (!completer.isCompleted) {
          completer.complete(textBuffer.toString());
        }
      }, onError: (Object error) {
        if (!completer.isCompleted) {
          completer.completeError(
            AsrException(
              AsrFailureType.unknown,
              '阿里云实时 ASR 连接中断：$error',
            ),
          );
        }
      });

      try {
        await for (final chunk in audioChunks) {
          if (chunk.isEmpty) {
            continue;
          }
          socket.add(jsonEncode({
            'type': 'input_audio_buffer.append',
            'audio': base64.encode(chunk),
          }));
          sentAudio = true;
        }
        if (!sentAudio) {
          throw const AsrException(AsrFailureType.emptyAudio, '录音为空，无法识别');
        }
        socket.add(jsonEncode({'type': 'input_audio_buffer.commit'}));
        socket.add(jsonEncode({'type': 'session.finish'}));
        final recognized = await completer.future.timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw const AsrException(
            AsrFailureType.timeout,
            '阿里云实时 ASR 识别超时，请稍后重试',
          ),
        );
        if (recognized.trim().isEmpty) {
          throw const AsrException(
            AsrFailureType.emptyResult,
            '阿里云实时 ASR 未返回识别结果',
          );
        }
        return recognized.trim();
      } finally {
        await subscription.cancel();
      }
    } on AsrException {
      rethrow;
    } on WebSocketException catch (e) {
      throw AsrException(
        AsrFailureType.connectFailed,
        '阿里云实时 ASR 连接失败：$e',
      );
    } catch (e) {
      throw AsrException(
        AsrFailureType.unknown,
        '阿里云实时 ASR 识别失败：$e',
      );
    } finally {
      await socket?.close();
    }
  }

  static Future<String> recognizeSafe({
    required List<int> audioBytes,
    int? articleId,
  }) async {
    try {
      return await recognize(
        audioBytes: audioBytes,
        articleId: articleId,
      );
    } catch (_) {
      return '';
    }
  }

  static AsrTimelineResult? timelineResultFromPayloadForTest(
    Map<String, dynamic> payload,
  ) =>
      _extractTimelineResult(payload);

  static String _normalizeAudioMimeType(String mimeType) {
    final normalized = mimeType.trim().toLowerCase();
    if (normalized.isEmpty) {
      return 'audio/wav';
    }
    if (normalized == 'audio/mp3') {
      return 'audio/mpeg';
    }
    return normalized;
  }

  static String _audioFormatFromMimeType(String mimeType) {
    final normalized = _normalizeAudioMimeType(mimeType);
    switch (normalized) {
      case 'audio/mpeg':
        return 'mp3';
      case 'audio/mp4':
      case 'audio/aac':
        return 'aac';
      case 'audio/flac':
      case 'audio/x-flac':
        return 'flac';
      case 'audio/ogg':
      case 'audio/opus':
        return 'ogg';
      case 'audio/wav':
      case 'audio/x-wav':
      default:
        return 'wav';
    }
  }

  static String _extractAliyunAsrText(Object? payload) {
    final map = _mapValue(payload);
    final choices = map['choices'];
    if (choices is List && choices.isNotEmpty) {
      final first = _mapValue(choices.first);
      final message = _mapValue(first['message']);
      final content = message['content'];
      if (content is String) {
        return content.trim();
      }
      if (content is List) {
        return content
            .map((item) {
              if (item is String) {
                return item;
              }
              final itemMap = _mapValue(item);
              return itemMap['text'] ?? itemMap['content'] ?? '';
            })
            .join(' ')
            .trim();
      }
    }
    return '';
  }

  static Map<String, dynamic> _jsonEvent(Object? event) {
    try {
      final decoded = event is String
          ? jsonDecode(event)
          : event is List<int>
              ? jsonDecode(utf8.decode(event))
              : event;
      return _mapValue(decoded);
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  static String _transcriptionTextFromEvent(Map<String, dynamic> payload) {
    for (final key in const [
      'text',
      'transcript',
      'content',
      'delta',
      'final_text',
    ]) {
      final value = payload[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) {
        return value;
      }
    }
    final item = _mapValue(payload['item']);
    final itemText =
        item['text'] ?? item['transcript'] ?? item['content'] ?? item['delta'];
    if (itemText != null && itemText.toString().trim().isNotEmpty) {
      return itemText.toString().trim();
    }
    final transcription = _mapValue(payload['transcription']);
    final text = transcription['text'] ?? transcription['transcript'];
    return text?.toString().trim() ?? '';
  }

  static Map<String, dynamic> _mapValue(Object? raw) {
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return const <String, dynamic>{};
  }

  static String _remoteErrorMessage(Object? raw) {
    final map = _mapValue(raw);
    final error = _mapValue(map['error']);
    final message = error['message'] ??
        map['message'] ??
        map['msg'] ??
        map['code'] ??
        map['type'];
    if (message != null && message.toString().trim().isNotEmpty) {
      return message.toString().trim();
    }
    return raw?.toString() ?? '未知错误';
  }

  static Future<WebSocket> _connectSocket({
    required String endpoint,
    required String apiKey,
    required String requestId,
  }) async {
    final errors = <String>[];

    for (final resourceId in _resourceIds) {
      try {
        _trace(
          'connect try requestId=$requestId resourceId=$resourceId auth=X-Api-Key',
        );
        return await WebSocket.connect(
          endpoint,
          headers: <String, String>{
            'X-Api-Key': apiKey,
            'X-Api-Resource-Id': resourceId,
            'X-Api-Request-Id': requestId,
            'X-Api-Sequence': '-1',
          },
        );
      } on WebSocketException catch (e) {
        final detail = 'resourceId=$resourceId error=$e';
        _trace('connect failed requestId=$requestId $detail');
        errors.add(detail);
      }
    }

    throw AsrException(
      AsrFailureType.connectFailed,
      'BigASR 连接失败，请检查网络、本机语音配置或 ResourceId（${errors.join(' | ')}）',
    );
  }

  static List<int> _buildFullClientRequestFrame({
    required String audioFormat,
    bool enablePunc = true,
    bool showUtterances = false,
  }) {
    final payloadMap = <String, dynamic>{
      'user': {
        'uid': 'tomato_app',
      },
      'audio': {
        'format': audioFormat,
        if (audioFormat == 'ogg') 'codec': 'opus',
        'rate': 16000,
        'bits': 16,
        'channel': 1,
        'language': 'en-US',
      },
      'request': {
        'model_name': 'bigmodel',
        'enable_itn': true,
        'enable_punc': enablePunc,
        if (showUtterances) 'show_utterances': true,
      },
    };

    final payload = gzip.encode(utf8.encode(jsonEncode(payloadMap)));
    return _buildFrame(
      messageType: _messageTypeFullClientRequest,
      flags: 0x0,
      serialization: _serializationJson,
      compression: _compressionGzip,
      payload: payload,
    );
  }

  static List<int> _buildAudioOnlyFrame({
    required List<int> audioChunk,
    required bool isLast,
  }) {
    final payload = gzip.encode(audioChunk);
    return _buildFrame(
      messageType: _messageTypeAudioOnlyRequest,
      flags: isLast ? 0x2 : 0x0,
      serialization: _serializationNone,
      compression: _compressionGzip,
      payload: payload,
    );
  }

  static List<int> _buildFrame({
    required int messageType,
    required int flags,
    required int serialization,
    required int compression,
    required List<int> payload,
  }) {
    final bytes = BytesBuilder();
    bytes.addByte(_protocolVersionAndHeader);
    bytes.addByte((messageType << 4) | (flags & 0x0F));
    bytes.addByte((serialization << 4) | (compression & 0x0F));
    bytes.addByte(_reservedByte);
    bytes.add(_int32Bytes(payload.length));
    bytes.add(payload);
    return bytes.toBytes();
  }

  static _AsrServerPacket? _parseServerPacket(dynamic event) {
    if (event is String && event.trim().isNotEmpty) {
      // Some gateways may emit plain text debug payloads.
      return _AsrServerPacket(
        messageType: _messageTypeFullServerResponse,
        flags: 0,
        payloadMap: _safeJsonMap(event),
        isTerminal: false,
      );
    }

    if (event is! List<int> || event.length < 8) {
      return null;
    }

    final data = Uint8List.fromList(event);
    final messageType = (data[1] >> 4) & 0x0F;
    final flags = data[1] & 0x0F;
    final serialization = (data[2] >> 4) & 0x0F;
    final compression = data[2] & 0x0F;

    var offset = 4;
    int? errorCode;

    if (messageType == _messageTypeError) {
      if (data.length < offset + 4) {
        return null;
      }
      errorCode = _readInt32(data, offset);
      offset += 4;
    }

    if (messageType == _messageTypeFullServerResponse &&
        (flags == 0x1 || flags == 0x3)) {
      if (data.length < offset + 4) {
        return null;
      }
      offset += 4;
    }

    if (data.length < offset + 4) {
      return null;
    }

    final payloadSize = _readInt32(data, offset);
    offset += 4;

    if (payloadSize < 0 || data.length < offset + payloadSize) {
      return null;
    }

    var payload = data.sublist(offset, offset + payloadSize);
    if (compression == _compressionGzip) {
      payload = Uint8List.fromList(gzip.decode(payload));
    }

    Map<String, dynamic>? payloadMap;
    String? errorMessage;

    if (serialization == _serializationJson) {
      final text = utf8.decode(payload, allowMalformed: true);
      payloadMap = _safeJsonMap(text);
      errorMessage = payloadMap?['error']?.toString();
    }

    if (messageType == _messageTypeError) {
      final fallback = errorCode != null ? 'code=$errorCode' : 'unknown';
      return _AsrServerPacket(
        messageType: messageType,
        flags: flags,
        payloadMap: payloadMap,
        isTerminal: true,
        errorMessage: errorMessage ?? 'BigASR 协议错误（$fallback）',
      );
    }

    final terminal = flags == 0x3;
    return _AsrServerPacket(
      messageType: messageType,
      flags: flags,
      payloadMap: payloadMap,
      isTerminal: terminal,
    );
  }

  static Map<String, dynamic>? _safeJsonMap(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static int _readInt32(Uint8List data, int offset) {
    final byteData = ByteData.sublistView(data, offset, offset + 4);
    return byteData.getInt32(0, Endian.big);
  }

  static List<int> _int32Bytes(int value) {
    final byteData = ByteData(4)..setInt32(0, value, Endian.big);
    return byteData.buffer.asUint8List();
  }

  static String? _extractText(Map<String, dynamic>? frame) {
    if (frame == null) {
      return null;
    }

    final payload = frame['payload'];
    if (payload is Map<String, dynamic>) {
      final inPayload = _extractTextFromMap(payload);
      if (inPayload != null) {
        return inPayload;
      }
    }

    return _extractTextFromMap(frame);
  }

  static String? _extractTextFromMap(Map<String, dynamic> source) {
    final direct = source['text']?.toString();
    if (direct != null && direct.trim().isNotEmpty) {
      return direct;
    }

    final transcript = source['transcript']?.toString();
    if (transcript != null && transcript.trim().isNotEmpty) {
      return transcript;
    }

    final result = source['result'];
    if (result is Map<String, dynamic>) {
      final recognized = result['text']?.toString();
      if (recognized != null && recognized.trim().isNotEmpty) {
        return recognized;
      }
    }

    final results = source['results'];
    if (results is List && results.isNotEmpty) {
      final first = results.first;
      if (first is Map<String, dynamic>) {
        final recognized = first['text']?.toString();
        if (recognized != null && recognized.trim().isNotEmpty) {
          return recognized;
        }
      }
    }

    return null;
  }

  static AsrTimelineResult? _extractTimelineResult(
    Map<String, dynamic>? frame,
  ) {
    if (frame == null) {
      return null;
    }
    final source = _payloadSource(frame);
    final text = _extractTextFromMap(source)?.trim() ??
        _extractText(frame)?.trim() ??
        '';
    final result = source['result'];
    final resultMap = result is Map<String, dynamic>
        ? result
        : result is Map
            ? Map<String, dynamic>.from(result)
            : source;
    final rawUtterances = resultMap['utterances'];
    final utterances = <AsrUtteranceTiming>[];
    if (rawUtterances is List) {
      for (final rawUtterance in rawUtterances) {
        final utterance = _parseUtterance(rawUtterance);
        if (utterance != null) {
          utterances.add(utterance);
        }
      }
    }
    final audioInfo = source['audio_info'] is Map
        ? Map<String, dynamic>.from(source['audio_info'] as Map)
        : frame['audio_info'] is Map
            ? Map<String, dynamic>.from(frame['audio_info'] as Map)
            : const <String, dynamic>{};
    final durationMs = (audioInfo['duration'] as num?)?.toInt();
    return AsrTimelineResult(
      text: text,
      utterances: utterances,
      durationMs: durationMs,
      raw: source,
    );
  }

  static Map<String, dynamic> _payloadSource(Map<String, dynamic> frame) {
    final payload = frame['payload'];
    if (payload is Map<String, dynamic>) {
      return payload;
    }
    if (payload is Map) {
      return Map<String, dynamic>.from(payload);
    }
    return frame;
  }

  static AsrUtteranceTiming? _parseUtterance(Object? value) {
    if (value is! Map) {
      return null;
    }
    final source = Map<String, dynamic>.from(value);
    final text = source['text']?.toString().trim() ?? '';
    final startMs = (source['start_time'] as num?)?.toInt() ??
        (source['startMs'] as num?)?.toInt() ??
        0;
    final endMs = (source['end_time'] as num?)?.toInt() ??
        (source['endMs'] as num?)?.toInt() ??
        startMs;
    final words = <AsrWordTiming>[];
    final rawWords = source['words'];
    if (rawWords is List) {
      for (final rawWord in rawWords) {
        final word = _parseWord(rawWord);
        if (word != null) {
          words.add(word);
        }
      }
    }
    return AsrUtteranceTiming(
      text: text,
      startMs: startMs,
      endMs: max(endMs, startMs),
      definite: source['definite'] == true,
      words: words,
    );
  }

  static AsrWordTiming? _parseWord(Object? value) {
    if (value is! Map) {
      return null;
    }
    final source = Map<String, dynamic>.from(value);
    final text = source['text']?.toString().trim() ?? '';
    if (text.isEmpty) {
      return null;
    }
    final startMs = (source['start_time'] as num?)?.toInt() ??
        (source['startMs'] as num?)?.toInt();
    final endMs = (source['end_time'] as num?)?.toInt() ??
        (source['endMs'] as num?)?.toInt();
    if (startMs == null || endMs == null) {
      return null;
    }
    final confidence = _parseConfidence(source);
    return AsrWordTiming(
      text: text,
      startMs: max(0, startMs),
      endMs: max(startMs, endMs),
      confidence: confidence,
    );
  }

  static double? _parseConfidence(Map<String, dynamic> source) {
    const keys = [
      'confidence',
      'confidence_score',
      'score',
      'probability',
      'prob',
    ];
    for (final key in keys) {
      final value = source[key];
      if (value is! num) {
        continue;
      }
      final raw = value.toDouble();
      if (!raw.isFinite || raw < 0) {
        continue;
      }
      return raw > 1 ? (raw / 100).clamp(0.0, 1.0) : raw.clamp(0.0, 1.0);
    }
    return null;
  }

  static String _newRequestId() {
    final time = DateTime.now().microsecondsSinceEpoch;
    final rand = Random().nextInt(1 << 20);
    return 'asr_${time}_$rand';
  }

  static void _trace(String message) {
    if (!_audioTraceEnabled) {
      return;
    }
    TomatoLogger.trace(
      category: 'asr',
      event: 'trace',
      message: message,
      data: {'tag': 'AsrTrace'},
      force: true,
    );
  }
}

class _AsrServerPacket {
  const _AsrServerPacket({
    required this.messageType,
    required this.flags,
    required this.payloadMap,
    required this.isTerminal,
    this.errorMessage,
  });

  final int messageType;
  final int flags;
  final Map<String, dynamic>? payloadMap;
  final bool isTerminal;
  final String? errorMessage;
}
