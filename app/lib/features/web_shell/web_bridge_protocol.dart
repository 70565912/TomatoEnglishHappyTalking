import 'dart:async';
import 'dart:convert';

class BridgeMessage {
  const BridgeMessage({
    required this.id,
    required this.type,
    required this.payload,
  });

  final String id;
  final String type;
  final Map<String, dynamic> payload;

  factory BridgeMessage.fromRaw(Object? raw) {
    final decoded = switch (raw) {
      final String text => jsonDecode(text),
      final Map<Object?, Object?> map => map,
      _ => throw const FormatException('Bridge message must be JSON object'),
    };

    if (decoded is! Map) {
      throw const FormatException('Bridge message must be JSON object');
    }

    final id = decoded['id'];
    final type = decoded['type'];
    final payload = decoded['payload'];

    if (id is! String || id.trim().isEmpty) {
      throw const FormatException('Bridge message missing id');
    }
    if (type is! String || type.trim().isEmpty) {
      throw const FormatException('Bridge message missing type');
    }
    if (payload != null && payload is! Map) {
      throw const FormatException('Bridge payload must be an object');
    }

    return BridgeMessage(
      id: id,
      type: type,
      payload: _stringKeyMap(payload),
    );
  }
}

typedef BridgeCommandHandler = FutureOr<Map<String, dynamic>> Function(
  BridgeMessage message,
);

class BridgeRouter {
  const BridgeRouter(this.handlers);

  final Map<String, BridgeCommandHandler> handlers;

  Future<Map<String, dynamic>> dispatch(Object? raw) async {
    BridgeMessage message;
    try {
      message = BridgeMessage.fromRaw(raw);
    } on FormatException catch (error) {
      return BridgeResponse.error(
        id: 'invalid',
        type: 'bridge.error',
        message: error.message,
      );
    }

    final handler = handlers[message.type];
    if (handler == null) {
      return BridgeResponse.error(
        id: message.id,
        type: '${message.type}.error',
        message: 'Unsupported bridge command: ${message.type}',
      );
    }

    try {
      final payload = await handler(message);
      return BridgeResponse.success(
        id: message.id,
        type: '${message.type}.result',
        payload: payload,
      );
    } catch (error) {
      return BridgeResponse.error(
        id: message.id,
        type: '${message.type}.error',
        message: error.toString(),
      );
    }
  }
}

class BridgeResponse {
  static Map<String, dynamic> success({
    required String id,
    required String type,
    Map<String, dynamic> payload = const {},
  }) =>
      {
        'id': id,
        'ok': true,
        'type': type,
        'payload': payload,
      };

  static Map<String, dynamic> error({
    required String id,
    required String type,
    required String message,
  }) =>
      {
        'id': id,
        'ok': false,
        'type': type,
        'error': {
          'message': message,
        },
      };
}

Map<String, dynamic> _stringKeyMap(Object? value) {
  if (value == null) {
    return <String, dynamic>{};
  }
  final map = value as Map;
  return map.map((key, value) => MapEntry(key.toString(), value));
}
