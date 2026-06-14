import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';
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
    'live image api probe',
    () async {
      await DatabaseService.resetForTest();
      final arkKey = await AppConfig.volcArkImageApiKey;
      // ignore: avoid_print
      print(
        'LIVE_IMAGE_PROBE_CONFIG arkKey=${arkKey.isNotEmpty}',
      );

      final result = await VolcImageService.generatePictureBookImage(
        prompt:
            'A warm English picture-book chapter illustration: a smiling child walks through a sunny garden, gentle colors, simple composition, a small storybook title sign may appear naturally if useful.',
        promptMetadata: const {
          'probe': true,
          'policy': 'chapter_storyboard_group_v2',
        },
        cachePurpose: 'live_image_probe',
      );
      // ignore: avoid_print
      print(
        'LIVE_IMAGE_PROBE_RESULT source=${result.source.name} path=${result.filePath ?? ''} error=${result.errorMessage ?? ''}',
      );
      if (result.filePath != null) {
        expect(await File(result.filePath!).exists(), isTrue);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
