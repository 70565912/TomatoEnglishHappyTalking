import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/logging/tomato_logger.dart';
import '../../../data/models/article_model.dart';
import '../../../data/models/learning_record_model.dart';
import '../../../shared/models/playback_visual_state.dart';
import '../../../services/api_cache_service.dart';
import '../../../services/database_service.dart';
import '../../../services/listening_audio_material_service.dart';
import '../../../services/nlp_service.dart';
import '../../../services/recognition_based_assessment_service.dart';
import '../../../services/scoring_service.dart';
import '../../../services/streaming_asr_service.dart';
import '../../../services/tts_memory_cache_service.dart';
import '../../../services/tts_service.dart' show TtsException;

part 'follow_read_provider.g.dart';

final followReadAssessmentEngineProvider = Provider<SpeechAssessmentEngine>(
    (ref) => RecognitionBasedAssessmentEngine());

// ---------------------------------------------------------------------------
// Step enum
// ---------------------------------------------------------------------------

enum FollowReadStep {
  idle, // ready — waiting for user action
  loadingTts, // checking cached TTS audio before playback
  playing, // playing TTS audio
  recording, // user is recording
  scoring, // recognizing audio and computing scores
  result, // showing recognition and evaluation result
  completed, // all sentences done
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class FollowReadState {
  final Article article;
  final int currentIndex;
  final FollowReadStep step;
  final PlaybackVisualState playbackState;
  final String? playbackError;
  final PronunciationResult? lastResult;
  final String? error;
  final String currentTranslation;
  final String? lastRecordingPath;
  final String liveRecognizedText;

  const FollowReadState({
    required this.article,
    required this.currentIndex,
    required this.step,
    this.playbackState = PlaybackVisualState.idle,
    this.playbackError,
    this.lastResult,
    this.error,
    this.currentTranslation = '',
    this.lastRecordingPath,
    this.liveRecognizedText = '',
  });

  String get currentSentence => article.sentences[currentIndex];
  bool get isLastSentence => currentIndex >= article.sentences.length - 1;
  int get totalSentences => article.sentences.length;

  FollowReadState copyWith({
    int? currentIndex,
    FollowReadStep? step,
    PlaybackVisualState? playbackState,
    String? playbackError,
    bool clearPlaybackError = false,
    PronunciationResult? lastResult,
    String? currentTranslation,
    bool clearCurrentTranslation = false,
    String? error,
    String? lastRecordingPath,
    bool clearLastRecordingPath = false,
    String? liveRecognizedText,
    bool clearLiveRecognizedText = false,
    bool clearResult = false,
    bool clearError = false,
  }) =>
      FollowReadState(
        article: article,
        currentIndex: currentIndex ?? this.currentIndex,
        step: step ?? this.step,
        playbackState: playbackState ?? this.playbackState,
        playbackError:
            clearPlaybackError ? null : (playbackError ?? this.playbackError),
        lastResult: clearResult ? null : (lastResult ?? this.lastResult),
        currentTranslation: clearCurrentTranslation
            ? ''
            : (currentTranslation ?? this.currentTranslation),
        error: clearError ? null : (error ?? this.error),
        lastRecordingPath: clearLastRecordingPath
            ? null
            : (lastRecordingPath ?? this.lastRecordingPath),
        liveRecognizedText: clearLiveRecognizedText
            ? ''
            : (liveRecognizedText ?? this.liveRecognizedText),
      );
}

class _CachedFollowRecording {
  const _CachedFollowRecording({
    required this.path,
    required this.recognizedText,
    required this.result,
  });

