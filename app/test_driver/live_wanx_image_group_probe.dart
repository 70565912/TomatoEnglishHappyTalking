import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/core/logging/tomato_logger.dart';
import 'package:tomato_english_happy_talking/services/aliyun_wanx_image_service.dart';
import 'package:tomato_english_happy_talking/services/picture_book_image_service.dart';
import 'package:tomato_english_happy_talking/services/volc_image_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  await TomatoLogger.initialize();
  await AppConfig.seedSecureStorageFromEnvironment();

  const outputPath = String.fromEnvironment(
    'TOMATO_WANX_PROBE_OUTPUT',
    defaultValue: '../.tmp/live_wanx_image_group_probe_result.json',
  );
  const model = String.fromEnvironment(
    'TOMATO_WANX_PROBE_MODEL',
    defaultValue: AppConfig.defaultAliyunBailianImageModel,
  );
  const sizeSetting = String.fromEnvironment(
    'TOMATO_WANX_PROBE_SIZE',
    defaultValue: AppConfig.defaultAliyunBailianImageSize,
  );
  const strict = bool.fromEnvironment('TOMATO_WANX_PROBE_STRICT');

  AppConfig.setRuntimeConfigForTest(
    aiProvider: AppConfig.aiProviderAliyunBailian,
    aliyunBailianImageModel: model,
    aliyunBailianImageSize: sizeSetting,
  );

  final runId = DateTime.now().microsecondsSinceEpoch.toString();
  final effectiveModel = await AppConfig.aliyunBailianImageModel;
  final effectiveSizeSetting = await AppConfig.aliyunBailianImageSize;
  final apiSize =
      AliyunWanxImageService.apiImageSizeForSetting(effectiveSizeSetting);
  final apiKey = await AppConfig.aliyunBailianApiKey;
  final startedAt = DateTime.now();
  Object? thrown;
  StackTrace? thrownStack;
  List<VolcImageResult> results = const [];
  try {
    results = await PictureBookImageService.generatePictureBookImageGroup(
      requests: _requests(runId),
      seriesId: 20260617,
      cachePurpose: 'live_wanx_image_group_probe',
      groupPromptOverride: _groupPrompt,
      reusePartialCache: false,
    );
  } catch (error, stackTrace) {
    thrown = error;
    thrownStack = stackTrace;
  }
  final finishedAt = DateTime.now();

  final payload = {
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt.toIso8601String(),
    'elapsedSeconds': finishedAt.difference(startedAt).inSeconds,
    'apiKeyConfigured': apiKey.isNotEmpty,
    'model': effectiveModel,
    'sizeSetting': effectiveSizeSetting,
    'apiSize': apiSize,
    'requestedCount': 2,
    'error': thrown?.toString(),
    'stack': thrownStack?.toString(),
    'results': [
      for (final result in results)
        {
          'pageIndex': result.pageIndex,
          'source': result.source.name,
          'filePath': result.filePath,
          'errorMessage': result.errorMessage,
          'exists': result.filePath == null
              ? false
              : await File(result.filePath!).exists(),
          'dimensions': result.filePath == null
              ? ''
              : await _pngDimensions(result.filePath!),
        }
    ],
  };
  final outputFile = File(outputPath);
  await outputFile.parent.create(recursive: true);
  await outputFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(payload),
  );
  // ignore: avoid_print
  print('LIVE_WANX_IMAGE_GROUP_PROBE_RESULT=${outputFile.absolute.path}');
  // ignore: avoid_print
  print(const JsonEncoder.withIndent('  ').convert(payload));

  final ok = apiKey.isNotEmpty &&
      thrown == null &&
      results.length == 2 &&
      results.every((result) => result.source == VolcImageResultSource.remote);
  exit(strict && !ok ? 1 : 0);
}

const _groupPrompt = '''
Book description: A warm English picture-book world with bright natural colors and simple friendly characters.
Chapter description: Two connected scenes follow the same child exploring a sunny classroom garden.

Image 1:
Scene description: A smiling child kneels beside a small tomato plant in a sunny classroom garden while a teacher points to the leaves.

Image 2:
Scene description: The same child carries a small basket of ripe tomatoes back to a bright classroom table with classmates nearby.
''';

List<VolcImageBatchRequest> _requests(String runId) => [
      VolcImageBatchRequest(
        pageIndex: 0,
        prompt:
            'Image 1: A smiling child kneels beside a small tomato plant in a sunny classroom garden while a teacher points to the leaves.',
        promptMetadata: {
          'probe': 'wanx_group_16_9',
          'page': 0,
          'runId': runId,
        },
      ),
      VolcImageBatchRequest(
        pageIndex: 1,
        prompt:
            'Image 2: The same child carries a small basket of ripe tomatoes back to a bright classroom table with classmates nearby.',
        promptMetadata: {
          'probe': 'wanx_group_16_9',
          'page': 1,
          'runId': runId,
        },
      ),
    ];

Future<String> _pngDimensions(String path) async {
  final file = File(path);
  if (!await file.exists()) {
    return '';
  }
  final bytes = await file.readAsBytes();
  if (bytes.length < 24) {
    return '';
  }
  final width = _readPngInt(bytes, 16);
  final height = _readPngInt(bytes, 20);
  return '${width}x$height';
}

int _readPngInt(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];
