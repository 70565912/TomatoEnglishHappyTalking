import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/config/app_config.dart';

enum RealtimeReplySource {
  remote,
  mockNoKey,
  mockOnError,
}

class RealtimeChatTurn {
  const RealtimeChatTurn({required this.role, required this.content});

  final String role;
  final String content;

  Map<String, String> toJson() => {
    'role': role,
    'content': content,
  };
}

class RealtimeReply {
  const RealtimeReply({
    required this.text,
    required this.source,
    this.errorMessage,
  });

  final String text;
  final RealtimeReplySource source;
  final String? errorMessage;
}

class RealtimeVoiceService {
  static const _audioTraceEnabled = bool.fromEnvironment(
    'TOMATO_AUDIO_TRACE',
    defaultValue: false,
  );

  // Realtime dialogue websocket endpoint (official API access document).
  static const _endpoint =
      'wss://openspeech.bytedance.com/api/v3/realtime/dialogue';

  static const _resourceId = 'volc.speech.dialog';
  static const _fixedAppKey = 'PlgvMymc7f3tQnJ6';
  static const _modelVersion = '1.2.1.1';

  static const _protocolVersionAndHeader = 0x11;
  static const _reservedByte = 0x00;

  static const _messageTypeFullClientRequest = 0x1;
  static const _messageTypeFullServerResponse = 0x9;
  static const _messageTypeError = 0xF;

  static const _serializationJson = 0x1;

  static const _compressionNone = 0x0;
  static const _compressionGzip = 0x1;

  static const String _systemPrompt =
      'You are a friendly and encouraging English teacher named Emma. '
      'Ask one question at a time and keep each response concise.';

  // Client event IDs
  static const _eventStartConnection = 1;
  static const _eventFinishConnection = 2;
  static const _eventStartSession = 100;
  static const _eventFinishSession = 102;
  static const _eventChatTextQuery = 501;

  // Server event IDs
  static const _eventConnectionStarted = 50;
  static const _eventConnectionFailed = 51;
  static const _eventSessionStarted = 150;
  static const _eventSessionFinished = 152;
  static const _eventSessionFailed = 153;
  static const _eventTtsSentenceStart = 350;
  static const _eventChatResponse = 550;
  static const _eventChatTextQueryConfirmed = 553;
  static const _eventChatEnded = 559;
  static const _eventDialogCommonError = 599;

  static Future<RealtimeReply> startSession({
    required String articleContent,
    String articleTitle = '',
  }) async {
    final turns = <RealtimeChatTurn>[
      const RealtimeChatTurn(role: 'system', content: _systemPrompt),
      RealtimeChatTurn(
        role: 'user',
        content:
            'Article title: $articleTitle\n\nArticle:\n$articleContent\n\nPlease greet me and ask your first question.',
      ),
    ];

    return _query(turns);
  }

  static Future<RealtimeReply> reply({
    required List<RealtimeChatTurn> history,
    required String userMessage,
    required int questionCount,
  }) async {
    final turns = <RealtimeChatTurn>[
      ...history,
      RealtimeChatTurn(role: 'user', content: userMessage),
      if (questionCount >= 8)
        const RealtimeChatTurn(
          role: 'user',
          content:
              'Please summarize what we discussed and give me encouragement to keep practicing.',
        ),
    ];

    return _query(turns);
  }

