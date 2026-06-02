import 'dart:async';

import 'package:flutter/foundation.dart';

import 'realtime_voice_service.dart';

class TranslationService {
  static final Map<String, Future<String>> _cache = {};

  static Future<String> toChinese(String text) {
    final key = _cacheKey(text);
    if (key.isEmpty) {
      return Future.value('');
    }
    return _cache.putIfAbsent(key, () => _translate(key));
  }

  static Future<String> _translate(String text) async {
    try {
      final reply = await RealtimeVoiceService.translateToChinese(text: text)
          .timeout(const Duration(seconds: 8));
      final translated = reply.text.trim();
      if (translated.isEmpty) {
        return '中文翻译暂不可用。';
      }
      return translated;
    } on TimeoutException catch (error) {
      debugPrint('[TranslationService] translate timeout: $error');
      return '中文翻译暂不可用。';
    } catch (error) {
      debugPrint('[TranslationService] translate failed: $error');
      return '中文翻译暂不可用。';
    }
  }

  static String _cacheKey(String text) =>
      text.replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim();
}
