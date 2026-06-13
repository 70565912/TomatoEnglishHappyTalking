import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/config/app_config.dart';
import '../data/models/article_model.dart';
import 'api_cache_service.dart';
import 'text_generation_service.dart';

typedef MiniMaxMusicPostOverride = Future<Object?> Function({
  required String endpoint,
  required Map<String, String> headers,
  required Map<String, dynamic> body,
});

class MiniMaxMusicException implements Exception {
  const MiniMaxMusicException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

class ArticleSongState {
  const ArticleSongState({
    required this.articleId,
    required this.status,
    this.stylePrompt = '',
    this.audioPath,
    this.errorMessage,
    this.durationMs,
    this.source = '',
    this.songUrl,
    this.metadataPath,
    this.manualActionMessage,
    this.automationStatus,
    this.creditsRemaining,
    this.versions = const [],
  });

  final int articleId;
  final String status;
  final String stylePrompt;
  final String? audioPath;
  final String? errorMessage;
  final int? durationMs;
  final String source;
  final String? songUrl;
  final String? metadataPath;
  final String? manualActionMessage;
  final String? automationStatus;
  final int? creditsRemaining;
  final List<ArticleSongVersion> versions;

  Map<String, dynamic> toJson() => {
        'articleId': articleId,
        'status': status,
        'stylePrompt': stylePrompt,
        'audioPath': audioPath,
        'errorMessage': errorMessage,
        'durationMs': durationMs,
        'source': source,
        if (songUrl != null) 'songUrl': songUrl,
        if (metadataPath != null) 'metadataPath': metadataPath,
        if (manualActionMessage != null)
          'manualActionMessage': manualActionMessage,
        if (automationStatus != null) 'automationStatus': automationStatus,
        if (creditsRemaining != null) 'creditsRemaining': creditsRemaining,
        if (versions.isNotEmpty)
          'versions': versions.map((version) => version.toJson()).toList(),
      };

  ArticleSongState copyWith({
    String? status,
    String? stylePrompt,
    String? audioPath,
    String? errorMessage,
    int? durationMs,
    String? source,
    String? songUrl,
    String? metadataPath,
    String? manualActionMessage,
    String? automationStatus,
    int? creditsRemaining,
    List<ArticleSongVersion>? versions,
  }) =>
      ArticleSongState(
        articleId: articleId,
        status: status ?? this.status,
        stylePrompt: stylePrompt ?? this.stylePrompt,
        audioPath: audioPath ?? this.audioPath,
        errorMessage: errorMessage,
        durationMs: durationMs ?? this.durationMs,
        source: source ?? this.source,
        songUrl: songUrl ?? this.songUrl,
        metadataPath: metadataPath ?? this.metadataPath,
        manualActionMessage: manualActionMessage ?? this.manualActionMessage,
        automationStatus: automationStatus ?? this.automationStatus,
        creditsRemaining: creditsRemaining ?? this.creditsRemaining,
        versions: versions ?? this.versions,
      );
}

class ArticleSongVersion {
  const ArticleSongVersion({
    required this.id,
    required this.audioPath,
    this.title,
    this.songUrl,
    this.durationMs,
    this.createdAt,
  });

  final String id;
  final String audioPath;
  final String? title;
  final String? songUrl;
  final int? durationMs;
  final String? createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'audioPath': audioPath,
        if (title != null) 'title': title,
        if (songUrl != null) 'songUrl': songUrl,
        if (durationMs != null) 'durationMs': durationMs,
        if (createdAt != null) 'createdAt': createdAt,
      };

  static ArticleSongVersion? fromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final id = (value['id'] ?? '').toString().trim();
    final audioPath = (value['audioPath'] ?? '').toString().trim();
    if (id.isEmpty || audioPath.isEmpty) {
      return null;
    }
    return ArticleSongVersion(
      id: id,
      audioPath: audioPath,
      title: _nonEmpty(value['title']),
      songUrl: _nonEmpty(value['songUrl']),
      durationMs: (value['durationMs'] as num?)?.toInt(),
      createdAt: _nonEmpty(value['createdAt']),
    );
  }

  static String? _nonEmpty(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }
}

class ArticleSongGenerationResult {
  const ArticleSongGenerationResult({
    required this.state,
    required this.lyrics,
    required this.lyricsCompressed,
  });

  final ArticleSongState state;
  final String lyrics;
  final bool lyricsCompressed;
}

