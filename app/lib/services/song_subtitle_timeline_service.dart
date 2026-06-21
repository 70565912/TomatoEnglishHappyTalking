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

class SongSubtitleTimelineService {
  static const purpose = 'suno_song_subtitle_timeline_v1';
  static const alignmentVersion = 6;
  static const staleTimelineMessage = '歌曲字幕时间线版本过旧，请重新生成歌曲字幕';
  static const _matchedLineLeadInMs = 180;
  static const _matchedLineTailMs = 320;
  static const _cueGapMs = 80;
  static const _recognizedTextMismatchThreshold = 0.74;
  static const _recognizedTextMinAverageConfidence = 0.62;

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
    final lineOccurrences = _collectLineOccurrences(
      lineTokens: lineTokens,
      words: normalizedWords,
    );
    final repeatedOccurrenceCount = _lineOccurrenceRepeatCount(lineOccurrences);

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

    final matchedLineIndexes = {
      for (var i = 0; i < matches.length; i += 1)
        if (matches[i] != null) i,
    };
    final occurrenceLineIndexes = {
      for (final occurrence in lineOccurrences) occurrence.lineIndex,
    };
    final useRepeatedOccurrences = repeatedOccurrenceCount > 0 &&
        occurrenceLineIndexes.length >= matchedLineIndexes.length;

    final draft = <SongSubtitleCue?>[
      for (var i = 0; i < lines.length; i += 1)
        matches[i] == null
            ? null
            : SongSubtitleCue(
                lineIndex: i,
                startMs:
                    math.max(0, matches[i]!.startMs - _matchedLineLeadInMs),
                endMs: matches[i]!.endMs,
                english: lines[i],
                chinese: translations[i]?.trim() ?? '',
                confidence: matches[i]!.confidence,
                method: 'matched',
              ),
    ];

    final List<SongSubtitleCue> rawCues;
    String? tailWarning;
    if (useRepeatedOccurrences) {
      rawCues = _buildCuesFromLineOccurrences(
        occurrences: lineOccurrences,
        lines: lines,
        lineTokens: lineTokens,
        translations: translations,
        weights: weights,
        words: normalizedWords,
        durationMs: safeDuration,
      );
    } else {
      _fillMissingCues(
        draft: draft,
        lines: lines,
        translations: translations,
        weights: weights,
        durationMs: safeDuration,
      );

      tailWarning = _collapseImplausibleTrailingEstimates(
        draft: draft,
        weights: weights,
        durationMs: safeDuration,
      );
      rawCues = draft.whereType<SongSubtitleCue>().toList(growable: false);
    }

