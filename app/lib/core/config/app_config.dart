import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// App 配置 — 存储 API Keys 等敏感信息
/// 使用 flutter_secure_storage 加密存储在本机
class AppConfig {
  static const _storage = FlutterSecureStorage();
  static final _cipher = AesGcm.with256bits();
  static final Map<String, String> _runtimeSecrets = <String, String>{};

  static const _encryptedApiKeyFileCandidates = [
    'security/api-key.txt',
    '../security/api-key.txt',
  ];
  static const _encryptionKeyFileCandidates = [
    'security/api-key.key.txt',
    '../security/api-key.key.txt',
  ];

  // ===== Local bootstrap via --dart-define =====
  static const _envVolcTtsAppId = String.fromEnvironment('TOMATO_VOLC_TTS_APP_ID');
  static const _envVolcTtsToken = String.fromEnvironment('TOMATO_VOLC_TTS_TOKEN');
  static const _envVolcAccessKey = String.fromEnvironment('TOMATO_VOLC_ACCESS_KEY');
  static const _envVolcSecretKey = String.fromEnvironment('TOMATO_VOLC_SECRET_KEY');
  static const _envVolcTtsApiKey = String.fromEnvironment('TOMATO_VOLC_TTS_API_KEY');
  static const _envVolcTtsResourceId = String.fromEnvironment('TOMATO_VOLC_TTS_RESOURCE_ID');
  static const _envVolcTtsSpeakerId = String.fromEnvironment('TOMATO_VOLC_TTS_SPEAKER_ID');
  static const _envVolcRealtimeAppId = String.fromEnvironment('TOMATO_VOLC_REALTIME_APP_ID');
  static const _envVolcRealtimeApiKey = String.fromEnvironment('TOMATO_VOLC_REALTIME_API_KEY');
  static const _envVolcBigAsrApiKey = String.fromEnvironment('TOMATO_VOLC_BIGASR_API_KEY');

  // ===== 火山引擎 TTS =====
  static const _volcTtsAppId = 'volc_tts_appid';
  static const _volcTtsToken = 'volc_tts_token';
  static const _volcAccessKey = 'volc_access_key';
  static const _volcSecretKey = 'volc_secret_key';
  static const _volcTtsApiKey = 'volc_tts_api_key';
  static const _volcTtsResourceId = 'volc_tts_resource_id';
  static const _volcTtsSpeakerId = 'volc_tts_speaker_id';

  // ===== 实时语音与 BigASR =====
  static const _volcRealtimeAppId = 'volc_realtime_app_id';
  static const _volcRealtimeApiKey = 'volc_realtime_api_key';
  static const _volcBigAsrApiKey = 'volc_bigasr_api_key';

    static Future<String> get volcTtsAppId async =>
      await _readSecret(key: _volcTtsAppId);
    static Future<String> get volcTtsToken async =>
      await _readSecret(key: _volcTtsToken);
    static Future<String> get volcAccessKey async =>
      await _readSecret(key: _volcAccessKey);
    static Future<String> get volcSecretKey async =>
      await _readSecret(key: _volcSecretKey);
    static Future<String> get volcTtsApiKey async =>
      await _readSecret(key: _volcTtsApiKey);
    static Future<String> get volcTtsResourceId async =>
      await _readSecret(key: _volcTtsResourceId, defaultValue: 'seed-tts-2.0');
    static Future<String> get volcTtsSpeakerId async =>
      await _readSecret(key: _volcTtsSpeakerId);
    static Future<String> get volcRealtimeAppId async =>
      await _readSecret(key: _volcRealtimeAppId);
  static Future<String> get volcRealtimeApiKey async {
    final dedicated = await _readSecret(key: _volcRealtimeApiKey);
    if (dedicated.trim().isNotEmpty) {
      return dedicated;
    }

    // New unified-key mode: Realtime can share TTS 2.0 API key.
    return await volcTtsApiKey;
  }

