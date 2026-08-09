import 'package:flutter/services.dart';

class UdpipeParserV3 {
  const UdpipeParserV3();

  static const MethodChannel _channel =
      MethodChannel('tomato_english/udpipe_parser_v3');

  Future<String> parse({
    required String text,
    required String modelPath,
    bool presegmented = false,
  }) async {
    if (text.trim().isEmpty) {
      throw const FormatException('UDPipe parse text must not be empty');
    }
    if (modelPath.trim().isEmpty) {
      throw const FormatException('UDPipe model path must not be empty');
    }
    final response = await _channel.invokeMethod<String>('parse', {
      'text': text,
      'modelPath': modelPath,
      'presegmented': presegmented,
    });
    if (response == null || response.trim().isEmpty) {
      throw PlatformException(
        code: 'empty_result',
        message: 'UDPipe returned an empty result',
      );
    }
    return response;
  }
}
