import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../data/models/picture_book_model.dart';
import 'api_cache_service.dart';
import 'database_service.dart';
import 'text_generation_service.dart';

class ChapterStoryOutline {
  const ChapterStoryOutline({
    required this.policyVersion,
    required this.contentHash,
    required this.title,
    required this.summary,
    required this.characters,
    required this.locations,
    required this.continuityNotes,
    required this.segments,
    required this.source,
    this.errorMessage,
  });

  final String policyVersion;
  final String contentHash;
  final String title;
  final String summary;
  final List<String> characters;
  final List<String> locations;
  final List<String> continuityNotes;
  final List<ChapterStorySegment> segments;
  final TextGenerationReplySource source;
  final String? errorMessage;

  Map<String, dynamic> toJson() => {
        'kind': 'chapter_story_outline',
        'policyVersion': policyVersion,
        'contentHash': contentHash,
        'title': title,
        'summary': summary,
        'characters': characters,
        'locations': locations,
        'continuityNotes': continuityNotes,
        'segments': segments.map((segment) => segment.toJson()).toList(),
        'source': source.name,
        if (errorMessage != null && errorMessage!.trim().isNotEmpty)
          'errorMessage': errorMessage,
      };

  String toConversationGuide({required String articleTitle}) {
    final title = articleTitle.trim().isEmpty ? this.title : articleTitle;
    final coverage = segments
        .map(
          (segment) =>
              '${segment.index + 1}. Sentences ${segment.sentenceStartIndex + 1}-${segment.sentenceEndIndex + 1}: ${segment.summary}',
        )
        .toList(growable: false);
    return [
      'Chapter summary: ${summary.trim().isEmpty ? ChapterStoryOutlineService._shorten(title, 160) : summary}',
      'Ordered coverage points:',
      if (coverage.isEmpty)
        '1. Discuss the chapter title "$title", the main event, the ending, and the meaning.'
      else
        ...coverage,
      'Character and setting facts: ${_factsLine()}',
      'Completion rubric: Finish only after the learner has discussed every ordered coverage point in sequence, including the ending and meaning.',
      'Ability assessment cues: Starter = one-word answers; Beginner = short phrases; Elementary = simple sentences; Pre-Intermediate = connected retelling; Intermediate = clear opinions with reasons; Upper-Intermediate = detailed retelling and inference.',
    ].join('\n');
  }

  String _factsLine() {
    final parts = <String>[
      if (characters.isNotEmpty) 'Characters: ${characters.join(', ')}.',
      if (locations.isNotEmpty) 'Settings: ${locations.join(', ')}.',
      if (continuityNotes.isNotEmpty) continuityNotes.join(' '),
    ];
    return parts.isEmpty
        ? 'Use only characters, places, objects, and events named or clearly implied by this chapter.'
        : parts.join(' ');
  }
}

class ChapterStorySegment {
  const ChapterStorySegment({
    required this.index,
    required this.title,
    required this.sentenceStartIndex,
    required this.sentenceEndIndex,
    required this.summary,
    required this.visualPrompt,
    required this.characters,
    required this.locations,
    required this.continuityNotes,
  });

  final int index;
  final String title;
  final int sentenceStartIndex;
  final int sentenceEndIndex;
  final String summary;
  final String visualPrompt;
  final List<String> characters;
  final List<String> locations;
  final List<String> continuityNotes;

  Map<String, dynamic> toJson() => {
        'index': index,
        'title': title,
        'sentenceStartIndex': sentenceStartIndex,
        'sentenceEndIndex': sentenceEndIndex,
        'summary': summary,
        'visualPrompt': visualPrompt,
        'characters': characters,
        'locations': locations,
        'continuityNotes': continuityNotes,
      };
}

class ChapterStoryOutlineService {
  static const cachePurpose = 'chapter_story_outline_v1';
  static const policyVersion = 'chapter_story_outline_v1';
  static const maxSegments = 12;

  static final Map<String, Future<ChapterStoryOutline>> _pending = {};

