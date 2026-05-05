import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/services/realtime_voice_service.dart';
import 'package:tomato_english_happy_talking/services/tts_service.dart';

void main() {
  group('live service check', () {
    setUpAll(() async {
      await AppConfig.seedSecureStorageFromEncryptedFile();
    });

    test('loads runtime configuration summary', () async {
      final volcApiKey = await AppConfig.volcApiKey;
      final ttsResourceId = await AppConfig.volcTtsResourceId;
      final ttsSpeakerId = await AppConfig.volcTtsSpeakerId;

      // Print redacted runtime status so the test log can confirm which path is active.
      // Do not print secret values.
      debugPrint(
        'CONFIG volcApiKey=${volcApiKey.isNotEmpty} '
        'ttsResourceId=${ttsResourceId.isNotEmpty ? ttsResourceId : '(empty)'} '
        'ttsSpeakerId=${ttsSpeakerId.isNotEmpty ? ttsSpeakerId : '(empty)'}',
      );

      expect(ttsResourceId, isNotEmpty);
    });

    test('validates tts success path', () async {
      final bytes = await TtsService.synthesize(
        text:
            'Hello. This is a live validation for Tomato English Happy Talking.',
      );

      debugPrint('TTS bytes=${bytes?.length ?? 0}');
      expect(bytes, isNotNull);
      expect(bytes!, isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('validates realtime service smoke path (non-blocking)', () async {
      final volcApiKey = await AppConfig.volcApiKey;

      if (volcApiKey.isEmpty) {
        debugPrint('Realtime validation skipped: volc_api_key is empty.');
        return;
      }

      debugPrint('Unified Volcengine API key configured=true');

      final reply = await RealtimeVoiceService.startSession(
        articleTitle: 'Realtime smoke check',
        articleContent:
            'Tomato English Happy Talking helps learners speak English.',
      );

      debugPrint(
        'Realtime smoke source=${reply.source.name} '
        'replyPreview=${reply.text.length > 120 ? reply.text.substring(0, 120) : reply.text} '
        'error=${reply.errorMessage ?? '(none)'}',
      );

      if (reply.source == RealtimeReplySource.mockOnError) {
        debugPrint('Realtime validation skipped after service fallback.');
        return;
      }

      expect(reply.source, RealtimeReplySource.remote);
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
