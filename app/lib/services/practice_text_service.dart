import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'text_generation_service.dart';

class PracticeWordLookup {
  const PracticeWordLookup({
    required this.word,
    required this.phonetic,
    required this.meaning,
    required this.sentenceMeaning,
    required this.source,
  });

  final String word;
  final String phonetic;
  final String meaning;
  final String sentenceMeaning;
  final TextGenerationReplySource source;
}

class PracticeSentenceTranslationBatch {
  const PracticeSentenceTranslationBatch({
    required this.translationsByIndex,
    required this.source,
  });

  final Map<int, String> translationsByIndex;
  final TextGenerationReplySource source;
}

class PracticeTextService {
  // Stability budget per Ark request; long source text is chunked, not cut.
  static const _englishPracticePromptChunkTarget = 8000;
  static const _titlePromptInputLimit = 1600;
  static const _sentenceTranslationCachePurpose =
      'article_sentence_translation_batch_v1';

  static Future<TextGenerationReply> translateToChinese({
    required String text,
    int? articleId,
    String cachePurpose = 'translate_to_chinese',
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const TextGenerationReply(
        text: '',
        source: TextGenerationReplySource.remote,
      );
    }
    if (RegExp(r'[\u3400-\u9FFF]').hasMatch(trimmed) &&
        !RegExp(r'[A-Za-z]').hasMatch(trimmed)) {
      return TextGenerationReply(
        text: trimmed,
        source: TextGenerationReplySource.remote,
      );
    }

    final turns = <TextGenerationTurn>[
      const TextGenerationTurn(
        role: 'system',
        content:
            'You are a precise English-to-Chinese translation engine. Return only natural Simplified Chinese. Do not explain.',
      ),
      TextGenerationTurn(
        role: 'user',
        content:
            'Translate this English learning text into natural Simplified Chinese. Keep names readable and return only the translation:\n\n$trimmed',
      ),
    ];

    final reply = await TextGenerationService.generateStrict(
      turns: turns,
      cachePurpose: cachePurpose,
      articleId: articleId,
      maxTokens: 512,
      skipCacheRead: true,
      skipCacheWrite: true,
    );
    final translated = _cleanTranslation(reply.text);
    if (translated.isEmpty) {
      throw const TextGenerationException('文本提交处理失败：AI 未返回有效中文翻译，请重试。');
    }
    return TextGenerationReply(
      text: translated,
      source: reply.source,
      errorMessage: reply.errorMessage,
    );
  }

  static Future<PracticeSentenceTranslationBatch>
      translateSentencesToChineseStrict({
    required Map<int, String> sentencesByIndex,
    int? articleId,
  }) async {
    final entries = sentencesByIndex.entries
        .map((entry) => MapEntry(entry.key, entry.value.trim()))
        .where((entry) => entry.value.isNotEmpty)
        .toList(growable: false)
      ..sort((a, b) => a.key.compareTo(b.key));
    if (entries.isEmpty) {
      return const PracticeSentenceTranslationBatch(
        translationsByIndex: {},
        source: TextGenerationReplySource.remote,
      );
    }

    // Article creation deliberately uses one strict remote task for sentence
    // translations: it must block save so safety failures can be edited, but it
    // must not fan out into one API call per sentence again.
    final reply = await TextGenerationService.generateStrict(
      turns: _sentenceTranslationPromptTurns(entries),
      cachePurpose: _sentenceTranslationCachePurpose,
      articleId: articleId,
      maxTokens: _sentenceTranslationMaxTokens(entries.length),
      receiveTimeout: _sentenceTranslationReceiveTimeout(entries.length),
      jsonResponse: true,
      skipCacheRead: true,
      skipCacheWrite: true,
    );
    final translations = _parseSentenceTranslationBatch(reply.text, entries);
    return PracticeSentenceTranslationBatch(
      translationsByIndex: translations,
      source: reply.source,
    );
  }

  static Future<TextGenerationReply> translateToEnglishForPractice({
    required String content,
    int? articleId,
  }) =>
      translateToEnglishForPracticeStrict(
        content: content,
        articleId: articleId,
      );

