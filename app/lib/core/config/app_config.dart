import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class OpenAiTextConfig {
  const OpenAiTextConfig({
    required this.provider,
    required this.apiKey,
    required this.baseUrl,
    required this.model,
  });

  final String provider;
  final String apiKey;
  final String baseUrl;
  final String model;

  String get chatCompletionsEndpoint =>
      '${baseUrl.trim().replaceFirst(RegExp(r'/+$'), '')}/chat/completions';
}

/// App 配置 — 存储统一 API Key 等敏感信息
/// 使用 flutter_secure_storage 加密存储在本机
class AppConfig {
  static const _storage = FlutterSecureStorage();
  static final Map<String, String> _runtimeSecrets = <String, String>{};

  static const aiProviderAliyunBailian = 'aliyun_bailian';
  static const aiProviderVolcengine = 'volcengine';
  static const aiProviderElevenLabs = 'elevenlabs';
  static const volcAsrModelAuto = 'auto';
  static const volcAsrModelSeedAsrV2 = 'seedasr_v2';
  static const volcAsrModelBigAsrV1 = 'bigasr_v1';
  static const songProviderSuno = 'suno';
  static const songProviderBailianFunMusic = 'bailian_fun_music';
  static const songProviderElevenLabsMusic = 'elevenlabs_music';

  static const defaultAiProvider = aiProviderAliyunBailian;
  static const defaultVolcAsrModel = volcAsrModelAuto;
  static const defaultSongProvider = songProviderSuno;
  static const defaultAliyunBailianBaseUrl =
      'https://dashscope.aliyuncs.com/compatible-mode/v1';
  static const defaultAliyunBailianApiBaseUrl =
      'https://dashscope.aliyuncs.com/api/v1';
  static const defaultAliyunBailianTextModel = 'qwen3.7-max';
  static const defaultAliyunBailianMusicModel = 'fun-music-v1';
  static const defaultAliyunBailianImageModel = 'wan2.7-image-pro';
  static const defaultAliyunBailianImageSize = '2K';
  static const defaultAliyunBailianTtsModel = 'cosyvoice-v3-flash';
  static const defaultAliyunBailianTtsVoice = 'loongabby_v3';
  static const defaultAliyunBailianTtsSampleRate = '24000';
  static const defaultAliyunBailianAsrModel = 'qwen3-asr-flash';
  static const defaultAliyunBailianRealtimeAsrModel =
      'qwen3-asr-flash-realtime';
  static const defaultAliyunBailianRealtimeAsrUrl =
      'wss://dashscope.aliyuncs.com/api-ws/v1/realtime';
  static const defaultVolcArkBaseUrl =
      'https://ark.cn-beijing.volces.com/api/v3';
  static const defaultVolcArkTextModel = 'deepseek-v4-flash-ga-260731';
  static const defaultVolcArkImageModel = 'doubao-seedream-5-0-260128';
  static const defaultElevenLabsBaseUrl = 'https://api.elevenlabs.io';
  static const defaultElevenLabsTtsModel = 'eleven_multilingual_v2';
  static const defaultElevenLabsTtsVoiceId = 'JBFqnCBsd6RMkjVDRZzb';
  static const defaultElevenLabsTtsOutputFormat = 'mp3_44100_128';
  static const defaultElevenLabsMusicModel = 'music_v2';
  static const defaultElevenLabsMusicOutputFormat = 'mp3_44100_128';

  // ===== Local non-key bootstrap via --dart-define =====
  static const _envVolcTtsResourceId =
      String.fromEnvironment('TOMATO_VOLC_TTS_RESOURCE_ID');
  static const _envVolcTtsSpeakerId =
      String.fromEnvironment('TOMATO_VOLC_TTS_SPEAKER_ID');

  // ===== 火山引擎 TTS =====
  static const _volcTtsResourceId = 'volc_tts_resource_id';
  static const _volcTtsSpeakerId = 'volc_tts_speaker_id';

