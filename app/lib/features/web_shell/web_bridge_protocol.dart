import 'dart:async';
import 'dart:convert';

import '../../core/logging/tomato_logger.dart';

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
      final Map map => map,
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
      TomatoLogger.warn(
        category: 'bridge',
        event: 'command.malformed',
        message: error.message,
        data: {'rawType': raw.runtimeType.toString()},
      );
      return BridgeResponse.error(
        id: 'invalid',
        type: 'bridge.error',
        message: error.message,
      );
    }

    final handler = handlers[message.type];
    if (handler == null) {
      TomatoLogger.warn(
        category: 'bridge',
        event: 'command.unsupported',
        flowId: message.id,
        status: 'unsupported',
        data: {'type': message.type},
      );
      return BridgeResponse.error(
        id: message.id,
        type: '${message.type}.error',
        message: 'Unsupported bridge command: ${message.type}',
      );
    }

    final stopwatch = Stopwatch()..start();
    TomatoLogger.info(
      category: 'bridge',
      event: 'command.start',
      flowId: message.id,
      status: 'start',
      data: {
        'type': message.type,
        'payload': _payloadSummary(message.payload),
      },
    );
    try {
      final payload = await handler(message);
      stopwatch.stop();
      TomatoLogger.info(
        category: 'bridge',
        event: 'command.end',
        flowId: message.id,
        status: 'success',
        durationMs: stopwatch.elapsedMilliseconds,
        data: {
          'type': message.type,
          'resultKeys': payload.keys.take(30).toList(growable: false),
        },
      );
      return BridgeResponse.success(
        id: message.id,
        type: '${message.type}.result',
        payload: payload,
      );
    } catch (error, stackTrace) {
      stopwatch.stop();
      TomatoLogger.error(
        category: 'bridge',
        event: 'command.error',
        flowId: message.id,
        status: 'error',
        durationMs: stopwatch.elapsedMilliseconds,
        data: {'type': message.type},
        error: error,
        stackTrace: stackTrace,
      );
      final resumeData = error is ArticleCreateResumeException
          ? error.toBridgeData()
          : null;
      return BridgeResponse.error(
        id: message.id,
        type: '${message.type}.error',
        message: error.toString(),
        data: resumeData,
      );
    }
  }
}

/// Raised when article body is already saved but a later create step failed.
/// Bridge returns [toBridgeData] so the Web UI can resume without full redo.
class ArticleCreateResumeException implements Exception {
  const ArticleCreateResumeException({
    required this.message,
    required this.resumeArticleId,
    required this.failedPhase,
    this.article,
  });

  final String message;
  final int resumeArticleId;
  final String failedPhase;
  final Map<String, dynamic>? article;

  Map<String, dynamic> toBridgeData() => {
        'resumeArticleId': resumeArticleId,
        'failedPhase': failedPhase,
        if (article != null) 'article': article,
      };

  @override
  String toString() => message;
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
    Map<String, dynamic>? data,
  }) =>
      {
        'id': id,
        'ok': false,
        'type': type,
        'error': {
          'message': message,
          if (data != null && data.isNotEmpty) 'data': data,
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

Map<String, dynamic> _payloadSummary(Map<String, dynamic> payload) {
  return payload.map(
    (key, value) => MapEntry(key, _valueSummary(value)),
  );
}

Object? _valueSummary(Object? value) {
  if (value == null || value is num || value is bool) {
    return value;
  }
  if (value is String) {
    return {
      'type': 'string',
      'length': value.length,
    };
  }
  if (value is List) {
    return {
      'type': 'list',
      'length': value.length,
    };
  }
  if (value is Map) {
    return {
      'type': 'object',
      'keys': value.keys.map((key) => key.toString()).take(30).toList(),
    };
  }
  return {'type': value.runtimeType.toString()};
}
