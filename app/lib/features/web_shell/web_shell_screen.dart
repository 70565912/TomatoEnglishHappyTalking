import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as path_lib;

import '../../core/config/app_config.dart';
import '../../core/logging/tomato_logger.dart';
import '../../core/practice/listening_sentence_visibility.dart';
import '../../core/theme/app_theme.dart';
import '../../core/webview/webview_environment.dart';
import '../../data/models/article_model.dart';
import '../../data/models/article_sentence_translation_model.dart';
import '../../data/models/article_song_model.dart';
import '../../data/models/picture_book_model.dart';
import '../../services/api_cache_service.dart';
import '../../services/article_song_cache_service.dart';
import '../../services/asset_path_service.dart';
import '../../services/bailian_music_service.dart';
import '../../services/book_transfer_service.dart';
import '../../services/database_service.dart';
import '../../services/content_safety_service.dart';
import '../../services/external_song_import_service.dart';
import '../../services/listening_audio_material_service.dart';
import '../../services/nlp_service.dart';
import '../../services/picture_book_service.dart';
import '../../services/practice_input_parser.dart';
import '../../services/practice_text_service.dart';
import '../../services/recording_export_service.dart';
import '../../services/scoring_service.dart';
import '../../services/song_subtitle_timeline_service.dart';
import '../../services/text_generation_service.dart';
import '../../services/tts_memory_cache_service.dart';
import '../../services/tts_service.dart';
import '../chat/providers/chat_provider.dart';
import '../follow_read/providers/follow_read_provider.dart';
import 'suno/suno_automation_host.dart';
import 'suno/suno_automation_controller.dart';
import 'suno/suno_web_scripts.dart';
import 'suno/suno_utilities.dart';
import 'web_bridge_protocol.dart';
import 'web_shell_qa_server.dart';

class WebShellScreen extends ConsumerStatefulWidget {
  const WebShellScreen({super.key});

  @override
  ConsumerState<WebShellScreen> createState() => _WebShellScreenState();
}