  static Future<TextGenerationReply> translateToEnglishForPracticeStrict({
    required String content,
    int? articleId,
  }) async {
    final trimmed = _normalizeEnglishWordJoiners(content.trim());
    if (trimmed.isEmpty) {
      return const TextGenerationReply(
        text: '',
        source: TextGenerationReplySource.remote,
      );
    }
    if (!_containsChineseText(trimmed)) {
      return TextGenerationReply(
        text: _normalizeInWordHyphens(
          trimmed.replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim(),
        ),
        source: TextGenerationReplySource.remote,
      );
    }

    final outputs = <String>[];
    final sources = <TextGenerationReplySource>[];
    for (final chunk in _splitPracticePromptChunks(trimmed)) {
      final prompt = _englishPracticePrompt(chunk);
      final reply = await TextGenerationService.generateStrict(
        turns: prompt.turns,
        cachePurpose: 'translate_to_english_practice',
        articleId: articleId,
        maxTokens: 1600,
        receiveTimeout: const Duration(seconds: 90),
        skipCacheRead: true,
        skipCacheWrite: true,
      );
      final cleaned = _cleanRequiredEnglishPracticeArticle(reply.text);
      outputs.add(cleaned);
      sources.add(reply.source);
    }

    final text = outputs.join('\n\n').trim();
    if (text.isEmpty) {
      throw const TextGenerationException(
        '文本提交处理失败：AI 未返回可保存的英文正文，请重试。',
      );
    }
    return TextGenerationReply(
      text: text,
      source: _combineTextGenerationSources(sources),
    );
  }

  static Future<PracticeWordLookup> lookupWordForLearning({
    required String word,
    required String sentence,
    int? articleId,
  }) async {
    final normalizedWord = _normalizeLookupWord(word);
    if (normalizedWord.isEmpty) {
      throw const FormatException('请选择要查询的英文单词。');
    }

    final normalizedSentence =
        sentence.replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim();
    final turns = <TextGenerationTurn>[
      const TextGenerationTurn(
        role: 'system',
        content:
            'You are a concise English vocabulary helper for Chinese-speaking children. Return only valid compact JSON with keys word, phonetic, meaning, sentenceMeaning. Use Simplified Chinese for meaning and sentenceMeaning. Phonetic should be IPA when possible.',
      ),
      TextGenerationTurn(
        role: 'user',
        content:
            'Word: $normalizedWord\nSentence: $normalizedSentence\nReturn JSON only. meaning is the common Chinese meanings. sentenceMeaning is the meaning of this word in this exact sentence.',
      ),
    ];

    final reply = await TextGenerationService.generateStrict(
      turns: turns,
      cachePurpose: 'word_lookup',
      articleId: articleId,
      maxTokens: 256,
      jsonResponse: true,
      skipCacheRead: true,
      skipCacheWrite: true,
    );
    final parsed = _parseRequiredWordLookupJson(reply.text);
    return PracticeWordLookup(
      word: parsed['word'] ?? normalizedWord,
      phonetic: parsed['phonetic']!,
      meaning: parsed['meaning']!,
      sentenceMeaning: parsed['sentenceMeaning']!,
      source: reply.source,
    );
  }

  static Future<TextGenerationReply> suggestArticleTitle({
    required String content,
    int? articleId,
  }) async {
    final trimmed = content.replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim();
    if (trimmed.isEmpty) {
      throw const FormatException('文章内容为空，无法生成标题。');
    }

    final turns = _articleTitlePrompt(trimmed);
    final reply = await TextGenerationService.generateStrict(
      turns: turns,
      cachePurpose: 'suggest_article_title',
      articleId: articleId,
      maxTokens: 64,
      skipCacheRead: true,
      skipCacheWrite: true,
    );
    return TextGenerationReply(
      text: _cleanRequiredArticleTitle(reply.text),
      source: reply.source,
      errorMessage: reply.errorMessage,
    );
  }