  static Future<String> get volcBigAsrApiKey async {
    final dedicated = await _readSecret(key: _volcBigAsrApiKey);
    if (dedicated.trim().isNotEmpty) {
      return dedicated;
    }

    // New unified-key mode: BigASR can share TTS 2.0 API key.
    return await volcTtsApiKey;
  }

  static Future<void> seedSecureStorageFromEnvironment() async {
    try {
      await _writeIfProvided(key: _volcTtsAppId, value: _envVolcTtsAppId);
      await _writeIfProvided(key: _volcTtsToken, value: _envVolcTtsToken);
      await _writeIfProvided(key: _volcAccessKey, value: _envVolcAccessKey);
      await _writeIfProvided(key: _volcSecretKey, value: _envVolcSecretKey);
      await _writeIfProvided(key: _volcTtsApiKey, value: _envVolcTtsApiKey);
      await _writeIfProvided(key: _volcTtsResourceId, value: _envVolcTtsResourceId);
      await _writeIfProvided(key: _volcTtsSpeakerId, value: _envVolcTtsSpeakerId);
      await _writeIfProvided(key: _volcRealtimeAppId, value: _envVolcRealtimeAppId);
      await _writeIfProvided(key: _volcRealtimeApiKey, value: _envVolcRealtimeApiKey);
      await _writeIfProvided(key: _volcBigAsrApiKey, value: _envVolcBigAsrApiKey);
    } catch (e) {
      debugPrint('[AppConfig] secure storage bootstrap failed: $e');
    }
  }

  static Future<void> seedSecureStorageFromEncryptedFile() async {
    try {
      final encryptedFile = _findExistingFile(_encryptedApiKeyFileCandidates);
      final keyFile = _findExistingFile(_encryptionKeyFileCandidates);
      if (encryptedFile == null || keyFile == null) {
        return;
      }

      final encryptedContent = await encryptedFile.readAsString();
      final keyContent = await keyFile.readAsString();
      final decryptedJson = await _decryptJsonPayload(
        encryptedJsonText: encryptedContent,
        base64KeyText: keyContent,
      );

      await _seedFromEncryptedMap(decryptedJson);
    } catch (e) {
      debugPrint('[AppConfig] encrypted file bootstrap failed: $e');
    }
  }

  static Future<void> saveVolcTts({
    required String appId,
    required String token,
    required String ak,
    required String sk,
  }) async {
    await _storage.write(key: _volcTtsAppId, value: appId);
    await _storage.write(key: _volcTtsToken, value: token);
    await _storage.write(key: _volcAccessKey, value: ak);
    await _storage.write(key: _volcSecretKey, value: sk);
  }

  static Future<void> saveVolcTtsV3({
    required String apiKey,
    String resourceId = 'seed-tts-2.0',
    String speakerId = '',
  }) async {
    await _storage.write(key: _volcTtsApiKey, value: apiKey);
    await _storage.write(key: _volcTtsResourceId, value: resourceId);
    await _storage.write(key: _volcTtsSpeakerId, value: speakerId);
  }

  static Future<void> saveVolcRealtime({
    String apiKey = '',
    String accessKey = '',
    String appId = '',
  }) async {
    final resolvedAccessKey = accessKey.trim().isNotEmpty
        ? accessKey.trim()
        : apiKey.trim();

    await _storage.write(key: _volcRealtimeApiKey, value: resolvedAccessKey);
    await _storage.write(key: _volcRealtimeAppId, value: appId.trim());
  }

  static Future<void> saveVolcBigAsr({
    required String apiKey,
  }) async {
    await _storage.write(key: _volcBigAsrApiKey, value: apiKey);
  }

  static Future<void> _writeIfProvided({
    required String key,
    required String value,
  }) async {
    final trimmedValue = value.trim();
    if (trimmedValue.isEmpty) {
      return;
    }

    final currentValue = await _storage.read(key: key);
    if (currentValue == trimmedValue) {
      return;
    }

    await _storage.write(key: key, value: trimmedValue);
  }

