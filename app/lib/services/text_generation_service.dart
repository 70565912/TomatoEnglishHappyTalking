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
    this.provider,
    this.model,
    this.usage = const TextGenerationUsage(),
  });

  final String text;
  final TextGenerationReplySource source;
  final String? errorMessage;
  final String? provider;
  final String? model;
  final TextGenerationUsage usage;
}

class TextGenerationUsage {
  const TextGenerationUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.totalTokens = 0,
    this.estimatedCostCny,
  });

  final int inputTokens;
  final int outputTokens;
  final int totalTokens;
  final double? estimatedCostCny;

  Map<String, dynamic> toJson() => {
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'totalTokens': totalTokens,
        'estimatedCostCny': estimatedCostCny,
      };
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

typedef TextGenerationTextValidator = void Function(String text);
typedef TextGenerationTextCachePredicate = bool Function(String text);

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
    double? temperature,
    bool disableThinking = false,
    TextGenerationTextValidator? validateText,
    TextGenerationTextCachePredicate? shouldCacheText,
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
      temperature: temperature,
      disableThinking: disableThinking,
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
        try {
          validateText?.call(cachedText);
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
            usage: const TextGenerationUsage(),
          );
          return TextGenerationReply(
            text: cachedText,
            source: TextGenerationReplySource.cached,
            provider: config.provider,
            model: config.model,
          );
        } catch (error) {
          debugPrint(
            '[TextGenerationService] ignored invalid cached response '
            'purpose=$cachePurpose error=${_errorSummary(error)}',
          );
        }
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
        if (temperature != null) 'temperature': temperature,
        if (disableThinking &&
            config.provider == AppConfig.aiProviderAliyunBailian)
          'enable_thinking': false,
        if (disableThinking &&
            config.provider == AppConfig.aiProviderVolcengine)
          'thinking': {'type': 'disabled'},
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
      validateText?.call(text);
      if (!skipCacheWrite && (shouldCacheText?.call(text) ?? true)) {
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
      final usage = _extractUsage(
        responseData,
        provider: config.provider,
        model: config.model,
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
        usage: usage,
      );
      return TextGenerationReply(
        text: text,
        source: TextGenerationReplySource.remote,
        provider: config.provider,
        model: config.model,
        usage: usage,
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

  /// Reads and validates a strict-generation cache entry without performing a
  /// remote request. This lets multi-round protocols reuse a successful
  /// expanded-round decision before paying for the initial round again.
  static Future<TextGenerationReply?> readStrictCache({
    required List<TextGenerationTurn> turns,
    required String cachePurpose,
    int? articleId,
    int maxTokens = 1024,
    bool jsonResponse = false,
    double? temperature,
    bool disableThinking = false,
    TextGenerationTextValidator? validateText,
  }) async {
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
      temperature: temperature,
      disableThinking: disableThinking,
    );
    final cacheKey = await ApiCacheService.keyForJson(
      _cacheNamespace,
      request,
    );
    final cachedText = await ApiCacheService.getText(
      cacheKey,
      articleId: articleId,
      purpose: cachePurpose,
    );
    if (cachedText == null || cachedText.trim().isEmpty) return null;
    try {
      validateText?.call(cachedText);
      return TextGenerationReply(
        text: cachedText,
        source: TextGenerationReplySource.cached,
        provider: config.provider,
        model: config.model,
      );
    } catch (error) {
      debugPrint(
        '[TextGenerationService] ignored invalid cache-only response '
        'purpose=$cachePurpose error=${_errorSummary(error)}',
      );
      return null;
    }
  }

  @visibleForTesting
  static Future<Map<String, dynamic>> cacheRequestForTest({
    required List<TextGenerationTurn> turns,
    required String purpose,
    int maxTokens = 1024,
    bool jsonResponse = false,
    double? temperature,
    bool disableThinking = false,
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
      temperature: temperature,
      disableThinking: disableThinking,
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
    double? temperature,
    bool disableThinking = false,
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
        if (temperature != null) 'temperature': temperature,
        if (disableThinking) 'thinkingMode': 'disabled',
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
    TextGenerationUsage usage = const TextGenerationUsage(),
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
        usage: usage,
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
    TextGenerationUsage usage = const TextGenerationUsage(),
  }) =>
      {
        'provider': config.provider,
        'model': config.model,
        'purpose': cachePurpose,
        'maxTokens': maxTokens,
        'jsonResponse': jsonResponse,
        'skipCacheRead': skipCacheRead,
        'skipCacheWrite': skipCacheWrite,
        'usage': usage.toJson(),
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

  static TextGenerationUsage _extractUsage(
    Object? responseData, {
    required String provider,
    required String model,
  }) {
    final decoded =
        responseData is String ? jsonDecode(responseData) : responseData;
    if (decoded is! Map || decoded['usage'] is! Map) {
      return const TextGenerationUsage();
    }
    final usage = decoded['usage'] as Map;
    final input = _usageInt(usage['prompt_tokens'] ?? usage['input_tokens']);
    final output =
        _usageInt(usage['completion_tokens'] ?? usage['output_tokens']);
    final total = _usageInt(usage['total_tokens']);
    return TextGenerationUsage(
      inputTokens: input,
      outputTokens: output,
      totalTokens: total > 0 ? total : input + output,
      estimatedCostCny: estimateCostCny(
        provider: provider,
        model: model,
        inputTokens: input,
        outputTokens: output,
      ),
    );
  }

  static int _usageInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static double? estimateCostCny({
    required String provider,
    required String model,
    required int inputTokens,
    required int outputTokens,
  }) {
    final rates = _verifiedRates(
      provider: provider,
      model: model,
      inputTokens: inputTokens,
    );
    if (rates == null) return null;
    return inputTokens * rates.input / 1000000 +
        outputTokens * rates.output / 1000000;
  }

  /// Conservative list prices verified from the official China-region price
  /// pages on 2026-08-09. Promotional discounts and free grants are ignored so
  /// a tuning budget can never be enlarged by a temporary offer.
  static ({double input, double output})? _verifiedRates({
    required String provider,
    required String model,
    required int inputTokens,
  }) {
    if (provider == AppConfig.aiProviderAliyunBailian) {
      if (model == 'qwen3.7-max' ||
          model == 'qwen3.7-max-2026-06-08' ||
          model == 'qwen3.7-max-2026-05-20') {
        return inputTokens <= 1000000 ? (input: 12, output: 36) : null;
      }
      if (model == 'qwen3.7-plus' || model == 'qwen3.7-plus-2026-05-26') {
        if (inputTokens <= 256000) return (input: 2, output: 8);
        if (inputTokens <= 1000000) return (input: 6, output: 24);
        return null;
      }
    }
    if (provider == AppConfig.aiProviderVolcengine &&
        (model == 'doubao-seed-2-0-lite' ||
            model.startsWith('doubao-seed-2-0-lite-'))) {
      if (inputTokens <= 32000) return (input: 0.6, output: 3.6);
      if (inputTokens <= 128000) return (input: 0.9, output: 5.4);
      if (inputTokens <= 256000) return (input: 1.8, output: 10.8);
    }
    if (provider == AppConfig.aiProviderVolcengine &&
        (model == 'doubao-seed-2-0-pro' ||
            model.startsWith('doubao-seed-2-0-pro-'))) {
      if (inputTokens <= 256000) return (input: 3.2, output: 16);
    }
    if (provider == AppConfig.aiProviderVolcengine &&
        (model == 'deepseek-v4-flash' ||
            model.startsWith('deepseek-v4-flash-'))) {
      return (input: 1, output: 2);
    }
    return null;
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