  static List<TextGenerationTurn> _articleTitlePrompt(String text) {
    final excerpt = text.length > _titlePromptInputLimit
        ? text.substring(0, _titlePromptInputLimit)
        : text;
    return <TextGenerationTurn>[
      const TextGenerationTurn(
        role: 'system',
        content:
            "You create short English titles for children English practice tasks. Return only the title, 2 to 5 words, title case. Keep necessary apostrophes such as Mother's. Do not add trailing punctuation.",
      ),
      TextGenerationTurn(
        role: 'user',
        content:
            'Create one short English title for this article. Return only the title:\n\n$excerpt',
      ),
    ];
  }

  static List<TextGenerationTurn> _sentenceTranslationPromptTurns(
    List<MapEntry<int, String>> entries,
  ) {
    final payload = jsonEncode({
      'sentences': [
        for (final entry in entries)
          {
            'index': entry.key,
            'english': entry.value,
          },
      ],
    });
    return <TextGenerationTurn>[
      const TextGenerationTurn(
        role: 'system',
        content:
            'You are a precise English-to-Chinese translation engine. Return only valid compact JSON shaped as {"translations":[{"index":0,"chinese":"..."}]}. Preserve every input index exactly once. Use natural Simplified Chinese. Do not explain.',
      ),
      TextGenerationTurn(
        role: 'user',
        content:
            'Translate each English sentence into Simplified Chinese for subtitle display. Keep the same indexes, do not omit or merge items, and return JSON only.\n\n$payload',
      ),
    ];
  }

  static int _sentenceTranslationMaxTokens(int sentenceCount) {
    final raw = 768 + sentenceCount * 96;
    return raw.clamp(1024, 12000).toInt();
  }

  static Duration _sentenceTranslationReceiveTimeout(int sentenceCount) {
    final rawSeconds = 90 + sentenceCount * 2;
    return Duration(seconds: rawSeconds.clamp(90, 240).toInt());
  }

  static Map<int, String> _parseSentenceTranslationBatch(
    String text,
    List<MapEntry<int, String>> expectedEntries,
  ) {
    final decoded = _decodeJsonValue(text);
    final translations = <int, String>{};

    void addTranslation(Object? rawIndex, Object? rawValue) {
      final index = _jsonInt(rawIndex);
      if (index == null) {
        return;
      }
      final value = rawValue is Map
          ? rawValue['chinese'] ??
              rawValue['chineseText'] ??
              rawValue['translation']
          : rawValue;
      final chinese = _cleanTranslation(value?.toString() ?? '');
      if (chinese.isEmpty || chinese.startsWith('中文翻译暂不可用')) {
        return;
      }
      translations[index] = chinese;
    }

    void parseList(Object? value) {
      if (value is! List) {
        return;
      }
      for (final item in value) {
        if (item is Map) {
          addTranslation(
            item['index'] ?? item['sentenceIndex'] ?? item['id'],
            item['chinese'] ?? item['chineseText'] ?? item['translation'],
          );
        }
      }
    }

    void parseMap(Object? value) {
      if (value is! Map) {
        return;
      }
      for (final entry in value.entries) {
        addTranslation(entry.key, entry.value);
      }
    }

    if (decoded is List) {
      parseList(decoded);
    } else if (decoded is Map) {
      final body =
          decoded['translations'] ?? decoded['sentences'] ?? decoded['items'];
      parseList(body);
      parseMap(body);
      if (translations.isEmpty) {
        parseMap(decoded);
      }
    }

    final missing = <int>[
      for (final entry in expectedEntries)
        if (!translations.containsKey(entry.key)) entry.key,
    ];
    if (missing.isNotEmpty) {
      throw TextGenerationException(
        '文本提交处理失败：AI 未返回完整中文对照（缺少第 ${missing.first + 1} 句），请重试。',
      );
    }
    return {
      for (final entry in expectedEntries) entry.key: translations[entry.key]!,
    };
  }

  static Object? _decodeJsonValue(String text) {
    final raw = text.trim();
    if (raw.isEmpty) {
      return null;
    }
    try {
      return jsonDecode(raw);
    } catch (_) {
      // Continue with a tolerant extraction below.
    }

    Object? trySlice(int start, int end) {
      if (start < 0 || end <= start) {
        return null;
      }
      try {
        return jsonDecode(raw.substring(start, end + 1));
      } catch (_) {
        return null;
      }
    }

    final object = trySlice(raw.indexOf('{'), raw.lastIndexOf('}'));
    if (object != null) {
      return object;
    }
    return trySlice(raw.indexOf('['), raw.lastIndexOf(']'));
  }

