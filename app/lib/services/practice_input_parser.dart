import '../data/models/article_sentence_translation_model.dart';
import 'nlp_service.dart';

enum PracticeInputSourceKind {
  english,
  standardBilingual,
  mixed,
  chinese,
}

class PracticeParagraphPair {
  const PracticeParagraphPair({
    required this.englishParagraph,
    required this.chineseParagraph,
  });

  final String englishParagraph;
  final String chineseParagraph;
}

class ParsedPracticeInput {
  const ParsedPracticeInput({
    required this.sourceKind,
    required this.titleCandidate,
    required this.englishContent,
    required this.paragraphPairs,
    required this.translationNotes,
  });

  final PracticeInputSourceKind sourceKind;
  final String titleCandidate;
  final String englishContent;
  final List<PracticeParagraphPair> paragraphPairs;
  final String translationNotes;

  bool get usesLocalEnglish =>
      sourceKind == PracticeInputSourceKind.english ||
      sourceKind == PracticeInputSourceKind.standardBilingual;

  List<ArticleSentenceTranslation> buildSentenceTranslations({
    required int articleId,
    required List<String> sentences,
    DateTime? now,
  }) {
    if (paragraphPairs.isEmpty || sentences.isEmpty) {
      return const [];
    }

    final createdAt = now ?? DateTime.now();
    final rows = <ArticleSentenceTranslation>[];
    var sentenceCursor = 0;

    for (final pair in paragraphPairs) {
      if (sentenceCursor >= sentences.length) {
        break;
      }

      final localEnglishSentences = NlpService.splitSentences(
        pair.englishParagraph,
      );
      if (localEnglishSentences.isEmpty) {
        continue;
      }

      final span = _sentenceSpanForParagraph(
        sentences: sentences,
        paragraph: pair.englishParagraph,
        cursor: sentenceCursor,
      );
      if (span == null || span.end <= span.start) {
        continue;
      }

      final spanSentenceCount = span.end - span.start;
      final chinesePieces = _splitChinesePieces(
        pair.chineseParagraph,
        targetCount: spanSentenceCount,
      );
      for (var i = 0; i < spanSentenceCount; i++) {
        final globalIndex = span.start + i;
        if (globalIndex >= sentences.length) {
          break;
        }

        final chineseText = _translationForChunk(
          chinesePieces: chinesePieces,
          fullChinese: pair.chineseParagraph,
          index: i,
          count: spanSentenceCount,
        );
        if (chineseText.trim().isEmpty) {
          continue;
        }

        rows.add(
          ArticleSentenceTranslation(
            articleId: articleId,
            sentenceIndex: globalIndex,
            englishSentence: sentences[globalIndex],
            chineseText: _normalizeChineseTranslation(chineseText),
            source: 'imported_bilingual',
            createdAt: createdAt,
            updatedAt: createdAt,
          ),
        );
      }
      sentenceCursor = span.end;
    }

    return _fillMissingImportedTranslations(
      articleId: articleId,
      sentences: sentences,
      rows: rows,
      paragraphPairs: paragraphPairs,
      createdAt: createdAt,
    );
  }
}

class PracticeInputParser {
  const PracticeInputParser._();

  static ParsedPracticeInput parse(String rawContent) {
    final normalized = normalizePracticeText(rawContent);
    final trimmed = normalized.trim();
    if (trimmed.isEmpty) {
      return const ParsedPracticeInput(
        sourceKind: PracticeInputSourceKind.english,
        titleCandidate: '',
        englishContent: '',
        paragraphPairs: [],
        translationNotes: '',
      );
    }

    final hasChinese = _containsChinese(trimmed);
    final hasEnglish = _containsEnglish(trimmed);
    if (!hasChinese) {
      return ParsedPracticeInput(
        sourceKind: PracticeInputSourceKind.english,
        titleCandidate: '',
        englishContent: _normalizeEnglishOnlyContent(trimmed),
        paragraphPairs: const [],
        translationNotes: '',
      );
    }
    if (!hasEnglish) {
      return const ParsedPracticeInput(
        sourceKind: PracticeInputSourceKind.chinese,
        titleCandidate: '',
        englishContent: '',
        paragraphPairs: [],
        translationNotes: '',
      );
    }

    final englishOriginalSection = _tryParseEnglishOriginalSection(trimmed);
    if (englishOriginalSection != null) {
      return englishOriginalSection;
    }

    final bilingual = _tryParseStandardBilingual(trimmed);
    if (bilingual != null) {
      return bilingual;
    }

    return const ParsedPracticeInput(
      sourceKind: PracticeInputSourceKind.mixed,
      titleCandidate: '',
      englishContent: '',
      paragraphPairs: [],
      translationNotes: '',
    );
  }

