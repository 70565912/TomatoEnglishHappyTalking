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
  slide;

  static RecordingPageTransition parse(String value) {
    final normalized = value.trim();
    return RecordingPageTransition.values.firstWhere(
      (item) => item.name == normalized,
      orElse: () => RecordingPageTransition.none,
    );
  }
}

class RecordingExportRequest {
  const RecordingExportRequest({
    required this.articleId,
    required this.mode,
    required this.codec,
    required this.resolution,
    required this.pageTransition,
    this.fps = 25,
    this.subtitleTranslations = const <int, String>{},
  });

  final int articleId;
  final String mode;
  final RecordingCodec codec;
  final RecordingResolution resolution;
  final RecordingPageTransition pageTransition;
  final int fps;
  final Map<int, String> subtitleTranslations;

  bool get bilingual => mode == 'bilingual';
}

class SongRecordingExportRequest {
  const SongRecordingExportRequest({
    required this.articleId,
    required this.audioPath,
    required this.timelinePath,
    required this.codec,
    required this.resolution,
    required this.pageTransition,
    this.fps = 25,
  });

  final int articleId;
  final String audioPath;
  final String timelinePath;
  final RecordingCodec codec;
  final RecordingResolution resolution;
  final RecordingPageTransition pageTransition;
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

  static Future<Map<String, dynamic>> settingsPayload() async {
    final settings = await AppConfig.recordingSettings;
    return _normalizeSettings(settings);
  }

  static Future<Map<String, dynamic>> saveSettings({
    required String codec,
    required String resolution,
    required String pageTransition,
  }) async {
    final normalized = _normalizeSettings({
      'codec': codec,
      'resolution': resolution,
      'pageTransition': pageTransition,
    });
    await AppConfig.saveRecordingSettings(
      codec: normalized['codec']! as String,
      resolution: normalized['resolution']! as String,
      pageTransition: normalized['pageTransition']! as String,
    );
    return normalized;
  }

