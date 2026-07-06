import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class SunoWebBridge {
  const SunoWebBridge();

  Future<Map<String, dynamic>> evaluateJson(
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

  Future<void> loadUrl(
    InAppWebViewController controller,
    String url,
  ) async {
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }
}
