import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/config/app_config.dart';
import '../core/logging/tomato_logger.dart';
import 'api_cache_service.dart';
import 'content_safety_service.dart';
import 'volc_image_service.dart';

typedef AliyunWanxPostOverride = Future<Object?> Function({
  required String endpoint,
  required Map<String, String> headers,
  required Map<String, dynamic> body,
});

typedef AliyunWanxGetOverride = Future<Object?> Function({
  required String endpoint,
  required Map<String, String> headers,
});

class AliyunWanxImageService {
  static const _logCategory = 'picture_book_image';
  static const _provider = 'aliyun_bailian';
  static const _missingApiKeyMessage =
      '缺少阿里云百炼 API Key，已跳过绘本图片生成。请在设置的云服务中配置阿里云百炼 Key。';
  static const _outputFormat = 'png';
  static const _minPollSeconds = 180;
  static const _secondsPerImage = 150;
  static const _maxPollSeconds = 2700;
  static const _landscape1kSize = '1696*960';
  static const _landscape2kSize = '2688*1536';

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 30),
    ),
  );

  static AliyunWanxPostOverride? _postOverrideForTest;
  static AliyunWanxGetOverride? _getOverrideForTest;

  @visibleForTesting
  static void setOverridesForTest({
    AliyunWanxPostOverride? post,
    AliyunWanxGetOverride? get,
  }) {
    _postOverrideForTest = post;
    _getOverrideForTest = get;
  }

  static Future<List<VolcImageResult>> generatePictureBookImageGroup({
    required List<VolcImageBatchRequest> requests,
    int? articleId,
    int? seriesId,
    String? groupPromptOverride,
    String cachePurpose = 'picture_book_image',
    bool reusePartialCache = true,
    bool cacheOnly = false,
  }) async {
    final cleaned = requests
        .where((request) => request.prompt.trim().isNotEmpty)
        .toList(growable: false);
    if (cleaned.isEmpty) {
      return const [];
    }
    final span = TomatoLogger.span(
      category: _logCategory,
      event: 'aliyun_wanx.group',
      articleId: articleId,
      stage: 'prepare',
      data: {
        'provider': _provider,
        'articleId': articleId,
        'seriesId': seriesId,
        'requestCount': requests.length,
        'cleanedCount': cleaned.length,
        'pageIndexes': _pageIndexes(cleaned),
        'groupPromptOverride': groupPromptOverride?.trim().isNotEmpty == true,
        'cachePurpose': cachePurpose,
        'cacheOnly': cacheOnly,
        'reusePartialCache': reusePartialCache,
      },
    );

    final endpoint = await AppConfig.aliyunWanxImageGenerationEndpoint;
    final model = await AppConfig.aliyunBailianImageModel;
    final sizeSetting = await AppConfig.aliyunBailianImageSize;
    final apiSize = _apiImageSize(sizeSetting);
    final rawGroupPrompt = groupPromptOverride?.trim().isNotEmpty == true
        ? groupPromptOverride!.trim()
        : VolcImageService.pictureBookGroupPromptForReview(cleaned);
    final groupPrompt = await ContentSafetyService.prepareTextForApi(
      rawGroupPrompt,
      serviceKind: ContentSafetyService.servicePictureBookImage,
      purpose: cachePurpose,
    );
    final promptHash = await ApiCacheService.hashUtf8(groupPrompt);
    TomatoLogger.info(
      category: _logCategory,
      event: 'aliyun_wanx.group.prompt_ready',
      flowId: span.flowId,
      articleId: articleId,
      stage: 'prompt',
      status: 'ready',
      data: {
        'provider': _provider,
        'promptLength': groupPrompt.length,
        'promptHash': promptHash,
        'rawPromptLength': rawGroupPrompt.length,
        'contentSafetyChanged': rawGroupPrompt != groupPrompt,
        'pageCount': cleaned.length,
        'pageIndexes': _pageIndexes(cleaned),
      },
    );
    final groupMetadata = {
      'kind': 'picture_book_group',
      'provider': AppConfig.aiProviderAliyunBailian,
      'page_count': cleaned.length,
      'pages': cleaned
          .map(
            (request) => {
              'page_index': request.pageIndex,
              'prompt_metadata': request.promptMetadata,
            },
          )
          .toList(growable: false),
    };
    final cacheRequests = <Map<String, dynamic>>[
      for (var index = 0; index < cleaned.length; index += 1)
        _cacheRequest(
          endpoint: endpoint,
          model: model,
          size: apiSize,
          sizeSetting: sizeSetting,
          prompt: groupPrompt,
          promptMetadata: groupMetadata,
          seriesId: seriesId,
          pageIndex: cleaned[index].pageIndex,
          outputIndex: index,
          maxImages: cleaned.length,
        ),
    ];
    final cacheKeys = <String>[
      for (final request in cacheRequests)
        await ApiCacheService.keyForJson('picture_book_image', request),
    ];

    final cachedResults = <int, VolcImageResult>{};
    final missingRequests = <VolcImageBatchRequest>[];
    for (var index = 0; index < cleaned.length; index += 1) {
      final cachedPath = await ApiCacheService.getFilePath(
        cacheKeys[index],
        articleId: articleId,
        purpose: cachePurpose,
      );
      if (cachedPath == null || cachedPath.trim().isEmpty) {
        missingRequests.add(cleaned[index]);
        continue;
      }
      cachedResults[cleaned[index].pageIndex] = VolcImageResult(
        source: VolcImageResultSource.cached,
        pageIndex: cleaned[index].pageIndex,
        filePath: cachedPath,
        cacheKey: cacheKeys[index],
      );
    }
    TomatoLogger.info(
      category: _logCategory,
      event: 'aliyun_wanx.group.cache_checked',
      flowId: span.flowId,
      articleId: articleId,
      stage: 'cache',
      status: missingRequests.isEmpty ? 'hit' : 'miss',
      data: {
        'provider': _provider,
        'cachePurpose': cachePurpose,
        'cachedCount': cachedResults.length,
        'missingCount': missingRequests.length,
        'cachedPageIndexes': cachedResults.keys.toList(growable: false),
        'missingPageIndexes': _pageIndexes(missingRequests),
      },
    );
    if (missingRequests.isEmpty) {
      final results = [
        for (final request in cleaned) cachedResults[request.pageIndex]!,
      ];
      span.end(
        status: 'cache_hit',
        data: _resultLogData(
          provider: _provider,
          results: results,
          extra: {'promptHash': promptHash},
        ),
      );
      return results;
    }
    if (cacheOnly) {
      final results = [
        for (final request in cleaned)
          cachedResults[request.pageIndex] ??
              VolcImageResult(
                source: VolcImageResultSource.failed,
                pageIndex: request.pageIndex,
                errorMessage: '阿里云组图缓存尚未生成第 ${request.pageIndex + 1} 张图片',
              ),
      ];
      span.end(
        status: 'cache_only',
        data: _resultLogData(
          provider: _provider,
          results: results,
          extra: {
            'promptHash': promptHash,
            'missingPageIndexes': _pageIndexes(missingRequests),
          },
        ),
      );
      return results;
    }
    if (cachedResults.isNotEmpty && reusePartialCache) {
      TomatoLogger.info(
        category: _logCategory,
        event: 'aliyun_wanx.group.partial_cache_retry',
        flowId: span.flowId,
        articleId: articleId,
        stage: 'cache',
        status: 'retry_missing',
        data: {
          'provider': _provider,
          'cachedPageIndexes': cachedResults.keys.toList(growable: false),
          'missingPageIndexes': _pageIndexes(missingRequests),
          'promptHash': promptHash,
        },
      );
      final generated = await generatePictureBookImageGroup(
        requests: missingRequests,
        articleId: articleId,
        seriesId: seriesId,
        groupPromptOverride: groupPromptOverride,
        cachePurpose: cachePurpose,
        reusePartialCache: reusePartialCache,
      );
      final byPage = <int, VolcImageResult>{
        ...cachedResults,
        for (final result in generated)
          if (result.pageIndex != null) result.pageIndex!: result,
      };
      final results = [
        for (final request in cleaned)
          byPage[request.pageIndex] ??
              VolcImageResult(
                source: VolcImageResultSource.failed,
                pageIndex: request.pageIndex,
                errorMessage: '阿里云组图缓存缺失且未返回该页图片',
              ),
      ];
      span.end(
        status: _statusForResults(results),
        data: _resultLogData(
          provider: _provider,
          results: results,
          extra: {'promptHash': promptHash, 'mode': 'partial_cache_retry'},
        ),
      );
      return results;
    }

    final apiKey = await AppConfig.aliyunBailianApiKey;
    if (apiKey.trim().isEmpty) {
      final results = [
        for (final request in cleaned)
          VolcImageResult(
            source: VolcImageResultSource.skippedNoKey,
            pageIndex: request.pageIndex,
            errorMessage: _missingApiKeyMessage,
          ),
      ];
      TomatoLogger.warn(
        category: _logCategory,
        event: 'aliyun_wanx.group.skipped_no_key',
        flowId: span.flowId,
        articleId: articleId,
        stage: 'credential',
        status: 'skipped',
        data: {
          'provider': _provider,
          'promptHash': promptHash,
          'pageIndexes': _pageIndexes(cleaned),
        },
      );
      span.end(
        status: 'skipped_no_key',
        data: _resultLogData(
          provider: _provider,
          results: results,
          extra: {'promptHash': promptHash},
        ),
      );
      return results;
    }

    try {
      TomatoLogger.info(
        category: _logCategory,
        event: 'aliyun_wanx.group.remote_submit',
        flowId: span.flowId,
        articleId: articleId,
        stage: 'remote_submit',
        status: 'start',
        data: {
          'provider': _provider,
          'endpoint': endpoint,
          'model': model,
          'size': apiSize,
          'sizeSetting': sizeSetting.trim().isEmpty ? '2K' : sizeSetting.trim(),
          'enableSequential': true,
          'imageCount': cleaned.length,
          'pollTimeoutSeconds':
              _pollTimeoutForImageCount(cleaned.length).inSeconds,
          'promptLength': groupPrompt.length,
          'promptHash': promptHash,
        },
      );
      final taskPayload = await _postJson(
        apiKey: apiKey,
        endpoint: endpoint,
        body: _requestBody(
          model: model,
          prompt: groupPrompt,
          size: apiSize,
          imageCount: cleaned.length,
        ),
      );
      final taskId = _extractTaskId(taskPayload);
      TomatoLogger.info(
        category: _logCategory,
        event: 'aliyun_wanx.group.task_created',
        flowId: span.flowId,
        articleId: articleId,
        stage: 'task',
        status: taskId == null ? 'inline_result' : 'created',
        data: {
          'provider': _provider,
          'taskId': taskId,
          'responseKind': _responseKind(taskPayload),
          'promptHash': promptHash,
        },
      );
      final resultPayload = taskId == null
          ? taskPayload
          : await _pollTask(
              apiKey: apiKey,
              taskId: taskId,
              imageCount: cleaned.length,
              flowId: span.flowId,
              articleId: articleId,
              promptHash: promptHash,
            );
      final imageBytes = await _extractAllImageBytes(resultPayload);
      TomatoLogger.info(
        category: _logCategory,
        event: 'aliyun_wanx.group.images_extracted',
        flowId: span.flowId,
        articleId: articleId,
        stage: 'extract',
        status: imageBytes.isEmpty ? 'empty' : 'ready',
        data: {
          'provider': _provider,
          'imageCount': imageBytes.length,
          'imageBytes': imageBytes.map((bytes) => bytes.length).toList(),
          'expectedCount': cleaned.length,
          'taskId': taskId,
          'promptHash': promptHash,
        },
      );
      if (imageBytes.isEmpty) {
        throw const _AliyunWanxException('阿里云万相组图接口未返回可保存的图片');
      }

      final output = <VolcImageResult>[];
      for (var index = 0; index < cleaned.length; index += 1) {
        if (index >= imageBytes.length || imageBytes[index].isEmpty) {
          output.add(
            VolcImageResult(
              source: VolcImageResultSource.failed,
              pageIndex: cleaned[index].pageIndex,
              cacheKey: cacheKeys[index],
              errorMessage: '阿里云万相组图未返回第 ${index + 1} 张图片',
            ),
          );
          continue;
        }
        final filePath = await ApiCacheService.putFileBytes(
          cacheKey: cacheKeys[index],
          kind: 'file',
          purpose: cachePurpose,
          request: cacheRequests[index],
          bytes: imageBytes[index],
          subdirectory: 'picture_book',
          extension: _outputFormat,
          contentType: 'image/png',
          articleId: articleId,
        );
        TomatoLogger.info(
          category: _logCategory,
          event: 'aliyun_wanx.group.cache_write',
          flowId: span.flowId,
          articleId: articleId,
          stage: 'cache_write',
          status: 'ready',
          data: {
            'provider': _provider,
            'pageIndex': cleaned[index].pageIndex,
            'outputIndex': index,
            'bytes': imageBytes[index].length,
            'cacheKey': cacheKeys[index],
            'filePath': filePath,
            'taskId': taskId,
            'promptHash': promptHash,
          },
        );
        output.add(
          VolcImageResult(
            source: VolcImageResultSource.remote,
            pageIndex: cleaned[index].pageIndex,
            filePath: filePath,
            cacheKey: cacheKeys[index],
          ),
        );
      }
      await ContentSafetyService.learnRulesFromLatestSuccessfulRetry(
        serviceKind: ContentSafetyService.servicePictureBookImage,
        purpose: cachePurpose,
        articleId: articleId,
        successfulText: groupPrompt,
      );
      span.end(
        status: _statusForResults(output),
        data: _resultLogData(
          provider: _provider,
          results: output,
          extra: {
            'promptHash': promptHash,
            'taskId': taskId,
            'expectedCount': cleaned.length,
            'remoteImageCount': imageBytes.length,
          },
        ),
      );
      return output;
    } catch (error, stackTrace) {
      final message = _failureMessage(error);
      final safety = ContentSafetyService.classifyFailure(error);
      if (safety.suspectedSafetyBlock) {
        await ContentSafetyService.recordFailure(
          serviceKind: ContentSafetyService.servicePictureBookImage,
          purpose: cachePurpose,
          articleId: articleId,
          failedText: groupPrompt,
          errorCode: safety.errorCode,
          errorMessage: safety.message,
        );
      }
      final results = [
        for (var index = 0; index < cleaned.length; index += 1)
          VolcImageResult(
            source: VolcImageResultSource.failed,
            pageIndex: cleaned[index].pageIndex,
            cacheKey: cacheKeys[index],
            errorMessage: message,
          ),
      ];
      span.fail(
        error,
        stackTrace: stackTrace,
        message: message,
        data: _resultLogData(
          provider: _provider,
          results: results,
          extra: {
            'promptHash': promptHash,
            'suspectedSafetyBlock': safety.suspectedSafetyBlock,
            'safetyErrorCode': safety.errorCode,
            'safetyMessage': safety.message,
          },
        ),
      );
      return results;
    }
  }

  static Map<String, dynamic> _cacheRequest({
    required String endpoint,
    required String model,
    required String size,
    required String sizeSetting,
    required String prompt,
    required Map<String, dynamic> promptMetadata,
    required int? seriesId,
    required int? pageIndex,
    required int outputIndex,
    required int maxImages,
  }) =>
      {
        'engine': 'aliyun_wanx_image_generation_async',
        'endpoint': endpoint,
        'model': model,
        'size': size,
        'size_setting': sizeSetting.trim().isEmpty ? '2K' : sizeSetting.trim(),
        'enable_sequential': true,
        'n': maxImages.clamp(1, 12),
        'output_index': outputIndex,
        'watermark': false,
        'prompt': prompt,
        'prompt_metadata': promptMetadata,
        'series_id': seriesId,
        'page_index': pageIndex,
      };

  static Map<String, dynamic> _requestBody({
    required String model,
    required String prompt,
    required String size,
    required int imageCount,
  }) =>
      {
        'model': model,
        'input': {
          'messages': [
            {
              'role': 'user',
              'content': [
                {'text': prompt},
              ],
            },
          ],
        },
        'parameters': {
          'enable_sequential': true,
          'n': imageCount.clamp(1, 12),
          'size': size.trim().isEmpty ? '2K' : size.trim(),
          'watermark': false,
        },
      };

  static String apiImageSizeForSetting(String configuredSize) =>
      _apiImageSize(configuredSize);

  static String _apiImageSize(String configuredSize) {
    final normalized = configuredSize.trim().toUpperCase();
    if (normalized.isEmpty || normalized == '2K') {
      return _landscape2kSize;
    }
    if (normalized == '1K') {
      return _landscape1kSize;
    }
    return configuredSize.trim().replaceAll('x', '*').replaceAll('X', '*');
  }

  static Future<Object?> _postJson({
    required String apiKey,
    required String endpoint,
    required Map<String, dynamic> body,
  }) async {
    final headers = {
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
      'X-DashScope-Async': 'enable',
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
    return _checkedResponse(response.statusCode ?? 0, response.data);
  }

  static Future<Object?> _getJson({
    required String apiKey,
    required String endpoint,
  }) async {
    final headers = {'Authorization': 'Bearer $apiKey'};
    final override = _getOverrideForTest;
    if (override != null) {
      return override(endpoint: endpoint, headers: headers);
    }
    final response = await _dio.get<Object?>(
      endpoint,
      options: Options(
        headers: headers,
        responseType: ResponseType.json,
        validateStatus: (_) => true,
      ),
    );
    return _checkedResponse(response.statusCode ?? 0, response.data);
  }

  static Object? _checkedResponse(int statusCode, Object? data) {
    if (statusCode >= 200 && statusCode < 300) {
      return data;
    }
    throw _AliyunWanxException(
      'HTTP $statusCode ${_extractRemoteErrorMessage(data)}',
    );
  }

  static Future<Object?> _pollTask({
    required String apiKey,
    required String taskId,
    required int imageCount,
    String? flowId,
    int? articleId,
    String? promptHash,
  }) async {
    final endpoint = await AppConfig.aliyunTaskEndpoint(taskId);
    final deadline = DateTime.now().add(_pollTimeoutForImageCount(imageCount));
    final startedAt = DateTime.now();
    var pollCount = 0;
    Object? latest;
    while (DateTime.now().isBefore(deadline)) {
      pollCount += 1;
      latest = await _getJson(apiKey: apiKey, endpoint: endpoint);
      final status = _extractTaskStatus(latest);
      TomatoLogger.info(
        category: _logCategory,
        event: 'aliyun_wanx.group.poll',
        flowId: flowId,
        articleId: articleId,
        stage: 'poll',
        status: status.isEmpty ? 'UNKNOWN' : status,
        durationMs: DateTime.now().difference(startedAt).inMilliseconds,
        data: {
          'provider': _provider,
          'taskId': taskId,
          'pollCount': pollCount,
          'taskStatus': status,
          'imageCount': imageCount,
          'promptHash': promptHash,
          'remoteMessage': _extractRemoteErrorMessage(latest),
        },
      );
      if (status == 'SUCCEEDED') {
        return latest;
      }
      if (status == 'FAILED' || status == 'CANCELED' || status == 'UNKNOWN') {
        throw _AliyunWanxException(
          '阿里云万相任务$status：${_extractRemoteErrorMessage(latest)}',
        );
      }
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    throw _AliyunWanxException('阿里云万相任务超时：$taskId');
  }

  static Duration _pollTimeoutForImageCount(int imageCount) {
    final requested = imageCount.clamp(1, 12).toInt() * _secondsPerImage;
    return Duration(
      seconds: requested.clamp(_minPollSeconds, _maxPollSeconds).toInt(),
    );
  }

  static String? _extractTaskId(Object? payload) {
    final map = _asMap(payload);
    final output = _asMap(map['output']);
    return output['task_id']?.toString().trim().isNotEmpty == true
        ? output['task_id'].toString().trim()
        : null;
  }

  static String _extractTaskStatus(Object? payload) {
    final map = _asMap(payload);
    final output = _asMap(map['output']);
    return output['task_status']?.toString().trim().toUpperCase() ?? '';
  }

  static Future<List<List<int>>> _extractAllImageBytes(Object? payload) async {
    final urls = _extractImageReferences(payload);
    final images = <List<int>>[];
    for (final url in urls) {
      final bytes = await _imageBytes(url);
      if (bytes.isNotEmpty) {
        images.add(bytes);
      }
    }
    return images;
  }

  static List<String> _extractImageReferences(Object? payload) {
    final refs = <String>[];

    void walk(Object? value) {
      if (value is Map) {
        final image = value['image']?.toString().trim();
        if (image != null && image.isNotEmpty) {
          refs.add(image);
        }
        for (final child in value.values) {
          walk(child);
        }
      } else if (value is List) {
        for (final item in value) {
          walk(item);
        }
      }
    }

    walk(payload);
    return refs.toList(growable: false);
  }

  static Future<List<int>> _imageBytes(String value) async {
    if (value.startsWith('data:image/')) {
      final comma = value.indexOf(',');
      if (comma < 0) {
        return const <int>[];
      }
      return base64.decode(value.substring(comma + 1));
    }
    final response = await _dio.get<List<int>>(
      value,
      options: Options(responseType: ResponseType.bytes),
    );
    return response.data ?? const <int>[];
  }

  static Map<String, dynamic> _asMap(Object? raw) {
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return const <String, dynamic>{};
  }

  static String _extractRemoteErrorMessage(Object? payload) {
    final map = _asMap(payload);
    final message = map['message'] ?? map['msg'] ?? map['error'];
    if (message != null && message.toString().trim().isNotEmpty) {
      return message.toString().trim();
    }
    final output = _asMap(map['output']);
    final outputMessage =
        output['message'] ?? output['task_status'] ?? output['code'];
    if (outputMessage != null && outputMessage.toString().trim().isNotEmpty) {
      return outputMessage.toString().trim();
    }
    return payload?.toString() ?? '未知错误';
  }

  static String _failureMessage(Object error) {
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  static List<int> _pageIndexes(Iterable<VolcImageBatchRequest> requests) =>
      requests.map((request) => request.pageIndex).toList(growable: false);

  static String _statusForResults(List<VolcImageResult> results) {
    if (results.isEmpty) {
      return 'empty';
    }
    if (results.every((result) => result.hasImage)) {
      return 'ready';
    }
    if (results.any((result) => result.hasImage)) {
      return 'partial';
    }
    if (results.any(
      (result) => result.source == VolcImageResultSource.skippedNoKey,
    )) {
      return 'skipped_no_key';
    }
    return 'failed';
  }

  static Map<String, dynamic> _resultLogData({
    required String provider,
    required List<VolcImageResult> results,
    Map<String, dynamic>? extra,
  }) {
    final data = <String, dynamic>{
      'provider': provider,
      'resultCount': results.length,
      'status': _statusForResults(results),
      'sourceCounts': _resultSourceCounts(results),
      'readyCount': results.where((result) => result.hasImage).length,
      'failedCount': results.where((result) => !result.hasImage).length,
      'pages': results
          .map(
            (result) => {
              'pageIndex': result.pageIndex,
              'source': result.source.name,
              'hasImage': result.hasImage,
              'cacheKey': result.cacheKey,
              'filePath': result.filePath,
              'errorMessage': result.errorMessage,
            },
          )
          .toList(growable: false),
      'errors': results
          .map((result) => result.errorMessage?.trim() ?? '')
          .where((message) => message.isNotEmpty)
          .toSet()
          .toList(growable: false),
    };
    if (extra != null) {
      data.addAll(extra);
    }
    return data;
  }

  static Map<String, int> _resultSourceCounts(
    Iterable<VolcImageResult> results,
  ) {
    final counts = <String, int>{};
    for (final result in results) {
      counts[result.source.name] = (counts[result.source.name] ?? 0) + 1;
    }
    return counts;
  }

  static String _responseKind(Object? responseData) {
    if (responseData == null) {
      return 'null';
    }
    if (responseData is Map) {
      final keys = responseData.keys
          .map((key) => key.toString())
          .take(8)
          .toList(growable: false);
      return 'map:${keys.join(',')}';
    }
    if (responseData is List) {
      return 'list:${responseData.length}';
    }
    return responseData.runtimeType.toString();
  }
}

class _AliyunWanxException implements Exception {
  const _AliyunWanxException(this.message);

  final String message;

  @override
  String toString() => message;
}