  static int? _jsonInt(Object? value) {
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim());
    }
    return null;
  }

  static ({List<TextGenerationTurn> turns}) _englishPracticePrompt(
    String text,
  ) {
    final trimmed = _normalizeEnglishWordJoiners(text.trim());

    if (_containsEnglishText(trimmed)) {
      return (
        turns: <TextGenerationTurn>[
          const TextGenerationTurn(
            role: 'system',
            content:
                'You prepare English practice story prose from mixed learning material. Keep only the story content in original order. If the story prose is already English, preserve the original English prose and do not rewrite it. If the story content is Chinese and no English story prose is present, translate only that story content into natural English. Remove lesson introductions, headings, dates, authors, explanations, expansion notes, culture cards, vocabulary lists, phonetics, examples, Chinese translations, metadata, and teacher instructions. Return only the final English story prose.',
          ),
          TextGenerationTurn(
            role: 'user',
            content:
                'Extract the story from this mixed learning text. Keep original English story prose when present; if the story is only in Chinese, translate it to English. Remove all non-story material and return only English story prose with normal spacing and punctuation:\n\n$trimmed',
          ),
        ],
      );
    }

    return (
      turns: <TextGenerationTurn>[
        const TextGenerationTurn(
          role: 'system',
          content:
              'You translate Chinese story text into clear natural English for children speaking practice. Return only the English article. Use short, speakable sentences. Do not explain.',
        ),
        TextGenerationTurn(
          role: 'user',
          content:
              'Translate this Chinese learning story into English practice text. Keep the meaning, use natural English, and return only English:\n\n$trimmed',
        ),
      ],
    );
  }

  @visibleForTesting
  static ({List<TextGenerationTurn> turns}) englishPracticePromptForTest(
    String text,
  ) =>
      _englishPracticePrompt(text);

  static List<String> _splitPracticePromptChunks(String text) {
    final trimmed = text.trim();
    if (trimmed.length <= _englishPracticePromptChunkTarget) {
      return [trimmed];
    }

    final paragraphs = trimmed
        .split(RegExp(r'\n\s*\n+'))
        .map((paragraph) => paragraph.trim())
        .where((paragraph) => paragraph.isNotEmpty)
        .toList(growable: false);
    if (paragraphs.length <= 1) {
      return _splitOversizedText(trimmed);
    }

    final chunks = <String>[];
    final buffer = StringBuffer();
    for (final paragraph in paragraphs) {
      if (paragraph.length > _englishPracticePromptChunkTarget) {
        if (buffer.isNotEmpty) {
          chunks.add(buffer.toString().trim());
          buffer.clear();
        }
        chunks.addAll(_splitOversizedText(paragraph));
        continue;
      }

      final separatorLength = buffer.isEmpty ? 0 : 2;
      if (buffer.length + separatorLength + paragraph.length >
          _englishPracticePromptChunkTarget) {
        chunks.add(buffer.toString().trim());
        buffer.clear();
      }
      if (buffer.isNotEmpty) {
        buffer.write('\n\n');
      }
      buffer.write(paragraph);
    }
    if (buffer.isNotEmpty) {
      chunks.add(buffer.toString().trim());
    }
    return chunks;
  }

  static List<String> _splitOversizedText(String text) {
    final chunks = <String>[];
    for (var start = 0; start < text.length;) {
      var end = (start + _englishPracticePromptChunkTarget)
          .clamp(
            0,
            text.length,
          )
          .toInt();
      if (end < text.length) {
        final safeBreak = text.lastIndexOf(RegExp(r'[。！？.!?；;]\s*'), end);
        if (safeBreak > start + (_englishPracticePromptChunkTarget ~/ 2)) {
          end = safeBreak + 1;
        }
      }
      chunks.add(text.substring(start, end).trim());
      start = end;
    }
    return chunks.where((chunk) => chunk.isNotEmpty).toList(growable: false);
  }

  static TextGenerationReplySource _combineTextGenerationSources(
    List<TextGenerationReplySource> sources,
  ) {
    if (sources.isEmpty) {
      throw const TextGenerationException(
        '文本提交处理失败：AI 未返回可保存的英文正文，请重试。',
      );
    }
    if (sources.contains(TextGenerationReplySource.remote)) {
      return TextGenerationReplySource.remote;
    }
    if (sources.contains(TextGenerationReplySource.cached)) {
      return TextGenerationReplySource.cached;
    }
    if (sources.contains(TextGenerationReplySource.stored)) {
      return TextGenerationReplySource.stored;
    }
    throw StateError('Unexpected non-strict text generation source.');
  }

  static String _extractEnglishStoryText(String text) {
    final lines = text
        .replaceAll(RegExp(r'[“”]'), '"')
        .replaceAll(RegExp(r'[‘’]'), "'")
        .split(RegExp(r'[\r\n]+|[。！？；;]+'));
    final kept = <String>[];
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty ||
          RegExp(
            r'^(title|heading|chapter|中文|翻译|译文|词汇|单词|注释|讲解|解析|vocabulary|note|notes|summary)\s*[:：]',
            caseSensitive: false,
          ).hasMatch(line)) {
        continue;
      }
      final englishWords =
          RegExp(r"[A-Za-z][A-Za-z'\-]*").allMatches(line).length;
      if (englishWords < 3) {
        continue;
      }
      final chineseChars = RegExp(r'[\u3400-\u9FFF]').allMatches(line).length;
      if (chineseChars > englishWords * 2) {
        continue;
      }
      final englishLine = line
          .replaceAll(RegExp(r'[\u3400-\u9FFF]+'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (englishLine.isNotEmpty) {
        kept.add(englishLine);
      }
    }

    if (kept.isNotEmpty) {
      return _normalizeInWordHyphens(kept.join(' '));
    }

    final stripped = text
        .replaceAll(RegExp(r'[\u3400-\u9FFF]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return _normalizeInWordHyphens(stripped);
  }

  static Map<String, String> _parseRequiredWordLookupJson(String text) {
    final trimmed = text.trim();
    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const TextGenerationException('单词查询失败：AI 未返回有效单词解释，请重试。');
    }

    try {
      final decoded = jsonDecode(trimmed.substring(start, end + 1));
      if (decoded is! Map) {
        throw const FormatException('word lookup response is not an object');
      }
      final parsed = {
        'word': _jsonString(decoded['word']),
        'phonetic': _jsonString(decoded['phonetic']),
        'meaning': _jsonString(decoded['meaning']),
        'sentenceMeaning': _jsonString(decoded['sentenceMeaning']),
      };
      if (parsed.values.any((value) => value.trim().isEmpty)) {
        throw const FormatException('word lookup response has empty fields');
      }
      return parsed;
    } catch (error) {
      if (error is TextGenerationException) {
        rethrow;
      }
      throw const TextGenerationException('单词查询失败：AI 未返回有效单词解释，请重试。');
    }
  }

  static String _jsonString(Object? value) {
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
    return '';
  }

  static String _cleanTranslation(String text) {
    var cleaned = text.trim();
    cleaned = cleaned.replaceAll(
      RegExp(r'^(中文翻译|翻译|译文)\s*[:：]\s*'),
      '',
    );
    cleaned = cleaned.replaceAll(RegExp(r'^["“]|["”]$'), '').trim();
    return cleaned;
  }

  static String _cleanEnglishPracticeArticle(String text) {
    var cleaned = text.trim();
    cleaned = cleaned.replaceAll(
      RegExp(
        r'^(english article|english text|translation|译文|英文)\s*[:：]\s*',
        caseSensitive: false,
      ),
      '',
    );
    cleaned = cleaned.replaceAll(RegExp(r'[‘’]'), "'");
    cleaned = cleaned.replaceAll(RegExp(r'^["“]|["”]$'), '').trim();
    cleaned = _normalizeInWordHyphens(cleaned);
    if (_containsChineseText(cleaned) && _containsEnglishText(cleaned)) {
      cleaned = _extractEnglishStoryText(cleaned);
    }
    return cleaned;
  }

  static String _cleanRequiredEnglishPracticeArticle(String text) {
    final cleaned = _cleanEnglishPracticeArticle(text).trim();
    if (cleaned.isEmpty ||
        (_containsChineseText(cleaned) && !_containsEnglishText(cleaned))) {
      throw const TextGenerationException(
        '文本提交处理失败：AI 未返回可保存的英文正文，请重试。',
      );
    }
    return cleaned;
  }

  static String _cleanRequiredArticleTitle(String text) {
    var cleaned = text
        .split(RegExp(r'[\r\n]'))
        .first
        .replaceAll(RegExp(r'["“”]'), '')
        .replaceAll(RegExp(r'[‘’]'), "'")
        .replaceFirst(
          RegExp(r'^(title|标题)\s*[:：]\s*', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'[.!?。！？]+$'), '')
        .trim();
    cleaned = _normalizeEnglishWordJoiners(cleaned);
    if (cleaned.isEmpty) {
      throw const TextGenerationException('标题生成失败：AI 未返回有效标题，请重试。');
    }

    final words = cleaned.split(RegExp(r'\s+')).where((word) {
      return RegExp(r'[A-Za-z]').hasMatch(word);
    }).toList(growable: false);
    if (words.isEmpty) {
      throw const TextGenerationException('标题生成失败：AI 未返回有效英文标题，请重试。');
    }

    cleaned = words.take(5).map(_titleCaseWord).join(' ');
    cleaned = _restoreCommonTitlePossessives(cleaned);
    if (cleaned.isEmpty) {
      throw const TextGenerationException('标题生成失败：AI 未返回有效标题，请重试。');
    }
    return cleaned;
  }

  static String _normalizeInWordHyphens(String text) => text.replaceAllMapped(
        RegExp(r'([A-Za-z])\s*-\s*([A-Za-z])'),
        (match) => '${match.group(1)!}-${match.group(2)!}',
      );

  static String _normalizeEnglishWordJoiners(String text) =>
      _normalizeInWordHyphens(text).replaceAllMapped(
        RegExp(r"([A-Za-z])\s*'\s*([A-Za-z])"),
        (match) => "${match.group(1)!}'${match.group(2)!}",
      );

  static bool _containsChineseText(String text) =>
      RegExp(r'[\u3400-\u9FFF]').hasMatch(text);

  static bool _containsEnglishText(String text) =>
      RegExp(r'[A-Za-z]').hasMatch(text);

  static String _normalizeLookupWord(String word) => word
      .replaceAll(RegExp(r'[‘’]'), "'")
      .replaceAll(RegExp(r'^[^A-Za-z]+|[^A-Za-z]+$'), '')
      .trim();

  static String _restoreCommonTitlePossessives(String title) {
    return title
        .replaceAll(RegExp(r"\bMothers\b"), "Mother's")
        .replaceAll(RegExp(r"\bFathers\b"), "Father's")
        .replaceAll(RegExp(r"\bChildrens\b"), "Children's")
        .replaceAll(RegExp(r"\bPeoples\b"), "People's");
  }

  static String _titleCaseWord(String word) {
    final titleWord = word
        .replaceAll(RegExp(r'[‘’]'), "'")
        .replaceAll(RegExp(r"[^A-Za-z'\-]"), '');
    if (titleWord.isEmpty) {
      return word;
    }
    return titleWord.split('-').map(_titleCaseHyphenPart).join('-');
  }

  static String _titleCaseHyphenPart(String part) {
    final pieces = part.split("'");
    if (pieces.isEmpty) {
      return part;
    }

    final first = _capitalizeAsciiWord(pieces.first);
    if (pieces.length == 1) {
      return first;
    }

    final suffixes = pieces.skip(1).map((piece) => piece.toLowerCase());
    return ([first, ...suffixes]).join("'");
  }

  static String _capitalizeAsciiWord(String word) {
    if (word.isEmpty) {
      return word;
    }
    if (word.length == 1) {
      return word.toUpperCase();
    }
    return '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}';
  }
}
