import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as path_lib;

import '../core/logging/tomato_logger.dart';
import '../data/models/article_model.dart';
import '../data/models/article_song_model.dart';
import 'api_cache_service.dart';
import 'database_service.dart';
import 'song_subtitle_timeline_service.dart';

typedef ExternalSongDurationProbe = Future<Duration?> Function(String path);

class ExternalSongImportService {
  ExternalSongImportService._();

  static const source = 'external_audio';
  static const allowedExtensions = <String>[
    'mp3',
    'wav',
    'm4a',
    'aac',
    'ogg',
    'flac',
  ];

  static Future<ArticleSongState?> loadState(
    Article article, {
    bool requireDefault = true,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      return null;
    }
    final versions = await loadVersions(
      article,
      requireDefault: requireDefault,
    );
    if (versions.isEmpty) {
      return null;
    }
    final selected =
        versions.firstWhere((version) => version.isDefault, orElse: () {
      return versions.first;
    });
    return ArticleSongState(
      articleId: articleId,
      status: 'ready',
      stylePrompt: '',
      audioPath: selected.audioPath,
      durationMs: selected.durationMs,
      source: source,
      metadataPath: await metadataPathForArticle(articleId),
      versions: versions,
      downloadComplete: true,
      automationStatus: 'complete',
    );
  }

  static Future<ArticleSongVersion> importFile({
    required Article article,
    required String sourcePath,
    required String lyrics,
    ExternalSongDurationProbe? durationProbe,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      throw const FormatException('章节尚未保存，不能导入本地音乐');
    }
    final trimmedPath = sourcePath.trim();
    if (trimmedPath.isEmpty) {
      throw const FormatException('请选择要导入的音乐文件');
    }
    final extension = _normalizedExtension(trimmedPath);
    if (!allowedExtensions.contains(extension)) {
      throw const FormatException('请选择 mp3、wav、m4a、aac、ogg 或 flac 音频文件');
    }
    final sourceFile = File(trimmedPath);
    if (!await sourceFile.exists()) {
      throw const FormatException('选择的音乐文件不存在');
    }
    final bytes = await sourceFile.readAsBytes();
    if (bytes.isEmpty) {
      throw const FormatException('选择的音乐文件为空');
    }
    final audioHash = await ApiCacheService.hashBytes(bytes);
    final directory = await _articleDirectory(articleId);
    await directory.create(recursive: true);
    final targetPath = path_lib.join(
      directory.path,
      'external_audio_${audioHash.substring(0, 24)}.$extension',
    );
    final existingVersions = await loadVersions(article);
    final existingVersion = _firstVersionWithHash(existingVersions, audioHash);
    final existingPath = (existingVersion?.audioPath ?? '').trim();
    final targetFile =
        File(existingPath.isNotEmpty ? existingPath : targetPath);
    var copiedThisImport = false;
    if (!await targetFile.exists()) {
      await sourceFile.copy(targetFile.path);
      copiedThisImport = true;
    }

    Duration? duration;
    try {
      duration = await (durationProbe ?? _probeDuration)(targetFile.path);
      if (duration == null || duration.inMilliseconds <= 0) {
        throw const FormatException('无法读取导入音频时长，请选择可播放的音乐文件');
      }
    } catch (error) {
      if (copiedThisImport) {
        await _deleteFileIfExists(targetFile.path);
      }
      if (error is FormatException) {
        rethrow;
      }
      throw FormatException('无法播放导入音频：${_displayError(error)}');
    }

    final now = DateTime.now().toIso8601String();
    final lyricsSnapshot = lyrics.trim();
    final lyricsHash = await ApiCacheService.hashUtf8(lyricsSnapshot);
    final versionId = 'external_audio_${audioHash.substring(0, 24)}';
    final existingTimelinePath = (existingVersion?.timelinePath ?? '').trim();
    final existingTimelineStatus =
        await _timelineStatusForPath(existingTimelinePath);
    final previousTimelineMatchesLyrics =
        existingVersion?.lyricsHash == lyricsHash &&
            existingTimelineStatus != 'missing';
    final previousTimelineReady =
        previousTimelineMatchesLyrics && existingTimelineStatus == 'ready';
    final imported = ArticleSongVersion(
      id: versionId,
      audioPath: targetFile.path,
      title: _titleFromPath(trimmedPath),
      durationMs: duration.inMilliseconds,
      createdAt: existingVersion?.createdAt ?? now,
      stylePrompt: null,
      styleKey: audioHash,
      lyricsHash: lyricsHash,
      submittedLyrics: lyricsSnapshot,
      source: source,
      timelinePath: previousTimelineMatchesLyrics ? existingTimelinePath : null,
      timelineStatus:
          previousTimelineMatchesLyrics ? existingTimelineStatus : 'missing',
      timelineConfidence:
          previousTimelineReady ? existingVersion?.timelineConfidence : null,
      timelineError: previousTimelineReady
          ? existingVersion?.timelineError
          : previousTimelineMatchesLyrics
              ? SongSubtitleTimelineService.staleTimelineMessage
              : null,
      isDefault: true,
    );
    final versions = <ArticleSongVersion>[
      imported,
      for (final version in existingVersions)
        if (version.id != imported.id)
          version.copyWith(isDefault: false, source: source),
    ];
    await saveVersions(article: article, versions: versions);
    TomatoLogger.info(
      category: 'music',
      event: 'external_song.imported',
      articleId: articleId,
      data: {
        'hash': audioHash,
        'durationMs': duration.inMilliseconds,
        'deduped': !copiedThisImport,
      },
    );
    return imported;
  }

