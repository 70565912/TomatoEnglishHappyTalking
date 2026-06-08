import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../shared/models/playback_visual_state.dart';
import '../../../services/chat_chapter_guide_service.dart';
import '../../../services/database_service.dart';
import '../../../services/realtime_voice_service.dart';
import '../../../services/streaming_asr_service.dart';
import '../../../services/tts_service.dart';
import '../../../services/translation_service.dart';

part 'chat_provider.g.dart';

// ---------------------------------------------------------------------------
// Step enum
// ---------------------------------------------------------------------------

enum ChatStep {
  init, // Loading article & calling AI for first question
  aiSpeaking, // TTS playing AI response
  userIdle, // Waiting for user input
  recording, // User is recording
  processing, // STT + AI call in progress
  completed, // Chapter practice completed
  error,
}

// ---------------------------------------------------------------------------
// Display message (shown in chat bubble list)
// ---------------------------------------------------------------------------

class DisplayMessage {
  final String id;
  final bool isAi;
  final String text;
  final String? translation;
  final PlaybackVisualState playbackState;
  final String? playbackError;

  const DisplayMessage({
    required this.id,
    required this.isAi,
    required this.text,
    this.translation,
    required this.playbackState,
    this.playbackError,
  });

  DisplayMessage copyWith({
    String? translation,
    PlaybackVisualState? playbackState,
    String? playbackError,
    bool clearPlaybackError = false,
    bool clearTranslation = false,
  }) =>
      DisplayMessage(
        id: id,
        isAi: isAi,
        text: text,
        translation:
            clearTranslation ? null : (translation ?? this.translation),
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
  final bool isChapterComplete;
  final String? abilityLevel;
  final String? practiceSummary;

  const ChatState({
    this.messages = const [],
    this.step = ChatStep.init,
    this.error,
    this.questionCount = 0,
    this.articleTitle = '',
    this.isChapterComplete = false,
    this.abilityLevel,
    this.practiceSummary,
  });

  ChatState copyWith({
    List<DisplayMessage>? messages,
    ChatStep? step,
    String? error,
    bool clearError = false,
    int? questionCount,
    String? articleTitle,
    bool? isChapterComplete,
    String? abilityLevel,
    String? practiceSummary,
    bool clearAbilityLevel = false,
    bool clearPracticeSummary = false,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        step: step ?? this.step,
        error: clearError ? null : (error ?? this.error),
        questionCount: questionCount ?? this.questionCount,
        articleTitle: articleTitle ?? this.articleTitle,
        isChapterComplete: isChapterComplete ?? this.isChapterComplete,
        abilityLevel:
            clearAbilityLevel ? null : (abilityLevel ?? this.abilityLevel),
        practiceSummary: clearPracticeSummary
            ? null
            : (practiceSummary ?? this.practiceSummary),
      );
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

@riverpod
class Chat extends _$Chat {
  static const _maxQuestions = 8;

  static const _audioTraceEnabled = bool.fromEnvironment(
    'TOMATO_AUDIO_TRACE',
    defaultValue: false,
  );

  final _recorder = AudioRecorder();
  String? _recordingPath;
  List<RealtimeChatTurn> _history = [];
  bool _disposed = false;

  @override
  ChatState build(int articleId) {
    _disposed = false;
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

      final guideReply = await ChatChapterGuideService.prepareGuide(
        articleTitle: article.title,
        articleContent: article.content,
        sentences: article.sentences,
        articleId: articleId,
      );
      final chapterGuide = guideReply.text.trim();

      // Call AI for the first question
      final aiReply = await RealtimeVoiceService.startSession(
        chapterGuide: chapterGuide,
        articleTitle: article.title,
        articleId: articleId,
      );
      final parsedReply = _parseAiReply(aiReply.text);
      final aiText = parsedReply.displayText;
      final aiMessageId = _newMessageId();

      // Build history for subsequent reply() calls:
      // [system, initialUserPrompt(article), firstAiResponse]
      _history = [
        RealtimeVoiceService.conversationSystemTurn(),
        RealtimeVoiceService.chapterGuideTurn(
          chapterGuide: chapterGuide,
          articleTitle: article.title,
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
        isChapterComplete: parsedReply.chapterDone,
        abilityLevel: parsedReply.abilityLevel,
        practiceSummary: parsedReply.practiceSummary,
        error: _mapAiFallbackMessage(aiReply),
        clearError: _mapAiFallbackMessage(aiReply) == null,
      );
      unawaited(_translateMessage(aiMessageId, aiText));

      final ttsError = await _playTts(
        text: aiText,
        messageId: aiMessageId,
      );
      state = state.copyWith(
        step: parsedReply.chapterDone ? ChatStep.completed : ChatStep.userIdle,
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
      final userText = await StreamingAsrService.recognizeSafe(
        audioBytes: audioBytes,
        articleId: articleId,
      );
      final displayText = userText.isNotEmpty ? userText : '(未能识别语音，请重试)';
      final userMessageId = _newMessageId();

      final newMsgs = [
        ...state.messages,
        DisplayMessage(
          id: userMessageId,
          isAi: false,
          text: displayText,
          playbackState: PlaybackVisualState.success,
        ),
      ];
      state = state.copyWith(messages: newMsgs);
      unawaited(_translateMessage(userMessageId, displayText));

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
    final userMessageId = newMsgs.last.id;
    state = state.copyWith(
        messages: newMsgs, step: ChatStep.processing, clearError: true);
    unawaited(_translateMessage(userMessageId, text));
    await _sendToAi(text);
  }

  // ---- Internal ----

  Future<void> _sendToAi(String userText) async {
    try {
      final newCount = state.questionCount + 1;
      final forceCompletion = newCount >= _maxQuestions;

      // history does NOT include the new userText yet — AiService.reply() adds it internally
      final aiReply = await RealtimeVoiceService.reply(
        history: _history,
        userMessage: userText,
        questionCount: newCount,
        forceChapterCompletion: forceCompletion,
        articleId: articleId,
      );
      final parsedReply = _parseAiReply(aiReply.text);
      final aiText = parsedReply.displayText;
      final aiMessageId = _newMessageId();
      final chapterComplete = parsedReply.chapterDone || forceCompletion;

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
        isChapterComplete: chapterComplete,
        abilityLevel: parsedReply.abilityLevel,
        practiceSummary: parsedReply.practiceSummary ??
            (chapterComplete ? _summaryFromFinalMessage(aiText) : null),
        error: _mapAiFallbackMessage(aiReply),
        clearError: _mapAiFallbackMessage(aiReply) == null,
      );
      unawaited(_translateMessage(aiMessageId, aiText));

      final ttsError = await _playTts(
        text: aiText,
        messageId: aiMessageId,
      );

      state = state.copyWith(
        step: chapterComplete ? ChatStep.completed : ChatStep.userIdle,
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

    final playbackError =
        await _playTts(text: target.text, messageId: messageId);
    state = state.copyWith(
      step: state.isChapterComplete ? ChatStep.completed : ChatStep.userIdle,
      error: playbackError,
      clearError: playbackError == null,
    );
  }

  _ParsedAiReply _parseAiReply(String rawText) {
    final doneMatch = RegExp(
      r'\[\[\s*TOMATO_CHAPTER_DONE\s*:\s*(yes|no|true|false)\s*\]\]',
      caseSensitive: false,
    ).firstMatch(rawText);
    final abilityMatch = RegExp(
      r'\[\[\s*TOMATO_ABILITY_LEVEL\s*:\s*([^\]]*?)\s*\]\]',
      caseSensitive: false,
    ).firstMatch(rawText);
    final summaryMatch = RegExp(
      r'\[\[\s*TOMATO_SUMMARY\s*:\s*([^\]]*?)\s*\]\]',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(rawText);

    var displayText = rawText
        .replaceAll(
          RegExp(
            r'\[\[\s*TOMATO_[A-Z_]+\s*:\s*.*?\s*\]\]',
            caseSensitive: false,
            dotAll: true,
          ),
          '',
        )
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    if (displayText.isEmpty) {
      displayText =
          'Great work! Practice summary: you discussed this chapter and can keep practicing with short answers.';
    }

    final doneValue = doneMatch?.group(1)?.toLowerCase().trim();
    final abilityLevel = abilityMatch?.group(1)?.trim();
    final practiceSummary = summaryMatch?.group(1)?.trim();
    return _ParsedAiReply(
      displayText: displayText,
      chapterDone: doneValue == 'yes' || doneValue == 'true',
      abilityLevel:
          abilityLevel == null || abilityLevel.isEmpty ? null : abilityLevel,
      practiceSummary: practiceSummary == null || practiceSummary.isEmpty
          ? null
          : practiceSummary,
    );
  }

  String _summaryFromFinalMessage(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 180) {
      return normalized;
    }
    return '${normalized.substring(0, 180).trim()}...';
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
      final tmpPath = await TtsService.synthesizeToCachedFile(
        text: text,
        articleId: articleId,
        cachePurpose: 'chat_tts',
      );
      _trace('playTts path=$tmpPath');

      player = AudioPlayer();
      await player.setFilePath(tmpPath).timeout(const Duration(seconds: 10));
      await player.seek(Duration.zero).timeout(const Duration(seconds: 3));
      await player.setVolume(1.0);
      _trace(
        'playTts loaded duration=${player.duration?.inMilliseconds ?? 0}ms',
      );

      final playbackStarted = Completer<void>();
      final playbackDone = Completer<void>();
      var playCommandIssued = false;
      Duration lastPosition = Duration.zero;
      Duration? mediaDuration;
      DateTime? playbackStartedAt;

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

      playerStateSub = player.playerStateStream.listen((event) {
        _trace(
          'playTts state playing=${event.playing} processing=${event.processingState.name}',
        );

        mediaDuration = player?.duration ?? mediaDuration;

        if (playCommandIssued && event.playing) {
          completeStarted();
        }

        if (event.processingState == ProcessingState.completed) {
          completeDone();
          return;
        }
      });

      positionSub = player.positionStream.listen((position) {
        lastPosition = position;
        mediaDuration = player?.duration ?? mediaDuration;

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
          _trace('playTts playbackEvent error=$error');
          completeError(error, stackTrace);
        },
      );

      final playFuture = player.play();
      playCommandIssued = true;
      unawaited(
        playFuture.then((_) => completeDone()).catchError(completeError),
      );
      _updateMessagePlayback(
        messageId,
        PlaybackVisualState.waitingStart,
        clearError: true,
      );

      await playbackStarted.future.timeout(const Duration(seconds: 6));
      playbackStartedAt = DateTime.now();
      final minimumPlaybackDuration =
          _minimumPlaybackDuration(text, mediaDuration);
      _updateMessagePlayback(
        messageId,
        PlaybackVisualState.playing,
        clearError: true,
      );
      _trace(
        'playTts started at=${lastPosition.inMilliseconds}ms '
        'minimum=${minimumPlaybackDuration.inMilliseconds}ms',
      );

      await playbackDone.future.timeout(
        _playbackTimeout(minimumPlaybackDuration),
      );
      await _holdUntilMinimumPlaybackDuration(
        startedAt: playbackStartedAt,
        minimumDuration: minimumPlaybackDuration,
      );

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
    if (reply.source == RealtimeReplySource.remote ||
        reply.source == RealtimeReplySource.cached) {
      return null;
    }

    if (reply.source == RealtimeReplySource.mockNoKey) {
      return 'AI 对话配置未读取，当前为本地示例回复';
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
    if (message.contains('语音密钥') || message.contains('API Key')) {
      return '语音合成失败：本机加密配置未读取到语音密钥';
    }
    if (message.contains('Resource ID')) {
      return '语音合成失败：本机加密配置未读取到 TTS Resource ID';
    }
    if (message.contains('Speaker')) {
      return '语音合成失败：本机加密配置未读取到 TTS Speaker';
    }
    if (message.contains('网络请求失败')) {
      return '语音合成失败：网络或鉴权异常，请稍后重试';
    }
    return '语音合成失败：$message';
  }

  Duration _minimumPlaybackDuration(String text, Duration? decoderDuration) {
    final wordCount =
        RegExp(r"[A-Za-z]+(?:'[A-Za-z]+)?").allMatches(text).length;
    final estimatedDuration = Duration(milliseconds: 900 + (wordCount * 270));
    var duration = decoderDuration ?? Duration.zero;
    if (estimatedDuration > duration) {
      duration = estimatedDuration;
    }
    if (duration < const Duration(seconds: 2)) {
      return const Duration(seconds: 2);
    }
    if (duration > const Duration(seconds: 30)) {
      return const Duration(seconds: 30);
    }
    return duration;
  }

  Future<void> _holdUntilMinimumPlaybackDuration({
    required DateTime? startedAt,
    required Duration minimumDuration,
  }) async {
    if (startedAt == null || minimumDuration <= Duration.zero) {
      return;
    }

    final elapsed = DateTime.now().difference(startedAt);
    final remaining = minimumDuration - elapsed;
    if (remaining > const Duration(milliseconds: 250)) {
      _trace('playTts hold player alive ${remaining.inMilliseconds}ms');
      await Future<void>.delayed(remaining);
    }
  }

  Duration _playbackTimeout(Duration duration) {
    if (duration <= Duration.zero) {
      return const Duration(seconds: 30);
    }

    final timeout = duration + const Duration(seconds: 8);
    if (timeout < const Duration(seconds: 12)) {
      return const Duration(seconds: 12);
    }
    if (timeout > const Duration(seconds: 60)) {
      return const Duration(seconds: 60);
    }
    return timeout;
  }

  Future<void> _cleanup() async {
    _disposed = true;
    await _recorder.dispose();
  }

  Future<void> _translateMessage(String messageId, String text) async {
    final translated = await TranslationService.toChinese(
      text,
      articleId: articleId,
      cachePurpose: 'chat_translation',
    );
    if (_disposed || translated.trim().isEmpty) {
      return;
    }

    final updated = state.messages
        .map(
          (message) => message.id == messageId
              ? message.copyWith(translation: translated.trim())
              : message,
        )
        .toList(growable: false);
    state = state.copyWith(messages: updated);
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

class _ParsedAiReply {
  const _ParsedAiReply({
    required this.displayText,
    required this.chapterDone,
    this.abilityLevel,
    this.practiceSummary,
  });

  final String displayText;
  final bool chapterDone;
  final String? abilityLevel;
  final String? practiceSummary;
}
