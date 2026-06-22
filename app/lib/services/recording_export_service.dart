import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as path_lib;

import '../core/config/app_config.dart';
import '../data/models/article_model.dart';
import '../data/models/picture_book_model.dart';
import 'database_service.dart';
import 'recording_export_utils.dart';
import 'song_subtitle_timeline_service.dart';
import 'tts_memory_cache_service.dart';
import 'tts_service.dart';

enum RecordingCodec { h264, h265 }

enum RecordingResolution {
  r1440('2560x1440', 2560, 1440),
  r1080('1920x1080', 1920, 1080),
  r720('1280x720', 1280, 720);

  const RecordingResolution(this.id, this.width, this.height);

  final String id;
  final int width;
  final int height;

  static RecordingResolution parse(String value) {
    final normalized = value.trim().toLowerCase();
    return RecordingResolution.values.firstWhere(
      (item) => item.id == normalized,
      orElse: () => RecordingResolution.r1080,
    );
  }
}

enum RecordingPageTransition {
  none,
  crossFade,
  panZoomFade,
  slide,
  pageCurl;

  static RecordingPageTransition parse(String value) {
    final normalized = value.trim();
    return RecordingPageTransition.values.firstWhere(
      (item) => item.name == normalized,
      orElse: () => RecordingPageTransition.none,
    );
  }
}

enum RecordingSubtitleMode {
  srt,
  burnedIn,
  both;

  static RecordingSubtitleMode parse(String value) {
    final normalized = value.trim();
    return RecordingSubtitleMode.values.firstWhere(
      (item) => item.name == normalized,
      orElse: () => RecordingSubtitleMode.srt,
    );
  }

  bool get writesSrt =>
      this == RecordingSubtitleMode.srt || this == RecordingSubtitleMode.both;

  bool get burnsIn =>
      this == RecordingSubtitleMode.burnedIn ||
      this == RecordingSubtitleMode.both;
}

class RecordingExportRequest {
  const RecordingExportRequest({
    required this.articleId,
    required this.mode,
    required this.codec,
    required this.resolution,
    required this.pageTransition,
    this.subtitleMode = RecordingSubtitleMode.srt,
    this.fps = 25,
    this.subtitleTranslations = const <int, String>{},
  });

  final int articleId;
  final String mode;
  final RecordingCodec codec;
  final RecordingResolution resolution;
  final RecordingPageTransition pageTransition;
  final RecordingSubtitleMode subtitleMode;
  final int fps;
  final Map<int, String> subtitleTranslations;

  bool get bilingual => false;
}

class SongRecordingExportRequest {
  const SongRecordingExportRequest({
    required this.articleId,
    required this.audioPath,
    required this.timelinePath,
    required this.codec,
    required this.resolution,
    required this.pageTransition,
    this.subtitleMode = RecordingSubtitleMode.srt,
    this.fps = 25,
  });

  final int articleId;
  final String audioPath;
  final String timelinePath;
  final RecordingCodec codec;
  final RecordingResolution resolution;
  final RecordingPageTransition pageTransition;
  final RecordingSubtitleMode subtitleMode;
  final int fps;
}

class RecordingReadiness {
  const RecordingReadiness({
    required this.ready,
    required this.reasons,
    required this.encoderName,
    required this.codec,
    required this.resolution,
    required this.pageTransition,
    required this.outputDirectory,
    required this.requiredEnglish,
    required this.readyEnglish,
    required this.requiredChinese,
    required this.readyChinese,
    required this.picturePageCount,
  });

  final bool ready;
  final List<String> reasons;
  final String encoderName;
  final RecordingCodec codec;
  final RecordingResolution resolution;
  final RecordingPageTransition pageTransition;
  final String outputDirectory;
  final int requiredEnglish;
  final int readyEnglish;
  final int requiredChinese;
  final int readyChinese;
  final int picturePageCount;

  Map<String, dynamic> toJson() => {
        'ready': ready,
        'reasons': reasons,
        'encoderName': encoderName,
        'codec': codec.name,
        'resolution': resolution.id,
        'pageTransition': pageTransition.name,
        'outputDirectory': outputDirectory,
        'requiredEnglish': requiredEnglish,
        'readyEnglish': readyEnglish,
        'requiredChinese': requiredChinese,
        'readyChinese': readyChinese,
        'picturePageCount': picturePageCount,
      };
}

class RecordingExportProgress {
  const RecordingExportProgress({
    required this.articleId,
    required this.phase,
    required this.progress,
    required this.completedFrames,
    required this.totalFrames,
    this.message = '',
  });

  final int articleId;
  final String phase;
  final double progress;
  final int completedFrames;
  final int totalFrames;
  final String message;

  Map<String, dynamic> toJson() => {
        'articleId': articleId,
        'phase': phase,
        'progress': progress.clamp(0, 1),
        'completedFrames': completedFrames,
        'totalFrames': totalFrames,
        'message': message,
      };
}

class RecordingExportResult {
  const RecordingExportResult({
    required this.articleId,
    required this.videoPath,
    required this.subtitlePath,
    required this.durationMs,
    required this.frameCount,
    required this.droppedFrameCount,
    required this.encoderName,
    required this.codec,
    required this.resolution,
    required this.pageTransition,
    required this.warnings,
  });

  final int articleId;
  final String videoPath;
  final String subtitlePath;
  final int durationMs;
  final int frameCount;
  final int droppedFrameCount;
  final String encoderName;
  final RecordingCodec codec;
  final RecordingResolution resolution;
  final RecordingPageTransition pageTransition;
  final List<String> warnings;

  Map<String, dynamic> toJson() => {
        'articleId': articleId,
        'videoPath': videoPath,
        'subtitlePath': subtitlePath,
        'durationMs': durationMs,
        'frameCount': frameCount,
        'droppedFrameCount': droppedFrameCount,
        'encoderName': encoderName,
        'codec': codec.name,
        'resolution': resolution.id,
        'pageTransition': pageTransition.name,
        'warnings': warnings,
      };
}

class RecordingVideoVersion {
  const RecordingVideoVersion({
    required this.id,
    required this.articleId,
    required this.videoPath,
    required this.subtitlePath,
    required this.createdAt,
    required this.source,
    required this.title,
    required this.isDefault,
    this.durationMs,
    this.frameCount,
    this.droppedFrameCount,
    this.encoderName = '',
    this.codec = '',
    this.resolution = '',
    this.pageTransition = '',
    this.sizeBytes,
  });

  final String id;
  final int articleId;
  final String videoPath;
  final String subtitlePath;
  final String createdAt;
  final String source;
  final String title;
  final bool isDefault;
  final int? durationMs;
  final int? frameCount;
  final int? droppedFrameCount;
  final String encoderName;
  final String codec;
  final String resolution;
  final String pageTransition;
  final int? sizeBytes;

  factory RecordingVideoVersion.fromJson(Map<String, dynamic> json) {
    final videoPath = (json['videoPath'] ?? '').toString();
    return RecordingVideoVersion(
      id: (json['id'] ?? _videoIdForPath(videoPath)).toString(),
      articleId: _jsonInt(json['articleId']) ?? 0,
      videoPath: videoPath,
      subtitlePath: (json['subtitlePath'] ?? '').toString(),
      createdAt: (json['createdAt'] ?? '').toString(),
      source: (json['source'] ?? 'listening').toString(),
      title: (json['title'] ?? '').toString(),
      isDefault: json['isDefault'] == true,
      durationMs: _jsonInt(json['durationMs']),
      frameCount: _jsonInt(json['frameCount']),
      droppedFrameCount: _jsonInt(json['droppedFrameCount']),
      encoderName: (json['encoderName'] ?? '').toString(),
      codec: (json['codec'] ?? '').toString(),
      resolution: (json['resolution'] ?? '').toString(),
      pageTransition: (json['pageTransition'] ?? '').toString(),
      sizeBytes: _jsonInt(json['sizeBytes']),
    );
  }

  RecordingVideoVersion copyWith({
    bool? isDefault,
  }) =>
      RecordingVideoVersion(
        id: id,
        articleId: articleId,
        videoPath: videoPath,
        subtitlePath: subtitlePath,
        createdAt: createdAt,
        source: source,
        title: title,
        isDefault: isDefault ?? this.isDefault,
        durationMs: durationMs,
        frameCount: frameCount,
        droppedFrameCount: droppedFrameCount,
        encoderName: encoderName,
        codec: codec,
        resolution: resolution,
        pageTransition: pageTransition,
        sizeBytes: sizeBytes,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'articleId': articleId,
        'videoPath': videoPath,
        'subtitlePath': subtitlePath,
        'createdAt': createdAt,
        'source': source,
        'title': title,
        'isDefault': isDefault,
        if (durationMs != null) 'durationMs': durationMs,
        if (frameCount != null) 'frameCount': frameCount,
        if (droppedFrameCount != null) 'droppedFrameCount': droppedFrameCount,
        if (encoderName.isNotEmpty) 'encoderName': encoderName,
        if (codec.isNotEmpty) 'codec': codec,
        if (resolution.isNotEmpty) 'resolution': resolution,
        if (pageTransition.isNotEmpty) 'pageTransition': pageTransition,
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
      };
}

class RecordingVideoLibrary {
  const RecordingVideoLibrary({
    required this.articleId,
    required this.outputDirectory,
    required this.versions,
  });

  final int articleId;
  final String outputDirectory;
  final List<RecordingVideoVersion> versions;

  Map<String, dynamic> toJson() => {
        'articleId': articleId,
        'outputDirectory': outputDirectory,
        'versions': versions.map((version) => version.toJson()).toList(),
      };
}

class RecordingCancelToken {
  bool _cancelled = false;
  final List<void Function()> _callbacks = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    for (final callback in List<void Function()>.from(_callbacks)) {
      callback();
    }
    _callbacks.clear();
  }

  void throwIfCancelled() {
    if (_cancelled) {
      throw const RecordingExportException('录制已取消');
    }
  }

  void onCancel(void Function() callback) {
    if (_cancelled) {
      callback();
      return;
    }
    _callbacks.add(callback);
  }
}

class RecordingExportException implements Exception {
  const RecordingExportException(this.message);

  final String message;

  @override
  String toString() => message;
}

class RecordingExportService {
  static const int defaultFps = 25;
  static const int transitionMs = 500;
  static const String _videoIndexFileName = 'recording_video_versions.json';

  static Future<Map<String, dynamic>> settingsPayload() async {
    final settings = await AppConfig.recordingSettings;
    return _normalizeSettings(settings);
  }

  static Future<Map<String, dynamic>> saveSettings({
    required String codec,
    required String resolution,
    required String pageTransition,
    required String subtitleMode,
  }) async {
    final normalized = _normalizeSettings({
      'codec': codec,
      'resolution': resolution,
      'pageTransition': pageTransition,
      'subtitleMode': subtitleMode,
    });
    await AppConfig.saveRecordingSettings(
      codec: normalized['codec']! as String,
      resolution: normalized['resolution']! as String,
      pageTransition: normalized['pageTransition']! as String,
      subtitleMode: normalized['subtitleMode']! as String,
    );
    return normalized;
  }

  static Future<RecordingVideoLibrary> videoLibrary(int articleId) async {
    final directory = Directory(defaultOutputDirectory());
    await directory.create(recursive: true);
    final allVersions = await _readVideoIndex();
    final scannedVersions = await _scanArticleVideos(
      directory: directory,
      articleId: articleId,
    );
    final articleVersions = await _normalizeArticleVideoVersions(
      <RecordingVideoVersion>[
        ...allVersions.where((version) => version.articleId == articleId),
        ...scannedVersions,
      ],
    );
    await _writeVideoIndex(_replaceArticleVideoVersions(
      allVersions,
      articleId,
      articleVersions,
    ));
    return RecordingVideoLibrary(
      articleId: articleId,
      outputDirectory: directory.path,
      versions: articleVersions,
    );
  }

  static Future<RecordingVideoLibrary> setDefaultVideo({
    required int articleId,
    required String videoId,
  }) async {
    final library = await videoLibrary(articleId);
    if (library.versions.isEmpty) {
      throw const RecordingExportException('还没有可播放的视频版本');
    }
    var found = false;
    final versions = library.versions.map((version) {
      final selected = version.id == videoId;
      found = found || selected;
      return version.copyWith(isDefault: selected);
    }).toList(growable: false);
    if (!found) {
      throw RecordingExportException('没有找到视频版本：$videoId');
    }
    final allVersions = await _readVideoIndex();
    await _writeVideoIndex(_replaceArticleVideoVersions(
      allVersions,
      articleId,
      versions,
    ));
    return RecordingVideoLibrary(
      articleId: articleId,
      outputDirectory: library.outputDirectory,
      versions: versions,
    );
  }