  static Future<ChapterStoryOutline> prepareOutline({
    required String articleTitle,
    required String articleContent,
    required List<String> sentences,
    int? articleId,
    StoryChapter? chapter,
    StorySeries? series,
  }) async {
    final cleanSentences = _cleanSentences(sentences, articleContent);
    final contentHash = await _contentHash(
      articleTitle: articleTitle,
      articleContent: articleContent,
      sentences: cleanSentences,
    );
    final existing = _outlineFromChapter(
      chapter,
      contentHash: contentHash,
      sentenceCount: cleanSentences.length,
    );
    if (existing != null &&
        (existing.source == TextGenerationReplySource.remote ||
            existing.source == TextGenerationReplySource.cached)) {
      return existing;
    }

    final pendingKey = articleId == null
        ? 'content:$contentHash'
        : 'article:$articleId:$contentHash';
    final pending = _pending[pendingKey];
    if (pending != null) {
      return pending;
    }

    final future = _prepareAndStore(
      articleTitle: articleTitle,
      articleContent: articleContent,
      sentences: cleanSentences,
      contentHash: contentHash,
      articleId: articleId,
      chapter: chapter,
      series: series,
    );
    _pending[pendingKey] = future;
    try {
      return await future;
    } finally {
      _pending.remove(pendingKey);
    }
  }

  static Future<String> contentHashFor({
    required String articleTitle,
    required String articleContent,
    required List<String> sentences,
  }) =>
      _contentHash(
        articleTitle: articleTitle,
        articleContent: articleContent,
        sentences: _cleanSentences(sentences, articleContent),
      );

  static ChapterStoryOutline buildLocalOutline({
    required String articleTitle,
    required String articleContent,
    required List<String> sentences,
    String contentHash = '',
    TextGenerationReplySource source = TextGenerationReplySource.mockNoKey,
    String? errorMessage,
  }) {
    final title =
        articleTitle.trim().isEmpty ? 'Untitled chapter' : articleTitle.trim();
    final cleanSentences = _cleanSentences(sentences, articleContent);
    final summary = cleanSentences.isEmpty
        ? _shorten(_normalizeContent(articleContent), 220)
        : _shorten(cleanSentences.take(3).join(' '), 220);
    final segmentCount = cleanSentences.isEmpty
        ? 1
        : min(maxSegments, max(1, (cleanSentences.length / 3).ceil()));
    final groupSize = cleanSentences.isEmpty
        ? 1
        : (cleanSentences.length / segmentCount).ceil();
    final segments = <ChapterStorySegment>[];
    if (cleanSentences.isEmpty) {
      final text = _shorten(_normalizeContent(articleContent), 260);
      segments.add(
        ChapterStorySegment(
          index: 0,
          title: 'Scene 1',
          sentenceStartIndex: 0,
          sentenceEndIndex: 0,
          summary: text.isEmpty ? 'Discuss the chapter opening.' : text,
          visualPrompt: text.isEmpty
              ? 'A warm opening story scene.'
              : 'Show this story moment: $text',
          characters: const [],
          locations: const [],
          continuityNotes: const [],
        ),
      );
    } else {
      for (var start = 0; start < cleanSentences.length; start += groupSize) {
        final end = min(cleanSentences.length, start + groupSize) - 1;
        final slice = cleanSentences.sublist(start, end + 1);
        final summaryText = _coverageSnippet(slice);
        segments.add(
          ChapterStorySegment(
            index: segments.length,
            title: 'Scene ${segments.length + 1}',
            sentenceStartIndex: start,
            sentenceEndIndex: end,
            summary: summaryText,
            visualPrompt:
                'Illustrate this ordered story scene with the correct recurring characters, setting, mood, and action: $summaryText',
            characters: _properNames(slice.join(' ')),
            locations: const [],
            continuityNotes: const [],
          ),
        );
      }
    }

    return ChapterStoryOutline(
      policyVersion: policyVersion,
      contentHash: contentHash,
      title: title,
      summary: summary,
      characters: _properNames(cleanSentences.join(' ')),
      locations: const [],
      continuityNotes: const [
        'Keep character appearance, costume, palette, and story world consistent across every picture-book image.',
      ],
      segments: segments,
      source: source,
      errorMessage: errorMessage,
    );
  }