  static String normalizePracticeText(String text) {
    var normalized = text
        .replaceAll('\u00A0', ' ')
        .replaceAll(RegExp(r'[“”]'), '"')
        .replaceAll(RegExp(r'[‘’]'), "'")
        .replaceAll(RegExp(r'\r\n?'), '\n');
    normalized = _normalizeEnglishJoiners(normalized);
    normalized = normalized
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .join('\n');
    return normalized.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  static ParsedPracticeInput? _tryParseStandardBilingual(String text) {
    final rawLines = text.split('\n');
    final pairs = <PracticeParagraphPair>[];
    final notes = <String>[];
    String? pendingEnglish;
    var titleCandidate = '';
    var bodyStarted = false;
    var skippedEnglishTitle = false;

    for (final rawLine in rawLines) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }
      if (_isTranslationNoteLine(line)) {
        notes.add(line);
        continue;
      }
      // Standard bilingual imports can be followed by vocab or exercise
      // sections; those are terminal learning material, not story text.
      if (bodyStarted && _isEnglishOriginalTerminalHeading(line)) {
        break;
      }

      final isEnglish = _isEnglishLine(line);
      final isChinese = _isChineseLine(line);

      if (!bodyStarted && isEnglish) {
        if (_isChapterHeading(line)) {
          continue;
        }
        if (titleCandidate.isEmpty && _looksLikeEnglishTitle(line)) {
          titleCandidate = _cleanTitleCandidate(line);
          skippedEnglishTitle = true;
          continue;
        }
      }

      if (!bodyStarted && isChinese) {
        if (_isChineseTitleOrChapter(line) || skippedEnglishTitle) {
          skippedEnglishTitle = false;
          continue;
        }
      }

      if (isEnglish) {
        if (pendingEnglish != null && _isLikelyStoryEnglish(pendingEnglish)) {
          pairs.add(
            PracticeParagraphPair(
              englishParagraph: pendingEnglish,
              chineseParagraph: '',
            ),
          );
          bodyStarted = true;
        }
        pendingEnglish = _cleanEnglishParagraph(line);
        continue;
      }

      if (isChinese && pendingEnglish != null) {
        pairs.add(
          PracticeParagraphPair(
            englishParagraph: pendingEnglish,
            chineseParagraph: _cleanChineseParagraph(line),
          ),
        );
        pendingEnglish = null;
        bodyStarted = true;
      }
    }

    if (pendingEnglish != null && bodyStarted) {
      pairs.add(
        PracticeParagraphPair(
          englishParagraph: pendingEnglish,
          chineseParagraph: '',
        ),
      );
    }

    final translatedPairs =
        pairs.where((pair) => pair.chineseParagraph.trim().isNotEmpty).length;
    if (translatedPairs < 2) {
      return null;
    }

    final englishParagraphs = pairs
        .map((pair) => pair.englishParagraph.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (englishParagraphs.length < translatedPairs) {
      return null;
    }

    return ParsedPracticeInput(
      sourceKind: PracticeInputSourceKind.standardBilingual,
      titleCandidate: titleCandidate,
      englishContent: englishParagraphs.join('\n\n'),
      paragraphPairs: pairs,
      translationNotes: notes.join('\n'),
    );
  }

