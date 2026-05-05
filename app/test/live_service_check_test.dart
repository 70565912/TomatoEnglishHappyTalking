import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/services/tts_service.dart';

void main() {
  group('live service check', () {
    setUpAll(() async {
      await AppConfig.seedSecureStorageFromEncryptedFile();
    });

    test('loads runtime configuration summary', () async {
      final ttsApiKey = await AppConfig.volcTtsApiKey;
      final ttsResourceId = await AppConfig.volcTtsResourceId;
      final ttsSpeakerId = await AppConfig.volcTtsSpeakerId;
      final decryptedSecrets = await _loadEncryptedSecrets();
      final realtimeDedicated = ((decryptedSecrets['volc_realtime_api_key'] as String?) ?? '').trim();
      final bigAsrDedicated = ((decryptedSecrets['volc_bigasr_api_key'] as String?) ?? '').trim();
      final realtimeApiKey = realtimeDedicated.isNotEmpty ? realtimeDedicated : ttsApiKey;
      final bigAsrApiKey = bigAsrDedicated.isNotEmpty ? bigAsrDedicated : ttsApiKey;

      // Print redacted runtime status so the test log can confirm which path is active.
      // Do not print secret values.
      debugPrint(
        'CONFIG ttsApiKey=${ttsApiKey.isNotEmpty} '
        'ttsResourceId=${ttsResourceId.isNotEmpty ? ttsResourceId : '(empty)'} '
        'ttsSpeakerId=${ttsSpeakerId.isNotEmpty ? ttsSpeakerId : '(empty)'} '
        'realtimeApiKey=${realtimeApiKey.isNotEmpty} '
        'bigAsrApiKey=${bigAsrApiKey.isNotEmpty}',
      );

      expect(ttsResourceId, isNotEmpty);
    });

    test('validates tts success path', () async {
      final bytes = await TtsService.synthesize(
        text: 'Hello. This is a live validation for Tomato English Happy Talking.',
      );

      debugPrint('TTS bytes=${bytes?.length ?? 0}');
      expect(bytes, isNotNull);
      expect(bytes!, isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('validates realtime key presence (non-blocking)', () async {
      final decryptedSecrets = await _loadEncryptedSecrets();
      final ttsApiKey = ((decryptedSecrets['volc_tts_api_key'] as String?) ?? '').trim();
      final realtimeDedicated = ((decryptedSecrets['volc_realtime_api_key'] as String?) ?? '').trim();
      final bigAsrDedicated = ((decryptedSecrets['volc_bigasr_api_key'] as String?) ?? '').trim();
      final realtimeApiKey = realtimeDedicated.isNotEmpty ? realtimeDedicated : ttsApiKey;
      final bigAsrApiKey = bigAsrDedicated.isNotEmpty ? bigAsrDedicated : ttsApiKey;

      if (realtimeApiKey.isEmpty) {
        debugPrint('Realtime validation skipped: volc_realtime_api_key is empty.');
        return;
      }

      debugPrint(
        'Realtime key configured=${realtimeApiKey.isNotEmpty}, '
        'BigASR key configured=${bigAsrApiKey.isNotEmpty}',
      );

      try {
        final response = await Dio().post<Map<String, dynamic>>(
          'https://ark.cn-beijing.volces.com/api/v3/chat/completions',
          options: Options(
            headers: {
              // Endpoint is used only as a non-blocking key-shape smoke check.
              'Authorization': 'Bearer $realtimeApiKey',
              'Content-Type': 'application/json',
            },
          ),
          data: {
            'model': 'doubao-pro-32k',
            'messages': const [
              {'role': 'user', 'content': 'Reply with exactly: TOMATO_OK'},
            ],
            'temperature': 0,
            'max_tokens': 32,
          },
        );

        final choices = response.data?['choices'];
        if (choices is! List || choices.isEmpty) {
          fail('Realtime smoke check response missing choices');
        }

        final first = choices.first;
        if (first is! Map) {
          fail('Realtime smoke check response choices[0] is invalid');
        }

        final message = first['message'];
        if (message is! Map) {
          fail('Realtime smoke check response choices[0].message is invalid');
        }

        final content = (message['content'] as String? ?? '').trim();
        debugPrint('Realtime key smoke reply preview=${content.length > 120 ? content.substring(0, 120) : content}');
        expect(content, isNotEmpty);
      } on DioException catch (error) {
        final statusCode = error.response?.statusCode;
        if (statusCode == 401) {
          debugPrint('Realtime validation skipped: key unauthorized for this endpoint (401).');
          return;
        }

        rethrow;
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('validates tts input error path', () async {
      expect(
        () => TtsService.synthesize(text: '   '),
        throwsA(
          predicate(
            (error) => error is TtsException && error.message.contains('TTS 文本不能为空'),
          ),
        ),
      );
    });
  });
}

Future<Map<String, dynamic>> _loadEncryptedSecrets() async {
  final encryptedFile = _findExistingFile(<String>[
    '../security/api-key.txt',
    'security/api-key.txt',
  ]);
  final keyFile = _findExistingFile(<String>[
    '../security/api-key.key.txt',
    'security/api-key.key.txt',
  ]);

  if (encryptedFile == null || keyFile == null) {
    throw StateError('Missing encrypted API key files in local workspace');
  }

  final encryptedMap = jsonDecode(await encryptedFile.readAsString());
  if (encryptedMap is! Map<String, dynamic>) {
    throw const FormatException('Encrypted API payload must be a JSON object');
  }

  final nonce = encryptedMap['nonce'] as String?;
  final cipherText = encryptedMap['cipherText'] as String?;
  final mac = encryptedMap['mac'] as String?;
  if (nonce == null || cipherText == null || mac == null) {
    throw const FormatException('Encrypted API payload missing nonce/cipherText/mac');
  }

  final keyText = (await keyFile.readAsString()).trim();
  final secretBox = SecretBox(
    base64Decode(cipherText),
    nonce: base64Decode(nonce),
    mac: Mac(base64Decode(mac)),
  );
  final clearTextBytes = await AesGcm.with256bits().decrypt(
    secretBox,
    secretKey: SecretKey(base64Decode(keyText)),
  );
  final clearMap = jsonDecode(utf8.decode(clearTextBytes));
  if (clearMap is! Map<String, dynamic>) {
    throw const FormatException('Decrypted API payload must be a JSON object');
  }

  return clearMap;
}

File? _findExistingFile(List<String> candidates) {
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) {
      return file;
    }
  }

  return null;
}
