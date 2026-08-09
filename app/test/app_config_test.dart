import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secureValues = <String, String>{};

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      final arguments = Map<String, dynamic>.from(call.arguments as Map);
      final key = arguments['key']?.toString() ?? '';
      switch (call.method) {
        case 'read':
          return secureValues[key];
        case 'write':
          secureValues[key] = arguments['value']?.toString() ?? '';
          return null;
        case 'delete':
          secureValues.remove(key);
          return null;
        case 'readAll':
          return Map<String, String>.from(secureValues);
        case 'deleteAll':
          secureValues.clear();
          return null;
        case 'containsKey':
          return secureValues.containsKey(key);
      }
      return null;
    });
  });

  setUp(() {
    secureValues.clear();
    AppConfig.resetRuntimeConfigForTest();
  });

  tearDown(() {
    AppConfig.resetRuntimeConfigForTest();
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  test('defaults text provider to Aliyun Bailian and songs to Suno', () async {
    expect(await AppConfig.aiProvider, AppConfig.aiProviderAliyunBailian);
    expect(await AppConfig.asrProvider, AppConfig.aiProviderAliyunBailian);
    expect(await AppConfig.textProvider, AppConfig.aiProviderAliyunBailian);
    expect(await AppConfig.imageProvider, AppConfig.aiProviderAliyunBailian);
    expect(await AppConfig.ttsProvider, AppConfig.aiProviderAliyunBailian);
    expect(await AppConfig.aliyunBailianBaseUrl,
        AppConfig.defaultAliyunBailianBaseUrl);
    expect(await AppConfig.aliyunBailianTextModel,
        AppConfig.defaultAliyunBailianTextModel);
    expect(await AppConfig.aliyunBailianMusicModel,
        AppConfig.defaultAliyunBailianMusicModel);
    expect(await AppConfig.aliyunBailianApiBaseUrl,
        AppConfig.defaultAliyunBailianApiBaseUrl);
    expect(await AppConfig.aliyunBailianImageModel,
        AppConfig.defaultAliyunBailianImageModel);
    expect(await AppConfig.aliyunBailianTtsModel,
        AppConfig.defaultAliyunBailianTtsModel);
    expect(await AppConfig.aliyunBailianTtsVoice,
        AppConfig.defaultAliyunBailianTtsVoice);
    expect(await AppConfig.aliyunBailianAsrModel,
        AppConfig.defaultAliyunBailianAsrModel);
    expect(await AppConfig.aliyunBailianRealtimeAsrModel,
        AppConfig.defaultAliyunBailianRealtimeAsrModel);
    expect(await AppConfig.volcAsrModel, AppConfig.defaultVolcAsrModel);
    expect(
        await AppConfig.elevenLabsBaseUrl, AppConfig.defaultElevenLabsBaseUrl);
    expect(await AppConfig.elevenLabsTtsModel,
        AppConfig.defaultElevenLabsTtsModel);
    expect(await AppConfig.elevenLabsTtsOutputFormat,
        AppConfig.defaultElevenLabsTtsOutputFormat);
    expect(await AppConfig.elevenLabsMusicModel,
        AppConfig.defaultElevenLabsMusicModel);
    expect(await AppConfig.songGenerationProvider, AppConfig.songProviderSuno);
  });

  test('openAI text config uses Aliyun Bailian settings by default', () async {
    AppConfig.setRuntimeConfigForTest(
      aliyunBailianApiKey: 'Bearer bailian-key-123456',
      aliyunBailianBaseUrl: 'https://example.aliyun.com/compatible-mode/v1/',
      aliyunBailianTextModel: 'qwen-test',
    );

    final config = await AppConfig.openAiTextConfig;

    expect(config.provider, AppConfig.aiProviderAliyunBailian);
    expect(config.apiKey, 'bailian-key-123456');
    expect(config.baseUrl, 'https://example.aliyun.com/compatible-mode/v1');
    expect(config.chatCompletionsEndpoint,
        'https://example.aliyun.com/compatible-mode/v1/chat/completions');
    expect(config.model, 'qwen-test');
  });

  test('openAI text config switches to Volcengine Ark settings', () async {
    AppConfig.setRuntimeConfigForTest(
      textProvider: AppConfig.aiProviderVolcengine,
      volcArkApiKey: 'Bearer volc-ark-key-987654',
      volcArkBaseUrl: 'https://ark.example.com/api/v3/',
      volcArkTextModel: 'doubao-test',
    );

    final config = await AppConfig.openAiTextConfig;

    expect(config.provider, AppConfig.aiProviderVolcengine);
    expect(config.apiKey, 'volc-ark-key-987654');
    expect(config.baseUrl, 'https://ark.example.com/api/v3');
    expect(config.chatCompletionsEndpoint,
        'https://ark.example.com/api/v3/chat/completions');
    expect(config.model, 'doubao-test');
  });

  test('split providers fall back to legacy aiProvider when unset', () async {
    AppConfig.setRuntimeConfigForTest(
      aiProvider: AppConfig.aiProviderVolcengine,
    );

    expect(await AppConfig.textProvider, AppConfig.aiProviderVolcengine);
    expect(await AppConfig.imageProvider, AppConfig.aiProviderVolcengine);
    expect(await AppConfig.ttsProvider, AppConfig.aiProviderVolcengine);
    expect(await AppConfig.asrProvider, AppConfig.aiProviderVolcengine);
  });

  test('asr and text providers are independent from image and tts providers',
      () async {
    AppConfig.setRuntimeConfigForTest(
      aiProvider: AppConfig.aiProviderVolcengine,
      asrProvider: AppConfig.aiProviderVolcengine,
      textProvider: AppConfig.aiProviderAliyunBailian,
      imageProvider: AppConfig.aiProviderVolcengine,
      ttsProvider: AppConfig.aiProviderElevenLabs,
      aliyunBailianApiKey: 'bailian-text-key',
      volcArkApiKey: 'volc-image-key',
      elevenLabsApiKey: 'elevenlabs-tts-key',
    );

    final config = await AppConfig.openAiTextConfig;

    expect(config.provider, AppConfig.aiProviderAliyunBailian);
    expect(await AppConfig.asrProvider, AppConfig.aiProviderVolcengine);
    expect(await AppConfig.imageProvider, AppConfig.aiProviderVolcengine);
    expect(await AppConfig.ttsProvider, AppConfig.aiProviderElevenLabs);
  });

  test('cloud settings payload masks keys and never returns plaintext',
      () async {
    AppConfig.setRuntimeConfigForTest(
      aiProvider: AppConfig.aiProviderAliyunBailian,
      asrProvider: AppConfig.aiProviderVolcengine,
      aliyunBailianApiKey: 'bailian-secret-1234567890',
      volcArkApiKey: 'volc-ark-secret-abcdefgh',
      volcSpeechApiKey: 'speech-secret-abcdef',
      elevenLabsApiKey: 'elevenlabs-secret-xyz987',
      textProvider: AppConfig.aiProviderVolcengine,
      imageProvider: AppConfig.aiProviderAliyunBailian,
      ttsProvider: AppConfig.aiProviderElevenLabs,
      aliyunBailianTextModel: 'qwen-live',
      aliyunBailianMusicModel: 'fun-music-v1',
      aliyunBailianImageModel: 'wan-test',
      aliyunBailianTtsModel: 'cosy-test',
      aliyunBailianTtsVoice: 'loongabby_v3',
      aliyunBailianAsrModel: 'qwen3-asr-flash-2026-02-10',
      aliyunBailianRealtimeAsrModel: 'qwen3-asr-flash-realtime-2026-02-10',
      volcAsrModel: AppConfig.volcAsrModelSeedAsrV2,
      volcArkTextModel: 'doubao-live',
      volcArkImageModel: 'seedream-live',
    );

    final payload = await AppConfig.cloudSettingsPayload();
    final text = payload.toString();

    expect(payload['aiProvider'], AppConfig.aiProviderVolcengine);
    expect(payload['asrProvider'], AppConfig.aiProviderVolcengine);
    expect(payload['textProvider'], AppConfig.aiProviderVolcengine);
    expect(payload['imageProvider'], AppConfig.aiProviderAliyunBailian);
    expect(payload['ttsProvider'], AppConfig.aiProviderElevenLabs);
    expect(payload['aliyunBailian']['apiKeyConfigured'], isTrue);
    expect(payload['aliyunBailian']['apiKeyMask'], '****7890');
    expect(payload['aliyunBailian']['textModel'], 'qwen-live');
    expect(payload['aliyunBailian']['musicModel'], 'fun-music-v1');
    expect(payload['aliyunBailian']['imageModel'], 'wan-test');
    expect(payload['aliyunBailian']['ttsModel'], 'cosy-test');
    expect(payload['aliyunBailian']['ttsVoice'], 'loongabby_v3');
    expect(payload['aliyunBailian']['asrModel'], 'qwen3-asr-flash-2026-02-10');
    expect(payload['aliyunBailian']['realtimeAsrModel'],
        'qwen3-asr-flash-realtime-2026-02-10');
    expect(payload['volcengine']['arkApiKeyConfigured'], isTrue);
    expect(payload['volcengine']['arkApiKeyMask'], '****efgh');
    expect(payload['volcengine']['speechApiKeyConfigured'], isTrue);
    expect(payload['volcengine']['speechApiKeyMask'], '****cdef');
    expect(payload['volcengine']['arkTextModel'], 'doubao-live');
    expect(payload['volcengine']['arkImageModel'], 'seedream-live');
    expect(payload['volcengine']['asrModel'], AppConfig.volcAsrModelSeedAsrV2);
    expect(payload['elevenLabs']['apiKeyConfigured'], isTrue);
    expect(payload['elevenLabs']['apiKeyMask'], '****z987');
    expect(
        payload['elevenLabs']['ttsModel'], AppConfig.defaultElevenLabsTtsModel);
    expect(payload['elevenLabs']['musicModel'],
        AppConfig.defaultElevenLabsMusicModel);
    expect(text, isNot(contains('bailian-secret-1234567890')));
    expect(text, isNot(contains('volc-ark-secret-abcdefgh')));
    expect(text, isNot(contains('speech-secret-abcdef')));
    expect(text, isNot(contains('elevenlabs-secret-xyz987')));
    expect(payload['aliyunBailian'], isNot(contains('baseUrl')));
    expect(payload['aliyunBailian'], isNot(contains('apiBaseUrl')));
    expect(payload['aliyunBailian'], isNot(contains('realtimeAsrUrl')));
    expect(payload['volcengine'], isNot(contains('arkBaseUrl')));
    expect(payload['elevenLabs'], isNot(contains('baseUrl')));
  });

  test('normalizes unsupported and legacy ASR models', () async {
    AppConfig.setRuntimeConfigForTest(
      aliyunBailianAsrModel: 'fun-asr',
      aliyunBailianRealtimeAsrModel: 'qwen3-asr-realtime',
      volcAsrModel: 'unsupported',
    );

    expect(await AppConfig.aliyunBailianAsrModel,
        AppConfig.defaultAliyunBailianAsrModel);
    expect(await AppConfig.aliyunBailianRealtimeAsrModel,
        AppConfig.defaultAliyunBailianRealtimeAsrModel);
    expect(await AppConfig.volcAsrModel, AppConfig.defaultVolcAsrModel);
  });

  test('migrates legacy ASR provider and removes saved endpoint overrides',
      () async {
    final previousDirectory = Directory.current;
    final tempDirectory =
        Directory.systemTemp.createTempSync('tomato_asr_migration_test_');
    addTearDown(() {
      Directory.current = previousDirectory;
      if (tempDirectory.existsSync()) {
        tempDirectory.deleteSync(recursive: true);
      }
    });
    Directory.current = tempDirectory;
    secureValues.addAll({
      'ai_provider': AppConfig.aiProviderVolcengine,
      'text_provider': AppConfig.aiProviderAliyunBailian,
      'aliyun_bailian_realtime_asr_model': 'qwen3-asr-realtime',
      'aliyun_bailian_base_url': 'https://legacy.example/compatible',
      'aliyun_bailian_api_base_url': 'https://legacy.example/api',
      'aliyun_bailian_realtime_asr_url': 'wss://legacy.example/realtime',
      'volc_ark_base_url': 'https://legacy.example/ark',
      'elevenlabs_base_url': 'https://legacy.example/elevenlabs',
    });

    await AppConfig.seedSecureStorageFromEnvironment();
    AppConfig.resetRuntimeConfigForTest();

    expect(await AppConfig.asrProvider, AppConfig.aiProviderVolcengine);
    expect(await AppConfig.textProvider, AppConfig.aiProviderAliyunBailian);
    expect(await AppConfig.imageProvider, AppConfig.aiProviderVolcengine);
    expect(await AppConfig.ttsProvider, AppConfig.aiProviderVolcengine);
    expect(await AppConfig.aliyunBailianRealtimeAsrModel,
        AppConfig.defaultAliyunBailianRealtimeAsrModel);
    expect(await AppConfig.aliyunBailianBaseUrl,
        AppConfig.defaultAliyunBailianBaseUrl);
    expect(await AppConfig.volcArkBaseUrl, AppConfig.defaultVolcArkBaseUrl);
    expect(
        await AppConfig.elevenLabsBaseUrl, AppConfig.defaultElevenLabsBaseUrl);
    expect(secureValues, isNot(contains('aliyun_bailian_base_url')));
    expect(secureValues, isNot(contains('aliyun_bailian_api_base_url')));
    expect(secureValues, isNot(contains('aliyun_bailian_realtime_asr_url')));
    expect(secureValues, isNot(contains('volc_ark_base_url')));
    expect(secureValues, isNot(contains('elevenlabs_base_url')));
  });

  test('seeds ElevenLabs key from security file without switching provider',
      () async {
    final previousDirectory = Directory.current;
    final tempDirectory =
        Directory.systemTemp.createTempSync('tomato_elevenlabs_key_test_');
    addTearDown(() {
      Directory.current = previousDirectory;
      if (tempDirectory.existsSync()) {
        tempDirectory.deleteSync(recursive: true);
      }
    });

    final securityDirectory =
        Directory(_joinPath(tempDirectory.path, 'security'))..createSync();
    File(_joinPath(securityDirectory.path, 'elevenlabs.txt')).writeAsStringSync(
      'ELEVENLABS_API_KEY=elevenlabs-file-key\n',
    );
    Directory.current = tempDirectory;

    await AppConfig.seedSecureStorageFromEnvironment();

    expect(await AppConfig.elevenLabsApiKey, 'elevenlabs-file-key');
    expect(await AppConfig.ttsProvider, AppConfig.aiProviderAliyunBailian);
  });

  test('seeds ElevenLabs key from ancestor security file', () async {
    final previousDirectory = Directory.current;
    final tempDirectory =
        Directory.systemTemp.createTempSync('tomato_elevenlabs_key_test_');
    addTearDown(() {
      Directory.current = previousDirectory;
      if (tempDirectory.existsSync()) {
        tempDirectory.deleteSync(recursive: true);
      }
    });

    final securityDirectory =
        Directory(_joinPath(tempDirectory.path, 'security'))..createSync();
    File(_joinPath(securityDirectory.path, 'elevenlabs.txt')).writeAsStringSync(
      'elevenlabs-ancestor-key\n',
    );
    final packagedWorkingDirectory = Directory(
      _joinPath(tempDirectory.path, 'release/windows/app'),
    )..createSync(recursive: true);
    Directory.current = packagedWorkingDirectory;

    await AppConfig.seedSecureStorageFromEnvironment();

    expect(await AppConfig.elevenLabsApiKey, 'elevenlabs-ancestor-key');
    expect(await AppConfig.ttsProvider, AppConfig.aiProviderAliyunBailian);
  });

  test('does not read legacy security key files from working directory',
      () async {
    final previousDirectory = Directory.current;
    final tempDirectory =
        Directory.systemTemp.createTempSync('tomato_app_config_test_');
    addTearDown(() {
      Directory.current = previousDirectory;
      if (tempDirectory.existsSync()) {
        tempDirectory.deleteSync(recursive: true);
      }
    });

    final securityDirectory =
        Directory(_joinPath(tempDirectory.path, 'security'))..createSync();
    File(_joinPath(securityDirectory.path, 'ark.txt')).writeAsStringSync(
      'ARK_API_KEY=legacy-ark-key\n',
    );
    File(_joinPath(securityDirectory.path, 'speech-api-key.txt'))
        .writeAsStringSync('legacy-speech-key\n');
    Directory.current = tempDirectory;

    expect(await AppConfig.volcArkTextApiKey, '');
    expect(await AppConfig.volcArkImageApiKey, '');
    expect(await AppConfig.volcSpeechApiKey, '');
  });
}

String _joinPath(String basePath, String childPath) {
  final separator = Platform.pathSeparator;
  final normalizedChild =
      childPath.replaceAll('/', separator).replaceAll(r'\', separator);
  if (basePath.endsWith(separator)) {
    return '$basePath$normalizedChild';
  }
  return '$basePath$separator$normalizedChild';
}
