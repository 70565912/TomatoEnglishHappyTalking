import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/tts_service.dart';

void main() {
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('tomato_tts_service_test_');
    DatabaseService.setDatabaseDirectoryOverrideForTest(tempDir.path);
    DatabaseService.setRuntimeDataRootOverrideForTest(tempDir.path);
    await DatabaseService.resetForTest();
    AppConfig.resetRuntimeConfigForTest();
    TtsService.setElevenLabsPostOverrideForTest(null);
    TtsService.setElevenLabsVoicesOverrideForTest(null);
    TtsService.clearElevenLabsVoiceCatalogCacheForTest();
  });

  tearDown(() async {
    TtsService.setElevenLabsPostOverrideForTest(null);
    TtsService.setElevenLabsVoicesOverrideForTest(null);
    TtsService.clearElevenLabsVoiceCatalogCacheForTest();
    AppConfig.resetRuntimeConfigForTest();
    await DatabaseService.resetForTest();
    DatabaseService.setDatabaseDirectoryOverrideForTest(null);
    DatabaseService.setRuntimeDataRootOverrideForTest(null);
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('TtsService text candidates', () {
    test('adds readable English fallback for imported mixed heading text', () {
      final candidates = TtsService.synthesisTextCandidatesForTest(
        'E25 爱丽丝梦游仙境（原著领读版）- E61 '
        'Alice\'s Adventures in Wonderland - Episod 61 '
        '"They were learning',
      );

      expect(candidates.length, 2);
      expect(candidates.first, contains('爱丽丝'));
      expect(candidates.last, '"They were learning');
      expect(candidates.last, isNot(contains('E25')));
      expect(candidates.last, isNot(contains('爱丽丝')));
    });

    test('keeps ordinary English text unchanged', () {
      final candidates = TtsService.synthesisTextCandidatesForTest(
        'Tom finds a bright snack box.',
      );

      expect(candidates, ['Tom finds a bright snack box.']);
    });

    test('keeps hyphenated words joined before synthesis', () {
      final candidates = TtsService.synthesisTextCandidatesForTest(
        'A well - known mother - in - law arrives.',
      );

      expect(candidates, ['A well-known mother-in-law arrives.']);
    });
  });

  group('ElevenLabs TTS', () {
    test('posts to text-to-speech endpoint and reuses cache', () async {
      AppConfig.setRuntimeConfigForTest(
        ttsProvider: AppConfig.aiProviderElevenLabs,
        elevenLabsApiKey: 'xi-test-key',
        elevenLabsBaseUrl: 'https://api.elevenlabs.test',
        elevenLabsTtsModel: 'eleven_multilingual_v2',
        elevenLabsTtsVoiceId: 'voice/test id',
        elevenLabsTtsOutputFormat: 'mp3_44100_128',
      );

      var calls = 0;
      String? capturedEndpoint;
      Map<String, String>? capturedHeaders;
      Map<String, dynamic>? capturedBody;
      TtsService.setElevenLabsPostOverrideForTest(
        ({
          required String endpoint,
          required Map<String, String> headers,
          required Map<String, dynamic> body,
        }) async {
          calls += 1;
          capturedEndpoint = endpoint;
          capturedHeaders = headers;
          capturedBody = body;
          return List<int>.generate(32, (index) => index + 1);
        },
      );

      final path = await TtsService.synthesizeToCachedFile(
        text: 'Hello bright world.',
        cachePurpose: 'unit_tts',
      );
      final cachedPath = await TtsService.synthesizeToCachedFile(
        text: 'Hello bright world.',
        cachePurpose: 'unit_tts',
      );

      expect(calls, 1);
      expect(cachedPath, path);
      expect(File(path).existsSync(), isTrue);
      expect(capturedEndpoint,
          'https://api.elevenlabs.test/v1/text-to-speech/voice%2Ftest%20id?output_format=mp3_44100_128');
      expect(capturedHeaders, containsPair('xi-api-key', 'xi-test-key'));
      expect(capturedHeaders, containsPair('Content-Type', 'application/json'));
      expect(capturedBody, containsPair('text', 'Hello bright world.'));
      expect(capturedBody, containsPair('model_id', 'eleven_multilingual_v2'));
    });

    test('cache keys include provider, model, voice and output format',
        () async {
      AppConfig.setRuntimeConfigForTest(
        ttsProvider: AppConfig.aiProviderElevenLabs,
        elevenLabsBaseUrl: 'https://api.elevenlabs.test',
        elevenLabsTtsModel: 'eleven_multilingual_v2',
        elevenLabsTtsVoiceId: 'voice-a',
        elevenLabsTtsOutputFormat: 'mp3_44100_128',
      );
      final elevenMp3 = await TtsService.cacheKeysForText(
        text: 'Provider split cache.',
      );

      AppConfig.setRuntimeConfigForTest(
        ttsProvider: AppConfig.aiProviderElevenLabs,
        elevenLabsBaseUrl: 'https://api.elevenlabs.test',
        elevenLabsTtsModel: 'eleven_multilingual_v2',
        elevenLabsTtsVoiceId: 'voice-a',
        elevenLabsTtsOutputFormat: 'mp3_44100_192',
      );
      final elevenHighRate = await TtsService.cacheKeysForText(
        text: 'Provider split cache.',
      );

      AppConfig.setRuntimeConfigForTest(
        ttsProvider: AppConfig.aiProviderVolcengine,
        volcTtsResourceId: 'seed-tts-2.0',
        volcTtsSpeakerId: 'voice-a',
      );
      final volcKeys = await TtsService.cacheKeysForText(
        text: 'Provider split cache.',
      );

      expect(elevenMp3, isNot(elevenHighRate));
      expect(elevenMp3.intersection(volcKeys), isEmpty);
    });

    test('throws friendly error when key is missing', () async {
      AppConfig.setRuntimeConfigForTest(
        ttsProvider: AppConfig.aiProviderElevenLabs,
        elevenLabsApiKey: '',
        elevenLabsTtsVoiceId: 'voice-a',
      );

      expect(
        () => TtsService.synthesizeToCachedFile(
          text: 'No key here.',
          cachePurpose: 'missing_key_tts',
          forceRefresh: true,
        ),
        throwsA(
          isA<TtsException>().having(
            (error) => error.message,
            'message',
            contains('ElevenLabs API Key'),
          ),
        ),
      );
    });

    test('loads ElevenLabs voice catalog from v2 voices endpoint', () async {
      AppConfig.setRuntimeConfigForTest(
        elevenLabsApiKey: 'xi-catalog-key',
        elevenLabsBaseUrl: 'https://api.elevenlabs.test/',
      );

      String? capturedEndpoint;
      Map<String, String>? capturedHeaders;
      TtsService.setElevenLabsVoicesOverrideForTest(
        ({
          required String endpoint,
          required Map<String, String> headers,
        }) async {
          capturedEndpoint = endpoint;
          capturedHeaders = headers;
          return {
            'voices': [
              {
                'voice_id': 'voice-1',
                'name': 'Bella',
                'category': 'professional',
                'labels': {'accent': 'American', 'gender': 'female'},
              },
            ],
          };
        },
      );

      final result = await TtsService.elevenLabsVoiceCatalog();

      expect(capturedEndpoint, 'https://api.elevenlabs.test/v2/voices');
      expect(capturedHeaders, containsPair('xi-api-key', 'xi-catalog-key'));
      expect(result.errorMessage, isNull);
      expect(result.voices, hasLength(1));
      expect(result.voices.single.id, 'voice-1');
      expect(result.voices.single.name, 'Bella');
      expect(result.voices.single.lang, 'American');
      expect(result.voices.single.scene, 'professional');
      expect(result.voices.single.gender, 'female');
    });

    test('keeps a recent ElevenLabs voice catalog cache for repeated loads',
        () async {
      AppConfig.setRuntimeConfigForTest(
        elevenLabsApiKey: 'xi-catalog-key',
        elevenLabsBaseUrl: 'https://api.elevenlabs.test',
      );

      var calls = 0;
      TtsService.setElevenLabsVoicesOverrideForTest(
        ({
          required String endpoint,
          required Map<String, String> headers,
        }) async {
          calls += 1;
          return {
            'voices': [
              {
                'voice_id': 'voice-1',
                'name': 'Bella',
                'labels': {'accent': 'American', 'gender': 'female'},
              },
            ],
          };
        },
      );

      final first = await TtsService.elevenLabsVoiceCatalog();
      final second = await TtsService.elevenLabsVoiceCatalog();

      expect(calls, 1);
      expect(first.voices.single.name, 'Bella');
      expect(second.voices.single.name, 'Bella');
      expect(second.errorMessage, isNull);
    });

    test('surfaces ElevenLabs voice catalog error payload details', () async {
      AppConfig.setRuntimeConfigForTest(
        elevenLabsApiKey: 'xi-catalog-key',
        elevenLabsBaseUrl: 'https://api.elevenlabs.test',
      );
      TtsService.setElevenLabsVoicesOverrideForTest(
        ({
          required String endpoint,
          required Map<String, String> headers,
        }) async =>
            {
          'detail': {
            'status': 'invalid_api_key',
            'message': 'Invalid API key',
          },
        },
      );

      final result = await TtsService.elevenLabsVoiceCatalog();

      expect(result.voices, isEmpty);
      expect(result.errorMessage, contains('invalid_api_key'));
      expect(result.errorMessage, contains('Invalid API key'));
      expect(result.errorMessage, isNot(contains('xi-catalog-key')));
    });
  });
}