  static Future<RealtimeReply> _query(List<RealtimeChatTurn> turns) async {
    final appId = await AppConfig.volcRealtimeAppId;
    final accessKey = await AppConfig.volcRealtimeApiKey;
    if (accessKey.trim().isEmpty) {
      return RealtimeReply(
        text: _mockResponse(),
        source: RealtimeReplySource.mockNoKey,
        errorMessage: 'volc_realtime_api_key is empty',
      );
    }

    WebSocket? socket;
    StreamSubscription<dynamic>? subscription;
    final connectId = _newConnectId();
    final sessionId = _newSessionId();
    final textQuery = _buildTextQuery(turns);
    try {
      socket = await _connectSocket(
        appId: appId,
        accessKey: accessKey,
        connectId: connectId,
      );
      _trace('connect success connectId=$connectId sessionId=$sessionId');

      final completer = Completer<String>();
      final connectionReady = Completer<void>();
      final sessionReady = Completer<void>();
      final textBuffer = StringBuffer();
      String? lastDelta;
      int? lastEventId;
      String? lastPayloadSummary;
      final eventTrail = <String>[];
      subscription = socket.listen((dynamic event) {
        final packet = _parseServerPacket(event);
        if (packet == null) {
          return;
        }

        if (packet.messageType == _messageTypeError && !completer.isCompleted) {
          completer.completeError(
            FormatException(packet.errorMessage ?? 'Realtime protocol error'),
          );
          return;
        }

        final eventId = packet.eventId;
        lastEventId = eventId;
        lastPayloadSummary = _summarizePayload(packet.payloadMap);
        if (eventId != null) {
          eventTrail.add('$eventId:${lastPayloadSummary ?? '{}'}');
          if (eventTrail.length > 8) {
            eventTrail.removeAt(0);
          }
        }
        _trace(
          'packet event=$eventId messageType=${packet.messageType} flags=${packet.flags} bytes=${packet.payloadBytes?.length ?? 0}',
        );

        if (_isFailureEvent(eventId) && !completer.isCompleted) {
          completer.completeError(
            FormatException(_extractError(packet.payloadMap) ?? 'Realtime session failed'),
          );
          return;
        }

        if (eventId == _eventConnectionStarted ||
            eventId == _eventSessionStarted ||
            eventId == _eventChatTextQueryConfirmed) {
          if (eventId == _eventConnectionStarted && !connectionReady.isCompleted) {
            connectionReady.complete();
          }
          if (eventId == _eventSessionStarted && !sessionReady.isCompleted) {
            sessionReady.complete();
          }
          return;
        }

        final delta = _extractTextDelta(packet.payloadMap, eventId);
        if (delta != null && delta.trim().isNotEmpty && delta != lastDelta) {
          textBuffer.write(delta);
          lastDelta = delta;
        }

        if (_isInterruptEvent(eventId) && !completer.isCompleted) {
          completer.complete(textBuffer.toString().trim());
          return;
        }

        if (_isTerminalEvent(eventId) && !completer.isCompleted) {
          completer.complete(textBuffer.toString().trim());
        }
      }, onDone: () {
        if (!connectionReady.isCompleted) {
          connectionReady.completeError(
            const FormatException('Realtime connection closed before ConnectionStarted'),
          );
        }
        if (!sessionReady.isCompleted) {
          sessionReady.completeError(
            const FormatException('Realtime connection closed before SessionStarted'),
          );
        }
        if (!completer.isCompleted) {
          completer.complete(textBuffer.toString().trim());
        }
      }, onError: (Object error) {
        if (!connectionReady.isCompleted) {
          connectionReady.completeError(error);
        }
        if (!sessionReady.isCompleted) {
          sessionReady.completeError(error);
        }
        if (!completer.isCompleted) {
          completer.completeError(
            FormatException('Realtime connection interrupted: $error'),
          );
        }
      });

      socket.add(
        _buildClientEventFrame(
          eventId: _eventStartConnection,
          payload: const <String, dynamic>{},
        ),
      );
      await connectionReady.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw const FormatException('Realtime connection start timeout'),
      );

      socket.add(
        _buildClientEventFrame(
          eventId: _eventStartSession,
          sessionId: sessionId,
          payload: _buildStartSessionPayload(),
        ),
      );
      await sessionReady.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw const FormatException('Realtime session start timeout'),
      );

      socket.add(
        _buildClientEventFrame(
          eventId: _eventChatTextQuery,
          sessionId: sessionId,
          payload: <String, dynamic>{
            'content': textQuery,
          },
        ),
      );

