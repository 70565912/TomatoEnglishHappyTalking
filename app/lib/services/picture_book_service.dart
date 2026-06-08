import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/models/article_model.dart';
import '../data/models/picture_book_model.dart';
import 'api_cache_service.dart';
import 'chapter_story_outline_service.dart';
import 'database_service.dart';
import 'text_generation_service.dart';
import 'volc_image_service.dart';

typedef PictureBookProgressCallback = FutureOr<void> Function(
  Map<String, dynamic> state,
);

class PictureBookService {
  static final Map<String, String> _imageUriCache = <String, String>{};
  static const String _promptPolicyVersion = 'chapter_storyboard_group_v1';
  static const int _maxReferenceImagesPerRequest = int.fromEnvironment(
    'TOMATO_PICTURE_BOOK_MAX_REFERENCE_IMAGES',
    defaultValue: 6,
  );
  static const int _maxNewCharacterReferencesPerArticle = int.fromEnvironment(
    'TOMATO_PICTURE_BOOK_MAX_NEW_CHARACTER_REFS',
    defaultValue: 4,
  );
  static const bool _aiSeriesBibleEnabled = bool.fromEnvironment(
    'TOMATO_PICTURE_BOOK_AI_SERIES_BIBLE',
    defaultValue: false,
  );
  static const bool _aiPagePromptEnabled = bool.fromEnvironment(
    'TOMATO_PICTURE_BOOK_AI_PAGE_PROMPTS',
    defaultValue: false,
  );
  static const bool _referenceImagesEnabled = bool.fromEnvironment(
    'TOMATO_PICTURE_BOOK_REFERENCE_IMAGES',
    defaultValue: false,
  );

  static const String _naturalTextPolicy =
      'NATURAL TEXT POLICY: visible text is allowed when it naturally belongs in the chapter illustration, such as a book title, sign, playing-card markings, map details, labels, handwritten notes, or decorative lettering. Text is optional; do not rely on text alone to explain the story because the app displays subtitles separately.';

  static const String _safeClassicStoryPolicy =
      'SAFETY ADAPTATION FOR CLASSIC STORY NONSENSE: reinterpret severe royal threats or aggressive old-fashioned phrases as harmless theatrical royal anger, comic panic, exaggerated gestures, and confused reactions. Keep every character safe, whole, expressive, and storybook-friendly.';

  static const Map<String, dynamic> defaultStyleGuide = {
    'audience': 'Chinese-speaking teens and children learning English',
    'visualStyle':
        'bright warm English picture book illustration, story-rich, friendly characters, clear facial expressions, simple readable composition, gentle colors, not childish',
    'safety':
        'safe, warm, child-appropriate storybook imagery; no frightening adult content, no graphic violence, no adult sexual content, no hateful content, no realistic gore',
    'layout':
        'a coherent sequence of 16:9 story illustrations, one image per storyboard segment, cinematic picture-book framing, enough visual focus for app-rendered subtitles, natural text-bearing props are allowed when useful',
  };

  static Future<StorySeries> createSeries({
    required String title,
  }) async {
    final now = DateTime.now();
    final series = StorySeries(
      title: title.trim().isEmpty ? 'Picture Book Story' : title.trim(),
      styleGuideJson: ApiCacheService.canonicalJson(defaultStyleGuide),
      bibleJson: ApiCacheService.canonicalJson({
        'characters': <Map<String, dynamic>>[],
        'locations': <Map<String, dynamic>>[],
        'continuityNotes': <String>[],
        'chapterSummaries': <Map<String, dynamic>>[],
      }),
      createdAt: now,
      updatedAt: now,
    );
    final id = await DatabaseService.saveStorySeries(series);
    return series.copyWith(id: id);
  }

  static Future<StoryChapter> ensureChapterForArticle({
    required int seriesId,
    required Article article,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      throw StateError('Article must be saved before creating a story chapter');
    }
    final existing = await DatabaseService.getStoryChapterForArticle(articleId);
    if (existing != null) {
      return existing;
    }
    final now = DateTime.now();
    final order = await DatabaseService.nextStoryChapterOrder(seriesId);
    final chapter = StoryChapter(
      seriesId: seriesId,
      articleId: articleId,
      chapterOrder: order,
      chapterTitle: article.title,
      summaryJson: ApiCacheService.canonicalJson({
        'title': article.title,
        'summary': _fallbackChapterSummary(article.content),
      }),
      createdAt: now,
      updatedAt: now,
    );
    final id = await DatabaseService.saveStoryChapter(chapter);
    return StoryChapter(
      id: id,
      seriesId: chapter.seriesId,
      articleId: chapter.articleId,
      chapterOrder: chapter.chapterOrder,
      chapterTitle: chapter.chapterTitle,
      summaryJson: chapter.summaryJson,
      createdAt: chapter.createdAt,
      updatedAt: chapter.updatedAt,
    );
  }

