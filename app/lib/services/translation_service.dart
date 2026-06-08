import 'dart:async';

import 'package:flutter/foundation.dart';

import 'database_service.dart';
import 'practice_text_service.dart';

class TranslationService {
  static final Map<String, Future<String>> _cache = {};

  @visibleForTesting
  static void clearCacheForTest() {
    _cache.clear();
  }

  @visibleForTesting
  static void setCacheEntryForTest(String memoryKey, Future<String> value) {
    _cache[memoryKey] = value;
  }

  @visibleForTesting
  static String cacheMemoryKeyForTest(
    String text, {
    int? articleId,
    int? sentenceIndex,
    String cachePurpose = 'translate_to_chinese',
  }) {
    final key = _cacheKey(text);
    return '$cachePurpose:${articleId ?? 'global'}:${sentenceIndex ?? 'any'}:$key';
  }

  static Future<String> toChinese(
    String text, {
    int? articleId,
    int? sentenceIndex,
    String cachePurpose = 'translate_to_chinese',
  }) {
    final key = _cacheKey(text);
    if (key.isEmpty) {
      return Future.value('');
    }
    final memoryKey = cacheMemoryKeyForTest(
      text,
      articleId: articleId,
      sentenceIndex: sentenceIndex,
      cachePurpose: cachePurpose,
    );
    return _cache.putIfAbsent(
      memoryKey,
      () => _translate(
        key,
        articleId: articleId,
        sentenceIndex: sentenceIndex,
        cachePurpose: cachePurpose,
      ),
    ).then((translated) {
      if (translated == '中文翻译暂不可用。') {
        _cache.remove(memoryKey);
      }
      return translated;
    });
  }

  static Future<String> _translate(
    String text, {
    int? articleId,
    int? sentenceIndex,
    required String cachePurpose,
  }) async {
    try {
      if (articleId != null && sentenceIndex != null) {
        final imported = await DatabaseService.getArticleSentenceTranslation(
          articleId,
          sentenceIndex,
          text,
        );
        if (imported != null && imported.trim().isNotEmpty) {
          return imported.trim();
        }
      }

      final reply = await PracticeTextService.translateToChinese(
        text: text,
        articleId: articleId,
        cachePurpose: cachePurpose,
      ).timeout(const Duration(seconds: 8));
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
