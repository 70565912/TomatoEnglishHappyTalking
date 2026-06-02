import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/features/web_shell/web_bridge_protocol.dart';

void main() {
  test('BridgeMessage parses JSON string payload', () {
    final message = BridgeMessage.fromRaw(
      '{"id":"1","type":"article.list","payload":{"page":1}}',
    );

    expect(message.id, '1');
    expect(message.type, 'article.list');
    expect(message.payload['page'], 1);
  });

  test('BridgeMessage parses local map payload', () {
    final message = BridgeMessage.fromRaw({
      'id': 'qa_1',
      'type': 'settings.load',
      'payload': <String, Object?>{},
    });

    expect(message.id, 'qa_1');
    expect(message.type, 'settings.load');
    expect(message.payload, isEmpty);
  });

  test('BridgeRouter returns structured error for unknown command', () async {
    const router = BridgeRouter({});

    final response = await router.dispatch({
      'id': 'abc',
      'type': 'missing.command',
      'payload': {},
    });

    expect(response['ok'], isFalse);
    expect(response['id'], 'abc');
    expect(response['type'], 'missing.command.error');
    expect(response['error'], isA<Map<String, dynamic>>());
  });

  test('BridgeRouter returns structured error for malformed message', () async {
    const router = BridgeRouter({});

    final response = await router.dispatch('[]');

    expect(response['ok'], isFalse);
    expect(response['id'], 'invalid');
    expect(response['type'], 'bridge.error');
  });
}