  static File? _findExistingFile(List<String> filePathCandidates) {
    for (final path in filePathCandidates) {
      final file = File(path);
      if (file.existsSync()) {
        return file;
      }
    }

    return null;
  }

  static Future<Map<String, dynamic>> _decryptJsonPayload({
    required String encryptedJsonText,
    required String base64KeyText,
  }) async {
    final encryptedMap = jsonDecode(encryptedJsonText);
    if (encryptedMap is! Map<String, dynamic>) {
      throw const FormatException('Encrypted API payload must be JSON object');
    }

    final nonceText = encryptedMap['nonce'];
    final cipherText = encryptedMap['cipherText'];
    final macText = encryptedMap['mac'];

    if (nonceText is! String || cipherText is! String || macText is! String) {
      throw const FormatException('Encrypted API payload missing nonce/cipherText/mac');
    }

    final keyText = base64KeyText.trim();
    final secretKey = SecretKey(base64Decode(keyText));
    final secretBox = SecretBox(
      base64Decode(cipherText),
      nonce: base64Decode(nonceText),
      mac: Mac(base64Decode(macText)),
    );

    final clearTextBytes = await _cipher.decrypt(
      secretBox,
      secretKey: secretKey,
    );
    final clearText = utf8.decode(clearTextBytes);
    final clearMap = jsonDecode(clearText);

    if (clearMap is! Map<String, dynamic>) {
      throw const FormatException('Decrypted API payload must be JSON object');
    }

    return clearMap;
  }

  static Future<void> _seedFromEncryptedMap(Map<String, dynamic> decryptedMap) async {
    final volcTtsApiKey = (decryptedMap['volc_tts_api_key'] as String?) ?? '';
    _setRuntimeSecretIfProvided(key: _volcTtsApiKey, value: volcTtsApiKey);

    final volcTtsResourceId = (decryptedMap['volc_tts_resource_id'] as String?) ?? '';
    _setRuntimeSecretIfProvided(key: _volcTtsResourceId, value: volcTtsResourceId);

    final volcTtsSpeakerId = (decryptedMap['volc_tts_speaker_id'] as String?) ?? '';
    _setRuntimeSecretIfProvided(key: _volcTtsSpeakerId, value: volcTtsSpeakerId);

    final volcRealtimeApiKey = (decryptedMap['volc_realtime_api_key'] as String?) ?? '';
    _setRuntimeSecretIfProvided(key: _volcRealtimeApiKey, value: volcRealtimeApiKey);

    final volcRealtimeAppId = (decryptedMap['volc_realtime_app_id'] as String?) ?? '';
    _setRuntimeSecretIfProvided(key: _volcRealtimeAppId, value: volcRealtimeAppId);

    final volcBigAsrApiKey = (decryptedMap['volc_bigasr_api_key'] as String?) ?? '';
    _setRuntimeSecretIfProvided(key: _volcBigAsrApiKey, value: volcBigAsrApiKey);
  }

  static Future<String> _readSecret({
    required String key,
    String defaultValue = '',
  }) async {
    final runtimeValue = _runtimeSecrets[key];
    if (runtimeValue != null && runtimeValue.isNotEmpty) {
      return runtimeValue;
    }

    return await _storage.read(key: key) ?? defaultValue;
  }

  static void _setRuntimeSecretIfProvided({
    required String key,
    required String value,
  }) {
    final trimmedValue = value.trim();
    if (trimmedValue.isEmpty) {
      return;
    }

    _runtimeSecrets[key] = trimmedValue;
  }
}

/// Riverpod provider — 判断是否已配置 API Keys
final configReadyProvider = FutureProvider<bool>((ref) async {
  final legacyToken = await AppConfig.volcTtsToken;
  final ttsApiKey = await AppConfig.volcTtsApiKey;
  final realtimeApiKey = await AppConfig.volcRealtimeApiKey;
  return legacyToken.isNotEmpty || ttsApiKey.isNotEmpty || realtimeApiKey.isNotEmpty;
});
