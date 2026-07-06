import 'dart:async';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/config/app_config.dart';
import '../../../core/logging/tomato_logger.dart';
import '../../../data/models/article_model.dart';
import '../../../data/models/article_song_model.dart';
import 'suno_automation_host.dart';
import 'suno_create_batch.dart';
import 'suno_automation_state.dart';
import 'suno_completion_policy.dart';
import 'suno_media_downloader.dart';
import 'suno_utilities.dart';
import 'suno_web_bridge.dart';
import 'suno_web_scripts.dart';

/// Suno WebView automation orchestrator (create, post-create download, detect-download).
class SunoAutomationController {
  SunoAutomationController({
    required SunoAutomationHost host,
    SunoWebBridge? bridge,
    SunoCompletionPolicy? policy,
    SunoMediaDownloader? mediaDownloader,
  })  : _host = host,
        _bridge = bridge ?? const SunoWebBridge(),
        _policy = policy ?? const SunoCompletionPolicy(),
        _mediaDownloader = mediaDownloader ?? SunoMediaDownloader(host: host);

  final SunoAutomationHost _host;
  final SunoWebBridge _bridge;
  final SunoCompletionPolicy _policy;
  final SunoMediaDownloader _mediaDownloader;
  final SunoAutomationState state = SunoAutomationState();
  Timer? _timer;
  InAppWebViewController? webController;

  bool get _useLibraryBroadRecall => _policy.useLibraryBroadRecall(state);

  void attachWebController(InAppWebViewController? controller) {
    webController = controller;
  }

  void onLoadStop(String? url) {
    state.lastLoadStopUrl = url;
    state.lastLoadStopAt = DateTime.now();
  }

