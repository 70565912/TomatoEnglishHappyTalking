import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as path_lib;

import '../../core/config/app_config.dart';
import '../../core/logging/tomato_logger.dart';
import '../../core/theme/app_theme.dart';
import '../../core/webview/webview_environment.dart';
import '../../data/models/article_model.dart';
import '../../data/models/article_sentence_translation_model.dart';
import '../../data/models/article_song_model.dart';
import '../../data/models/picture_book_model.dart';
import '../../services/api_cache_service.dart';
import '../../services/asset_path_service.dart';
import '../../services/database_service.dart';
import '../../services/content_safety_service.dart';
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
  static const _englishVoicePreviewText =
      "Hello, I am your tomato tutor. Let's practice English together.";
  static const _chineseVoicePreviewText = '你好，我是番茄助教。让我们一起快乐练英语。';

  InAppWebViewController? _controller;
  WebShellQaServer? _qaServer;
  ProviderSubscription<AsyncValue<FollowReadState>>? _followSubscription;
  ProviderSubscription<ChatState>? _chatSubscription;
  AudioPlayer? _listeningPlayer;
  AudioPlayer? _previewPlayer;
  AudioPlayer? _songPlayer;
  final Map<String, Future<String>> _listeningTtsPathFutures = {};
  final Map<String, Future<ArticleSongVersion>> _songTimelineTasks = {};
  final Map<String, String> _songTimelineErrors = {};
  InAppWebViewController? _sunoController;
  Timer? _sunoAutomationTimer;
  int? _sunoArticleId;
  String _sunoStylePrompt = '';
  String _sunoLyrics = '';
  String _sunoAutomationStatus = 'idle';
  String? _sunoManualActionMessage;
  String? _sunoErrorMessage;
  String _sunoInitialUrl = 'https://suno.com/create';
  String _sunoIgnoredStylePrompt = '';
  String? _sunoSongUrl;
  String? _sunoAudioPath;
  String? _sunoMetadataPath;
  int? _sunoCreditsRemaining;
  DateTime? _sunoStyleMagicRequestedAt;
  final List<ArticleSongVersion> _sunoVersions = <ArticleSongVersion>[];
  final Set<String> _sunoDownloadedSongUrls = <String>{};
  final Set<String> _sunoDownloadedDownloadKeys = <String>{};
  final Set<String> _sunoDownloadInFlightKeys = <String>{};
  final Set<String> _sunoDetectedSongUrls = <String>{};
  String? _sunoPendingDownloadSongUrl;
  String? _sunoPendingDownloadTitle;
  DateTime? _sunoExistingDownloadStartedAt;
  int _sunoExistingDownloadMenuRetries = 0;
  bool _sunoExistingDownloadLibraryTried = false;
  String? _sunoLastLoadStopUrl;
  DateTime? _sunoLastLoadStopAt;
  bool _sunoVisible = false;
  bool _sunoCreateSubmitted = false;
  bool _sunoExistingDownloadOnly = false;
  bool _sunoCompletedStandby = false;
  bool _sunoCompletedStandbyFilled = false;
  bool _sunoAutomationBusy = false;
  RecordingCancelToken? _recordingCancelToken;
  int? _activeFollowArticleId;
  int? _activeListeningArticleId;
  int? _activeChatArticleId;
  int _listeningPlaybackToken = 0;
  int _previewPlaybackToken = 0;
  int _songPlaybackToken = 0;
  int _preloadRunCounter = 0;
  bool _listeningPausedForWord = false;
  bool _webReady = false;
  String? _loadError;
  final List<Map<String, dynamic>> _pendingEvents = [];
  final Set<String> _retryingPictureBookPages = <String>{};
  final Map<String, _PreloadAggregate> _preloadAggregates =
      <String, _PreloadAggregate>{};

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
        'article.delete': _handleArticleDelete,
        'series.list': _handleSeriesList,
        'series.create': _handleSeriesCreate,
        'series.delete': _handleSeriesDelete,
        'series.attachArticle': _handleSeriesAttachArticle,
        'pictureBook.state': _handlePictureBookState,
        'pictureBook.pageImage': _handlePictureBookPageImage,
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
        'listening.prepare': _handleListeningPrepare,
        'listening.preloadChinese': _handleListeningPreloadChinese,
        'listening.play': _handleListeningPlay,
        'listening.playSequence': _handleListeningPlaySequence,
        'listening.fullscreenReady': _handleListeningFullscreenReady,
        'listening.recordingReady': _handleListeningRecordingReady,
        'listening.recordVideo': _handleListeningRecordVideo,
        'listening.cancelRecording': _handleListeningCancelRecording,
        'listening.songState': _handleListeningSongState,
        'listening.songGenerate': _handleListeningSongGenerate,
        'listening.songConfirmSunoCreate':
            _handleListeningSongConfirmSunoCreate,
        'listening.songDownloadSunoExisting':
            _handleListeningSongDownloadSunoExisting,
        'listening.songTimelineGenerate': _handleListeningSongTimelineGenerate,
        'listening.songPlay': _handleListeningSongPlay,
        'listening.songSetDefault': _handleListeningSongSetDefault,
        'listening.songStop': _handleListeningSongStop,
        'listening.songRecordVideo': _handleListeningSongRecordVideo,
        'suno.debugInspect': _handleSunoDebugInspect,
        'suno.debugFill': _handleSunoDebugFill,
        'suno.debugRows': _handleSunoDebugRows,
        'suno.debugSnapshot': _handleSunoDebugSnapshot,
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
        'diagnostics.logsRecent': _handleDiagnosticsLogsRecent,
        'diagnostics.logsExport': _handleDiagnosticsLogsExport,
        'diagnostics.clientLog': _handleDiagnosticsClientLog,
        'recording.settings.load': _handleRecordingSettingsLoad,
        'recording.settings.save': _handleRecordingSettingsSave,
        'settings.previewVoice': _handleSettingsPreviewVoice,
        'contentSafety.setRuleEnabled': _handleContentSafetySetRuleEnabled,
        'contentSafety.deleteRule': _handleContentSafetyDeleteRule,
      });

  @override
  void initState() {
    super.initState();
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
        dispatchBridge: (raw) => _bridgeRouter.dispatch(raw),
      );
      unawaited(_qaServer!.start());
    }
  }

  @override
  void dispose() {
    unawaited(_qaServer?.stop());
    _recordingCancelToken?.cancel();
    unawaited(_stopListeningPlayback());
    unawaited(_stopVoicePreview());
    unawaited(_stopSongPlayback());
    _stopSunoAutomation(clearVisible: true);
    _listeningTtsPathFutures.clear();
    final followArticleId = _activeFollowArticleId;
    if (followArticleId != null) {
      _clearPreloadAggregatesForArticle(followArticleId);
      TtsMemoryCacheService.releaseArticle(followArticleId);
    }
    _closeFollowSession();
    final listeningArticleId = _activeListeningArticleId;
    if (listeningArticleId != null) {
      _clearPreloadAggregatesForArticle(listeningArticleId);
      TtsMemoryCacheService.releaseArticle(listeningArticleId);
    }
    _activeListeningArticleId = null;
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
        child: Stack(
          children: [
            Positioned.fill(
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
            if (_sunoVisible) Positioned.fill(child: _buildSunoOverlay()),
          ],
        ),
      ),
    );
  }

  Widget _buildSunoOverlay() {
    final statusText = _sunoOverlayStatusText();
    final canConfirm =
        _sunoAutomationStatus == 'waitingConfirm' && !_sunoCreateSubmitted;
    final isComplete = _sunoAutomationStatus == 'complete';
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
                    onPressed: _sunoAutomationBusy
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
                        _sunoVisible = false;
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
                      _stopSunoAutomation(clearVisible: true);
                      final articleId = _sunoArticleId;
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
                initialUrlRequest: URLRequest(
                  url: WebUri(_sunoInitialUrl),
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
                    articleId: _sunoArticleId,
                    data: {'initialUrl': _sunoInitialUrl},
                  );
                  _sunoController = controller;
                },
                onLoadStop: (controller, url) {
                  _sunoLastLoadStopUrl = url?.toString();
                  _sunoLastLoadStopAt = DateTime.now();
                  TomatoLogger.info(
                    category: 'suno',
                    event: 'webview.load_stop',
                    articleId: _sunoArticleId,
                    data: {
                      'url': url?.toString(),
                      'pageKind':
                          url == null ? null : _sunoPageKind(url.toString()),
                    },
                  );
                  _sunoController = controller;
                  unawaited(_continueSunoAutomation());
                },
                onDownloadStartRequest: (controller, request) {
                  TomatoLogger.info(
                    category: 'suno',
                    event: 'download.request',
                    articleId: _sunoArticleId,
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
        _clearPreloadAggregatesForArticle(articleId);
        TtsMemoryCacheService.releaseArticle(articleId);
      }
      _closeFollowSession();
    }
    if (!path.startsWith('/chat')) {
      _closeChatSession();
    }
    if (!path.startsWith('/listen')) {
      final articleId = _activeListeningArticleId;
      unawaited(_stopListeningPlayback());
      unawaited(_stopSongPlayback());
      _stopSunoAutomation(clearVisible: true);
      if (articleId != null) {
        _clearPreloadAggregatesForArticle(articleId);
        TtsMemoryCacheService.releaseArticle(articleId);
      }
      _activeListeningArticleId = null;
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
      fallback: false,
    );
    final requestedSeriesId = _payloadOptionalInt(message.payload, 'seriesId');
    final requestedSeriesTitle =
        _payloadString(message.payload, 'seriesTitle').trim();
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
    await _saveArticleTranslationsAtCreate(
      articleId: id,
      sentences: sentences,
      parsedInput: parsedInput,
    );
    if (!parsedInput.usesLocalEnglish) {
      await PracticeTextService.attachTranslateToEnglishForPracticeCache(
        content: content,
        articleId: id,
      );
    }
    if (requestedTitle.isEmpty && parsedInput.titleCandidate.trim().isEmpty) {
      await PracticeTextService.attachSuggestArticleTitleCache(
        content: englishContent,
        articleId: id,
      );
    }
    if (pictureBookEnabled) {
      final savedArticle = article.copyWith(id: id);
      int? seriesIdForRollback;
      try {
        final series = await _resolveStorySeries(
          requestedSeriesId: requestedSeriesId,
          requestedSeriesTitle: requestedSeriesTitle,
          fallbackTitle: title,
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
        await PictureBookService.ensureChapterPlanForArticle(
          article: savedArticle,
          chapter: chapter,
          series: series,
        );
        unawaited(
          PictureBookService.generateForArticle(
            article: savedArticle,
            chapter: chapter,
            onProgress: (state) => _pushEvent('pictureBook.state', state),
          ),
        );
      } catch (_) {
        await DatabaseService.deleteArticle(id);
        if (seriesIdForRollback != null && requestedSeriesId == null) {
          await DatabaseService.deleteStorySeriesIfEmpty(seriesIdForRollback);
        }
        rethrow;
      }
    }
    final payload = await _articleListPayload();
    unawaited(_pushEvent('article.state', payload));
    return {
      'article': await _articleJsonWithStory(article.copyWith(id: id),
          averageScore: 0),
      'articles': payload['articles'],
      'series': payload['series'],
    };
  }

  Future<Map<String, dynamic>> _handleArticleDelete(
    BridgeMessage message,
  ) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    await DatabaseService.deleteArticle(articleId);
    _clearPreloadAggregatesForArticle(articleId);
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

  Future<Map<String, dynamic>> _handleSeriesList(BridgeMessage message) async {
    return _storySeriesListPayload();
  }

  Future<Map<String, dynamic>> _handleSeriesCreate(
    BridgeMessage message,
  ) async {
    final title = _payloadString(message.payload, 'title').trim();
    if (title.isEmpty) {
      throw const FormatException('请填写书籍名称');
    }
    await PictureBookService.createSeries(title: title);
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
    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) {
      throw FormatException('文章不存在（id=$articleId）');
    }

    final article = await _articleWithCurrentSentences(rawArticle);
    final series = await _resolveStorySeries(
      requestedSeriesId: requestedSeriesId,
      requestedSeriesTitle: requestedSeriesTitle,
      fallbackTitle: article.title,
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
    return PictureBookService.pageImagePayload(
      articleId: articleId,
      pageIndex: pageIndex,
    );
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
    final article = await _articleWithCurrentSentences(rawArticle);
    var chapter = await DatabaseService.getStoryChapterForArticle(articleId);
    if (chapter == null) {
      final series =
          await PictureBookService.createSeries(title: article.title);
      final seriesId = series.id;
      if (seriesId == null) {
        throw const FormatException('书籍创建失败');
      }
      chapter = await PictureBookService.ensureChapterForArticle(
        seriesId: seriesId,
        article: article,
      );
    }
    unawaited(
      PictureBookService.generateForArticle(
        article: article,
        chapter: chapter,
        regenerate: regenerate,
        onProgress: (state) => _pushEvent('pictureBook.state', state),
      ),
    );
    final state = await PictureBookService.statePayload(articleId);
    unawaited(_pushEvent('pictureBook.state', state));
    return state;
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
      await PictureBookService.regenerateArticle(
        articleId: articleId,
        onProgress: (state) => _pushEvent('pictureBook.state', state),
      );
      final state = await PictureBookService.statePayload(articleId);
      unawaited(_pushEvent('pictureBook.state', state));
      return state;
    } finally {
      _retryingPictureBookPages.remove(retryKey);
    }
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
      _clearPreloadAggregatesForArticle(listeningArticleId);
      TtsMemoryCacheService.releaseArticle(listeningArticleId);
    }
    _activeListeningArticleId = null;
    await _stopListeningPlayback();
    await _stopSongPlayback();
    _openFollowSession(articleId);
    final value = await ref.read(followReadProvider(articleId).future);
    final payload = _followPayload(AsyncValue.data(value));
    final preloadRunId = _resetPreloadAggregate(
      articleId,
      'follow',
      scope: 'english',
    );
    unawaited(_preloadFollowArticle(value.article, runId: preloadRunId));
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
      _clearPreloadAggregatesForArticle(followArticleId);
      TtsMemoryCacheService.releaseArticle(followArticleId);
    }
    _closeFollowSession();
    _closeChatSession();
    final listeningArticleId = _activeListeningArticleId;
    if (listeningArticleId != null && listeningArticleId != articleId) {
      _clearPreloadAggregatesForArticle(listeningArticleId);
      TtsMemoryCacheService.releaseArticle(listeningArticleId);
    }
    await _stopListeningPlayback();
    await _stopSongPlayback();
    _activeListeningArticleId = articleId;

    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) {
      throw FormatException('文章不存在（id=$articleId）');
    }

    final article = await _articleWithCurrentSentences(rawArticle);
    final items = await _listeningItemsForArticle(article);

    if (article.id != null && items.isNotEmpty) {
      final preloadRunId = _resetPreloadAggregate(
        article.id!,
        'listening',
        scope: 'english',
      );
      unawaited(
        _preloadListeningWindow(
          article.id!,
          items,
          startIndex: 0,
          runId: preloadRunId,
        ),
      );
      unawaited(_pushSongState(article.id!));
    }

    return {
      'article': _articleJson(article),
      'items': items,
    };
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
      if (sentence.isEmpty) {
        continue;
      }
      items.add({
        'index': i,
        'english': sentence,
        'chinese': translations[i] ?? '',
      });
    }
    return items;
  }

  Future<Article> _songArticle(int articleId) async {
    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) {
      throw FormatException('文章不存在（id=$articleId）');
    }
    return _articleWithCurrentSentences(rawArticle);
  }

  Future<String> _articleSongContentHash(Article article) =>
      ApiCacheService.hashUtf8(
        _articleSongStoryText(article),
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
    if (_sunoArticleId != articleId || _sunoAutomationStatus == 'idle') {
      return null;
    }
    final hasLocalAudio = (_sunoAudioPath?.trim().isNotEmpty ?? false) ||
        _sunoVersions.isNotEmpty;
    final canPlayDownloaded = hasLocalAudio &&
        (_sunoAutomationStatus == 'complete' ||
            _sunoAutomationStatus == 'manualAction');
    final status = _sunoErrorMessage != null
        ? 'error'
        : canPlayDownloaded
            ? 'ready'
            : (_sunoAutomationStatus == 'manualAction'
                ? 'empty'
                : 'generating');
    return ArticleSongState(
      articleId: articleId,
      status: status,
      stylePrompt: _sunoStylePrompt,
      audioPath: (_sunoAudioPath?.trim().isNotEmpty ?? false)
          ? _sunoAudioPath
          : (_sunoVersions.isNotEmpty ? _sunoVersions.first.audioPath : null),
      errorMessage: _sunoErrorMessage,
      source: 'suno',
      songUrl: _sunoSongUrl ??
          (_sunoVersions.isNotEmpty ? _sunoVersions.first.songUrl : null),
      metadataPath: _sunoMetadataPath,
      manualActionMessage: _sunoManualActionMessage,
      automationStatus: _sunoAutomationStatus,
      creditsRemaining: _sunoCreditsRemaining,
      downloadComplete: _currentSunoDownloadsComplete(),
      detectedSongUrls: _sunoDetectedSongUrls.toList(growable: false),
      versions: _songVersionsForPayload(articleId, _sunoVersions),
    );
  }

  bool _isTransientSunoWebViewError(Object error) {
    final message = error.toString();
    return message.contains('MissingPluginException') &&
        message.contains('evaluateJavascript');
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
    final contentHash = await _articleSongContentHash(article);
    final builders = <String, SunoCachedSongGroupBuilder>{};
    for (final entry in entries) {
      if ((entry.jsonValue ?? '').trim().isEmpty) {
        continue;
      }
      final request = _decodeJsonObject(entry.requestJson);
      if (request['contentHash'] != contentHash) {
        continue;
      }
      final metadata = _decodeJsonObject(entry.jsonValue);
      final stylePrompt = (_nonEmptyString(metadata['stylePrompt']) ??
              _nonEmptyString(request['stylePrompt']) ??
              '')
          .trim();
      final styleKey = _sunoStyleKey(stylePrompt);
      final builder = builders.putIfAbsent(
        styleKey,
        () => SunoCachedSongGroupBuilder(
          stylePrompt: stylePrompt,
          styleKey: styleKey,
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
            songUrl: _nonEmptyString(metadata['songUrl']),
            stylePrompt: stylePrompt.isEmpty ? null : stylePrompt,
            styleKey: styleKey,
          ),
        ]);
      }
      builder.detectedSongUrls.addAll(
        _sunoSongUrlList(metadata['detectedSongUrls']),
      );
      final songUrl = _nonEmptyString(metadata['songUrl']) ??
          _firstNonEmptyString(builder.detectedSongUrls) ??
          _firstNonEmptyString(
            builder.versions.map((version) => version.songUrl),
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
    final latestGroup = groups.first;
    final rawVersions =
        groups.expand((group) => group.versions).toList(growable: false);
    final versions = _songVersionsForPayload(articleId, rawVersions);
    final detectedSongUrls = groups
        .expand((group) => group.detectedSongUrls)
        .where((value) => value.trim().isNotEmpty)
        .toSet()
        .toList(growable: false);
    final hasAudio = versions.isNotEmpty;
    final downloadComplete = latestGroup.hasKnownCompleteDownloads;
    return ArticleSongState(
      articleId: articleId,
      status: hasAudio ? 'ready' : 'empty',
      stylePrompt: latestGroup.stylePrompt,
      audioPath: versions.isNotEmpty ? versions.first.audioPath : null,
      durationMs: versions.isNotEmpty ? versions.first.durationMs : null,
      source: 'suno',
      songUrl: latestGroup.songUrl,
      metadataPath: latestGroup.metadataPath,
      versions: versions,
      detectedSongUrls: detectedSongUrls,
      downloadComplete: hasAudio ? downloadComplete : null,
      manualActionMessage: hasAudio
          ? null
          : (latestGroup.manualActionMessage ??
              'Suno 歌曲已生成记录，但还没有本地音频文件。请在 Suno 页面手工下载后重试。'),
      automationStatus: hasAudio ? 'complete' : 'manualAction',
    );
  }

  Future<List<ArticleSongVersion>> _sunoVersionsFromMetadata(
    Map<String, dynamic> metadata, {
    required String fallbackStylePrompt,
  }) async {
    final rawVersions = metadata['versions'];
    final versions = <ArticleSongVersion>[];
    final fallbackStyleKey = _sunoStyleKey(fallbackStylePrompt);
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
          final hasTimeline = timelinePath != null &&
              timelinePath.trim().isNotEmpty &&
              await File(timelinePath).exists();
          versions.add(
            ArticleSongVersion(
              id: version.id,
              audioPath: audioPath,
              title: version.title,
              songUrl: version.songUrl,
              durationMs: version.durationMs,
              createdAt: version.createdAt,
              stylePrompt: version.stylePrompt ?? fallbackStylePrompt,
              styleKey: version.styleKey ?? fallbackStyleKey,
              lyricsHash: version.lyricsHash,
              timelinePath: hasTimeline ? timelinePath : null,
              timelineStatus:
                  hasTimeline ? _versionTimelineStatus(version) : 'missing',
              timelineConfidence:
                  hasTimeline ? version.timelineConfidence : null,
              timelineError: hasTimeline ? version.timelineError : null,
              isDefault: version.isDefault,
            ),
          );
        }
      }
    }
    return versions;
  }

  bool _hasSunoVersionForSongUrl(String songUrl) {
    final normalized = songUrl.trim();
    if (normalized.isEmpty) {
      return false;
    }
    return _sunoVersions.any(
      (version) => (version.songUrl ?? '').trim() == normalized,
    );
  }

  Future<Map<String, dynamic>> _songStatePayload(
    int articleId, {
    String? statusOverride,
    String? stylePromptOverride,
    String? errorMessageOverride,
  }) async {
    final article = await _songArticle(articleId);
    final activeSuno = await _activeSunoSongState(articleId);
    if (activeSuno != null) {
      var state = activeSuno;
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
    var state = cachedSuno ??
        ArticleSongState(
          articleId: articleId,
          status: 'empty',
          stylePrompt: '',
          source: 'suno',
        );
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
  }) async {
    try {
      final payload = await _songStatePayload(
        articleId,
        statusOverride: statusOverride,
        stylePromptOverride: stylePromptOverride,
        errorMessageOverride: errorMessageOverride,
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

  Future<void> _preloadListeningWindow(
    int articleId,
    List<Map<String, dynamic>> items, {
    required int startIndex,
    required String runId,
  }) async {
    final windowItems = _listeningWindowItems(
      items,
      startIndex: startIndex,
      lookaheadCount: 2,
    );
    final requests = <TtsPreloadRequest>[
      for (final item in windowItems)
        TtsPreloadRequest(
          text: (item['english'] ?? '').toString(),
          voiceType: TtsService.defaultVoiceType,
          preferRequestedVoice: false,
          cachePurpose: 'listening_tts',
          articleId: articleId,
        ),
    ];
    await _preloadTtsRequests(
      articleId: articleId,
      mode: 'listening',
      scope: 'english',
      requests: requests,
      runId: runId,
    );
  }

  Future<void> _preloadFollowArticle(
    Article article, {
    required String runId,
  }) async {
    final id = article.id;
    if (id == null) {
      return;
    }
    final requests = <TtsPreloadRequest>[
      for (final sentence in article.sentences)
        TtsPreloadRequest(
          text: sentence,
          voiceType: TtsService.defaultVoiceType,
          preferRequestedVoice: false,
          cachePurpose: 'follow_tts',
          articleId: id,
        ),
    ];
    await _preloadTtsRequests(
      articleId: id,
      mode: 'follow',
      scope: 'english',
      requests: requests,
      runId: runId,
    );
  }

  Future<void> _preloadTtsRequests({
    required int articleId,
    required String mode,
    required String scope,
    required List<TtsPreloadRequest> requests,
    required String runId,
  }) async {
    final total =
        requests.where((request) => request.text.trim().isNotEmpty).length;
    final aggregate = _preloadAggregate(articleId, mode, scope: scope);
    if (aggregate.runId != runId) {
      return;
    }
    aggregate.total = total;
    aggregate.completed = 0;
    aggregate.failed = 0;
    if (total == 0) {
      await _pushAggregatePreloadState(
        articleId,
        mode,
        scope: scope,
        runId: runId,
      );
      return;
    }
    await _pushAggregatePreloadState(
      articleId,
      mode,
      scope: scope,
      runId: runId,
    );
    await TtsMemoryCacheService.preload(
      requests,
      onProgress: (progress) {
        final current = _preloadAggregates[_preloadAggregateKey(
          articleId,
          mode,
          scope,
        )];
        if (current == null || current.runId != runId) {
          return;
        }
        current.completed = progress.completed;
        current.failed = progress.failed;
        current.total = progress.total;
        unawaited(_pushAggregatePreloadState(
          articleId,
          mode,
          scope: scope,
          runId: runId,
        ));
      },
    );
    await _pushAggregatePreloadState(
      articleId,
      mode,
      scope: scope,
      runId: runId,
    );
  }

  _PreloadAggregate _preloadAggregate(
    int articleId,
    String mode, {
    required String scope,
  }) {
    return _preloadAggregates.putIfAbsent(
      _preloadAggregateKey(articleId, mode, scope),
      () => _PreloadAggregate('idle_${articleId}_${mode}_$scope'),
    );
  }

  String _resetPreloadAggregate(
    int articleId,
    String mode, {
    required String scope,
  }) {
    final runId = '${mode}_${scope}_${articleId}_${++_preloadRunCounter}';
    _preloadAggregates[_preloadAggregateKey(articleId, mode, scope)] =
        _PreloadAggregate(runId);
    return runId;
  }

  void _clearPreloadAggregatesForArticle(int articleId) {
    _preloadAggregates.removeWhere(
      (key, _) => key.endsWith(':$articleId'),
    );
  }

  String _preloadAggregateKey(int articleId, String mode, String scope) =>
      '$mode:$scope:$articleId';

  Future<void> _pushAggregatePreloadState(
    int articleId,
    String mode, {
    required String scope,
    required String runId,
  }) {
    final aggregate = _preloadAggregate(articleId, mode, scope: scope);
    if (aggregate.runId != runId) {
      return Future<void>.value();
    }
    final loading = aggregate.completed < aggregate.total;
    final status = loading
        ? 'loading'
        : aggregate.failed > 0
            ? 'partial'
            : 'complete';
    return _pushPreloadState(
      articleId: articleId,
      mode: mode,
      scope: scope,
      status: status,
      completed: aggregate.completed,
      total: aggregate.total,
      failed: aggregate.failed,
      runId: aggregate.runId,
    );
  }

  Future<void> _pushPreloadState({
    required int articleId,
    required String mode,
    required String scope,
    required String status,
    required int completed,
    required int total,
    required int failed,
    required String runId,
  }) =>
      _pushEvent('preload.state', {
        'articleId': articleId,
        'mode': mode,
        'scope': scope,
        'runId': runId,
        'status': status,
        'completed': completed,
        'total': total,
        'failed': failed,
      });

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
    final article = await _articleWithCurrentSentences(rawArticle);
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

    final article = await _articleWithCurrentSentences(rawArticle);
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

    for (var position = 0; position < readinessItems.length; position += 1) {
      final item = readinessItems[position];
      final sentenceIndex = (item['index'] as num?)?.toInt() ?? position;
      final english = (item['english'] ?? '').toString().trim();
      if (english.isNotEmpty) {
        requiredEnglish += 1;
        final ready = await TtsMemoryCacheService.hasInMemory(
          text: english,
          voiceType: TtsService.defaultVoiceType,
          preferRequestedVoice: false,
          cachePurpose: 'listening_tts',
        );
        if (!ready) {
          missingEnglish.add(sentenceIndex);
        }
      }
    }

    final englishFailed = _preloadAggregates[
                _preloadAggregateKey(articleId, 'listening', 'english')]
            ?.failed ??
        0;
    const chineseFailed = 0;
    final reasons = <String>[];
    if (missingEnglish.isNotEmpty) {
      reasons.add('当前和下一句英文音频还没有加载到内存');
    }
    final failed = englishFailed + chineseFailed;
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
    final forceNew = _payloadBool(
      message.payload,
      'forceNew',
      fallback: false,
    );
    final cachedSuno = await _cachedSunoSongState(article);
    final requestedStylePrompt =
        _payloadString(message.payload, 'stylePrompt').trim();
    final cachedSunoStylePrompt = (cachedSuno?.stylePrompt ?? '').trim();
    final stylePrompt = requestedStylePrompt.isNotEmpty
        ? requestedStylePrompt
        : cachedSunoStylePrompt;
    if (!forceNew && cachedSuno != null) {
      final groups = await _cachedSunoSongGroups(article);
      final styleKey = _sunoStyleKey(stylePrompt);
      SunoCachedSongGroup? matchingGroup;
      for (final group in groups) {
        if (group.styleKey == styleKey) {
          matchingGroup = group;
          break;
        }
      }
      if (matchingGroup != null &&
          ((matchingGroup.songUrl ?? '').trim().isNotEmpty ||
              matchingGroup.detectedSongUrls.isNotEmpty)) {
        return _startExistingSunoDownload(
          article,
          stylePrompt: stylePrompt,
        );
      }
    }
    final lyrics = _payloadString(message.payload, 'lyrics').trim();
    return _startSunoAutomation(
      article: article,
      stylePrompt: stylePrompt,
      lyrics: lyrics.isEmpty ? _articleSongLyrics(article) : lyrics,
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
    if (_sunoArticleId != articleId) {
      throw const FormatException('当前没有等待确认的 Suno 歌曲任务');
    }
    if (_sunoAutomationStatus != 'waitingConfirm') {
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
    }
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
    final article = await _songArticle(articleId);
    final currentPayload = await _songStatePayload(articleId);
    final currentVersions = ((currentPayload['versions'] as List?) ?? const [])
        .map(ArticleSongVersion.fromJson)
        .whereType<ArticleSongVersion>()
        .toList();
    if (currentVersions.isEmpty) {
      throw const FormatException('还没有可用的本地歌曲版本');
    }
    var found = false;
    final updatedVersions = currentVersions.map((version) {
      final selected = version.id == versionId;
      found = found || selected;
      return version.copyWith(isDefault: selected);
    }).toList(growable: false);
    if (!found) {
      throw FormatException('没有找到歌曲版本：$versionId');
    }
    if (_sunoArticleId == articleId) {
      _sunoVersions
        ..clear()
        ..addAll(updatedVersions);
    }
    final versionsByStyle = <String, List<ArticleSongVersion>>{};
    final stylePromptByKey = <String, String>{};
    for (final version in updatedVersions) {
      final stylePrompt = (version.stylePrompt ?? '').trim();
      final savedStyleKey = (version.styleKey ?? '').trim();
      final styleKey =
          savedStyleKey.isNotEmpty ? savedStyleKey : _sunoStyleKey(stylePrompt);
      versionsByStyle
          .putIfAbsent(styleKey, () => <ArticleSongVersion>[])
          .add(version);
      stylePromptByKey.putIfAbsent(styleKey, () => stylePrompt);
    }
    for (final entry in versionsByStyle.entries) {
      await _saveSunoMetadataForVersions(
        article: article,
        versions: entry.value,
        stylePrompt: stylePromptByKey[entry.key] ?? '',
      );
    }
    return _songStatePayload(articleId);
  }

  Future<Map<String, dynamic>> _handleListeningSongStop(
    BridgeMessage message,
  ) async {
    await _stopSongPlayback();
    return {'stopped': true};
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
    final lyricLines = _articleSongLyrics(article)
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    final translations = <int, String>{};
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
    final result = await SongSubtitleTimelineService.generate(
      articleId: articleId,
      audioPath: version.audioPath,
      lyricLines: lyricLines,
      translations: translations,
      source: 'suno',
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
      timelinePath: result.timelinePath,
      timelineStatus: 'ready',
      timelineConfidence: result.timeline.confidence,
      timelineError: null,
      isDefault: version.isDefault,
    );
    await _persistUpdatedSunoVersion(article, updated);
    return updated;
  }

  Future<void> _persistUpdatedSunoVersion(
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
    if (_sunoArticleId == articleId) {
      _sunoVersions
        ..clear()
        ..addAll(currentVersions);
    }
    await _saveSunoMetadataForVersions(
      article: article,
      versions: currentVersions,
      stylePrompt: updated.stylePrompt ?? _sunoStylePrompt,
    );
  }

  Future<void> _saveSunoMetadataForVersions({
    required Article article,
    required List<ArticleSongVersion> versions,
    required String stylePrompt,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      return;
    }
    final normalizedStylePrompt = stylePrompt.trim();
    final styleKey = _sunoStyleKey(normalizedStylePrompt);
    final currentVersions = versions
        .where((version) => (version.styleKey ?? styleKey).trim() == styleKey)
        .toList(growable: false);
    final settings = await _songSettingsPayload();
    final directory = Directory(
      (settings['sunoOutputDirectory'] ?? _defaultSunoOutputDirectory())
          .toString(),
    );
    await directory.create(recursive: true);
    final metadataPath = path_lib.join(
      directory.path,
      'article_${articleId}_suno_${DateTime.now().millisecondsSinceEpoch}.json',
    );
    final detectedSongUrls = currentVersions
        .map((version) => (version.songUrl ?? '').trim())
        .where((value) => value.isNotEmpty && !_isSyntheticSunoSongKey(value))
        .toSet()
        .toList(growable: false);
    final currentAudioPath =
        currentVersions.isNotEmpty ? currentVersions.first.audioPath : null;
    final currentSongUrl = _firstNonEmptyString(
      currentVersions.map((version) => version.songUrl),
    );
    final metadata = {
      'provider': 'suno',
      'articleId': articleId,
      'articleTitle': article.title,
      'stylePrompt': normalizedStylePrompt,
      'styleKey': styleKey,
      'songUrl': currentSongUrl,
      'detectedSongUrls': detectedSongUrls,
      'downloadComplete': detectedSongUrls.isNotEmpty,
      'audioPath': currentAudioPath,
      'metadataPath': metadataPath,
      'versions': currentVersions.map((version) => version.toJson()).toList(),
      'manualActionMessage': null,
      'createdAt': DateTime.now().toIso8601String(),
    };
    await File(metadataPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(metadata),
      flush: true,
    );
    if (_sunoArticleId == articleId &&
        styleKey == _sunoStyleKey(_sunoStylePrompt)) {
      _sunoMetadataPath = metadataPath;
    }
    final request = {
      'version': 1,
      'provider': 'suno',
      'articleId': articleId,
      'articleTitle': article.title,
      'contentHash': await _articleSongContentHash(article),
      'stylePrompt': normalizedStylePrompt,
    };
    final cacheKey = await ApiCacheService.keyForJson(
      'article_suno_song',
      request,
    );
    await ApiCacheService.putJson(
      cacheKey: cacheKey,
      kind: 'suno_music',
      purpose: _sunoSongPurpose,
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
    final articleId = article.id;
    if (articleId == null) {
      throw const FormatException('文章尚未保存，不能生成歌曲');
    }
    if (lyrics.trim().isEmpty) {
      throw const FormatException('文章没有可用于 Suno 的英文歌词');
    }
    _stopSunoAutomation(clearVisible: false);
    _sunoArticleId = articleId;
    _sunoStylePrompt = stylePrompt.trim();
    _sunoLyrics = lyrics.trim();
    _sunoInitialUrl = 'https://suno.com/create';
    _sunoIgnoredStylePrompt = '';
    _sunoAutomationStatus = completedStandby ? 'complete' : 'waitingLogin';
    _sunoManualActionMessage = completedStandby
        ? '这首歌词和当前风格的 Suno 完整版已完成生成和下载。Tomato 已填好歌词和上一次风格；如需新版本，请在 Suno 页面改动风格后自行点击 Create。'
        : 'Suno 页面已打开，请先在页面中自行登录。';
    _sunoErrorMessage = null;
    _sunoSongUrl = null;
    _sunoAudioPath = null;
    _sunoMetadataPath = null;
    _sunoCreditsRemaining = null;
    _sunoStyleMagicRequestedAt = null;
    _sunoVersions.clear();
    _sunoDownloadedSongUrls.clear();
    _sunoDownloadedDownloadKeys.clear();
    _sunoDownloadInFlightKeys.clear();
    _sunoDetectedSongUrls.clear();
    _sunoPendingDownloadSongUrl = null;
    _sunoPendingDownloadTitle = null;
    _sunoExistingDownloadStartedAt = null;
    _sunoExistingDownloadMenuRetries = 0;
    _sunoExistingDownloadLibraryTried = false;
    final cachedGroups = await _cachedSunoSongGroups(article);
    final cachedSuno = await _cachedSunoSongState(article);
    if (cachedSuno != null && cachedSuno.versions.isNotEmpty) {
      _sunoVersions.addAll(cachedSuno.versions);
      _rememberCurrentStyleDownloadedSunoUrls();
    }
    for (final group in cachedGroups) {
      if (group.styleKey == _sunoStyleKey(_sunoStylePrompt)) {
        _sunoDetectedSongUrls.addAll(group.detectedSongUrls);
        break;
      }
    }
    _syncCurrentStyleDownloadedSunoUrlsIntoDetected();
    _sunoCreateSubmitted = false;
    _sunoExistingDownloadOnly = false;
    _sunoCompletedStandby = completedStandby;
    _sunoCompletedStandbyFilled = false;
    _sunoVisible = true;
    TomatoLogger.info(
      category: 'suno',
      event: 'automation.started',
      articleId: articleId,
      status: _sunoAutomationStatus,
      data: {
        'articleTitle': article.title,
        'styleSource': stylePrompt.trim().isEmpty ? 'suno_magic' : 'cached',
        'styleLength': _sunoStylePrompt.length,
        'lyricsLength': _sunoLyrics.length,
        'cachedVersions': _sunoVersions.length,
      },
    );
    if (mounted) {
      setState(() {});
    }
    unawaited(_pushSongState(articleId));
    _startSunoPolling();
    return _songStatePayload(articleId);
  }

  Future<Map<String, dynamic>> _startExistingSunoDownload(
    Article article, {
    String? stylePrompt,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      throw const FormatException('文章尚未保存，不能下载歌曲');
    }
    final cachedSuno = await _cachedSunoSongState(article);
    final groups = await _cachedSunoSongGroups(article);
    if (cachedSuno == null || groups.isEmpty) {
      throw const FormatException('没有找到可重新检测下载的 Suno 歌曲链接');
    }
    final requestedStyleKey = _sunoStyleKey(stylePrompt ?? '');
    final group = groups.firstWhere(
      (item) => (stylePrompt ?? '').trim().isNotEmpty
          ? item.styleKey == requestedStyleKey
          : item.styleKey == _sunoStyleKey(cachedSuno.stylePrompt),
      orElse: () => groups.first,
    );
    final songUrl = (group.missingSongUrls.isNotEmpty
            ? group.missingSongUrls.first
            : group.songUrl ?? '')
        .trim();
    if (group.hasKnownCompleteDownloads) {
      return _startSunoAutomation(
        article: article,
        stylePrompt: group.stylePrompt,
        lyrics: _articleSongLyrics(article),
        completedStandby: true,
      );
    }
    if (songUrl.isEmpty && group.detectedSongUrls.isEmpty) {
      throw const FormatException('没有找到可重新检测下载的 Suno 歌曲链接');
    }

    _stopSunoAutomation(clearVisible: false);
    _sunoArticleId = articleId;
    _sunoStylePrompt = group.stylePrompt.trim();
    _sunoLyrics = _articleSongLyrics(article);
    _sunoInitialUrl = songUrl.isEmpty ? 'https://suno.com/create' : songUrl;
    _sunoAutomationStatus = 'downloading';
    _sunoManualActionMessage = '正在打开 Suno 已生成歌曲并尝试下载...';
    _sunoErrorMessage = null;
    _sunoSongUrl = songUrl.isEmpty ? group.songUrl : songUrl;
    _sunoAudioPath = null;
    _sunoMetadataPath = group.metadataPath;
    _sunoCreditsRemaining = null;
    _sunoStyleMagicRequestedAt = null;
    _sunoVersions
      ..clear()
      ..addAll(cachedSuno.versions);
    _sunoDownloadedSongUrls.clear();
    _sunoDownloadedDownloadKeys.clear();
    _sunoDownloadInFlightKeys.clear();
    _sunoDetectedSongUrls
      ..clear()
      ..addAll(group.detectedSongUrls);
    _rememberCurrentStyleDownloadedSunoUrls();
    _syncCurrentStyleDownloadedSunoUrlsIntoDetected();
    _sunoPendingDownloadSongUrl = songUrl.isEmpty ? null : songUrl;
    _sunoPendingDownloadTitle = article.title;
    _sunoExistingDownloadStartedAt = DateTime.now();
    _sunoExistingDownloadMenuRetries = 0;
    _sunoCreateSubmitted = true;
    _sunoExistingDownloadOnly = true;
    _sunoCompletedStandby = false;
    _sunoCompletedStandbyFilled = false;
    _sunoVisible = true;
    TomatoLogger.info(
      category: 'suno',
      event: 'existing_download.started',
      articleId: articleId,
      status: _sunoAutomationStatus,
      data: {
        'songUrl': songUrl,
        'styleLength': _sunoStylePrompt.length,
        'metadataPath': group.metadataPath,
        'detectedSongUrls': group.detectedSongUrls.length,
        'cachedVersions': group.versions.length,
      },
    );
    if (mounted) {
      setState(() {});
    }
    final controller = _sunoController;
    if (controller != null) {
      unawaited(
        controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(songUrl)),
        ),
      );
    }
    unawaited(_pushSongState(articleId));
    _startSunoPolling();
    return _songStatePayload(articleId);
  }

  void _startSunoPolling() {
    _sunoAutomationTimer?.cancel();
    _sunoAutomationTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_continueSunoAutomation()),
    );
    unawaited(_continueSunoAutomation());
  }

  void _closeCompletedSunoOverlay() {
    final articleId = _sunoArticleId;
    _stopSunoAutomation(clearVisible: true);
    if (articleId != null) {
      unawaited(_pushSongState(articleId));
    }
  }

  void _stopSunoAutomation({required bool clearVisible}) {
    final articleId = _sunoArticleId;
    final previousStatus = _sunoAutomationStatus;
    _sunoAutomationTimer?.cancel();
    _sunoAutomationTimer = null;
    _sunoAutomationBusy = false;
    _sunoCreateSubmitted = false;
    _sunoExistingDownloadOnly = false;
    _sunoCompletedStandby = false;
    _sunoCompletedStandbyFilled = false;
    _sunoStyleMagicRequestedAt = null;
    _sunoIgnoredStylePrompt = '';
    _sunoPendingDownloadSongUrl = null;
    _sunoPendingDownloadTitle = null;
    _sunoExistingDownloadStartedAt = null;
    _sunoExistingDownloadMenuRetries = 0;
    _sunoLastLoadStopUrl = null;
    _sunoLastLoadStopAt = null;
    _sunoDownloadInFlightKeys.clear();
    if (clearVisible && mounted) {
      setState(() {
        _sunoVisible = false;
      });
    } else if (clearVisible) {
      _sunoVisible = false;
    }
    if (clearVisible) {
      _sunoAutomationStatus = 'idle';
      _sunoManualActionMessage = null;
      _sunoErrorMessage = null;
      _sunoDetectedSongUrls.clear();
    }
    TomatoLogger.info(
      category: 'suno',
      event: 'automation.stopped',
      articleId: articleId,
      status: _sunoAutomationStatus,
      data: {
        'previousStatus': previousStatus,
        'clearVisible': clearVisible,
      },
    );
  }

  Future<void> _continueSunoAutomation() async {
    if (_sunoAutomationBusy || _sunoArticleId == null) {
      return;
    }
    final controller = _sunoController;
    if (controller == null) {
      return;
    }
    _sunoAutomationBusy = true;
    try {
      final inspect = await _evaluateSunoJson(controller, _sunoInspectScript);
      final loggedIn = inspect['loggedIn'] == true;
      _sunoCreditsRemaining = (inspect['creditsRemaining'] as num?)?.toInt();
      if (!loggedIn) {
        await _setSunoStatus(
          'waitingLogin',
          'Suno 页面已打开，请先在页面中自行登录。',
        );
        return;
      }
      if (_sunoExistingDownloadOnly &&
          (_sunoAutomationStatus == 'manualAction' ||
              _sunoAutomationStatus == 'failed' ||
              _sunoAutomationStatus == 'complete')) {
        return;
      }
      if (_sunoCompletedStandby) {
        final currentUrl = (await controller.getUrl())?.toString() ?? '';
        var styleChanged = false;
        if (_sunoPageKind(currentUrl) == 'create') {
          if (!_sunoCompletedStandbyFilled) {
            final fill = await _evaluateSunoJson(
              controller,
              _sunoFillScript(
                lyrics: _sunoLyrics,
                stylePrompt: _sunoStylePrompt,
                ignoredStylePrompt: _sunoIgnoredStylePrompt,
                allowMagicClick: false,
                magicAlreadyRequested: true,
              ),
            );
            final filledStyle = (fill['stylePrompt'] ?? '').toString().trim();
            if (filledStyle.isNotEmpty) {
              _sunoStylePrompt = filledStyle;
            }
            if (fill['ok'] == true) {
              _sunoCompletedStandbyFilled = true;
              await _setSunoStatus(
                'complete',
                '这首歌词和当前风格的 Suno 完整版已完成生成和下载。Tomato 已填好歌词和上一次风格，等待你自行改风格或点击 Create。',
              );
            } else {
              await _setSunoStatus(
                'manualAction',
                (fill['message'] ?? '').toString().trim().isEmpty
                    ? 'Tomato 正在填写 Suno Create 表单，填好后会停止自动操作并等待你自行改风格或点击 Create。'
                    : (fill['message'] ?? '').toString(),
              );
            }
            return;
          }
          final probe = await _evaluateSunoJson(
            controller,
            _sunoFillScript(
              lyrics: _sunoLyrics,
              stylePrompt: _sunoStylePrompt,
              ignoredStylePrompt: _sunoIgnoredStylePrompt,
              allowMagicClick: false,
              magicAlreadyRequested: _sunoStyleMagicRequestedAt != null,
              readOnly: true,
            ),
          );
          final currentStyle = (probe['stylePrompt'] ?? '').toString().trim();
          if (currentStyle.isNotEmpty &&
              currentStyle != _sunoStylePrompt.trim()) {
            _sunoStylePrompt = currentStyle;
            _sunoDetectedSongUrls.clear();
            _rememberCurrentStyleDownloadedSunoUrls();
            styleChanged = true;
            await _setSunoStatus(
              'manualAction',
              '检测到你已修改 Suno 风格。请在 Suno 页面自行点击 Create；生成完成后 Tomato 会自动下载全部完整版。',
            );
          }
        }
        final result = await _evaluateSunoJson(
          controller,
          _sunoCompletionScript(
            expectedStylePrompt: _sunoStylePrompt,
            expectedLyrics: _sunoLyrics,
            requireExpectedMatch: true,
          ),
        );
        final detectedSongUrls = (result['songUrls'] as List?)
                ?.map((value) => value.toString().trim())
                .where((value) =>
                    value.isNotEmpty && !_isSyntheticSunoSongKey(value))
                .toList() ??
            <String>[];
        final newUrls = detectedSongUrls
            .where((value) =>
                !_sunoDetectedSongUrls.contains(value) &&
                !_sunoDownloadedSongUrls.contains(value) &&
                !_hasSunoVersionForSongUrl(value))
            .toList();
        if (newUrls.isNotEmpty) {
          _sunoDetectedSongUrls
            ..clear()
            ..addAll(detectedSongUrls);
          _syncCurrentStyleDownloadedSunoUrlsIntoDetected();
          _sunoSongUrl = newUrls.first;
          _sunoPendingDownloadSongUrl = newUrls.first;
          _sunoCreateSubmitted = true;
          _sunoExistingDownloadOnly = false;
          _sunoCompletedStandby = false;
          await _setSunoStatus(
            'downloading',
            '检测到新的 Suno 完整歌曲，正在下载全部版本...',
          );
        } else {
          if (!styleChanged && _currentSunoDownloadsComplete()) {
            await _setSunoStatus(
              'complete',
              '这首歌词和当前风格的 Suno 完整版已完成生成和下载。Tomato 已停在 Create 页面并填好歌词和上一次风格，等待你自行改风格或点击 Create。',
            );
          } else {
            await _setSunoStatus(
              'manualAction',
              '请在 Suno 页面自行点击 Create；生成完成后 Tomato 会自动下载全部完整版。',
            );
          }
        }
        return;
      }
      if (!_sunoExistingDownloadOnly &&
          (_sunoAutomationStatus == 'waitingLogin' ||
              _sunoAutomationStatus == 'manualAction' ||
              _sunoAutomationStatus == 'failed')) {
        final currentUrl = (await controller.getUrl())?.toString() ?? '';
        if (_sunoPageKind(currentUrl) != 'create') {
          await controller.loadUrl(
            urlRequest: URLRequest(url: WebUri('https://suno.com/create')),
          );
          await _setSunoStatus(
            'manualAction',
            'Suno 当前不在 Create 页面，Tomato 正在重新打开 Create 后再填写。',
          );
          return;
        }
        final now = DateTime.now();
        final allowMagicClick = _sunoStyleMagicRequestedAt == null ||
            now.difference(_sunoStyleMagicRequestedAt!) >
                const Duration(seconds: 18);
        final fill = await _evaluateSunoJson(
          controller,
          _sunoFillScript(
            lyrics: _sunoLyrics,
            stylePrompt: _sunoStylePrompt,
            ignoredStylePrompt: _sunoIgnoredStylePrompt,
            allowMagicClick: allowMagicClick,
            magicAlreadyRequested: _sunoStyleMagicRequestedAt != null,
          ),
        );
        TomatoLogger.info(
          category: 'suno',
          event: 'create.fill_probe',
          articleId: _sunoArticleId,
          status: _sunoAutomationStatus,
          data: {
            'ok': fill['ok'],
            'retry': fill['retry'],
            'missing': fill['missing'],
            'fieldCount': fill['fieldCount'],
            'magicClicked': fill['magicClicked'],
            'styleLength': (fill['stylePrompt'] ?? '').toString().length,
          },
        );
        final ignoredStylePrompt =
            (fill['ignoredStylePrompt'] ?? '').toString().trim();
        if (ignoredStylePrompt.isNotEmpty && _sunoStylePrompt.trim().isEmpty) {
          _sunoIgnoredStylePrompt = ignoredStylePrompt;
        }
        final generatedStyle = (fill['stylePrompt'] ?? '').toString().trim();
        if (generatedStyle.isNotEmpty) {
          _sunoStylePrompt = generatedStyle;
          _sunoIgnoredStylePrompt = '';
          _sunoStyleMagicRequestedAt = null;
        }
        if (fill['magicClicked'] == true) {
          _sunoStyleMagicRequestedAt = DateTime.now();
        }
        if (fill['ok'] == true) {
          await _setSunoStatus(
            'waitingConfirm',
            'Suno 歌词和自动风格已填写，请确认消耗 Suno credits 后创建。',
          );
          return;
        }
        if (fill['retry'] == true) {
          await _setSunoStatus(
            'manualAction',
            (fill['message'] ?? '').toString().trim().isEmpty
                ? 'Tomato 正在等待 Suno 页面完成当前自动操作。'
                : (fill['message'] ?? '').toString(),
          );
          return;
        }
        final missing = (fill['missing'] as List?)
                ?.map((value) => value.toString())
                .where((value) => value.trim().isNotEmpty)
                .join(', ') ??
            '';
        final fieldCount = (fill['fieldCount'] as num?)?.toInt();
        final diagnostics = [
          if (missing.isNotEmpty) '缺少：$missing',
          if (fieldCount != null) '候选输入框：$fieldCount 个',
        ].join('；');
        await _setSunoStatus(
          'manualAction',
          diagnostics.isEmpty
              ? 'Tomato 没能准确找到 Suno Advanced 歌词或风格输入框，请在页面中手工填写后点击“继续检测”。'
              : 'Tomato 没能准确找到 Suno Advanced 歌词或风格输入框（$diagnostics）。请在页面中手工填写后点击“继续检测”。',
        );
        return;
      }
      if (_sunoCreateSubmitted) {
        final result = await _evaluateSunoJson(
          controller,
          _sunoCompletionScript(
            expectedStylePrompt: _sunoStylePrompt,
            expectedLyrics: _sunoLyrics,
            requireExpectedMatch: true,
          ),
        );
        TomatoLogger.info(
          category: 'suno',
          event: 'completion.probe',
          articleId: _sunoArticleId,
          status: _sunoAutomationStatus,
          data: {
            'ok': result['ok'],
            'songUrl': result['songUrl'],
            'songUrlCount': (result['songUrls'] as List?)?.length ?? 0,
            'currentPageExpectedScore': result['currentPageExpectedScore'],
            'expectedMatchThreshold': result['expectedMatchThreshold'],
          },
        );
        var songUrl = (result['songUrl'] ?? '').toString().trim();
        final knownSongUrl = (_sunoSongUrl ?? '').trim();
        if (_sunoExistingDownloadOnly && knownSongUrl.isNotEmpty) {
          songUrl = knownSongUrl;
        } else if (songUrl.isEmpty && knownSongUrl.isNotEmpty) {
          songUrl = knownSongUrl;
        }
        if (songUrl.isNotEmpty) {
          _sunoSongUrl = songUrl;
          final currentUrl = (await controller.getUrl())?.toString() ?? '';
          final currentPageKind = _sunoPageKind(currentUrl);
          if (_sunoExistingDownloadOnly &&
              currentPageKind == 'song' &&
              !_isSunoPageSettled(currentUrl)) {
            await _setSunoStatus(
              'downloading',
              '正在等待 Suno 歌曲详情页加载完成后检测完整歌曲列表...',
            );
            return;
          }
          if (_sunoExistingDownloadOnly &&
              songUrl.startsWith('https://') &&
              !currentUrl.startsWith(songUrl)) {
            final alreadyTriedSongDetail =
                _sunoPendingDownloadSongUrl == songUrl;
            _sunoPendingDownloadSongUrl = songUrl;
            if (!alreadyTriedSongDetail && !_isSunoProfileUrl(currentUrl)) {
              await controller.loadUrl(
                urlRequest: URLRequest(url: WebUri(songUrl)),
              );
              await _setSunoStatus(
                'downloading',
                '正在打开 Suno E28 歌曲详情页准备下载...',
              );
              return;
            }
            if (alreadyTriedSongDetail &&
                currentPageKind != 'library' &&
                currentPageKind != 'profile' &&
                !_sunoExistingDownloadLibraryTried) {
              _sunoExistingDownloadLibraryTried = true;
              await controller.loadUrl(
                urlRequest: URLRequest(url: WebUri('https://suno.com/me')),
              );
              await _setSunoStatus(
                'downloading',
                'Suno 页面跳到了非歌曲页，正在打开 Library 查找对应完整歌曲...',
              );
              return;
            }
            if (_isSunoProfileUrl(currentUrl)) {
              await _setSunoStatus(
                'downloading',
                'Suno 打开歌曲链接后跳到了个人主页，Tomato 将只在当前页面查找下载入口，不再反复刷新。',
              );
            }
          }
          if (_sunoExistingDownloadOnly &&
              songUrl.startsWith('https://') &&
              !currentUrl.startsWith(songUrl) &&
              !_isSunoProfileUrl(currentUrl) &&
              _sunoPendingDownloadSongUrl != songUrl) {
            return;
          }
          final detectedSongUrls = (result['songUrls'] as List?)
                  ?.map((value) => value.toString().trim())
                  .where((value) => value.isNotEmpty)
                  .toList() ??
              <String>[];
          final realDetectedSongUrls = detectedSongUrls
              .where((value) => !_isSyntheticSunoSongKey(value))
              .toList(growable: false);
          if (realDetectedSongUrls.isNotEmpty) {
            _sunoDetectedSongUrls.addAll(realDetectedSongUrls);
            _syncCurrentStyleDownloadedSunoUrlsIntoDetected();
          }
          final songUrls =
              detectedSongUrls.isEmpty ? <String>[songUrl] : detectedSongUrls;
          final completedUrls = songUrls
              .where((value) =>
                  !_sunoDownloadedSongUrls.contains(value) &&
                  !_hasSunoVersionForSongUrl(value))
              .toList();
          if (completedUrls.isEmpty && _sunoVersions.isNotEmpty) {
            if (_sunoExistingDownloadOnly &&
                !_sunoExistingDownloadLibraryTried &&
                currentPageKind != 'library') {
              _sunoExistingDownloadLibraryTried = true;
              _sunoPendingDownloadSongUrl = songUrl;
              await controller.loadUrl(
                urlRequest: URLRequest(url: WebUri('https://suno.com/me')),
              );
              await _setSunoStatus(
                'downloading',
                '歌曲详情页只看到已下载版本，正在打开 Suno Library 检测同风格的其它完整歌曲...',
              );
              return;
            }
            if (_sunoExistingDownloadOnly && realDetectedSongUrls.isEmpty) {
              await _setSunoStatus(
                'downloading',
                '正在等待 Suno 页面露出同风格完整歌曲列表...',
              );
              return;
            }
            await _saveSunoMetadata();
            await _setSunoStatus('complete', null);
            _sunoAutomationTimer?.cancel();
            return;
          }
          final mediaBySongUrl = <String, String>{};
          final rawMediaBySongUrl = result['mediaBySongUrl'];
          if (rawMediaBySongUrl is Map) {
            for (final entry in rawMediaBySongUrl.entries) {
              final key = entry.key.toString().trim();
              final value = entry.value.toString().trim();
              if (key.isNotEmpty && value.isNotEmpty) {
                mediaBySongUrl[key] = value;
              }
            }
          }
          final directMediaDownloaded = await _downloadSunoDirectMediaUrls(
            articleId: _sunoArticleId!,
            songUrls: completedUrls,
            mediaBySongUrl: mediaBySongUrl,
            fallbackMediaUrl: (result['mediaUrl'] ?? '').toString(),
          );
          if (directMediaDownloaded > 0) {
            final remainingUrls = songUrls
                .where((value) => !_sunoDownloadedSongUrls.contains(value))
                .toList();
            if (remainingUrls.isEmpty) {
              await _setSunoStatus('complete', null);
              _sunoAutomationTimer?.cancel();
              return;
            }
            await _setSunoStatus(
              'downloading',
              '已直接保存 $directMediaDownloaded 个 Suno 完整版本，正在检查其它版本...',
            );
            return;
          }
          final download = await _evaluateSunoJson(
            controller,
            _sunoDownloadScript(
              downloadedSongUrls: _sunoDownloadedSongUrls.toList(),
              pendingSongUrl: _pendingSunoDownloadTarget(completedUrls),
              allowedSongUrls: completedUrls,
              expectedStylePrompt: _sunoStylePrompt,
              expectedLyrics: _sunoLyrics,
              requireExpectedMatch: true,
            ),
          );
          TomatoLogger.info(
            category: 'suno',
            event: 'download.probe',
            articleId: _sunoArticleId,
            status: _sunoAutomationStatus,
            data: _sunoDownloadProbeLogData(download),
          );
          final pendingSongUrl = (download['songUrl'] ?? '').toString().trim();
          final pendingTitle = (download['title'] ?? '').toString().trim();
          if (pendingSongUrl.isNotEmpty &&
              !_isSyntheticSunoSongKey(pendingSongUrl)) {
            _sunoPendingDownloadSongUrl = pendingSongUrl;
          }
          if (pendingTitle.isNotEmpty) {
            _sunoPendingDownloadTitle = pendingTitle;
          }
          if (download['ok'] == true || download['retry'] == true) {
            final downloadStage = (download['stage'] ?? '').toString();
            if (download['retry'] == true && downloadStage == 'menu') {
              _sunoExistingDownloadMenuRetries += 1;
              if (_sunoExistingDownloadOnly &&
                  _sunoExistingDownloadMenuRetries >= 3 &&
                  !_sunoExistingDownloadLibraryTried &&
                  _sunoPageKind(currentUrl) != 'library') {
                _sunoExistingDownloadLibraryTried = true;
                _sunoPendingDownloadSongUrl = songUrl;
                await controller.loadUrl(
                  urlRequest: URLRequest(url: WebUri('https://suno.com/me')),
                );
                await _setSunoStatus(
                  'downloading',
                  '歌曲详情页菜单没有露出下载入口，正在打开 Suno Library 查找对应完整歌曲...',
                );
                return;
              }
              if (_sunoExistingDownloadOnly &&
                  _sunoExistingDownloadMenuRetries >= 3 &&
                  _sunoPageKind(currentUrl) == 'library') {
                await _saveSunoMetadata(
                  manualActionMessage:
                      'Suno 已检测到缺失完整歌曲，但 Library 菜单没有露出 Download/Audio 项。',
                );
                await _setSunoStatus(
                  'manualAction',
                  'Suno 已检测到缺失完整歌曲，但 Library 菜单没有露出 Download/Audio 项。请在 Suno 页面手动下载音频，Tomato 会保存已能自动获取的版本。',
                );
                _sunoAutomationTimer?.cancel();
                return;
              }
            } else if (download['ok'] == true) {
              _sunoExistingDownloadMenuRetries = 0;
            }
            await _saveSunoMetadata(
              manualActionMessage:
                  'Suno 已生成 ${songUrls.length} 个完整版本，Tomato 正在下载未保存的版本。',
            );
            await _setSunoStatus(
              'downloading',
              '正在下载 Suno 缺失歌曲版本 1 / ${completedUrls.length}...',
            );
            return;
          }
          if (_sunoExistingDownloadOnly &&
              !_sunoExistingDownloadLibraryTried &&
              _sunoPageKind(currentUrl) != 'library') {
            _sunoExistingDownloadLibraryTried = true;
            _sunoPendingDownloadSongUrl = songUrl;
            await controller.loadUrl(
              urlRequest: URLRequest(url: WebUri('https://suno.com/me')),
            );
            await _setSunoStatus(
              'downloading',
              '歌曲详情页没有露出下载入口，正在打开 Suno Library 查找对应完整歌曲...',
            );
            return;
          }
          await _saveSunoMetadata(
            manualActionMessage: 'Suno 已生成完整歌曲，但 Tomato 没能找到可自动点击的音频下载入口。',
          );
          await _setSunoStatus(
            'manualAction',
            (download['message'] ?? '').toString().trim().isEmpty
                ? 'Suno 已生成完整歌曲，但 Tomato 没能找到可自动点击的音频下载入口。请在页面中点击下载音频。'
                : (download['message'] ?? '').toString(),
          );
          _sunoAutomationTimer?.cancel();
        } else if (_sunoExistingDownloadOnly) {
          final download = await _evaluateSunoJson(
            controller,
            _sunoDownloadScript(
              downloadedSongUrls: _sunoDownloadedSongUrls.toList(),
              pendingSongUrl: _sunoPendingDownloadSongUrl,
              allowedSongUrls: const <String>[],
              expectedStylePrompt: _sunoStylePrompt,
              expectedLyrics: _sunoLyrics,
              requireExpectedMatch: true,
            ),
          );
          TomatoLogger.info(
            category: 'suno',
            event: 'download.probe',
            articleId: _sunoArticleId,
            status: _sunoAutomationStatus,
            data: _sunoDownloadProbeLogData(download),
          );
          final pendingSongUrl = (download['songUrl'] ?? '').toString().trim();
          final pendingTitle = (download['title'] ?? '').toString().trim();
          if (pendingSongUrl.isNotEmpty &&
              !_isSyntheticSunoSongKey(pendingSongUrl)) {
            _sunoPendingDownloadSongUrl = pendingSongUrl;
          }
          if (pendingTitle.isNotEmpty) {
            _sunoPendingDownloadTitle = pendingTitle;
          }
          if (download['ok'] == true || download['retry'] == true) {
            await _setSunoStatus(
              'downloading',
              '正在下载 Suno 已生成的 E28 完整歌曲...',
            );
            return;
          }
          final startedAt = _sunoExistingDownloadStartedAt;
          if (startedAt == null ||
              DateTime.now().difference(startedAt) <
                  const Duration(seconds: 75)) {
            await _setSunoStatus(
              'downloading',
              '正在等待 Suno 歌曲列表加载完成...',
            );
            return;
          }
          await _setSunoStatus(
            'manualAction',
            'Suno 页面中没有找到与当前 E28 歌词或风格匹配的完整歌曲，已停止自动下载以避免保存错歌。',
          );
          _sunoAutomationTimer?.cancel();
        } else {
          await _setSunoStatus('creating', 'Suno 正在生成歌曲...');
        }
      }
    } catch (error) {
      if (_isTransientSunoWebViewError(error)) {
        await _setSunoStatus(
          'manualAction',
          'Suno 页面控件还在初始化或刚刚重建，Tomato 会继续检测；也可以稍后点击“继续检测”。',
        );
        return;
      }
      await _failSunoAutomation(_displayError(error));
    } finally {
      _sunoAutomationBusy = false;
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _confirmSunoCreate() async {
    final controller = _sunoController;
    if (controller == null || _sunoArticleId == null) {
      return;
    }
    try {
      final result = await _evaluateSunoJson(controller, _sunoCreateScript);
      if (result['ok'] == true) {
        _sunoCreateSubmitted = true;
        _sunoCompletedStandby = false;
        _sunoCompletedStandbyFilled = false;
        _sunoDetectedSongUrls.clear();
        _rememberCurrentStyleDownloadedSunoUrls();
        await _setSunoStatus('creating', 'Suno 正在生成歌曲...');
        _startSunoPolling();
        return;
      }
      await _setSunoStatus(
        'manualAction',
        (result['message'] ?? '').toString().trim().isEmpty
            ? 'Tomato 没能点击 Suno Create，请检查页面字段或手工点击 Create。'
            : (result['message'] ?? '').toString(),
      );
    } catch (error) {
      if (_isTransientSunoWebViewError(error)) {
        await _setSunoStatus(
          'manualAction',
          'Suno 页面控件还在初始化或刚刚重建，请稍后再确认创建。',
        );
        return;
      }
      await _failSunoAutomation(_displayError(error));
    }
  }

  Future<void> _handleSunoDownload(DownloadStartRequest request) async {
    final articleId = _sunoArticleId;
    if (articleId == null) {
      return;
    }
    final songUrl = (_sunoPendingDownloadSongUrl ?? _sunoSongUrl ?? '').trim();
    final requestUrl = request.url.toString();
    if (_isRejectedSunoMediaUrl(requestUrl)) {
      TomatoLogger.info(
        category: 'suno',
        event: 'download.skipped_preview',
        articleId: articleId,
        status: _sunoAutomationStatus,
        data: {'requestUrl': requestUrl},
      );
      await _setSunoStatus(
        'downloading',
        '已跳过 Suno 预览片段，正在继续查找完整版下载...',
      );
      _startSunoPolling();
      return;
    }
    if (songUrl.isNotEmpty &&
        _isVerifiableSunoMediaUrl(requestUrl) &&
        _matchingSunoMediaUrl(requestUrl, songUrl) == null) {
      TomatoLogger.warn(
        category: 'suno',
        event: 'download.rejected_wrong_song',
        articleId: articleId,
        status: _sunoAutomationStatus,
        data: {
          'requestUrl': requestUrl,
          'targetSongUrl': songUrl,
        },
      );
      await _setSunoStatus(
        'manualAction',
        '已拦截一个不属于当前文章目标歌曲的 Suno 下载链接，避免保存错歌。请回到正确歌曲页后再继续检测。',
      );
      _sunoAutomationTimer?.cancel();
      return;
    }
    if (songUrl.isNotEmpty &&
        (_sunoDownloadedSongUrls.contains(songUrl) ||
            _hasSunoVersionForSongUrl(songUrl))) {
      _sunoDownloadedSongUrls.add(songUrl);
      _sunoDetectedSongUrls.add(songUrl);
      _sunoPendingDownloadSongUrl = null;
      _sunoPendingDownloadTitle = null;
      await _setSunoStatus(
        'downloading',
        '这个 Suno 版本已经下载过，正在检查其它版本...',
      );
      _startSunoPolling();
      return;
    }
    final downloadKey =
        songUrl.isNotEmpty ? 'song:$songUrl' : 'download:$requestUrl';
    if (_sunoDownloadInFlightKeys.contains(downloadKey) ||
        _sunoDownloadedDownloadKeys.contains(downloadKey)) {
      return;
    }
    _sunoDownloadInFlightKeys.add(downloadKey);
    await _setSunoStatus('downloading', '正在下载 Suno 生成的歌曲...');
    try {
      final settings = await _songSettingsPayload();
      final directory = Directory(
        (settings['sunoOutputDirectory'] ?? _defaultSunoOutputDirectory())
            .toString(),
      );
      await directory.create(recursive: true);
      final filename = _safeSunoFilename(request.suggestedFilename);
      final target = _uniqueSunoTargetFile(directory, filename);
      final bytes = await _downloadSunoUrl(
        requestUrl,
        userAgent: request.userAgent,
      );
      if (bytes.isEmpty) {
        throw const FormatException('下载结果为空');
      }
      await target.writeAsBytes(bytes, flush: true);
      _sunoAudioPath = target.path;
      if (songUrl.isNotEmpty) {
        _sunoDownloadedSongUrls.add(songUrl);
        _sunoDetectedSongUrls.add(songUrl);
      }
      _sunoDownloadedDownloadKeys.add(downloadKey);
      final version = ArticleSongVersion(
        id: 'suno_${articleId}_${DateTime.now().millisecondsSinceEpoch}_${_sunoVersions.length + 1}',
        audioPath: target.path,
        title: (_sunoPendingDownloadTitle ?? '').trim().isEmpty
            ? 'Suno 版本 ${_sunoVersions.length + 1}'
            : _sunoPendingDownloadTitle!.trim(),
        songUrl: songUrl.isEmpty ? _sunoSongUrl : songUrl,
        createdAt: DateTime.now().toIso8601String(),
        stylePrompt:
            _sunoStylePrompt.trim().isEmpty ? null : _sunoStylePrompt.trim(),
        styleKey: _sunoStyleKey(_sunoStylePrompt),
      );
      _sunoVersions.removeWhere((item) =>
          item.songUrl != null &&
          version.songUrl != null &&
          item.songUrl == version.songUrl);
      _sunoVersions.add(version);
      TomatoLogger.info(
        category: 'suno',
        event: 'download.saved',
        articleId: articleId,
        status: _sunoAutomationStatus,
        data: {
          'songUrl': version.songUrl,
          'bytes': bytes.length,
          'audioPath': target.path,
          'versionCount': _sunoVersions.length,
        },
      );
      _sunoPendingDownloadSongUrl = null;
      _sunoPendingDownloadTitle = null;
      await _saveSunoMetadata();
      await _setSunoStatus(
        'downloading',
        '已下载 ${_sunoVersions.length} 个 Suno 完整版本，正在检查是否还有其它版本...',
      );
      _startSunoPolling();
    } catch (error) {
      TomatoLogger.error(
        category: 'suno',
        event: 'download.failed',
        articleId: articleId,
        status: _sunoAutomationStatus,
        data: {
          'requestUrl': requestUrl,
          'targetSongUrl': songUrl,
        },
        error: error,
      );
      await _setSunoStatus(
        'manualAction',
        '自动下载失败：${_displayError(error)}。请在 Suno 页面手工下载音频。',
      );
    } finally {
      _sunoDownloadInFlightKeys.remove(downloadKey);
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
        'status': _sunoAutomationStatus,
      };
    }
    final url = await controller.getUrl();
    final inspect = await _evaluateSunoJson(controller, _sunoInspectScript);
    final diagnostics = await _evaluateSunoJson(
      controller,
      _sunoDomDiagnosticsScript,
    );
    return {
      'ok': true,
      'status': _sunoAutomationStatus,
      'manualActionMessage': _sunoManualActionMessage,
      'errorMessage': _sunoErrorMessage,
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
        'status': _sunoAutomationStatus,
      };
    }
    final rows = await _evaluateSunoJson(
      controller,
      _sunoRowsDebugScript(
        expectedStylePrompt: _sunoStylePrompt,
        expectedLyrics: _sunoLyrics,
      ),
    );
    return {
      'ok': true,
      'status': _sunoAutomationStatus,
      'stylePrompt': _sunoStylePrompt,
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
        'status': _sunoAutomationStatus,
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
    final pageKind = _sunoPageKind(url);
    final stem = _safeSunoSnapshotStem(url, timestamp);
    final warnings = <String>[];

    final inspect = await _evaluateSunoJson(controller, _sunoInspectScript);
    final diagnostics = await _evaluateSunoJson(
      controller,
      _sunoDomDiagnosticsScript,
    );
    final rows = await _evaluateSunoJson(
      controller,
      _sunoRowsDebugScript(
        expectedStylePrompt: _sunoStylePrompt,
        expectedLyrics: _sunoLyrics,
      ),
    );
    final completion = await _evaluateSunoJson(
      controller,
      _sunoCompletionScript(
        expectedStylePrompt: _sunoStylePrompt,
        expectedLyrics: _sunoLyrics,
        requireExpectedMatch: false,
      ),
    );
    final currentSongUrl = (_sunoSongUrl ?? '').trim();
    final shouldProbeDownload = pageKind == 'song' ||
        pageKind == 'library' ||
        pageKind == 'profile' ||
        _sunoExistingDownloadOnly ||
        _sunoCreateSubmitted ||
        _sunoAutomationStatus == 'downloading';
    final downloadProbe = shouldProbeDownload
        ? await _evaluateSunoJson(
            controller,
            _sunoDownloadScript(
              downloadedSongUrls: _sunoDownloadedSongUrls.toList(),
              pendingSongUrl: _sunoPendingDownloadSongUrl ?? currentSongUrl,
              allowedSongUrls:
                  currentSongUrl.isEmpty ? const <String>[] : [currentSongUrl],
              expectedStylePrompt: _sunoStylePrompt,
              expectedLyrics: _sunoLyrics,
              requireExpectedMatch: true,
              dryRun: true,
            ),
          )
        : <String, dynamic>{
            'skipped': true,
            'reason': 'not-download-page',
            'pageKind': pageKind,
          };
    final page = await _evaluateSunoJson(controller, _sunoSnapshotScript);
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
      'status': _sunoAutomationStatus,
      'manualActionMessage': _sunoManualActionMessage,
      'errorMessage': _sunoErrorMessage,
      'articleId': _sunoArticleId,
      'songUrl': _sunoSongUrl,
      'pendingSongUrl': _sunoPendingDownloadSongUrl,
      'existingDownloadOnly': _sunoExistingDownloadOnly,
      'createSubmitted': _sunoCreateSubmitted,
      'stylePrompt': _sunoStylePrompt,
      'lyricsSample': _sunoLyrics.length <= 1200
          ? _sunoLyrics
          : '${_sunoLyrics.substring(0, 1200)}...',
      'downloadedSongUrls': _sunoDownloadedSongUrls.toList(),
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
      'pageKind': _sunoPageKind(url),
      'status': _sunoAutomationStatus,
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
        'status': _sunoAutomationStatus,
      };
    }
    final lyrics = _payloadString(
      message.payload,
      'lyrics',
      fallback: _sunoLyrics.isEmpty
          ? 'Tomato Suno automation field detection test.'
          : _sunoLyrics,
    );
    final stylePrompt = _payloadString(
      message.payload,
      'stylePrompt',
      fallback: _sunoStylePrompt.isEmpty
          ? 'whimsical story song, gentle pop, bright piano'
          : _sunoStylePrompt,
    );
    return _evaluateSunoJson(
      controller,
      _sunoFillScript(
        lyrics: lyrics,
        stylePrompt: stylePrompt,
        ignoredStylePrompt: _payloadString(
          message.payload,
          'ignoredStylePrompt',
          fallback: _sunoIgnoredStylePrompt,
        ),
        allowMagicClick: true,
        magicAlreadyRequested: false,
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

  Future<int> _downloadSunoDirectMediaUrls({
    required int articleId,
    required Iterable<String> songUrls,
    required Map<String, String> mediaBySongUrl,
    String? fallbackMediaUrl,
  }) async {
    var downloadedCount = 0;
    final settings = await _songSettingsPayload();
    final directory = Directory(
      (settings['sunoOutputDirectory'] ?? _defaultSunoOutputDirectory())
          .toString(),
    );
    await directory.create(recursive: true);

    for (final rawSongUrl in songUrls) {
      final songUrl = rawSongUrl.trim();
      if (songUrl.isEmpty ||
          _sunoDownloadedSongUrls.contains(songUrl) ||
          _hasSunoVersionForSongUrl(songUrl)) {
        continue;
      }
      final mediaUrl = (mediaBySongUrl[songUrl] ??
              _matchingSunoMediaUrl(
                fallbackMediaUrl,
                songUrl,
              ) ??
              '')
          .trim();
      if (mediaUrl.isEmpty) {
        TomatoLogger.warn(
          category: 'suno',
          event: 'direct_media.missing',
          articleId: articleId,
          status: _sunoAutomationStatus,
          data: {'songUrl': songUrl},
        );
        continue;
      }
      final downloadKey = 'direct:$songUrl:$mediaUrl';
      if (_sunoDownloadInFlightKeys.contains(downloadKey) ||
          _sunoDownloadedDownloadKeys.contains(downloadKey)) {
        continue;
      }
      _sunoDownloadInFlightKeys.add(downloadKey);
      try {
        final extension = _sunoMediaExtension(mediaUrl);
        final songId = _sunoSongId(songUrl) ??
            DateTime.now().millisecondsSinceEpoch.toString();
        final filename = _safeSunoFilename(
          'suno_article_${articleId}_${songId}_v${_sunoVersions.length + 1}$extension',
        );
        final target = _uniqueSunoTargetFile(directory, filename);
        final bytes = await _downloadSunoUrl(mediaUrl);
        if (bytes.length < 64 * 1024) {
          throw FormatException('下载结果过小，疑似不是完整歌曲（${bytes.length} bytes）');
        }
        await target.writeAsBytes(bytes, flush: true);
        _sunoAudioPath = target.path;
        _sunoDownloadedSongUrls.add(songUrl);
        _sunoDetectedSongUrls.add(songUrl);
        _sunoDownloadedDownloadKeys.add(downloadKey);
        final title = (_sunoPendingDownloadTitle ?? '').trim();
        final version = ArticleSongVersion(
          id: 'suno_${articleId}_${DateTime.now().millisecondsSinceEpoch}_${_sunoVersions.length + 1}',
          audioPath: target.path,
          title: title.isEmpty ? 'Suno 版本 ${_sunoVersions.length + 1}' : title,
          songUrl: songUrl,
          createdAt: DateTime.now().toIso8601String(),
          stylePrompt:
              _sunoStylePrompt.trim().isEmpty ? null : _sunoStylePrompt.trim(),
          styleKey: _sunoStyleKey(_sunoStylePrompt),
        );
        _sunoVersions.removeWhere((item) =>
            item.songUrl != null &&
            version.songUrl != null &&
            item.songUrl == version.songUrl);
        _sunoVersions.add(version);
        downloadedCount += 1;
        TomatoLogger.info(
          category: 'suno',
          event: 'direct_media.saved',
          articleId: articleId,
          status: _sunoAutomationStatus,
          data: {
            'songUrl': songUrl,
            'mediaUrl': mediaUrl,
            'bytes': bytes.length,
            'audioPath': target.path,
          },
        );
      } catch (error) {
        TomatoLogger.error(
          category: 'suno',
          event: 'direct_media.failed',
          articleId: articleId,
          status: _sunoAutomationStatus,
          data: {
            'songUrl': songUrl,
            'mediaUrl': mediaUrl,
          },
          error: error,
        );
      } finally {
        _sunoDownloadInFlightKeys.remove(downloadKey);
      }
    }

    if (downloadedCount > 0) {
      _sunoPendingDownloadSongUrl = null;
      _sunoPendingDownloadTitle = null;
      await _saveSunoMetadata();
    }
    return downloadedCount;
  }

  String? _matchingSunoMediaUrl(String? mediaUrl, String songUrl) {
    final normalized = (mediaUrl ?? '').trim();
    if (normalized.isEmpty) {
      return null;
    }
    final songId = _sunoSongId(songUrl);
    if (songId == null || !normalized.contains(songId)) {
      return null;
    }
    if (_isRejectedSunoMediaUrl(normalized)) {
      return null;
    }
    return normalized;
  }

  bool _isVerifiableSunoMediaUrl(String mediaUrl) {
    final normalized = mediaUrl.trim().toLowerCase();
    if (normalized.isEmpty) {
      return false;
    }
    return normalized.contains('cdn1.suno.ai') ||
        RegExp(r'\.(mp3|m4a|wav|webm)(?:[?#]|$)', caseSensitive: false)
            .hasMatch(normalized);
  }

  String? _sunoSongId(String songUrl) {
    final match = RegExp(
      r'/song/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})',
    ).firstMatch(songUrl);
    return match?.group(1);
  }

  bool _isRejectedSunoMediaUrl(String mediaUrl) {
    final lower = mediaUrl.toLowerCase();
    return lower.contains('sil-100') ||
        lower.contains('preview') ||
        lower.contains('sample') ||
        lower.contains('snippet') ||
        lower.contains('teaser');
  }

  String _sunoMediaExtension(String mediaUrl) {
    final uri = Uri.tryParse(mediaUrl);
    final extension = uri == null ? '' : path_lib.extension(uri.path);
    if (extension.isNotEmpty && extension.length <= 8) {
      return extension;
    }
    return '.mp3';
  }

  Map<String, dynamic> _sunoDownloadProbeLogData(Map<String, dynamic> result) {
    final candidates = (result['candidates'] as List? ?? const [])
        .take(5)
        .whereType<Map>()
        .map(
          (candidate) => {
            'label': candidate['label']?.toString(),
            'score': candidate['score'],
            'directDownload': candidate['directDownload'],
            'songUrl': candidate['songUrl']?.toString(),
            'title': candidate['title']?.toString(),
            'inOpenMenu': candidate['inOpenMenu'],
          },
        )
        .toList(growable: false);
    return {
      'ok': result['ok'],
      'retry': result['retry'],
      'stage': result['stage'],
      'message': result['message'],
      'songUrl': result['songUrl'],
      'title': result['title'],
      'currentPageExpectedScore': result['currentPageExpectedScore'],
      'expectedMatchThreshold': result['expectedMatchThreshold'],
      'candidateCount': (result['candidates'] as List?)?.length ?? 0,
      'candidates': candidates,
    };
  }

  Future<void> _setSunoStatus(String status, String? message) async {
    final previousStatus = _sunoAutomationStatus;
    _sunoAutomationStatus = status;
    _sunoManualActionMessage = message;
    _sunoErrorMessage = null;
    TomatoLogger.info(
      category: 'suno',
      event: 'status.changed',
      articleId: _sunoArticleId,
      status: status,
      data: {
        'previousStatus': previousStatus,
        'message': message,
        'songUrl': _sunoSongUrl,
        'pendingSongUrl': _sunoPendingDownloadSongUrl,
        'versions': _sunoVersions.length,
      },
    );
    if (mounted) {
      setState(() {});
    }
    final articleId = _sunoArticleId;
    if (articleId != null) {
      await _pushSongState(articleId);
    }
  }

  Future<void> _failSunoAutomation(String message) async {
    final previousStatus = _sunoAutomationStatus;
    _sunoAutomationStatus = 'failed';
    _sunoErrorMessage = message;
    _sunoManualActionMessage = null;
    _sunoAutomationTimer?.cancel();
    TomatoLogger.error(
      category: 'suno',
      event: 'automation.failed',
      articleId: _sunoArticleId,
      status: 'failed',
      data: {
        'previousStatus': previousStatus,
        'message': message,
        'songUrl': _sunoSongUrl,
      },
    );
    if (mounted) {
      setState(() {});
    }
    final articleId = _sunoArticleId;
    if (articleId != null) {
      await _pushSongState(articleId);
    }
  }

  Future<void> _saveSunoMetadata({String? manualActionMessage}) async {
    final articleId = _sunoArticleId;
    if (articleId == null) {
      return;
    }
    final article = await _songArticle(articleId);
    final settings = await _songSettingsPayload();
    final directory = Directory(
      (settings['sunoOutputDirectory'] ?? _defaultSunoOutputDirectory())
          .toString(),
    );
    await directory.create(recursive: true);
    final metadataPath = path_lib.join(
      directory.path,
      'article_${articleId}_suno_${DateTime.now().millisecondsSinceEpoch}.json',
    );
    final currentVersions = _sunoVersionsForStyle(_sunoStylePrompt);
    final currentAudioPath = currentVersions.isNotEmpty
        ? currentVersions.first.audioPath
        : _sunoAudioPath;
    final currentSongUrl = _firstNonEmptyString([
      _sunoSongUrl,
      ..._sunoDetectedSongUrls,
      ...currentVersions.map((version) => version.songUrl),
    ]);
    final metadata = {
      'provider': 'suno',
      'articleId': articleId,
      'articleTitle': article.title,
      'stylePrompt': _sunoStylePrompt,
      'styleKey': _sunoStyleKey(_sunoStylePrompt),
      'songUrl': currentSongUrl,
      'detectedSongUrls': _sunoDetectedSongUrls.toList(growable: false),
      'downloadComplete': _currentSunoDownloadsComplete(),
      'audioPath': currentAudioPath,
      'metadataPath': metadataPath,
      'versions': currentVersions.map((version) => version.toJson()).toList(),
      'manualActionMessage': manualActionMessage,
      'createdAt': DateTime.now().toIso8601String(),
    };
    await File(metadataPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(metadata),
      flush: true,
    );
    _sunoMetadataPath = metadataPath;
    final request = {
      'version': 1,
      'provider': 'suno',
      'articleId': articleId,
      'articleTitle': article.title,
      'contentHash': await _articleSongContentHash(article),
      'stylePrompt': _sunoStylePrompt,
    };
    final cacheKey = await ApiCacheService.keyForJson(
      'article_suno_song',
      request,
    );
    await ApiCacheService.putJson(
      cacheKey: cacheKey,
      kind: 'suno_music',
      purpose: _sunoSongPurpose,
      request: request,
      jsonValue: metadata,
      articleId: articleId,
    );
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
    if (_sunoErrorMessage != null) {
      return 'Suno 自动化失败：$_sunoErrorMessage';
    }
    if ((_sunoManualActionMessage ?? '').trim().isNotEmpty) {
      return _sunoManualActionMessage!;
    }
    switch (_sunoAutomationStatus) {
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

  String _safeSunoFilename(String? suggestedFilename) {
    final raw = (suggestedFilename ?? '').trim();
    final fallback =
        'suno_article_${_sunoArticleId ?? 0}_${DateTime.now().millisecondsSinceEpoch}.mp3';
    final filename = raw.isEmpty ? fallback : raw;
    final cleaned = filename
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) {
      return fallback;
    }
    return path_lib.extension(cleaned).isEmpty ? '$cleaned.mp3' : cleaned;
  }

  File _uniqueSunoTargetFile(Directory directory, String filename) {
    final extension = path_lib.extension(filename);
    final stem = path_lib.basenameWithoutExtension(filename);
    var candidate = File(path_lib.join(directory.path, filename));
    var suffix = 2;
    while (candidate.existsSync()) {
      final nextName =
          extension.isEmpty ? '${stem}_$suffix' : '${stem}_$suffix$extension';
      candidate = File(path_lib.join(directory.path, nextName));
      suffix += 1;
    }
    return candidate;
  }

  String get _sunoInspectScript => r'''
(() => {
  const text = document.body ? document.body.innerText || '' : '';
  const creditsMatch = text.match(/Credits\s+remaining[:\s]+(\d+)/i) || text.match(/(\d+)\s+Credits/i);
  const hasCreateSurface = /Create song|Create|Lyrics|Instrumental|Advanced|Style of Music|Song Description/i.test(text);
  const hasLoginPrompt = /sign in|log in|continue with google|continue with discord/i.test(text);
  const hasAccountSignal = /Profile menu button|\b\d+\s+Credits\b|Upgrade to Pro|Library|Notifications|Activity/i.test(text);
  const hasSongDetail = /\/song\//i.test(location.href) && /Lyrics|Comments|Add a Caption|Show full styles|v\d/i.test(text);
  return JSON.stringify({
    loggedIn: hasAccountSignal || hasSongDetail || (hasCreateSurface && !hasLoginPrompt),
    creditsRemaining: creditsMatch ? Number(creditsMatch[1]) : null,
    textSample: text.slice(0, 800)
  });
})()
''';

  String get _sunoDomDiagnosticsScript => r'''
(() => {
  const normalize = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
  const rectOf = (el) => {
    const rect = el.getBoundingClientRect();
    return {
      x: Math.round(rect.x),
      y: Math.round(rect.y),
      width: Math.round(rect.width),
      height: Math.round(rect.height)
    };
  };
  const visible = (el) => {
    if (!el) return false;
    const rect = el.getBoundingClientRect();
    const style = window.getComputedStyle(el);
    return rect.width > 0 &&
      rect.height > 0 &&
      style.visibility !== 'hidden' &&
      style.display !== 'none' &&
      Number(style.opacity || '1') > 0.01;
  };
  const attrsText = (el) => normalize([
    el.getAttribute?.('aria-label'),
    el.getAttribute?.('placeholder'),
    el.getAttribute?.('data-testid'),
    el.getAttribute?.('data-test-id'),
    el.getAttribute?.('name'),
    el.getAttribute?.('id'),
    el.getAttribute?.('role'),
    el.getAttribute?.('type')
  ].filter(Boolean).join(' '));
  const inputValue = (el) => normalize(el?.matches?.('input,textarea') ? el.value || '' : '');
  const ownText = (el) => normalize(
    inputValue(el) ||
      el.getAttribute?.('aria-label') ||
      el.innerText ||
      el.textContent ||
      el.getAttribute?.('placeholder') ||
      ''
  );
  const contextText = (el) => {
    const parts = [attrsText(el), ownText(el)];
    let current = el.parentElement;
    for (let i = 0; current && i < 5; i += 1, current = current.parentElement) {
      const text = normalize(current.innerText || current.textContent || '');
      if (text && text.length <= 700) parts.push(text);
      parts.push(attrsText(current));
    }
    return normalize(parts.join(' ')).slice(0, 900);
  };
  const summarize = (el) => ({
    tag: el.tagName.toLowerCase(),
    role: el.getAttribute('role') || '',
    type: el.getAttribute('type') || '',
    id: el.id || '',
    name: el.getAttribute('name') || '',
    className: String(el.className || '').slice(0, 180),
    ariaLabel: el.getAttribute('aria-label') || '',
    placeholder: el.getAttribute('placeholder') || '',
    value: inputValue(el),
    dataTestId: el.getAttribute('data-testid') || el.getAttribute('data-test-id') || '',
    text: ownText(el).slice(0, 220),
    context: contextText(el).slice(0, 420),
    editable: Boolean(el.isContentEditable),
    disabled: Boolean(el.disabled) || el.getAttribute('aria-disabled') === 'true',
    rect: rectOf(el)
  });
  const controlSelector = [
    'button',
    '[role="button"]',
    '[role="tab"]',
    'a',
    'label',
    '[aria-label]',
    '[data-testid]',
    '[data-test-id]'
  ].join(',');
  const editorSelector = [
    'textarea',
    'input:not([type])',
    'input[type="text"]',
    'input[type="search"]',
    '[contenteditable="true"]',
    '[role="textbox"]',
    '.ProseMirror',
    '[data-slate-editor="true"]',
    '[data-lexical-editor="true"]'
  ].join(',');
  const controls = Array.from(document.querySelectorAll(controlSelector))
    .filter(visible)
    .filter((el) => /advanced|simple|create|lyrics|style|song|music|歌词|风格/i.test(contextText(el)))
    .slice(0, 80)
    .map(summarize);
  const editors = Array.from(document.querySelectorAll(editorSelector))
    .filter(visible)
    .slice(0, 60)
    .map(summarize);
  return JSON.stringify({
    href: location.href,
    title: document.title,
    bodyTextSample: normalize(document.body?.innerText || '').slice(0, 1600),
    controls,
    editors,
    controlCount: controls.length,
    editorCount: editors.length
  });
})()
''';

  String get _sunoSnapshotScript => r'''
(() => {
  const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
  const maskSensitiveText = (value) => normalize(value)
    .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, '[email]')
    .replace(/\b(?:Bearer|token|authorization|session|cookie)\s*[:=]\s*[A-Za-z0-9._~+/=-]{12,}/gi, '[secret]')
    .replace(/https:\/\/suno\.com\/@\w+/gi, 'https://suno.com/@user')
    .replace(/@\d{5,}/g, '@user')
    .replace(/\b\d{7,}\b/g, (match) => match.length >= 10 ? '[number]' : match);
  const rectOf = (el) => {
    const rect = el.getBoundingClientRect();
    return {
      x: Math.round(rect.x),
      y: Math.round(rect.y),
      width: Math.round(rect.width),
      height: Math.round(rect.height)
    };
  };
  const visible = (el) => {
    if (!el) return false;
    const rect = el.getBoundingClientRect();
    const style = window.getComputedStyle(el);
    return rect.width > 0 &&
      rect.height > 0 &&
      style.visibility !== 'hidden' &&
      style.display !== 'none' &&
      Number(style.opacity || '1') > 0.01;
  };
  const attrsText = (el) => normalize([
    el.getAttribute?.('aria-label'),
    el.getAttribute?.('title'),
    el.getAttribute?.('placeholder'),
    el.getAttribute?.('data-testid'),
    el.getAttribute?.('data-test-id'),
    el.getAttribute?.('name'),
    el.getAttribute?.('id'),
    el.getAttribute?.('role'),
    el.getAttribute?.('type'),
    el.getAttribute?.('download'),
    el.href
  ].filter(Boolean).join(' '));
  const ownText = (el) => normalize([
    el.matches?.('input,textarea') ? el.value || '' : '',
    el.getAttribute?.('aria-label'),
    el.getAttribute?.('title'),
    el.innerText,
    el.textContent,
    el.getAttribute?.('placeholder')
  ].filter(Boolean).join(' '));
  const contextText = (el) => {
    const parts = [attrsText(el), ownText(el)];
    let current = el.parentElement;
    for (let i = 0; current && i < 4; i += 1, current = current.parentElement) {
      const text = normalize(current.innerText || current.textContent || '');
      if (text && text.length <= 900) parts.push(text);
      parts.push(attrsText(current));
    }
    return maskSensitiveText(parts.join(' ')).slice(0, 1200);
  };
  const summarize = (el, index) => ({
    index,
    tag: el.tagName.toLowerCase(),
    role: el.getAttribute('role') || '',
    type: el.getAttribute('type') || '',
    id: maskSensitiveText(el.id || '').slice(0, 120),
    name: maskSensitiveText(el.getAttribute('name') || '').slice(0, 120),
    className: String(el.className || '').slice(0, 220),
    ariaLabel: maskSensitiveText(el.getAttribute('aria-label') || '').slice(0, 220),
    title: maskSensitiveText(el.getAttribute('title') || '').slice(0, 220),
    placeholder: maskSensitiveText(el.getAttribute('placeholder') || '').slice(0, 220),
    dataTestId: el.getAttribute('data-testid') || el.getAttribute('data-test-id') || '',
    href: maskSensitiveText(el.href || '').slice(0, 260),
    download: maskSensitiveText(el.getAttribute('download') || '').slice(0, 180),
    value: el.matches?.('input,textarea') && el.type !== 'password'
      ? maskSensitiveText(el.value || '').slice(0, 260)
      : '',
    text: maskSensitiveText(ownText(el)).slice(0, 360),
    context: contextText(el).slice(0, 700),
    editable: Boolean(el.isContentEditable),
    disabled: Boolean(el.disabled) || el.getAttribute('aria-disabled') === 'true',
    rect: rectOf(el)
  });
  const selectors = [
    'a[href]',
    'button',
    '[role="button"]',
    '[role="menuitem"]',
    '[role="tab"]',
    'label',
    'textarea',
    'input',
    '[contenteditable="true"]',
    '[role="textbox"]',
    '.ProseMirror',
    '[data-slate-editor="true"]',
    '[data-lexical-editor="true"]',
    '[aria-label]',
    '[title]',
    '[data-testid]',
    '[data-test-id]',
    'audio[src]',
    'video[src]'
  ].join(',');
  const elements = Array.from(document.querySelectorAll(selectors))
    .filter(visible)
    .slice(0, 450)
    .map(summarize);
  const songLinks = Array.from(document.querySelectorAll('a[href*="/song/"],a[href*="suno.com/song"]'))
    .filter(visible)
    .slice(0, 80)
    .map((el, index) => summarize(el, index));
  const media = Array.from(document.querySelectorAll('audio[src],video[src]'))
    .filter(visible)
    .slice(0, 40)
    .map((el, index) => summarize(el, index));
  const outline = [];
  const walk = (node, depth) => {
    if (!node || outline.length >= 900 || depth > 7 || node.nodeType !== Node.ELEMENT_NODE) return;
    const el = node;
    if (visible(el) || depth <= 2) {
      const text = maskSensitiveText(normalize(el.innerText || el.textContent || '')).slice(0, 160);
      outline.push({
        depth,
        tag: el.tagName.toLowerCase(),
        role: el.getAttribute('role') || '',
        id: maskSensitiveText(el.id || '').slice(0, 80),
        className: String(el.className || '').slice(0, 120),
        ariaLabel: maskSensitiveText(el.getAttribute('aria-label') || '').slice(0, 120),
        dataTestId: el.getAttribute('data-testid') || el.getAttribute('data-test-id') || '',
        text,
        rect: rectOf(el)
      });
    }
    Array.from(el.children || []).forEach((child) => walk(child, depth + 1));
  };
  walk(document.body, 0);

  const clone = document.documentElement.cloneNode(true);
  clone.querySelectorAll('script,style,noscript,template').forEach((el) => el.remove());
  clone.querySelectorAll('*').forEach((el) => {
    Array.from(el.attributes || []).forEach((attr) => {
      const name = attr.name.toLowerCase();
      if (name.startsWith('on') || /cookie|token|session|authorization|password/i.test(name)) {
        el.removeAttribute(attr.name);
      } else if (name === 'value' && /password/i.test(el.getAttribute('type') || '')) {
        el.setAttribute(attr.name, '[password]');
      } else if (attr.value) {
        el.setAttribute(attr.name, maskSensitiveText(attr.value).slice(0, 500));
      }
    });
    if (el.matches?.('input[type="password"]')) {
      el.setAttribute('value', '[password]');
    }
  });
  const sanitizedHtml = maskSensitiveText(clone.outerHTML).slice(0, 350000);
  return JSON.stringify({
    href: maskSensitiveText(location.href),
    rawHref: location.href,
    title: maskSensitiveText(document.title || ''),
    bodyTextSample: maskSensitiveText(document.body?.innerText || '').slice(0, 5000),
    elementCount: elements.length,
    elements,
    songLinks,
    media,
    outline,
    sanitizedHtml
  });
})()
''';

  String _sunoRowsDebugScript({
    required String expectedStylePrompt,
    required String expectedLyrics,
  }) {
    final expectedStyleJson = jsonEncode(expectedStylePrompt.trim());
    final expectedLyricsJson = jsonEncode(expectedLyrics.trim());
    return '''
(() => {
  const expectedStyle = $expectedStyleJson;
  const expectedLyrics = $expectedLyricsJson;
  const normalize = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
  const normalizeLoose = (value) => normalize(value).toLowerCase();
  const expectedTokens = normalize(expectedStyle)
    .split(/[\\s,，、;；|/]+/g)
    .map((value) => value.trim())
    .filter((value) => value.length >= 2)
    .slice(0, 16);
  const expectedMatchThreshold = Math.max(1, Math.min(13, Math.ceil(expectedTokens.length * 0.8)));
  const lyricSamples = normalize(expectedLyrics)
    .split(/\\n+/g)
    .map((value) => value.trim())
    .filter((value) => value.length >= 24)
    .slice(0, 4)
    .map((value) => value.slice(0, 90));
  const expectedScore = (text) => {
    const haystack = normalizeLoose(text);
    let score = 0;
    for (const token of expectedTokens) {
      if (haystack.includes(token.toLowerCase())) score += 1;
    }
    for (const sample of lyricSamples) {
      if (haystack.includes(sample.toLowerCase())) score += 6;
    }
    return score;
  };
  const incomplete = /generating|creating|processing|queued|loading|failed|error|retry|生成中|创建中|处理中|排队|失败|重试/i;
  const preview = /preview|demo|sample|clip|snippet|teaser|试听|試聽|预览|預覽|片段|样例|樣例/i;
  const rows = Array.from(document.querySelectorAll('[data-testid="clip-row"],.clip-row,[role="group"][aria-label]'))
    .map((row, index) => {
      const text = normalize(row.innerText || row.textContent || '');
      const title = normalize(row.getAttribute('aria-label') || row.querySelector?.('h1,h2,h3,[role="heading"]')?.innerText || text.split('\\n')[0] || '');
      const anchor = row.querySelector?.('a[href*="/song/"],a[href*="suno.com/song"]');
      const rect = row.getBoundingClientRect();
      return {
        index,
        title,
        href: anchor?.href || '',
        text: text.slice(0, 500),
        expectedScore: expectedScore(title + '\\n' + text),
        incomplete: incomplete.test(text),
        preview: preview.test(text),
        rect: {
          x: Math.round(rect.x),
          y: Math.round(rect.y),
          width: Math.round(rect.width),
          height: Math.round(rect.height)
        }
      };
    });
  const visible = (el) => {
    if (!el) return false;
    const rect = el.getBoundingClientRect();
    const style = window.getComputedStyle(el);
    return rect.width > 0 &&
      rect.height > 0 &&
      style.visibility !== 'hidden' &&
      style.display !== 'none' &&
      Number(style.opacity || '1') > 0.01;
  };
  const textOf = (el) => normalize([
    el.getAttribute?.('aria-label'),
    el.getAttribute?.('title'),
    el.getAttribute?.('download'),
    el.getAttribute?.('data-testid'),
    el.getAttribute?.('data-test-id'),
    el.getAttribute?.('role'),
    el.href,
    el.innerText,
    el.textContent
  ].filter(Boolean).join(' '));
  const contextText = (el) => {
    const parts = [textOf(el)];
    let current = el.parentElement;
    for (let i = 0; current && i < 5; i += 1, current = current.parentElement) {
      const text = normalize(current.innerText || current.textContent || '');
      if (text && text.length <= 900) parts.push(text);
      parts.push(textOf(current));
    }
    return normalize(parts.join(' ')).slice(0, 1200);
  };
  const controlCandidates = Array.from(document.querySelectorAll(
    'a[href],button,[role="button"],[role="menuitem"],label,[aria-label],[title],[data-testid],[data-test-id]'
  ))
    .filter(visible)
    .map((el, index) => {
      const context = contextText(el);
      const score = expectedScore(context);
      const rect = el.getBoundingClientRect();
      return {
        index,
        tag: el.tagName.toLowerCase(),
        role: el.getAttribute('role') || '',
        ariaLabel: el.getAttribute('aria-label') || '',
        dataTestId: el.getAttribute('data-testid') || el.getAttribute('data-test-id') || '',
        text: textOf(el).slice(0, 140),
        expectedScore: score,
        context: context.slice(0, 420),
        rect: {
          x: Math.round(rect.x),
          y: Math.round(rect.y),
          width: Math.round(rect.width),
          height: Math.round(rect.height)
        }
      };
    })
    .filter((item) => item.expectedScore > 0 || /猫头|奇幻儿童|爱丽丝|Download|下载|More/i.test(item.context))
    .slice(0, 80);
  return JSON.stringify({
    expectedStyle,
    expectedTokens,
    lyricSamples,
    rowCount: rows.length,
    rows,
    controlCandidates
  });
})()
''';
  }

  String _sunoFillScript({
    required String lyrics,
    required String stylePrompt,
    required String ignoredStylePrompt,
    required bool allowMagicClick,
    required bool magicAlreadyRequested,
    bool readOnly = false,
  }) {
    final lyricsJson = jsonEncode(lyrics);
    final styleJson = jsonEncode(stylePrompt);
    final ignoredStyleJson = jsonEncode(ignoredStylePrompt);
    final allowMagicClickJson = jsonEncode(allowMagicClick);
    final magicAlreadyRequestedJson = jsonEncode(magicAlreadyRequested);
    final readOnlyJson = jsonEncode(readOnly);
    return '''
(() => {
  const lyrics = $lyricsJson;
  const style = $styleJson;
  const ignoredStyleRaw = $ignoredStyleJson;
  const allowMagicClick = $allowMagicClickJson;
  const magicAlreadyRequested = $magicAlreadyRequestedJson;
  const readOnly = $readOnlyJson;
  const normalize = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
  const ignoredStyle = normalize(ignoredStyleRaw);
  const isCreatePage = (() => {
    try {
      const url = new URL(window.location.href);
      const host = url.hostname.toLowerCase();
      return (host === 'suno.com' || host === 'www.suno.com') &&
        url.pathname.split('/').filter(Boolean).includes('create');
    } catch (_) {
      return false;
    }
  })();
  if (!isCreatePage) {
    return JSON.stringify({
      ok: false,
      retry: true,
      missing: ['createPage'],
      message: 'Suno 当前不在 Create 页面，Tomato 会重新打开 Create 后再填写。',
      currentUrl: window.location.href
    });
  }
  const visible = (el) => {
    if (!el) return false;
    const rect = el.getBoundingClientRect();
    const style = window.getComputedStyle(el);
    return rect.width > 0 &&
      rect.height > 0 &&
      style.visibility !== 'hidden' &&
      style.display !== 'none' &&
      Number(style.opacity || '1') > 0.01;
  };
  const rectOf = (el) => {
    const rect = el.getBoundingClientRect();
    return {
      x: Math.round(rect.x),
      y: Math.round(rect.y),
      width: Math.round(rect.width),
      height: Math.round(rect.height)
    };
  };
  const textOf = (el) => [
    el.getAttribute?.('aria-label'),
    el.getAttribute?.('placeholder'),
    el.getAttribute?.('data-testid'),
    el.getAttribute?.('data-test-id'),
    el.getAttribute?.('role'),
    el.name,
    el.id,
    el.innerText,
    el.textContent,
    el.value
  ].filter(Boolean).join(' ');
  const inputValue = (el) => normalize(el?.matches?.('input,textarea') ? el.value || '' : '');
  const ownText = (el) => normalize(
    inputValue(el) ||
      el.getAttribute?.('aria-label') ||
      el.innerText ||
      el.textContent ||
      el.getAttribute?.('placeholder') ||
      ''
  );
  const contextText = (el) => {
    const parts = [textOf(el)];
    let current = el.parentElement;
    for (let i = 0; current && i < 5; i += 1, current = current.parentElement) {
      const text = normalize(current.innerText || current.textContent || '');
      if (text && text.length <= 800) parts.push(text);
      parts.push(textOf(current));
    }
    return normalize(parts.join(' ')).slice(0, 1200);
  };
  const summarize = (el) => el ? {
    tag: el.tagName.toLowerCase(),
    role: el.getAttribute('role') || '',
    type: el.getAttribute('type') || '',
    id: el.id || '',
    name: el.getAttribute('name') || '',
    className: String(el.className || '').slice(0, 160),
    ariaLabel: el.getAttribute('aria-label') || '',
    placeholder: el.getAttribute('placeholder') || '',
    value: inputValue(el),
    text: ownText(el).slice(0, 160),
    context: contextText(el).slice(0, 260),
    editable: Boolean(el.isContentEditable),
    rect: rectOf(el)
  } : null;
  const isDisabled = (el) =>
    Boolean(el?.disabled) || el?.getAttribute?.('aria-disabled') === 'true';
  const clickableAncestor = (el) =>
    el?.closest?.('button,[role="button"],[role="tab"],a,label') || el;
  const clickCookieBanner = () => {
    const cookiePattern = /cookie|cookies|privacy|consent|tracking|隐私|隱私/i;
    const positivePattern = /accept all|accept cookies|accept|agree|i agree|allow all|allow|got it|ok|okay|同意|接受|全部接受|允许全部|允許全部|知道了/i;
    const softPositivePattern = /continue|继续/i;
    const negativePattern = /reject|decline|manage|settings|preferences|customize|learn more|privacy policy|terms|拒绝|拒絕|管理|设置|設定|偏好/i;
    const nearbyCookieText = (el) => {
      const parts = [];
      let current = el;
      for (let i = 0; current && i < 6; i += 1, current = current.parentElement) {
        const attrs = normalize([
          current.getAttribute?.('id'),
          current.getAttribute?.('class'),
          current.getAttribute?.('aria-label'),
          current.getAttribute?.('data-testid'),
          current.getAttribute?.('data-test-id')
        ].filter(Boolean).join(' '));
        if (attrs) parts.push(attrs);
        const text = normalize(current.innerText || current.textContent || '');
        if (text && text.length <= 1200) {
          parts.push(text);
        }
      }
      return normalize(parts.join(' '));
    };
    const candidates = Array.from(document.querySelectorAll(
      'button,[role="button"],a,label'
    ))
      .filter(visible)
      .map((el) => {
        const clickable = clickableAncestor(el);
        const label = normalize(textOf(el));
        const context = nearbyCookieText(clickable);
        const hasCookieContext = cookiePattern.test(context);
        const hasStrongPositive = positivePattern.test(label);
        const hasSoftPositive = softPositivePattern.test(label) && hasCookieContext;
        if ((!hasStrongPositive && !hasSoftPositive) || !hasCookieContext) {
          return null;
        }
        if (isDisabled(clickable)) {
          return null;
        }
        let score = 0;
        if (clickable === el || clickable.contains(el)) score += 2;
        if (clickable.tagName === 'BUTTON') score += 10;
        if (/button/i.test(clickable.getAttribute('role') || '')) score += 6;
        if (/accept all|全部接受|允许全部|允許全部/i.test(label)) score += 10;
        if (/accept cookies|accept|agree|同意|接受/i.test(label)) score += 7;
        if (hasSoftPositive) score += 3;
        if (negativePattern.test(label)) score -= 20;
        if (negativePattern.test(context) && !/accept|agree|同意|接受/i.test(label)) score -= 5;
        score -= Math.max(0, label.length - 40) / 30;
        return { clickable, label, score };
      })
      .filter(Boolean)
      .sort((left, right) => right.score - left.score);
    const match = candidates[0];
    if (!match || match.score < 6) {
      return { clicked: false, target: null };
    }
    match.clickable.scrollIntoView({ block: 'center', inline: 'center' });
    match.clickable.focus?.();
    match.clickable.click();
    return { clicked: true, target: summarize(match.clickable) };
  };
  const isAdvancedActive = () => {
    const candidates = Array.from(document.querySelectorAll(
      'button,[role="button"],[role="tab"],a,label,[aria-label],[data-testid],[data-test-id]'
    )).filter(visible);
    return candidates.some((el) => {
      const label = normalize(textOf(el));
      if (!/\\badvanced\\b/i.test(label)) return false;
      const className = String(el.className || '');
      return el.getAttribute('aria-selected') === 'true' ||
        el.getAttribute('aria-pressed') === 'true' ||
        el.getAttribute('data-state') === 'active' ||
        /active|selected|checked/i.test(className);
    });
  };
  const clickAdvanced = () => {
    if (isAdvancedActive()) {
      return { clicked: false, alreadyActive: true, target: null };
    }
    const candidates = Array.from(document.querySelectorAll(
      'button,[role="button"],[role="tab"],a,label,span,div,[aria-label],[data-testid],[data-test-id]'
    ))
      .filter(visible)
      .map((el) => {
        const label = normalize(textOf(el));
        const exact = label.toLowerCase() === 'advanced';
        const shortMatch = /\\badvanced\\b/i.test(label) && label.length <= 120;
        if (!exact && !shortMatch) return null;
        const clickable = clickableAncestor(el);
        const role = clickable.getAttribute('role') || '';
        let score = 0;
        if (exact) score += 20;
        if (/button|tab/i.test(role) || clickable.tagName === 'BUTTON') score += 8;
        if (clickable.getAttribute('aria-selected') === 'false') score += 3;
        if (!isDisabled(clickable)) score += 2;
        score -= Math.max(0, label.length - 8) / 20;
        return { el, clickable, label, score };
      })
      .filter(Boolean)
      .sort((left, right) => right.score - left.score);
    const match = candidates[0];
    if (!match || isDisabled(match.clickable)) {
      return { clicked: false, alreadyActive: false, target: null };
    }
    match.clickable.scrollIntoView({ block: 'center', inline: 'center' });
    match.clickable.focus?.();
    match.clickable.click();
    return { clicked: true, alreadyActive: false, target: summarize(match.clickable) };
  };
  const cookieResult = clickCookieBanner();
  const advancedResult = clickAdvanced();
  if (cookieResult.clicked || advancedResult.clicked) {
    return JSON.stringify({
      ok: false,
      retry: true,
      message: cookieResult.clicked
        ? 'Tomato 已处理 Suno Cookies 提示，正在等待页面刷新后继续填写。'
        : 'Tomato 已尝试切换 Suno Advanced，正在等待页面刷新后继续填写。',
      cookieAccepted: cookieResult.clicked,
      cookieTarget: cookieResult.target,
      advancedClicked: advancedResult.clicked,
      advancedAlreadyActive: advancedResult.alreadyActive,
      advancedActive: isAdvancedActive(),
      advancedTarget: advancedResult.target
    });
  }
  const editorSelector = [
    'textarea',
    'input:not([type])',
    'input[type="text"]',
    'input[type="search"]',
    '[contenteditable="true"]',
    '[role="textbox"]',
    '.ProseMirror',
    '[data-slate-editor="true"]',
    '[data-lexical-editor="true"]'
  ].join(',');
  const utilityMeta = (el) => normalize([
    el.getAttribute?.('aria-label'),
    el.getAttribute?.('placeholder'),
    el.getAttribute?.('name'),
    el.getAttribute?.('id'),
    el.getAttribute?.('data-testid'),
    el.getAttribute?.('data-test-id'),
    el.getAttribute?.('type')
  ].filter(Boolean).join(' '));
  const isUtilityEditor = (el, context) => {
    const meta = utilityMeta(el);
    if (/\bsearch\b|current page|song title|enhance lyrics|搜索|页码|标题|增强歌词/i.test(meta)) {
      return true;
    }
    return el.matches?.('input[type="search"]') === true;
  };
  const allFields = Array.from(document.querySelectorAll(editorSelector))
    .filter(visible)
    .filter((el) => !isDisabled(el))
    .map((el) => {
      const context = contextText(el);
      const rect = el.getBoundingClientRect();
      const text = normalize(textOf(el));
      const lyricMatch = /lyrics?|歌词|歌詞/i.test(context);
      const styleMatch = /style|genre|music|describe|description|风格|曲风/i.test(context);
      let lyricScore = 0;
      let styleScore = 0;
      if (lyricMatch) lyricScore += 14;
      if (/lyrics?|歌词|歌詞/i.test(text)) lyricScore += 8;
      if (rect.height >= 120) lyricScore += 3;
      if (styleMatch) styleScore += 14;
      if (/style|genre|music|describe|description|风格|曲风/i.test(text)) styleScore += 8;
      if (rect.height < 180) styleScore += 2;
      if (/prompt|song description/i.test(context)) styleScore += 3;
      if (isUtilityEditor(el, context)) {
        lyricScore -= 30;
        styleScore -= 30;
      }
      return { el, context, lyricScore, styleScore, rect };
    });
  const formFields = allFields.filter((item) => !isUtilityEditor(item.el, item.context));
  const choose = (scoreName, exclude) => formFields
    .filter((item) => item.el !== exclude)
    .sort((left, right) => {
      const scoreDiff = right[scoreName] - left[scoreName];
      if (scoreDiff !== 0) return scoreDiff;
      if (scoreName === 'lyricScore') {
        return right.rect.height - left.rect.height;
      }
      return left.rect.height - right.rect.height;
    })[0]?.el;
  let lyricsField = choose('lyricScore');
  let styleField = choose('styleScore', lyricsField);
  if (lyricsField) {
    const lyricsRect = lyricsField.getBoundingClientRect();
    const styleBelowLyrics = formFields
      .filter((item) => item.el !== lyricsField)
      .filter((item) => item.rect.top > lyricsRect.top + 20)
      .filter((item) => item.rect.height >= 60)
      .filter((item) =>
        Math.min(item.rect.right, lyricsRect.right) -
          Math.max(item.rect.left, lyricsRect.left) >
        Math.min(item.rect.width, lyricsRect.width) * 0.35
      )
      .sort((left, right) => left.rect.top - right.rect.top)[0]?.el;
    if (styleBelowLyrics) {
      styleField = styleBelowLyrics;
    }
  }
  if (formFields.length >= 2 && (!lyricsField || !styleField || lyricsField === styleField)) {
    const byHeight = [...formFields].sort((left, right) => right.rect.height - left.rect.height);
    lyricsField = byHeight[0]?.el;
    styleField = byHeight.find((item) => item.el !== lyricsField)?.el;
  }
  if (!lyricsField && formFields.length === 1) {
    lyricsField = formFields[0].el;
  }
  const fillTarget = (el) => {
    if (!el) return null;
    if (el.matches?.('input,textarea') || el.isContentEditable) return el;
    return el.querySelector?.('textarea,input,[contenteditable="true"],[role="textbox"],.ProseMirror') || el;
  };
  const dispatchInput = (el, value) => {
    try {
      el.dispatchEvent(new InputEvent('beforeinput', {
        bubbles: true,
        cancelable: true,
        inputType: 'insertText',
        data: value
      }));
    } catch (_) {}
    try {
      el.dispatchEvent(new InputEvent('input', {
        bubbles: true,
        inputType: 'insertText',
        data: value
      }));
    } catch (_) {
      el.dispatchEvent(new Event('input', { bubbles: true }));
    }
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
    el.blur?.();
  };
  const setValue = (rawEl, value) => {
    const el = fillTarget(rawEl);
    if (!el) return false;
    const currentValue = el.matches?.('input,textarea')
      ? normalize(el.value || '')
      : normalize(el.innerText || el.textContent || el.value || '');
    if (currentValue === normalize(value)) return true;
    el.scrollIntoView({ block: 'center', inline: 'center' });
    el.focus?.();
    if (el.matches?.('input,textarea')) {
      const nativePrototype = el.tagName === 'TEXTAREA'
        ? HTMLTextAreaElement.prototype
        : HTMLInputElement.prototype;
      const nativeSetter = Object.getOwnPropertyDescriptor(nativePrototype, 'value')?.set;
      const ownSetter = Object.getOwnPropertyDescriptor(el, 'value')?.set;
      const setNativeValue = (nextValue) => {
        if (ownSetter && ownSetter !== nativeSetter) {
          ownSetter.call(el, nextValue);
        } else if (nativeSetter) {
          nativeSetter.call(el, nextValue);
        } else {
          el.value = nextValue;
        }
      };
      try {
        el.setSelectionRange?.(0, (el.value || '').length);
      } catch (_) {}
      try {
        el.select?.();
      } catch (_) {}
      try {
        el._valueTracker?.setValue('');
      } catch (_) {}
      let inserted = false;
      try {
        if (typeof el.setRangeText === 'function') {
          el.setRangeText(value, 0, (el.value || '').length, 'end');
          inserted = normalize(el.value || '') === normalize(value);
        }
      } catch (_) {
        inserted = false;
      }
      if (!inserted) {
        try {
          inserted = document.execCommand && document.execCommand('insertText', false, value);
        } catch (_) {
          inserted = false;
        }
      }
      if (!inserted || normalize(el.value || '') !== normalize(value)) {
        setNativeValue(value);
      }
      dispatchInput(el, value);
      try {
        el.setSelectionRange?.((el.value || '').length, (el.value || '').length);
      } catch (_) {}
      return true;
    }
    if (el.isContentEditable || el.getAttribute?.('role') === 'textbox') {
      const selection = window.getSelection?.();
      const range = document.createRange();
      try {
        range.selectNodeContents(el);
        selection?.removeAllRanges();
        selection?.addRange(range);
      } catch (_) {}
      let inserted = false;
      try {
        inserted = document.execCommand && document.execCommand('insertText', false, value);
      } catch (_) {
        inserted = false;
      }
      if (!inserted) {
        el.textContent = value;
      }
      dispatchInput(el, value);
      return true;
    }
    return false;
  };
  const fields = allFields.map((item) => ({
    lyricScore: item.lyricScore,
    styleScore: item.styleScore,
    field: summarize(item.el)
  })).slice(0, 20);
  const getValue = (rawEl) => {
    const el = fillTarget(rawEl);
    if (!el) return '';
    if (el.matches?.('input,textarea')) return normalize(el.value || '');
    return normalize(el.innerText || el.textContent || el.value || '');
  };
  const getPlaceholder = (rawEl) => {
    const el = fillTarget(rawEl);
    return normalize(
      el?.getAttribute?.('placeholder') ||
        rawEl?.getAttribute?.('placeholder') ||
        ''
    );
  };
  if (readOnly) {
    return JSON.stringify({
      ok: Boolean(lyricsField && styleField),
      retry: false,
      stylePrompt: styleField ? getValue(styleField) : '',
      lyricsPrompt: lyricsField ? getValue(lyricsField) : '',
      stylePlaceholder: styleField ? getPlaceholder(styleField) : '',
      fieldCount: allFields.length,
      lyricsField: summarize(lyricsField),
      styleField: summarize(styleField),
      fields,
      textSample: normalize(document.body?.innerText || '').slice(0, 1000)
    });
  }
  const isRejectedStyleMagicLabel = (label, context) => {
    const labelText = normalize(label);
    const text = normalize(String(label || '') + ' ' + String(context || ''));
    if (/refresh recommended styles|recommended styles|add style|no saved styles|save prompt|undo changes|clear styles|clear all|lyrics?|create song|download|delete|remove|upload|advanced|simple|sign in|log in|credits|instrumental|extend|cover|\\bpersona\\b|刷新推荐|推荐风格|添加风格|保存提示|撤销|清空|歌词|创建|下载|删除|上传|登录/i.test(labelText)) {
      return true;
    }
    return /refresh recommended styles|add style|no saved styles|save prompt|undo changes|clear styles|clear all|刷新推荐|添加风格|保存提示|撤销|清空/i.test(text);
  };
  const findStyleMagicButton = () => {
    if (!styleField) return null;
    const styleRect = styleField.getBoundingClientRect();
    const candidates = Array.from(document.querySelectorAll(
      'button,[role="button"],a,label,[aria-label],[data-testid],[data-test-id]'
    ))
      .filter(visible)
      .map((el) => {
        const clickable = clickableAncestor(el);
        if (!clickable || isDisabled(clickable)) return null;
        const label = normalize(textOf(el));
        const context = contextText(el);
        const rect = clickable.getBoundingClientRect();
        const nearStyle =
          rect.bottom >= styleRect.top - 180 &&
          rect.top <= styleRect.bottom + 180 &&
          rect.right >= styleRect.left - 260 &&
          rect.left <= styleRect.right + 260;
        const hasIcon = Boolean(clickable.querySelector?.('svg,img,[class*="icon"],[class*="magic"],[class*="wand"],[class*="spark"]'));
        const hasAccent = /accent|aura|magic|wand|spark|blue/i.test(String(clickable.className || ''));
        const positive = /personalize style prompt|magic wand|magic|wand|spark|auto.*style|style.*auto|generate.*style|style.*generate|inspire|style prompt|风格.*魔法|魔法.*风格|自动.*风格|风格.*自动|生成.*风格|风格.*生成|曲风.*生成|生成.*曲风/i;
        const strongMagic = /personalize style prompt|magic wand|magic|wand|spark|魔法|自动.*风格|生成.*风格|曲风.*生成|inspire/i;
        if (isRejectedStyleMagicLabel(label, context)) return null;
        if (!nearStyle) return null;
        if (!positive.test(label) && !positive.test(context) && !hasAccent && !hasIcon) {
          return null;
        }
        let score = 0;
        if (nearStyle) score += 8;
        if (strongMagic.test(label)) score += 18;
        if (strongMagic.test(context)) score += 10;
        if (/style|music|genre|风格|曲风/i.test(label)) score += 8;
        if (/style|music|genre|风格|曲风/i.test(context)) score += 5;
        if (hasAccent) score += 8;
        if (hasIcon) score += 4;
        if (clickable.tagName === 'BUTTON') score += 3;
        if (!label && (hasAccent || hasIcon)) score += 7;
        score -= Math.max(0, label.length - 80) / 25;
        return { clickable, label, context, score };
      })
      .filter(Boolean)
      .sort((left, right) => right.score - left.score);
    const match = candidates[0];
    if (!match || match.score < 8) return null;
    return match;
  };
  const missing = [];
  const expectedLyrics = normalize(lyrics);
  const expectedStyle = normalize(style);
  let styleValue = styleField ? getValue(styleField) : '';
  let stylePlaceholder = styleField ? getPlaceholder(styleField) : '';
  let styleFilled = false;
  let styleSource = '';
  let magicClicked = false;
  let magicTarget = null;
  if (!lyricsField) {
    missing.push('lyrics');
  } else if (!expectedLyrics) {
    missing.push('lyricsText');
  } else if (getValue(lyricsField) !== expectedLyrics) {
    const lyricsFilled = setValue(lyricsField, lyrics);
    const lyricsValue = getValue(lyricsField);
    if (!lyricsFilled || lyricsValue !== expectedLyrics) {
      missing.push('lyricsFill');
    } else {
      return JSON.stringify({
        ok: false,
        retry: true,
        magicClicked: false,
        message: 'Tomato 已把歌词写入 Suno Lyrics，正在确认页面渲染。',
        stylePrompt: '',
        styleSource: '',
        fieldCount: allFields.length,
        lyricsField: summarize(lyricsField),
        styleField: summarize(styleField),
        fields,
        textSample: normalize(document.body?.innerText || '').slice(0, 1000)
      });
    }
  }
  if (!styleField) {
    missing.push('style');
  } else {
    const magic = findStyleMagicButton();
    if (expectedStyle) {
      if (styleValue !== expectedStyle) {
        styleFilled = setValue(styleField, style);
        styleValue = getValue(styleField);
        styleSource = 'fallback';
        if (!styleFilled || styleValue !== expectedStyle) {
          missing.push('styleFill');
        } else {
          return JSON.stringify({
            ok: false,
            retry: true,
            magicClicked: false,
            message: 'Tomato 已把已有风格写入 Suno Styles，正在确认页面渲染。',
            stylePrompt: styleValue,
            styleSource,
            styleFilled,
            fieldCount: allFields.length,
            lyricsField: summarize(lyricsField),
            styleField: summarize(styleField),
            stylePlaceholder,
            fields,
            textSample: normalize(document.body?.innerText || '').slice(0, 1000)
          });
        }
      } else {
        styleFilled = true;
        styleSource = 'fallback';
      }
    } else if (magicAlreadyRequested &&
        styleValue.length >= 6 &&
        styleValue !== ignoredStyle) {
      styleSource = 'sunoMagic';
    } else if (styleValue.length >= 6 &&
        (!magicAlreadyRequested || styleValue === ignoredStyle)) {
      const ignoredStylePrompt = ignoredStyle || styleValue;
      styleFilled = setValue(styleField, '');
      styleValue = getValue(styleField);
      return JSON.stringify({
        ok: false,
        retry: true,
        magicClicked: false,
        message: 'Tomato 已清空 Suno Styles 中的旧风格，准备点击自动风格魔法棒。',
        stylePrompt: '',
        styleSource: 'sunoMagic',
        ignoredStylePrompt,
        styleFilled,
        fieldCount: allFields.length,
        lyricsField: summarize(lyricsField),
        styleField: summarize(styleField),
        stylePlaceholder,
        fields,
        textSample: normalize(document.body?.innerText || '').slice(0, 1000)
      });
    } else if (magic && (!magicAlreadyRequested || allowMagicClick)) {
      magic.clickable.scrollIntoView({ block: 'center', inline: 'center' });
      magic.clickable.focus?.();
      magic.clickable.click();
      magicClicked = true;
      magicTarget = summarize(magic.clickable);
      return JSON.stringify({
        ok: false,
        retry: true,
        magicClicked: true,
        message: 'Tomato 已点击 Suno 自动风格魔法棒，正在等待 Suno 根据歌词生成风格。',
        stylePrompt: '',
        styleSource: 'sunoMagic',
        magicTarget,
        ignoredStylePrompt: ignoredStyle,
        fieldCount: allFields.length,
        lyricsField: summarize(lyricsField),
        styleField: summarize(styleField),
        stylePlaceholder,
        fields,
        textSample: normalize(document.body?.innerText || '').slice(0, 1000)
      });
    } else if (magicAlreadyRequested || (magic && !allowMagicClick)) {
      return JSON.stringify({
        ok: false,
        retry: true,
        magicClicked: false,
        message: '正在等待 Suno 自动风格生成完成...',
        stylePrompt: '',
        styleSource: 'sunoMagic',
        magicTarget: magic ? summarize(magic.clickable) : null,
        ignoredStylePrompt: ignoredStyle,
        stylePlaceholder,
        fieldCount: allFields.length,
        lyricsField: summarize(lyricsField),
        styleField: summarize(styleField),
        fields,
        textSample: normalize(document.body?.innerText || '').slice(0, 1000)
      });
    } else {
      missing.push('styleMagic');
    }
  }
  const advancedActive = isAdvancedActive();
  return JSON.stringify({
    ok: missing.length === 0,
    missing,
    retry: false,
    magicClicked,
    magicTarget,
    stylePrompt: styleValue,
    stylePlaceholder,
    styleSource,
    styleFilled,
    cookieAccepted: cookieResult.clicked,
    cookieTarget: cookieResult.target,
    advancedClicked: advancedResult.clicked,
    advancedAlreadyActive: advancedResult.alreadyActive,
    advancedActive,
    advancedTarget: advancedResult.target,
    fieldCount: allFields.length,
    lyricsField: summarize(lyricsField),
    styleField: summarize(styleField),
    fields,
    textSample: normalize(document.body?.innerText || '').slice(0, 1000)
  });
})()
''';
  }

  String get _sunoCreateScript => r'''
(() => {
  const visible = (el) => {
    if (!el) return false;
    const rect = el.getBoundingClientRect();
    const style = window.getComputedStyle(el);
    return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
  };
  const textOf = (el) => [
    el.getAttribute?.('aria-label'),
    el.innerText,
    el.textContent
  ].filter(Boolean).join(' ');
  const buttons = Array.from(document.querySelectorAll('button,[role="button"]')).filter(visible);
  const button = buttons.find((el) => /create song/i.test(textOf(el))) ||
    buttons.find((el) => /^create$/i.test(textOf(el).trim())) ||
    buttons.find((el) => /create/i.test(textOf(el)));
  if (!button) {
    return JSON.stringify({ ok: false, message: '没有找到 Suno Create 按钮。' });
  }
  if (button.disabled || button.getAttribute('aria-disabled') === 'true') {
    return JSON.stringify({ ok: false, message: 'Suno Create 按钮仍不可用，请检查歌词、风格或 credits。' });
  }
  button.click();
  return JSON.stringify({ ok: true });
})()
''';

  String _sunoCompletionScript({
    required String expectedStylePrompt,
    required String expectedLyrics,
    required bool requireExpectedMatch,
  }) {
    final expectedStyleJson = jsonEncode(expectedStylePrompt.trim());
    final expectedLyricsJson = jsonEncode(expectedLyrics.trim());
    final requireExpectedJson = jsonEncode(requireExpectedMatch);
    return '''
(() => {
  const expectedStyle = $expectedStyleJson;
  const expectedLyrics = $expectedLyricsJson;
  const requireExpectedMatch = $requireExpectedJson;
  const normalize = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
  const normalizeLoose = (value) => normalize(value).toLowerCase();
  const expectedTokens = normalize(expectedStyle)
    .split(/[\\s,，、;；|/]+/g)
    .map((value) => value.trim())
    .filter((value) => value.length >= 2)
    .slice(0, 16);
  const expectedMatchThreshold = Math.max(1, Math.min(13, Math.ceil(expectedTokens.length * 0.8)));
  const lyricSamples = normalize(expectedLyrics)
    .split(/\\n+/g)
    .map((value) => value.trim())
    .filter((value) => value.length >= 24)
    .slice(0, 4)
    .map((value) => value.slice(0, 90));
  const expectedScore = (text) => {
    const haystack = normalizeLoose(text);
    let score = 0;
    for (const token of expectedTokens) {
      if (haystack.includes(token.toLowerCase())) score += 1;
    }
    for (const sample of lyricSamples) {
      if (haystack.includes(sample.toLowerCase())) score += 6;
    }
    return score;
  };
  const visible = (el) => {
    if (!el) return false;
    const rect = el.getBoundingClientRect();
    const style = window.getComputedStyle(el);
    return rect.width > 0 &&
      rect.height > 0 &&
      style.visibility !== 'hidden' &&
      style.display !== 'none' &&
      Number(style.opacity || '1') > 0.01;
  };
  const incomplete = /generating|creating|processing|queued|loading|failed|error|retry|生成中|创建中|处理中|排队|失败|重试/i;
  const preview = /preview|demo|sample|clip|snippet|teaser|试听|試聽|预览|預覽|片段|样例|樣例/i;
  const anchors = Array.from(document.querySelectorAll('a[href]'))
    .filter(visible)
    .filter((a) => /suno\\.com\\/song|\\/song\\//i.test(a.href))
    .map((a) => {
      const container = a.closest('article,section,[data-testid],[data-test-id],div') || a;
      const text = normalize(container.innerText || container.textContent || a.innerText || '');
      const title = normalize(container.querySelector?.('h1,h2,h3,[role="heading"]')?.innerText || a.innerText || '');
      return { href: a.href, title, text, expectedScore: expectedScore(title + '\\n' + text) };
    })
    .filter((item) => item.href && !incomplete.test(item.text) && !preview.test(item.text))
    .filter((item) => !requireExpectedMatch || item.expectedScore >= expectedMatchThreshold);
  const rows = Array.from(document.querySelectorAll('[data-testid="clip-row"],.clip-row,[role="group"][aria-label]'))
    .map((row, index) => {
      const text = normalize(row.innerText || row.textContent || '');
      const title = normalize(row.getAttribute('aria-label') || row.querySelector?.('h1,h2,h3,[role="heading"]')?.innerText || text.split('\\n')[0] || '');
      const anchor = row.querySelector?.('a[href*="/song/"],a[href*="suno.com/song"]');
      const href = anchor?.href || ('suno-row:' + index + ':' + (title || 'untitled'));
      return { href, title, text, expectedScore: expectedScore(title + '\\n' + text) };
    })
    .filter((item) => item.href && !incomplete.test(item.text) && !preview.test(item.text))
    .filter((item) => !requireExpectedMatch || item.expectedScore >= expectedMatchThreshold);
  const seen = new Set();
  const songCandidates = anchors.concat(rows).filter((item) => {
    if (seen.has(item.href)) return false;
    seen.add(item.href);
    return true;
  }).sort((left, right) => right.expectedScore - left.expectedScore);
  const songIdFromUrl = (url) => {
    const match = String(url || '').match(/\\/song\\/([0-9a-fA-F-]{36})/);
    return match ? match[1] : '';
  };
  const mediaRank = (url) => {
    if (/\\.mp3(?:[?#]|\$)/i.test(url)) return 4;
    if (/\\.m4a(?:[?#]|\$)/i.test(url)) return 3;
    if (/\\.wav(?:[?#]|\$)/i.test(url)) return 2;
    if (/\\.webm(?:[?#]|\$)/i.test(url)) return 1;
    return 0;
  };
  const mediaUrls = Array.from(new Set(
    Array.from(document.querySelectorAll('audio[src],video[src],source[src]'))
      .map((el) => el.src)
      .concat(
        Array.from((document.documentElement?.innerHTML || '').matchAll(/https:\\/\\/cdn1\\.suno\\.ai\\/[^"'<>\\s\\\\]+?\\.(?:mp3|m4a|wav|webm)(?:\\?[^"'<>\\s\\\\]*)?/gi))
          .map((match) => match[0])
      )
      .map((value) => String(value || '').replace(/&amp;/g, '&').trim())
      .filter((value) => value && !/sil-100|preview|sample|snippet|teaser/i.test(value))
  )).sort((left, right) => mediaRank(right) - mediaRank(left));
  const mediaBySongUrl = {};
  for (const song of songCandidates) {
    const songId = songIdFromUrl(song.href);
    if (!songId) continue;
    const matched = mediaUrls.find((url) => url.includes(songId));
    if (matched) mediaBySongUrl[song.href] = matched;
  }
  const currentPageExpectedScore = expectedScore(document.body?.innerText || document.body?.textContent || '');
  const currentSongUrl = /\\/song\\//i.test(location.href) &&
    (!requireExpectedMatch || currentPageExpectedScore >= expectedMatchThreshold)
    ? location.href
    : '';
  const primarySongUrl = songCandidates[0]?.href || currentSongUrl;
  const primarySongId = songIdFromUrl(primarySongUrl);
  const primaryMediaUrl = primarySongUrl && mediaBySongUrl[primarySongUrl]
    ? mediaBySongUrl[primarySongUrl]
    : primarySongId
      ? (mediaUrls.find((url) => url.includes(primarySongId)) || '')
      : '';
  return JSON.stringify({
    songUrl: songCandidates[0]?.href || '',
    songUrls: songCandidates.map((item) => item.href),
    songs: songCandidates,
    mediaUrl: primaryMediaUrl,
    mediaUrls,
    mediaBySongUrl,
    currentPageExpectedScore,
    expectedMatchThreshold,
    linkCount: songCandidates.length
  });
})()
''';
  }

  String _sunoDownloadScript({
    required List<String> downloadedSongUrls,
    required List<String> allowedSongUrls,
    required String expectedStylePrompt,
    required String expectedLyrics,
    required bool requireExpectedMatch,
    bool dryRun = false,
    String? pendingSongUrl,
  }) {
    final downloadedJson = jsonEncode(downloadedSongUrls);
    final allowedJson = jsonEncode(allowedSongUrls);
    final expectedStyleJson = jsonEncode(expectedStylePrompt.trim());
    final expectedLyricsJson = jsonEncode(expectedLyrics.trim());
    final requireExpectedJson = jsonEncode(requireExpectedMatch);
    final dryRunJson = jsonEncode(dryRun);
    final pendingJson = jsonEncode((pendingSongUrl ?? '').trim());
    return '''
(() => {
  const downloadedSongUrls = new Set($downloadedJson);
  const allowedSongUrls = new Set($allowedJson);
  const expectedStyle = $expectedStyleJson;
  const expectedLyrics = $expectedLyricsJson;
  const requireExpectedMatch = $requireExpectedJson;
  const dryRun = $dryRunJson;
  const pendingSongUrl = $pendingJson;
  const normalize = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
  const normalizeLoose = (value) => normalize(value).toLowerCase();
  const expectedTokens = normalize(expectedStyle)
    .split(/[\\s,，、;；|/]+/g)
    .map((value) => value.trim())
    .filter((value) => value.length >= 2)
    .slice(0, 16);
  const expectedMatchThreshold = Math.max(1, Math.min(13, Math.ceil(expectedTokens.length * 0.8)));
  const lyricSamples = normalize(expectedLyrics)
    .split(/\\n+/g)
    .map((value) => value.trim())
    .filter((value) => value.length >= 24)
    .slice(0, 4)
    .map((value) => value.slice(0, 90));
  const expectedScore = (text) => {
    const haystack = normalizeLoose(text);
    let score = 0;
    for (const token of expectedTokens) {
      if (haystack.includes(token.toLowerCase())) score += 1;
    }
    for (const sample of lyricSamples) {
      if (haystack.includes(sample.toLowerCase())) score += 6;
    }
    return score;
  };
  const currentPageExpectedScore = expectedScore(
    document.body?.innerText || document.body?.textContent || ''
  );
  const isExpectedMatch = (score) =>
    !requireExpectedMatch || score >= expectedMatchThreshold;
  const visible = (el) => {
    if (!el) return false;
    const rect = el.getBoundingClientRect();
    const style = window.getComputedStyle(el);
    return rect.width > 0 &&
      rect.height > 0 &&
      style.visibility !== 'hidden' &&
      style.display !== 'none' &&
      Number(style.opacity || '1') > 0.01;
  };
  const textOf = (el) => normalize([
    el.getAttribute?.('aria-label'),
    el.getAttribute?.('title'),
    el.getAttribute?.('download'),
    el.getAttribute?.('data-testid'),
    el.getAttribute?.('data-test-id'),
    el.getAttribute?.('role'),
    el.href,
    el.innerText,
    el.textContent
  ].filter(Boolean).join(' '));
  const contextText = (el) => {
    const parts = [textOf(el)];
    let current = el.parentElement;
    for (let i = 0; current && i < 5; i += 1, current = current.parentElement) {
      const text = normalize(current.innerText || current.textContent || '');
      if (text && text.length <= 900) parts.push(text);
      parts.push(textOf(current));
    }
    return normalize(parts.join(' ')).slice(0, 1200);
  };
  const summarize = (el) => {
    if (!el) return null;
    const rect = el.getBoundingClientRect();
    return {
      tag: el.tagName.toLowerCase(),
      role: el.getAttribute('role') || '',
      type: el.getAttribute('type') || '',
      id: el.id || '',
      className: String(el.className || '').slice(0, 160),
      ariaLabel: el.getAttribute('aria-label') || '',
      title: el.getAttribute('title') || '',
      href: el.href || '',
      text: textOf(el).slice(0, 180),
      rect: {
        x: Math.round(rect.x),
        y: Math.round(rect.y),
        width: Math.round(rect.width),
        height: Math.round(rect.height)
      }
    };
  };
  const menuLayerSelector = '[role="menu"],[role="listbox"],[data-radix-popper-content-wrapper],[data-floating-ui-portal],[data-side][data-align]';
  const menuLayerFor = (el) => el?.closest?.(menuLayerSelector) || null;
  const clickLikeUser = (el) => {
    if (!el) return;
    el.scrollIntoView({ block: 'center', inline: 'center' });
    el.focus?.();
    const rect = el.getBoundingClientRect();
    const x = Math.max(0, Math.min(window.innerWidth - 1, rect.left + rect.width / 2));
    const y = Math.max(0, Math.min(window.innerHeight - 1, rect.top + rect.height / 2));
    const hit = document.elementFromPoint(x, y);
    const target = hit && (hit === el || el.contains(hit)) ? hit : el;
    const pointerOptions = {
      bubbles: true,
      cancelable: true,
      composed: true,
      view: window,
      clientX: x,
      clientY: y,
      screenX: window.screenX + x,
      screenY: window.screenY + y,
      button: 0,
      buttons: 1,
      pointerId: 1,
      pointerType: 'mouse',
      isPrimary: true
    };
    const mouseOptions = {
      bubbles: true,
      cancelable: true,
      composed: true,
      view: window,
      clientX: x,
      clientY: y,
      screenX: window.screenX + x,
      screenY: window.screenY + y,
      button: 0,
      buttons: 1
    };
    try {
      if (typeof PointerEvent === 'function') {
        target.dispatchEvent(new PointerEvent('pointerover', pointerOptions));
        target.dispatchEvent(new PointerEvent('pointermove', pointerOptions));
        target.dispatchEvent(new PointerEvent('pointerdown', pointerOptions));
      }
      target.dispatchEvent(new MouseEvent('mouseover', mouseOptions));
      target.dispatchEvent(new MouseEvent('mousemove', mouseOptions));
      target.dispatchEvent(new MouseEvent('mousedown', mouseOptions));
      if (typeof PointerEvent === 'function') {
        target.dispatchEvent(new PointerEvent('pointerup', {
          ...pointerOptions,
          buttons: 0
        }));
      }
      target.dispatchEvent(new MouseEvent('mouseup', {
        ...mouseOptions,
        buttons: 0
      }));
      el.click?.();
    } catch (_) {
      el.click?.();
    }
  };
  const isDisabled = (el) =>
    Boolean(el?.disabled) || el?.getAttribute?.('aria-disabled') === 'true';
  const clickableAncestor = (el) =>
    el?.closest?.('button,[role="button"],[role="menuitem"],a,label');
  const songUrlFor = (el) => {
    const anchor = el.closest?.('a[href*="/song/"],a[href*="suno.com/song"]') ||
      el.querySelector?.('a[href*="/song/"],a[href*="suno.com/song"]') ||
      el.closest?.('[data-testid],[data-test-id],article,section,div')?.querySelector?.('a[href*="/song/"],a[href*="suno.com/song"]');
    const href = String(anchor?.href || '');
    return href || '';
  };
  const titleFor = (el) => {
    const container = el.closest?.('article,section,[data-testid],[data-test-id],div') || el;
    const heading = container.querySelector?.('h1,h2,h3,[role="heading"]');
    const headingText = normalize(heading?.innerText || heading?.textContent || '');
    if (headingText) return headingText.slice(0, 120);
    const text = normalize(container.innerText || container.textContent || '');
    return text.split(/\\n|\\|/).map((part) => normalize(part)).find((part) =>
      part.length >= 3 &&
      part.length <= 120 &&
      !/download|audio|mp3|create|share|more|下载|音频|创建|分享|更多/i.test(part)
    ) || '';
  };
  const controls = Array.from(document.querySelectorAll(
    'a[href],button,[role="button"],[role="menuitem"],label,[aria-label],[title],[data-testid],[data-test-id]'
  ))
    .filter(visible)
    .map((el) => {
      const clickable = clickableAncestor(el);
      if (!clickable || isDisabled(clickable)) return null;
      const label = textOf(el);
      const context = contextText(el);
      const matchScore = expectedScore(context);
      const inOpenMenu = Boolean(menuLayerFor(clickable) || menuLayerFor(el));
      if (requireExpectedMatch && !pendingSongUrl && !isExpectedMatch(matchScore)) return null;
      const href = String(clickable.href || el.href || '');
      if (/suno\\.com\\/@|\\/\\@/i.test(href)) return null;
      if (/\\/style\\//i.test(href)) return null;
      if (href && !/\\/song\\//i.test(href) && !/download|audio|mp3/i.test(href)) return null;
      const songUrl = songUrlFor(clickable) || songUrlFor(el);
      const onSongDetail = /\\/song\\//i.test(location.href);
      const currentUrlMatchesPending = pendingSongUrl &&
        location.href.startsWith(pendingSongUrl);
      if (allowedSongUrls.size > 0 && !songUrl && !onSongDetail && !pendingSongUrl) return null;
      if (allowedSongUrls.size > 0 && songUrl && !allowedSongUrls.has(songUrl)) return null;
      if (pendingSongUrl && songUrl && songUrl !== pendingSongUrl) return null;
      if (songUrl && downloadedSongUrls.has(songUrl)) return null;
      if (!songUrl && pendingSongUrl && downloadedSongUrls.has(pendingSongUrl)) return null;
      if (requireExpectedMatch && songUrl && !isExpectedMatch(matchScore)) {
        const trustedSongDetail =
          onSongDetail && location.href.startsWith(songUrl) && isExpectedMatch(currentPageExpectedScore);
        if (!trustedSongDetail) return null;
      }
      if (requireExpectedMatch && pendingSongUrl && !songUrl) {
        const trustedPendingDetail =
          onSongDetail && currentUrlMatchesPending && isExpectedMatch(currentPageExpectedScore);
        const trustedLibraryContext =
          !onSongDetail && isExpectedMatch(matchScore);
        const trustedOpenMenu =
          inOpenMenu && !onSongDetail && isExpectedMatch(currentPageExpectedScore);
        if (!trustedPendingDetail && !trustedLibraryContext && !trustedOpenMenu) {
          return null;
        }
      }
      let score = 0;
      const audioPattern = /\\bmp3\\b|\\baudio\\b|download audio|下载音频|音频下载|音频|聲音/i;
      const downloadPattern = /download|save|export|下载|下載|保存/i;
      const menuPattern = /more|options|menu|actions|ellipsis|更多|菜单|選單|操作/i;
      const hasDownloadIntent =
        audioPattern.test(label) ||
        downloadPattern.test(label) ||
        /download|audio|mp3/i.test(href) ||
        (inOpenMenu && (audioPattern.test(context) || downloadPattern.test(context)));
      const hasMenuIntent =
        menuPattern.test(label) ||
        /more menu contents|more options/i.test(label) ||
        (inOpenMenu && menuPattern.test(context));
      if (!hasDownloadIntent && !hasMenuIntent) return null;
      const previewReject = /preview|demo|sample|clip|snippet|teaser|试听|試聽|预览|預覽|片段|样例|樣例/i;
      const incompleteReject = /generating|creating|processing|queued|loading|failed|error|retry|生成中|创建中|处理中|排队|失败|重试/i;
      const reject = /video|mp4|wav|midi|stems?|instrumental|share|copy|remix|extend|cover|image|artwork|delete|report|play|like|dislike|publish|创建|create|视频|影片|分享|复制|删除|举报|播放|喜欢|不喜欢|發布|发布|封面|图片|圖片/i;
      const profileReject = /profile|subscription|account|followers|following|upgrade|sign out|signout|log out|logout|my taste|个人主页|账户|账号|订阅|退出/i;
      const sidebarReject = /home|explore|create|studio|library|notifications|labs|terms|policies|upgrade|首页|探索|工作室|资料库|通知|条款/i;
      const globalMenuReject = /earn credits|invite friends|what'?s new|help|about|blog|careers|feedback|instagram|discord|twitter|\\bx\\b|积分|邀请|帮助|关于|博客|职业|反馈/i;
      const createFormReject = /add audio|browse|upload|record audio|save prompt|clear all form|save lyrics|clear lyrics|generate lyrics|enhance lyrics|saved styles|recommended styles|添加音频|上传|录音|保存歌词|清空歌词|生成歌词|推荐风格/i;
      const openMenuContext = /remix|edit|publish|share|download|manage|queue|playlist|song radio|trash|audio|mp3/i.test(context);
      if (previewReject.test(label) || previewReject.test(context)) return null;
      if (incompleteReject.test(context)) return null;
      if (profileReject.test(label) && !audioPattern.test(label)) return null;
      const clickableRect = clickable.getBoundingClientRect();
      if (menuPattern.test(label) && clickableRect.left < 220 && clickableRect.width >= 80) return null;
      if (globalMenuReject.test(label) ||
          /listen-and-rank|release-notes|help\\.suno|\\/about|\\/blog|ashbyhq|x\\.com|instagram|discord/i.test(href)) return null;
      if (menuPattern.test(label) &&
          sidebarReject.test(context) &&
          !/download|audio|mp3|remix|edit|publish|share/i.test(context)) return null;
      if (/\\/create(?:\\/|\$)/i.test(location.pathname) && createFormReject.test(label)) return null;
      if (reject.test(label) && !audioPattern.test(label)) return null;
      if (allowedSongUrls.size > 0 &&
          !songUrl &&
          !onSongDetail &&
          pendingSongUrl &&
          !openMenuContext &&
          matchScore <= 0) return null;
      if (audioPattern.test(label)) score += 35;
      if (audioPattern.test(context)) score += 12;
      if (downloadPattern.test(label)) score += 24;
      if (downloadPattern.test(context)) score += 8;
      if (menuPattern.test(label)) score += 9;
      if (inOpenMenu && audioPattern.test(label)) score += 28;
      if (inOpenMenu && downloadPattern.test(label)) score += 18;
      if (isExpectedMatch(matchScore)) score += Math.min(18, 6 + matchScore * 2);
      if (/download|audio|mp3/i.test(href)) score += 20;
      if (clickable.tagName === 'A' && href) score += 6;
      if (clickable.tagName === 'BUTTON') score += 4;
      if (!label && clickable.querySelector?.('svg')) score += 2;
      score -= Math.max(0, label.length - 80) / 30;
      if (songUrl) score += 8;
      const directDownload = audioPattern.test(label) ||
        /download audio|audio download|mp3/i.test(label) ||
        /download|audio|mp3/i.test(href);
      return {
        clickable,
        label,
        context,
        href,
        score,
        directDownload,
        songUrl,
        title: titleFor(clickable),
        inOpenMenu
      };
    })
    .filter(Boolean)
    .sort((left, right) => right.score - left.score);
  const augmentedControls = controls.slice();
  const playbarMenu = Array.from(document.querySelectorAll('button,[role="button"],[aria-label]'))
    .filter(visible)
    .find((el) => /more menu contents/i.test(textOf(el)));
  const playbarSongUrl = playbarMenu ? songUrlFor(playbarMenu) : '';
  const playbarAllowed =
    allowedSongUrls.size === 0 ||
    (playbarSongUrl && allowedSongUrls.has(playbarSongUrl));
  if (playbarMenu &&
      playbarAllowed &&
      !augmentedControls.some((item) => item.clickable === playbarMenu)) {
    augmentedControls.push({
      clickable: playbarMenu,
      label: textOf(playbarMenu),
      context: contextText(playbarMenu),
      href: '',
      score: 18,
      directDownload: false,
      songUrl: playbarSongUrl || pendingSongUrl || '',
      title: titleFor(playbarMenu),
      inOpenMenu: false
    });
  }
  augmentedControls.sort((left, right) => right.score - left.score);
  const direct = augmentedControls.find((item) => item.directDownload && item.score >= 28);
  const openMenuText = normalize(Array.from(document.querySelectorAll(menuLayerSelector))
    .filter(visible)
    .map((el) => el.innerText || el.textContent || '')
    .join(' '));
  const nonDownloadSongMenuOpen =
    /restore to library|delete permanently|report|恢复到资料库|永久删除|举报/i.test(openMenuText) &&
    !/download|audio|mp3|下载|下載|音频|音頻/i.test(openMenuText);
  if (!direct && nonDownloadSongMenuOpen) {
    return JSON.stringify({
      ok: false,
      retry: false,
      stage: 'nonDownloadMenu',
      message: 'Suno 当前歌曲详情菜单没有 Download/Audio 项，将改到 Library 查找完整歌曲。',
      menuText: openMenuText.slice(0, 240),
      candidates: augmentedControls.slice(0, 12).map((item) => ({
        label: item.label,
        score: item.score,
        directDownload: item.directDownload,
        songUrl: item.songUrl,
        title: item.title,
        inOpenMenu: item.inOpenMenu,
        target: summarize(item.clickable)
      })),
      currentPageExpectedScore,
      expectedMatchThreshold
    });
  }
  const menu = augmentedControls.find((item) =>
    item.inOpenMenu && item.score >= 10 && !/more menu contents/i.test(item.label)
  ) || augmentedControls.find((item) => item.score >= 10);
  const target = direct || menu;
  if (!target) {
    return JSON.stringify({
      ok: false,
      retry: false,
      message: 'Suno 生成结果已出现，但没有找到 Download 或 Audio 下载按钮。',
      candidates: augmentedControls.slice(0, 12).map((item) => ({
        label: item.label,
        score: item.score,
        directDownload: item.directDownload,
        songUrl: item.songUrl,
        title: item.title,
        inOpenMenu: item.inOpenMenu,
        target: summarize(item.clickable)
      })),
      currentPageExpectedScore,
      expectedMatchThreshold
    });
  }
  if (dryRun) {
    return JSON.stringify({
      ok: Boolean(direct),
      retry: !direct,
      dryRun: true,
      wouldClick: true,
      stage: direct ? 'download' : 'menu',
      songUrl: target.songUrl || pendingSongUrl || ('suno-row:' + (target.title || 'matched')),
      title: target.title || '',
      target: summarize(target.clickable),
      candidates: augmentedControls.slice(0, 12).map((item) => ({
        label: item.label,
        score: item.score,
        directDownload: item.directDownload,
        songUrl: item.songUrl,
        title: item.title,
        inOpenMenu: item.inOpenMenu,
        target: summarize(item.clickable)
      })),
      currentPageExpectedScore,
      expectedMatchThreshold
    });
  }
  clickLikeUser(target.clickable);
  return JSON.stringify({
    ok: Boolean(direct),
    retry: !direct,
    clicked: true,
    stage: direct ? 'download' : 'menu',
    songUrl: target.songUrl || pendingSongUrl || ('suno-row:' + (target.title || 'matched')),
    title: target.title || '',
    target: summarize(target.clickable),
    candidates: augmentedControls.slice(0, 12).map((item) => ({
      label: item.label,
      score: item.score,
      directDownload: item.directDownload,
      songUrl: item.songUrl,
      title: item.title,
      inOpenMenu: item.inOpenMenu,
      target: summarize(item.clickable)
    })),
    currentPageExpectedScore,
    expectedMatchThreshold
  });
})()
''';
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
    await _cachedListeningPath(
      text: text,
      voiceType: TtsService.defaultVoiceType,
      preferRequestedVoice: false,
      cachePurpose: 'listening_tts',
    );
    return {'prepared': true};
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
    if (english.isEmpty) {
      throw const FormatException('英文字幕不能为空');
    }

    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) {
      throw FormatException('文章不存在（id=$articleId）');
    }
    final article = await _articleWithCurrentSentences(rawArticle);
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
    final englishChanged = english != oldEnglish ||
        (previousEnglish.isNotEmpty && previousEnglish != english);
    final chineseChanged = chinese != oldChinese;

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
    if (chinese.isEmpty) {
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
        'chinese': chinese,
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
    final article = await _articleWithCurrentSentences(rawArticle);
    if (sentenceIndex < 0 || sentenceIndex >= article.sentences.length) {
      throw FormatException('句子序号不存在（index=$sentenceIndex）');
    }
    await _stopListeningPlayback();
    await _stopSongPlayback();
    final english = article.sentences[sentenceIndex].trim();
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
      _clearPreloadAggregatesForArticle(followArticleId);
      TtsMemoryCacheService.releaseArticle(followArticleId);
    }
    _closeFollowSession();
    final listeningArticleId = _activeListeningArticleId;
    if (listeningArticleId != null && listeningArticleId != articleId) {
      _clearPreloadAggregatesForArticle(listeningArticleId);
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
    if (!TtsService.isPresetVoice(speakerId)) {
      throw const FormatException('请选择支持的声音');
    }

    await AppConfig.saveVolcTtsSpeakerId(speakerId);
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
    );
    unawaited(_pushEvent('recording.settings.state', payload));
    return payload;
  }

  Future<Map<String, dynamic>> _handleSettingsPreviewVoice(
    BridgeMessage message,
  ) async {
    final speakerId = _payloadString(message.payload, 'speakerId').trim();
    if (!TtsService.isPresetVoice(speakerId)) {
      throw const FormatException('请选择支持的声音');
    }

    await _playVoicePreview(speakerId);
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
      final handle = await TtsMemoryCacheService.load(
        text: text,
        voiceType: TtsService.defaultVoiceType,
        preferRequestedVoice: false,
        articleId: _activeArticleContextId,
        cachePurpose: 'listening_tts',
      );
      if (!_isActiveListeningPlayback(token)) {
        return;
      }

      final player = AudioPlayer();
      _listeningPlayer = player;
      try {
        await _playAudioSourceToEnd(
          player: player,
          source: handle.toAudioSource(),
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

    final safeStart = startIndex.clamp(0, cleanItems.length - 1).toInt();
    final endIndex = singleItem ? safeStart : cleanItems.length - 1;
    final player = AudioPlayer();
    _listeningPlayer = player;
    var currentPlaybackIndex = safeStart;
    final pendingHandles = <int, Future<TtsMemoryHandle>>{};

    Future<TtsMemoryHandle> loadHandleAt(int itemIndex) {
      final item = cleanItems[itemIndex];
      final english = (item['english'] ?? '').toString().trim();
      return TtsMemoryCacheService.load(
        text: english,
        voiceType: TtsService.defaultVoiceType,
        preferRequestedVoice: false,
        articleId: articleId,
        cachePurpose: 'listening_tts',
      );
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
        await _playAudioSourceToEnd(
          player: player,
          source: englishHandle.toAudioSource(),
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
        await TtsMemoryCacheService.load(
          text: newEnglish,
          voiceType: TtsService.defaultVoiceType,
          preferRequestedVoice: false,
          articleId: articleId,
          cachePurpose: 'listening_tts',
          forceRefresh: true,
        );
        englishStatus = 'ready';
      } catch (error) {
        englishStatus = 'error';
        errors.add('英文语音合成失败：$error');
      }
    }

    return {
      'status': errors.isEmpty ? 'ready' : 'error',
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
  }) async {
    final token = ++_songPlaybackToken;
    await _stopListeningPlayback();
    await _stopVoicePreview();
    await _disposeSongPlayer();

    final player = AudioPlayer();
    _songPlayer = player;
    try {
      final timeline = (timelinePath ?? '').trim().isEmpty
          ? null
          : await SongSubtitleTimelineService.readTimeline(timelinePath!);
      await player.setFilePath(path).timeout(const Duration(seconds: 10));
      await player.seek(Duration.zero).timeout(const Duration(seconds: 3));
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
      if (timeline != null) {
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
          final cue = _songCueAt(timeline, positionMs);
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
                player.duration?.inMilliseconds ?? timeline.durationMs,
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

  SongSubtitleCue? _songCueAt(SongSubtitleTimeline timeline, int positionMs) {
    for (final cue in timeline.cues) {
      if (positionMs >= cue.startMs && positionMs < cue.endMs) {
        return cue;
      }
    }
    if (timeline.cues.isEmpty) {
      return null;
    }
    if (positionMs < timeline.cues.first.startMs) {
      return null;
    }
    return timeline.cues.last;
  }

  Future<void> _playVoicePreview(String speakerId) async {
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
  }

  Future<void> _disposePreviewPlayer() async {
    final player = _previewPlayer;
    _previewPlayer = null;
    if (player == null) {
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
  }

  Future<void> _disposeSongPlayer() async {
    final player = _songPlayer;
    _songPlayer = null;
    if (player == null) {
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
      final article = await _articleWithCurrentSentences(originalArticle);
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
    json['chapterOrder'] = chapter.chapterOrder;
    final coverPayload =
        await PictureBookService.coverImagePayloadForArticle(articleId);
    if (coverPayload != null) {
      json.addAll(coverPayload);
    }
    return json;
  }

  Future<StorySeries> _resolveStorySeries({
    required int? requestedSeriesId,
    required String requestedSeriesTitle,
    required String fallbackTitle,
  }) async {
    if (requestedSeriesId != null) {
      final series =
          await DatabaseService.getStorySeriesById(requestedSeriesId);
      if (series != null) {
        return series;
      }
    }

    final title = requestedSeriesTitle.isNotEmpty
        ? requestedSeriesTitle
        : fallbackTitle.trim().isEmpty
            ? 'Picture Book Story'
            : fallbackTitle.trim();
    final existingSeries = await DatabaseService.getStorySeries();
    for (final series in existingSeries) {
      if (series.title.trim().toLowerCase() == title.trim().toLowerCase()) {
        return series;
      }
    }

    return PictureBookService.createSeries(
      title: title,
    );
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

    try {
      final reply = await PracticeTextService.suggestArticleTitle(
        content: englishContent,
      ).timeout(const Duration(seconds: 12));
      final generated = _normalizeEnglishWordJoiners(reply.text.trim());
      if (generated.isNotEmpty) {
        return generated.length > 80 ? generated.substring(0, 80) : generated;
      }
    } catch (error) {
      TomatoLogger.warn(
        category: 'article',
        event: 'title_suggestion.failed',
        error: error,
      );
    }

    final fallback = _fallbackArticleTitle(englishContent);
    return fallback.length > 80 ? fallback.substring(0, 80) : fallback;
  }

  String _fallbackArticleTitle(String englishContent) {
    final sentences = NlpService.splitSentences(englishContent);
    final firstSentence = sentences.isEmpty ? null : sentences.first;
    final base = (firstSentence ?? englishContent)
        .replaceAll(RegExp(r"[^A-Za-z0-9\s'\-]"), ' ')
        .trim();
    final words = base
        .split(RegExp(r'\s+'))
        .where((word) => RegExp(r'[A-Za-z]').hasMatch(word))
        .take(5)
        .toList(growable: false);
    if (words.isEmpty) {
      return 'English Story';
    }
    return words.map(_titleCaseFallbackWord).join(' ');
  }

  String _titleCaseFallbackWord(String word) {
    final cleaned = word
        .replaceAll(RegExp(r'[‘’]'), "'")
        .replaceAll(RegExp(r"[^A-Za-z'\-]"), '');
    if (cleaned.isEmpty) {
      return word;
    }
    return cleaned
        .split('-')
        .map(
          (part) => part.isEmpty
              ? part
              : '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}',
        )
        .join('-');
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

    const batchSize = 4;
    for (var start = 0; start < sentences.length; start += batchSize) {
      final futures = <Future<ArticleSentenceTranslation?>>[];
      for (var offset = 0; offset < batchSize; offset += 1) {
        final index = start + offset;
        if (index >= sentences.length || rowsByIndex.containsKey(index)) {
          continue;
        }
        futures.add(
          _generatedArticleTranslationRow(
            articleId: articleId,
            sentenceIndex: index,
            sentence: sentences[index],
            createdAt: createdAt,
          ),
        );
      }

      for (final row in await Future.wait(futures)) {
        if (row != null) {
          rowsByIndex[row.sentenceIndex] = row;
        }
      }
    }

    final rows = rowsByIndex.values.toList(growable: false)
      ..sort((a, b) => a.sentenceIndex.compareTo(b.sentenceIndex));
    if (rows.isNotEmpty) {
      await DatabaseService.saveArticleSentenceTranslations(articleId, rows);
    }
  }

  Future<ArticleSentenceTranslation?> _generatedArticleTranslationRow({
    required int articleId,
    required int sentenceIndex,
    required String sentence,
    required DateTime createdAt,
  }) async {
    final english = sentence.trim();
    if (english.isEmpty) {
      return null;
    }

    try {
      final reply = await PracticeTextService.translateToChinese(
        text: english,
        articleId: articleId,
        cachePurpose: 'article_sentence_translation',
      ).timeout(const Duration(seconds: 20));
      if (reply.source != TextGenerationReplySource.remote &&
          reply.source != TextGenerationReplySource.cached) {
        return null;
      }
      final chinese = reply.text.trim();
      if (chinese.isEmpty || chinese.startsWith('中文翻译暂不可用')) {
        return null;
      }
      return ArticleSentenceTranslation(
        articleId: articleId,
        sentenceIndex: sentenceIndex,
        englishSentence: english,
        chineseText: chinese,
        source: reply.source == TextGenerationReplySource.cached
            ? 'cached_at_create'
            : 'generated_at_create',
        createdAt: createdAt,
        updatedAt: createdAt,
      );
    } catch (error) {
      TomatoLogger.warn(
        category: 'article',
        event: 'translation_at_create.failed',
        articleId: articleId,
        data: {'sentenceIndex': sentenceIndex},
        error: error,
      );
      return null;
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
            ).timeout(const Duration(seconds: 12));
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

  Future<Article> _articleWithCurrentSentences(Article article) async {
    final id = article.id;
    final originalContent = article.content;
    var content = _normalizeEnglishWordJoiners(originalContent);
    var sentences = NlpService.splitSentences(content);

    if (sentences.isEmpty && _containsChinese(content)) {
      final parsedInput = PracticeInputParser.parse(content);
      final translatedContent = await _englishPracticeContent(
        content,
        articleId: id,
        parsedInput: parsedInput,
      );
      final translatedSentences = NlpService.splitSentences(translatedContent);
      if (translatedSentences.isNotEmpty) {
        content = translatedContent;
        sentences = translatedSentences;
        if (id != null) {
          await DatabaseService.updateArticleContentAndSentences(
            id,
            content,
            sentences,
          );
        }
        return article.copyWith(content: content, sentences: sentences);
      }
    }

    final contentChanged = content != originalContent;
    final sentencesChanged = !listEquals(article.sentences, sentences);
    if (sentences.isEmpty || (!contentChanged && !sentencesChanged)) {
      return article;
    }

    if (id != null) {
      if (contentChanged) {
        await DatabaseService.updateArticleContentAndSentences(
          id,
          content,
          sentences,
        );
      } else {
        await DatabaseService.updateArticleSentences(id, sentences);
      }
    }
    return article.copyWith(content: content, sentences: sentences);
  }

  String _contentWithUpdatedSentence({
    required String content,
    required String oldSentence,
    required String newSentence,
    required List<String> sentences,
  }) {
    final oldText = oldSentence.trim();
    final newText = newSentence.trim();
    if (oldText.isEmpty) {
      return sentences.map((sentence) => sentence.trim()).join(' ');
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
    if (_versionTimelineStatus(version) != 'ready' || timelinePath.isEmpty) {
      throw const FormatException('请先生成这首歌的字幕时间线');
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
      fps: fps <= 0 ? RecordingExportService.defaultFps : fps,
    );
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
    final speakerId = await AppConfig.volcTtsSpeakerId;
    final resolvedSpeakerId = TtsService.isPresetVoice(speakerId)
        ? speakerId.trim()
        : TtsService.defaultVoiceType;
    final songSettings = await _songSettingsPayload();
    return {
      'tts': {
        'resourceId': await AppConfig.volcTtsResourceId,
        'speakerId': resolvedSpeakerId,
      },
      'song': songSettings,
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
    final outputDirectory = _resolveSunoOutputDirectory(rawOutputDirectory);
    if (rawOutputDirectory.isNotEmpty &&
        AssetPathService.isTemporaryAssetDirectory(rawOutputDirectory)) {
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
    }
    return {
      'sunoOutputDirectory': outputDirectory,
      'sunoTimeoutMinutes': timeout.clamp(5, 120),
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
    pictureBookScene,
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
    final listeningArticleId = _activeListeningArticleId;
    final chatArticleId = _activeChatArticleId;
    final payload = <String, dynamic>{
      'activeFollowArticleId': followArticleId,
      'activeListeningArticleId': listeningArticleId,
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

  String _sunoStyleKey(String stylePrompt) {
    final normalized =
        stylePrompt.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    return normalized.isEmpty ? 'suno:auto-style' : 'suno:$normalized';
  }

  List<String> _sunoSongUrlList(Object? value) {
    final urls = <String>[];
    if (value is List) {
      for (final item in value) {
        final text = _nonEmptyString(item);
        if (text == null || _isSyntheticSunoSongKey(text)) {
          continue;
        }
        urls.add(text);
      }
    }
    return urls.toSet().toList(growable: false);
  }

  List<ArticleSongVersion> _sunoVersionsForStyle(String stylePrompt) {
    final styleKey = _sunoStyleKey(stylePrompt);
    return _sunoVersions
        .where((version) => (version.styleKey ?? '').trim() == styleKey)
        .toList(growable: false);
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

  String _versionTimelineStatus(ArticleSongVersion version) {
    final explicit = (version.timelineStatus ?? '').trim();
    if (explicit.isNotEmpty && explicit != 'generating') {
      return explicit;
    }
    return (version.timelinePath ?? '').trim().isNotEmpty ? 'ready' : 'missing';
  }

  List<ArticleSongVersion> _songVersionsForPayload(
    int articleId,
    List<ArticleSongVersion> versions,
  ) {
    final payloadVersions = versions.map((version) {
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

  void _rememberCurrentStyleDownloadedSunoUrls() {
    _sunoDownloadedSongUrls
      ..clear()
      ..addAll(
        _sunoVersionsForStyle(_sunoStylePrompt)
            .map(
              (version) => (version.songUrl ?? '').trim(),
            )
            .where((value) => value.isNotEmpty),
      );
  }

  void _syncCurrentStyleDownloadedSunoUrlsIntoDetected() {
    _sunoDetectedSongUrls.addAll(
      _sunoVersionsForStyle(_sunoStylePrompt)
          .map((version) => (version.songUrl ?? '').trim())
          .where(
              (value) => value.isNotEmpty && !_isSyntheticSunoSongKey(value)),
    );
  }

  bool _currentSunoDownloadsComplete() {
    if (_sunoDetectedSongUrls.isEmpty) {
      return false;
    }
    final downloaded = _sunoVersionsForStyle(_sunoStylePrompt)
        .map((version) => (version.songUrl ?? '').trim())
        .where((value) => value.isNotEmpty)
        .toSet();
    return _sunoDetectedSongUrls.every(downloaded.contains);
  }

  String? _pendingSunoDownloadTarget(List<String> missingSongUrls) {
    final currentPending = (_sunoPendingDownloadSongUrl ?? '').trim();
    if (currentPending.isNotEmpty && missingSongUrls.contains(currentPending)) {
      return currentPending;
    }
    return missingSongUrls.isEmpty ? null : missingSongUrls.first;
  }

  bool _isSunoProfileUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) {
      return false;
    }
    final host = uri.host.toLowerCase();
    if (host != 'suno.com' && host != 'www.suno.com') {
      return false;
    }
    return uri.pathSegments.isNotEmpty &&
        uri.pathSegments.first.startsWith('@');
  }

  bool _isSyntheticSunoSongKey(String value) {
    return value.trim().toLowerCase().startsWith('suno-row:');
  }

  String _sunoPageKind(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) {
      return 'unknown';
    }
    final host = uri.host.toLowerCase();
    if (host != 'suno.com' && host != 'www.suno.com') {
      return 'external';
    }
    if (_isSunoProfileUrl(url)) {
      return 'profile';
    }
    if (uri.pathSegments.contains('song')) {
      return 'song';
    }
    if (uri.pathSegments.contains('create')) {
      return 'create';
    }
    if (uri.pathSegments.contains('library') ||
        (uri.pathSegments.length == 1 && uri.pathSegments.first == 'me')) {
      return 'library';
    }
    return uri.pathSegments.isEmpty ? 'home' : 'unknown';
  }

  bool _isSunoPageSettled(String currentUrl) {
    final loadedUrl = _sunoLastLoadStopUrl;
    final loadedAt = _sunoLastLoadStopAt;
    if (loadedUrl == null || loadedAt == null) {
      return false;
    }
    if (!_sameSunoPageLocation(currentUrl, loadedUrl)) {
      return false;
    }
    return DateTime.now().difference(loadedAt) >=
        const Duration(milliseconds: 800);
  }

  bool _sameSunoPageLocation(String left, String right) {
    final leftUri = Uri.tryParse(left.trim());
    final rightUri = Uri.tryParse(right.trim());
    if (leftUri == null || rightUri == null) {
      return left.trim() == right.trim();
    }
    return leftUri.host.toLowerCase() == rightUri.host.toLowerCase() &&
        leftUri.path == rightUri.path;
  }

  String _safeSunoSnapshotStem(String url, DateTime timestamp) {
    final stamp = timestamp
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .replaceAll('Z', 'z');
    final kind = _sunoPageKind(url);
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

  String _defaultSunoOutputDirectory() => path_lib.join(
        AssetPathService.programDirectory(),
        'suno-music',
      );

  String _resolveSunoOutputDirectory(String configured) =>
      AssetPathService.resolvePersistentDirectory(
        configured: configured,
        defaultDirectory: _defaultSunoOutputDirectory(),
      );

  String _sunoOutputDirectorySettingForSave(String configured) {
    final trimmed = configured.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    return AssetPathService.isTemporaryAssetDirectory(trimmed) ? '' : trimmed;
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

class _PreloadAggregate {
  _PreloadAggregate(this.runId);

  final String runId;
  int completed = 0;
  int total = 0;
  int failed = 0;
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
