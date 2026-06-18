import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/config/app_config.dart';
import '../core/logging/tomato_logger.dart';
import 'api_cache_service.dart';
import 'content_safety_service.dart';

enum VolcImageResultSource {
  remote,
  cached,
  skippedNoKey,
  failed,
}

class VolcImageResult {
  const VolcImageResult({
    required this.source,
    this.pageIndex,
    this.filePath,
    this.cacheKey,
    this.errorMessage,
  });

  final VolcImageResultSource source;
  final int? pageIndex;
  final String? filePath;
  final String? cacheKey;
  final String? errorMessage;

  bool get hasImage => filePath != null && filePath!.trim().isNotEmpty;
}

class VolcImageBatchRequest {
  const VolcImageBatchRequest({
    required this.pageIndex,
    required this.prompt,
    required this.promptMetadata,
  });

  final int pageIndex;
  final String prompt;
  final Map<String, dynamic> promptMetadata;
}

typedef VolcImagePostOverride = Future<Object?> Function({
  required String endpoint,
  required Map<String, String> headers,
  required Map<String, dynamic> body,
});

class VolcImageService {
  static const supportsReferenceImages = true;
  static const _logCategory = 'picture_book_image';
  static const _provider = 'volcengine';
  static const _missingArkImageKeyMessage =
      '缺少火山方舟 API Key，已跳过绘本图片生成。请在设置的云服务中配置火山引擎方舟 Key。';

