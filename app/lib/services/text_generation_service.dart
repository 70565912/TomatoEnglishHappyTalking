import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/config/app_config.dart';
import 'api_cache_service.dart';
import 'content_safety_service.dart';

enum TextGenerationReplySource {
  remote,
  cached,
  mockNoKey,
  mockOnError,
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

typedef TextGenerationPostOverride = Future<Object?> Function({
  required String endpoint,
  required Map<String, String> headers,
  required Map<String, dynamic> body,
});

class TextGenerationService {
  static const _endpoint =
      'https://ark.cn-beijing.volces.com/api/v3/chat/completions';
  static const _cacheNamespace = 'ark_text';

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

  static Future<TextGenerationReply> generate({
    required List<TextGenerationTurn> turns,
    required String cachePurpose,
    required String fallbackText,
    int? articleId,
    int maxTokens = 1024,
  }) async {
    final preparedTurns = await _prepareTurnsForApi(
      turns,
      purpose: cachePurpose,
    );
    final model = await AppConfig.volcArkTextModel;
    final request = _cacheRequest(
      model: model,
      turns: preparedTurns,
      purpose: cachePurpose,
      maxTokens: maxTokens,
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
    if (cachedText != null && cachedText.trim().isNotEmpty) {
      return TextGenerationReply(
        text: cachedText,
        source: TextGenerationReplySource.cached,
      );
    }

    final apiKey = await AppConfig.volcArkTextApiKey;
    if (apiKey.trim().isEmpty) {
      return TextGenerationReply(
        text: fallbackText,
        source: TextGenerationReplySource.mockNoKey,
        errorMessage: 'ark api key is empty',
      );
    }

    try {
      final body = <String, dynamic>{
        'model': model,
        'messages':
            preparedTurns.map((turn) => turn.toJson()).toList(growable: false),
        'max_tokens': maxTokens,
        'stream': false,
      };
      final responseData = await _postJson(
        apiKey: apiKey,
        body: body,
      );
      final text = _extractMessageContent(responseData).trim();
      if (text.isEmpty) {
        throw const FormatException('Ark response has no message content');
      }
      await ApiCacheService.putText(
        cacheKey: cacheKey,
        kind: _cacheNamespace,
        purpose: cachePurpose,
        request: request,
        textValue: text,
        articleId: articleId,
      );
      await ContentSafetyService.learnRulesFromLatestSuccessfulRetry(
        serviceKind: ContentSafetyService.serviceArkText,
        purpose: cachePurpose,
        articleId: articleId,
        successfulText: _requestTranscript(preparedTurns),
      );
      return TextGenerationReply(
        text: text,
        source: TextGenerationReplySource.remote,
      );
    } catch (e) {
      final errorSummary = _errorSummary(e);
      final safety = ContentSafetyService.classifyFailure(e);
      if (safety.suspectedSafetyBlock) {
        await ContentSafetyService.recordFailure(
          serviceKind: ContentSafetyService.serviceArkText,
          purpose: cachePurpose,
          articleId: articleId,
          failedText: _requestTranscript(turns),
          errorCode: safety.errorCode,
          errorMessage: safety.message,
        );
      }
      debugPrint('[TextGenerationService] fallback error=$errorSummary');
      return TextGenerationReply(
        text: fallbackText,
        source: TextGenerationReplySource.mockOnError,
        errorMessage: errorSummary,
      );
    }
  }

  static Future<void> attachExistingCache({
    required List<TextGenerationTurn> turns,
    required String cachePurpose,
    required int articleId,
    int maxTokens = 1024,
  }) async {
    final preparedTurns = await _prepareTurnsForApi(
      turns,
      purpose: cachePurpose,
    );
    final model = await AppConfig.volcArkTextModel;
    final request = _cacheRequest(
      model: model,
      turns: preparedTurns,
      purpose: cachePurpose,
      maxTokens: maxTokens,
    );
    await ApiCacheService.attachExistingJsonCache(
      namespace: _cacheNamespace,
      purpose: cachePurpose,
      request: request,
      articleId: articleId,
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
            serviceKind: ContentSafetyService.serviceArkText,
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
    required String apiKey,
    required Map<String, dynamic> body,
  }) async {
    final headers = <String, String>{
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
    };
    final override = _postOverrideForTest;
    if (override != null) {
      return override(
        endpoint: _endpoint,
        headers: headers,
        body: body,
      );
    }

    final response = await _dio.post<dynamic>(
      _endpoint,
      data: body,
      options: Options(headers: headers),
    );
    return response.data;
  }

  static Map<String, dynamic> _cacheRequest({
    required String model,
    required List<TextGenerationTurn> turns,
    required String purpose,
    required int maxTokens,
  }) =>
      {
        'service': 'ark_chat_completions',
        'endpoint': _endpoint,
        'model': model,
        'purpose': purpose,
        'maxTokens': maxTokens,
        'stream': false,
        'messages': turns.map((turn) => turn.toJson()).toList(growable: false),
      };

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
