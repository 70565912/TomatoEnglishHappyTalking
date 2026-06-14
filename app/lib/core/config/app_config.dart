import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// App 配置 — 存储统一 API Key 等敏感信息
/// 使用 flutter_secure_storage 加密存储在本机
class AppConfig {
  static const _storage = FlutterSecureStorage();
  static final Map<String, String> _runtimeSecrets = <String, String>{};

  static const _maxConfigParentSearchDepth = 8;

  // ===== Local bootstrap via --dart-define =====
  static const _envVolcTtsResourceId =
      String.fromEnvironment('TOMATO_VOLC_TTS_RESOURCE_ID');
  static const _envVolcTtsSpeakerId =
      String.fromEnvironment('TOMATO_VOLC_TTS_SPEAKER_ID');
  static const _envVolcSpeechApiKey =
      String.fromEnvironment('TOMATO_VOLC_SPEECH_API_KEY');
  static const _envVolcArkApiKey =
      String.fromEnvironment('TOMATO_VOLC_ARK_API_KEY');
  static const _envVolcArkTextModel =
      String.fromEnvironment('TOMATO_VOLC_ARK_TEXT_MODEL');
  static const defaultVolcArkTextModel = 'doubao-seed-2-0-lite-260215';

  static const _speechApiKeyFileCandidates = [
    'speech-api-key.txt',
    'security/speech-api-key.txt',
    '../speech-api-key.txt',
    '../security/speech-api-key.txt',
  ];

  static const _arkApiKeyFileCandidates = [
    'ark.txt',
    'security/ark.txt',
    '../ark.txt',
    '../security/ark.txt',
  ];

  // ===== 火山引擎 TTS =====
  static const _volcTtsResourceId = 'volc_tts_resource_id';
  static const _volcTtsSpeakerId = 'volc_tts_speaker_id';

  // ===== 实时语音与 BigASR =====
  static const _volcSpeechApiKey = 'volc_speech_api_key';
  static const _volcArkApiKey = 'volc_ark_api_key';
  static const _volcArkTextModel = 'volc_ark_text_model';
  static const _recordingCodec = 'recording_codec';
  static const _recordingResolution = 'recording_resolution';
  static const _recordingPageTransition = 'recording_page_transition';
  static const _sunoOutputDirectory = 'suno_output_directory';
  static const _sunoTimeoutMinutes = 'suno_timeout_minutes';

  static Future<String> get volcTtsResourceId async =>
      await _readSecret(key: _volcTtsResourceId, defaultValue: 'seed-tts-2.0');
  static Future<String> get volcTtsSpeakerId async {
    final storageValue = await _readStorageSecret(key: _volcTtsSpeakerId);
    if (storageValue.isNotEmpty) {
      return storageValue;
    }

    return _runtimeSecrets[_volcTtsSpeakerId]?.trim() ?? '';
  }

  static Future<String> get volcSpeechApiKey async {
    final speechApiKeyFile = _findExistingFile(_speechApiKeyFileCandidates);
    if (speechApiKeyFile != null) {
      try {
        final value =
            _parseSpeechApiKeyFile(await speechApiKeyFile.readAsString());
        if (value.isNotEmpty) {
          return value;
        }
      } catch (e) {
        debugPrint('[AppConfig] speech-api-key.txt read failed: $e');
      }
    }

    final envValue = _envVolcSpeechApiKey.trim();
    if (envValue.isNotEmpty) {
      return envValue;
    }

    return _readSecret(key: _volcSpeechApiKey);
  }

  static Future<String> get volcTtsApiKey async => await volcSpeechApiKey;

  static Future<String> get volcRealtimeApiKey async => await volcSpeechApiKey;

  static Future<String> get volcBigAsrApiKey async => await volcSpeechApiKey;

  static Future<String> get volcArkTextApiKey async {
    final arkApiKeyFile = _findExistingFile(_arkApiKeyFileCandidates);
    if (arkApiKeyFile != null) {
      try {
        final value = _parseArkApiKeyFile(await arkApiKeyFile.readAsString());
        if (value.isNotEmpty) {
          return value;
        }
      } catch (e) {
        debugPrint('[AppConfig] ark.txt read failed: $e');
      }
    }

    final envValue = _envVolcArkApiKey.trim();
    if (envValue.isNotEmpty) {
      return _stripBearerPrefix(envValue);
    }

    return _readSecret(key: _volcArkApiKey);
  }