  void startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(tick());
    });
    unawaited(tick());
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  void stopAutomation({required bool clearVisible}) {
    final articleId = state.articleId;
    final previousStatus = state.statusKey;
    stopPolling();
    state.resetForStop(clearVisible: clearVisible);
    if (clearVisible) {
      state.articleId = null;
      webController = null;
      _host.requestSetState();
    }
    TomatoLogger.info(
      category: 'suno',
      event: 'automation.stopped',
      articleId: articleId,
      status: state.statusKey,
      data: {
        'previousStatus': previousStatus,
        'clearVisible': clearVisible,
      },
    );
  }

  String overlayStatusText() {
    if (state.errorMessage != null) {
      return 'Suno 自动化失败：${state.errorMessage}';
    }
    if ((state.manualActionMessage ?? '').trim().isNotEmpty) {
      return state.manualActionMessage!;
    }
    switch (state.statusKey) {
      case 'waitingLogin':
        return '等待 Suno 登录';
      case 'waitingConfirm':
        return 'Suno 歌词和自动风格已填写，等待确认创建';
      case 'creating':
        return 'Suno 正在生成歌曲';
      case 'downloading':
        return '正在下载 Suno 歌曲';
      case 'complete':
        return 'Suno 自动化已完成';
      case 'manualAction':
        return '需要手工操作 Suno 页面';
      case 'failed':
        return 'Suno 自动化失败';
      default:
        return 'Suno 自动化';
    }
  }

  bool _isPageSettled(String currentUrl) => SunoUtilities.isPageSettled(
        currentUrl: currentUrl,
        lastLoadStopUrl: state.lastLoadStopUrl,
        lastLoadStopAt: state.lastLoadStopAt,
      );

  void _trustSongUrls(Iterable<Object?> values) => state.trustSongUrls(values);

  List<String> _libraryCandidateSongUrls(
    Map<String, dynamic> result, {
    required bool detectDownloadBroadRecall,
  }) =>
      _policy.libraryCandidateSongUrls(
        result,
        broadRecall: detectDownloadBroadRecall,
        downloadedUrls: state.downloadedSongUrls,
        rejectedUrls: state.rejectedCandidateSongUrls,
        hasLocalVersion: state.hasLocalVersionForSongUrl,
      );

  String? _pendingDownloadTarget(List<String> missingSongUrls) =>
      state.pendingDownloadTarget(missingSongUrls);

  void _absorbCreateBatchFromProbe(Map<String, dynamic> result) {
    if (!state.createSubmitted || state.existingDownloadOnly) {
      return;
    }
    final sidebar = (result['createSidebarSongUrls'] as List?)
            ?.map((value) => value.toString())
            .toList() ??
        const <String>[];
    if (sidebar.isNotEmpty) {
      state.createBatch.absorbCreateSidebarUrls(sidebar);
      TomatoLogger.info(
        category: 'suno',
        event: 'batch.sidebar_detected',
        articleId: state.articleId,
        status: state.statusKey,
        data: {
          ...state.createBatch.snapshot(),
          'generatingCount': result['createSidebarGeneratingCount'],
        },
      );
    }
    final candidates = (result['candidateSongUrls'] as List?)
            ?.map((value) => value.toString())
            .where((value) => !state.rejectedCandidateSongUrls.contains(value))
            .toList() ??
        const <String>[];
    if (SunoUtilities.pageKind((result['currentUrl'] ?? '').toString()) ==
            'create' &&
        candidates.isNotEmpty) {
      state.createBatch.absorbCreateSidebarUrls(candidates);
    }
    TomatoLogger.debug(
      category: 'suno',
      event: 'batch.snapshot',
      articleId: state.articleId,
      status: state.statusKey,
      data: state.createBatch.snapshot(),
    );
  }

  Future<void> _tryComplete({
    required String currentUrl,
    required String reason,
  }) async {
    state.mightHaveMoreLibraryRows =
        !_isPageSettled(currentUrl) || state.hasOpenLibraryCandidates;
    if (!_policy.canComplete(state)) {
      final block = _policy.blockReason(state);
      TomatoLogger.info(
        category: 'suno',
        event: 'complete.blocked',
        articleId: state.articleId,
        status: state.statusKey,
        data: {
          'reason': reason,
          ..._policy.blockedSummary(state, block),
        },
      );
      return;
    }
    TomatoLogger.info(
      category: 'suno',
      event: 'complete.allowed',
      articleId: state.articleId,
      status: state.statusKey,
      data: {
        'reason': reason,
        ..._policy.allowedSummary(state),
      },
    );
    await saveMetadata();
    await setStatus('complete', null);
    stopPolling();
  }

  Future<void> setStatus(String status, String? message) async {
    final previous = state.statusKey;
    state.statusKey = status;
    state.manualActionMessage = message;
    state.errorMessage = null;
    TomatoLogger.info(
      category: 'suno',
      event: 'status.changed',
      articleId: state.articleId,
      status: status,
      data: {
        'previousStatus': previous,
        'message': message,
        'songUrl': state.songUrl,
        'pendingSongUrl': state.pendingDownloadSongUrl,
        'versions': state.versions.length,
      },
    );
    _host.requestSetState();
    final articleId = state.articleId;
    if (articleId != null) {
      await _host.pushSongState(articleId);
    }
  }

  Future<void> failAutomation(String message) async {
    final previous = state.statusKey;
    state.statusKey = 'failed';
    state.errorMessage = message;
    state.manualActionMessage = null;
    stopPolling();
    TomatoLogger.error(
      category: 'suno',
      event: 'automation.failed',
      articleId: state.articleId,
      status: 'failed',
      data: {'previousStatus': previous, 'message': message},
    );
    _host.requestSetState();
    final articleId = state.articleId;
    if (articleId != null) {
      await _host.pushSongState(articleId);
    }
  }

  Future<void> saveMetadata({String? manualActionMessage}) async {
    final articleId = state.articleId;
    if (articleId == null) {
      return;
    }
    final article = await _host.loadSongArticle(articleId);
    await _host.saveSunoMetadataForVersions(
      article: article,
      versions: state.versions
          .map(
            (version) => version.copyWith(
              source: AppConfig.songProviderSuno,
              songUrl: SunoUtilities.canonicalSongUrl(version.songUrl),
            ),
          )
          .toList(growable: false),
      manualActionMessage: manualActionMessage,
      downloadCompleteOverride: state.currentDownloadsComplete(),
      stylePromptOverride:
          state.stylePrompt.trim().isEmpty ? null : state.stylePrompt.trim(),
      detectedSongUrlsOverride: SunoUtilities.mergeSongUrls([
        state.detectedSongUrls,
        state.versions.map((version) => version.songUrl),
      ]),
    );
  }

  Future<void> tick() async {
    if (state.automationBusy || state.articleId == null) {
      return;
    }
    final controller = webController;
    if (controller == null) {
      return;
    }
    state.automationBusy = true;
    try {
      final inspect =
          await _bridge.evaluateJson(controller, SunoWebScripts.inspectScript);
      final currentUrl = (inspect['currentUrl'] ??
              (await controller.getUrl())?.toString() ??
              '')
          .toString();
      final loginFlow = inspect['loginFlow'] == true ||
          SunoUtilities.isLoginFlowUrl(currentUrl);
      final loggedIn = inspect['loggedIn'] == true && !loginFlow;
      state.creditsRemaining = (inspect['creditsRemaining'] as num?)?.toInt();
      if (!loggedIn) {
        if (state.suppressLoginProbe) {
          await setStatus(
            state.statusKey == 'creating' ? 'creating' : 'downloading',
            'Suno 页面正在跳转，Tomato 会继续等待当前歌曲流程...',
          );
          return;
        }
        await setStatus(
          'waitingLogin',
          'Suno 页面已打开，请先在页面中自行登录。',
        );
        return;
      }
      if (state.existingDownloadOnly &&
          (state.statusKey == 'manualAction' ||
              state.statusKey == 'failed' ||
              state.statusKey == 'complete')) {
        return;
      }
      if (state.completedStandby) {
        final currentUrl = (await controller.getUrl())?.toString() ?? '';
        var styleChanged = false;
        if (SunoUtilities.pageKind(currentUrl) == 'create') {
          if (!state.completedStandbyFilled) {
            final fill = await _bridge.evaluateJson(
              controller,
              SunoWebScripts.fillScript(
                lyrics: state.lyrics,
                stylePrompt: state.stylePrompt,
                ignoredStylePrompt: state.ignoredStylePrompt,
                allowMagicClick: false,
                magicAlreadyRequested: true,
              ),
            );
            final filledStyle = (fill['stylePrompt'] ?? '').toString().trim();
            if (filledStyle.isNotEmpty) {
              state.stylePrompt = filledStyle;
            }
            if (fill['ok'] == true) {
              state.completedStandbyFilled = true;
              await setStatus(
                'complete',
                '这首歌词的 Suno 完整版已完成生成和下载。Tomato 已填好歌词，等待你自行点击 Create 生成新版本。',
              );
            } else {
              await setStatus(
                'manualAction',
                (fill['message'] ?? '').toString().trim().isEmpty
                    ? 'Tomato 正在填写 Suno Create 表单，填好后会停止自动操作并等待你自行改风格或点击 Create。'
                    : (fill['message'] ?? '').toString(),
              );
            }
            return;
          }
          final probe = await _bridge.evaluateJson(
            controller,
            SunoWebScripts.fillScript(
              lyrics: state.lyrics,
              stylePrompt: state.stylePrompt,
              ignoredStylePrompt: state.ignoredStylePrompt,
              allowMagicClick: false,
              magicAlreadyRequested: state.styleMagicRequestedAt != null,
              readOnly: true,
            ),
          );
          final currentStyle = (probe['stylePrompt'] ?? '').toString().trim();
          if (currentStyle.isNotEmpty &&
              currentStyle != state.stylePrompt.trim()) {
            state.stylePrompt = currentStyle;
            state.detectedSongUrls.clear();
            state.rememberDownloadedSongUrls();
            styleChanged = true;
            await setStatus(
              'manualAction',
              '检测到 Suno 风格已更新。请在 Suno 页面自行点击 Create；生成完成后 Tomato 会自动下载全部完整版。',
            );
          }
        }
        final result = await _bridge.evaluateJson(
          controller,
          SunoWebScripts.completionScript(
            expectedStylePrompt: state.stylePrompt,
            expectedLyrics: state.lyrics,
            requireExpectedMatch: true,
            trustedSongUrls: state.trustedSongUrlsList(),
          ),
        );
        final resultSongUrls = (result['songUrls'] as List?)
                ?.map((value) => value.toString().trim())
                .where((value) => value.isNotEmpty)
                .toList() ??
            <String>[];
        _trustSongUrls(resultSongUrls);
        final detectedSongUrls = SunoUtilities.mergeSongUrls([
          resultSongUrls,
          state.detectedSongUrls,
        ]);
        final newUrls = detectedSongUrls
            .where((value) =>
                !state.detectedSongUrls.contains(value) &&
                !state.downloadedSongUrls.contains(value) &&
                !state.hasLocalVersionForSongUrl(value))
            .toList();
        if (newUrls.isNotEmpty) {
          state.detectedSongUrls
            ..clear()
            ..addAll(detectedSongUrls);
          state.syncDownloadedIntoDetected();
          state.songUrl = newUrls.first;
          state.pendingDownloadSongUrl = newUrls.first;
          state.createSubmitted = true;
          state.existingDownloadOnly = false;
          state.existingDownloadLibraryTried = false;
          state.completedStandby = false;
          await setStatus(
            'downloading',
            '检测到新的 Suno 完整歌曲，正在下载全部版本...',
          );
        } else {
          if (!styleChanged && state.currentDownloadsComplete()) {
            await setStatus(
              'complete',
              '这首歌词的 Suno 完整版已完成生成和下载。Tomato 已停在 Create 页面并填好歌词，等待你自行点击 Create 生成新版本。',
            );
          } else {
            await setStatus(
              'manualAction',
              '请在 Suno 页面自行点击 Create；生成完成后 Tomato 会自动下载全部完整版。',
            );
          }
        }
        return;
      }
      if (!state.existingDownloadOnly &&
          !state.createSubmitted &&
          (state.statusKey == 'waitingLogin' ||
              state.statusKey == 'manualAction' ||
              state.statusKey == 'failed')) {
        final currentUrl = (await controller.getUrl())?.toString() ?? '';
        if (SunoUtilities.isLoginFlowUrl(currentUrl)) {
          await setStatus(
            'waitingLogin',
            'Suno 登录流程进行中，请先在页面中完成登录。',
          );
          return;
        }
        if (SunoUtilities.pageKind(currentUrl) != 'create') {
          state.markNavigating();
          await _bridge.loadUrl(controller, 'https://suno.com/create');
          await setStatus(
            'manualAction',
            'Suno 当前不在 Create 页面，Tomato 正在重新打开 Create 后再填写。',
          );
          return;
        }
        final allowMagicClick = state.styleMagicRequestedAt == null;
        final fill = await _bridge.evaluateJson(
          controller,
          SunoWebScripts.fillScript(
            lyrics: state.lyrics,
            stylePrompt: state.stylePrompt,
            ignoredStylePrompt: state.ignoredStylePrompt,
            allowMagicClick: allowMagicClick,
            magicAlreadyRequested: state.styleMagicRequestedAt != null,
          ),
        );
        TomatoLogger.info(
          category: 'suno',
          event: 'create.fill_probe',
          articleId: state.articleId,
          status: state.statusKey,
          data: {
            'ok': fill['ok'],
            'retry': fill['retry'],
            'missing': fill['missing'],
            'fieldCount': fill['fieldCount'],
            'magicClicked': fill['magicClicked'],
            'styleLength': (fill['stylePrompt'] ?? '').toString().length,
            'magicTarget': fill['magicTarget'],
            'magicTrigger': fill['magicTrigger'],
            'styleExpandTarget': fill['styleExpandTarget'],
            'stylePlaceholder': fill['stylePlaceholder'],
            'lyricsField': fill['lyricsField'],
            'styleField': fill['styleField'],
          },
        );
        final ignoredStylePrompt =
            (fill['ignoredStylePrompt'] ?? '').toString().trim();
        if (ignoredStylePrompt.isNotEmpty && state.stylePrompt.trim().isEmpty) {
          state.ignoredStylePrompt = ignoredStylePrompt;
        }
        final generatedStyle = (fill['stylePrompt'] ?? '').toString().trim();
        if (generatedStyle.isNotEmpty) {
          state.stylePrompt = generatedStyle;
          state.ignoredStylePrompt = '';
        }
        if (fill['magicClicked'] == true) {
          state.styleMagicRequestedAt = DateTime.now();
          await setStatus(
            'manualAction',
            'Tomato 已点击 Suno 自动风格魔法棒，正在等待 Suno 根据歌词生成 Styles。',
          );
          return;
        }
        if (fill['ok'] == true) {
          await setStatus(
            'waitingConfirm',
            'Suno 歌词和自动风格已填写，请确认消耗 Suno credits 后创建。',
          );
          return;
        }
        if (fill['retry'] == true) {
          await setStatus(
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
        await setStatus(
          'manualAction',
          diagnostics.isEmpty
              ? 'Tomato 没能准确找到 Suno Advanced 歌词或风格输入框，请在页面中手工填写后点击“继续检测”。'
              : 'Tomato 没能准确找到 Suno Advanced 歌词或风格输入框（$diagnostics）。请在页面中手工填写后点击“继续检测”。',
        );
        return;
      }
      if (state.createSubmitted) {
        final result = await _bridge.evaluateJson(
          controller,
          SunoWebScripts.completionScript(
            expectedStylePrompt: state.stylePrompt,
            expectedLyrics: state.lyrics,
            requireExpectedMatch: true,
            trustedSongUrls: state.trustedSongUrlsList(),
          ),
        );
        TomatoLogger.info(
          category: 'suno',
          event: 'completion.probe',
          articleId: state.articleId,
          status: state.statusKey,
          data: {
            'ok': result['ok'],
            'songUrl': result['songUrl'],
            'songUrlCount': (result['songUrls'] as List?)?.length ?? 0,
            'candidateSongUrlCount':
                (result['candidateSongUrls'] as List?)?.length ?? 0,
            'libraryCandidateSongUrlCount': _libraryCandidateSongUrls(
              result,
              detectDownloadBroadRecall: _useLibraryBroadRecall,
            ).length,
            'libraryBroadRecall': _useLibraryBroadRecall,
            'currentPageExpectedScore': result['currentPageExpectedScore'],
            'currentPageLyricsExactMatch':
                result['currentPageLyricsExactMatch'],
            'currentPageGenerating': result['currentPageGenerating'],
          },
        );

        var songUrl = SunoUtilities.canonicalSongUrl(result['songUrl']) ?? '';
        final currentUrl = (await controller.getUrl())?.toString() ?? '';
        _absorbCreateBatchFromProbe(result);
        state.hasOpenLibraryCandidates = _libraryCandidateSongUrls(
          result,
          detectDownloadBroadRecall: _useLibraryBroadRecall,
        ).isNotEmpty;
        state.libraryScanSettled = _isPageSettled(currentUrl) &&
            (SunoUtilities.pageKind(currentUrl) == 'library' ||
                SunoUtilities.pageKind(currentUrl) == 'create');

        final currentPageKind = SunoUtilities.pageKind(currentUrl);
        final knownSongUrl =
            SunoUtilities.canonicalSongUrl(state.songUrl) ?? '';
        final currentPageLyricsExactMatch =
            result['currentPageLyricsExactMatch'] == true;
        final currentPageGenerating = result['currentPageGenerating'] == true;
        final currentUrlMatchesKnown =
            knownSongUrl.isNotEmpty && currentUrl.startsWith(knownSongUrl);
        if (state.existingDownloadOnly &&
            knownSongUrl.isNotEmpty &&
            currentPageKind != 'library' &&
            currentUrlMatchesKnown &&
            currentPageLyricsExactMatch) {
          songUrl = knownSongUrl;
        } else if (songUrl.isEmpty &&
            knownSongUrl.isNotEmpty &&
            currentPageKind != 'library' &&
            currentUrlMatchesKnown &&
            currentPageLyricsExactMatch) {
          songUrl = knownSongUrl;
        }
        final libraryCandidateSongUrls = _libraryCandidateSongUrls(
          result,
          detectDownloadBroadRecall: _useLibraryBroadRecall,
        );
        if (_useLibraryBroadRecall &&
            currentPageKind == 'library' &&
            libraryCandidateSongUrls.isNotEmpty) {
          final candidateUrl = libraryCandidateSongUrls.first;
          state.pendingDownloadSongUrl = candidateUrl;
          state.songUrl = candidateUrl;
          state.markNavigating();
          await _bridge.loadUrl(controller, candidateUrl);
          TomatoLogger.info(
            category: 'suno',
            event: 'library.candidate_open',
            articleId: state.articleId,
            status: state.statusKey,
            data: {
              'broadRecall': _useLibraryBroadRecall,
              'candidateUrl': candidateUrl,
              'candidateCount': libraryCandidateSongUrls.length,
            },
          );
          await setStatus(
            'downloading',
            '正在打开 Suno 候选歌曲详情页核对歌词后下载...',
          );
          return;
        }
        if (songUrl.isEmpty) {
          final pendingCandidate =
              SunoUtilities.canonicalSongUrl(state.pendingDownloadSongUrl) ??
                  '';
          if (currentPageKind == 'song' &&
              pendingCandidate.isNotEmpty &&
              currentUrl.startsWith(pendingCandidate) &&
              !_isPageSettled(currentUrl)) {
            await setStatus(
              'downloading',
              '正在等待 Suno 候选歌曲详情页加载完成后核对歌词...',
            );
            return;
          }
          if (currentPageKind == 'song' &&
              pendingCandidate.isNotEmpty &&
              currentUrl.startsWith(pendingCandidate) &&
              _isPageSettled(currentUrl) &&
              !currentPageLyricsExactMatch) {
            if (state.createSubmitted &&
                !state.existingDownloadOnly &&
                !state.hasNewVersionsSinceCreate) {
              await setStatus(
                currentPageGenerating || state.statusKey == 'creating'
                    ? 'creating'
                    : 'downloading',
                currentPageGenerating
                    ? '正在歌曲详情页等待 Suno 生成完成并核对歌词...'
                    : '正在歌曲详情页等待歌词匹配后下载...',
              );
              return;
            }
            state.rejectedCandidateSongUrls.add(pendingCandidate);
            state.pendingDownloadSongUrl = null;
            if (_useLibraryBroadRecall) {
              await _navigateToLibraryForMoreCandidates(
                controller,
                message: '这个 Suno 歌曲详情页歌词与当前文章不匹配，正在回到 Library 核对其它候选...',
              );
            } else {
              await setStatus(
                'manualAction',
                'Suno 候选歌曲详情页歌词与当前文章不匹配，已停止自动下载以避免保存错歌。',
              );
              _timer?.cancel();
            }
            return;
          }
          final rawCandidateSongUrls = SunoUtilities.mergeSongUrls([
            ((result['candidateSongUrls'] as List?) ?? const [])
                .map((value) => value.toString()),
          ]);
          final candidateSongUrls = rawCandidateSongUrls
              .where((value) =>
                  !state.downloadedSongUrls.contains(value) &&
                  !state.hasLocalVersionForSongUrl(value) &&
                  !state.rejectedCandidateSongUrls.contains(value))
              .toList();
          final canOpenCandidate = currentPageKind == 'library' ||
              (!state.existingDownloadOnly && currentPageKind == 'create');
          final openFromLibrary = _useLibraryBroadRecall &&
              currentPageKind == 'library' &&
              libraryCandidateSongUrls.isNotEmpty;
          final nextCandidateUrls =
              openFromLibrary ? libraryCandidateSongUrls : candidateSongUrls;
          if (nextCandidateUrls.isNotEmpty && canOpenCandidate) {
            final candidateUrl = nextCandidateUrls.first;
            state.pendingDownloadSongUrl = candidateUrl;
            _trustSongUrls([candidateUrl]);
            state.markNavigating();
            await _bridge.loadUrl(controller, candidateUrl);
            await setStatus(
              'downloading',
              '正在打开 Suno 候选歌曲详情页核对歌词后下载...',
            );
            return;
          }
          if ((currentPageKind == 'library' || currentPageKind == 'create') &&
              rawCandidateSongUrls.isNotEmpty &&
              candidateSongUrls.isEmpty &&
              (!_useLibraryBroadRecall || libraryCandidateSongUrls.isEmpty) &&
              (state.existingDownloadOnly
                  ? state.versions.isNotEmpty
                  : state.hasNewVersionsSinceCreate)) {
            // Suno Library rows hydrate lazily. Do not mark an article complete
            // just because the first visible row is an already-downloaded song:
            // same lyrics with a different style is still another valid version.
            if (!_isPageSettled(currentUrl)) {
              await setStatus(
                'downloading',
                '正在等待 Suno 歌曲列表加载完成，继续检查同歌词的其它风格版本...',
              );
              return;
            }
            await _tryComplete(
                currentUrl: currentUrl, reason: 'library_candidates_exhausted');
            return;
          }
          if (!state.existingDownloadOnly &&
              (currentPageKind == 'library' || currentPageKind == 'create') &&
              rawCandidateSongUrls.isEmpty &&
              (!_useLibraryBroadRecall || libraryCandidateSongUrls.isEmpty) &&
              state.hasNewVersionsSinceCreate &&
              _isPageSettled(currentUrl)) {
            await _tryComplete(
                currentUrl: currentUrl, reason: 'library_candidates_exhausted');
            return;
          }
        }
        if (songUrl.isNotEmpty) {
          state.songUrl = songUrl;
          if (state.existingDownloadOnly &&
              currentPageKind == 'song' &&
              !_isPageSettled(currentUrl)) {
            await setStatus(
              'downloading',
              '正在等待 Suno 歌曲详情页加载完成后检测完整歌曲列表...',
            );
            return;
          }
          if (state.existingDownloadOnly &&
              songUrl.startsWith('https://') &&
              !currentUrl.startsWith(songUrl)) {
            final alreadyTriedSongDetail =
                state.pendingDownloadSongUrl == songUrl;
            state.pendingDownloadSongUrl = songUrl;
            if (!alreadyTriedSongDetail &&
                !SunoUtilities.isProfileUrl(currentUrl)) {
              state.markNavigating();
              await _bridge.loadUrl(controller, songUrl);
              await setStatus(
                'downloading',
                '正在打开 Suno 歌曲详情页准备下载...',
              );
              return;
            }
            if (alreadyTriedSongDetail &&
                currentPageKind != 'library' &&
                currentPageKind != 'profile' &&
                !state.existingDownloadLibraryTried) {
              state.existingDownloadLibraryTried = true;
              state.markNavigating();
              await _bridge.loadUrl(controller, 'https://suno.com/me');
              await setStatus(
                'downloading',
                'Suno 页面跳到了非歌曲页，正在打开 Library 查找对应完整歌曲...',
              );
              return;
            }
            if (SunoUtilities.isProfileUrl(currentUrl)) {
              await setStatus(
                'downloading',
                'Suno 打开歌曲链接后跳到了个人主页，Tomato 将只在当前页面查找下载入口，不再反复刷新。',
              );
            }
          }
          if (state.existingDownloadOnly &&
              songUrl.startsWith('https://') &&
              !currentUrl.startsWith(songUrl) &&
              !SunoUtilities.isProfileUrl(currentUrl) &&
              state.pendingDownloadSongUrl != songUrl) {
            return;
          }
          final resultSongUrls = (result['songUrls'] as List?)
                  ?.map((value) => value.toString().trim())
                  .where((value) => value.isNotEmpty)
                  .toList() ??
              <String>[];
          final currentSongUrls = SunoUtilities.mergeSongUrls([
            resultSongUrls,
            state.detectedSongUrls,
            [songUrl],
          ]);
          final resultDetectedSongUrls =
              SunoUtilities.mergeSongUrls([resultSongUrls]);
          if (currentSongUrls.isNotEmpty) {
            state.detectedSongUrls.addAll(currentSongUrls);
            _trustSongUrls(resultDetectedSongUrls);
            state.syncDownloadedIntoDetected();
          }
          final completedUrls = currentSongUrls
              .where((value) =>
                  !state.downloadedSongUrls.contains(value) &&
                  !state.hasLocalVersionForSongUrl(value))
              .toList();
          if (completedUrls.isEmpty && state.versions.isNotEmpty) {
            final undownloadedSidebarSongUrls = SunoUtilities.mergeSongUrls([
              ((result['candidateSongUrls'] as List?) ?? const [])
                  .map((value) => value.toString()),
            ])
                .where((value) =>
                    !state.downloadedSongUrls.contains(value) &&
                    !state.hasLocalVersionForSongUrl(value) &&
                    !state.rejectedCandidateSongUrls.contains(value))
                .toList();
            if (!state.existingDownloadOnly &&
                state.hasNewVersionsSinceCreate &&
                currentPageKind == 'song') {
              await _navigateToLibraryForMoreCandidates(
                controller,
                message: '这个候选歌曲已保存，正在回到 Library 扫描后续候选...',
              );
              return;
            }
            if (state.createSubmitted &&
                !state.existingDownloadOnly &&
                state.hasNewVersionsSinceCreate &&
                currentPageKind == 'create' &&
                undownloadedSidebarSongUrls.isNotEmpty) {
              final candidateUrl = undownloadedSidebarSongUrls.first;
              state.pendingDownloadSongUrl = candidateUrl;
              state.songUrl = candidateUrl;
              _trustSongUrls([candidateUrl]);
              state.markNavigating();
              await _bridge.loadUrl(controller, candidateUrl);
              await setStatus(
                'downloading',
                'Create 页还有未下载的完整歌曲，正在打开下一首详情页核对歌词...',
              );
              return;
            }
            if (state.createSubmitted &&
                !state.existingDownloadOnly &&
                state.hasNewVersionsSinceCreate &&
                currentPageKind != 'library') {
              await _navigateToLibraryForMoreCandidates(
                controller,
                message: '已保存本次 Create 匹配歌曲，正在打开 Library 扫描同批其它版本...',
              );
              return;
            }
            if (_useLibraryBroadRecall &&
                currentPageKind == 'library' &&
                libraryCandidateSongUrls.isNotEmpty) {
              await setStatus(
                'downloading',
                '当前歌曲已保存，正在 Library 继续打开其它候选歌曲详情页...',
              );
              return;
            }
            if (_useLibraryBroadRecall &&
                currentPageKind == 'library' &&
                !_isPageSettled(currentUrl)) {
              await setStatus(
                'downloading',
                '正在等待 Suno Library 歌曲列表加载完成，继续检查同歌词的其它版本...',
              );
              return;
            }
            if (state.existingDownloadOnly &&
                !state.existingDownloadLibraryTried &&
                currentPageKind != 'library') {
              state.existingDownloadLibraryTried = true;
              state.pendingDownloadSongUrl = songUrl;
              state.markNavigating();
              await _bridge.loadUrl(controller, 'https://suno.com/me');
              await setStatus(
                'downloading',
                '歌曲详情页只看到已下载版本，正在打开 Suno Library 检测同一歌词的其它完整歌曲...',
              );
              return;
            }
            if (state.existingDownloadOnly && resultDetectedSongUrls.isEmpty) {
              await setStatus(
                'downloading',
                '正在等待 Suno 页面露出同一歌词的完整歌曲列表...',
              );
              return;
            }
            await _tryComplete(
                currentUrl: currentUrl, reason: 'library_candidates_exhausted');
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
          final directMediaDownloaded = await _downloadDirectMediaUrls(
            articleId: state.articleId!,
            songUrls: completedUrls,
            mediaBySongUrl: mediaBySongUrl,
            fallbackMediaUrl: (result['mediaUrl'] ?? '').toString(),
          );
          if (directMediaDownloaded > 0) {
            final remainingUrls = currentSongUrls
                .where((value) =>
                    !state.downloadedSongUrls.contains(value) &&
                    !state.hasLocalVersionForSongUrl(value))
                .toList();
            if (remainingUrls.isEmpty) {
              final shouldScanLibraryForMore =
                  _useLibraryBroadRecall && currentPageKind != 'library';
              if (shouldScanLibraryForMore ||
                  (!state.existingDownloadOnly && currentPageKind == 'song') ||
                  (state.existingDownloadOnly && currentPageKind == 'song')) {
                await _navigateToLibraryForMoreCandidates(
                  controller,
                  message: state.createSubmitted && !state.existingDownloadOnly
                      ? '已直接保存 $directMediaDownloaded 个匹配歌曲，正在回到 Library 扫描后续候选...'
                      : '已直接保存 $directMediaDownloaded 个 Suno 完整版本，正在回到 Library 继续检测其它候选...',
                );
                return;
              }
              if (_useLibraryBroadRecall &&
                  currentPageKind == 'library' &&
                  libraryCandidateSongUrls.isNotEmpty) {
                await setStatus(
                  'downloading',
                  '已直接保存 $directMediaDownloaded 个 Suno 完整版本，正在 Library 继续打开其它候选...',
                );
                return;
              }
              if (_useLibraryBroadRecall &&
                  currentPageKind == 'library' &&
                  !_isPageSettled(currentUrl)) {
                await setStatus(
                  'downloading',
                  '已直接保存 $directMediaDownloaded 个 Suno 完整版本，正在等待 Library 加载后继续扫描...',
                );
                return;
              }
              await _tryComplete(
                currentUrl: currentUrl,
                reason: 'direct_media_remaining_empty',
              );
              return;
            }
            await setStatus(
              'downloading',
              '已直接保存 $directMediaDownloaded 个 Suno 完整版本，正在检查其它版本...',
            );
            return;
          }
          final unresolvedDirectUrls = currentSongUrls
              .where((value) =>
                  !state.downloadedSongUrls.contains(value) &&
                  !state.hasLocalVersionForSongUrl(value))
              .toList(growable: false);
          if (state.isAwaitingMenuDownload() &&
              unresolvedDirectUrls.isNotEmpty &&
              SunoUtilities.pageKind(currentUrl) == 'song') {
            await setStatus(
              'downloading',
              '已点击 Suno 下载菜单，正在等待 WebView 接收音频文件...',
            );
            return;
          }
          if (state.existingDownloadOnly &&
              unresolvedDirectUrls.isNotEmpty &&
              SunoUtilities.pageKind(currentUrl) == 'song' &&
              !state.isAwaitingMenuDownload()) {
            // Pitfall: clicking Suno's native "Download Anyway" confirmation
            // in Windows WebView can crash flutter_inappwebview_windows_plugin.
            // Keep this path on Dart-side media downloads or stop safely.
            await saveMetadata(
              manualActionMessage:
                  'Suno 详情页歌词已匹配，但 Tomato 没能提取可直接保存的音频地址。Windows WebView 下载确认会导致程序崩溃，已停止自动点击以保护数据。',
            );
            await setStatus(
              'manualAction',
              'Suno 详情页歌词已匹配，但 Tomato 没能提取可直接保存的音频地址。请先不要手动点击 Download Anyway；我需要继续适配这个页面的媒体地址。',
            );
            _timer?.cancel();
            return;
          }
          final download = await _bridge.evaluateJson(
            controller,
            SunoWebScripts.downloadScript(
              downloadedSongUrls: state.downloadedSongUrls.toList(),
              pendingSongUrl: _pendingDownloadTarget(completedUrls),
              allowedSongUrls: completedUrls,
              expectedStylePrompt: state.stylePrompt,
              expectedLyrics: state.lyrics,
              requireExpectedMatch: true,
              trustedSongUrls: state.trustedSongUrlsList(completedUrls),
            ),
          );
          TomatoLogger.info(
            category: 'suno',
            event: 'download.probe',
            articleId: state.articleId,
            status: state.statusKey,
            data: _downloadProbeLogData(download),
          );
          final pendingSongUrl =
              SunoUtilities.canonicalSongUrl(download['songUrl']) ?? '';
          final pendingTitle = (download['title'] ?? '').toString().trim();
          if (pendingSongUrl.isNotEmpty &&
              !SunoUtilities.isSyntheticSongKey(pendingSongUrl)) {
            state.pendingDownloadSongUrl = pendingSongUrl;
          }
          if (pendingTitle.isNotEmpty) {
            state.pendingDownloadTitle = pendingTitle;
          }
          if (download['ok'] == true || download['retry'] == true) {
            final downloadStage = (download['stage'] ?? '').toString();
            if (download['ok'] == true && downloadStage == 'download') {
              state.menuDownloadClickedAt = DateTime.now();
            }
            if (download['retry'] == true && downloadStage == 'menu') {
              state.existingDownloadMenuRetries += 1;
              if (state.existingDownloadOnly &&
                  state.existingDownloadMenuRetries >= 3 &&
                  !state.existingDownloadLibraryTried &&
                  SunoUtilities.pageKind(currentUrl) != 'library') {
                state.existingDownloadLibraryTried = true;
                state.pendingDownloadSongUrl = songUrl;
                state.markNavigating();
                await _bridge.loadUrl(controller, 'https://suno.com/me');
                await setStatus(
                  'downloading',
                  '歌曲详情页菜单没有露出下载入口，正在打开 Suno Library 查找对应完整歌曲...',
                );
                return;
              }
              if (state.existingDownloadOnly &&
                  state.existingDownloadMenuRetries >= 3 &&
                  SunoUtilities.pageKind(currentUrl) == 'library') {
                await saveMetadata(
                  manualActionMessage:
                      'Suno 已检测到缺失完整歌曲，但 Library 菜单没有露出 Download/Audio 项。',
                );
                await setStatus(
                  'manualAction',
                  'Suno 已检测到缺失完整歌曲，但 Library 菜单没有露出 Download/Audio 项。请在 Suno 页面手动下载音频，Tomato 会保存已能自动获取的版本。',
                );
                _timer?.cancel();
                return;
              }
            } else if (download['ok'] == true) {
              state.existingDownloadMenuRetries = 0;
            }
            await saveMetadata(
              manualActionMessage:
                  'Suno 已生成 ${currentSongUrls.length} 个完整版本，Tomato 正在下载未保存的版本。',
            );
            await setStatus(
              'downloading',
              '正在下载 Suno 缺失歌曲版本 1 / ${completedUrls.length}...',
            );
            return;
          }
          if (state.existingDownloadOnly &&
              !state.existingDownloadLibraryTried &&
              SunoUtilities.pageKind(currentUrl) != 'library') {
            state.existingDownloadLibraryTried = true;
            state.pendingDownloadSongUrl = songUrl;
            state.markNavigating();
            await _bridge.loadUrl(controller, 'https://suno.com/me');
            await setStatus(
              'downloading',
              '歌曲详情页没有露出下载入口，正在打开 Suno Library 查找对应完整歌曲...',
            );
            return;
          }
          if (state.createSubmitted && currentPageKind == 'song') {
            await setStatus(
              'downloading',
              'Suno 歌曲还在生成或音频未就绪，Tomato 会继续等待...',
            );
            return;
          }
          await saveMetadata(
            manualActionMessage: 'Suno 已生成完整歌曲，但 Tomato 没能找到可自动点击的音频下载入口。',
          );
          await setStatus(
            'manualAction',
            (download['message'] ?? '').toString().trim().isEmpty
                ? 'Suno 已生成完整歌曲，但 Tomato 没能找到可自动点击的音频下载入口。请在页面中点击下载音频。'
                : (download['message'] ?? '').toString(),
          );
          _timer?.cancel();
        } else if (state.existingDownloadOnly) {
          final startedAt = state.existingDownloadStartedAt;
          if (startedAt == null ||
              DateTime.now().difference(startedAt) <
                  const Duration(seconds: 75)) {
            await setStatus(
              'downloading',
              '正在等待 Suno 歌曲列表加载完成，或打开候选详情页核对歌词...',
            );
            return;
          }
          await setStatus(
            'manualAction',
            'Suno 页面中没有找到与当前歌词匹配的完整歌曲，已停止自动下载以避免保存错歌。',
          );
          _timer?.cancel();
        } else {
          await setStatus('creating', 'Suno 正在生成歌曲...');
        }
      }
    } catch (error) {
      if (_isTransientWebViewError(error)) {
        await setStatus(
          'manualAction',
          'Suno 页面控件还在初始化或刚刚重建，Tomato 会继续检测；也可以稍后点击“继续检测”。',
        );
        return;
      }
      await failAutomation(_host.displayError(error));
    } finally {
      state.automationBusy = false;
      if (_host.isMounted) {
        _host.requestSetState();
      }
    }
  }

  Future<void> _navigateToLibraryForMoreCandidates(
    InAppWebViewController controller, {
    required String message,
    bool resetLibraryTried = true,
  }) async {
    if (resetLibraryTried) {
      state.existingDownloadLibraryTried = false;
    }
    state.pendingDownloadSongUrl = null;
    state.markNavigating();
    await _bridge.loadUrl(controller, 'https://suno.com/me');
    await setStatus('downloading', message);
  }

  Future<int> _downloadDirectMediaUrls({
    required int articleId,
    required Iterable<String> songUrls,
    required Map<String, String> mediaBySongUrl,
    String? fallbackMediaUrl,
  }) =>
      _mediaDownloader.downloadDirectMediaUrls(
        state: state,
        articleId: articleId,
        songUrls: songUrls,
        mediaBySongUrl: mediaBySongUrl,
        fallbackMediaUrl: fallbackMediaUrl,
        onSaved: saveMetadata,
        safeFilename: _safeFilename,
        uniqueTargetFile: _uniqueTargetFile,
      );

  Future<File> _uniqueTargetFile(Directory directory, String filename) async {
    final base = filename.trim();
    var candidate = File('${directory.path}${Platform.pathSeparator}$base');
    var suffix = 1;
    while (await candidate.exists()) {
      final dot = base.lastIndexOf('.');
      final stem = dot > 0 ? base.substring(0, dot) : base;
      final ext = dot > 0 ? base.substring(dot) : '';
      candidate = File(
        '${directory.path}${Platform.pathSeparator}${stem}_$suffix$ext',
      );
      suffix += 1;
    }
    return candidate;
  }

  String _safeFilename(String? suggested) {
    final raw = (suggested ?? 'suno_download.mp3').trim();
    final cleaned = raw.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    return cleaned.isEmpty ? 'suno_download.mp3' : cleaned;
  }

  Map<String, Object?> _downloadProbeLogData(Map<String, dynamic> download) {
    final candidates = ((download['candidates'] as List?) ?? const [])
        .whereType<Map>()
        .map(
          (item) => {
            'label': item['label'],
            'stage': item['stage'],
            'score': item['score'],
          },
        )
        .take(6)
        .toList(growable: false);
    return {
      'ok': download['ok'],
      'retry': download['retry'],
      'stage': download['stage'],
      'songUrl': download['songUrl'],
      'title': download['title'],
      'currentPageExpectedScore': download['currentPageExpectedScore'],
      'currentPageLyricsExactMatch': download['currentPageLyricsExactMatch'],
      'candidateCount': (download['candidates'] as List?)?.length ?? 0,
      'candidates': candidates,
    };
  }

  bool _isTransientWebViewError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('webview') ||
        text.contains('channel') ||
        text.contains('disposed');
  }

  Future<Map<String, dynamic>> startAutomation({
    required Article article,
    required String stylePrompt,
    required String lyrics,
    bool completedStandby = false,
    required Future<List<SunoCachedSongGroup>> Function(Article) loadGroups,
    required Future<ArticleSongState?> Function(Article) loadCachedState,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      throw const FormatException('文章尚未保存，不能生成歌曲');
    }
    if (lyrics.trim().isEmpty) {
      throw const FormatException('文章没有可用于 Suno 的英文歌词');
    }
    stopAutomation(clearVisible: false);
    state.articleId = articleId;
    webController = null;
    state.webViewInstance += 1;
    state.stylePrompt = stylePrompt.trim();
    state.lyrics = lyrics.trim();
    state.initialUrl = 'https://suno.com/create';
    state.ignoredStylePrompt = '';
    state.statusKey = completedStandby ? 'complete' : 'waitingLogin';
    state.manualActionMessage =
        completedStandby ? '这首歌词的 Suno 完整版已完成生成和下载。' : 'Suno 页面已打开，请先在页面中自行登录。';
    state.errorMessage = null;
    state.songUrl = null;
    state.audioPath = null;
    state.metadataPath = null;
    state.creditsRemaining = null;
    state.styleMagicRequestedAt = null;
    state.versions.clear();
    state.downloadedSongUrls.clear();
    state.downloadedDownloadKeys.clear();
    state.downloadInFlightKeys.clear();
    state.detectedSongUrls.clear();
    state.trustedSongUrls.clear();
    state.rejectedCandidateSongUrls.clear();
    state.pendingDownloadSongUrl = null;
    state.pendingDownloadTitle = null;
    state.createBatch = SunoCreateBatch();
    final cachedGroups = await loadGroups(article);
    final cachedSuno = await loadCachedState(article);
    if (cachedSuno != null && cachedSuno.versions.isNotEmpty) {
      state.versions.addAll(cachedSuno.versions);
      state.rememberDownloadedSongUrls();
    }
    final cachedDetected = SunoUtilities.mergeSongUrls(
      cachedGroups.map((group) => group.detectedSongUrls),
    );
    state.detectedSongUrls
      ..clear()
      ..addAll(cachedDetected);
    state.trustedSongUrls.addAll(cachedDetected);
    state.trustedSongUrls.addAll(
      state.versions
          .map((v) => SunoUtilities.canonicalSongUrl(v.songUrl))
          .whereType<String>()
          .where((v) => v.isNotEmpty && !SunoUtilities.isSyntheticSongKey(v)),
    );
    state.syncDownloadedIntoDetected();
    state.createBaselineVersionCount = state.versions.length;
    state.createSubmitted = false;
    state.existingDownloadOnly = false;
    state.completedStandby = completedStandby;
    state.completedStandbyFilled = false;
    state.visible = true;
    TomatoLogger.info(
      category: 'suno',
      event: 'automation.started',
      articleId: articleId,
      status: state.statusKey,
      data: {
        'styleLength': state.stylePrompt.length,
        'lyricsLength': state.lyrics.length,
        'cachedVersions': state.versions.length,
      },
    );
    _host.requestSetState();
    await _host.pushSongState(articleId);
    startPolling();
    return {'articleId': articleId};
  }

  Future<Map<String, dynamic>> startExistingDownload({
    required Article article,
    required String lyrics,
    required Future<List<SunoCachedSongGroup>> Function(Article) loadGroups,
    required Future<ArticleSongState?> Function(Article) loadCachedState,
    required Future<Set<String>> Function(int articleId) otherArticleUrls,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      throw const FormatException('文章尚未保存，不能下载歌曲');
    }
    final cachedSuno = await loadCachedState(article);
    final groups = await loadGroups(article);
    final group = groups.isEmpty ? null : groups.first;
    final missing = group?.missingSongUrls ?? const <String>[];
    final songUrl = SunoUtilities.canonicalSongUrl(
            missing.isNotEmpty ? missing.first : '') ??
        '';

    stopAutomation(clearVisible: false);
    state.articleId = articleId;
    webController = null;
    state.webViewInstance += 1;
    state.stylePrompt = '';
    state.lyrics = lyrics;
    state.initialUrl = songUrl.isEmpty ? 'https://suno.com/me' : songUrl;
    state.statusKey = 'downloading';
    state.manualActionMessage = songUrl.isEmpty
        ? '正在打开 Suno Library，并按当前歌词查找未下载歌曲...'
        : '正在打开 Suno 已生成歌曲并尝试下载...';
    state.errorMessage = null;
    state.songUrl = songUrl.isEmpty ? null : songUrl;
    state.versions
      ..clear()
      ..addAll(cachedSuno?.versions ?? const <ArticleSongVersion>[]);
    state.downloadedSongUrls.clear();
    state.downloadedDownloadKeys.clear();
    state.downloadInFlightKeys.clear();
    state.rejectedCandidateSongUrls
      ..clear()
      ..addAll(await otherArticleUrls(articleId));
    state.detectedSongUrls
      ..clear()
      ..addAll(SunoUtilities.mergeSongUrls([group?.detectedSongUrls ?? []]));
    state.trustedSongUrls
      ..clear()
      ..addAll(state.detectedSongUrls);
    if (songUrl.isNotEmpty) {
      state.trustedSongUrls.add(songUrl);
    }
    state.rememberDownloadedSongUrls();
    state.syncDownloadedIntoDetected();
    state.createBaselineVersionCount = state.versions.length;
    state.pendingDownloadSongUrl = songUrl.isEmpty ? null : songUrl;
    state.pendingDownloadTitle = article.title;
    state.existingDownloadStartedAt = DateTime.now();
    state.existingDownloadMenuRetries = 0;
    state.existingDownloadLibraryTried = false;
    state.createSubmitted = true;
    state.existingDownloadOnly = true;
    state.completedStandby = false;
    state.completedStandbyFilled = false;
    state.visible = true;
    state.createBatch = SunoCreateBatch();
    _host.requestSetState();
    await _host.pushSongState(articleId);
    startPolling();
    return {'articleId': articleId};
  }

  Future<void> confirmCreate() async {
    final controller = webController;
    if (controller == null || state.articleId == null) {
      return;
    }
    if (state.automationBusy) {
      return;
    }
    state.automationBusy = true;
    try {
      try {
        final currentUrl = (await controller.getUrl())?.toString() ?? '';
        if (SunoUtilities.pageKind(currentUrl) == 'create') {
          final probe = await _bridge.evaluateJson(
            controller,
            SunoWebScripts.fillScript(
              lyrics: state.lyrics,
              stylePrompt: state.stylePrompt,
              ignoredStylePrompt: state.ignoredStylePrompt,
              allowMagicClick: false,
              magicAlreadyRequested: state.styleMagicRequestedAt != null,
              readOnly: true,
            ),
          );
          final currentStyle = (probe['stylePrompt'] ?? '').toString().trim();
          if (currentStyle.isNotEmpty) {
            state.stylePrompt = currentStyle;
          }
        }
      } catch (error, stackTrace) {
        TomatoLogger.warn(
          category: 'suno',
          event: 'create.style_sync_skipped',
          articleId: state.articleId,
          status: state.statusKey,
          message: _host.displayError(error),
          stackTrace: stackTrace,
        );
      }
      await snapshotPreCreateSongUrls(controller);
      state.markNavigating();
      final result = await _bridge.evaluateJson(
        controller,
        SunoWebScripts.createScript,
      );
      if (result['ok'] == true) {
        state.createBaselineVersionCount = state.versions.length;
        state.createSubmitted = true;
        state.completedStandby = false;
        state.completedStandbyFilled = false;
        state.detectedSongUrls.clear();
        state.rememberDownloadedSongUrls();
        state.createBatch = SunoCreateBatch(
          preCreateUrls: state.rejectedCandidateSongUrls,
        );
        await setStatus('creating', 'Suno 正在生成歌曲...');
        startPolling();
        return;
      }
      await setStatus(
        'manualAction',
        (result['message'] ?? '').toString().trim().isEmpty
            ? 'Tomato 没能点击 Suno Create，请检查页面字段或手工点击 Create。'
            : (result['message'] ?? '').toString(),
      );
    } catch (error) {
      if (_isTransientWebViewError(error)) {
        await setStatus('manualAction', 'Suno 页面控件还在初始化或刚刚重建，请稍后再确认创建。');
        return;
      }
      await failAutomation(_host.displayError(error));
    } finally {
      state.automationBusy = false;
      _host.requestSetState();
    }
  }

  Future<void> snapshotPreCreateSongUrls(
      InAppWebViewController controller) async {
    try {
      final probe = await _bridge.evaluateJson(
        controller,
        SunoWebScripts.completionScript(
          expectedStylePrompt: state.stylePrompt,
          expectedLyrics: state.lyrics,
          requireExpectedMatch: false,
          trustedSongUrls: state.trustedSongUrlsList(),
        ),
      );
      final preExisting = SunoUtilities.mergeSongUrls([
        ((probe['candidateSongUrls'] as List?) ?? const [])
            .map((value) => value.toString()),
        ((probe['songUrls'] as List?) ?? const [])
            .map((value) => value.toString()),
        ((probe['createSidebarSongUrls'] as List?) ?? const [])
            .map((value) => value.toString()),
      ]);
      state.rejectedCandidateSongUrls.addAll(preExisting);
      state.createBatch.markPreCreateUrls(preExisting);
      TomatoLogger.info(
        category: 'suno',
        event: 'create.pre_submit_snapshot',
        articleId: state.articleId,
        status: state.statusKey,
        data: {
          'preExistingSongUrls': preExisting.length,
          'rejectedTotal': state.rejectedCandidateSongUrls.length,
        },
      );
    } catch (error, stackTrace) {
      TomatoLogger.warn(
        category: 'suno',
        event: 'create.pre_submit_snapshot_skipped',
        articleId: state.articleId,
        status: state.statusKey,
        message: _host.displayError(error),
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> handleWebViewDownload(DownloadStartRequest request) async {
    final articleId = state.articleId;
    if (articleId == null) {
      return;
    }
    final songUrl = SunoUtilities.canonicalSongUrl(
          state.pendingDownloadSongUrl ?? state.songUrl,
        ) ??
        '';
    final requestUrl = request.url.toString();
    if (SunoUtilities.isRejectedPreviewMediaUrl(requestUrl)) {
      await setStatus('downloading', '已跳过 Suno 预览片段，正在继续查找完整版下载...');
      startPolling();
      return;
    }
    if (songUrl.isNotEmpty &&
        SunoUtilities.isVerifiableMediaUrl(requestUrl) &&
        SunoUtilities.matchingMediaUrl(requestUrl, songUrl) == null) {
      await setStatus(
        'manualAction',
        '已拦截一个不属于当前文章目标歌曲的 Suno 下载链接，避免保存错歌。请回到正确歌曲页后再继续检测。',
      );
      stopPolling();
      return;
    }
    if (songUrl.isNotEmpty &&
        (state.downloadedSongUrls.contains(songUrl) ||
            state.hasLocalVersionForSongUrl(songUrl))) {
      state.downloadedSongUrls.add(songUrl);
      state.detectedSongUrls.add(songUrl);
      state.trustedSongUrls.add(songUrl);
      state.createBatch.markDownloaded(songUrl);
      state.pendingDownloadSongUrl = null;
      state.pendingDownloadTitle = null;
      await setStatus('downloading', '这个 Suno 版本已经下载过，正在检查其它版本...');
      startPolling();
      return;
    }
    final downloadKey =
        songUrl.isNotEmpty ? 'song:$songUrl' : 'download:$requestUrl';
    if (state.downloadInFlightKeys.contains(downloadKey) ||
        state.downloadedDownloadKeys.contains(downloadKey)) {
      return;
    }
    state.downloadInFlightKeys.add(downloadKey);
    await setStatus('downloading', '正在下载 Suno 生成的歌曲...');
    try {
      final directory = Directory(await _host.resolvedSunoOutputDirectory());
      await directory.create(recursive: true);
      final filename = _safeFilename(request.suggestedFilename);
      final target = await _uniqueTargetFile(directory, filename);
      final bytes = await _host.downloadUrl(
        requestUrl,
        userAgent: request.userAgent,
      );
      if (bytes.isEmpty) {
        throw const FormatException('下载结果为空');
      }
      await target.writeAsBytes(bytes, flush: true);
      state.audioPath = target.path;
      if (songUrl.isNotEmpty) {
        state.downloadedSongUrls.add(songUrl);
        state.detectedSongUrls.add(songUrl);
        state.trustedSongUrls.add(songUrl);
        state.createBatch.markDownloaded(songUrl);
      }
      state.downloadedDownloadKeys.add(downloadKey);
      final article = await _host.loadSongArticle(articleId);
      final lyricsHash = await _host.articleSongLyricsHash(article);
      final version = ArticleSongVersion(
        id: 'suno_${articleId}_${DateTime.now().millisecondsSinceEpoch}_${state.versions.length + 1}',
        audioPath: target.path,
        title: (state.pendingDownloadTitle ?? '').trim().isEmpty
            ? 'Suno 版本 ${state.versions.length + 1}'
            : state.pendingDownloadTitle!.trim(),
        songUrl: songUrl.isEmpty
            ? SunoUtilities.canonicalSongUrl(state.songUrl)
            : songUrl,
        createdAt: DateTime.now().toIso8601String(),
        stylePrompt:
            state.stylePrompt.trim().isEmpty ? null : state.stylePrompt.trim(),
        lyricsHash: lyricsHash,
      );
      state.versions.removeWhere(
        (item) =>
            item.songUrl != null &&
            version.songUrl != null &&
            SunoUtilities.canonicalSongUrl(item.songUrl) ==
                SunoUtilities.canonicalSongUrl(version.songUrl),
      );
      state.versions.add(version);
      TomatoLogger.info(
        category: 'suno',
        event: 'download.saved',
        articleId: articleId,
        status: state.statusKey,
        data: {
          'songUrl': version.songUrl,
          'bytes': bytes.length,
          'versionCount': state.versions.length,
        },
      );
      state.pendingDownloadSongUrl = null;
      state.pendingDownloadTitle = null;
      state.menuDownloadClickedAt = null;
      await saveMetadata();
      await setStatus(
        'downloading',
        '已下载 ${state.versions.length} 个 Suno 完整版本，正在检查是否还有其它版本...',
      );
      startPolling();
    } catch (error) {
      TomatoLogger.error(
        category: 'suno',
        event: 'download.failed',
        articleId: articleId,
        status: state.statusKey,
        data: {'requestUrl': requestUrl, 'targetSongUrl': songUrl},
        error: error,
      );
      await setStatus(
        'manualAction',
        '自动下载失败：${_host.displayError(error)}。请在 Suno 页面手工下载音频。',
      );
    } finally {
      state.downloadInFlightKeys.remove(downloadKey);
    }
  }
}
