import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/logging/tomato_logger.dart';
import 'suno_web_bridge.dart';
import 'suno_web_scripts.dart';

/// Result of an automatic Lexical lyrics paste attempt.
class SunoWebViewPasteResult {
  const SunoWebViewPasteResult({
    required this.pasteMethod,
    this.focusOk = false,
    this.pasteOk = false,
  });

  final String? pasteMethod;
  final bool focusOk;

  /// Whether a WebView CDP paste path reported success.
  final bool pasteOk;

  bool get cdpOk => pasteMethod == 'cdpCtrlV' || pasteMethod == 'cdpCtrlVKeys';
}

typedef SunoWebViewFocusCallback = Future<void> Function();

/// WebView-scoped Lexical lyrics paste via OS clipboard + in-WebView CDP click/paste.
///
/// Never injects lyrics through JavaScript (no insertText, synthetic paste, or
/// embedded lyric payloads in evaluateJavascript).
class SunoWebViewPaste {
  SunoWebViewPaste({SunoWebBridge? bridge})
      : _bridge = bridge ?? SunoWebBridge();

  final SunoWebBridge _bridge;

  Future<SunoWebViewPasteResult> autoPasteLexicalLyrics({
    required InAppWebViewController controller,
    required String lyrics,
    bool editorAlreadyReady = false,
    SunoWebViewFocusCallback? ensureWebViewFocused,
  }) async {
    try {
      await ensureWebViewFocused?.call();
      await Clipboard.setData(ClipboardData(text: lyrics));
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final focus = editorAlreadyReady
          ? await _bridge.evaluateJson(
              controller,
              SunoWebScripts.focusLexicalLyricsEditorScript(),
            )
          : await _focusEditorWithRetry(controller);
      final focusOk = focus['focusOk'] == true || focus['ok'] == true;
      if (!focusOk) {
        TomatoLogger.warn(
          category: 'suno',
          event: 'create.clipboard_paste.focus_failed',
          message: 'Lexical editor focus failed before paste',
          data: focus,
        );
        return const SunoWebViewPasteResult(
          pasteMethod: 'editorNotReady',
          focusOk: false,
        );
      }

      TomatoLogger.info(
        category: 'suno',
        event: 'create.clipboard_paste.start',
        message: 'Starting clipboard + CDP click/paste into Lexical editor',
        data: {
          'lyricsLength': lyrics.length,
          'editorAlreadyReady': editorAlreadyReady,
          'isEmptyEditor': focus['isEmptyEditor'] == true,
          'clickX': focus['clickX'],
          'clickY': focus['clickY'],
        },
      );

      await ensureWebViewFocused?.call();
      await Future<void>.delayed(const Duration(milliseconds: 250));

      final pasteMethod = await _dispatchPaste(controller, focus);
      final pasteOk = pasteMethod == 'cdpCtrlV' || pasteMethod == 'cdpCtrlVKeys';

      TomatoLogger.info(
        category: 'suno',
        event: 'create.clipboard_paste.sent',
        message: 'Paste dispatch finished',
        data: {
          'pasteMethod': pasteMethod,
          'pasteOk': pasteOk,
        },
      );

      return SunoWebViewPasteResult(
        pasteMethod: pasteMethod,
        focusOk: focusOk,
        pasteOk: pasteOk,
      );
    } catch (error, stack) {
      TomatoLogger.error(
        category: 'suno',
        event: 'create.clipboard_paste.error',
        message: error.toString(),
        error: error,
        stackTrace: stack,
      );
      return const SunoWebViewPasteResult(
        pasteMethod: 'pasteException',
      );
    }
  }

  Future<String> _dispatchPaste(
    InAppWebViewController controller,
    Map<String, dynamic> focus,
  ) async {
    await _dispatchCdpMouseClick(controller, focus);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (await _dispatchCdpPasteCommand(controller)) {
      return 'cdpCtrlV';
    }
    if (await _dispatchCdpCtrlVKeys(controller)) {
      return 'cdpCtrlVKeys';
    }
    return 'pasteFailed';
  }

