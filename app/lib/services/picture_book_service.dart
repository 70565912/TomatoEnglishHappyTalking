import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path_lib;

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
  static final Map<String, String> _thumbnailPathCache = <String, String>{};
  static final Queue<_PictureBookGenerationJob> _generationQueue =
      Queue<_PictureBookGenerationJob>();
  static final Map<String, _PictureBookPromptReviewDraft> _promptReviewDrafts =
      <String, _PictureBookPromptReviewDraft>{};
  static final Map<int, int> _scheduledGenerationCounts = <int, int>{};
  static int _activeGenerationJobs = 0;
  static int _promptReviewSequence = 0;
  static const int _creationThumbnailMaxWidth = 640;
  static const int _creationThumbnailMaxHeight = 360;
  static const String _promptPolicyVersion = 'picture_book_prompt_v4';
  static const String _chapterPlanCachePurpose = 'picture_book_chapter_plan_v4';
  static const String _chapterPlanPolicyVersion =
      'picture_book_chapter_plan_v4';
  static const String _bookDescriptionRefreshPurpose =
      'picture_book_prompt_v4_book_description_refresh';
  static const String _bookDescriptionDraftPurpose =
      'picture_book_prompt_v4_book_description_draft';
  static const String _storyBriefRefreshPurpose =
      'picture_book_prompt_v4_story_refresh';
  static const String _chapterBriefRefreshPurpose =
      'picture_book_prompt_v4_chapter_refresh';
  static const String _scenesRefreshPurpose =
      'picture_book_prompt_v4_scenes_refresh';
  static const int _maxConcurrentGenerationJobs = int.fromEnvironment(
    'TOMATO_PICTURE_BOOK_MAX_CONCURRENT_JOBS',
    defaultValue: 1,
  );
  static Future<StorySeries> createSeries({
    required String title,
    String description = '',
  }) async {
    final now = DateTime.now();
    final series = StorySeries(
      title: title.trim().isEmpty ? 'Picture Book Story' : title.trim(),
      description: description.trim(),
      createdAt: now,
      updatedAt: now,
    );
    final id = await DatabaseService.saveStorySeries(series);
    return series.copyWith(id: id);
  }

  static Future<String> suggestBookDescription({
    required Article article,
    required StoryChapter chapter,
    required String seriesTitle,
    String currentDescription = '',
  }) async {
    final fallback = _fallbackBookDescription(
      seriesTitle: seriesTitle,
      article: article,
    );
    final reply = await TextGenerationService.generate(
      turns: _bookDescriptionRefreshPromptTurns(
        article: article,
        chapter: chapter,
        seriesTitle: seriesTitle.trim().isEmpty
            ? article.title.trim()
            : seriesTitle.trim(),
        bookDescription: currentDescription,
        storyBrief: '',
        chapterBrief: '',
      ),
      cachePurpose: _bookDescriptionDraftPurpose,
      fallbackText: jsonEncode({'bookDescription': fallback}),
      articleId: article.id,
      maxTokens: 700,
    );
    final raw = _decodeJson(reply.text, const <String, dynamic>{});
    final generated = _sanitizeForImagePrompt(
      raw['bookDescription']?.toString().trim() ?? reply.text.trim(),
    );
    final description = generated.isEmpty ? fallback : generated;
    return _shorten(description, 1000);
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

  static Future<ChapterPicturePlan> ensureChapterPlanForArticle({
    required Article article,
    required StoryChapter chapter,
    StorySeries? series,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      throw StateError('Article must be saved before planning picture book');
    }
    final currentSeries =
        series ?? await DatabaseService.getStorySeriesById(chapter.seriesId);
    if (currentSeries == null) {
      throw const TextGenerationException('文本提交处理失败：书籍信息不存在，请重试。');
    }

    final contentHash = await ChapterStoryOutlineService.contentHashFor(
      articleTitle: article.title,
      articleContent: article.content,
      sentences: article.sentences,
    );
    final existing = _chapterPlanFromSummary(
      chapter.summaryJson,
      contentHash: contentHash,
      sentenceCount: article.sentences.length,
    );
    if (existing != null) {
      return existing;
    }

    final reply = await TextGenerationService.generateStrict(
      turns: _chapterPlanPromptTurns(
        article: article,
        chapter: chapter,
        series: currentSeries,
      ),
      cachePurpose: _chapterPlanCachePurpose,
      articleId: articleId,
      maxTokens: 5200,
      receiveTimeout: _chapterPlanReceiveTimeout(article),
      jsonResponse: true,
    );
    final raw = _decodeJson(reply.text, const <String, dynamic>{});
    final plan = _chapterPlanFromJson(
      raw,
      contentHash: contentHash,
      sentenceCount: article.sentences.length,
      source: reply.source,
      fallbackTitle: article.title,
    );
    if (plan == null) {
      throw const TextGenerationException(
        '文本提交处理失败：AI 未返回有效绘本分镜，请重试。',
      );
    }
    final summaryJson = {
      'planKind': _chapterPlanCachePurpose,
      'planPolicyVersion': _chapterPlanPolicyVersion,
      'contentHash': contentHash,
      'title': article.title,
      'storyBrief': plan.storyBrief,
      'chapterBrief': plan.chapterBrief,
      'scenes': plan.scenes.map((scene) => scene.toJson()).toList(),
    };
    await DatabaseService.updateStoryChapter(
      chapter.copyWith(
        summaryJson: ApiCacheService.canonicalJson(summaryJson),
        updatedAt: DateTime.now(),
      ),
    );
    return plan;
  }

  static Future<Map<String, dynamic>> promptReviewPayload({
    required Article article,
    required StoryChapter chapter,
    bool regenerate = false,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      throw StateError('Article must be saved before reviewing picture book');
    }

    final currentChapter =
        await DatabaseService.getStoryChapterForArticle(articleId) ?? chapter;
    final series =
        await DatabaseService.getStorySeriesById(currentChapter.seriesId);
    if (series == null) {
      throw const TextGenerationException('文本提交处理失败：书籍信息不存在，请重试。');
    }

    final plan = await ensureChapterPlanForArticle(
      article: article,
      chapter: currentChapter,
      series: series,
    );
    final segments = _segmentArticle(article, plan);
    if (segments.isEmpty) {
      throw const FormatException('章节内容不足，无法生成绘本分镜。');
    }

    final refreshedSeries =
        await DatabaseService.getStorySeriesById(currentChapter.seriesId) ??
            series;
    final pageDrafts = [
      for (final segment in segments) _PromptReviewPageDraft(segment: segment),
    ];
    final groupPrompt = _composeGroupPrompt(
      series: refreshedSeries,
      plan: plan,
      segments: segments,
    );
    final reviewId = _nextPromptReviewId(articleId);
    final draft = _PictureBookPromptReviewDraft(
      reviewId: reviewId,
      article: article,
      chapter: currentChapter,
      series: refreshedSeries,
      regenerate: regenerate,
      pages: pageDrafts,
      bookDescription: refreshedSeries.description,
      storyBrief: plan.storyBrief,
      chapterBrief: plan.chapterBrief,
      groupPrompt: groupPrompt,
      createdAt: DateTime.now(),
    );
    _promptReviewDrafts[reviewId] = draft;
    _prunePromptReviewDrafts();
    return draft.toPayload();
  }

  static Future<Map<String, dynamic>> refreshPromptReview({
    required String reviewId,
    required String target,
    required String bookDescription,
    required String storyBrief,
    required String chapterBrief,
    required List<Map<String, dynamic>> scenes,
  }) async {
    final draft = _promptReviewDrafts[reviewId];
    if (draft == null) {
      throw const FormatException('绘本提示词审核已过期，请重新打开审核弹窗。');
    }
    final articleId = draft.article.id;
    if (articleId == null) {
      throw const FormatException('绘本提示词审核缺少文章信息。');
    }

    final normalizedTarget = target.trim();
    var currentBookDescription = bookDescription.trim();
    var currentStoryBrief = storyBrief.trim().isEmpty
        ? draft.storyBrief
        : _sanitizeForImagePrompt(storyBrief);
    var currentChapterBrief = chapterBrief.trim().isEmpty
        ? draft.chapterBrief
        : _sanitizeForImagePrompt(chapterBrief);
    var currentSegments = _submittedSegmentsForDraft(draft, scenes);

    switch (normalizedTarget) {
      case 'bookDescription':
        final reply = await TextGenerationService.generateStrict(
          turns: _bookDescriptionRefreshPromptTurns(
            article: draft.article,
            chapter: draft.chapter,
            seriesTitle: draft.series.title,
            bookDescription: currentBookDescription,
            storyBrief: currentStoryBrief,
            chapterBrief: currentChapterBrief,
          ),
          cachePurpose: _bookDescriptionRefreshPurpose,
          articleId: articleId,
          maxTokens: 700,
          jsonResponse: true,
          skipCacheRead: true,
        );
        final raw = _decodeJson(reply.text, const <String, dynamic>{});
        final refreshed = _sanitizeForImagePrompt(
          raw['bookDescription']?.toString().trim() ?? '',
        );
        if (refreshed.isEmpty) {
          throw const TextGenerationException('AI 未返回有效书籍简介，请重试。');
        }
        currentBookDescription = refreshed;
        break;
      case 'storyBrief':
        final reply = await TextGenerationService.generateStrict(
          turns: _storyBriefRefreshPromptTurns(
            article: draft.article,
            chapter: draft.chapter,
            seriesTitle: draft.series.title,
            bookDescription: currentBookDescription,
            storyBrief: currentStoryBrief,
            chapterBrief: currentChapterBrief,
          ),
          cachePurpose: _storyBriefRefreshPurpose,
          articleId: articleId,
          maxTokens: 900,
          jsonResponse: true,
          skipCacheRead: true,
        );
        final raw = _decodeJson(reply.text, const <String, dynamic>{});
        final refreshed = _sanitizeForImagePrompt(
          raw['storyBrief']?.toString().trim() ?? '',
        );
        if (refreshed.isEmpty) {
          throw const TextGenerationException('AI 未返回有效绘本故事简述，请重试。');
        }
        currentStoryBrief = refreshed;
        break;
      case 'chapterBrief':
        final reply = await TextGenerationService.generateStrict(
          turns: _chapterBriefRefreshPromptTurns(
            article: draft.article,
            chapter: draft.chapter,
            seriesTitle: draft.series.title,
            bookDescription: currentBookDescription,
            storyBrief: currentStoryBrief,
            chapterBrief: currentChapterBrief,
          ),
          cachePurpose: _chapterBriefRefreshPurpose,
          articleId: articleId,
          maxTokens: 900,
          jsonResponse: true,
          skipCacheRead: true,
        );
        final raw = _decodeJson(reply.text, const <String, dynamic>{});
        final refreshed = _sanitizeForImagePrompt(
          raw['chapterBrief']?.toString().trim() ?? '',
        );
        if (refreshed.isEmpty) {
          throw const TextGenerationException('AI 未返回有效章节组图简述，请重试。');
        }
        currentChapterBrief = refreshed;
        break;
      case 'scenes':
        final reply = await TextGenerationService.generateStrict(
          turns: _scenesRefreshPromptTurns(
            article: draft.article,
            chapter: draft.chapter,
            seriesTitle: draft.series.title,
            bookDescription: currentBookDescription,
            storyBrief: currentStoryBrief,
            chapterBrief: currentChapterBrief,
            segments: currentSegments,
          ),
          cachePurpose: _scenesRefreshPurpose,
          articleId: articleId,
          maxTokens: 4200,
          receiveTimeout: _chapterPlanReceiveTimeout(draft.article),
          jsonResponse: true,
          skipCacheRead: true,
        );
        final raw = _decodeJson(reply.text, const <String, dynamic>{});
        final refreshedScenes = _pictureBookScenesFromJson(
          raw['scenes'],
          sentenceCount: draft.article.sentences.length,
        );
        if (refreshedScenes.isEmpty) {
          throw const TextGenerationException('AI 未返回有效分镜描述，请重试。');
        }
        currentSegments = _segmentArticle(
          draft.article,
          ChapterPicturePlan(
            storyBrief: currentStoryBrief,
            chapterBrief: currentChapterBrief,
            scenes: refreshedScenes,
            source: TextGenerationReplySource.remote,
          ),
        );
        break;
      default:
        throw FormatException('不支持的提示词刷新类型：$target');
    }

    final updatedSeries = draft.series.copyWith(
      description: currentBookDescription,
      updatedAt: DateTime.now(),
    );
    final updatedPages = [
      for (final segment in currentSegments)
        _PromptReviewPageDraft(segment: segment),
    ];
    final updatedGroupPrompt = _composeGroupPrompt(
      series: updatedSeries,
      plan: ChapterPicturePlan(
        storyBrief: currentStoryBrief,
        chapterBrief: currentChapterBrief,
        scenes: [
          for (final segment in currentSegments)
            PictureBookScene(
              pageIndex: segment.pageIndex,
              sentenceStartIndex: segment.sentenceStartIndex,
              sentenceEndIndex: segment.sentenceEndIndex,
              title: segment.title,
              story: segment.summary,
              visual: segment.visualPrompt,
            ),
        ],
        source: TextGenerationReplySource.remote,
      ),
      segments: currentSegments,
    );
    final updatedDraft = draft.copyWith(
      series: updatedSeries,
      pages: updatedPages,
      bookDescription: currentBookDescription,
      storyBrief: currentStoryBrief,
      chapterBrief: currentChapterBrief,
      groupPrompt: updatedGroupPrompt,
    );
    _promptReviewDrafts[reviewId] = updatedDraft;
    return {
      ...updatedDraft.toPayload(),
      'refreshedTarget': normalizedTarget,
    };
  }

  static Future<Map<String, dynamic>> confirmPromptReview({
    required String reviewId,
    required String groupPrompt,
    required String bookDescription,
    required String storyBrief,
    required String chapterBrief,
    required List<Map<String, dynamic>> scenes,
    PictureBookProgressCallback? onProgress,
  }) async {
    final draft = _promptReviewDrafts[reviewId];
    if (draft == null) {
      throw const FormatException('绘本提示词审核已过期，请重新打开审核弹窗。');
    }
    final articleId = draft.article.id;
    final seriesId = draft.series.id;
    if (articleId == null || seriesId == null) {
      throw const FormatException('绘本提示词审核缺少文章或书籍信息。');
    }

    final confirmedBookDescription = bookDescription.trim();
    final confirmedStoryBrief = storyBrief.trim().isEmpty
        ? draft.storyBrief
        : _sanitizeForImagePrompt(storyBrief);
    final confirmedChapterBrief = chapterBrief.trim().isEmpty
        ? draft.chapterBrief
        : _sanitizeForImagePrompt(chapterBrief);
    final updatedSeries = draft.series.copyWith(
      description: confirmedBookDescription,
      updatedAt: DateTime.now(),
    );
    await DatabaseService.updateStorySeries(updatedSeries);

    final confirmedSegments = _submittedSegmentsForDraft(draft, scenes);
    final fallbackGroupPrompt = _composeGroupPrompt(
      series: updatedSeries,
      plan: ChapterPicturePlan(
        storyBrief: confirmedStoryBrief,
        chapterBrief: confirmedChapterBrief,
        scenes: [
          for (final segment in confirmedSegments)
            PictureBookScene(
              pageIndex: segment.pageIndex,
              sentenceStartIndex: segment.sentenceStartIndex,
              sentenceEndIndex: segment.sentenceEndIndex,
              title: segment.title,
              story: segment.summary,
              visual: segment.visualPrompt,
            ),
        ],
        source: TextGenerationReplySource.cached,
      ),
      segments: confirmedSegments,
    );
    final confirmedGroupPrompt = groupPrompt.trim().isEmpty
        ? fallbackGroupPrompt
        : _sanitizeForImagePrompt(groupPrompt);

    await _saveConfirmedChapterPlan(
      article: draft.article,
      chapter: draft.chapter,
      storyBrief: confirmedStoryBrief,
      chapterBrief: confirmedChapterBrief,
      segments: confirmedSegments,
    );

    final existingPages = await DatabaseService.getPictureBookPages(articleId);
    if (draft.regenerate || existingPages.isNotEmpty) {
      await DatabaseService.deletePictureBookPagesForArticle(articleId);
      await ApiCacheService.deleteArticleRefsAndUnusedFilesForPurposes(
        articleId,
        purposes: {'picture_book_image'},
      );
      _imageUriCache.clear();
      _thumbnailPathCache.clear();
    }

    final promptedSegments = <_PromptedSegment>[];
    for (final segment in confirmedSegments) {
      final promptJson = _promptJsonForSegment(
        series: updatedSeries,
        chapter: draft.chapter,
        segment: segment,
        storyBrief: confirmedStoryBrief,
        chapterBrief: confirmedChapterBrief,
        groupPrompt: confirmedGroupPrompt,
        reviewId: reviewId,
      );
      final now = DateTime.now();
      final queued = PictureBookPage(
        articleId: articleId,
        seriesId: seriesId,
        pageIndex: segment.pageIndex,
        sentenceStartIndex: segment.sentenceStartIndex,
        sentenceEndIndex: segment.sentenceEndIndex,
        paragraphText: segment.text,
        promptJson: ApiCacheService.canonicalJson({
          ...promptJson,
          'status': 'queued',
        }),
        status: 'queued',
        errorMessage: '',
        createdAt: now,
        updatedAt: now,
      );
      await DatabaseService.upsertPictureBookPage(queued);
    }
    await _emit(articleId, onProgress);

    for (final segment in confirmedSegments) {
      final promptJson = _promptJsonForSegment(
        series: updatedSeries,
        chapter: draft.chapter,
        segment: segment,
        storyBrief: confirmedStoryBrief,
        chapterBrief: confirmedChapterBrief,
        groupPrompt: confirmedGroupPrompt,
        reviewId: reviewId,
      );
      final generatingPage = await _markPage(
        segment,
        articleId: articleId,
        seriesId: seriesId,
        status: 'generating',
        promptJson: promptJson,
        errorMessage: '',
      );
      await _emit(articleId, onProgress);
      promptedSegments.add(
        _PromptedSegment(
          segment: segment,
          page: generatingPage,
          promptJson: promptJson,
          prompt: _scenePromptForRequest(segment),
        ),
      );
    }

    final requests = [
      for (final item in promptedSegments)
        VolcImageBatchRequest(
          pageIndex: item.segment.pageIndex,
          prompt: item.prompt,
          promptMetadata: item.promptJson,
        ),
    ];
    final groupResults = await VolcImageService.generatePictureBookImageGroup(
      requests: requests,
      articleId: articleId,
      seriesId: seriesId,
      referenceImagePaths: const [],
      groupPromptOverride: confirmedGroupPrompt,
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

    _promptReviewDrafts.remove(reviewId);
    return statePayload(articleId);
  }

  static Future<Map<String, dynamic>> cancelPromptReview(
      String reviewId) async {
    final removed = _promptReviewDrafts.remove(reviewId);
    return {
      'reviewId': reviewId,
      'cancelled': removed != null,
    };
  }

  static Future<void> generateForArticle({
    required Article article,
    required StoryChapter chapter,
    PictureBookProgressCallback? onProgress,
    bool regenerate = false,
  }) async {
    // Low-level worker used by the queue and focused tests. App/UI entrypoints
    // should call scheduleGenerateForArticle so the image API is rate-limited.
    final articleId = article.id;
    if (articleId == null) {
      return;
    }

    final existingPages = await DatabaseService.getPictureBookPages(articleId);
    final currentChapter =
        await DatabaseService.getStoryChapterForArticle(articleId) ?? chapter;
    final series =
        await DatabaseService.getStorySeriesById(currentChapter.seriesId);
    if (series == null) {
      return;
    }

    final ChapterPicturePlan plan;
    try {
      plan = await ensureChapterPlanForArticle(
        article: article,
        chapter: currentChapter,
        series: series,
      );
    } catch (error) {
      await _writePlanningErrorPage(
        article: article,
        chapter: currentChapter,
        series: series,
        errorMessage: _displayErrorMessage(error),
      );
      await _emit(articleId, onProgress);
      return;
    }
    final pages = _segmentArticle(article, plan);
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
          'promptPolicyVersion': _promptPolicyVersion,
          'scene': segment.toJson(),
        }),
        status: 'queued',
        createdAt: now,
        updatedAt: now,
      );
      await DatabaseService.upsertPictureBookPage(queued);
    }
    await _emit(articleId, onProgress);

    final refreshedSeries =
        await DatabaseService.getStorySeriesById(currentChapter.seriesId) ??
            series;
    final promptedSegments = <_PromptedSegment>[];
    final groupPrompt = _composeGroupPrompt(
      series: refreshedSeries,
      plan: plan,
      segments: pages,
    );

    for (final segment in pages) {
      final promptPage = await _markPage(
        segment,
        articleId: articleId,
        seriesId: refreshedSeries.id,
        status: 'prompting',
      );
      await _emit(articleId, onProgress);

      final promptJson = _promptJsonForSegment(
        series: refreshedSeries,
        chapter: currentChapter,
        segment: segment,
        storyBrief: plan.storyBrief,
        chapterBrief: plan.chapterBrief,
        groupPrompt: groupPrompt,
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
          prompt: _scenePromptForRequest(segment),
        ),
      );
    }

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
      referenceImagePaths: const [],
      groupPromptOverride: groupPrompt,
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

  static Future<void> scheduleGenerateForArticle({
    required Article article,
    required StoryChapter chapter,
    PictureBookProgressCallback? onProgress,
    bool regenerate = false,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      return;
    }

    // This is the UI-facing generation entrypoint. Keep image API work behind
    // the queue so article.create can return and remote image submissions stay
    // concurrency-limited.
    final completer = Completer<void>();
    _scheduledGenerationCounts[articleId] =
        (_scheduledGenerationCounts[articleId] ?? 0) + 1;
    _generationQueue.add(
      _PictureBookGenerationJob(
        article: article,
        chapter: chapter,
        onProgress: onProgress,
        regenerate: regenerate,
        completer: completer,
      ),
    );
    await _emit(articleId, onProgress);
    _drainGenerationQueue();
    return completer.future;
  }

  static void _drainGenerationQueue() {
    const maxJobs =
        _maxConcurrentGenerationJobs <= 0 ? 1 : _maxConcurrentGenerationJobs;
    while (_activeGenerationJobs < maxJobs && _generationQueue.isNotEmpty) {
      final job = _generationQueue.removeFirst();
      _activeGenerationJobs += 1;
      unawaited(_runGenerationJob(job));
    }
  }

  static Future<void> _runGenerationJob(_PictureBookGenerationJob job) async {
    final articleId = job.article.id;
    try {
      if (articleId != null) {
        await _emit(articleId, job.onProgress);
      }
      await generateForArticle(
        article: job.article,
        chapter: job.chapter,
        onProgress: job.onProgress,
        regenerate: job.regenerate,
      );
      if (!job.completer.isCompleted) {
        job.completer.complete();
      }
    } catch (error, stackTrace) {
      debugPrint('[PictureBookService] queued generation failed: $error');
      debugPrint('$stackTrace');
      if (!job.completer.isCompleted) {
        job.completer.complete();
      }
    } finally {
      if (articleId != null) {
        final remaining = (_scheduledGenerationCounts[articleId] ?? 1) - 1;
        if (remaining <= 0) {
          _scheduledGenerationCounts.remove(articleId);
        } else {
          _scheduledGenerationCounts[articleId] = remaining;
        }
        await _emit(articleId, job.onProgress);
      }
      _activeGenerationJobs -= 1;
      _drainGenerationQueue();
    }
  }

  static Future<void> regenerateArticle({
    required int articleId,
    PictureBookProgressCallback? onProgress,
  }) async {
    final article = await DatabaseService.getArticleById(articleId);
    final chapter = await DatabaseService.getStoryChapterForArticle(articleId);
    if (article == null || chapter == null) {
      return;
    }

    await scheduleGenerateForArticle(
      article: article,
      chapter: chapter,
      onProgress: onProgress,
      regenerate: true,
    );
  }

  static Future<Map<String, dynamic>> clearArticlePictureBookCache(
    int articleId,
  ) async {
    final article = await DatabaseService.getArticleById(articleId);
    final chapter = await DatabaseService.getStoryChapterForArticle(articleId);
    final pages = await DatabaseService.getPictureBookPages(articleId);

    await DatabaseService.deletePictureBookPagesForArticle(articleId);
    await ApiCacheService.deleteArticleRefsAndUnusedFilesForPurposes(
      articleId,
      purposes: {
        'picture_book_image',
        _chapterPlanCachePurpose,
      },
    );

    if (article != null && chapter != null) {
      await DatabaseService.updateStoryChapter(
        chapter.copyWith(
          summaryJson: ApiCacheService.canonicalJson({
            'title': article.title,
            'summary': _fallbackChapterSummary(article.content),
          }),
          updatedAt: DateTime.now(),
        ),
      );
    }
    _imageUriCache.clear();
    return {
      'articleId': articleId,
      'deletedPages': pages.length,
      'clearedPurposes': [
        'picture_book_image',
        _chapterPlanCachePurpose,
      ],
    };
  }

  static Future<void> _writePlanningErrorPage({
    required Article article,
    required StoryChapter chapter,
    required StorySeries series,
    required String errorMessage,
  }) async {
    final articleId = article.id;
    final seriesId = series.id;
    if (articleId == null || seriesId == null) {
      return;
    }
    await DatabaseService.deletePictureBookPagesForArticle(articleId);
    final now = DateTime.now();
    await DatabaseService.upsertPictureBookPage(
      PictureBookPage(
        articleId: articleId,
        seriesId: seriesId,
        pageIndex: 0,
        sentenceStartIndex: 0,
        sentenceEndIndex:
            article.sentences.isEmpty ? 0 : article.sentences.length - 1,
        paragraphText: article.content,
        promptJson: ApiCacheService.canonicalJson({
          'status': 'planning_error',
          'chapterTitle': chapter.chapterTitle,
          'promptPolicyVersion': _chapterPlanPolicyVersion,
        }),
        status: 'error',
        errorMessage: errorMessage,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  static Duration _chapterPlanReceiveTimeout(Article article) {
    final rawSeconds = 120 + article.sentences.length * 5;
    final seconds =
        rawSeconds < 180 ? 180 : (rawSeconds > 420 ? 420 : rawSeconds);
    return Duration(seconds: seconds);
  }

  static String _displayErrorMessage(Object error) {
    final message = error is TextGenerationException
        ? error.message
        : error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
    final trimmed = message.trim();
    return trimmed.isEmpty ? '文本提交处理失败，请重试。' : trimmed;
  }

  static Future<void> regeneratePage({
    required int articleId,
    required int pageIndex,
    PictureBookProgressCallback? onProgress,
  }) =>
      regenerateArticle(articleId: articleId, onProgress: onProgress);

  static Future<Map<String, dynamic>> statePayload(
    int articleId, {
    bool includeImageUris = false,
  }) async {
    final chapter = await DatabaseService.getStoryChapterForArticle(articleId);
    final series = chapter == null
        ? null
        : await DatabaseService.getStorySeriesById(chapter.seriesId);
    var pages = await DatabaseService.getPictureBookPages(articleId);
    if (chapter != null && pages.length > 1) {
      pages = await _recoverReadyPagesFromGroupCache(
        articleId: articleId,
        seriesId: chapter.seriesId,
        pages: pages,
      );
    }
    final pageJsons = await Future.wait(
      pages.map((page) => _pageJson(page, includeImageUri: includeImageUris)),
    );
    final status =
        pages.isEmpty && _scheduledGenerationCounts[articleId] != null
            ? 'queued'
            : _overallStatus(pages);
    return {
      'articleId': articleId,
      'enabled': chapter != null,
      'status': status,
      'series': series?.toJson(),
      'chapter': chapter?.toJson(series),
      'pages': pageJsons,
    };
  }

  static Future<List<PictureBookPage>> _recoverReadyPagesFromGroupCache({
    required int articleId,
    required int? seriesId,
    required List<PictureBookPage> pages,
  }) async {
    if (!pages.any((page) =>
        page.status == 'queued' ||
        page.status == 'prompting' ||
        page.status == 'generating' ||
        (page.status == 'ready' &&
            (page.imagePath == null || page.imagePath!.trim().isEmpty)))) {
      return pages;
    }

    final sorted = [...pages]
      ..sort((a, b) => a.pageIndex.compareTo(b.pageIndex));
    final requests = <VolcImageBatchRequest>[];
    String? groupPromptOverride;
    for (final page in sorted) {
      final promptJson = _decodeJson(page.promptJson, const {});
      groupPromptOverride ??= promptJson['groupPrompt']?.toString().trim();
      final prompt = _imagePromptFrom(promptJson);
      if (prompt.trim().isEmpty) {
        return pages;
      }
      requests.add(
        VolcImageBatchRequest(
          pageIndex: page.pageIndex,
          prompt: prompt,
          promptMetadata: promptJson,
        ),
      );
    }

    final results = await VolcImageService.generatePictureBookImageGroup(
      requests: requests,
      articleId: articleId,
      seriesId: seriesId,
      useSequential: true,
      reusePartialCache: false,
      cacheOnly: true,
      groupPromptOverride:
          groupPromptOverride?.isNotEmpty == true ? groupPromptOverride : null,
    );
    final byPage = <int, VolcImageResult>{
      for (final result in results)
        if (result.pageIndex != null) result.pageIndex!: result,
    };

    var changed = false;
    for (final page in sorted) {
      final result = byPage[page.pageIndex];
      final imagePath = result?.filePath?.trim() ?? '';
      if (result == null ||
          imagePath.isEmpty ||
          (result.source != VolcImageResultSource.cached &&
              result.source != VolcImageResultSource.remote)) {
        continue;
      }
      final imageCacheKey = result.cacheKey?.trim() ?? page.imageCacheKey;
      if (page.status == 'ready' &&
          page.imagePath == imagePath &&
          page.imageCacheKey == imageCacheKey) {
        continue;
      }
      await DatabaseService.upsertPictureBookPage(
        page.copyWith(
          imageCacheKey: imageCacheKey,
          imagePath: imagePath,
          status: 'ready',
          errorMessage: '',
          updatedAt: DateTime.now(),
        ),
      );
      changed = true;
    }

    if (!changed) {
      return pages;
    }
    return DatabaseService.getPictureBookPages(articleId);
  }

  static Future<Map<String, dynamic>> pageImagePayload({
    required int articleId,
    required int pageIndex,
    String variant = 'full',
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

    final normalizedVariant = variant.trim().toLowerCase();
    final useThumbnail = normalizedVariant == 'thumbnail';
    final imageUri = useThumbnail
        ? await _thumbnailImageUriForPath(targetPage.imagePath)
        : await _imageUriForPath(targetPage.imagePath);
    final imagePath = targetPage.imagePath?.trim() ?? '';
    return {
      'articleId': articleId,
      'pageIndex': pageIndex,
      'variant': useThumbnail ? 'thumbnail' : 'full',
      'imageUri': imageUri,
      'missing': imageUri == null && imagePath.isNotEmpty,
      'errorMessage': imageUri == null && imagePath.isNotEmpty
          ? useThumbnail
              ? '绘本缩略图缓存生成失败，请重试'
              : '绘本缓存文件丢失，请重试生成'
          : null,
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
      final imageUri = await _thumbnailImageUriForPath(imagePath);
      if (imageUri == null) {
        continue;
      }
      return {
        'coverImagePath': imagePath,
        'coverImageUri': imageUri,
        'coverImageVariant': 'thumbnail',
      };
    }
    return null;
  }

  static List<TextGenerationTurn> _chapterPlanPromptTurns({
    required Article article,
    required StoryChapter chapter,
    required StorySeries series,
  }) {
    final cleanSentences = article.sentences
        .map((sentence) => sentence.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
    final numberedSentences = [
      for (var i = 0; i < cleanSentences.length; i += 1)
        '$i. ${cleanSentences[i]}',
    ].join('\n');
    return [
      const TextGenerationTurn(
        role: 'system',
        content:
            'You create one complete picture-book group-image plan for a chapter. Return only strict valid minified JSON and nothing else. Do not use markdown. Do not use Python tuples, comments, trailing commas, or prose outside JSON. The JSON must contain storyBrief, chapterBrief, and scenes. Each scene becomes exactly one generated image in order.',
      ),
      TextGenerationTurn(
        role: 'user',
        content: [
          'Book or series title: ${series.title}',
          'Book description: ${series.description.trim()}',
          'Chapter order: ${chapter.chapterOrder}',
          'Chapter title: ${chapter.chapterTitle}',
          '',
          'Return JSON with this exact top-level shape:',
          '{"planKind":"picture_book_chapter_plan_v4","storyBrief":"...","chapterBrief":"...","scenes":[{"pageIndex":0,"sentenceStartIndex":0,"sentenceEndIndex":2,"title":"...","story":"...","visual":"..."}]}',
          '',
          'Rules:',
          '- Output must be parseable by JSON.parse exactly as returned. Use ["note"] not [("note")].',
          '- storyBrief should briefly describe the book world for this chapter and any main character appearance details needed for visual consistency.',
          '- chapterBrief should briefly describe this chapter as one coherent picture-book image sequence.',
          '- Split scenes by natural story beats: scene, event, conflict, decision, setting change, and ending.',
          '- Use the smallest useful number of scenes, up to ${ChapterStoryOutlineService.maxSegments}.',
          '- scenes must cover every sentence from 0 to ${cleanSentences.isEmpty ? 0 : cleanSentences.length - 1}, in order, without overlap.',
          '- scenes[i].pageIndex must equal i.',
          '- Each scene visual must describe exactly one illustration: characters, action, setting, mood, key props, and composition.',
          '- Use the book title and book description to infer era, style, story world, and recurring character appearance, but prioritize the current chapter text.',
          '- Return only the top-level fields and scene fields shown in the JSON shape.',
          '',
          'Numbered chapter sentences:',
          numberedSentences.isEmpty
              ? article.content.replaceAll(RegExp(r'\s+'), ' ').trim()
              : numberedSentences,
        ].join('\n'),
      ),
    ];
  }

  static List<TextGenerationTurn> _bookDescriptionRefreshPromptTurns({
    required Article article,
    required StoryChapter chapter,
    required String seriesTitle,
    required String bookDescription,
    required String storyBrief,
    required String chapterBrief,
  }) {
    return [
      const TextGenerationTurn(
        role: 'system',
        content:
            'You refresh only the bookDescription field for an English picture-book image sequence. Return strict valid minified JSON only, with exactly one top-level field: bookDescription.',
      ),
      TextGenerationTurn(
        role: 'user',
        content: [
          'Book or series title: $seriesTitle',
          'Current bookDescription written or approved by the user: $bookDescription',
          'Chapter order: ${chapter.chapterOrder}',
          'Chapter title: ${chapter.chapterTitle}',
          'Current storyBrief: $storyBrief',
          'Current chapterBrief: $chapterBrief',
          '',
          'Return JSON shape:',
          '{"bookDescription":"..."}',
          '',
          'Rules:',
          '- Keep it concise and useful as the book-level visual anchor.',
          '- Describe the era, story world, overall illustration style, color mood, and main recurring character appearance.',
          '- Use the book title and current chapter text to infer missing visual context, but avoid chapter-only plot details.',
          '- Do not add app subtitle, caption, safety, audience, or negative-prompt boilerplate.',
          '- Return only JSON with bookDescription.',
          '',
          'Numbered chapter sentences:',
          _numberedChapterSentencesForPrompt(article),
        ].join('\n'),
      ),
    ];
  }

  static List<TextGenerationTurn> _storyBriefRefreshPromptTurns({
    required Article article,
    required StoryChapter chapter,
    required String seriesTitle,
    required String bookDescription,
    required String storyBrief,
    required String chapterBrief,
  }) {
    return [
      const TextGenerationTurn(
        role: 'system',
        content:
            'You refresh only the storyBrief field for an English picture-book image sequence. Return strict valid minified JSON only, with exactly one top-level field: storyBrief.',
      ),
      TextGenerationTurn(
        role: 'user',
        content: [
          'Book or series title: $seriesTitle',
          'Book description written or approved by the user: $bookDescription',
          'Chapter order: ${chapter.chapterOrder}',
          'Chapter title: ${chapter.chapterTitle}',
          'Current storyBrief: $storyBrief',
          'Current chapterBrief: $chapterBrief',
          '',
          'Return JSON shape:',
          '{"storyBrief":"..."}',
          '',
          'Rules:',
          '- Keep it concise, visual, and useful for keeping book world and main character appearance consistent.',
          '- Use the book title and user book description to infer era, story world, color mood, illustration style, and primary character appearance.',
          '- Prioritize this chapter text over unrelated prior assumptions.',
          '- Return only JSON with storyBrief.',
          '',
          'Numbered chapter sentences:',
          _numberedChapterSentencesForPrompt(article),
        ].join('\n'),
      ),
    ];
  }

  static List<TextGenerationTurn> _chapterBriefRefreshPromptTurns({
    required Article article,
    required StoryChapter chapter,
    required String seriesTitle,
    required String bookDescription,
    required String storyBrief,
    required String chapterBrief,
  }) {
    return [
      const TextGenerationTurn(
        role: 'system',
        content:
            'You refresh only the chapterBrief field for an English picture-book image sequence. Return strict valid minified JSON only, with exactly one top-level field: chapterBrief.',
      ),
      TextGenerationTurn(
        role: 'user',
        content: [
          'Book or series title: $seriesTitle',
          'Book description written or approved by the user: $bookDescription',
          'Chapter order: ${chapter.chapterOrder}',
          'Chapter title: ${chapter.chapterTitle}',
          'Current storyBrief: $storyBrief',
          'Current chapterBrief: $chapterBrief',
          '',
          'Return JSON shape:',
          '{"chapterBrief":"..."}',
          '',
          'Rules:',
          '- Describe this chapter as one coherent sequence of picture-book images.',
          '- Mention the chapter arc, setting changes, important actions, mood changes, and ending.',
          '- Keep it concise and grounded in the current chapter text.',
          '- Return only JSON with chapterBrief.',
          '',
          'Numbered chapter sentences:',
          _numberedChapterSentencesForPrompt(article),
        ].join('\n'),
      ),
    ];
  }

  static List<TextGenerationTurn> _scenesRefreshPromptTurns({
    required Article article,
    required StoryChapter chapter,
    required String seriesTitle,
    required String bookDescription,
    required String storyBrief,
    required String chapterBrief,
    required List<_PicturePageSegment> segments,
  }) {
    final currentScenes = [
      for (final segment in segments)
        {
          'pageIndex': segment.pageIndex,
          'sentenceStartIndex': segment.sentenceStartIndex,
          'sentenceEndIndex': segment.sentenceEndIndex,
          'title': segment.title,
          'story': segment.summary,
          'visual': segment.visualPrompt,
        },
    ];
    return [
      const TextGenerationTurn(
        role: 'system',
        content:
            'You refresh only the storyboard scenes for an English picture-book group image sequence. Return strict valid minified JSON only, with exactly one top-level field: scenes.',
      ),
      TextGenerationTurn(
        role: 'user',
        content: [
          'Book or series title: $seriesTitle',
          'Book description written or approved by the user: $bookDescription',
          'Chapter order: ${chapter.chapterOrder}',
          'Chapter title: ${chapter.chapterTitle}',
          'Story brief: $storyBrief',
          'Chapter brief: $chapterBrief',
          '',
          'Current scenes JSON:',
          ApiCacheService.canonicalJson(currentScenes),
          '',
          'Return JSON shape:',
          '{"scenes":[{"pageIndex":0,"sentenceStartIndex":0,"sentenceEndIndex":2,"title":"...","story":"...","visual":"..."}]}',
          '',
          'Rules:',
          '- Split scenes by natural story beats: scene, event, conflict, decision, setting change, and ending.',
          '- Use the smallest useful number of scenes, up to ${ChapterStoryOutlineService.maxSegments}.',
          '- scenes must cover every sentence from 0 to ${article.sentences.isEmpty ? 0 : article.sentences.length - 1}, in order, without overlap.',
          '- scenes[i].pageIndex must equal i.',
          '- Each scene visual must describe exactly one illustration: characters, action, setting, mood, key props, and composition.',
          '- Keep recurring character appearance and illustration style consistent with the book description and story brief.',
          '- Return only JSON with scenes.',
          '',
          'Numbered chapter sentences:',
          _numberedChapterSentencesForPrompt(article),
        ].join('\n'),
      ),
    ];
  }

  static String _numberedChapterSentencesForPrompt(Article article) {
    final cleanSentences = article.sentences
        .map((sentence) => sentence.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
    if (cleanSentences.isEmpty) {
      return article.content.replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    return [
      for (var i = 0; i < cleanSentences.length; i += 1)
        '$i. ${cleanSentences[i]}',
    ].join('\n');
  }

  static ChapterPicturePlan? _chapterPlanFromSummary(
    String summaryJson, {
    required String contentHash,
    required int sentenceCount,
  }) {
    return _chapterPlanFromJson(
      _decodeJson(summaryJson, const <String, dynamic>{}),
      contentHash: contentHash,
      sentenceCount: sentenceCount,
      source: TextGenerationReplySource.cached,
      fallbackTitle: null,
    );
  }

  static ChapterPicturePlan? _chapterPlanFromJson(
    Map<String, dynamic> json, {
    required String contentHash,
    required int sentenceCount,
    required TextGenerationReplySource source,
    String? fallbackTitle,
  }) {
    final planKind = json['planKind']?.toString();
    final policyVersion = json['planPolicyVersion']?.toString();
    final isCachedPlan = source == TextGenerationReplySource.cached;
    if (planKind != _chapterPlanCachePurpose) {
      return null;
    }
    if (isCachedPlan && policyVersion != _chapterPlanPolicyVersion) {
      return null;
    }
    final scenes = _pictureBookScenesFromJson(
      json['scenes'],
      sentenceCount: sentenceCount,
    );
    if (scenes.isEmpty) {
      return null;
    }
    return ChapterPicturePlan(
      storyBrief: _sanitizeForImagePrompt(
        json['storyBrief']?.toString().trim() ?? '',
      ),
      chapterBrief: _sanitizeForImagePrompt(
        json['chapterBrief']?.toString().trim() ??
            json['summary']?.toString().trim() ??
            fallbackTitle ??
            '',
      ),
      scenes: scenes,
      source: source,
    );
  }

  static List<PictureBookScene> _pictureBookScenesFromJson(
    Object? raw, {
    required int sentenceCount,
  }) {
    if (raw is! List) {
      return const [];
    }
    final scenes = <PictureBookScene>[];
    final maxSentenceIndex = math.max(0, sentenceCount - 1);
    for (var i = 0; i < raw.length; i += 1) {
      final map = _mapValue(raw[i]);
      if (map.isEmpty) {
        continue;
      }
      final rawIndex = map['pageIndex'];
      final index = rawIndex is num ? rawIndex.toInt() : i;
      if (index < 0 || index >= ChapterStoryOutlineService.maxSegments) {
        continue;
      }
      final rawStart = map['sentenceStartIndex'];
      final rawEnd = map['sentenceEndIndex'];
      final start = rawStart is num ? rawStart.toInt() : 0;
      final end = rawEnd is num ? rawEnd.toInt() : start;
      final normalizedStart = start.clamp(0, maxSentenceIndex).toInt();
      final normalizedEnd =
          end.clamp(normalizedStart, maxSentenceIndex).toInt();
      final title = _sanitizeForImagePrompt(
        map['title']?.toString().trim().isNotEmpty == true
            ? map['title'].toString()
            : 'Scene ${index + 1}',
      );
      final story = _sanitizeForImagePrompt(
        map['story']?.toString().trim().isNotEmpty == true
            ? map['story'].toString()
            : map['summary']?.toString() ?? '',
      );
      final visual = _sanitizeForImagePrompt(
        map['visual']?.toString().trim().isNotEmpty == true
            ? map['visual'].toString()
            : map['visualPrompt']?.toString() ??
                map['prompt']?.toString() ??
                story,
      );
      if (story.isEmpty && visual.isEmpty) {
        continue;
      }
      scenes.add(
        PictureBookScene(
          pageIndex: index,
          sentenceStartIndex: normalizedStart,
          sentenceEndIndex: normalizedEnd,
          title: title,
          story: story,
          visual: visual,
        ),
      );
    }
    scenes.sort((a, b) => a.pageIndex.compareTo(b.pageIndex));
    return _normalizeSceneCoverage(scenes, sentenceCount);
  }

  static Map<String, dynamic> _mapValue(Object? raw) {
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return const <String, dynamic>{};
  }

  static List<PictureBookScene> _normalizeSceneCoverage(
    List<PictureBookScene> scenes,
    int sentenceCount,
  ) {
    if (scenes.isEmpty || sentenceCount <= 0) {
      return scenes;
    }
    final output = <PictureBookScene>[];
    final maxSentenceIndex = sentenceCount - 1;
    var nextStart = 0;
    for (var i = 0; i < scenes.length; i += 1) {
      final scene = scenes[i];
      var start = scene.sentenceStartIndex;
      var end = scene.sentenceEndIndex;
      if (i == 0) {
        start = 0;
      } else if (start > nextStart) {
        start = nextStart;
      } else if (start < nextStart) {
        start = nextStart;
      }
      if (end < start) {
        end = start;
      }
      if (i == scenes.length - 1 || end >= maxSentenceIndex) {
        end = maxSentenceIndex;
      }
      output.add(
        scene.copyWith(
          pageIndex: output.length,
          sentenceStartIndex: start.clamp(0, maxSentenceIndex).toInt(),
          sentenceEndIndex: end.clamp(start, maxSentenceIndex).toInt(),
        ),
      );
      nextStart = output.last.sentenceEndIndex + 1;
      if (nextStart > maxSentenceIndex) {
        break;
      }
    }
    if (output.isNotEmpty && output.last.sentenceEndIndex < maxSentenceIndex) {
      final last = output.removeLast();
      output.add(last.copyWith(sentenceEndIndex: maxSentenceIndex));
    }
    return output;
  }

  static String _composeGroupPrompt({
    required StorySeries series,
    required ChapterPicturePlan plan,
    required List<_PicturePageSegment> segments,
  }) {
    final buffer = StringBuffer()
      ..writeln(
        'Generate a coherent sequence of full-frame 16:9 English picture-book illustrations.',
      )
      ..writeln(
        'Each image corresponds to exactly one storyboard scene below, in order.',
      )
      ..writeln(
        'Keep the same book world, illustration style, color palette, and recurring character appearances across the whole sequence.',
      )
      ..writeln(
        'For every image, match the assigned scene action, characters, setting, props, mood, and composition.',
      )
      ..writeln('Do not treat the images as alternate candidates.')
      ..writeln(
        'Natural story-world text may appear only when it belongs to the scene, such as signs, book covers, maps, labels, or playing-card marks.',
      )
      ..writeln()
      ..writeln('Book title: ${series.title}')
      ..writeln('Book description: ${series.description.trim()}')
      ..writeln('Story brief: ${plan.storyBrief}')
      ..writeln('Chapter brief: ${plan.chapterBrief}');
    for (final segment in segments) {
      buffer
        ..writeln()
        ..writeln('Image ${segment.pageIndex + 1}:')
        ..writeln(
          'Sentence range: ${segment.sentenceStartIndex + 1}-${segment.sentenceEndIndex + 1}',
        )
        ..writeln('Scene title: ${segment.title}')
        ..writeln('Scene story: ${segment.summary}')
        ..writeln('Visual direction: ${segment.visualPrompt}');
    }
    return _sanitizeForImagePrompt(buffer.toString());
  }

  static String _scenePromptForRequest(_PicturePageSegment segment) {
    return _sanitizeForImagePrompt([
      'Image ${segment.pageIndex + 1}',
      'Sentence range: ${segment.sentenceStartIndex + 1}-${segment.sentenceEndIndex + 1}',
      'Scene title: ${segment.title}',
      'Scene story: ${segment.summary}',
      'Visual direction: ${segment.visualPrompt}',
    ].join('\n'));
  }

  static _PicturePageSegment _segmentWithSubmittedScene(
    _PicturePageSegment segment,
    Map<String, dynamic>? submitted,
  ) {
    if (submitted == null || submitted.isEmpty) {
      return segment;
    }
    return segment.copyWith(
      title: _sanitizeForImagePrompt(
        submitted['title']?.toString().trim().isNotEmpty == true
            ? submitted['title'].toString()
            : segment.title,
      ),
      summary: _sanitizeForImagePrompt(
        submitted['story']?.toString().trim().isNotEmpty == true
            ? submitted['story'].toString()
            : segment.summary,
      ),
      visualPrompt: _sanitizeForImagePrompt(
        submitted['visual']?.toString().trim().isNotEmpty == true
            ? submitted['visual'].toString()
            : segment.visualPrompt,
      ),
    );
  }

  static List<_PicturePageSegment> _submittedSegmentsForDraft(
    _PictureBookPromptReviewDraft draft,
    List<Map<String, dynamic>> scenes,
  ) {
    final submittedScenes = {
      for (final item in scenes)
        if ((item['pageIndex'] as num?) != null)
          (item['pageIndex'] as num).toInt(): item,
    };
    return [
      for (final pageDraft in draft.pages)
        _segmentWithSubmittedScene(
          pageDraft.segment,
          submittedScenes[pageDraft.segment.pageIndex],
        ),
    ];
  }

  static Future<void> _saveConfirmedChapterPlan({
    required Article article,
    required StoryChapter chapter,
    required String storyBrief,
    required String chapterBrief,
    required List<_PicturePageSegment> segments,
  }) async {
    final contentHash = await ChapterStoryOutlineService.contentHashFor(
      articleTitle: article.title,
      articleContent: article.content,
      sentences: article.sentences,
    );
    await DatabaseService.updateStoryChapter(
      chapter.copyWith(
        summaryJson: ApiCacheService.canonicalJson({
          'planKind': _chapterPlanCachePurpose,
          'planPolicyVersion': _chapterPlanPolicyVersion,
          'contentHash': contentHash,
          'title': article.title,
          'storyBrief': storyBrief,
          'chapterBrief': chapterBrief,
          'scenes': [
            for (final segment in segments)
              {
                'pageIndex': segment.pageIndex,
                'sentenceStartIndex': segment.sentenceStartIndex,
                'sentenceEndIndex': segment.sentenceEndIndex,
                'title': segment.title,
                'story': segment.summary,
                'visual': segment.visualPrompt,
              },
          ],
        }),
        updatedAt: DateTime.now(),
      ),
    );
  }

  static Map<String, dynamic> _promptJsonForSegment({
    required StorySeries series,
    required StoryChapter chapter,
    required _PicturePageSegment segment,
    required String storyBrief,
    required String chapterBrief,
    required String groupPrompt,
    String? reviewId,
  }) {
    return {
      'planKind': _chapterPlanCachePurpose,
      'planPolicyVersion': _chapterPlanPolicyVersion,
      'promptPolicyVersion': _promptPolicyVersion,
      'seriesTitle': series.title,
      'bookDescription': series.description,
      'chapterOrder': chapter.chapterOrder,
      'chapterTitle': chapter.chapterTitle,
      'storyBrief': storyBrief,
      'chapterBrief': chapterBrief,
      'scene': segment.toJson(),
      'groupPrompt': groupPrompt,
      if (reviewId != null) 'reviewId': reviewId,
      'confirmedAt': DateTime.now().toIso8601String(),
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
    ChapterPicturePlan plan,
  ) {
    final sentences = article.sentences
        .map((sentence) => sentence.trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
    if (sentences.isEmpty) {
      return const [];
    }

    return plan.scenes.map((scene) {
      final start =
          scene.sentenceStartIndex.clamp(0, sentences.length - 1).toInt();
      final end =
          scene.sentenceEndIndex.clamp(start, sentences.length - 1).toInt();
      final text = sentences.sublist(start, end + 1).join(' ');
      return _PicturePageSegment(
        pageIndex: scene.pageIndex,
        pageCount: plan.scenes.length,
        sentenceStartIndex: start,
        sentenceEndIndex: end,
        text: _normalizeFullChapterStoryForPrompt(text),
        title: scene.title,
        summary: scene.story,
        visualPrompt: scene.visual,
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
    final plan = ChapterPicturePlan(
      storyBrief: outline.summary,
      chapterBrief: outline.summary,
      scenes: [
        for (final segment in outline.segments)
          PictureBookScene(
            pageIndex: segment.index,
            sentenceStartIndex: segment.sentenceStartIndex,
            sentenceEndIndex: segment.sentenceEndIndex,
            title: segment.title,
            story: segment.summary,
            visual: segment.visualPrompt,
          ),
      ],
      source: outline.source,
    );
    return _segmentArticle(article, plan)
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

  static Future<String?> _thumbnailImageUriForPath(String? rawPath) async {
    final thumbnailPath = await _thumbnailPathForImage(rawPath);
    if (thumbnailPath == null || thumbnailPath.trim().isEmpty) {
      return null;
    }
    return _imageUriForPath(thumbnailPath);
  }

  static Future<String?> _thumbnailPathForImage(String? rawPath) async {
    final imagePath = rawPath?.trim() ?? '';
    if (imagePath.isEmpty) {
      return null;
    }

    final source = File(imagePath);
    if (!await source.exists()) {
      return null;
    }

    final stat = await source.stat();
    final cacheIdentity = ApiCacheService.canonicalJson({
      'version': 1,
      'sourcePath': path_lib.normalize(path_lib.absolute(source.path)),
      'sourceLength': stat.size,
      'sourceModifiedMs': stat.modified.millisecondsSinceEpoch,
      'maxWidth': _creationThumbnailMaxWidth,
      'maxHeight': _creationThumbnailMaxHeight,
    });
    final cachedPath = _thumbnailPathCache[cacheIdentity];
    if (cachedPath != null && await File(cachedPath).exists()) {
      return cachedPath;
    }

    final cacheKey = await ApiCacheService.hashUtf8(cacheIdentity);
    final directory =
        await ApiCacheService.cacheDirectory('picture_book_thumbnails');
    final target = File(path_lib.join(directory.path, '$cacheKey.png'));
    if (await target.exists() && await target.length() > 0) {
      _thumbnailPathCache[cacheIdentity] = target.path;
      return target.path;
    }

    try {
      final bytes = await source.readAsBytes();
      final thumbnail = await _resizeImageToPng(
        bytes,
        maxWidth: _creationThumbnailMaxWidth,
        maxHeight: _creationThumbnailMaxHeight,
      );
      if (thumbnail.isEmpty) {
        return null;
      }
      await target.writeAsBytes(thumbnail, flush: true);
      _thumbnailPathCache[cacheIdentity] = target.path;
      return target.path;
    } catch (error, stackTrace) {
      debugPrint('PictureBook thumbnail generation failed: $error');
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'picture_book_service',
          context: ErrorDescription('generating picture-book thumbnail'),
        ),
      );
      return null;
    }
  }

  static Future<Uint8List> _resizeImageToPng(
    Uint8List bytes, {
    required int maxWidth,
    required int maxHeight,
  }) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.FrameInfo? frame;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      if (width <= 0 || height <= 0) {
        return Uint8List(0);
      }
      final scale = math.min(
        1.0,
        math.min(maxWidth / width, maxHeight / height),
      );
      final targetWidth = math.max(1, (width * scale).round());
      final targetHeight = math.max(1, (height * scale).round());
      codec = await descriptor.instantiateCodec(
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List() ?? Uint8List(0);
    } finally {
      frame?.image.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
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
    if (prompt.isNotEmpty) {
      return prompt;
    }
    final scene = _mapValue(promptJson['scene']);
    if (scene.isEmpty) {
      return '';
    }
    return _sanitizeForImagePrompt([
      if (scene['title']?.toString().trim().isNotEmpty == true)
        'Scene title: ${scene['title']}',
      if (scene['story']?.toString().trim().isNotEmpty == true)
        'Scene story: ${scene['story']}',
      if (scene['visual']?.toString().trim().isNotEmpty == true)
        'Visual direction: ${scene['visual']}',
    ].join('\n'));
  }

  static String _sanitizeForImagePrompt(String text) {
    var safe = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (safe.isEmpty) {
      return safe;
    }

    // Prompt hygiene rule: remove unwanted positive layout hints at the source.
    // Once they are gone, do not add matching "do not ..." constraints.
    final replacements = <RegExp, String>{
      RegExp(
        r'\b(?:enough|large|wide|clear|keep|leave|with)?\s*(?:open\s+clean|clean\s+open|clean)\s+space\b[^.;,\n]*(?:subtitles?|captions?|app[- ]rendered|text|bottom|edge|lower|margin|outside)[^.;,\n]*',
        caseSensitive: false,
      ): 'natural scene composition',
      RegExp(
        r'\b(?:enough|large|wide|clear|keep|leave|with)?\s*open\s+space\s+(?:at|along|on|near|around|for|outside|below|under)\b[^.;,\n]*(?:subtitles?|captions?|app[- ]rendered|text|bottom|edge|lower|margin|outside)[^.;,\n]*',
        caseSensitive: false,
      ): 'natural scene composition',
      RegExp(
        r'\b(?:blank|empty|white)\s+(?:area|band|space|panel|margin|lower area|bottom area)\b[^.;,\n]*(?:subtitles?|captions?|app[- ]rendered|text)[^.;,\n]*',
        caseSensitive: false,
      ): 'natural scene composition',
      RegExp(
        r'\b(?:reserved|reserve)\s+(?:space|area|band|panel|margin)\b[^.;,\n]*(?:subtitles?|captions?|app[- ]rendered|text)[^.;,\n]*',
        caseSensitive: false,
      ): 'natural scene composition',
      RegExp(
        r'\b(?:bottom|lower)\s+(?:third|edge|area|band|margin)\b[^.;,\n]*(?:subtitles?|captions?|app[- ]rendered|text)[^.;,\n]*',
        caseSensitive: false,
      ): 'natural scene composition',
      RegExp(r'\bopen clean space for subtitles\b', caseSensitive: false):
          'natural scene composition',
      RegExp(
        r'\benough clean open space for app-rendered subtitles outside the generated artwork\b',
        caseSensitive: false,
      ): 'natural scene composition',
      RegExp(r'\bapp[- ]rendered subtitles?\b', caseSensitive: false): '',
      RegExp(r'\bapp[- ]rendered captions?\b', caseSensitive: false): '',
      RegExp(r'\bapp displays subtitles separately\b', caseSensitive: false):
          '',
      RegExp(r'\bthe app overlays subtitles separately\b',
          caseSensitive: false): '',
      RegExp(r'\bsubtitles?\b', caseSensitive: false): '',
      RegExp(r'\bcaptions?\b', caseSensitive: false): '',
      RegExp(r'\bapp[- ]rendered\b', caseSensitive: false): '',
      RegExp(r'\bUI overlays?\b', caseSensitive: false): '',
      RegExp(r'\btext[- ]free\b', caseSensitive: false):
          'full-frame story-world',
      RegExp(r'\bno visible text\b', caseSensitive: false): '',
      RegExp(r'\bno letters\b', caseSensitive: false): '',
      RegExp(r'\bno words\b', caseSensitive: false): '',
      RegExp(r'\bno pseudo text\b', caseSensitive: false): '',
      RegExp(r'\bspeech bubbles?\b', caseSensitive: false): '',
      RegExp(r'\bnarration bars?\b', caseSensitive: false): '',
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
    return _cleanPromptPunctuation(safe);
  }

  static String _cleanPromptPunctuation(String text) {
    var cleaned = text.replaceAll(RegExp(r'\s+'), ' ');
    cleaned = cleaned.replaceAllMapped(
      RegExp(r'\s+([,.;:])'),
      (match) => match.group(1) ?? '',
    );
    cleaned = cleaned
        .replaceAll(RegExp(r'(?:,\s*){2,}'), ', ')
        .replaceAll(RegExp(r'(?:;\s*){2,}'), '; ')
        .replaceAll(RegExp(r'\(\s*\)'), '')
        .trim();
    cleaned = cleaned.replaceAll(RegExp(r'^[,.;:\-\s]+'), '').trim();
    return cleaned.replaceAll(RegExp(r'[,;:\-\s]+$'), '').trim();
  }

  @visibleForTesting
  static String imagePromptForTest(Map<String, dynamic> promptJson) {
    return _imagePromptFrom(promptJson);
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

  static String _fallbackBookDescription({
    required String seriesTitle,
    required Article article,
  }) {
    final title =
        seriesTitle.trim().isEmpty ? article.title.trim() : seriesTitle.trim();
    final subject = title.isEmpty ? 'This English picture book' : title;
    final excerpt = _fallbackChapterSummary(article.content);
    return _sanitizeForImagePrompt(
      [
        '$subject as a warm child-friendly picture-book world, with consistent recurring characters, bright natural colors, expressive storybook illustration, and clear scene details.',
        if (excerpt.isNotEmpty) 'Chapter mood and anchors: $excerpt',
      ].join(' '),
    );
  }

  static String _shorten(String text, int maxLength) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= maxLength) {
      return normalized;
    }
    return normalized.substring(0, maxLength).trim();
  }

  static String _nextPromptReviewId(int articleId) {
    _promptReviewSequence += 1;
    return 'pb_${articleId}_${DateTime.now().microsecondsSinceEpoch}_$_promptReviewSequence';
  }

  static void _prunePromptReviewDrafts() {
    if (_promptReviewDrafts.length <= 24) {
      return;
    }
    final entries = _promptReviewDrafts.entries.toList(growable: false)
      ..sort((a, b) => a.value.createdAt.compareTo(b.value.createdAt));
    for (final entry in entries.take(_promptReviewDrafts.length - 24)) {
      _promptReviewDrafts.remove(entry.key);
    }
  }
}

class _PictureBookGenerationJob {
  const _PictureBookGenerationJob({
    required this.article,
    required this.chapter,
    required this.onProgress,
    required this.regenerate,
    required this.completer,
  });

  final Article article;
  final StoryChapter chapter;
  final PictureBookProgressCallback? onProgress;
  final bool regenerate;
  final Completer<void> completer;
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
  });

  final int pageIndex;
  final int pageCount;
  final int sentenceStartIndex;
  final int sentenceEndIndex;
  final String text;
  final String title;
  final String summary;
  final String visualPrompt;

  _PicturePageSegment copyWith({
    int? pageIndex,
    int? pageCount,
    int? sentenceStartIndex,
    int? sentenceEndIndex,
    String? text,
    String? title,
    String? summary,
    String? visualPrompt,
  }) =>
      _PicturePageSegment(
        pageIndex: pageIndex ?? this.pageIndex,
        pageCount: pageCount ?? this.pageCount,
        sentenceStartIndex: sentenceStartIndex ?? this.sentenceStartIndex,
        sentenceEndIndex: sentenceEndIndex ?? this.sentenceEndIndex,
        text: text ?? this.text,
        title: title ?? this.title,
        summary: summary ?? this.summary,
        visualPrompt: visualPrompt ?? this.visualPrompt,
      );

  Map<String, dynamic> toJson() => {
        'pageIndex': pageIndex,
        'sentenceStartIndex': sentenceStartIndex,
        'sentenceEndIndex': sentenceEndIndex,
        'title': title,
        'story': summary,
        'visual': visualPrompt,
      };
}

class _PromptedSegment {
  const _PromptedSegment({
    required this.segment,
    required this.page,
    required this.promptJson,
    required this.prompt,
  });

  final _PicturePageSegment segment;
  final PictureBookPage page;
  final Map<String, dynamic> promptJson;
  final String prompt;
}

class _PromptReviewPageDraft {
  const _PromptReviewPageDraft({
    required this.segment,
  });

  final _PicturePageSegment segment;

  Map<String, dynamic> toPayload() => {
        'pageIndex': segment.pageIndex,
        'sentenceStartIndex': segment.sentenceStartIndex,
        'sentenceEndIndex': segment.sentenceEndIndex,
        'paragraphText': segment.text,
        'title': segment.title,
        'story': segment.summary,
        'visual': segment.visualPrompt,
      };
}

class _PictureBookPromptReviewDraft {
  const _PictureBookPromptReviewDraft({
    required this.reviewId,
    required this.article,
    required this.chapter,
    required this.series,
    required this.regenerate,
    required this.pages,
    required this.bookDescription,
    required this.storyBrief,
    required this.chapterBrief,
    required this.groupPrompt,
    required this.createdAt,
  });

  final String reviewId;
  final Article article;
  final StoryChapter chapter;
  final StorySeries series;
  final bool regenerate;
  final List<_PromptReviewPageDraft> pages;
  final String bookDescription;
  final String storyBrief;
  final String chapterBrief;
  final String groupPrompt;
  final DateTime createdAt;

  _PictureBookPromptReviewDraft copyWith({
    StorySeries? series,
    List<_PromptReviewPageDraft>? pages,
    String? bookDescription,
    String? storyBrief,
    String? chapterBrief,
    String? groupPrompt,
  }) =>
      _PictureBookPromptReviewDraft(
        reviewId: reviewId,
        article: article,
        chapter: chapter,
        series: series ?? this.series,
        regenerate: regenerate,
        pages: pages ?? this.pages,
        bookDescription: bookDescription ?? this.bookDescription,
        storyBrief: storyBrief ?? this.storyBrief,
        chapterBrief: chapterBrief ?? this.chapterBrief,
        groupPrompt: groupPrompt ?? this.groupPrompt,
        createdAt: createdAt,
      );

  Map<String, dynamic> toPayload() => {
        'reviewId': reviewId,
        'articleId': article.id,
        'chapterId': chapter.id,
        'seriesId': series.id,
        'regenerate': regenerate,
        'bookDescription': bookDescription,
        'storyBrief': storyBrief,
        'chapterBrief': chapterBrief,
        'groupPrompt': groupPrompt,
        'scenes': pages.map((page) => page.toPayload()).toList(growable: false),
        'createdAt': createdAt.toIso8601String(),
      };
}

class ChapterPicturePlan {
  const ChapterPicturePlan({
    required this.storyBrief,
    required this.chapterBrief,
    required this.scenes,
    required this.source,
  });

  final String storyBrief;
  final String chapterBrief;
  final List<PictureBookScene> scenes;
  final TextGenerationReplySource source;
}

class PictureBookScene {
  const PictureBookScene({
    required this.pageIndex,
    required this.sentenceStartIndex,
    required this.sentenceEndIndex,
    required this.title,
    required this.story,
    required this.visual,
  });

  final int pageIndex;
  final int sentenceStartIndex;
  final int sentenceEndIndex;
  final String title;
  final String story;
  final String visual;

  PictureBookScene copyWith({
    int? pageIndex,
    int? sentenceStartIndex,
    int? sentenceEndIndex,
    String? title,
    String? story,
    String? visual,
  }) =>
      PictureBookScene(
        pageIndex: pageIndex ?? this.pageIndex,
        sentenceStartIndex: sentenceStartIndex ?? this.sentenceStartIndex,
        sentenceEndIndex: sentenceEndIndex ?? this.sentenceEndIndex,
        title: title ?? this.title,
        story: story ?? this.story,
        visual: visual ?? this.visual,
      );

  Map<String, dynamic> toJson() => {
        'pageIndex': pageIndex,
        'sentenceStartIndex': sentenceStartIndex,
        'sentenceEndIndex': sentenceEndIndex,
        'title': title,
        'story': story,
        'visual': visual,
      };
}
