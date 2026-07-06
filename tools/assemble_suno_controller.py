#!/usr/bin/env python3
"""Assemble suno_automation_controller.dart from tick body + wrappers."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
tick_path = root / "app/lib/features/web_shell/suno/_tick_body.dart.txt"
tick = tick_path.read_text(encoding="utf-8")
tick = tick.replace("_sunoCreditsRemaining", "state.creditsRemaining")
tick = tick.replace("_evaluateSunoJson(\n              controller,", "_bridge.evaluateJson(webController,")
tick = tick.replace("_evaluateSunoJson(\n            controller,", "_bridge.evaluateJson(webController,")
tick = tick.replace("_evaluateSunoJson(\n          controller,", "_bridge.evaluateJson(webController,")
tick = tick.replace("_evaluateSunoJson(\n        controller,", "_bridge.evaluateJson(webController,")
tick = tick.replace("await controller.loadUrl(\n            urlRequest: URLRequest(url: WebUri(", "state.markNavigating();\n            await _bridge.loadUrl(webController, ")
tick = tick.replace("await controller.loadUrl(\n              urlRequest: URLRequest(url: WebUri(", "state.markNavigating();\n            await _bridge.loadUrl(webController, ")
tick = tick.replace("await controller.loadUrl(\n                urlRequest: URLRequest(url: WebUri(", "state.markNavigating();\n            await _bridge.loadUrl(webController, ")
tick = tick.replace("await controller.loadUrl(\n          urlRequest: URLRequest(url: WebUri(", "state.markNavigating();\n          await _bridge.loadUrl(webController, ")
# fix loadUrl replacements - remove trailing WebUri parens
import re
tick = re.sub(
    r"await _bridge\.loadUrl\(webController, ([^)]+)\)\),\n            \);",
    r"await _bridge.loadUrl(webController, \1);",
    tick,
)
tick = re.sub(
    r"await _bridge\.loadUrl\(webController, ([^)]+)\)\),\n          \);",
    r"await _bridge.loadUrl(webController, \1);",
    tick,
)

# login suppression
tick = tick.replace(
    "      if (!loggedIn) {\n        await setStatus(\n          'waitingLogin',\n          'Suno 页面已打开，请先在页面中自行登录。',\n        );\n        return;\n      }",
    """      if (!loggedIn) {
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
      }""",
    1,
)

# batch on completion probe - after completion.probe log block, insert batch absorb
batch_insert = """
        _absorbCreateBatchFromProbe(result);
        state.hasOpenLibraryCandidates = _libraryCandidateSongUrls(
          result,
          detectDownloadBroadRecall: _useLibraryBroadRecall,
        ).isNotEmpty;
        state.libraryScanSettled = _isPageSettled(currentUrl) &&
            (SunoUtilities.pageKind(currentUrl) == 'library' ||
                SunoUtilities.pageKind(currentUrl) == 'create');
"""
marker = "        var songUrl = SunoUtilities.canonicalSongUrl(result['songUrl']) ?? '';"
if marker in tick and "_absorbCreateBatchFromProbe" not in tick:
    tick = tick.replace(marker, batch_insert + "\n" + marker, 1)

# replace complete calls
tick = tick.replace(
    "await saveMetadata();\n            await setStatus('complete', null);\n            _timer?.cancel();\n            return;",
    "await _tryComplete(currentUrl: currentUrl, reason: 'library_candidates_exhausted');\n            return;",
)
tick = tick.replace(
    "await saveMetadata();\n              await setStatus('complete', null);\n              _timer?.cancel();\n              return;",
    "await _tryComplete(currentUrl: currentUrl, reason: 'direct_media_remaining_empty');\n              return;",
)

header = r'''import 'dart:async';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/logging/tomato_logger.dart';
import '../../../data/models/article_model.dart';
import '../../../data/models/article_song_model.dart';
import 'suno_automation_host.dart';
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
    state.mightHaveMoreLibraryRows = !_isPageSettled(currentUrl) ||
        state.hasOpenLibraryCandidates ||
        state.createBatch.hasPending;
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
      if (state.createBatch.hasPending &&
          SunoUtilities.pageKind(currentUrl) != 'create') {
        state.markNavigating();
        final controller = webController;
        if (controller != null) {
          await _bridge.loadUrl(controller, 'https://suno.com/create');
        }
        await setStatus(
          'downloading',
          'Create 批次仍有未下载歌曲，正在回到 Create 页面继续扫描...',
        );
      }
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
              source: 'suno',
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
'''

footer = r'''
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
}
'''

out = root / "app/lib/features/web_shell/suno/suno_automation_controller.dart"
out.write_text(header + tick + footer, encoding="utf-8")
print(f"Wrote {out}")