  static Future<StoryChapter> attachArticleToSeries({
    required int seriesId,
    required Article article,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      throw StateError('Article must be saved before attaching to a series');
    }

    final existing = await DatabaseService.getStoryChapterForArticle(articleId);
    if (existing != null && existing.seriesId == seriesId) {
      return existing;
    }

    final now = DateTime.now();
    final order = await DatabaseService.nextStoryChapterOrder(seriesId);
    final chapter = StoryChapter(
      id: existing?.id,
      seriesId: seriesId,
      articleId: articleId,
      chapterOrder: order,
      chapterTitle: article.title,
      summaryJson: ApiCacheService.canonicalJson({
        'title': article.title,
        'summary': _fallbackChapterSummary(article.content),
      }),
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    final id = await DatabaseService.saveStoryChapter(chapter);
    return StoryChapter(
      id: chapter.id ?? id,
      seriesId: chapter.seriesId,
      articleId: chapter.articleId,
      chapterOrder: chapter.chapterOrder,
      chapterTitle: chapter.chapterTitle,
      summaryJson: chapter.summaryJson,
      createdAt: chapter.createdAt,
      updatedAt: chapter.updatedAt,
    );
  }

  static Future<void> generateForArticle({
    required Article article,
    required StoryChapter chapter,
    PictureBookProgressCallback? onProgress,
    bool regenerate = false,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      return;
    }

    final existingPages = await DatabaseService.getPictureBookPages(articleId);
    final series = await DatabaseService.getStorySeriesById(chapter.seriesId);
    if (series == null) {
      return;
    }

    final outline = await ChapterStoryOutlineService.prepareOutline(
      articleTitle: article.title,
      articleContent: article.content,
      sentences: article.sentences,
      articleId: articleId,
      chapter: chapter,
      series: series,
    );
    final pages = _segmentArticle(article, outline);
    if (pages.isEmpty) {
      return;
    }

    final existingPagesAreCurrent =
        _existingPagesMatchStoryboardPolicy(existingPages, pages);
    if (!regenerate &&
        existingPagesAreCurrent &&
        existingPages.every((page) =>
            page.status == 'ready' ||
            page.status == 'skipped' ||
            page.status == 'error')) {
      await _emit(articleId, onProgress);
      return;
    }

    if (regenerate || (existingPages.isNotEmpty && !existingPagesAreCurrent)) {
      await DatabaseService.deletePictureBookPagesForArticle(articleId);
    }

    await _updateSeriesBible(
      series: series,
      chapter: chapter,
      article: article,
    );

    for (final segment in pages) {
      final now = DateTime.now();
      final queued = PictureBookPage(
        articleId: articleId,
        seriesId: series.id,
        pageIndex: segment.pageIndex,
        sentenceStartIndex: segment.sentenceStartIndex,
        sentenceEndIndex: segment.sentenceEndIndex,
        paragraphText: segment.text,
        promptJson: ApiCacheService.canonicalJson({
          'status': 'queued',
          'style': defaultStyleGuide,
          'promptPolicyVersion': _promptPolicyVersion,
          'storyboard': segment.outlineJson,
        }),
        status: 'queued',
        createdAt: now,
        updatedAt: now,
      );
      await DatabaseService.upsertPictureBookPage(queued);
    }
    await _emit(articleId, onProgress);

    final refreshedSeries =
        await DatabaseService.getStorySeriesById(chapter.seriesId) ?? series;
    final promptedSegments = <_PromptedSegment>[];

    for (final segment in pages) {
      final promptPage = await _markPage(
        segment,
        articleId: articleId,
        seriesId: refreshedSeries.id,
        status: 'prompting',
      );
      await _emit(articleId, onProgress);

      final promptJson = await _buildPagePrompt(
        series: refreshedSeries,
        chapter: chapter,
        segment: segment,
        articleId: articleId,
      );
      final generatingPage = promptPage.copyWith(
        promptJson: ApiCacheService.canonicalJson(promptJson),
        status: 'generating',
        errorMessage: '',
        updatedAt: DateTime.now(),
      );
      await DatabaseService.upsertPictureBookPage(generatingPage);
      await _emit(articleId, onProgress);

      promptedSegments.add(
        _PromptedSegment(
          segment: segment,
          page: generatingPage,
          promptJson: promptJson,
          prompt: _imagePromptFrom(promptJson),
          characterNames: _characterNamesForPrompt(promptJson),
        ),
      );
    }

    final references =
        VolcImageService.supportsReferenceImages && _referenceImagesEnabled
            ? await _ensureReferenceAssets(
                series: refreshedSeries,
                articleId: articleId,
                promptedSegments: promptedSegments,
              )
            : const <StoryReferenceAsset>[];
    await _emit(articleId, onProgress);

    final groupResults = await VolcImageService.generatePictureBookImageGroup(
      requests: [
        for (final item in promptedSegments)
          VolcImageBatchRequest(
            pageIndex: item.segment.pageIndex,
            prompt: item.prompt,
            promptMetadata: item.promptJson,
          ),
      ],
      articleId: articleId,
      seriesId: refreshedSeries.id,
      referenceImagePaths: _referencePathsForBatch(
        references,
        promptedSegments,
      ),
      useSequential: true,
      reusePartialCache: false,
    );
    final groupResultByPage = {
      for (final result in groupResults)
        if (result.pageIndex != null) result.pageIndex!: result,
    };

    for (final item in promptedSegments) {
      final result = groupResultByPage[item.segment.pageIndex] ??
          VolcImageResult(
            source: VolcImageResultSource.failed,
            pageIndex: item.segment.pageIndex,
            errorMessage: '组图接口未返回第 ${item.segment.pageIndex + 1} 张图片',
          );
      final status = switch (result.source) {
        VolcImageResultSource.remote || VolcImageResultSource.cached => 'ready',
        VolcImageResultSource.skippedNoKey => 'skipped',
        VolcImageResultSource.failed => 'error',
      };
      await DatabaseService.upsertPictureBookPage(
        item.page.copyWith(
          imageCacheKey: result.cacheKey,
          imagePath: result.filePath,
          status: status,
          errorMessage: result.errorMessage ?? '',
          updatedAt: DateTime.now(),
        ),
      );
      await _emit(articleId, onProgress);
    }
  }

  static Future<void> regeneratePage({
    required int articleId,
    required int pageIndex,
    PictureBookProgressCallback? onProgress,
  }) async {
    final article = await DatabaseService.getArticleById(articleId);
    final chapter = await DatabaseService.getStoryChapterForArticle(articleId);
    if (article == null || chapter == null) {
      return;
    }

    final series = await DatabaseService.getStorySeriesById(chapter.seriesId);
    if (series == null) {
      return;
    }

    final outline = await ChapterStoryOutlineService.prepareOutline(
      articleTitle: article.title,
      articleContent: article.content,
      sentences: article.sentences,
      articleId: articleId,
      chapter: chapter,
      series: series,
    );
    final segments = _segmentArticle(article, outline);
    _PicturePageSegment? targetSegment;
    for (final segment in segments) {
      if (segment.pageIndex == pageIndex) {
        targetSegment = segment;
        break;
      }
    }
    if (targetSegment == null) {
      return;
    }

    final promptingPage = await _markPage(
      targetSegment,
      articleId: articleId,
      seriesId: series.id,
      status: 'prompting',
      imagePath: '',
      imageCacheKey: '',
      errorMessage: '',
    );
    await _emit(articleId, onProgress);

    final promptJson = await _buildPagePrompt(
      series: series,
      chapter: chapter,
      segment: targetSegment,
      articleId: articleId,
    );
    final generatingPage = promptingPage.copyWith(
      promptJson: ApiCacheService.canonicalJson(promptJson),
      imagePath: '',
      imageCacheKey: '',
      status: 'generating',
      errorMessage: '',
      updatedAt: DateTime.now(),
    );
    await DatabaseService.upsertPictureBookPage(generatingPage);
    await _emit(articleId, onProgress);

    final promptedSegment = _PromptedSegment(
      segment: targetSegment,
      page: generatingPage,
      promptJson: promptJson,
      prompt: _imagePromptFrom(promptJson),
      characterNames: _characterNamesForPrompt(promptJson),
    );
    final references =
        VolcImageService.supportsReferenceImages && _referenceImagesEnabled
            ? await _ensureReferenceAssets(
                series: series,
                articleId: articleId,
                promptedSegments: [promptedSegment],
              )
            : const <StoryReferenceAsset>[];
    await _emit(articleId, onProgress);

    final result = await VolcImageService.generatePictureBookImage(
      prompt: promptedSegment.prompt,
      promptMetadata: promptedSegment.promptJson,
      articleId: articleId,
      seriesId: series.id,
      pageIndex: targetSegment.pageIndex,
      referenceImagePaths: _referencePathsForPage(references, promptedSegment),
      cachePurpose: 'picture_book_image',
    );

    final status = switch (result.source) {
      VolcImageResultSource.remote || VolcImageResultSource.cached => 'ready',
      VolcImageResultSource.skippedNoKey => 'skipped',
      VolcImageResultSource.failed => 'error',
    };
    await DatabaseService.upsertPictureBookPage(
      generatingPage.copyWith(
        imageCacheKey: result.cacheKey ?? '',
        imagePath: result.filePath ?? '',
        status: status,
        errorMessage: result.errorMessage ?? '',
        updatedAt: DateTime.now(),
      ),
    );
    await _emit(articleId, onProgress);
  }

  static Future<Map<String, dynamic>> statePayload(int articleId) async {
    final chapter = await DatabaseService.getStoryChapterForArticle(articleId);
    final series = chapter == null
        ? null
        : await DatabaseService.getStorySeriesById(chapter.seriesId);
    final pages = await DatabaseService.getPictureBookPages(articleId);
    final pageJsons = await Future.wait(
      pages.map((page) => _pageJson(page, includeImageUri: false)),
    );
    final status = _overallStatus(pages);
    return {
      'articleId': articleId,
      'enabled': chapter != null,
      'status': status,
      'series': series?.toJson(),
      'chapter': chapter?.toJson(series),
      'pages': pageJsons,
    };
  }

  static Future<Map<String, dynamic>> pageImagePayload({
    required int articleId,
    required int pageIndex,
  }) async {
    final pages = await DatabaseService.getPictureBookPages(articleId);
    PictureBookPage? targetPage;
    for (final page in pages) {
      if (page.pageIndex == pageIndex) {
        targetPage = page;
        break;
      }
    }

    if (targetPage == null) {
      return {
        'articleId': articleId,
        'pageIndex': pageIndex,
        'imageUri': null,
      };
    }

    final imageUri = await _imageUriForPath(targetPage.imagePath);
    final imagePath = targetPage.imagePath?.trim() ?? '';
    return {
      'articleId': articleId,
      'pageIndex': pageIndex,
      'imageUri': imageUri,
      'missing': imageUri == null && imagePath.isNotEmpty,
      'errorMessage':
          imageUri == null && imagePath.isNotEmpty ? '绘本缓存文件丢失，请重试生成' : null,
    };
  }

  static bool _existingPagesMatchStoryboardPolicy(
    List<PictureBookPage> pages,
    List<_PicturePageSegment> segments,
  ) {
    if (pages.length != segments.length || segments.isEmpty) {
      return false;
    }
    final byIndex = {
      for (final page in pages) page.pageIndex: page,
    };
    for (final segment in segments) {
      final page = byIndex[segment.pageIndex];
      if (page == null ||
          page.sentenceStartIndex != segment.sentenceStartIndex ||
          page.sentenceEndIndex != segment.sentenceEndIndex) {
        return false;
      }
      final promptJson = _decodeJson(page.promptJson, const {});
      if (promptJson['promptPolicyVersion'] != _promptPolicyVersion) {
        return false;
      }
    }
    return true;
  }

  static Future<Map<String, dynamic>?> coverImagePayloadForArticle(
    int articleId,
  ) async {
    final pages = await DatabaseService.getPictureBookPages(articleId);
    for (final page in pages) {
      if (page.status != 'ready') {
        continue;
      }
      final imagePath = page.imagePath?.trim() ?? '';
      if (imagePath.isEmpty) {
        continue;
      }
      final imageUri = await _imageUriForPath(imagePath);
      if (imageUri == null) {
        continue;
      }
      return {
        'coverImagePath': imagePath,
        'coverImageUri': imageUri,
      };
    }
    return null;
  }

  static Future<void> _updateSeriesBible({
    required StorySeries series,
    required StoryChapter chapter,
    required Article article,
  }) async {
    final knownContinuityGuide = _knownSeriesContinuityGuide(series.title);
    final existingBible = _decodeJson(series.bibleJson, const {});
    final existingNotes = existingBible['continuityNotes'] is List
        ? (existingBible['continuityNotes'] as List)
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList(growable: true)
        : <String>[];
    if (knownContinuityGuide.isNotEmpty &&
        !existingNotes.contains(knownContinuityGuide)) {
      existingNotes.add(knownContinuityGuide);
    }
    if (!existingNotes.contains(
        'Keep the same friendly English picture-book style across chapters.')) {
      existingNotes.add(
        'Keep the same friendly English picture-book style across chapters.',
      );
    }
    final chapterSummaries = existingBible['chapterSummaries'] is List
        ? (existingBible['chapterSummaries'] as List)
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .where((item) => item['chapterOrder'] != chapter.chapterOrder)
            .toList(growable: true)
        : <Map<String, dynamic>>[];
    chapterSummaries.add({
      'chapterOrder': chapter.chapterOrder,
      'title': article.title,
      'summary': _fallbackChapterSummary(article.content),
    });
    final fallback = {
      'characters': existingBible['characters'] is List
          ? existingBible['characters']
          : <Map<String, dynamic>>[],
      'locations': existingBible['locations'] is List
          ? existingBible['locations']
          : <Map<String, dynamic>>[],
      'continuityNotes': existingNotes,
      'chapterSummaries': chapterSummaries,
    };
    if (!_aiSeriesBibleEnabled) {
      await DatabaseService.updateStorySeries(
        series.copyWith(
          bibleJson: ApiCacheService.canonicalJson(fallback),
          updatedAt: DateTime.now(),
        ),
      );
      return;
    }
    final reply = await TextGenerationService.generate(
      turns: [
        const TextGenerationTurn(
          role: 'system',
          content:
              'You maintain a compact story bible for a children and teen English picture book. Return only valid JSON. Keys: characters, locations, continuityNotes, chapterSummaries. Keep details visual and consistent.',
        ),
        TextGenerationTurn(
          role: 'user',
          content:
              'Existing story bible JSON:\n${series.bibleJson}\n\nStyle guide JSON:\n${series.styleGuideJson}\n${_optionalSection('Fixed continuity guide', knownContinuityGuide)}\nSafe visual adaptation rule:\n$_safeClassicStoryPolicy\n\nFull new chapter ${chapter.chapterOrder}: ${article.title}\n${_sanitizeForImagePrompt(article.content)}\n\nUpdate the story bible for consistent future illustration prompts. Preserve any fixed continuity guide details exactly. Return JSON only.',
        ),
      ],
      fallbackText: jsonEncode(fallback),
      cachePurpose: 'picture_book_series_bible',
      articleId: article.id,
    );
    final decoded = _decodeJson(reply.text, fallback);
    await DatabaseService.updateStorySeries(
      series.copyWith(
        bibleJson: ApiCacheService.canonicalJson(decoded),
        updatedAt: DateTime.now(),
      ),
    );
  }

  static Future<List<StoryReferenceAsset>> _ensureReferenceAssets({
    required StorySeries series,
    required int articleId,
    List<_PromptedSegment> promptedSegments = const [],
  }) async {
    final seriesId = series.id;
    if (seriesId == null) {
      return const [];
    }
    final available = await _validReferenceAssets(seriesId);
    final continuityGuide = _knownSeriesContinuityGuide(series.title);

    if (!available.any((asset) => asset.kind == 'style_character_reference')) {
      final promptJson = {
        'kind': 'series_reference',
        'seriesTitle': series.title,
        'continuityGuide': continuityGuide,
        'styleGuide': _decodeJson(series.styleGuideJson, defaultStyleGuide),
        'bible': _decodeJson(series.bibleJson, const <String, dynamic>{}),
        'prompt':
            'Create a style and main-cast reference image for a warm English picture book for teens and children. Show the recurring visual style, color palette, and friendly expressive character design language for the story series. If one or more main characters are already known in the story bible, show them in a simple lineup. Natural labels, title lettering, signs, or book details may appear if they help the reference, but they are optional. Use the book title and continuity guide to match the original story world when relevant.',
        'negativePrompt': defaultStyleGuide['safety'],
        'textPolicy': _naturalTextPolicy,
        'promptPolicyVersion': _promptPolicyVersion,
      };
      final result = await VolcImageService.generatePictureBookImage(
        prompt: _imagePromptFrom(promptJson),
        promptMetadata: promptJson,
        articleId: null,
        seriesId: seriesId,
        referenceImagePaths: const [],
        cachePurpose: 'picture_reference_image',
      );
      if (result.hasImage) {
        final now = DateTime.now();
        final asset = StoryReferenceAsset(
          seriesId: seriesId,
          kind: 'style_character_reference',
          name: 'Series style reference',
          filePath: result.filePath!,
          promptJson: ApiCacheService.canonicalJson(promptJson),
          cacheKey: result.cacheKey,
          createdAt: now,
          updatedAt: now,
        );
        final id = await DatabaseService.saveStoryReferenceAsset(asset);
        available.add(
          StoryReferenceAsset(
            id: id,
            seriesId: asset.seriesId,
            kind: asset.kind,
            name: asset.name,
            filePath: asset.filePath,
            promptJson: asset.promptJson,
            cacheKey: asset.cacheKey,
            createdAt: asset.createdAt,
            updatedAt: asset.updatedAt,
          ),
        );
      }
    }

    final existingCharacterNames = {
      for (final asset in available)
        if (asset.kind == 'character_reference')
          _normalizeCharacterName(asset.name),
    }..remove('');
    final styleReferencePaths = [
      for (final asset in available)
        if (asset.kind == 'style_character_reference') asset.filePath,
    ];
    var createdCount = 0;
    for (final name in _characterNamesForSegments(promptedSegments)) {
      final normalized = _normalizeCharacterName(name);
      if (normalized.isEmpty || existingCharacterNames.contains(normalized)) {
        continue;
      }
      if (createdCount >= _maxNewCharacterReferencesPerArticle) {
        break;
      }

      final promptJson = _characterReferencePrompt(
        series: series,
        characterName: name,
        promptedSegments: promptedSegments,
        continuityGuide: continuityGuide,
      );
      final result = await VolcImageService.generatePictureBookImage(
        prompt: _imagePromptFrom(promptJson),
        promptMetadata: promptJson,
        articleId: null,
        seriesId: seriesId,
        referenceImagePaths: styleReferencePaths,
        cachePurpose: 'picture_character_reference_image',
      );
      if (!result.hasImage) {
        continue;
      }

      final now = DateTime.now();
      final asset = StoryReferenceAsset(
        seriesId: seriesId,
        kind: 'character_reference',
        name: name,
        filePath: result.filePath!,
        promptJson: ApiCacheService.canonicalJson(promptJson),
        cacheKey: result.cacheKey,
        createdAt: now,
        updatedAt: now,
      );
      final id = await DatabaseService.saveStoryReferenceAsset(asset);
      available.add(
        StoryReferenceAsset(
          id: id,
          seriesId: asset.seriesId,
          kind: asset.kind,
          name: asset.name,
          filePath: asset.filePath,
          promptJson: asset.promptJson,
          cacheKey: asset.cacheKey,
          createdAt: asset.createdAt,
          updatedAt: asset.updatedAt,
        ),
      );
      existingCharacterNames.add(normalized);
      createdCount += 1;
    }

    return available;
  }

  static Future<List<StoryReferenceAsset>> _validReferenceAssets(
    int seriesId,
  ) async {
    final existing = await DatabaseService.getStoryReferenceAssets(seriesId);
    final available = <StoryReferenceAsset>[];
    for (final asset in existing) {
      final promptJson =
          _decodeJson(asset.promptJson, const <String, dynamic>{});
      if (promptJson['promptPolicyVersion'] == _promptPolicyVersion &&
          await File(asset.filePath).exists()) {
        available.add(asset);
      }
    }
    return available;
  }

  static Map<String, dynamic> _characterReferencePrompt({
    required StorySeries series,
    required String characterName,
    required List<_PromptedSegment> promptedSegments,
    required String continuityGuide,
  }) {
    final scenes = promptedSegments
        .where((item) => item.characterNames
            .map(_normalizeCharacterName)
            .contains(_normalizeCharacterName(characterName)))
        .map((item) => _sanitizeForImagePrompt(item.segment.text))
        .take(3)
        .join('\n');
    return {
      'kind': 'character_reference',
      'characterName': characterName,
      'seriesTitle': series.title,
      'continuityGuide': continuityGuide,
      'styleGuide': _decodeJson(series.styleGuideJson, defaultStyleGuide),
      'bible': _decodeJson(series.bibleJson, const <String, dynamic>{}),
      'sourceScenes': scenes,
      'prompt':
          'Create one character reference image for "$characterName" in the book/story series "${series.title}". Show the character as a consistent friendly English picture-book character for teens and children, with clear face, outfit, silhouette, color palette, and full-body proportions. Use the story bible, book title, continuity guide, and these scene excerpts to infer the right appearance. If the character belongs to a known public-domain classic, match the recognizable story role and era. Use a simple background. Natural labels or book-style decorative lettering may appear if useful, but the character design should remain the focus.',
      'negativePrompt': defaultStyleGuide['safety'],
      'textPolicy': _naturalTextPolicy,
      'promptPolicyVersion': _promptPolicyVersion,
    };
  }

  static List<String> _referencePathsForBatch(
    List<StoryReferenceAsset> references,
    List<_PromptedSegment> batch,
  ) {
    final maxCount =
        (15 - batch.length).clamp(0, _maxReferenceImagesPerRequest).toInt();
    final paths = <String>[];
    for (final item in batch) {
      paths
          .addAll(_referencePathsForPage(references, item, maxCount: maxCount));
    }
    return _dedupePaths(paths).take(maxCount).toList(growable: false);
  }

  static List<String> _referencePathsForPage(
    List<StoryReferenceAsset> references,
    _PromptedSegment item, {
    int maxCount = _maxReferenceImagesPerRequest,
  }) {
    if (references.isEmpty || maxCount <= 0) {
      return const [];
    }

    final names = item.characterNames.map(_normalizeCharacterName).toSet()
      ..remove('');
    final paths = <String>[];
    for (final asset in references) {
      if (asset.kind == 'style_character_reference') {
        paths.add(asset.filePath);
      }
    }
    for (final asset in references) {
      if (asset.kind != 'character_reference') {
        continue;
      }
      final normalized = _normalizeCharacterName(asset.name);
      if (names.contains(normalized) ||
          _normalizedTextContainsName(item.segment.text, normalized)) {
        paths.add(asset.filePath);
      }
    }
    if (paths.length <= 1) {
      for (final asset in references) {
        if (asset.kind == 'character_reference') {
          paths.add(asset.filePath);
          break;
        }
      }
    }
    return _dedupePaths(paths).take(maxCount).toList(growable: false);
  }

  static List<String> _dedupePaths(List<String> paths) {
    final seen = <String>{};
    final output = <String>[];
    for (final path in paths) {
      final trimmed = path.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) {
        continue;
      }
      output.add(trimmed);
    }
    return output;
  }