  static List<TextGenerationTurn> outlinePromptTurns({
    required String articleTitle,
    required String articleContent,
    required List<String> sentences,
    StorySeries? series,
  }) {
    final title =
        articleTitle.trim().isEmpty ? 'Untitled chapter' : articleTitle.trim();
    final cleanSentences = _cleanSentences(sentences, articleContent);
    final numberedSentences = [
      for (var i = 0; i < cleanSentences.length; i += 1)
        '$i. ${cleanSentences[i]}',
    ].join('\n');
    return [
      const TextGenerationTurn(
        role: 'system',
        content:
            'You create structured storyboards for English picture-book learning chapters. Return only valid compact JSON. Do not use markdown. Split by natural story structure: scene, event, conflict, character decision, setting change, and ending. Use no more than $maxSegments segments. Each segment becomes exactly one generated image in a sequential image-generation request, not an image candidate.',
      ),
      TextGenerationTurn(
        role: 'user',
        content: [
          'Book or series title: ${series?.title.trim().isNotEmpty == true ? series!.title : title}',
          'Chapter title: $title',
          if (series != null && series.description.trim().isNotEmpty)
            'Book description: ${series.description.trim()}',
          '',
          'Return JSON with this shape:',
          '{"summary":"...","characters":["..."],"locations":["..."],"continuityNotes":["..."],"segments":[{"title":"...","sentenceStartIndex":0,"sentenceEndIndex":2,"summary":"...","visualPrompt":"...","characters":["..."],"locations":["..."],"continuityNotes":["..."]}]}',
          '',
          'Rules:',
          '- sentenceStartIndex and sentenceEndIndex are zero-based indexes into the numbered sentence list below.',
          '- Segments must be in order, cover every sentence from 0 to ${max(0, cleanSentences.length - 1)}, and must not overlap.',
          '- Use the smallest number of segments that preserves the story beats; short chapters may need 3-5, ordinary chapters 6-10, long chapters up to $maxSegments.',
          '- visualPrompt must describe the exact illustration for that segment and mention continuity details needed for the sequential group.',
          '- Keep the storyboard faithful to the current chapter.',
          '',
          'Numbered chapter sentences:',
          numberedSentences.isEmpty
              ? _normalizeContent(articleContent)
              : numberedSentences,
        ].join('\n'),
      ),
    ];
  }

  static ChapterStoryOutline? outlineFromJson(
    Map<String, dynamic> json, {
    required String contentHash,
    required int sentenceCount,
    TextGenerationReplySource source = TextGenerationReplySource.cached,
    String? fallbackTitle,
    String? errorMessage,
  }) {
    if (json['kind'] == 'chapter_story_outline' &&
        json['policyVersion'] != policyVersion) {
      return null;
    }
    final rawSegments = json['segments'];
    if (rawSegments is! List || rawSegments.isEmpty) {
      return null;
    }

    final segments = <ChapterStorySegment>[];
    for (final raw in rawSegments) {
      if (raw is! Map) {
        continue;
      }
      final start = _intValue(raw['sentenceStartIndex']);
      final end = _intValue(raw['sentenceEndIndex']);
      if (start == null || end == null || start > end) {
        continue;
      }
      segments.add(
        ChapterStorySegment(
          index: segments.length,
          title: _stringValue(raw['title'],
              fallback: 'Scene ${segments.length + 1}'),
          sentenceStartIndex: start,
          sentenceEndIndex: end,
          summary: _stringValue(raw['summary']),
          visualPrompt: _stringValue(raw['visualPrompt']),
          characters: _stringList(raw['characters']),
          locations: _stringList(raw['locations']),
          continuityNotes: _stringList(raw['continuityNotes']),
        ),
      );
    }
    final normalized = _normalizeSegments(
      segments,
      sentenceCount: max(1, sentenceCount),
    );
    if (normalized.isEmpty) {
      return null;
    }

    final title = _stringValue(json['title'], fallback: fallbackTitle ?? '');
    final summary = _stringValue(json['summary']);
    return ChapterStoryOutline(
      policyVersion: policyVersion,
      contentHash: contentHash,
      title: title,
      summary: summary,
      characters: _stringList(json['characters']),
      locations: _stringList(json['locations']),
      continuityNotes: _stringList(json['continuityNotes']),
      segments: normalized,
      source: source,
      errorMessage: errorMessage,
    );
  }