  final String path;
  final String recognizedText;
  final PronunciationResult result;
}

const _autoStopContractions = <String, String>{
  "i'm": 'i am',
  "you're": 'you are',
  "he's": 'he is',
  "she's": 'she is',
  "it's": 'it is',
  "we're": 'we are',
  "they're": 'they are',
  "i've": 'i have',
  "you've": 'you have',
  "we've": 'we have',
  "they've": 'they have',
  "i'll": 'i will',
  "you'll": 'you will',
  "he'll": 'he will',
  "she'll": 'she will',
  "it'll": 'it will',
  "we'll": 'we will',
  "they'll": 'they will',
  "i'd": 'i would',
  "you'd": 'you would',
  "he'd": 'he would',
  "she'd": 'she would',
  "we'd": 'we would',
  "they'd": 'they would',
  "can't": 'cannot',
  "won't": 'will not',
  "don't": 'do not',
  "doesn't": 'does not',
  "didn't": 'did not',
  "isn't": 'is not',
  "aren't": 'are not',
  "wasn't": 'was not',
  "weren't": 'were not',
  "couldn't": 'could not',
  "shouldn't": 'should not',
  "wouldn't": 'would not',
  "let's": 'let us',
};

const _autoStopHomophones = <String, String>{
  'too': 'to',
  'two': 'to',
  'four': 'for',
  'fore': 'for',
  'won': 'one',
  'our': 'hour',
  'ate': 'eight',
  'see': 'sea',
  'hear': 'here',
  'there': 'their',
  'theyre': 'their',
  'write': 'right',
  'buy': 'by',
  'bye': 'by',
};

const _autoStopOptionalEndingWords = <String>{'a', 'an', 'the'};

bool _shouldAutoStopRecording({
  required String referenceText,
  required String recognizedText,
}) {
  final referenceWords = _autoStopWords(referenceText);
  final recognizedWords = _autoStopWords(recognizedText);
  if (referenceWords.isEmpty || recognizedWords.isEmpty) {
    return false;
  }

  final minimumRecognizedWords = referenceWords.length <= 2
      ? referenceWords.length
      : math.min(referenceWords.length, 3);
  if (recognizedWords.length < minimumRecognizedWords) {
    return false;
  }

  final matchedCount = _orderedMatchCount(referenceWords, recognizedWords);
  final coverage = matchedCount / referenceWords.length;
  final requiredCoverage = referenceWords.length <= 4
      ? 0.78
      : referenceWords.length <= 8
          ? 0.68
          : 0.58;
  if (coverage < requiredCoverage) {
    return false;
  }

  final endingLength = referenceWords.length <= 3
      ? referenceWords.length
      : math.min(4, math.max(2, (referenceWords.length * 0.28).ceil()));
  return _hasApproximateEnding(
    referenceWords: referenceWords,
    recognizedWords: recognizedWords,
    endingLength: endingLength,
  );
}

List<String> _autoStopWords(String text) {
  var normalized = text
      .toLowerCase()
      .replaceAll('’', "'")
      .replaceAll('‘', "'")
      .replaceAll('`', "'");
  normalized = ' $normalized ';
  for (final entry in _autoStopContractions.entries) {
    normalized = normalized.replaceAll(
      RegExp('\\b${RegExp.escape(entry.key)}\\b'),
      ' ${entry.value} ',
    );
  }
  return RegExp(r'[a-z0-9]+').allMatches(normalized).map((match) {
    final word = match.group(0)!;
    return _autoStopHomophones[word] ?? word;
  }).toList(growable: false);
}

int _orderedMatchCount(List<String> referenceWords, List<String> spokenWords) {
  final previous = List<int>.filled(spokenWords.length + 1, 0);
  final current = List<int>.filled(spokenWords.length + 1, 0);
  for (final reference in referenceWords) {
    for (var j = 1; j <= spokenWords.length; j++) {
      if (_wordsSimilar(reference, spokenWords[j - 1])) {
        current[j] = previous[j - 1] + 1;
      } else {
        current[j] = math.max(previous[j], current[j - 1]);
      }
    }
    previous.setAll(0, current);
    for (var j = 0; j < current.length; j++) {
      current[j] = 0;
    }
  }
  return previous.last;
}

bool _hasApproximateEnding({
  required List<String> referenceWords,
  required List<String> recognizedWords,
  required int endingLength,
}) {
  if (endingLength <= 0 || recognizedWords.length < endingLength) {
    return false;
  }

  final referenceEnding =
      referenceWords.sublist(referenceWords.length - endingLength);
  final latestStart = recognizedWords.length - endingLength;
  final earliestStart = math.max(0, latestStart - 2);
  for (var start = earliestStart; start <= latestStart; start++) {
    final candidate = recognizedWords.sublist(start, start + endingLength);
    final matches = _pairwiseMatchCount(referenceEnding, candidate);
    final requiredMatches = endingLength <= 2 ? endingLength : endingLength - 1;
    if (matches >= requiredMatches &&
        _wordsSimilar(referenceEnding.last, candidate.last)) {
      return true;
    }
  }

  final referenceCompact = referenceEnding.join();
  for (var tailLength = endingLength;
      tailLength <= math.min(recognizedWords.length, endingLength + 2);
      tailLength++) {
    final candidateCompact =
        recognizedWords.sublist(recognizedWords.length - tailLength).join();
    if (_similarity(referenceCompact, candidateCompact) >= 0.78) {
      return true;
    }
  }
  final relaxedReferenceEnding = referenceEnding
      .where((word) => !_autoStopOptionalEndingWords.contains(word))
      .toList(growable: false);
  if (relaxedReferenceEnding.isNotEmpty &&
      relaxedReferenceEnding.length < referenceEnding.length &&
      _hasApproximateEnding(
        referenceWords: relaxedReferenceEnding,
        recognizedWords: recognizedWords,
        endingLength: relaxedReferenceEnding.length,
      )) {
    return true;
  }
  return false;
}

int _pairwiseMatchCount(List<String> left, List<String> right) {
  var matches = 0;
  for (var i = 0; i < left.length && i < right.length; i++) {
    if (_wordsSimilar(left[i], right[i])) {
      matches++;
    }
  }
  return matches;
}

bool _wordsSimilar(String expected, String actual) {
  if (expected == actual) {
    return true;
  }
  if (expected.length <= 2 || actual.length <= 2) {
    return false;
  }
  return _similarity(expected, actual) >= 0.76;
}

double _similarity(String left, String right) {
  if (left == right) {
    return 1;
  }
  if (left.isEmpty || right.isEmpty) {
    return 0;
  }
  final distance = _levenshteinDistance(left, right);
  final longest = math.max(left.length, right.length);
  return 1 - distance / longest;
}

int _levenshteinDistance(String left, String right) {
  final previous = List<int>.generate(right.length + 1, (index) => index);
  final current = List<int>.filled(right.length + 1, 0);
  for (var i = 0; i < left.length; i++) {
    current[0] = i + 1;
    for (var j = 0; j < right.length; j++) {
      final substitutionCost =
          left.codeUnitAt(i) == right.codeUnitAt(j) ? 0 : 1;
      current[j + 1] = math.min(
        math.min(current[j] + 1, previous[j + 1] + 1),
        previous[j] + substitutionCost,
      );
    }
    previous.setAll(0, current);
  }
  return previous.last;
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

@riverpod
class FollowRead extends _$FollowRead {
  static const _audioTraceEnabled = bool.fromEnvironment(
    'TOMATO_AUDIO_TRACE',
    defaultValue: false,
  );
  static const _autoStopDelay = Duration(milliseconds: 480);

  @visibleForTesting
  static bool shouldAutoStopRecordingForTest({
    required String referenceText,
    required String recognizedText,
  }) =>
      _shouldAutoStopRecording(
        referenceText: referenceText,
        recognizedText: recognizedText,
      );

  AudioPlayer? _player;
  AudioRecorder? _recorder;
  String? _recordingPath;
  BytesBuilder? _recordingPcmBuilder;
  StreamController<List<int>>? _recordingAsrController;
  StreamSubscription<Uint8List>? _recordingStreamSub;
  Completer<void>? _recordingStreamDone;
  Future<String>? _liveRecognitionFuture;
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<ProcessingState>? _processingStateSub;
  StreamSubscription<Object>? _playbackErrorSub;
  Timer? _autoStopRecordingTimer;
  int _playbackToken = 0;
  bool _pausedForWord = false;
  bool _autoStopRecordingTriggered = false;
  @override
  Future<FollowReadState> build(int articleId) async {
    ref.onDispose(_cleanup);

    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) throw Exception('文章不存在（id=$articleId）');
    final article = await _articleWithCurrentSentences(rawArticle);
    final initialSentence = article.sentences.first;
    final initialTranslation = await _savedTranslationFor(
      articleId: article.id,
      sentenceIndex: 0,
      sentence: initialSentence,
    );
    final initialRecording =
        await _latestRecordingFor(index: 0, sentence: initialSentence);

    _recorder = AudioRecorder();

    return FollowReadState(
      article: article,
      currentIndex: 0,
      step: FollowReadStep.idle,
      playbackState: PlaybackVisualState.idle,
      currentTranslation: initialTranslation,
      lastResult: initialRecording?.result,
      lastRecordingPath: initialRecording?.path,
      liveRecognizedText: initialRecording?.recognizedText ?? '',
    );
  }

  void _cleanup() {
    _playbackToken++;
    _pausedForWord = false;
    unawaited(_disposePlayer());
    unawaited(_cleanupRecordingStream());
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) {
      unawaited(recorder.dispose());
    }
  }