  // ===== 实时语音与火山 ASR（SeedASR / 可选 BigASR）=====
  static const _aiProvider = 'ai_provider';
  static const _asrProvider = 'asr_provider';
  static const _textProvider = 'text_provider';
  static const _imageProvider = 'image_provider';
  static const _ttsProvider = 'tts_provider';
  static const _aliyunBailianApiKey = 'aliyun_bailian_api_key';
  static const _aliyunBailianBaseUrl = 'aliyun_bailian_base_url';
  static const _aliyunBailianApiBaseUrl = 'aliyun_bailian_api_base_url';
  static const _aliyunBailianTextModel = 'aliyun_bailian_text_model';
  static const _aliyunBailianMusicModel = 'aliyun_bailian_music_model';
  static const _aliyunBailianImageModel = 'aliyun_bailian_image_model';
  static const _aliyunBailianImageSize = 'aliyun_bailian_image_size';
  static const _aliyunBailianTtsModel = 'aliyun_bailian_tts_model';
  static const _aliyunBailianTtsVoice = 'aliyun_bailian_tts_voice';
  static const _aliyunBailianTtsSampleRate = 'aliyun_bailian_tts_sample_rate';
  static const _aliyunBailianAsrModel = 'aliyun_bailian_asr_model';
  static const _aliyunBailianRealtimeAsrModel =
      'aliyun_bailian_realtime_asr_model';
  static const _aliyunBailianRealtimeAsrUrl = 'aliyun_bailian_realtime_asr_url';
  static const _volcSpeechApiKey = 'volc_speech_api_key';
  static const _volcAsrModel = 'volc_asr_model';
  static const _volcArkApiKey = 'volc_ark_api_key';
  static const _volcArkBaseUrl = 'volc_ark_base_url';
  static const _volcArkTextModel = 'volc_ark_text_model';
  static const _volcArkImageModel = 'volc_ark_image_model';
  static const _elevenLabsApiKey = 'elevenlabs_api_key';
  static const _elevenLabsBaseUrl = 'elevenlabs_base_url';
  static const _elevenLabsTtsModel = 'elevenlabs_tts_model';
  static const _elevenLabsTtsVoiceId = 'elevenlabs_tts_voice_id';
  static const _elevenLabsTtsOutputFormat = 'elevenlabs_tts_output_format';
  static const _elevenLabsMusicModel = 'elevenlabs_music_model';
  static const _elevenLabsMusicOutputFormat = 'elevenlabs_music_output_format';
  static const _recordingCodec = 'recording_codec';
  static const _recordingResolution = 'recording_resolution';
  static const _recordingPageTransition = 'recording_page_transition';
  static const _recordingSubtitleMode = 'recording_subtitle_mode';
  static const _songProvider = 'song_provider';
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

  /// Legacy compatibility alias. New code should use [asrProvider].
  static Future<String> get aiProvider async => asrProvider;

  static Future<String> get asrProvider async {
    final stored = await _readSecret(key: _asrProvider);
    if (stored.trim().isNotEmpty) {
      return _normalizeAiProvider(stored);
    }
    return _normalizeAiProvider(
      await _readSecret(
        key: _aiProvider,
        defaultValue: defaultAiProvider,
      ),
    );
  }

  static Future<String> get textProvider async {
    final stored = await _readSecret(key: _textProvider);
    if (stored.trim().isNotEmpty) {
      return _normalizeAiProvider(stored);
    }
    return aiProvider;
  }

  static Future<String> get imageProvider async {
    final stored = await _readSecret(key: _imageProvider);
    if (stored.trim().isNotEmpty) {
      return _normalizeAiProvider(stored);
    }
    return aiProvider;
  }

  static Future<String> get ttsProvider async {
    final stored = await _readSecret(key: _ttsProvider);
    if (stored.trim().isNotEmpty) {
      return _normalizeTtsProvider(stored);
    }
    return _normalizeTtsProvider(await aiProvider);
  }

  static Future<String> get volcSpeechApiKey async =>
      _readSecret(key: _volcSpeechApiKey);

  static Future<String> get volcTtsApiKey async => await volcSpeechApiKey;

  static Future<String> get volcRealtimeApiKey async => await volcSpeechApiKey;

  static Future<String> get volcBigAsrApiKey async => await volcSpeechApiKey;

  static Future<String> get volcArkTextApiKey async =>
      _stripBearerPrefix(await _readSecret(key: _volcArkApiKey));

  static Future<String> get volcArkBaseUrl async => _fixedEndpoint(
        key: _volcArkBaseUrl,
        defaultValue: defaultVolcArkBaseUrl,
      );

  static Future<String> get volcAsrModel async => _normalizeVolcAsrModel(
        await _readSecret(
          key: _volcAsrModel,
          defaultValue: defaultVolcAsrModel,
        ),
      );

  static Future<String> get volcArkTextModel async {
    final stored = await _readSecret(key: _volcArkTextModel);
    return stored.isNotEmpty ? stored : defaultVolcArkTextModel;
  }

  static Future<String> get volcArkImageApiKey async =>
      _stripBearerPrefix(await _readSecret(key: _volcArkApiKey));

  static Future<String> get volcArkImageModel async {
    final stored = await _readSecret(key: _volcArkImageModel);
    return stored.isNotEmpty ? stored : defaultVolcArkImageModel;
  }

  static Future<String> get elevenLabsApiKey async =>
      _stripBearerPrefix(await _readSecret(key: _elevenLabsApiKey));

  static Future<String> get elevenLabsBaseUrl async => _fixedEndpoint(
        key: _elevenLabsBaseUrl,
        defaultValue: defaultElevenLabsBaseUrl,
      );

  static Future<String> get elevenLabsTtsModel async {
    final stored = await _readSecret(key: _elevenLabsTtsModel);
    return stored.isNotEmpty ? stored : defaultElevenLabsTtsModel;
  }