  static ParsedPracticeInput? _tryParseEnglishOriginalSection(String text) {
    final lines = text.split('\n');
    final startIndex = lines.indexWhere((line) {
      final compact = line.replaceAll(RegExp(r'\s+'), '');
      return compact == '英文原文' ||
          compact == '英语原文' ||
          compact == '英文故事' ||
          compact == '原文';
    });
    if (startIndex < 0) {
      return null;
    }

    final englishLines = <String>[];
    var insideSoftInterruption = false;
    var insideStoryVerseBlock = false;
    var sawSoftInterruption = false;
    var resumedAfterSoftInterruption = false;
    var skippedLikelyEnglishInSoftInterruption = false;
    for (var index = startIndex + 1; index < lines.length; index += 1) {
      final rawLine = lines[index];
      final line = rawLine.trim();
      if (line.isEmpty) {
        insideStoryVerseBlock = false;
        if (!insideSoftInterruption &&
            englishLines.isNotEmpty &&
            englishLines.last.isNotEmpty) {
          englishLines.add('');
        }
        continue;
      }
      if (_isEnglishOriginalSectionTerminalStop(line) ||
          (!insideSoftInterruption &&
              _isEnglishOriginalSectionHardStop(line))) {
        break;
      }
      if (_isEnglishOriginalSectionSoftInterruption(line)) {
        insideSoftInterruption = true;
        insideStoryVerseBlock = false;
        sawSoftInterruption = true;
        if (englishLines.isNotEmpty && englishLines.last.isNotEmpty) {
          englishLines.add('');
        }
        continue;
      }

      if (insideSoftInterruption) {
        final resumesVerseBlock =
            _isStoryVerseStartAfterPrompt(line, englishLines);
        final resumesPoemBlock = _sectionSoFarLooksLikeVerse(englishLines) &&
            _isLikelyStoryVerseContinuationLine(line);
        if (resumesVerseBlock ||
            resumesPoemBlock ||
            _isLikelyStoryEnglishContinuation(line, rawLine: rawLine)) {
          insideSoftInterruption = false;
          insideStoryVerseBlock = resumesVerseBlock ||
              resumesPoemBlock ||
              _isIndentedEnglishVerseLine(rawLine, line);
          resumedAfterSoftInterruption = true;
        } else {
          if (_isEnglishLine(line) && _isLikelyStoryEnglish(line)) {
            skippedLikelyEnglishInSoftInterruption = true;
          }
          continue;
        }
      }

      if (_isEnglishLine(line) &&
          (_isLikelyStoryEnglish(line) ||
              (insideStoryVerseBlock && _isLikelyStoryVerseLine(line)))) {
        englishLines.add(_cleanEnglishParagraph(line));
      } else {
        insideStoryVerseBlock = false;
      }
    }

    while (englishLines.isNotEmpty && englishLines.last.isEmpty) {
      englishLines.removeLast();
    }
    final paragraphs = englishLines
        .join('\n')
        .split(RegExp(r'\n\s*\n+'))
        .map((paragraph) => paragraph
            .split('\n')
            .map(_cleanEnglishParagraph)
            .where((line) => line.isNotEmpty)
            .join(' '))
        .where((paragraph) => paragraph.isNotEmpty)
        .toList(growable: false);
    final wordCount = paragraphs
        .join(' ')
        .split(RegExp(r'\s+'))
        .where((word) => RegExp(r'[A-Za-z]').hasMatch(word))
        .length;
    if (paragraphs.isEmpty || wordCount < 20) {
      return null;
    }
    if (sawSoftInterruption &&
        !resumedAfterSoftInterruption &&
        (skippedLikelyEnglishInSoftInterruption || wordCount < 120)) {
      return null;
    }

    return ParsedPracticeInput(
      sourceKind: PracticeInputSourceKind.english,
      titleCandidate: '',
      englishContent: paragraphs.join('\n\n'),
      paragraphPairs: const [],
      translationNotes: '',
    );
  }

  static bool _isEnglishOriginalSectionHardStop(String line) {
    final compact = line.replaceAll(RegExp(r'\s+'), '');
    if (_isEnglishOriginalSectionTerminalStop(line)) {
      return true;
    }
    if (compact.startsWith('【') || compact.endsWith('】')) {
      return !_isEnglishOriginalSectionSoftInterruption(line);
    }
    if (RegExp(r'^\d+[.、]').hasMatch(line)) {
      return true;
    }
    return false;
  }

  static bool _isEnglishOriginalSectionTerminalStop(String line) {
    final compact = line.replaceAll(RegExp(r'\s+'), '');
    final bareHeading = _bareChineseBracketHeading(compact);
    return _isEnglishOriginalTerminalHeading(bareHeading) ||
        _isEnglishOriginalTerminalHeading(compact);
  }

  static String _bareChineseBracketHeading(String compact) {
    if (compact.startsWith('【') && compact.endsWith('】')) {
      return compact.substring(1, compact.length - 1);
    }
    return compact;
  }

  static String _normalizedHeadingKey(String heading) {
    final compact = heading.replaceAll(RegExp(r'\s+'), '');
    return _bareChineseBracketHeading(compact)
        .replaceAll(RegExp(r'''[【】\[\]（）()《》<>:：,，.。!！?？、;'"\-—–_/\\]+'''), '')
        .toLowerCase();
  }