  static Future<RecordingVideoLibrary> deleteVideo({
    required int articleId,
    required String videoId,
  }) async {
    final requestedId = videoId.trim();
    if (requestedId.isEmpty) {
      throw const RecordingExportException('请选择要删除的视频');
    }
    final library = await videoLibrary(articleId);
    RecordingVideoVersion? target;
    for (final version in library.versions) {
      if (version.id == requestedId) {
        target = version;
        break;
      }
    }
    if (target == null) {
      throw RecordingExportException('没有找到视频版本：$requestedId');
    }

    final outputDirectory = library.outputDirectory;
    if (!_isPathInsideDirectory(target.videoPath, outputDirectory)) {
      throw RecordingExportException('视频文件不在导出目录内，已取消删除：${target.videoPath}');
    }

    final targetId = target.id;
    final paths = <String>{
      target.videoPath,
      if (target.subtitlePath.trim().isNotEmpty) target.subtitlePath,
      path_lib.setExtension(target.videoPath, '.srt'),
    };
    for (final path in paths) {
      if (!_isPathInsideDirectory(path, outputDirectory)) {
        continue;
      }
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }

    final remaining = await _normalizeArticleVideoVersions(
      library.versions
          .where((version) => version.id != targetId)
          .toList(growable: false),
    );
    final allVersions = await _readVideoIndex();
    await _writeVideoIndex(_replaceArticleVideoVersions(
      allVersions,
      articleId,
      remaining,
    ));
    return RecordingVideoLibrary(
      articleId: articleId,
      outputDirectory: outputDirectory,
      versions: remaining,
    );
  }

  static Future<RecordingVideoVersion> resolveVideo({
    required int articleId,
    String videoId = '',
  }) async {
    final library = await videoLibrary(articleId);
    if (library.versions.isEmpty) {
      throw const RecordingExportException('还没有可播放的视频版本');
    }
    if (videoId.trim().isEmpty) {
      return library.versions.firstWhere(
        (version) => version.isDefault,
        orElse: () => library.versions.first,
      );
    }
    for (final version in library.versions) {
      if (version.id == videoId) {
        return version;
      }
    }
    throw RecordingExportException('没有找到视频版本：$videoId');
  }

  static Future<RecordingReadiness> readiness(
    RecordingExportRequest request,
  ) async {
    final reasons = <String>[];
    final assets = await _prepareAssets(
      request,
      collectAudioClips: false,
      reasons: reasons,
    );
    final encoder = await _resolveEncoder(
      codec: request.codec,
    );
    if (!encoder.available) {
      reasons.add(encoder.reason);
    }
    final directory = Directory(defaultOutputDirectory());
    try {
      await directory.create(recursive: true);
      final probe = File(path_lib.join(
        directory.path,
        '.tomato_recording_write_probe',
      ));
      await probe.writeAsString('ok');
      await probe.delete();
    } catch (error) {
      reasons.add('输出目录不可写：$error');
    }

    return RecordingReadiness(
      ready: reasons.isEmpty,
      reasons: reasons,
      encoderName: encoder.encoderName,
      codec: request.codec,
      resolution: request.resolution,
      pageTransition: request.pageTransition,
      outputDirectory: directory.path,
      requiredEnglish: assets.requiredEnglish,
      readyEnglish: assets.readyEnglish,
      requiredChinese: assets.requiredChinese,
      readyChinese: assets.readyChinese,
      picturePageCount: assets.pages.length,
    );
  }

