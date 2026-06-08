import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/volc_image_service.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'live Ark sequential image generation probe without fallback',
    () async {
      await DatabaseService.resetForTest();
      final outputPath =
          Platform.environment['TOMATO_IMAGE_GROUP_PROBE_OUTPUT']?.trim() ??
              '../.tmp/live_image_group_probe_result.json';
      final count = int.tryParse(
            Platform.environment['TOMATO_IMAGE_GROUP_PROBE_COUNT'] ?? '',
          ) ??
          2;
      final strict =
          Platform.environment['TOMATO_IMAGE_GROUP_PROBE_STRICT'] == '1';
      final selected = _requests.take(count.clamp(1, _requests.length));

      final startedAt = DateTime.now();
      final results = await VolcImageService.generatePictureBookImageGroup(
        requests: selected.toList(growable: false),
        seriesId: 20260607,
        cachePurpose: 'live_image_group_probe',
        useSequential: true,
      );
      final finishedAt = DateTime.now();

      final payload = {
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': finishedAt.toIso8601String(),
        'elapsedSeconds': finishedAt.difference(startedAt).inSeconds,
        'requestedCount': selected.length,
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
      print('LIVE_IMAGE_GROUP_PROBE_RESULT=${outputFile.absolute.path}');
      // ignore: avoid_print
      print(const JsonEncoder.withIndent('  ').convert(payload));

      if (strict) {
        expect(results, hasLength(selected.length));
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

const _requests = [
  VolcImageBatchRequest(
    pageIndex: 0,
    prompt:
        'Image 1: Alice from Alice\'s Adventures in Wonderland walks beside the White Rabbit in a sunny Victorian fantasy garden. English picture-book illustration; natural storybook text, signs, or playing-card marks may appear if useful.',
    promptMetadata: {'probe': 'group', 'page': 0},
  ),
  VolcImageBatchRequest(
    pageIndex: 1,
    prompt:
        'Image 2: The same Alice and the same White Rabbit arrive at the Queen of Hearts croquet ground with card soldiers in a rose garden. Keep character appearances consistent with Image 1. English picture-book illustration; natural storybook text, signs, or playing-card marks may appear if useful.',
    promptMetadata: {'probe': 'group', 'page': 1},
  ),
  VolcImageBatchRequest(
    pageIndex: 2,
    prompt:
        'Image 3: The same Alice watches a whimsical croquet game with flamingo mallets and hedgehog balls, everyone safe and comic. Keep character appearances consistent with previous images. English picture-book illustration; natural storybook text, signs, or playing-card marks may appear if useful.',
    promptMetadata: {'probe': 'group', 'page': 2},
  ),
  VolcImageBatchRequest(
    pageIndex: 3,
    prompt:
        'Image 4: The same Alice sees the Cheshire Cat smiling in the air above the garden while the croquet scene continues nearby. Keep the same picture-book style and character continuity. English picture-book illustration; natural storybook text, signs, or playing-card marks may appear if useful.',
    promptMetadata: {'probe': 'group', 'page': 3},
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
