import 'dart:convert';

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

class PracticeTextService {
  // Stability budget per Ark request; long source text is chunked, not cut.
  static const _englishPracticePromptChunkTarget = 8000;
  static const _titlePromptInputLimit = 1600;

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

    final reply = await TextGenerationService.generate(
      turns: turns,
      fallbackText: _mockTranslation(trimmed),
      cachePurpose: cachePurpose,
      articleId: articleId,
      maxTokens: 512,
    );
    return TextGenerationReply(
      text: _cleanTranslation(reply.text),
      source: reply.source,
      errorMessage: reply.errorMessage,
    );
  }

  static Future<TextGenerationReply> translateToEnglishForPractice({
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

    final chunks = _splitPracticePromptChunks(trimmed);
    if (chunks.length <= 1) {
      final prompt = _englishPracticePrompt(trimmed);
      final reply = await TextGenerationService.generate(
        turns: prompt.turns,
        fallbackText: prompt.fallback,
        cachePurpose: 'translate_to_english_practice',
        articleId: articleId,
        maxTokens: 1600,
      );
      return TextGenerationReply(
        text: _cleanEnglishPracticeArticle(reply.text, prompt.fallback),
        source: reply.source,
        errorMessage: reply.errorMessage,
      );
    }

    final outputs = <String>[];
    final sources = <TextGenerationReplySource>[];
    String? firstError;
    for (final chunk in chunks) {
      final prompt = _englishPracticePrompt(chunk);
      final reply = await TextGenerationService.generate(
        turns: prompt.turns,
        fallbackText: prompt.fallback,
        cachePurpose: 'translate_to_english_practice',
        articleId: articleId,
        maxTokens: 1600,
      );
      final cleaned = _cleanEnglishPracticeArticle(reply.text, prompt.fallback);
      if (cleaned.trim().isNotEmpty) {
        outputs.add(cleaned.trim());
      }
      sources.add(reply.source);
      firstError ??= reply.errorMessage;
    }

    return TextGenerationReply(
      text: outputs.join('\n\n'),
      source: _combineTextGenerationSources(sources),
      errorMessage: firstError,
    );
  }

  static Future<PracticeWordLookup> lookupWordForLearning({
    required String word,
    required String sentence,
    int? articleId,
  }) async {
    final normalizedWord = _normalizeLookupWord(word);
    if (normalizedWord.isEmpty) {
      return PracticeWordLookup(
        word: word.trim(),
        phonetic: '/.../',
        meaning: '这个单词的中文含义暂不可用。',
        sentenceMeaning: '请结合原句理解这个单词。',
        source: TextGenerationReplySource.mockNoKey,
      );
    }

    final normalizedSentence =
        sentence.replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim();
    final fallback = _mockWordLookupJson(normalizedWord, normalizedSentence);
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

    final reply = await TextGenerationService.generate(
      turns: turns,
      fallbackText: jsonEncode(fallback),
      cachePurpose: 'word_lookup',
      articleId: articleId,
      maxTokens: 256,
    );
    final parsed = _parseWordLookupJson(reply.text, fallback);
    return PracticeWordLookup(
      word: parsed['word'] ?? normalizedWord,
      phonetic: parsed['phonetic'] ?? '/.../',
      meaning: parsed['meaning'] ?? '这个单词的中文含义暂不可用。',
      sentenceMeaning: parsed['sentenceMeaning'] ?? '请结合原句理解这个单词。',
      source: reply.source,
    );
  }

  static Future<TextGenerationReply> suggestArticleTitle({
    required String content,
    int? articleId,
  }) async {
    final trimmed = content.replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim();
    final fallback = _mockArticleTitle(trimmed);
    if (trimmed.isEmpty) {
      return TextGenerationReply(
        text: fallback,
        source: TextGenerationReplySource.mockNoKey,
        errorMessage: 'content is empty',
      );
    }

    final turns = _articleTitlePrompt(trimmed);
    final reply = await TextGenerationService.generate(
      turns: turns,
      fallbackText: fallback,
      cachePurpose: 'suggest_article_title',
      articleId: articleId,
      maxTokens: 64,
    );
    return TextGenerationReply(
      text: _cleanArticleTitle(reply.text, fallback),
      source: reply.source,
      errorMessage: reply.errorMessage,
    );
  }

  static Future<void> attachTranslateToEnglishForPracticeCache({
    required String content,
    required int articleId,
  }) async {
    final trimmed = _normalizeEnglishWordJoiners(content.trim());
    if (trimmed.isEmpty || !_containsChineseText(trimmed)) {
      return;
    }
    for (final chunk in _splitPracticePromptChunks(trimmed)) {
      final prompt = _englishPracticePrompt(chunk);
      await TextGenerationService.attachExistingCache(
        turns: prompt.turns,
        cachePurpose: 'translate_to_english_practice',
        articleId: articleId,
        maxTokens: 1600,
      );
    }
  }

  static Future<void> attachSuggestArticleTitleCache({
    required String content,
    required int articleId,
  }) async {
    final trimmed = content.replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim();
    if (trimmed.isEmpty) {
      return;
    }
    await TextGenerationService.attachExistingCache(
      turns: _articleTitlePrompt(trimmed),
      cachePurpose: 'suggest_article_title',
      articleId: articleId,
      maxTokens: 64,
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

  static String _mockTranslation(String text) {
    final normalized = text.trim();
    if (normalized.isEmpty) {
      return '';
    }

    final lower = normalized.toLowerCase();
    if (lower.contains('tom finds a bright snack box')) {
      return '汤姆发现了一个明亮的零食盒。';
    }
    if (lower.contains('he shares it with his team')) {
      return '他把它分享给自己的队友。';
    }
    if (lower.contains('alice')) {
      return '这是一句关于爱丽丝故事的英文，请结合上方英文理解。';
    }
    return '中文翻译暂不可用，请先参考英文原句。';
  }

  static ({List<TextGenerationTurn> turns, String fallback})
      _englishPracticePrompt(String text) {
    final trimmed = _normalizeEnglishWordJoiners(text.trim());

    if (_containsEnglishText(trimmed)) {
      final fallback = _extractEnglishStoryText(trimmed);
      return (
        fallback: fallback.isEmpty
            ? _normalizeInWordHyphens(
                trimmed.replaceAll(RegExp(r'[ \t\r\n]+'), ' ').trim(),
              )
            : fallback,
        turns: <TextGenerationTurn>[
          const TextGenerationTurn(
            role: 'system',
            content:
                'You extract original English story prose from mixed Chinese-English learning material. Keep only the English story text in original order. Remove Chinese translations, explanations, vocabulary notes, headings, page labels, metadata, and teacher instructions. Do not translate Chinese into new story text. Return only English prose.',
          ),
          TextGenerationTurn(
            role: 'user',
            content:
                'Extract the English story original from this mixed learning text. Return only the English story prose, with normal spacing and punctuation:\n\n$trimmed',
          ),
        ],
      );
    }

    final fallback = _mockEnglishPracticeArticle(trimmed);
    return (
      fallback: fallback,
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
      return TextGenerationReplySource.mockOnError;
    }
    if (sources.contains(TextGenerationReplySource.remote)) {
      return TextGenerationReplySource.remote;
    }
    if (sources.contains(TextGenerationReplySource.cached)) {
      return TextGenerationReplySource.cached;
    }
    if (sources.contains(TextGenerationReplySource.mockOnError)) {
      return TextGenerationReplySource.mockOnError;
    }
    return TextGenerationReplySource.mockNoKey;
  }

  static String _mockArticleTitle(String text) {
    if (RegExp(r'[\u3400-\u9FFF]').hasMatch(text)) {
      if (text.contains('母') || text.contains('妈')) {
        return "A Mother's Choice";
      }
      return 'English Practice';
    }

    final lowerText = text.toLowerCase();
    if (lowerText.contains('mother') && lowerText.contains('choice')) {
      return "A Mother's Choice";
    }

    final words = <String>[];
    final seen = <String>{};
    for (final match in RegExp(r'[A-Za-z]+').allMatches(text)) {
      final value = match.group(0);
      if (value == null) {
        continue;
      }
      final word = value.toLowerCase();
      if (word.length < 4 || _titleStopWords.contains(word)) {
        continue;
      }
      if (seen.add(word)) {
        words.add(word);
      }
      if (words.length >= 3) {
        break;
      }
    }
    if (words.isEmpty) {
      return 'English Practice';
    }
    return words.map(_titleCaseWord).join(' ');
  }

  static String _mockEnglishPracticeArticle(String text) {
    if (text.contains('母') || text.contains('妈') || text.contains('选择')) {
      return 'A mother makes a choice for her child. She thinks about love, family, and the future.';
    }
    return 'This is a short English practice story. The people make a choice and learn something important.';
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

  static Map<String, String> _mockWordLookupJson(
    String word,
    String sentence,
  ) {
    final normalized = _normalizeLookupWord(word);
    final lower = normalized.toLowerCase();
    final known = <String, Map<String, String>>{
      'bright': {
        'phonetic': '/brait/',
        'meaning': '明亮的；聪明的；鲜艳的',
        'sentenceMeaning': '在本句中表示“明亮的”。',
      },
      'snack': {
        'phonetic': '/snak/',
        'meaning': '零食；小吃',
        'sentenceMeaning': '在本句中表示“零食”。',
      },
      'find': {
        'phonetic': '/faind/',
        'meaning': '找到；发现',
        'sentenceMeaning': '在本句中表示“发现”。',
      },
      'finds': {
        'phonetic': '/faindz/',
        'meaning': '找到；发现',
        'sentenceMeaning': '在本句中表示“发现”。',
      },
      'share': {
        'phonetic': '/sher/',
        'meaning': '分享；分给',
        'sentenceMeaning': '在本句中表示“分享”。',
      },
      'shares': {
        'phonetic': '/sherz/',
        'meaning': '分享；分给',
        'sentenceMeaning': '在本句中表示“分享”。',
      },
      'choice': {
        'phonetic': '/tshois/',
        'meaning': '选择；选择权',
        'sentenceMeaning': '在本句中表示“选择”。',
      },
      'mother': {
        'phonetic': '/muh-ther/',
        'meaning': '母亲；妈妈',
        'sentenceMeaning': '在本句中表示“母亲”。',
      },
    };

    final fallback = known[lower] ??
        {
          'phonetic': '/.../',
          'meaning': '这个单词的中文含义暂不可用。',
          'sentenceMeaning': sentence.isEmpty ? '请结合原句理解这个单词。' : '请结合本句理解这个单词。',
        };

    return {
      'word': normalized.isEmpty ? word.trim() : normalized,
      'phonetic': fallback['phonetic']!,
      'meaning': fallback['meaning']!,
      'sentenceMeaning': fallback['sentenceMeaning']!,
    };
  }

  static Map<String, String> _parseWordLookupJson(
    String text,
    Map<String, String> fallback,
  ) {
    final trimmed = text.trim();
    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');
    if (start < 0 || end <= start) {
      return fallback;
    }

    try {
      final decoded = jsonDecode(trimmed.substring(start, end + 1));
      if (decoded is! Map) {
        return fallback;
      }
      return {
        'word': _jsonString(decoded['word'], fallback['word'] ?? ''),
        'phonetic':
            _jsonString(decoded['phonetic'], fallback['phonetic'] ?? '/.../'),
        'meaning': _jsonString(
          decoded['meaning'],
          fallback['meaning'] ?? '这个单词的中文含义暂不可用。',
        ),
        'sentenceMeaning': _jsonString(
          decoded['sentenceMeaning'],
          fallback['sentenceMeaning'] ?? '请结合原句理解这个单词。',
        ),
      };
    } catch (_) {
      return fallback;
    }
  }

  static String _jsonString(Object? value, String fallback) {
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
    return fallback;
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

  static String _cleanEnglishPracticeArticle(String text, String fallback) {
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
    if (cleaned.isEmpty) {
      return fallback;
    }
    if (_containsChineseText(cleaned) && !_containsEnglishText(cleaned)) {
      return fallback;
    }
    return cleaned;
  }

  static String _cleanArticleTitle(String text, String fallback) {
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
      return fallback;
    }

    final words = cleaned.split(RegExp(r'\s+')).where((word) {
      return RegExp(r'[A-Za-z]').hasMatch(word);
    }).toList(growable: false);
    if (words.isEmpty) {
      return fallback;
    }

    cleaned = words.take(5).map(_titleCaseWord).join(' ');
    cleaned = _restoreCommonTitlePossessives(cleaned);
    return cleaned.isEmpty ? fallback : cleaned;
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

  static const Set<String> _titleStopWords = {
    'about',
    'after',
    'again',
    'also',
    'because',
    'before',
    'bright',
    'from',
    'have',
    'into',
    'little',
    'looks',
    'slowly',
    'that',
    'their',
    'there',
    'they',
    'this',
    'with',
  };
}
