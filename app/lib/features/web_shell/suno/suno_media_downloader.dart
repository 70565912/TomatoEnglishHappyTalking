import 'dart:io';

import 'package:dio/dio.dart';

import '../../../core/logging/tomato_logger.dart';
import '../../../data/models/article_song_model.dart';
import 'suno_automation_host.dart';
import 'suno_automation_state.dart';
import 'suno_utilities.dart';

/// CDN direct download with not-ready (403/404) handling.
class SunoMediaDownloader {
  SunoMediaDownloader({
    required SunoAutomationHost host,
    Dio? dio,
  })  : _host = host,
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 120),
              ),
            );

  final SunoAutomationHost _host;
  final Dio _dio;

  Future<int> downloadDirectMediaUrls({
    required SunoAutomationState state,
    required int articleId,
    required Iterable<String> songUrls,
    required Map<String, String> mediaBySongUrl,
    String? fallbackMediaUrl,
    required Future<void> Function() onSaved,
    required String Function(String songUrl) safeFilename,
    required Future<File> Function(Directory directory, String filename)
        uniqueTargetFile,
  }) async {
    var downloadedCount = 0;
    final directory = Directory(await _host.resolvedSunoOutputDirectory());
    await directory.create(recursive: true);
    final article = await _host.loadSongArticle(articleId);
    final lyricsHash = await _host.articleSongLyricsHash(article);
    final canonicalMediaBySongUrl = <String, String>{};
    for (final entry in mediaBySongUrl.entries) {
      final key = SunoUtilities.canonicalSongUrl(entry.key);
      final value = entry.value.trim();
      if (key != null &&
          key.isNotEmpty &&
          !SunoUtilities.isSyntheticSongKey(key) &&
          value.isNotEmpty) {
        canonicalMediaBySongUrl[key] = value;
      }
    }

    for (final rawSongUrl in songUrls) {
      final songUrl = SunoUtilities.canonicalSongUrl(rawSongUrl) ?? '';
      if (songUrl.isEmpty ||
          state.downloadedSongUrls.contains(songUrl) ||
          state.hasLocalVersionForSongUrl(songUrl)) {
        continue;
      }
      final mediaUrl = (canonicalMediaBySongUrl[songUrl] ??
              SunoUtilities.matchingMediaUrl(
                fallbackMediaUrl ?? '',
                songUrl,
              ) ??
              (fallbackMediaUrl != null &&
                      fallbackMediaUrl.trim().isNotEmpty &&
                      SunoUtilities.matchingMediaUrl(fallbackMediaUrl, songUrl) !=
                          null
                  ? fallbackMediaUrl.trim()
                  : null) ??
              SunoUtilities.canonicalCdnMediaUrl(songUrl))
          .trim();
      if (mediaUrl.isEmpty) {
        TomatoLogger.warn(
          category: 'suno',
          event: 'direct_media.missing',
          articleId: articleId,
          status: state.statusKey,
          data: {'songUrl': songUrl},
        );
        continue;
      }
      final downloadKey = 'direct:$songUrl:$mediaUrl';
      if (state.downloadInFlightKeys.contains(downloadKey) ||
          state.downloadedDownloadKeys.contains(downloadKey)) {
        continue;
      }
      state.downloadInFlightKeys.add(downloadKey);
      try {
        final bytes = await _downloadUrl(mediaUrl);
        if (bytes.length < 64 * 1024) {
          throw FormatException('下载结果过小，疑似不是完整歌曲（${bytes.length} bytes）');
        }
        final extension = SunoUtilities.mediaExtension(mediaUrl);
        final songId = SunoUtilities.songId(songUrl) ??
            DateTime.now().millisecondsSinceEpoch.toString();
        final filename = safeFilename(
          'suno_article_${articleId}_${songId}_v${state.versions.length + 1}$extension',
        );
        final target = await uniqueTargetFile(directory, filename);
        await target.writeAsBytes(bytes, flush: true);
        state.audioPath = target.path;
        state.downloadedSongUrls.add(songUrl);
        state.detectedSongUrls.add(songUrl);
        state.trustedSongUrls.add(songUrl);
        state.downloadedDownloadKeys.add(downloadKey);
        state.createBatch.markDownloaded(songUrl);
        final title = (state.pendingDownloadTitle ?? '').trim();
        final version = ArticleSongVersion(
          id: 'suno_${articleId}_${DateTime.now().millisecondsSinceEpoch}_${state.versions.length + 1}',
          audioPath: target.path,
          title: title.isEmpty ? 'Suno 版本 ${state.versions.length + 1}' : title,
          songUrl: songUrl,
          createdAt: DateTime.now().toIso8601String(),
          stylePrompt:
              state.stylePrompt.trim().isEmpty ? null : state.stylePrompt.trim(),
          lyricsHash: lyricsHash,
        );
        state.versions.removeWhere(
          (item) =>
              item.songUrl != null &&
              version.songUrl != null &&
              SunoUtilities.canonicalSongUrl(item.songUrl) ==
                  SunoUtilities.canonicalSongUrl(version.songUrl),
        );
        state.versions.add(version);
        downloadedCount += 1;
        TomatoLogger.info(
          category: 'suno',
          event: 'direct_media.saved',
          articleId: articleId,
          status: state.statusKey,
          data: {
            'songUrl': songUrl,
            'mediaUrl': mediaUrl,
            'bytes': bytes.length,
            'audioPath': target.path,
          },
        );
      } on DioException catch (error) {
        final status = error.response?.statusCode;
        if (status == 403 || status == 404) {
          TomatoLogger.warn(
            category: 'suno',
            event: 'direct_media.not_ready',
            articleId: articleId,
            status: state.statusKey,
            data: {
              'songUrl': songUrl,
              'mediaUrl': mediaUrl,
              'httpStatus': status,
            },
          );
        } else {
          TomatoLogger.error(
            category: 'suno',
            event: 'direct_media.failed',
            articleId: articleId,
            status: state.statusKey,
            data: {'songUrl': songUrl, 'mediaUrl': mediaUrl},
            error: error,
          );
        }
      } catch (error) {
        TomatoLogger.error(
          category: 'suno',
          event: 'direct_media.failed',
          articleId: articleId,
          status: state.statusKey,
          data: {'songUrl': songUrl, 'mediaUrl': mediaUrl},
          error: error,
        );
      } finally {
        state.downloadInFlightKeys.remove(downloadKey);
      }
    }

    if (downloadedCount > 0) {
      state.pendingDownloadSongUrl = null;
      state.pendingDownloadTitle = null;
      state.menuDownloadClickedAt = null;
      await onSaved();
    }
    return downloadedCount;
  }

  Future<List<int>> _downloadUrl(String mediaUrl) async {
    final response = await _dio.get<List<int>>(
      mediaUrl,
      options: Options(responseType: ResponseType.bytes),
    );
    return response.data ?? const <int>[];
  }
}