  static Future<String> get elevenLabsTtsVoiceId async {
    final stored = await _readSecret(key: _elevenLabsTtsVoiceId);
    return stored.isNotEmpty ? stored : defaultElevenLabsTtsVoiceId;
  }

  static Future<String> get elevenLabsTtsOutputFormat async {
    final stored = await _readSecret(key: _elevenLabsTtsOutputFormat);
    return stored.isNotEmpty ? stored : defaultElevenLabsTtsOutputFormat;
  }

  static Future<String> get elevenLabsMusicModel async {
    final stored = await _readSecret(key: _elevenLabsMusicModel);
    return stored.isNotEmpty ? stored : defaultElevenLabsMusicModel;
  }

  static Future<String> get elevenLabsMusicOutputFormat async {
    final stored = await _readSecret(key: _elevenLabsMusicOutputFormat);
    return stored.isNotEmpty ? stored : defaultElevenLabsMusicOutputFormat;
  }

  static Future<String> get volcArkImageEndpoint async =>
      '${await volcArkBaseUrl}/images/generations';

  static Future<String> get aliyunBailianApiKey async =>
      _stripBearerPrefix(await _readSecret(key: _aliyunBailianApiKey));

  static Future<String> get aliyunBailianBaseUrl async => _fixedEndpoint(
        key: _aliyunBailianBaseUrl,
        defaultValue: defaultAliyunBailianBaseUrl,
      );

  static Future<String> get aliyunBailianApiBaseUrl async => _fixedEndpoint(
        key: _aliyunBailianApiBaseUrl,
        defaultValue: defaultAliyunBailianApiBaseUrl,
      );

  static Future<String> get aliyunBailianTextModel async {
    final stored = await _readSecret(key: _aliyunBailianTextModel);
    return stored.isNotEmpty ? stored : defaultAliyunBailianTextModel;
  }

  static Future<String> get aliyunBailianMusicModel async {
    final stored = await _readSecret(key: _aliyunBailianMusicModel);
    return stored.isNotEmpty ? stored : defaultAliyunBailianMusicModel;
  }

  static Future<String> get aliyunBailianImageModel async {
    final stored = await _readSecret(key: _aliyunBailianImageModel);
    return stored.isNotEmpty ? stored : defaultAliyunBailianImageModel;
  }

  static Future<String> get aliyunBailianImageSize async {
    final stored = await _readSecret(key: _aliyunBailianImageSize);
    return stored.isNotEmpty ? stored : defaultAliyunBailianImageSize;
  }

  static Future<String> get aliyunBailianTtsModel async {
    final stored = await _readSecret(key: _aliyunBailianTtsModel);
    return stored.isNotEmpty ? stored : defaultAliyunBailianTtsModel;
  }

  static Future<String> get aliyunBailianTtsVoice async {
    final stored = await _readSecret(key: _aliyunBailianTtsVoice);
    return stored.isNotEmpty ? stored : defaultAliyunBailianTtsVoice;
  }

  static Future<int> get aliyunBailianTtsSampleRate async {
    final stored = await _readSecret(
      key: _aliyunBailianTtsSampleRate,
      defaultValue: defaultAliyunBailianTtsSampleRate,
    );
    return int.tryParse(stored.trim()) ??
        int.parse(defaultAliyunBailianTtsSampleRate);
  }

  static Future<String> get aliyunBailianAsrModel async {
    final stored = await _readSecret(key: _aliyunBailianAsrModel);
    return _normalizeAliyunAsrModel(stored);
  }

  static Future<String> get aliyunBailianRealtimeAsrModel async {
    final stored = await _readSecret(key: _aliyunBailianRealtimeAsrModel);
    return _normalizeAliyunRealtimeAsrModel(stored);
  }

  static Future<String> get aliyunBailianRealtimeAsrUrl async => _fixedEndpoint(
        key: _aliyunBailianRealtimeAsrUrl,
        defaultValue: defaultAliyunBailianRealtimeAsrUrl,
      );

  static Future<String> get aliyunWanxImageGenerationEndpoint async =>
      '${await aliyunBailianApiBaseUrl}/services/aigc/image-generation/generation';

  static Future<String> aliyunTaskEndpoint(String taskId) async =>
      '${await aliyunBailianApiBaseUrl}/tasks/$taskId';

  static Future<String> get aliyunCosyVoiceEndpoint async =>
      '${await aliyunBailianApiBaseUrl}/services/audio/tts/SpeechSynthesizer';

  static Future<String> get aliyunRealtimeAsrEndpoint async {
    final base = await aliyunBailianRealtimeAsrUrl;
    final model = Uri.encodeQueryComponent(await aliyunBailianRealtimeAsrModel);
    return '$base?model=$model';
  }

  static Future<String> get songGenerationProvider async =>
      _normalizeSongProvider(
        await _readSecret(
          key: _songProvider,
          defaultValue: defaultSongProvider,
        ),
      );