  static Future<RecordingExportResult> exportVideo(
    RecordingExportRequest request, {
    RecordingCancelToken? cancelToken,
    void Function(RecordingExportProgress progress)? onProgress,
  }) async {
    final token = cancelToken ?? RecordingCancelToken();
    token.throwIfCancelled();

    final ready = await readiness(request);
    if (!ready.ready) {
      throw RecordingExportException(ready.reasons.join('\n'));
    }
    final reasons = <String>[];
    final assets = await _prepareAssets(
      request,
      collectAudioClips: true,
      reasons: reasons,
    );
    if (reasons.isNotEmpty) {
      throw RecordingExportException(reasons.join('\n'));
    }
    final encoder = await _resolveEncoder(
      codec: request.codec,
    );
    if (!encoder.available) {
      throw RecordingExportException(encoder.reason);
    }

    final timeline = _buildTimeline(assets, request);
    if (timeline.durationMs <= 0 || timeline.segments.isEmpty) {
      throw const RecordingExportException('没有可导出的听力音频时间轴');
    }

    final outputDirectory = Directory(defaultOutputDirectory());
    await outputDirectory.create(recursive: true);
    final baseName = await _availableOutputBaseName(
      directory: outputDirectory,
      article: assets.article,
      series: assets.series,
    );
    final videoPath = path_lib.join(outputDirectory.path, '$baseName.mp4');
    final subtitleOutputPath =
        path_lib.join(outputDirectory.path, '$baseName.srt');
    final subtitlePath =
        request.subtitleMode.writesSrt ? subtitleOutputPath : '';
    final frameCount = (timeline.durationMs / (1000 / request.fps))
        .ceil()
        .clamp(1, 1 << 31)
        .toInt();
    final tempDir = await Directory.systemTemp.createTemp(
      'tomato_recording_${request.articleId}_',
    );

    try {
      token.throwIfCancelled();
      if (request.subtitleMode.writesSrt) {
        await File(subtitleOutputPath).writeAsString(
          _srtForTimeline(timeline),
          encoding: utf8,
        );
      }
      onProgress?.call(RecordingExportProgress(
        articleId: request.articleId,
        phase: 'rendering',
        progress: 0.02,
        completedFrames: 0,
        totalFrames: frameCount,
        message: '正在渲染视频帧',
      ));

      final audioListPath = path_lib.join(tempDir.path, 'audio_concat.txt');
      await File(audioListPath).writeAsString(
        assets.audioClips
            .map((clip) => "file '${_ffmpegConcatPath(clip.filePath)}'")
            .join('\n'),
        encoding: utf8,
      );

      if (request.pageTransition == RecordingPageTransition.none) {
        final videoListPath = await _renderStillSegments(
          request: request,
          assets: assets,
          timeline: timeline,
          frameCount: frameCount,
          outputDirectory: tempDir,
          cancelToken: token,
          onProgress: onProgress,
        );

        onProgress?.call(RecordingExportProgress(
          articleId: request.articleId,
          phase: 'encoding',
          progress: 0.35,
          completedFrames: 0,
          totalFrames: frameCount,
          message: '正在编码 MP4',
        ));

        await _runFfmpegEncodeStillSegments(
          ffmpegPath: encoder.ffmpegExecutable,
          encoderName: encoder.encoderName,
          request: request,
          videoListPath: videoListPath,
          audioListPath: audioListPath,
          outputPath: videoPath,
          keyFrameTimes: timeline.pageChangeTimesMs,
          frameCount: frameCount,
          cancelToken: token,
          onProgress: onProgress,
        );
      } else {
        final videoListPath = await _renderHybridSegments(
          request: request,
          assets: assets,
          timeline: timeline,
          frameCount: frameCount,
          outputDirectory: tempDir,
          cancelToken: token,
          onProgress: onProgress,
        );

        onProgress?.call(RecordingExportProgress(
          articleId: request.articleId,
          phase: 'encoding',
          progress: 0.35,
          completedFrames: 0,
          totalFrames: frameCount,
          message: '正在编码 MP4',
        ));

        await _runFfmpegEncodeStillSegments(
          ffmpegPath: encoder.ffmpegExecutable,
          encoderName: encoder.encoderName,
          request: request,
          videoListPath: videoListPath,
          audioListPath: audioListPath,
          outputPath: videoPath,
          keyFrameTimes: timeline.pageChangeTimesMs,
          frameCount: frameCount,
          cancelToken: token,
          onProgress: onProgress,
        );
      }

      onProgress?.call(RecordingExportProgress(
        articleId: request.articleId,
        phase: 'completed',
        progress: 1,
        completedFrames: frameCount,
        totalFrames: frameCount,
        message: '录制完成',
      ));

      final warnings = <String>[
        if (encoder.softwareFallback) '当前使用软件编码器 ${encoder.encoderName}',
      ];
      final result = RecordingExportResult(
        articleId: request.articleId,
        videoPath: videoPath,
        subtitlePath: subtitlePath,
        durationMs: timeline.durationMs,
        frameCount: frameCount,
        droppedFrameCount: 0,
        encoderName: encoder.encoderName,
        codec: request.codec,
        resolution: request.resolution,
        pageTransition: request.pageTransition,
        warnings: warnings,
      );
      await _registerVideoVersion(
        result,
        source: 'listening',
      );
      return result;
    } catch (_) {
      await _cleanupFailedExport(
        videoPath: videoPath,
        subtitlePath: subtitleOutputPath,
      );
      rethrow;
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // Temporary frame cleanup is best effort.
      }
    }
  }

  static Future<RecordingReadiness> songReadiness(
    SongRecordingExportRequest request,
  ) async {
    final reasons = <String>[];
    final assets = await _prepareSongAssets(request, reasons: reasons);
    final encoder = await _resolveEncoder(codec: request.codec);
    if (!encoder.available) {
      reasons.add(encoder.reason);
    }
    final directory = Directory(defaultOutputDirectory());
    try {
      await directory.create(recursive: true);
      final probe = File(path_lib.join(
        directory.path,
        '.tomato_recording_write_probe',
      ));
      await probe.writeAsString('ok');
      await probe.delete();
    } catch (error) {
      reasons.add('输出目录不可写：$error');
    }
    return RecordingReadiness(
      ready: reasons.isEmpty,
      reasons: reasons,
      encoderName: encoder.encoderName,
      codec: request.codec,
      resolution: request.resolution,
      pageTransition: request.pageTransition,
      outputDirectory: directory.path,
      requiredEnglish: assets.timeline.cues.length,
      readyEnglish: reasons.isEmpty ? assets.timeline.cues.length : 0,
      requiredChinese: 0,
      readyChinese: 0,
      picturePageCount: assets.pages.length,
    );
  }

  static Future<RecordingExportResult> exportSongVideo(
    SongRecordingExportRequest request, {
    RecordingCancelToken? cancelToken,
    void Function(RecordingExportProgress progress)? onProgress,
  }) async {
    final token = cancelToken ?? RecordingCancelToken();
    token.throwIfCancelled();

    final ready = await songReadiness(request);
    if (!ready.ready) {
      throw RecordingExportException(ready.reasons.join('\n'));
    }
    final reasons = <String>[];
    final assets = await _prepareSongAssets(request, reasons: reasons);
    if (reasons.isNotEmpty) {
      throw RecordingExportException(reasons.join('\n'));
    }
    final encoder = await _resolveEncoder(codec: request.codec);
    if (!encoder.available) {
      throw RecordingExportException(encoder.reason);
    }
    final timeline = _buildSongTimeline(assets);
    if (timeline.durationMs <= 0 || timeline.segments.isEmpty) {
      throw const RecordingExportException('没有可导出的歌曲字幕时间轴');
    }

    final outputDirectory = Directory(defaultOutputDirectory());
    await outputDirectory.create(recursive: true);
    final baseName = await _availableOutputBaseName(
      directory: outputDirectory,
      article: assets.article,
      series: assets.series,
    );
    final videoPath = path_lib.join(outputDirectory.path, '$baseName.mp4');
    final subtitleOutputPath =
        path_lib.join(outputDirectory.path, '$baseName.srt');
    final subtitlePath =
        request.subtitleMode.writesSrt ? subtitleOutputPath : '';
    final frameCount = (timeline.durationMs / (1000 / request.fps))
        .ceil()
        .clamp(1, 1 << 31)
        .toInt();
    final tempDir = await Directory.systemTemp.createTemp(
      'tomato_song_recording_${request.articleId}_',
    );

    try {
      token.throwIfCancelled();
      if (request.subtitleMode.writesSrt) {
        await File(subtitleOutputPath).writeAsString(
          SongSubtitleTimelineService.srtForTimeline(assets.timeline),
          encoding: utf8,
        );
      }
      onProgress?.call(RecordingExportProgress(
        articleId: request.articleId,
        phase: 'rendering',
        progress: 0.02,
        completedFrames: 0,
        totalFrames: frameCount,
        message: '正在渲染歌曲视频帧',
      ));

      final audioListPath = path_lib.join(tempDir.path, 'audio_concat.txt');
      await File(audioListPath).writeAsString(
        "file '${_ffmpegConcatPath(request.audioPath)}'",
        encoding: utf8,
      );

      if (request.pageTransition == RecordingPageTransition.none) {
        final videoListPath = await _renderStillSegments(
          request: RecordingExportRequest(
            articleId: request.articleId,
            mode: 'english',
            codec: request.codec,
            resolution: request.resolution,
            pageTransition: request.pageTransition,
            subtitleMode: request.subtitleMode,
            fps: request.fps,
          ),
          assets: assets.toRecordingAssets(),
          timeline: timeline,
          frameCount: frameCount,
          outputDirectory: tempDir,
          cancelToken: token,
          onProgress: onProgress,
        );
        await _runFfmpegEncodeStillSegments(
          ffmpegPath: encoder.ffmpegExecutable,
          encoderName: encoder.encoderName,
          request: RecordingExportRequest(
            articleId: request.articleId,
            mode: 'english',
            codec: request.codec,
            resolution: request.resolution,
            pageTransition: request.pageTransition,
            subtitleMode: request.subtitleMode,
            fps: request.fps,
          ),
          videoListPath: videoListPath,
          audioListPath: audioListPath,
          outputPath: videoPath,
          keyFrameTimes: timeline.pageChangeTimesMs,
          frameCount: frameCount,
          cancelToken: token,
          onProgress: onProgress,
        );
      } else {
        final recordingRequest = RecordingExportRequest(
          articleId: request.articleId,
          mode: 'english',
          codec: request.codec,
          resolution: request.resolution,
          pageTransition: request.pageTransition,
          subtitleMode: request.subtitleMode,
          fps: request.fps,
        );
        final videoListPath = await _renderHybridSegments(
          request: recordingRequest,
          assets: assets.toRecordingAssets(),
          timeline: timeline,
          frameCount: frameCount,
          outputDirectory: tempDir,
          cancelToken: token,
          onProgress: onProgress,
        );
        await _runFfmpegEncodeStillSegments(
          ffmpegPath: encoder.ffmpegExecutable,
          encoderName: encoder.encoderName,
          request: recordingRequest,
          videoListPath: videoListPath,
          audioListPath: audioListPath,
          outputPath: videoPath,
          keyFrameTimes: timeline.pageChangeTimesMs,
          frameCount: frameCount,
          cancelToken: token,
          onProgress: onProgress,
        );
      }

      onProgress?.call(RecordingExportProgress(
        articleId: request.articleId,
        phase: 'completed',
        progress: 1,
        completedFrames: frameCount,
        totalFrames: frameCount,
        message: '歌曲视频录制完成',
      ));

      final warnings = <String>[
        ...assets.timeline.warnings,
        if (encoder.softwareFallback) '当前使用软件编码器 ${encoder.encoderName}',
      ];
      final result = RecordingExportResult(
        articleId: request.articleId,
        videoPath: videoPath,
        subtitlePath: subtitlePath,
        durationMs: timeline.durationMs,
        frameCount: frameCount,
        droppedFrameCount: 0,
        encoderName: encoder.encoderName,
        codec: request.codec,
        resolution: request.resolution,
        pageTransition: request.pageTransition,
        warnings: warnings,
      );
      await _registerVideoVersion(
        result,
        source: 'song',
      );
      return result;
    } catch (_) {
      await _cleanupFailedExport(
        videoPath: videoPath,
        subtitlePath: subtitleOutputPath,
      );
      rethrow;
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // Temporary frame cleanup is best effort.
      }
    }
  }

  static Map<String, dynamic> _normalizeSettings(Map<String, String> settings) {
    final codec = _parseCodec(settings['codec'] ?? 'h264').name;
    final resolution =
        RecordingResolution.parse(settings['resolution'] ?? '').id;
    final transition =
        RecordingPageTransition.parse(settings['pageTransition'] ?? '').name;
    final subtitleMode =
        RecordingSubtitleMode.parse(settings['subtitleMode'] ?? '').name;
    return {
      'codec': codec,
      'resolution': resolution,
      'pageTransition': transition,
      'subtitleMode': subtitleMode,
      'outputDirectory': defaultOutputDirectory(),
      'ffmpegPath': bundledFfmpegPath(),
      'fps': defaultFps,
      'quality': 'high',
      'hardwareBackend': 'auto',
    };
  }

  static RecordingCodec _parseCodec(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized == 'h265' || normalized == 'hevc'
        ? RecordingCodec.h265
        : RecordingCodec.h264;
  }

  static String programDirectory() =>
      File(Platform.resolvedExecutable).parent.absolute.path;

  static String bundledFfmpegPath() =>
      path_lib.join(programDirectory(), 'ffmpeg.exe');

  static String defaultOutputDirectory() =>
      path_lib.join(programDirectory(), 'recording-export');

  static Future<void> _registerVideoVersion(
    RecordingExportResult result, {
    required String source,
  }) async {
    final version = await _videoVersionFromResult(result, source: source);
    final allVersions = await _readVideoIndex();
    final articleVersions = await _normalizeArticleVideoVersions(
      <RecordingVideoVersion>[
        ...allVersions
            .where((item) => item.articleId == result.articleId)
            .where((item) => item.id != version.id),
        version,
      ],
    );
    await _writeVideoIndex(_replaceArticleVideoVersions(
      allVersions,
      result.articleId,
      articleVersions,
    ));
  }

  static Future<RecordingVideoVersion> _videoVersionFromResult(
    RecordingExportResult result, {
    required String source,
  }) async {
    FileStat? stat;
    try {
      stat = await File(result.videoPath).stat();
    } catch (_) {
      stat = null;
    }
    final createdAt = _createdAtFromVideoPath(result.videoPath) ??
        stat?.modified ??
        DateTime.now();
    return RecordingVideoVersion(
      id: _videoIdForPath(result.videoPath),
      articleId: result.articleId,
      videoPath: result.videoPath,
      subtitlePath: result.subtitlePath,
      createdAt: createdAt.toIso8601String(),
      source: source,
      title: path_lib.basenameWithoutExtension(result.videoPath),
      isDefault: false,
      durationMs: result.durationMs,
      frameCount: result.frameCount,
      droppedFrameCount: result.droppedFrameCount,
      encoderName: result.encoderName,
      codec: result.codec.name,
      resolution: result.resolution.id,
      pageTransition: result.pageTransition.name,
      sizeBytes: stat?.size,
    );
  }

  static Future<List<RecordingVideoVersion>> _readVideoIndex() async {
    final file = _videoIndexFile();
    if (!await file.exists()) {
      return const <RecordingVideoVersion>[];
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      final rawList =
          decoded is Map ? (decoded['versions'] ?? decoded['videos']) : decoded;
      if (rawList is! List) {
        return const <RecordingVideoVersion>[];
      }
      return rawList
          .whereType<Map>()
          .map((item) => RecordingVideoVersion.fromJson(
                Map<String, dynamic>.from(item),
              ))
          .where(
              (item) => item.articleId > 0 && item.videoPath.trim().isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const <RecordingVideoVersion>[];
    }
  }

  static Future<void> _writeVideoIndex(
    List<RecordingVideoVersion> versions,
  ) async {
    final deduped = <String, RecordingVideoVersion>{};
    for (final version in versions) {
      if (version.videoPath.trim().isEmpty || version.articleId <= 0) {
        continue;
      }
      deduped[_videoPathKey(version.videoPath)] = version;
    }
    final sorted = deduped.values.toList()
      ..sort((left, right) {
        final articleCompare = left.articleId.compareTo(right.articleId);
        if (articleCompare != 0) {
          return articleCompare;
        }
        return _videoCreatedAt(right).compareTo(_videoCreatedAt(left));
      });
    final file = _videoIndexFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'versions': sorted.map((version) => version.toJson()).toList(),
      }),
      encoding: utf8,
    );
  }

  static File _videoIndexFile() =>
      File(path_lib.join(defaultOutputDirectory(), _videoIndexFileName));

  static bool _isPathInsideDirectory(String path, String directoryPath) {
    final normalizedDirectory =
        path_lib.normalize(Directory(directoryPath).absolute.path);
    final normalizedPath = path_lib.normalize(File(path).absolute.path);
    final directory = Platform.isWindows
        ? normalizedDirectory.toLowerCase()
        : normalizedDirectory;
    final candidate =
        Platform.isWindows ? normalizedPath.toLowerCase() : normalizedPath;
    return candidate == directory ||
        candidate.startsWith('$directory${path_lib.separator}');
  }

  static List<RecordingVideoVersion> _replaceArticleVideoVersions(
    List<RecordingVideoVersion> allVersions,
    int articleId,
    List<RecordingVideoVersion> articleVersions,
  ) =>
      <RecordingVideoVersion>[
        ...allVersions.where((version) => version.articleId != articleId),
        ...articleVersions,
      ];

  static Future<List<RecordingVideoVersion>> _normalizeArticleVideoVersions(
    List<RecordingVideoVersion> versions,
  ) async {
    final byPath = <String, RecordingVideoVersion>{};
    for (final version in versions) {
      final videoPath = version.videoPath.trim();
      if (videoPath.isEmpty) {
        continue;
      }
      final videoFile = File(videoPath);
      if (!await videoFile.exists()) {
        continue;
      }
      final stat = await videoFile.stat();
      if (stat.size <= 0) {
        await _cleanupFailedExport(
          videoPath: videoPath,
          subtitlePath: version.subtitlePath.trim().isNotEmpty
              ? version.subtitlePath
              : path_lib.setExtension(videoPath, '.srt'),
        );
        continue;
      }
      byPath.putIfAbsent(_videoPathKey(videoPath), () => version);
    }
    final sorted = byPath.values.toList()
      ..sort((left, right) =>
          _videoCreatedAt(right).compareTo(_videoCreatedAt(left)));
    if (sorted.isEmpty) {
      return const <RecordingVideoVersion>[];
    }
    final defaultVersion = sorted.firstWhere(
      (version) => version.isDefault,
      orElse: () => sorted.first,
    );
    return sorted
        .map((version) =>
            version.copyWith(isDefault: version.id == defaultVersion.id))
        .toList(growable: false);
  }

  static Future<List<RecordingVideoVersion>> _scanArticleVideos({
    required Directory directory,
    required int articleId,
  }) async {
    if (!await directory.exists()) {
      return const <RecordingVideoVersion>[];
    }
    final context = await _recordingArticleContext(articleId);
    final article = context.article;
    if (article == null) {
      return const <RecordingVideoVersion>[];
    }
    final prefix = _outputBasePrefix(
      seriesTitle: context.series?.title ?? '',
      articleTitle: article.title,
    );
    if (prefix.isEmpty) {
      return const <RecordingVideoVersion>[];
    }
    final pattern = RegExp(
      '^${RegExp.escape(prefix)} - (\\d{8}-\\d{6})(?:-\\d+)?\\.mp4\$',
      caseSensitive: false,
    );
    final versions = <RecordingVideoVersion>[];
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File ||
            path_lib.extension(entity.path).toLowerCase() != '.mp4') {
          continue;
        }
        final fileName = path_lib.basename(entity.path);
        final match = pattern.firstMatch(fileName);
        if (match == null) {
          continue;
        }
        final stat = await entity.stat();
        if (stat.size <= 0) {
          await _cleanupFailedExport(
            videoPath: entity.path,
            subtitlePath: path_lib.setExtension(entity.path, '.srt'),
          );
          continue;
        }
        final createdAt = _dateTimeFromStamp(match.group(1)) ?? stat.modified;
        final subtitlePath = path_lib.setExtension(entity.path, '.srt');
        versions.add(RecordingVideoVersion(
          id: _videoIdForPath(entity.path),
          articleId: articleId,
          videoPath: entity.path,
          subtitlePath: await File(subtitlePath).exists() ? subtitlePath : '',
          createdAt: createdAt.toIso8601String(),
          source: 'scanned',
          title: path_lib.basenameWithoutExtension(entity.path),
          isDefault: false,
          sizeBytes: stat.size,
        ));
      }
    } catch (_) {
      return versions;
    }
    return versions;
  }

  static Future<_RecordingArticleContext> _recordingArticleContext(
    int articleId,
  ) async {
    final article = await DatabaseService.getArticleById(articleId);
    if (article == null) {
      return const _RecordingArticleContext(null, null);
    }
    final chapter = await DatabaseService.getStoryChapterForArticle(articleId);
    final series = chapter == null
        ? null
        : await DatabaseService.getStorySeriesById(chapter.seriesId);
    return _RecordingArticleContext(article, series);
  }

  static String _outputBasePrefix({
    required String seriesTitle,
    required String articleTitle,
  }) =>
      _sanitizeFileName([
        if (seriesTitle.trim().isNotEmpty) seriesTitle,
        articleTitle,
      ].join(' - '));

  static Future<_PreparedRecordingAssets> _prepareAssets(
    RecordingExportRequest request, {
    required bool collectAudioClips,
    required List<String> reasons,
  }) async {
    final article = await DatabaseService.getArticleById(request.articleId);
    if (article == null) {
      reasons.add('文章不存在（id=${request.articleId}）');
      return _PreparedRecordingAssets.empty(request.articleId);
    }
    final sentences = article.sentences
        .map((sentence) => sentence.trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
    if (sentences.isEmpty) {
      reasons.add('文章没有可导出的英文句子');
    }
    final chapter =
        await DatabaseService.getStoryChapterForArticle(request.articleId);
    final series = chapter == null
        ? null
        : await DatabaseService.getStorySeriesById(chapter.seriesId);
    final pages = await DatabaseService.getPictureBookPages(request.articleId);
    final readyPages = pages
        .where((page) => page.status == 'ready')
        .toList(growable: false)
      ..sort((a, b) => a.pageIndex.compareTo(b.pageIndex));
    if (readyPages.isEmpty) {
      reasons.add('绘本图尚未生成完成');
    }
    final imageByPath = <String, Uint8List>{};
    for (final page in readyPages) {
      final imagePath = page.imagePath?.trim() ?? '';
      if (imagePath.isEmpty) {
        reasons.add('第 ${page.pageIndex + 1} 张绘本缺少图片文件路径');
        continue;
      }
      final file = File(imagePath);
      if (!await file.exists()) {
        reasons.add('第 ${page.pageIndex + 1} 张绘本图片文件不存在');
        continue;
      }
      try {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) {
          reasons.add('第 ${page.pageIndex + 1} 张绘本图片为空');
        } else {
          imageByPath[imagePath] = bytes;
        }
      } catch (error) {
        reasons.add('第 ${page.pageIndex + 1} 张绘本图片读取失败：$error');
      }
    }

    final covered = <int>{};
    for (final page in readyPages) {
      for (var i = page.sentenceStartIndex;
          i <= page.sentenceEndIndex && i < sentences.length;
          i += 1) {
        if (i >= 0) {
          covered.add(i);
        }
      }
    }
    for (var i = 0; i < sentences.length; i += 1) {
      if (!covered.contains(i)) {
        reasons.add('绘本页未覆盖第 ${i + 1} 句');
        break;
      }
    }

    final items = <_RecordingSentenceItem>[];
    var requiredEnglish = 0;
    var readyEnglish = 0;
    var requiredChinese = 0;
    var readyChinese = 0;
    final audioClips = <_RecordingAudioClip>[];
    for (var index = 0; index < sentences.length; index += 1) {
      final english = sentences[index];
      final overrideChinese = request.subtitleTranslations[index]?.trim() ?? '';
      final chinese = overrideChinese.isNotEmpty
          ? overrideChinese
          : (await DatabaseService.getArticleSentenceTranslation(
                request.articleId,
                index,
                english,
              )) ??
              '';
      final page = _pageForSentence(readyPages, index);
      items.add(_RecordingSentenceItem(
        index: index,
        english: english,
        chinese: chinese,
        pageIndex: page?.pageIndex ?? 0,
      ));

      requiredEnglish += 1;
      final englishHandle = await _audioFileHandleOrNull(
        text: english,
        voiceType: TtsService.defaultVoiceType,
        preferRequestedVoice: false,
        articleId: request.articleId,
      );
      if (englishHandle == null) {
        reasons.add('第 ${index + 1} 句英文音频文件准备失败');
      } else {
        readyEnglish += 1;
        if (collectAudioClips) {
          final bytes = await File(englishHandle.filePath).readAsBytes();
          audioClips.add(_RecordingAudioClip(
            sentenceIndex: index,
            part: 'english',
            text: english,
            filePath: englishHandle.filePath,
            durationMs: RecordingExportUtils.estimateMp3DurationMs(bytes),
          ));
        }
      }
    }

    if (collectAudioClips) {
      for (final clip in audioClips) {
        if (clip.durationMs <= 0) {
          reasons.add('第 ${clip.sentenceIndex + 1} 句音频时长解析失败');
          break;
        }
      }
    }

    return _PreparedRecordingAssets(
      article: article,
      series: series,
      pages: readyPages,
      pageImageBytes: imageByPath,
      items: items,
      audioClips: audioClips,
      requiredEnglish: requiredEnglish,
      readyEnglish: readyEnglish,
      requiredChinese: requiredChinese,
      readyChinese: readyChinese,
    );
  }

  static Future<_PreparedSongRecordingAssets> _prepareSongAssets(
    SongRecordingExportRequest request, {
    required List<String> reasons,
  }) async {
    final article = await DatabaseService.getArticleById(request.articleId);
    if (article == null) {
      reasons.add('文章不存在（id=${request.articleId}）');
      return _PreparedSongRecordingAssets.empty(request.articleId);
    }
    final audioFile = File(request.audioPath);
    if (!await audioFile.exists()) {
      reasons.add('歌曲音频文件不存在：${request.audioPath}');
    }
    SongSubtitleTimeline timeline;
    try {
      timeline = await SongSubtitleTimelineService.readCurrentTimeline(
        request.timelinePath,
      );
    } catch (error) {
      reasons.add(error.toString());
      timeline = SongSubtitleTimeline(
        version: 1,
        articleId: request.articleId,
        audioHash: '',
        lyricsHash: '',
        durationMs: 0,
        source: 'suno',
        cues: const [],
      );
    }
    if (timeline.cues.isEmpty) {
      reasons.add('歌曲字幕时间线为空');
    }
    final chapter =
        await DatabaseService.getStoryChapterForArticle(request.articleId);
    final series = chapter == null
        ? null
        : await DatabaseService.getStorySeriesById(chapter.seriesId);
    final pages = await DatabaseService.getPictureBookPages(request.articleId);
    final readyPages = pages
        .where((page) => page.status == 'ready')
        .toList(growable: false)
      ..sort((a, b) => a.pageIndex.compareTo(b.pageIndex));
    if (readyPages.isEmpty) {
      reasons.add('绘本图尚未生成完成');
    }
    final imageByPath = <String, Uint8List>{};
    for (final page in readyPages) {
      final imagePath = page.imagePath?.trim() ?? '';
      if (imagePath.isEmpty) {
        reasons.add('第 ${page.pageIndex + 1} 张绘本缺少图片文件路径');
        continue;
      }
      final file = File(imagePath);
      if (!await file.exists()) {
        reasons.add('第 ${page.pageIndex + 1} 张绘本图片文件不存在');
        continue;
      }
      try {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) {
          reasons.add('第 ${page.pageIndex + 1} 张绘本图片为空');
        } else {
          imageByPath[imagePath] = bytes;
        }
      } catch (error) {
        reasons.add('第 ${page.pageIndex + 1} 张绘本图片读取失败：$error');
      }
    }

    final items = <_RecordingSentenceItem>[];
    for (final cue in timeline.cues) {
      final page = _pageForSentence(readyPages, cue.lineIndex);
      items.add(_RecordingSentenceItem(
        index: cue.lineIndex,
        english: cue.english,
        chinese: cue.chinese,
        pageIndex: page?.pageIndex ?? 0,
      ));
    }
    return _PreparedSongRecordingAssets(
      article: article,
      series: series,
      pages: readyPages,
      pageImageBytes: imageByPath,
      items: items,
      timeline: timeline,
    );
  }

  static Future<TtsFileHandle?> _audioFileHandleOrNull({
    required String text,
    required String voiceType,
    required bool preferRequestedVoice,
    required int articleId,
  }) async {
    try {
      return await TtsMemoryCacheService.loadFile(
        text: text,
        voiceType: voiceType,
        preferRequestedVoice: preferRequestedVoice,
        articleId: articleId,
        cachePurpose: 'listening_tts',
      );
    } catch (_) {
      return null;
    }
  }

  static _RecordingTimeline _buildTimeline(
    _PreparedRecordingAssets assets,
    RecordingExportRequest request,
  ) {
    final clipsBySentence = <int, List<_RecordingAudioClip>>{};
    for (final clip in assets.audioClips) {
      (clipsBySentence[clip.sentenceIndex] ??= <_RecordingAudioClip>[])
          .add(clip);
    }
    var cursorMs = 0;
    final segments = <_RecordingTimelineSegment>[];
    for (final item in assets.items) {
      final clips =
          clipsBySentence[item.index] ?? const <_RecordingAudioClip>[];
      final english = clips.firstWhere(
        (clip) => clip.part == 'english',
        orElse: () => _RecordingAudioClip.empty(item.index, 'english'),
      );
      final chinese = _RecordingAudioClip.empty(item.index, 'chinese');
      final englishStart = cursorMs;
      final englishDurationMs = english.durationMs < 0 ? 0 : english.durationMs;
      final chineseDurationMs = chinese.durationMs < 0 ? 0 : chinese.durationMs;
      final englishEnd = englishStart + englishDurationMs;
      final chineseStart = englishEnd;
      final chineseEnd = chineseStart + chineseDurationMs;
      final sentenceEnd = math.max(englishEnd, chineseEnd);
      segments.add(_RecordingTimelineSegment(
        item: item,
        sentenceStartMs: cursorMs,
        englishStartMs: englishStart,
        englishEndMs: englishEnd,
        chineseStartMs: chineseStart,
        chineseEndMs: chineseEnd,
        sentenceEndMs: sentenceEnd,
      ));
      cursorMs = sentenceEnd;
    }

    final pageChangeTimes = <int>[];
    for (var i = 1; i < segments.length; i += 1) {
      if (segments[i - 1].item.pageIndex != segments[i].item.pageIndex) {
        pageChangeTimes.add(segments[i].sentenceStartMs);
      }
    }
    return _RecordingTimeline(
      segments: segments,
      durationMs: cursorMs,
      pageChangeTimesMs: pageChangeTimes,
    );
  }

  static _RecordingTimeline _buildSongTimeline(
    _PreparedSongRecordingAssets assets,
  ) {
    final segments = <_RecordingTimelineSegment>[];
    var cursorMs = 0;
    var currentPageIndex =
        assets.items.isEmpty ? 0 : assets.items.first.pageIndex;

    void addBlankSegment(int startMs, int endMs, int pageIndex) {
      if (endMs <= startMs) {
        return;
      }
      segments.add(_RecordingTimelineSegment(
        item: _RecordingSentenceItem(
          index: -1,
          english: '',
          chinese: '',
          pageIndex: pageIndex,
        ),
        sentenceStartMs: startMs,
        englishStartMs: startMs,
        englishEndMs: startMs,
        chineseStartMs: startMs,
        chineseEndMs: startMs,
        sentenceEndMs: endMs,
      ));
    }

    for (var i = 0; i < assets.timeline.cues.length; i += 1) {
      final cue = assets.timeline.cues[i];
      final cueStart = cue.startMs.clamp(0, assets.timeline.durationMs).toInt();
      final cueEnd =
          cue.endMs.clamp(cueStart, assets.timeline.durationMs).toInt();
      final item = i < assets.items.length
          ? assets.items[i]
          : _RecordingSentenceItem(
              index: cue.lineIndex,
              english: cue.english,
              chinese: cue.chinese,
              pageIndex: 0,
            );
      if (cueStart > cursorMs) {
        addBlankSegment(cursorMs, cueStart, currentPageIndex);
      }
      segments.add(_RecordingTimelineSegment(
        item: item,
        sentenceStartMs: cueStart,
        englishStartMs: cueStart,
        englishEndMs: cueEnd,
        chineseStartMs: cueStart,
        chineseEndMs: cueEnd,
        sentenceEndMs: cueEnd,
      ));
      cursorMs = math.max(cursorMs, cueEnd);
      currentPageIndex = item.pageIndex;
    }
    if (cursorMs < assets.timeline.durationMs) {
      addBlankSegment(cursorMs, assets.timeline.durationMs, currentPageIndex);
    }
    if (segments.isEmpty && assets.timeline.durationMs > 0) {
      addBlankSegment(0, assets.timeline.durationMs, currentPageIndex);
    }
    final pageChangeTimes = <int>[];
    for (var i = 1; i < segments.length; i += 1) {
      if (segments[i - 1].item.pageIndex != segments[i].item.pageIndex) {
        pageChangeTimes.add(segments[i].sentenceStartMs);
      }
    }
    return _RecordingTimeline(
      segments: segments,
      durationMs: math.max(
        assets.timeline.durationMs,
        segments.isEmpty ? 0 : segments.last.sentenceEndMs,
      ),
      pageChangeTimesMs: pageChangeTimes,
    );
  }

  static Future<String> _renderHybridSegments({
    required RecordingExportRequest request,
    required _PreparedRecordingAssets assets,
    required _RecordingTimeline timeline,
    required int frameCount,
    required Directory outputDirectory,
    required RecordingCancelToken cancelToken,
    void Function(RecordingExportProgress progress)? onProgress,
  }) async {
    final images = <int, ui.Image>{};
    final parts = _hybridRenderParts(
      timeline: timeline,
      transition: request.pageTransition,
    );
    final renderedParts = <_RenderedVideoPart>[];
    var renderedMs = 0.0;
    var assetIndex = 0;

    Future<void> renderPartProgress(
      _HybridRenderPart part,
      double renderedDurationMs,
    ) async {
      final completedFrames = math.min(
        frameCount,
        (renderedDurationMs * request.fps / 1000).ceil(),
      );
      onProgress?.call(RecordingExportProgress(
        articleId: request.articleId,
        phase: 'rendering',
        progress: 0.02 +
            0.3 *
                (renderedDurationMs /
                    math.max(1, timeline.durationMs).toDouble()),
        completedFrames: completedFrames,
        totalFrames: frameCount,
        message: part.isTransition ? '正在渲染转场视频帧' : '正在渲染视频画面',
      ));
    }

    try {
      for (final page in assets.pages) {
        final imagePath = page.imagePath?.trim() ?? '';
        final bytes = assets.pageImageBytes[imagePath];
        if (bytes == null || bytes.isEmpty) {
          continue;
        }
        images[page.pageIndex] = await _decodeImage(bytes);
      }

      for (final part in parts) {
        cancelToken.throwIfCancelled();
        if (!part.isTransition) {
          final timeMs = math.min(
            math.max(0, timeline.durationMs - 1),
            part.startMs,
          );
          final bitmap = await _renderFrameBitmap(
            request: request,
            timeline: timeline,
            images: images,
            timeMs: timeMs,
          );
          final partPath = path_lib.join(
            outputDirectory.path,
            'hybrid_${assetIndex.toString().padLeft(5, '0')}.bmp',
          );
          assetIndex += 1;
          await File(partPath).writeAsBytes(bitmap, flush: false);
          renderedParts.add(_RenderedVideoPart(
            path: partPath,
            durationMs: part.durationMs.toDouble(),
          ));
          renderedMs += part.durationMs;
          await renderPartProgress(part, renderedMs);
          continue;
        }

        final frameDurationMs = 1000 / math.max(1, request.fps);
        var cursorMs = part.startMs.toDouble();
        var localFrameIndex = 0;
        while (cursorMs < part.endMs) {
          cancelToken.throwIfCancelled();
          final nextMs =
              math.min(part.endMs.toDouble(), cursorMs + frameDurationMs);
          final timeMs = math.min(
            math.max(0, timeline.durationMs - 1),
            cursorMs.round(),
          );
          final bitmap = await _renderFrameBitmap(
            request: request,
            timeline: timeline,
            images: images,
            timeMs: timeMs,
          );
          final framePath = path_lib.join(
            outputDirectory.path,
            'transition_${assetIndex.toString().padLeft(5, '0')}.bmp',
          );
          assetIndex += 1;
          await File(framePath).writeAsBytes(bitmap, flush: false);
          final durationMs = math.max(1.0, nextMs - cursorMs);
          renderedParts.add(_RenderedVideoPart(
            path: framePath,
            durationMs: durationMs,
          ));
          renderedMs += durationMs;
          localFrameIndex += 1;
          if (localFrameIndex % math.max(1, request.fps) == 0 ||
              nextMs >= part.endMs) {
            await renderPartProgress(part, renderedMs);
          }
          cursorMs = nextMs;
        }
      }
    } finally {
      for (final image in images.values) {
        image.dispose();
      }
    }

    if (renderedParts.isEmpty) {
      throw const RecordingExportException('没有可导出的视频画面');
    }

    final lines = <String>['ffconcat version 1.0'];
    for (final part in renderedParts) {
      lines
        ..add("file '${_ffmpegConcatPath(part.path)}'")
        ..add('duration ${(part.durationMs / 1000).toStringAsFixed(6)}');
    }
    lines.add("file '${_ffmpegConcatPath(renderedParts.last.path)}'");
    final videoListPath =
        path_lib.join(outputDirectory.path, 'video_hybrid_concat.txt');
    await File(videoListPath).writeAsString(lines.join('\n'), encoding: utf8);
    return videoListPath;
  }

  static List<_HybridRenderPart> _hybridRenderParts({
    required _RecordingTimeline timeline,
    required RecordingPageTransition transition,
  }) {
    if (timeline.segments.isEmpty) {
      return const <_HybridRenderPart>[];
    }
    final windows = _transitionWindows(timeline, transition);
    final parts = <_HybridRenderPart>[];
    for (final segment in timeline.segments) {
      final segmentStart = segment.sentenceStartMs
          .clamp(0, math.max(0, timeline.durationMs))
          .toInt();
      final segmentEnd = segment.sentenceEndMs
          .clamp(segmentStart, math.max(segmentStart, timeline.durationMs))
          .toInt();
      var cursor = segmentStart;
      for (final window in windows) {
        if (window.endMs <= cursor) {
          continue;
        }
        if (window.startMs >= segmentEnd) {
          break;
        }
        final staticEnd = math.min(segmentEnd, window.startMs).toInt();
        if (staticEnd > cursor) {
          parts.add(_HybridRenderPart.static(
            startMs: cursor,
            endMs: staticEnd,
          ));
        }
        final transitionStart = math.max(cursor, window.startMs).toInt();
        final transitionEnd = math.min(segmentEnd, window.endMs).toInt();
        if (transitionEnd > transitionStart) {
          parts.add(_HybridRenderPart.transition(
            startMs: transitionStart,
            endMs: transitionEnd,
          ));
        }
        cursor = math.max(cursor, transitionEnd).toInt();
      }
      if (segmentEnd > cursor) {
        parts.add(_HybridRenderPart.static(
          startMs: cursor,
          endMs: segmentEnd,
        ));
      }
    }
    return parts.where((part) => part.durationMs > 0).toList(growable: false);
  }

  static Future<String> _renderStillSegments({
    required RecordingExportRequest request,
    required _PreparedRecordingAssets assets,
    required _RecordingTimeline timeline,
    required int frameCount,
    required Directory outputDirectory,
    required RecordingCancelToken cancelToken,
    void Function(RecordingExportProgress progress)? onProgress,
  }) async {
    final images = <int, ui.Image>{};
    final segmentPaths = <String>[];
    try {
      for (final page in assets.pages) {
        final imagePath = page.imagePath?.trim() ?? '';
        final bytes = assets.pageImageBytes[imagePath];
        if (bytes == null || bytes.isEmpty) {
          continue;
        }
        images[page.pageIndex] = await _decodeImage(bytes);
      }
      for (var index = 0; index < timeline.segments.length; index += 1) {
        cancelToken.throwIfCancelled();
        final segment = timeline.segments[index];
        final timeMs = math.min(
          timeline.durationMs - 1,
          segment.sentenceStartMs,
        );
        final bitmap = await _renderFrameBitmap(
          request: request,
          timeline: timeline,
          images: images,
          timeMs: timeMs,
        );
        final cardPath = path_lib.join(
          outputDirectory.path,
          'segment_${index.toString().padLeft(4, '0')}.bmp',
        );
        await File(cardPath).writeAsBytes(bitmap, flush: false);
        segmentPaths.add(cardPath);
        final completedFrames = math.min(
          frameCount,
          (segment.sentenceEndMs * request.fps / 1000).ceil(),
        );
        onProgress?.call(RecordingExportProgress(
          articleId: request.articleId,
          phase: 'rendering',
          progress: 0.02 + 0.3 * ((index + 1) / timeline.segments.length),
          completedFrames: completedFrames,
          totalFrames: frameCount,
          message: '正在渲染视频画面',
        ));
      }
    } finally {
      for (final image in images.values) {
        image.dispose();
      }
    }

    if (segmentPaths.isEmpty) {
      throw const RecordingExportException('没有可导出的视频画面');
    }

    final lines = <String>['ffconcat version 1.0'];
    for (var index = 0; index < timeline.segments.length; index += 1) {
      final segment = timeline.segments[index];
      final durationMs = math.max(
        1,
        segment.sentenceEndMs - segment.sentenceStartMs,
      );
      lines
        ..add("file '${_ffmpegConcatPath(segmentPaths[index])}'")
        ..add('duration ${(durationMs / 1000).toStringAsFixed(6)}');
    }
    lines.add("file '${_ffmpegConcatPath(segmentPaths.last)}'");
    final videoListPath =
        path_lib.join(outputDirectory.path, 'video_concat.txt');
    await File(videoListPath).writeAsString(lines.join('\n'), encoding: utf8);
    return videoListPath;
  }

  static Future<ui.Image> _decodeImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  static Future<Uint8List> _renderFrameBitmap({
    required RecordingExportRequest request,
    required _RecordingTimeline timeline,
    required Map<int, ui.Image> images,
    required int timeMs,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = Size(
      request.resolution.width.toDouble(),
      request.resolution.height.toDouble(),
    );
    final bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..color = const Color(0xFF07111F));

    final segment = timeline.segmentAt(timeMs);
    final transition = _transitionAt(
      timeline: timeline,
      timeMs: timeMs,
      currentPageIndex: segment.item.pageIndex,
      transition: request.pageTransition,
    );
    if (transition == null) {
      final image = images[segment.item.pageIndex];
      if (image != null) {
        _drawContainImage(canvas, image, bounds, Paint());
      }
    } else {
      final fromImage = images[transition.fromPageIndex];
      final toImage = images[transition.toPageIndex];
      _drawTransition(
        canvas: canvas,
        bounds: bounds,
        fromImage: fromImage,
        toImage: toImage,
        progress: transition.progress,
        transition: request.pageTransition,
      );
    }

    if (request.subtitleMode.burnsIn) {
      _drawBurnedInSubtitles(canvas, segment, bounds);
    }

    final picture = recorder.endRecording();
    final image =
        await picture.toImage(size.width.toInt(), size.height.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    picture.dispose();
    if (bytes == null) {
      throw const RecordingExportException('视频帧编码 BMP 失败');
    }
    return _bmpFromRawRgba(
      bytes.buffer.asUint8List(),
      size.width.toInt(),
      size.height.toInt(),
    );
  }

  static Uint8List _bmpFromRawRgba(Uint8List rgba, int width, int height) {
    const headerSize = 54;
    final pixelBytes = width * height * 4;
    if (rgba.lengthInBytes < pixelBytes) {
      throw const RecordingExportException('视频帧像素数据不完整');
    }
    final output = Uint8List(headerSize + pixelBytes);
    final data = ByteData.sublistView(output);
    data
      ..setUint16(0, 0x4D42, Endian.little)
      ..setUint32(2, output.lengthInBytes, Endian.little)
      ..setUint32(10, headerSize, Endian.little)
      ..setUint32(14, 40, Endian.little)
      ..setInt32(18, width, Endian.little)
      ..setInt32(22, -height, Endian.little)
      ..setUint16(26, 1, Endian.little)
      ..setUint16(28, 32, Endian.little)
      ..setUint32(34, pixelBytes, Endian.little);

    var src = 0;
    var dst = headerSize;
    for (var i = 0; i < width * height; i += 1) {
      final r = rgba[src];
      final g = rgba[src + 1];
      final b = rgba[src + 2];
      final a = rgba[src + 3];
      output[dst] = b;
      output[dst + 1] = g;
      output[dst + 2] = r;
      output[dst + 3] = a;
      src += 4;
      dst += 4;
    }
    return output;
  }

  static void _drawBurnedInSubtitles(
    Canvas canvas,
    _RecordingTimelineSegment segment,
    Rect bounds,
  ) {
    final english = RecordingExportUtils.cleanSubtitleText(
      segment.item.english,
    );
    final chinese = RecordingExportUtils.cleanSubtitleText(
      segment.item.chinese,
    );
    if (english.isEmpty && chinese.isEmpty) {
      return;
    }

    final maxWidth = bounds.width * 0.84;
    final lineGap =
        chinese.isEmpty ? 0.0 : math.max(6.0, bounds.height * 0.006);
    final englishFont = math.max(28.0, math.min(54.0, bounds.width / 34));
    final chineseFont = math.max(22.0, math.min(42.0, bounds.width / 46));
    final outlineWidth = math.max(3.0, bounds.width * 0.0022);
    final englishParagraph = _subtitleParagraph(
      english,
      fontSize: englishFont,
      fontWeight: FontWeight.w800,
      maxLines: 3,
      maxWidth: maxWidth,
    );
    final englishOutline = _subtitleParagraph(
      english,
      fontSize: englishFont,
      fontWeight: FontWeight.w800,
      maxLines: 3,
      maxWidth: maxWidth,
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = outlineWidth
        ..color = const Color(0xE607111F),
    );
    final chineseParagraph = chinese.isEmpty
        ? null
        : _subtitleParagraph(
            chinese,
            fontSize: chineseFont,
            fontWeight: FontWeight.w700,
            maxLines: 2,
            maxWidth: maxWidth,
          );
    final chineseOutline = chinese.isEmpty
        ? null
        : _subtitleParagraph(
            chinese,
            fontSize: chineseFont,
            fontWeight: FontWeight.w700,
            maxLines: 2,
            maxWidth: maxWidth,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeJoin = StrokeJoin.round
              ..strokeWidth = outlineWidth
              ..color = const Color(0xE607111F),
          );

    final contentHeight = englishParagraph.height +
        (chineseParagraph == null ? 0 : lineGap + chineseParagraph.height);
    final bottomPadding = math.max(30.0, bounds.height * 0.045);
    var y = math.max(
      bounds.top + 12,
      bounds.bottom - bottomPadding - contentHeight,
    );

    _drawOutlinedSubtitleParagraph(
      canvas,
      fill: englishParagraph,
      outline: englishOutline,
      offset: Offset(
        bounds.left + (bounds.width - englishParagraph.width) / 2,
        y,
      ),
    );
    y += englishParagraph.height + lineGap;
    if (chineseParagraph != null && chineseOutline != null) {
      _drawOutlinedSubtitleParagraph(
        canvas,
        fill: chineseParagraph,
        outline: chineseOutline,
        offset: Offset(
          bounds.left + (bounds.width - chineseParagraph.width) / 2,
          y,
        ),
      );
    }
  }

  static void _drawOutlinedSubtitleParagraph(
    Canvas canvas, {
    required ui.Paragraph fill,
    required ui.Paragraph outline,
    required Offset offset,
  }) {
    canvas.drawParagraph(outline, offset);
    canvas.drawParagraph(outline, offset + const Offset(0, 2));
    canvas.drawParagraph(fill, offset);
  }

  static ui.Paragraph _subtitleParagraph(
    String text, {
    required double fontSize,
    required FontWeight fontWeight,
    required int maxLines,
    required double maxWidth,
    Paint? foreground,
  }) {
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: TextAlign.center,
        maxLines: maxLines,
        ellipsis: '...',
      ),
    )..pushStyle(ui.TextStyle(
        color: foreground == null ? const Color(0xFFFFFFFF) : null,
        foreground: foreground,
        fontSize: fontSize,
        fontWeight: fontWeight,
        height: 1.18,
      ));
    builder.addText(text);
    final paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: maxWidth));
    return paragraph;
  }

  static void _drawContainImage(
    Canvas canvas,
    ui.Image image,
    Rect bounds,
    Paint paint, {
    double scale = 1,
    Offset offset = Offset.zero,
  }) {
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final fitted = applyBoxFit(BoxFit.contain, imageSize, bounds.size);
    var dst = Alignment.center.inscribe(fitted.destination, bounds);
    if (scale != 1) {
      dst = Rect.fromCenter(
        center: dst.center,
        width: dst.width * scale,
        height: dst.height * scale,
      );
    }
    dst = dst.shift(offset);
    canvas.drawImageRect(
      image,
      Offset.zero & imageSize,
      dst,
      paint,
    );
  }

  static void _drawTransition({
    required Canvas canvas,
    required Rect bounds,
    required ui.Image? fromImage,
    required ui.Image? toImage,
    required double progress,
    required RecordingPageTransition transition,
  }) {
    final clamped = progress.clamp(0, 1).toDouble();
    switch (transition) {
      case RecordingPageTransition.pageCurl:
        _drawPageCurlTransition(
          canvas: canvas,
          bounds: bounds,
          fromImage: fromImage,
          toImage: toImage,
          progress: clamped,
        );
      case RecordingPageTransition.slide:
        if (fromImage != null) {
          _drawContainImage(
            canvas,
            fromImage,
            bounds,
            Paint(),
            offset: Offset(-bounds.width * clamped, 0),
          );
        }
        if (toImage != null) {
          _drawContainImage(
            canvas,
            toImage,
            bounds,
            Paint(),
            offset: Offset(bounds.width * (1 - clamped), 0),
          );
        }
      case RecordingPageTransition.panZoomFade:
        if (fromImage != null) {
          _drawContainImage(
            canvas,
            fromImage,
            bounds,
            _opacityPaint(1 - clamped),
            scale: 1 + clamped * 0.03,
          );
        }
        if (toImage != null) {
          _drawContainImage(
            canvas,
            toImage,
            bounds,
            _opacityPaint(clamped),
            scale: 1.04 - clamped * 0.04,
          );
        }
      case RecordingPageTransition.crossFade:
      case RecordingPageTransition.none:
        if (fromImage != null) {
          _drawContainImage(
            canvas,
            fromImage,
            bounds,
            _opacityPaint(1 - clamped),
          );
        }
        if (toImage != null) {
          _drawContainImage(
            canvas,
            toImage,
            bounds,
            _opacityPaint(clamped),
          );
        }
    }
  }

  static void _drawPageCurlTransition({
    required Canvas canvas,
    required Rect bounds,
    required ui.Image? fromImage,
    required ui.Image? toImage,
    required double progress,
  }) {
    final raw = progress.clamp(0, 1).toDouble();
    if (raw <= 0.015) {
      if (fromImage != null) {
        _drawContainImage(canvas, fromImage, bounds, Paint());
      } else if (toImage != null) {
        _drawContainImage(canvas, toImage, bounds, Paint());
      }
      return;
    }
    if (raw >= 0.985) {
      if (toImage != null) {
        _drawContainImage(canvas, toImage, bounds, Paint());
      } else if (fromImage != null) {
        _drawContainImage(canvas, fromImage, bounds, Paint());
      }
      return;
    }

    if (fromImage == null) {
      if (toImage != null) {
        _drawContainImage(canvas, toImage, bounds, Paint());
      } else {
        canvas.drawRect(bounds, Paint()..color = const Color(0xFFF8F8F4));
      }
      return;
    }

    final pageWidth = bounds.width;
    final pageHeight = bounds.height;
    final halfPageWidth = pageWidth * 0.5;
    final spineX = bounds.center.dx;
    final turn = _smoothStep(raw);
    final arc = math.sin(math.pi * turn);

    _drawContainImage(canvas, fromImage, bounds, Paint());

    if (toImage != null) {
      final sheetWidth =
          halfPageWidth * (0.055 + 0.945 * math.sin(turn * math.pi / 2));
      final rightEdgeProgress = _smoothStep(((raw - 0.16) / 0.84).clamp(0, 1));
      final rightEdge = _lerp(
        bounds.right + halfPageWidth * 0.018,
        spineX,
        rightEdgeProgress,
      );
      final leftEdge = rightEdge - sheetWidth;
      final slant = halfPageWidth * 0.20 * arc;
      final lift = pageHeight * 0.050 * arc * (1 - turn * 0.35);

      final topLeft = Offset(
        leftEdge + slant * 0.62,
        bounds.top - pageHeight * 0.014 * arc,
      );
      final topRight = Offset(
        rightEdge + slant * 0.22,
        bounds.top + pageHeight * 0.018 * arc,
      );
      final bottomLeft = Offset(
        leftEdge - slant * 0.48,
        bounds.bottom - lift,
      );
      final bottomRight = Offset(
        rightEdge - slant * 0.28,
        bounds.bottom - pageHeight * 0.010 * arc,
      );

      final rightRevealPath = Path()
        ..moveTo(topRight.dx, topRight.dy)
        ..lineTo(bounds.right, bounds.top)
        ..lineTo(bounds.right, bounds.bottom)
        ..lineTo(bottomRight.dx, bottomRight.dy)
        ..close();
      canvas.save();
      canvas.clipPath(rightRevealPath, doAntiAlias: true);
      _drawRightHalfAsFlatPage(
        canvas: canvas,
        image: toImage,
        bounds: bounds,
        opacity: 1,
      );
      canvas.restore();

      _drawBookSpineHint(canvas, bounds, strength: 0.18 + 0.28 * turn);

      final sheetPath = Path()
        ..moveTo(topLeft.dx, topLeft.dy)
        ..lineTo(topRight.dx, topRight.dy)
        ..lineTo(bottomRight.dx, bottomRight.dy)
        ..lineTo(bottomLeft.dx, bottomLeft.dy)
        ..close();

      canvas.drawShadow(
        sheetPath,
        const Color(0xAA000000),
        math.max(5, pageWidth * 0.006),
        true,
      );

      canvas.save();
      canvas.clipPath(sheetPath, doAntiAlias: true);
      canvas.drawRect(
          sheetPath.getBounds(), Paint()..color = const Color(0xFFFDFDFB));
      _drawImageSliceIntoQuad(
        canvas: canvas,
        image: toImage,
        source: Rect.fromLTRB(
          0,
          0,
          toImage.width * 0.5,
          toImage.height.toDouble(),
        ),
        topLeft: topLeft,
        topRight: topRight,
        bottomLeft: bottomLeft,
        clipPath: sheetPath,
      );
      _drawPageCurlBackShading(
        canvas: canvas,
        sheetBounds: sheetPath.getBounds(),
        creaseTop: topRight,
        creaseBottom: bottomRight,
        progress: turn,
      );
      canvas.restore();

      _drawPageCurlCrease(
        canvas: canvas,
        creaseTop: topRight,
        creaseBottom: bottomRight,
        outerTop: topLeft,
        outerBottom: bottomLeft,
        progress: turn,
      );
      return;
    }

    _drawBookSpineHint(canvas, bounds, strength: 0.25 * turn);
  }

  static void _drawImageSliceIntoQuad({
    required Canvas canvas,
    required ui.Image image,
    required Rect source,
    required Offset topLeft,
    required Offset topRight,
    required Offset bottomLeft,
    required Path clipPath,
  }) {
    if (source.width <= 1 || source.height <= 1) {
      return;
    }
    final xAxis = (topRight - topLeft) / source.width;
    final yAxis = (bottomLeft - topLeft) / source.height;
    canvas.save();
    canvas.clipPath(clipPath, doAntiAlias: true);
    canvas.transform(Float64List.fromList([
      xAxis.dx,
      xAxis.dy,
      0,
      0,
      yAxis.dx,
      yAxis.dy,
      0,
      0,
      0,
      0,
      1,
      0,
      topLeft.dx,
      topLeft.dy,
      0,
      1,
    ]));
    canvas.drawImageRect(
      image,
      source,
      Rect.fromLTWH(0, 0, source.width, source.height),
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  static void _drawPageCurlBackShading({
    required Canvas canvas,
    required Rect sheetBounds,
    required Offset creaseTop,
    required Offset creaseBottom,
    required double progress,
  }) {
    if (sheetBounds.width <= 1 || sheetBounds.height <= 1) {
      return;
    }
    final shadowStrength =
        (0.16 + 0.22 * math.sin(math.pi * progress)).clamp(0, 0.42).toDouble();
    canvas.drawRect(
      sheetBounds,
      Paint()
        ..shader = ui.Gradient.linear(
          sheetBounds.centerLeft,
          sheetBounds.centerRight,
          [
            const Color(0x22FFFFFF),
            const Color.fromRGBO(255, 255, 255, 0.18),
            Color.fromRGBO(0, 0, 0, shadowStrength),
            const Color(0x18FFFFFF),
          ],
          const [0.0, 0.46, 0.86, 1.0],
        ),
    );
    canvas.drawLine(
      creaseTop,
      creaseBottom,
      Paint()
        ..color = Color.fromRGBO(0, 0, 0, 0.16 + shadowStrength * 0.35)
        ..strokeWidth = math.max(2.0, sheetBounds.width * 0.006),
    );
  }

  static void _drawPageCurlCrease({
    required Canvas canvas,
    required Offset creaseTop,
    required Offset creaseBottom,
    required Offset outerTop,
    required Offset outerBottom,
    required double progress,
  }) {
    final creaseWidth =
        math.max(2.0, (creaseBottom - creaseTop).distance * 0.002);
    canvas.drawLine(
      creaseTop,
      creaseBottom,
      Paint()
        ..color = const Color(0xAA242424)
        ..strokeWidth = creaseWidth,
    );
    canvas.drawLine(
      outerTop,
      outerBottom,
      Paint()
        ..color = const Color(0xDDFFFFFF)
        ..strokeWidth = math.max(1.6, creaseWidth * 0.85),
    );
    final lipProgress =
        (1 - _smoothStep((progress / 0.36).clamp(0, 1))).clamp(0, 1).toDouble();
    if (lipProgress <= 0.02) {
      return;
    }
    final lipLength = math.max(16.0, (outerBottom - creaseBottom).distance);
    final lipPath = Path()
      ..moveTo(creaseBottom.dx, creaseBottom.dy)
      ..quadraticBezierTo(
        _lerp(creaseBottom.dx, outerBottom.dx, 0.45),
        creaseBottom.dy - lipLength * 0.18,
        outerBottom.dx,
        outerBottom.dy,
      )
      ..lineTo(
        outerBottom.dx + lipLength * 0.08 * lipProgress,
        outerBottom.dy - lipLength * 0.18 * lipProgress,
      )
      ..quadraticBezierTo(
        _lerp(creaseBottom.dx, outerBottom.dx, 0.66),
        creaseBottom.dy - lipLength * 0.30 * lipProgress,
        creaseBottom.dx,
        creaseBottom.dy,
      )
      ..close();
    canvas.drawPath(
      lipPath,
      Paint()
        ..shader = ui.Gradient.linear(
          creaseBottom,
          outerBottom,
          const [
            Color(0xFFFFFFFF),
            Color(0xFFE8E8E4),
            Color(0xFFBDBDB8),
          ],
          const [0.0, 0.55, 1.0],
        ),
    );
  }

  static void _drawRightHalfAsFlatPage({
    required Canvas canvas,
    required ui.Image image,
    required Rect bounds,
    required double opacity,
  }) {
    final dst = Rect.fromLTRB(
      bounds.center.dx,
      bounds.top,
      bounds.right,
      bounds.bottom,
    );
    if (dst.width <= 1 || dst.height <= 1) {
      return;
    }
    final src = Rect.fromLTRB(
      image.width * 0.5,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    canvas.drawImageRect(
      image,
      src,
      dst,
      _opacityPaint(opacity),
    );
  }

  static void _drawBookSpineHint(
    Canvas canvas,
    Rect bounds, {
    required double strength,
  }) {
    if (strength <= 0) {
      return;
    }
    final alpha = (strength.clamp(0, 1) * 255).round();
    final spineWidth = math.max(10.0, bounds.width * 0.035);
    final spineRect = Rect.fromCenter(
      center: Offset(bounds.center.dx, bounds.center.dy),
      width: spineWidth,
      height: bounds.height,
    );
    canvas.drawRect(
      spineRect,
      Paint()
        ..shader = ui.Gradient.linear(
          spineRect.centerLeft,
          spineRect.centerRight,
          [
            const Color.fromARGB(0, 0, 0, 0),
            Color.fromARGB((alpha * 0.38).round(), 0, 0, 0),
            Color.fromARGB((alpha * 0.16).round(), 255, 255, 255),
            Color.fromARGB((alpha * 0.34).round(), 0, 0, 0),
            const Color.fromARGB(0, 0, 0, 0),
          ],
          const [0.0, 0.35, 0.50, 0.65, 1.0],
        ),
    );
  }

  static Paint _opacityPaint(double opacity) => Paint()
    ..colorFilter = ui.ColorFilter.mode(
      Color.fromRGBO(255, 255, 255, opacity.clamp(0, 1).toDouble()),
      BlendMode.modulate,
    );

  static double _smoothStep(double value) {
    final t = value.clamp(0, 1).toDouble();
    return t * t * (3 - 2 * t);
  }

  static double _lerp(double start, double end, double progress) =>
      start + (end - start) * progress;

  static _PageTransition? _transitionAt({
    required _RecordingTimeline timeline,
    required int timeMs,
    required int currentPageIndex,
    required RecordingPageTransition transition,
  }) {
    for (final window in _transitionWindows(timeline, transition)) {
      if (timeMs < window.startMs || timeMs > window.endMs) {
        continue;
      }
      return _PageTransition(
        fromPageIndex: window.fromPageIndex,
        toPageIndex: window.toPageIndex,
        progress: (timeMs - window.startMs) / (window.endMs - window.startMs),
      );
    }
    return null;
  }

  static List<_TransitionWindow> _transitionWindows(
    _RecordingTimeline timeline,
    RecordingPageTransition transition,
  ) {
    if (transition == RecordingPageTransition.none) {
      return const <_TransitionWindow>[];
    }
    final windows = <_TransitionWindow>[];
    for (var i = 1; i < timeline.segments.length; i += 1) {
      final previous = timeline.segments[i - 1];
      final next = timeline.segments[i];
      if (previous.item.pageIndex == next.item.pageIndex) {
        continue;
      }
      final changeMs = next.sentenceStartMs;
      final before = math.min(
        transitionMs ~/ 2,
        math.max(0, previous.sentenceEndMs - previous.sentenceStartMs) ~/ 2,
      );
      final after = math.min(
        transitionMs - before,
        math.max(0, next.sentenceEndMs - next.sentenceStartMs) ~/ 2,
      );
      final start = (changeMs - before)
          .clamp(0, math.max(0, timeline.durationMs))
          .toInt();
      final end = (changeMs + after)
          .clamp(start, math.max(start, timeline.durationMs))
          .toInt();
      if (end <= start) {
        continue;
      }
      windows.add(_TransitionWindow(
        startMs: start,
        endMs: end,
        fromPageIndex: previous.item.pageIndex,
        toPageIndex: next.item.pageIndex,
      ));
    }
    return windows;
  }

  static Future<void> _runFfmpegEncodeStillSegments({
    required String ffmpegPath,
    required String encoderName,
    required RecordingExportRequest request,
    required String videoListPath,
    required String audioListPath,
    required String outputPath,
    required List<int> keyFrameTimes,
    required int frameCount,
    required RecordingCancelToken cancelToken,
    void Function(RecordingExportProgress progress)? onProgress,
  }) async {
    final bitrate = _bitrateProfile(request.resolution, request.codec);
    final args = <String>[
      '-y',
      '-hide_banner',
      '-loglevel',
      'error',
      '-nostats',
      '-progress',
      'pipe:1',
      '-f',
      'concat',
      '-safe',
      '0',
      '-i',
      videoListPath,
      '-f',
      'concat',
      '-safe',
      '0',
      '-i',
      audioListPath,
      '-map',
      '0:v:0',
      '-map',
      '1:a:0',
      '-r',
      request.fps.toString(),
      '-vsync',
      'cfr',
      '-c:v',
      encoderName,
      ..._encoderQualityArgs(
        encoderName: encoderName,
        codec: request.codec,
        bitrate: bitrate,
      ),
      '-g',
      (request.fps * 5).toString(),
      '-keyint_min',
      request.fps.toString(),
      if (keyFrameTimes.isNotEmpty) ...[
        '-force_key_frames',
        keyFrameTimes.map((ms) => (ms / 1000).toStringAsFixed(3)).join(','),
      ],
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'copy',
      '-shortest',
      '-movflags',
      '+faststart',
      outputPath,
    ];

    final process = await Process.start(
      ffmpegPath,
      args,
      runInShell: false,
    );
    cancelToken.onCancel(() {
      process.kill(ProcessSignal.sigterm);
    });

    final stderrBuffer = StringBuffer();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .listen(stderrBuffer.write)
        .asFuture<void>();
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final frame = _parseProgressFrame(line);
      if (frame == null) {
        return;
      }
      onProgress?.call(RecordingExportProgress(
        articleId: request.articleId,
        phase: 'encoding',
        progress: 0.35 + 0.63 * (frame / math.max(1, frameCount)),
        completedFrames: math.min(frame, frameCount),
        totalFrames: frameCount,
        message: '正在编码 MP4',
      ));
    }).asFuture<void>();
    final exitCode = await process.exitCode;
    await Future.wait([stderrDone, stdoutDone]);
    cancelToken.throwIfCancelled();
    if (exitCode != 0) {
      final error = stderrBuffer.toString().trim();
      throw RecordingExportException(
        _friendlyFfmpegEncodeError(
          error.isEmpty ? 'FFmpeg 编码失败（exit=$exitCode）' : error,
          encoderName: encoderName,
          codec: request.codec,
        ),
      );
    }
  }

  static int? _parseProgressFrame(String line) {
    final match = RegExp(r'^frame=(\d+)').firstMatch(line.trim());
    if (match == null) {
      return null;
    }
    return int.tryParse(match.group(1) ?? '');
  }

  static List<String> _encoderQualityArgs({
    required String encoderName,
    required RecordingCodec codec,
    required _BitrateProfile bitrate,
  }) {
    final args = <String>[
      '-b:v',
      '${bitrate.targetKbps}k',
      '-maxrate',
      '${bitrate.maxKbps}k',
      '-bufsize',
      '${bitrate.maxKbps * 2}k',
    ];
    if (encoderName == 'libx264') {
      args.addAll(['-preset', 'slow']);
    } else if (encoderName == 'libx265') {
      args.addAll(['-preset', 'slow', '-tag:v', 'hvc1']);
    } else if (codec == RecordingCodec.h265) {
      args.addAll(['-tag:v', 'hvc1']);
    }
    return args;
  }

  static Future<_ResolvedEncoder> _resolveEncoder({
    required RecordingCodec codec,
  }) async {
    final executable = await _resolveFfmpegExecutable();
    if (executable == null) {
      return _ResolvedEncoder.unavailable(
        '程序目录缺少 ffmpeg.exe：${bundledFfmpegPath()}。请重新发布程序或把 ffmpeg.exe 放到程序目录。',
      );
    }
    final probe = await _runProcess(
      executable,
      const ['-hide_banner', '-encoders'],
      timeout: const Duration(seconds: 10),
    );
    if (probe.exitCode != 0) {
      final error = probe.stderr.trim().isEmpty
          ? probe.stdout.trim()
          : probe.stderr.trim();
      return _ResolvedEncoder.unavailable(
        'FFmpeg 编码器探测失败：${error.isEmpty ? '未知错误' : error}',
      );
    }
    final candidates = _selectEncoderCandidates(codec, probe.stdout);
    if (candidates.isEmpty) {
      return _ResolvedEncoder.unavailable(
        codec == RecordingCodec.h265
            ? '当前 FFmpeg 不支持 H.265/HEVC 编码'
            : '当前 FFmpeg 不支持 H.264 编码',
      );
    }
    final rejected = <String>[];
    for (final encoder in candidates) {
      final unusableReason = await _probeEncoderUsability(
        executable: executable,
        codec: codec,
        encoderName: encoder,
      );
      if (unusableReason != null) {
        rejected.add('$encoder：$unusableReason');
        continue;
      }
      return _ResolvedEncoder(
        available: true,
        ffmpegExecutable: executable,
        encoderName: encoder,
        reason: '',
        softwareFallback: encoder == 'libx264' || encoder == 'libx265',
      );
    }
    return _ResolvedEncoder.unavailable(
      '${codec == RecordingCodec.h265 ? 'H.265/HEVC' : 'H.264'} 编码器不可用：'
      '${rejected.join('；')}',
    );
  }

  static Future<String?> _probeEncoderUsability({
    required String executable,
    required RecordingCodec codec,
    required String encoderName,
  }) async {
    final result = await _runProcess(
      executable,
      [
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'color=c=black:s=64x64:r=1:d=0.1',
        '-frames:v',
        '1',
        '-an',
        '-pix_fmt',
        'yuv420p',
        '-c:v',
        encoderName,
        ..._probeEncoderArgs(encoderName, codec),
        '-f',
        'null',
        '-',
      ],
      timeout: const Duration(seconds: 10),
    );
    if (result.exitCode == 0) {
      return null;
    }
    final error =
        result.stderr.trim().isEmpty ? result.stdout.trim() : result.stderr;
    return _friendlyFfmpegEncodeError(
      error.trim().isEmpty ? 'FFmpeg 编码器探测失败' : error.trim(),
      encoderName: encoderName,
      codec: codec,
    );
  }

  static List<String> _probeEncoderArgs(
    String encoderName,
    RecordingCodec codec,
  ) {
    if (encoderName == 'libx264' || encoderName == 'libx265') {
      return const ['-preset', 'ultrafast'];
    }
    return const <String>[];
  }

  static String _friendlyFfmpegEncodeError(
    String rawError, {
    required String encoderName,
    required RecordingCodec codec,
  }) {
    final codecLabel = codec == RecordingCodec.h265 ? 'H.265/HEVC' : 'H.264';
    final trimmed = rawError.trim();
    final firstLine = trimmed
        .split(RegExp(r'[\r\n]+'))
        .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '')
        .trim();
    final lower = trimmed.toLowerCase();
    if (lower.contains('no capable devices found') &&
        encoderName.contains('nvenc')) {
      return '$codecLabel 硬件编码失败：编码器 $encoderName 找不到可用的 NVIDIA NVENC 设备。'
          '当前电脑或显卡驱动不支持该硬件编码，请改选 H.264，或安装/启用支持 $codecLabel 的显卡驱动后重试。';
    }
    if (lower.contains('unknown encoder')) {
      return '$codecLabel 编码失败：当前 ffmpeg.exe 不支持编码器 $encoderName，'
          '请重新发布程序或更换包含该编码器的 ffmpeg.exe。';
    }
    if (lower.contains('error while opening encoder')) {
      return '$codecLabel 编码失败：编码器 $encoderName 无法启动。'
          '${firstLine.isEmpty ? '' : 'FFmpeg 提示：$firstLine'}';
    }
    return trimmed.isEmpty ? '$codecLabel 编码失败：FFmpeg 没有返回错误详情。' : trimmed;
  }

  static Future<void> _cleanupFailedExport({
    required String videoPath,
    required String subtitlePath,
  }) async {
    await _deleteFileIfExists(videoPath);
    await _deleteFileIfExists(subtitlePath);
  }

  static Future<void> _deleteFileIfExists(String filePath) async {
    final normalized = filePath.trim();
    if (normalized.isEmpty) {
      return;
    }
    try {
      final file = File(normalized);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Failed export cleanup is best effort; the original export error wins.
    }
  }

  static List<String> _selectEncoderCandidates(
    RecordingCodec codec,
    String encodersOutput,
  ) {
    return RecordingExportUtils.selectEncoderCandidates(
      codec == RecordingCodec.h265 ? 'h265' : 'h264',
      encodersOutput,
    );
  }

  static Future<String?> _resolveFfmpegExecutable() async {
    final candidate = bundledFfmpegPath();
    if (!await File(candidate).exists()) {
      return null;
    }
    try {
      final result = await _runProcess(
        candidate,
        const ['-version'],
        timeout: const Duration(seconds: 5),
      );
      return result.exitCode == 0 ? candidate : null;
    } catch (_) {
      return null;
    }
  }

  static Future<_ProcessResultText> _runProcess(
    String executable,
    List<String> args, {
    required Duration timeout,
  }) async {
    final process = await Process.start(executable, args, runInShell: false);
    final stdout = StringBuffer();
    final stderr = StringBuffer();
    final stdoutDone =
        process.stdout.transform(utf8.decoder).listen(stdout.write).asFuture();
    final stderrDone =
        process.stderr.transform(utf8.decoder).listen(stderr.write).asFuture();
    final exitCode = await process.exitCode.timeout(timeout, onTimeout: () {
      process.kill(ProcessSignal.sigterm);
      return -1;
    });
    await Future.wait([stdoutDone, stderrDone]);
    return _ProcessResultText(
      exitCode: exitCode,
      stdout: stdout.toString(),
      stderr: stderr.toString(),
    );
  }

  static _BitrateProfile _bitrateProfile(
    RecordingResolution resolution,
    RecordingCodec codec,
  ) {
    final profile = RecordingExportUtils.bitrateProfile(
      resolution.id,
      codec == RecordingCodec.h265 ? 'h265' : 'h264',
    );
    return _BitrateProfile(profile.targetKbps, profile.maxKbps);
  }

  static Future<String> _availableOutputBaseName({
    required Directory directory,
    required Article article,
    required StorySeries? series,
  }) async {
    final now = DateTime.now();
    final safeBase = _outputBaseName(
      seriesTitle: series?.title ?? '',
      articleTitle: article.title,
      now: now,
    );
    var candidate = safeBase;
    var suffix = 2;
    while (await File(path_lib.join(directory.path, '$candidate.mp4'))
            .exists() ||
        await File(path_lib.join(directory.path, '$candidate.srt')).exists()) {
      candidate = '$safeBase-$suffix';
      suffix += 1;
    }
    return candidate;
  }

  static String _outputBaseName({
    required String seriesTitle,
    required String articleTitle,
    required DateTime now,
  }) {
    final stamp =
        '${now.year}${_two(now.month)}${_two(now.day)}-${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
    final raw = [
      if (seriesTitle.trim().isNotEmpty) seriesTitle,
      articleTitle,
      stamp,
    ].join(' - ');
    return _sanitizeFileName(raw);
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String _sanitizeFileName(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[<>:"/\\|?*]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.length <= 160) {
      return cleaned.isEmpty ? 'Tomato Recording' : cleaned;
    }
    return cleaned.substring(0, 160).trim();
  }

  static String _ffmpegConcatPath(String path) =>
      path.replaceAll(r'\', '/').replaceAll("'", r"'\''");

  static String _srtForTimeline(_RecordingTimeline timeline) {
    return RecordingExportUtils.srtForCues(
      timeline.segments
          .map(
            (segment) => RecordingSubtitleCue(
              startMs: segment.sentenceStartMs,
              endMs: segment.sentenceEndMs,
              english: segment.item.english,
              chinese: segment.item.chinese,
            ),
          )
          .toList(growable: false),
    );
  }

  static PictureBookPage? _pageForSentence(
    List<PictureBookPage> pages,
    int sentenceIndex,
  ) {
    for (final page in pages) {
      if (sentenceIndex >= page.sentenceStartIndex &&
          sentenceIndex <= page.sentenceEndIndex) {
        return page;
      }
    }
    if (pages.isEmpty) {
      return null;
    }
    return pages.lastWhere(
      (page) => page.sentenceStartIndex <= sentenceIndex,
      orElse: () => pages.first,
    );
  }

  @visibleForTesting
  static Map<String, dynamic> normalizeSettingsForTest(
    Map<String, String> settings,
  ) =>
      _normalizeSettings(settings);

  @visibleForTesting
  static int estimateMp3DurationMsForTest(Uint8List bytes) =>
      RecordingExportUtils.estimateMp3DurationMs(bytes);

  @visibleForTesting
  static String srtForTest(List<Map<String, dynamic>> rows) {
    final segments = rows
        .map(
          (row) => _RecordingTimelineSegment(
            item: _RecordingSentenceItem(
              index: row['index'] as int? ?? 0,
              english: row['english']?.toString() ?? '',
              chinese: row['chinese']?.toString() ?? '',
              pageIndex: row['pageIndex'] as int? ?? 0,
            ),
            sentenceStartMs: row['startMs'] as int? ?? 0,
            englishStartMs: row['startMs'] as int? ?? 0,
            englishEndMs: row['endMs'] as int? ?? 0,
            chineseStartMs: row['endMs'] as int? ?? 0,
            chineseEndMs: row['endMs'] as int? ?? 0,
            sentenceEndMs: row['endMs'] as int? ?? 0,
          ),
        )
        .toList(growable: false);
    return _srtForTimeline(_RecordingTimeline(
      segments: segments,
      durationMs: segments.isEmpty ? 0 : segments.last.sentenceEndMs,
      pageChangeTimesMs: const [],
    ));
  }

  @visibleForTesting
  static List<Map<String, Object?>> songTimelineRowsForTest(
    SongSubtitleTimeline timeline,
  ) {
    final items = [
      for (final cue in timeline.cues)
        _RecordingSentenceItem(
          index: cue.lineIndex,
          english: cue.english,
          chinese: cue.chinese,
          pageIndex: math.max(0, cue.lineIndex),
        ),
    ];
    final built = _buildSongTimeline(_PreparedSongRecordingAssets(
      article: Article(
        id: timeline.articleId,
        title: '',
        content: '',
        sentences: const [],
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
      series: null,
      pages: const [],
      pageImageBytes: const {},
      items: items,
      timeline: timeline,
    ));
    return [
      for (final segment in built.segments)
        {
          'index': segment.item.index,
          'english': segment.item.english,
          'chinese': segment.item.chinese,
          'pageIndex': segment.item.pageIndex,
          'startMs': segment.sentenceStartMs,
          'endMs': segment.sentenceEndMs,
        },
    ];
  }

  @visibleForTesting
  static List<Map<String, Object?>> hybridRenderPartsForTest({
    required List<Map<String, Object?>> segments,
    required String transition,
  }) {
    final timelineSegments = <_RecordingTimelineSegment>[];
    var durationMs = 0;
    for (var i = 0; i < segments.length; i += 1) {
      final segment = segments[i];
      final startMs = ((segment['startMs'] ?? 0) as num).toInt();
      final endMs = ((segment['endMs'] ?? startMs) as num).toInt();
      final pageIndex = ((segment['pageIndex'] ?? 0) as num).toInt();
      durationMs = math.max(durationMs, endMs);
      timelineSegments.add(_RecordingTimelineSegment(
        item: _RecordingSentenceItem(
          index: i,
          english: 'line $i',
          chinese: '',
          pageIndex: pageIndex,
        ),
        sentenceStartMs: startMs,
        englishStartMs: startMs,
        englishEndMs: endMs,
        chineseStartMs: startMs,
        chineseEndMs: endMs,
        sentenceEndMs: endMs,
      ));
    }
    final parts = _hybridRenderParts(
      timeline: _RecordingTimeline(
        segments: timelineSegments,
        durationMs: durationMs,
        pageChangeTimesMs: const [],
      ),
      transition: RecordingPageTransition.parse(transition),
    );
    return [
      for (final part in parts)
        {
          'startMs': part.startMs,
          'endMs': part.endMs,
          'durationMs': part.durationMs,
          'isTransition': part.isTransition,
        },
    ];
  }

  @visibleForTesting
  static String outputBaseNameForTest({
    required String articleTitle,
    String seriesTitle = '',
    DateTime? now,
  }) =>
      _outputBaseName(
        seriesTitle: seriesTitle,
        articleTitle: articleTitle,
        now: now ?? DateTime(2026, 1, 2, 3, 4, 5),
      );

  @visibleForTesting
  static Map<String, int> bitrateProfileForTest(
    String resolution,
    String codec,
  ) {
    final profile = _bitrateProfile(
      RecordingResolution.parse(resolution),
      _parseCodec(codec),
    );
    return {
      'targetKbps': profile.targetKbps,
      'maxKbps': profile.maxKbps,
    };
  }

  @visibleForTesting
  static String? selectEncoderForTest(String codec, String encodersOutput) =>
      RecordingExportUtils.selectEncoder(codec, encodersOutput);
}

int? _jsonInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value.trim());
  }
  return null;
}