class MiniMaxMusicService {
  static const endpoint = 'https://api.minimaxi.com/v1/music_generation';
  static const model = 'music-2.6-free';
  static const maxPromptChars = 2000;
  static const maxLyricsChars = 3500;
  static const stylePurpose = 'article_song_style_v1';
  static const lyricsPurpose = 'article_song_lyrics_v1';
  static const audioPurpose = 'article_song_audio_v1';

  static final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(minutes: 5),
    ),
  );

  static MiniMaxMusicPostOverride? _postOverrideForTest;

  @visibleForTesting
  static void setPostOverrideForTest(MiniMaxMusicPostOverride? override) {
    _postOverrideForTest = override;
  }

  static Future<ArticleSongState> stateForArticle(Article article) async {
    final articleId = article.id;
    if (articleId == null) {
      throw const MiniMaxMusicException('文章尚未保存，不能生成歌曲');
    }

    final contentHash = await _articleContentHash(article);
    final audioEntry = await _latestMatchingEntry(
      articleId: articleId,
      purpose: audioPurpose,
      contentHash: contentHash,
    );
    if (audioEntry != null && (audioEntry.filePath ?? '').trim().isNotEmpty) {
      final request = _decodeRequest(audioEntry.requestJson);
      return ArticleSongState(
        articleId: articleId,
        status: 'ready',
        stylePrompt: (request['stylePrompt'] ?? '').toString(),
        audioPath: audioEntry.filePath,
        durationMs: (request['durationMs'] as num?)?.toInt(),
        source: 'minimax',
        versions: [
          ArticleSongVersion(
            id: audioEntry.cacheKey,
            audioPath: audioEntry.filePath!,
            title: 'MiniMax',
            durationMs: (request['durationMs'] as num?)?.toInt(),
          ),
        ],
      );
    }

    final style = await cachedStylePrompt(article);
    return ArticleSongState(
      articleId: articleId,
      status: 'empty',
      stylePrompt: style,
    );
  }

  static Future<String> cachedStylePrompt(Article article) async {
    final articleId = article.id;
    if (articleId == null) {
      return '';
    }
    final request = await _styleCacheRequest(article);
    final cacheKey = await ApiCacheService.keyForJson(
      'article_song_style',
      request,
    );
    return (await ApiCacheService.getText(
          cacheKey,
          articleId: articleId,
          purpose: stylePurpose,
        ))
            ?.trim() ??
        '';
  }

  static Future<String> ensureStylePromptForArticle(Article article) async {
    final articleId = article.id;
    if (articleId == null) {
      throw const MiniMaxMusicException('文章尚未保存，不能生成歌曲风格');
    }

    final existing = await cachedStylePrompt(article);
    if (existing.isNotEmpty) {
      return existing;
    }

    final story = _articleStoryText(article);
    final reply = await TextGenerationService.generateStrict(
      articleId: articleId,
      cachePurpose: stylePurpose,
      maxTokens: 220,
      receiveTimeout: const Duration(seconds: 60),
      turns: [
        const TextGenerationTurn(
          role: 'system',
          content:
              '你是儿童英语绘本歌曲制作人。根据故事内容生成适合 Suno 或 MiniMax 等音乐生成工具的歌曲风格描述，只输出一行逗号分隔的风格、情绪、节奏、乐器和场景关键词，不要解释。',
        ),
        TextGenerationTurn(
          role: 'user',
          content:
              '文章标题：${article.title}\n\n故事内容：\n${_clipForPrompt(story, 5200)}',
        ),
      ],
    );
    final style = _cleanStylePrompt(reply.text);
    if (style.isEmpty) {
      throw const MiniMaxMusicException('歌曲风格生成失败：AI 未返回可用风格描述');
    }

    final request = await _styleCacheRequest(article);
    final cacheKey = await ApiCacheService.keyForJson(
      'article_song_style',
      request,
    );
    await ApiCacheService.putText(
      cacheKey: cacheKey,
      kind: 'minimax_music',
      purpose: stylePurpose,
      request: request,
      textValue: style,
      articleId: articleId,
    );
    return style;
  }

  static Future<ArticleSongGenerationResult> generateSong({
    required Article article,
    required String stylePrompt,
    required bool compressLyricsIfNeeded,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      throw const MiniMaxMusicException('文章尚未保存，不能生成歌曲');
    }
    final cleanedStyle = _cleanStylePrompt(stylePrompt);
    if (cleanedStyle.isEmpty) {
      throw const MiniMaxMusicException('请先填写歌曲风格描述');
    }

    final lyricsResult = await _lyricsForMiniMax(
      article,
      compressIfNeeded: compressLyricsIfNeeded,
    );
    final lyrics = lyricsResult.$1;
    final lyricsCompressed = lyricsResult.$2;
    final contentHash = await _articleContentHash(article);
    final lyricsHash = await ApiCacheService.hashUtf8(lyrics);
    final audioRequest = <String, dynamic>{
      'version': 1,
      'provider': 'minimax',
      'model': model,
      'articleId': articleId,
      'articleTitle': article.title,
      'contentHash': contentHash,
      'lyricsHash': lyricsHash,
      'stylePrompt': cleanedStyle,
      'lyricsCompressed': lyricsCompressed,
      'audio': {
        'sample_rate': 44100,
        'bitrate': 256000,
        'format': 'mp3',
      },
    };
    final audioCacheKey = await ApiCacheService.keyForJson(
      'article_song_audio',
      audioRequest,
    );
    final cachedPath = await ApiCacheService.getFilePath(
      audioCacheKey,
      articleId: articleId,
      purpose: audioPurpose,
    );
    if (cachedPath != null && cachedPath.trim().isNotEmpty) {
      return ArticleSongGenerationResult(
        state: ArticleSongState(
          articleId: articleId,
          status: 'ready',
          stylePrompt: cleanedStyle,
          audioPath: cachedPath,
          source: 'minimax',
          versions: [
            ArticleSongVersion(
              id: audioCacheKey,
              audioPath: cachedPath,
              title: 'MiniMax',
            ),
          ],
        ),
        lyrics: lyrics,
        lyricsCompressed: lyricsCompressed,
      );
    }

    final apiKey = await AppConfig.miniMaxApiKey;
    if (apiKey.trim().isEmpty) {
      throw const MiniMaxMusicException(
        '歌曲生成失败：未读取到 MiniMax API Key，请检查 security\\MiniMax.txt。',
      );
    }

    final body = <String, dynamic>{
      'model': model,
      'prompt': cleanedStyle,
      'lyrics': lyrics,
      'stream': false,
      'output_format': 'hex',
      'audio_setting': {
        'sample_rate': 44100,
        'bitrate': 256000,
        'format': 'mp3',
      },
      'aigc_watermark': false,
      'lyrics_optimizer': false,
      'is_instrumental': false,
    };

    try {
      final response = await _postJson(apiKey: apiKey, body: body);
      final parsed = _decodeResponse(response);
      final extraInfo = parsed['extra_info'];
      final durationMs = extraInfo is Map
          ? (extraInfo['music_duration'] as num?)?.toInt()
          : null;
      final audioBytes = _decodeHexAudio(parsed);
      final requestWithDuration = {
        ...audioRequest,
        if (durationMs != null) 'durationMs': durationMs,
      };
      final filePath = await ApiCacheService.putFileBytes(
        cacheKey: audioCacheKey,
        kind: 'minimax_music',
        purpose: audioPurpose,
        request: requestWithDuration,
        bytes: audioBytes,
        subdirectory: 'music/article_$articleId',
        extension: 'mp3',
        contentType: 'audio/mpeg',
        articleId: articleId,
      );
      await _cacheStylePrompt(article, cleanedStyle);
      return ArticleSongGenerationResult(
        state: ArticleSongState(
          articleId: articleId,
          status: 'ready',
          stylePrompt: cleanedStyle,
          audioPath: filePath,
          durationMs: durationMs,
          source: 'minimax',
          versions: [
            ArticleSongVersion(
              id: audioCacheKey,
              audioPath: filePath,
              title: 'MiniMax',
              durationMs: durationMs,
              createdAt: DateTime.now().toIso8601String(),
            ),
          ],
        ),
        lyrics: lyrics,
        lyricsCompressed: lyricsCompressed,
      );
    } catch (error) {
      if (error is MiniMaxMusicException) {
        rethrow;
      }
      throw MiniMaxMusicException(_userMessage(error), cause: error);
    }
  }

  static Future<(String, bool)> _lyricsForMiniMax(
    Article article, {
    required bool compressIfNeeded,
  }) async {
    final rawLyrics = _articleLyrics(article);
    if (rawLyrics.isEmpty) {
      throw const MiniMaxMusicException('文章没有可用歌词');
    }
    if (rawLyrics.length <= maxLyricsChars) {
      return (rawLyrics, false);
    }
    if (!compressIfNeeded) {
      throw MiniMaxMusicException(
        'MiniMax 歌词最多 $maxLyricsChars 字符，当前文章歌词约 ${rawLyrics.length} 字符。请确认使用 AI 改写压缩后再生成。',
      );
    }
    final compressed = await _compressedLyrics(article, rawLyrics);
    return (compressed, true);
  }

  static Future<String> _compressedLyrics(
    Article article,
    String rawLyrics,
  ) async {
    final articleId = article.id;
    if (articleId == null) {
      throw const MiniMaxMusicException('文章尚未保存，不能压缩歌词');
    }
    final request = await _lyricsCacheRequest(article);
    final cacheKey = await ApiCacheService.keyForJson(
      'article_song_lyrics',
      request,
    );
    final cachedLyrics = await ApiCacheService.getText(
      cacheKey,
      articleId: articleId,
      purpose: lyricsPurpose,
    );
    if (cachedLyrics != null &&
        cachedLyrics.trim().isNotEmpty &&
        cachedLyrics.trim().length <= maxLyricsChars) {
      return cachedLyrics.trim();
    }

    final reply = await TextGenerationService.generateStrict(
      articleId: articleId,
      cachePurpose: lyricsPurpose,
      maxTokens: 1300,
      receiveTimeout: const Duration(seconds: 90),
      turns: [
        const TextGenerationTurn(
          role: 'system',
          content:
              '你是儿童英语故事歌曲改编助手。把完整英文故事压缩改写成适合演唱的英文歌词，必须保留主要剧情顺序和角色，不要加入故事外信息。只输出歌词正文，可以使用 [Verse]、[Chorus]、[Bridge]、[Outro] 标签。',
        ),
        TextGenerationTurn(
          role: 'user',
          content: '请把下面故事改写为 3500 字符以内的英文歌词：\n\n$rawLyrics',
        ),
      ],
    );
    final lyrics = _cleanLyrics(reply.text);
    if (lyrics.isEmpty) {
      throw const MiniMaxMusicException('歌词改写失败：AI 未返回可用歌词');
    }
    if (lyrics.length > maxLyricsChars) {
      throw const MiniMaxMusicException(
        '歌词改写后仍超过 MiniMax $maxLyricsChars 字符上限，请缩短文章后重试。',
      );
    }

    await ApiCacheService.putText(
      cacheKey: cacheKey,
      kind: 'minimax_music',
      purpose: lyricsPurpose,
      request: request,
      textValue: lyrics,
      articleId: articleId,
    );
    return lyrics;
  }

  static Future<void> _cacheStylePrompt(
    Article article,
    String stylePrompt,
  ) async {
    final articleId = article.id;
    if (articleId == null || stylePrompt.trim().isEmpty) {
      return;
    }
    final request = await _styleCacheRequest(article);
    final cacheKey = await ApiCacheService.keyForJson(
      'article_song_style',
      request,
    );
    await ApiCacheService.putText(
      cacheKey: cacheKey,
      kind: 'minimax_music',
      purpose: stylePurpose,
      request: request,
      textValue: _cleanStylePrompt(stylePrompt),
      articleId: articleId,
    );
  }

  static Future<ApiCacheEntry?> _latestMatchingEntry({
    required int articleId,
    required String purpose,
    required String contentHash,
  }) async {
    final entry = await ApiCacheService.getLatestEntryForArticlePurpose(
      articleId: articleId,
      purpose: purpose,
    );
    if (entry == null) {
      return null;
    }
    final request = _decodeRequest(entry.requestJson);
    return request['contentHash'] == contentHash ? entry : null;
  }

  static Future<Map<String, dynamic>> _styleCacheRequest(
      Article article) async {
    return {
      'version': 2,
      'articleId': article.id,
      'articleTitle': article.title,
      'contentHash': await _articleContentHash(article),
      'target': 'article_song_style',
    };
  }

  static Future<Map<String, dynamic>> _lyricsCacheRequest(
      Article article) async {
    return {
      'version': 1,
      'articleId': article.id,
      'articleTitle': article.title,
      'contentHash': await _articleContentHash(article),
      'maxChars': maxLyricsChars,
      'target': 'minimax_music_lyrics',
    };
  }

  static Future<String> _articleContentHash(Article article) =>
      ApiCacheService.hashUtf8(_articleStoryText(article));

  static String _articleStoryText(Article article) {
    final sentences = article.sentences
        .map((sentence) => sentence.trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
    if (sentences.isNotEmpty) {
      return sentences.join('\n');
    }
    return article.content.trim();
  }

  static String _articleLyrics(Article article) =>
      _cleanLyrics(_articleStoryText(article));

  static String _cleanStylePrompt(String text) {
    final normalized = text
        .replaceAll(RegExp(r'^[\s"“”‘’`]+|[\s"“”‘’`]+$'), '')
        .replaceAll(RegExp(r'[\r\n]+'), ', ')
        .replaceAll(RegExp(r'\s*,\s*'), ', ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.length <= maxPromptChars) {
      return normalized;
    }
    return normalized.substring(0, maxPromptChars).trim();
  }

  static String _cleanLyrics(String text) => text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();

  static String _clipForPrompt(String text, int maxChars) {
    final trimmed = text.trim();
    if (trimmed.length <= maxChars) {
      return trimmed;
    }
    return '${trimmed.substring(0, maxChars)}\n...';
  }

  static Map<String, dynamic> _decodeRequest(String requestJson) {
    try {
      final decoded = jsonDecode(requestJson);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {
      // Bad cache metadata should simply make the entry unusable.
    }
    return <String, dynamic>{};
  }

  static Future<Object?> _postJson({
    required String apiKey,
    required Map<String, dynamic> body,
  }) async {
    final headers = <String, String>{
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
    };
    final override = _postOverrideForTest;
    if (override != null) {
      return override(endpoint: endpoint, headers: headers, body: body);
    }

    final response = await _dio.post<dynamic>(
      endpoint,
      data: body,
      options: Options(headers: headers),
    );
    return response.data;
  }

  static Map<String, dynamic> _decodeResponse(Object? response) {
    final root = switch (response) {
      final String text => jsonDecode(text),
      final Map map => map,
      _ => throw const FormatException('MiniMax response is not a JSON object'),
    };
    if (root is! Map) {
      throw const FormatException('MiniMax response is not a JSON object');
    }
    final decoded = root.map((key, value) => MapEntry(key.toString(), value));
    final baseResp = decoded['base_resp'];
    if (baseResp is Map) {
      final code = (baseResp['status_code'] as num?)?.toInt() ?? 0;
      if (code != 0) {
        final message = (baseResp['status_msg'] ?? 'unknown error').toString();
        throw MiniMaxMusicException('MiniMax 歌曲生成失败：$message');
      }
    }
    return decoded;
  }

  static List<int> _decodeHexAudio(Map<String, dynamic> response) {
    final data = response['data'];
    if (data is! Map) {
      throw const FormatException('MiniMax response has no data object');
    }
    final audioHex = (data['audio'] ?? '').toString().trim();
    if (audioHex.isEmpty) {
      throw const FormatException('MiniMax response has no audio data');
    }
    final normalized = audioHex.replaceAll(RegExp(r'\s+'), '');
    if (normalized.length.isOdd) {
      throw const FormatException('MiniMax audio hex length is invalid');
    }
    final bytes = <int>[];
    for (var i = 0; i < normalized.length; i += 2) {
      bytes.add(int.parse(normalized.substring(i, i + 2), radix: 16));
    }
    if (bytes.isEmpty) {
      throw const FormatException('MiniMax audio is empty');
    }
    return bytes;
  }

  static String _userMessage(Object error) {
    if (error is DioException &&
        error.type == DioExceptionType.receiveTimeout) {
      return '歌曲生成超时，请稍后重试。';
    }
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map) {
        final baseResp = data['base_resp'];
        if (baseResp is Map) {
          final message = (baseResp['status_msg'] ?? '').toString().trim();
          if (message.isNotEmpty) {
            return 'MiniMax 歌曲生成失败：$message';
          }
        }
      }
      final message = error.message?.trim();
      if (message != null && message.isNotEmpty) {
        return 'MiniMax 歌曲生成失败：$message';
      }
    }
    final message = error.toString().trim();
    return message.isEmpty ? 'MiniMax 歌曲生成失败，请重试。' : message;
  }
}
