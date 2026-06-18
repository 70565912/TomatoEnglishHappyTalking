import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/config/app_config.dart';
import '../core/logging/tomato_logger.dart';
import 'api_cache_service.dart';
import 'content_safety_service.dart';

enum TextGenerationReplySource {
  remote,
  cached,
  stored,
}

class TextGenerationTurn {
  const TextGenerationTurn({required this.role, required this.content});

  final String role;
  final String content;

  Map<String, String> toJson() => {
        'role': role,
        'content': content,
      };
}

class TextGenerationReply {
  const TextGenerationReply({
    required this.text,
    required this.source,
    this.errorMessage,
  });

  final String text;
  final TextGenerationReplySource source;
  final String? errorMessage;
}

class TextGenerationException implements Exception {
  const TextGenerationException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

typedef TextGenerationPostOverride = Future<Object?> Function({
  required String endpoint,
  required Map<String, String> headers,
  required Map<String, dynamic> body,
});

class TextGenerationService {
  static const _cacheNamespace = 'openai_text';

  static final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 45),
    ),
  );

  static TextGenerationPostOverride? _postOverrideForTest;

  @visibleForTesting
  static void setPostOverrideForTest(TextGenerationPostOverride? override) {
    _postOverrideForTest = override;
  }

  static Future<TextGenerationReply> generateStrict({
    required List<TextGenerationTurn> turns,
    required String cachePurpose,
    int? articleId,
    int maxTokens = 1024,
    Duration? receiveTimeout,
    bool jsonResponse = false,
    bool skipCacheRead = false,
    bool skipCacheWrite = false,
  }) async {
    final stopwatch = Stopwatch()..start();
    final preparedTurns = await _prepareTurnsForApi(
      turns,
      purpose: cachePurpose,
    );
    final config = await AppConfig.openAiTextConfig;
    final request = _cacheRequest(
      config: config,
      turns: preparedTurns,
      purpose: cachePurpose,
      maxTokens: maxTokens,
      jsonResponse: jsonResponse,
    );
    final cacheKey = await ApiCacheService.keyForJson(
      _cacheNamespace,
      request,
    );
    if (!skipCacheRead) {
      final cachedText = await ApiCacheService.getText(
        cacheKey,
        articleId: articleId,
        purpose: cachePurpose,
      );
      if (cachedText != null && cachedText.trim().isNotEmpty) {
        _logCompletion(
          event: 'chat.generateStrict',
          config: config,
          cachePurpose: cachePurpose,
          articleId: articleId,
          maxTokens: maxTokens,
          durationMs: stopwatch.elapsedMilliseconds,
          source: TextGenerationReplySource.cached,
          jsonResponse: jsonResponse,
          skipCacheRead: skipCacheRead,
          skipCacheWrite: skipCacheWrite,
        );
        return TextGenerationReply(
          text: cachedText,
          source: TextGenerationReplySource.cached,
        );
      }
    }

    final apiKey = config.apiKey;
    if (apiKey.trim().isEmpty) {
      final error = TextGenerationException(
        '文本提交处理失败：未配置 ${_providerLabel(config.provider)} API Key，请在设置中配置后重试。',
      );
      _logFailure(
        event: 'chat.generateStrict',
        config: config,
        cachePurpose: cachePurpose,
        articleId: articleId,
        maxTokens: maxTokens,
        durationMs: stopwatch.elapsedMilliseconds,
        error: error,
        jsonResponse: jsonResponse,
        skipCacheRead: skipCacheRead,
        skipCacheWrite: skipCacheWrite,
      );
      throw error;
    }

    try {
      final body = <String, dynamic>{
        'model': config.model,
        'messages':
            preparedTurns.map((turn) => turn.toJson()).toList(growable: false),
        'max_tokens': maxTokens,
        'stream': false,
        if (jsonResponse) 'response_format': {'type': 'json_object'},
      };
      final responseData = await _postJson(
        config: config,
        body: body,
        receiveTimeout: receiveTimeout,
      );
      final text = _extractMessageContent(responseData).trim();
      if (text.isEmpty) {
        throw const FormatException(
            'OpenAI-compatible response has no message content');
      }
      if (!skipCacheWrite) {
        await ApiCacheService.putText(
          cacheKey: cacheKey,
          kind: _cacheNamespace,
          purpose: cachePurpose,
          request: request,
          textValue: text,
          articleId: articleId,
        );
      }
      await ContentSafetyService.learnRulesFromLatestSuccessfulRetry(
        serviceKind: ContentSafetyService.serviceOpenAiText,
        purpose: cachePurpose,
        articleId: articleId,
        successfulText: _requestTranscript(preparedTurns),
      );
      _logCompletion(
        event: 'chat.generateStrict',
        config: config,
        cachePurpose: cachePurpose,
        articleId: articleId,
        maxTokens: maxTokens,
        durationMs: stopwatch.elapsedMilliseconds,
        source: TextGenerationReplySource.remote,
        jsonResponse: jsonResponse,
        skipCacheRead: skipCacheRead,
        skipCacheWrite: skipCacheWrite,
      );
      return TextGenerationReply(
        text: text,
        source: TextGenerationReplySource.remote,
      );
    } catch (error) {
      final errorSummary = _errorSummary(error);
      final safety = ContentSafetyService.classifyFailure(error);
      if (safety.suspectedSafetyBlock) {
        await ContentSafetyService.recordFailure(
          serviceKind: ContentSafetyService.serviceOpenAiText,
          purpose: cachePurpose,
          articleId: articleId,
          failedText: _requestTranscript(turns),
          errorCode: safety.errorCode,
          errorMessage: safety.message,
        );
      }
      debugPrint('[TextGenerationService] strict error=$errorSummary');
      _logFailure(
        event: 'chat.generateStrict',
        config: config,
        cachePurpose: cachePurpose,
        articleId: articleId,
        maxTokens: maxTokens,
        durationMs: stopwatch.elapsedMilliseconds,
        error: error,
        jsonResponse: jsonResponse,
        skipCacheRead: skipCacheRead,
        skipCacheWrite: skipCacheWrite,
      );
      throw TextGenerationException(
        _strictUserMessage(error),
        cause: error,
      );
    }
  }

  @visibleForTesting
  static Future<Map<String, dynamic>> cacheRequestForTest({
    required List<TextGenerationTurn> turns,
    required String purpose,
    int maxTokens = 1024,
    bool jsonResponse = false,
  }) async {
    final preparedTurns = await _prepareTurnsForApi(
      turns,
      purpose: purpose,
    );
    final config = await AppConfig.openAiTextConfig;
    return _cacheRequest(
      config: config,
      turns: preparedTurns,
      purpose: purpose,
      maxTokens: maxTokens,
      jsonResponse: jsonResponse,
    );
  }

  static Future<List<TextGenerationTurn>> _prepareTurnsForApi(
    List<TextGenerationTurn> turns, {
    required String purpose,
  }) async {
    final prepared = <TextGenerationTurn>[];
    for (final turn in turns) {
      prepared.add(
        TextGenerationTurn(
          role: turn.role,
          content: await ContentSafetyService.prepareTextForApi(
            turn.content,
            serviceKind: ContentSafetyService.serviceOpenAiText,
            purpose: purpose,
          ),
        ),
      );
    }
    return prepared;
  }

  static String _requestTranscript(List<TextGenerationTurn> turns) =>
      turns.map((turn) => '${turn.role}: ${turn.content}').join('\n\n').trim();

  static Future<Object?> _postJson({
    required OpenAiTextConfig config,
    required Map<String, dynamic> body,
    Duration? receiveTimeout,
  }) async {
    final apiKey = config.apiKey;
    final headers = <String, String>{
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
    };
    final override = _postOverrideForTest;
    if (override != null) {
      return override(
        endpoint: config.chatCompletionsEndpoint,
        headers: headers,
        body: body,
      );
    }

    final response = await _dio.post<dynamic>(
      config.chatCompletionsEndpoint,
      data: body,
      options: Options(
        headers: headers,
        receiveTimeout: receiveTimeout,
      ),
    );
    return response.data;
  }

  static String _strictUserMessage(Object error) {
    if (error is TextGenerationException) {
      return error.message;
    }
    if (error is DioException &&
        error.type == DioExceptionType.receiveTimeout) {
      return '文本提交处理超时，请稍后重试。';
    }
    if (error is DioException &&
        error.type == DioExceptionType.connectionTimeout) {
      return '文本提交连接超时，请检查网络后重试。';
    }
    if (error is FormatException) {
      return '文本提交处理失败：AI 返回内容格式不正确，请重试。';
    }
    return '文本提交处理失败，请稍后重试。';
  }

  static Map<String, dynamic> _cacheRequest({
    required OpenAiTextConfig config,
    required List<TextGenerationTurn> turns,
    required String purpose,
    required int maxTokens,
    bool jsonResponse = false,
  }) =>
      {
        'service': 'openai_chat_completions',
        'provider': config.provider,
        'baseUrl': config.baseUrl,
        'endpoint': config.chatCompletionsEndpoint,
        'model': config.model,
        'purpose': purpose,
        'maxTokens': maxTokens,
        'stream': false,
        if (jsonResponse) 'responseFormat': 'json_object',
        'messages': turns.map((turn) => turn.toJson()).toList(growable: false),
      };

  static void _logCompletion({
    required String event,
    required OpenAiTextConfig config,
    required String cachePurpose,
    required int? articleId,
    required int maxTokens,
    required int durationMs,
    required TextGenerationReplySource source,
    bool jsonResponse = false,
    bool skipCacheRead = false,
    bool skipCacheWrite = false,
  }) {
    TomatoLogger.info(
      category: 'text_generation',
      event: event,
      articleId: articleId,
      status: _replySourceName(source),
      durationMs: durationMs,
      data: _logData(
        config: config,
        cachePurpose: cachePurpose,
        maxTokens: maxTokens,
        jsonResponse: jsonResponse,
        skipCacheRead: skipCacheRead,
        skipCacheWrite: skipCacheWrite,
      ),
    );
  }

  static void _logFailure({
    required String event,
    required OpenAiTextConfig config,
    required String cachePurpose,
    required int? articleId,
    required int maxTokens,
    required int durationMs,
    required Object error,
    bool jsonResponse = false,
    bool skipCacheRead = false,
    bool skipCacheWrite = false,
  }) {
    TomatoLogger.warn(
      category: 'text_generation',
      event: event,
      articleId: articleId,
      status: 'error',
      durationMs: durationMs,
      error: error.runtimeType.toString(),
      data: {
        ..._logData(
          config: config,
          cachePurpose: cachePurpose,
          maxTokens: maxTokens,
          jsonResponse: jsonResponse,
          skipCacheRead: skipCacheRead,
          skipCacheWrite: skipCacheWrite,
        ),
        if (error is DioException) ...{
          'dioType': error.type.name,
          'statusCode': error.response?.statusCode,
        },
      },
    );
  }

  static Map<String, dynamic> _logData({
    required OpenAiTextConfig config,
    required String cachePurpose,
    required int maxTokens,
    required bool jsonResponse,
    required bool skipCacheRead,
    required bool skipCacheWrite,
  }) =>
      {
        'provider': config.provider,
        'model': config.model,
        'purpose': cachePurpose,
        'maxTokens': maxTokens,
        'jsonResponse': jsonResponse,
        'skipCacheRead': skipCacheRead,
        'skipCacheWrite': skipCacheWrite,
      };

  static String _replySourceName(TextGenerationReplySource source) =>
      switch (source) {
        TextGenerationReplySource.remote => 'remote',
        TextGenerationReplySource.cached => 'cached',
        TextGenerationReplySource.stored => 'stored',
      };

  static String _providerLabel(String provider) =>
      provider == AppConfig.aiProviderVolcengine ? '火山方舟' : '阿里云百炼';

  static String _extractMessageContent(Object? responseData) {
    final decoded =
        responseData is String ? jsonDecode(responseData) : responseData;
    if (decoded is! Map) {
      return '';
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      return '';
    }
    final firstChoice = choices.first;
    if (firstChoice is! Map) {
      return '';
    }
    final message = firstChoice['message'];
    if (message is! Map) {
      return '';
    }
    final content = message['content'];
    if (content is String) {
      return content;
    }
    if (content is List) {
      return content
          .map((part) {
            if (part is Map) {
              return part['text']?.toString() ?? '';
            }
            return part.toString();
          })
          .where((part) => part.trim().isNotEmpty)
          .join();
    }
    return '';
  }

  static String _errorSummary(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      final data = error.response?.data;
      final body = data == null ? '' : data.toString();
      return 'DioException status=$status message=${error.message} body=$body';
    }
    return error.toString();
  }
}
