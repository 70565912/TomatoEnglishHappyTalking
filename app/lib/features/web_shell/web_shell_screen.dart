import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/webview/webview_environment.dart';
import '../../data/models/article_model.dart';
import '../../services/database_service.dart';
import '../../services/nlp_service.dart';
import '../../services/scoring_service.dart';
import '../../services/tts_service.dart';
import '../chat/providers/chat_provider.dart';
import '../follow_read/providers/follow_read_provider.dart';
import 'web_bridge_protocol.dart';
import 'web_shell_qa_server.dart';

class WebShellScreen extends ConsumerStatefulWidget {
  const WebShellScreen({super.key});

  @override
  ConsumerState<WebShellScreen> createState() => _WebShellScreenState();
}

class _WebShellScreenState extends ConsumerState<WebShellScreen> {
  static const _devServerUrl = String.fromEnvironment(
    'TOMATO_WEB_UI_DEV_URL',
  );
  static const _qaRemoteEnabled = bool.fromEnvironment('TOMATO_QA_REMOTE');
  static const _qaRemotePort = int.fromEnvironment(
    'TOMATO_QA_PORT',
    defaultValue: 39317,
  );
  static const _qaRemoteToken = String.fromEnvironment('TOMATO_QA_TOKEN');

  InAppWebViewController? _controller;
  WebShellQaServer? _qaServer;
  ProviderSubscription<AsyncValue<FollowReadState>>? _followSubscription;
  ProviderSubscription<ChatState>? _chatSubscription;
  int? _activeFollowArticleId;
  int? _activeChatArticleId;
  bool _webReady = false;
  String? _loadError;
  final List<Map<String, dynamic>> _pendingEvents = [];

  bool get _usesDevServer => _devServerUrl.trim().isNotEmpty;

  BridgeRouter get _bridgeRouter => BridgeRouter({
        'app.ready': _handleAppReady,
        'app.navigate': _handleAppNavigate,
        'app.back': _handleAppBack,
        'article.list': _handleArticleList,
        'article.create': _handleArticleCreate,
        'article.delete': _handleArticleDelete,
        'follow.open': _handleFollowOpen,
        'follow.play': _handleFollowPlay,
        'follow.recordStart': _handleFollowRecordStart,
        'follow.recordStop': _handleFollowRecordStop,
        'follow.retry': _handleFollowRetry,
        'follow.next': _handleFollowNext,
        'follow.replay': _handleFollowReplay,
        'chat.open': _handleChatOpen,
        'chat.recordStart': _handleChatRecordStart,
        'chat.recordStop': _handleChatRecordStop,
        'chat.sendText': _handleChatSendText,
        'chat.replay': _handleChatReplay,
        'settings.load': _handleSettingsLoad,
        'settings.saveVoice': _handleSettingsSaveVoice,
      });

  @override
  void initState() {
    super.initState();
    if (_qaRemoteEnabled) {
      _qaServer = WebShellQaServer(
        port: _qaRemotePort,
        token: _qaRemoteToken,
        health: _qaHealth,
        snapshot: _qaSnapshot,
        screenshot: _qaScreenshot,
        navigate: _qaNavigate,
        click: _qaClick,
        fill: _qaFill,
        dispatchBridge: (raw) => _bridgeRouter.dispatch(raw),
      );
      unawaited(_qaServer!.start());
    }
  }