  Future<void> _dispatchCdpMouseClick(
    InAppWebViewController controller,
    Map<String, dynamic> focus,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.windows) {
      return;
    }
    final clickX = _jsonDouble(focus['clickX']) ??
        _jsonDouble(focus['centerX']);
    final clickY = _jsonDouble(focus['clickY']) ??
        _jsonDouble(focus['centerY']);
    if (clickX == null || clickY == null) {
      TomatoLogger.warn(
        category: 'suno',
        event: 'create.clipboard_paste.click_skipped',
        message: 'Missing editor click coordinates; skipping CDP mouse click',
        data: focus,
      );
      return;
    }
    try {
      await controller.callDevToolsProtocolMethod(
        methodName: 'Input.dispatchMouseEvent',
        parameters: {
          'type': 'mousePressed',
          'x': clickX,
          'y': clickY,
          'button': 'left',
          'clickCount': 1,
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await controller.callDevToolsProtocolMethod(
        methodName: 'Input.dispatchMouseEvent',
        parameters: {
          'type': 'mouseReleased',
          'x': clickX,
          'y': clickY,
          'button': 'left',
          'clickCount': 1,
        },
      );
    } catch (error, stack) {
      TomatoLogger.warn(
        category: 'suno',
        event: 'create.clipboard_paste.click_failed',
        message: error.toString(),
        error: error,
        stackTrace: stack,
      );
    }
  }

  double? _jsonDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return null;
  }

  Future<Map<String, dynamic>> _focusEditorWithRetry(
    InAppWebViewController controller,
  ) async {
    Map<String, dynamic> focus = {};
    for (var attempt = 0; attempt < 8; attempt++) {
      focus = await _bridge.evaluateJson(
        controller,
        SunoWebScripts.focusLexicalLyricsEditorScript(),
      );
      if (focus['focusOk'] == true || focus['ok'] == true) {
        focus['editorFound'] = true;
        return focus;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return focus;
  }

  Future<bool> _dispatchCdpCtrlVKeys(InAppWebViewController controller) async {
    if (defaultTargetPlatform != TargetPlatform.windows) {
      return false;
    }
    try {
      const ctrlDown = {
        'type': 'keyDown',
        'modifiers': 2,
        'key': 'Control',
        'code': 'ControlLeft',
        'windowsVirtualKeyCode': 17,
        'nativeVirtualKeyCode': 17,
      };
      const vDown = {
        'type': 'keyDown',
        'modifiers': 2,
        'key': 'v',
        'code': 'KeyV',
        'windowsVirtualKeyCode': 86,
        'nativeVirtualKeyCode': 86,
        'text': 'v',
      };
      const vUp = {
        'type': 'keyUp',
        'modifiers': 2,
        'key': 'v',
        'code': 'KeyV',
        'windowsVirtualKeyCode': 86,
        'nativeVirtualKeyCode': 86,
      };
      const ctrlUp = {
        'type': 'keyUp',
        'key': 'Control',
        'code': 'ControlLeft',
        'windowsVirtualKeyCode': 17,
        'nativeVirtualKeyCode': 17,
      };
      await controller.callDevToolsProtocolMethod(
        methodName: 'Input.dispatchKeyEvent',
        parameters: ctrlDown,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await controller.callDevToolsProtocolMethod(
        methodName: 'Input.dispatchKeyEvent',
        parameters: vDown,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await controller.callDevToolsProtocolMethod(
        methodName: 'Input.dispatchKeyEvent',
        parameters: vUp,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await controller.callDevToolsProtocolMethod(
        methodName: 'Input.dispatchKeyEvent',
        parameters: ctrlUp,
      );
      return true;
    } catch (error, stack) {
      TomatoLogger.warn(
        category: 'suno',
        event: 'create.clipboard_paste.cdp_keys_failed',
        message: error.toString(),
        error: error,
        stackTrace: stack,
      );
      return false;
    }
  }

  Future<bool> _dispatchCdpPasteCommand(InAppWebViewController controller) async {
    if (defaultTargetPlatform != TargetPlatform.windows) {
      return false;
    }
    try {
      await controller.callDevToolsProtocolMethod(
        methodName: 'Input.dispatchKeyEvent',
        parameters: const {
          'type': 'keyDown',
          'commands': ['paste'],
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await controller.callDevToolsProtocolMethod(
        methodName: 'Input.dispatchKeyEvent',
        parameters: const {
          'type': 'keyUp',
        },
      );
      return true;
    } catch (error, stack) {
      TomatoLogger.warn(
        category: 'suno',
        event: 'create.clipboard_paste.cdp_failed',
        message: error.toString(),
        error: error,
        stackTrace: stack,
      );
      return false;
    }
  }
}
