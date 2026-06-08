import 'dart:async';

import 'package:flutter/foundation.dart';

import 'database_service.dart';
import 'practice_text_service.dart';

class TranslationService {
  static final Map<String, Future<String>> _cache = {};

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
    final memoryKey =
        '$cachePurpose:${articleId ?? 'global'}:${sentenceIndex ?? 'any'}:$key';
    return _cache.putIfAbsent(
      memoryKey,
      () => _translate(
        key,
        articleId: articleId,
        sentenceIndex: sentenceIndex,
        cachePurpose: cachePurpose,
      ),
    );
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