String _videoIdForPath(String videoPath) {
  final key = _videoPathKey(videoPath);
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash = (hash ^ unit) & 0xffffffff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return 'video_${hash.toRadixString(16).padLeft(8, '0')}';
}

String _videoPathKey(String videoPath) =>
    path_lib.normalize(File(videoPath).absolute.path).toLowerCase();

DateTime _videoCreatedAt(RecordingVideoVersion version) =>
    DateTime.tryParse(version.createdAt) ??
    _createdAtFromVideoPath(version.videoPath) ??
    DateTime.fromMillisecondsSinceEpoch(0);

DateTime? _createdAtFromVideoPath(String videoPath) {
  final name = path_lib.basenameWithoutExtension(videoPath);
  final match = RegExp(r'(\d{8}-\d{6})(?:-\d+)?$').firstMatch(name);
  return _dateTimeFromStamp(match?.group(1));
}

DateTime? _dateTimeFromStamp(String? stamp) {
  if (stamp == null || stamp.length != 15) {
    return null;
  }
  try {
    final year = int.parse(stamp.substring(0, 4));
    final month = int.parse(stamp.substring(4, 6));
    final day = int.parse(stamp.substring(6, 8));
    final hour = int.parse(stamp.substring(9, 11));
    final minute = int.parse(stamp.substring(11, 13));
    final second = int.parse(stamp.substring(13, 15));
    return DateTime(year, month, day, hour, minute, second);
  } catch (_) {
    return null;
  }
}