  static Future<OpenAiTextConfig> get openAiTextConfig async {
    final provider = await textProvider;
    if (provider == aiProviderVolcengine) {
      return OpenAiTextConfig(
        provider: aiProviderVolcengine,
        apiKey: await volcArkTextApiKey,
        baseUrl: await volcArkBaseUrl,
        model: await volcArkTextModel,
      );
    }
    return OpenAiTextConfig(
      provider: aiProviderAliyunBailian,
      apiKey: await aliyunBailianApiKey,
      baseUrl: await aliyunBailianBaseUrl,
      model: await aliyunBailianTextModel,
    );
  }

  static String _stripBearerPrefix(String value) {
    return value
        .trim()
        .replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '')
        .trim();
  }

  static Future<void> seedSecureStorageFromEnvironment() async {
    try {
      await _migrateAsrSettings();
      await _clearLegacyEndpointOverrides();
      await _writeIfProvided(
          key: _volcTtsResourceId, value: _envVolcTtsResourceId);
      await _writeIfProvided(
          key: _volcTtsSpeakerId, value: _envVolcTtsSpeakerId);
      await _seedElevenLabsKeyFromFile();
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
        'subtitleMode': await _readSecret(
          key: _recordingSubtitleMode,
          defaultValue: 'srt',
        ),
      };

  static Future<void> saveRecordingSettings({
    required String codec,
    required String resolution,
    required String pageTransition,
    required String subtitleMode,
  }) async {
    await _storage.write(key: _recordingCodec, value: codec.trim());
    await _storage.write(key: _recordingResolution, value: resolution.trim());
    await _storage.write(
      key: _recordingPageTransition,
      value: pageTransition.trim(),
    );
    await _storage.write(
      key: _recordingSubtitleMode,
      value: subtitleMode.trim(),
    );
    _runtimeSecrets[_recordingCodec] = codec.trim();
    _runtimeSecrets[_recordingResolution] = resolution.trim();
    _runtimeSecrets[_recordingPageTransition] = pageTransition.trim();
    _runtimeSecrets[_recordingSubtitleMode] = subtitleMode.trim();
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
        'songProvider': await songGenerationProvider,
      };

  static Future<void> saveSongSettings({
    required String sunoOutputDirectory,
    required int sunoTimeoutMinutes,
    String? songProvider,
  }) async {
    final timeout = sunoTimeoutMinutes.clamp(5, 120).toString();
    final provider = songProvider == null
        ? await songGenerationProvider
        : _normalizeSongProvider(songProvider);
    await _storage.write(
      key: _sunoOutputDirectory,
      value: sunoOutputDirectory.trim(),
    );
    await _storage.write(key: _sunoTimeoutMinutes, value: timeout);
    await _storage.write(key: _songProvider, value: provider);
    _runtimeSecrets[_sunoOutputDirectory] = sunoOutputDirectory.trim();
    _runtimeSecrets[_sunoTimeoutMinutes] = timeout;
    _runtimeSecrets[_songProvider] = provider;
  }

  static Future<void> saveVolcBigAsr({
    required String apiKey,
  }) async {
    await _writeIfProvided(key: _volcSpeechApiKey, value: apiKey);
  }

  static Future<void> saveCloudSettings({
    String? aiProvider,
    String? asrProvider,
    String? textProvider,
    String? imageProvider,
    String? ttsProvider,
    String? aliyunBailianApiKey,
    bool clearAliyunBailianApiKey = false,
    String? aliyunBailianTextModel,
    String? aliyunBailianMusicModel,
    String? aliyunBailianImageModel,
    String? aliyunBailianImageSize,
    String? aliyunBailianTtsModel,
    String? aliyunBailianTtsVoice,
    String? aliyunBailianTtsSampleRate,
    String? aliyunBailianAsrModel,
    String? aliyunBailianRealtimeAsrModel,
    String? volcArkApiKey,
    bool clearVolcArkApiKey = false,
    String? volcAsrModel,
    String? volcArkTextModel,
    String? volcArkImageModel,
    String? elevenLabsApiKey,
    bool clearElevenLabsApiKey = false,
    String? elevenLabsTtsModel,
    String? elevenLabsTtsVoiceId,
    String? elevenLabsTtsOutputFormat,
    String? elevenLabsMusicModel,
    String? elevenLabsMusicOutputFormat,
    String? volcSpeechApiKey,
    bool clearVolcSpeechApiKey = false,
    String? volcTtsResourceId,
    String? volcTtsSpeakerId,
  }) async {
    final requestedAsrProvider = asrProvider ?? aiProvider;
    if (requestedAsrProvider != null) {
      final provider = _normalizeAiProvider(requestedAsrProvider);
      await _storage.write(key: _asrProvider, value: provider);
      _runtimeSecrets[_asrProvider] = provider;
      await _storage.write(key: _aiProvider, value: provider);
      _runtimeSecrets[_aiProvider] = provider;
    }
    if (textProvider != null) {
      final provider = _normalizeAiProvider(textProvider);
      await _storage.write(key: _textProvider, value: provider);
      _runtimeSecrets[_textProvider] = provider;
    }
    if (imageProvider != null) {
      final provider = _normalizeAiProvider(imageProvider);
      await _storage.write(key: _imageProvider, value: provider);
      _runtimeSecrets[_imageProvider] = provider;
    }
    if (ttsProvider != null) {
      final provider = _normalizeTtsProvider(ttsProvider);
      await _storage.write(key: _ttsProvider, value: provider);
      _runtimeSecrets[_ttsProvider] = provider;
    }
    if (clearAliyunBailianApiKey) {
      await _deleteSecret(_aliyunBailianApiKey);
    } else if (aliyunBailianApiKey != null) {
      await _writeIfProvided(
        key: _aliyunBailianApiKey,
        value: _stripBearerPrefix(aliyunBailianApiKey),
      );
    }
    if (clearVolcArkApiKey) {
      await _deleteSecret(_volcArkApiKey);
    } else if (volcArkApiKey != null) {
      await _writeIfProvided(
        key: _volcArkApiKey,
        value: _stripBearerPrefix(volcArkApiKey),
      );
    }
    if (clearVolcSpeechApiKey) {
      await _deleteSecret(_volcSpeechApiKey);
    } else if (volcSpeechApiKey != null) {
      await _writeIfProvided(key: _volcSpeechApiKey, value: volcSpeechApiKey);
    }
    if (clearElevenLabsApiKey) {
      await _deleteSecret(_elevenLabsApiKey);
    } else if (elevenLabsApiKey != null) {
      await _writeIfProvided(
        key: _elevenLabsApiKey,
        value: _stripBearerPrefix(elevenLabsApiKey),
      );
    }
    await _writeConfigValue(
      key: _aliyunBailianTextModel,
      value: aliyunBailianTextModel,
      defaultValue: defaultAliyunBailianTextModel,
    );
    await _writeConfigValue(
      key: _aliyunBailianMusicModel,
      value: aliyunBailianMusicModel,
      defaultValue: defaultAliyunBailianMusicModel,
    );
    await _writeConfigValue(
      key: _aliyunBailianImageModel,
      value: aliyunBailianImageModel,
      defaultValue: defaultAliyunBailianImageModel,
    );
    await _writeConfigValue(
      key: _aliyunBailianImageSize,
      value: aliyunBailianImageSize,
      defaultValue: defaultAliyunBailianImageSize,
    );
    await _writeConfigValue(
      key: _aliyunBailianTtsModel,
      value: aliyunBailianTtsModel,
      defaultValue: defaultAliyunBailianTtsModel,
    );
    await _writeConfigValue(
      key: _aliyunBailianTtsVoice,
      value: aliyunBailianTtsVoice,
      defaultValue: defaultAliyunBailianTtsVoice,
    );
    await _writeConfigValue(
      key: _aliyunBailianTtsSampleRate,
      value: aliyunBailianTtsSampleRate,
      defaultValue: defaultAliyunBailianTtsSampleRate,
    );
    await _writeConfigValue(
      key: _aliyunBailianAsrModel,
      value: aliyunBailianAsrModel == null
          ? null
          : _normalizeAliyunAsrModel(aliyunBailianAsrModel),
      defaultValue: defaultAliyunBailianAsrModel,
    );
    await _writeConfigValue(
      key: _aliyunBailianRealtimeAsrModel,
      value: aliyunBailianRealtimeAsrModel == null
          ? null
          : _normalizeAliyunRealtimeAsrModel(
              aliyunBailianRealtimeAsrModel,
            ),
      defaultValue: defaultAliyunBailianRealtimeAsrModel,
    );
    await _writeConfigValue(
      key: _volcAsrModel,
      value: volcAsrModel == null ? null : _normalizeVolcAsrModel(volcAsrModel),
      defaultValue: defaultVolcAsrModel,
    );
    await _writeConfigValue(
      key: _volcArkTextModel,
      value: volcArkTextModel,
      defaultValue: defaultVolcArkTextModel,
    );
    await _writeConfigValue(
      key: _volcArkImageModel,
      value: volcArkImageModel,
      defaultValue: defaultVolcArkImageModel,
    );
    await _writeConfigValue(
      key: _elevenLabsTtsModel,
      value: elevenLabsTtsModel,
      defaultValue: defaultElevenLabsTtsModel,
    );
    await _writeConfigValue(
      key: _elevenLabsTtsVoiceId,
      value: elevenLabsTtsVoiceId,
      defaultValue: defaultElevenLabsTtsVoiceId,
    );
    await _writeConfigValue(
      key: _elevenLabsTtsOutputFormat,
      value: elevenLabsTtsOutputFormat,
      defaultValue: defaultElevenLabsTtsOutputFormat,
    );
    await _writeConfigValue(
      key: _elevenLabsMusicModel,
      value: elevenLabsMusicModel,
      defaultValue: defaultElevenLabsMusicModel,
    );
    await _writeConfigValue(
      key: _elevenLabsMusicOutputFormat,
      value: elevenLabsMusicOutputFormat,
      defaultValue: defaultElevenLabsMusicOutputFormat,
    );
    await _writeConfigValue(
      key: _volcTtsResourceId,
      value: volcTtsResourceId,
      defaultValue: 'seed-tts-2.0',
    );
    await _writeConfigValue(
      key: _volcTtsSpeakerId,
      value: volcTtsSpeakerId,
      defaultValue: '',
    );
  }

  static Future<Map<String, dynamic>> cloudSettingsPayload() async {
    final aliyunKey = await aliyunBailianApiKey;
    final volcArkKey = await volcArkTextApiKey;
    final volcSpeechKey = await volcSpeechApiKey;
    final elevenLabsKey = await elevenLabsApiKey;
    return {
      'aiProvider': await aiProvider,
      'asrProvider': await asrProvider,
      'textProvider': await textProvider,
      'imageProvider': await imageProvider,
      'ttsProvider': await ttsProvider,
      'aliyunBailian': {
        'apiKeyConfigured': aliyunKey.isNotEmpty,
        'apiKeyMask': maskSecret(aliyunKey),
        'textModel': await aliyunBailianTextModel,
        'musicModel': await aliyunBailianMusicModel,
        'imageModel': await aliyunBailianImageModel,
        'imageSize': await aliyunBailianImageSize,
        'ttsModel': await aliyunBailianTtsModel,
        'ttsVoice': await aliyunBailianTtsVoice,
        'ttsSampleRate': await aliyunBailianTtsSampleRate,
        'asrModel': await aliyunBailianAsrModel,
        'realtimeAsrModel': await aliyunBailianRealtimeAsrModel,
      },
      'volcengine': {
        'arkApiKeyConfigured': volcArkKey.isNotEmpty,
        'arkApiKeyMask': maskSecret(volcArkKey),
        'arkTextModel': await volcArkTextModel,
        'arkImageModel': await volcArkImageModel,
        'asrModel': await volcAsrModel,
        'speechApiKeyConfigured': volcSpeechKey.isNotEmpty,
        'speechApiKeyMask': maskSecret(volcSpeechKey),
        'ttsResourceId': await volcTtsResourceId,
        'ttsSpeakerId': await volcTtsSpeakerId,
      },
      'elevenLabs': {
        'apiKeyConfigured': elevenLabsKey.isNotEmpty,
        'apiKeyMask': maskSecret(elevenLabsKey),
        'ttsModel': await elevenLabsTtsModel,
        'ttsVoiceId': await elevenLabsTtsVoiceId,
        'ttsOutputFormat': await elevenLabsTtsOutputFormat,
        'musicModel': await elevenLabsMusicModel,
        'musicOutputFormat': await elevenLabsMusicOutputFormat,
      },
    };
  }

  static String maskSecret(String value) {
    final trimmed = _stripBearerPrefix(value);
    if (trimmed.isEmpty) {
      return '';
    }
    if (trimmed.length <= 4) {
      return '****';
    }
    return '****${trimmed.substring(trimmed.length - 4)}';
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
    _runtimeSecrets[key] = trimmedValue;
  }

  static Future<void> _writeConfigValue({
    required String key,
    required String? value,
    required String defaultValue,
  }) async {
    if (value == null) {
      return;
    }
    final trimmedValue = value.trim();
    if (trimmedValue.isEmpty || trimmedValue == defaultValue) {
      await _deleteSecret(key);
      return;
    }
    await _storage.write(key: key, value: trimmedValue);
    _runtimeSecrets[key] = trimmedValue;
  }

  static Future<void> _deleteSecret(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      final message = e.toString().split('\n').first;
      debugPrint('[AppConfig] secure storage delete failed for $key: $message');
    }
    _runtimeSecrets.remove(key);
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

  static String _normalizeAiProvider(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized == aiProviderVolcengine
        ? aiProviderVolcengine
        : aiProviderAliyunBailian;
  }

  static String _normalizeTtsProvider(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == aiProviderElevenLabs) {
      return aiProviderElevenLabs;
    }
    return _normalizeAiProvider(normalized);
  }

  static String _normalizeVolcAsrModel(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == volcAsrModelSeedAsrV2) {
      return volcAsrModelSeedAsrV2;
    }
    if (normalized == volcAsrModelBigAsrV1) {
      return volcAsrModelBigAsrV1;
    }
    return volcAsrModelAuto;
  }

  static String _normalizeAliyunAsrModel(String value) {
    const supported = {
      'qwen3-asr-flash',
      'qwen3-asr-flash-2026-02-10',
      'qwen3-asr-flash-2025-09-08',
    };
    final normalized = value.trim().toLowerCase();
    return supported.contains(normalized)
        ? normalized
        : defaultAliyunBailianAsrModel;
  }

  static String _normalizeAliyunRealtimeAsrModel(String value) {
    const supported = {
      'qwen3-asr-flash-realtime',
      'qwen3-asr-flash-realtime-2026-02-10',
      'qwen3-asr-flash-realtime-2025-10-27',
    };
    final normalized = value.trim().toLowerCase();
    if (normalized == 'qwen3-asr-realtime') {
      return defaultAliyunBailianRealtimeAsrModel;
    }
    return supported.contains(normalized)
        ? normalized
        : defaultAliyunBailianRealtimeAsrModel;
  }

  static String _normalizeSongProvider(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == songProviderBailianFunMusic) {
      return songProviderBailianFunMusic;
    }
    if (normalized == songProviderElevenLabsMusic) {
      return songProviderElevenLabsMusic;
    }
    return songProviderSuno;
  }

  static String _normalizeBaseUrl(String value, String fallback) {
    final normalized = _trimTrailingSlash(value);
    return normalized.isEmpty ? fallback : normalized;
  }

  static String _trimTrailingSlash(String value) =>
      value.trim().replaceFirst(RegExp(r'/+$'), '');

  static Future<String> _fixedEndpoint({
    required String key,
    required String defaultValue,
  }) async {
    final testOverride = _runtimeSecrets[key]?.trim() ?? '';
    return _normalizeBaseUrl(testOverride, defaultValue);
  }

  static Future<void> _migrateAsrSettings() async {
    final storedAsrProvider = await _readStorageSecret(key: _asrProvider);
    final legacyProvider = await _readStorageSecret(key: _aiProvider);
    if (storedAsrProvider.isEmpty) {
      if (legacyProvider.isNotEmpty) {
        await _storage.write(
          key: _asrProvider,
          value: _normalizeAiProvider(legacyProvider),
        );
      }
    }

    if (legacyProvider.isNotEmpty) {
      final legacyAiProvider = _normalizeAiProvider(legacyProvider);
      for (final key in const [
        _textProvider,
        _imageProvider,
        _ttsProvider,
      ]) {
        if ((await _readStorageSecret(key: key)).isEmpty) {
          await _storage.write(key: key, value: legacyAiProvider);
        }
      }
    }

    final legacyRealtimeModel =
        await _readStorageSecret(key: _aliyunBailianRealtimeAsrModel);
    if (legacyRealtimeModel.toLowerCase() == 'qwen3-asr-realtime') {
      await _storage.write(
        key: _aliyunBailianRealtimeAsrModel,
        value: defaultAliyunBailianRealtimeAsrModel,
      );
    }
  }

  static Future<void> _clearLegacyEndpointOverrides() async {
    const endpointKeys = {
      _aliyunBailianBaseUrl,
      _aliyunBailianApiBaseUrl,
      _aliyunBailianRealtimeAsrUrl,
      _volcArkBaseUrl,
      _elevenLabsBaseUrl,
    };
    for (final key in endpointKeys) {
      try {
        await _storage.delete(key: key);
      } catch (e) {
        final message = e.toString().split('\n').first;
        debugPrint(
          '[AppConfig] legacy endpoint cleanup failed for $key: $message',
        );
      }
    }
  }

  static Future<void> _seedElevenLabsKeyFromFile() async {
    final apiKey = await _readElevenLabsKeyFile();
    if (apiKey.isEmpty) {
      return;
    }
    _runtimeSecrets[_elevenLabsApiKey] = apiKey;
    try {
      await _storage.write(key: _elevenLabsApiKey, value: apiKey);
    } catch (e) {
      final message = e.toString().split('\n').first;
      debugPrint(
          '[AppConfig] secure storage write failed for elevenlabs: $message');
    }
  }

  static Future<String> _readElevenLabsKeyFile() async {
    final paths = <String>{};
    void addAncestorSecurityPaths(String startPath) {
      var directory = Directory(startPath).absolute;
      for (var depth = 0; depth < 8; depth += 1) {
        paths.add(_joinPath(directory.path, 'security/elevenlabs.txt'));
        final parent = directory.parent.absolute;
        if (parent.path == directory.path) {
          break;
        }
        directory = parent;
      }
    }

    addAncestorSecurityPaths(Directory.current.path);
    addAncestorSecurityPaths(File(Platform.resolvedExecutable).parent.path);
    for (final path in paths) {
      try {
        final file = File(path);
        if (!await file.exists()) {
          continue;
        }
        final value = _parseElevenLabsKeyFile(await file.readAsString());
        if (value.isNotEmpty) {
          return value;
        }
      } catch (e) {
        final message = e.toString().split('\n').first;
        debugPrint('[AppConfig] elevenlabs key file read failed: $message');
      }
    }
    return '';
  }

  static String _parseElevenLabsKeyFile(String raw) {
    for (final line in raw.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        continue;
      }
      final match = RegExp(
        r'^(?:ELEVENLABS_API_KEY|XI_API_KEY)\s*=\s*(.+)$',
        caseSensitive: false,
      ).firstMatch(trimmed);
      final value = match?.group(1)?.trim() ?? trimmed;
      return _stripBearerPrefix(value).replaceAll('"', '').replaceAll("'", '');
    }
    return '';
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

  @visibleForTesting
  static void resetRuntimeConfigForTest() {
    _runtimeSecrets.clear();
  }

  @visibleForTesting
  static void setRuntimeConfigForTest({
    String? aiProvider,
    String? asrProvider,
    String? textProvider,
    String? imageProvider,
    String? ttsProvider,
    String? aliyunBailianApiKey,
    String? aliyunBailianBaseUrl,
    String? aliyunBailianApiBaseUrl,
    String? aliyunBailianTextModel,
    String? aliyunBailianMusicModel,
    String? aliyunBailianImageModel,
    String? aliyunBailianImageSize,
    String? aliyunBailianTtsModel,
    String? aliyunBailianTtsVoice,
    String? aliyunBailianTtsSampleRate,
    String? aliyunBailianAsrModel,
    String? aliyunBailianRealtimeAsrModel,
    String? aliyunBailianRealtimeAsrUrl,
    String? volcSpeechApiKey,
    String? volcAsrModel,
    String? volcArkApiKey,
    String? volcArkBaseUrl,
    String? volcArkTextModel,
    String? volcArkImageModel,
    String? volcTtsResourceId,
    String? volcTtsSpeakerId,
    String? elevenLabsApiKey,
    String? elevenLabsBaseUrl,
    String? elevenLabsTtsModel,
    String? elevenLabsTtsVoiceId,
    String? elevenLabsTtsOutputFormat,
    String? elevenLabsMusicModel,
    String? elevenLabsMusicOutputFormat,
    String? songProvider,
    String? sunoOutputDirectory,
    String? sunoTimeoutMinutes,
  }) {
    void put(String key, String? value) {
      if (value == null) {
        return;
      }
      final trimmedValue = value.trim();
      if (trimmedValue.isEmpty) {
        _runtimeSecrets.remove(key);
      } else {
        _runtimeSecrets[key] = trimmedValue;
      }
    }

    put(_aiProvider, aiProvider);
    put(_asrProvider, asrProvider);
    put(_textProvider, textProvider);
    put(_imageProvider, imageProvider);
    put(_ttsProvider, ttsProvider);
    put(_aliyunBailianApiKey, aliyunBailianApiKey);
    put(_aliyunBailianBaseUrl, aliyunBailianBaseUrl);
    put(_aliyunBailianApiBaseUrl, aliyunBailianApiBaseUrl);
    put(_aliyunBailianTextModel, aliyunBailianTextModel);
    put(_aliyunBailianMusicModel, aliyunBailianMusicModel);
    put(_aliyunBailianImageModel, aliyunBailianImageModel);
    put(_aliyunBailianImageSize, aliyunBailianImageSize);
    put(_aliyunBailianTtsModel, aliyunBailianTtsModel);
    put(_aliyunBailianTtsVoice, aliyunBailianTtsVoice);
    put(_aliyunBailianTtsSampleRate, aliyunBailianTtsSampleRate);
    put(_aliyunBailianAsrModel, aliyunBailianAsrModel);
    put(_aliyunBailianRealtimeAsrModel, aliyunBailianRealtimeAsrModel);
    put(_aliyunBailianRealtimeAsrUrl, aliyunBailianRealtimeAsrUrl);
    put(_volcSpeechApiKey, volcSpeechApiKey);
    put(_volcAsrModel, volcAsrModel);
    put(_volcArkApiKey, volcArkApiKey);
    put(_volcArkBaseUrl, volcArkBaseUrl);
    put(_volcArkTextModel, volcArkTextModel);
    put(_volcArkImageModel, volcArkImageModel);
    put(_volcTtsResourceId, volcTtsResourceId);
    put(_volcTtsSpeakerId, volcTtsSpeakerId);
    put(_elevenLabsApiKey, elevenLabsApiKey);
    put(_elevenLabsBaseUrl, elevenLabsBaseUrl);
    put(_elevenLabsTtsModel, elevenLabsTtsModel);
    put(_elevenLabsTtsVoiceId, elevenLabsTtsVoiceId);
    put(_elevenLabsTtsOutputFormat, elevenLabsTtsOutputFormat);
    put(_elevenLabsMusicModel, elevenLabsMusicModel);
    put(_elevenLabsMusicOutputFormat, elevenLabsMusicOutputFormat);
    put(_songProvider, songProvider);
    put(_sunoOutputDirectory, sunoOutputDirectory);
    put(_sunoTimeoutMinutes, sunoTimeoutMinutes);
  }
}

/// Riverpod provider — 判断是否已配置新版语音 API Key
final configReadyProvider = FutureProvider<bool>((ref) async {
  final provider = await AppConfig.ttsProvider;
  final apiKey = provider == AppConfig.aiProviderElevenLabs
      ? await AppConfig.elevenLabsApiKey
      : provider == AppConfig.aiProviderVolcengine
          ? await AppConfig.volcSpeechApiKey
          : await AppConfig.aliyunBailianApiKey;
  return apiKey.isNotEmpty;
});