  static Future<List<ArticleSongVersion>> loadVersions(
    Article article, {
    bool requireDefault = true,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      return const <ArticleSongVersion>[];
    }
    final metadataFile = File(await metadataPathForArticle(articleId));
    if (!await metadataFile.exists()) {
      return const <ArticleSongVersion>[];
    }
    final metadata = _decodeJsonObject(await metadataFile.readAsString());
    final rawVersions = metadata['versions'];
    if (rawVersions is! List) {
      return const <ArticleSongVersion>[];
    }
    var changed = false;
    final versions = <ArticleSongVersion>[];
    for (final rawVersion in rawVersions) {
      final version = ArticleSongVersion.fromJson(rawVersion);
      if (version == null) {
        changed = true;
        continue;
      }
      final audioPath = version.audioPath.trim();
      if (audioPath.isEmpty || !await File(audioPath).exists()) {
        changed = true;
        continue;
      }
      final timelinePath = (version.timelinePath ?? '').trim();
      final timelineStatus = await _timelineStatusForPath(timelinePath);
      final hasTimeline = timelineStatus != 'missing';
      final timelineReady = timelineStatus == 'ready';
      if (timelinePath.isNotEmpty && !hasTimeline) {
        changed = true;
      }
      if (hasTimeline && timelineStatus != _versionTimelineStatus(version)) {
        changed = true;
      }
      if (timelineStatus == 'stale' &&
          version.timelineError !=
              SongSubtitleTimelineService.staleTimelineMessage) {
        changed = true;
      }
      versions.add(
        version.copyWith(
          source: source,
          timelinePath: hasTimeline ? timelinePath : null,
          timelineStatus: timelineStatus,
          timelineConfidence: timelineReady ? version.timelineConfidence : null,
          timelineError: timelineReady
              ? version.timelineError
              : timelineStatus == 'stale'
                  ? SongSubtitleTimelineService.staleTimelineMessage
                  : null,
        ),
      );
    }
    final normalized = _ensureSingleDefault(
      versions,
      requireDefault: requireDefault,
    );
    changed = changed || !_sameVersionDefaults(versions, normalized);
    if (changed) {
      await saveVersions(
        article: article,
        versions: normalized,
        requireDefault: requireDefault,
      );
    }
    return normalized;
  }

