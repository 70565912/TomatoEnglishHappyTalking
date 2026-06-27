import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as path_lib;

import '../core/config/app_config.dart';
import 'api_cache_service.dart';
import 'recording_export_service.dart';
import 'recording_export_utils.dart';
import 'streaming_asr_service.dart';

class SongSubtitleTimelineException implements Exception {
  const SongSubtitleTimelineException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

class SongSubtitleCue {
  const SongSubtitleCue({
    required this.lineIndex,
    required this.startMs,
    required this.endMs,
    required this.english,
    this.chinese = '',
    this.confidence = 0,
    this.method = 'fallback',
  });

  final int lineIndex;
  final int startMs;
  final int endMs;
  final String english;
  final String chinese;
  final double confidence;
  final String method;

  Map<String, dynamic> toJson() => {
        'lineIndex': lineIndex,
        'startMs': startMs,
        'endMs': endMs,
        'english': english,
        'chinese': chinese,
        'confidence': confidence,
        'method': method,
      };

  static SongSubtitleCue fromJson(Object? value) {
    final map = value is Map ? Map<String, dynamic>.from(value) : {};
    return SongSubtitleCue(
      lineIndex: (map['lineIndex'] as num?)?.toInt() ?? 0,
      startMs: (map['startMs'] as num?)?.toInt() ?? 0,
      endMs: (map['endMs'] as num?)?.toInt() ?? 0,
      english: map['english']?.toString() ?? '',
      chinese: map['chinese']?.toString() ?? '',
      confidence: (map['confidence'] as num?)?.toDouble() ?? 0,
      method: map['method']?.toString() ?? 'fallback',
    );
  }
}

class SongSubtitleTimeline {
  const SongSubtitleTimeline({
    required this.version,
    this.alignmentVersion = 0,
    required this.articleId,
    required this.audioHash,
    required this.lyricsHash,
    required this.durationMs,
    required this.source,
    required this.cues,
    this.warnings = const [],
  });

  final int version;
  final int alignmentVersion;
  final int articleId;
  final String audioHash;
  final String lyricsHash;
  final int durationMs;
  final String source;
  final List<SongSubtitleCue> cues;
  final List<String> warnings;

  double get confidence {
    if (cues.isEmpty) {
      return 0;
    }
    final total =
        cues.fold<double>(0, (sum, cue) => sum + cue.confidence.clamp(0, 1));
    return total / cues.length;
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'alignmentVersion': alignmentVersion,
        'articleId': articleId,
        'audioHash': audioHash,
        'lyricsHash': lyricsHash,
        'durationMs': durationMs,
        'source': source,
        'cues': cues.map((cue) => cue.toJson()).toList(),
        'warnings': warnings,
        'confidence': confidence,
      };

  static SongSubtitleTimeline fromJson(Object? value) {
    final map = value is Map ? Map<String, dynamic>.from(value) : {};
    final rawCues = map['cues'];
    return SongSubtitleTimeline(
      version: (map['version'] as num?)?.toInt() ?? 1,
      alignmentVersion: (map['alignmentVersion'] as num?)?.toInt() ?? 0,
      articleId: (map['articleId'] as num?)?.toInt() ?? 0,
      audioHash: map['audioHash']?.toString() ?? '',
      lyricsHash: map['lyricsHash']?.toString() ?? '',
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
      source: map['source']?.toString() ?? 'suno',
      cues: rawCues is List
          ? rawCues.map(SongSubtitleCue.fromJson).toList(growable: false)
          : const [],
      warnings: (map['warnings'] as List?)
              ?.map((value) => value.toString())
              .where((value) => value.trim().isNotEmpty)
              .toList(growable: false) ??
          const [],
    );
  }
}

class SongSubtitleTimelineGenerationResult {
  const SongSubtitleTimelineGenerationResult({
    required this.timeline,
    required this.timelinePath,
    required this.cacheKey,
    required this.lyricsHash,
    required this.fromCache,
  });

  final SongSubtitleTimeline timeline;
  final String timelinePath;
  final String cacheKey;
  final String lyricsHash;
  final bool fromCache;
}

class SongAsrDiagnosticResult {
  const SongAsrDiagnosticResult({
    required this.outputPath,
    required this.outputDirectory,
    required this.payload,
  });

  final String outputPath;
  final String outputDirectory;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => {
        'outputPath': outputPath,
        'outputDirectory': outputDirectory,
        'payload': payload,
      };
}

class SongSubtitleTimelineService {
  static const purpose = 'suno_song_subtitle_timeline_v1';
  static const alignmentVersion = 10;
  static const staleTimelineMessage = '歌曲字幕时间线版本过旧，请重新生成歌曲字幕';
  static const _matchedLineLeadInMs = 180;
  static const _matchedLineTailMs = 320;
  static const _cueGapMs = 80;

  const SongSubtitleTimelineService._();

  static Future<SongSubtitleTimelineGenerationResult> generate({
    required int articleId,
    required String audioPath,
    required List<String> lyricLines,
    required Map<int, String> translations,
    String source = 'suno',
  }) async {
    final audioFile = File(audioPath);
    if (!await audioFile.exists()) {
      throw SongSubtitleTimelineException('歌曲音频文件不存在：$audioPath');
    }
    final lines = _cleanLines(lyricLines);
    if (lines.isEmpty) {
      throw const SongSubtitleTimelineException('没有可用于生成字幕的英文歌词');
    }

    final audioBytes = await audioFile.readAsBytes();
    if (audioBytes.isEmpty) {
      throw const SongSubtitleTimelineException('歌曲音频文件为空');
    }
    final audioHash = await ApiCacheService.hashBytes(audioBytes);
    final lyricsText = lines.join('\n');
    final lyricsHash = await ApiCacheService.hashUtf8(lyricsText);
    final asrProvider = await AppConfig.aiProvider;
    final originalMimeType = _audioMimeTypeForPath(audioPath);
    final originalFormat = _audioFormatFromMimeType(originalMimeType);
    final useOriginalAudio = _providerSupportsOriginalAudio(
      provider: asrProvider,
      audioFormat: originalFormat,
    );
    final asrMimeType = useOriginalAudio ? originalMimeType : 'audio/wav';
    final asrFormat = useOriginalAudio ? originalFormat : 'wav';
    final request = {
      'service': asrProvider == AppConfig.aiProviderAliyunBailian
          ? 'qwen_asr'
          : 'bigasr',
      'provider': asrProvider,
      'purpose': purpose,
      'audioHash': audioHash,
      'lyricsHash': lyricsHash,
      'audioFormat': asrFormat,
      'audioMimeType': asrMimeType,
      if (!useOriginalAudio) 'sampleRate': 16000,
      'language': 'en-US',
      'showUtterances': asrProvider != AppConfig.aiProviderAliyunBailian,
      'alignmentVersion': alignmentVersion,
    };
    final cacheKey = await ApiCacheService.keyForJson(
        'suno_song_subtitle_timeline', request);
    final cachedPath = await ApiCacheService.getFilePath(
      cacheKey,
      articleId: articleId,
      purpose: purpose,
    );
    if (cachedPath != null && cachedPath.trim().isNotEmpty) {
      final cachedTimeline = SongSubtitleTimeline.fromJson(
        jsonDecode(await File(cachedPath).readAsString()),
      );
      if (isCurrentTimeline(cachedTimeline)) {
        validateTimelineCompleteness(cachedTimeline, lines.length);
        return SongSubtitleTimelineGenerationResult(
          timeline: cachedTimeline,
          timelinePath: cachedPath,
          cacheKey: cacheKey,
          lyricsHash: lyricsHash,
          fromCache: true,
        );
      }
    }

    final asrBytes =
        useOriginalAudio ? audioBytes : await _wav16kMonoBytes(audioPath);
    final asr = await StreamingAsrService.recognizeWithTimeline(
      audioBytes: asrBytes,
      audioMimeType: asrMimeType,
    );
    final estimatedDuration = _estimateDurationMs(
      audioBytes: audioBytes,
      asr: asr,
    );
    final timeline = buildTimeline(
      articleId: articleId,
      audioHash: audioHash,
      lyricsHash: lyricsHash,
      durationMs: estimatedDuration,
      source: source,
      lyricLines: lines,
      translations: translations,
      words: asr.words,
    );
    validateTimelineCompleteness(timeline, lines.length);
    final timelineBytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(timeline.toJson()),
    );
    final path = await ApiCacheService.putFileBytes(
      cacheKey: cacheKey,
      kind: 'song_subtitle_timeline',
      purpose: purpose,
      request: request,
      bytes: timelineBytes,
      subdirectory: 'song-subtitle-timelines',
      extension: 'json',
      contentType: 'application/json',
      articleId: articleId,
    );
    return SongSubtitleTimelineGenerationResult(
      timeline: timeline,
      timelinePath: path,
      cacheKey: cacheKey,
      lyricsHash: lyricsHash,
      fromCache: false,
    );
  }

