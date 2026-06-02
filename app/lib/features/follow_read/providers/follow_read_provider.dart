import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../data/models/article_model.dart';
import '../../../data/models/learning_record_model.dart';
import '../../../shared/models/playback_visual_state.dart';
import '../../../services/database_service.dart';
import '../../../services/nlp_service.dart';
import '../../../services/recognition_based_assessment_service.dart';
import '../../../services/scoring_service.dart';
import '../../../services/tts_service.dart';
import '../../../services/translation_service.dart';

part 'follow_read_provider.g.dart';

final followReadAssessmentEngineProvider = Provider<SpeechAssessmentEngine>(
    (ref) => RecognitionBasedAssessmentEngine());

// ---------------------------------------------------------------------------
// Step enum
// ---------------------------------------------------------------------------

enum FollowReadStep {
  idle, // ready — waiting for user action
  loadingTts, // fetching TTS audio from cloud
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

  const FollowReadState({
    required this.article,
    required this.currentIndex,
    required this.step,
    this.playbackState = PlaybackVisualState.idle,
    this.playbackError,
    this.lastResult,
    this.error,
    this.currentTranslation = '',
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
      );
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

  AudioPlayer? _player;
  AudioRecorder? _recorder;
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<ProcessingState>? _processingStateSub;
  StreamSubscription<Object>? _playbackErrorSub;
  final Map<String, String> _ttsPathCache = {};
  int _playbackToken = 0;
  @override
  Future<FollowReadState> build(int articleId) async {
    ref.onDispose(_cleanup);

    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) throw Exception('文章不存在（id=$articleId）');
    final article = await _articleWithCurrentSentences(rawArticle);
    final initialSentence = article.sentences.first;
    final initialTranslation =
        (await TranslationService.toChinese(initialSentence)).trim();

    _recorder = AudioRecorder();

    return FollowReadState(
      article: article,
      currentIndex: 0,
      step: FollowReadStep.idle,
      playbackState: PlaybackVisualState.idle,
      currentTranslation: initialTranslation,
    );
  }

  void _cleanup() {
    _playbackToken++;
    _ttsPathCache.clear();
    unawaited(_disposePlayer());
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
      final path = await _cachedTtsPath(index: index, sentence: sentence);
      if (!_isActivePlayback(token, index)) {
        return;
      }

      await _playFileWithRecovery(
        path: path,
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

  Future<String> _cachedTtsPath({
    required int index,
    required String sentence,
  }) async {
    final key = '${articleId}_${index}_${_stableTextHash(sentence)}';
    final cachedPath = _ttsPathCache[key];
    if (cachedPath != null && await File(cachedPath).exists()) {
      _trace('tts cache hit key=$key path=$cachedPath');
      return cachedPath;
    }

    final bytes = await TtsService.synthesize(text: sentence);
    if (bytes == null || bytes.isEmpty) {
      throw const TtsException('TTS 未返回音频数据');
    }

    final path = '${Directory.systemTemp.path}/tomato_follow_tts_$key.mp3';
    _trace('tts bytes=${bytes.length} key=$key path=$path');
    await File(path).writeAsBytes(bytes, flush: true);
    _ttsPathCache[key] = path;
    return path;
  }

  Future<void> _playFileWithRecovery({
    required String path,
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
          path: path,
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

  Future<void> _playFileOnce({
    required String path,
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
    var playCommandIssued = false;
    var progressObserved = false;
    Duration lastPosition = Duration.zero;
    Duration? mediaDuration;

    void completeStarted() {
      if (!playbackStarted.isCompleted) {
        playbackStarted.complete();
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
      await player.setFilePath(path).timeout(const Duration(seconds: 10));
      await player.seek(Duration.zero).timeout(const Duration(seconds: 3));
      mediaDuration = player.duration;
      _trace(
        'playback loaded idx=$index attempt=$attempt duration=${mediaDuration?.inMilliseconds ?? 0}ms',
      );

      stateSub = player.playerStateStream.listen((event) {
        if (!_isActivePlayback(token, index)) {
          return;
        }
        mediaDuration = player.duration ?? mediaDuration;

        if (playCommandIssued && event.playing) {
          completeStarted();
        }

        if (event.processingState == ProcessingState.completed) {
          progressObserved = true;
          completeDone();
          return;
        }

        if (playCommandIssued && progressObserved && !event.playing) {
          completeDone();
        }
      });

      positionSub = player.positionStream.listen((position) {
        if (!_isActivePlayback(token, index)) {
          return;
        }
        lastPosition = position;
        mediaDuration = player.duration ?? mediaDuration;

        if (playCommandIssued && position > const Duration(milliseconds: 120)) {
          progressObserved = true;
          completeStarted();
        }

        final duration = mediaDuration;
        if (duration != null &&
            duration > Duration.zero &&
            position >= duration - const Duration(milliseconds: 180)) {
          progressObserved = true;
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
    if (_s.step != FollowReadStep.idle) return;
    _playbackToken++;
    unawaited(_disposePlayer());

    final hasPermission = await _recorder!.hasPermission();
    if (!hasPermission) {
      _set(error: '未获得麦克风权限，请在系统设置中允许');
      return;
    }

    final path = '${Directory.systemTemp.path}/rec_${_s.currentIndex}.wav';
    await _recorder!.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );

    _set(step: FollowReadStep.recording, clearError: true);
  }

  // ---- Stop recording and submit for scoring ----
  Future<void> stopRecordingAndScore() async {
    if (_s.step != FollowReadStep.recording) return;

    final path = await _recorder!.stop();
    _set(step: FollowReadStep.scoring);

    try {
      var audioBytes = <int>[];
      if (path != null) {
        final file = File(path);
        if (await file.exists()) audioBytes = await file.readAsBytes();
      }

      final assessmentEngine = ref.read(followReadAssessmentEngineProvider);
      final result = await assessmentEngine.assess(
        audioBytes: audioBytes,
        referenceText: _s.currentSentence,
      );

      final aid = _s.article.id;
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
      }

      state = AsyncValue.data(
        _s.copyWith(step: FollowReadStep.result, lastResult: result),
      );
    } catch (e) {
      debugPrint('[FollowRead] scoring failed: $e');
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

  // ---- Advance to next sentence ----
  Future<void> nextSentence() async {
    _playbackToken++;
    unawaited(_disposePlayer());
    if (_s.isLastSentence) {
      _set(step: FollowReadStep.completed, clearResult: true);
    } else {
      final nextIndex = _s.currentIndex + 1;
      final nextSentence = _s.article.sentences[nextIndex];
      final nextTranslation =
          (await TranslationService.toChinese(nextSentence)).trim();
      state = AsyncValue.data(
        _s.copyWith(
          currentIndex: nextIndex,
          step: FollowReadStep.idle,
          playbackState: PlaybackVisualState.idle,
          clearPlaybackError: true,
          clearResult: true,
          clearError: true,
          currentTranslation: nextTranslation,
        ),
      );
    }
  }

  // ---- Re-try current sentence ----
  void retry() {
    _playbackToken++;
    unawaited(_disposePlayer());
    _set(
      step: FollowReadStep.idle,
      playbackState: PlaybackVisualState.idle,
      clearPlaybackError: true,
      clearResult: true,
      clearError: true,
    );
  }

  Future<void> replayCurrentSentence() async {
    if (_s.step != FollowReadStep.idle && _s.step != FollowReadStep.result) {
      return;
    }
    await playCurrent();
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
      ),
    );
  }

  void _trace(String message) {
    if (!_audioTraceEnabled) {
      return;
    }
    debugPrint('[FollowReadTrace] $message');
  }
}
