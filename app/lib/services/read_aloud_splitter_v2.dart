class ReadAloudSplitterV2 {
  static const version = 'read_aloud_dp_v2';
  static const hardMaxWords = 30;
  static const defaultFontSizePx = 30.0;
  static const defaultMaxLineWidthPx = 1280 * 0.84;
  static const Map<String, double> _advanceEm = {
    '0': 0.6,
    '1': 0.6,
    '2': 0.6,
    '3': 0.6,
    '4': 0.6,
    '5': 0.6,
    '6': 0.6,
    '7': 0.6,
    '8': 0.6,
    '9': 0.6,
    ' ': 0.279,
    '!': 0.26,
    '"': 0.481,
    '#': 0.6,
    r'$': 0.6,
    '%': 0.954,
    '&': 0.745,
    "'": 0.256,
    '(': 0.382,
    ')': 0.382,
    '*': 0.454,
    '+': 0.6,
    ',': 0.26,
    '-': 0.44,
    '.': 0.26,
    '/': 0.331,
    ':': 0.26,
    ';': 0.26,
    '<': 0.6,
    '=': 0.6,
    '>': 0.6,
    '?': 0.468,
    '@': 0.952,
    'A': 0.753,
    'B': 0.695,
    'C': 0.684,
    'D': 0.774,
    'E': 0.605,
    'F': 0.57,
    'G': 0.742,
    'H': 0.78,
    'I': 0.297,
    'J': 0.372,
    'K': 0.688,
    'L': 0.573,
    'M': 0.876,
    'N': 0.753,
    'O': 0.796,
    'P': 0.664,
    'Q': 0.796,
    'R': 0.696,
    'S': 0.641,
    'T': 0.632,
    'U': 0.743,
    'V': 0.727,
    'W': 1.12,
    'X': 0.685,
    'Y': 0.631,
    'Z': 0.615,
    '[': 0.377,
    '\\': 0.331,
    ']': 0.377,
    '^': 0.6,
    '_': 0.5,
    '`': 0.388,
    'a': 0.557,
    'b': 0.61,
    'c': 0.478,
    'd': 0.61,
    'e': 0.549,
    'f': 0.382,
    'g': 0.615,
    'h': 0.595,
    'i': 0.268,
    'j': 0.273,
    'k': 0.558,
    'l': 0.333,
    'm': 0.889,
    'n': 0.595,
    'o': 0.589,
    'p': 0.61,
    'q': 0.61,
    'r': 0.412,
    's': 0.492,
    't': 0.404,
    'u': 0.59,
    'v': 0.534,
    'w': 0.861,
    'x': 0.559,
    'y': 0.533,
    'z': 0.48,
    '{': 0.414,
    '|': 0.302,
    '}': 0.414,
    '~': 0.6,
    '‘': 0.26,
    '’': 0.26,
    '“': 0.472,
    '”': 0.472,
    '…': 0.78,
    '–': 0.5,
    '—': 1,
  };

  static double measureNunitoExtraBoldPx(String text,
      {double fontSizePx = defaultFontSizePx}) {
    var em = 0.0;
    for (final rune in text.runes) {
      em += _advanceEm[String.fromCharCode(rune)] ?? 0.56;
    }
    return em * fontSizePx;
  }

  static bool fitsEnglishLine(String text) =>
      measureNunitoExtraBoldPx(text) <= defaultMaxLineWidthPx;

  static int wordCount(String text) =>
      text.trim().isEmpty ? 0 : text.trim().split(RegExp(r'\s+')).length;

  static String normalizeForRoundTrip(String text) => text
      .replaceAll(RegExp(r'\r\n?'), '\n')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'-\s+'), '-')
      .replaceAllMapped(RegExp(r'([—–])\s+'), (match) => match[1]!)
      .trim();

  static void validateReviewedSentences(
      String englishContent, List<String> sentences) {
    if (sentences.isEmpty) {
      throw const FormatException('审核分句不能为空');
    }
    for (var index = 0; index < sentences.length; index += 1) {
      final sentence = sentences[index];
      if (sentence.trim().isEmpty) {
        throw FormatException('审核分句第 ${index + 1} 块为空');
      }
      if (sentence.contains('\n') || sentence.contains('\r')) {
        throw FormatException('审核分句第 ${index + 1} 块含显示换行');
      }
      final count = wordCount(sentence);
      if (count > hardMaxWords) {
        throw FormatException('审核分句第 ${index + 1} 块为 $count 词，超过 30 词硬上限');
      }
    }
    final comparableEnglish =
        _normalizeArticleParagraphs(englishContent).join(' ');
    if (normalizeForRoundTrip(sentences.join(' ')) !=
        normalizeForRoundTrip(comparableEnglish)) {
      throw const FormatException('审核分句规范化拼接与最终英文正文不一致');
    }
  }

  static List<String> splitSentences(String text) {
    final paragraphs = _normalizeArticleParagraphs(text);
    final result = <String>[];
    for (final paragraph in paragraphs) {
      final normalizedParagraph = _coarseSentences(paragraph).join(' ');
      result.addAll(_splitParagraphWithDp(normalizedParagraph));
    }
    return result;
  }

  static List<String> _normalizeArticleParagraphs(String text) {
    final normalized = text
        .replaceAll(RegExp(r'\r\n?'), '\n')
        .replaceAll(RegExp(r'[‐‑‒]'), '-')
        .replaceAllMapped(
          RegExp(r'([A-Za-z])\s+-\s+(?=[A-Za-z])'),
          (match) => '${match[1]}-',
        )
        .replaceAllMapped(
          RegExp(r'''([—–])(?=[^\s"'”’])'''),
          (match) => '${match[1]} ',
        );
    final paragraphs = <String>[];
    final current = <String>[];
    void flush() {
      final value = current.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
      if (value.isNotEmpty && !_isImportedHeadingLine(value)) {
        paragraphs.add(value);
      }
      current.clear();
    }

    for (final rawLine in normalized.split('\n')) {
      final line = _stripCjkPrefix(rawLine.trim());
      if (line.isEmpty) {
        flush();
      } else if (_isImportedHeadingLine(line)) {
        flush();
      } else {
        current.add(line);
      }
    }
    flush();
    return paragraphs;
  }

  static String _stripCjkPrefix(String line) {
    final firstLatin = line.indexOf(RegExp(r'''[A-Za-z"“'‘]'''));
    if (firstLatin > 0 &&
        RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff]')
            .hasMatch(line.substring(0, firstLatin))) {
      return line.substring(firstLatin).trim();
    }
    return line;
  }

  static bool _isImportedHeadingLine(String line) {
    final value = line.trim();
    if (RegExp(r'^e\d{1,3}$', caseSensitive: false).hasMatch(value)) {
      return true;
    }
    if (RegExp(
      r'^chapter\s+(?:[ivxlcdm]+|\d+)\s*[:：.-]?\s+.{1,90}$',
      caseSensitive: false,
    ).hasMatch(value)) {
      return true;
    }
    if (RegExp(r"^[A-Z][A-Z '\-–—]{2,50}$").hasMatch(value)) {
      return true;
    }
    if (RegExp(
      r"^(?:the\s+wind\s+in\s+the\s+willows|alice'?s\s+adventures\s+in\s+wonderland)\s*[-–—:]\s*(?:e|episod(?:e)?)\s*\d+",
      caseSensitive: false,
    ).hasMatch(value)) {
      return true;
    }
    final words = value.split(RegExp(r'\s+'));
    if (words.length <= 8 && !RegExp(r'''[.!?]["”’)]*$''').hasMatch(value)) {
      final titleWords = words
          .where((word) => RegExp(r"^[A-Z][A-Za-z'’-]*$").hasMatch(word))
          .length;
      if (titleWords >= (words.length * 0.7).ceil().clamp(2, words.length)) {
        return true;
      }
    }
    return false;
  }

  static List<String> _coarseSentences(String text) {
    final output = <String>[];
    var start = 0;
    for (var index = 0; index < text.length; index += 1) {
      final char = text[index];
      if (!'.!?…'.contains(char)) continue;
      if (char == '.' &&
          index > 0 &&
          index + 1 < text.length &&
          RegExp(r'\d').hasMatch(text[index - 1]) &&
          RegExp(r'\d').hasMatch(text[index + 1])) {
        continue;
      }
      final current = text.substring(start, index + 1);
      if (char == '.' && _protectedPeriod(current)) continue;
      var end = index + 1;
      while (end < text.length && '"\'”’)}]'.contains(text[end])) {
        final isGluedOpeningQuote = end == index + 1 &&
            (text[end] == '"' || text[end] == '“') &&
            end + 1 < text.length &&
            RegExp(r'[A-Z]').hasMatch(text[end + 1]);
        if (isGluedOpeningQuote) break;
        end += 1;
      }
      var next = end;
      while (next < text.length && RegExp(r'\s').hasMatch(text[next])) {
        next += 1;
      }
      if (next >= text.length ||
          RegExp(r'''[A-Z0-9"“'‘(]''').hasMatch(text[next])) {
        output.add(text.substring(start, end).trim());
        start = next;
        index = next - 1;
      }
    }
    final tail = text.substring(start).trim();
    if (tail.isNotEmpty) output.add(tail);
    return output;
  }

  static bool _protectedPeriod(String current) {
    final lower = current.toLowerCase();
    const abbreviations = [
      'mr.',
      'mrs.',
      'ms.',
      'dr.',
      'prof.',
      'sr.',
      'jr.',
      'st.',
      'vs.',
      'etc.',
      'e.g.',
      'i.e.',
      'a.m.',
      'p.m.',
      'no.',
      'fig.',
      'chap.'
    ];
    return abbreviations.any(lower.endsWith) ||
        RegExp(r'(?:\b[A-Z]\.){1,4}$').hasMatch(current);
  }

  static List<String> _splitParagraphWithDp(String paragraph) {
    final tokens = paragraph.trim().split(RegExp(r'\s+'));
    if (tokens.length <= 20) {
      return [paragraph.trim()];
    }
    final size = tokens.length;
    final states = List.generate(
      size + 1,
      (_) => <int, ({double cost, int previousPosition, int previousLength})>{},
    );
    states[0][0] = (cost: 0, previousPosition: -1, previousLength: -1);
    for (var start = 0; start < size; start += 1) {
      if (states[start].isEmpty) continue;
      for (var end = start + 1;
          end <= size && end - start <= hardMaxWords;
          end += 1) {
        final chunk = tokens.sublist(start, end).join(' ');
        final length = end - start;
        final isFinal = end == size;
        final boundaryCost = isFinal ? 0.0 : _boundaryCost(tokens, end);
        final containsSemanticClauseBoundary = _containsRelativeClauseBoundary(
          tokens,
          start,
          end,
        );
        for (final entry in states[start].entries) {
          final candidate = entry.value.cost +
              _segmentCost(
                chunk,
                length: length,
                previousLength: entry.key,
                isFinal: isFinal,
                containsSemanticClauseBoundary: containsSemanticClauseBoundary,
              ) +
              (isFinal ? 0.0 : 60.0 + boundaryCost);
          final existing = states[end][length];
          if (existing == null || candidate < existing.cost) {
            states[end][length] = (
              cost: candidate,
              previousPosition: start,
              previousLength: entry.key,
            );
          }
        }
      }
    }
    if (states[size].isEmpty) {
      throw const FormatException('正文无法按 30 词硬上限分块');
    }
    var finalLength = states[size]
        .entries
        .reduce(
            (left, right) => left.value.cost <= right.value.cost ? left : right)
        .key;
    final chunks = <String>[];
    var cursor = size;
    while (cursor > 0) {
      final state = states[cursor][finalLength];
      if (state == null) throw const FormatException('分句回溯状态无效');
      chunks.add(tokens.sublist(state.previousPosition, cursor).join(' '));
      cursor = state.previousPosition;
      finalLength = state.previousLength;
    }
    return chunks.reversed.toList(growable: false);
  }

  static double _segmentCost(
    String text, {
    required int length,
    required int previousLength,
    required bool isFinal,
    required bool containsSemanticClauseBoundary,
  }) {
    const targetWords = 15.0;
    // Length decides whether another chunk is useful. Punctuation only ranks
    // where a necessary cut should go; it must never reward adding a cut.
    var cost = (length - targetWords) * (length - targetWords);
    final complete = _completeBreath(text);
    if (length < 10) {
      final shortfall = 10 - length;
      cost += shortfall * shortfall * (complete ? 8.0 : 20.0);
      final first = text
          .trim()
          .split(RegExp(r'\s+'))
          .first
          .toLowerCase()
          .replaceAll(RegExp(r'^[^a-z]+|[^a-z]+$'), '');
      if (const {'and', 'but', 'or', 'so', 'yet', 'for', 'of', 'to', 'from'}
          .contains(first)) {
        cost += shortfall * 40.0;
        cost += 600.0;
      }
    } else if (length > 20) {
      final softOverflow = length - 20;
      cost += softOverflow * softOverflow * 2.0;
      if (length > 22) {
        final excessiveOverflow = length - 22;
        cost += excessiveOverflow * excessiveOverflow * 15.0;
      }
      if (containsSemanticClauseBoundary) cost += 130.0;
    }
    if (length < 6 && !complete) {
      final orphan = 6 - length;
      cost += orphan * orphan * 90.0;
      if (isFinal) cost += 180.0;
    }
    if (previousLength > 0) {
      cost += (length - previousLength).abs();
    }
    return cost;
  }

  static bool _completeBreath(String text) =>
      RegExp(r'''[.!?…;:—–]["'”’)}\]]*$''').hasMatch(text.trim());

  static bool _containsRelativeClauseBoundary(
    List<String> tokens,
    int start,
    int end,
  ) {
    for (var position = start + 1; position < end; position += 1) {
      final right = tokens[position]
          .toLowerCase()
          .replaceAll(RegExp(r'^[^a-z]+|[^a-z]+$'), '');
      if (const {'who', 'which', 'whose'}.contains(right)) return true;
    }
    return false;
  }

  static double _boundaryCost(List<String> tokens, int position) {
    final left = tokens[position - 1];
    final right = tokens[position]
        .toLowerCase()
        .replaceAll(RegExp(r'^[^a-z]+|[^a-z]+$'), '');
    final bareLeft =
        left.toLowerCase().replaceAll(RegExp(r'^[^a-z]+|[^a-z]+$'), '');
    const speechAttributions = {'said', 'asked', 'replied', 'cried', 'shouted'};
    if (RegExp(r'''^["“'‘(]?[A-Z]\.$''').hasMatch(left) &&
        RegExp(r'^[A-Z]').hasMatch(tokens[position])) {
      return 5000;
    }
    if (RegExp(r'''[.!?…]["'”’)}\]]*$''').hasMatch(left)) {
      if (speechAttributions.contains(right)) return 2200;
      if (RegExp(r'^[a-z]').hasMatch(tokens[position])) return 2000;
      return 0;
    }
    if (RegExp(r'''[;:—–]["'”’)}\]]*$''').hasMatch(left)) return 20;
    if (RegExp(r''',["'”’)}\]]*$''').hasMatch(left)) {
      if (RegExp(r'(?:ing|ed)$').hasMatch(right)) return 5000;
      return 80;
    }
    const protectedHeads = {
      'a',
      'an',
      'the',
      'this',
      'that',
      'these',
      'those',
      'my',
      'your',
      'his',
      'her',
      'its',
      'our',
      'their',
      'of',
      'to',
      'from',
      'with',
      'by',
      'in',
      'on',
      'at',
      'into',
      'upon',
      'and',
      'or',
      'but',
      'so',
      'yet',
      'for',
      'can',
      'could',
      'may',
      'might',
      'must',
      'shall',
      'should',
      'will',
      'would',
      'am',
      'is',
      'are',
      'was',
      'were',
      'be',
      'been',
      'being',
      'have',
      'has',
      'had',
      'do',
      'does',
      'did',
      'me',
      'as',
      'if',
      'about',
      'like',
      'than',
      'very',
      'what',
      'how',
      'why',
      'where',
      'when',
      'which',
      'who'
    };
    if (protectedHeads.contains(bareLeft)) return 5000;
    const clauseStarts = {
      'although',
      'as',
      'because',
      'before',
      'if',
      'since',
      'that',
      'though',
      'unless',
      'when',
      'where',
      'whether',
      'while',
      'who',
      'which',
      'whose',
      'and',
      'but',
      'or',
      'so',
      'yet',
      'for'
    };
    if (const {'who', 'which', 'whose'}.contains(right)) return 40;
    return clauseStarts.contains(right) ? 60 : 240;
  }
}