  static Future<SongSubtitleTimelineGenerationResult> generateFromAsrSnapshot({
    required int articleId,
    required String audioPath,
    required List<String> lyricLines,
    required Map<int, String> translations,
    required String asrSnapshotPath,
    String source = 'suno',
  }) async {
    final audioFile = File(audioPath);
    if (!await audioFile.exists()) {
      throw SongSubtitleTimelineException('歌曲音频文件不存在：$audioPath');
    }
    final snapshotFile = File(asrSnapshotPath);
    if (!await snapshotFile.exists()) {
      throw SongSubtitleTimelineException('ASR 诊断结果文件不存在：$asrSnapshotPath');
    }
    final lines = _cleanLines(lyricLines);
    if (lines.isEmpty) {
      throw const SongSubtitleTimelineException('没有可用于生成字幕的英文歌词');
    }

    final audioBytes = await audioFile.readAsBytes();
    if (audioBytes.isEmpty) {
      throw const SongSubtitleTimelineException('歌曲音频文件为空');
    }
    final snapshotText = await snapshotFile.readAsString();
    final snapshotJson = jsonDecode(snapshotText);
    final snapshotWords = _wordsFromAsrSnapshot(snapshotJson);
    if (snapshotWords.isEmpty) {
      throw const SongSubtitleTimelineException('ASR 诊断结果没有词级时间，无法生成字幕');
    }

    final audioHash = await ApiCacheService.hashBytes(audioBytes);
    final lyricsText = lines.join('\n');
    final lyricsHash = await ApiCacheService.hashUtf8(lyricsText);
    final snapshotHash = await ApiCacheService.hashUtf8(snapshotText);
    final snapshotDurationMs = _durationFromAsrSnapshot(snapshotJson);
    final durationMs = [
      snapshotDurationMs,
      snapshotWords.last.endMs,
      RecordingExportUtils.estimateMp3DurationMs(audioBytes),
      1000,
    ].reduce(math.max);
    final request = {
      'service': 'asr_snapshot_import',
      'provider': 'diagnostic',
      'purpose': purpose,
      'audioHash': audioHash,
      'lyricsHash': lyricsHash,
      'asrSnapshotHash': snapshotHash,
      'language': 'en-US',
      'alignmentVersion': alignmentVersion,
    };
    final cacheKey = await ApiCacheService.keyForJson(
        'suno_song_subtitle_timeline', request);
    final timeline = buildTimeline(
      articleId: articleId,
      audioHash: audioHash,
      lyricsHash: lyricsHash,
      durationMs: durationMs,
      source: source,
      lyricLines: lines,
      translations: translations,
      words: snapshotWords,
    );
    validateTimelineCompleteness(timeline, lines.length);
    final path = await ApiCacheService.putFileBytes(
      cacheKey: cacheKey,
      kind: 'song_subtitle_timeline',
      purpose: purpose,
      request: request,
      bytes: utf8.encode(
        const JsonEncoder.withIndent('  ').convert(timeline.toJson()),
      ),
      subdirectory: 'song-subtitle-timelines',
      extension: 'json',
      contentType: 'application/json',
      articleId: articleId,
    );
    return SongSubtitleTimelineGenerationResult(
      timeline: timeline,
      timelinePath: path,
      cacheKey: cacheKey,
      lyricsHash: lyricsHash,
      fromCache: false,
    );
  }

  static Future<SongAsrDiagnosticResult> submitAsrDiagnostics({
    required int articleId,
    required String audioPath,
    required String versionId,
    String source = 'suno',
  }) async {
    final audioFile = File(audioPath);
    if (!await audioFile.exists()) {
      throw SongSubtitleTimelineException('歌曲音频文件不存在：$audioPath');
    }
    final audioBytes = await audioFile.readAsBytes();
    if (audioBytes.isEmpty) {
      throw const SongSubtitleTimelineException('歌曲音频文件为空');
    }

    final asrProvider = await AppConfig.aiProvider;
    final originalMimeType = _audioMimeTypeForPath(audioPath);
    final originalFormat = _audioFormatFromMimeType(originalMimeType);
    final useOriginalAudio = _providerSupportsOriginalAudio(
      provider: asrProvider,
      audioFormat: originalFormat,
    );
    final asrMimeType = useOriginalAudio ? originalMimeType : 'audio/wav';
    final asrFormat = useOriginalAudio ? originalFormat : 'wav';
    final asrBytes =
        useOriginalAudio ? audioBytes : await _wav16kMonoBytes(audioPath);
    final submittedAt = DateTime.now();
    final asr = await StreamingAsrService.recognizeWithTimeline(
      audioBytes: asrBytes,
      audioMimeType: asrMimeType,
    );
    final estimatedDuration = _estimateDurationMs(
      audioBytes: audioBytes,
      asr: asr,
    );
    final words = asr.words;
    final payload = {
      'articleId': articleId,
      'versionId': versionId,
      'source': source,
      'audioPath': audioPath,
      'audioHash': await ApiCacheService.hashBytes(audioBytes),
      'audioBytes': audioBytes.length,
      'asrProvider': asrProvider,
      'originalAudioMimeType': originalMimeType,
      'submittedAudioMimeType': asrMimeType,
      'submittedAudioFormat': asrFormat,
      if (!useOriginalAudio) 'sampleRate': 16000,
      'submittedAt': submittedAt.toIso8601String(),
      'estimatedDurationMs': estimatedDuration,
      'asrDurationMs': asr.durationMs,
      'wordCount': words.length,
      if (words.isNotEmpty) ...{
        'firstWord': words.first.toJson(),
        'lastWord': words.last.toJson(),
      },
      'words': words.map((word) => word.toJson()).toList(growable: false),
      'asr': asr.toJson(),
    };

    final directory = Directory(path_lib.join(
      RecordingExportService.programDirectory(),
      'diagnostics',
    ));
    await directory.create(recursive: true);
    final timestamp = _diagnosticTimestamp(submittedAt);
    final safeVersionId = _safeDiagnosticName(versionId);
    final outputPath = path_lib.join(
      directory.path,
      'song-asr-article-$articleId-$safeVersionId-$timestamp.json',
    );
    await File(outputPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      encoding: utf8,
    );
    return SongAsrDiagnosticResult(
      outputPath: outputPath,
      outputDirectory: directory.path,
      payload: payload,
    );
  }