  static bool _startsWithNearHeading(
    String key,
    Set<String> prefixes, {
    int extraLength = 14,
  }) {
    for (final prefix in prefixes) {
      if (key == prefix ||
          (key.startsWith(prefix) &&
              key.length <= prefix.length + extraLength)) {
        return true;
      }
    }
    return false;
  }

  static bool _isEnglishOriginalTerminalHeading(String heading) {
    final key = _normalizedHeadingKey(heading);
    const exactHeadings = {
      '文化卡片',
      '生词好句',
      '重点词汇',
      '词汇讲解',
      '词汇',
      '单词讲解',
      '生词',
      '中文译文',
      '中文翻译',
      '参考译文',
      '译文',
      '翻译',
      '课程导读',
      '课后练习',
      '练习',
      '作业',
      '例句',
      '示例',
      '范例',
      '参考答案',
      '答案',
      '课文翻译',
      '原文翻译',
      '译文参考',
      'vocabulary',
      'wordlist',
      'newwords',
      'keywords',
      'keyvocabulary',
      'wordsandphrases',
      'usefulphrases',
      'usefulsentences',
      'sentencebank',
      'translation',
      'referencetranslation',
      'chinesetranslation',
      'answer',
      'answers',
      'exercises',
      'homework',
      'quiz',
      'questions',
      'culturecard',
      'culturalcard',
    };
    if (exactHeadings.contains(key)) {
      return true;
    }
    const chinesePrefixes = {
      '生词',
      '词汇',
      '单词',
      '短语',
      '句型',
      '例句',
      '练习',
      '作业',
      '答案',
      '参考答案',
      '阅读理解',
      '课后题',
      '问题',
      '测验',
    };
    if (_startsWithNearHeading(key, chinesePrefixes, extraLength: 16)) {
      return true;
    }
    const englishPrefixes = {
      'vocabulary',
      'wordlist',
      'newwords',
      'keywords',
      'phrase',
      'phrases',
      'translation',
      'answer',
      'answers',
      'exercise',
      'exercises',
      'homework',
      'quiz',
      'question',
      'questions',
    };
    return _startsWithNearHeading(key, englishPrefixes, extraLength: 10);
  }

  static bool _isEnglishOriginalSectionSoftInterruption(String line) {
    final compact = line.replaceAll(RegExp(r'\s+'), '');
    if (_isEnglishOriginalSectionTerminalStop(line)) {
      return false;
    }
    if (compact.startsWith('【') && compact.endsWith('】')) {
      return true;
    }
    final key = _normalizedHeadingKey(compact);
    const softHeadings = {
      '拓展',
      '背景',
      '背景知识',
      '文化拓展',
      '补充',
      '补充说明',
      '延伸阅读',
      '知识点',
      '知识拓展',
      '句子解析',
      '难句解析',
      '长难句',
      '语法点',
      '语法讲解',
      '文化注释',
      '原文解析',
      '重点解析',
      '讲解',
      '解析',
      '说明',
      '小贴士',
      'tips',
      'note',
      'notes',
      'teachersnote',
      'teachernote',
      'background',
      'backgroundknowledge',
      'extension',
      'extendedreading',
      'supplement',
      'explanation',
      'analysis',
      'sentenceanalysis',
      'difficultsentences',
      'grammarnote',
      'grammarnotes',
      'culturenote',
      'culturalnote',
    };
    if (softHeadings.contains(key)) {
      return true;
    }
    const englishPrefixes = {
      'background',
      'extension',
      'supplement',
      'explanation',
      'analysis',
      'note',
      'notes',
      'grammar',
      'culture',
      'cultural',
      'tip',
      'tips',
      'teacher',
    };
    if (_startsWithNearHeading(key, englishPrefixes, extraLength: 18)) {
      return true;
    }
    return RegExp(
      r'^(拓展|背景|补充|注释|讲解|解析|知识|语法|难句|长难句|文化|说明|小贴士|导读)',
    ).hasMatch(compact);
  }

  static bool _containsChinese(String text) =>
      RegExp(r'[\u3400-\u9FFF]').hasMatch(text);

  static bool _containsEnglish(String text) =>
      RegExp(r'[A-Za-z]').hasMatch(text);

