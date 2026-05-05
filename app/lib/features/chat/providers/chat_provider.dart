import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../shared/models/playback_visual_state.dart';
import '../../../services/database_service.dart';
import '../../../services/realtime_voice_service.dart';
import '../../../services/streaming_asr_service.dart';
import '../../../services/tts_service.dart';

part 'chat_provider.g.dart';

// ---------------------------------------------------------------------------
// Step enum
// ---------------------------------------------------------------------------

enum ChatStep {
  init,        // Loading article & calling AI for first question
  aiSpeaking,  // TTS playing AI response
  userIdle,    // Waiting for user input
  recording,   // User is recording
  processing,  // STT + AI call in progress
  completed,   // Max rounds reached
  error,
}

// ---------------------------------------------------------------------------
// Display message (shown in chat bubble list)
// ---------------------------------------------------------------------------

class DisplayMessage {
  final String id;
  final bool isAi;
  final String text;
  final PlaybackVisualState playbackState;
  final String? playbackError;

  const DisplayMessage({
    required this.id,
    required this.isAi,
    required this.text,
    required this.playbackState,
    this.playbackError,
  });

  DisplayMessage copyWith({
    PlaybackVisualState? playbackState,
    String? playbackError,
    bool clearPlaybackError = false,
  }) =>
      DisplayMessage(
        id: id,
        isAi: isAi,
        text: text,
        playbackState: playbackState ?? this.playbackState,
        playbackError:
            clearPlaybackError ? null : (playbackError ?? this.playbackError),
      );
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class ChatState {
  final List<DisplayMessage> messages;
  final ChatStep step;
  final String? error;
  final int questionCount;
  final String articleTitle;

  const ChatState({
    this.messages = const [],
    this.step = ChatStep.init,
    this.error,
    this.questionCount = 0,
    this.articleTitle = '',
  });

  ChatState copyWith({
    List<DisplayMessage>? messages,
    ChatStep? step,
    String? error,
    bool clearError = false,
    int? questionCount,
    String? articleTitle,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        step: step ?? this.step,
        error: clearError ? null : (error ?? this.error),
        questionCount: questionCount ?? this.questionCount,
        articleTitle: articleTitle ?? this.articleTitle,
      );
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

@riverpod
class Chat extends _$Chat {
  static const _audioTraceEnabled = bool.fromEnvironment(
    'TOMATO_AUDIO_TRACE',
    defaultValue: false,
  );

  final _recorder = AudioRecorder();
  String? _recordingPath;
  List<RealtimeChatTurn> _history = [];

  @override
  ChatState build(int articleId) {
    ref.onDispose(_cleanup);
    _init(articleId);
    return const ChatState();
  }

  Future<void> _init(int articleId) async {
    try {
      final article = await DatabaseService.getArticleById(articleId);
      if (article == null) {
        state = state.copyWith(step: ChatStep.error, error: '文章未找到');
        return;
      }

      state = state.copyWith(articleTitle: article.title);

      // Call AI for the first question
      final aiReply = await RealtimeVoiceService.startSession(
        articleContent: article.content,
        articleTitle: article.title,
      );
      final aiText = aiReply.text;
      final aiMessageId = _newMessageId();

      // Build history for subsequent reply() calls:
      // [system, initialUserPrompt(article), firstAiResponse]
      _history = [
        const RealtimeChatTurn(
          role: 'system',
          content:
              'You are a friendly and encouraging English teacher named Emma. Ask one question at a time.',
        ),
        RealtimeChatTurn(
          role: 'assistant',
          content: aiText,
        ),
      ];

      final msgs = [
        DisplayMessage(
          id: aiMessageId,
          isAi: true,
          text: aiText,
          playbackState: PlaybackVisualState.waitingStart,
        ),
      ];
      state = state.copyWith(
        messages: msgs,
        step: ChatStep.aiSpeaking,
        questionCount: 1,
        articleTitle: article.title,
        error: _mapAiFallbackMessage(aiReply),
        clearError: _mapAiFallbackMessage(aiReply) == null,
      );

      final ttsError = await _playTts(
        text: aiText,
        messageId: aiMessageId,
      );
      state = state.copyWith(
        step: ChatStep.userIdle,
        error: ttsError,
        clearError: ttsError == null,
      );
    } catch (e) {
      state = state.copyWith(step: ChatStep.error, error: e.toString());
    }
  }

  // ---- Recording ----

  Future<void> startRecording() async {
    if (state.step != ChatStep.userIdle) return;

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      state = state.copyWith(step: ChatStep.error, error: '需要麦克风权限');
      return;
    }

    _recordingPath =
        '${Directory.systemTemp.path}/chat_rec_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: _recordingPath!,
    );
    state = state.copyWith(step: ChatStep.recording, clearError: true);
  }

  Future<void> stopRecordingAndSend() async {
    if (state.step != ChatStep.recording) return;
    state = state.copyWith(step: ChatStep.processing);
    try {
      await _recorder.stop();
      final path = _recordingPath;
      if (path == null) return;
      final audioBytes = await File(path).readAsBytes();

      // Volc BigASR streaming STT for chat mode.
      final userText = await StreamingAsrService.recognizeSafe(audioBytes: audioBytes);
      final displayText =
          userText.isNotEmpty ? userText : '(未能识别语音，请重试)';

      final newMsgs = [
        ...state.messages,
        DisplayMessage(
          id: _newMessageId(),
          isAi: false,
          text: displayText,
          playbackState: PlaybackVisualState.success,
        ),
      ];
      state = state.copyWith(messages: newMsgs);

      await _sendToAi(
        userText.isNotEmpty
            ? userText
            : 'I tried to say something but it was unclear.',
      );
    } catch (e) {
      state = state.copyWith(step: ChatStep.error, error: e.toString());
    }
  }

  // ---- Text input ----

  Future<void> sendText(String text) async {
    if (text.trim().isEmpty) return;
    if (state.step != ChatStep.userIdle) return;

    final newMsgs = [
      ...state.messages,
      DisplayMessage(
        id: _newMessageId(),
        isAi: false,
        text: text,
        playbackState: PlaybackVisualState.success,
      ),
    ];
    state = state.copyWith(
        messages: newMsgs, step: ChatStep.processing, clearError: true);
    await _sendToAi(text);
  }

  // ---- Internal ----

  Future<void> _sendToAi(String userText) async {
    try {
      final newCount = state.questionCount + 1;

      // history does NOT include the new userText yet — AiService.reply() adds it internally
      final aiReply = await RealtimeVoiceService.reply(
        history: _history,
        userMessage: userText,
        questionCount: newCount,
      );
      final aiText = aiReply.text;
      final aiMessageId = _newMessageId();

      // Now update local history
      _history
        ..add(RealtimeChatTurn(role: 'user', content: userText))
        ..add(RealtimeChatTurn(role: 'assistant', content: aiText));

      final newMsgs = [
        ...state.messages,
        DisplayMessage(
          id: aiMessageId,
          isAi: true,
          text: aiText,
          playbackState: PlaybackVisualState.waitingStart,
        ),
      ];

      state = state.copyWith(
        messages: newMsgs,
        step: ChatStep.aiSpeaking,
        questionCount: newCount,
        error: _mapAiFallbackMessage(aiReply),
        clearError: _mapAiFallbackMessage(aiReply) == null,
      );

      final ttsError = await _playTts(
        text: aiText,
        messageId: aiMessageId,
      );

      state = state.copyWith(
        step: newCount >= 8 ? ChatStep.completed : ChatStep.userIdle,
        error: ttsError,
        clearError: ttsError == null,
      );
    } catch (e) {
      state = state.copyWith(step: ChatStep.error, error: e.toString());
    }
  }

  Future<void> replayAiMessage(String messageId) async {
    if (state.step == ChatStep.init ||
        state.step == ChatStep.processing ||
        state.step == ChatStep.recording) {
      return;
    }

    final target = state.messages
        .where((m) => m.id == messageId && m.isAi)
        .cast<DisplayMessage?>()
        .firstWhere((m) => m != null, orElse: () => null);
    if (target == null) {
      return;
    }

    _updateMessagePlayback(
      messageId,
      PlaybackVisualState.waitingStart,
      clearError: true,
    );
    state = state.copyWith(step: ChatStep.aiSpeaking, clearError: true);

    final playbackError = await _playTts(text: target.text, messageId: messageId);
    state = state.copyWith(
      step: state.questionCount >= 8 ? ChatStep.completed : ChatStep.userIdle,
      error: playbackError,
      clearError: playbackError == null,
    );
  }

  Future<String?> _playTts({
    required String text,
    required String messageId,
  }) async {
    AudioPlayer? player;
    StreamSubscription<PlayerState>? playerStateSub;
    StreamSubscription<PlaybackEvent>? playbackEventSub;
    StreamSubscription<Duration>? positionSub;
    try {
      final bytes = await TtsService.synthesize(text: text);
      if (bytes == null || bytes.isEmpty) {
        _updateMessagePlayback(
          messageId,
          PlaybackVisualState.failed,
          error: 'TTS 未返回音频数据',
        );
        return '语音合成失败：TTS 未返回音频数据';
      }

      final tmpPath =
          '${Directory.systemTemp.path}/chat_tts_${DateTime.now().millisecondsSinceEpoch}.mp3';
      await File(tmpPath).writeAsBytes(bytes);
      _trace('playTts bytes=${bytes.length} path=$tmpPath');

      player = AudioPlayer();
      await player
          .setFilePath(tmpPath)
          .timeout(const Duration(seconds: 10));
      _trace('playTts loaded');

      final playbackStarted = Completer<void>();
      final playbackDone = Completer<void>();
      var playCommandIssued = false;
      var progressObserved = false;
      Duration lastPosition = Duration.zero;
      Duration? mediaDuration;

      playerStateSub = player.playerStateStream.listen((event) {
        _trace(
          'playTts state playing=${event.playing} processing=${event.processingState.name}',
        );

        mediaDuration = player?.duration ?? mediaDuration;

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
        mediaDuration = player?.duration ?? mediaDuration;

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

      playbackEventSub = player.playbackEventStream.listen(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          _trace('playTts playbackEvent error=$error');
        },
      );

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
      _updateMessagePlayback(
        messageId,
        PlaybackVisualState.waitingStart,
        clearError: true,
      );

      await playbackStarted.future.timeout(const Duration(seconds: 6));
      _updateMessagePlayback(
        messageId,
        PlaybackVisualState.playing,
        clearError: true,
      );
      _trace('playTts started at=${lastPosition.inMilliseconds}ms');

      await playbackDone.future.timeout(const Duration(seconds: 45));

      _updateMessagePlayback(
        messageId,
        PlaybackVisualState.success,
        clearError: true,
      );
      _trace('playTts completed');
      await player.stop();
      return null;
    } on TimeoutException {
      _trace('playTts timeout');
      _updateMessagePlayback(
        messageId,
        PlaybackVisualState.failed,
        error: '播放超时',
      );
      return '语音播放失败：播放超时，请重试';
    } on TtsException catch (e) {
      _updateMessagePlayback(
        messageId,
        PlaybackVisualState.failed,
        error: e.message,
      );
      return _mapTtsException(e);
    } catch (e) {
      debugPrint('[ChatProvider] audio playback failed: $e');
      _updateMessagePlayback(
        messageId,
        PlaybackVisualState.failed,
        error: e.toString(),
      );
      return '语音播放失败：请稍后重试';
    } finally {
      await playerStateSub?.cancel();
      await playbackEventSub?.cancel();
      await positionSub?.cancel();
      await player?.dispose();
    }
  }

  String? _mapAiFallbackMessage(RealtimeReply reply) {
    if (reply.source == RealtimeReplySource.remote) {
      return null;
    }

    if (reply.source == RealtimeReplySource.mockNoKey) {
      return 'AI 未配置 Realtime API Key，当前为本地示例回复';
    }

    debugPrint('[ChatProvider] realtime AI fallback: ${reply.errorMessage}');
    final detail = reply.errorMessage?.trim();
    if (detail == null || detail.isEmpty) {
      return 'Realtime AI 服务暂不可用，当前为本地示例回复';
    }
    return 'Realtime AI 服务暂不可用：$detail';
  }

  String _mapTtsException(TtsException error) {
    final message = error.message;
    if (message.contains('API Key')) {
      return '语音合成失败：请先在设置页配置 TTS API Key';
    }
    if (message.contains('Resource ID')) {
      return '语音合成失败：请先在设置页配置 TTS Resource ID';
    }
    if (message.contains('Speaker')) {
      return '语音合成失败：请先在设置页选择 TTS Speaker';
    }
    if (message.contains('网络请求失败')) {
      return '语音合成失败：网络或鉴权异常，请稍后重试';
    }
    return '语音合成失败：$message';
  }

  Future<void> _cleanup() async {
    await _recorder.dispose();
  }

  void _updateMessagePlayback(
    String messageId,
    PlaybackVisualState playbackState, {
    String? error,
    bool clearError = false,
  }) {
    final updated = state.messages
        .map(
          (m) => m.id == messageId
              ? m.copyWith(
                  playbackState: playbackState,
                  playbackError: error,
                  clearPlaybackError: clearError,
                )
              : m,
        )
        .toList(growable: false);
    state = state.copyWith(messages: updated);
  }

  String _newMessageId() {
    final time = DateTime.now().microsecondsSinceEpoch;
    final rand = time % 1000000;
    return 'msg_${time}_$rand';
  }

  void _trace(String message) {
    if (!_audioTraceEnabled) {
      return;
    }
    debugPrint('[ChatTrace] $message');
  }
}