  static const _arkSize = String.fromEnvironment(
    'TOMATO_VOLC_ARK_IMAGE_SIZE',
    defaultValue: '2560x1440',
  );
  static const _arkResponseFormat = String.fromEnvironment(
    'TOMATO_VOLC_ARK_IMAGE_RESPONSE_FORMAT',
    defaultValue: 'url',
  );
  static const _arkSequentialEnabled = bool.fromEnvironment(
    'TOMATO_VOLC_IMAGE_GROUP_PAGES',
    defaultValue: false,
  );
  static const _arkSequentialMaxImages = int.fromEnvironment(
    'TOMATO_VOLC_IMAGE_GROUP_MAX_IMAGES',
    defaultValue: 4,
  );
  static const _outputFormat = String.fromEnvironment(
    'TOMATO_VOLC_IMAGE_OUTPUT_FORMAT',
    defaultValue: 'png',
  );
  static const _watermark = bool.fromEnvironment(
    'TOMATO_VOLC_IMAGE_WATERMARK',
    defaultValue: false,
  );
  static const _minReceiveTimeoutSeconds = int.fromEnvironment(
    'TOMATO_VOLC_IMAGE_MIN_RECEIVE_TIMEOUT_SECONDS',
    defaultValue: 180,
  );
  static const _secondsPerSequentialImage = int.fromEnvironment(
    'TOMATO_VOLC_IMAGE_SECONDS_PER_IMAGE',
    defaultValue: 150,
  );
  static const _maxReceiveTimeoutSeconds = int.fromEnvironment(
    'TOMATO_VOLC_IMAGE_MAX_RECEIVE_TIMEOUT_SECONDS',
    defaultValue: 2700,
  );

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: _minReceiveTimeoutSeconds),
      sendTimeout: const Duration(seconds: 30),
    ),
  );

  static VolcImagePostOverride? _postOverrideForTest;

  @visibleForTesting
  static void setPostOverrideForTest(VolcImagePostOverride? override) {
    _postOverrideForTest = override;
  }

  static Future<VolcImageResult> generatePictureBookImage({
    required String prompt,
    required Map<String, dynamic> promptMetadata,
    int? articleId,
    int? seriesId,
    int? pageIndex,
    List<String> referenceImagePaths = const [],
    String cachePurpose = 'picture_book_image',
  }) async {
    final trimmedPrompt = prompt.trim();
    if (trimmedPrompt.isEmpty) {
      return const VolcImageResult(
        source: VolcImageResultSource.failed,
        errorMessage: '图片提示词为空',
      );
    }

    final referenceImages = await _referenceImages(referenceImagePaths);
    final preparedPrompt = await ContentSafetyService.prepareTextForApi(
      trimmedPrompt,
      serviceKind: ContentSafetyService.servicePictureBookImage,
      purpose: cachePurpose,
    );
    final arkApiKey = await AppConfig.volcArkImageApiKey;
    if (arkApiKey.trim().isNotEmpty) {
      final endpoint = await AppConfig.volcArkImageEndpoint;
      final model = await AppConfig.volcArkImageModel;
      return _generateArkPictureBookImage(
        apiKey: arkApiKey,
        endpoint: endpoint,
        model: model,
        prompt: preparedPrompt,
        promptMetadata: promptMetadata,
        articleId: articleId,
        seriesId: seriesId,
        pageIndex: pageIndex,
        referenceImages: referenceImages,
        cachePurpose: cachePurpose,
      );
    }

    return VolcImageResult(
      source: VolcImageResultSource.skippedNoKey,
      pageIndex: pageIndex,
      errorMessage: _missingArkImageKeyMessage,
    );
  }

  static Future<List<VolcImageResult>> generatePictureBookImageGroup({
    required List<VolcImageBatchRequest> requests,
    int? articleId,
    int? seriesId,
    List<String> referenceImagePaths = const [],
    String? groupPromptOverride,
    String cachePurpose = 'picture_book_image',
    bool useSequential = false,
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
      event: 'volc.group',
      articleId: articleId,
      stage: 'prepare',
      data: {
        'provider': _provider,
        'articleId': articleId,
        'seriesId': seriesId,
        'requestCount': requests.length,
        'cleanedCount': cleaned.length,
        'pageIndexes': _pageIndexes(cleaned),
        'referencePathCount': referenceImagePaths.length,
        'groupPromptOverride': groupPromptOverride?.trim().isNotEmpty == true,
        'cachePurpose': cachePurpose,
        'cacheOnly': cacheOnly,
        'reusePartialCache': reusePartialCache,
        'useSequential': useSequential,
        'arkSequentialEnabled': _arkSequentialEnabled,
      },
    );
    if (((!_arkSequentialEnabled && !useSequential) || cleaned.length == 1) &&
        !cacheOnly) {
      TomatoLogger.info(
        category: _logCategory,
        event: 'volc.group.fan_out_single',
        flowId: span.flowId,
        articleId: articleId,
        stage: 'fan_out',
        status: 'start',
        data: {
          'provider': _provider,
          'reason':
              cleaned.length == 1 ? 'single_request' : 'sequential_disabled',
          'pageIndexes': _pageIndexes(cleaned),
        },
      );
      try {
        final results = await Future.wait(
          cleaned.map(
            (request) => generatePictureBookImage(
              prompt: request.prompt,
              promptMetadata: request.promptMetadata,
              articleId: articleId,
              seriesId: seriesId,
              pageIndex: request.pageIndex,
              referenceImagePaths: referenceImagePaths,
              cachePurpose: cachePurpose,
            ),
          ),
        );
        span.end(
          status: _statusForResults(results),
          data: _resultLogData(
            provider: _provider,
            results: results,
            extra: {'mode': 'fan_out_single'},
          ),
        );
        return results;
      } catch (error, stackTrace) {
        span.fail(
          error,
          stackTrace: stackTrace,
          message: '火山单图 fan-out 组图失败',
          data: {
            'provider': _provider,
            'pageIndexes': _pageIndexes(cleaned),
          },
        );
        rethrow;
      }
    }

    final referenceImages = await _referenceImages(referenceImagePaths);
    final rawGroupPrompt = groupPromptOverride?.trim().isNotEmpty == true
        ? groupPromptOverride!.trim()
        : _groupPrompt(cleaned);
    final groupPrompt = await ContentSafetyService.prepareTextForApi(
      rawGroupPrompt,
      serviceKind: ContentSafetyService.servicePictureBookImage,
      purpose: cachePurpose,
    );
    final promptHash = await ApiCacheService.hashUtf8(groupPrompt);
    TomatoLogger.info(
      category: _logCategory,
      event: 'volc.group.prompt_ready',
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
    final endpoint = await AppConfig.volcArkImageEndpoint;
    final model = await AppConfig.volcArkImageModel;
    final cacheRequests = <Map<String, dynamic>>[
      for (var index = 0; index < cleaned.length; index += 1)
        _arkCacheRequest(
          endpoint: endpoint,
          model: model,
          prompt: groupPrompt,
          promptMetadata: groupMetadata,
          seriesId: seriesId,
          pageIndex: cleaned[index].pageIndex,
          referenceImages: referenceImages,
          sequential: true,
          maxImages: cleaned.length,
          outputIndex: index,
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
      event: 'volc.group.cache_checked',
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
                errorMessage: '组图缓存尚未生成第 ${request.pageIndex + 1} 张图片',
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
        event: 'volc.group.partial_cache_retry',
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
        referenceImagePaths: referenceImagePaths,
        groupPromptOverride: groupPromptOverride,
        cachePurpose: cachePurpose,
        useSequential: useSequential,
        reusePartialCache: reusePartialCache,
        cacheOnly: cacheOnly,
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
                errorMessage: '组图缓存缺失且未返回该页图片',
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

    final apiKey = await AppConfig.volcArkImageApiKey;
    if (apiKey.trim().isEmpty) {
      final results = [
        for (final request in cleaned)
          cachedResults[request.pageIndex] ??
              VolcImageResult(
                source: VolcImageResultSource.skippedNoKey,
                pageIndex: request.pageIndex,
                errorMessage: _missingArkImageKeyMessage,
              ),
      ];
      TomatoLogger.warn(
        category: _logCategory,
        event: 'volc.group.skipped_no_key',
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
      final body = _arkRequestBody(
        model: model,
        prompt: groupPrompt,
        referenceImages: referenceImages,
        sequential: true,
        maxImages: cleaned.length,
      );
      TomatoLogger.info(
        category: _logCategory,
        event: 'volc.group.remote_submit',
        flowId: span.flowId,
        articleId: articleId,
        stage: 'remote_submit',
        status: 'start',
        data: {
          'provider': _provider,
          'endpoint': endpoint,
          'model': model,
          'size': _arkSize,
          'responseFormat': _arkResponseFormat,
          'outputFormat': _outputFormat,
          'watermark': _watermark,
          'sequential': true,
          'maxImages': cleaned.length,
          'receiveTimeoutSeconds':
              _receiveTimeoutForImageCount(cleaned.length).inSeconds,
          'promptLength': groupPrompt.length,
          'promptHash': promptHash,
          'referenceImageCount': referenceImages.length,
          'referenceImageHashes': referenceImages
              .map((image) => image.hash)
              .toList(growable: false),
        },
      );
      final responseData = await _postArkImages(
        apiKey: apiKey,
        endpoint: endpoint,
        body: body,
        imageCount: cleaned.length,
      );
      TomatoLogger.info(
        category: _logCategory,
        event: 'volc.group.remote_response',
        flowId: span.flowId,
        articleId: articleId,
        stage: 'remote_response',
        status: 'received',
        data: {
          'provider': _provider,
          'responseKind': _responseKind(responseData),
          'promptHash': promptHash,
        },
      );
      final images = await _extractAllImageBytes(responseData);
      TomatoLogger.info(
        category: _logCategory,
        event: 'volc.group.images_extracted',
        flowId: span.flowId,
        articleId: articleId,
        stage: 'extract',
        status: images.isEmpty ? 'empty' : 'ready',
        data: {
          'provider': _provider,
          'imageCount': images.length,
          'imageBytes': images.map((bytes) => bytes.length).toList(),
          'expectedCount': cleaned.length,
          'promptHash': promptHash,
        },
      );
      if (images.isEmpty) {
        throw const _VolcImageRemoteException('组图接口未返回可保存的图片');
      }

      final output = <VolcImageResult>[];
      for (var index = 0; index < cleaned.length; index += 1) {
        if (index >= images.length || images[index].isEmpty) {
          output.add(
            VolcImageResult(
              source: VolcImageResultSource.failed,
              pageIndex: cleaned[index].pageIndex,
              cacheKey: cacheKeys[index],
              errorMessage: '组图接口未返回第 ${index + 1} 张图片',
            ),
          );
          continue;
        }
        final filePath = await ApiCacheService.putFileBytes(
          cacheKey: cacheKeys[index],
          kind: 'file',
          purpose: cachePurpose,
          request: cacheRequests[index],
          bytes: images[index],
          subdirectory: 'picture_book',
          extension: _outputFormat,
          contentType: _contentTypeFor(_outputFormat),
          articleId: articleId,
        );
        TomatoLogger.info(
          category: _logCategory,
          event: 'volc.group.cache_write',
          flowId: span.flowId,
          articleId: articleId,
          stage: 'cache_write',
          status: 'ready',
          data: {
            'provider': _provider,
            'pageIndex': cleaned[index].pageIndex,
            'outputIndex': index,
            'bytes': images[index].length,
            'cacheKey': cacheKeys[index],
            'filePath': filePath,
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
            'expectedCount': cleaned.length,
            'remoteImageCount': images.length,
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
          )
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

  static Future<VolcImageResult> _generateArkPictureBookImage({
    required String apiKey,
    required String endpoint,
    required String model,
    required String prompt,
    required Map<String, dynamic> promptMetadata,
    required int? articleId,
    required int? seriesId,
    required int? pageIndex,
    required List<_ReferenceImage> referenceImages,
    required String cachePurpose,
  }) async {
    final promptHash = await ApiCacheService.hashUtf8(prompt);
    final span = TomatoLogger.span(
      category: _logCategory,
      event: 'volc.single',
      articleId: articleId,
      stage: 'prepare',
      data: {
        'provider': _provider,
        'articleId': articleId,
        'seriesId': seriesId,
        'pageIndex': pageIndex,
        'model': model,
        'endpoint': endpoint,
        'size': _arkSize,
        'promptLength': prompt.length,
        'promptHash': promptHash,
        'referenceImageCount': referenceImages.length,
        'cachePurpose': cachePurpose,
      },
    );
    final requestForCache = _arkCacheRequest(
      endpoint: endpoint,
      model: model,
      prompt: prompt,
      promptMetadata: promptMetadata,
      seriesId: seriesId,
      pageIndex: pageIndex,
      referenceImages: referenceImages,
      sequential: false,
    );
    final cacheKey = await ApiCacheService.keyForJson(
      'picture_book_image',
      requestForCache,
    );
    final cachedPath = await ApiCacheService.getFilePath(
      cacheKey,
      articleId: articleId,
      purpose: cachePurpose,
    );
    if (cachedPath != null && cachedPath.trim().isNotEmpty) {
      final result = VolcImageResult(
        source: VolcImageResultSource.cached,
        pageIndex: pageIndex,
        filePath: cachedPath,
        cacheKey: cacheKey,
      );
      span.end(
        status: 'cache_hit',
        data: _resultLogData(
          provider: _provider,
          results: [result],
          extra: {'promptHash': promptHash},
        ),
      );
      return result;
    }

    try {
      TomatoLogger.info(
        category: _logCategory,
        event: 'volc.single.remote_submit',
        flowId: span.flowId,
        articleId: articleId,
        stage: 'remote_submit',
        status: 'start',
        data: {
          'provider': _provider,
          'endpoint': endpoint,
          'model': model,
          'size': _arkSize,
          'responseFormat': _arkResponseFormat,
          'outputFormat': _outputFormat,
          'watermark': _watermark,
          'pageIndex': pageIndex,
          'promptLength': prompt.length,
          'promptHash': promptHash,
          'referenceImageCount': referenceImages.length,
        },
      );
      final responseData = await _postArkImages(
        apiKey: apiKey,
        endpoint: endpoint,
        body: _arkRequestBody(
          model: model,
          prompt: prompt,
          referenceImages: referenceImages,
          sequential: false,
        ),
        imageCount: 1,
      );
      final imageBytes = await _extractImageBytes(responseData);
      if (imageBytes.isEmpty) {
        final result = VolcImageResult(
          source: VolcImageResultSource.failed,
          pageIndex: pageIndex,
          cacheKey: cacheKey,
          errorMessage: '图片接口未返回可保存的图片',
        );
        span.end(
          status: 'failed',
          data: _resultLogData(
            provider: _provider,
            results: [result],
            extra: {
              'promptHash': promptHash,
              'responseKind': _responseKind(responseData),
            },
          ),
        );
        return result;
      }
      final filePath = await ApiCacheService.putFileBytes(
        cacheKey: cacheKey,
        kind: 'file',
        purpose: cachePurpose,
        request: requestForCache,
        bytes: imageBytes,
        subdirectory: 'picture_book',
        extension: _outputFormat,
        contentType: _contentTypeFor(_outputFormat),
        articleId: articleId,
      );
      TomatoLogger.info(
        category: _logCategory,
        event: 'volc.single.cache_write',
        flowId: span.flowId,
        articleId: articleId,
        stage: 'cache_write',
        status: 'ready',
        data: {
          'provider': _provider,
          'pageIndex': pageIndex,
          'bytes': imageBytes.length,
          'cacheKey': cacheKey,
          'filePath': filePath,
          'promptHash': promptHash,
        },
      );
      await ContentSafetyService.learnRulesFromLatestSuccessfulRetry(
        serviceKind: ContentSafetyService.servicePictureBookImage,
        purpose: cachePurpose,
        articleId: articleId,
        successfulText: prompt,
      );
      final result = VolcImageResult(
        source: VolcImageResultSource.remote,
        pageIndex: pageIndex,
        filePath: filePath,
        cacheKey: cacheKey,
      );
      span.end(
        status: 'ready',
        data: _resultLogData(
          provider: _provider,
          results: [result],
          extra: {'promptHash': promptHash, 'bytes': imageBytes.length},
        ),
      );
      return result;
    } catch (error, stackTrace) {
      final message = _failureMessage(error);
      final safety = ContentSafetyService.classifyFailure(error);
      if (safety.suspectedSafetyBlock) {
        await ContentSafetyService.recordFailure(
          serviceKind: ContentSafetyService.servicePictureBookImage,
          purpose: cachePurpose,
          articleId: articleId,
          failedText: prompt,
          errorCode: safety.errorCode,
          errorMessage: safety.message,
        );
      }
      final result = VolcImageResult(
        source: VolcImageResultSource.failed,
        pageIndex: pageIndex,
        cacheKey: cacheKey,
        errorMessage: message,
      );
      span.fail(
        error,
        stackTrace: stackTrace,
        message: message,
        data: _resultLogData(
          provider: _provider,
          results: [result],
          extra: {
            'promptHash': promptHash,
            'suspectedSafetyBlock': safety.suspectedSafetyBlock,
            'safetyErrorCode': safety.errorCode,
            'safetyMessage': safety.message,
          },
        ),
      );
      return result;
    }
  }

  static Map<String, dynamic> _arkCacheRequest({
    required String endpoint,
    required String model,
    required String prompt,
    required Map<String, dynamic> promptMetadata,
    required int? seriesId,
    required int? pageIndex,
    required List<_ReferenceImage> referenceImages,
    required bool sequential,
    int? maxImages,
    int? outputIndex,
  }) =>
      {
        'engine': 'ark_images_generations',
        'endpoint': endpoint,
        'model': model,
        'size': _arkSize,
        'response_format': _arkResponseFormat,
        'output_format': _outputFormat,
        'watermark': _watermark,
        'sequential_image_generation': sequential ? 'auto' : 'disabled',
        if (sequential)
          'sequential_image_generation_options': {
            'max_images': maxImages?.clamp(1, 15) ?? _arkSequentialMaxImages,
          },
        if (outputIndex != null) 'output_index': outputIndex,
        'prompt': prompt,
        'prompt_metadata': promptMetadata,
        'series_id': seriesId,
        'page_index': pageIndex,
        'reference_image_hashes':
            referenceImages.map((image) => image.hash).toList(growable: false),
      };

  static Map<String, dynamic> _arkRequestBody({
    required String model,
    required String prompt,
    required List<_ReferenceImage> referenceImages,
    required bool sequential,
    int? maxImages,
  }) {
    final body = <String, dynamic>{
      'model': model,
      'prompt': prompt,
      'size': _arkSize,
      'response_format': _arkResponseFormat,
      'output_format': _outputFormat,
      'watermark': _watermark,
      'sequential_image_generation': sequential ? 'auto' : 'disabled',
    };
    if (referenceImages.isNotEmpty) {
      body['image'] =
          referenceImages.map((image) => image.dataUri).toList(growable: false);
    }
    if (sequential) {
      body['sequential_image_generation_options'] = {
        'max_images': maxImages?.clamp(1, 15) ?? _arkSequentialMaxImages,
      };
    }
    return body;
  }

  static Future<Object?> _postArkImages({
    required String apiKey,
    required String endpoint,
    required Map<String, dynamic> body,
    required int imageCount,
  }) async {
    final headers = <String, String>{
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
    };
    final override = _postOverrideForTest;
    if (override != null) {
      return override(
        endpoint: endpoint,
        headers: headers,
        body: body,
      );
    }
    final response = await _dio.post<Object?>(
      endpoint,
      data: body,
      options: Options(
        headers: headers,
        responseType: ResponseType.json,
        validateStatus: (_) => true,
        receiveTimeout: _receiveTimeoutForImageCount(imageCount),
      ),
    );
    final statusCode = response.statusCode ?? 0;
    if (statusCode < 200 || statusCode >= 300) {
      throw _VolcImageRemoteException(
        'HTTP $statusCode ${_extractRemoteErrorMessage(response.data)}',
      );
    }
    return response.data;
  }

  static Duration _receiveTimeoutForImageCount(int imageCount) {
    final count = imageCount.clamp(1, 15).toInt();
    const perImageSeconds =
        _secondsPerSequentialImage <= 0 ? 150 : _secondsPerSequentialImage;
    const minSeconds =
        _minReceiveTimeoutSeconds <= 0 ? 180 : _minReceiveTimeoutSeconds;
    const maxSeconds = _maxReceiveTimeoutSeconds <= minSeconds
        ? minSeconds
        : _maxReceiveTimeoutSeconds;
    final requestedSeconds = count * perImageSeconds;
    return Duration(
      seconds: requestedSeconds.clamp(minSeconds, maxSeconds).toInt(),
    );
  }

  static String _groupPrompt(List<VolcImageBatchRequest> requests) {
    final buffer = StringBuffer();
    for (var index = 0; index < requests.length; index += 1) {
      buffer
        ..writeln('Image ${index + 1}:')
        ..writeln(_sanitizePromptArtifacts(requests[index].prompt));
      if (index < requests.length - 1) {
        buffer.writeln();
      }
    }
    return buffer.toString().trim();
  }

  static String _sanitizePromptArtifacts(String prompt) {
    var cleaned = prompt.replaceAll(RegExp(r'\s+'), ' ').trim();
    // Prompt hygiene rule: remove unwanted positive layout hints at the source.
    // Once they are gone, do not add matching "do not ..." constraints.
    final replacements = <RegExp, String>{
      RegExp(
        r'\b(?:enough|large|wide|clear|keep|leave|with)?\s*(?:open\s+clean|clean\s+open|clean)\s+space\b[^.;,\n]*(?:subtitles?|captions?|app[- ]rendered|text|bottom|edge|lower|margin|outside)[^.;,\n]*',
        caseSensitive: false,
      ): 'natural scene composition',
      RegExp(
        r'\b(?:enough|large|wide|clear|keep|leave|with)?\s*open\s+space\s+(?:at|along|on|near|around|for|outside|below|under)\b[^.;,\n]*(?:subtitles?|captions?|app[- ]rendered|text|bottom|edge|lower|margin|outside)[^.;,\n]*',
        caseSensitive: false,
      ): 'natural scene composition',
      RegExp(
        r'\b(?:blank|empty|white)\s+(?:area|band|space|panel|margin|lower area|bottom area)\b[^.;,\n]*(?:subtitles?|captions?|app[- ]rendered|text)[^.;,\n]*',
        caseSensitive: false,
      ): 'natural scene composition',
      RegExp(
        r'\b(?:reserved|reserve)\s+(?:space|area|band|panel|margin)\b[^.;,\n]*(?:subtitles?|captions?|app[- ]rendered|text)[^.;,\n]*',
        caseSensitive: false,
      ): 'natural scene composition',
      RegExp(
        r'\b(?:bottom|lower)\s+(?:third|edge|area|band|margin)\b[^.;,\n]*(?:subtitles?|captions?|app[- ]rendered|text)[^.;,\n]*',
        caseSensitive: false,
      ): 'natural scene composition',
      RegExp(r'\bopen clean space for subtitles\b', caseSensitive: false):
          'natural scene composition',
      RegExp(
        r'\benough clean open space for app-rendered subtitles outside the generated artwork\b',
        caseSensitive: false,
      ): 'natural scene composition',
      RegExp(r'\bapp[- ]rendered subtitles?\b', caseSensitive: false): '',
      RegExp(r'\bapp[- ]rendered captions?\b', caseSensitive: false): '',
      RegExp(r'\bapp displays subtitles separately\b', caseSensitive: false):
          '',
      RegExp(r'\bthe app overlays subtitles separately\b',
          caseSensitive: false): '',
      RegExp(r'\bsubtitles?\b', caseSensitive: false): '',
      RegExp(r'\bcaptions?\b', caseSensitive: false): '',
      RegExp(r'\bapp[- ]rendered\b', caseSensitive: false): '',
      RegExp(r'\bUI overlays?\b', caseSensitive: false): '',
      RegExp(r'\btext[- ]free\b', caseSensitive: false):
          'full-frame story-world',
      RegExp(r'\bno visible text\b', caseSensitive: false): '',
      RegExp(r'\bno letters\b', caseSensitive: false): '',
      RegExp(r'\bno words\b', caseSensitive: false): '',
      RegExp(r'\bno pseudo text\b', caseSensitive: false): '',
      RegExp(r'\bspeech bubbles?\b', caseSensitive: false): '',
      RegExp(r'\bnarration bars?\b', caseSensitive: false): '',
    };
    for (final entry in replacements.entries) {
      cleaned = cleaned.replaceAll(entry.key, entry.value);
    }
    return _cleanPromptPunctuation(cleaned);
  }

  static String _cleanPromptPunctuation(String text) {
    var cleaned = text.replaceAll(RegExp(r'\s+'), ' ');
    cleaned = cleaned.replaceAllMapped(
      RegExp(r'\s+([,.;:])'),
      (match) => match.group(1) ?? '',
    );
    cleaned = cleaned
        .replaceAll(RegExp(r'(?:,\s*){2,}'), ', ')
        .replaceAll(RegExp(r'(?:;\s*){2,}'), '; ')
        .replaceAll(RegExp(r'\(\s*\)'), '')
        .trim();
    cleaned = cleaned.replaceAll(RegExp(r'^[,.;:\-\s]+'), '').trim();
    return cleaned.replaceAll(RegExp(r'[,;:\-\s]+$'), '').trim();
  }

  @visibleForTesting
  static String groupPromptForTest(List<VolcImageBatchRequest> requests) {
    return _groupPrompt(requests);
  }

  static String pictureBookGroupPromptForReview(
    List<VolcImageBatchRequest> requests,
  ) {
    final cleaned = requests
        .where((request) => request.prompt.trim().isNotEmpty)
        .toList(growable: false);
    if (cleaned.isEmpty) {
      return '';
    }
    return _groupPrompt(cleaned);
  }

  static Future<List<int>> _extractImageBytes(Object? responseData) async {
    final data = responseData;
    if (data is! Map) {
      return const [];
    }

    final list = data['data'];
    if (list is! List || list.isEmpty) {
      return const [];
    }
    final first = list.first;
    if (first is! Map) {
      return const [];
    }
    final b64 = first['b64_json']?.toString() ?? '';
    if (b64.trim().isNotEmpty) {
      return base64Decode(_stripDataUriPrefix(b64.trim()));
    }
    final url = first['url']?.toString() ?? '';
    if (url.trim().isEmpty) {
      return const [];
    }
    return _downloadImage(url.trim());
  }

  static Future<List<List<int>>> _extractAllImageBytes(
    Object? responseData,
  ) async {
    final decoded =
        responseData is String ? jsonDecode(responseData) : responseData;
    if (decoded is! Map) {
      return const [];
    }

    final list = decoded['data'];
    if (list is List && list.isNotEmpty) {
      final images = <List<int>>[];
      for (final item in list) {
        if (item is! Map) {
          continue;
        }
        final b64 = item['b64_json']?.toString().trim() ?? '';
        if (b64.isNotEmpty) {
          images.add(base64Decode(_stripDataUriPrefix(b64)));
          continue;
        }
        final url = item['url']?.toString().trim() ?? '';
        if (url.isNotEmpty) {
          images.add(await _downloadImage(url));
        }
      }
      return images;
    }

    final first = await _extractImageBytes(decoded);
    return first.isEmpty ? const [] : [first];
  }

  static Future<List<int>> _downloadImage(String url) async {
    final download = await _dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    return download.data ?? const [];
  }

  static String _failureMessage(Object error) {
    if (error is _VolcImageRemoteException) {
      return '绘本图片生成失败：${error.message}';
    }
    if (error is DioException) {
      final response = error.response;
      final status = response?.statusCode;
      final body = response?.data;
      final remoteMessage = _extractRemoteErrorMessage(body);
      final details = <String>[
        if (status != null) 'HTTP $status',
        if (remoteMessage.isNotEmpty) remoteMessage,
        if (remoteMessage.isEmpty) error.message ?? error.type.name,
      ].where((part) => part.trim().isNotEmpty).join(' - ');
      return details.isEmpty ? '绘本图片生成失败' : '绘本图片生成失败：$details';
    }
    final text = error.toString().trim();
    if (text.isEmpty) {
      return '绘本图片生成失败';
    }
    return '绘本图片生成失败：$text';
  }

  static String _extractRemoteErrorMessage(Object? body) {
    if (body is Map) {
      final values = <String>[
        body['code']?.toString() ?? '',
        body['status']?.toString() ?? '',
        body['message']?.toString() ?? '',
        body['request_id'] == null ? '' : 'request_id=${body['request_id']}',
        body['error'] is Map
            ? _extractRemoteErrorMessage(body['error'])
            : body['error']?.toString() ?? '',
      ];
      return values
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .join(' ');
    }
    final text = body?.toString().trim() ?? '';
    return text.length <= 240 ? text : '${text.substring(0, 240)}...';
  }

  static Future<List<_ReferenceImage>> _referenceImages(
    List<String> paths,
  ) async {
    final images = <_ReferenceImage>[];
    for (final path in paths) {
      final filePath = path.trim();
      if (filePath.isEmpty) {
        continue;
      }
      final file = File(filePath);
      if (!await file.exists()) {
        continue;
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        continue;
      }
      final extension = _extensionForPath(filePath);
      final hash = await ApiCacheService.hashBytes(bytes);
      images.add(
        _ReferenceImage(
          hash: hash,
          dataUri:
              'data:${_contentTypeFor(extension)};base64,${base64Encode(bytes)}',
        ),
      );
    }
    return images;
  }

  static String _stripDataUriPrefix(String value) {
    final index = value.indexOf(',');
    if (value.startsWith('data:image/') && index >= 0) {
      return value.substring(index + 1);
    }
    return value;
  }

  static String _extensionForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'jpeg';
    }
    if (lower.endsWith('.webp')) {
      return 'webp';
    }
    return 'png';
  }

  static String _contentTypeFor(String extension) {
    final normalized = extension.toLowerCase().replaceFirst('.', '');
    return switch (normalized) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      _ => 'image/png',
    };
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

class _VolcImageRemoteException implements Exception {
  const _VolcImageRemoteException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _ReferenceImage {
  const _ReferenceImage({
    required this.hash,
    required this.dataUri,
  });

  final String hash;
  final String dataUri;
}