  static Future<ChapterStoryOutline> _prepareAndStore({
    required String articleTitle,
    required String articleContent,
    required List<String> sentences,
    required String contentHash,
    required int? articleId,
    required StoryChapter? chapter,
    required StorySeries? series,
  }) async {
    final fallback = buildLocalOutline(
      articleTitle: articleTitle,
      articleContent: articleContent,
      sentences: sentences,
      contentHash: contentHash,
    );
    final reply = await TextGenerationService.generate(
      turns: outlinePromptTurns(
        articleTitle: articleTitle,
        articleContent: articleContent,
        sentences: sentences,
        series: series,
      ),
      cachePurpose: cachePurpose,
      fallbackText: jsonEncode(fallback.toJson()),
      articleId: articleId,
      maxTokens: 2400,
    );
    final parsedJson = _decodeJsonObject(reply.text);
    final parsed = parsedJson == null
        ? null
        : outlineFromJson(
            parsedJson,
            contentHash: contentHash,
            sentenceCount: sentences.length,
            source: reply.source,
            fallbackTitle: articleTitle,
            errorMessage: reply.errorMessage,
          );
    final outline = parsed ??
        buildLocalOutline(
          articleTitle: articleTitle,
          articleContent: articleContent,
          sentences: sentences,
          contentHash: contentHash,
          source: reply.source,
          errorMessage: reply.errorMessage,
        );
    if (chapter != null) {
      await DatabaseService.updateStoryChapter(
        chapter.copyWith(
          summaryJson: ApiCacheService.canonicalJson(outline.toJson()),
          updatedAt: DateTime.now(),
        ),
      );
    }
    return outline;
  }

  static ChapterStoryOutline? _outlineFromChapter(
    StoryChapter? chapter, {
    required String contentHash,
    required int sentenceCount,
  }) {
    if (chapter == null) {
      return null;
    }
    final json = _decodeJsonObject(chapter.summaryJson);
    if (json == null ||
        json['kind'] != 'chapter_story_outline' ||
        json['policyVersion'] != policyVersion ||
        json['contentHash'] != contentHash) {
      return null;
    }
    final source = _sourceFromName(json['source']?.toString() ?? '');
    return outlineFromJson(
      json,
      contentHash: contentHash,
      sentenceCount: sentenceCount,
      source: source,
      fallbackTitle: chapter.chapterTitle,
      errorMessage: json['errorMessage']?.toString(),
    );
  }

  static Future<String> _contentHash({
    required String articleTitle,
    required String articleContent,
    required List<String> sentences,
  }) {
    return ApiCacheService.hashUtf8(
      ApiCacheService.canonicalJson({
        'title': articleTitle.trim(),
        'content': _normalizeContent(articleContent),
        'sentences': sentences,
        'policyVersion': policyVersion,
      }),
    );
  }

  static TextGenerationReplySource _sourceFromName(String name) {
    for (final value in TextGenerationReplySource.values) {
      if (value.name == name) {
        return value;
      }
    }
    return TextGenerationReplySource.mockNoKey;
  }

  static Map<String, dynamic>? _decodeJsonObject(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {
      final start = text.indexOf('{');
      final end = text.lastIndexOf('}');
      if (start >= 0 && end > start) {
        try {
          final decoded = jsonDecode(text.substring(start, end + 1));
          if (decoded is Map<String, dynamic>) {
            return decoded;
          }
          if (decoded is Map) {
            return decoded.map((key, value) => MapEntry(key.toString(), value));
          }
        } catch (_) {
          return null;
        }
      }
    }
    return null;
  }