class _RecordingArticleContext {
  const _RecordingArticleContext(this.article, this.series);

  final Article? article;
  final StorySeries? series;
}

class _PreparedRecordingAssets {
  const _PreparedRecordingAssets({
    required this.article,
    required this.series,
    required this.pages,
    required this.pageImageBytes,
    required this.items,
    required this.audioClips,
    required this.requiredEnglish,
    required this.readyEnglish,
    required this.requiredChinese,
    required this.readyChinese,
  });

  factory _PreparedRecordingAssets.empty(int articleId) =>
      _PreparedRecordingAssets(
        article: Article(
          id: articleId,
          title: '',
          content: '',
          sentences: const [],
          createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        ),
        series: null,
        pages: const [],
        pageImageBytes: const {},
        items: const [],
        audioClips: const [],
        requiredEnglish: 0,
        readyEnglish: 0,
        requiredChinese: 0,
        readyChinese: 0,
      );

  final Article article;
  final StorySeries? series;
  final List<PictureBookPage> pages;
  final Map<String, Uint8List> pageImageBytes;
  final List<_RecordingSentenceItem> items;
  final List<_RecordingAudioClip> audioClips;
  final int requiredEnglish;
  final int readyEnglish;
  final int requiredChinese;
  final int readyChinese;
}

