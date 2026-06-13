import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:tomato_english_happy_talking/core/logging/tomato_logger.dart';
import 'package:tomato_english_happy_talking/features/web_shell/web_shell_qa_server.dart';

void main() {
  late Directory logDirectory;
  late WebShellQaServer server;

  setUp(() async {
    logDirectory = await Directory.systemTemp.createTemp('tomato_qa_logs_');
    await TomatoLogger.initialize(
      directory: logDirectory,
      minLevel: 'trace',
    );
    server = WebShellQaServer(
      port: 0,
      token: '',
      health: () async => {
        'ok': true,
        'authorization': 'Bearer export-secret-12345678901234567890',
      },
      snapshot: () async => {
        'route': '/settings',
        'file': r'F:\TomatoEnglishHappyTalking\security\ark.txt',
      },
      screenshot: () async => Uint8List(0),
      navigate: (route) async => {'ok': true, 'route': route},
      click: (payload) async => {'ok': true, 'payload': payload},
      fill: (payload) async => {'ok': true, 'payload': payload},
      dispatchBridge: (raw) async => {'ok': true, 'raw': raw},
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    await TomatoLogger.resetForTest();
    if (await logDirectory.exists()) {
      await logDirectory.delete(recursive: true);
    }
  });

  test('/logs/recent returns filtered memory logs', () async {
    TomatoLogger.info(
      category: 'suno',
      event: 'qa_recent_probe',
      articleId: 42,
    );
    TomatoLogger.info(category: 'bridge', event: 'excluded_probe');

    final body = await _getJson(server, '/logs/recent?limit=5&category=suno');
    expect(body['ok'], isTrue);
    final logs = (body['logs'] as List).cast<Map<String, dynamic>>();
    expect(logs.map((entry) => entry['event']), contains('qa_recent_probe'));
    expect(
        logs.map((entry) => entry['event']), isNot(contains('excluded_probe')));
  });

  test('/logs/export creates a sanitized diagnostic package', () async {
    TomatoLogger.info(
      category: 'config',
      event: 'export_probe',
      data: {'cookie': 'session=super-secret-cookie'},
    );

    final body = await _getJson(server, '/logs/export');
    expect(body['ok'], isTrue);
    final export = (body['export'] as Map).cast<String, dynamic>();
    final exportDirectory = Directory(export['path'] as String);
    expect(await exportDirectory.exists(), isTrue);
    expect((export['files'] as List), contains('environment.json'));
    expect((export['files'] as List), contains('snapshot.json'));
    expect((export['files'] as List), contains('recent.ndjson'));

    final environment =
        await File(path.join(exportDirectory.path, 'environment.json'))
            .readAsString();
    final snapshot =
        await File(path.join(exportDirectory.path, 'snapshot.json'))
            .readAsString();
    expect(environment, contains('[redacted]'));
    expect(environment, isNot(contains('export-secret-12345678901234567890')));
    expect(snapshot, contains('[path:ark.txt]'));
    expect(snapshot, isNot(contains(r'F:\TomatoEnglishHappyTalking\security')));
  });

  test('/logs/stream pushes new matching logs over SSE', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final request =
        await client.getUrl(_uri(server, '/logs/stream?category=qa'));
    final response = await request.close();
    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.contentType?.mimeType, 'text/event-stream');

    final completer = Completer<String>();
    final buffer = StringBuffer();
    late StreamSubscription<List<int>> subscription;
    subscription = response.listen((chunk) {
      buffer.write(utf8.decode(chunk));
      final text = buffer.toString();
      if (text.contains('qa_stream_probe') && !completer.isCompleted) {
        completer.complete(text);
      }
    });
    addTearDown(() async => subscription.cancel());

    await Future<void>.delayed(const Duration(milliseconds: 50));
    TomatoLogger.info(category: 'qa', event: 'qa_stream_probe');

    final text = await completer.future.timeout(const Duration(seconds: 3));
    expect(text, contains('event: ready'));
    expect(text, contains('event: log'));
    expect(text, contains('qa_stream_probe'));
  });
}

Future<Map<String, dynamic>> _getJson(
  WebShellQaServer server,
  String pathAndQuery,
) async {
  final client = HttpClient();
  addTearDown(() => client.close(force: true));
  final request = await client.getUrl(_uri(server, pathAndQuery));
  final response = await request.close();
  final text = await utf8.decoder.bind(response).join();
  expect(response.statusCode, HttpStatus.ok);
  return (jsonDecode(text) as Map).cast<String, dynamic>();
}

Uri _uri(WebShellQaServer server, String pathAndQuery) {
  final port = server.activePort;
  expect(port, isNotNull);
  return Uri.parse('http://127.0.0.1:$port$pathAndQuery');
}
