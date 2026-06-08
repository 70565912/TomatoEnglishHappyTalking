import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/webview/webview_environment.dart';
import '../../data/models/article_model.dart';
import '../../data/models/picture_book_model.dart';
import '../../services/database_service.dart';
import '../../services/content_safety_service.dart';
import '../../services/nlp_service.dart';
import '../../services/picture_book_service.dart';
import '../../services/practice_input_parser.dart';
import '../../services/practice_text_service.dart';
import '../../services/scoring_service.dart';
import '../../services/tts_service.dart';
import '../../services/translation_service.dart';
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
  static const _listeningChineseVoiceType = 'zh_female_xiaoxue_uranus_bigtts';
  static const _englishVoicePreviewText =
      "Hello, I am your tomato tutor. Let's practice English together.";
  static const _chineseVoicePreviewText = '你好，我是番茄助教。让我们一起快乐练英语。';

  InAppWebViewController? _controller;
  WebShellQaServer? _qaServer;
  ProviderSubscription<AsyncValue<FollowReadState>>? _followSubscription;
  ProviderSubscription<ChatState>? _chatSubscription;
  AudioPlayer? _listeningPlayer;
  AudioPlayer? _previewPlayer;
  final Map<String, Future<String>> _listeningTtsPathFutures = {};
  int? _activeFollowArticleId;
  int? _activeListeningArticleId;
  int? _activeChatArticleId;
  int _listeningPlaybackToken = 0;
  int _previewPlaybackToken = 0;
  bool _listeningPausedForWord = false;
  bool _webReady = false;
  String? _loadError;
  final List<Map<String, dynamic>> _pendingEvents = [];

  bool get _usesDevServer => _devServerUrl.trim().isNotEmpty;

  BridgeRouter get _bridgeRouter => BridgeRouter({
        'app.ready': _handleAppReady,
        'app.navigate': _handleAppNavigate,
        'app.back': _handleAppBack,
        'article.list': _handleArticleList,
        'article.translateToEnglish': _handleArticleTranslateToEnglish,
        'article.suggestTitle': _handleArticleSuggestTitle,
        'article.create': _handleArticleCreate,
        'article.delete': _handleArticleDelete,
        'series.list': _handleSeriesList,
        'series.create': _handleSeriesCreate,
        'series.attachArticle': _handleSeriesAttachArticle,
        'pictureBook.state': _handlePictureBookState,
        'pictureBook.generate': _handlePictureBookGenerate,
        'pictureBook.retryPage': _handlePictureBookRetryPage,
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
        'listening.play': _handleListeningPlay,
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
        'settings.previewVoice': _handleSettingsPreviewVoice,
        'contentSafety.setRuleEnabled': _handleContentSafetySetRuleEnabled,
        'contentSafety.deleteRule': _handleContentSafetyDeleteRule,
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
    unawaited(_stopListeningPlayback());
    unawaited(_stopVoicePreview());
    _listeningTtsPathFutures.clear();
    _closeFollowSession();
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
      'series': articles['series'],
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
    if (!path.startsWith('/listen')) {
      unawaited(_stopListeningPlayback());
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

    final parsedInput = PracticeInputParser.parse(content);
    final englishContent = await _englishPracticeContent(
      content,
      parsedInput: parsedInput,
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
    if (parsedInput.sourceKind == PracticeInputSourceKind.standardBilingual) {
      await DatabaseService.saveArticleSentenceTranslations(
        id,
        parsedInput.buildSentenceTranslations(
          articleId: id,
          sentences: sentences,
        ),
      );
    }
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
      final series = await _resolveStorySeries(
        requestedSeriesId: requestedSeriesId,
        requestedSeriesTitle: requestedSeriesTitle,
        fallbackTitle: title,
      );
      final seriesId = series.id;
      if (seriesId == null) {
        throw const FormatException('书籍创建失败');
      }
      final chapter = await PictureBookService.ensureChapterForArticle(
        seriesId: seriesId,
        article: savedArticle,
      );
      unawaited(
        PictureBookService.generateForArticle(
          article: savedArticle,
          chapter: chapter,
          onProgress: (state) => _pushEvent('pictureBook.state', state),
        ),
      );
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
    if (_activeFollowArticleId == articleId) {
      _closeFollowSession();
    }
    if (_activeListeningArticleId == articleId) {
      await _stopListeningPlayback();
      _activeListeningArticleId = null;
    }
    if (_activeChatArticleId == articleId) {
      _closeChatSession();
    }
    final payload = await _articleListPayload();
    unawaited(_pushEvent('article.state', payload));
    return payload;
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
    return _storySeriesListPayload();
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
    return PictureBookService.statePayload(articleId);
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
    final pageIndex = _payloadInt(message.payload, 'pageIndex');
    unawaited(
      PictureBookService.regeneratePage(
        articleId: articleId,
        pageIndex: pageIndex,
        onProgress: (state) => _pushEvent('pictureBook.state', state),
      ),
    );
    final state = await PictureBookService.statePayload(articleId);
    unawaited(_pushEvent('pictureBook.state', state));
    return state;
  }

  Future<Map<String, dynamic>> _handleFollowOpen(BridgeMessage message) async {
    final articleId = _payloadInt(message.payload, 'articleId');
    _closeChatSession();
    _activeListeningArticleId = null;
    await _stopListeningPlayback();
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
    _closeFollowSession();
    _closeChatSession();
    await _stopListeningPlayback();
    _activeListeningArticleId = articleId;

    final rawArticle = await DatabaseService.getArticleById(articleId);
    if (rawArticle == null) {
      throw FormatException('文章不存在（id=$articleId）');
    }

    final article = await _articleWithCurrentSentences(rawArticle);
    final items = <Map<String, dynamic>>[];
    for (var i = 0; i < article.sentences.length; i++) {
      final sentence = article.sentences[i].trim();
      if (sentence.isEmpty) {
        continue;
      }
      final importedTranslation = article.id == null
          ? null
          : await DatabaseService.getArticleSentenceTranslation(
              article.id!,
              i,
              sentence,
            );
      items.add({
        'index': i,
        'english': sentence,
        'chinese': importedTranslation ?? '',
      });
    }

    if (article.id != null && items.isNotEmpty) {
      unawaited(_pushListeningTranslations(article.id!, article.sentences));
    }

    return {
      'article': _articleJson(article),
      'items': items,
    };
  }

  Future<Map<String, dynamic>> _handleListeningPlay(
    BridgeMessage message,
  ) async {
    final text = _payloadString(message.payload, 'text').trim();
    if (text.isEmpty) {
      throw const FormatException('朗读文本不能为空');
    }

    final part = _payloadString(message.payload, 'part').trim();
    await _playListeningText(
      text: text,
      useChineseVoice: part == 'chinese' || _containsChinese(text),
    );
    return {'playbackState': 'success'};
  }

  Future<Map<String, dynamic>> _handleListeningPrepare(
    BridgeMessage message,
  ) async {
    final text = _payloadString(message.payload, 'text').trim();
    if (text.isEmpty) {
      return {'prepared': false};
    }

    final part = _payloadString(message.payload, 'part').trim();
    final useChineseVoice = part == 'chinese' || _containsChinese(text);
    await _cachedListeningPath(
      text: text,
      voiceType: useChineseVoice
          ? _listeningChineseVoiceType
          : TtsService.defaultVoiceType,
      preferRequestedVoice: useChineseVoice,
      cachePurpose: 'listening_tts',
    );
    return {'prepared': true};
  }

  Future<Map<String, dynamic>> _handleListeningStop(
    BridgeMessage message,
  ) async {
    await _stopListeningPlayback();
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
      debugPrint('[WebShell] pause listening failed: $error');
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
      debugPrint('[WebShell] resume listening failed: $error');
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
    _closeFollowSession();
    _activeListeningArticleId = null;
    await _stopListeningPlayback();
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
    required bool useChineseVoice,
  }) async {
    final token = ++_listeningPlaybackToken;
    _listeningPausedForWord = false;
    await _stopVoicePreview();
    await _disposeListeningPlayer();

    try {
      final path = await _cachedListeningPath(
        text: text,
        voiceType: useChineseVoice
            ? _listeningChineseVoiceType
            : TtsService.defaultVoiceType,
        preferRequestedVoice: useChineseVoice,
        cachePurpose: 'listening_tts',
      );
      if (!_isActiveListeningPlayback(token)) {
        return;
      }

      final player = AudioPlayer();
      _listeningPlayer = player;
      try {
        await _playAudioFileToEnd(
          player: player,
          path: path,
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

  Future<void> _playVoicePreview(String speakerId) async {
    final token = ++_previewPlaybackToken;
    await _stopListeningPlayback();
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

  Future<void> _pushListeningTranslations(
    int articleId,
    List<String> sentences,
  ) async {
    try {
      const batchSize = 4;
      final indexedSentences = <MapEntry<int, String>>[];
      for (var i = 0; i < sentences.length; i++) {
        final sentence = sentences[i].trim();
        if (sentence.isNotEmpty) {
          indexedSentences.add(MapEntry(i, sentence));
        }
      }

      for (var start = 0; start < indexedSentences.length; start += batchSize) {
        final batch = indexedSentences.skip(start).take(batchSize).toList();
        final translations = await Future.wait(
          batch.map((entry) async {
            final translated = await TranslationService.toChinese(
              entry.value,
              articleId: articleId,
              sentenceIndex: entry.key,
              cachePurpose: 'listening_translation',
            );
            return {
              'index': entry.key,
              'chinese': translated.trim(),
            };
          }),
        );
        await _pushEvent('listening.translations', {
          'articleId': articleId,
          'translations': translations,
        });
      }
    } catch (error) {
      debugPrint('[WebShell] listening translations failed: $error');
    }
  }

  Future<void> _playAudioFileToEnd({
    required AudioPlayer player,
    required String path,
    required bool Function() isActive,
  }) async {
    final playbackStarted = Completer<void>();
    final playbackDone = Completer<void>();
    StreamSubscription<PlayerState>? stateSub;
    StreamSubscription<Duration>? positionSub;
    StreamSubscription<PlaybackEvent>? playbackEventSub;
    var playCommandIssued = false;
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

  bool _isActiveListeningPlayback(int token) =>
      token == _listeningPlaybackToken;

  bool _isActiveVoicePreview(int token) => token == _previewPlaybackToken;

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
      debugPrint('[WebShell] suggest article title failed: $error');
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

  Future<String> _englishPracticeContent(
    String content, {
    int? articleId,
    ParsedPracticeInput? parsedInput,
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
      final reply = await PracticeTextService.translateToEnglishForPractice(
        content: trimmed,
        articleId: articleId,
      ).timeout(const Duration(seconds: 12));
      final translated = _normalizeEnglishWordJoiners(reply.text.trim());
      return translated.isEmpty ? trimmed : translated;
    } catch (error) {
      debugPrint('[WebShell] translate article to English failed: $error');
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
      'contentSafety': {
        'rules': await ContentSafetyService.listRules(),
      },
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