class _PreparedSongRecordingAssets {
  const _PreparedSongRecordingAssets({
    required this.article,
    required this.series,
    required this.pages,
    required this.pageImageBytes,
    required this.items,
    required this.timeline,
  });

  factory _PreparedSongRecordingAssets.empty(int articleId) =>
      _PreparedSongRecordingAssets(
        article: Article(
          id: articleId,
          title: '',
          content: '',
          sentences: const [],
          createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        ),
        series: null,
        pages: const [],
        pageImageBytes: const {},
        items: const [],
        timeline: const SongSubtitleTimeline(
          version: 1,
          articleId: 0,
          audioHash: '',
          lyricsHash: '',
          durationMs: 0,
          source: 'suno',
          cues: [],
        ),
      );

  final Article article;
  final StorySeries? series;
  final List<PictureBookPage> pages;
  final Map<String, Uint8List> pageImageBytes;
  final List<_RecordingSentenceItem> items;
  final SongSubtitleTimeline timeline;

  _PreparedRecordingAssets toRecordingAssets() => _PreparedRecordingAssets(
        article: article,
        series: series,
        pages: pages,
        pageImageBytes: pageImageBytes,
        items: items,
        audioClips: const [],
        requiredEnglish: timeline.cues.length,
        readyEnglish: timeline.cues.length,
        requiredChinese: 0,
        readyChinese: 0,
      );
}