  static Future<SongSubtitleTimeline> readTimeline(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw SongSubtitleTimelineException('歌曲字幕时间线文件不存在：$path');
    }
    return SongSubtitleTimeline.fromJson(jsonDecode(await file.readAsString()));
  }

  static Future<SongSubtitleTimeline> readCurrentTimeline(String path) async {
    final timeline = await readTimeline(path);
    if (!isCurrentTimeline(timeline)) {
      throw const SongSubtitleTimelineException(staleTimelineMessage);
    }
    return timeline;
  }

  static Future<bool> timelineFileIsCurrent(String path) async {
    final normalized = path.trim();
    if (normalized.isEmpty) {
      return false;
    }
    try {
      return isCurrentTimeline(await readTimeline(normalized));
    } catch (_) {
      return false;
    }
  }

  static bool isCurrentTimeline(SongSubtitleTimeline timeline) =>
      timeline.alignmentVersion == alignmentVersion;

  static String _diagnosticTimestamp(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}${two(value.month)}${two(value.day)}-'
        '${two(value.hour)}${two(value.minute)}${two(value.second)}';
  }

  static String _safeDiagnosticName(String value) {
    final sanitized = value
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return sanitized.isEmpty ? 'default' : sanitized;
  }

  static List<AsrWordTiming> _wordsFromAsrSnapshot(Object? raw) {
    final words = <AsrWordTiming>[];
    if (raw is! Map) {
      return words;
    }
    final topLevelWords = raw['words'];
    if (topLevelWords is List) {
      for (final item in topLevelWords) {
        final word = _wordFromAsrSnapshotItem(item);
        if (word != null) {
          words.add(word);
        }
      }
    }
    if (words.isNotEmpty) {
      return words;
    }

    final asr = raw['asr'];
    final utterances = asr is Map ? asr['utterances'] : null;
    if (utterances is! List) {
      return words;
    }
    for (final utterance in utterances) {
      if (utterance is! Map) {
        continue;
      }
      final utteranceWords = utterance['words'];
      if (utteranceWords is! List) {
        continue;
      }
      for (final item in utteranceWords) {
        final word = _wordFromAsrSnapshotItem(item);
        if (word != null) {
          words.add(word);
        }
      }
    }
    return words;
  }

  static AsrWordTiming? _wordFromAsrSnapshotItem(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final text = _cleanRecognizedWord(raw['text']);
    final startMs = _snapshotInt(raw['startMs'] ?? raw['start_time']);
    final endMs = _snapshotInt(raw['endMs'] ?? raw['end_time']);
    if (text.isEmpty || startMs == null || endMs == null || endMs <= startMs) {
      return null;
    }
    final rawConfidence = raw['confidence'] ?? raw['score'];
    final confidence = rawConfidence is num
        ? rawConfidence > 1
            ? rawConfidence.toDouble() / 100
            : rawConfidence.toDouble()
        : null;
    return AsrWordTiming(
      text: text,
      startMs: startMs,
      endMs: endMs,
      confidence: confidence,
    );
  }

  static int _durationFromAsrSnapshot(Object? raw) {
    if (raw is! Map) {
      return 0;
    }
    final topLevel = _snapshotInt(raw['estimatedDurationMs']) ??
        _snapshotInt(raw['asrDurationMs']) ??
        _snapshotInt(raw['durationMs']);
    if (topLevel != null && topLevel > 0) {
      return topLevel;
    }
    final asr = raw['asr'];
    if (asr is Map) {
      final asrDuration = _snapshotInt(asr['durationMs']);
      if (asrDuration != null && asrDuration > 0) {
        return asrDuration;
      }
    }
    return 0;
  }

  static int? _snapshotInt(Object? raw) {
    if (raw is num) {
      return raw.round();
    }
    if (raw is String) {
      return int.tryParse(raw.trim());
    }
    return null;
  }

  static String srtForTimeline(SongSubtitleTimeline timeline) {
    return RecordingExportUtils.srtForCues(
      timeline.cues
          .map(
            (cue) => RecordingSubtitleCue(
              startMs: cue.startMs,
              endMs: cue.endMs,
              english: cue.english,
              chinese: cue.chinese,
            ),
          )
          .toList(growable: false),
    );
  }

  static SongSubtitleCue? cueAtPosition(
    SongSubtitleTimeline timeline,
    int positionMs,
  ) {
    if (positionMs < 0) {
      return null;
    }
    for (final cue in timeline.cues) {
      if (positionMs >= cue.startMs && positionMs < cue.endMs) {
        return cue;
      }
    }
    return null;
  }

  static void validateTimelineCompleteness(
    SongSubtitleTimeline timeline,
    int lyricLineCount,
  ) {
    if (lyricLineCount <= 0) {
      return;
    }
    final cueLineIndexes = timeline.cues
        .map((cue) => cue.lineIndex)
        .where((index) => index >= 0 && index < lyricLineCount)
        .toSet();
    final lastCueLineIndex = cueLineIndexes.isEmpty
        ? -1
        : cueLineIndexes.reduce((a, b) => math.max(a, b));
    if (cueLineIndexes.length >= lyricLineCount &&
        lastCueLineIndex >= lyricLineCount - 1) {
      return;
    }
    final warnings = timeline.warnings
        .map((warning) => warning.trim())
        .where((warning) => warning.isNotEmpty)
        .join('；');
    final detail = warnings.isEmpty ? '' : ' $warnings';
    throw SongSubtitleTimelineException(
      '歌曲可能没有唱完整歌词：字幕时间线只覆盖到 ${cueLineIndexes.length}/$lyricLineCount 行。'
      '$detail 请删除这次 Suno 结果并重新生成歌曲后再生成字幕。',
    );
  }

  static SongSubtitleTimeline buildTimeline({
    required int articleId,
    required String audioHash,
    required String lyricsHash,
    required int durationMs,
    required String source,
    required List<String> lyricLines,
    required Map<int, String> translations,
    required List<AsrWordTiming> words,
  }) {
    final lines = _cleanLines(lyricLines);
    final safeDuration = math.max(
      1000,
      math.max(durationMs, words.isEmpty ? 0 : words.last.endMs),
    );
    if (lines.isEmpty) {
      return SongSubtitleTimeline(
        version: 1,
        alignmentVersion: alignmentVersion,
        articleId: articleId,
        audioHash: audioHash,
        lyricsHash: lyricsHash,
        durationMs: safeDuration,
        source: source,
        cues: const [],
        warnings: const ['歌词为空'],
      );
    }

    final normalizedWords = words
        .map(_TimedToken.fromAsr)
        .where((word) => word.normalized.isNotEmpty)
        .toList(growable: false);
    final lineTokens = [
      for (final line in lines) _tokensForLine(line),
    ];
    final weights = [
      for (var i = 0; i < lines.length; i += 1)
        _singingWeight(lineTokens[i], lines[i]),
    ];
    final matches = List<_LineMatch?>.filled(lines.length, null);
    var searchStart = 0;
    for (var i = 0; i < lines.length; i += 1) {
      final match = _bestLineMatch(
        tokens: lineTokens[i],
        words: normalizedWords,
        searchStart: searchStart,
      );
      if (match != null &&
          match.confidence >= _lineConfidenceThreshold(i, lineTokens[i])) {
        matches[i] = match;
        searchStart = math.min(normalizedWords.length, match.lastWordIndex + 1);
      }
    }
    _rescueMissingLineMatches(
      matches: matches,
      lineTokens: lineTokens,
      words: normalizedWords,
    );
    _refineWeakLineMatches(
      matches: matches,
      lineTokens: lineTokens,
      words: normalizedWords,
    );

    final draft = <SongSubtitleCue?>[
      for (var i = 0; i < lines.length; i += 1)
        matches[i] == null
            ? null
            : SongSubtitleCue(
                lineIndex: i,
                startMs:
                    math.max(0, matches[i]!.startMs - _matchedLineLeadInMs),
                endMs: _endMsForLineMatch(
                  match: matches[i]!,
                  lineIndex: i,
                  matches: matches,
                  words: normalizedWords,
                  durationMs: safeDuration,
                ),
                english: lines[i],
                chinese: translations[i]?.trim() ?? '',
                confidence: matches[i]!.confidence,
                method: matches[i]!.hasMissingBoundary ? 'partial' : 'matched',
              ),
    ];

    _fillMissingCues(
      draft: draft,
      lines: lines,
      translations: translations,
      weights: weights,
      durationMs: safeDuration,
    );
    _redistributeSqueezedInferredSpans(
      draft: draft,
      weights: weights,
      tokenCounts: [
        for (final tokens in lineTokens) math.max(1, tokens.length),
      ],
      durationMs: safeDuration,
    );

    final tailWarning = _collapseImplausibleTrailingEstimates(
      draft: draft,
      weights: weights,
      durationMs: safeDuration,
    );
    final rawCues = draft.whereType<SongSubtitleCue>().toList(growable: false);

    final cues = _normalizeCueBounds(
      rawCues,
      durationMs: safeDuration,
    );
    final matchedCount = cues.where(_cueHasAsrAnchor).length;
    final partialCount = cues.where((cue) => cue.method == 'partial').length;
    final warnings = <String>[
      if (normalizedWords.isEmpty) 'ASR 未返回可用词级时间，已使用 fallback',
      if (matchedCount < cues.length) '部分歌词行使用插值或估算时间',
      if (partialCount > 0) '部分歌词行仅局部匹配 ASR，已按歌词长度补齐时间',
      if (matchedCount == 0) '没有歌词行与 ASR 结果可靠匹配',
      if (tailWarning != null) tailWarning,
    ];
    return SongSubtitleTimeline(
      version: 1,
      alignmentVersion: alignmentVersion,
      articleId: articleId,
      audioHash: audioHash,
      lyricsHash: lyricsHash,
      durationMs: safeDuration,
      source: source,
      cues: cues,
      warnings: warnings,
    );
  }

  static String audioMimeTypeForPathForTest(String audioPath) =>
      _audioMimeTypeForPath(audioPath);

  static String audioFormatFromMimeTypeForTest(String mimeType) =>
      _audioFormatFromMimeType(mimeType);

  static String _audioMimeTypeForPath(String audioPath) {
    final extension = path_lib.extension(audioPath).toLowerCase();
    switch (extension) {
      case '.mp3':
      case '.mpeg':
        return 'audio/mpeg';
      case '.wav':
        return 'audio/wav';
      case '.m4a':
      case '.mp4':
        return 'audio/mp4';
      case '.aac':
        return 'audio/aac';
      case '.ogg':
        return 'audio/ogg';
      case '.flac':
        return 'audio/flac';
      default:
        return 'audio/mpeg';
    }
  }

  static String _audioFormatFromMimeType(String mimeType) {
    switch (mimeType.trim().toLowerCase()) {
      case 'audio/mpeg':
        return 'mp3';
      case 'audio/mp4':
      case 'audio/aac':
        return 'aac';
      case 'audio/ogg':
        return 'ogg';
      case 'audio/flac':
      case 'audio/x-flac':
        return 'flac';
      case 'audio/wav':
      case 'audio/x-wav':
      default:
        return 'wav';
    }
  }

  static bool providerSupportsOriginalAudioForTest({
    required String provider,
    required String audioFormat,
  }) =>
      _providerSupportsOriginalAudio(
        provider: provider,
        audioFormat: audioFormat,
      );

  static bool _providerSupportsOriginalAudio({
    required String provider,
    required String audioFormat,
  }) {
    final normalizedFormat = audioFormat.trim().toLowerCase();
    if (provider == AppConfig.aiProviderAliyunBailian) {
      return normalizedFormat == 'mp3' || normalizedFormat == 'wav';
    }
    return normalizedFormat == 'wav';
  }

  static Future<List<int>> _wav16kMonoBytes(String audioPath) async {
    if (audioPath.toLowerCase().endsWith('.wav')) {
      return File(audioPath).readAsBytes();
    }
    final ffmpegPath = RecordingExportService.bundledFfmpegPath();
    if (!await File(ffmpegPath).exists()) {
      throw SongSubtitleTimelineException(
        '程序目录缺少 ffmpeg.exe：$ffmpegPath。请重新发布程序或把 ffmpeg.exe 放到程序目录。',
      );
    }
    final tempDir = await Directory.systemTemp.createTemp('tomato_song_asr_');
    try {
      final outputPath = path_lib.join(tempDir.path, 'song_16k_mono.wav');
      final result = await Process.run(
        ffmpegPath,
        [
          '-y',
          '-hide_banner',
          '-loglevel',
          'error',
          '-i',
          audioPath,
          '-ac',
          '1',
          '-ar',
          '16000',
          '-acodec',
          'pcm_s16le',
          outputPath,
        ],
      ).timeout(const Duration(minutes: 3));
      if (result.exitCode != 0) {
        final stderr = result.stderr?.toString().trim() ?? '';
        throw SongSubtitleTimelineException(
          '歌曲音频转码失败：${stderr.isEmpty ? 'FFmpeg exit ${result.exitCode}' : stderr}',
        );
      }
      final bytes = await File(outputPath).readAsBytes();
      if (bytes.isEmpty) {
        throw const SongSubtitleTimelineException('歌曲音频转码结果为空');
      }
      return bytes;
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // Best-effort cleanup.
      }
    }
  }

  static int _estimateDurationMs({
    required Uint8List audioBytes,
    required AsrTimelineResult asr,
  }) {
    final asrDuration = asr.durationMs ?? 0;
    final lastWord = asr.words.isEmpty ? 0 : asr.words.last.endMs;
    final mp3Duration = RecordingExportUtils.estimateMp3DurationMs(audioBytes);
    return [asrDuration, lastWord, mp3Duration, 1000].reduce(math.max);
  }

  static List<String> _cleanLines(List<String> lines) => lines
      .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);

  static List<String> _tokensForLine(String line) => _expandContractions(line)
      .map(_normalizeToken)
      .where((token) => token.isNotEmpty)
      .toList(growable: false);

  static Iterable<String> _expandContractions(String line) sync* {
    final words = line
        .replaceAll(RegExp(r'[‘’]'), "'")
        .split(RegExp(r"[^A-Za-z0-9\-']+"));
    for (final word in words) {
      final lower = word.toLowerCase();
      switch (lower) {
        case "i'm":
          yield 'i';
          yield 'am';
          break;
        case "you're":
          yield 'you';
          yield 'are';
          break;
        case "we're":
          yield 'we';
          yield 'are';
          break;
        case "they're":
          yield 'they';
          yield 'are';
          break;
        case "don't":
          yield 'do';
          yield 'not';
          break;
        case "can't":
          yield 'can';
          yield 'not';
          break;
        case "won't":
          yield 'will';
          yield 'not';
          break;
        default:
          if (lower.endsWith("n't") && lower.length > 3) {
            yield lower.substring(0, lower.length - 3);
            yield 'not';
          } else {
            yield lower;
          }
      }
    }
  }

  static String _normalizeToken(Object? value) {
    final raw = value?.toString().toLowerCase() ?? '';
    return raw
        .replaceAll(RegExp(r'[‘’]'), "'")
        .replaceAll(RegExp(r"^[^a-z0-9']+|[^a-z0-9']+$"), '')
        .replaceAll("'", '')
        .trim();
  }

  static double _singingWeight(List<String> tokens, String line) {
    if (tokens.isEmpty) {
      return math.max(1, line.trim().length / 8);
    }
    var weight = 0.0;
    for (final token in tokens) {
      final syllables = RegExp(r'[aeiouy]+').allMatches(token).length;
      weight += math.max(1, syllables);
      if (RegExp(r'([a-z])\1{1,}').hasMatch(token)) {
        weight += 0.5;
      }
    }
    return math.max(1, weight);
  }

  static double _lineConfidenceThreshold(int index, List<String> tokens) {
    if (tokens.length <= 1) {
      return 0.58;
    }
    if (tokens.length <= 3) {
      return 0.5;
    }
    return 0.42;
  }

  static _LineMatch? _bestLineMatch({
    required List<String> tokens,
    required List<_TimedToken> words,
    required int searchStart,
    int? searchEndExclusive,
  }) {
    final searchEnd =
        math.min(searchEndExclusive ?? words.length, words.length);
    if (tokens.isEmpty ||
        words.isEmpty ||
        searchStart >= words.length ||
        searchStart >= searchEnd) {
      return null;
    }
    _LineMatch? best;
    for (var start = searchStart; start < searchEnd; start += 1) {
      final match = _lineMatchAtStart(
        tokens: tokens,
        words: words,
        start: start,
        searchStart: searchStart,
        searchEndExclusive: searchEnd,
      );
      if (match == null) {
        continue;
      }
      if (best == null || match.confidence > best.confidence) {
        best = match;
      }
      if (match.confidence > 0.92) {
        break;
      }
    }
    return best;
  }

  static _LineMatch? _lineMatchAtStart({
    required List<String> tokens,
    required List<_TimedToken> words,
    required int start,
    required int searchStart,
    required int searchEndExclusive,
  }) {
    var cursor = start;
    var score = 0.0;
    var matched = 0;
    int? first;
    int? last;
    int? firstMatchedTokenIndex;
    int? lastMatchedTokenIndex;
    for (var tokenIndex = 0; tokenIndex < tokens.length; tokenIndex += 1) {
      final token = tokens[tokenIndex];
      var bestWordIndex = -1;
      var bestScore = 0.0;
      final lookahead = math.min(searchEndExclusive, cursor + 8);
      for (var wordIndex = cursor; wordIndex < lookahead; wordIndex += 1) {
        final candidateScore =
            _tokenSimilarity(token, words[wordIndex].normalized);
        if (candidateScore > bestScore) {
          bestScore = candidateScore;
          bestWordIndex = wordIndex;
        }
      }
      if (bestWordIndex >= 0 && bestScore >= 0.54) {
        // ASR often drops light lyric tokens such as "and", "but", or "the".
        // If a low-information token jumps across several recognized words, it
        // can steal a later lyric line's anchor and cascade into very long or
        // squeezed subtitles. Treat that weak token as missing; the surrounding
        // stronger words are better anchors for the line.
        final allowedWeakTokenGap = tokenIndex == 0 ? 1 : 2;
        if (_isSkippableLowInformationToken(token) &&
            bestWordIndex - cursor > allowedWeakTokenGap) {
          score -= 0.08;
          continue;
        }
        first ??= bestWordIndex;
        last = bestWordIndex;
        firstMatchedTokenIndex ??= tokenIndex;
        lastMatchedTokenIndex = tokenIndex;
        matched += 1;
        score += bestScore;
        cursor = bestWordIndex + 1;
      } else {
        score -= 0.08;
      }
    }
    if (first == null || last == null || matched == 0) {
      return null;
    }
    final coverage = matched / tokens.length;
    final averageScore = score / tokens.length;
    final distancePenalty = math.min(0.18, (start - searchStart) * 0.006);
    final confidence = (coverage * 0.62 + averageScore * 0.38 - distancePenalty)
        .clamp(0.0, 1.0);
    return _LineMatch(
      firstWordIndex: first,
      lastWordIndex: last,
      startMs: words[first].startMs,
      endMs: words[last].endMs,
      confidence: confidence,
      matchedTokenCount: matched,
      tokenCount: tokens.length,
      firstMatchedTokenIndex: firstMatchedTokenIndex ?? 0,
      lastMatchedTokenIndex: lastMatchedTokenIndex ?? tokens.length - 1,
    );
  }

  static bool _isSkippableLowInformationToken(String token) {
    switch (token) {
      case 'and':
      case 'but':
      case 'or':
      case 'so':
      case 'for':
      case 'the':
      case 'a':
      case 'an':
        return true;
      default:
        return false;
    }
  }

  static void _rescueMissingLineMatches({
    required List<_LineMatch?> matches,
    required List<List<String>> lineTokens,
    required List<_TimedToken> words,
  }) {
    if (words.isEmpty) {
      return;
    }
    for (var lineIndex = 0; lineIndex < matches.length; lineIndex += 1) {
      if (matches[lineIndex] != null || lineTokens[lineIndex].isEmpty) {
        continue;
      }
      final previous = _previousLineMatch(matches, lineIndex);
      final next = _nextLineMatch(matches, lineIndex);
      final searchStart = previous == null
          ? 0
          : previous.isWeakBoundary
              ? math.max(0, previous.firstWordIndex + 1)
              : math.max(0, previous.lastWordIndex + 1 - 6);
      final searchEnd = math.max(
        searchStart + 1,
        next == null ? words.length : next.firstWordIndex,
      );
      final match = _bestLineMatch(
        tokens: lineTokens[lineIndex],
        words: words,
        searchStart: searchStart,
        searchEndExclusive: searchEnd,
      );
      if (match == null) {
        continue;
      }
      final threshold = math.max(
        0.36,
        _lineConfidenceThreshold(lineIndex, lineTokens[lineIndex]) - 0.04,
      );
      if (match.confidence >= threshold && match.coverage >= 0.58) {
        matches[lineIndex] = match;
      }
    }
  }

  static void _refineWeakLineMatches({
    required List<_LineMatch?> matches,
    required List<List<String>> lineTokens,
    required List<_TimedToken> words,
  }) {
    if (words.isEmpty) {
      return;
    }
    for (var lineIndex = 0; lineIndex < matches.length; lineIndex += 1) {
      final current = matches[lineIndex];
      if (current == null ||
          (!current.hasMissingBoundary && !current.isWeakBoundary)) {
        continue;
      }
      final previous = _previousLineMatch(matches, lineIndex);
      final next = _nextLineMatch(matches, lineIndex);
      final searchStart = previous == null ? 0 : previous.lastWordIndex + 1;
      final searchEnd = next == null ? words.length : next.firstWordIndex;
      if (searchStart >= searchEnd) {
        continue;
      }
      final candidate = _bestLineMatch(
        tokens: lineTokens[lineIndex],
        words: words,
        searchStart: searchStart,
        searchEndExclusive: searchEnd,
      );
      if (candidate == null) {
        continue;
      }
      final threshold =
          _lineConfidenceThreshold(lineIndex, lineTokens[lineIndex]);
      final improvesCoverage =
          candidate.missingBoundaryCount < current.missingBoundaryCount ||
              candidate.coverage > current.coverage + 0.12;
      final improvesConfidence =
          candidate.confidence > current.confidence + 0.04;
      if (candidate.confidence >= threshold &&
          (improvesCoverage || improvesConfidence)) {
        matches[lineIndex] = candidate;
      }
    }
  }

  static _LineMatch? _previousLineMatch(
    List<_LineMatch?> matches,
    int lineIndex,
  ) {
    for (var index = lineIndex - 1; index >= 0; index -= 1) {
      final match = matches[index];
      if (match != null) {
        return match;
      }
    }
    return null;
  }

  static _LineMatch? _nextLineMatch(
    List<_LineMatch?> matches,
    int lineIndex,
  ) {
    for (var index = lineIndex + 1; index < matches.length; index += 1) {
      final match = matches[index];
      if (match != null) {
        return match;
      }
    }
    return null;
  }

  static int _endMsForLineMatch({
    required _LineMatch match,
    required int lineIndex,
    required List<_LineMatch?> matches,
    required List<_TimedToken> words,
    required int durationMs,
  }) {
    if (match.missingSuffixTokenCount <= 0) {
      return match.endMs;
    }
    final recognizedDuration = math.max(1, match.endMs - match.startMs);
    final localMsPerToken =
        recognizedDuration / math.max(1, match.matchedTokenCount);
    final next = _nextLineMatch(matches, lineIndex);
    final isTrailingLine = next == null || lineIndex >= matches.length - 1;
    final suffixFactor = isTrailingLine ? 2.2 : 1.25;
    final suffixExtension =
        (match.missingSuffixTokenCount * localMsPerToken * suffixFactor)
            .round();
    var endMs = match.endMs + suffixExtension + _matchedLineTailMs;
    if (next != null && next.startMs > match.startMs) {
      endMs =
          math.min(endMs, math.max(match.endMs + 1, next.startMs - _cueGapMs));
    } else {
      endMs = math.min(endMs, durationMs);
    }
    return math.max(match.endMs + 1, endMs);
  }

  static double _tokenSimilarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) {
      return 0;
    }
    if (a == b) {
      return 1;
    }
    if (_stem(a) == _stem(b)) {
      return 0.88;
    }
    final distance = _levenshtein(a, b);
    final maxLen = math.max(a.length, b.length);
    final editScore = 1 - distance / maxLen;
    final soundScore = _soundKey(a) == _soundKey(b) ? 0.72 : 0.0;
    final consonantScore =
        _consonantFrame(a) == _consonantFrame(b) ? 0.66 : 0.0;
    return [editScore, soundScore, consonantScore].reduce(math.max).clamp(0, 1);
  }

  static String _stem(String token) {
    for (final suffix in const ['ing', 'ed', 'es', 's']) {
      if (token.length > suffix.length + 2 && token.endsWith(suffix)) {
        return token.substring(0, token.length - suffix.length);
      }
    }
    return token;
  }

  static String _soundKey(String token) {
    if (token.isEmpty) {
      return '';
    }
    final first = token.substring(0, 1);
    final tail = token.substring(1).replaceAll(RegExp(r'[aeiouy]'), '');
    return '$first$tail';
  }

  static String _consonantFrame(String token) {
    final consonants = token.replaceAll(RegExp(r'[aeiouy]'), '');
    if (consonants.length <= 2) {
      return consonants;
    }
    return '${consonants[0]}${consonants[consonants.length - 1]}';
  }

  static int _levenshtein(String a, String b) {
    final previous = List<int>.generate(b.length + 1, (index) => index);
    final current = List<int>.filled(b.length + 1, 0);
    for (var i = 0; i < a.length; i += 1) {
      current[0] = i + 1;
      for (var j = 0; j < b.length; j += 1) {
        final substitution = previous[j] + (a[i] == b[j] ? 0 : 1);
        current[j + 1] = [
          current[j] + 1,
          previous[j + 1] + 1,
          substitution,
        ].reduce(math.min);
      }
      previous.setAll(0, current);
    }
    return previous[b.length];
  }

  static void _fillMissingCues({
    required List<SongSubtitleCue?> draft,
    required List<String> lines,
    required Map<int, String> translations,
    required List<double> weights,
    required int durationMs,
  }) {
    final matchedIndexes = <int>[
      for (var i = 0; i < draft.length; i += 1)
        if (draft[i] != null) i,
    ];
    if (matchedIndexes.isEmpty) {
      _assignRange(
        draft: draft,
        lines: lines,
        translations: translations,
        weights: weights,
        startLine: 0,
        endLine: draft.length - 1,
        startMs: 0,
        endMs: durationMs,
        method: 'fallback',
        confidence: 0.35,
      );
      return;
    }

    final first = matchedIndexes.first;
    if (first > 0) {
      _assignRange(
        draft: draft,
        lines: lines,
        translations: translations,
        weights: weights,
        startLine: 0,
        endLine: first - 1,
        startMs: 0,
        endMs: draft[first]!.startMs,
        method: 'estimated',
        confidence: 0.48,
      );
    }

    for (var i = 0; i < matchedIndexes.length - 1; i += 1) {
      final left = matchedIndexes[i];
      final right = matchedIndexes[i + 1];
      if (right - left <= 1) {
        continue;
      }
      _assignRange(
        draft: draft,
        lines: lines,
        translations: translations,
        weights: weights,
        startLine: left + 1,
        endLine: right - 1,
        startMs: draft[left]!.endMs,
        endMs: draft[right]!.startMs,
        method: 'interpolated',
        confidence: 0.68,
      );
    }

    final last = matchedIndexes.last;
    if (last < draft.length - 1) {
      _assignRange(
        draft: draft,
        lines: lines,
        translations: translations,
        weights: weights,
        startLine: last + 1,
        endLine: draft.length - 1,
        startMs: draft[last]!.endMs,
        endMs: durationMs,
        method: 'estimated',
        confidence: 0.48,
      );
    }
  }

  static void _assignRange({
    required List<SongSubtitleCue?> draft,
    required List<String> lines,
    required Map<int, String> translations,
    required List<double> weights,
    required int startLine,
    required int endLine,
    required int startMs,
    required int endMs,
    required String method,
    required double confidence,
  }) {
    if (startLine > endLine) {
      return;
    }
    final safeStart = math.max(0, startMs);
    final safeEnd =
        math.max(safeStart + (endLine - startLine + 1) * 400, endMs);
    final totalWeight = weights
        .sublist(startLine, endLine + 1)
        .fold<double>(0, (sum, weight) => sum + math.max(1, weight));
    var cursor = safeStart.toDouble();
    for (var index = startLine; index <= endLine; index += 1) {
      final share = math.max(1, weights[index]) / math.max(1, totalWeight);
      final next = index == endLine
          ? safeEnd.toDouble()
          : cursor + (safeEnd - safeStart) * share;
      draft[index] = SongSubtitleCue(
        lineIndex: index,
        startMs: cursor.round(),
        endMs: math.max(cursor.round() + 250, next.round()),
        english: lines[index],
        chinese: translations[index]?.trim() ?? '',
        confidence: confidence,
        method: method,
      );
      cursor = next;
    }
  }

  static void _redistributeSqueezedInferredSpans({
    required List<SongSubtitleCue?> draft,
    required List<double> weights,
    required List<int> tokenCounts,
    required int durationMs,
  }) {
    final medianMsPerWord = _medianMatchedMsPerWord(
      draft: draft,
      tokenCounts: tokenCounts,
    );
    final firstMatched = _firstMatchedCueIndex(draft);
    final lastMatched = _lastMatchedCueIndex(draft);
    if (firstMatched == null || lastMatched == null) {
      return;
    }

    final hasSqueezedLeading = firstMatched > 0 &&
        _inferredRunIsSqueezed(
          draft: draft,
          weights: weights,
          tokenCounts: tokenCounts,
          startLine: 0,
          endLine: firstMatched - 1,
          medianMsPerWord: medianMsPerWord,
        );
    final hasSqueezedTrailing = lastMatched < draft.length - 1 &&
        _inferredRunIsSqueezed(
          draft: draft,
          weights: weights,
          tokenCounts: tokenCounts,
          startLine: lastMatched + 1,
          endLine: draft.length - 1,
          medianMsPerWord: medianMsPerWord,
        );

    if (firstMatched == lastMatched) {
      if (hasSqueezedLeading && hasSqueezedTrailing) {
        _redistributeCueWindowByWeight(
          draft: draft,
          weights: weights,
          startLine: 0,
          endLine: draft.length - 1,
          startMs: 0,
          endMs: durationMs,
        );
      } else if (hasSqueezedLeading) {
        _redistributeCueWindowByWeight(
          draft: draft,
          weights: weights,
          startLine: 0,
          endLine: firstMatched,
          startMs: 0,
          endMs: draft[firstMatched]!.endMs,
        );
      } else if (hasSqueezedTrailing) {
        _redistributeCueWindowByWeight(
          draft: draft,
          weights: weights,
          startLine: lastMatched,
          endLine: draft.length - 1,
          startMs: draft[lastMatched]!.startMs,
          endMs: durationMs,
        );
      }
      return;
    }

    // Inferred lyrics can be squeezed at the beginning, middle, or end. When
    // that happens, the nearest matched boundary is usually the unreliable
    // piece: first matched start too early, previous matched end too late, or
    // last matched end too late. Subtitles may be a little long, but they must
    // not be too short to read, so each local window is fully split by lyric
    // weight without reserving leftover silence.
    if (hasSqueezedLeading) {
      _redistributeCueWindowByWeight(
        draft: draft,
        weights: weights,
        startLine: 0,
        endLine: firstMatched,
        startMs: 0,
        endMs: draft[firstMatched]!.endMs,
      );
    }

    var index = firstMatched + 1;
    while (index < lastMatched) {
      final cue = draft[index];
      if (cue == null || _cueHasAsrAnchor(cue)) {
        index += 1;
        continue;
      }
      final runStart = index;
      var runEnd = index;
      while (runEnd + 1 < draft.length &&
          draft[runEnd + 1] != null &&
          !_cueHasAsrAnchor(draft[runEnd + 1]!)) {
        runEnd += 1;
      }
      final leftIndex = runStart - 1;
      final rightIndex = runEnd + 1;
      final left = draft[leftIndex];
      final right = draft[rightIndex];
      if (left == null || right == null || !_cueHasAsrAnchor(left)) {
        index = runEnd + 1;
        continue;
      }
      if (!_cueHasAsrAnchor(right) || right.startMs <= left.startMs) {
        index = runEnd + 1;
        continue;
      }

      if (!_inferredRunIsSqueezed(
        draft: draft,
        weights: weights,
        tokenCounts: tokenCounts,
        startLine: runStart,
        endLine: runEnd,
        medianMsPerWord: medianMsPerWord,
      )) {
        index = runEnd + 1;
        continue;
      }

      _redistributeCueWindowByWeight(
        draft: draft,
        weights: weights,
        startLine: leftIndex,
        endLine: runEnd,
        startMs: left.startMs,
        endMs: right.startMs,
      );
      index = runEnd + 1;
    }

    if (hasSqueezedTrailing) {
      _redistributeCueWindowByWeight(
        draft: draft,
        weights: weights,
        startLine: lastMatched,
        endLine: draft.length - 1,
        startMs: draft[lastMatched]!.startMs,
        endMs: durationMs,
      );
    }
  }

  static bool _inferredRunIsSqueezed({
    required List<SongSubtitleCue?> draft,
    required List<double> weights,
    required List<int> tokenCounts,
    required int startLine,
    required int endLine,
    required double medianMsPerWord,
  }) {
    if (startLine > endLine) {
      return false;
    }
    for (var i = startLine; i <= endLine; i += 1) {
      final cue = draft[i];
      if (cue == null || _cueHasAsrAnchor(cue)) {
        continue;
      }
      final duration = cue.endMs - cue.startMs;
      final readableDuration = _inferredReadableDurationMs(
        tokenCount: tokenCounts[i],
        weight: weights[i],
        medianMsPerWord: medianMsPerWord,
      );
      if (duration < readableDuration * 0.72 || duration < 900) {
        return true;
      }
    }
    return false;
  }

  static void _redistributeCueWindowByWeight({
    required List<SongSubtitleCue?> draft,
    required List<double> weights,
    required int startLine,
    required int endLine,
    required int startMs,
    required int endMs,
  }) {
    if (startLine > endLine || endMs <= startMs) {
      return;
    }
    final totalWeight = weights
        .sublist(startLine, endLine + 1)
        .fold<double>(0, (sum, weight) => sum + math.max(1, weight));
    final windowMs = endMs - startMs;
    var cursor = startMs.toDouble();
    for (var index = startLine; index <= endLine; index += 1) {
      final cue = draft[index];
      if (cue == null) {
        continue;
      }
      final next = index == endLine
          ? endMs.toDouble()
          : cursor +
              windowMs * math.max(1, weights[index]) / math.max(1, totalWeight);
      draft[index] = _copyCue(
        cue,
        startMs: cursor.round(),
        endMs: math.max(cursor.round() + 1, next.round()),
      );
      cursor = next;
    }
  }

  static double _medianMatchedMsPerWord({
    required List<SongSubtitleCue?> draft,
    required List<int> tokenCounts,
  }) {
    final rates = <double>[];
    for (var i = 0; i < draft.length; i += 1) {
      final cue = draft[i];
      if (cue == null || !_cueHasAsrAnchor(cue)) {
        continue;
      }
      final duration = cue.endMs - cue.startMs;
      if (duration <= 0) {
        continue;
      }
      rates.add(duration / math.max(1, tokenCounts[i]));
    }
    if (rates.isEmpty) {
      return 320;
    }
    rates.sort();
    return rates[rates.length ~/ 2].clamp(220.0, 520.0);
  }

  static int? _firstMatchedCueIndex(List<SongSubtitleCue?> draft) {
    for (var i = 0; i < draft.length; i += 1) {
      if (_cueHasAsrAnchor(draft[i])) {
        return i;
      }
    }
    return null;
  }

  static int? _lastMatchedCueIndex(List<SongSubtitleCue?> draft) {
    for (var i = draft.length - 1; i >= 0; i -= 1) {
      if (_cueHasAsrAnchor(draft[i])) {
        return i;
      }
    }
    return null;
  }

  static int _inferredReadableDurationMs({
    required int tokenCount,
    required double weight,
    required double medianMsPerWord,
  }) {
    final byWords = math.max(1, tokenCount) * medianMsPerWord * 0.65;
    final byWeight = math.max(1, weight) * 130;
    final floor = tokenCount <= 2
        ? 650
        : tokenCount <= 5
            ? 950
            : 1200;
    return math
        .min(3800, math.max(floor.toDouble(), math.max(byWords, byWeight)))
        .round();
  }

  static SongSubtitleCue _copyCue(
    SongSubtitleCue cue, {
    int? startMs,
    int? endMs,
  }) =>
      SongSubtitleCue(
        lineIndex: cue.lineIndex,
        startMs: startMs ?? cue.startMs,
        endMs: endMs ?? cue.endMs,
        english: cue.english,
        chinese: cue.chinese,
        confidence: cue.confidence,
        method: cue.method,
      );

  static String? _collapseImplausibleTrailingEstimates({
    required List<SongSubtitleCue?> draft,
    required List<double> weights,
    required int durationMs,
  }) {
    var lastMatched = -1;
    for (var i = draft.length - 1; i >= 0; i -= 1) {
      final cue = draft[i];
      if (_cueHasAsrAnchor(cue)) {
        lastMatched = i;
        break;
      }
    }
    if (lastMatched < 0 || lastMatched >= draft.length - 1) {
      return null;
    }

    final tailCues = <SongSubtitleCue>[];
    for (var i = lastMatched + 1; i < draft.length; i += 1) {
      final cue = draft[i];
      if (cue != null) {
        if (_cueHasAsrAnchor(cue)) {
          return null;
        }
        tailCues.add(cue);
      }
    }
    if (tailCues.length < 3) {
      return null;
    }

    final anchor = draft[lastMatched]!;
    final availableMs = math.max(0, durationMs - anchor.endMs);
    final tailLineMinimumMs = tailCues.length * 650;
    final tailWeight = weights
        .skip(lastMatched + 1)
        .fold<double>(0, (sum, weight) => sum + math.max(1, weight));
    final matchedRates = <double>[];
    for (var i = 0; i <= lastMatched; i += 1) {
      final cue = draft[i];
      if (cue == null || !_cueHasAsrAnchor(cue)) {
        continue;
      }
      final duration = math.max(1, cue.endMs - cue.startMs);
      matchedRates.add(duration / math.max(1, weights[i]));
    }
    matchedRates.sort();
    final medianRate =
        matchedRates.isEmpty ? 650.0 : matchedRates[matchedRates.length ~/ 2];
    final weightedMinimumMs = tailWeight * medianRate * 0.35;
    final requiredMs = math.max(tailLineMinimumMs, weightedMinimumMs).round();
    if (availableMs >= requiredMs) {
      return null;
    }

    for (var i = lastMatched + 1; i < draft.length; i += 1) {
      draft[i] = null;
    }
    draft[lastMatched] = _copyCue(anchor, endMs: durationMs);
    return '尾部 ${tailCues.length} 行歌词缺少可靠人声匹配，已延长最后匹配字幕到歌曲结束';
  }

  static String _cleanRecognizedWord(Object? value) =>
      value?.toString().replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';

  static List<SongSubtitleCue> _normalizeCueBounds(
    List<SongSubtitleCue> cues, {
    required int durationMs,
  }) {
    if (cues.isEmpty) {
      return cues;
    }
    final minCueMs = math.max(
      1,
      math.min(250, durationMs ~/ math.max(1, cues.length)),
    );
    final starts = <int>[];
    for (var i = 0; i < cues.length; i += 1) {
      final rawStart = i == 0 ? math.max(0, cues[i].startMs) : cues[i].startMs;
      final minStart = i == 0 ? 0 : starts[i - 1] + minCueMs;
      starts.add(math.min(durationMs - 1, math.max(minStart, rawStart)));
    }
    starts[starts.length - 1] = math.min(
      starts.last,
      math.max(0, durationMs - minCueMs),
    );
    for (var i = starts.length - 2; i >= 0; i -= 1) {
      starts[i] = math.min(
        starts[i],
        math.max(0, starts[i + 1] - minCueMs),
      );
    }
    final normalized = <SongSubtitleCue>[];
    for (var i = 0; i < cues.length; i += 1) {
      final start = starts[i];
      final cue = cues[i];
      final preciseBounds = _cueHasAsrAnchor(cue);
      final nextStart = i == cues.length - 1 ? durationMs : starts[i + 1];
      final preferredEnd =
          cue.method == 'matched' ? cue.endMs + _matchedLineTailMs : cue.endMs;
      var end = math.max(start + minCueMs, preferredEnd);
      if (i < cues.length - 1) {
        final maxEndBeforeNext =
            math.max(start + minCueMs, nextStart - _cueGapMs);
        end = math.min(end, maxEndBeforeNext);
      } else {
        end = math.min(end, durationMs);
      }
      if (!preciseBounds && i < cues.length - 1) {
        end = math.max(end, nextStart);
      }
      end = math.min(durationMs, math.max(start + minCueMs, end));
      normalized.add(SongSubtitleCue(
        lineIndex: cue.lineIndex,
        startMs: start,
        endMs: end,
        english: cue.english,
        chinese: cue.chinese,
        confidence: cue.confidence,
        method: cue.method,
      ));
    }
    return normalized;
  }

  static bool _cueHasAsrAnchor(SongSubtitleCue? cue) =>
      cue != null && (cue.method == 'matched' || cue.method == 'partial');
}