  static Future<void> saveVersions({
    required Article article,
    required List<ArticleSongVersion> versions,
    bool requireDefault = true,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      return;
    }
    final directory = await _articleDirectory(articleId);
    await directory.create(recursive: true);
    final metadataPath = await metadataPathForArticle(articleId);
    final currentVersions = _ensureSingleDefault(
      versions
          .where((version) => version.audioPath.trim().isNotEmpty)
          .map((version) => version.copyWith(source: source))
          .toList(growable: false),
      requireDefault: requireDefault,
    );
    final selected = currentVersions.isEmpty
        ? null
        : currentVersions.firstWhere(
            (version) => version.isDefault,
            orElse: () => currentVersions.first,
          );
    final metadata = {
      'provider': source,
      'articleId': articleId,
      'articleTitle': article.title,
      'audioPath': selected?.audioPath,
      'durationMs': selected?.durationMs,
      'metadataPath': metadataPath,
      'downloadComplete': currentVersions.isNotEmpty,
      'versions': currentVersions.map((version) => version.toJson()).toList(),
      'updatedAt': DateTime.now().toIso8601String(),
    };
    await File(metadataPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(metadata),
      flush: true,
    );
  }

  static Future<void> deleteVersionAssets(ArticleSongVersion version) async {
    await _deleteFileIfExists(version.audioPath);
    final timelinePath = (version.timelinePath ?? '').trim();
    if (timelinePath.isNotEmpty) {
      await _deleteFileIfExists(timelinePath);
    }
  }

