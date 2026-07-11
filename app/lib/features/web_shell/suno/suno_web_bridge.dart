import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:tomato_english_happy_talking/core/logging/tomato_logger.dart';

/// Serializes Suno WebView JavaScript evaluation to avoid concurrent crashes.
class SunoWebBridge {
  SunoWebBridge();

  Future<void> _evaluationChain = Future<void>.value();

  Future<Map<String, dynamic>> evaluateJson(
    InAppWebViewController controller,
    String source,
  ) async {
    final previous = _evaluationChain;
    final gate = Completer<void>();
    _evaluationChain = gate.future;
    await previous;
    try {
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
    } catch (error, stack) {
      TomatoLogger.warn(
        category: 'suno',
        event: 'webview.evaluate_failed',
        message: error.toString(),
        error: error,
        stackTrace: stack,
      );
      rethrow;
    } finally {
      gate.complete();
    }
  }

  Future<void> loadUrl(
    InAppWebViewController controller,
    String url,
  ) async {
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }
}