class _TimedToken {
  const _TimedToken({
    required this.text,
    required this.normalized,
    required this.startMs,
    required this.endMs,
    this.confidence,
  });

  factory _TimedToken.fromAsr(AsrWordTiming word) => _TimedToken(
        text: SongSubtitleTimelineService._cleanRecognizedWord(word.text),
        normalized: SongSubtitleTimelineService._normalizeToken(word.text),
        startMs: word.startMs,
        endMs: word.endMs,
        confidence: word.confidence,
      );

  final String text;
  final String normalized;
  final int startMs;
  final int endMs;
  final double? confidence;
}

class _LineMatch {
  const _LineMatch({
    required this.firstWordIndex,
    required this.lastWordIndex,
    required this.startMs,
    required this.endMs,
    required this.confidence,
    required this.matchedTokenCount,
    required this.tokenCount,
    required this.firstMatchedTokenIndex,
    required this.lastMatchedTokenIndex,
  });

  final int firstWordIndex;
  final int lastWordIndex;
  final int startMs;
  final int endMs;
  final double confidence;
  final int matchedTokenCount;
  final int tokenCount;
  final int firstMatchedTokenIndex;
  final int lastMatchedTokenIndex;

  double get coverage =>
      tokenCount <= 0 ? 0 : matchedTokenCount / math.max(1, tokenCount);

  int get missingPrefixTokenCount => math.max(0, firstMatchedTokenIndex);

  int get missingSuffixTokenCount =>
      math.max(0, tokenCount - lastMatchedTokenIndex - 1);

  bool get hasMissingBoundary =>
      missingPrefixTokenCount >= 2 || missingSuffixTokenCount >= 2;

  int get missingBoundaryCount =>
      missingPrefixTokenCount + missingSuffixTokenCount;

  bool get isWeakBoundary => confidence < 0.78 || coverage < 0.86;
}