  static bool _isEnglishLine(String line) {
    if (!_containsEnglish(line)) {
      return false;
    }
    final chineseCount = RegExp(r'[\u3400-\u9FFF]').allMatches(line).length;
    final englishWordCount =
        RegExp(r"[A-Za-z][A-Za-z'\-]*").allMatches(line).length;
    return chineseCount == 0 || englishWordCount >= chineseCount;
  }

  static bool _isChineseLine(String line) {
    if (!_containsChinese(line)) {
      return false;
    }
    final chineseCount = RegExp(r'[\u3400-\u9FFF]').allMatches(line).length;
    final englishWordCount =
        RegExp(r"[A-Za-z][A-Za-z'\-]*").allMatches(line).length;
    return chineseCount > englishWordCount;
  }

  static bool _isTranslationNoteLine(String line) => RegExp(
        r'^\s*[\(（]?\s*(注|译注|说明|备注)\s*[:：]',
      ).hasMatch(line);

  static bool _isChapterHeading(String line) => RegExp(
        "^(chapter|episode|part|book)\\b[\\w\\s\\-'\".,:]*\$",
        caseSensitive: false,
      ).hasMatch(line.trim());

  static bool _isChineseTitleOrChapter(String line) {
    if (!_containsChinese(line)) {
      return false;
    }
    final compact = line.replaceAll(RegExp(r'\s+'), '');
    if (RegExp(r'^第.+[章节回篇]').hasMatch(compact)) {
      return true;
    }
    return compact.length <= 18 && !RegExp(r'[。！？!?；;，,]').hasMatch(compact);
  }

  static bool _looksLikeEnglishTitle(String line) {
    final cleaned = line
        .replaceAll(RegExp("^\\s*[\"']|[\"']\\s*\$"), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty || _isChapterHeading(cleaned)) {
      return false;
    }
    if (RegExp(r'[.!?;:]$').hasMatch(cleaned)) {
      return false;
    }
    final wordCount =
        RegExp(r"[A-Za-z][A-Za-z'\-]*").allMatches(cleaned).length;
    if (wordCount < 2 || wordCount > 10) {
      return false;
    }
    final lower = cleaned.toLowerCase();
    return !lower.startsWith('by ');
  }

  static bool _isLikelyStoryEnglish(String line) {
    final wordCount = RegExp(r"[A-Za-z][A-Za-z'\-]*").allMatches(line).length;
    return wordCount >= 5 || RegExp(r'[.!?;:,"—–]$').hasMatch(line.trim());
  }

  static bool _isLikelyStoryEnglishContinuation(
    String line, {
    String rawLine = '',
  }) {
    if (!_isEnglishLine(line)) {
      return false;
    }
    final trimmed = line.trim();
    if (_isIndentedEnglishVerseLine(rawLine, trimmed)) {
      return true;
    }
    if (!_isLikelyStoryEnglish(line)) {
      return false;
    }
    final lower = trimmed.toLowerCase();
    if (_looksLikeEnglishTitle(trimmed) &&
        !_startsWithEnglishQuote(trimmed) &&
        !_hasStoryNarrationSignal(lower)) {
      return false;
    }
    if (_hasStoryNarrationSignal(lower)) {
      return true;
    }
    return false;
  }

  static bool _hasStoryNarrationSignal(String lowerLine) {
    return RegExp(
      r"\b(said|asked|answered|replied|remarked|cried|shouted|whispered|called|sighed|pleaded|ventured|growled|thought|looked|glanced|heard|found|appeared|noticed|began|went|came|hurried|tucked|caught|flung|threw|walked|spoke|added)\b",
      caseSensitive: false,
    ).hasMatch(lowerLine);
  }

  static bool _startsWithEnglishQuote(String line) {
    return line.startsWith('"') ||
        line.startsWith("'") ||
        line.startsWith('“') ||
        line.startsWith('‘') ||
        line.startsWith('’');
  }

  static bool _isIndentedEnglishVerseLine(String rawLine, String line) {
    final leadingSpaces = rawLine.length - rawLine.trimLeft().length;
    return leadingSpaces >= 2 &&
        _isLikelyStoryVerseLine(line) &&
        _startsWithEnglishQuote(line);
  }

  static bool _isLikelyStoryVerseLine(String line) {
    if (!_isEnglishLine(line) || _containsChinese(line)) {
      return false;
    }
    if (_isEnglishOriginalTerminalHeading(line)) {
      return false;
    }
    return RegExp(r"[A-Za-z][A-Za-z'\-]*").hasMatch(line);
  }