    final normalizedCues = _normalizeCueBounds(
      rawCues,
      durationMs: safeDuration,
    );
    final recognizedReplacement = _applyRecognizedTextForMismatchedCues(
      cues: normalizedCues,
      words: normalizedWords,
      lineTokens: lineTokens,
    );
    final cues = recognizedReplacement.replacedCount > 0
        ? _normalizeCueBounds(
            recognizedReplacement.cues,
            durationMs: safeDuration,
          )
        : recognizedReplacement.cues;
    final matchedCount = cues.where((cue) => cue.method == 'matched').length;
    final recognizedCueCount =
        cues.where((cue) => cue.method == 'recognized').length;
    final warnings = <String>[
      if (normalizedWords.isEmpty) 'ASR 未返回可用词级时间，已使用 fallback',
      if (matchedCount < cues.length) '部分歌词行使用插值或估算时间',
      if (recognizedReplacement.replacedCount > 0 || recognizedCueCount > 0)
        '部分字幕文字已按 ASR 识别内容替换',
      if (useRepeatedOccurrences) 'ASR 检测到重复唱段，已为重复歌词生成额外字幕',
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
  }) {
    if (tokens.isEmpty || words.isEmpty || searchStart >= words.length) {
      return null;
    }
    _LineMatch? best;
    for (var start = searchStart; start < words.length; start += 1) {
      final match = _lineMatchAtStart(
        tokens: tokens,
        words: words,
        start: start,
        searchStart: searchStart,
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
  }) {
    var cursor = start;
    var score = 0.0;
    var matched = 0;
    int? first;
    int? last;
    for (final token in tokens) {
      var bestWordIndex = -1;
      var bestScore = 0.0;
      final lookahead = math.min(words.length, cursor + 8);
      for (var wordIndex = cursor; wordIndex < lookahead; wordIndex += 1) {
        final candidateScore =
            _tokenSimilarity(token, words[wordIndex].normalized);
        if (candidateScore > bestScore) {
          bestScore = candidateScore;
          bestWordIndex = wordIndex;
        }
      }
      if (bestWordIndex >= 0 && bestScore >= 0.54) {
        first ??= bestWordIndex;
        last = bestWordIndex;
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
    );
  }

  static List<_LineOccurrence> _collectLineOccurrences({
    required List<List<String>> lineTokens,
    required List<_TimedToken> words,
  }) {
    if (lineTokens.isEmpty || words.isEmpty) {
      return const [];
    }
    final occurrences = <_LineOccurrence>[];
    var cursor = 0;
    var expectedLine = 0;
    var guard = 0;
    while (cursor < words.length && guard < words.length * 2) {
      guard += 1;
      final candidates = <_LineOccurrence>[];
      for (var lineIndex = 0; lineIndex < lineTokens.length; lineIndex += 1) {
        final tokens = lineTokens[lineIndex];
        if (tokens.isEmpty) {
          continue;
        }
        final match = _firstReliableLineMatch(
          tokens: tokens,
          words: words,
          searchStart: cursor,
          threshold: _lineOccurrenceThreshold(lineIndex, tokens),
        );
        if (match == null) {
          continue;
        }
        candidates.add(_LineOccurrence(lineIndex: lineIndex, match: match));
      }
      if (candidates.isEmpty) {
        break;
      }

      final earliestWord = candidates
          .map((candidate) => candidate.match.firstWordIndex)
          .reduce(math.min);
      final nearEarliest = candidates
          .where(
              (candidate) => candidate.match.firstWordIndex <= earliestWord + 2)
          .toList(growable: false);
      nearEarliest.sort((a, b) {
        final scoreCompare = _lineOccurrenceScore(
          b,
          expectedLine: expectedLine,
          lineCount: lineTokens.length,
        ).compareTo(_lineOccurrenceScore(
          a,
          expectedLine: expectedLine,
          lineCount: lineTokens.length,
        ));
        if (scoreCompare != 0) {
          return scoreCompare;
        }
        return a.lineIndex.compareTo(b.lineIndex);
      });
      final selected = nearEarliest.first;
      occurrences.add(selected);
      cursor = math.max(cursor + 1, selected.match.lastWordIndex + 1);
      expectedLine = selected.lineIndex + 1;
      if (expectedLine >= lineTokens.length) {
        expectedLine = 0;
      }
    }
    return occurrences;
  }

  static _LineMatch? _firstReliableLineMatch({
    required List<String> tokens,
    required List<_TimedToken> words,
    required int searchStart,
    required double threshold,
  }) {
    if (tokens.isEmpty || words.isEmpty || searchStart >= words.length) {
      return null;
    }
    final coverageThreshold = _lineOccurrenceCoverageThreshold(tokens);
    for (var start = searchStart; start < words.length; start += 1) {
      final match = _lineMatchAtStart(
        tokens: tokens,
        words: words,
        start: start,
        searchStart: searchStart,
      );
      if (match == null) {
        continue;
      }
      if (match.confidence >= threshold &&
          match.coverage >= coverageThreshold) {
        return match;
      }
    }
    return null;
  }

  static double _lineOccurrenceThreshold(int index, List<String> tokens) {
    final base = _lineConfidenceThreshold(index, tokens);
    if (tokens.length <= 1) {
      return math.max(base, 0.72);
    }
    if (tokens.length <= 3) {
      return math.max(base, 0.62);
    }
    if (tokens.length <= 6) {
      return math.max(base, 0.52);
    }
    return math.max(base, 0.48);
  }

  static double _lineOccurrenceCoverageThreshold(List<String> tokens) {
    if (tokens.length <= 2) {
      return 1.0;
    }
    if (tokens.length <= 4) {
      return 0.7;
    }
    return 0.45;
  }

  static double _lineOccurrenceScore(
    _LineOccurrence occurrence, {
    required int expectedLine,
    required int lineCount,
  }) {
    final lineDistance =
        _forwardLineDistance(expectedLine, occurrence.lineIndex, lineCount);
    final linePenalty = math.min(0.14, lineDistance * 0.018);
    final coverageBonus = math.min(0.08, occurrence.match.coverage * 0.08);
    return occurrence.match.confidence + coverageBonus - linePenalty;
  }

  static int _forwardLineDistance(int from, int to, int count) {
    if (count <= 0) {
      return 0;
    }
    final normalizedFrom = from % count;
    final normalizedTo = to % count;
    if (normalizedTo >= normalizedFrom) {
      return normalizedTo - normalizedFrom;
    }
    return count - normalizedFrom + normalizedTo;
  }

  static int _lineOccurrenceRepeatCount(List<_LineOccurrence> occurrences) {
    final seen = <int>{};
    var repeats = 0;
    for (final occurrence in occurrences) {
      if (!seen.add(occurrence.lineIndex)) {
        repeats += 1;
      }
    }
    return repeats;
  }

  static List<SongSubtitleCue> _buildCuesFromLineOccurrences({
    required List<_LineOccurrence> occurrences,
    required List<String> lines,
    required List<List<String>> lineTokens,
    required Map<int, String> translations,
    required List<double> weights,
    required List<_TimedToken> words,
    required int durationMs,
  }) {
    if (occurrences.isEmpty) {
      return const [];
    }
    final cues = <SongSubtitleCue>[];
    final coveredLineIndexes = <int>{};

    void appendEstimatedRange({
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
      final draft = List<SongSubtitleCue?>.filled(lines.length, null);
      _assignRange(
        draft: draft,
        lines: lines,
        translations: translations,
        weights: weights,
        startLine: startLine,
        endLine: endLine,
        startMs: startMs,
        endMs: endMs,
        method: method,
        confidence: confidence,
      );
      for (var i = startLine; i <= endLine; i += 1) {
        final cue = draft[i];
        if (cue != null) {
          coveredLineIndexes.add(i);
          cues.add(cue);
        }
      }
    }

    bool appendRecognizedWordRange({
      required int firstWordIndex,
      required int lastWordIndex,
    }) {
      if (firstWordIndex < 0 ||
          lastWordIndex < firstWordIndex ||
          firstWordIndex >= words.length) {
        return false;
      }
      final safeLast = math.min(lastWordIndex, words.length - 1);
      final segment = words.sublist(firstWordIndex, safeLast + 1);
      final text = _recognizedTextFromWords(segment);
      final duration =
          segment.isEmpty ? 0 : segment.last.endMs - segment.first.startMs;
      if (text.isEmpty ||
          segment.length < 2 ||
          duration < 500 ||
          !_hasReliableRecognizedConfidence(segment)) {
        return false;
      }
      cues.add(SongSubtitleCue(
        lineIndex: -1,
        startMs: math.max(0, segment.first.startMs - _matchedLineLeadInMs),
        endMs: segment.last.endMs,
        english: text,
        chinese: '',
        confidence: _recognizedCueConfidence(segment, fallback: 0.72),
        method: 'recognized',
      ));
      return true;
    }

    final first = occurrences.first;
    if (first.lineIndex > 0) {
      appendEstimatedRange(
        startLine: 0,
        endLine: first.lineIndex - 1,
        startMs: 0,
        endMs: first.match.startMs,
        method: 'estimated',
        confidence: 0.48,
      );
    }

    for (var i = 0; i < occurrences.length; i += 1) {
      final occurrence = occurrences[i];
      if (i > 0) {
        final previous = occurrences[i - 1];
        final insertedRecognizedGap = appendRecognizedWordRange(
          firstWordIndex: previous.match.lastWordIndex + 1,
          lastWordIndex: occurrence.match.firstWordIndex - 1,
        );
        if (!insertedRecognizedGap &&
            occurrence.lineIndex > previous.lineIndex + 1) {
          appendEstimatedRange(
            startLine: previous.lineIndex + 1,
            endLine: occurrence.lineIndex - 1,
            startMs: previous.match.endMs,
            endMs: occurrence.match.startMs,
            method: 'interpolated',
            confidence: 0.68,
          );
        }
      }
      coveredLineIndexes.add(occurrence.lineIndex);
      final recognizedTokens = words
          .sublist(
            occurrence.match.firstWordIndex,
            occurrence.match.lastWordIndex + 1,
          )
          .toList(growable: false);
      final recognizedText = _recognizedTextFromWords(recognizedTokens);
      final originalTokens =
          occurrence.lineIndex >= 0 && occurrence.lineIndex < lineTokens.length
              ? lineTokens[occurrence.lineIndex]
              : const <String>[];
      final recognizedNormalized = recognizedTokens
          .map((word) => word.normalized)
          .where((word) => word.isNotEmpty)
          .toList(growable: false);
      final similarity = _orderedTokenSimilarity(
        originalTokens,
        recognizedNormalized,
      );
      final shouldUseRecognizedText = recognizedText.isNotEmpty &&
          _hasReliableRecognizedConfidence(recognizedTokens) &&
          similarity < _recognizedTextMismatchThreshold;
      cues.add(SongSubtitleCue(
        lineIndex: occurrence.lineIndex,
        startMs: math.max(
          0,
          occurrence.match.startMs - _matchedLineLeadInMs,
        ),
        endMs: occurrence.match.endMs,
        english: shouldUseRecognizedText
            ? recognizedText
            : lines[occurrence.lineIndex],
        chinese: shouldUseRecognizedText
            ? ''
            : translations[occurrence.lineIndex]?.trim() ?? '',
        confidence: shouldUseRecognizedText
            ? _recognizedCueConfidence(
                recognizedTokens,
                fallback: occurrence.match.confidence,
              )
            : occurrence.match.confidence,
        method: shouldUseRecognizedText ? 'recognized' : 'matched',
      ));
    }

    final last = occurrences.last;
    final insertedTrailingRecognized = appendRecognizedWordRange(
      firstWordIndex: last.match.lastWordIndex + 1,
      lastWordIndex: words.length - 1,
    );
    if (last.lineIndex < lines.length - 1) {
      final missingAfter = [
        for (var i = last.lineIndex + 1; i < lines.length; i += 1)
          if (!coveredLineIndexes.contains(i)) i,
      ];
      if (missingAfter.isNotEmpty && !insertedTrailingRecognized) {
        appendEstimatedRange(
          startLine: missingAfter.first,
          endLine: lines.length - 1,
          startMs: last.match.endMs,
          endMs: durationMs,
          method: 'estimated',
          confidence: 0.48,
        );
      }
    }

    return cues;
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

  static String? _collapseImplausibleTrailingEstimates({
    required List<SongSubtitleCue?> draft,
    required List<double> weights,
    required int durationMs,
  }) {
    var lastMatched = -1;
    for (var i = draft.length - 1; i >= 0; i -= 1) {
      final cue = draft[i];
      if (cue != null && cue.method == 'matched') {
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
        if (cue.method == 'matched') {
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
      if (cue == null || cue.method != 'matched') {
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
    return '尾部 ${tailCues.length} 行歌词缺少可靠人声匹配，已延长最后匹配字幕到歌曲结束';
  }

  static _RecognizedCueReplacement _applyRecognizedTextForMismatchedCues({
    required List<SongSubtitleCue> cues,
    required List<_TimedToken> words,
    required List<List<String>> lineTokens,
  }) {
    if (cues.isEmpty || words.isEmpty) {
      return _RecognizedCueReplacement(cues: cues, replacedCount: 0);
    }

    var replacedCount = 0;
    final replaced = <SongSubtitleCue>[];
    for (final cue in cues) {
      final originalTokens =
          cue.lineIndex >= 0 && cue.lineIndex < lineTokens.length
              ? lineTokens[cue.lineIndex]
              : const <String>[];
      final recognizedTokens = _wordsForCue(cue, words);
      final recognizedText = _recognizedTextFromWords(recognizedTokens);
      if (_shouldUseRecognizedText(
        cue: cue,
        originalTokens: originalTokens,
        recognizedTokens: recognizedTokens,
        recognizedText: recognizedText,
      )) {
        replacedCount += 1;
        replaced.add(
          SongSubtitleCue(
            lineIndex: cue.lineIndex,
            startMs: math.max(
              0,
              recognizedTokens.first.startMs - _matchedLineLeadInMs,
            ),
            endMs: recognizedTokens.last.endMs,
            english: recognizedText,
            chinese: '',
            confidence: cue.confidence,
            method: 'recognized',
          ),
        );
      } else {
        replaced.add(cue);
      }
    }
    return _RecognizedCueReplacement(
      cues: replaced,
      replacedCount: replacedCount,
    );
  }

  static List<_TimedToken> _wordsForCue(
    SongSubtitleCue cue,
    List<_TimedToken> words,
  ) =>
      words
          .where((word) => word.endMs > cue.startMs && word.startMs < cue.endMs)
          .toList(growable: false);

  static bool _shouldUseRecognizedText({
    required SongSubtitleCue cue,
    required List<String> originalTokens,
    required List<_TimedToken> recognizedTokens,
    required String recognizedText,
  }) {
    if (recognizedText.trim().isEmpty || recognizedTokens.isEmpty) {
      return false;
    }
    final recognizedNormalized = recognizedTokens
        .map((word) => word.normalized)
        .where((word) => word.isNotEmpty)
        .toList(growable: false);
    if (recognizedNormalized.isEmpty) {
      return false;
    }
    if (!_hasReliableRecognizedConfidence(recognizedTokens)) {
      return false;
    }
    final minWords = originalTokens.length <= 3 ? 1 : 2;
    if (recognizedNormalized.length < minWords) {
      return false;
    }
    final similarity = _orderedTokenSimilarity(
      originalTokens,
      recognizedNormalized,
    );
    if (cue.method == 'matched') {
      return false;
    }
    return similarity < _recognizedTextMismatchThreshold;
  }

  static bool _hasReliableRecognizedConfidence(List<_TimedToken> words) {
    final average = _averageKnownConfidence(words);
    return average == null || average >= _recognizedTextMinAverageConfidence;
  }

  static double _recognizedCueConfidence(
    List<_TimedToken> words, {
    required double fallback,
  }) {
    final average = _averageKnownConfidence(words);
    if (average == null) {
      return fallback.clamp(0.0, 1.0);
    }
    return average.clamp(0.0, 1.0);
  }

  static double? _averageKnownConfidence(List<_TimedToken> words) {
    final values = [
      for (final word in words)
        if (word.confidence != null)
          word.confidence!.clamp(0.0, 1.0).toDouble(),
    ];
    if (values.isEmpty) {
      return null;
    }
    return values.fold<double>(0, (sum, value) => sum + value) / values.length;
  }

  static double _orderedTokenSimilarity(
    List<String> expected,
    List<String> actual,
  ) {
    if (expected.isEmpty || actual.isEmpty) {
      return 0;
    }
    var cursor = 0;
    var score = 0.0;
    for (final token in expected) {
      var bestIndex = -1;
      var bestScore = 0.0;
      for (var i = cursor; i < actual.length; i += 1) {
        final candidate = _tokenSimilarity(token, actual[i]);
        if (candidate > bestScore) {
          bestScore = candidate;
          bestIndex = i;
        }
      }
      if (bestIndex >= 0 && bestScore >= 0.54) {
        score += bestScore;
        cursor = bestIndex + 1;
      }
    }
    return (score / math.max(expected.length, actual.length)).clamp(0.0, 1.0);
  }

  static String _recognizedTextFromWords(List<_TimedToken> words) {
    final parts = words
        .map((word) => word.text.trim())
        .where((word) => word.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) {
      return '';
    }
    var text = parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    text = text.replaceAllMapped(
      RegExp(r'\s+([,.;:!?])'),
      (match) => match.group(1) ?? '',
    );
    if (text.isEmpty) {
      return '';
    }
    final first = text.substring(0, 1);
    return '${first.toUpperCase()}${text.substring(1)}';
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
      final preciseBounds =
          cue.method == 'matched' || cue.method == 'recognized';
      final nextStart = i == cues.length - 1 ? durationMs : starts[i + 1];
      final preferredEnd =
          preciseBounds ? cue.endMs + _matchedLineTailMs : cue.endMs;
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

class _RecognizedCueReplacement {
  const _RecognizedCueReplacement({
    required this.cues,
    required this.replacedCount,
  });

  final List<SongSubtitleCue> cues;
  final int replacedCount;
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
  });

  final int firstWordIndex;
  final int lastWordIndex;
  final int startMs;
  final int endMs;
  final double confidence;
  final int matchedTokenCount;
  final int tokenCount;

  double get coverage =>
      tokenCount <= 0 ? 0 : matchedTokenCount / math.max(1, tokenCount);
}

class _LineOccurrence {
  const _LineOccurrence({
    required this.lineIndex,
    required this.match,
  });

  final int lineIndex;
  final _LineMatch match;
}