  static List<String> _characterNamesForSegments(
    List<_PromptedSegment> promptedSegments,
  ) {
    final names = <String>[];
    final seen = <String>{};
    for (final item in promptedSegments) {
      for (final name in item.characterNames) {
        final normalized = _normalizeCharacterName(name);
        if (normalized.isEmpty || !seen.add(normalized)) {
          continue;
        }
        names.add(name);
      }
    }
    return names;
  }

  static List<String> _characterNamesForPrompt(
    Map<String, dynamic> promptJson,
  ) {
    final names = <String>[];
    final seen = <String>{};
    void addName(String rawName) {
      final cleaned = _canonicalCharacterName(rawName);
      final normalized = _normalizeCharacterName(cleaned);
      if (normalized.isEmpty || !seen.add(normalized)) {
        return;
      }
      names.add(cleaned);
    }

    final characters = promptJson['characters'];
    if (characters is List) {
      for (final item in characters) {
        if (item is Map) {
          addName(
              item['name']?.toString() ?? item['character']?.toString() ?? '');
        } else {
          addName(item.toString());
        }
      }
    } else if (characters is String) {
      for (final part in characters.split(RegExp(r'[,;，；、\n]| and '))) {
        addName(part);
      }
    }

    final paragraph = promptJson['paragraphText']?.toString() ?? '';
    final knownNames = _knownCharacterNamesForText(paragraph);
    for (final name in knownNames) {
      addName(name);
    }
    for (final match in RegExp(
      r"\b[A-Z][A-Za-z']+(?:\s+(?:of|the|and|[A-Z][A-Za-z']+)){0,3}",
    ).allMatches(paragraph)) {
      addName(match.group(0) ?? '');
    }
    return names;
  }