  static bool _isLikelyStoryVerseContinuationLine(String line) {
    if (!_isLikelyStoryVerseLine(line)) {
      return false;
    }
    final wordCount = RegExp(r"[A-Za-z][A-Za-z'\-]*").allMatches(line).length;
    return wordCount >= 2 && wordCount <= 12;
  }

  static bool _sectionSoFarLooksLikeVerse(List<String> englishLines) {
    final recent = englishLines
        .where((line) => line.trim().isNotEmpty)
        .toList(growable: false);
    if (recent.length < 4) {
      return false;
    }

    final sample =
        recent.length > 12 ? recent.sublist(recent.length - 12) : recent;
    final wordCounts = sample
        .map((line) => RegExp(r"[A-Za-z][A-Za-z'\-]*").allMatches(line).length)
        .toList(growable: false);
    final shortLines = wordCounts.where((count) => count >= 2 && count <= 8);
    final longLines = wordCounts.where((count) => count > 12);
    return shortLines.length >= 4 && longLines.isEmpty;
  }

  static bool _isStoryVerseStartAfterPrompt(
    String line,
    List<String> englishLines,
  ) {
    if (!_startsWithEnglishQuote(line) || !_isLikelyStoryVerseLine(line)) {
      return false;
    }
    for (var index = englishLines.length - 1; index >= 0; index -= 1) {
      final previous = englishLines[index].trim();
      if (previous.isEmpty) {
        continue;
      }
      return previous.endsWith(':');
    }
    return false;
  }

  static String _cleanTitleCandidate(String line) =>
      _tightenSpaceBeforePunctuation(
        _cleanEnglishParagraph(line).replaceAll(RegExp(r'\s+'), ' '),
      ).trim();

  static String _cleanEnglishParagraph(String line) =>
      _tightenSpaceBeforePunctuation(
        _normalizeEnglishJoiners(line).replaceAll(RegExp(r'\s+'), ' '),
      ).trim();

  static String _cleanChineseParagraph(String line) =>
      line.replaceAll(RegExp(r'\s+'), '').trim();

  static String _normalizeEnglishOnlyContent(String text) {
    final paragraphs = text
        .split(RegExp(r'\n\s*\n+'))
        .map((paragraph) => paragraph
            .split('\n')
            .map((line) => _cleanEnglishParagraph(line))
            .where((line) => line.isNotEmpty)
            .join(' '))
        .where((paragraph) => paragraph.isNotEmpty)
        .toList(growable: false);
    return paragraphs.join('\n\n');
  }

  static String _normalizeEnglishJoiners(String text) {
    var normalized = text.replaceAllMapped(
      RegExp(
        r"\b([A-Za-z]+)\s+'\s*(s|t|re|ve|ll|d|m)\b",
        caseSensitive: false,
      ),
      (match) => "${match.group(1)}'${match.group(2)}",
    );
    normalized = normalized.replaceAllMapped(
      RegExp(r'([A-Za-z])\s*-\s*([A-Za-z])'),
      (match) => '${match.group(1)}-${match.group(2)}',
    );
    return normalized;
  }

  static String _tightenSpaceBeforePunctuation(String text) =>
      text.replaceAllMapped(
        RegExp(r'\s+([:;,.!?])'),
        (match) => match.group(1) ?? '',
      );
}

List<String> _splitChinesePieces(String text, {int targetCount = 1}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return const [];
  }

  final strongPieces = _splitChineseByPunctuation(
    trimmed,
    RegExp(r'[。！？!?；;]'),
  );
  if (targetCount <= 1 || strongPieces.length >= targetCount) {
    return strongPieces;
  }
  final softPieces = _splitChineseByPunctuation(
    trimmed,
    RegExp(r'[。！？!?；;：:，,]'),
  );
  return softPieces.length > strongPieces.length ? softPieces : strongPieces;
}

List<String> _splitChineseByPunctuation(String text, RegExp punctuation) {
  final pieces = <String>[];
  final buffer = StringBuffer();

  void addPiece(String value) {
    final piece = value.trim();
    if (piece.isEmpty) {
      return;
    }
    if (_isOnlyQuoteMarks(piece) && pieces.isNotEmpty) {
      pieces[pieces.length - 1] = '${pieces.last}$piece';
      return;
    }
    pieces.add(piece);
  }

  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    buffer.write(char);
    if (punctuation.hasMatch(char)) {
      addPiece(buffer.toString());
      buffer.clear();
    }
  }
  addPiece(buffer.toString());
  return pieces.isEmpty ? [text] : pieces;
}