  static List<ChapterStorySegment> _normalizeSegments(
    List<ChapterStorySegment> input, {
    required int sentenceCount,
  }) {
    final sorted = [...input]
      ..sort((a, b) => a.sentenceStartIndex.compareTo(b.sentenceStartIndex));
    final output = <ChapterStorySegment>[];
    var cursor = 0;
    for (final segment in sorted) {
      if (output.length >= maxSegments) {
        break;
      }
      var start =
          segment.sentenceStartIndex.clamp(0, sentenceCount - 1).toInt();
      var end = segment.sentenceEndIndex.clamp(0, sentenceCount - 1).toInt();
      if (end < cursor) {
        continue;
      }
      if (start > cursor) {
        start = cursor;
      }
      if (start < cursor) {
        start = cursor;
      }
      if (end < start) {
        continue;
      }
      output.add(_reindex(segment, output.length, start, end));
      cursor = end + 1;
      if (cursor >= sentenceCount) {
        break;
      }
    }
    if (output.isEmpty) {
      return const [];
    }
    if (cursor < sentenceCount) {
      final last = output.removeLast();
      output.add(_reindex(
          last, output.length, last.sentenceStartIndex, sentenceCount - 1));
    }
    if (output.length <= maxSegments) {
      return output
          .asMap()
          .entries
          .map((entry) => _reindex(
                entry.value,
                entry.key,
                entry.value.sentenceStartIndex,
                entry.value.sentenceEndIndex,
              ))
          .toList(growable: false);
    }
    return output.take(maxSegments).toList(growable: false);
  }

  static ChapterStorySegment _reindex(
    ChapterStorySegment segment,
    int index,
    int start,
    int end,
  ) {
    return ChapterStorySegment(
      index: index,
      title: segment.title.trim().isEmpty
          ? 'Scene ${index + 1}'
          : segment.title.trim(),
      sentenceStartIndex: start,
      sentenceEndIndex: end,
      summary: segment.summary.trim(),
      visualPrompt: segment.visualPrompt.trim().isEmpty
          ? segment.summary.trim()
          : segment.visualPrompt.trim(),
      characters: segment.characters,
      locations: segment.locations,
      continuityNotes: segment.continuityNotes,
    );
  }

  static List<String> _cleanSentences(
    List<String> sentences,
    String articleContent,
  ) {
    final clean = sentences
        .map((sentence) => sentence.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
    if (clean.isNotEmpty) {
      return clean;
    }
    final normalized = _normalizeContent(articleContent);
    if (normalized.isEmpty) {
      return const [];
    }
    return normalized
        .split(RegExp(r'(?<=[.!?])\s+'))
        .map((sentence) => sentence.trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
  }

  static String _coverageSnippet(List<String> group) {
    final joined = group.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (joined.length <= 180 || group.length <= 1) {
      return _shorten(joined, 180);
    }
    final first = _shorten(group.first, 82);
    final last = _shorten(group.last, 82);
    return '$first ... $last';
  }

  static List<String> _properNames(String text) {
    final names = <String>[];
    final seen = <String>{};
    for (final match in RegExp(
      r"\b[A-Z][A-Za-z']+(?:\s+(?:of|the|and|[A-Z][A-Za-z']+)){0,3}",
    ).allMatches(text)) {
      final name =
          (match.group(0) ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
      final lower = name.toLowerCase();
      if (name.isEmpty ||
          lower == 'chapter' ||
          lower == 'sentence' ||
          lower == 'story' ||
          lower == 'scene' ||
          RegExp(r'\d').hasMatch(name) ||
          !seen.add(lower)) {
        continue;
      }
      names.add(name);
      if (names.length >= 8) {
        break;
      }
    }
    return names;
  }

  static List<String> _stringList(Object? value) {
    if (value is List) {
      return value
          .map((item) => item.toString().replaceAll(RegExp(r'\s+'), ' ').trim())
          .where((item) => item.isNotEmpty)
          .take(12)
          .toList(growable: false);
    }
    if (value is String) {
      return value
          .split(RegExp(r'[,;，；、\n]'))
          .map((item) => item.replaceAll(RegExp(r'\s+'), ' ').trim())
          .where((item) => item.isNotEmpty)
          .take(12)
          .toList(growable: false);
    }
    return const [];
  }

  static String _stringValue(Object? value, {String fallback = ''}) {
    final text = value?.toString().replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  static int? _intValue(Object? value) {
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim());
    }
    return null;
  }

  static String _normalizeContent(String text) =>
      text.replaceAll(RegExp(r'[ \t]+'), ' ').trim();

  static String _shorten(String text, int maxLength) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= maxLength) {
      return normalized;
    }
    return '${normalized.substring(0, maxLength).trim()}...';
  }
}