  void _bindPlayerTrace() {
    _playerStateSub?.cancel();
    _processingStateSub?.cancel();
    _playbackErrorSub?.cancel();
    _playerStateSub = null;
    _processingStateSub = null;
    _playbackErrorSub = null;

    if (!_audioTraceEnabled) {
      return;
    }

    final player = _player;
    if (player == null) {
      return;
    }

    _playerStateSub = player.playerStateStream.listen((event) {
      _trace(
        'playerState playing=${event.playing} processing=${event.processingState.name}',
      );
    });

    _processingStateSub = player.processingStateStream.listen((event) {
      _trace('processingState ${event.name}');
    });

    _playbackErrorSub = player.playbackEventStream.listen(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _trace('playbackEvent error=$error');
      },
    );
  }

  FollowReadState get _s => state.requireValue;

  // ---- Play TTS for the current sentence ----
  Future<void> playCurrent() async {
    if (_s.step != FollowReadStep.idle && _s.step != FollowReadStep.result) {
      return;
    }

    final token = ++_playbackToken;
    _pausedForWord = false;
    final index = _s.currentIndex;
    final sentence = _s.currentSentence;
    _trace(
        'playCurrent start idx=$index chars=${sentence.length} token=$token');
    _set(
      step: FollowReadStep.loadingTts,
      playbackState: PlaybackVisualState.waitingStart,
      clearPlaybackError: true,
      clearResult: true,
      clearError: true,
    );

    try {
      final source = await _cachedTtsSource(index: index, sentence: sentence);
      if (!_isActivePlayback(token, index)) {
        return;
      }

      await _playSourceWithRecovery(
        source: source,
        token: token,
        index: index,
      );
      await _disposePlayer();

      if (!_isActivePlayback(token, index)) {
        return;
      }
      _trace('playCurrent completed idx=$index token=$token');
    } on TimeoutException {
      await _disposePlayer();
      if (!_isActivePlayback(token, index)) {
        return;
      }
      _set(
        step: FollowReadStep.idle,
        playbackState: PlaybackVisualState.failed,
        playbackError: '播放超时，请重试',
        error: '播放超时：请重试播放原音',
      );
      _trace('playCurrent timeout idx=$index token=$token');
      return;
    } catch (e) {
      await _disposePlayer();
      if (!_isActivePlayback(token, index)) {
        return;
      }
      final message = _friendlyPlaybackError(e);
      _trace('playCurrent failed idx=$index token=$token error=$e');
      _set(
        step: FollowReadStep.idle,
        playbackState: PlaybackVisualState.failed,
        playbackError: message,
        error: '播放失败：$message',
      );
      return;
    }

    _set(
      step: FollowReadStep.idle,
      playbackState: PlaybackVisualState.success,
      clearPlaybackError: true,
    );
  }

  Future<Article> _articleWithCurrentSentences(Article article) async {
    final sentences = NlpService.splitSentences(article.content);
    if (sentences.isEmpty || listEquals(article.sentences, sentences)) {
      return article;
    }

    final id = article.id;
    if (id != null) {
      await DatabaseService.updateArticleSentences(id, sentences);
    }
    return article.copyWith(sentences: sentences);
  }

  Future<AudioSource> _cachedTtsSource({
    required int index,
    required String sentence,
  }) async {
    final key = '${articleId}_${index}_${_stableTextHash(sentence)}';
    final handle = await TtsMemoryCacheService.cachedFileHandle(
      text: sentence,
      articleId: articleId,
      cachePurpose: ListeningAudioMaterialService.cachePurpose,
    );
    if (handle == null) {
      throw const TtsException(
        ListeningAudioMaterialService.missingMaterialMessage,
      );
    }
    _trace('tts key=$key path=${handle.filePath}');
    return handle.toAudioSource();
  }

  Future<void> _playSourceWithRecovery({
    required AudioSource source,
    required int token,
    required int index,
  }) async {
    Object? lastError;
    StackTrace? lastStackTrace;

    for (var attempt = 1; attempt <= 2; attempt++) {
      if (!_isActivePlayback(token, index)) {
        return;
      }

      try {
        await _playFileOnce(
          source: source,
          token: token,
          index: index,
          attempt: attempt,
        );
        return;
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        _trace('playback attempt=$attempt failed error=$error');
        await _disposePlayer();
        if (attempt == 1) {
          continue;
        }
      }
    }

    if (lastError != null && lastStackTrace != null) {
      Error.throwWithStackTrace(lastError, lastStackTrace);
    }
  }

  Future<void> _playFileWithRecovery({
    required String path,
    required int token,
    required int index,
  }) =>
      _playSourceWithRecovery(
        source: AudioSource.file(path),
        token: token,
        index: index,
      );

  Future<void> _playFileOnce({
    required AudioSource source,
    required int token,
    required int index,
    required int attempt,
  }) async {
    final player = await _createFreshPlayer();
    final playbackStarted = Completer<void>();
    final playbackDone = Completer<void>();
    StreamSubscription<Duration>? positionSub;
    StreamSubscription<PlayerState>? stateSub;
    StreamSubscription<PlaybackEvent>? playbackEventSub;
    Timer? durationFallbackTimer;
    var playCommandIssued = false;
    Duration lastPosition = Duration.zero;
    Duration? mediaDuration;

    void completeStarted() {
      if (!playbackStarted.isCompleted) {
        playbackStarted.complete();
      }
      final duration = mediaDuration;
      if (duration != null &&
          duration > Duration.zero &&
          durationFallbackTimer == null) {
        durationFallbackTimer = Timer(
          duration + const Duration(milliseconds: 900),
          () {
            if (_isActivePlayback(token, index)) {
              completeStarted();
              if (!playbackDone.isCompleted) {
                playbackDone.complete();
              }
            }
          },
        );
      }
    }

    void completeDone() {
      completeStarted();
      if (!playbackDone.isCompleted) {
        playbackDone.complete();
      }
    }

    void completeError(Object error, StackTrace stackTrace) {
      if (!playbackStarted.isCompleted) {
        playbackStarted.completeError(error, stackTrace);
      }
      if (!playbackDone.isCompleted) {
        playbackDone.completeError(error, stackTrace);
      }
    }

    try {
      await player.setAudioSource(source).timeout(const Duration(seconds: 10));
      await player.seek(Duration.zero).timeout(const Duration(seconds: 3));
      mediaDuration = player.duration;
      _trace(
        'playback loaded idx=$index attempt=$attempt duration=${mediaDuration?.inMilliseconds ?? 0}ms',
      );

      stateSub = player.playerStateStream.listen((event) {
        if (!_isActivePlayback(token, index)) {
          completeDone();
          return;
        }
        mediaDuration = player.duration ?? mediaDuration;

        if (playCommandIssued && event.playing) {
          completeStarted();
        }

        if (event.processingState == ProcessingState.completed) {
          completeDone();
          return;
        }
      });

      positionSub = player.positionStream.listen((position) {
        if (!_isActivePlayback(token, index)) {
          completeDone();
          return;
        }
        lastPosition = position;
        mediaDuration = player.duration ?? mediaDuration;

        if (playCommandIssued && position > const Duration(milliseconds: 120)) {
          completeStarted();
        }

        final duration = mediaDuration;
        if (duration != null &&
            duration > Duration.zero &&
            position >= duration - const Duration(milliseconds: 180)) {
          completeDone();
        }
      });

      playbackEventSub = player.playbackEventStream.listen(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          if (_isActivePlayback(token, index)) {
            completeError(error, stackTrace);
          }
        },
      );

      final playFuture = player.play();
      playCommandIssued = true;
      unawaited(playFuture.catchError(completeError));

      await playbackStarted.future.timeout(const Duration(seconds: 6));
      if (!_isActivePlayback(token, index)) {
        return;
      }
      _set(
        step: FollowReadStep.playing,
        playbackState: PlaybackVisualState.playing,
        clearPlaybackError: true,
      );
      _trace(
        'playback started idx=$index attempt=$attempt at=${lastPosition.inMilliseconds}ms',
      );

      await playbackDone.future.timeout(_playbackTimeout(mediaDuration));
      if (!_isActivePlayback(token, index)) {
        return;
      }
      await player.stop().timeout(const Duration(seconds: 3));
    } finally {
      durationFallbackTimer?.cancel();
      await stateSub?.cancel();
      await positionSub?.cancel();
      await playbackEventSub?.cancel();
    }
  }

  Future<AudioPlayer> _createFreshPlayer() async {
    await _disposePlayer();
    final player = AudioPlayer();
    _player = player;
    _bindPlayerTrace();
    return player;
  }

  Future<void> _disposePlayer() async {
    _pausedForWord = false;
    await _playerStateSub?.cancel();
    await _processingStateSub?.cancel();
    await _playbackErrorSub?.cancel();
    _playerStateSub = null;
    _processingStateSub = null;
    _playbackErrorSub = null;

    final player = _player;
    _player = null;
    if (player == null) {
      return;
    }

    try {
      await player.stop().timeout(const Duration(seconds: 2));
    } catch (e) {
      _trace('player stop ignored error=$e');
    }
    try {
      await player.dispose().timeout(const Duration(seconds: 2));
    } catch (e) {
      _trace('player dispose ignored error=$e');
    }
  }

  bool _isActivePlayback(int token, int index) =>
      token == _playbackToken &&
      state.hasValue &&
      _s.currentIndex == index &&
      (_s.step == FollowReadStep.loadingTts ||
          _s.step == FollowReadStep.playing);

  Duration _playbackTimeout(Duration? duration) {
    if (duration == null || duration <= Duration.zero) {
      return const Duration(seconds: 30);
    }

    final timeout = duration + const Duration(seconds: 8);
    if (timeout < const Duration(seconds: 12)) {
      return const Duration(seconds: 12);
    }
    if (timeout > const Duration(seconds: 45)) {
      return const Duration(seconds: 45);
    }
    return timeout;
  }

  int _stableTextHash(String text) {
    var hash = 0x811c9dc5;
    for (final codeUnit in text.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toUnsigned(32);
  }

  String _friendlyPlaybackError(Object error) {
    if (error is TtsException) {
      return error.message;
    }
    if (error is TimeoutException) {
      return '播放超时，请重试';
    }
    return '语音播放失败，请重试';
  }

  // ---- Start microphone recording ----
  Future<void> startRecording() async {
    if (_s.step != FollowReadStep.idle && _s.step != FollowReadStep.result) {
      return;
    }
    _playbackToken++;
    unawaited(_disposePlayer());
    _cancelAutoStopRecording(resetTrigger: true);

    final hasPermission = await _recorder!.hasPermission();
    if (!hasPermission) {
      _set(error: '未获得麦克风权限，请在系统设置中允许');
      return;
    }

    final path =
        '${Directory.systemTemp.path}/rec_${_s.currentIndex}_${DateTime.now().millisecondsSinceEpoch}.wav';
    _recordingPath = path;
    _recordingPcmBuilder = BytesBuilder(copy: false);

    final asrController = StreamController<List<int>>();
    _recordingAsrController = asrController;
    _liveRecognitionFuture = StreamingAsrService.recognizeLive(
      audioChunks: asrController.stream,
      onPartial: _updateLiveRecognizedText,
    ).catchError((Object error, StackTrace stackTrace) {
      TomatoLogger.warn(
        category: 'follow',
        event: 'live_recognition.start_failed',
        articleId: _s.article.id,
        error: error,
        stackTrace: stackTrace,
      );
      return '';
    });

    final stream = await _recorder!.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        streamBufferSize: 3200,
      ),
    );

    final done = Completer<void>();
    _recordingStreamDone = done;
    _recordingStreamSub = stream.listen(
      (data) {
        if (data.isEmpty) {
          return;
        }
        _recordingPcmBuilder?.add(data);
        _recordingAsrController?.add(data);
      },
      onDone: () {
        _closeRecordingAsrInput();
        if (!done.isCompleted) {
          done.complete();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _recordingAsrController?.addError(error, stackTrace);
        _closeRecordingAsrInput();
        if (!done.isCompleted) {
          done.completeError(error, stackTrace);
        }
      },
    );

    _set(
      step: FollowReadStep.recording,
      clearResult: true,
      clearError: true,
      clearLastRecordingPath: true,
      clearLiveRecognizedText: true,
    );
  }

  // ---- Stop recording and submit for scoring ----
  Future<void> stopRecordingAndScore() async {
    if (_s.step != FollowReadStep.recording) return;
    _cancelAutoStopRecording(resetTrigger: false);

    final path = _recordingPath;
    await _recorder!.stop();
    await _waitRecordingStreamDone();
    await _recordingStreamSub?.cancel();
    _recordingStreamSub = null;
    _recordingStreamDone = null;
    _closeRecordingAsrInput();
    _set(step: FollowReadStep.scoring);

    try {
      final pcmBytes = _recordingPcmBuilder?.takeBytes() ?? Uint8List(0);
      _recordingPcmBuilder = null;
      final audioBytes = _wavBytesFromPcm(pcmBytes);
      if (path != null && audioBytes.isNotEmpty) {
        await File(path).writeAsBytes(audioBytes, flush: true);
      }

      final assessmentEngine = ref.read(followReadAssessmentEngineProvider);
      final recognizedText = await _finishLiveRecognition();
      late final PronunciationResult result;
      if (assessmentEngine is RecognitionBasedAssessmentEngine) {
        final resolvedRecognizedText = recognizedText.trim().isNotEmpty
            ? recognizedText
            : await StreamingAsrService.recognize(
                audioBytes: audioBytes,
                articleId: _s.article.id,
              );
        result = assessmentEngine.assessRecognizedText(
          referenceText: _s.currentSentence,
          recognizedText: resolvedRecognizedText,
        );
      } else {
        result = await assessmentEngine.assess(
          audioBytes: audioBytes,
          referenceText: _s.currentSentence,
        );
      }

      final aid = _s.article.id;
      var durableRecordingPath = path;
      if (aid != null) {
        await DatabaseService.saveLearningRecord(
          LearningRecord(
            articleId: aid,
            sentence: _s.currentSentence,
            overallScore: result.overallScore,
            accuracyScore: result.accuracyScore,
            fluencyScore: result.fluencyScore,
            completenessScore: result.completenessScore,
            prosodyScore: result.prosodyScore,
            createdAt: DateTime.now(),
          ),
        );
        durableRecordingPath =
            await ApiCacheService.saveLatestSentenceRecording(
          articleId: aid,
          sentenceIndex: _s.currentIndex,
          sentence: _s.currentSentence,
          audioBytes: audioBytes,
          recognizedText: result.recognizedText,
          resultJson: jsonEncode(_resultToJson(result)),
        );
      }

      state = AsyncValue.data(
        _s.copyWith(
          step: FollowReadStep.result,
          lastResult: result,
          lastRecordingPath: durableRecordingPath?.isNotEmpty == true
              ? durableRecordingPath
              : path,
          liveRecognizedText: result.recognizedText,
        ),
      );
    } catch (e, stackTrace) {
      TomatoLogger.error(
        category: 'follow',
        event: 'scoring.failed',
        articleId: _s.article.id,
        error: e,
        stackTrace: stackTrace,
      );
      _recordingPcmBuilder = null;
      _set(step: FollowReadStep.idle, error: _friendlyScoringError(e));
    }
  }

  String _friendlyScoringError(Object error) {
    final message = error.toString();
    if (message.contains('未返回识别结果') || message.contains('empty')) {
      return '这次没有听清楚，请靠近麦克风，再读一遍试试。';
    }
    if (message.contains('权限') || message.contains('permission')) {
      return '还不能录音，请在系统设置里允许麦克风权限。';
    }
    if (message.contains('网络') ||
        message.contains('WebSocket') ||
        message.contains('API') ||
        message.contains('配置')) {
      return '语音识别暂时连不上，请检查网络和本机语音配置后再试。';
    }
    return '这次评分没有成功，请再试一次。';
  }

  Future<_CachedFollowRecording?> _latestRecordingFor({
    required int index,
    required String sentence,
  }) async {
    final aid = articleId;
    final recording = await ApiCacheService.getLatestSentenceRecording(
      articleId: aid,
      sentenceIndex: index,
    );
    if (recording == null || recording.sentence.trim() != sentence.trim()) {
      return null;
    }

    final result = _resultFromJson(recording.resultJson);
    if (result == null) {
      return null;
    }
    return _CachedFollowRecording(
      path: recording.recordingPath,
      recognizedText: recording.recognizedText,
      result: result,
    );
  }

  Map<String, dynamic> _resultToJson(PronunciationResult result) => {
        'overallScore': result.overallScore,
        'accuracyScore': result.accuracyScore,
        'fluencyScore': result.fluencyScore,
        'completenessScore': result.completenessScore,
        'prosodyScore': result.prosodyScore,
        'recognizedText': result.recognizedText,
        'isMock': result.isMock,
        'words': result.words
            .map(
              (word) => {
                'word': word.word,
                'score': word.score,
                'errorType': word.errorType,
              },
            )
            .toList(growable: false),
      };

  PronunciationResult? _resultFromJson(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        return null;
      }
      final words = decoded['words'];
      return PronunciationResult(
        overallScore: _jsonDouble(decoded['overallScore']),
        accuracyScore: _jsonDouble(decoded['accuracyScore']),
        fluencyScore: _jsonDouble(decoded['fluencyScore']),
        completenessScore: _jsonDouble(decoded['completenessScore']),
        prosodyScore: _jsonDouble(decoded['prosodyScore']),
        recognizedText: decoded['recognizedText']?.toString() ?? '',
        isMock: decoded['isMock'] == true,
        words: words is List
            ? words
                .whereType<Map>()
                .map(
                  (word) => WordScore(
                    word: word['word']?.toString() ?? '',
                    score: _jsonDouble(word['score']),
                    errorType: word['errorType']?.toString() ?? 'None',
                  ),
                )
                .where((word) => word.word.isNotEmpty)
                .toList(growable: false)
            : const [],
      );
    } catch (_) {
      return null;
    }
  }

  double _jsonDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  // ---- Advance to next sentence ----
  Future<void> nextSentence() async {
    _playbackToken++;
    unawaited(_disposePlayer());
    if (_s.isLastSentence) {
      _set(step: FollowReadStep.completed, clearResult: true);
    } else {
      final nextIndex = _s.currentIndex + 1;
      final nextSentence = _s.article.sentences[nextIndex];
      final nextTranslation = await _savedTranslationFor(
        articleId: _s.article.id,
        sentenceIndex: nextIndex,
        sentence: nextSentence,
      );
      final latestRecording = await _latestRecordingFor(
        index: nextIndex,
        sentence: nextSentence,
      );
      state = AsyncValue.data(
        _s.copyWith(
          currentIndex: nextIndex,
          step: FollowReadStep.idle,
          playbackState: PlaybackVisualState.idle,
          clearPlaybackError: true,
          lastResult: latestRecording?.result,
          clearResult: latestRecording == null,
          clearError: true,
          lastRecordingPath: latestRecording?.path,
          clearLastRecordingPath: latestRecording == null,
          liveRecognizedText: latestRecording?.recognizedText,
          clearLiveRecognizedText: latestRecording == null,
          currentTranslation: nextTranslation,
        ),
      );
    }
  }

  Future<String> _savedTranslationFor({
    required int? articleId,
    required int sentenceIndex,
    required String sentence,
  }) async {
    if (articleId == null) {
      return '';
    }
    final translation = await DatabaseService.getArticleSentenceTranslation(
      articleId,
      sentenceIndex,
      sentence,
    );
    return translation?.trim() ?? '';
  }

  // ---- Re-try current sentence ----
  Future<bool> pauseCurrentPlayback() async {
    final player = _player;
    if (player == null || _s.step != FollowReadStep.playing) {
      return false;
    }
    if (_pausedForWord) {
      return true;
    }

    try {
      await player.pause().timeout(const Duration(seconds: 2));
      _pausedForWord = true;
      return true;
    } catch (error) {
      _trace('pause playback failed error=$error');
      return false;
    }
  }

  Future<bool> resumeCurrentPlayback() async {
    final player = _player;
    if (player == null || !_pausedForWord) {
      _pausedForWord = false;
      return false;
    }

    _pausedForWord = false;
    unawaited(player.play().catchError((Object error) {
      _trace('resume playback failed error=$error');
    }));
    return true;
  }

  void retry() {
    _playbackToken++;
    _pausedForWord = false;
    unawaited(_disposePlayer());
    _set(
      step: FollowReadStep.idle,
      playbackState: PlaybackVisualState.idle,
      clearPlaybackError: true,
      clearResult: true,
      clearError: true,
      clearLastRecordingPath: true,
      clearLiveRecognizedText: true,
    );
  }

  Future<void> replayCurrentSentence() async {
    if (_s.step != FollowReadStep.idle && _s.step != FollowReadStep.result) {
      return;
    }
    await playCurrent();
  }

  Future<void> replayLastRecording() async {
    if (_s.step != FollowReadStep.idle && _s.step != FollowReadStep.result) {
      return;
    }

    final path = _s.lastRecordingPath;
    if (path == null || path.trim().isEmpty || !await File(path).exists()) {
      _set(error: '还没有可播放的录音，请先录一句。');
      return;
    }

    final token = ++_playbackToken;
    _pausedForWord = false;
    final index = _s.currentIndex;
    _set(
      step: FollowReadStep.playing,
      playbackState: PlaybackVisualState.waitingStart,
      clearPlaybackError: true,
      clearError: true,
    );

    try {
      await _playFileWithRecovery(path: path, token: token, index: index);
      await _disposePlayer();
      if (!_isActivePlayback(token, index)) {
        return;
      }
      _set(
        step: FollowReadStep.result,
        playbackState: PlaybackVisualState.success,
        clearPlaybackError: true,
      );
    } on TimeoutException {
      await _disposePlayer();
      if (!_isActivePlayback(token, index)) {
        return;
      }
      _set(
        step: FollowReadStep.result,
        playbackState: PlaybackVisualState.failed,
        playbackError: '录音播放超时，请重试',
        error: '录音播放超时，请重试',
      );
    } catch (error) {
      await _disposePlayer();
      if (!_isActivePlayback(token, index)) {
        return;
      }
      final message = _friendlyPlaybackError(error);
      _set(
        step: FollowReadStep.result,
        playbackState: PlaybackVisualState.failed,
        playbackError: message,
        error: '录音播放失败：$message',
      );
    }
  }

  // ---- Internal helper ----
  void _set({
    FollowReadStep? step,
    PlaybackVisualState? playbackState,
    String? playbackError,
    bool clearPlaybackError = false,
    String? error,
    bool clearResult = false,
    bool clearError = false,
    String? lastRecordingPath,
    bool clearLastRecordingPath = false,
    String? liveRecognizedText,
    bool clearLiveRecognizedText = false,
  }) {
    if (_audioTraceEnabled) {
      _trace(
        'state ${_s.step.name} -> ${(step ?? _s.step).name} '
        'playback ${_s.playbackState.name} -> ${(playbackState ?? _s.playbackState).name} '
        'idx=${_s.currentIndex} '
        'error=${error ?? '-'} '
        'clearResult=$clearResult clearError=$clearError',
      );
    }

    state = AsyncValue.data(
      _s.copyWith(
        step: step,
        playbackState: playbackState,
        playbackError: playbackError,
        clearPlaybackError: clearPlaybackError,
        error: error,
        clearResult: clearResult,
        clearError: clearError,
        lastRecordingPath: lastRecordingPath,
        clearLastRecordingPath: clearLastRecordingPath,
        liveRecognizedText: liveRecognizedText,
        clearLiveRecognizedText: clearLiveRecognizedText,
      ),
    );
  }

  void _updateLiveRecognizedText(String text) {
    final normalized = text.trim();
    if (normalized.isEmpty || !state.hasValue) {
      return;
    }

    final current = _s;
    if (current.step != FollowReadStep.recording &&
        current.step != FollowReadStep.scoring) {
      return;
    }

    state = AsyncValue.data(
      current.copyWith(liveRecognizedText: normalized, clearError: true),
    );

    if (current.step == FollowReadStep.recording &&
        _shouldAutoStopRecording(
          referenceText: current.currentSentence,
          recognizedText: normalized,
        )) {
      _scheduleAutoStopRecording(normalized);
    }
  }

  void _scheduleAutoStopRecording(String matchedText) {
    if (_autoStopRecordingTriggered || _autoStopRecordingTimer != null) {
      return;
    }

    _autoStopRecordingTriggered = true;
    _autoStopRecordingTimer = Timer(_autoStopDelay, () {
      _autoStopRecordingTimer = null;
      if (!state.hasValue) {
        _autoStopRecordingTriggered = false;
        return;
      }

      final current = _s;
      if (current.step != FollowReadStep.recording) {
        return;
      }

      final latestRecognized = current.liveRecognizedText.trim().isNotEmpty
          ? current.liveRecognizedText
          : matchedText;
      if (!_shouldAutoStopRecording(
        referenceText: current.currentSentence,
        recognizedText: latestRecognized,
      )) {
        _autoStopRecordingTriggered = false;
        return;
      }

      TomatoLogger.info(
        category: 'follow',
        event: 'recording.auto_stop',
        articleId: current.article.id,
        data: {
          'sentenceIndex': current.currentIndex,
          'recognizedWords': _autoStopWords(latestRecognized).length,
        },
      );
      unawaited(stopRecordingAndScore());
    });
  }

  void _cancelAutoStopRecording({required bool resetTrigger}) {
    _autoStopRecordingTimer?.cancel();
    _autoStopRecordingTimer = null;
    if (resetTrigger) {
      _autoStopRecordingTriggered = false;
    }
  }

  Future<String> _finishLiveRecognition() async {
    final future = _liveRecognitionFuture;
    _liveRecognitionFuture = null;
    if (future == null) {
      return '';
    }

    try {
      return await future.timeout(const Duration(seconds: 10));
    } catch (e, stackTrace) {
      TomatoLogger.warn(
        category: 'follow',
        event: 'live_recognition.failed',
        articleId: _s.article.id,
        error: e,
        stackTrace: stackTrace,
      );
      return '';
    }
  }

  Future<void> _waitRecordingStreamDone() async {
    final done = _recordingStreamDone;
    if (done == null) {
      return;
    }

    try {
      await done.future.timeout(const Duration(seconds: 3));
    } catch (e, stackTrace) {
      TomatoLogger.warn(
        category: 'recording',
        event: 'stream_finish.ignored',
        articleId: _s.article.id,
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  void _closeRecordingAsrInput() {
    final controller = _recordingAsrController;
    _recordingAsrController = null;
    if (controller == null || controller.isClosed) {
      return;
    }
    unawaited(controller.close());
  }

  Future<void> _cleanupRecordingStream() async {
    _cancelAutoStopRecording(resetTrigger: true);
    await _recordingStreamSub?.cancel();
    _recordingStreamSub = null;
    _recordingStreamDone = null;
    _closeRecordingAsrInput();
    _recordingPcmBuilder = null;
    _liveRecognitionFuture = null;
  }

  Uint8List _wavBytesFromPcm(
    List<int> pcmBytes, {
    int sampleRate = 16000,
    int channels = 1,
  }) {
    final dataLength = pcmBytes.length;
    final byteRate = sampleRate * channels * 2;
    final blockAlign = channels * 2;
    final header = ByteData(44);
    final bytes = header.buffer.asUint8List();

    void writeAscii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        bytes[offset + i] = value.codeUnitAt(i);
      }
    }

    writeAscii(0, 'RIFF');
    header.setUint32(4, 36 + dataLength, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, 16, Endian.little);
    writeAscii(36, 'data');
    header.setUint32(40, dataLength, Endian.little);

    final builder = BytesBuilder(copy: false)
      ..add(bytes)
      ..add(pcmBytes);
    return builder.toBytes();
  }

  void _trace(String message) {
    if (!_audioTraceEnabled) {
      return;
    }
    TomatoLogger.trace(
      category: 'follow',
      event: 'trace',
      articleId: _s.article.id,
      message: message,
      data: {'tag': 'FollowReadTrace'},
      force: true,
    );
  }
}