bool _isOnlyQuoteMarks(String text) => RegExp(r'''^["']+$''').hasMatch(text);

String _translationForChunk({
  required List<String> chinesePieces,
  required String fullChinese,
  required int index,
  required int count,
}) {
  if (fullChinese.trim().isEmpty) {
    return '';
  }
  if (count <= 1 || chinesePieces.length <= 1) {
    return _normalizeChineseTranslation(fullChinese);
  }
  if (chinesePieces.length == count) {
    return _normalizeChineseTranslation(chinesePieces[index]);
  }
  if (chinesePieces.length < count) {
    return _normalizeChineseTranslation(fullChinese);
  }

  final start = (index * chinesePieces.length / count).floor();
  var end = ((index + 1) * chinesePieces.length / count).floor();
  if (end <= start) {
    end = start + 1;
  }
  final safeStart = start.clamp(0, chinesePieces.length).toInt();
  final safeEnd = end.clamp(0, chinesePieces.length).toInt();
  return _normalizeChineseTranslation(
    chinesePieces.sublist(safeStart, safeEnd).join(''),
  );
}

String _normalizeChineseTranslation(String text) {
  final trimmed = text.trim();
  if (trimmed.length > 1 && trimmed.startsWith('"')) {
    final quoteCount = '"'.allMatches(trimmed).length;
    if (quoteCount == 1) {
      return trimmed.substring(1).trimLeft();
    }
  }
  return trimmed;
}

({int start, int end})? _sentenceSpanForParagraph({
  required List<String> sentences,
  required String paragraph,
  required int cursor,
}) {
  final paragraphCompact = _compactEnglishForAlignment(paragraph);
  if (paragraphCompact.isEmpty || sentences.isEmpty) {
    return null;
  }

  final safeCursor = cursor.clamp(0, sentences.length).toInt();
  var start = safeCursor;
  var foundStart = false;
  final maxSearch = (safeCursor + 8).clamp(0, sentences.length).toInt();
  for (var candidate = safeCursor; candidate < maxSearch; candidate++) {
    final sentenceCompact = _compactEnglishForAlignment(sentences[candidate]);
    if (sentenceCompact.isEmpty) {
      continue;
    }
    if (_alignmentOverlaps(paragraphCompact, sentenceCompact)) {
      start = candidate;
      foundStart = true;
      break;
    }
  }
  if (!foundStart) {
    return null;
  }

  var end = start;
  var combined = '';
  while (end < sentences.length) {
    final sentenceCompact = _compactEnglishForAlignment(sentences[end]);
    if (sentenceCompact.isEmpty) {
      end++;
      continue;
    }

    final nextCombined = combined + sentenceCompact;
    if (combined.isNotEmpty &&
        !_alignmentOverlaps(paragraphCompact, nextCombined)) {
      break;
    }

    combined = nextCombined;
    end++;
    if (combined.length >= paragraphCompact.length ||
        combined == paragraphCompact ||
        combined.contains(paragraphCompact) ||
        (paragraphCompact.startsWith(combined) &&
            paragraphCompact.length - combined.length < 8)) {
      break;
    }
  }

  return end > start ? (start: start, end: end) : null;
}

String _compactEnglishForAlignment(String text) =>
    text.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]+"), '').trim();

bool _alignmentOverlaps(String paragraphCompact, String sentenceCompact) =>
    paragraphCompact.startsWith(sentenceCompact) ||
    paragraphCompact.contains(sentenceCompact) ||
    sentenceCompact.contains(paragraphCompact);