  static Future<String> get volcArkTextModel async {
    final arkApiKeyFile = _findExistingFile(_arkApiKeyFileCandidates);
    if (arkApiKeyFile != null) {
      try {
        final value =
            _parseArkTextModelFile(await arkApiKeyFile.readAsString());
        if (value.isNotEmpty) {
          return value;
        }
      } catch (e) {
        debugPrint('[AppConfig] ark.txt model read failed: $e');
      }
    }

    final envValue = _envVolcArkTextModel.trim();
    if (envValue.isNotEmpty) {
      return envValue;
    }

    final stored = await _readSecret(key: _volcArkTextModel);
    return stored.isNotEmpty ? stored : defaultVolcArkTextModel;
  }

  static Future<String> get volcArkImageApiKey async {
    final arkApiKeyFile = _findExistingFile(_arkApiKeyFileCandidates);
    if (arkApiKeyFile != null) {
      try {
        final value = _parseArkApiKeyFile(await arkApiKeyFile.readAsString());
        if (value.isNotEmpty) {
          return value;
        }
      } catch (e) {
        debugPrint('[AppConfig] ark.txt image key read failed: $e');
      }
    }

    final envValue = _envVolcArkApiKey.trim();
    if (envValue.isNotEmpty) {
      return _stripBearerPrefix(envValue);
    }

    return _readSecret(key: _volcArkApiKey);
  }