class _WebShellScreenState extends ConsumerState<WebShellScreen>
    with WidgetsBindingObserver {
  static const _devServerUrl = String.fromEnvironment(
    'TOMATO_WEB_UI_DEV_URL',
  );
  static final _qaRemoteEnabled =
      const bool.fromEnvironment('TOMATO_QA_REMOTE') ||
          _envFlag('TOMATO_QA_REMOTE');
  static final _qaRemotePort =
      int.tryParse(Platform.environment['TOMATO_QA_PORT'] ?? '') ??
          const int.fromEnvironment('TOMATO_QA_PORT', defaultValue: 39317);
  static final _qaRemoteToken = Platform.environment['TOMATO_QA_TOKEN'] ??
      const String.fromEnvironment('TOMATO_QA_TOKEN');
  static const _articleContentMaxChars = 8000;
  static const _sunoSongPurpose = 'article_suno_song_v1';
  static const _bailianSongPurpose = BailianMusicService.cachePurpose;
  static const _mainWebViewFrameRateSettleDelay = Duration(milliseconds: 900);
  static const _mainWebViewFrameRateIdleDelay = Duration(milliseconds: 2200);
  static const _mainWebViewActiveFpsLimit = 0;
  static const _mainWebViewSettledFpsLimit = 12;
  static const _mainWebViewIdleFpsLimit = 5;
  static const _englishVoicePreviewText =
      "Hello, I am your tomato tutor. Let's practice English together.";
  static const _chineseVoicePreviewText = '你好，我是番茄助教。让我们一起快乐练英语。';

  InAppWebViewController? _controller;
  WebShellQaServer? _qaServer;
  Timer? _mainWebViewFrameRateTimer;
  bool _mainWebViewFpsLimitUnsupported = false;
  bool _mainWebViewFpsLimitWarningLogged = false;
  int _mainWebViewCurrentFpsLimit = _mainWebViewActiveFpsLimit;
  int _mainWebViewFrameRateActivityDepth = 0;
  ProviderSubscription<AsyncValue<FollowReadState>>? _followSubscription;
  ProviderSubscription<ChatState>? _chatSubscription;
  AudioPlayer? _listeningPlayer;
  AudioPlayer? _previewPlayer;
  AudioPlayer? _songPlayer;
  final Map<String, Future<String>> _listeningTtsPathFutures = {};
  final Map<String, Future<ArticleSongVersion>> _songTimelineTasks = {};
  final Map<String, String> _songTimelineErrors = {};
  InAppWebViewController? _sunoController;
  late final SunoAutomationController _sunoEngine;

  bool get _supportsWindowsFrameRateLimit =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.windows &&
      !_mainWebViewFpsLimitUnsupported;

  bool get _canLimitMainWebViewFrameRate =>
      _supportsWindowsFrameRateLimit &&
      mounted &&
      _controller != null &&
      _webReady &&
      _mainWebViewFrameRateActivityDepth == 0 &&
      _listeningPlayer == null &&
      _previewPlayer == null &&
      _songPlayer == null &&
      _recordingCancelToken == null;

  // Visible idle GPU comes from flutter_inappwebview_windows copying WebView2
  // frames into a Flutter texture. Do not Stop() the visible capture session:
  // that can leave Flutter without a valid texture surface and flash blank.
  Future<bool> _setWindowsFrameRateLimit(
    InAppWebViewController controller,
    int fpsLimit,
  ) async {
    if (!_supportsWindowsFrameRateLimit) {
      return false;
    }
    final viewId = controller.getViewId();
    if (viewId == null) {
      return false;
    }
    final channel = MethodChannel(
      'com.pichillilorenzo/custom_platform_view_$viewId',
    );
    try {
      await channel.invokeMethod<void>('setFpsLimit', fpsLimit);
      return true;
    } on MissingPluginException catch (error, stackTrace) {
      _mainWebViewFpsLimitUnsupported = true;
      _logFrameRateLimitWarning(
        error: error,
        stackTrace: stackTrace,
        message: 'Windows WebView frame-rate limit is not available.',
      );
      return false;
    } on PlatformException catch (error, stackTrace) {
      _logFrameRateLimitWarning(
        error: error,
        stackTrace: stackTrace,
        message: 'Windows WebView frame-rate limit failed.',
      );
      return false;
    }
  }

  void _logFrameRateLimitWarning({
    required Object error,
    required StackTrace stackTrace,
    required String message,
  }) {
    if (_mainWebViewFpsLimitWarningLogged) {
      return;
    }
    _mainWebViewFpsLimitWarningLogged = true;
    TomatoLogger.warn(
      category: 'webview',
      event: 'frame_rate_limit_unavailable',
      message: message,
      error: error,
      stackTrace: stackTrace,
    );
  }

  void _markMainWebViewFrameRateActive() {
    if (!_supportsWindowsFrameRateLimit) {
      return;
    }
    _mainWebViewFrameRateTimer?.cancel();
    unawaited(_applyMainWebViewFpsLimit(_mainWebViewActiveFpsLimit));
    _scheduleMainWebViewFrameRateLimit();
  }

  Future<T> _runWithMainWebViewFrameRateActive<T>(
    Future<T> Function() action,
  ) async {
    if (!_supportsWindowsFrameRateLimit) {
      return action();
    }
    _mainWebViewFrameRateTimer?.cancel();
    _mainWebViewFrameRateActivityDepth += 1;
    try {
      await _applyMainWebViewFpsLimit(_mainWebViewActiveFpsLimit);
      return await action();
    } finally {
      _mainWebViewFrameRateActivityDepth -= 1;
      if (_mainWebViewFrameRateActivityDepth < 0) {
        _mainWebViewFrameRateActivityDepth = 0;
      }
      _scheduleMainWebViewFrameRateLimit();
    }
  }

  void _scheduleMainWebViewFrameRateLimit() {
    if (!_canLimitMainWebViewFrameRate) {
      return;
    }
    _mainWebViewFrameRateTimer?.cancel();
    _mainWebViewFrameRateTimer = Timer(_mainWebViewFrameRateSettleDelay, () {
      _mainWebViewFrameRateTimer = null;
      if (!_canLimitMainWebViewFrameRate) {
        return;
      }
      unawaited(_applyMainWebViewFpsLimit(_mainWebViewSettledFpsLimit));
      final idleDelay =
          _mainWebViewFrameRateIdleDelay - _mainWebViewFrameRateSettleDelay;
      _mainWebViewFrameRateTimer = Timer(idleDelay, () {
        _mainWebViewFrameRateTimer = null;
        if (!_canLimitMainWebViewFrameRate) {
          return;
        }
        unawaited(_applyMainWebViewFpsLimit(_mainWebViewIdleFpsLimit));
      });
    });
  }

  Future<void> _applyMainWebViewFpsLimit(int fpsLimit) async {
    if (!_supportsWindowsFrameRateLimit ||
        _mainWebViewCurrentFpsLimit == fpsLimit) {
      return;
    }
    final controller = _controller;
    if (controller == null) {
      return;
    }
    final changed = await _setWindowsFrameRateLimit(controller, fpsLimit);
    if (changed) {
      _mainWebViewCurrentFpsLimit = fpsLimit;
    }
  }

  RecordingCancelToken? _recordingCancelToken;
  int? _activeFollowArticleId;
  int? _activeListeningArticleId;
  int? _activeChatArticleId;
  int _listeningPlaybackToken = 0;
  int _previewPlaybackToken = 0;
  int _songPlaybackToken = 0;
  bool _listeningPausedForWord = false;
  bool _webReady = false;
  String? _loadError;
  final List<Map<String, dynamic>> _pendingEvents = [];
  final Set<String> _retryingPictureBookPages = <String>{};

  bool get _usesDevServer => _devServerUrl.trim().isNotEmpty;

  static bool _envFlag(String key) {
    final value = (Platform.environment[key] ?? '').trim().toLowerCase();
    return value == '1' || value == 'true' || value == 'yes' || value == 'on';
  }

  BridgeRouter get _bridgeRouter => BridgeRouter({
        'app.ready': _handleAppReady,
        'app.navigate': _handleAppNavigate,
        'app.back': _handleAppBack,
        'article.list': _handleArticleList,
        'article.translateToEnglish': _handleArticleTranslateToEnglish,
        'article.suggestTitle': _handleArticleSuggestTitle,
        'article.create': _handleArticleCreate,
        'article.rename': _handleArticleRename,
        'article.fullText': _handleArticleFullText,
        'article.delete': _handleArticleDelete,
        'series.list': _handleSeriesList,
        'series.suggestDescription': _handleSeriesSuggestDescription,
        'series.create': _handleSeriesCreate,
        'series.update': _handleSeriesUpdate,
        'series.delete': _handleSeriesDelete,
        'series.attachArticle': _handleSeriesAttachArticle,
        'series.export': _handleSeriesExport,
        'series.import': _handleSeriesImport,
        'pictureBook.state': _handlePictureBookState,
        'pictureBook.pageImage': _handlePictureBookPageImage,
        'pictureBook.promptReview': _handlePictureBookPromptReview,
        'pictureBook.pagePromptReview': _handlePictureBookPagePromptReview,
        'pictureBook.refreshPromptReview':
            _handlePictureBookRefreshPromptReview,
        'pictureBook.savePromptReview': _handlePictureBookSavePromptReview,
        'pictureBook.confirmPromptReview':
            _handlePictureBookConfirmPromptReview,
        'pictureBook.confirmPagePromptReview':
            _handlePictureBookConfirmPagePromptReview,
        'pictureBook.cancelPromptReview': _handlePictureBookCancelPromptReview,
        'pictureBook.generate': _handlePictureBookGenerate,
        'pictureBook.retryPage': _handlePictureBookRetryPage,
        'pictureBook.clearArticleCache': _handlePictureBookClearArticleCache,
        'follow.open': _handleFollowOpen,
        'follow.play': _handleFollowPlay,
        'follow.recordStart': _handleFollowRecordStart,
        'follow.recordStop': _handleFollowRecordStop,
        'follow.recordReplay': _handleFollowRecordReplay,
        'follow.retry': _handleFollowRetry,
        'follow.next': _handleFollowNext,
        'follow.replay': _handleFollowReplay,
        'follow.pause': _handleFollowPause,
        'follow.resume': _handleFollowResume,
        'listening.open': _handleListeningOpen,
        'listening.audioStatus': _handleListeningAudioStatus,
        'listening.audioGenerate': _handleListeningAudioGenerate,
        'listening.prepare': _handleListeningPrepare,
        'listening.preloadChinese': _handleListeningPreloadChinese,
        'listening.play': _handleListeningPlay,
        'listening.playSequence': _handleListeningPlaySequence,
        'listening.fullscreenReady': _handleListeningFullscreenReady,
        'listening.recordingReady': _handleListeningRecordingReady,
        'listening.recordVideo': _handleListeningRecordVideo,
        'listening.cancelRecording': _handleListeningCancelRecording,
        'recording.videoList': _handleRecordingVideoList,
        'recording.videoSetDefault': _handleRecordingVideoSetDefault,
        'recording.videoPlay': _handleRecordingVideoPlay,
        'recording.videoDelete': _handleRecordingVideoDelete,
        'recording.videoOpenDirectory': _handleRecordingVideoOpenDirectory,
        'listening.songState': _handleListeningSongState,
        'listening.songGenerate': _handleListeningSongGenerate,
        'listening.songImportExternal': _handleListeningSongImportExternal,
        'listening.songConfirmSunoCreate':
            _handleListeningSongConfirmSunoCreate,
        'listening.songDownloadSunoExisting':
            _handleListeningSongDownloadSunoExisting,
        'listening.songTimelineGenerate': _handleListeningSongTimelineGenerate,
        'listening.songPlay': _handleListeningSongPlay,
        'listening.songSetDefault': _handleListeningSongSetDefault,
        'listening.songDeleteVersion': _handleListeningSongDeleteVersion,
        'listening.songStop': _handleListeningSongStop,
        'listening.songPause': _handleListeningSongPause,
        'listening.songResume': _handleListeningSongResume,
        'listening.songRecordVideo': _handleListeningSongRecordVideo,
        'listening.songExportAudio': _handleListeningSongExportAudio,
        'suno.debugInspect': _handleSunoDebugInspect,
        'suno.debugFill': _handleSunoDebugFill,
        'suno.debugRows': _handleSunoDebugRows,
        'suno.debugSnapshot': _handleSunoDebugSnapshot,
        'suno.continueAutomation': _handleSunoContinueAutomation,
        'listening.updateSentence': _handleListeningUpdateSentence,
        'listening.resynthesizeSentence': _handleListeningResynthesizeSentence,
        'listening.stop': _handleListeningStop,
        'listening.pause': _handleListeningPause,
        'listening.resume': _handleListeningResume,
        'word.lookup': _handleWordLookup,
        'word.play': _handleWordPlay,
        'word.stop': _handleWordStop,
        'chat.open': _handleChatOpen,
        'chat.recordStart': _handleChatRecordStart,
        'chat.recordStop': _handleChatRecordStop,
        'chat.sendText': _handleChatSendText,
        'chat.replay': _handleChatReplay,
        'settings.load': _handleSettingsLoad,
        'settings.saveVoice': _handleSettingsSaveVoice,
        'settings.saveSong': _handleSettingsSaveSong,
        'settings.saveCloud': _handleSettingsSaveCloud,
        'diagnostics.logsRecent': _handleDiagnosticsLogsRecent,
        'diagnostics.logsExport': _handleDiagnosticsLogsExport,
        'diagnostics.clientLog': _handleDiagnosticsClientLog,
        'diagnostics.songAsrSnapshot': _handleDiagnosticsSongAsrSnapshot,
        'diagnostics.songTimelineFromAsrSnapshot':
            _handleDiagnosticsSongTimelineFromAsrSnapshot,
        'recording.settings.load': _handleRecordingSettingsLoad,
        'recording.settings.save': _handleRecordingSettingsSave,
        'settings.previewVoice': _handleSettingsPreviewVoice,
        'contentSafety.setRuleEnabled': _handleContentSafetySetRuleEnabled,
        'contentSafety.deleteRule': _handleContentSafetyDeleteRule,
      });

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sunoEngine = SunoAutomationController(host: _WebShellSunoHost(this));
    if (_qaRemoteEnabled) {
      TomatoLogger.info(
        category: 'qa',
        event: 'server.start_requested',
        data: {
          'port': _qaRemotePort,
          'tokenEnabled': _qaRemoteToken.trim().isNotEmpty,
        },
      );
      _qaServer = WebShellQaServer(
        port: _qaRemotePort,
        token: _qaRemoteToken,
        health: _qaHealth,
        snapshot: _qaSnapshot,
        screenshot: _qaScreenshot,
        navigate: _qaNavigate,
        click: _qaClick,
        fill: _qaFill,
        dispatchBridge: (raw) => _runWithMainWebViewFrameRateActive(
          () => _bridgeRouter.dispatch(raw),
        ),
      );
      unawaited(_qaServer!.start());
    }
  }

  void sunoRequestSetState() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mainWebViewFrameRateTimer?.cancel();
    unawaited(_qaServer?.stop());
    _recordingCancelToken?.cancel();
    unawaited(_stopListeningPlayback());
    unawaited(_stopVoicePreview());
    unawaited(_stopSongPlayback());
    _stopSunoAutomation(clearVisible: true);
    _listeningTtsPathFutures.clear();
    final followArticleId = _activeFollowArticleId;
    if (followArticleId != null) {
      TtsMemoryCacheService.releaseArticle(followArticleId);
    }
    _closeFollowSession();
    final listeningArticleId = _activeListeningArticleId;
    if (listeningArticleId != null) {
      TtsMemoryCacheService.releaseArticle(listeningArticleId);
    }
    _activeListeningArticleId = null;
    _closeChatSession();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _markMainWebViewFrameRateActive();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _markMainWebViewFrameRateActive();
    } else {
      _mainWebViewFrameRateTimer?.cancel();
    }
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
        child: Stack(
          children: [
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) => _markMainWebViewFrameRateActive(),
                onPointerMove: (_) => _markMainWebViewFrameRateActive(),
                onPointerHover: (_) => _markMainWebViewFrameRateActive(),
                onPointerSignal: (_) => _markMainWebViewFrameRateActive(),
                child: InAppWebView(
                  initialUrlRequest: URLRequest(
                    url: WebUri(
                      _usesDevServer
                          ? _devServerUrl.trim()
                          : tomatoWebUiLocalUrl,
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
                    TomatoLogger.info(
                      category: 'webview',
                      event: 'main.created',
                      data: {
                        'usesDevServer': _usesDevServer,
                        'initialUrl': _usesDevServer
                            ? _devServerUrl.trim()
                            : tomatoWebUiLocalUrl,
                      },
                    );
                    _controller = controller;
                    _scheduleMainWebViewFrameRateLimit();
                    controller.addJavaScriptHandler(
                      handlerName: 'tomatoBridge',
                      callback: (args) async {
                        final raw = args.isEmpty ? null : args.first;
                        return _runWithMainWebViewFrameRateActive(
                          () => _bridgeRouter.dispatch(raw),
                        );
                      },
                    );
                  },
                  onReceivedError: (controller, request, error) {
                    if (request.isForMainFrame == false) {
                      return;
                    }
                    TomatoLogger.error(
                      category: 'webview',
                      event: 'main.load_error',
                      message: error.description,
                      data: {
                        'url': request.url.toString(),
                        'type': error.type.toString(),
                      },
                    );
                    setState(() {
                      _loadError = 'Web UI 加载失败：${error.description}';
                    });
                  },
                ),
              ),
            ),
            if (_sunoEngine.state.visible)
              Positioned.fill(child: _buildSunoOverlay()),
          ],
        ),
      ),
    );
  }

  Widget _buildSunoOverlay() {
    final statusText = _sunoOverlayStatusText();
    final canConfirm = _sunoEngine.state.statusKey == 'waitingConfirm' &&
        !_sunoEngine.state.createSubmitted;
    final isComplete = _sunoEngine.state.statusKey == 'complete';
    return Material(
      color: Colors.black.withValues(alpha: 0.42),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: AppTheme.darkBlue,
            child: Row(
              children: [
                const Icon(Icons.music_note, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    statusText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (canConfirm)
                  ElevatedButton.icon(
                    onPressed: _sunoEngine.state.automationBusy
                        ? null
                        : () => unawaited(_confirmSunoCreate()),
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('确认消耗 credits 并创建'),
                  ),
                if (isComplete)
                  ElevatedButton.icon(
                    onPressed: () => _closeCompletedSunoOverlay(),
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('确认并关闭 Suno 窗口'),
                  ),
                const SizedBox(width: 8),
                if (!isComplete)
                  TextButton(
                    onPressed: () => unawaited(_continueSunoAutomation()),
                    child: const Text(
                      '继续检测',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                if (!isComplete)
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _sunoEngine.state.visible = false;
                      });
                    },
                    child: const Text(
                      '隐藏',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                if (!isComplete)
                  TextButton(
                    onPressed: () {
                      final articleId = _sunoEngine.state.articleId;
                      _stopSunoAutomation(clearVisible: true);
                      _sunoController = null;
                      if (articleId != null) {
                        unawaited(_pushSongState(articleId));
                      }
                    },
                    child: const Text(
                      '取消',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              color: Colors.white,
              child: InAppWebView(
                key:
                    ValueKey('suno-webview-$_sunoEngine.state.webViewInstance'),
                initialUrlRequest: URLRequest(
                  url: WebUri(_sunoEngine.state.initialUrl),
                ),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  transparentBackground: false,
                  mediaPlaybackRequiresUserGesture: false,
                  isInspectable: kDebugMode,
                  useOnDownloadStart: true,
                ),
                webViewEnvironment: tomatoWebViewEnvironment,
                onWebViewCreated: (controller) {
                  TomatoLogger.info(
                    category: 'suno',
                    event: 'webview.created',
                    articleId: _sunoEngine.state.articleId,
                    data: {'initialUrl': _sunoEngine.state.initialUrl},
                  );
                  _sunoController = controller;
                  _sunoEngine.attachWebController(controller);
                },
                onLoadStop: (controller, url) {
                  _sunoEngine.onLoadStop(url?.toString());
                  TomatoLogger.info(
                    category: 'suno',
                    event: 'webview.load_stop',
                    articleId: _sunoEngine.state.articleId,
                    data: {
                      'url': url?.toString(),
                      'pageKind': url == null
                          ? null
                          : SunoUtilities.pageKind(url.toString()),
                    },
                  );
                  _sunoController = controller;
                  _sunoEngine.attachWebController(controller);
                  unawaited(_continueSunoAutomation());
                },
                onDownloadStartRequest: (controller, request) {
                  TomatoLogger.info(
                    category: 'suno',
                    event: 'download.request',
                    articleId: _sunoEngine.state.articleId,
                    data: {
                      'url': request.url.toString(),
                      'suggestedFilename': request.suggestedFilename,
                    },
                  );
                  unawaited(_handleSunoDownload(request));
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<Map<String, dynamic>> _handleAppReady(BridgeMessage message) async {
    _webReady = true;
    TomatoLogger.info(
      category: 'webview',
      event: 'app.ready',
      route: message.payload['route']?.toString(),
      data: {'pendingEvents': _pendingEvents.length},
    );
    unawaited(_flushPendingEvents());
    final articles = await _articleListPayload();
    return {
      'platform': defaultTargetPlatform.name,
      'usesDevServer': _usesDevServer,
      'articles': articles['articles'],
      'series': articles['series'],
    };
  }

  Future<Map<String, dynamic>> _handleAppNavigate(BridgeMessage message) async {
    final path = _payloadString(message.payload, 'path');
    if (!path.startsWith('/follow')) {
      final articleId = _activeFollowArticleId;
      if (articleId != null) {
        TtsMemoryCacheService.releaseArticle(articleId);
      }
      _closeFollowSession();
    }
    if (!path.startsWith('/chat')) {
      _closeChatSession();
    }
    if (!_pathIsListeningContext(path)) {
      final articleId = _activeListeningArticleId;
      unawaited(_stopListeningPlayback());
      unawaited(_stopSongPlayback());
      _stopSunoAutomation(clearVisible: true);
      if (articleId != null) {
        TtsMemoryCacheService.releaseArticle(articleId);
      }
      _activeListeningArticleId = null;
    }
    return {'path': path};
  }

  static final RegExp _bookPlayerPathPattern = RegExp(r'^/books/\d+/player');

  /// 听力上下文包括旧的 `/listen/<id>` 路由，以及书籍播放器 `/books/<id>/player`
  /// （听力/歌曲子模式）。书籍播放器切换听力/歌曲模式只会改变 `mode` query，不会
  /// 重新触发 Web UI 的 `listening.open`，因此这里不能因为路径不是 `/listen` 就把
  /// `_activeListeningArticleId` 清空，否则从歌曲切回听力播放会报“听力任务尚未打开”。
  bool _pathIsListeningContext(String path) {
    return path.startsWith('/listen') || _bookPlayerPathPattern.hasMatch(path);
  }

  Future<Map<String, dynamic>> _handleAppBack(BridgeMessage message) async {
    if (mounted) {
      await Navigator.of(context).maybePop();
    }
    return {};
  }

  Future<Map<String, dynamic>> _handleArticleList(BridgeMessage message) =>
      _articleListPayload();

  Future<Map<String, dynamic>> _handleArticleTranslateToEnglish(
    BridgeMessage message,
  ) async {
    final content = _payloadString(message.payload, 'content').trim();
    if (content.isEmpty) {
      throw const FormatException('请先输入文章内容');
    }
    _ensureArticleContentWithinLimit(content);
    final parsedInput = PracticeInputParser.parse(content);
    return {
      'content': await _englishPracticeContent(
        content,
        parsedInput: parsedInput,
      ),
    };
  }

  Future<Map<String, dynamic>> _handleArticleSuggestTitle(
    BridgeMessage message,
  ) async {
    final content = _payloadString(message.payload, 'content').trim();
    if (content.isEmpty) {
      throw const FormatException('请先输入文章内容');
    }
    _ensureArticleContentWithinLimit(content);

    final parsedInput = PracticeInputParser.parse(content);
    final localTitle = parsedInput.titleCandidate.trim();
    if (localTitle.isNotEmpty) {
      return {
        'title':
            localTitle.length > 80 ? localTitle.substring(0, 80) : localTitle,
      };
    }

    final englishContent = await _englishPracticeContent(
      content,
      parsedInput: parsedInput,
    );
    final reply = await PracticeTextService.suggestArticleTitle(
      content: englishContent,
    );
    final title = reply.text.trim();
    if (title.isEmpty) {
      throw const FormatException('自动标题暂时生成失败');
    }
    return {'title': title.length > 80 ? title.substring(0, 80) : title};
  }

  Future<Map<String, dynamic>> _handleArticleCreate(
    BridgeMessage message,
  ) async {
    final requestedTitle = _payloadString(message.payload, 'title').trim();
    final content = _payloadString(message.payload, 'content').trim();
    final pictureBookEnabled = _payloadBool(
      message.payload,
      'pictureBookEnabled',
      fallback: true,
    );
    final requestedSeriesId = _payloadOptionalInt(message.payload, 'seriesId');
    final requestedSeriesTitle =
        _payloadString(message.payload, 'seriesTitle').trim();
    final requestedSeriesDescription =
        _payloadString(message.payload, 'seriesDescription').trim();
    final requestedSeriesCharactersProvided =
        message.payload.containsKey('seriesCharacters');
    final requestedSeriesCharacters =
        _payloadBookCharacters(message.payload, 'seriesCharacters');
    if (content.isEmpty) {
      throw const FormatException('请填写文章内容');
    }
    _ensureArticleContentWithinLimit(content);

    final parsedInput = PracticeInputParser.parse(content);
    final englishContent = await _englishPracticeContent(
      content,
      parsedInput: parsedInput,
      strictAi: true,
    );
    final sentences = NlpService.splitSentences(englishContent);
    if (sentences.isEmpty) {
      throw const FormatException('文章内容需要能转换为英文练习句子');
    }
    final title = await _resolveArticleTitle(
      requestedTitle,
      englishContent,
      titleCandidate: parsedInput.titleCandidate,
    );

    final article = Article(
      title: title,
      content: englishContent,
      sentences: sentences,
      createdAt: DateTime.now(),
    );
    final id = await DatabaseService.saveArticle(article);
    int? seriesIdForRollback;
    var shouldRollbackArticle = true;
    try {
      // Translation stays inside the create path on purpose. If Ark rejects the
      // text, the user must be able to edit the submitted content before the
      // article appears as saved.
      await _saveArticleTranslationsAtCreate(
        articleId: id,
        sentences: sentences,
        parsedInput: parsedInput,
      );

      final savedArticle = article.copyWith(id: id);
      if (pictureBookEnabled) {
        final series = await _resolveStorySeries(
          requestedSeriesId: requestedSeriesId,
          requestedSeriesTitle: requestedSeriesTitle,
          requestedSeriesDescription: requestedSeriesDescription,
          requestedSeriesCharacters: requestedSeriesCharacters,
          requestedSeriesCharactersProvided: requestedSeriesCharactersProvided,
        );
        final seriesId = series.id;
        seriesIdForRollback = seriesId;
        if (seriesId == null) {
          throw const FormatException('书籍创建失败');
        }
        final chapter = await PictureBookService.ensureChapterForArticle(
          seriesId: seriesId,
          article: savedArticle,
        );
        await _ensureStorySeriesDescription(
          series: series,
          article: savedArticle,
        );
        // Saving only persists the chapter relationship. The Web UI must open
        // pictureBook.promptReview next; image API calls happen only after the
        // user confirms pictureBook.confirmPromptReview.
        unawaited(_pushEvent(
          'pictureBook.state',
          await PictureBookService.statePayload(chapter.articleId),
        ));
      }

      final payload = await _articleListPayload();
      unawaited(_pushEvent('article.state', payload));
      shouldRollbackArticle = false;
      return {
        'article': await _articleJsonWithStory(
          savedArticle,
          averageScore: 0,
        ),
        'articles': payload['articles'],
        'series': payload['series'],
      };
    } finally {
      if (shouldRollbackArticle) {
        await DatabaseService.deleteArticle(id);
        if (seriesIdForRollback != null && requestedSeriesId == null) {
          await DatabaseService.deleteStorySeriesIfEmpty(seriesIdForRollback);
        }
      }
    }
  }

  Future<Map<String, dynamic>> _handleArticleDelete(
    BridgeMessage message,
  ) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    await DatabaseService.deleteArticle(articleId);
    await ExternalSongImportService.deleteArticleAssets(articleId);
    TtsMemoryCacheService.releaseArticle(articleId);
    if (_activeFollowArticleId == articleId) {
      _closeFollowSession();
    }
    if (_activeListeningArticleId == articleId) {
      await _stopListeningPlayback();
      await _stopSongPlayback();
      _activeListeningArticleId = null;
    }
    if (_activeChatArticleId == articleId) {
      _closeChatSession();
    }
    final payload = await _articleListPayload();
    unawaited(_pushEvent('article.state', payload));
    return payload;
  }

  Future<Map<String, dynamic>> _handleArticleRename(
    BridgeMessage message,
  ) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    final title =
        _normalizeEnglishWordJoiners(_payloadString(message.payload, 'title'))
            .trim();
    if (title.isEmpty) {
      throw const FormatException('文章标题不能为空');
    }
    if (title.length > 120) {
      throw const FormatException('文章标题不能超过 120 个字符');
    }

    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) {
      throw FormatException('文章不存在（id=$articleId）');
    }
    await DatabaseService.updateArticleTitle(articleId, title);
    await DatabaseService.updateStoryChapterTitleForArticle(articleId, title);
    final updatedArticle =
        (await DatabaseService.getArticleById(articleId)) ?? rawArticle;
    final payload = await _articleListPayload();
    unawaited(_pushEvent('article.state', payload));
    return {
      'article': await _articleJsonWithStory(
        updatedArticle.copyWith(title: title),
        averageScore: await DatabaseService.getAverageScore(articleId),
      ),
      'articles': payload['articles'],
      'series': payload['series'],
    };
  }

  Future<Map<String, dynamic>> _handleArticleFullText(
    BridgeMessage message,
  ) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) {
      throw FormatException('文章不存在（id=$articleId）');
    }

    final article = await _articleWithPersistedSentences(rawArticle);
    final articleJson = await _articleJsonWithStory(
      article,
      averageScore: await DatabaseService.getAverageScore(articleId),
    );
    final seriesTitle = articleJson['seriesTitle']?.toString().trim() ?? '';
    return {
      'article': articleJson,
      'bookTitle': seriesTitle.isNotEmpty ? seriesTitle : article.title,
      'items': await _listeningItemsForArticle(article),
    };
  }

  Future<Map<String, dynamic>> _handleSeriesList(BridgeMessage message) async {
    return _storySeriesListPayload();
  }

  Future<Map<String, dynamic>> _handleSeriesSuggestDescription(
    BridgeMessage message,
  ) async {
    final requestedSeriesTitle =
        _payloadString(message.payload, 'seriesTitle').trim();
    final requestedArticleTitle =
        _payloadString(message.payload, 'articleTitle').trim();
    final currentDescription =
        _payloadString(message.payload, 'description').trim();
    final currentCharacters =
        _payloadBookCharacters(message.payload, 'characters');
    final content = _payloadString(message.payload, 'content').trim();
    if (content.isEmpty) {
      throw const FormatException('请先填写文章内容');
    }
    _ensureArticleContentWithinLimit(content);

    final parsedInput = PracticeInputParser.parse(content);
    final englishContent = await _englishPracticeContent(
      content,
      parsedInput: parsedInput,
    );
    final sentences = NlpService.splitSentences(englishContent);
    if (sentences.isEmpty) {
      throw const FormatException('文章内容需要能转换为英文练习句子');
    }
    final articleTitle = _firstNonEmptyString([
          requestedArticleTitle,
          parsedInput.titleCandidate,
        ]) ??
        'Untitled chapter';
    final seriesTitle = requestedSeriesTitle;
    if (seriesTitle.isEmpty) {
      throw const FormatException('请填写书籍名称');
    }
    final now = DateTime.now();
    final article = Article(
      title: articleTitle,
      content: englishContent,
      sentences: sentences,
      createdAt: now,
    );
    final suggestion = await PictureBookService.suggestBookDescription(
      article: article,
      seriesTitle: seriesTitle,
      currentDescription: currentDescription,
      currentCharacters: currentCharacters,
    );
    if (suggestion.description.trim().isEmpty) {
      throw const FormatException('自动书籍简介暂时生成失败');
    }
    return suggestion.toJson();
  }

  Future<Map<String, dynamic>> _handleSeriesCreate(
    BridgeMessage message,
  ) async {
    final title = _payloadString(message.payload, 'title').trim();
    final description = _payloadString(message.payload, 'description').trim();
    final characters = _payloadBookCharacters(message.payload, 'characters');
    if (title.isEmpty) {
      throw const FormatException('请填写书籍名称');
    }
    await PictureBookService.createSeries(
      title: title,
      description: description,
      characters: characters,
    );
    final payload = await _articleListPayload();
    unawaited(_pushEvent('article.state', payload));
    return payload;
  }

  Future<Map<String, dynamic>> _handleSeriesUpdate(
    BridgeMessage message,
  ) async {
    final seriesId = _payloadInt(message.payload, 'seriesId');
    final title = _payloadString(message.payload, 'title').trim();
    final description = _payloadString(message.payload, 'description').trim();
    final characters = _payloadBookCharacters(message.payload, 'characters');
    if (title.isEmpty) {
      throw const FormatException('请填写书籍名称');
    }
    if (title.length > 120) {
      throw const FormatException('书籍名称不能超过 120 个字符');
    }
    final series = await DatabaseService.getStorySeriesById(seriesId);
    if (series == null) {
      throw FormatException('书籍不存在（id=$seriesId）');
    }
    await DatabaseService.updateStorySeries(
      series.copyWith(
        title: title,
        description: description,
        characters: characters,
        updatedAt: DateTime.now(),
      ),
    );
    final payload = await _articleListPayload();
    unawaited(_pushEvent('article.state', payload));
    return payload;
  }

  Future<Map<String, dynamic>> _handleSeriesDelete(
    BridgeMessage message,
  ) async {
    final seriesId = _payloadInt(message.payload, 'seriesId');
    final deleted = await DatabaseService.deleteStorySeriesIfEmpty(seriesId);
    if (!deleted) {
      throw const FormatException('只能删除没有文章的书籍');
    }
    final payload = await _articleListPayload();
    unawaited(_pushEvent('article.state', payload));
    return payload;
  }

  Future<Map<String, dynamic>> _handleSeriesAttachArticle(
    BridgeMessage message,
  ) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    final requestedSeriesId = _payloadOptionalInt(message.payload, 'seriesId');
    final requestedSeriesTitle =
        _payloadString(message.payload, 'seriesTitle').trim();
    final requestedSeriesDescription =
        _payloadString(message.payload, 'seriesDescription').trim();
    final requestedSeriesCharactersProvided =
        message.payload.containsKey('seriesCharacters');
    final requestedSeriesCharacters =
        _payloadBookCharacters(message.payload, 'seriesCharacters');
    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) {
      throw FormatException('文章不存在（id=$articleId）');
    }

    final article = await _articleWithPersistedSentences(rawArticle);
    final series = await _resolveStorySeries(
      requestedSeriesId: requestedSeriesId,
      requestedSeriesTitle: requestedSeriesTitle,
      requestedSeriesDescription: requestedSeriesDescription,
      requestedSeriesCharacters: requestedSeriesCharacters,
      requestedSeriesCharactersProvided: requestedSeriesCharactersProvided,
    );
    final seriesId = series.id;
    if (seriesId == null) {
      throw const FormatException('书籍创建失败');
    }

    final chapter = await PictureBookService.attachArticleToSeries(
      seriesId: seriesId,
      article: article,
    );
    final payload = await _articleListPayload();
    unawaited(_pushEvent('article.state', payload));
    return {
      'article': await _articleJsonWithStory(article),
      'chapter': chapter.toJson(series),
      'articles': payload['articles'],
      'series': payload['series'],
    };
  }

  Future<Map<String, dynamic>> _handleSeriesExport(
    BridgeMessage message,
  ) async {
    final seriesId = _payloadInt(message.payload, 'seriesId');
    var outputDirectory =
        _payloadString(message.payload, 'outputDirectory').trim();
    if (outputDirectory.isEmpty) {
      outputDirectory = (await FilePicker.platform.getDirectoryPath(
            dialogTitle: '选择书籍导出目录',
          )) ??
          '';
    }
    if (outputDirectory.isEmpty) {
      return {'cancelled': true};
    }
    final result = await BookTransferService.exportSeries(
      seriesId: seriesId,
      outputDirectory: outputDirectory,
    );
    return result.toJson();
  }

  Future<Map<String, dynamic>> _handleSeriesImport(
    BridgeMessage message,
  ) async {
    var filePath = _payloadString(message.payload, 'filePath').trim();
    if (filePath.isEmpty) {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
        allowMultiple: false,
        withData: false,
        dialogTitle: '选择书籍迁移包',
      );
      filePath = picked?.files.single.path?.trim() ?? '';
    }
    if (filePath.isEmpty) {
      return {'cancelled': true};
    }
    final result = await BookTransferService.importSeriesArchive(
      filePath: filePath,
    );
    final payload = await _articleListPayload();
    unawaited(_pushEvent('article.state', payload));
    return {
      ...result.toJson(),
      'articles': payload['articles'],
      'series': payload['series'],
    };
  }

  Future<Map<String, dynamic>> _handlePictureBookState(
    BridgeMessage message,
  ) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    final includeImageUris = _payloadBool(
      message.payload,
      'includeImageUris',
      fallback: false,
    );
    return PictureBookService.statePayload(
      articleId,
      includeImageUris: includeImageUris,
    );
  }

  Future<Map<String, dynamic>> _handlePictureBookPageImage(
    BridgeMessage message,
  ) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    final pageIndex = _payloadInt(message.payload, 'pageIndex');
    final variant = _payloadString(
      message.payload,
      'variant',
      fallback: 'full',
    );
    return PictureBookService.pageImagePayload(
      articleId: articleId,
      pageIndex: pageIndex,
      variant: variant,
    );
  }

  Future<Map<String, dynamic>> _handlePictureBookPromptReview(
    BridgeMessage message,
  ) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    final regenerate = _payloadBool(
      message.payload,
      'regenerate',
      fallback: false,
    );
    return _pictureBookPromptReviewForArticle(
      articleId: articleId,
      regenerate: regenerate,
    );
  }

  Future<Map<String, dynamic>> _handlePictureBookPagePromptReview(
    BridgeMessage message,
  ) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    final pageIndex = _payloadInt(message.payload, 'pageIndex');
    return _pictureBookPagePromptReviewForArticle(
      articleId: articleId,
      pageIndex: pageIndex,
    );
  }

  Future<Map<String, dynamic>> _handlePictureBookRefreshPromptReview(
    BridgeMessage message,
  ) async {
    final reviewId = _payloadString(message.payload, 'reviewId').trim();
    if (reviewId.isEmpty) {
      throw const FormatException('缺少绘本提示词审核 ID');
    }
    return PictureBookService.refreshPromptReview(
      reviewId: reviewId,
      target: _payloadString(message.payload, 'target').trim(),
      bookDescription:
          _payloadString(message.payload, 'bookDescription').trim(),
      bookCharacters: _payloadBookCharacters(message.payload, 'bookCharacters'),
      newCharacters: _payloadBookCharacters(message.payload, 'newCharacters'),
      chapterDescription:
          _payloadString(message.payload, 'chapterDescription').trim(),
      scenes: _payloadMapList(message.payload, 'scenes'),
    );
  }

  Future<Map<String, dynamic>> _handlePictureBookConfirmPromptReview(
    BridgeMessage message,
  ) async {
    final reviewId = _payloadString(message.payload, 'reviewId').trim();
    if (reviewId.isEmpty) {
      throw const FormatException('缺少绘本提示词审核 ID');
    }
    final groupPrompt = _payloadString(message.payload, 'groupPrompt').trim();
    final bookDescription =
        _payloadString(message.payload, 'bookDescription').trim();
    final chapterDescription =
        _payloadString(message.payload, 'chapterDescription').trim();
    final bookCharacters =
        _payloadBookCharacters(message.payload, 'bookCharacters');
    final newCharacters =
        _payloadBookCharacters(message.payload, 'newCharacters');
    final scenes = _payloadMapList(message.payload, 'scenes');
    final state = await PictureBookService.confirmPromptReview(
      reviewId: reviewId,
      groupPrompt: groupPrompt,
      bookDescription: bookDescription,
      bookCharacters: bookCharacters,
      newCharacters: newCharacters,
      chapterDescription: chapterDescription,
      scenes: scenes,
      onProgress: (payload) => _pushEvent('pictureBook.state', payload),
    );
    unawaited(_pushEvent('pictureBook.state', state));
    final articlePayload = await _articleListPayload();
    unawaited(_pushEvent('article.state', articlePayload));
    return state;
  }

  Future<Map<String, dynamic>> _handlePictureBookConfirmPagePromptReview(
    BridgeMessage message,
  ) async {
    final reviewId = _payloadString(message.payload, 'reviewId').trim();
    if (reviewId.isEmpty) {
      throw const FormatException('缺少绘本提示词审核 ID');
    }
    final groupPrompt = _payloadString(message.payload, 'groupPrompt').trim();
    final bookDescription =
        _payloadString(message.payload, 'bookDescription').trim();
    final chapterDescription =
        _payloadString(message.payload, 'chapterDescription').trim();
    final bookCharacters =
        _payloadBookCharacters(message.payload, 'bookCharacters');
    final newCharacters =
        _payloadBookCharacters(message.payload, 'newCharacters');
    final scenes = _payloadMapList(message.payload, 'scenes');
    final referencePageIndexes =
        _payloadIntList(message.payload, 'referencePageIndexes');
    final referencePageIndex =
        _payloadOptionalInt(message.payload, 'referencePageIndex');
    final state = await PictureBookService.confirmPagePromptReview(
      reviewId: reviewId,
      groupPrompt: groupPrompt,
      bookDescription: bookDescription,
      bookCharacters: bookCharacters,
      newCharacters: newCharacters,
      chapterDescription: chapterDescription,
      scenes: scenes,
      referencePageIndexes: referencePageIndexes,
      referencePageIndex: referencePageIndex,
      onProgress: (payload) => _pushEvent('pictureBook.state', payload),
    );
    unawaited(_pushEvent('pictureBook.state', state));
    final articlePayload = await _articleListPayload();
    unawaited(_pushEvent('article.state', articlePayload));
    return state;
  }

  Future<Map<String, dynamic>> _handlePictureBookSavePromptReview(
    BridgeMessage message,
  ) async {
    final reviewId = _payloadString(message.payload, 'reviewId').trim();
    if (reviewId.isEmpty) {
      throw const FormatException('缺少绘本提示词审核 ID');
    }
    final groupPrompt = _payloadString(message.payload, 'groupPrompt').trim();
    final bookDescription =
        _payloadString(message.payload, 'bookDescription').trim();
    final chapterDescription =
        _payloadString(message.payload, 'chapterDescription').trim();
    final bookCharacters =
        _payloadBookCharacters(message.payload, 'bookCharacters');
    final newCharacters =
        _payloadBookCharacters(message.payload, 'newCharacters');
    final scenes = _payloadMapList(message.payload, 'scenes');
    return PictureBookService.savePromptReview(
      reviewId: reviewId,
      groupPrompt: groupPrompt,
      bookDescription: bookDescription,
      bookCharacters: bookCharacters,
      newCharacters: newCharacters,
      chapterDescription: chapterDescription,
      scenes: scenes,
    );
  }

  Future<Map<String, dynamic>> _handlePictureBookCancelPromptReview(
    BridgeMessage message,
  ) async {
    final reviewId = _payloadString(message.payload, 'reviewId').trim();
    if (reviewId.isEmpty) {
      return {
        'reviewId': reviewId,
        'cancelled': false,
      };
    }
    return PictureBookService.cancelPromptReview(reviewId);
  }

  Future<Map<String, dynamic>> _handlePictureBookGenerate(
    BridgeMessage message,
  ) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    final regenerate = _payloadBool(
      message.payload,
      'regenerate',
      fallback: false,
    );
    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) {
      throw FormatException('文章不存在（id=$articleId）');
    }
    return _pictureBookPromptReviewForArticle(
      articleId: articleId,
      regenerate: regenerate,
    );
  }

  Future<Map<String, dynamic>> _handlePictureBookRetryPage(
    BridgeMessage message,
  ) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    final retryKey = '$articleId:group';
    if (_retryingPictureBookPages.contains(retryKey)) {
      return PictureBookService.statePayload(articleId);
    }
    _retryingPictureBookPages.add(retryKey);
    try {
      return await _pictureBookPromptReviewForArticle(
        articleId: articleId,
        regenerate: true,
      );
    } finally {
      _retryingPictureBookPages.remove(retryKey);
    }
  }

  Future<Map<String, dynamic>> _pictureBookPromptReviewForArticle({
    required int articleId,
    required bool regenerate,
  }) async {
    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) {
      throw FormatException('文章不存在（id=$articleId）');
    }
    final article = await _articleWithPersistedSentences(rawArticle);
    var chapter = await DatabaseService.getStoryChapterForArticle(articleId);
    if (chapter == null) {
      final series = await PictureBookService.createSeries(
        title: article.title,
      );
      final seriesId = series.id;
      if (seriesId == null) {
        throw const FormatException('书籍创建失败');
      }
      chapter = await PictureBookService.ensureChapterForArticle(
        seriesId: seriesId,
        article: article,
      );
      final payload = await _articleListPayload();
      unawaited(_pushEvent('article.state', payload));
    }
    return PictureBookService.promptReviewPayload(
      article: article,
      chapter: chapter,
      regenerate: regenerate,
    );
  }

  Future<Map<String, dynamic>> _pictureBookPagePromptReviewForArticle({
    required int articleId,
    required int pageIndex,
  }) async {
    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) {
      throw FormatException('文章不存在（id=$articleId）');
    }
    final article = await _articleWithPersistedSentences(rawArticle);
    final chapter = await DatabaseService.getStoryChapterForArticle(articleId);
    if (chapter == null) {
      return _pictureBookPromptReviewForArticle(
        articleId: articleId,
        regenerate: true,
      );
    }
    return PictureBookService.pagePromptReviewPayload(
      article: article,
      chapter: chapter,
      pageIndex: pageIndex,
    );
  }

  Future<Map<String, dynamic>> _handlePictureBookClearArticleCache(
    BridgeMessage message,
  ) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    final result = await PictureBookService.clearArticlePictureBookCache(
      articleId,
    );
    final state = await PictureBookService.statePayload(articleId);
    unawaited(_pushEvent('pictureBook.state', state));
    final articlePayload = await _articleListPayload();
    unawaited(_pushEvent('article.state', articlePayload));
    return {
      ...result,
      'pictureBook': state,
    };
  }

  Future<Map<String, dynamic>> _handleFollowOpen(BridgeMessage message) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    _closeChatSession();
    final listeningArticleId = _activeListeningArticleId;
    if (listeningArticleId != null && listeningArticleId != articleId) {
      TtsMemoryCacheService.releaseArticle(listeningArticleId);
    }
    _activeListeningArticleId = null;
    await _stopListeningPlayback();
    await _stopSongPlayback();
    _openFollowSession(articleId);
    final value = await ref.read(followReadProvider(articleId).future);
    final payload = _followPayload(AsyncValue.data(value));
    unawaited(_pushEvent('follow.state', payload));
    unawaited(
      PictureBookService.statePayload(articleId).then(
        (state) => _pushEvent('pictureBook.state', state),
      ),
    );
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

  Future<Map<String, dynamic>> _handleFollowRecordReplay(
    BridgeMessage message,
  ) async {
    final articleId = _requireActiveFollow();
    await ref
        .read(followReadProvider(articleId).notifier)
        .replayLastRecording();
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

  Future<Map<String, dynamic>> _handleFollowPause(
    BridgeMessage message,
  ) async {
    final articleId = _requireActiveFollow();
    final paused = await ref
        .read(followReadProvider(articleId).notifier)
        .pauseCurrentPlayback();
    return {'paused': paused};
  }

  Future<Map<String, dynamic>> _handleFollowResume(
    BridgeMessage message,
  ) async {
    final articleId = _requireActiveFollow();
    final resumed = await ref
        .read(followReadProvider(articleId).notifier)
        .resumeCurrentPlayback();
    return {'resumed': resumed};
  }

  Future<Map<String, dynamic>> _handleListeningOpen(
    BridgeMessage message,
  ) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    final followArticleId = _activeFollowArticleId;
    if (followArticleId != null && followArticleId != articleId) {
      TtsMemoryCacheService.releaseArticle(followArticleId);
    }
    _closeFollowSession();
    _closeChatSession();
    final listeningArticleId = _activeListeningArticleId;
    if (listeningArticleId != null && listeningArticleId != articleId) {
      TtsMemoryCacheService.releaseArticle(listeningArticleId);
    }
    await _stopListeningPlayback();
    await _stopSongPlayback();
    _activeListeningArticleId = articleId;

    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) {
      throw FormatException('文章不存在（id=$articleId）');
    }

    final article = await _articleWithPersistedSentences(rawArticle);
    final items = await _listeningItemsForArticle(article);

    if (article.id != null && items.isNotEmpty) {
      unawaited(_pushSongState(article.id!));
    }

    return {
      'article': _articleJson(article),
      'items': items,
    };
  }

  Future<Map<String, dynamic>> _handleListeningAudioStatus(
    BridgeMessage message,
  ) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    final status = await ListeningAudioMaterialService.status(articleId);
    return status.toJson();
  }

  Future<Map<String, dynamic>> _handleListeningAudioGenerate(
    BridgeMessage message,
  ) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    final overwrite = _payloadBool(
      message.payload,
      'overwrite',
      fallback: false,
    );
    _listeningTtsPathFutures.clear();
    await _stopListeningPlayback();
    await _stopSongPlayback();

    final result = await ListeningAudioMaterialService.generate(
      articleId: articleId,
      overwrite: overwrite,
      onProgress: (progress) {
        final loading = progress.completed < progress.total;
        unawaited(_pushEvent('listening.audioMaterial.progress', {
          'articleId': articleId,
          'status': loading
              ? 'loading'
              : progress.failed > 0
                  ? 'partial'
                  : 'complete',
          'completed': progress.completed,
          'total': progress.total,
          'failed': progress.failed,
          'overwrite': overwrite,
        }));
      },
    );
    unawaited(_pushEvent('listening.audioMaterial.progress', {
      ...result.toJson(),
      'completed': result.ready,
    }));
    return result.toJson();
  }

  Future<List<Map<String, dynamic>>> _listeningItemsForArticle(
    Article article,
  ) async {
    final translations = article.id == null
        ? const <int, String>{}
        : await DatabaseService.getArticleSentenceTranslationsForSentences(
            articleId: article.id!,
            sentences: article.sentences,
          );
    final items = <Map<String, dynamic>>[];
    for (var i = 0; i < article.sentences.length; i++) {
      final sentence = article.sentences[i].trim();
      final hidden = isHiddenListeningSentence(sentence);
      items.add({
        'index': i,
        'english': hidden ? '' : sentence,
        'chinese': hidden ? '' : (translations[i] ?? ''),
        'hidden': hidden,
      });
    }
    return items;
  }

  Future<Article> _songArticle(int articleId) async {
    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) {
      throw FormatException('文章不存在（id=$articleId）');
    }
    return _articleWithPersistedSentences(rawArticle);
  }

  Future<String> _articleSongContentHash(Article article) =>
      ApiCacheService.hashUtf8(
        _articleSongStoryText(article),
      );

  Future<String> _articleSongLyricsHash(Article article) =>
      ApiCacheService.hashUtf8(
        _articleSongLyrics(article),
      );

  String _articleSongStoryText(Article article) {
    final story = article.sentences
        .map((sentence) => sentence.trim())
        .where((sentence) => sentence.isNotEmpty)
        .join('\n')
        .trim();
    return story.isEmpty ? article.content.trim() : story;
  }

  String _articleSongLyrics(Article article) {
    final text = _articleSongStoryText(article);
    return text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  Future<ArticleSongState?> _activeSunoSongState(int articleId) async {
    if (_sunoEngine.state.articleId != articleId ||
        _sunoEngine.state.statusKey == 'idle') {
      return null;
    }
    final hasLocalAudio =
        (_sunoEngine.state.audioPath?.trim().isNotEmpty ?? false) ||
            _sunoEngine.state.versions.isNotEmpty;
    final canPlayDownloaded = hasLocalAudio &&
        (_sunoEngine.state.statusKey == 'complete' ||
            _sunoEngine.state.statusKey == 'manualAction');
    final status = _sunoEngine.state.errorMessage != null
        ? 'error'
        : canPlayDownloaded
            ? 'ready'
            : (_sunoEngine.state.statusKey == 'manualAction'
                ? 'empty'
                : 'generating');
    return ArticleSongState(
      articleId: articleId,
      status: status,
      stylePrompt: '',
      audioPath: (_sunoEngine.state.audioPath?.trim().isNotEmpty ?? false)
          ? _sunoEngine.state.audioPath
          : (_sunoEngine.state.versions.isNotEmpty
              ? _sunoEngine.state.versions.first.audioPath
              : null),
      errorMessage: _sunoEngine.state.errorMessage,
      source: 'suno',
      songUrl: SunoUtilities.canonicalSongUrl(_sunoEngine.state.songUrl) ??
          (_sunoEngine.state.versions.isNotEmpty
              ? SunoUtilities.canonicalSongUrl(
                  _sunoEngine.state.versions.first.songUrl)
              : null),
      metadataPath: _sunoEngine.state.metadataPath,
      manualActionMessage: _sunoEngine.state.manualActionMessage,
      automationStatus: _sunoEngine.state.statusKey,
      creditsRemaining: _sunoEngine.state.creditsRemaining,
      downloadComplete: _currentSunoDownloadsComplete(),
      detectedSongUrls:
          SunoUtilities.mergeSongUrls([_sunoEngine.state.detectedSongUrls]),
      versions: _songVersionsForPayload(
        articleId,
        _sunoEngine.state.versions,
        requireDefault: false,
      ),
    );
  }

  Future<List<SunoCachedSongGroup>> _cachedSunoSongGroups(
    Article article,
  ) async {
    final articleId = article.id;
    if (articleId == null) {
      return const [];
    }
    final entries = await ApiCacheService.getEntriesForArticlePurpose(
      articleId: articleId,
      purpose: _sunoSongPurpose,
      limit: 100,
    );
    if (entries.isEmpty) {
      return const [];
    }
    final builders = <String, SunoCachedSongGroupBuilder>{};
    for (final entry in entries) {
      if ((entry.jsonValue ?? '').trim().isEmpty) {
        continue;
      }
      final request = _decodeJsonObject(entry.requestJson);
      final requestLyricsHash = _nonEmptyString(request['lyricsHash']);
      final metadata = _decodeJsonObject(entry.jsonValue);
      final stylePrompt = (_nonEmptyString(metadata['stylePrompt']) ??
              _nonEmptyString(request['stylePrompt']) ??
              '')
          .trim();
      final groupLyricsHash = _nonEmptyString(metadata['lyricsHash']) ??
          requestLyricsHash ??
          entry.cacheKey;
      final builder = builders.putIfAbsent(
        groupLyricsHash,
        () => SunoCachedSongGroupBuilder(
          lyricsHash: groupLyricsHash,
          stylePrompt: stylePrompt,
        ),
      );
      if (builder.stylePrompt.trim().isEmpty && stylePrompt.isNotEmpty) {
        builder.stylePrompt = stylePrompt;
      }
      final metadataPath = (metadata['metadataPath'] ?? '').toString().trim();
      final hasMetadataFile =
          metadataPath.isNotEmpty && await File(metadataPath).exists();
      final audioPath = await _migrateSunoAssetPathIfNeeded(
        (metadata['audioPath'] ?? '').toString(),
      );
      final hasAudio = audioPath.isNotEmpty && await File(audioPath).exists();
      if (!hasAudio &&
          metadataPath.isNotEmpty &&
          !hasMetadataFile &&
          (metadata['versions'] is! List)) {
        continue;
      }
      final versions = await _sunoVersionsFromMetadata(
        metadata,
        fallbackStylePrompt: stylePrompt,
        fallbackLyricsHash: groupLyricsHash,
      );
      final resolvedMetadataPath = await _migrateSunoMetadataPathIfNeeded(
        metadataPath: metadataPath,
        metadata: metadata,
        versions: versions,
      );
      builder.addVersions(versions);
      if (versions.isEmpty && hasAudio) {
        builder.addVersions([
          ArticleSongVersion(
            id: 'suno_legacy_${articleId}_${audioPath.hashCode}',
            audioPath: audioPath,
            title: 'Suno 版本 1',
            songUrl: SunoUtilities.canonicalSongUrl(metadata['songUrl']),
            stylePrompt: stylePrompt.isEmpty ? null : stylePrompt,
            lyricsHash: groupLyricsHash,
          ),
        ]);
      }
      builder.detectedSongUrls.addAll(
        SunoUtilities.songUrlList(metadata['detectedSongUrls']),
      );
      final songUrl = SunoUtilities.canonicalSongUrl(metadata['songUrl']) ??
          _firstNonEmptyString(builder.detectedSongUrls) ??
          _firstNonEmptyString(
            builder.versions.map(
                (version) => SunoUtilities.canonicalSongUrl(version.songUrl)),
          );
      builder.songUrl ??= songUrl;
      builder.metadataPath ??= _nonEmptyString(resolvedMetadataPath);
      builder.manualActionMessage ??=
          _nonEmptyString(metadata['manualActionMessage']);
    }
    return builders.values
        .map((builder) => builder.build())
        .where((group) =>
            group.versions.isNotEmpty ||
            (group.songUrl ?? '').trim().isNotEmpty ||
            group.detectedSongUrls.isNotEmpty)
        .toList(growable: false);
  }

  Future<ArticleSongState?> _cachedSunoSongState(Article article) async {
    final articleId = article.id;
    if (articleId == null) {
      return null;
    }
    final groups = await _cachedSunoSongGroups(article);
    if (groups.isEmpty) {
      return null;
    }
    final currentLyricsHash = await _articleSongLyricsHash(article);
    SunoCachedSongGroup? currentHashGroup;
    for (final group in groups) {
      if (group.lyricsHash == currentLyricsHash) {
        currentHashGroup = group;
        break;
      }
    }
    final latestGroup = groups.first;
    final activeGroup = currentHashGroup ?? latestGroup;
    final rawVersions =
        groups.expand((group) => group.versions).toList(growable: false);
    final versions = _songVersionsForPayload(
      articleId,
      rawVersions,
      requireDefault: false,
    );
    final hasAudio = versions.isNotEmpty;
    final downloadComplete = activeGroup.hasKnownCompleteDownloads;
    return ArticleSongState(
      articleId: articleId,
      status: hasAudio ? 'ready' : 'empty',
      stylePrompt: '',
      audioPath: versions.isNotEmpty ? versions.first.audioPath : null,
      durationMs: versions.isNotEmpty ? versions.first.durationMs : null,
      source: 'suno',
      songUrl: activeGroup.songUrl ?? latestGroup.songUrl,
      metadataPath: activeGroup.metadataPath ?? latestGroup.metadataPath,
      versions: versions,
      detectedSongUrls: activeGroup.detectedSongUrls,
      downloadComplete: hasAudio ? downloadComplete : null,
      manualActionMessage: hasAudio
          ? null
          : (activeGroup.manualActionMessage ??
              latestGroup.manualActionMessage ??
              'Suno 歌曲已生成记录，但还没有本地音频文件。请在 Suno 页面手工下载后重试。'),
      automationStatus: hasAudio ? 'complete' : 'manualAction',
    );
  }

  Future<ArticleSongState?> _cachedBailianSongState(Article article) async {
    final articleId = article.id;
    if (articleId == null) {
      return null;
    }
    final entries = await ApiCacheService.getEntriesForArticlePurpose(
      articleId: articleId,
      purpose: _bailianSongPurpose,
      limit: 80,
    );
    if (entries.isEmpty) {
      return null;
    }
    final versions = <ArticleSongVersion>[];
    var lyricsCompressed = false;
    String? metadataPath;
    String? songUrl;
    for (final entry in entries) {
      if ((entry.jsonValue ?? '').trim().isEmpty) {
        continue;
      }
      final metadata = _decodeJsonObject(entry.jsonValue);
      final entryLyricsHash = _nonEmptyString(metadata['lyricsHash']) ??
          _nonEmptyString(
            _decodeJsonObject(entry.requestJson)['lyricsHash'],
          );
      lyricsCompressed =
          lyricsCompressed || metadata['lyricsCompressed'] == true;
      metadataPath ??= _nonEmptyString(metadata['metadataPath']);
      songUrl ??= _nonEmptyString(metadata['songUrl']);
      final rawVersions = metadata['versions'];
      if (rawVersions is List) {
        for (final rawVersion in rawVersions) {
          final version = ArticleSongVersion.fromJson(rawVersion);
          if (version == null) {
            continue;
          }
          final audioPath =
              await ApiCacheService.migrateLegacyCacheFileIfNeeded(
            version.audioPath,
          );
          if (!await File(audioPath).exists()) {
            continue;
          }
          final timelinePath = version.timelinePath == null
              ? null
              : await ApiCacheService.migrateLegacyCacheFileIfNeeded(
                  version.timelinePath!,
                );
          final timelineStatus = await _songTimelineStatusForPath(timelinePath);
          final hasTimeline = timelineStatus != 'missing';
          final timelineReady = timelineStatus == 'ready';
          versions.add(
            version.copyWith(
              audioPath: audioPath,
              lyricsHash: version.lyricsHash ?? entryLyricsHash,
              source: AppConfig.songProviderBailianFunMusic,
              timelinePath: hasTimeline ? timelinePath : null,
              timelineStatus: timelineStatus,
              timelineConfidence:
                  timelineReady ? version.timelineConfidence : null,
              timelineError: timelineReady
                  ? version.timelineError
                  : timelineStatus == 'stale'
                      ? SongSubtitleTimelineService.staleTimelineMessage
                      : null,
            ),
          );
        }
      }
      if (versions.isEmpty) {
        final legacyAudioPath =
            await ApiCacheService.migrateLegacyCacheFileIfNeeded(
          (metadata['audioPath'] ?? '').toString(),
        );
        if (legacyAudioPath.trim().isNotEmpty &&
            await File(legacyAudioPath).exists()) {
          versions.add(
            ArticleSongVersion(
              id: 'bailian_fun_music_${articleId}_${legacyAudioPath.hashCode}',
              audioPath: legacyAudioPath,
              title: '阿里云百聆版本 1',
              songUrl: _nonEmptyString(metadata['songUrl']),
              durationMs: (metadata['durationMs'] as num?)?.toInt(),
              createdAt: _nonEmptyString(metadata['createdAt']),
              stylePrompt: _nonEmptyString(metadata['model']),
              styleKey: _nonEmptyString(metadata['model']),
              lyricsHash: entryLyricsHash,
              source: AppConfig.songProviderBailianFunMusic,
              isDefault: true,
            ),
          );
        }
      }
    }
    if (versions.isEmpty) {
      return null;
    }
    final payloadVersions = _songVersionsForPayload(
      articleId,
      _dedupeSongVersions(versions),
      requireDefault: false,
    );
    final selected =
        _defaultSongVersion(payloadVersions) ?? payloadVersions.first;
    return ArticleSongState(
      articleId: articleId,
      status: 'ready',
      stylePrompt: '',
      audioPath: selected.audioPath,
      durationMs: selected.durationMs,
      source: AppConfig.songProviderBailianFunMusic,
      lyricsCompressed: lyricsCompressed,
      songUrl: selected.songUrl ?? songUrl,
      metadataPath: metadataPath,
      versions: payloadVersions,
      downloadComplete: true,
      automationStatus: 'complete',
    );
  }

  Future<ArticleSongState?> _cachedExternalSongState(Article article) {
    return ExternalSongImportService.loadState(
      article,
      requireDefault: false,
    );
  }

  Future<List<ArticleSongVersion>> _sunoVersionsFromMetadata(
    Map<String, dynamic> metadata, {
    required String fallbackStylePrompt,
    required String fallbackLyricsHash,
  }) async {
    final rawVersions = metadata['versions'];
    final versions = <ArticleSongVersion>[];
    if (rawVersions is List) {
      for (final rawVersion in rawVersions) {
        final version = ArticleSongVersion.fromJson(rawVersion);
        if (version == null) {
          continue;
        }
        final audioPath = await _migrateSunoAssetPathIfNeeded(
          version.audioPath,
        );
        if (await File(audioPath).exists()) {
          final timelinePath = version.timelinePath == null
              ? null
              : await ApiCacheService.migrateLegacyCacheFileIfNeeded(
                  version.timelinePath!,
                );
          final timelineStatus = await _songTimelineStatusForPath(timelinePath);
          final hasTimeline = timelineStatus != 'missing';
          final timelineReady = timelineStatus == 'ready';
          versions.add(
            ArticleSongVersion(
              id: version.id,
              audioPath: audioPath,
              title: version.title,
              songUrl: SunoUtilities.canonicalSongUrl(version.songUrl),
              durationMs: version.durationMs,
              createdAt: version.createdAt,
              stylePrompt: version.stylePrompt ?? fallbackStylePrompt,
              styleKey: version.styleKey,
              lyricsHash: version.lyricsHash ?? fallbackLyricsHash,
              source: version.source,
              timelinePath: hasTimeline ? timelinePath : null,
              timelineStatus: timelineStatus,
              timelineConfidence:
                  timelineReady ? version.timelineConfidence : null,
              timelineError: timelineReady
                  ? version.timelineError
                  : timelineStatus == 'stale'
                      ? SongSubtitleTimelineService.staleTimelineMessage
                      : null,
              isDefault: version.isDefault,
            ),
          );
        }
      }
    }
    return versions;
  }

  Future<Map<String, dynamic>> _songStatePayload(
    int articleId, {
    String? statusOverride,
    String? stylePromptOverride,
    String? errorMessageOverride,
    String? sourceOverride,
  }) async {
    final article = await _songArticle(articleId);
    final activeSuno = await _activeSunoSongState(articleId);
    final preferredSource = _normalizeSongSource(
      sourceOverride ?? await AppConfig.songGenerationProvider,
    );
    if (activeSuno != null &&
        _normalizeSongSource(sourceOverride ?? AppConfig.songProviderSuno) ==
            AppConfig.songProviderSuno) {
      final cachedBailian = await _cachedBailianSongState(article);
      final cachedExternal = await _cachedExternalSongState(article);
      final combinedVersions = <ArticleSongVersion>[
        ...activeSuno.versions,
        ...?cachedBailian?.versions,
        ...?cachedExternal?.versions,
      ];
      var state = activeSuno;
      if (combinedVersions.isNotEmpty) {
        final versions = _songVersionsForPayload(articleId, combinedVersions);
        final selected = _defaultSongVersion(versions) ?? versions.first;
        state = state.copyWith(
          audioPath: selected.audioPath,
          durationMs: selected.durationMs,
          songUrl: selected.songUrl ?? state.songUrl,
          versions: versions,
        );
      }
      if (statusOverride != null) {
        state = state.copyWith(status: statusOverride);
      }
      if (stylePromptOverride != null) {
        state = state.copyWith(stylePrompt: stylePromptOverride);
      }
      if (errorMessageOverride != null) {
        state = state.copyWith(errorMessage: errorMessageOverride);
      }
      return state.toJson();
    }
    final cachedSuno = await _cachedSunoSongState(article);
    final cachedBailian = await _cachedBailianSongState(article);
    final cachedExternal = await _cachedExternalSongState(article);
    final statesBySource = <String, ArticleSongState?>{
      AppConfig.songProviderSuno: cachedSuno,
      AppConfig.songProviderBailianFunMusic: cachedBailian,
      ExternalSongImportService.source: cachedExternal,
    };
    final orderedSources = <String>[
      preferredSource,
      AppConfig.songProviderSuno,
      AppConfig.songProviderBailianFunMusic,
      ExternalSongImportService.source,
    ].fold<List<String>>(<String>[], (sources, source) {
      if (!sources.contains(source)) {
        sources.add(source);
      }
      return sources;
    });
    final preferredState = statesBySource[preferredSource];
    final fallbackState = orderedSources
        .map((source) => statesBySource[source])
        .whereType<ArticleSongState>()
        .cast<ArticleSongState?>()
        .firstWhere((state) => state != null, orElse: () => null);
    final combinedVersions = <ArticleSongVersion>[
      for (final source in orderedSources) ...?statesBySource[source]?.versions,
    ];
    var state = preferredState ??
        fallbackState ??
        ArticleSongState(
          articleId: articleId,
          status: 'empty',
          stylePrompt: '',
          source: preferredSource,
        );
    if (combinedVersions.isNotEmpty) {
      final versions = _songVersionsForPayload(articleId, combinedVersions);
      final selected = _defaultSongVersion(versions) ?? versions.first;
      state = state.copyWith(
        status: 'ready',
        source: preferredSource,
        audioPath: selected.audioPath,
        durationMs: selected.durationMs,
        songUrl: selected.songUrl ?? state.songUrl,
        versions: versions,
      );
    } else if (state.source != preferredSource) {
      state = state.copyWith(source: preferredSource);
    }
    if (statusOverride != null) {
      state = state.copyWith(status: statusOverride);
    }
    if (stylePromptOverride != null) {
      state = state.copyWith(stylePrompt: stylePromptOverride);
    }
    if (errorMessageOverride != null) {
      state = state.copyWith(errorMessage: errorMessageOverride);
    }
    return state.toJson();
  }

  Future<void> _pushSongState(
    int articleId, {
    String? statusOverride,
    String? stylePromptOverride,
    String? errorMessageOverride,
    String? sourceOverride,
  }) async {
    try {
      final payload = await _songStatePayload(
        articleId,
        statusOverride: statusOverride,
        stylePromptOverride: stylePromptOverride,
        errorMessageOverride: errorMessageOverride,
        sourceOverride: sourceOverride,
      );
      await _pushEvent('listening.song.state', payload);
    } catch (error) {
      TomatoLogger.warn(
        category: 'listening',
        event: 'song_state.push_failed',
        articleId: articleId,
        error: error,
      );
    }
  }

  List<Map<String, dynamic>>? _payloadListeningItems(
    Map<String, dynamic> payload,
  ) {
    final rawItems = payload['items'];
    if (rawItems is! List) {
      return null;
    }
    final items = <Map<String, dynamic>>[];
    for (final raw in rawItems) {
      if (raw is! Map) {
        continue;
      }
      final english = (raw['english'] ?? '').toString().trim();
      if (english.isEmpty) {
        continue;
      }
      final rawIndex = raw['index'];
      final index = rawIndex is num ? rawIndex.toInt() : items.length;
      items.add({
        'index': index,
        'english': english,
        'chinese': (raw['chinese'] ?? '').toString().trim(),
      });
    }
    return items.isEmpty ? null : items;
  }

  List<Map<String, dynamic>> _listeningWindowItems(
    List<Map<String, dynamic>> items, {
    required int startIndex,
    int lookaheadCount = 2,
  }) {
    final cleanItems = items
        .where((item) => (item['english'] ?? '').toString().trim().isNotEmpty)
        .toList(growable: false);
    if (cleanItems.isEmpty) {
      return const <Map<String, dynamic>>[];
    }
    final exactPosition = cleanItems.indexWhere((item) {
      final sentenceIndex = (item['index'] as num?)?.toInt();
      return sentenceIndex == startIndex;
    });
    final startPosition = exactPosition >= 0
        ? exactPosition
        : startIndex.clamp(0, cleanItems.length - 1).toInt();
    return cleanItems
        .skip(startPosition)
        .take(lookaheadCount.clamp(1, cleanItems.length).toInt())
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> _handleListeningPlay(
    BridgeMessage message,
  ) async {
    final text = _payloadString(message.payload, 'text').trim();
    if (text.isEmpty) {
      throw const FormatException('朗读文本不能为空');
    }

    final part = _payloadString(message.payload, 'part').trim();
    if (part == 'chinese' || _containsChinese(text)) {
      return {
        'playbackState': 'skipped',
        'reason': 'chinese_tts_disabled',
      };
    }
    await _playListeningText(
      text: text,
    );
    return {'playbackState': 'success'};
  }

  Future<Map<String, dynamic>> _handleListeningPlaySequence(
    BridgeMessage message,
  ) async {
    final articleId = _activeListeningArticleId;
    if (articleId == null) {
      throw const FormatException('听力任务尚未打开');
    }
    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) {
      throw FormatException('文章不存在（id=$articleId）');
    }
    final article = await _articleWithPersistedSentences(rawArticle);
    final items = _payloadListeningItems(message.payload) ??
        await _listeningItemsForArticle(article);
    final startIndex = _payloadOptionalInt(message.payload, 'startIndex') ?? 0;
    final singleItem = _payloadBool(
      message.payload,
      'singleItem',
      fallback: false,
    );
    await _playListeningSequence(
      articleId: articleId,
      items: items,
      startIndex: startIndex,
      singleItem: singleItem,
    );
    return {'playbackState': 'success'};
  }

  Future<Map<String, dynamic>> _handleListeningFullscreenReady(
    BridgeMessage message,
  ) async {
    final articleId = _payloadOptionalInt(message.payload, 'articleId') ??
        _activeListeningArticleId;
    if (articleId == null) {
      return {
        'ready': false,
        'reasons': ['听力任务尚未打开'],
        'missingEnglish': <int>[],
        'missingChinese': <int>[],
        'failed': 0,
      };
    }

    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) {
      return {
        'ready': false,
        'reasons': ['文章不存在（id=$articleId）'],
        'missingEnglish': <int>[],
        'missingChinese': <int>[],
        'failed': 0,
      };
    }

    final article = await _articleWithPersistedSentences(rawArticle);
    final items = _payloadListeningItems(message.payload) ??
        await _listeningItemsForArticle(article);
    final startIndex = _payloadOptionalInt(message.payload, 'startIndex') ?? 0;
    final lookaheadCount =
        (_payloadOptionalInt(message.payload, 'lookaheadCount') ?? 2)
            .clamp(1, 4)
            .toInt();
    final readinessItems = _listeningWindowItems(
      items,
      startIndex: startIndex,
      lookaheadCount: lookaheadCount,
    );
    final missingEnglish = <int>[];
    final missingChinese = <int>[];
    var requiredEnglish = 0;
    const requiredChinese = 0;
    final audioHandlesByText =
        await ListeningAudioMaterialService.cachedFileHandlesByTextForArticle(
      articleId: articleId,
    );

    for (var position = 0; position < readinessItems.length; position += 1) {
      final item = readinessItems[position];
      final sentenceIndex = (item['index'] as num?)?.toInt() ?? position;
      final english = (item['english'] ?? '').toString().trim();
      if (english.isNotEmpty) {
        requiredEnglish += 1;
        final handle =
            ListeningAudioMaterialService.cachedFileHandleFromArticleMap(
          text: english,
          handlesByText: audioHandlesByText,
        );
        if (handle == null) {
          missingEnglish.add(sentenceIndex);
        }
      }
    }

    const chineseFailed = 0;
    final reasons = <String>[];
    if (missingEnglish.isNotEmpty) {
      reasons.add('当前和下一句英文音频未生成，请先在创作中心生成听力材料');
    }
    const failed = chineseFailed;
    if (failed > 0 &&
        (missingEnglish.isNotEmpty || missingChinese.isNotEmpty)) {
      reasons.add('有 $failed 项音频预热失败');
    }

    return {
      'ready': reasons.isEmpty,
      'reasons': reasons,
      'requiredEnglish': requiredEnglish,
      'readyEnglish': requiredEnglish - missingEnglish.length,
      'requiredChinese': requiredChinese,
      'readyChinese': requiredChinese - missingChinese.length,
      'missingEnglish': missingEnglish,
      'missingChinese': missingChinese,
      'failed': failed,
    };
  }

  Future<Map<String, dynamic>> _handleListeningRecordingReady(
    BridgeMessage message,
  ) async {
    final request = await _recordingRequestFromPayload(message.payload);
    final readiness = await RecordingExportService.readiness(request);
    return readiness.toJson();
  }

  Future<Map<String, dynamic>> _handleListeningRecordVideo(
    BridgeMessage message,
  ) async {
    if (_recordingCancelToken != null) {
      throw const FormatException('已有录制导出正在进行，请先取消或等待完成');
    }
    final request = await _recordingRequestFromPayload(message.payload);
    final token = RecordingCancelToken();
    _recordingCancelToken = token;
    try {
      final result = await RecordingExportService.exportVideo(
        request,
        cancelToken: token,
        onProgress: (progress) {
          unawaited(_pushEvent(
            'listening.recording.progress',
            progress.toJson(),
          ));
        },
      );
      await _pushEvent('listening.recording.completed', result.toJson());
      return result.toJson();
    } catch (error) {
      final payload = {
        'articleId': request.articleId,
        'message': error.toString(),
      };
      await _pushEvent('listening.recording.error', payload);
      rethrow;
    } finally {
      if (_recordingCancelToken == token) {
        _recordingCancelToken = null;
        _scheduleMainWebViewFrameRateLimit();
      }
    }
  }

  Future<Map<String, dynamic>> _handleListeningCancelRecording(
    BridgeMessage message,
  ) async {
    final token = _recordingCancelToken;
    if (token == null) {
      return {'cancelled': false};
    }
    token.cancel();
    return {'cancelled': true};
  }

  Future<Map<String, dynamic>> _handleRecordingVideoList(
    BridgeMessage message,
  ) async {
    final articleId = _payloadOptionalInt(message.payload, 'articleId') ??
        _activeListeningArticleId;
    if (articleId == null) {
      throw const FormatException('听力任务尚未打开');
    }
    final library = await RecordingExportService.videoLibrary(articleId);
    return library.toJson();
  }

  Future<Map<String, dynamic>> _handleRecordingVideoSetDefault(
    BridgeMessage message,
  ) async {
    final articleId = _payloadOptionalInt(message.payload, 'articleId') ??
        _activeListeningArticleId;
    if (articleId == null) {
      throw const FormatException('听力任务尚未打开');
    }
    final videoId = _payloadString(message.payload, 'videoId').trim();
    if (videoId.isEmpty) {
      throw const FormatException('请选择要设为默认播放的视频');
    }
    final library = await RecordingExportService.setDefaultVideo(
      articleId: articleId,
      videoId: videoId,
    );
    return library.toJson();
  }

  Future<Map<String, dynamic>> _handleRecordingVideoPlay(
    BridgeMessage message,
  ) async {
    final articleId = _payloadOptionalInt(message.payload, 'articleId') ??
        _activeListeningArticleId;
    if (articleId == null) {
      throw const FormatException('听力任务尚未打开');
    }
    final video = await RecordingExportService.resolveVideo(
      articleId: articleId,
      videoId: _payloadString(message.payload, 'videoId').trim(),
    );
    await _openWithSystemPlayer(video.videoPath);
    return {
      'played': true,
      'articleId': articleId,
      'videoId': video.id,
      'videoPath': video.videoPath,
    };
  }

  Future<Map<String, dynamic>> _handleRecordingVideoDelete(
    BridgeMessage message,
  ) async {
    final articleId = _payloadOptionalInt(message.payload, 'articleId') ??
        _activeListeningArticleId;
    if (articleId == null) {
      throw const FormatException('听力任务尚未打开');
    }
    final videoId = _payloadString(message.payload, 'videoId').trim();
    if (videoId.isEmpty) {
      throw const FormatException('请选择要删除的视频');
    }
    final library = await RecordingExportService.deleteVideo(
      articleId: articleId,
      videoId: videoId,
    );
    return library.toJson();
  }

  Future<Map<String, dynamic>> _handleRecordingVideoOpenDirectory(
    BridgeMessage message,
  ) async {
    final articleId = _payloadOptionalInt(message.payload, 'articleId') ??
        _activeListeningArticleId;
    if (articleId == null) {
      throw const FormatException('听力任务尚未打开');
    }
    final library = await RecordingExportService.videoLibrary(articleId);
    final directory = Directory(library.outputDirectory);
    await directory.create(recursive: true);
    await _openWithSystemFileManager(directory.path);
    return {
      'opened': true,
      'articleId': articleId,
      'outputDirectory': directory.path,
    };
  }

  Future<Map<String, dynamic>> _handleListeningSongState(
    BridgeMessage message,
  ) async {
    final articleId = _payloadOptionalInt(message.payload, 'articleId') ??
        _activeListeningArticleId;
    if (articleId == null) {
      throw const FormatException('听力任务尚未打开');
    }
    return _songStatePayload(articleId);
  }

  Future<Map<String, dynamic>> _handleListeningSongGenerate(
    BridgeMessage message,
  ) async {
    final articleId = _payloadOptionalInt(message.payload, 'articleId') ??
        _activeListeningArticleId;
    if (articleId == null) {
      throw const FormatException('听力任务尚未打开');
    }
    final article = await _songArticle(articleId);
    final lyrics = _payloadString(message.payload, 'lyrics').trim();
    final requestedSource = _payloadString(message.payload, 'source').trim();
    final source = requestedSource.isEmpty
        ? await AppConfig.songGenerationProvider
        : _normalizeSongProvider(requestedSource);
    if (source == AppConfig.songProviderBailianFunMusic) {
      return _generateBailianFunMusic(
        article: article,
        lyrics: lyrics.isEmpty ? _articleSongLyrics(article) : lyrics,
      );
    }
    return _startSunoAutomation(
      article: article,
      stylePrompt: '',
      lyrics: lyrics.isEmpty ? _articleSongLyrics(article) : lyrics,
    );
  }

  Future<Map<String, dynamic>> _handleListeningSongImportExternal(
    BridgeMessage message,
  ) async {
    final articleId = _payloadOptionalInt(message.payload, 'articleId') ??
        _activeListeningArticleId;
    if (articleId == null) {
      throw const FormatException('听力任务尚未打开');
    }
    final returnSource = _normalizeSongProvider(
      _payloadString(message.payload, 'source', fallback: ''),
    );
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ExternalSongImportService.allowedExtensions,
      allowMultiple: false,
      withData: false,
    );
    if (result == null || result.files.isEmpty) {
      final payload = await _songStatePayload(
        articleId,
        sourceOverride: returnSource,
      );
      payload['importCancelled'] = true;
      payload['manualActionMessage'] = '已取消导入本地音乐';
      return payload;
    }
    final selectedPath = (result.files.single.path ?? '').trim();
    if (selectedPath.isEmpty) {
      throw const FormatException('无法读取选择的音乐文件路径');
    }
    await _stopSongPlayback();
    final article = await _songArticle(articleId);
    final imported = await ExternalSongImportService.importFile(
      article: article,
      sourcePath: selectedPath,
      lyrics: _articleSongLyrics(article),
    );
    final currentPayload = await _songStatePayload(
      articleId,
      sourceOverride: returnSource,
    );
    final currentVersions = ((currentPayload['versions'] as List?) ?? const [])
        .map(ArticleSongVersion.fromJson)
        .whereType<ArticleSongVersion>()
        .toList(growable: false);
    final updatedVersions = currentVersions
        .map(
            (version) => version.copyWith(isDefault: version.id == imported.id))
        .toList(growable: false);
    await ExternalSongImportService.saveVersions(
      article: article,
      versions: updatedVersions
          .where(
            (version) =>
                _normalizeSongSource(version.source) ==
                ExternalSongImportService.source,
          )
          .toList(growable: false),
    );
    _syncActiveSunoVersions(articleId, updatedVersions);
    await _pushSongState(
      articleId,
      sourceOverride: returnSource,
    );
    return _songStatePayload(
      articleId,
      statusOverride: 'ready',
      sourceOverride: returnSource,
    );
  }

  Future<Map<String, dynamic>> _handleListeningSongConfirmSunoCreate(
    BridgeMessage message,
  ) async {
    final articleId = _payloadOptionalInt(message.payload, 'articleId') ??
        _activeListeningArticleId;
    if (articleId == null) {
      throw const FormatException('听力任务尚未打开');
    }
    if (_sunoEngine.state.articleId != articleId) {
      throw const FormatException('当前没有等待确认的 Suno 歌曲任务');
    }
    if (_sunoEngine.state.statusKey != 'waitingConfirm') {
      throw FormatException('Suno 当前还不能确认创建：${_sunoOverlayStatusText()}');
    }
    await _confirmSunoCreate();
    return _songStatePayload(articleId);
  }

  Future<Map<String, dynamic>> _handleListeningSongDownloadSunoExisting(
    BridgeMessage message,
  ) async {
    final articleId = _payloadOptionalInt(message.payload, 'articleId') ??
        _activeListeningArticleId;
    if (articleId == null) {
      throw const FormatException('听力任务尚未打开');
    }
    final article = await _songArticle(articleId);
    // 检测下载：每次用户点击都必须进入 Suno 页面重新扫描，见
    // docs/suno_song_download_rules.md「检测下载」；不得因本地已完整而跳过。
    return _startExistingSunoDownload(article);
  }

  Future<Map<String, dynamic>> _handleListeningSongTimelineGenerate(
    BridgeMessage message,
  ) async {
    final articleId = _payloadOptionalInt(message.payload, 'articleId') ??
        _activeListeningArticleId;
    if (articleId == null) {
      throw const FormatException('听力任务尚未打开');
    }
    final article = await _songArticle(articleId);
    final version = await _selectedSongVersion(
      articleId: articleId,
      versionId: _payloadString(message.payload, 'versionId').trim(),
    );
    final key = _songTimelineKey(articleId, version.id);
    final existing = _songTimelineTasks[key];
    if (existing != null) {
      await existing;
      return _songStatePayload(articleId);
    }
    _songTimelineErrors.remove(key);
    final task = _generateTimelineForVersion(article, version);
    _songTimelineTasks[key] = task;
    unawaited(_pushSongState(articleId));
    Object? failure;
    StackTrace? failureStack;
    try {
      await task;
    } catch (error, stackTrace) {
      _songTimelineErrors[key] = _displayError(error);
      failure = error;
      failureStack = stackTrace;
    } finally {
      _songTimelineTasks.remove(key);
    }
    await _pushSongState(articleId);
    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStack ?? StackTrace.current);
    }
    return _songStatePayload(articleId);
  }

  Future<Map<String, dynamic>> _handleListeningSongRecordVideo(
    BridgeMessage message,
  ) async {
    if (_recordingCancelToken != null) {
      throw const FormatException('已有录制导出正在进行，请先取消或等待完成');
    }
    final request = await _songRecordingRequestFromPayload(message.payload);
    final token = RecordingCancelToken();
    _recordingCancelToken = token;
    try {
      final result = await RecordingExportService.exportSongVideo(
        request,
        cancelToken: token,
        onProgress: (progress) {
          unawaited(_pushEvent(
            'listening.recording.progress',
            progress.toJson(),
          ));
        },
      );
      await _pushEvent('listening.recording.completed', result.toJson());
      return result.toJson();
    } catch (error) {
      final payload = {
        'articleId': request.articleId,
        'message': error.toString(),
      };
      await _pushEvent('listening.recording.error', payload);
      rethrow;
    } finally {
      _recordingCancelToken = null;
      _scheduleMainWebViewFrameRateLimit();
    }
  }

  Future<Map<String, dynamic>> _handleListeningSongExportAudio(
    BridgeMessage message,
  ) async {
    final articleId = _payloadOptionalInt(message.payload, 'articleId') ??
        _activeListeningArticleId;
    if (articleId == null) {
      throw const FormatException('听力任务尚未打开');
    }
    final version = await _selectedSongVersion(
      articleId: articleId,
      versionId: _payloadString(message.payload, 'versionId').trim(),
    );
    final result = await RecordingExportService.exportSongAudio(
      articleId: articleId,
      version: version,
    );
    return result.toJson();
  }

  Future<Map<String, dynamic>> _handleDiagnosticsSongAsrSnapshot(
    BridgeMessage message,
  ) async {
    final articleId = _payloadOptionalInt(message.payload, 'articleId') ??
        _activeListeningArticleId;
    if (articleId == null) {
      throw const FormatException('听力任务尚未打开');
    }
    final version = await _selectedSongVersion(
      articleId: articleId,
      versionId: _payloadString(message.payload, 'versionId').trim(),
    );
    final result = await SongSubtitleTimelineService.submitAsrDiagnostics(
      articleId: articleId,
      versionId: version.id,
      audioPath: version.audioPath,
      source: version.source,
    );
    return result.toJson();
  }

  Future<Map<String, dynamic>> _handleDiagnosticsSongTimelineFromAsrSnapshot(
    BridgeMessage message,
  ) async {
    final articleId = _payloadOptionalInt(message.payload, 'articleId') ??
        _activeListeningArticleId;
    if (articleId == null) {
      throw const FormatException('听力任务尚未打开');
    }
    final snapshotPath =
        _payloadString(message.payload, 'asrSnapshotPath').trim();
    if (snapshotPath.isEmpty) {
      throw const FormatException('请提供 ASR 诊断结果文件路径');
    }
    final article = await _songArticle(articleId);
    final version = await _selectedSongVersion(
      articleId: articleId,
      versionId: _payloadString(message.payload, 'versionId').trim(),
    );
    final updated = await _generateTimelineForVersionFromAsrSnapshot(
      article: article,
      version: version,
      asrSnapshotPath: snapshotPath,
    );
    await _pushSongState(articleId);
    return {
      'articleId': articleId,
      'versionId': updated.id,
      'timelinePath': updated.timelinePath,
      'timelineStatus': updated.timelineStatus,
      'timelineConfidence': updated.timelineConfidence,
      'state': await _songStatePayload(articleId),
    };
  }

  Future<Map<String, dynamic>> _handleListeningSongPlay(
    BridgeMessage message,
  ) async {
    final articleId = _payloadOptionalInt(message.payload, 'articleId') ??
        _activeListeningArticleId;
    if (articleId == null) {
      throw const FormatException('听力任务尚未打开');
    }
    final payload = await _songStatePayload(articleId);
    final requestedVersionId =
        _payloadString(message.payload, 'versionId').trim();
    final startLineIndex =
        _payloadOptionalInt(message.payload, 'startLineIndex');
    final versions = ((payload['versions'] as List?) ?? const [])
        .map(ArticleSongVersion.fromJson)
        .whereType<ArticleSongVersion>()
        .toList();
    ArticleSongVersion? selectedVersion;
    if (requestedVersionId.isEmpty) {
      selectedVersion = _defaultSongVersion(versions);
    } else {
      for (final version in versions) {
        if (version.id == requestedVersionId) {
          selectedVersion = version;
          break;
        }
      }
    }
    final path = (selectedVersion?.audioPath ?? payload['audioPath'] ?? '')
        .toString()
        .trim();
    if (payload['status'] != 'ready' || path.isEmpty) {
      throw const FormatException('歌曲还没有生成，请先生成歌曲');
    }
    final state = ArticleSongState(
      articleId: articleId,
      status: 'ready',
      stylePrompt: selectedVersion?.stylePrompt ??
          (payload['stylePrompt'] ?? '').toString(),
      audioPath: path,
      errorMessage: payload['errorMessage']?.toString(),
      durationMs: selectedVersion?.durationMs ??
          (payload['durationMs'] as num?)?.toInt(),
      source: (payload['source'] ?? '').toString(),
      songUrl: selectedVersion?.songUrl ?? payload['songUrl']?.toString(),
      metadataPath: payload['metadataPath']?.toString(),
      manualActionMessage: payload['manualActionMessage']?.toString(),
      automationStatus: payload['automationStatus']?.toString(),
      creditsRemaining: (payload['creditsRemaining'] as num?)?.toInt(),
      downloadComplete: payload['downloadComplete'] is bool
          ? payload['downloadComplete'] as bool
          : null,
      detectedSongUrls: ((payload['detectedSongUrls'] as List?) ?? const [])
          .map((value) => value.toString())
          .where((value) => value.trim().isNotEmpty)
          .toList(growable: false),
      versions: versions,
    );
    await _playSongFile(
      articleId: articleId,
      path: path,
      state: state,
      versionId: selectedVersion?.id,
      timelinePath: selectedVersion?.timelinePath,
      startLineIndex: startLineIndex,
    );
    return {'playbackState': 'playing'};
  }

  Future<Map<String, dynamic>> _handleListeningSongSetDefault(
    BridgeMessage message,
  ) async {
    final articleId = _payloadOptionalInt(message.payload, 'articleId') ??
        _activeListeningArticleId;
    if (articleId == null) {
      throw const FormatException('听力任务尚未打开');
    }
    final versionId = _payloadString(message.payload, 'versionId').trim();
    if (versionId.isEmpty) {
      throw const FormatException('请选择要设为默认播放的歌曲');
    }
    final currentPayload = await _songStatePayload(articleId);
    final currentVersions = ((currentPayload['versions'] as List?) ?? const [])
        .map(ArticleSongVersion.fromJson)
        .whereType<ArticleSongVersion>()
        .toList();
    if (currentVersions.isEmpty) {
      throw const FormatException('还没有可用的本地歌曲版本');
    }
    var found = false;
    for (final version in currentVersions) {
      if (version.id == versionId) {
        found = true;
        break;
      }
    }
    if (!found) {
      throw FormatException('没有找到歌曲版本：$versionId');
    }
    final selectedVersion =
        currentVersions.firstWhere((version) => version.id == versionId);
    final updatedVersions = currentVersions.map((version) {
      return version.copyWith(isDefault: version.id == versionId);
    }).toList(growable: false);
    _syncActiveSunoVersions(articleId, updatedVersions);
    await _applyDefaultSongVersionInCaches(
      articleId: articleId,
      versionId: versionId,
      source: _normalizeSongSource(selectedVersion.source),
    );
    return _songStatePayload(articleId);
  }

  Future<void> _applyDefaultSongVersionInCaches({
    required int articleId,
    required String versionId,
    required String source,
  }) async {
    switch (source) {
      case AppConfig.songProviderSuno:
        await ArticleSongCacheService.setDefaultVersionInArticleCaches(
          articleId: articleId,
          versionId: versionId,
          purpose: _sunoSongPurpose,
          kind: 'suno_music',
        );
      case AppConfig.songProviderBailianFunMusic:
        await ArticleSongCacheService.setDefaultVersionInArticleCaches(
          articleId: articleId,
          versionId: versionId,
          purpose: _bailianSongPurpose,
          kind: 'bailian_fun_music',
        );
      case ExternalSongImportService.source:
        final article = await _songArticle(articleId);
        final payload = await _songStatePayload(articleId);
        final versions = ((payload['versions'] as List?) ?? const [])
            .map(ArticleSongVersion.fromJson)
            .whereType<ArticleSongVersion>()
            .where(
              (version) =>
                  _normalizeSongSource(version.source) ==
                  ExternalSongImportService.source,
            )
            .map(
              (version) => version.copyWith(isDefault: version.id == versionId),
            )
            .toList(growable: false);
        await ExternalSongImportService.saveVersions(
          article: article,
          versions: versions,
        );
      default:
        break;
    }
  }

  Future<Map<String, dynamic>> _handleListeningSongDeleteVersion(
    BridgeMessage message,
  ) async {
    final articleId = _payloadOptionalInt(message.payload, 'articleId') ??
        _activeListeningArticleId;
    if (articleId == null) {
      throw const FormatException('听力任务尚未打开');
    }
    final versionId = _payloadString(message.payload, 'versionId').trim();
    if (versionId.isEmpty) {
      throw const FormatException('请选择要删除的歌曲');
    }
    final article = await _songArticle(articleId);
    final currentPayload = await _songStatePayload(articleId);
    final currentVersions = ((currentPayload['versions'] as List?) ?? const [])
        .map(ArticleSongVersion.fromJson)
        .whereType<ArticleSongVersion>()
        .toList();
    ArticleSongVersion? target;
    final remainingVersions = <ArticleSongVersion>[];
    for (final version in currentVersions) {
      if (version.id == versionId) {
        target = version;
      } else {
        remainingVersions.add(version);
      }
    }
    if (target == null) {
      throw FormatException('没有找到歌曲版本：$versionId');
    }
    final timelineKey = _songTimelineKey(articleId, versionId);
    if (_songTimelineTasks.containsKey(timelineKey)) {
      throw const FormatException('歌曲字幕正在生成，请等待完成后再删除');
    }
    await _stopSongPlayback();
    final deletedSource = _normalizeSongSource(target.source);
    if (deletedSource == ExternalSongImportService.source) {
      await ExternalSongImportService.deleteVersionAssets(target);
    } else {
      await _deleteFileIfExists(target.audioPath);
      final timelinePath = (target.timelinePath ?? '').trim();
      if (timelinePath.isNotEmpty) {
        await _deleteFileIfExists(timelinePath);
      }
    }
    if (remainingVersions.isNotEmpty &&
        !remainingVersions.any((version) => version.isDefault)) {
      remainingVersions[0] = remainingVersions[0].copyWith(isDefault: true);
    }
    if (deletedSource == ExternalSongImportService.source) {
      await ExternalSongImportService.saveVersions(
        article: article,
        versions: remainingVersions
            .where(
              (version) =>
                  _normalizeSongSource(version.source) ==
                  ExternalSongImportService.source,
            )
            .toList(growable: false),
      );
    } else if (deletedSource == AppConfig.songProviderSuno) {
      await ArticleSongCacheService.removeVersionFromArticleCache(
        articleId: articleId,
        versionId: versionId,
        purpose: _sunoSongPurpose,
        kind: 'suno_music',
      );
    } else if (deletedSource == AppConfig.songProviderBailianFunMusic) {
      await ArticleSongCacheService.removeVersionFromArticleCache(
        articleId: articleId,
        versionId: versionId,
        purpose: _bailianSongPurpose,
        kind: 'bailian_fun_music',
      );
    }
    final deletedSongUrl = deletedSource == AppConfig.songProviderSuno
        ? SunoUtilities.canonicalSongUrl(target.songUrl)
        : null;
    _syncActiveSunoVersions(articleId, remainingVersions);
    if (_sunoEngine.state.articleId == articleId) {
      if (deletedSongUrl != null) {
        _sunoEngine.state.downloadedSongUrls.remove(deletedSongUrl);
        _sunoEngine.state.trustedSongUrls.remove(deletedSongUrl);
      }
    }
    _songTimelineErrors.remove(timelineKey);
    await _pushSongState(articleId);
    return _songStatePayload(articleId);
  }

  Future<Map<String, dynamic>> _handleListeningSongStop(
    BridgeMessage message,
  ) async {
    await _stopSongPlayback();
    return {'stopped': true};
  }

  Future<Map<String, dynamic>> _handleListeningSongPause(
    BridgeMessage message,
  ) async {
    final player = _songPlayer;
    if (player == null) {
      return {'paused': false};
    }
    try {
      await player.pause().timeout(const Duration(seconds: 2));
      return {'paused': true};
    } catch (error) {
      TomatoLogger.warn(
        category: 'listening',
        event: 'song.play.pause_failed',
        articleId: _activeListeningArticleId,
        error: error,
      );
      return {'paused': false};
    }
  }

  Future<Map<String, dynamic>> _handleListeningSongResume(
    BridgeMessage message,
  ) async {
    final player = _songPlayer;
    if (player == null) {
      return {'resumed': false};
    }
    try {
      unawaited(player.play().catchError((Object error) {
        TomatoLogger.warn(
          category: 'listening',
          event: 'song.play.resume_failed',
          articleId: _activeListeningArticleId,
          error: error,
        );
      }));
      return {'resumed': true};
    } catch (error) {
      TomatoLogger.warn(
        category: 'listening',
        event: 'song.play.resume_failed',
        articleId: _activeListeningArticleId,
        error: error,
      );
      return {'resumed': false};
    }
  }

  Future<ArticleSongVersion> _selectedSongVersion({
    required int articleId,
    required String versionId,
  }) async {
    final payload = await _songStatePayload(articleId);
    final versions = ((payload['versions'] as List?) ?? const [])
        .map(ArticleSongVersion.fromJson)
        .whereType<ArticleSongVersion>()
        .toList(growable: false);
    if (versions.isEmpty) {
      throw const FormatException('还没有可用的本地歌曲版本');
    }
    if (versionId.isEmpty) {
      return _defaultSongVersion(versions) ?? versions.first;
    }
    for (final version in versions) {
      if (version.id == versionId) {
        return version;
      }
    }
    throw FormatException('没有找到歌曲版本：$versionId');
  }

  Future<ArticleSongVersion> _generateTimelineForVersion(
    Article article,
    ArticleSongVersion version,
  ) async {
    final articleId = article.id;
    if (articleId == null) {
      throw const FormatException('文章尚未保存，不能生成歌曲字幕');
    }
    final articleLyrics = _articleSongLyrics(article);
    final submittedLyrics = (version.submittedLyrics ?? '').trim();
    final timelineLyrics =
        submittedLyrics.isNotEmpty ? submittedLyrics : articleLyrics;
    final usesArticleLyrics = submittedLyrics.isEmpty ||
        submittedLyrics.replaceAll('\r\n', '\n').trim() ==
            articleLyrics.replaceAll('\r\n', '\n').trim();
    final lyricLines = timelineLyrics
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    final translations = <int, String>{};
    if (usesArticleLyrics) {
      for (var i = 0; i < lyricLines.length; i += 1) {
        final translation = await DatabaseService.getArticleSentenceTranslation(
          articleId,
          i,
          lyricLines[i],
        );
        if (translation != null && translation.trim().isNotEmpty) {
          translations[i] = translation.trim();
        }
      }
    }
    final result = await SongSubtitleTimelineService.generate(
      articleId: articleId,
      audioPath: version.audioPath,
      versionId: version.id,
      lyricLines: lyricLines,
      translations: translations,
      source: version.source,
    );
    final updated = ArticleSongVersion(
      id: version.id,
      audioPath: version.audioPath,
      title: version.title,
      songUrl: version.songUrl,
      durationMs: version.durationMs ?? result.timeline.durationMs,
      createdAt: version.createdAt,
      stylePrompt: version.stylePrompt,
      styleKey: version.styleKey,
      lyricsHash: result.lyricsHash,
      submittedLyrics: timelineLyrics,
      source: version.source,
      timelinePath: result.timelinePath,
      timelineStatus: 'ready',
      timelineConfidence: result.timeline.confidence,
      timelineError: null,
      isDefault: version.isDefault,
    );
    await _persistUpdatedSongVersion(article, updated);
    return updated;
  }

  Future<ArticleSongVersion> _generateTimelineForVersionFromAsrSnapshot({
    required Article article,
    required ArticleSongVersion version,
    required String asrSnapshotPath,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      throw const FormatException('文章尚未保存，不能生成歌曲字幕');
    }
    final articleLyrics = _articleSongLyrics(article);
    final submittedLyrics = (version.submittedLyrics ?? '').trim();
    final timelineLyrics =
        submittedLyrics.isNotEmpty ? submittedLyrics : articleLyrics;
    final usesArticleLyrics = submittedLyrics.isEmpty ||
        submittedLyrics.replaceAll('\r\n', '\n').trim() ==
            articleLyrics.replaceAll('\r\n', '\n').trim();
    final lyricLines = timelineLyrics
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    final translations = <int, String>{};
    if (usesArticleLyrics) {
      for (var i = 0; i < lyricLines.length; i += 1) {
        final translation = await DatabaseService.getArticleSentenceTranslation(
          articleId,
          i,
          lyricLines[i],
        );
        if (translation != null && translation.trim().isNotEmpty) {
          translations[i] = translation.trim();
        }
      }
    }
    final result = await SongSubtitleTimelineService.generateFromAsrSnapshot(
      articleId: articleId,
      audioPath: version.audioPath,
      lyricLines: lyricLines,
      translations: translations,
      asrSnapshotPath: asrSnapshotPath,
      source: version.source,
    );
    final updated = ArticleSongVersion(
      id: version.id,
      audioPath: version.audioPath,
      title: version.title,
      songUrl: version.songUrl,
      durationMs: version.durationMs ?? result.timeline.durationMs,
      createdAt: version.createdAt,
      stylePrompt: version.stylePrompt,
      styleKey: version.styleKey,
      lyricsHash: result.lyricsHash,
      submittedLyrics: timelineLyrics,
      source: version.source,
      timelinePath: result.timelinePath,
      timelineStatus: 'ready',
      timelineConfidence: result.timeline.confidence,
      timelineError: null,
      isDefault: version.isDefault,
    );
    await _persistUpdatedSongVersion(article, updated);
    return updated;
  }

  Future<void> _persistUpdatedSongVersion(
    Article article,
    ArticleSongVersion updated,
  ) async {
    final articleId = article.id;
    if (articleId == null) {
      return;
    }
    final currentPayload = await _songStatePayload(articleId);
    final currentVersions = ((currentPayload['versions'] as List?) ?? const [])
        .map(ArticleSongVersion.fromJson)
        .whereType<ArticleSongVersion>()
        .toList();
    var replaced = false;
    for (var i = 0; i < currentVersions.length; i += 1) {
      if (currentVersions[i].id == updated.id) {
        currentVersions[i] = updated;
        replaced = true;
      }
    }
    if (!replaced) {
      currentVersions.add(updated);
    }
    _syncActiveSunoVersions(articleId, currentVersions);
    final normalizedSource = _normalizeSongSource(updated.source);
    if (normalizedSource == ExternalSongImportService.source) {
      await ExternalSongImportService.saveVersions(
        article: article,
        versions: currentVersions
            .where(
              (version) =>
                  _normalizeSongSource(version.source) ==
                  ExternalSongImportService.source,
            )
            .toList(growable: false),
      );
    } else if (normalizedSource == AppConfig.songProviderSuno) {
      await ArticleSongCacheService.updateVersionInArticleCache(
        articleId: articleId,
        updated: updated.copyWith(source: AppConfig.songProviderSuno),
        purpose: _sunoSongPurpose,
        kind: 'suno_music',
      );
    } else if (normalizedSource == AppConfig.songProviderBailianFunMusic) {
      await ArticleSongCacheService.updateVersionInArticleCache(
        articleId: articleId,
        updated:
            updated.copyWith(source: AppConfig.songProviderBailianFunMusic),
        purpose: _bailianSongPurpose,
        kind: 'bailian_fun_music',
      );
    }
  }

  void _syncActiveSunoVersions(
    int articleId,
    Iterable<ArticleSongVersion> versions,
  ) {
    if (_sunoEngine.state.articleId != articleId) {
      return;
    }
    _sunoEngine.state.versions
      ..clear()
      ..addAll(
        versions.where(
          (version) =>
              _normalizeSongSource(version.source) ==
              AppConfig.songProviderSuno,
        ),
      );
  }

  Future<void> _saveSunoMetadataForVersions({
    required Article article,
    required List<ArticleSongVersion> versions,
    String? manualActionMessage,
    bool? downloadCompleteOverride,
    String? stylePromptOverride,
    List<String>? detectedSongUrlsOverride,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      return;
    }
    final incomingVersions = versions
        .map((version) => version.copyWith(
              source: AppConfig.songProviderSuno,
              songUrl: SunoUtilities.canonicalSongUrl(version.songUrl),
            ))
        .toList(growable: false);
    if (incomingVersions.isEmpty) {
      return;
    }
    final lyricsHash = await _articleSongLyricsHash(article);
    final existingEntry = await ArticleSongCacheService.findEntryForLyricsHash(
      articleId: articleId,
      purpose: _sunoSongPurpose,
      lyricsHash: lyricsHash,
    );
    final directory = Directory(await _resolvedSunoOutputDirectorySetting());
    await directory.create(recursive: true);
    Map<String, dynamic> request;
    Map<String, dynamic>? existingMetadata;
    String metadataPath;
    List<ArticleSongVersion> mergedVersions;
    if (existingEntry != null) {
      existingMetadata = ArticleSongCacheService.decodeJsonObject(
        existingEntry.jsonValue,
      );
      request = ArticleSongCacheService.decodeRequest(existingEntry);
      metadataPath = (existingMetadata['metadataPath'] ?? '').toString().trim();
      if (metadataPath.isEmpty) {
        metadataPath = path_lib.join(
          directory.path,
          'article_${articleId}_suno_${DateTime.now().millisecondsSinceEpoch}.json',
        );
      }
      mergedVersions = _dedupeSongVersions([
        ...ArticleSongCacheService.versionsFromMetadata(existingMetadata),
        ...incomingVersions,
      ]);
    } else {
      request = {
        'version': 1,
        'provider': 'suno',
        'articleId': articleId,
        'articleTitle': article.title,
        'contentHash': await _articleSongContentHash(article),
        'lyricsHash': lyricsHash,
      };
      metadataPath = path_lib.join(
        directory.path,
        'article_${articleId}_suno_${DateTime.now().millisecondsSinceEpoch}.json',
      );
      mergedVersions = _dedupeSongVersions(incomingVersions);
    }
    final detectedSongUrlSet = SunoUtilities.mergeSongUrls([
      if (detectedSongUrlsOverride != null) detectedSongUrlsOverride,
      mergedVersions.map((version) => version.songUrl),
      if (_sunoEngine.state.articleId == articleId)
        _sunoEngine.state.detectedSongUrls,
      if (existingMetadata != null)
        SunoUtilities.songUrlList(existingMetadata['detectedSongUrls']),
    ]).toSet();
    final detectedSongUrls = detectedSongUrlSet.toList(growable: false);
    final downloadedSongUrls = mergedVersions
        .map(SunoUtilities.canonicalSongUrl)
        .whereType<String>()
        .where((value) =>
            value.isNotEmpty && !SunoUtilities.isSyntheticSongKey(value))
        .toSet();
    final selected = _defaultSongVersion(mergedVersions) ??
        (mergedVersions.isNotEmpty ? mergedVersions.first : null);
    final stylePrompt = stylePromptOverride ??
        _firstNonEmptyString(
          mergedVersions.map((version) => version.stylePrompt),
        ) ??
        _nonEmptyString(existingMetadata?['stylePrompt']) ??
        '';
    final downloadComplete = downloadCompleteOverride ??
        (detectedSongUrls.isNotEmpty &&
            detectedSongUrls.every(downloadedSongUrls.contains));
    final metadata = {
      'provider': 'suno',
      'articleId': articleId,
      'articleTitle': article.title,
      'lyricsHash': lyricsHash,
      if (stylePrompt.isNotEmpty) 'stylePrompt': stylePrompt,
      'songUrl': _firstNonEmptyString([
        SunoUtilities.canonicalSongUrl(_sunoEngine.state.articleId == articleId
            ? _sunoEngine.state.songUrl
            : null),
        ...mergedVersions
            .map((version) => SunoUtilities.canonicalSongUrl(version.songUrl)),
      ]),
      'detectedSongUrls': detectedSongUrls,
      'downloadComplete': downloadComplete,
      'audioPath': selected?.audioPath ??
          (_sunoEngine.state.articleId == articleId
              ? _sunoEngine.state.audioPath
              : null),
      'metadataPath': metadataPath,
      'versions': mergedVersions.map((version) => version.toJson()).toList(),
      'manualActionMessage': manualActionMessage,
      'createdAt':
          existingMetadata?['createdAt'] ?? DateTime.now().toIso8601String(),
    };
    await File(metadataPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(metadata),
      flush: true,
    );
    if (_sunoEngine.state.articleId == articleId) {
      _sunoEngine.state.metadataPath = metadataPath;
    }
    final cacheKey = existingEntry?.cacheKey ??
        await ApiCacheService.keyForJson('article_suno_song', request);
    await ApiCacheService.putJson(
      cacheKey: cacheKey,
      kind: 'suno_music',
      purpose: _sunoSongPurpose,
      request: request,
      jsonValue: metadata,
      articleId: articleId,
    );
  }

  Future<Map<String, dynamic>> _generateBailianFunMusic({
    required Article article,
    required String lyrics,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      throw const FormatException('文章尚未保存，不能生成歌曲');
    }
    final trimmedLyrics = lyrics.trim();
    if (trimmedLyrics.isEmpty) {
      throw const FormatException('文章没有可用于阿里云百聆的英文歌词');
    }
    _stopSunoAutomation(clearVisible: false);
    await _pushEvent(
      'listening.song.state',
      ArticleSongState(
        articleId: articleId,
        status: 'generating',
        source: AppConfig.songProviderBailianFunMusic,
        manualActionMessage: '阿里云百聆正在根据当前歌词生成歌曲。',
      ).toJson(),
    );
    final result = await BailianMusicService.generateFromLyrics(
      lyrics: trimmedLyrics,
      title: article.title,
      articleId: articleId,
    );
    if (result.source == BailianMusicResultSource.skippedNoKey ||
        result.source == BailianMusicResultSource.failed ||
        (result.filePath ?? '').trim().isEmpty) {
      final message = _bailianMusicErrorMessage(result.errorMessage);
      await _pushSongState(
        articleId,
        statusOverride: 'error',
        errorMessageOverride: message,
        sourceOverride: AppConfig.songProviderBailianFunMusic,
      );
      throw FormatException(message);
    }

    final existingState = await _cachedBailianSongState(article);
    final existingVersions = existingState?.versions.toList(growable: true) ??
        <ArticleSongVersion>[];
    final cacheId = (result.cacheKey ?? DateTime.now().millisecondsSinceEpoch)
        .toString()
        .replaceAll(RegExp(r'[^A-Za-z0-9_]+'), '_');
    final submittedLyrics = (result.submittedLyrics ?? trimmedLyrics).trim();
    final lyricsHash = await ApiCacheService.hashUtf8(submittedLyrics);
    final model = await AppConfig.aliyunBailianMusicModel;
    final resultPath = result.filePath!.trim();
    ArticleSongVersion? existingMatch;
    for (final version in existingVersions) {
      if (version.audioPath.trim() == resultPath) {
        existingMatch = version;
        break;
      }
    }
    final newVersion = (existingMatch ??
            ArticleSongVersion(
              id: 'bailian_fun_music_$cacheId',
              audioPath: resultPath,
              title: '阿里云百聆版本 ${existingVersions.length + 1}',
              createdAt: DateTime.now().toIso8601String(),
            ))
        .copyWith(
      songUrl: result.audioUrl ?? existingMatch?.songUrl,
      durationMs: result.durationMs ?? existingMatch?.durationMs,
      stylePrompt: model,
      styleKey: model,
      lyricsHash: lyricsHash,
      submittedLyrics: submittedLyrics,
      source: AppConfig.songProviderBailianFunMusic,
      isDefault: true,
    );
    final sameHashExisting = existingVersions
        .where((version) => (version.lyricsHash ?? '') == lyricsHash)
        .toList(growable: false);
    final versions = <ArticleSongVersion>[
      newVersion,
      for (final version in sameHashExisting)
        if (version.id != newVersion.id &&
            version.audioPath.trim() != newVersion.audioPath.trim())
          version.copyWith(isDefault: false),
    ];
    await _saveBailianMusicMetadataForVersions(
      article: article,
      versions: versions,
      songUrl: result.audioUrl,
      durationMs: result.durationMs,
      requestId: result.requestId,
      model: model,
      lyricsCompressed: result.lyricsCompressed,
    );
    return _songStatePayload(
      articleId,
      statusOverride: 'ready',
      sourceOverride: AppConfig.songProviderBailianFunMusic,
    );
  }

  String _bailianMusicErrorMessage(String? rawMessage) {
    final raw = (rawMessage ?? '').trim();
    if (raw.isEmpty) {
      return '阿里云百聆生成失败';
    }
    if (raw.contains('Lyrics content is illegal')) {
      return '阿里云百聆拒绝了当前歌词内容。已按歌曲格式压缩歌词后仍失败，请换一篇更温和的英文内容或稍后重试。';
    }
    return raw
        .replaceFirst(RegExp(r'^FormatException:\s*'), '')
        .replaceFirst(RegExp(r'^FormatException:\s*'), '')
        .trim();
  }

  Future<void> _saveBailianMusicMetadataForVersions({
    required Article article,
    required List<ArticleSongVersion> versions,
    String? songUrl,
    int? durationMs,
    String? requestId,
    required String model,
    bool lyricsCompressed = false,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      return;
    }
    final incomingVersions = versions
        .map((version) =>
            version.copyWith(source: AppConfig.songProviderBailianFunMusic))
        .toList(growable: false);
    if (incomingVersions.isEmpty) {
      return;
    }
    final selectedIncoming =
        _defaultSongVersion(incomingVersions) ?? incomingVersions.first;
    final lyricsHash =
        selectedIncoming.lyricsHash ?? await _articleSongLyricsHash(article);
    final submittedLyrics = (selectedIncoming.submittedLyrics ?? '').trim();
    final existingEntry = await ArticleSongCacheService.findEntryForLyricsHash(
      articleId: articleId,
      purpose: _bailianSongPurpose,
      lyricsHash: lyricsHash,
    );
    final directory = Directory(await _resolvedSunoOutputDirectorySetting());
    await directory.create(recursive: true);
    Map<String, dynamic> request;
    Map<String, dynamic>? existingMetadata;
    String metadataPath;
    List<ArticleSongVersion> mergedVersions;
    if (existingEntry != null) {
      existingMetadata = ArticleSongCacheService.decodeJsonObject(
        existingEntry.jsonValue,
      );
      request = ArticleSongCacheService.decodeRequest(existingEntry);
      metadataPath = (existingMetadata['metadataPath'] ?? '').toString().trim();
      if (metadataPath.isEmpty) {
        metadataPath = path_lib.join(
          directory.path,
          'article_${articleId}_bailian_fun_music_${DateTime.now().millisecondsSinceEpoch}.json',
        );
      }
      mergedVersions = _dedupeSongVersions([
        ...ArticleSongCacheService.versionsFromMetadata(existingMetadata),
        ...incomingVersions,
      ]);
    } else {
      request = {
        'version': 1,
        'provider': AppConfig.songProviderBailianFunMusic,
        'articleId': articleId,
        'articleTitle': article.title,
        'contentHash': await _articleSongContentHash(article),
        'lyricsHash': lyricsHash,
        if (submittedLyrics.isNotEmpty)
          'submittedLyricsHash':
              await ApiCacheService.hashUtf8(submittedLyrics),
        'model': model,
      };
      metadataPath = path_lib.join(
        directory.path,
        'article_${articleId}_bailian_fun_music_${DateTime.now().millisecondsSinceEpoch}.json',
      );
      mergedVersions = _dedupeSongVersions(incomingVersions);
    }
    final selected = _defaultSongVersion(mergedVersions) ??
        (mergedVersions.isNotEmpty ? mergedVersions.first : null);
    final metadata = {
      'provider': AppConfig.songProviderBailianFunMusic,
      'articleId': articleId,
      'articleTitle': article.title,
      'lyricsHash': lyricsHash,
      if (submittedLyrics.isNotEmpty) 'submittedLyrics': submittedLyrics,
      if (lyricsCompressed || existingMetadata?['lyricsCompressed'] == true)
        'lyricsCompressed': true,
      'model': model,
      'songUrl': songUrl ?? selected?.songUrl,
      'durationMs': durationMs ?? selected?.durationMs,
      'requestId': requestId,
      'audioPath': selected?.audioPath,
      'metadataPath': metadataPath,
      'downloadComplete': true,
      'versions': mergedVersions.map((version) => version.toJson()).toList(),
      'createdAt':
          existingMetadata?['createdAt'] ?? DateTime.now().toIso8601String(),
    };
    await File(metadataPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(metadata),
      flush: true,
    );
    final cacheKey = existingEntry?.cacheKey ??
        await ApiCacheService.keyForJson('article_bailian_fun_music', request);
    await ApiCacheService.putJson(
      cacheKey: cacheKey,
      kind: 'bailian_fun_music',
      purpose: _bailianSongPurpose,
      request: request,
      jsonValue: metadata,
      articleId: articleId,
    );
  }

  Future<Map<String, dynamic>> _startSunoAutomation({
    required Article article,
    required String stylePrompt,
    required String lyrics,
    bool completedStandby = false,
  }) async {
    await _sunoEngine.startAutomation(
      article: article,
      stylePrompt: stylePrompt,
      lyrics: lyrics,
      completedStandby: completedStandby,
      loadGroups: _cachedSunoSongGroups,
      loadCachedState: _cachedSunoSongState,
    );
    final articleId = article.id;
    if (articleId == null) {
      throw const FormatException('文章尚未保存，不能生成歌曲');
    }
    return _songStatePayload(articleId);
  }

  Future<Map<String, dynamic>> _startExistingSunoDownload(
    Article article,
  ) async {
    final articleId = article.id;
    if (articleId == null) {
      throw const FormatException('文章尚未保存，不能下载歌曲');
    }
    await _sunoEngine.startExistingDownload(
      article: article,
      lyrics: _articleSongLyrics(article),
      loadGroups: _cachedSunoSongGroups,
      loadCachedState: _cachedSunoSongState,
      otherArticleUrls: _sunoSongUrlsForOtherArticles,
    );
    return _songStatePayload(articleId);
  }

  void _stopSunoAutomation({required bool clearVisible}) {
    _sunoEngine.stopAutomation(clearVisible: clearVisible);
  }

  Future<void> _continueSunoAutomation() async {
    _sunoEngine.attachWebController(_sunoController);
    await _sunoEngine.tick();
  }

  Future<Map<String, dynamic>> _handleSunoContinueAutomation(
    BridgeMessage message,
  ) async {
    await _continueSunoAutomation();
    final articleId = _sunoEngine.state.articleId ??
        _payloadOptionalInt(message.payload, 'articleId');
    if (articleId == null) {
      return {
        'ok': false,
        'status': _sunoEngine.state.statusKey,
        'message': '当前没有进行中的 Suno 自动化',
      };
    }
    return {
      'ok': true,
      'status': _sunoEngine.state.statusKey,
      ...(await _songStatePayload(articleId)),
    };
  }

  Future<void> _confirmSunoCreate() async {
    _sunoEngine.attachWebController(_sunoController);
    await _sunoEngine.confirmCreate();
  }

  Future<void> _handleSunoDownload(DownloadStartRequest request) async {
    await _sunoEngine.handleWebViewDownload(request);
  }

  void _closeCompletedSunoOverlay() {
    _stopSunoAutomation(clearVisible: true);
    final articleId = _sunoEngine.state.articleId;
    if (articleId != null) {
      unawaited(_pushSongState(articleId));
    }
  }

  Future<Map<String, dynamic>> _handleSunoDebugInspect(
    BridgeMessage message,
  ) async {
    final controller = _sunoController;
    if (controller == null) {
      return {
        'ok': false,
        'message': 'Suno 页面尚未打开',
        'status': _sunoEngine.state.statusKey,
      };
    }
    final url = await controller.getUrl();
    final inspect =
        await _evaluateSunoJson(controller, SunoWebScripts.inspectScript);
    final diagnostics = await _evaluateSunoJson(
      controller,
      SunoWebScripts.domDiagnosticsScript,
    );
    return {
      'ok': true,
      'status': _sunoEngine.state.statusKey,
      'manualActionMessage': _sunoEngine.state.manualActionMessage,
      'errorMessage': _sunoEngine.state.errorMessage,
      'url': url?.toString(),
      'inspect': inspect,
      'diagnostics': diagnostics,
    };
  }

  Future<Map<String, dynamic>> _handleSunoDebugRows(
    BridgeMessage message,
  ) async {
    final controller = _sunoController;
    if (controller == null) {
      return {
        'ok': false,
        'message': 'Suno 页面尚未打开',
        'status': _sunoEngine.state.statusKey,
      };
    }
    final rows = await _evaluateSunoJson(
      controller,
      SunoWebScripts.rowsDebugScript(
        expectedStylePrompt: _sunoEngine.state.stylePrompt,
        expectedLyrics: _sunoEngine.state.lyrics,
      ),
    );
    return {
      'ok': true,
      'status': _sunoEngine.state.statusKey,
      'stylePrompt': _sunoEngine.state.stylePrompt,
      'rows': rows,
    };
  }

  Future<Map<String, dynamic>> _handleSunoDebugSnapshot(
    BridgeMessage message,
  ) async {
    final controller = _sunoController;
    if (controller == null) {
      return {
        'ok': false,
        'message': 'Suno 页面尚未打开',
        'status': _sunoEngine.state.statusKey,
      };
    }

    final outputDirectory = _payloadString(
      message.payload,
      'directory',
      fallback: _defaultSunoFixtureDirectory(),
    ).trim();
    final includeScreenshot = _payloadBool(
      message.payload,
      'includeScreenshot',
      fallback: true,
    );
    final directory = Directory(
      outputDirectory.isEmpty
          ? _defaultSunoFixtureDirectory()
          : outputDirectory,
    );
    await directory.create(recursive: true);

    final url = (await controller.getUrl())?.toString() ?? '';
    final timestamp = DateTime.now().toUtc();
    final pageKind = SunoUtilities.pageKind(url);
    final stem = _safeSunoSnapshotStem(url, timestamp);
    final warnings = <String>[];

    final inspect =
        await _evaluateSunoJson(controller, SunoWebScripts.inspectScript);
    final diagnostics = await _evaluateSunoJson(
      controller,
      SunoWebScripts.domDiagnosticsScript,
    );
    final rows = await _evaluateSunoJson(
      controller,
      SunoWebScripts.rowsDebugScript(
        expectedStylePrompt: _sunoEngine.state.stylePrompt,
        expectedLyrics: _sunoEngine.state.lyrics,
      ),
    );
    final completion = await _evaluateSunoJson(
      controller,
      SunoWebScripts.completionScript(
        expectedStylePrompt: _sunoEngine.state.stylePrompt,
        expectedLyrics: _sunoEngine.state.lyrics,
        requireExpectedMatch: false,
        trustedSongUrls: _sunoEngine.state.trustedSongUrlsList(),
      ),
    );
    final currentSongUrl = (_sunoEngine.state.songUrl ?? '').trim();
    final shouldProbeDownload = pageKind == 'song' ||
        pageKind == 'library' ||
        pageKind == 'profile' ||
        _sunoEngine.state.existingDownloadOnly ||
        _sunoEngine.state.createSubmitted ||
        _sunoEngine.state.statusKey == 'downloading';
    final downloadProbe = shouldProbeDownload
        ? await _evaluateSunoJson(
            controller,
            SunoWebScripts.downloadScript(
              downloadedSongUrls: _sunoEngine.state.downloadedSongUrls.toList(),
              pendingSongUrl:
                  _sunoEngine.state.pendingDownloadSongUrl ?? currentSongUrl,
              allowedSongUrls:
                  currentSongUrl.isEmpty ? const <String>[] : [currentSongUrl],
              expectedStylePrompt: _sunoEngine.state.stylePrompt,
              expectedLyrics: _sunoEngine.state.lyrics,
              requireExpectedMatch: true,
              trustedSongUrls: _sunoEngine.state.trustedSongUrlsList(
                currentSongUrl.isEmpty ? const <String>[] : [currentSongUrl],
              ),
              dryRun: true,
            ),
          )
        : <String, dynamic>{
            'skipped': true,
            'reason': 'not-download-page',
            'pageKind': pageKind,
          };
    final page =
        await _evaluateSunoJson(controller, SunoWebScripts.snapshotScript);
    final sanitizedHtml = (page.remove('sanitizedHtml') ?? '').toString();

    String? htmlPath;
    if (sanitizedHtml.trim().isNotEmpty) {
      htmlPath = path_lib.join(directory.path, '$stem.html');
      await File(htmlPath).writeAsString(sanitizedHtml, flush: true);
      page['sanitizedHtmlPath'] = htmlPath;
    }

    String? screenshotPath;
    if (includeScreenshot) {
      try {
        final screenshot = await controller.takeScreenshot();
        if (screenshot != null && screenshot.isNotEmpty) {
          screenshotPath = path_lib.join(directory.path, '$stem.png');
          await File(screenshotPath).writeAsBytes(screenshot, flush: true);
        }
      } catch (error) {
        warnings.add('截图保存失败：${_displayError(error)}');
      }
    }

    final snapshotPath = path_lib.join(directory.path, '$stem.json');
    final snapshot = {
      'schema': 'tomato_suno_snapshot_v1',
      'capturedAt': timestamp.toIso8601String(),
      'url': url,
      'pageKind': pageKind,
      'status': _sunoEngine.state.statusKey,
      'manualActionMessage': _sunoEngine.state.manualActionMessage,
      'errorMessage': _sunoEngine.state.errorMessage,
      'articleId': _sunoEngine.state.articleId,
      'songUrl': _sunoEngine.state.songUrl,
      'pendingSongUrl': _sunoEngine.state.pendingDownloadSongUrl,
      'existingDownloadOnly': _sunoEngine.state.existingDownloadOnly,
      'createSubmitted': _sunoEngine.state.createSubmitted,
      'stylePrompt': _sunoEngine.state.stylePrompt,
      'lyricsSample': _sunoEngine.state.lyrics.length <= 1200
          ? _sunoEngine.state.lyrics
          : '${_sunoEngine.state.lyrics.substring(0, 1200)}...',
      'downloadedSongUrls': _sunoEngine.state.downloadedSongUrls.toList(),
      'inspect': inspect,
      'diagnostics': diagnostics,
      'rows': rows,
      'completion': completion,
      'downloadProbe': downloadProbe,
      'page': page,
      'htmlPath': htmlPath,
      'screenshotPath': screenshotPath,
      'warnings': warnings,
    };
    await File(snapshotPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(snapshot),
      flush: true,
    );

    return {
      'ok': true,
      'path': snapshotPath,
      'htmlPath': htmlPath,
      'screenshotPath': screenshotPath,
      'url': url,
      'pageKind': SunoUtilities.pageKind(url),
      'status': _sunoEngine.state.statusKey,
      'downloadProbe': downloadProbe,
      'warnings': warnings,
    };
  }

  Future<Map<String, dynamic>> _handleSunoDebugFill(
    BridgeMessage message,
  ) async {
    final controller = _sunoController;
    if (controller == null) {
      return {
        'ok': false,
        'message': 'Suno 页面尚未打开',
        'status': _sunoEngine.state.statusKey,
      };
    }
    final lyrics = _payloadString(
      message.payload,
      'lyrics',
      fallback: _sunoEngine.state.lyrics.isEmpty
          ? 'Tomato Suno automation field detection test.'
          : _sunoEngine.state.lyrics,
    );
    final stylePrompt = _payloadString(
      message.payload,
      'stylePrompt',
      fallback: _sunoEngine.state.stylePrompt.isEmpty
          ? 'whimsical story song, gentle pop, bright piano'
          : _sunoEngine.state.stylePrompt,
    );
    return _evaluateSunoJson(
      controller,
      SunoWebScripts.fillScript(
        lyrics: lyrics,
        stylePrompt: stylePrompt,
        ignoredStylePrompt: _payloadString(
          message.payload,
          'ignoredStylePrompt',
          fallback: _sunoEngine.state.ignoredStylePrompt,
        ),
        allowMagicClick: true,
        magicAlreadyRequested: false,
        readOnly: _payloadBool(message.payload, 'readOnly', fallback: false),
      ),
    );
  }

  Future<List<int>> _downloadSunoUrl(
    String url, {
    String? userAgent,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      if ((userAgent ?? '').trim().isNotEmpty) {
        request.headers.set(HttpHeaders.userAgentHeader, userAgent!.trim());
      }
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw FormatException('HTTP ${response.statusCode}');
      }
      final chunks = <int>[];
      await for (final chunk in response) {
        chunks.addAll(chunk);
      }
      return chunks;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _deleteFileIfExists(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final file = File(trimmed);
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (error, stackTrace) {
      TomatoLogger.warn(
        category: 'filesystem',
        event: 'delete_file_failed',
        message: _displayError(error),
        stackTrace: stackTrace,
        data: {'path': trimmed},
      );
    }
  }

  Future<Map<String, dynamic>> _evaluateSunoJson(
    InAppWebViewController controller,
    String source,
  ) async {
    final raw = await controller.evaluateJavascript(source: source);
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    final text = raw?.toString().trim() ?? '';
    if (text.isEmpty) {
      return const <String, dynamic>{};
    }
    final decoded = jsonDecode(text);
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    return const <String, dynamic>{};
  }

  String _sunoOverlayStatusText() {
    if (_sunoEngine.state.errorMessage != null) {
      return 'Suno 自动化失败：$_sunoEngine.state.errorMessage';
    }
    if ((_sunoEngine.state.manualActionMessage ?? '').trim().isNotEmpty) {
      return _sunoEngine.state.manualActionMessage!;
    }
    switch (_sunoEngine.state.statusKey) {
      case 'waitingLogin':
        return '等待 Suno 登录';
      case 'waitingConfirm':
        return 'Suno 歌词和自动风格已填写，等待确认创建';
      case 'creating':
        return 'Suno 正在生成歌曲';
      case 'downloading':
        return '正在下载 Suno 歌曲';
      case 'complete':
        return 'Suno 歌曲下载完成，请确认关闭 Suno 窗口。';
      default:
        return 'Suno 自动操作中';
    }
  }

  Future<Map<String, dynamic>> _handleListeningPrepare(
    BridgeMessage message,
  ) async {
    final text = _payloadString(message.payload, 'text').trim();
    if (text.isEmpty) {
      return {'prepared': false};
    }

    final part = _payloadString(message.payload, 'part').trim();
    final isChineseAudioRequest = part == 'chinese' || _containsChinese(text);
    if (isChineseAudioRequest) {
      return {
        'prepared': false,
        'reason': 'chinese_tts_disabled',
      };
    }
    final handle = await ListeningAudioMaterialService.cachedFileHandle(
      text: text,
      voiceType: TtsService.defaultVoiceType,
      preferRequestedVoice: false,
      articleId: _activeArticleContextId,
    );
    if (handle == null) {
      return {
        'prepared': false,
        'reason': 'missing_audio_material',
        'message': ListeningAudioMaterialService.missingMaterialMessage,
      };
    }
    return {'prepared': true, 'path': handle.filePath};
  }

  Future<Map<String, dynamic>> _handleListeningPreloadChinese(
    BridgeMessage message,
  ) async =>
      {'started': false, 'reason': 'chinese_tts_disabled'};

  Future<Map<String, dynamic>> _handleListeningUpdateSentence(
    BridgeMessage message,
  ) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    final sentenceIndex = _payloadInt(message.payload, 'index');
    final english =
        _normalizeEnglishWordJoiners(_payloadString(message.payload, 'english'))
            .trim();
    final chinese = _payloadString(message.payload, 'chinese').trim();
    final previousEnglish =
        _payloadString(message.payload, 'previousEnglish').trim();
    final previousChinese =
        _payloadString(message.payload, 'previousChinese').trim();
    if (english.isEmpty && previousEnglish.trim().isEmpty) {
      throw const FormatException('该句已隐藏');
    }

    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) {
      throw FormatException('文章不存在（id=$articleId）');
    }
    final article = await _articleWithPersistedSentences(rawArticle);
    if (sentenceIndex < 0 || sentenceIndex >= article.sentences.length) {
      throw FormatException('句子序号不存在（index=$sentenceIndex）');
    }

    final oldEnglish = article.sentences[sentenceIndex].trim();
    final storedChinese = await DatabaseService.getArticleSentenceTranslation(
      articleId,
      sentenceIndex,
      oldEnglish,
    );
    final oldChinese =
        previousChinese.isNotEmpty ? previousChinese : (storedChinese ?? '');
    final isHiding = english.isEmpty;
    final englishChanged = isHiding ||
        english != oldEnglish ||
        (previousEnglish.isNotEmpty && previousEnglish != english);
    final chineseChanged = isHiding || chinese != oldChinese;

    if (englishChanged || chineseChanged) {
      await _stopListeningPlayback();
      await _stopSongPlayback();
    }

    final updatedSentences = List<String>.from(article.sentences);
    updatedSentences[sentenceIndex] = english;
    final updatedContent = _contentWithUpdatedSentence(
      content: article.content,
      oldSentence: oldEnglish,
      newSentence: english,
      sentences: updatedSentences,
    );
    await DatabaseService.updateArticleContentAndSentences(
      articleId,
      updatedContent,
      updatedSentences,
    );
    if (isHiding || chinese.isEmpty) {
      await DatabaseService.deleteArticleSentenceTranslation(
        articleId,
        sentenceIndex,
      );
    } else {
      await DatabaseService.upsertArticleSentenceTranslation(
        articleId: articleId,
        sentenceIndex: sentenceIndex,
        englishSentence: english,
        chineseText: chinese,
      );
    }

    ref.invalidate(followReadProvider(articleId));
    final updatedArticle = article.copyWith(
      content: updatedContent,
      sentences: updatedSentences,
    );
    final synthesis = await _refreshEditedListeningAudio(
      articleId: articleId,
      oldEnglish: oldEnglish,
      newEnglish: english,
      refreshEnglish: englishChanged,
      refreshChinese: chineseChanged,
      synthesizeEnglish: false,
    );
    final payload = await _articleListPayload();
    unawaited(_pushEvent('article.state', payload));
    return {
      'article': await _articleJsonWithStory(
        updatedArticle,
        averageScore: await DatabaseService.getAverageScore(articleId),
      ),
      'item': {
        'index': sentenceIndex,
        'english': english,
        'chinese': isHiding ? '' : chinese,
        'hidden': isHiding,
      },
      'items': await _listeningItemsForArticle(updatedArticle),
      'synthesis': synthesis,
      'articles': payload['articles'],
      'series': payload['series'],
    };
  }

  Future<Map<String, dynamic>> _handleListeningResynthesizeSentence(
    BridgeMessage message,
  ) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    final sentenceIndex = _payloadInt(message.payload, 'index');
    final part = _payloadString(message.payload, 'part', fallback: 'both');
    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) {
      throw FormatException('文章不存在（id=$articleId）');
    }
    final article = await _articleWithPersistedSentences(rawArticle);
    if (sentenceIndex < 0 || sentenceIndex >= article.sentences.length) {
      throw FormatException('句子序号不存在（index=$sentenceIndex）');
    }
    await _stopListeningPlayback();
    await _stopSongPlayback();
    final english = article.sentences[sentenceIndex].trim();
    if (isHiddenListeningSentence(english)) {
      throw const FormatException('该句已隐藏，请先恢复字幕');
    }
    final chinese = (await DatabaseService.getArticleSentenceTranslation(
          articleId,
          sentenceIndex,
          english,
        )) ??
        _payloadString(message.payload, 'chinese').trim();
    final refreshChinese =
        (part == 'both' || part == 'chinese') && chinese.trim().isNotEmpty;
    final synthesis = await _refreshEditedListeningAudio(
      articleId: articleId,
      oldEnglish: english,
      newEnglish: english,
      refreshEnglish: part == 'both' || part == 'english',
      refreshChinese: refreshChinese,
      synthesizeEnglish: true,
    );
    return {
      'item': {
        'index': sentenceIndex,
        'english': english,
        'chinese': chinese,
      },
      'synthesis': synthesis,
    };
  }

  Future<Map<String, dynamic>> _handleListeningStop(
    BridgeMessage message,
  ) async {
    await _stopListeningPlayback();
    await _stopSongPlayback();
    return {'stopped': true};
  }

  Future<Map<String, dynamic>> _handleListeningPause(
    BridgeMessage message,
  ) async {
    final player = _listeningPlayer;
    if (player == null) {
      return {'paused': false};
    }

    if (_listeningPausedForWord) {
      return {'paused': true};
    }

    try {
      await player.pause().timeout(const Duration(seconds: 2));
      _listeningPausedForWord = true;
      return {'paused': true};
    } catch (error) {
      TomatoLogger.warn(
        category: 'listening',
        event: 'playback.pause_failed',
        articleId: _activeListeningArticleId,
        error: error,
      );
      return {'paused': false};
    }
  }

  Future<Map<String, dynamic>> _handleListeningResume(
    BridgeMessage message,
  ) async {
    final player = _listeningPlayer;
    if (player == null || !_listeningPausedForWord) {
      _listeningPausedForWord = false;
      return {'resumed': false};
    }

    _listeningPausedForWord = false;
    unawaited(player.play().catchError((Object error) {
      TomatoLogger.warn(
        category: 'listening',
        event: 'playback.resume_failed',
        articleId: _activeListeningArticleId,
        error: error,
      );
    }));
    return {'resumed': true};
  }

  Future<Map<String, dynamic>> _handleWordLookup(
    BridgeMessage message,
  ) async {
    final word = _normalizeLookupWord(
      _payloadString(message.payload, 'word'),
    );
    final sentence = _payloadString(message.payload, 'sentence').trim();
    if (word.isEmpty) {
      throw const FormatException('单词不能为空');
    }

    final lookup = await PracticeTextService.lookupWordForLearning(
      word: word,
      sentence: sentence,
      articleId: _activeArticleContextId,
    ).timeout(const Duration(seconds: 12));

    return {
      'word': lookup.word,
      'phonetic': lookup.phonetic,
      'meaning': lookup.meaning,
      'sentenceMeaning': lookup.sentenceMeaning,
      'source': lookup.source.name,
    };
  }

  Future<Map<String, dynamic>> _handleWordPlay(
    BridgeMessage message,
  ) async {
    final word = _normalizeLookupWord(
      _payloadString(message.payload, 'word'),
    );
    if (word.isEmpty) {
      throw const FormatException('单词不能为空');
    }

    await _playWordPronunciation(word);
    return {'playbackState': 'success'};
  }

  Future<Map<String, dynamic>> _handleWordStop(
    BridgeMessage message,
  ) async {
    await _stopVoicePreview();
    return {'stopped': true};
  }

  Future<Map<String, dynamic>> _handleChatOpen(BridgeMessage message) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    final followArticleId = _activeFollowArticleId;
    if (followArticleId != null && followArticleId != articleId) {
      TtsMemoryCacheService.releaseArticle(followArticleId);
    }
    _closeFollowSession();
    final listeningArticleId = _activeListeningArticleId;
    if (listeningArticleId != null && listeningArticleId != articleId) {
      TtsMemoryCacheService.releaseArticle(listeningArticleId);
    }
    _activeListeningArticleId = null;
    await _stopListeningPlayback();
    await _stopSongPlayback();
    _openChatSession(articleId);
    unawaited(
      PictureBookService.statePayload(articleId).then(
        (state) => _pushEvent('pictureBook.state', state),
      ),
    );
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
    final provider = _payloadString(
      message.payload,
      'aiProvider',
      fallback: await AppConfig.aiProvider,
    ).trim();
    if (provider == AppConfig.aiProviderAliyunBailian) {
      if (!TtsService.isAliyunPresetVoice(speakerId)) {
        throw const FormatException('请选择支持的阿里云声音');
      }
      await AppConfig.saveCloudSettings(aliyunBailianTtsVoice: speakerId);
    } else if (TtsService.isPresetVoice(speakerId)) {
      await AppConfig.saveVolcTtsSpeakerId(speakerId);
    } else {
      throw const FormatException('请选择支持的声音');
    }
    final payload = await _settingsPayload();
    unawaited(_pushEvent('settings.state', payload));
    return payload;
  }

  Future<Map<String, dynamic>> _handleSettingsSaveSong(
    BridgeMessage message,
  ) async {
    final sunoOutputDirectory = _payloadString(
      message.payload,
      'sunoOutputDirectory',
    ).trim();
    final timeout = _payloadOptionalInt(
          message.payload,
          'sunoTimeoutMinutes',
        ) ??
        20;

    final safeSunoOutputDirectory =
        _sunoOutputDirectorySettingForSave(sunoOutputDirectory);
    await AppConfig.saveSongSettings(
      sunoOutputDirectory: safeSunoOutputDirectory,
      sunoTimeoutMinutes: timeout,
      songProvider: _payloadString(
        message.payload,
        'songProvider',
        fallback: await AppConfig.songGenerationProvider,
      ),
    );
    final payload = await _settingsPayload();
    unawaited(_pushEvent('settings.state', payload));
    return payload;
  }

  Future<Map<String, dynamic>> _handleSettingsSaveCloud(
    BridgeMessage message,
  ) async {
    String? optionalString(String key) => message.payload.containsKey(key)
        ? _payloadString(message.payload, key).trim()
        : null;
    await AppConfig.saveCloudSettings(
      aiProvider: optionalString('aiProvider'),
      aliyunBailianApiKey: optionalString('aliyunBailianApiKey'),
      clearAliyunBailianApiKey: _payloadBool(
        message.payload,
        'clearAliyunBailianApiKey',
      ),
      aliyunBailianBaseUrl: optionalString('aliyunBailianBaseUrl'),
      aliyunBailianApiBaseUrl: optionalString('aliyunBailianApiBaseUrl'),
      aliyunBailianTextModel: optionalString('aliyunBailianTextModel'),
      aliyunBailianMusicModel: optionalString('aliyunBailianMusicModel'),
      aliyunBailianImageModel: optionalString('aliyunBailianImageModel'),
      aliyunBailianImageSize: optionalString('aliyunBailianImageSize'),
      aliyunBailianTtsModel: optionalString('aliyunBailianTtsModel'),
      aliyunBailianTtsVoice: optionalString('aliyunBailianTtsVoice'),
      aliyunBailianTtsSampleRate: optionalString('aliyunBailianTtsSampleRate'),
      aliyunBailianAsrModel: optionalString('aliyunBailianAsrModel'),
      aliyunBailianRealtimeAsrModel:
          optionalString('aliyunBailianRealtimeAsrModel'),
      aliyunBailianRealtimeAsrUrl:
          optionalString('aliyunBailianRealtimeAsrUrl'),
      volcArkApiKey: optionalString('volcArkApiKey'),
      clearVolcArkApiKey: _payloadBool(
        message.payload,
        'clearVolcArkApiKey',
      ),
      volcArkBaseUrl: optionalString('volcArkBaseUrl'),
      volcArkTextModel: optionalString('volcArkTextModel'),
      volcArkImageModel: optionalString('volcArkImageModel'),
      volcSpeechApiKey: optionalString('volcSpeechApiKey'),
      clearVolcSpeechApiKey: _payloadBool(
        message.payload,
        'clearVolcSpeechApiKey',
      ),
      volcTtsResourceId: optionalString('volcTtsResourceId'),
      volcTtsSpeakerId: optionalString('volcTtsSpeakerId'),
    );
    final payload = await _settingsPayload();
    unawaited(_pushEvent('settings.state', payload));
    return payload;
  }

  Future<Map<String, dynamic>> _handleDiagnosticsLogsRecent(
    BridgeMessage message,
  ) async {
    return {
      'logs': TomatoLogger.recentJson(
        limit: _payloadOptionalInt(message.payload, 'limit') ?? 200,
        level: _payloadString(message.payload, 'level'),
        category: _payloadString(message.payload, 'category'),
        since: _payloadString(message.payload, 'since'),
      ),
    };
  }

  Future<Map<String, dynamic>> _handleDiagnosticsLogsExport(
    BridgeMessage message,
  ) =>
      TomatoLogger.exportDiagnostics(
        environment: _qaHealth,
        snapshot: _qaSnapshot,
      );

  Future<Map<String, dynamic>> _handleDiagnosticsClientLog(
    BridgeMessage message,
  ) async {
    final level = _payloadString(
      message.payload,
      'level',
      fallback: 'info',
    );
    final category = _payloadString(
      message.payload,
      'category',
      fallback: 'webview',
    );
    final event = _payloadString(
      message.payload,
      'event',
      fallback: 'client.log',
    );
    final text = _payloadString(message.payload, 'message').trim();
    TomatoLogger.log(
      level: level,
      category: category.trim().isEmpty ? 'webview' : category,
      event: event.trim().isEmpty ? 'client.log' : event,
      message: text.isEmpty ? null : text,
      route: _payloadString(message.payload, 'route'),
      data: {
        'source': 'web_ui',
        'data': message.payload['data'],
      },
      error: message.payload['error'],
    );
    return {'accepted': true};
  }

  Future<Map<String, dynamic>> _handleRecordingSettingsLoad(
    BridgeMessage message,
  ) =>
      RecordingExportService.settingsPayload();

  Future<Map<String, dynamic>> _handleRecordingSettingsSave(
    BridgeMessage message,
  ) async {
    final payload = await RecordingExportService.saveSettings(
      codec: _payloadString(message.payload, 'codec', fallback: 'h264'),
      resolution: _payloadString(
        message.payload,
        'resolution',
        fallback: '1920x1080',
      ),
      pageTransition: _payloadString(
        message.payload,
        'pageTransition',
        fallback: 'none',
      ),
      subtitleMode: _payloadString(
        message.payload,
        'subtitleMode',
        fallback: 'srt',
      ),
    );
    unawaited(_pushEvent('recording.settings.state', payload));
    return payload;
  }

  Future<Map<String, dynamic>> _handleSettingsPreviewVoice(
    BridgeMessage message,
  ) async {
    final speakerId = _payloadString(message.payload, 'speakerId').trim();
    final provider = _payloadString(
      message.payload,
      'aiProvider',
      fallback: await AppConfig.aiProvider,
    ).trim();
    final validVoice = provider == AppConfig.aiProviderAliyunBailian
        ? TtsService.isAliyunPresetVoice(speakerId)
        : TtsService.isPresetVoice(speakerId);
    if (!validVoice) {
      throw const FormatException('请选择支持的声音');
    }

    await _playVoicePreview(speakerId, provider: provider);
    return {'playbackState': 'success'};
  }

  Future<Map<String, dynamic>> _handleContentSafetySetRuleEnabled(
    BridgeMessage message,
  ) async {
    final id = _payloadInt(message.payload, 'id');
    final enabled = _payloadBool(message.payload, 'enabled', fallback: true);
    await ContentSafetyService.setRuleEnabled(id, enabled);
    final payload = await _settingsPayload();
    unawaited(_pushEvent('settings.state', payload));
    return payload;
  }

  Future<Map<String, dynamic>> _handleContentSafetyDeleteRule(
    BridgeMessage message,
  ) async {
    final id = _payloadInt(message.payload, 'id');
    await ContentSafetyService.deleteRule(id);
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

  Future<void> _playListeningText({
    required String text,
  }) async {
    final token = ++_listeningPlaybackToken;
    _listeningPausedForWord = false;
    await _stopVoicePreview();
    await _stopSongPlayback();
    await _disposeListeningPlayer();

    try {
      final handle = await ListeningAudioMaterialService.cachedFileHandle(
        text: text,
        voiceType: TtsService.defaultVoiceType,
        preferRequestedVoice: false,
        articleId: _activeArticleContextId,
      );
      if (handle == null) {
        throw const TtsException(
          ListeningAudioMaterialService.missingMaterialMessage,
        );
      }
      if (!_isActiveListeningPlayback(token)) {
        return;
      }

      final player = AudioPlayer();
      _listeningPlayer = player;
      try {
        await _playAudioFileToEnd(
          player: player,
          path: handle.filePath,
          isActive: () => _isActiveListeningPlayback(token),
        );
      } on TimeoutException {
        if (_isActiveListeningPlayback(token)) {
          throw const TtsException('播放超时，请重试');
        }
      } finally {
        if (_listeningPlayer == player) {
          _listeningPlayer = null;
        }
        try {
          await player.stop().timeout(const Duration(seconds: 2));
        } catch (_) {
          // Best-effort cleanup after playback completes or is cancelled.
        }
        try {
          await player.dispose().timeout(const Duration(seconds: 2));
        } catch (_) {
          // Best-effort cleanup after playback completes or is cancelled.
        }
      }
    } catch (error) {
      if (!_isActiveListeningPlayback(token)) {
        return;
      }
      rethrow;
    }
  }

  Future<void> _playListeningSequence({
    required int articleId,
    required List<Map<String, dynamic>> items,
    required int startIndex,
    required bool singleItem,
  }) async {
    await _stopSongPlayback();
    final cleanItems = items
        .where((item) => (item['english'] ?? '').toString().trim().isNotEmpty)
        .toList(growable: false);
    if (cleanItems.isEmpty) {
      return;
    }

    final token = ++_listeningPlaybackToken;
    _listeningPausedForWord = false;
    await _stopVoicePreview();
    await _disposeListeningPlayer();

    final exactPosition = cleanItems.indexWhere((item) {
      final sentenceIndex = (item['index'] as num?)?.toInt();
      return sentenceIndex == startIndex;
    });
    final safeStart = exactPosition >= 0
        ? exactPosition
        : startIndex.clamp(0, cleanItems.length - 1).toInt();
    final endIndex = singleItem ? safeStart : cleanItems.length - 1;
    final player = AudioPlayer();
    _listeningPlayer = player;
    var currentPlaybackIndex = safeStart;
    final pendingHandles = <int, Future<TtsFileHandle>>{};
    final audioHandlesByText =
        await ListeningAudioMaterialService.cachedFileHandlesByTextForArticle(
      articleId: articleId,
    );

    Future<TtsFileHandle> loadHandleAt(int itemIndex) async {
      final item = cleanItems[itemIndex];
      final english = (item['english'] ?? '').toString().trim();
      final handle =
          ListeningAudioMaterialService.cachedFileHandleFromArticleMap(
        text: english,
        handlesByText: audioHandlesByText,
      );
      if (handle == null) {
        throw const TtsException(
          ListeningAudioMaterialService.missingMaterialMessage,
        );
      }
      return handle;
    }

    void warmHandleAt(int itemIndex) {
      if (itemIndex < safeStart || itemIndex > endIndex) {
        return;
      }
      if (pendingHandles.containsKey(itemIndex)) {
        return;
      }
      final future = loadHandleAt(itemIndex);
      pendingHandles[itemIndex] = future;
      unawaited(future.then<void>((_) {}, onError: (_, __) {}));
    }

    try {
      warmHandleAt(safeStart);
      if (!singleItem) {
        warmHandleAt(safeStart + 1);
      }
      for (var index = safeStart; index <= endIndex; index += 1) {
        if (!_isActiveListeningPlayback(token)) {
          return;
        }
        final item = cleanItems[index];
        final sentenceIndex = (item['index'] as num?)?.toInt() ?? index;
        currentPlaybackIndex = sentenceIndex;
        await _pushEvent('listening.playback', {
          'articleId': articleId,
          'index': sentenceIndex,
          'part': 'english',
          'state': 'partStart',
        });
        final englishHandle =
            await (pendingHandles.remove(index) ?? loadHandleAt(index));
        if (!_isActiveListeningPlayback(token)) {
          return;
        }
        if (!singleItem) {
          warmHandleAt(index + 1);
        }
        await _playAudioFileToEnd(
          player: player,
          path: englishHandle.filePath,
          isActive: () => _isActiveListeningPlayback(token),
        );
      }
      if (_isActiveListeningPlayback(token)) {
        await _pushEvent('listening.playback', {
          'articleId': articleId,
          'index': endIndex,
          'part': null,
          'state': 'completed',
        });
      }
    } catch (error) {
      if (_isActiveListeningPlayback(token)) {
        await _pushEvent('listening.playback', {
          'articleId': articleId,
          'index': currentPlaybackIndex,
          'part': null,
          'state': 'error',
          'error': error.toString(),
        });
      }
      rethrow;
    } finally {
      if (_listeningPlayer == player) {
        _listeningPlayer = null;
      }
      try {
        await player.stop().timeout(const Duration(seconds: 2));
      } catch (_) {
        // Best-effort cleanup after playback completes or is cancelled.
      }
      try {
        await player.dispose().timeout(const Duration(seconds: 2));
      } catch (_) {
        // Best-effort cleanup after playback completes or is cancelled.
      }
    }
  }

  Future<String> _cachedListeningPath({
    required String text,
    required String voiceType,
    required bool preferRequestedVoice,
    String cachePurpose = 'listening_tts',
  }) {
    final key =
        '${cachePurpose}_${voiceType}_${preferRequestedVoice}_${_stableTextHash(text)}';
    final pending = _listeningTtsPathFutures[key];
    if (pending != null) {
      return pending;
    }

    final future = () async {
      final path = await TtsService.synthesizeToCachedFile(
        text: text,
        voiceType: voiceType,
        preferRequestedVoice: preferRequestedVoice,
        articleId: _activeArticleContextId,
        cachePurpose: cachePurpose,
      );
      return path;
    }();

    _listeningTtsPathFutures[key] = future;
    unawaited(future.whenComplete(() {
      _listeningTtsPathFutures.remove(key);
    }));
    return future;
  }

  Future<Map<String, dynamic>> _refreshEditedListeningAudio({
    required int articleId,
    required String oldEnglish,
    required String newEnglish,
    required bool refreshEnglish,
    required bool refreshChinese,
    required bool synthesizeEnglish,
  }) async {
    final errors = <String>[];
    var englishStatus = refreshEnglish ? 'pending' : 'unchanged';
    final chineseStatus = refreshChinese ? 'disabled' : 'unchanged';

    if (refreshEnglish) {
      try {
        await _evictListeningTtsForText(
          articleId: articleId,
          text: oldEnglish,
          deleteDiskCache: true,
        );
        await _evictListeningTtsForText(
          articleId: articleId,
          text: newEnglish,
          deleteDiskCache: true,
        );
        if (synthesizeEnglish && newEnglish.trim().isNotEmpty) {
          await TtsMemoryCacheService.loadFile(
            text: newEnglish,
            voiceType: TtsService.defaultVoiceType,
            preferRequestedVoice: false,
            articleId: articleId,
            cachePurpose: 'listening_tts',
            forceRefresh: true,
          );
          englishStatus = 'ready';
        } else if (newEnglish.trim().isEmpty) {
          englishStatus = 'cleared';
        } else {
          englishStatus = 'missing';
        }
      } catch (error) {
        englishStatus = 'error';
        errors.add('英文语音合成失败：$error');
      }
    }

    return {
      'status': errors.isEmpty
          ? englishStatus == 'missing'
              ? 'missing'
              : englishStatus == 'cleared'
                  ? 'ready'
                  : 'ready'
          : 'error',
      'english': englishStatus,
      'chinese': chineseStatus,
      'error': errors.join('\n'),
    };
  }

  Future<void> _evictListeningTtsForText({
    required int articleId,
    required String text,
    required bool deleteDiskCache,
  }) async {
    if (text.trim().isEmpty) {
      return;
    }
    await TtsMemoryCacheService.evictForText(
      text: text,
      voiceType: TtsService.defaultVoiceType,
      preferRequestedVoice: false,
      articleId: articleId,
      cachePurpose: 'listening_tts',
      deleteDiskCache: deleteDiskCache,
    );
  }

  Future<void> _playSongFile({
    required int articleId,
    required String path,
    required ArticleSongState state,
    String? versionId,
    String? timelinePath,
    int? startLineIndex,
  }) async {
    final token = ++_songPlaybackToken;
    await _stopListeningPlayback();
    await _stopVoicePreview();
    await _disposeSongPlayer();

    final player = AudioPlayer();
    _songPlayer = player;
    try {
      SongSubtitleTimeline? timeline;
      final normalizedTimelinePath = (timelinePath ?? '').trim();
      if (normalizedTimelinePath.isNotEmpty) {
        try {
          timeline = await SongSubtitleTimelineService.readTimeline(
            normalizedTimelinePath,
          );
        } catch (error) {
          TomatoLogger.warn(
            category: 'listening',
            event: 'song.play.timeline_unavailable',
            articleId: articleId,
            error: error,
            data: {
              'versionId': versionId,
              'timelinePath': normalizedTimelinePath,
            },
          );
        }
      }
      final startPosition = _songStartPositionForLine(
        timeline: timeline,
        startLineIndex: startLineIndex,
      );
      await player.setFilePath(path).timeout(const Duration(seconds: 10));
      await player.seek(startPosition).timeout(const Duration(seconds: 3));
      await player.setVolume(1.0);
      await _pushEvent(
        'listening.song.state',
        state.copyWith(status: 'playing').toJson(),
      );
      TomatoLogger.info(
        category: 'listening',
        event: 'song.play.start',
        articleId: articleId,
        data: {
          'versionId': versionId,
          'audioPath': path,
          'durationMs': player.duration?.inMilliseconds ?? timeline?.durationMs,
          'timelinePath': timelinePath,
          'timelineCueCount': timeline?.cues.length,
          'startLineIndex': startLineIndex,
          'startPositionMs': startPosition.inMilliseconds,
        },
      );

      late StreamSubscription<PlayerState> stateSubscription;
      StreamSubscription<Duration>? positionSubscription;
      int? lastLoggedCueLineIndex;
      stateSubscription = player.playerStateStream.listen((event) {
        if (!_isActiveSongPlayback(token)) {
          unawaited(stateSubscription.cancel());
          unawaited(positionSubscription?.cancel());
          return;
        }
        if (event.processingState == ProcessingState.completed) {
          TomatoLogger.info(
            category: 'listening',
            event: 'song.play.completed',
            articleId: articleId,
            data: {
              'versionId': versionId,
              'positionMs': player.position.inMilliseconds,
              'durationMs': player.duration?.inMilliseconds,
              'timelineCueCount': timeline?.cues.length,
              'lastCueLineIndex': lastLoggedCueLineIndex,
            },
          );
          unawaited(stateSubscription.cancel());
          unawaited(positionSubscription?.cancel());
          unawaited(_pushEvent('listening.song.state', state.toJson()));
          unawaited(_pushEvent('listening.song.position', {
            'articleId': articleId,
            'versionId': versionId,
            'positionMs': player.duration?.inMilliseconds ?? 0,
            'durationMs': player.duration?.inMilliseconds,
            'cue': null,
          }));
          unawaited(_disposeSongPlayer());
        }
      });
      final currentTimeline = timeline;
      if (currentTimeline != null) {
        DateTime lastPush = DateTime.fromMillisecondsSinceEpoch(0);
        positionSubscription = player.positionStream.listen((position) {
          if (!_isActiveSongPlayback(token)) {
            unawaited(positionSubscription?.cancel());
            return;
          }
          final now = DateTime.now();
          if (now.difference(lastPush).inMilliseconds < 120) {
            return;
          }
          lastPush = now;
          final positionMs = position.inMilliseconds;
          final cue = SongSubtitleTimelineService.cueAtPosition(
            currentTimeline,
            positionMs,
          );
          if (cue != null && cue.lineIndex != lastLoggedCueLineIndex) {
            lastLoggedCueLineIndex = cue.lineIndex;
            TomatoLogger.info(
              category: 'listening',
              event: 'song.play.cue',
              articleId: articleId,
              data: {
                'versionId': versionId,
                'positionMs': positionMs,
                'lineIndex': cue.lineIndex,
                'cueStartMs': cue.startMs,
                'cueEndMs': cue.endMs,
              },
            );
          }
          unawaited(_pushEvent('listening.song.position', {
            'articleId': articleId,
            'versionId': versionId,
            'positionMs': positionMs,
            'durationMs':
                player.duration?.inMilliseconds ?? currentTimeline.durationMs,
            'cue': cue?.toJson(),
          }));
        });
      }
      unawaited(player.play().catchError((Object error) async {
        if (!_isActiveSongPlayback(token)) {
          return;
        }
        TomatoLogger.error(
          category: 'listening',
          event: 'song.play.error',
          articleId: articleId,
          error: error,
          data: {
            'versionId': versionId,
            'audioPath': path,
          },
        );
        final message = _displayError(error);
        await _pushSongState(
          articleId,
          statusOverride: 'error',
          errorMessageOverride: message,
          stylePromptOverride: state.stylePrompt,
        );
        await _disposeSongPlayer();
      }));
    } catch (error) {
      if (_isActiveSongPlayback(token)) {
        await _disposeSongPlayer();
      }
      TomatoLogger.error(
        category: 'listening',
        event: 'song.play.start_failed',
        articleId: articleId,
        error: error,
        data: {
          'versionId': versionId,
          'audioPath': path,
        },
      );
      rethrow;
    }
  }

  Duration _songStartPositionForLine({
    required SongSubtitleTimeline? timeline,
    required int? startLineIndex,
  }) {
    final lineIndex = startLineIndex;
    if (lineIndex == null || lineIndex <= 0) {
      return Duration.zero;
    }
    if (timeline == null) {
      throw FormatException(
        '歌曲还没有可用字幕时间线，无法从第 ${lineIndex + 1} 句开始播放',
      );
    }
    final startMs = SongSubtitleTimelineService.startMsForLineIndex(
      timeline,
      lineIndex,
    );
    if (startMs == null) {
      throw FormatException(
        '歌曲字幕时间线中没有找到第 ${lineIndex + 1} 句歌词时间，请重新生成歌曲字幕',
      );
    }
    return Duration(milliseconds: startMs);
  }

  Future<void> _playVoicePreview(
    String speakerId, {
    String? provider,
  }) async {
    final token = ++_previewPlaybackToken;
    await _stopListeningPlayback();
    await _stopSongPlayback();
    await _disposePreviewPlayer();

    final previewText = _voicePreviewTextFor(speakerId);
    try {
      final path = await TtsService.synthesizeToCachedFile(
        text: previewText,
        voiceType: speakerId,
        preferRequestedVoice: true,
        cachePurpose: 'voice_preview',
        aiProviderOverride: provider,
      );
      if (!_isActiveVoicePreview(token)) {
        return;
      }

      final player = AudioPlayer();
      _previewPlayer = player;
      try {
        await _playAudioFileToEnd(
          player: player,
          path: path,
          isActive: () => _isActiveVoicePreview(token),
        );
      } on TimeoutException {
        if (_isActiveVoicePreview(token)) {
          throw const TtsException('播放超时，请重试');
        }
      } finally {
        if (_previewPlayer == player) {
          _previewPlayer = null;
        }
        try {
          await player.stop().timeout(const Duration(seconds: 2));
        } catch (_) {
          // Best-effort cleanup after playback completes or is cancelled.
        }
        try {
          await player.dispose().timeout(const Duration(seconds: 2));
        } catch (_) {
          // Best-effort cleanup after playback completes or is cancelled.
        }
      }
    } catch (error) {
      if (!_isActiveVoicePreview(token)) {
        return;
      }
      rethrow;
    }
  }

  Future<void> _playWordPronunciation(String word) async {
    final token = ++_previewPlaybackToken;
    await _stopSongPlayback();
    await _disposePreviewPlayer();

    try {
      final path = await _cachedListeningPath(
        text: word,
        voiceType: TtsService.defaultVoiceType,
        preferRequestedVoice: true,
        cachePurpose: 'word_pronunciation',
      );
      if (!_isActiveVoicePreview(token)) {
        return;
      }

      final player = AudioPlayer();
      _previewPlayer = player;
      try {
        await _playAudioFileToEnd(
          player: player,
          path: path,
          isActive: () => _isActiveVoicePreview(token),
        );
      } on TimeoutException {
        if (_isActiveVoicePreview(token)) {
          throw const TtsException('播放超时，请重试');
        }
      } finally {
        if (_previewPlayer == player) {
          _previewPlayer = null;
        }
        try {
          await player.stop().timeout(const Duration(seconds: 2));
        } catch (_) {
          // Best-effort cleanup after playback completes or is cancelled.
        }
        try {
          await player.dispose().timeout(const Duration(seconds: 2));
        } catch (_) {
          // Disposal is best effort; a fresh player is created for each segment.
        }
      }
    } catch (error) {
      if (!_isActiveVoicePreview(token)) {
        return;
      }
      rethrow;
    }
  }

  Future<void> _playAudioFileToEnd({
    required AudioPlayer player,
    required String path,
    required bool Function() isActive,
  }) =>
      _playAudioSourceToEnd(
        player: player,
        source: AudioSource.file(path),
        isActive: isActive,
      );

  Future<void> _playAudioSourceToEnd({
    required AudioPlayer player,
    required AudioSource source,
    required bool Function() isActive,
  }) async {
    final playbackStarted = Completer<void>();
    final playbackDone = Completer<void>();
    StreamSubscription<PlayerState>? stateSub;
    StreamSubscription<Duration>? positionSub;
    StreamSubscription<PlaybackEvent>? playbackEventSub;
    Timer? durationFallbackTimer;
    var playCommandIssued = false;
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
            if (isActive()) {
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
      await player.setVolume(1.0);
      mediaDuration = player.duration;

      stateSub = player.playerStateStream.listen((event) {
        if (!isActive()) {
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
        if (!isActive()) {
          completeDone();
          return;
        }
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
          if (isActive()) {
            completeError(error, stackTrace);
          }
        },
      );

      final playFuture = player.play();
      playCommandIssued = true;
      unawaited(playFuture.catchError(completeError));

      await playbackStarted.future.timeout(const Duration(seconds: 6));
      if (!isActive()) {
        return;
      }
      await playbackDone.future
          .timeout(_listeningPlaybackTimeout(mediaDuration));
    } finally {
      durationFallbackTimer?.cancel();
      await stateSub?.cancel();
      await positionSub?.cancel();
      await playbackEventSub?.cancel();
    }
  }

  Future<void> _stopListeningPlayback() async {
    _listeningPlaybackToken++;
    _listeningPausedForWord = false;
    await _disposeListeningPlayer();
  }

  Future<void> _stopVoicePreview() async {
    _previewPlaybackToken++;
    await _disposePreviewPlayer();
  }

  Future<void> _stopSongPlayback() async {
    _songPlaybackToken++;
    await _disposeSongPlayer();
  }

  Future<void> _disposeListeningPlayer() async {
    final player = _listeningPlayer;
    _listeningPlayer = null;
    _listeningPausedForWord = false;
    if (player == null) {
      _scheduleMainWebViewFrameRateLimit();
      return;
    }

    try {
      await player.stop().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Stopping an already-finished player is harmless.
    }
    try {
      await player.dispose().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Disposal is best effort; a fresh player is created for each segment.
    }
    _scheduleMainWebViewFrameRateLimit();
  }

  Future<void> _disposePreviewPlayer() async {
    final player = _previewPlayer;
    _previewPlayer = null;
    if (player == null) {
      _scheduleMainWebViewFrameRateLimit();
      return;
    }

    try {
      await player.stop().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Stopping an already-finished player is harmless.
    }
    try {
      await player.dispose().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Disposal is best effort; a fresh player is created for each preview.
    }
    _scheduleMainWebViewFrameRateLimit();
  }

  Future<void> _disposeSongPlayer() async {
    final player = _songPlayer;
    _songPlayer = null;
    if (player == null) {
      _scheduleMainWebViewFrameRateLimit();
      return;
    }

    try {
      await player.stop().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Stopping an already-finished song is harmless.
    }
    try {
      await player.dispose().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Disposal is best effort; a fresh player is created for each song.
    }
    _scheduleMainWebViewFrameRateLimit();
  }

  bool _isActiveListeningPlayback(int token) =>
      token == _listeningPlaybackToken;

  bool _isActiveVoicePreview(int token) => token == _previewPlaybackToken;

  bool _isActiveSongPlayback(int token) => token == _songPlaybackToken;

  String _voicePreviewTextFor(String speakerId) {
    if (speakerId.startsWith('zh_')) {
      return _chineseVoicePreviewText;
    }
    return _englishVoicePreviewText;
  }

  Duration _listeningPlaybackTimeout(Duration? duration) {
    if (duration == null || duration <= Duration.zero) {
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

  String _displayError(Object error) {
    if (error is FormatException) {
      return error.message;
    }
    final text = error.toString().trim();
    return text.replaceFirst(RegExp(r'^Exception:\s*'), '');
  }

  int _stableTextHash(String text) {
    var hash = 0x811c9dc5;
    for (final codeUnit in text.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toUnsigned(32);
  }

  bool _containsChinese(String text) =>
      RegExp(r'[\u3400-\u9FFF]').hasMatch(text);

  int? get _activeArticleContextId =>
      _activeFollowArticleId ??
      _activeListeningArticleId ??
      _activeChatArticleId;

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
      final article = await _articleWithPersistedSentences(originalArticle);
      final id = article.id;
      final averageScore =
          id == null ? 0.0 : await DatabaseService.getAverageScore(id);
      articlePayloads.add(
        await _articleJsonWithStory(article, averageScore: averageScore),
      );
    }
    final seriesPayload = await _storySeriesListPayload();
    return {
      'articles': articlePayloads,
      'series': seriesPayload['series'],
    };
  }

  Future<Map<String, dynamic>> _storySeriesListPayload() async {
    final series = await DatabaseService.getStorySeries();
    return {
      'series': series.map((item) => item.toJson()).toList(growable: false),
    };
  }

  Future<Map<String, dynamic>> _articleJsonWithStory(
    Article article, {
    double averageScore = 0,
  }) async {
    final json = _articleJson(article, averageScore: averageScore);
    final articleId = article.id;
    if (articleId == null) {
      return json;
    }

    final chapter = await DatabaseService.getStoryChapterForArticle(articleId);
    if (chapter == null) {
      json['pictureBookEnabled'] = false;
      return json;
    }
    final series = await DatabaseService.getStorySeriesById(chapter.seriesId);
    json['pictureBookEnabled'] = true;
    json['seriesId'] = chapter.seriesId;
    json['seriesTitle'] = series?.title ?? '';
    json['seriesDescription'] = series?.description ?? '';
    json['chapterOrder'] = chapter.chapterOrder;
    json['chapterDescription'] = _storyChapterDescription(chapter.summaryJson);
    final coverPayload =
        await PictureBookService.coverImagePayloadForArticle(articleId);
    if (coverPayload != null) {
      json.addAll(coverPayload);
    }
    return json;
  }

  String _storyChapterDescription(String summaryJson) {
    final summary = _decodeJsonObject(summaryJson);
    return summary['chapterDescription']?.toString().trim() ?? '';
  }

  Future<StorySeries> _resolveStorySeries({
    required int? requestedSeriesId,
    required String requestedSeriesTitle,
    required String requestedSeriesDescription,
    required List<BookCharacter> requestedSeriesCharacters,
    required bool requestedSeriesCharactersProvided,
  }) async {
    if (requestedSeriesId != null) {
      final series =
          await DatabaseService.getStorySeriesById(requestedSeriesId);
      if (series != null) {
        final description = requestedSeriesDescription.trim();
        final characters = requestedSeriesCharacters;
        if ((description.isNotEmpty && description != series.description) ||
            requestedSeriesCharactersProvided) {
          final updated = series.copyWith(
            description:
                description.isNotEmpty ? description : series.description,
            characters: requestedSeriesCharactersProvided
                ? characters
                : series.characters,
            updatedAt: DateTime.now(),
          );
          await DatabaseService.updateStorySeries(updated);
          return updated;
        }
        return series;
      }
    }

    final title = requestedSeriesTitle.trim();
    if (title.isEmpty) {
      throw const FormatException('请填写书籍名称');
    }
    final existingSeries = await DatabaseService.getStorySeries();
    for (final series in existingSeries) {
      if (series.title.trim().toLowerCase() == title.trim().toLowerCase()) {
        final description = requestedSeriesDescription.trim();
        final characters = requestedSeriesCharacters;
        if ((description.isNotEmpty && description != series.description) ||
            requestedSeriesCharactersProvided) {
          final updated = series.copyWith(
            description:
                description.isNotEmpty ? description : series.description,
            characters: requestedSeriesCharactersProvided
                ? characters
                : series.characters,
            updatedAt: DateTime.now(),
          );
          await DatabaseService.updateStorySeries(updated);
          return updated;
        }
        return series;
      }
    }

    return PictureBookService.createSeries(
      title: title,
      description: requestedSeriesDescription,
      characters: requestedSeriesCharacters,
    );
  }

  Future<StorySeries> _ensureStorySeriesDescription({
    required StorySeries series,
    required Article article,
  }) async {
    final seriesId = series.id;
    if (seriesId == null || series.description.trim().isNotEmpty) {
      return series;
    }
    final suggestion = await PictureBookService.suggestBookDescription(
      article: article,
      seriesTitle: series.title,
      currentDescription: series.description,
      currentCharacters: series.characters,
    );
    final trimmed = suggestion.description.trim();
    if (trimmed.isEmpty) {
      return series;
    }
    final updated = series.copyWith(
      description: trimmed,
      characters: suggestion.characters.isNotEmpty
          ? suggestion.characters
          : series.characters,
      updatedAt: DateTime.now(),
    );
    await DatabaseService.updateStorySeries(updated);
    return updated;
  }

  Future<String> _resolveArticleTitle(
      String requestedTitle, String englishContent,
      {String titleCandidate = ''}) async {
    final normalizedRequested =
        _normalizeEnglishWordJoiners(requestedTitle).trim();
    if (normalizedRequested.isNotEmpty) {
      return normalizedRequested.length > 80
          ? normalizedRequested.substring(0, 80)
          : normalizedRequested;
    }

    final normalizedCandidate =
        _normalizeEnglishWordJoiners(titleCandidate).trim();
    if (normalizedCandidate.isNotEmpty) {
      return normalizedCandidate.length > 80
          ? normalizedCandidate.substring(0, 80)
          : normalizedCandidate;
    }

    final reply = await PracticeTextService.suggestArticleTitle(
      content: englishContent,
    );
    final generated = _normalizeEnglishWordJoiners(reply.text.trim());
    if (generated.isEmpty) {
      throw const TextGenerationException('标题生成失败：AI 未返回有效标题，请重试。');
    }
    return generated.length > 80 ? generated.substring(0, 80) : generated;
  }

  Future<void> _saveArticleTranslationsAtCreate({
    required int articleId,
    required List<String> sentences,
    required ParsedPracticeInput parsedInput,
  }) async {
    if (sentences.isEmpty) {
      return;
    }

    final createdAt = DateTime.now();
    final rowsByIndex = <int, ArticleSentenceTranslation>{};
    if (parsedInput.sourceKind == PracticeInputSourceKind.standardBilingual) {
      for (final row in parsedInput.buildSentenceTranslations(
        articleId: articleId,
        sentences: sentences,
        now: createdAt,
      )) {
        rowsByIndex[row.sentenceIndex] = row;
      }
    }

    final missingSentences = <int, String>{
      for (var index = 0; index < sentences.length; index += 1)
        if (!rowsByIndex.containsKey(index)) index: sentences[index],
    };
    if (missingSentences.isNotEmpty) {
      final batch = await PracticeTextService.translateSentencesToChineseStrict(
        sentencesByIndex: missingSentences,
        articleId: articleId,
      );
      for (final entry in batch.translationsByIndex.entries) {
        rowsByIndex[entry.key] = ArticleSentenceTranslation(
          articleId: articleId,
          sentenceIndex: entry.key,
          englishSentence: sentences[entry.key],
          chineseText: entry.value,
          source: 'generated_batch_at_create',
          createdAt: createdAt,
          updatedAt: createdAt,
        );
      }
    }

    final rows = rowsByIndex.values.toList(growable: false)
      ..sort((a, b) => a.sentenceIndex.compareTo(b.sentenceIndex));
    if (rows.isNotEmpty) {
      await DatabaseService.saveArticleSentenceTranslations(articleId, rows);
    }
  }

  Future<String> _englishPracticeContent(
    String content, {
    int? articleId,
    ParsedPracticeInput? parsedInput,
    bool strictAi = false,
  }) async {
    final parsed = parsedInput ?? PracticeInputParser.parse(content);
    if (parsed.usesLocalEnglish) {
      return parsed.englishContent;
    }

    final trimmed = _normalizeEnglishWordJoiners(content.trim());
    if (trimmed.isEmpty) {
      return trimmed;
    }

    try {
      final reply = strictAi
          ? await PracticeTextService.translateToEnglishForPracticeStrict(
              content: trimmed,
              articleId: articleId,
            )
          : await PracticeTextService.translateToEnglishForPractice(
              content: trimmed,
              articleId: articleId,
            );
      final translated = _normalizeEnglishWordJoiners(reply.text.trim());
      if (strictAi && translated.isEmpty) {
        throw const TextGenerationException(
          '文本提交处理失败：AI 未返回可保存的英文正文，请重试。',
        );
      }
      return translated.isEmpty ? trimmed : translated;
    } catch (error) {
      if (strictAi) {
        rethrow;
      }
      TomatoLogger.warn(
        category: 'article',
        event: 'translate_to_english.failed',
        error: error,
      );
      return trimmed;
    }
  }

  Future<Article> _articleWithPersistedSentences(Article article) async {
    final storedSentences = article.sentences
        .map((sentence) => sentence.trim())
        .toList(growable: false);
    if (storedSentences.isNotEmpty) {
      return article.copyWith(sentences: storedSentences);
    }

    // Incomplete rows get an in-memory fallback only. Read/open/status paths
    // must never rewrite article content or sentence boundaries.
    final content = _normalizeEnglishWordJoiners(article.content);
    final fallback = NlpService.splitSentences(content);
    if (fallback.isEmpty) {
      return article;
    }
    return article.copyWith(content: content, sentences: fallback);
  }

  String _contentWithUpdatedSentence({
    required String content,
    required String oldSentence,
    required String newSentence,
    required List<String> sentences,
  }) {
    final oldText = oldSentence.trim();
    final newText = newSentence.trim();
    if (newText.isEmpty) {
      return rebuildArticleContentFromSentences(sentences);
    }
    if (oldText.isEmpty) {
      return rebuildArticleContentFromSentences(sentences);
    }

    final directIndex = content.indexOf(oldText);
    if (directIndex >= 0) {
      return content.replaceRange(
        directIndex,
        directIndex + oldText.length,
        newText,
      );
    }

    final normalizedContent = _normalizeEnglishWordJoiners(content);
    final normalizedIndex = normalizedContent.indexOf(oldText);
    if (normalizedIndex >= 0) {
      return normalizedContent.replaceRange(
        normalizedIndex,
        normalizedIndex + oldText.length,
        newText,
      );
    }

    return sentences.map((sentence) => sentence.trim()).join(' ');
  }

  static String _normalizeEnglishWordJoiners(String text) =>
      text.replaceAllMapped(
        RegExp(r'([A-Za-z])\s*-\s*([A-Za-z])'),
        (match) {
          final left = match.group(1);
          final right = match.group(2);
          if (left == null || right == null) {
            return match.group(0) ?? '';
          }
          return '$left-$right';
        },
      );

  static String _normalizeLookupWord(String word) => word
      .replaceAll(RegExp(r'[‘’]'), "'")
      .replaceAll(RegExp(r'^[^A-Za-z]+|[^A-Za-z]+$'), '')
      .trim();

  Future<RecordingExportRequest> _recordingRequestFromPayload(
    Map<String, dynamic> payload,
  ) async {
    final settings = await RecordingExportService.settingsPayload();
    final articleId =
        _payloadOptionalInt(payload, 'articleId') ?? _activeListeningArticleId;
    if (articleId == null) {
      throw const FormatException('听力任务尚未打开');
    }
    final codecText = _payloadString(
      payload,
      'codec',
      fallback: settings['codec']?.toString() ?? 'h264',
    ).trim();
    final resolutionText = _payloadString(
      payload,
      'resolution',
      fallback: settings['resolution']?.toString() ?? '1920x1080',
    ).trim();
    final transitionText = _payloadString(
      payload,
      'pageTransition',
      fallback: settings['pageTransition']?.toString() ?? 'none',
    ).trim();
    final subtitleModeText = _payloadString(
      payload,
      'subtitleMode',
      fallback: settings['subtitleMode']?.toString() ?? 'srt',
    ).trim();
    final fps = _payloadOptionalInt(payload, 'fps') ??
        (settings['fps'] is num
            ? (settings['fps'] as num).toInt()
            : RecordingExportService.defaultFps);
    final subtitleTranslations = _payloadSubtitleTranslations(payload);
    return RecordingExportRequest(
      articleId: articleId,
      mode: 'english',
      codec: codecText == 'h265' || codecText == 'hevc'
          ? RecordingCodec.h265
          : RecordingCodec.h264,
      resolution: RecordingResolution.parse(resolutionText),
      pageTransition: RecordingPageTransition.parse(transitionText),
      subtitleMode: RecordingSubtitleMode.parse(subtitleModeText),
      fps: fps <= 0 ? RecordingExportService.defaultFps : fps,
      subtitleTranslations: subtitleTranslations,
    );
  }

  Future<SongRecordingExportRequest> _songRecordingRequestFromPayload(
    Map<String, dynamic> payload,
  ) async {
    final settings = await RecordingExportService.settingsPayload();
    final articleId =
        _payloadOptionalInt(payload, 'articleId') ?? _activeListeningArticleId;
    if (articleId == null) {
      throw const FormatException('听力任务尚未打开');
    }
    final version = await _selectedSongVersion(
      articleId: articleId,
      versionId: _payloadString(payload, 'versionId').trim(),
    );
    final timelinePath = (version.timelinePath ?? '').trim();
    final timelineStatus = _versionTimelineStatus(version);
    if (timelineStatus == 'stale') {
      throw const FormatException(
        SongSubtitleTimelineService.staleTimelineMessage,
      );
    }
    if (timelineStatus != 'ready' || timelinePath.isEmpty) {
      throw const FormatException('请先生成这首歌的字幕时间线');
    }
    if (!await SongSubtitleTimelineService.timelineFileIsCurrent(
      timelinePath,
    )) {
      throw const FormatException(
        SongSubtitleTimelineService.staleTimelineMessage,
      );
    }
    final codecText = _payloadString(
      payload,
      'codec',
      fallback: settings['codec']?.toString() ?? 'h264',
    ).trim();
    final resolutionText = _payloadString(
      payload,
      'resolution',
      fallback: settings['resolution']?.toString() ?? '1920x1080',
    ).trim();
    final transitionText = _payloadString(
      payload,
      'pageTransition',
      fallback: settings['pageTransition']?.toString() ?? 'none',
    ).trim();
    final subtitleModeText = _payloadString(
      payload,
      'subtitleMode',
      fallback: settings['subtitleMode']?.toString() ?? 'srt',
    ).trim();
    final fps = _payloadOptionalInt(payload, 'fps') ??
        (settings['fps'] is num
            ? (settings['fps'] as num).toInt()
            : RecordingExportService.defaultFps);
    return SongRecordingExportRequest(
      articleId: articleId,
      audioPath: version.audioPath,
      timelinePath: timelinePath,
      codec: codecText == 'h265' || codecText == 'hevc'
          ? RecordingCodec.h265
          : RecordingCodec.h264,
      resolution: RecordingResolution.parse(resolutionText),
      pageTransition: RecordingPageTransition.parse(transitionText),
      subtitleMode: RecordingSubtitleMode.parse(subtitleModeText),
      fps: fps <= 0 ? RecordingExportService.defaultFps : fps,
    );
  }

  Future<void> _openWithSystemPlayer(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FormatException('视频文件不存在：$filePath');
    }
    if (Platform.isWindows) {
      await Process.start('cmd', ['/c', 'start', '', file.path]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('open', [file.path]);
      return;
    }
    if (Platform.isLinux) {
      await Process.start('xdg-open', [file.path]);
      return;
    }
    throw const FormatException('当前平台不支持调用系统播放器');
  }

  Future<void> _openWithSystemFileManager(String directoryPath) async {
    final directory = Directory(directoryPath);
    if (!await directory.exists()) {
      throw FormatException('目录不存在：$directoryPath');
    }
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [directory.path]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('open', [directory.path]);
      return;
    }
    if (Platform.isLinux) {
      await Process.start('xdg-open', [directory.path]);
      return;
    }
    throw const FormatException('当前平台不支持打开文件管理器');
  }

  Map<int, String> _payloadSubtitleTranslations(Map<String, dynamic> payload) {
    final raw = payload['subtitleTranslations'];
    if (raw is! List) {
      return const <int, String>{};
    }
    final translations = <int, String>{};
    for (final item in raw) {
      if (item is! Map) {
        continue;
      }
      final indexValue = item['index'];
      final index = indexValue is int
          ? indexValue
          : indexValue is num
              ? indexValue.toInt()
              : int.tryParse(indexValue?.toString() ?? '');
      if (index == null || index < 0) {
        continue;
      }
      final chinese = (item['chinese'] ?? '').toString().trim();
      if (chinese.isNotEmpty) {
        translations[index] = chinese;
      }
    }
    return translations;
  }

  Future<Map<String, dynamic>> _settingsPayload() async {
    final provider = await AppConfig.aiProvider;
    final volcSpeakerId = await AppConfig.volcTtsSpeakerId;
    final resolvedVolcSpeakerId = TtsService.isPresetVoice(volcSpeakerId)
        ? volcSpeakerId.trim()
        : TtsService.defaultVoiceType;
    final aliyunVoice = await AppConfig.aliyunBailianTtsVoice;
    final resolvedAliyunVoice = aliyunVoice.trim().isNotEmpty
        ? aliyunVoice.trim()
        : TtsService.defaultAliyunVoiceType;
    final activeSpeakerId = provider == AppConfig.aiProviderAliyunBailian
        ? resolvedAliyunVoice
        : resolvedVolcSpeakerId;
    final songSettings = await _songSettingsPayload();
    return {
      'tts': {
        'resourceId': provider == AppConfig.aiProviderAliyunBailian
            ? await AppConfig.aliyunBailianTtsModel
            : await AppConfig.volcTtsResourceId,
        'speakerId': activeSpeakerId,
      },
      'song': songSettings,
      'cloud': await AppConfig.cloudSettingsPayload(),
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
      'voiceCatalog': {
        'aliyunBailian': TtsService.aliyunVoices
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
        'volcengine': TtsService.voices
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
      },
      'contentSafety': {
        'rules': await ContentSafetyService.listRules(),
      },
    };
  }

  Future<Map<String, dynamic>> _songSettingsPayload() async {
    final settings = await AppConfig.songSettings;
    final rawOutputDirectory = (settings['sunoOutputDirectory'] ?? '').trim();
    final timeout =
        int.tryParse((settings['sunoTimeoutMinutes'] ?? '').trim()) ?? 20;
    if (rawOutputDirectory.isNotEmpty &&
        AssetPathService.isTemporaryAssetDirectory(
          rawOutputDirectory,
          baseDirectory: AssetPathService.programDirectory(),
        )) {
      final defaultSetting = _defaultSunoOutputDirectorySetting();
      final outputDirectory = _resolveSunoOutputDirectory(defaultSetting);
      await AppConfig.saveSongSettings(
        sunoOutputDirectory: '',
        sunoTimeoutMinutes: timeout,
      );
      TomatoLogger.warn(
        category: 'suno',
        event: 'asset_directory.temporary_setting_ignored',
        data: {
          'configuredDirectory': rawOutputDirectory,
          'resolvedDirectory': outputDirectory,
        },
      );
      return {
        'sunoOutputDirectory': defaultSetting,
        'resolvedSunoOutputDirectory': outputDirectory,
        'sunoTimeoutMinutes': timeout.clamp(5, 120),
        'songProvider':
            settings['songProvider'] ?? AppConfig.defaultSongProvider,
      };
    }
    final defaultSetting = _defaultSunoOutputDirectorySetting();
    final configured = rawOutputDirectory.isEmpty ||
            _isDefaultSunoOutputDirectory(rawOutputDirectory)
        ? defaultSetting
        : rawOutputDirectory;
    final outputDirectory = _resolveSunoOutputDirectory(configured);
    return {
      'sunoOutputDirectory': configured,
      'resolvedSunoOutputDirectory': outputDirectory,
      'sunoTimeoutMinutes': timeout.clamp(5, 120),
      'songProvider': settings['songProvider'] ?? AppConfig.defaultSongProvider,
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
          'visibleSentenceCount': state.visibleSentenceTotal,
          'currentSentence': state.currentSentence,
          'currentTranslation': state.currentTranslation,
          'isLastSentence': state.isLastSentence,
          'step': state.step.name,
          'playbackState': state.playbackState.name,
          'playbackError': state.playbackError,
          'result': _pronunciationResultJson(state.lastResult),
          'hasRecording': state.lastRecordingPath != null,
          'liveRecognizedText': state.liveRecognizedText,
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
      'isChapterComplete': state.isChapterComplete,
      'abilityLevel': state.abilityLevel,
      'practiceSummary': state.practiceSummary,
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
      'visibleSentenceCount': visibleSentenceCount(article.sentences),
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
    await _applyMainWebViewFpsLimit(_mainWebViewActiveFpsLimit);
    await _controller!.evaluateJavascript(
      source:
          'window.__tomatoNativeEvent && window.__tomatoNativeEvent($encoded);',
    );
    _scheduleMainWebViewFrameRateLimit();
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
    return _runWithMainWebViewFrameRateActive(() async {
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
    });
  }

  Future<Uint8List> _qaScreenshot() async {
    return _runWithMainWebViewFrameRateActive(() async {
      final bytes = await _requireWebController().takeScreenshot();
      if (bytes == null || bytes.isEmpty) {
        throw StateError('WebView screenshot is empty');
      }
      return bytes;
    });
  }

  Future<Map<String, dynamic>> _qaClick(Map<String, dynamic> payload) async {
    return _runWithMainWebViewFrameRateActive(() async {
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
    });
  }

  Future<Map<String, dynamic>> _qaFill(Map<String, dynamic> payload) async {
    return _runWithMainWebViewFrameRateActive(() async {
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
    });
  }

  Future<Map<String, dynamic>> _qaSnapshot() async {
    return _runWithMainWebViewFrameRateActive(() async {
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
  const activeElement = document.activeElement;
  const activeControl = activeElement && activeElement !== document.body
    ? {
        tag: activeElement.tagName.toLowerCase(),
        id: activeElement.id || '',
        className: String(activeElement.className || ''),
        value: 'value' in activeElement ? String(activeElement.value || '').slice(0, 240) : ''
      }
    : null;
  const pictureBookScene = (() => {
    const scene = document.querySelector('.picture-book-scene');
    if (!scene) return null;
    const image = scene.querySelector('img');
    const placeholder = scene.querySelector('.picture-book-placeholder');
    const retry = scene.querySelector('.picture-book-retry');
    const badge = scene.querySelector('.picture-book-page-badge');
    const subtitles = scene.querySelector('.picture-book-subtitles');
    return {
      className: String(scene.className || ''),
      ready: scene.classList.contains('ready'),
      busy: scene.classList.contains('busy'),
      failed: scene.classList.contains('failed'),
      placeholderText: (placeholder?.textContent || '').trim().replace(/\\s+/g, ' '),
      retryText: (retry?.textContent || '').trim().replace(/\\s+/g, ' '),
      hasRetry: Boolean(retry),
      badgeText: (badge?.textContent || '').trim(),
      image: image
        ? {
            src: image.getAttribute('src') || '',
            currentSrc: image.currentSrc || '',
            complete: image.complete,
            naturalWidth: image.naturalWidth,
            naturalHeight: image.naturalHeight,
            rect: rectOf(image)
          }
        : null,
      subtitles: {
        english: (subtitles?.querySelector('h1')?.textContent || '').trim().replace(/\\s+/g, ' '),
        chinese: (subtitles?.querySelector('p')?.textContent || '').trim().replace(/\\s+/g, ' ')
      },
      rect: rectOf(scene)
    };
  })();
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
    activeElement: activeControl,
    focusGuardInstalled: Boolean(window.__tomatoWebViewFocusGuardInstalled),
    pictureBookScene,
    visibleText: (document.body?.innerText || '').replace(/\\s+/g, ' ').slice(0, 4000)
  });
})()
''',
      );
      final payload = _decodeJavascriptJsonMap(raw);
      payload['runtimeState'] = await _qaRuntimeState();
      return payload;
    });
  }

  Future<Map<String, dynamic>> _qaRuntimeState() async {
    final followArticleId = _activeFollowArticleId;
    final listeningArticleId = _activeListeningArticleId;
    final chatArticleId = _activeChatArticleId;
    final payload = <String, dynamic>{
      'activeFollowArticleId': followArticleId,
      'activeListeningArticleId': listeningArticleId,
      'activeChatArticleId': chatArticleId,
      'webViewFrameRate': {
        'fpsLimit': _mainWebViewCurrentFpsLimit,
        'unsupported': _mainWebViewFpsLimitUnsupported,
        'activityDepth': _mainWebViewFrameRateActivityDepth,
      },
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

    final pictureBookArticleId =
        listeningArticleId ?? followArticleId ?? chatArticleId;
    if (pictureBookArticleId != null) {
      try {
        payload['pictureBook'] =
            await _qaPictureBookSummary(pictureBookArticleId);
      } catch (error) {
        payload['pictureBookError'] = error.toString();
      }
    }

    return payload;
  }

  Future<Map<String, dynamic>> _qaPictureBookSummary(int articleId) async {
    final pages = await DatabaseService.getPictureBookPages(articleId);
    final statusCounts = <String, int>{};
    for (final page in pages) {
      final status = page.status;
      statusCounts[status] = (statusCounts[status] ?? 0) + 1;
    }
    return {
      'articleId': articleId,
      'status': _pictureBookSummaryStatus(pages),
      'pageCount': pages.length,
      'statusCounts': statusCounts,
      'ranges': pages
          .map(
            (page) => {
              'pageIndex': page.pageIndex,
              'sentenceStartIndex': page.sentenceStartIndex,
              'sentenceEndIndex': page.sentenceEndIndex,
              'status': page.status,
              'imagePath': page.imagePath,
              'hasImage': page.imagePath?.trim().isNotEmpty ?? false,
              'errorMessage': page.errorMessage,
            },
          )
          .toList(growable: false),
    };
  }

  String _pictureBookSummaryStatus(List<PictureBookPage> pages) {
    if (pages.isEmpty) {
      return 'empty';
    }
    if (pages.any((page) =>
        page.status == 'queued' ||
        page.status == 'prompting' ||
        page.status == 'generating')) {
      return 'generating';
    }
    if (pages.every((page) => page.status == 'ready')) {
      return 'ready';
    }
    if (pages.every((page) => page.status == 'skipped')) {
      return 'skipped';
    }
    if (pages.any((page) => page.status == 'ready')) {
      return 'partial';
    }
    if (pages.any((page) => page.status == 'error')) {
      return 'error';
    }
    return 'empty';
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

  int? _payloadOptionalInt(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    if (value == null || value == '') {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  List<int>? _payloadIntList(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    if (value == null) {
      return null;
    }
    if (value is! List) {
      return null;
    }
    final items = <int>[];
    for (final item in value) {
      final parsed = _intFromDynamic(item);
      if (parsed == null) {
        return null;
      }
      items.add(parsed);
    }
    return items;
  }

  int? _intFromDynamic(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  bool _payloadBool(
    Map<String, dynamic> payload,
    String key, {
    bool fallback = false,
  }) {
    final value = payload[key];
    if (value == null) {
      return fallback;
    }
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1' || normalized == 'yes') {
        return true;
      }
      if (normalized == 'false' || normalized == '0' || normalized == 'no') {
        return false;
      }
    }
    return fallback;
  }

  void _ensureArticleContentWithinLimit(String content) {
    if (content.length <= _articleContentMaxChars) {
      return;
    }
    throw const FormatException('文章内容不能超过 8000 个字符');
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

  String _normalizeSongProvider(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized == AppConfig.songProviderBailianFunMusic
        ? AppConfig.songProviderBailianFunMusic
        : AppConfig.songProviderSuno;
  }

  String _normalizeSongSource(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == ExternalSongImportService.source) {
      return ExternalSongImportService.source;
    }
    return _normalizeSongProvider(normalized);
  }

  List<Map<String, dynamic>> _payloadMapList(
    Map<String, dynamic> payload,
    String key,
  ) {
    final value = payload[key];
    if (value is! List) {
      return const <Map<String, dynamic>>[];
    }
    return value
        .whereType<Map>()
        .map(
            (item) => item.map((key, value) => MapEntry(key.toString(), value)))
        .toList(growable: false);
  }

  List<BookCharacter> _payloadBookCharacters(
    Map<String, dynamic> payload,
    String key,
  ) {
    return [
      for (final item in _payloadMapList(payload, key))
        if ((item['name']?.toString().trim() ?? '').isNotEmpty &&
            (item['description']?.toString().trim() ?? '').isNotEmpty)
          BookCharacter(
            name:
                item['name']!.toString().replaceAll(RegExp(r'\s+'), ' ').trim(),
            description: item['description']!
                .toString()
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim(),
          ),
    ];
  }

  Map<String, dynamic> _decodeJsonObject(String? text) {
    final raw = text?.trim() ?? '';
    if (raw.isEmpty) {
      return const <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    } catch (_) {
      // Invalid cache metadata is ignored and treated as empty.
    }
    return const <String, dynamic>{};
  }

  String? _nonEmptyString(Object? value) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? null : text;
  }

  String? _firstNonEmptyString(Iterable<Object?> values) {
    for (final value in values) {
      final text = _nonEmptyString(value);
      if (text != null) {
        return text;
      }
    }
    return null;
  }

  String _songTimelineKey(int articleId, String versionId) =>
      '$articleId::$versionId';

  ArticleSongVersion? _defaultSongVersion(List<ArticleSongVersion> versions) {
    if (versions.isEmpty) {
      return null;
    }
    for (final version in versions) {
      if (version.isDefault) {
        return version;
      }
    }
    return versions.first;
  }

  List<ArticleSongVersion> _ensureSingleDefaultSongVersion(
    List<ArticleSongVersion> versions, {
    bool requireDefault = true,
  }) {
    if (versions.isEmpty) {
      return const <ArticleSongVersion>[];
    }
    var defaultSeen = false;
    final normalized = <ArticleSongVersion>[];
    for (final version in versions) {
      if (version.isDefault && !defaultSeen) {
        defaultSeen = true;
        normalized.add(version);
      } else if (version.isDefault) {
        normalized.add(version.copyWith(isDefault: false));
      } else {
        normalized.add(version);
      }
    }
    if (!defaultSeen && requireDefault) {
      normalized[0] = normalized[0].copyWith(isDefault: true);
    }
    return normalized;
  }

  List<ArticleSongVersion> _dedupeSongVersions(
    List<ArticleSongVersion> versions,
  ) {
    final byAudioPath = <String, ArticleSongVersion>{};
    for (final version in versions) {
      final key = version.audioPath.trim();
      if (key.isEmpty) {
        continue;
      }
      final existing = byAudioPath[key];
      byAudioPath[key] =
          existing == null ? version : _mergeSongVersion(existing, version);
    }
    return byAudioPath.values.toList(growable: false);
  }

  ArticleSongVersion _mergeSongVersion(
    ArticleSongVersion primary,
    ArticleSongVersion fallback,
  ) =>
      primary.copyWith(
        title: primary.title ?? fallback.title,
        songUrl: primary.songUrl ?? fallback.songUrl,
        durationMs: primary.durationMs ?? fallback.durationMs,
        createdAt: primary.createdAt ?? fallback.createdAt,
        stylePrompt: primary.stylePrompt ?? fallback.stylePrompt,
        styleKey: primary.styleKey ?? fallback.styleKey,
        lyricsHash: primary.lyricsHash ?? fallback.lyricsHash,
        submittedLyrics: primary.submittedLyrics ?? fallback.submittedLyrics,
        timelinePath: primary.timelinePath ?? fallback.timelinePath,
        timelineStatus: primary.timelineStatus ?? fallback.timelineStatus,
        timelineConfidence:
            primary.timelineConfidence ?? fallback.timelineConfidence,
        timelineError: primary.timelineError ?? fallback.timelineError,
        isDefault: primary.isDefault || fallback.isDefault,
      );

  String _versionTimelineStatus(ArticleSongVersion version) {
    final explicit = (version.timelineStatus ?? '').trim();
    if (explicit.isNotEmpty && explicit != 'generating') {
      return explicit;
    }
    return (version.timelinePath ?? '').trim().isNotEmpty ? 'ready' : 'missing';
  }

  Future<String> _songTimelineStatusForPath(String? timelinePath) async {
    final normalized = (timelinePath ?? '').trim();
    if (normalized.isEmpty) {
      return 'missing';
    }
    if (!await File(normalized).exists()) {
      return 'missing';
    }
    return await SongSubtitleTimelineService.timelineFileIsCurrent(normalized)
        ? 'ready'
        : 'stale';
  }

  List<ArticleSongVersion> _songVersionsForPayload(
    int articleId,
    List<ArticleSongVersion> versions, {
    bool requireDefault = true,
  }) {
    final payloadVersions = _ensureSingleDefaultSongVersion(
      _dedupeSongVersions(versions),
      requireDefault: requireDefault,
    ).map((version) {
      final key = _songTimelineKey(articleId, version.id);
      if (_songTimelineTasks.containsKey(key)) {
        return version.copyWith(
          timelineStatus: 'generating',
          timelineError: null,
        );
      }
      final error = _songTimelineErrors[key];
      if (error != null && error.trim().isNotEmpty) {
        return version.copyWith(
          timelineStatus: 'error',
          timelineError: error,
        );
      }
      return version.copyWith(
        timelineStatus: _versionTimelineStatus(version),
        timelineError: version.timelineError,
      );
    }).toList(growable: false);
    return [
      ...payloadVersions.where((version) => version.isDefault),
      ...payloadVersions.where((version) => !version.isDefault),
    ];
  }

  Future<Set<String>> _sunoSongUrlsForOtherArticles(int articleId) async {
    final db = await DatabaseService.database;
    final rows = await db.query(
      'api_cache_entries',
      columns: ['request_json', 'json_value'],
      where: 'purpose = ?',
      whereArgs: [_sunoSongPurpose],
    );
    final urls = <String>{};
    for (final row in rows) {
      final request = _decodeJsonObject(row['request_json']?.toString());
      final metadata = _decodeJsonObject(row['json_value']?.toString());
      final entryArticleId = _intFromDynamic(metadata['articleId']) ??
          _intFromDynamic(request['articleId']);
      if (entryArticleId == null || entryArticleId == articleId) {
        continue;
      }
      final songUrl = SunoUtilities.canonicalSongUrl(metadata['songUrl']);
      if (songUrl != null && !SunoUtilities.isSyntheticSongKey(songUrl)) {
        urls.add(songUrl);
      }
      urls.addAll(
        SunoUtilities.songUrlList(metadata['detectedSongUrls'])
            .where((value) => !SunoUtilities.isSyntheticSongKey(value)),
      );
      final versions = metadata['versions'];
      if (versions is List) {
        for (final version in versions) {
          if (version is! Map) {
            continue;
          }
          final versionSongUrl =
              SunoUtilities.canonicalSongUrl(version['songUrl']);
          if (versionSongUrl != null &&
              !SunoUtilities.isSyntheticSongKey(versionSongUrl)) {
            urls.add(versionSongUrl);
          }
        }
      }
    }
    // E28 Part2 exposed the pitfall: an E28 Part1 Suno URL
    // (1d591a17...) weakly matched the neighboring chapter lyrics and was
    // downloaded again. Treat already-owned song URLs as another article's
    // assets unless they were explicitly cached for the current article.
    return urls;
  }

  bool _currentSunoDownloadsComplete() {
    if (_sunoEngine.state.detectedSongUrls.isEmpty) {
      return false;
    }
    final downloaded = _sunoEngine.state.versions
        .map((version) => SunoUtilities.canonicalSongUrl(version.songUrl))
        .whereType<String>()
        .where((value) =>
            value.isNotEmpty && !SunoUtilities.isSyntheticSongKey(value))
        .toSet();
    return _sunoEngine.state.detectedSongUrls.every((value) {
      final songUrl = SunoUtilities.canonicalSongUrl(value);
      return songUrl != null && downloaded.contains(songUrl);
    });
  }

  String _defaultSunoFixtureDirectory() {
    final configured =
        (Platform.environment['TOMATO_SUNO_FIXTURE_DIR'] ?? '').trim();
    if (configured.isNotEmpty) {
      return configured;
    }
    final current = Directory.current.absolute.path;
    if (path_lib.basename(current).toLowerCase() == 'app') {
      return path_lib.join(path_lib.dirname(current), '.tmp', 'suno-fixtures');
    }
    return path_lib.join(
        RecordingExportService.programDirectory(), 'suno-fixtures');
  }

  String _defaultSunoOutputDirectorySetting() =>
      AssetPathService.defaultSunoOutputDirectorySetting();

  String _defaultSunoOutputDirectory() =>
      AssetPathService.defaultSunoOutputDirectory();

  String _resolveSunoOutputDirectory(String configured) =>
      AssetPathService.resolvePersistentDirectory(
        configured: configured,
        defaultDirectory: _defaultSunoOutputDirectory(),
        baseDirectory: AssetPathService.programDirectory(),
      );

  bool _isDefaultSunoOutputDirectory(String configured) {
    final trimmed = configured.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    return path_lib.equals(
      path_lib.normalize(_resolveSunoOutputDirectory(trimmed)),
      path_lib.normalize(_defaultSunoOutputDirectory()),
    );
  }

  String _safeSunoSnapshotStem(String url, DateTime timestamp) {
    final stamp = timestamp
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .replaceAll('Z', 'z');
    final kind = SunoUtilities.pageKind(url);
    final uri = Uri.tryParse(url.trim());
    final path = uri == null
        ? 'unknown'
        : uri.pathSegments.take(3).join('-').replaceAll('@', 'at-');
    final slug = (path.isEmpty ? kind : '$kind-$path')
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    return 'suno_${stamp}_${slug.isEmpty ? kind : slug}';
  }

  String _sunoOutputDirectorySettingForSave(String configured) {
    final trimmed = configured.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    return AssetPathService.isTemporaryAssetDirectory(
      trimmed,
      baseDirectory: AssetPathService.programDirectory(),
    )
        ? ''
        : trimmed;
  }

  Future<String> _resolvedSunoOutputDirectorySetting() async {
    final settings = await _songSettingsPayload();
    return (settings['resolvedSunoOutputDirectory'] ??
            _resolveSunoOutputDirectory(
              (settings['sunoOutputDirectory'] ?? '').toString(),
            ))
        .toString();
  }

  Future<String> _migrateSunoAssetPathIfNeeded(String audioPath) async {
    final migrated = await AssetPathService.migrateTemporaryAssetFileIfNeeded(
      sourcePath: audioPath,
      targetDirectory: _defaultSunoOutputDirectory(),
    );
    if (migrated != audioPath.trim()) {
      TomatoLogger.info(
        category: 'suno',
        event: 'asset.migrated_from_temporary_directory',
        data: {
          'oldPath': audioPath,
          'newPath': migrated,
        },
      );
    }
    return migrated;
  }

  Future<String> _migrateSunoMetadataPathIfNeeded({
    required String metadataPath,
    required Map<String, dynamic> metadata,
    required List<ArticleSongVersion> versions,
  }) async {
    final trimmed = metadataPath.trim();
    if (trimmed.isEmpty ||
        !AssetPathService.isTemporaryAssetDirectory(trimmed)) {
      return trimmed;
    }

    final directory = Directory(_defaultSunoOutputDirectory());
    await directory.create(recursive: true);
    final filename = path_lib.basename(trimmed).trim().isEmpty
        ? 'suno_metadata_${DateTime.now().millisecondsSinceEpoch}.json'
        : path_lib.basename(trimmed);
    final targetPath = path_lib.join(directory.path, filename);
    final migratedMetadata = Map<String, dynamic>.from(metadata);
    migratedMetadata['metadataPath'] = targetPath;
    if (versions.isNotEmpty) {
      migratedMetadata['audioPath'] = versions.first.audioPath;
      migratedMetadata['versions'] =
          versions.map((version) => version.toJson()).toList(growable: false);
    }
    await File(targetPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(migratedMetadata),
      flush: true,
    );
    TomatoLogger.info(
      category: 'suno',
      event: 'metadata.migrated_from_temporary_directory',
      data: {
        'oldPath': trimmed,
        'newPath': targetPath,
      },
    );
    return targetPath;
  }
}

class _WebShellSunoHost implements SunoAutomationHost {
  _WebShellSunoHost(this._state);

  final _WebShellScreenState _state;

  @override
  bool get isMounted => _state.mounted;

  @override
  void requestSetState() => _state.sunoRequestSetState();

  @override
  Future<Article> loadSongArticle(int articleId) =>
      _state._songArticle(articleId);

  @override
  Future<String> articleSongLyricsHash(Article article) =>
      _state._articleSongLyricsHash(article);

  @override
  Future<List<SunoCachedSongGroup>> cachedSunoSongGroups(Article article) =>
      _state._cachedSunoSongGroups(article);

  @override
  Future<ArticleSongState?> cachedSunoSongState(Article article) =>
      _state._cachedSunoSongState(article);

  @override
  Future<void> pushSongState(int articleId) => _state._pushSongState(articleId);

  @override
  Future<void> saveSunoMetadataForVersions({
    required Article article,
    required List<ArticleSongVersion> versions,
    String? manualActionMessage,
    bool? downloadCompleteOverride,
    String? stylePromptOverride,
    List<String>? detectedSongUrlsOverride,
  }) =>
      _state._saveSunoMetadataForVersions(
        article: article,
        versions: versions,
        manualActionMessage: manualActionMessage,
        downloadCompleteOverride: downloadCompleteOverride,
        stylePromptOverride: stylePromptOverride,
        detectedSongUrlsOverride: detectedSongUrlsOverride,
      );

  @override
  Future<String> resolvedSunoOutputDirectory() =>
      _state._resolvedSunoOutputDirectorySetting();

  @override
  Future<Set<String>> sunoSongUrlsForOtherArticles(int articleId) =>
      _state._sunoSongUrlsForOtherArticles(articleId);

  @override
  String displayError(Object error) => _state._displayError(error);

  @override
  Future<List<int>> downloadUrl(String url, {String? userAgent}) =>
      _state._downloadSunoUrl(url, userAgent: userAgent);
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