List<ArticleSentenceTranslation> _fillMissingImportedTranslations({
  required int articleId,
  required List<String> sentences,
  required List<ArticleSentenceTranslation> rows,
  required List<PracticeParagraphPair> paragraphPairs,
  required DateTime createdAt,
}) {
  final byIndex = <int, ArticleSentenceTranslation>{
    for (final row in rows) row.sentenceIndex: row,
  };

  for (var index = 0; index < sentences.length; index++) {
    final fallbackMatches = _fallbackChineseMatchesForSentence(
      sentence: sentences[index],
      paragraphPairs: paragraphPairs,
    );
    if (fallbackMatches.isEmpty) {
      continue;
    }
    final fallback = _joinUniqueChineseTranslations(fallbackMatches);
    if (fallback.trim().isEmpty) {
      continue;
    }

    final existing = byIndex[index];
    if (existing != null && fallbackMatches.length <= 1) {
      continue;
    }
    if (existing != null &&
        _translationCovers(existing.chineseText, fallback)) {
      continue;
    }

    byIndex[index] = ArticleSentenceTranslation(
      articleId: articleId,
      sentenceIndex: index,
      englishSentence: sentences[index],
      chineseText: _normalizeChineseTranslation(fallback),
      source: 'imported_bilingual',
      createdAt: createdAt,
      updatedAt: existing?.updatedAt ?? createdAt,
    );
  }

  final filledRows = byIndex.values.toList(growable: false)
    ..sort((a, b) => a.sentenceIndex.compareTo(b.sentenceIndex));
  return filledRows;
}

bool _translationCovers(String existing, String candidate) {
  final existingCompact = _compactChineseForAlignment(existing);
  final candidateCompact = _compactChineseForAlignment(candidate);
  return existingCompact.isNotEmpty &&
      candidateCompact.isNotEmpty &&
      (existingCompact == candidateCompact ||
          existingCompact.contains(candidateCompact) ||
          candidateCompact.contains(existingCompact) &&
              candidateCompact.length - existingCompact.length < 8);
}

String _compactChineseForAlignment(String text) =>
    text.replaceAll(RegExp(r'\s+'), '').trim();

List<String> _fallbackChineseMatchesForSentence({
  required String sentence,
  required List<PracticeParagraphPair> paragraphPairs,
}) {
  final sentenceCompact = _compactEnglishForAlignment(sentence);
  if (sentenceCompact.isEmpty) {
    return const [];
  }

  final exactMatches = <String>[];
  for (final pair in paragraphPairs) {
    final chinese = pair.chineseParagraph.trim();
    if (chinese.isEmpty) {
      continue;
    }

    final paragraphCompact = _compactEnglishForAlignment(pair.englishParagraph);
    if (paragraphCompact.isEmpty) {
      continue;
    }
    if (_alignmentOverlaps(paragraphCompact, sentenceCompact)) {
      exactMatches.add(chinese);
    }
  }
  if (exactMatches.isNotEmpty) {
    return exactMatches;
  }

  final tokenMatches = <String>[];
  final sentenceTokens = _englishTokenSetForAlignment(sentence);
  if (sentenceTokens.length < 2) {
    return const [];
  }
  for (final pair in paragraphPairs) {
    final chinese = pair.chineseParagraph.trim();
    if (chinese.isEmpty) {
      continue;
    }

    final paragraphTokens = _englishTokenSetForAlignment(pair.englishParagraph);
    final overlapCount =
        sentenceTokens.where(paragraphTokens.contains).take(2).length;
    if (overlapCount >= 2) {
      tokenMatches.add(chinese);
      if (tokenMatches.length >= 2) {
        break;
      }
    }
  }
  if (tokenMatches.isNotEmpty) {
    return tokenMatches;
  }

  return const [];
}

Set<String> _englishTokenSetForAlignment(String text) {
  const stopWords = {
    'a',
    'an',
    'and',
    'are',
    'as',
    'at',
    'be',
    'but',
    'for',
    'from',
    'had',
    'has',
    'he',
    'her',
    'him',
    'his',
    'i',
    'if',
    'in',
    'is',
    'it',
    'its',
    'of',
    'on',
    'or',
    'she',
    'that',
    'the',
    'their',
    'them',
    'they',
    'this',
    'to',
    'was',
    'were',
    'what',
    'who',
    'with',
    'you',
  };
  return RegExp(r"[a-z][a-z'\-]*")
      .allMatches(text.toLowerCase())
      .map((match) => match.group(0) ?? '')
      .where((token) => token.length > 1 && !stopWords.contains(token))
      .toSet();
}

String _joinUniqueChineseTranslations(List<String> values) {
  final seen = <String>{};
  final joined = <String>[];
  for (final value in values) {
    final normalized = value.trim();
    if (normalized.isEmpty || !seen.add(normalized)) {
      continue;
    }
    joined.add(normalized);
  }
  return joined.join('');
}
