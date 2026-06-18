import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/picture_book_image_service.dart';
import 'package:tomato_english_happy_talking/services/volc_image_service.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'live Wanx sequential landscape image generation probe',
    () async {
      await DatabaseService.resetForTest();
      final outputPath =
          Platform.environment['TOMATO_WANX_PROBE_OUTPUT']?.trim() ??
              '../.tmp/live_wanx_image_group_probe_result.json';
      final model = Platform.environment['TOMATO_WANX_PROBE_MODEL']?.trim();
      final size = Platform.environment['TOMATO_WANX_PROBE_SIZE']?.trim();
      final apiKey = _envApiKey() ?? '';
      final strict = Platform.environment['TOMATO_WANX_PROBE_STRICT'] == '1';
      AppConfig.setRuntimeConfigForTest(
        aiProvider: AppConfig.aiProviderAliyunBailian,
        aliyunBailianApiKey: apiKey,
        aliyunBailianImageModel: model?.isNotEmpty == true
            ? model
            : AppConfig.defaultAliyunBailianImageModel,
        aliyunBailianImageSize: size?.isNotEmpty == true
            ? size
            : AppConfig.defaultAliyunBailianImageSize,
      );

      final effectiveModel = await AppConfig.aliyunBailianImageModel;
      final effectiveSizeSetting = await AppConfig.aliyunBailianImageSize;
      final startedAt = DateTime.now();
      final results =
          await PictureBookImageService.generatePictureBookImageGroup(
        requests: _requests,
        seriesId: 20260617,
        cachePurpose: 'live_wanx_image_group_probe',
        groupPromptOverride: _groupPrompt,
        reusePartialCache: false,
      );
      final finishedAt = DateTime.now();

      final payload = {
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': finishedAt.toIso8601String(),
        'elapsedSeconds': finishedAt.difference(startedAt).inSeconds,
        'apiKeyConfigured': apiKey.isNotEmpty,
        'model': effectiveModel,
        'sizeSetting': effectiveSizeSetting,
        'requestedCount': _requests.length,
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

      if (strict) {
        expect(apiKey.isNotEmpty, isTrue);
        expect(results, hasLength(_requests.length));
        expect(
          results
              .every((result) => result.source == VolcImageResultSource.remote),
          isTrue,
          reason: const JsonEncoder.withIndent('  ').convert(payload),
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

const _groupPrompt = '''
Book name: Tomato Garden
Book description: A warm English picture-book world with bright natural colors and simple friendly characters.
Chapter description: Two connected scenes follow the same child exploring a sunny classroom garden.

Image 1:
Scene description: A smiling child kneels beside a small tomato plant in a sunny classroom garden while a teacher points to the leaves.

Image 2:
Scene description: The same child carries a small basket of ripe tomatoes back to a bright classroom table with classmates nearby.
''';

const _requests = [
  VolcImageBatchRequest(
    pageIndex: 0,
    prompt:
        'Image 1: A smiling child kneels beside a small tomato plant in a sunny classroom garden while a teacher points to the leaves.',
    promptMetadata: {'probe': 'wanx_group_landscape', 'page': 0},
  ),
  VolcImageBatchRequest(
    pageIndex: 1,
    prompt:
        'Image 2: The same child carries a small basket of ripe tomatoes back to a bright classroom table with classmates nearby.',
    promptMetadata: {'probe': 'wanx_group_landscape', 'page': 1},
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

String? _envApiKey() {
  for (final name in const [
    'TOMATO_ALIYUN_BAILIAN_API_KEY',
    'DASHSCOPE_API_KEY',
  ]) {
    final value = Platform.environment[name]?.trim();
    if (value != null && value.isNotEmpty) {
      return value;
    }
  }
  return null;
}