  static List<String> _knownCharacterNamesForText(String text) {
    final names = <String>[];
    final seen = <String>{};
    for (final match in RegExp(
      r"\b[A-Z][A-Za-z']+(?:\s+(?:of|the|and|[A-Z][A-Za-z']+)){0,3}",
    ).allMatches(text)) {
      final name = _canonicalCharacterName(match.group(0) ?? '');
      final normalized = _normalizeCharacterName(name);
      if (normalized.isNotEmpty && seen.add(normalized)) {
        names.add(name);
      }
      if (names.length >= 8) {
        break;
      }
    }
    return names;
  }

  static String _canonicalCharacterName(String rawName) {
    var name = rawName
        .replaceAll(RegExp(r'["“”‘’]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    name = name.replaceFirst(RegExp(r"^the\s+", caseSensitive: false), '');
    name = name.replaceFirst(RegExp(r"^a\s+", caseSensitive: false), '');
    name = name.replaceFirst(RegExp(r"^an\s+", caseSensitive: false), '');
    name = name.replaceFirst(RegExp(r"'s$", caseSensitive: false), '');
    name = name.trim();
    final lower = name.toLowerCase();
    const rejected = {
      '',
      'a',
      'an',
      'and',
      'as',
      'at',
      'book',
      'chapter',
      'english',
      'he',
      'her',
      'his',
      'image',
      'it',
      'my',
      'no',
      'one',
      'paragraph',
      'picture book',
      'scene',
      'series',
      'story',
      'style',
      'table',
      'the',
      'they',
      'there',
      'very',
      'we',
      'you',
    };
    if (rejected.contains(lower)) {
      return '';
    }
    final wordCount = RegExp(r"[A-Za-z]+").allMatches(name).length;
    if (wordCount == 0 || wordCount > 4) {
      return '';
    }
    if (RegExp(r'\d').hasMatch(name)) {
      return '';
    }
    return name;
  }

  static String _normalizeCharacterName(String value) =>
      _canonicalCharacterName(value).toLowerCase();

  static bool _normalizedTextContainsName(String text, String normalizedName) {
    if (normalizedName.isEmpty) {
      return false;
    }
    return text.toLowerCase().contains(normalizedName);
  }

  static Future<Map<String, dynamic>> _buildPagePrompt({
    required StorySeries series,
    required StoryChapter chapter,
    required _PicturePageSegment segment,
    required int articleId,
  }) async {
    final continuityGuide = _knownSeriesContinuityGuide(series.title);
    final safeChapterStory = _sanitizeForImagePrompt(segment.text);
    final storyCharacters = _knownCharacterNamesForText(safeChapterStory);
    final fallback = {
      'scene':
          'Picture-book storyboard image ${segment.pageIndex + 1} of ${segment.pageCount}: ${segment.title}.',
      'characters':
          segment.characters.isNotEmpty ? segment.characters : storyCharacters,
      'prompt':
          '${defaultStyleGuide['visualStyle']}. Create image ${segment.pageIndex + 1} of ${segment.pageCount} in a continuous 16:9 picture-book sequence for the book/story series "${series.title}" and chapter "${chapter.chapterTitle}". This image corresponds only to this storyboard segment, but it must visually match the same characters, costumes, setting logic, color palette, and story world used by the other images in the same generated group. Segment title: ${segment.title}. Segment summary: ${segment.summary}. Visual direction: ${segment.visualPrompt}. Segment story text: $safeChapterStory. $_naturalTextPolicy $_safeClassicStoryPolicy',
      'negativePrompt': defaultStyleGuide['safety'],
      'textPolicy': _naturalTextPolicy,
      'safeClassicStoryPolicy': _safeClassicStoryPolicy,
      'continuityGuide': continuityGuide,
      'chapterTitle': chapter.chapterTitle,
      'segmentTitle': segment.title,
      'segmentSummary': segment.summary,
      'visualPrompt': segment.visualPrompt,
      'pageCount': segment.pageCount,
      'storyboard': segment.outlineJson,
      'segmentStoryText': segment.text,
      'safeSegmentStoryText': safeChapterStory,
    };
    if (!_aiPagePromptEnabled) {
      return {
        ...fallback,
        'styleGuide': _decodeJson(series.styleGuideJson, defaultStyleGuide),
        'seriesTitle': series.title,
        'continuityGuide': continuityGuide,
        'chapterOrder': chapter.chapterOrder,
        'pageIndex': segment.pageIndex,
        'textPolicy': _naturalTextPolicy,
        'promptPolicyVersion': _promptPolicyVersion,
        'paragraphText': segment.text,
        'segmentStoryText': segment.text,
        'safeSegmentStoryText': safeChapterStory,
      };
    }
    final reply = await TextGenerationService.generate(
      turns: [
        const TextGenerationTurn(
          role: 'system',
          content:
              'You write image prompts for one image inside a sequential English picture-book group for teens and children. Return only valid compact JSON with keys scene, characters, prompt, negativePrompt. The image prompt must be visual, concrete, safe, and based on the storyboard segment. It must preserve character and setting continuity with the other images in the same generated group. Visible text is allowed when it naturally belongs in the scene. If the source is a classic story with severe royal threats or comic panic, adapt it into harmless theatrical emotion and keep every character safe and whole.',
        ),
        TextGenerationTurn(
          role: 'user',
          content:
              'Series title: ${series.title}\nStyle guide JSON:\n${series.styleGuideJson}\nStory bible JSON:\n${series.bibleJson}\n${_optionalSection('Fixed continuity guide', continuityGuide)}\nNatural text policy:\n$_naturalTextPolicy\nSafe classic story adaptation rule:\n$_safeClassicStoryPolicy\n\nChapter ${chapter.chapterOrder}: ${chapter.chapterTitle}\nStoryboard image ${segment.pageIndex + 1} of ${segment.pageCount}: ${segment.title}\nStoryboard JSON:\n${jsonEncode(segment.outlineJson)}\nSegment story content:\n$safeChapterStory\n\nCreate one 16:9 illustration prompt for this exact storyboard image. Keep the correct book, setting, characters, mood, and action, and make it visually continuous with the rest of the same sequential group. Prioritize the current segment content over unrelated earlier events. Return JSON only.',
        ),
      ],
      fallbackText: jsonEncode(fallback),
      cachePurpose: 'picture_book_page_prompt',
      articleId: articleId,
    );
    final parsed = _decodeJson(reply.text, fallback);
    return {
      ...fallback,
      ...parsed,
      'styleGuide': _decodeJson(series.styleGuideJson, defaultStyleGuide),
      'seriesTitle': series.title,
      'continuityGuide': continuityGuide,
      'chapterOrder': chapter.chapterOrder,
      'pageIndex': segment.pageIndex,
      'textPolicy': _naturalTextPolicy,
      'promptPolicyVersion': _promptPolicyVersion,
      'paragraphText': segment.text,
      'segmentStoryText': segment.text,
      'safeSegmentStoryText': safeChapterStory,
    };
  }

  static Future<PictureBookPage> _markPage(
    _PicturePageSegment segment, {
    required int articleId,
    required int? seriesId,
    required String status,
    Map<String, dynamic>? promptJson,
    String? imagePath,
    String? imageCacheKey,
    String? errorMessage,
  }) async {
    final existing = await DatabaseService.getPictureBookPages(articleId);
    PictureBookPage? current;
    for (final page in existing) {
      if (page.pageIndex == segment.pageIndex) {
        current = page;
        break;
      }
    }
    final now = DateTime.now();
    final page = PictureBookPage(
      id: current?.id,
      articleId: articleId,
      seriesId: seriesId,
      pageIndex: segment.pageIndex,
      sentenceStartIndex: segment.sentenceStartIndex,
      sentenceEndIndex: segment.sentenceEndIndex,
      paragraphText: segment.text,
      promptJson: promptJson == null
          ? (current?.promptJson ?? '{}')
          : ApiCacheService.canonicalJson(promptJson),
      imageCacheKey: imageCacheKey ?? current?.imageCacheKey,
      imagePath: imagePath ?? current?.imagePath,
      status: status,
      errorMessage: errorMessage ?? '',
      createdAt: current?.createdAt ?? now,
      updatedAt: now,
    );
    await DatabaseService.upsertPictureBookPage(page);
    return page;
  }

  static List<_PicturePageSegment> _segmentArticle(
    Article article,
    ChapterStoryOutline outline,
  ) {
    final sentences = article.sentences
        .map((sentence) => sentence.trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
    if (sentences.isEmpty) {
      return const [];
    }

    return outline.segments.map((segment) {
      final start =
          segment.sentenceStartIndex.clamp(0, sentences.length - 1).toInt();
      final end =
          segment.sentenceEndIndex.clamp(start, sentences.length - 1).toInt();
      final text = sentences.sublist(start, end + 1).join(' ');
      return _PicturePageSegment(
        pageIndex: segment.index,
        pageCount: outline.segments.length,
        sentenceStartIndex: start,
        sentenceEndIndex: end,
        text: _normalizeFullChapterStoryForPrompt(text),
        title: segment.title,
        summary: segment.summary,
        visualPrompt: segment.visualPrompt,
        characters: segment.characters,
        locations: segment.locations,
        continuityNotes: [
          ...outline.continuityNotes,
          ...segment.continuityNotes,
        ],
        outlineJson: segment.toJson(),
      );
    }).toList(growable: false);
  }

  static String _normalizeFullChapterStoryForPrompt(String text) {
    final paragraphs = text
        .split(RegExp(r'\n\s*\n+'))
        .map((paragraph) => paragraph.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((paragraph) => paragraph.isNotEmpty)
        .toList(growable: false);
    if (paragraphs.isEmpty) {
      return text.replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    return paragraphs.join('\n\n');
  }

  @visibleForTesting
  static List<Map<String, dynamic>> pictureSegmentsForTest(Article article) {
    final outline = ChapterStoryOutlineService.buildLocalOutline(
      articleTitle: article.title,
      articleContent: article.content,
      sentences: article.sentences,
    );
    return _segmentArticle(article, outline)
        .map(
          (segment) => {
            'pageIndex': segment.pageIndex,
            'sentenceStartIndex': segment.sentenceStartIndex,
            'sentenceEndIndex': segment.sentenceEndIndex,
            'title': segment.title,
            'summary': segment.summary,
            'text': segment.text,
          },
        )
        .toList(growable: false);
  }

  static Future<Map<String, dynamic>> _pageJson(
    PictureBookPage page, {
    bool includeImageUri = true,
  }) async {
    final json = page.toJson();
    if (!includeImageUri) {
      return json;
    }

    final imageUri = await _imageUriForPath(page.imagePath);
    if (imageUri != null) {
      json['imageUri'] = imageUri;
    }
    return json;
  }

  static Future<String?> _imageUriForPath(String? rawPath) async {
    final imagePath = rawPath?.trim() ?? '';
    if (imagePath.isEmpty) {
      return null;
    }

    final cached = _imageUriCache[imagePath];
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    final file = File(imagePath);
    if (!await file.exists()) {
      return null;
    }

    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      return null;
    }

    final imageUri =
        'data:${_imageContentType(imagePath)};base64,${base64Encode(bytes)}';
    _imageUriCache[imagePath] = imageUri;
    return imageUri;
  }

  static String _imageContentType(String imagePath) {
    final lower = imagePath.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    return 'image/png';
  }

  static String _overallStatus(List<PictureBookPage> pages) {
    if (pages.isEmpty) {
      return 'empty';
    }
    if (pages.any((page) =>
        page.status == 'queued' ||
        page.status == 'prompting' ||
        page.status == 'generating')) {
      return 'generating';
    }
    if (pages.every((page) => page.status == 'ready')) {
      return 'ready';
    }
    if (pages.every((page) => page.status == 'skipped')) {
      return 'skipped';
    }
    if (pages.any((page) => page.status == 'ready')) {
      return 'partial';
    }
    return 'error';
  }

  static Future<void> _emit(
    int articleId,
    PictureBookProgressCallback? callback,
  ) async {
    if (callback == null) {
      return;
    }
    try {
      await callback(await statePayload(articleId));
    } catch (error) {
      debugPrint('[PictureBookService] state callback failed: $error');
    }
  }

  static String _imagePromptFrom(Map<String, dynamic> promptJson) {
    final prompt = _sanitizeForImagePrompt(
      promptJson['prompt']?.toString().trim() ?? '',
    );
    final seriesTitle = promptJson['seriesTitle']?.toString().trim() ?? '';
    final promptContinuity =
        promptJson['continuityGuide']?.toString().trim() ?? '';
    final knownContinuity = _knownSeriesContinuityGuide(seriesTitle);
    final continuityGuide =
        promptContinuity.isNotEmpty ? promptContinuity : knownContinuity;
    final storyContext = _seriesStoryContext(seriesTitle);
    final sceneGuard = _knownSeriesSceneGuard(seriesTitle);
    final style = promptJson['styleGuide']?.toString() ??
        defaultStyleGuide['visualStyle'].toString();
    final pageIndex = (promptJson['pageIndex'] as num?)?.toInt();
    final pageCount = (promptJson['pageCount'] as num?)?.toInt();
    final imageNumber = pageIndex == null ? '' : '${pageIndex + 1}';
    final sequenceLine = pageCount == null || pageIndex == null
        ? 'This image is one page in a coherent sequential picture-book storyboard.'
        : 'This image is page $imageNumber of $pageCount in a coherent sequential picture-book storyboard. It is not a candidate variant.';
    return [
      'Create one 16:9 English picture-book scene illustration for an app.',
      sequenceLine,
      if (seriesTitle.isNotEmpty)
        'BOOK TITLE / SERIES TITLE: $seriesTitle. Use this title to keep the story world, recurring characters, tone, and chapter continuity accurate.',
      if (storyContext.isNotEmpty) 'STORY CONTEXT: $storyContext',
      if (continuityGuide.isNotEmpty) 'CONTINUITY GUIDE: $continuityGuide',
      if (sceneGuard.isNotEmpty) 'SCENE GUARD: $sceneGuard',
      _naturalTextPolicy,
      _safeClassicStoryPolicy,
      prompt.isEmpty ? 'A warm English picture book illustration.' : prompt,
      'Style: $style',
      'Audience: teens and children learning English.',
      'Use the book title, chapter title, and current storyboard segment as the priority. Show the segment setting, main characters, props, mood, and action in one cohesive scene.',
      'Keep recurring characters, costumes, color palette, and setting logic visually consistent with the other images in the same generated group.',
      'Do not import unrelated characters or locations from earlier segments unless the current segment mentions or strongly implies them.',
      'The app overlays subtitles separately, so readable text can be decorative or atmospheric, but facial expression, posture, action, and setting should carry the story.',
    ].join('\n');
  }

  static String _sanitizeForImagePrompt(String text) {
    var safe = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (safe.isEmpty) {
      return safe;
    }

    final replacements = <RegExp, String>{
      RegExp(r'\bunder sentence of execution\b', caseSensitive: false):
          'in serious trouble with the Queen',
      RegExp(r'\bsentence of execution\b', caseSensitive: false):
          'serious royal punishment',
      RegExp(r'\bexecution\b', caseSensitive: false): 'strict royal punishment',
      RegExp(r'\bbehead(?:ing|ed)?\b', caseSensitive: false):
          'dramatic royal punishment',
      RegExp(r'\bOff with (?:his|her|their|its) head!?\b',
              caseSensitive: false):
          'the Queen shouts an exaggerated angry command',
      RegExp(r'\bheads? (?:off|cut off)\b', caseSensitive: false):
          'royal punishment',
      RegExp(r"\bbox(?:ed|ing)? the Queen's ears\b", caseSensitive: false):
          'offended the Queen in a comic way',
      RegExp(r'\bfighting\b', caseSensitive: false): 'scrambling',
      RegExp(r'\bblow with its head\b', caseSensitive: false):
          'gentle nudge with its head',
      RegExp(r'\bgive the hedgehog a blow\b', caseSensitive: false):
          'nudge the hedgehog',
    };
    for (final entry in replacements.entries) {
      safe = safe.replaceAll(entry.key, entry.value);
    }
    return safe.trim();
  }

  @visibleForTesting
  static String imagePromptForTest(Map<String, dynamic> promptJson) {
    return _imagePromptFrom(promptJson);
  }

  static String _optionalSection(String title, String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    return '$title:\n$trimmed\n\n';
  }

  static String _knownSeriesContinuityGuide(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    return 'Use the book title "$trimmed", the saved series bible, previous chapter summaries, and the current chapter story to infer recurring characters, era, costumes, props, locations, visual tone, and story world rules. Keep recurring characters consistent when they appear or are strongly implied in the current chapter. Do not import unrelated characters, props, or locations from earlier chapters unless the current chapter story mentions or clearly requires them.';
  }

  static String _seriesStoryContext(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    return 'This is one image in a coherent illustrated chapter sequence from the book or story series "$trimmed". Use the book title, existing series bible, prior chapter continuity, and current chapter storyboard to keep the story world, recurring characters, era, tone, and setting consistent. Do not reinterpret it as an unrelated generic children\'s lesson or as another book.';
  }

  static String _knownSeriesSceneGuard(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    return 'The setting must come from the current "$trimmed" chapter title and story content first. Use the saved series references only for continuity. Avoid modern classroom, learning-room, or unrelated educational props unless the source chapter explicitly requires them.';
  }

  static Map<String, dynamic> _decodeJson(
    String text,
    Map<String, dynamic> fallback,
  ) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return decoded;
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
        } catch (_) {
          // Fall through to fallback.
        }
      }
    }
    return fallback;
  }

