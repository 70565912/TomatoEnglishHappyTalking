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
import '../../../services/recognition_based_assessment_service.dart';
import '../../../services/scoring_service.dart';
import '../../../services/tts_service.dart';

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

  const FollowReadState({
    required this.article,
    required this.currentIndex,
    required this.step,
    this.playbackState = PlaybackVisualState.idle,
    this.playbackError,
    this.lastResult,
    this.error,
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

  @override
  Future<FollowReadState> build(int articleId) async {
    ref.onDispose(_cleanup);

    final article = await DatabaseService.getArticleById(articleId);
    if (article == null) throw Exception('文章不存在（id=$articleId）');

    _player = AudioPlayer();
    _recorder = AudioRecorder();
    _bindPlayerTrace();

    return FollowReadState(
      article: article,
      currentIndex: 0,
      step: FollowReadStep.idle,
      playbackState: PlaybackVisualState.idle,
    );
  }

  void _cleanup() {
    _playerStateSub?.cancel();
    _processingStateSub?.cancel();
    _playbackErrorSub?.cancel();
    _player?.dispose();
    _recorder?.dispose();
  }

  void _bindPlayerTrace() {
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

    _trace(
        'playCurrent start idx=${_s.currentIndex} chars=${_s.currentSentence.length}');
    _set(
      step: FollowReadStep.loadingTts,
      playbackState: PlaybackVisualState.waitingStart,
      clearPlaybackError: true,
      clearResult: true,
      clearError: true,
    );

    try {
      final bytes = await TtsService.synthesize(text: _s.currentSentence);
      if (bytes == null || bytes.isEmpty) {
        throw const TtsException('TTS 未返回音频数据');
      }

      final player = _player;
      if (player == null) {
        throw const TtsException('播放器未初始化');
      }

      final tmpPath =
          '${Directory.systemTemp.path}/tts_${_s.currentIndex}_${DateTime.now().millisecondsSinceEpoch}.mp3';
      _trace('tts bytes=${bytes.length} tmpPath=$tmpPath');
      await File(tmpPath).writeAsBytes(bytes);
      await player.setFilePath(tmpPath);

      final playbackStarted = Completer<void>();
      final playbackDone = Completer<void>();
      StreamSubscription<Duration>? positionSub;
      StreamSubscription<PlayerState>? stateSub;
      var playCommandIssued = false;
      var progressObserved = false;
      Duration lastPosition = Duration.zero;
      Duration? mediaDuration = player.duration;

      stateSub = player.playerStateStream.listen((event) {
        mediaDuration = player.duration ?? mediaDuration;

        if (event.processingState == ProcessingState.completed &&
            !playbackDone.isCompleted) {
          if (!playbackStarted.isCompleted) {
            playbackStarted.complete();
          }
          playbackDone.complete();
          return;
        }

        if (playCommandIssued &&
            progressObserved &&
            !event.playing &&
            !playbackDone.isCompleted) {
          playbackDone.complete();
        }
      });

      positionSub = player.positionStream.listen((position) {
        lastPosition = position;
        mediaDuration = player.duration ?? mediaDuration;

        if (playCommandIssued &&
            position > const Duration(milliseconds: 120) &&
            !playbackStarted.isCompleted) {
          progressObserved = true;
          playbackStarted.complete();
        }

        final duration = mediaDuration;
        if (duration != null &&
            duration > Duration.zero &&
            position >= duration - const Duration(milliseconds: 180)) {
          progressObserved = true;
          if (!playbackStarted.isCompleted) {
            playbackStarted.complete();
          }
          if (!playbackDone.isCompleted) {
            playbackDone.complete();
          }
        }
      });

      final playFuture = player.play();
      playCommandIssued = true;
      unawaited(
        playFuture.catchError((Object error, StackTrace stackTrace) {
          if (!playbackStarted.isCompleted) {
            playbackStarted.completeError(error, stackTrace);
          }
          if (!playbackDone.isCompleted) {
            playbackDone.completeError(error, stackTrace);
          }
        }),
      );

      await playbackStarted.future.timeout(const Duration(seconds: 6));
      _set(
        step: FollowReadStep.playing,
        playbackState: PlaybackVisualState.playing,
        clearPlaybackError: true,
      );
      _trace(
          'playCurrent started idx=${_s.currentIndex} at=${lastPosition.inMilliseconds}ms');

      await playbackDone.future.timeout(const Duration(seconds: 30));
      await player.stop();
      await stateSub.cancel();
      await positionSub.cancel();
      _trace('playCurrent completed idx=${_s.currentIndex}');
    } on TimeoutException {
      _set(
        step: FollowReadStep.idle,
        playbackState: PlaybackVisualState.failed,
        playbackError: '播放超时',
        error: '播放超时：30 秒内未完成',
      );
      _trace('playCurrent timeout idx=${_s.currentIndex}');
      return;
    } catch (e) {
      _trace('playCurrent failed idx=${_s.currentIndex} error=$e');
      _set(
        step: FollowReadStep.idle,
        playbackState: PlaybackVisualState.failed,
        playbackError: e.toString(),
        error: '播放失败：$e',
      );
      return;
    }

    _set(
      step: FollowReadStep.idle,
      playbackState: PlaybackVisualState.success,
      clearPlaybackError: true,
    );
  }

  // ---- Start microphone recording ----
  Future<void> startRecording() async {
    if (_s.step != FollowReadStep.idle) return;

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
      _set(step: FollowReadStep.idle, error: '识别或评分失败：$e');
    }
  }

  // ---- Advance to next sentence ----
  void nextSentence() {
    if (_s.isLastSentence) {
      _set(step: FollowReadStep.completed, clearResult: true);
    } else {
      state = AsyncValue.data(
        _s.copyWith(
          currentIndex: _s.currentIndex + 1,
          step: FollowReadStep.idle,
          playbackState: PlaybackVisualState.idle,
          clearPlaybackError: true,
          clearResult: true,
          clearError: true,
        ),
      );
    }
  }

  // ---- Re-try current sentence ----
  void retry() => _set(
        step: FollowReadStep.idle,
        playbackState: PlaybackVisualState.idle,
        clearPlaybackError: true,
        clearResult: true,
        clearError: true,
      );

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