  @override
  void dispose() {
    unawaited(_qaServer?.stop());
    _closeFollowSession();
    _closeChatSession();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final environmentError = tomatoWebViewEnvironmentError;
    if (environmentError != null &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.windows) {
      return _NativeErrorView(message: environmentError);
    }

    final serverError = tomatoWebUiServerError;
    if (!_usesDevServer && serverError != null) {
      return _NativeErrorView(message: serverError);
    }

    if (_loadError != null) {
      return _NativeErrorView(message: _loadError!);
    }

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: InAppWebView(
          initialUrlRequest: URLRequest(
            url: WebUri(
              _usesDevServer ? _devServerUrl.trim() : tomatoWebUiLocalUrl,
            ),
          ),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            transparentBackground: false,
            allowFileAccessFromFileURLs: true,
            allowUniversalAccessFromFileURLs: true,
            mediaPlaybackRequiresUserGesture: false,
            isInspectable: kDebugMode,
          ),
          webViewEnvironment: tomatoWebViewEnvironment,
          onWebViewCreated: (controller) {
            _controller = controller;
            controller.addJavaScriptHandler(
              handlerName: 'tomatoBridge',
              callback: (args) async {
                final raw = args.isEmpty ? null : args.first;
                return _bridgeRouter.dispatch(raw);
              },
            );
          },
          onReceivedError: (controller, request, error) {
            if (request.isForMainFrame == false) {
              return;
            }
            setState(() {
              _loadError = 'Web UI 加载失败：${error.description}';
            });
          },
        ),
      ),
    );
  }

  Future<Map<String, dynamic>> _handleAppReady(BridgeMessage message) async {
    _webReady = true;
    unawaited(_flushPendingEvents());
    final articles = await _articleListPayload();
    return {
      'platform': defaultTargetPlatform.name,
      'usesDevServer': _usesDevServer,
      'articles': articles['articles'],
    };
  }

  Future<Map<String, dynamic>> _handleAppNavigate(BridgeMessage message) async {
    final path = _payloadString(message.payload, 'path');
    if (!path.startsWith('/follow')) {
      _closeFollowSession();
    }
    if (!path.startsWith('/chat')) {
      _closeChatSession();
    }
    return {'path': path};
  }

  Future<Map<String, dynamic>> _handleAppBack(BridgeMessage message) async {
    if (mounted) {
      await Navigator.of(context).maybePop();
    }
    return {};
  }

  Future<Map<String, dynamic>> _handleArticleList(BridgeMessage message) =>
      _articleListPayload();

  Future<Map<String, dynamic>> _handleArticleCreate(
    BridgeMessage message,
  ) async {
    final title = _payloadString(message.payload, 'title').trim();
    final content = _payloadString(message.payload, 'content').trim();
    if (title.isEmpty) {
      throw const FormatException('请填写文章标题');
    }
    if (content.isEmpty) {
      throw const FormatException('请填写文章内容');
    }

    final article = Article(
      title: title,
      content: content,
      sentences: NlpService.splitSentences(content),
      createdAt: DateTime.now(),
    );
    final id = await DatabaseService.saveArticle(article);
    final payload = await _articleListPayload();
    unawaited(_pushEvent('article.state', payload));
    return {
      'article': _articleJson(article.copyWith(id: id), averageScore: 0),
      'articles': payload['articles'],
    };
  }

  Future<Map<String, dynamic>> _handleArticleDelete(
    BridgeMessage message,
  ) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    await DatabaseService.deleteArticle(articleId);
    if (_activeFollowArticleId == articleId) {
      _closeFollowSession();
    }
    if (_activeChatArticleId == articleId) {
      _closeChatSession();
    }
    final payload = await _articleListPayload();
    unawaited(_pushEvent('article.state', payload));
    return payload;
  }

  Future<Map<String, dynamic>> _handleFollowOpen(BridgeMessage message) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    _closeChatSession();
    _openFollowSession(articleId);
    final value = await ref.read(followReadProvider(articleId).future);
    final payload = _followPayload(AsyncValue.data(value));
    unawaited(_pushEvent('follow.state', payload));
    return payload;
  }

  Future<Map<String, dynamic>> _handleFollowPlay(BridgeMessage message) async {
    final articleId = _requireActiveFollow();
    await ref.read(followReadProvider(articleId).notifier).playCurrent();
    return _currentFollowPayload(articleId);
  }

  Future<Map<String, dynamic>> _handleFollowRecordStart(
    BridgeMessage message,
  ) async {
    final articleId = _requireActiveFollow();
    await ref.read(followReadProvider(articleId).notifier).startRecording();
    return _currentFollowPayload(articleId);
  }

  Future<Map<String, dynamic>> _handleFollowRecordStop(
    BridgeMessage message,
  ) async {
    final articleId = _requireActiveFollow();
    await ref
        .read(followReadProvider(articleId).notifier)
        .stopRecordingAndScore();
    return _currentFollowPayload(articleId);
  }

  Future<Map<String, dynamic>> _handleFollowRetry(BridgeMessage message) async {
    final articleId = _requireActiveFollow();
    ref.read(followReadProvider(articleId).notifier).retry();
    return _currentFollowPayload(articleId);
  }

  Future<Map<String, dynamic>> _handleFollowNext(BridgeMessage message) async {
    final articleId = _requireActiveFollow();
    await ref.read(followReadProvider(articleId).notifier).nextSentence();
    return _currentFollowPayload(articleId);
  }

  Future<Map<String, dynamic>> _handleFollowReplay(
    BridgeMessage message,
  ) async {
    final articleId = _requireActiveFollow();
    await ref
        .read(followReadProvider(articleId).notifier)
        .replayCurrentSentence();
    return _currentFollowPayload(articleId);
  }

  Future<Map<String, dynamic>> _handleChatOpen(BridgeMessage message) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    _closeFollowSession();
    _openChatSession(articleId);
    return _chatPayload(ref.read(chatProvider(articleId)));
  }

  Future<Map<String, dynamic>> _handleChatRecordStart(
    BridgeMessage message,
  ) async {
    final articleId = _requireActiveChat();
    await ref.read(chatProvider(articleId).notifier).startRecording();
    return _chatPayload(ref.read(chatProvider(articleId)));
  }

  Future<Map<String, dynamic>> _handleChatRecordStop(
    BridgeMessage message,
  ) async {
    final articleId = _requireActiveChat();
    await ref.read(chatProvider(articleId).notifier).stopRecordingAndSend();
    return _chatPayload(ref.read(chatProvider(articleId)));
  }

  Future<Map<String, dynamic>> _handleChatSendText(
    BridgeMessage message,
  ) async {
    final articleId = _requireActiveChat();
    final text = _payloadString(message.payload, 'text').trim();
    if (text.isEmpty) {
      throw const FormatException('请输入要发送的内容');
    }
    await ref.read(chatProvider(articleId).notifier).sendText(text);
    return _chatPayload(ref.read(chatProvider(articleId)));
  }

  Future<Map<String, dynamic>> _handleChatReplay(BridgeMessage message) async {
    final articleId = _requireActiveChat();
    final messageId = _payloadString(message.payload, 'messageId');
    await ref.read(chatProvider(articleId).notifier).replayAiMessage(messageId);
    return _chatPayload(ref.read(chatProvider(articleId)));
  }

  Future<Map<String, dynamic>> _handleSettingsLoad(BridgeMessage message) =>
      _settingsPayload();

  Future<Map<String, dynamic>> _handleSettingsSaveVoice(
    BridgeMessage message,
  ) async {
    final speakerId = _payloadString(message.payload, 'speakerId').trim();
    if (!TtsService.isPresetVoice(speakerId)) {
      throw const FormatException('请选择支持的声音');
    }

    await AppConfig.saveVolcTtsSpeakerId(speakerId);
    final payload = await _settingsPayload();
    unawaited(_pushEvent('settings.state', payload));
    return payload;
  }

  void _openFollowSession(int articleId) {
    if (_activeFollowArticleId == articleId && _followSubscription != null) {
      return;
    }

    _closeFollowSession();
    _activeFollowArticleId = articleId;
    _followSubscription = ProviderScope.containerOf(
      context,
      listen: false,
    ).listen<AsyncValue<FollowReadState>>(
      followReadProvider(articleId),
      (_, next) {
        final payload = _followPayload(next);
        unawaited(_pushEvent('follow.state', payload));
        unawaited(_pushEvent('avatar.state', payload['avatar']));
      },
      fireImmediately: true,
    );
  }

  void _closeFollowSession() {
    _followSubscription?.close();
    _followSubscription = null;
    _activeFollowArticleId = null;
  }

  void _openChatSession(int articleId) {
    if (_activeChatArticleId == articleId && _chatSubscription != null) {
      return;
    }

    _closeChatSession();
    _activeChatArticleId = articleId;
    _chatSubscription = ProviderScope.containerOf(
      context,
      listen: false,
    ).listen<ChatState>(
      chatProvider(articleId),
      (_, next) {
        final payload = _chatPayload(next);
        unawaited(_pushEvent('chat.state', payload));
        unawaited(_pushEvent('avatar.state', payload['avatar']));
      },
      fireImmediately: true,
    );
  }

  void _closeChatSession() {
    _chatSubscription?.close();
    _chatSubscription = null;
    _activeChatArticleId = null;
  }

  int _requireActiveFollow() {
    final articleId = _activeFollowArticleId;
    if (articleId == null) {
      throw StateError('Follow-read session is not open');
    }
    return articleId;
  }

  int _requireActiveChat() {
    final articleId = _activeChatArticleId;
    if (articleId == null) {
      throw StateError('Chat session is not open');
    }
    return articleId;
  }

  Future<Map<String, dynamic>> _currentFollowPayload(int articleId) async {
    final asyncState = ref.read(followReadProvider(articleId));
    if (asyncState.hasValue) {
      return _followPayload(asyncState);
    }
    final value = await ref.read(followReadProvider(articleId).future);
    return _followPayload(AsyncValue.data(value));
  }

  Future<Map<String, dynamic>> _articleListPayload() async {
    final articles = await DatabaseService.getArticles();
    final articlePayloads = <Map<String, dynamic>>[];
    for (final originalArticle in articles) {
      final article = await _articleWithCurrentSentences(originalArticle);
      final id = article.id;
      final averageScore =
          id == null ? 0.0 : await DatabaseService.getAverageScore(id);
      articlePayloads.add(_articleJson(article, averageScore: averageScore));
    }
    return {'articles': articlePayloads};
  }

  Future<Article> _articleWithCurrentSentences(Article article) async {
    final id = article.id;
    final sentences = NlpService.splitSentences(article.content);
    if (sentences.isEmpty || listEquals(article.sentences, sentences)) {
      return article;
    }

    if (id != null) {
      await DatabaseService.updateArticleSentences(id, sentences);
    }
    return article.copyWith(sentences: sentences);
  }

  Future<Map<String, dynamic>> _settingsPayload() async {
    final speakerId = await AppConfig.volcTtsSpeakerId;
    final resolvedSpeakerId = TtsService.isPresetVoice(speakerId)
        ? speakerId.trim()
        : TtsService.defaultVoiceType;
    return {
      'tts': {
        'resourceId': await AppConfig.volcTtsResourceId,
        'speakerId': resolvedSpeakerId,
      },
      'voices': TtsService.voices
          .map(
            (voice) => {
              'id': voice.id,
              'name': voice.name,
              'lang': voice.lang,
              'gender': voice.gender,
              'scene': voice.scene,
            },
          )
          .toList(growable: false),
    };
  }

  Map<String, dynamic> _followPayload(AsyncValue<FollowReadState> asyncState) {
    return asyncState.when(
      loading: () => {
        'status': 'loading',
        'avatar': _avatarJson(
          mode: 'thinking',
          emotion: 'focused',
          mouth: 'closed',
        ),
      },
      error: (error, _) => {
        'status': 'error',
        'error': error.toString(),
        'avatar': _avatarJson(
          mode: 'error',
          emotion: 'sad',
          mouth: 'closed',
        ),
      },
      data: (state) {
        final avatar = _avatarForFollow(state.step);
        return {
          'status': 'ready',
          'article': _articleJson(state.article),
          'currentIndex': state.currentIndex,
          'totalSentences': state.totalSentences,
          'currentSentence': state.currentSentence,
          'currentTranslation': state.currentTranslation,
          'isLastSentence': state.isLastSentence,
          'step': state.step.name,
          'playbackState': state.playbackState.name,
          'playbackError': state.playbackError,
          'result': _pronunciationResultJson(state.lastResult),
          'error': state.error,
          'avatar': avatar,
        };
      },
    );
  }

  Map<String, dynamic> _chatPayload(ChatState state) {
    final avatar = _avatarForChat(state.step);
    return {
      'articleTitle': state.articleTitle,
      'step': state.step.name,
      'error': state.error,
      'questionCount': state.questionCount,
      'maxQuestions': 8,
      'messages': state.messages
          .map(
            (message) => {
              'id': message.id,
              'isAi': message.isAi,
              'text': message.text,
              'translation': message.translation,
              'playbackState': message.playbackState.name,
              'playbackError': message.playbackError,
            },
          )
          .toList(growable: false),
      'avatar': avatar,
    };
  }

  Map<String, dynamic> _articleJson(
    Article article, {
    double averageScore = 0,
  }) {
    return {
      'id': article.id,
      'title': article.title,
      'content': article.content,
      'sentences': article.sentences,
      'sentenceCount': article.sentences.length,
      'createdAt': article.createdAt.toIso8601String(),
      'averageScore': averageScore,
    };
  }

  Map<String, dynamic>? _pronunciationResultJson(PronunciationResult? result) {
    if (result == null) {
      return null;
    }
    return {
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
  }

  Map<String, dynamic> _avatarForFollow(FollowReadStep step) {
    return switch (step) {
      FollowReadStep.idle => _avatarJson(
          mode: 'idle',
          emotion: 'encouraging',
          mouth: 'closed',
        ),
      FollowReadStep.loadingTts || FollowReadStep.scoring => _avatarJson(
          mode: 'thinking',
          emotion: 'focused',
          mouth: 'small',
          volume: 0.25,
        ),
      FollowReadStep.playing => _avatarJson(
          mode: 'speaking',
          emotion: 'happy',
          mouth: 'wide',
          volume: 0.75,
        ),
      FollowReadStep.recording => _avatarJson(
          mode: 'listening',
          emotion: 'focused',
          mouth: 'closed',
          volume: 0.4,
        ),
      FollowReadStep.result => _avatarJson(
          mode: 'celebrating',
          emotion: 'happy',
          mouth: 'medium',
          volume: 0.5,
        ),
      FollowReadStep.completed => _avatarJson(
          mode: 'celebrating',
          emotion: 'happy',
          mouth: 'wide',
          volume: 0.7,
        ),
    };
  }

  Map<String, dynamic> _avatarForChat(ChatStep step) {
    return switch (step) {
      ChatStep.init || ChatStep.processing => _avatarJson(
          mode: 'thinking',
          emotion: 'focused',
          mouth: 'small',
          volume: 0.2,
        ),
      ChatStep.aiSpeaking => _avatarJson(
          mode: 'speaking',
          emotion: 'happy',
          mouth: 'wide',
          volume: 0.8,
        ),
      ChatStep.userIdle => _avatarJson(
          mode: 'idle',
          emotion: 'encouraging',
          mouth: 'closed',
        ),
      ChatStep.recording => _avatarJson(
          mode: 'listening',
          emotion: 'focused',
          mouth: 'closed',
          volume: 0.45,
        ),
      ChatStep.completed => _avatarJson(
          mode: 'celebrating',
          emotion: 'happy',
          mouth: 'wide',
          volume: 0.75,
        ),
      ChatStep.error => _avatarJson(
          mode: 'error',
          emotion: 'sad',
          mouth: 'closed',
        ),
    };
  }

  Map<String, dynamic> _avatarJson({
    required String mode,
    required String emotion,
    required String mouth,
    double volume = 0,
  }) =>
      {
        'mode': mode,
        'emotion': emotion,
        'mouth': mouth,
        'volume': volume,
      };

  Future<void> _pushEvent(String type, Object? payload) async {
    final event = {
      'type': type,
      'payload': payload ?? <String, dynamic>{},
    };
    if (_controller == null || !_webReady) {
      _pendingEvents.add(event);
      return;
    }

    final encoded = jsonEncode(event);
    await _controller!.evaluateJavascript(
      source:
          'window.__tomatoNativeEvent && window.__tomatoNativeEvent($encoded);',
    );
  }

  Future<void> _flushPendingEvents() async {
    final events = List<Map<String, dynamic>>.from(_pendingEvents);
    _pendingEvents.clear();
    for (final event in events) {
      await _pushEvent(event['type'] as String, event['payload']);
    }
  }

  Future<Map<String, dynamic>> _qaHealth() async {
    final controller = _controller;
    final url = controller == null ? null : await controller.getUrl();
    return {
      'ok': true,
      'platform': defaultTargetPlatform.name,
      'webReady': _webReady,
      'usesDevServer': _usesDevServer,
      'activeFollowArticleId': _activeFollowArticleId,
      'activeChatArticleId': _activeChatArticleId,
      'url': url?.toString(),
      'runtimeState': await _qaRuntimeState(),
      'endpoints': [
        'GET /health',
        'GET /snapshot',
        'GET /screenshot',
        'POST /navigate {"path":"/settings"}',
        'POST /click {"text":"保存任务"}',
        'POST /fill {"selector":"input","value":"Space Snacks"}',
        'POST /bridge {"type":"article.list","payload":{}}',
      ],
    };
  }

  Future<Map<String, dynamic>> _qaNavigate(String path) async {
    await _bridgeRouter.dispatch({
      'id': 'qa_nav_${DateTime.now().microsecondsSinceEpoch}',
      'type': 'app.navigate',
      'payload': {'path': path},
    });
    final controller = _requireWebController();
    await controller.evaluateJavascript(
      source: 'window.location.hash = ${jsonEncode(path)};',
    );
    return {
      'ok': true,
      'path': path,
    };
  }

  Future<Uint8List> _qaScreenshot() async {
    final bytes = await _requireWebController().takeScreenshot();
    if (bytes == null || bytes.isEmpty) {
      throw StateError('WebView screenshot is empty');
    }
    return bytes;
  }

  Future<Map<String, dynamic>> _qaClick(Map<String, dynamic> payload) async {
    final raw = await _requireWebController().evaluateJavascript(
      source: '''
(() => {
  const payload = ${jsonEncode(payload)};
  const normalize = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
  const rectOf = (element) => {
    const rect = element.getBoundingClientRect();
    return {
      x: Math.round(rect.x),
      y: Math.round(rect.y),
      width: Math.round(rect.width),
      height: Math.round(rect.height)
    };
  };
  const isVisible = (element) => {
    const rect = element.getBoundingClientRect();
    const style = window.getComputedStyle(element);
    return rect.width > 0 &&
      rect.height > 0 &&
      style.visibility !== 'hidden' &&
      style.display !== 'none';
  };
  const selector = normalize(payload.selector);
  const text = normalize(payload.text);
  const exact = Boolean(payload.exact);
  const index = Number.isFinite(Number(payload.index)) ? Number(payload.index) : 0;
  let candidates = selector
    ? Array.from(document.querySelectorAll(selector))
    : Array.from(document.querySelectorAll('button, [role="button"], a, label, input, textarea, select'));
  candidates = candidates.filter(isVisible);
  if (text) {
    const wanted = text.toLowerCase();
    const labelOf = (element) => normalize(
      element.getAttribute('aria-label') ||
      element.getAttribute('placeholder') ||
      element.textContent ||
      element.value
    ).toLowerCase();
    candidates = candidates.filter((element) => {
      const label = labelOf(element);
      return exact ? label === wanted : label.includes(wanted);
    });
    candidates.sort((left, right) => {
      const leftLabel = labelOf(left);
      const rightLabel = labelOf(right);
      const leftExact = leftLabel === wanted ? 0 : 1;
      const rightExact = rightLabel === wanted ? 0 : 1;
      if (leftExact !== rightExact) return leftExact - rightExact;
      const leftStarts = leftLabel.startsWith(wanted) ? 0 : 1;
      const rightStarts = rightLabel.startsWith(wanted) ? 0 : 1;
      if (leftStarts !== rightStarts) return leftStarts - rightStarts;
      return leftLabel.length - rightLabel.length;
    });
  }
  const target = candidates[index];
  if (!target) {
    return JSON.stringify({
      ok: false,
      error: {
        message: 'No clickable element matched',
        selector,
        text,
        index,
        candidates: candidates.length
      }
    });
  }
  const disabled = Boolean(target.disabled) || target.getAttribute('aria-disabled') === 'true';
  if (disabled) {
    return JSON.stringify({
      ok: false,
      error: {
        message: 'Clickable element is disabled',
        selector,
        text,
        index
      },
      target: {
        tag: target.tagName.toLowerCase(),
        className: String(target.className || ''),
        text: normalize(target.textContent || target.getAttribute('aria-label') || target.getAttribute('placeholder') || target.value).slice(0, 160),
        disabled,
        rect: rectOf(target)
      }
    });
  }
  target.scrollIntoView({ block: 'center', inline: 'center' });
  target.focus?.();
  target.click();
  return JSON.stringify({
    ok: true,
    action: 'click',
    target: {
      tag: target.tagName.toLowerCase(),
      className: String(target.className || ''),
      text: normalize(target.textContent || target.getAttribute('aria-label') || target.getAttribute('placeholder') || target.value).slice(0, 160),
      disabled: Boolean(target.disabled),
      rect: rectOf(target)
    }
  });
})()
''',
    );
    return _decodeJavascriptJsonMap(raw);
  }

  Future<Map<String, dynamic>> _qaFill(Map<String, dynamic> payload) async {
    final raw = await _requireWebController().evaluateJavascript(
      source: '''
(() => {
  const payload = ${jsonEncode(payload)};
  const normalize = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
  const rectOf = (element) => {
    const rect = element.getBoundingClientRect();
    return {
      x: Math.round(rect.x),
      y: Math.round(rect.y),
      width: Math.round(rect.width),
      height: Math.round(rect.height)
    };
  };
  const isVisible = (element) => {
    const rect = element.getBoundingClientRect();
    const style = window.getComputedStyle(element);
    return rect.width > 0 &&
      rect.height > 0 &&
      style.visibility !== 'hidden' &&
      style.display !== 'none';
  };
  const selector = normalize(payload.selector);
  if (!selector) {
    return JSON.stringify({
      ok: false,
      error: { message: 'fill.selector is required' }
    });
  }
  const value = String(payload.value ?? '');
  const index = Number.isFinite(Number(payload.index)) ? Number(payload.index) : 0;
  const candidates = Array.from(document.querySelectorAll(selector)).filter(isVisible);
  const target = candidates[index];
  if (!target) {
    return JSON.stringify({
      ok: false,
      error: {
        message: 'No fillable element matched',
        selector,
        index,
        candidates: candidates.length
      }
    });
  }
  target.scrollIntoView({ block: 'center', inline: 'center' });
  target.focus?.();
  if (target.isContentEditable) {
    target.textContent = value;
  } else {
    const prototype = Object.getPrototypeOf(target);
    const descriptor = Object.getOwnPropertyDescriptor(prototype, 'value') ||
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value') ||
      Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value');
    if (descriptor?.set) {
      descriptor.set.call(target, value);
    } else {
      target.value = value;
    }
  }
  target.dispatchEvent(new Event('input', { bubbles: true }));
  target.dispatchEvent(new Event('change', { bubbles: true }));
  return JSON.stringify({
    ok: true,
    action: 'fill',
    target: {
      tag: target.tagName.toLowerCase(),
      className: String(target.className || ''),
      placeholder: target.getAttribute('placeholder') || '',
      valueLength: value.length,
      rect: rectOf(target)
    }
  });
})()
''',
    );
    return _decodeJavascriptJsonMap(raw);
  }

  Future<Map<String, dynamic>> _qaSnapshot() async {
    final raw = await _requireWebController().evaluateJavascript(
      source: '''
(() => {
  const rectOf = (element) => {
    const rect = element.getBoundingClientRect();
    return {
      x: Math.round(rect.x),
      y: Math.round(rect.y),
      width: Math.round(rect.width),
      height: Math.round(rect.height)
    };
  };
  const images = Array.from(document.images).map((image) => ({
    src: image.getAttribute('src') || '',
    currentSrc: image.currentSrc || '',
    complete: image.complete,
    naturalWidth: image.naturalWidth,
    naturalHeight: image.naturalHeight,
    rect: rectOf(image)
  }));
  const brokenImages = images.filter((image) =>
    !image.complete || image.naturalWidth === 0 || image.naturalHeight === 0
  );
  const isQaVisible = (element) => {
    if (element.closest('.visually-hidden,[hidden],[aria-hidden="true"]')) {
      return false;
    }
    const rect = element.getBoundingClientRect();
    if (rect.width <= 1 || rect.height <= 1) {
      return false;
    }
    const style = window.getComputedStyle(element);
    return style.display !== 'none' &&
      style.visibility !== 'hidden' &&
      Number(style.opacity || '1') > 0.01;
  };
  const isExpectedScrollContainer = (element) => {
    const style = window.getComputedStyle(element);
    const overflowX = style.overflowX;
    const overflowY = style.overflowY;
    const horizontalScroll = element.scrollWidth > element.clientWidth + 4 &&
      (overflowX === 'auto' || overflowX === 'scroll');
    const verticalScroll = element.scrollHeight > element.clientHeight + 4 &&
      (overflowY === 'auto' || overflowY === 'scroll');
    return horizontalScroll || verticalScroll;
  };
  const overflowElements = Array.from(document.querySelectorAll('*'))
    .filter((element) =>
      isQaVisible(element) &&
      !isExpectedScrollContainer(element) &&
      (
        element.scrollWidth > element.clientWidth + 4 ||
        element.scrollHeight > element.clientHeight + 4
      )
    )
    .slice(0, 80)
    .map((element) => ({
      tag: element.tagName.toLowerCase(),
      className: String(element.className || ''),
      text: (element.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 120),
      clientWidth: element.clientWidth,
      scrollWidth: element.scrollWidth,
      clientHeight: element.clientHeight,
      scrollHeight: element.scrollHeight,
      rect: rectOf(element)
    }));
  const buttons = Array.from(document.querySelectorAll('button'))
    .map((button) => ({
      text: (button.textContent || '').trim().replace(/\\s+/g, ' '),
      disabled: button.disabled,
      rect: rectOf(button)
    }));
  const formControls = Array.from(document.querySelectorAll('input, textarea, select'))
    .map((control) => ({
      tag: control.tagName.toLowerCase(),
      className: String(control.className || ''),
      placeholder: control.getAttribute('placeholder') || '',
      value: String(control.value || '').slice(0, 240),
      disabled: Boolean(control.disabled),
      rect: rectOf(control)
    }));
  return JSON.stringify({
    href: location.href,
    hash: location.hash,
    title: document.title,
    viewport: {
      width: window.innerWidth,
      height: window.innerHeight,
      scrollX: window.scrollX,
      scrollY: window.scrollY,
      bodyScrollWidth: document.body.scrollWidth,
      bodyScrollHeight: document.body.scrollHeight
    },
    imageCount: images.length,
    images,
    brokenImages,
    overflowElements,
    buttons,
    formControls,
    visibleText: (document.body?.innerText || '').replace(/\\s+/g, ' ').slice(0, 4000)
  });
})()
''',
    );
    final payload = _decodeJavascriptJsonMap(raw);
    payload['runtimeState'] = await _qaRuntimeState();
    return payload;
  }

  Future<Map<String, dynamic>> _qaRuntimeState() async {
    final followArticleId = _activeFollowArticleId;
    final chatArticleId = _activeChatArticleId;
    final payload = <String, dynamic>{
      'activeFollowArticleId': followArticleId,
      'activeChatArticleId': chatArticleId,
    };

    if (followArticleId != null) {
      try {
        payload['follow'] = await _currentFollowPayload(followArticleId);
      } catch (error) {
        payload['followError'] = error.toString();
      }
    }

    if (chatArticleId != null) {
      try {
        payload['chat'] = _chatPayload(ref.read(chatProvider(chatArticleId)));
      } catch (error) {
        payload['chatError'] = error.toString();
      }
    }

    return payload;
  }

  InAppWebViewController _requireWebController() {
    final controller = _controller;
    if (controller == null) {
      throw StateError('WebView is not ready');
    }
    return controller;
  }

  Map<String, dynamic> _decodeJavascriptJsonMap(Object? raw) {
    final decoded = switch (raw) {
      final String text => jsonDecode(text),
      final Map map => map,
      _ => throw const FormatException('JavaScript result must be JSON object'),
    };
    if (decoded is! Map) {
      throw const FormatException('JavaScript result must be JSON object');
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  int _payloadInt(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) {
        return parsed;
      }
    }
    throw FormatException('Missing integer payload field: $key');
  }

  String _payloadString(
    Map<String, dynamic> payload,
    String key, {
    String fallback = '',
  }) {
    final value = payload[key];
    if (value == null) {
      return fallback;
    }
    if (value is String) {
      return value;
    }
    return value.toString();
  }
}

class _NativeErrorView extends StatelessWidget {
  const _NativeErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.web_asset_off,
                  color: AppTheme.primary,
                  size: 56,
                ),
                const SizedBox(height: 16),
                Text(
                  'Web UI 启动失败',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: AppTheme.darkBlue,
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
