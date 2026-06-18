import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/realtime_voice_service.dart';
import 'package:tomato_english_happy_talking/services/text_generation_service.dart';
import 'package:tomato_english_happy_talking/services/tts_service.dart';

void main() {
  group('live service check', () {
    late Directory tempDir;

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      tempDir =
          await Directory.systemTemp.createTemp('tomato_live_cache_test_');
      await databaseFactory.setDatabasesPath(tempDir.path);
      DatabaseService.setDatabaseDirectoryOverrideForTest(tempDir.path);
      await DatabaseService.resetForTest();
    });

    tearDownAll(() async {
      await DatabaseService.resetForTest();
      DatabaseService.setDatabaseDirectoryOverrideForTest(null);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('loads runtime configuration summary', () async {
      final speechApiKey = await AppConfig.volcSpeechApiKey;
      final textConfig = await AppConfig.openAiTextConfig;
      final ttsResourceId = await AppConfig.volcTtsResourceId;
      final ttsSpeakerId = await AppConfig.volcTtsSpeakerId;

      // Print redacted runtime status so the test log can confirm which path is active.
      // Do not print secret values.
      debugPrint(
        'CONFIG speechApiKey=${speechApiKey.isNotEmpty} '
        'textProvider=${textConfig.provider} '
        'textApiKey=${textConfig.apiKey.isNotEmpty} '
        'textModel=${textConfig.model} '
        'textBaseUrl=${textConfig.baseUrl} '
        'ttsResourceId=${ttsResourceId.isNotEmpty ? ttsResourceId : '(empty)'} '
        'ttsSpeakerId=${ttsSpeakerId.isNotEmpty ? ttsSpeakerId : '(empty)'}',
      );

      expect(ttsResourceId, isNotEmpty);
    });

    test('validates OpenAI-compatible text smoke path (skippable)', () async {
      final textConfig = await AppConfig.openAiTextConfig;

      if (textConfig.apiKey.isEmpty) {
        debugPrint(
          'Text validation skipped: ${textConfig.provider} api key is empty.',
        );
        return;
      }

      final reply = await TextGenerationService.generateStrict(
        turns: const [
          TextGenerationTurn(role: 'user', content: 'Reply OK only.'),
        ],
        cachePurpose: 'openai_text_live_smoke',
        maxTokens: 8,
      );

      debugPrint(
        'Text smoke provider=${textConfig.provider} '
        'source=${reply.source.name} '
        'replyPreview=${reply.text.length > 80 ? reply.text.substring(0, 80) : reply.text} '
        'error=${reply.errorMessage ?? '(none)'}',
      );

      expect(
        reply.source,
        isIn([
          TextGenerationReplySource.remote,
          TextGenerationReplySource.cached
        ]),
      );
      expect(reply.text.trim(), isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('validates tts success path', () async {
      final speechApiKey = await AppConfig.volcSpeechApiKey;
      if (speechApiKey.isEmpty) {
        debugPrint('TTS validation skipped: speech api key is empty.');
        return;
      }

      final bytes = await TtsService.synthesize(
        text:
            'Hello. This is a live validation for Tomato English Happy Talking.',
      );

      debugPrint('TTS bytes=${bytes?.length ?? 0}');
      expect(bytes, isNotNull);
      expect(bytes!, isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('validates realtime service smoke path (non-blocking)', () async {
      final textConfig = await AppConfig.openAiTextConfig;

      if (textConfig.apiKey.isEmpty) {
        debugPrint(
          'Realtime validation skipped: ${textConfig.provider} api key is empty.',
        );
        return;
      }

      debugPrint(
          'Realtime text provider=${textConfig.provider} configured=true');

      final reply = await RealtimeVoiceService.startSession(
        articleTitle: 'Realtime smoke check',
        chapterGuide:
            'Chapter summary: Tomato English Happy Talking helps learners speak English. Ordered coverage points: 1. The app supports practice. 2. The learner can answer a simple question. Completion rubric: ask about the app purpose.',
      );

      debugPrint(
        'Realtime smoke source=${reply.source.name} '
        'replyPreview=${reply.text.length > 120 ? reply.text.substring(0, 120) : reply.text} '
        'error=${reply.errorMessage ?? '(none)'}',
      );

      expect(
        reply.source,
        isIn([RealtimeReplySource.remote, RealtimeReplySource.cached]),
      );
      expect(reply.text.trim(), isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('validates tts input error path', () async {
      expect(
        () => TtsService.synthesize(text: '   '),
        throwsA(
          predicate(
            (error) =>
                error is TtsException && error.message.contains('TTS 文本不能为空'),
          ),
        ),
      );
    });
  });
}