  static String _parseSpeechApiKeyFile(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return '';
    }

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        return _firstNonEmpty([
          decoded['X-Api-Key']?.toString(),
          decoded['x_api_key']?.toString(),
          decoded['speech_api_key']?.toString(),
          decoded['volc_speech_api_key']?.toString(),
          decoded['api_key']?.toString(),
          decoded['apiKey']?.toString(),
        ]);
      }
    } catch (_) {
      // Plain text is the common local format.
    }

    final labeledPattern = RegExp(
      r'^\s*(?:X-Api-Key|SPEECH_API_KEY|TOMATO_VOLC_SPEECH_API_KEY|volc_speech_api_key|api[_ -]?key)\s*[:=]\s*(.+?)\s*$',
      caseSensitive: false,
    );
    final values = <String>[];
    for (final rawLine in trimmed.split(RegExp(r'[\r\n]+'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      final match = labeledPattern.firstMatch(line);
      if (match != null) {
        return match.group(1)?.trim() ?? '';
      }
      values.add(line);
    }
    if (values.isEmpty) {
      return '';
    }

    final uuidLike = values.where((value) {
      return RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        caseSensitive: false,
      ).hasMatch(value);
    }).toList(growable: false);
    if (uuidLike.isNotEmpty) {
      return uuidLike.first;
    }

    final longValues =
        values.where((value) => value.length >= 32).toList(growable: false);
    if (longValues.isNotEmpty) {
      return longValues.first;
    }

    return values.first;
  }

  static String _parseArkApiKeyFile(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return '';
    }

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        return _stripBearerPrefix(
          _firstNonEmpty([
            decoded['ARK_API_KEY']?.toString(),
            decoded['TOMATO_VOLC_ARK_API_KEY']?.toString(),
            decoded['volc_ark_api_key']?.toString(),
            decoded['api_key']?.toString(),
            decoded['apiKey']?.toString(),
          ]),
        );
      }
    } catch (_) {
      // Plain text and key:value lines are the common local formats.
    }

    final labeledPattern = RegExp(
      r'^(?:ARK_API_KEY|TOMATO_VOLC_ARK_API_KEY|volc_ark_api_key|api[_ -]?key)\s*[:=]\s*(.+)$',
      caseSensitive: false,
    );
    final unlabeledValues = <String>[];
    for (final rawLine in trimmed.split(RegExp(r'[\r\n]+'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      final match = labeledPattern.firstMatch(line);
      if (match != null) {
        return _stripBearerPrefix(match.group(1) ?? '');
      }
      if (RegExp(r'^[A-Za-z_][A-Za-z0-9_\- ]*\s*[:=]').hasMatch(line)) {
        continue;
      }
      unlabeledValues.add(line);
    }

    if (RegExp(
      r'AccessKeyId|SecretAccessKey',
      caseSensitive: false,
    ).hasMatch(trimmed)) {
      return '';
    }

    if (unlabeledValues.isEmpty) {
      return '';
    }
    if (unlabeledValues.length == 1) {
      return _stripBearerPrefix(unlabeledValues.first);
    }

    final longValues = unlabeledValues
        .where((value) => value.length >= 32)
        .toList(growable: false)
      ..sort((left, right) => right.length.compareTo(left.length));
    if (longValues.isNotEmpty) {
      return _stripBearerPrefix(longValues.first);
    }
    return '';
  }

  static String _parseArkTextModelFile(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return '';
    }

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        return _firstNonEmpty([
          decoded['ARK_TEXT_MODEL']?.toString(),
          decoded['TOMATO_VOLC_ARK_TEXT_MODEL']?.toString(),
          decoded['volc_ark_text_model']?.toString(),
          decoded['model']?.toString(),
        ]).trim();
      }
    } catch (_) {
      // Plain text and key:value lines are the common local formats.
    }

    final labeledPattern = RegExp(
      r'^(?:ARK_TEXT_MODEL|TOMATO_VOLC_ARK_TEXT_MODEL|volc_ark_text_model|model)\s*[:=]\s*(.+)$',
      caseSensitive: false,
    );
    for (final rawLine in trimmed.split(RegExp(r'[\r\n]+'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      final match = labeledPattern.firstMatch(line);
      if (match != null) {
        return match.group(1)?.trim() ?? '';
      }
    }
    return '';
  }

  static String _stripBearerPrefix(String value) {
    return value
        .trim()
        .replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '')
        .trim();
  }

  static Future<void> seedSecureStorageFromEnvironment() async {
    try {
      await _writeIfProvided(
          key: _volcTtsResourceId, value: _envVolcTtsResourceId);
      await _writeIfProvided(
          key: _volcTtsSpeakerId, value: _envVolcTtsSpeakerId);
      await _writeIfProvided(
        key: _volcSpeechApiKey,
        value: _envVolcSpeechApiKey,
      );
      await _writeIfProvided(key: _volcArkApiKey, value: _envVolcArkApiKey);
      await _writeIfProvided(
          key: _volcArkTextModel, value: _envVolcArkTextModel);
    } catch (e) {
      debugPrint('[AppConfig] secure storage bootstrap failed: $e');
    }
  }

  static Future<void> saveVolcTtsV3({
    required String apiKey,
    String resourceId = 'seed-tts-2.0',
    String speakerId = '',
  }) async {
    await _writeIfProvided(key: _volcSpeechApiKey, value: apiKey);
    await _storage.write(key: _volcTtsResourceId, value: resourceId);
    await _storage.write(key: _volcTtsSpeakerId, value: speakerId);
    _runtimeSecrets[_volcTtsSpeakerId] = speakerId.trim();
  }

  static Future<void> saveVolcTtsSpeakerId(String speakerId) async {
    final trimmedSpeakerId = speakerId.trim();
    await _storage.write(key: _volcTtsSpeakerId, value: trimmedSpeakerId);
    _runtimeSecrets[_volcTtsSpeakerId] = trimmedSpeakerId;
  }

  static Future<Map<String, String>> get recordingSettings async => {
        'codec': await _readSecret(
          key: _recordingCodec,
          defaultValue: 'h264',
        ),
        'resolution': await _readSecret(
          key: _recordingResolution,
          defaultValue: '1920x1080',
        ),
        'pageTransition': await _readSecret(
          key: _recordingPageTransition,
          defaultValue: 'none',
        ),
      };

  static Future<void> saveRecordingSettings({
    required String codec,
    required String resolution,
    required String pageTransition,
  }) async {
    await _storage.write(key: _recordingCodec, value: codec.trim());
    await _storage.write(key: _recordingResolution, value: resolution.trim());
    await _storage.write(
      key: _recordingPageTransition,
      value: pageTransition.trim(),
    );
    _runtimeSecrets[_recordingCodec] = codec.trim();
    _runtimeSecrets[_recordingResolution] = resolution.trim();
    _runtimeSecrets[_recordingPageTransition] = pageTransition.trim();
  }

  static Future<Map<String, String>> get songSettings async => {
        'sunoOutputDirectory': await _readSecret(
          key: _sunoOutputDirectory,
          defaultValue: '',
        ),
        'sunoTimeoutMinutes': await _readSecret(
          key: _sunoTimeoutMinutes,
          defaultValue: '20',
        ),
      };

  static Future<void> saveSongSettings({
    required String sunoOutputDirectory,
    required int sunoTimeoutMinutes,
  }) async {
    final timeout = sunoTimeoutMinutes.clamp(5, 120).toString();
    await _storage.write(
      key: _sunoOutputDirectory,
      value: sunoOutputDirectory.trim(),
    );
    await _storage.write(key: _sunoTimeoutMinutes, value: timeout);
    _runtimeSecrets[_sunoOutputDirectory] = sunoOutputDirectory.trim();
    _runtimeSecrets[_sunoTimeoutMinutes] = timeout;
  }

  static Future<void> saveVolcBigAsr({
    required String apiKey,
  }) async {
    await _writeIfProvided(key: _volcSpeechApiKey, value: apiKey);
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
    final checkedPaths = <String>{};
    for (final file in _configFileCandidates(filePathCandidates)) {
      if (!checkedPaths.add(file.absolute.path)) {
        continue;
      }
      if (file.existsSync()) {
        return file;
      }
    }

    return null;
  }

  @visibleForTesting
  static File? findExistingFileForTest(List<String> filePathCandidates) =>
      _findExistingFile(filePathCandidates);

  static Iterable<File> _configFileCandidates(
    List<String> filePathCandidates,
  ) sync* {
    for (final path in filePathCandidates) {
      yield File(path);
    }

    for (final baseDirectory in _candidateBaseDirectories()) {
      for (final directory in _selfAndParents(baseDirectory)) {
        for (final path in filePathCandidates) {
          final file = File(path);
          if (file.isAbsolute) {
            continue;
          }
          yield File(_joinPath(directory.path, path));
        }
      }
    }
  }

  static List<Directory> _candidateBaseDirectories() {
    final directories = <String, Directory>{};

    void addDirectory(Directory directory) {
      final absoluteDirectory = directory.absolute;
      directories[absoluteDirectory.path] = absoluteDirectory;
    }

    addDirectory(Directory.current);

    final executablePath = Platform.resolvedExecutable.trim();
    if (executablePath.isNotEmpty) {
      addDirectory(File(executablePath).parent);
    }

    return directories.values.toList(growable: false);
  }

  static Iterable<Directory> _selfAndParents(Directory start) sync* {
    var directory = start.absolute;
    for (var depth = 0; depth <= _maxConfigParentSearchDepth; depth += 1) {
      yield directory;
      final parent = directory.parent.absolute;
      if (parent.path == directory.path) {
        break;
      }
      directory = parent;
    }
  }

  static String _joinPath(String basePath, String childPath) {
    final separator = Platform.pathSeparator;
    final normalizedChild =
        childPath.replaceAll('/', separator).replaceAll(r'\', separator);
    if (basePath.endsWith(separator)) {
      return '$basePath$normalizedChild';
    }
    return '$basePath$separator$normalizedChild';
  }

  static Future<String> _readSecret({
    required String key,
    String defaultValue = '',
  }) async {
    final runtimeValue = _runtimeSecrets[key];
    if (runtimeValue != null && runtimeValue.isNotEmpty) {
      return runtimeValue;
    }

    final storageValue = await _readStorageSecret(key: key);
    return storageValue.isNotEmpty ? storageValue : defaultValue;
  }

  static Future<String> _readStorageSecret({required String key}) async {
    try {
      return (await _storage.read(key: key))?.trim() ?? '';
    } catch (e) {
      final message = e.toString().split('\n').first;
      debugPrint('[AppConfig] secure storage read failed for $key: $message');
      return '';
    }
  }

  static String _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      final trimmedValue = value?.trim() ?? '';
      if (trimmedValue.isNotEmpty) {
        return trimmedValue;
      }
    }

    return '';
  }
}

/// Riverpod provider — 判断是否已配置新版语音 API Key
final configReadyProvider = FutureProvider<bool>((ref) async {
  final apiKey = await AppConfig.volcSpeechApiKey;
  return apiKey.isNotEmpty;
});