      try {
        final result = await completer.future.timeout(
          const Duration(seconds: 20),
          onTimeout: () {
            final fallback = textBuffer.toString().trim();
            if (fallback.isNotEmpty) {
              return fallback;
            }
            throw const FormatException('Realtime response timeout');
          },
        );
        if (result.isEmpty) {
          throw FormatException(
            'Realtime response has no text payload (lastEvent=$lastEventId, payload=$lastPayloadSummary, trail=${eventTrail.join(' -> ')})',
          );
        }
        return RealtimeReply(text: result, source: RealtimeReplySource.remote);
      } finally {
        try {
          socket.add(
            _buildClientEventFrame(
              eventId: _eventFinishSession,
              sessionId: sessionId,
              payload: const <String, dynamic>{},
            ),
          );
          socket.add(
            _buildClientEventFrame(
              eventId: _eventFinishConnection,
              payload: const <String, dynamic>{},
            ),
          );
        } catch (_) {
          // Socket may already be closed after a protocol failure.
        }
      }
    } catch (e) {
      _trace('fallback error=$e');
      return RealtimeReply(
        text: _mockResponse(),
        source: RealtimeReplySource.mockOnError,
        errorMessage: e.toString(),
      );
    } finally {
      await subscription?.cancel();
      await socket?.close();
    }
  }

  static Future<WebSocket> _connectSocket({
    required String appId,
    required String accessKey,
    required String connectId,
  }) async {
    WebSocketException? newConsoleError;

    try {
      // New-console compatible mode: API key only.
      _trace('connect try auth=X-Api-Key connectId=$connectId');
      return await WebSocket.connect(
        _endpoint,
        headers: <String, String>{
          'X-Api-Key': accessKey,
          'X-Api-Resource-Id': _resourceId,
          'X-Api-Connect-Id': connectId,
        },
      );
    } on WebSocketException catch (e) {
      newConsoleError = e;
      _trace('connect fail auth=X-Api-Key connectId=$connectId error=$e');
    }

    // Legacy mode requires App ID and fixed App Key.
    if (appId.trim().isEmpty) {
      throw WebSocketException(
        'Realtime connect failed in API-key mode and appId is empty for legacy mode: $newConsoleError',
      );
    }

    _trace('connect try auth=legacy connectId=$connectId');
    return await WebSocket.connect(
      _endpoint,
      headers: <String, String>{
        'X-Api-App-ID': appId,
        'X-Api-Access-Key': accessKey,
        'X-Api-Resource-Id': _resourceId,
        'X-Api-App-Key': _fixedAppKey,
        'X-Api-Connect-Id': connectId,
      },
    );
  }

  static List<int> _buildClientEventFrame({
    required int eventId,
    required Map<String, dynamic> payload,
    String? sessionId,
  }) {
    final payloadBytes = utf8.encode(jsonEncode(payload));
    final bytes = BytesBuilder();
    bytes.addByte(_protocolVersionAndHeader);
    bytes.addByte((_messageTypeFullClientRequest << 4) | 0x4);
    bytes.addByte((_serializationJson << 4) | _compressionNone);
    bytes.addByte(_reservedByte);
    bytes.add(_int32Bytes(eventId));

    if (sessionId != null) {
      final sessionBytes = utf8.encode(sessionId);
      bytes.add(_int32Bytes(sessionBytes.length));
      bytes.add(sessionBytes);
    }

    bytes.add(_int32Bytes(payloadBytes.length));
    bytes.add(payloadBytes);
    return bytes.toBytes();
  }

  static Map<String, dynamic> _buildStartSessionPayload() => <String, dynamic>{
        'dialog': {
          'bot_name': 'Emma',
          'dialog_id': '',
          'system_role': _systemPrompt,
          'extra': {
            'input_mod': 'text',
            'enable_conversation_truncate': true,
            'model': _modelVersion,
          },
        },
      };

  static _RealtimeServerPacket? _parseServerPacket(dynamic event) {
    if (event is String && event.trim().isNotEmpty) {
      return _RealtimeServerPacket(
        messageType: _messageTypeFullServerResponse,
        flags: 0,
        payloadMap: _safeJsonMap(event),
      );
    }

    if (event is! List<int> || event.length < 8) {
      return null;
    }

    final data = Uint8List.fromList(event);
    final messageType = (data[1] >> 4) & 0x0F;
    final flags = data[1] & 0x0F;
    final serialization = (data[2] >> 4) & 0x0F;
    final compression = data[2] & 0x0F;

    var offset = 4;
    int? errorCode;
    if (messageType == _messageTypeError) {
      if (data.length < offset + 4) {
        return null;
      }
      errorCode = _readInt32(data, offset);
      offset += 4;
    }

    int? sequence;
    final sequenceMode = flags & 0x3;
    if (sequenceMode != 0) {
      if (data.length < offset + 4) {
        return null;
      }
      sequence = _readInt32(data, offset);
      offset += 4;
    }

    int? eventId;
    if ((flags & 0x4) != 0) {
      if (data.length < offset + 4) {
        return null;
      }
      eventId = _readInt32(data, offset);
      offset += 4;
    }

    final offsets = _candidatePayloadOffsets(data, offset, eventId);
    if (offsets.isEmpty) {
      return null;
    }

    Map<String, dynamic>? payloadMap;
    List<int>? payload;
    for (final payloadOffset in offsets) {
      final payloadSize = _readInt32(data, payloadOffset);
      final contentOffset = payloadOffset + 4;
      if (payloadSize < 0 || data.length < contentOffset + payloadSize) {
        continue;
      }

      var candidatePayload = data.sublist(contentOffset, contentOffset + payloadSize);
      if (compression == _compressionGzip) {
        candidatePayload = Uint8List.fromList(gzip.decode(candidatePayload));
      }

      Map<String, dynamic>? candidatePayloadMap;
      if (serialization == _serializationJson) {
        candidatePayloadMap = _safeJsonMap(
          utf8.decode(candidatePayload, allowMalformed: true),
        );
      }

      final prefersCandidate = serialization != _serializationJson ||
          candidatePayloadMap != null ||
          offsets.length == 1;
      if (!prefersCandidate) {
        continue;
      }

      payload = candidatePayload;
      payloadMap = candidatePayloadMap;
      break;
    }

    if (payload == null) {
      return null;
    }

    if (messageType == _messageTypeError) {
      return _RealtimeServerPacket(
        messageType: messageType,
        flags: flags,
        eventId: eventId,
        sequence: sequence,
        payloadMap: payloadMap,
        payloadBytes: payload,
        errorMessage: _extractError(payloadMap) ??
            'Realtime protocol error${errorCode != null ? ' (code=$errorCode)' : ''}',
      );
    }

    return _RealtimeServerPacket(
      messageType: messageType,
      flags: flags,
      eventId: eventId,
      sequence: sequence,
      payloadMap: payloadMap,
      payloadBytes: payload,
    );
  }

  static int _skipEventScopedIdIfPresent(
    Uint8List data,
    int offset,
    int? eventId,
  ) {
    if (eventId == null || !_eventMayCarrySessionId(eventId)) {
      return offset;
    }

    if (data.length < offset + 4) {
      return -1;
    }
    final idSize = _readInt32(data, offset);
    if (idSize < 0 || data.length < offset + 4 + idSize) {
      return -1;
    }

    final nextOffset = offset + 4 + idSize;
    return nextOffset <= data.length ? nextOffset : -1;
  }

  static List<int> _candidatePayloadOffsets(
    Uint8List data,
    int offset,
    int? eventId,
  ) {
    final offsets = <int>[];
    if (_hasValidPayloadSize(data, offset)) {
      offsets.add(offset);
    }

    final skippedOffset = _skipEventScopedIdIfPresent(data, offset, eventId);
    if (skippedOffset >= 0 &&
        skippedOffset != offset &&
        _hasValidPayloadSize(data, skippedOffset)) {
      offsets.insert(0, skippedOffset);
    }

    return offsets;
  }

  static bool _hasValidPayloadSize(Uint8List data, int offset) {
    if (data.length < offset + 4) {
      return false;
    }
    final payloadSize = _readInt32(data, offset);
    return payloadSize >= 0 && data.length >= offset + 4 + payloadSize;
  }

  static bool _eventMayCarrySessionId(int eventId) =>
      eventId >= _eventSessionStarted && eventId < 600;

  static bool _isFailureEvent(int? eventId) =>
      eventId == _eventConnectionFailed ||
      eventId == _eventSessionFailed ||
      eventId == _eventDialogCommonError;

  static bool _isInterruptEvent(int? eventId) => eventId == 515;

  static bool _isTerminalEvent(int? eventId) =>
      eventId == _eventChatEnded || eventId == _eventSessionFinished;

  static String? _extractError(Map<String, dynamic>? frame) {
    if (frame == null) {
      return null;
    }

    final payload = frame['payload'];
    if (payload is Map<String, dynamic>) {
      final nested = _extractError(payload);
      if (nested != null) {
        return nested;
      }
    }

    final message = frame['message']?.toString();
    if (message != null && message.trim().isNotEmpty) {
      return message;
    }
    final error = frame['error']?.toString();
    if (error != null && error.trim().isNotEmpty) {
      return error;
    }
    return null;
  }

  static String? _extractTextDelta(
    Map<String, dynamic>? frame,
    int? eventId,
  ) {
    if (frame == null) {
      return null;
    }

    final isTextBearingEvent = eventId == null ||
        eventId == _eventChatResponse ||
        eventId == _eventTtsSentenceStart;
    if (!isTextBearingEvent) {
      return null;
    }

    final payload = frame['payload'];
    if (payload is Map<String, dynamic>) {
      final fromPayload = _extractTextFromMap(payload);
      if (fromPayload != null) {
        return fromPayload;
      }
    }

    return _extractTextFromMap(frame);
  }

  static Map<String, dynamic>? _safeJsonMap(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static int _readInt32(Uint8List data, int offset) {
    final byteData = ByteData.sublistView(data, offset, offset + 4);
    return byteData.getInt32(0, Endian.big);
  }

  static List<int> _int32Bytes(int value) {
    final byteData = ByteData(4)..setInt32(0, value, Endian.big);
    return byteData.buffer.asUint8List();
  }

  static String? _extractTextFromMap(Map<String, dynamic> source) {
    final directText = source['text']?.toString();
    if (directText != null && directText.trim().isNotEmpty) {
      return directText;
    }

    final content = source['content']?.toString();
    if (content != null && content.trim().isNotEmpty) {
      return content;
    }

    final delta = source['delta']?.toString();
    if (delta != null && delta.trim().isNotEmpty) {
      return delta;
    }

    final transcript = source['transcript']?.toString();
    if (transcript != null && transcript.trim().isNotEmpty) {
      return transcript;
    }

    final message = source['message'];
    if (message is Map<String, dynamic>) {
      final nested = _extractTextFromMap(message);
      if (nested != null) {
        return nested;
      }
    }

    return null;
  }

  static String _summarizePayload(Map<String, dynamic>? payload) {
    if (payload == null || payload.isEmpty) {
      return '{}';
    }

    try {
      final json = jsonEncode(payload);
      if (json.length <= 160) {
        return json;
      }
      return '${json.substring(0, 157)}...';
    } catch (_) {
      return payload.keys.join(',');
    }
  }

  static String _buildTextQuery(List<RealtimeChatTurn> turns) {
    final buffer = StringBuffer();
    for (final turn in turns) {
      final role = turn.role.toUpperCase();
      buffer.writeln('[$role] ${turn.content}');
    }
    return buffer.toString().trim();
  }

  static String _newSessionId() {
    final time = DateTime.now().microsecondsSinceEpoch;
    final rand = Random().nextInt(1 << 20);
    return 'session_${time}_$rand';
  }

  static String _newConnectId() {
    final time = DateTime.now().microsecondsSinceEpoch;
    final rand = Random().nextInt(1 << 20);
    return 'conn_${time}_$rand';
  }

  static void _trace(String message) {
    if (!_audioTraceEnabled) {
      return;
    }
    debugPrint('[RealtimeTrace] $message');
  }

  static String _mockResponse() =>
      "That's interesting! What do you think is the most important idea in this article?";
}

class _RealtimeServerPacket {
  const _RealtimeServerPacket({
    required this.messageType,
    required this.flags,
    this.eventId,
    this.sequence,
    this.payloadMap,
    this.payloadBytes,
    this.errorMessage,
  });

  final int messageType;
  final int flags;
  final int? eventId;
  final int? sequence;
  final Map<String, dynamic>? payloadMap;
  final List<int>? payloadBytes;
  final String? errorMessage;
}
