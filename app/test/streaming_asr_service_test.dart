import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/services/api_cache_service.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/streaming_asr_service.dart';

void main() {
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Directory tempDirectory;
  late Directory previousDirectory;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      if (call.method == 'readAll') return <String, String>{};
      if (call.method == 'containsKey') return false;
      return null;
    });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  setUp(() async {
    previousDirectory = Directory.current;
    tempDirectory =
        await Directory.systemTemp.createTemp('tomato_asr_cache_test_');
    Directory.current = tempDirectory;
    await databaseFactory.setDatabasesPath(tempDirectory.path);
    DatabaseService.setDatabaseDirectoryOverrideForTest(tempDirectory.path);
    await DatabaseService.resetForTest();
    AppConfig.resetRuntimeConfigForTest();
  });

  tearDown(() async {
    AppConfig.resetRuntimeConfigForTest();
    await DatabaseService.resetForTest();
    DatabaseService.setDatabaseDirectoryOverrideForTest(null);
    DatabaseService.setRuntimeDataRootOverrideForTest(null);
    Directory.current = previousDirectory;
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('uses configured Volcengine model resource IDs without cross fallback',
      () {
    expect(
      StreamingAsrService.resourceIdsForModelForTest(
        AppConfig.volcAsrModelAuto,
      ),
      const [
        'volc.seedasr.sauc.duration',
        'volc.bigasr.sauc.duration',
        'volc.seedasr.sauc.concurrent',
        'volc.bigasr.sauc.concurrent',
      ],
    );
    expect(
      StreamingAsrService.resourceIdsForModelForTest(
        AppConfig.volcAsrModelSeedAsrV2,
      ),
      const [
        'volc.seedasr.sauc.duration',
        'volc.seedasr.sauc.concurrent',
      ],
    );
    expect(
      StreamingAsrService.resourceIdsForModelForTest(
        AppConfig.volcAsrModelBigAsrV1,
      ),
      const [
        'volc.bigasr.sauc.duration',
        'volc.bigasr.sauc.concurrent',
      ],
    );
  });

  test('all ASR entry points follow asrProvider instead of textProvider',
      () async {
    Future<void> expectMissingKey({
      required String asrProvider,
      required String textProvider,
      required String vendorLabel,
    }) async {
      AppConfig.resetRuntimeConfigForTest();
      AppConfig.setRuntimeConfigForTest(
        asrProvider: asrProvider,
        textProvider: textProvider,
      );
      final matcher = throwsA(
        isA<AsrException>()
            .having((error) => error.type, 'type', AsrFailureType.missingApiKey)
            .having((error) => error.message, 'message', contains(vendorLabel)),
      );

      await expectLater(
        StreamingAsrService.recognize(audioBytes: const [1, 2, 3]),
        matcher,
      );
      await expectLater(
        StreamingAsrService.recognizeWithTimeline(
          audioBytes: const [4, 5, 6],
        ),
        matcher,
      );
      await expectLater(
        StreamingAsrService.recognizeLive(
          audioChunks: const Stream<List<int>>.empty(),
        ),
        matcher,
      );
    }

    await expectMissingKey(
      asrProvider: AppConfig.aiProviderAliyunBailian,
      textProvider: AppConfig.aiProviderVolcengine,
      vendorLabel: '阿里云',
    );
    await expectMissingKey(
      asrProvider: AppConfig.aiProviderVolcengine,
      textProvider: AppConfig.aiProviderAliyunBailian,
      vendorLabel: '火山',
    );
  });

  test('recognizeWithTimeline reuses persistent cache before API key check',
      () async {
    const audioBytes = <int>[82, 73, 70, 70, 1, 2, 3, 4];
    AppConfig.setRuntimeConfigForTest(
      asrProvider: AppConfig.aiProviderVolcengine,
      volcAsrModel: AppConfig.volcAsrModelSeedAsrV2,
    );
    final request = await StreamingAsrService.timelineCacheRequestForTest(
      audioBytes: audioBytes,
      language: 'en-US',
    );
    final resolvedRequest = {
      ...request,
      'resourceId': 'volc.seedasr.sauc.duration',
    };
    final cacheKey =
        await ApiCacheService.keyForJson('asr_timeline', resolvedRequest);
    await ApiCacheService.putJson(
      cacheKey: cacheKey,
      kind: 'asr_timeline',
      purpose: 'asr_timeline_recognize_v1',
      request: resolvedRequest,
      jsonValue: const {
        'text': 'The river ran quietly.',
        'durationMs': 1250,
        'utterances': [
          {
            'text': 'The river ran quietly.',
            'startMs': 0,
            'endMs': 1250,
            'definite': true,
            'words': [
              {'text': 'The', 'startMs': 0, 'endMs': 180},
              {'text': 'river', 'startMs': 200, 'endMs': 480},
              {'text': 'ran', 'startMs': 500, 'endMs': 720},
              {'text': 'quietly', 'startMs': 740, 'endMs': 1250},
            ],
          },
        ],
        'raw': {
          'provider': 'volcengine',
          'configuredModel': 'seedasr_v2',
          'resourceId': 'volc.seedasr.sauc.duration',
        },
      },
    );

    AppConfig.resetRuntimeConfigForTest();
    AppConfig.setRuntimeConfigForTest(
      asrProvider: AppConfig.aiProviderVolcengine,
      volcAsrModel: AppConfig.volcAsrModelSeedAsrV2,
    );
    final result = await StreamingAsrService.recognizeWithTimeline(
      audioBytes: audioBytes,
      language: 'en-US',
    );

    expect(result.text, 'The river ran quietly.');
    expect(result.durationMs, 1250);
    expect(result.words, hasLength(4));
    expect(result.raw['provider'], AppConfig.aiProviderVolcengine);
    expect(result.raw['configuredModel'], AppConfig.volcAsrModelSeedAsrV2);
    expect(result.raw['resourceId'], 'volc.seedasr.sauc.duration');
    expect(result.raw['cacheHit'], isTrue);
    expect(await ApiCacheService.getEntry(cacheKey), isNotNull);
  });
}