  static Future<RecordingReadiness> readiness(
    RecordingExportRequest request,
  ) async {
    final reasons = <String>[];
    final assets = await _prepareAssets(
      request,
      requireMemoryAudio: true,
      collectAudioBytes: false,
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
      requireMemoryAudio: true,
      collectAudioBytes: true,
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
    final subtitlePath = path_lib.join(outputDirectory.path, '$baseName.srt');
    final frameCount = (timeline.durationMs / (1000 / request.fps))
        .ceil()
        .clamp(1, 1 << 31)
        .toInt();
    final tempDir = await Directory.systemTemp.createTemp(
      'tomato_recording_${request.articleId}_',
    );

    try {
      token.throwIfCancelled();
      await File(subtitlePath).writeAsString(
        _srtForTimeline(timeline),
        encoding: utf8,
      );
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
        await _renderFrames(
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
          progress: 0.78,
          completedFrames: frameCount,
          totalFrames: frameCount,
          message: '正在编码 MP4',
        ));

        await _runFfmpegEncode(
          ffmpegPath: encoder.ffmpegExecutable,
          encoderName: encoder.encoderName,
          request: request,
          frameDirectory: tempDir,
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
      return RecordingExportResult(
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
    final subtitlePath = path_lib.join(outputDirectory.path, '$baseName.srt');
    final frameCount = (timeline.durationMs / (1000 / request.fps))
        .ceil()
        .clamp(1, 1 << 31)
        .toInt();
    final tempDir = await Directory.systemTemp.createTemp(
      'tomato_song_recording_${request.articleId}_',
    );

    try {
      token.throwIfCancelled();
      await File(subtitlePath).writeAsString(
        SongSubtitleTimelineService.srtForTimeline(assets.timeline),
        encoding: utf8,
      );
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
          fps: request.fps,
        );
        await _renderFrames(
          request: recordingRequest,
          assets: assets.toRecordingAssets(),
          timeline: timeline,
          frameCount: frameCount,
          outputDirectory: tempDir,
          cancelToken: token,
          onProgress: onProgress,
        );
        await _runFfmpegEncode(
          ffmpegPath: encoder.ffmpegExecutable,
          encoderName: encoder.encoderName,
          request: recordingRequest,
          frameDirectory: tempDir,
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
      return RecordingExportResult(
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
    return {
      'codec': codec,
      'resolution': resolution,
      'pageTransition': transition,
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

  static Future<_PreparedRecordingAssets> _prepareAssets(
    RecordingExportRequest request, {
    required bool requireMemoryAudio,
    required bool collectAudioBytes,
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
      final englishHandle = await _memoryHandleOrNull(
        text: english,
        voiceType: TtsService.defaultVoiceType,
        preferRequestedVoice: false,
        articleId: request.articleId,
        requireMemory: requireMemoryAudio,
      );
      if (englishHandle == null) {
        reasons.add('第 ${index + 1} 句英文音频尚未完成内存预加载');
      } else {
        readyEnglish += 1;
        if (collectAudioBytes) {
          audioClips.add(_RecordingAudioClip(
            sentenceIndex: index,
            part: 'english',
            text: english,
            filePath: englishHandle.filePath,
            bytes: englishHandle.bytes,
            durationMs:
                RecordingExportUtils.estimateMp3DurationMs(englishHandle.bytes),
          ));
        }
      }

      if (request.bilingual && chinese.trim().isNotEmpty) {
        requiredChinese += 1;
        final chineseHandle = await _memoryHandleOrNull(
          text: chinese,
          voiceType: _chineseVoiceType,
          preferRequestedVoice: true,
          articleId: request.articleId,
          requireMemory: requireMemoryAudio,
        );
        if (chineseHandle == null) {
          reasons.add('第 ${index + 1} 句中文音频尚未完成内存预加载');
        } else {
          readyChinese += 1;
          if (collectAudioBytes) {
            audioClips.add(_RecordingAudioClip(
              sentenceIndex: index,
              part: 'chinese',
              text: chinese,
              filePath: chineseHandle.filePath,
              bytes: chineseHandle.bytes,
              durationMs: RecordingExportUtils.estimateMp3DurationMs(
                chineseHandle.bytes,
              ),
            ));
          }
        }
      }
    }

    if (collectAudioBytes) {
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
      timeline = await SongSubtitleTimelineService.readTimeline(
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

  static Future<TtsMemoryHandle?> _memoryHandleOrNull({
    required String text,
    required String voiceType,
    required bool preferRequestedVoice,
    required int articleId,
    required bool requireMemory,
  }) async {
    try {
      if (requireMemory) {
        return await TtsMemoryCacheService.requireInMemory(
          text: text,
          voiceType: voiceType,
          preferRequestedVoice: preferRequestedVoice,
          articleId: articleId,
          cachePurpose: 'listening_tts',
        );
      }
      return await TtsMemoryCacheService.load(
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
      final chinese = request.bilingual
          ? clips.firstWhere(
              (clip) => clip.part == 'chinese',
              orElse: () => _RecordingAudioClip.empty(item.index, 'chinese'),
            )
          : _RecordingAudioClip.empty(item.index, 'chinese');
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
    final itemByLine = {
      for (final item in assets.items) item.index: item,
    };
    final segments = <_RecordingTimelineSegment>[];
    for (final cue in assets.timeline.cues) {
      final item = itemByLine[cue.lineIndex] ??
          _RecordingSentenceItem(
            index: cue.lineIndex,
            english: cue.english,
            chinese: cue.chinese,
            pageIndex: 0,
          );
      segments.add(_RecordingTimelineSegment(
        item: item,
        sentenceStartMs: cue.startMs,
        englishStartMs: cue.startMs,
        englishEndMs: cue.endMs,
        chineseStartMs: cue.startMs,
        chineseEndMs: cue.endMs,
        sentenceEndMs: cue.endMs,
      ));
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

  static Future<void> _renderFrames({
    required RecordingExportRequest request,
    required _PreparedRecordingAssets assets,
    required _RecordingTimeline timeline,
    required int frameCount,
    required Directory outputDirectory,
    required RecordingCancelToken cancelToken,
    void Function(RecordingExportProgress progress)? onProgress,
  }) async {
    final images = <int, ui.Image>{};
    try {
      for (final page in assets.pages) {
        final imagePath = page.imagePath?.trim() ?? '';
        final bytes = assets.pageImageBytes[imagePath];
        if (bytes == null || bytes.isEmpty) {
          continue;
        }
        images[page.pageIndex] = await _decodeImage(bytes);
      }
      for (var frameIndex = 0; frameIndex < frameCount; frameIndex += 1) {
        cancelToken.throwIfCancelled();
        final timeMs = math.min(
          timeline.durationMs - 1,
          (frameIndex * 1000 / request.fps).round(),
        );
        final bitmap = await _renderFrameBitmap(
          request: request,
          timeline: timeline,
          images: images,
          timeMs: timeMs,
        );
        final framePath = path_lib.join(
          outputDirectory.path,
          'frame_${frameIndex.toString().padLeft(6, '0')}.bmp',
        );
        await File(framePath).writeAsBytes(bitmap, flush: false);
        if (frameIndex % request.fps == 0 || frameIndex == frameCount - 1) {
          onProgress?.call(RecordingExportProgress(
            articleId: request.articleId,
            phase: 'rendering',
            progress: 0.02 + 0.74 * ((frameIndex + 1) / frameCount),
            completedFrames: frameIndex + 1,
            totalFrames: frameCount,
            message: '正在渲染视频帧',
          ));
        }
      }
    } finally {
      for (final image in images.values) {
        image.dispose();
      }
    }
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

  static Paint _opacityPaint(double opacity) => Paint()
    ..colorFilter = ui.ColorFilter.mode(
      Color.fromRGBO(255, 255, 255, opacity.clamp(0, 1).toDouble()),
      BlendMode.modulate,
    );

  static _PageTransition? _transitionAt({
    required _RecordingTimeline timeline,
    required int timeMs,
    required int currentPageIndex,
    required RecordingPageTransition transition,
  }) {
    if (transition == RecordingPageTransition.none) {
      return null;
    }
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
      final start = changeMs - before;
      final end = changeMs + after;
      if (end <= start || timeMs < start || timeMs > end) {
        continue;
      }
      return _PageTransition(
        fromPageIndex: previous.item.pageIndex,
        toPageIndex: next.item.pageIndex,
        progress: (timeMs - start) / (end - start),
      );
    }
    return null;
  }

  static Future<void> _runFfmpegEncode({
    required String ffmpegPath,
    required String encoderName,
    required RecordingExportRequest request,
    required Directory frameDirectory,
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
      '-framerate',
      request.fps.toString(),
      '-i',
      path_lib.join(frameDirectory.path, 'frame_%06d.bmp'),
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
        progress: 0.78 + 0.2 * (frame / math.max(1, frameCount)),
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
        error.isEmpty ? 'FFmpeg 编码失败（exit=$exitCode）' : error,
      );
    }
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
        error.isEmpty ? 'FFmpeg 编码失败（exit=$exitCode）' : error,
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
    final encoder = _selectEncoder(codec, probe.stdout);
    if (encoder == null) {
      return _ResolvedEncoder.unavailable(
        codec == RecordingCodec.h265
            ? '当前 FFmpeg 不支持 H.265/HEVC 编码'
            : '当前 FFmpeg 不支持 H.264 编码',
      );
    }
    return _ResolvedEncoder(
      available: true,
      ffmpegExecutable: executable,
      encoderName: encoder,
      reason: '',
      softwareFallback: encoder == 'libx264' || encoder == 'libx265',
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

  static String? _selectEncoder(RecordingCodec codec, String encodersOutput) {
    return RecordingExportUtils.selectEncoder(
      codec == RecordingCodec.h265 ? 'h265' : 'h264',
      encodersOutput,
    );
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

const _chineseVoiceType = 'zh_female_xiaoxue_uranus_bigtts';

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
    required this.bytes,
    required this.durationMs,
  });

  factory _RecordingAudioClip.empty(int sentenceIndex, String part) =>
      _RecordingAudioClip(
        sentenceIndex: sentenceIndex,
        part: part,
        text: '',
        filePath: '',
        bytes: Uint8List(0),
        durationMs: 0,
      );

  final int sentenceIndex;
  final String part;
  final String text;
  final String filePath;
  final Uint8List bytes;
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