  static Future<void> deleteArticleAssets(int articleId) async {
    final directory = await _articleDirectory(articleId);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  static Future<String> metadataPathForArticle(int articleId) async {
    final directory = await _articleDirectory(articleId);
    return path_lib.join(directory.path, 'external_audio_metadata.json');
  }

  static Future<Directory> _articleDirectory(int articleId) async {
    final root = await DatabaseService.runtimeDataRoot;
    return Directory(
      path_lib.join(root, 'song-assets', source, 'article_$articleId'),
    );
  }

  static Future<Duration?> _probeDuration(String path) async {
    final playerDuration = await _probeDurationWithPlayer(path);
    if (playerDuration != null && playerDuration.inMilliseconds > 0) {
      return playerDuration;
    }
    final ffmpegDuration = await _probeDurationWithFfmpeg(path);
    if (ffmpegDuration != null && ffmpegDuration.inMilliseconds > 0) {
      return ffmpegDuration;
    }
    return playerDuration;
  }

  static Future<Duration?> _probeDurationWithPlayer(String path) async {
    final player = AudioPlayer();
    try {
      return await player.setFilePath(path);
    } catch (error) {
      TomatoLogger.warn(
        category: 'music',
        event: 'external_song.player_duration_probe_failed',
        error: error,
        data: {'path': path},
      );
      return null;
    } finally {
      await player.dispose();
    }
  }

  static Future<Duration?> _probeDurationWithFfmpeg(String path) async {
    final executable = _bundledFfmpegPath();
    if (!await File(executable).exists()) {
      return null;
    }
    try {
      final result = await Process.run(
        executable,
        ['-hide_banner', '-i', path],
      ).timeout(const Duration(seconds: 15));
      final output = '${result.stderr}\n${result.stdout}';
      final duration = _durationFromFfmpegOutput(output);
      if (duration != null && duration.inMilliseconds > 0) {
        TomatoLogger.info(
          category: 'music',
          event: 'external_song.ffmpeg_duration_probe_used',
          data: {
            'path': path,
            'durationMs': duration.inMilliseconds,
          },
        );
      }
      return duration;
    } catch (error) {
      TomatoLogger.warn(
        category: 'music',
        event: 'external_song.ffmpeg_duration_probe_failed',
        error: error,
        data: {'path': path},
      );
      return null;
    }
  }

  static Duration? _durationFromFfmpegOutput(String output) {
    final match = RegExp(
      r'Duration:\s*(\d+):(\d{2}):(\d{2})(?:\.(\d+))?',
    ).firstMatch(output);
    if (match == null) {
      return null;
    }
    final hours = int.tryParse(match.group(1) ?? '');
    final minutes = int.tryParse(match.group(2) ?? '');
    final seconds = int.tryParse(match.group(3) ?? '');
    if (hours == null || minutes == null || seconds == null) {
      return null;
    }
    final fraction = match.group(4) ?? '';
    final millis = fraction.isEmpty
        ? 0
        : int.parse((fraction.padRight(3, '0')).substring(0, 3));
    return Duration(
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      milliseconds: millis,
    );
  }

  static Duration? parseFfmpegDurationForTest(String output) =>
      _durationFromFfmpegOutput(output);

  static String _bundledFfmpegPath() => path_lib.join(
      File(Platform.resolvedExecutable).parent.path, 'ffmpeg.exe');
  static ArticleSongVersion? _firstVersionWithHash(
    List<ArticleSongVersion> versions,
    String hash,
  ) {
    final versionId = 'external_audio_${hash.substring(0, 24)}';
    for (final version in versions) {
      if (version.id == versionId || version.styleKey == hash) {
        return version;
      }
    }
    return null;
  }

  static List<ArticleSongVersion> _ensureSingleDefault(
    List<ArticleSongVersion> versions, {
    bool requireDefault = true,
  }) {
    if (versions.isEmpty) {
      return const <ArticleSongVersion>[];
    }
    var hasDefault = false;
    final normalized = <ArticleSongVersion>[];
    for (final version in versions) {
      if (version.isDefault && !hasDefault) {
        hasDefault = true;
        normalized.add(version);
      } else if (version.isDefault) {
        normalized.add(version.copyWith(isDefault: false));
      } else {
        normalized.add(version);
      }
    }
    if (!hasDefault && requireDefault) {
      normalized[0] = normalized[0].copyWith(isDefault: true);
    }
    return normalized;
  }

  static bool _sameVersionDefaults(
    List<ArticleSongVersion> left,
    List<ArticleSongVersion> right,
  ) {
    if (left.length != right.length) {
      return false;
    }
    for (var i = 0; i < left.length; i += 1) {
      if (left[i].id != right[i].id ||
          left[i].isDefault != right[i].isDefault) {
        return false;
      }
    }
    return true;
  }

  static String _normalizedExtension(String filePath) {
    return path_lib.extension(filePath).replaceFirst('.', '').toLowerCase();
  }

  static String _titleFromPath(String filePath) {
    final title = path_lib.basenameWithoutExtension(filePath).trim();
    return title.isEmpty ? '外部导入音乐' : title;
  }

  static String _versionTimelineStatus(ArticleSongVersion version) {
    final explicit = (version.timelineStatus ?? '').trim();
    if (explicit.isNotEmpty && explicit != 'generating') {
      return explicit;
    }
    return (version.timelinePath ?? '').trim().isNotEmpty ? 'ready' : 'missing';
  }

  static Future<String> _timelineStatusForPath(String timelinePath) async {
    if (timelinePath.isEmpty) {
      return 'missing';
    }
    if (!await File(timelinePath).exists()) {
      return 'missing';
    }
    return await SongSubtitleTimelineService.timelineFileIsCurrent(timelinePath)
        ? 'ready'
        : 'stale';
  }

  static Map<String, dynamic> _decodeJsonObject(String? text) {
    final raw = text?.trim() ?? '';
    if (raw.isEmpty) {
      return const <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (error) {
      TomatoLogger.warn(
        category: 'music',
        event: 'external_song.metadata_decode_failed',
        error: error,
      );
    }
    return const <String, dynamic>{};
  }

  static Future<void> _deleteFileIfExists(String filePath) async {
    final path = filePath.trim();
    if (path.isEmpty) {
      return;
    }
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (error) {
      TomatoLogger.warn(
        category: 'music',
        event: 'external_song.delete_file_failed',
        error: error,
        data: {'path': path},
      );
    }
  }

  static String _displayError(Object error) {
    final text = error.toString().trim();
    return text
        .replaceFirst(RegExp(r'^FormatException:\s*'), '')
        .replaceFirst(RegExp(r'^Exception:\s*'), '')
        .trim();
  }
}
