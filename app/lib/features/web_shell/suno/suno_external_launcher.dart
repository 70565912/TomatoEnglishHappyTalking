import 'dart:io';

import 'package:flutter/services.dart';

import '../../../core/logging/tomato_logger.dart';

/// Opens Suno in the system browser. App does not embed Suno Create (Lexical
/// keyboard crashes in flutter_inappwebview on Windows).
class SunoExternalLauncher {
  static const createUrl = 'https://suno.com/create';

  static String manualActionMessage({
    required int lyricsLength,
    required bool browserOpened,
  }) {
    if (browserOpened) {
      return '整篇歌词（$lyricsLength 字）已复制到剪贴板，并已在系统浏览器打开 Suno Create。'
          '请在浏览器中登录、粘贴歌词、设置风格并 Create；'
          '在 Suno 下载 MP3 后，回到创作中心点击「导入本地音乐」添加歌曲版本。';
    }
    return '整篇歌词（$lyricsLength 字）已复制到剪贴板。'
        '无法自动打开浏览器，请手动访问 $createUrl；'
        '在 Suno 完成 Create 并下载 MP3 后，回到创作中心点击「导入本地音乐」。';
  }

  /// Copies [lyrics] to the clipboard and opens Suno Create in the system browser.
  static Future<bool> launchManualCreate({required String lyrics}) async {
    final trimmed = lyrics.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    await Clipboard.setData(ClipboardData(text: trimmed));
    final opened = await openUrl(createUrl);
    TomatoLogger.info(
      category: 'suno',
      event: opened ? 'manual_create.opened' : 'manual_create.browser_failed',
      data: {'lyricsLength': trimmed.length},
    );
    return opened;
  }

  static Future<bool> openUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    try {
      if (Platform.isWindows) {
        final result = await Process.run(
          'cmd',
          ['/c', 'start', '', trimmed],
          runInShell: true,
        );
        return result.exitCode == 0;
      }
      if (Platform.isMacOS) {
        final result = await Process.run('open', [trimmed]);
        return result.exitCode == 0;
      }
      if (Platform.isLinux) {
        final result = await Process.run('xdg-open', [trimmed]);
        return result.exitCode == 0;
      }
    } catch (error, stackTrace) {
      TomatoLogger.warn(
        category: 'suno',
        event: 'external_browser.open_failed',
        message: 'Failed to open external browser',
        error: error,
        stackTrace: stackTrace,
        data: {'url': trimmed},
      );
    }
    return false;
  }
}