class _RecordingSentenceItem {
  const _RecordingSentenceItem({
    required this.index,
    required this.english,
    required this.chinese,
    required this.pageIndex,
  });

  final int index;
  final String english;
  final String chinese;
  final int pageIndex;
}

class _RecordingAudioClip {
  const _RecordingAudioClip({
    required this.sentenceIndex,
    required this.part,
    required this.text,
    required this.filePath,
    required this.durationMs,
  });

  factory _RecordingAudioClip.empty(int sentenceIndex, String part) =>
      _RecordingAudioClip(
        sentenceIndex: sentenceIndex,
        part: part,
        text: '',
        filePath: '',
        durationMs: 0,
      );

  final int sentenceIndex;
  final String part;
  final String text;
  final String filePath;
  final int durationMs;
}

class _RecordingTimeline {
  const _RecordingTimeline({
    required this.segments,
    required this.durationMs,
    required this.pageChangeTimesMs,
  });

  final List<_RecordingTimelineSegment> segments;
  final int durationMs;
  final List<int> pageChangeTimesMs;

  _RecordingTimelineSegment segmentAt(int timeMs) {
    if (segments.isEmpty) {
      throw const RecordingExportException('时间轴为空');
    }
    if (timeMs < segments.first.sentenceStartMs) {
      return segments.first;
    }
    for (final segment in segments) {
      if (timeMs >= segment.sentenceStartMs && timeMs < segment.sentenceEndMs) {
        return segment;
      }
    }
    return segments.last;
  }
}

