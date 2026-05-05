import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as path_lib;

WebViewEnvironment? tomatoWebViewEnvironment;
String? tomatoWebViewEnvironmentError;
InAppLocalhostServer? tomatoWebUiServer;
String? tomatoWebUiServerError;

const tomatoWebUiServerPort = 48731;
const tomatoWebUiLocalUrl =
    'http://127.0.0.1:$tomatoWebUiServerPort/index.html';

Future<void> initializeTomatoWebViewEnvironment() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
    return;
  }

  try {
    final version = await WebViewEnvironment.getAvailableVersion();
    if (version == null || version.trim().isEmpty) {
      tomatoWebViewEnvironmentError =
          '未检测到 Microsoft Edge WebView2 Runtime，请安装后重试。';
      return;
    }

    final localAppData = Platform.environment['LOCALAPPDATA'];
    final userDataRoot = localAppData == null || localAppData.trim().isEmpty
        ? Directory.systemTemp.path
        : localAppData;
    final userDataFolder = path_lib.join(
      userDataRoot,
      'TomatoEnglishHappyTalking',
      'WebView2',
    );

    tomatoWebViewEnvironment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(userDataFolder: userDataFolder),
    );
  } catch (error) {
    tomatoWebViewEnvironmentError = 'WebView2 初始化失败：$error';
  }
}

Future<void> initializeTomatoWebUiServer() async {
  if (kIsWeb) {
    return;
  }

  try {
    final server = InAppLocalhostServer(
      port: tomatoWebUiServerPort,
      documentRoot: 'assets/web',
      directoryIndex: 'index.html',
    );
    await server.start();
    tomatoWebUiServer = server;
  } catch (error) {
    tomatoWebUiServerError = 'Web UI 本地资源服务启动失败：$error';
  }
}