  static String _fallbackChapterSummary(String content) {
    final normalized = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    return _shorten(normalized, 260);
  }

  static String _shorten(String text, int maxLength) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= maxLength) {
      return normalized;
    }
    return normalized.substring(0, maxLength).trim();
  }
}

class _PicturePageSegment {
  const _PicturePageSegment({
    required this.pageIndex,
    required this.pageCount,
    required this.sentenceStartIndex,
    required this.sentenceEndIndex,
    required this.text,
    required this.title,
    required this.summary,
    required this.visualPrompt,
    required this.characters,
    required this.locations,
    required this.continuityNotes,
    required this.outlineJson,
  });

  final int pageIndex;
  final int pageCount;
  final int sentenceStartIndex;
  final int sentenceEndIndex;
  final String text;
  final String title;
  final String summary;
  final String visualPrompt;
  final List<String> characters;
  final List<String> locations;
  final List<String> continuityNotes;
  final Map<String, dynamic> outlineJson;
}

class _PromptedSegment {
  const _PromptedSegment({
    required this.segment,
    required this.page,
    required this.promptJson,
    required this.prompt,
    required this.characterNames,
  });

  final _PicturePageSegment segment;
  final PictureBookPage page;
  final Map<String, dynamic> promptJson;
  final String prompt;
  final List<String> characterNames;
}
