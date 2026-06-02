import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

typedef QaBridgeDispatcher = Future<Map<String, dynamic>> Function(Object? raw);
typedef QaJsonProducer = Future<Map<String, dynamic>> Function();
typedef QaNavigator = Future<Map<String, dynamic>> Function(String path);
typedef QaScreenshotProducer = Future<Uint8List> Function();
typedef QaDomOperator = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> payload,
);

class WebShellQaServer {
  WebShellQaServer({
    required this.port,
    required this.token,
    required this.health,
    required this.snapshot,
    required this.screenshot,
    required this.navigate,
    required this.click,
    required this.fill,
    required this.dispatchBridge,
  });

  final int port;
  final String token;
  final QaJsonProducer health;
  final QaJsonProducer snapshot;
  final QaScreenshotProducer screenshot;
  final QaNavigator navigate;
  final QaDomOperator click;
  final QaDomOperator fill;
  final QaBridgeDispatcher dispatchBridge;

  HttpServer? _server;

  Future<void> start() async {
    if (_server != null) {
      return;
    }

    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      _server = server;
      debugPrint(
        '[WebShellQA] listening on http://127.0.0.1:${server.port}',
      );
      unawaited(_serve(server));
    } catch (error) {
      debugPrint('[WebShellQA] failed to start: $error');
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handleRequest(request));
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    _addCorsHeaders(request);
    if (request.method == 'OPTIONS') {
      await request.response.close();
      return;
    }

    if (!_isAuthorized(request)) {
      await _writeJson(
        request,
        {
          'ok': false,
          'error': {'message': 'Missing or invalid QA token'},
        },
        statusCode: HttpStatus.unauthorized,
      );
      return;
    }

    try {
      final path = request.uri.path;
      if (request.method == 'GET' && (path == '/' || path == '/health')) {
        await _writeJson(request, await health());
        return;
      }

      if (request.method == 'GET' && path == '/snapshot') {
        await _writeJson(request, await snapshot());
        return;
      }

      if (request.method == 'GET' && path == '/screenshot') {
        final bytes = await screenshot();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('image', 'png')
          ..add(bytes);
        await request.response.close();
        return;
      }

      if (request.method == 'POST' && path == '/navigate') {
        final body = await _readJsonBody(request);
        final route = body['path'];
        if (route is! String || !route.startsWith('/')) {
          throw const FormatException('navigate.path must start with /');
        }
        await _writeJson(request, await navigate(route));
        return;
      }

      if (request.method == 'POST' && path == '/click') {
        final body = await _readJsonBody(request);
        await _writeJson(request, await click(body));
        return;
      }

      if (request.method == 'POST' && path == '/fill') {
        final body = await _readJsonBody(request);
        await _writeJson(request, await fill(body));
        return;
      }

      if (request.method == 'POST' && path == '/bridge') {
        final body = await _readJsonBody(request);
        final type = body['type'];
        if (type is! String || type.trim().isEmpty) {
          throw const FormatException('bridge.type is required');
        }
        final payload = body['payload'];
        if (payload != null && payload is! Map) {
          throw const FormatException('bridge.payload must be an object');
        }
        final response = await dispatchBridge({
          'id': 'qa_${DateTime.now().microsecondsSinceEpoch}',
          'type': type,
          'payload': payload ?? <String, dynamic>{},
        });
        await _writeJson(request, response);
        return;
      }

      await _writeJson(
        request,
        {
          'ok': false,
          'error': {'message': 'Unknown QA endpoint'},
          'endpoints': [
            'GET /health',
            'GET /snapshot',
            'GET /screenshot',
            'POST /navigate',
            'POST /click',
            'POST /fill',
            'POST /bridge',
          ],
        },
        statusCode: HttpStatus.notFound,
      );
    } catch (error) {
      await _writeJson(
        request,
        {
          'ok': false,
          'error': {'message': error.toString()},
        },
        statusCode: HttpStatus.internalServerError,
      );
    }
  }

  bool _isAuthorized(HttpRequest request) {
    if (token.trim().isEmpty) {
      return true;
    }
    final queryToken = request.uri.queryParameters['token'];
    final headerToken = request.headers.value('X-Tomato-QA-Token');
    return token == queryToken || token == headerToken;
  }

  void _addCorsHeaders(HttpRequest request) {
    request.response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
      ..set(
        'Access-Control-Allow-Headers',
        'Content-Type, X-Tomato-QA-Token',
      );
  }

  Future<Map<String, dynamic>> _readJsonBody(HttpRequest request) async {
    final text = await utf8.decoder.bind(request).join();
    if (text.trim().isEmpty) {
      return <String, dynamic>{};
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const FormatException('Request body must be a JSON object');
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  Future<void> _writeJson(
    HttpRequest request,
    Map<String, dynamic> payload, {
    int statusCode = HttpStatus.ok,
  }) async {
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(payload));
    await request.response.close();
  }
}