class _RecordingTimelineSegment {
  const _RecordingTimelineSegment({
    required this.item,
    required this.sentenceStartMs,
    required this.englishStartMs,
    required this.englishEndMs,
    required this.chineseStartMs,
    required this.chineseEndMs,
    required this.sentenceEndMs,
  });

  final _RecordingSentenceItem item;
  final int sentenceStartMs;
  final int englishStartMs;
  final int englishEndMs;
  final int chineseStartMs;
  final int chineseEndMs;
  final int sentenceEndMs;
}

class _PageTransition {
  const _PageTransition({
    required this.fromPageIndex,
    required this.toPageIndex,
    required this.progress,
  });

  final int fromPageIndex;
  final int toPageIndex;
  final double progress;
}

class _TransitionWindow {
  const _TransitionWindow({
    required this.startMs,
    required this.endMs,
    required this.fromPageIndex,
    required this.toPageIndex,
  });

  final int startMs;
  final int endMs;
  final int fromPageIndex;
  final int toPageIndex;
}

class _HybridRenderPart {
  const _HybridRenderPart._({
    required this.startMs,
    required this.endMs,
    required this.isTransition,
  });

  const _HybridRenderPart.static({
    required int startMs,
    required int endMs,
  }) : this._(
          startMs: startMs,
          endMs: endMs,
          isTransition: false,
        );

  const _HybridRenderPart.transition({
    required int startMs,
    required int endMs,
  }) : this._(
          startMs: startMs,
          endMs: endMs,
          isTransition: true,
        );

  final int startMs;
  final int endMs;
  final bool isTransition;

  int get durationMs => math.max(0, endMs - startMs);
}

class _RenderedVideoPart {
  const _RenderedVideoPart({
    required this.path,
    required this.durationMs,
  });

  final String path;
  final double durationMs;
}

class _BitrateProfile {
  const _BitrateProfile(this.targetKbps, this.maxKbps);

  final int targetKbps;
  final int maxKbps;
}

class _ResolvedEncoder {
  const _ResolvedEncoder({
    required this.available,
    required this.ffmpegExecutable,
    required this.encoderName,
    required this.reason,
    required this.softwareFallback,
  });

  const _ResolvedEncoder.unavailable(this.reason)
      : available = false,
        ffmpegExecutable = '',
        encoderName = '',
        softwareFallback = false;

  final bool available;
  final String ffmpegExecutable;
  final String encoderName;
  final String reason;
  final bool softwareFallback;
}

class _ProcessResultText {
  const _ProcessResultText({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}
