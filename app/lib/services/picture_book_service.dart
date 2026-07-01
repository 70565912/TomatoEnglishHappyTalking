import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path_lib;

import '../core/logging/tomato_logger.dart';
import '../data/models/article_model.dart';
import '../data/models/picture_book_model.dart';
import 'api_cache_service.dart';
import 'database_service.dart';
import 'picture_book_image_service.dart';
import 'text_generation_service.dart';
import 'volc_image_service.dart';

typedef PictureBookProgressCallback = FutureOr<void> Function(
  Map<String, dynamic> state,
);

class BookDescriptionSuggestion {
  const BookDescriptionSuggestion({
    required this.description,
    required this.characters,
  });

  final String description;
  final List<BookCharacter> characters;

  Map<String, dynamic> toJson() => {
        'description': description,
        'characters': characters.map((item) => item.toJson()).toList(),
      };
}

/// 绘本章节分镜、审核与顺序组图服务。
///
/// ## 章节分镜持久化规则（不要回退）
///
/// - `story_chapters.summary_json` 保存的是用户审核/保存过的章节分镜计划，属于显式确认产物，不是后台静默 AI 缓存。
/// - **不要**为绘本分镜引入 `contentHash`、正文指纹或“输入变更即自动作废”机制。历史上因此导致 rename、改书籍简介后旧分镜被静默丢弃（E15）。
/// - 下列操作**不得**自动让已保存分镜失效：`article.rename`、绘本审核里改书籍简介/角色、听力页 `listening.updateSentence` 微调字幕。
/// - 当前产品没有整篇正文编辑；要改变文章只能删文重建，此时章节记录一并删除，无需 hash 判断。
/// - 需要新分镜时，只能由用户显式触发：`pictureBook.refreshPromptReview(target: chapterPlan)`，或删文后重新走审核流程。
/// - 打开 `pictureBook.promptReview` 时：优先读取 `summary_json` 中 `planKind=picture_book_chapter_scene_plan_v2` 且 `scenes[].sceneDescription` 非空的计划；读不到时才回退 `_blankPromptReviewSegments` 空占位。
/// - **不要**在计划失效时只保留 `chapterDescription` 却清空分镜；这会让 UI 看起来像“有章节描述、没分镜”，并误导用户直接确认出图。
/// - 对话练习提纲（`ChatChapterGuideService`）仍可使用自己的 `contentHash`；那是独立链路，不要复用到绘本分镜。
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
  static const String _promptPolicyVersion =
      'picture_book_group_prompt_scene_description_v2';
  static const String _chapterPlanCachePurpose =
      'picture_book_chapter_scene_plan_v2';
  static const String _characterRosterRule =
      'Use short consistent labels and visible traits for recurring characters and visually important recurring groups; avoid one-off actions, emotions, and props.';
  static const int _maxSceneCount = 12;
  static const String _bookDescriptionRefreshPurpose =
      'picture_book_book_description_refresh_v1';
  static const String _bookDescriptionDraftPurpose =
      'picture_book_book_description_draft_v1';
  static const Duration _bookDescriptionTextReceiveTimeout =
      Duration(seconds: 120);
  static const int _maxConcurrentGenerationJobs = int.fromEnvironment(
    'TOMATO_PICTURE_BOOK_MAX_CONCURRENT_JOBS',
    defaultValue: 1,
  );
  static Future<StorySeries> createSeries({
    required String title,
    String description = '',
    List<BookCharacter> characters = const [],
  }) async {
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) {
      throw const FormatException('请填写书籍名称');
    }
    final now = DateTime.now();
    final series = StorySeries(
      title: trimmedTitle,
      description: description.trim(),
      characters: _sanitizeBookCharacters(characters),
      createdAt: now,
      updatedAt: now,
    );
    final id = await DatabaseService.saveStorySeries(series);
    return series.copyWith(id: id);
  }

  static Future<BookDescriptionSuggestion> suggestBookDescription({
    required Article article,
    required String seriesTitle,
    String currentDescription = '',
    List<BookCharacter> currentCharacters = const [],
  }) async {
    final trimmedSeriesTitle = seriesTitle.trim();
    if (trimmedSeriesTitle.isEmpty) {
      throw const FormatException('请填写书籍名称');
    }
    final currentBookDescription = _sanitizeBookDescription(currentDescription);
    final currentBookCharacters = _sanitizeBookCharacters(currentCharacters);
    final reply = await TextGenerationService.generateStrict(
      turns: _bookDescriptionRefreshPromptTurns(
        article: article,
        seriesTitle: trimmedSeriesTitle,
        bookDescription: currentBookDescription,
        bookCharacters: currentBookCharacters,
      ),
      cachePurpose: _bookDescriptionDraftPurpose,
      articleId: article.id,
      maxTokens: 700,
      receiveTimeout: _bookDescriptionTextReceiveTimeout,
      jsonResponse: true,
      skipCacheRead: true,
      skipCacheWrite: true,
    );
    final raw = _decodeJson(reply.text, const <String, dynamic>{});
    final generated = _sanitizeBookDescription(
      raw['bookDescription']?.toString().trim() ?? '',
    );
    if (generated.isEmpty) {
      throw const TextGenerationException('AI 未返回有效书籍简介，请重试。');
    }
    final generatedCharacters = _sanitizeBookCharacters(
      _bookCharactersFromJson(raw['characters']),
    );
    return BookDescriptionSuggestion(
      description: generated,
      characters: generatedCharacters.isEmpty
          ? currentBookCharacters
          : _mergeBookCharacters(currentBookCharacters, generatedCharacters),
    );
  }

  static Future<StoryChapter> ensureChapterForArticle({
    required int seriesId,
    required Article article,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      throw StateError('Article must be saved before creating a chapter');
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

    final relevantCharacters = _relevantBookCharactersForArticle(
      article,
      currentSeries.characters,
    );
    final existing = _chapterPlanFromSummary(
      chapter.summaryJson,
      sentenceCount: article.sentences.length,
    );
    if (existing != null) {
      return existing;
    }

    final summaryMissReason = _chapterPlanSummaryMissReason(
      chapter.summaryJson,
      sentenceCount: article.sentences.length,
    );
    final recovered = await _recoverChapterPlanFromPages(
      article: article,
      chapter: chapter,
    );
    if (recovered != null) {
      await DatabaseService.updateStoryChapter(
        chapter.copyWith(
          summaryJson: ApiCacheService.canonicalJson(
            _chapterPlanSummaryJson(
              article: article,
              plan: recovered,
            ),
          ),
          updatedAt: DateTime.now(),
        ),
      );
      TomatoLogger.info(
        category: 'picture_book',
        event: 'chapter_plan.recovered_from_pages',
        articleId: articleId,
        status: 'cached',
        data: {
          'summaryMissReason': summaryMissReason,
          'sceneCount': recovered.scenes.length,
        },
      );
      return recovered;
    }

    TomatoLogger.info(
      category: 'picture_book',
      event: 'chapter_plan.remote_required',
      articleId: articleId,
      status: 'remote',
      data: {'summaryMissReason': summaryMissReason},
    );
    final reply = await TextGenerationService.generateStrict(
      turns: _chapterPlanPromptTurns(
        article: article,
        bookDescription: currentSeries.description,
        relevantCharacters: relevantCharacters,
      ),
      cachePurpose: _chapterPlanCachePurpose,
      articleId: articleId,
      maxTokens: 5200,
      receiveTimeout: _chapterPlanReceiveTimeout(article),
      jsonResponse: true,
      skipCacheRead: true,
      skipCacheWrite: true,
    );
    final raw = _decodeJson(reply.text, const <String, dynamic>{});
    final plan = _chapterPlanFromJson(
      raw,
      sentenceCount: article.sentences.length,
      source: reply.source,
    );
    if (plan == null) {
      throw const TextGenerationException(
        '文本提交处理失败：AI 未返回有效绘本分镜，请重试。',
      );
    }
    await DatabaseService.updateStoryChapter(
      chapter.copyWith(
        summaryJson: ApiCacheService.canonicalJson(
          _chapterPlanSummaryJson(
            article: article,
            plan: plan,
          ),
        ),
        updatedAt: DateTime.now(),
      ),
    );
    return plan;
  }

  static Future<ChapterPicturePlan?> _cachedChapterPlanForArticle({
    required Article article,
    required StoryChapter chapter,
    required StorySeries series,
  }) async {
    return _chapterPlanFromSummary(
      chapter.summaryJson,
      sentenceCount: article.sentences.length,
    );
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

    // Opening the review dialog must stay a visible, manual step: load only
    // persisted local planning data here. Text AI is triggered by refresh only.
    final plan = await _storedChapterPlanForPromptReview(
      article: article,
      chapter: currentChapter,
      series: series,
    );
    final segments = plan == null
        ? _blankPromptReviewSegments(article)
        : _segmentArticle(article, plan);
    if (segments.isEmpty) {
      throw const FormatException('章节内容不足，无法生成绘本分镜。');
    }

    final refreshedSeries =
        await DatabaseService.getStorySeriesById(currentChapter.seriesId) ??
            series;
    final reviewBookDescription =
        _sanitizeBookDescription(refreshedSeries.description);
    final reviewSeries = refreshedSeries.copyWith(
      description: reviewBookDescription,
    );
    final bookCharacters = _sanitizeBookCharacters(reviewSeries.characters);
    final relevantCharacters = _relevantBookCharactersForArticle(
      article,
      bookCharacters,
    );
    final reviewChapterDescription = plan?.chapterDescription ??
        _persistedChapterDescription(currentChapter.summaryJson);
    final newCharacters = _sanitizeBookCharacters(
      plan?.newCharacters ?? const [],
    );
    final pageDrafts = [
      for (final segment in segments) _PromptReviewPageDraft(segment: segment),
    ];
    final groupPrompt = _composeGroupPrompt(
      series: reviewSeries,
      plan: ChapterPicturePlan(
        chapterDescription: reviewChapterDescription,
        scenes: [
          for (final segment in segments)
            PictureBookScene(
              pageIndex: segment.pageIndex,
              sentenceStartIndex: segment.sentenceStartIndex,
              sentenceEndIndex: segment.sentenceEndIndex,
              sceneDescription: segment.summary,
            ),
        ],
        newCharacters: newCharacters,
        source: TextGenerationReplySource.cached,
      ),
      segments: segments,
      relevantCharacters: _mergeBookCharacters(
        relevantCharacters,
        newCharacters,
      ),
    );
    final reviewId = _nextPromptReviewId(articleId);
    final draft = _PictureBookPromptReviewDraft(
      reviewId: reviewId,
      article: article,
      chapter: currentChapter,
      series: reviewSeries,
      regenerate: regenerate,
      pages: pageDrafts,
      bookDescription: reviewBookDescription,
      bookCharacters: bookCharacters,
      relevantCharacters: relevantCharacters,
      newCharacters: newCharacters,
      chapterDescription: reviewChapterDescription,
      groupPrompt: groupPrompt,
      createdAt: DateTime.now(),
    );
    _promptReviewDrafts[reviewId] = draft;
    _prunePromptReviewDrafts();
    return draft.toPayload();
  }

  /// 审核弹窗打开时加载本地分镜；不调用图片 API。
  ///
  /// 读取顺序：已保存 `summary_json` → 从既有 `picture_book_pages` 恢复 → 空占位草稿。
  /// 不会因 rename / 改书籍元数据 / 听力字幕微调而自动作废已保存分镜。
  static Future<ChapterPicturePlan?> _storedChapterPlanForPromptReview({
    required Article article,
    required StoryChapter chapter,
    required StorySeries series,
  }) async {
    final articleId = article.id;
    if (articleId == null) {
      throw StateError('Article must be saved before reviewing picture book');
    }
    final existing = _chapterPlanFromSummary(
      chapter.summaryJson,
      sentenceCount: article.sentences.length,
    );
    if (existing != null) {
      return existing;
    }

    final recovered = await _recoverChapterPlanFromPages(
      article: article,
      chapter: chapter,
    );
    if (recovered != null) {
      await DatabaseService.updateStoryChapter(
        chapter.copyWith(
          summaryJson: ApiCacheService.canonicalJson(
            _chapterPlanSummaryJson(
              article: article,
              plan: recovered,
            ),
          ),
          updatedAt: DateTime.now(),
        ),
      );
      TomatoLogger.info(
        category: 'picture_book',
        event: 'chapter_plan.prompt_review_recovered_from_pages',
        articleId: articleId,
        status: 'cached',
        data: {'sceneCount': recovered.scenes.length},
      );
      return recovered;
    }

    TomatoLogger.info(
      category: 'picture_book',
      event: 'chapter_plan.prompt_review_empty_draft',
      articleId: articleId,
      status: 'local',
    );
    return null;
  }

  static Future<Map<String, dynamic>> pagePromptReviewPayload({
    required Article article,
    required StoryChapter chapter,
    required int pageIndex,
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

    final referencePage = await _nearestReferencePage(
      articleId: articleId,
      targetPageIndex: pageIndex,
    );
    if (referencePage == null) {
      return promptReviewPayload(
        article: article,
        chapter: currentChapter,
        regenerate: true,
      );
    }

    final existingPages = await DatabaseService.getPictureBookPages(articleId);
    PictureBookPage? targetPage;
    for (final page in existingPages) {
      if (page.pageIndex == pageIndex) {
        targetPage = page;
        break;
      }
    }

    final plan = await _cachedChapterPlanForArticle(
      article: article,
      chapter: currentChapter,
      series: series,
    );
    final segments = plan == null
        ? const <_PicturePageSegment>[]
        : _segmentArticle(article, plan);
    _PicturePageSegment? targetSegment;
    for (final segment in segments) {
      if (segment.pageIndex == pageIndex) {
        targetSegment = segment;
        break;
      }
    }
    targetSegment ??= _segmentFromExistingPage(
      article: article,
      page: targetPage,
      pageCount: existingPages.length,
    );
    if (targetSegment == null) {
      return promptReviewPayload(
        article: article,
        chapter: currentChapter,
        regenerate: true,
      );
    }

    final refreshedSeries =
        await DatabaseService.getStorySeriesById(currentChapter.seriesId) ??
            series;
    final reviewBookDescription =
        _sanitizeBookDescription(refreshedSeries.description);
    final reviewSeries = refreshedSeries.copyWith(
      description: reviewBookDescription,
    );
    final bookCharacters = _sanitizeBookCharacters(reviewSeries.characters);
    final relevantCharacters = _relevantBookCharactersForArticle(
      article,
      bookCharacters,
    );
    final newCharacters = _sanitizeBookCharacters(
      plan?.newCharacters ?? _newCharactersFromPagePrompt(targetPage),
    );
    final finalRelevantCharacters = _mergeBookCharacters(
      relevantCharacters,
      newCharacters,
    );
    final reviewChapterDescription = _singlePageChapterDescription(
      chapter: currentChapter,
      plan: plan,
      targetPage: targetPage,
    );
    final singlePrompt = _composeSinglePagePrompt(
      series: reviewSeries,
      chapterDescription: reviewChapterDescription,
      segment: targetSegment,
      relevantCharacters: finalRelevantCharacters,
    );
    final reviewId = _nextPromptReviewId(articleId);
    final draft = _PictureBookPromptReviewDraft(
      reviewId: reviewId,
      article: article,
      chapter: currentChapter,
      series: reviewSeries,
      regenerate: true,
      pages: [_PromptReviewPageDraft(segment: targetSegment)],
      bookDescription: reviewBookDescription,
      bookCharacters: bookCharacters,
      relevantCharacters: relevantCharacters,
      newCharacters: newCharacters,
      chapterDescription: reviewChapterDescription,
      groupPrompt: singlePrompt,
      createdAt: DateTime.now(),
      mode: 'singlePage',
      targetPageIndex: pageIndex,
      referencePageIndex: referencePage.pageIndex,
      referenceImagePath: referencePage.imagePath,
    );
    _promptReviewDrafts[reviewId] = draft;
    _prunePromptReviewDrafts();
    return draft.toPayload();
  }

  static Future<Map<String, dynamic>> refreshPromptReview({
    required String reviewId,
    required String target,
    required String bookDescription,
    required List<BookCharacter> bookCharacters,
    required List<BookCharacter> newCharacters,
    required String chapterDescription,
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
    var currentBookDescription = _sanitizeBookDescription(bookDescription);
    var currentBookCharacters = _sanitizeBookCharacters(bookCharacters);
    var currentRelevantCharacters = _relevantBookCharactersForArticle(
      draft.article,
      currentBookCharacters,
    );
    var currentNewCharacters = _sanitizeBookCharacters(newCharacters);
    var currentChapterDescription = chapterDescription.trim().isEmpty
        ? draft.chapterDescription
        : _sanitizeForImagePrompt(chapterDescription);
    var currentSegments = _submittedSegmentsForDraft(draft, scenes);

    switch (normalizedTarget) {
      case 'bookDescription':
        final reply = await TextGenerationService.generateStrict(
          turns: _bookDescriptionRefreshPromptTurns(
            article: draft.article,
            seriesTitle: draft.series.title,
            bookDescription: currentBookDescription,
            bookCharacters: currentBookCharacters,
          ),
          cachePurpose: _bookDescriptionRefreshPurpose,
          articleId: articleId,
          maxTokens: 700,
          receiveTimeout: _bookDescriptionTextReceiveTimeout,
          jsonResponse: true,
          skipCacheRead: true,
          skipCacheWrite: true,
        );
        final raw = _decodeJson(reply.text, const <String, dynamic>{});
        final refreshed = _sanitizeBookDescription(
          raw['bookDescription']?.toString().trim() ?? '',
        );
        if (refreshed.isEmpty) {
          throw const TextGenerationException('AI 未返回有效书籍简介，请重试。');
        }
        currentBookDescription = refreshed;
        final refreshedCharacters = _sanitizeBookCharacters(
          _bookCharactersFromJson(raw['characters']),
        );
        if (refreshedCharacters.isNotEmpty) {
          currentBookCharacters = _mergeBookCharacters(
            currentBookCharacters,
            refreshedCharacters,
          );
          currentRelevantCharacters = _relevantBookCharactersForArticle(
            draft.article,
            currentBookCharacters,
          );
        }
        break;
      case 'chapterPlan':
        final reply = await TextGenerationService.generateStrict(
          turns: _chapterPlanPromptTurns(
            article: draft.article,
            bookDescription: currentBookDescription,
            relevantCharacters: currentRelevantCharacters,
          ),
          cachePurpose: _chapterPlanCachePurpose,
          articleId: articleId,
          maxTokens: 5200,
          receiveTimeout: _chapterPlanReceiveTimeout(draft.article),
          jsonResponse: true,
          skipCacheRead: true,
          skipCacheWrite: true,
        );
        final refreshedPlan = _chapterPlanFromJson(
          _decodeJson(reply.text, const <String, dynamic>{}),
          sentenceCount: draft.article.sentences.length,
          source: reply.source,
        );
        if (refreshedPlan == null) {
          throw const TextGenerationException('AI 未返回有效章节规划，请重试。');
        }
        currentChapterDescription = refreshedPlan.chapterDescription;
        currentNewCharacters =
            _sanitizeBookCharacters(refreshedPlan.newCharacters);
        currentSegments = _segmentArticle(
          draft.article,
          refreshedPlan,
        );
        break;
      default:
        throw FormatException('不支持的提示词刷新类型：$target');
    }

    currentBookDescription = _sanitizeBookDescription(currentBookDescription);
    final updatedSeries = draft.series.copyWith(
      description: currentBookDescription,
      characters: currentBookCharacters,
      updatedAt: DateTime.now(),
    );
    final updatedPages = [
      for (final segment in currentSegments)
        _PromptReviewPageDraft(segment: segment),
    ];
    final updatedGroupPrompt = _composeGroupPrompt(
      series: updatedSeries,
      plan: ChapterPicturePlan(
        chapterDescription: currentChapterDescription,
        scenes: [
          for (final segment in currentSegments)
            PictureBookScene(
              pageIndex: segment.pageIndex,
              sentenceStartIndex: segment.sentenceStartIndex,
              sentenceEndIndex: segment.sentenceEndIndex,
              sceneDescription: segment.summary,
            ),
        ],
        source: TextGenerationReplySource.remote,
      ),
      segments: currentSegments,
      relevantCharacters: _mergeBookCharacters(
        currentRelevantCharacters,
        currentNewCharacters,
      ),
    );
    final updatedDraft = draft.copyWith(
      series: updatedSeries,
      pages: updatedPages,
      bookDescription: currentBookDescription,
      bookCharacters: currentBookCharacters,
      relevantCharacters: currentRelevantCharacters,
      newCharacters: currentNewCharacters,
      chapterDescription: currentChapterDescription,
      groupPrompt: updatedGroupPrompt,
    );
    _promptReviewDrafts[reviewId] = updatedDraft;
    return {
      ...updatedDraft.toPayload(),
      'refreshedTarget': normalizedTarget,
    };
  }

  static Future<Map<String, dynamic>> savePromptReview({
    required String reviewId,
    required String groupPrompt,
    required String bookDescription,
    required List<BookCharacter> bookCharacters,
    required List<BookCharacter> newCharacters,
    required String chapterDescription,
    required List<Map<String, dynamic>> scenes,
  }) async {
    final draft = _promptReviewDrafts[reviewId];
    if (draft == null) {
      throw const FormatException('绘本提示词审核已过期，请重新打开审核弹窗。');
    }

    final confirmedChapterDescription = chapterDescription.trim().isEmpty
        ? draft.chapterDescription
        : _sanitizeForImagePrompt(chapterDescription);
    final confirmedBookDescription = _sanitizeBookDescription(bookDescription);
    final confirmedBookCharacters = _sanitizeBookCharacters(bookCharacters);
    final confirmedNewCharacters = _sanitizeBookCharacters(newCharacters);
    final confirmedRelevantCharacters = _relevantBookCharactersForArticle(
      draft.article,
      confirmedBookCharacters,
    );
    final updatedSeries = draft.series.copyWith(
      description: confirmedBookDescription,
      characters: confirmedBookCharacters,
      updatedAt: DateTime.now(),
    );
    await DatabaseService.updateStorySeries(updatedSeries);

    final confirmedSegments = _submittedSegmentsForDraft(draft, scenes);
    final fallbackGroupPrompt = _composeGroupPrompt(
      series: updatedSeries,
      plan: ChapterPicturePlan(
        chapterDescription: confirmedChapterDescription,
        scenes: [
          for (final segment in confirmedSegments)
            PictureBookScene(
              pageIndex: segment.pageIndex,
              sentenceStartIndex: segment.sentenceStartIndex,
              sentenceEndIndex: segment.sentenceEndIndex,
              sceneDescription: segment.summary,
            ),
        ],
        source: TextGenerationReplySource.cached,
      ),
      segments: confirmedSegments,
      relevantCharacters: _mergeBookCharacters(
        confirmedRelevantCharacters,
        confirmedNewCharacters,
      ),
    );
    final confirmedGroupPrompt = groupPrompt.trim().isEmpty
        ? fallbackGroupPrompt
        : _sanitizeForImagePrompt(groupPrompt);

    await _saveConfirmedChapterPlan(
      article: draft.article,
      chapter: draft.chapter,
      bookDescription: confirmedBookDescription,
      relevantCharacters: confirmedRelevantCharacters,
      chapterDescription: confirmedChapterDescription,
      segments: confirmedSegments,
      newCharacters: confirmedNewCharacters,
    );

    final updatedDraft = draft.copyWith(
      series: updatedSeries,
      pages: [
        for (final segment in confirmedSegments)
          _PromptReviewPageDraft(segment: segment),
      ],
      bookDescription: confirmedBookDescription,
      bookCharacters: confirmedBookCharacters,
      relevantCharacters: confirmedRelevantCharacters,
      newCharacters: confirmedNewCharacters,
      chapterDescription: confirmedChapterDescription,
      groupPrompt: confirmedGroupPrompt,
    );
    _promptReviewDrafts[reviewId] = updatedDraft;
    return updatedDraft.toPayload();
  }

  static Future<Map<String, dynamic>> confirmPromptReview({
    required String reviewId,
    required String groupPrompt,
    required String bookDescription,
    required List<BookCharacter> bookCharacters,
    required List<BookCharacter> newCharacters,
    required String chapterDescription,
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

    final confirmedChapterDescription = chapterDescription.trim().isEmpty
        ? draft.chapterDescription
        : _sanitizeForImagePrompt(chapterDescription);
    final confirmedBookDescription = _sanitizeBookDescription(bookDescription);
    final confirmedBookCharacters = _sanitizeBookCharacters(bookCharacters);
    final confirmedNewCharacters = _sanitizeBookCharacters(newCharacters);
    final confirmedRelevantCharacters = _relevantBookCharactersForArticle(
      draft.article,
      confirmedBookCharacters,
    );
    final finalRelevantCharacters = _mergeBookCharacters(
      confirmedRelevantCharacters,
      confirmedNewCharacters,
    );
    final mergedCharacters = _mergeBookCharacters(
      confirmedBookCharacters,
      confirmedNewCharacters,
    );
    final updatedSeries = draft.series.copyWith(
      description: confirmedBookDescription,
      characters: mergedCharacters,
      updatedAt: DateTime.now(),
    );
    await DatabaseService.updateStorySeries(updatedSeries);

    final confirmedSegments = _submittedSegmentsForDraft(draft, scenes);
    final fallbackGroupPrompt = _composeGroupPrompt(
      series: updatedSeries,
      plan: ChapterPicturePlan(
        chapterDescription: confirmedChapterDescription,
        scenes: [
          for (final segment in confirmedSegments)
            PictureBookScene(
              pageIndex: segment.pageIndex,
              sentenceStartIndex: segment.sentenceStartIndex,
              sentenceEndIndex: segment.sentenceEndIndex,
              sceneDescription: segment.summary,
            ),
        ],
        source: TextGenerationReplySource.cached,
      ),
      segments: confirmedSegments,
      relevantCharacters: finalRelevantCharacters,
    );
    final confirmedGroupPrompt = groupPrompt.trim().isEmpty
        ? fallbackGroupPrompt
        : _sanitizeForImagePrompt(groupPrompt);

    await _saveConfirmedChapterPlan(
      article: draft.article,
      chapter: draft.chapter,
      bookDescription: confirmedBookDescription,
      relevantCharacters: finalRelevantCharacters,
      chapterDescription: confirmedChapterDescription,
      segments: confirmedSegments,
      newCharacters: confirmedNewCharacters,
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
        chapterDescription: confirmedChapterDescription,
        relevantCharacters: finalRelevantCharacters,
        newCharacters: confirmedNewCharacters,
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
        chapterDescription: confirmedChapterDescription,
        relevantCharacters: finalRelevantCharacters,
        newCharacters: confirmedNewCharacters,
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
    final groupResults =
        await PictureBookImageService.generatePictureBookImageGroup(
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

  static Future<Map<String, dynamic>> confirmPagePromptReview({
    required String reviewId,
    required String groupPrompt,
    required String bookDescription,
    required List<BookCharacter> bookCharacters,
    required List<BookCharacter> newCharacters,
    required String chapterDescription,
    required List<Map<String, dynamic>> scenes,
    PictureBookProgressCallback? onProgress,
  }) async {
    final draft = _promptReviewDrafts[reviewId];
    if (draft == null) {
      throw const FormatException('绘本提示词审核已过期，请重新打开审核弹窗。');
    }
    if (draft.mode != 'singlePage') {
      throw const FormatException('当前审核不是单页重生成审核，请重新打开审核弹窗。');
    }
    final articleId = draft.article.id;
    final seriesId = draft.series.id;
    final referenceImagePath = draft.referenceImagePath?.trim() ?? '';
    if (articleId == null || seriesId == null) {
      throw const FormatException('绘本提示词审核缺少文章或书籍信息。');
    }
    if (referenceImagePath.isEmpty ||
        !(await File(referenceImagePath).exists())) {
      throw const FormatException('参考图文件不存在，请重新打开单页重生成。');
    }

    final confirmedChapterDescription = chapterDescription.trim().isEmpty
        ? draft.chapterDescription
        : _sanitizeForImagePrompt(chapterDescription);
    final confirmedBookDescription = _sanitizeBookDescription(bookDescription);
    final confirmedBookCharacters = _sanitizeBookCharacters(bookCharacters);
    final confirmedNewCharacters = _sanitizeBookCharacters(newCharacters);
    final confirmedRelevantCharacters = _relevantBookCharactersForArticle(
      draft.article,
      confirmedBookCharacters,
    );
    final finalRelevantCharacters = _mergeBookCharacters(
      confirmedRelevantCharacters,
      confirmedNewCharacters,
    );
    final mergedCharacters = _mergeBookCharacters(
      confirmedBookCharacters,
      confirmedNewCharacters,
    );
    final updatedSeries = draft.series.copyWith(
      description: confirmedBookDescription,
      characters: mergedCharacters,
      updatedAt: DateTime.now(),
    );
    await DatabaseService.updateStorySeries(updatedSeries);

    final confirmedSegments = _submittedSegmentsForDraft(draft, scenes);
    if (confirmedSegments.length != 1) {
      throw const FormatException('单页重生成只能提交一个分镜。');
    }
    final targetSegment = confirmedSegments.single;
    final fallbackSinglePrompt = _composeSinglePagePrompt(
      series: updatedSeries,
      chapterDescription: confirmedChapterDescription,
      segment: targetSegment,
      relevantCharacters: finalRelevantCharacters,
    );
    final confirmedSinglePrompt = groupPrompt.trim().isEmpty
        ? fallbackSinglePrompt
        : _sanitizeForImagePrompt(groupPrompt);

    await _saveSinglePageConfirmedChapterPlan(
      article: draft.article,
      chapter: draft.chapter,
      bookDescription: confirmedBookDescription,
      relevantCharacters: finalRelevantCharacters,
      chapterDescription: confirmedChapterDescription,
      segment: targetSegment,
      newCharacters: confirmedNewCharacters,
    );

    final promptJson = {
      ..._promptJsonForSegment(
        series: updatedSeries,
        chapter: draft.chapter,
        segment: targetSegment,
        chapterDescription: confirmedChapterDescription,
        relevantCharacters: finalRelevantCharacters,
        newCharacters: confirmedNewCharacters,
        groupPrompt: confirmedSinglePrompt,
        reviewId: reviewId,
      ),
      'mode': 'singlePage',
      'targetPageIndex': targetSegment.pageIndex,
      'referencePageIndex': draft.referencePageIndex,
    };
    final generatingPage = await _markPage(
      targetSegment,
      articleId: articleId,
      seriesId: seriesId,
      status: 'generating',
      promptJson: promptJson,
      errorMessage: '',
    );
    _imageUriCache.clear();
    _thumbnailPathCache.clear();
    await _emit(articleId, onProgress);

    final results = await PictureBookImageService.generatePictureBookImageGroup(
      requests: [
        VolcImageBatchRequest(
          pageIndex: targetSegment.pageIndex,
          prompt: confirmedSinglePrompt,
          promptMetadata: promptJson,
        ),
      ],
      articleId: articleId,
      seriesId: seriesId,
      referenceImagePaths: [referenceImagePath],
      groupPromptOverride: confirmedSinglePrompt,
      useSequential: false,
      reusePartialCache: false,
    );
    final result = results.firstWhere(
      (item) => item.pageIndex == targetSegment.pageIndex,
      orElse: () => results.isNotEmpty
          ? results.first
          : VolcImageResult(
              source: VolcImageResultSource.failed,
              pageIndex: targetSegment.pageIndex,
              errorMessage: '单页图片接口未返回第 ${targetSegment.pageIndex + 1} 张图片',
            ),
    );
    final status = switch (result.source) {
      VolcImageResultSource.remote || VolcImageResultSource.cached => 'ready',
      VolcImageResultSource.skippedNoKey => 'skipped',
      VolcImageResultSource.failed => 'error',
    };
    await DatabaseService.upsertPictureBookPage(
      generatingPage.copyWith(
        imageCacheKey: result.hasImage ? result.cacheKey : null,
        imagePath: result.hasImage ? result.filePath : null,
        status: status,
        errorMessage: result.errorMessage ?? '',
        updatedAt: DateTime.now(),
      ),
    );
    _imageUriCache.clear();
    _thumbnailPathCache.clear();
    await _emit(articleId, onProgress);

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
    final promptSeries = refreshedSeries.copyWith(
      description: _sanitizeForImagePrompt(refreshedSeries.description),
    );
    final promptRelevantCharacters = _mergeBookCharacters(
      _relevantBookCharactersForArticle(article, promptSeries.characters),
      plan.newCharacters,
    );
    final promptedSegments = <_PromptedSegment>[];
    final groupPrompt = _composeGroupPrompt(
      series: promptSeries,
      plan: plan,
      segments: pages,
      relevantCharacters: promptRelevantCharacters,
    );

    for (final segment in pages) {
      final promptPage = await _markPage(
        segment,
        articleId: articleId,
        seriesId: promptSeries.id,
        status: 'prompting',
      );
      await _emit(articleId, onProgress);

      final promptJson = _promptJsonForSegment(
        series: promptSeries,
        chapter: currentChapter,
        segment: segment,
        chapterDescription: plan.chapterDescription,
        relevantCharacters: promptRelevantCharacters,
        newCharacters: plan.newCharacters,
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

    final groupResults =
        await PictureBookImageService.generatePictureBookImageGroup(
      requests: [
        for (final item in promptedSegments)
          VolcImageBatchRequest(
            pageIndex: item.segment.pageIndex,
            prompt: item.prompt,
            promptMetadata: item.promptJson,
          ),
      ],
      articleId: articleId,
      seriesId: promptSeries.id,
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
    final pages = await DatabaseService.getPictureBookPages(articleId);

    await DatabaseService.deletePictureBookPagesForArticle(articleId);
    await ApiCacheService.deleteArticleRefsAndUnusedFilesForPurposes(
      articleId,
      purposes: {'picture_book_image'},
    );

    _imageUriCache.clear();
    return {
      'articleId': articleId,
      'deletedPages': pages.length,
      'clearedPurposes': ['picture_book_image'],
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
          'planKind': _chapterPlanCachePurpose,
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

  static Future<PictureBookPage?> _nearestReferencePage({
    required int articleId,
    required int targetPageIndex,
  }) async {
    final pages = await DatabaseService.getPictureBookPages(articleId);
    final before = pages
        .where((page) => page.pageIndex < targetPageIndex)
        .toList(growable: false)
      ..sort((a, b) => b.pageIndex.compareTo(a.pageIndex));
    for (final page in before) {
      if (await _hasUsableReferenceImage(page)) {
        return page;
      }
    }

    final after = pages
        .where((page) => page.pageIndex > targetPageIndex)
        .toList(growable: false)
      ..sort((a, b) => a.pageIndex.compareTo(b.pageIndex));
    for (final page in after) {
      if (await _hasUsableReferenceImage(page)) {
        return page;
      }
    }
    return null;
  }

  static Future<bool> _hasUsableReferenceImage(PictureBookPage page) async {
    if (page.status != 'ready') {
      return false;
    }
    final imagePath = page.imagePath?.trim() ?? '';
    if (imagePath.isEmpty) {
      return false;
    }
    return File(imagePath).exists();
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

    final results = await PictureBookImageService.generatePictureBookImageGroup(
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
    // Web UI <img> cannot load arbitrary cache-directory file:// URIs from the
    // embedded WebView origin. Always return data:image/...;base64,... here.
    // See docs/build-and-release-pitfalls.md (WebView 绘本图不要用 file:// 原图路径).
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
    required String bookDescription,
    required List<BookCharacter> relevantCharacters,
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
            'Create a compact picture-book scene plan for one chapter. Return strict minified JSON only.',
      ),
      TextGenerationTurn(
        role: 'user',
        content: [
          'Book description:',
          bookDescription.trim(),
          '',
          'Relevant characters already approved for this book and appearing in this chapter:',
          _charactersForPrompt(relevantCharacters),
          '',
          'Return JSON with this exact top-level shape:',
          '{"planKind":"$_chapterPlanCachePurpose","chapterDescription":"...","scenes":[{"pageIndex":0,"sentenceStartIndex":0,"sentenceEndIndex":2,"sceneDescription":"..."}],"newCharacters":[{"name":"...","description":"..."}]}',
          '',
          'Rules:',
          '- Output valid JSON only.',
          '- chapterDescription: describe only this chapter arc, settings, atmosphere, key actions, and ending.',
          '- Use bookDescription as context for the visual world, style, color mood, and setting.',
          '- Use Relevant characters as the only source for approved recurring character appearance anchors.',
          '- Do not include character rosters, visual-anchor lists, or phrases like "Visual anchors" in chapterDescription.',
          '- Do not repeat character appearance, clothing, hair, age, facial features, accessories, or other visual anchors already present in Relevant characters.',
          '- If this chapter introduces an image-relevant character or group not present in Relevant characters, add it to newCharacters with name and stable visible description.',
          '- newCharacters must include only characters or recurring visual groups that affect image consistency; do not include temporary props, places, actions, emotions, or ordinary background elements.',
          // Keep scene planning visual-composition driven. Do not replace this
          // with length quotas or story-specific examples; those caused brittle
          // over-splitting or over-merging during prompt-review tuning.
          '- First identify the main visual story beats of the chapter, then assign sentence ranges to those beats.',
          '- Numbered sentences are coverage anchors, not scene candidates; do not create one scene per numbered sentence.',
          '- Use a compact but complete set of illustrations that preserves every major visible transition needed to understand the chapter.',
          '- Balance compactness and completeness: avoid over-merging unrelated phases, and avoid over-splitting consecutive beats that share one drawable composition.',
          '- Do not decide the scene count from text length or sentence count.',
          '- The $_maxSceneCount scene limit is an extreme upper bound, not a target. Never use $_maxSceneCount scenes unless there are $_maxSceneCount genuinely different visual beats.',
          '- A scene boundary is valid only when the next part has a clear visual boundary reason: location change, time jump, main character group change, story purpose change, major visible state change, or an action result that cannot be shown in the same illustration.',
          '- Create a new scene only when the main visual story beat changes for one of those visual boundary reasons.',
          '- Do not split a scene only because of one sentence, one prop, one line of dialogue, one internal thought, one facial expression, one camera angle, or one small action.',
          '- Merge adjacent sentences into one scene when they share the same place, time, characters, and story purpose, even if several actions or props are mentioned.',
          '- Keep a continuous action chain in one location as one scene when it has the same location, same character group, and same story purpose.',
          '- A boundary must come from a non-composable visual change, not from narration order, dialogue turns, or small sequential steps.',
          '- Neighboring parts should be merged when they share the same setting, main participants, immediate story purpose, and can be drawn as one coherent composition with foreground and background action.',
          '- Each sceneDescription must describe one dominant drawable composition, not a sequence of separate visible states.',
          '- If a sceneDescription needs words like "then", "after", "next", "later", or "meanwhile" to connect different visible states, revise the scene split.',
          '- Do not split narrative micro-phases of the same immediate visual outcome.',
          '- A boundary is weak when neighboring parts share the same setting, main participants, immediate purpose, and can be shown as one stable composition.',
          '- Dialogue turns, decision steps, brief responses, and acknowledgements are not scene boundaries unless they create a new non-composable visual state.',
          '- Do not merge distant story phases only to reduce the count; brief visible transitions still deserve their own scene when they cannot share the same drawable composition.',
          '- Before returning JSON, run the final audit in this order: first, split any scene that mixes multiple non-composable compositions; second, merge neighboring scenes whose boundary is only a narrative micro-phase of the same immediate visual outcome.',
          '- Use the smallest complete scene set that covers the chapter naturally.',
          '- Use at most $_maxSceneCount scenes.',
          '- sceneDescription: describe only the scene, action, objects, location, composition, emotion, and visual change for that story beat.',
          '- In sceneDescription, use character names only; do not describe character clothing, hair, age, facial features, accessories, or parenthesized character details.',
          '- Mention props only as active objects in the scene, not as repeated character appearance details.',
          '- Before returning JSON, remove all recurring character appearance details from chapterDescription and sceneDescription; those details belong only in Relevant characters or newCharacters.',
          '- scenes must cover every sentence from 0 to ${cleanSentences.isEmpty ? 0 : cleanSentences.length - 1}, in order, without overlap.',
          '- scenes[i].pageIndex must equal i.',
          '',
          'Chapter text:',
          numberedSentences.isEmpty
              ? article.content.replaceAll(RegExp(r'\s+'), ' ').trim()
              : numberedSentences,
        ].join('\n'),
      ),
    ];
  }

  static List<TextGenerationTurn> _bookDescriptionRefreshPromptTurns({
    required Article article,
    required String seriesTitle,
    required String bookDescription,
    required List<BookCharacter> bookCharacters,
  }) {
    return [
      const TextGenerationTurn(
        role: 'system',
        content:
            'Write a short reader-facing English description of this book visual world. Return strict minified JSON only.',
      ),
      TextGenerationTurn(
        role: 'user',
        content: [
          'Book or series title: $seriesTitle',
          'Current bookDescription written or approved by the user: $bookDescription',
          'Current characters written or approved by the user:',
          _charactersForPrompt(bookCharacters),
          '',
          'Return JSON shape:',
          '{"bookDescription":"...","characters":[{"name":"...","description":"..."}]}',
          '',
          'Rules:',
          '- Output valid JSON only.',
          '- bookDescription: write one short natural paragraph that can be saved directly as the book visual-world description.',
          '- bookDescription describes only the book world, setting, illustration style, color mood, era, and long-term visual atmosphere.',
          '- Do not put character appearance, clothing, hair, age, facial features, accessories, or roster lists in bookDescription.',
          '- characters: list recurring characters or important recurring visual groups with short stable visible descriptions.',
          '- Use the reference text only to discover details that belong to the whole book. Do not summarize this chapter.',
          '- Do not include chapter plot, scene actions, temporary emotions, camera composition, momentary props, sentence-by-sentence details, or direct quotes from the reference text.',
          '- $_characterRosterRule',
          '- For each recurring character or group, use a short label plus visible traits only; do not describe what they are doing in this chapter.',
          '- If the title or reference text clearly belongs to a well-known public-domain story, you may use public literary knowledge for recurring characters; otherwise do not invent characters, settings, or appearances not supported by the title or reference text.',
          '- Preserve useful user-approved bookDescription and Current characters unless they conflict with these rules.',
          '- Do not mention internal planning words or these instructions.',
          '- Do not use section headings.',
          '- Return only JSON with bookDescription and characters.',
          '',
          'Reference text:',
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

  /// 从 `story_chapters.summary_json` 读取已保存分镜。
  ///
  /// 不按标题、正文、书籍简介或句子变化做自动失效；只要 JSON 结构有效且分镜描述非空即视为可复用。
  static ChapterPicturePlan? _chapterPlanFromSummary(
    String summaryJson, {
    required int sentenceCount,
  }) {
    return _chapterPlanFromJson(
      _decodeJson(summaryJson, const <String, dynamic>{}),
      sentenceCount: sentenceCount,
      source: TextGenerationReplySource.cached,
    );
  }

  /// 写入 `story_chapters.summary_json` 的章节分镜结构。
  ///
  /// 只保存用户确认后的计划字段；不要恢复 `contentHash` 字段。
  static Map<String, dynamic> _chapterPlanSummaryJson({
    required Article article,
    required ChapterPicturePlan plan,
  }) =>
      {
        'planKind': _chapterPlanCachePurpose,
        'title': article.title,
        'chapterDescription': plan.chapterDescription,
        'scenes': plan.scenes.map((scene) => scene.toJson()).toList(),
        'newCharacters':
            plan.newCharacters.map((character) => character.toJson()).toList(),
      };

  static String _chapterPlanSummaryMissReason(
    String summaryJson, {
    required int sentenceCount,
  }) {
    final json = _decodeJson(summaryJson, const <String, dynamic>{});
    if (json.isEmpty) {
      return 'empty_summary';
    }
    final planKind = json['planKind']?.toString();
    if (planKind != _chapterPlanCachePurpose) {
      return 'plan_kind_mismatch';
    }
    if (json['scenes'] is! List) {
      return 'missing_scenes';
    }
    final scenes = _pictureBookScenesFromJson(
      json['scenes'],
      sentenceCount: sentenceCount,
    );
    if (scenes.isEmpty) {
      return 'empty_scenes';
    }
    final chapterDescription = _sanitizeForImagePrompt(
      json['chapterDescription']?.toString().trim() ?? '',
    );
    if (chapterDescription.isEmpty) {
      return 'empty_chapter_description';
    }
    return 'unknown';
  }

  static Future<ChapterPicturePlan?> _recoverChapterPlanFromPages({
    required Article article,
    required StoryChapter chapter,
  }) async {
    final articleId = article.id;
    if (articleId == null || article.sentences.isEmpty) {
      return null;
    }
    final pages = await DatabaseService.getPictureBookPages(articleId);
    if (pages.isEmpty) {
      return null;
    }

    final sortedPages = [...pages]
      ..sort((a, b) => a.pageIndex.compareTo(b.pageIndex));
    final scenes = <PictureBookScene>[];
    var chapterDescription = '';
    var newCharacters = <BookCharacter>[];

    for (final page in sortedPages) {
      final prompt = _pagePromptMap(page);
      if (chapterDescription.isEmpty) {
        chapterDescription = _sanitizeForImagePrompt(
          prompt['chapterDescription']?.toString() ?? '',
        );
      }
      newCharacters = _mergeBookCharacters(
        newCharacters,
        _bookCharactersFromJson(prompt['newCharacters']),
      );

      final sceneDescription = _pageSceneDescription(page);
      if (sceneDescription.isEmpty) {
        continue;
      }
      final promptScene = _mapValue(prompt['scene']);
      final rawPageIndex = promptScene['pageIndex'];
      final rawStart = promptScene['sentenceStartIndex'];
      final rawEnd = promptScene['sentenceEndIndex'];
      final pageIndex =
          rawPageIndex is num ? rawPageIndex.toInt() : page.pageIndex;
      final sentenceStart =
          rawStart is num ? rawStart.toInt() : page.sentenceStartIndex;
      final sentenceEnd =
          rawEnd is num ? rawEnd.toInt() : page.sentenceEndIndex;
      scenes.add(
        PictureBookScene(
          pageIndex: pageIndex,
          sentenceStartIndex: sentenceStart,
          sentenceEndIndex: sentenceEnd,
          sceneDescription: sceneDescription,
        ),
      );
    }

    final normalizedScenes = _normalizeSceneCoverage(
      scenes,
      article.sentences.length,
    );
    if (normalizedScenes.isEmpty) {
      return null;
    }
    if (chapterDescription.isEmpty) {
      return null;
    }

    return ChapterPicturePlan(
      chapterDescription: chapterDescription,
      scenes: normalizedScenes,
      newCharacters: _sanitizeBookCharacters(newCharacters),
      source: TextGenerationReplySource.cached,
    );
  }

  static ChapterPicturePlan? _chapterPlanFromJson(
    Map<String, dynamic> json, {
    required int sentenceCount,
    required TextGenerationReplySource source,
  }) {
    final planKind = json['planKind']?.toString();
    if (planKind != _chapterPlanCachePurpose) {
      return null;
    }
    final scenes = _pictureBookScenesFromJson(
      json['scenes'],
      sentenceCount: sentenceCount,
    );
    if (scenes.isEmpty) {
      return null;
    }
    final chapterDescription = _sanitizeForImagePrompt(
      json['chapterDescription']?.toString().trim() ?? '',
    );
    if (chapterDescription.isEmpty) {
      return null;
    }
    return ChapterPicturePlan(
      chapterDescription: chapterDescription,
      scenes: scenes,
      newCharacters: _sanitizeBookCharacters(
        _bookCharactersFromJson(json['newCharacters']),
      ),
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
      if (index < 0 || index >= _maxSceneCount) {
        continue;
      }
      final rawStart = map['sentenceStartIndex'];
      final rawEnd = map['sentenceEndIndex'];
      final start = rawStart is num ? rawStart.toInt() : 0;
      final end = rawEnd is num ? rawEnd.toInt() : start;
      final normalizedStart = start.clamp(0, maxSentenceIndex).toInt();
      final normalizedEnd =
          end.clamp(normalizedStart, maxSentenceIndex).toInt();
      final sceneDescription = _sanitizeForImagePrompt(
        map['sceneDescription']?.toString().trim() ?? '',
      );
      if (sceneDescription.isEmpty) {
        continue;
      }
      scenes.add(
        PictureBookScene(
          pageIndex: index,
          sentenceStartIndex: normalizedStart,
          sentenceEndIndex: normalizedEnd,
          sceneDescription: sceneDescription,
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

  static Map<String, dynamic> _pagePromptMap(PictureBookPage? page) {
    if (page == null) {
      return const <String, dynamic>{};
    }
    return _decodeJson(page.promptJson, const <String, dynamic>{});
  }

  static String _pageSceneDescription(PictureBookPage? page) {
    final prompt = _pagePromptMap(page);
    final scene = _mapValue(prompt['scene']);
    for (final value in [
      scene['sceneDescription'],
      prompt['sceneDescription'],
      prompt['summary'],
    ]) {
      final sanitized = _sanitizeForImagePrompt(value?.toString() ?? '');
      if (sanitized.isNotEmpty) {
        return sanitized;
      }
    }
    return '';
  }

  static List<BookCharacter> _newCharactersFromPagePrompt(
    PictureBookPage? page,
  ) {
    final prompt = _pagePromptMap(page);
    return _sanitizeBookCharacters(_bookCharactersFromJson(
      prompt['newCharacters'],
    ));
  }

  static String _singlePageChapterDescription({
    required StoryChapter chapter,
    required ChapterPicturePlan? plan,
    required PictureBookPage? targetPage,
  }) {
    final planDescription = _sanitizeForImagePrompt(
      plan?.chapterDescription ?? '',
    );
    if (planDescription.isNotEmpty) {
      return planDescription;
    }

    final pagePrompt = _pagePromptMap(targetPage);
    final pageDescription = _sanitizeForImagePrompt(
      pagePrompt['chapterDescription']?.toString() ?? '',
    );
    if (pageDescription.isNotEmpty) {
      return pageDescription;
    }

    return _persistedChapterDescription(chapter.summaryJson);
  }

  static String _persistedChapterDescription(String summaryJson) {
    final summary = _decodeJson(summaryJson, const <String, dynamic>{});
    return _sanitizeForImagePrompt(
      summary['chapterDescription']?.toString() ?? '',
    );
  }

  static _PicturePageSegment? _segmentFromExistingPage({
    required Article article,
    required PictureBookPage? page,
    required int pageCount,
  }) {
    if (page == null) {
      return null;
    }

    final sentences = article.sentences
        .map((sentence) => sentence.trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
    final maxSentenceIndex = math.max(0, sentences.length - 1);
    final start = sentences.isEmpty
        ? math.max(0, page.sentenceStartIndex)
        : page.sentenceStartIndex.clamp(0, maxSentenceIndex).toInt();
    final end = sentences.isEmpty
        ? math.max(start, page.sentenceEndIndex)
        : page.sentenceEndIndex.clamp(start, maxSentenceIndex).toInt();
    final pageText = page.paragraphText.replaceAll(RegExp(r'\s+'), ' ').trim();
    final text = pageText.isNotEmpty
        ? pageText
        : sentences.isEmpty
            ? ''
            : sentences.sublist(start, end + 1).join(' ');
    if (text.trim().isEmpty) {
      return null;
    }

    var summary = _pageSceneDescription(page);
    if (summary.isEmpty && sentences.isNotEmpty) {
      summary = _sceneDescriptionForRange(sentences, start, end);
    }
    if (summary.isEmpty) {
      summary = _promptExcerpt(text, maxWords: 28, maxChars: 180);
    }

    return _PicturePageSegment(
      pageIndex: page.pageIndex,
      pageCount: math.max(1, pageCount),
      sentenceStartIndex: start,
      sentenceEndIndex: end,
      text: _normalizeFullChapterStoryForPrompt(text),
      summary: summary,
    );
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
    List<BookCharacter> relevantCharacters = const [],
  }) {
    final sanitizedCharacters = _sanitizeBookCharacters(relevantCharacters);
    final buffer = StringBuffer()
      ..writeln(
        'Book name: ${_sanitizeForImagePrompt(series.title.trim())}',
      )
      ..writeln(
        'Book description: ${_sanitizeForImagePrompt(series.description.trim())}',
      );
    if (sanitizedCharacters.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Relevant characters:');
      for (final character in sanitizedCharacters) {
        buffer.writeln('- ${character.name}: ${character.description}');
      }
    }
    buffer
      ..writeln()
      ..writeln(
        'Chapter description: ${_sanitizeForImagePrompt(plan.chapterDescription)}',
      );
    for (final segment in segments) {
      final sceneDescription = _sanitizeForImagePrompt(segment.summary);
      buffer
        ..writeln()
        ..writeln('Image ${segment.pageIndex + 1}:');
      if (sceneDescription.isNotEmpty) {
        buffer.writeln('Scene description: $sceneDescription');
      }
    }
    return buffer.toString().trim();
  }

  static String _composeSinglePagePrompt({
    required StorySeries series,
    required String chapterDescription,
    required _PicturePageSegment segment,
    List<BookCharacter> relevantCharacters = const [],
  }) {
    final sanitizedCharacters = _sanitizeBookCharacters(relevantCharacters);
    final sceneDescription = _sanitizeForImagePrompt(segment.summary);
    final buffer = StringBuffer()
      ..writeln(
        'Book name: ${_sanitizeForImagePrompt(series.title.trim())}',
      )
      ..writeln(
        'Book description: ${_sanitizeForImagePrompt(series.description.trim())}',
      );
    if (sanitizedCharacters.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Relevant characters:');
      for (final character in sanitizedCharacters) {
        buffer.writeln('- ${character.name}: ${character.description}');
      }
    }
    buffer
      ..writeln()
      ..writeln(
          'Chapter description: ${_sanitizeForImagePrompt(chapterDescription)}')
      ..writeln()
      ..writeln(
        'Generate exactly one picture for Image ${segment.pageIndex + 1}. Use the reference image only for visual consistency.',
      )
      ..writeln(
        'Do not generate other scenes, a collage, comic panels, or a multi-image sheet.',
      )
      ..writeln()
      ..writeln('Image ${segment.pageIndex + 1}:');
    if (sceneDescription.isNotEmpty) {
      buffer.writeln('Scene description: $sceneDescription');
    }
    return buffer.toString().trim();
  }

  static String _scenePromptForRequest(_PicturePageSegment segment) {
    return _sanitizeForImagePrompt([
      'Image ${segment.pageIndex + 1}',
      'Scene description: ${segment.summary}',
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
      summary: _sanitizeForImagePrompt(
        submitted['sceneDescription']?.toString().trim().isNotEmpty == true
            ? submitted['sceneDescription'].toString()
            : segment.summary,
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
    required String bookDescription,
    required List<BookCharacter> relevantCharacters,
    required String chapterDescription,
    required List<_PicturePageSegment> segments,
    List<BookCharacter> newCharacters = const [],
  }) async {
    await DatabaseService.updateStoryChapter(
      chapter.copyWith(
        summaryJson: ApiCacheService.canonicalJson(
          _chapterPlanSummaryJson(
            article: article,
            plan: ChapterPicturePlan(
              chapterDescription: chapterDescription,
              scenes: [
                for (final segment in segments)
                  PictureBookScene(
                    pageIndex: segment.pageIndex,
                    sentenceStartIndex: segment.sentenceStartIndex,
                    sentenceEndIndex: segment.sentenceEndIndex,
                    sceneDescription: segment.summary,
                  ),
              ],
              newCharacters: newCharacters,
              source: TextGenerationReplySource.cached,
            ),
          ),
        ),
        updatedAt: DateTime.now(),
      ),
    );
  }

  static Future<void> _saveSinglePageConfirmedChapterPlan({
    required Article article,
    required StoryChapter chapter,
    required String bookDescription,
    required List<BookCharacter> relevantCharacters,
    required String chapterDescription,
    required _PicturePageSegment segment,
    List<BookCharacter> newCharacters = const [],
  }) async {
    final articleId = article.id;
    final baseChapter = articleId == null
        ? chapter
        : await DatabaseService.getStoryChapterForArticle(articleId) ?? chapter;
    final rawSummary = _decodeJson(
      baseChapter.summaryJson,
      const <String, dynamic>{},
    );
    var scenes = _pictureBookScenesFromJson(
      rawSummary['scenes'],
      sentenceCount: article.sentences.length,
    );
    if (scenes.isEmpty && articleId != null) {
      final existingPages = await DatabaseService.getPictureBookPages(
        articleId,
      );
      final pageSegments = [
        for (final page in existingPages)
          if (_segmentFromExistingPage(
            article: article,
            page: page,
            pageCount: existingPages.length,
          )
              case final segment?)
            segment,
      ]..sort((a, b) => a.pageIndex.compareTo(b.pageIndex));
      scenes = [
        for (final pageSegment in pageSegments)
          PictureBookScene(
            pageIndex: pageSegment.pageIndex,
            sentenceStartIndex: pageSegment.sentenceStartIndex,
            sentenceEndIndex: pageSegment.sentenceEndIndex,
            sceneDescription: pageSegment.summary,
          ),
      ];
    }
    final mergedScenes = <PictureBookScene>[];
    var replaced = false;
    for (final scene in scenes) {
      if (scene.pageIndex == segment.pageIndex) {
        mergedScenes.add(
          PictureBookScene(
            pageIndex: segment.pageIndex,
            sentenceStartIndex: segment.sentenceStartIndex,
            sentenceEndIndex: segment.sentenceEndIndex,
            sceneDescription: segment.summary,
          ),
        );
        replaced = true;
      } else {
        mergedScenes.add(scene);
      }
    }
    if (!replaced) {
      mergedScenes.add(
        PictureBookScene(
          pageIndex: segment.pageIndex,
          sentenceStartIndex: segment.sentenceStartIndex,
          sentenceEndIndex: segment.sentenceEndIndex,
          sceneDescription: segment.summary,
        ),
      );
      mergedScenes.sort((a, b) => a.pageIndex.compareTo(b.pageIndex));
    }
    final mergedSegments = _segmentArticle(
      article,
      ChapterPicturePlan(
        chapterDescription: chapterDescription,
        scenes: mergedScenes,
        newCharacters: newCharacters,
        source: TextGenerationReplySource.cached,
      ),
    );
    await _saveConfirmedChapterPlan(
      article: article,
      chapter: baseChapter,
      bookDescription: bookDescription,
      relevantCharacters: relevantCharacters,
      chapterDescription: chapterDescription,
      segments: mergedSegments,
      newCharacters: newCharacters,
    );
  }

  static Map<String, dynamic> _promptJsonForSegment({
    required StorySeries series,
    required StoryChapter chapter,
    required _PicturePageSegment segment,
    required String chapterDescription,
    required List<BookCharacter> relevantCharacters,
    required List<BookCharacter> newCharacters,
    required String groupPrompt,
    String? reviewId,
  }) {
    return {
      'planKind': _chapterPlanCachePurpose,
      'promptPolicyVersion': _promptPolicyVersion,
      'seriesTitle': series.title,
      'bookDescription': series.description,
      'bookCharacters': _sanitizeBookCharacters(series.characters)
          .map((item) => item.toJson())
          .toList(),
      'relevantCharacters': _sanitizeBookCharacters(relevantCharacters)
          .map((item) => item.toJson())
          .toList(),
      'newCharacters': _sanitizeBookCharacters(newCharacters)
          .map((item) => item.toJson())
          .toList(),
      'chapterOrder': chapter.chapterOrder,
      'chapterTitle': chapter.chapterTitle,
      'chapterDescription': chapterDescription,
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
        summary: scene.sceneDescription,
      );
    }).toList(growable: false);
  }

  static List<_PicturePageSegment> _blankPromptReviewSegments(
    Article article,
  ) {
    // These are editable placeholders for the review dialog, not an AI scene
    // plan. Keep descriptions empty and only derive ranges so users can see
    // what each draft row covers before they type or explicitly refresh AI.
    final sentences = article.sentences
        .map((sentence) => sentence.trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
    if (sentences.isEmpty) {
      return const [];
    }
    final ranges = _draftSceneRanges(article.content, sentences);
    return [
      for (var index = 0; index < ranges.length; index += 1)
        _PicturePageSegment(
          pageIndex: index,
          pageCount: ranges.length,
          sentenceStartIndex: ranges[index].$1,
          sentenceEndIndex: ranges[index].$2,
          text: _normalizeFullChapterStoryForPrompt(
            sentences.sublist(ranges[index].$1, ranges[index].$2 + 1).join(' '),
          ),
          summary: '',
        ),
    ];
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

  static List<(int, int)> _paragraphSentenceRanges(
    String content,
    List<String> sentences,
  ) {
    final normalizedParagraphs = content
        .split(RegExp(r'\n\s*\n+'))
        .map((paragraph) => paragraph.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((paragraph) => paragraph.isNotEmpty)
        .toList(growable: false);
    if (normalizedParagraphs.length <= 1) {
      return [(0, sentences.length - 1)];
    }

    final ranges = <(int, int)>[];
    var cursor = 0;
    for (final paragraph in normalizedParagraphs) {
      if (cursor >= sentences.length) {
        break;
      }
      final start = cursor;
      var end = start;
      final paragraphLower = paragraph.toLowerCase();
      while (end < sentences.length &&
          paragraphLower.contains(sentences[end].toLowerCase())) {
        end += 1;
      }
      if (end == start) {
        end = start + 1;
      }
      ranges.add((start, math.min(end - 1, sentences.length - 1)));
      cursor = math.min(end, sentences.length);
    }
    if (ranges.isEmpty) {
      return [(0, sentences.length - 1)];
    }
    final last = ranges.removeLast();
    ranges.add((last.$1, sentences.length - 1));
    return ranges;
  }

  static List<(int, int)> _limitSceneRanges(
    List<(int, int)> ranges,
    int sentenceCount,
  ) {
    if (ranges.length <= _maxSceneCount) {
      return ranges;
    }
    final limited = <(int, int)>[];
    for (var index = 0; index < _maxSceneCount; index += 1) {
      final start = (index * sentenceCount / _maxSceneCount).floor();
      final end = index == _maxSceneCount - 1
          ? sentenceCount - 1
          : (((index + 1) * sentenceCount / _maxSceneCount).floor() - 1);
      limited.add((start, math.max(start, end)));
    }
    return limited;
  }

  static List<(int, int)> _draftSceneRanges(
    String content,
    List<String> sentences,
  ) {
    // Placeholder row contract: multi-paragraph chapters start with paragraph
    // ranges capped at 12; single-paragraph chapters use one row per sentence
    // up to 12; longer single paragraphs are evenly split into 12 ranges.
    final sentenceCount = sentences.length;
    final paragraphRanges = _paragraphSentenceRanges(content, sentences);
    if (paragraphRanges.length > 1) {
      return _limitSceneRanges(paragraphRanges, sentenceCount);
    }
    final sceneCount = math.min(_maxSceneCount, sentenceCount);
    if (sceneCount <= 1) {
      return [(0, sentenceCount - 1)];
    }
    return [
      for (var index = 0; index < sceneCount; index += 1)
        (
          (index * sentenceCount / sceneCount).floor(),
          index == sceneCount - 1
              ? sentenceCount - 1
              : math.max(
                  (index * sentenceCount / sceneCount).floor(),
                  (((index + 1) * sentenceCount / sceneCount).floor() - 1),
                ),
        ),
    ];
  }

  static String _sceneDescriptionForRange(
    List<String> sentences,
    int start,
    int end,
  ) {
    final slice = sentences.sublist(start, end + 1);
    final joined = slice.join(' ');
    if (joined.length <= 180) {
      return joined;
    }
    if (slice.length == 1) {
      return _promptExcerpt(joined, maxWords: 28, maxChars: 180);
    }
    return '${_promptExcerpt(slice.first, maxWords: 14, maxChars: 90)} ... '
        '${_promptExcerpt(slice.last, maxWords: 14, maxChars: 90)}';
  }

  @visibleForTesting
  static List<Map<String, dynamic>> pictureSegmentsForTest(Article article) {
    final sentences = article.sentences
        .map((sentence) => sentence.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
    if (sentences.isEmpty) {
      return const [];
    }
    final ranges = _limitSceneRanges(
      _paragraphSentenceRanges(article.content, sentences),
      sentences.length,
    );
    return [
      for (var index = 0; index < ranges.length; index += 1)
        {
          'pageIndex': index,
          'sentenceStartIndex': ranges[index].$1,
          'sentenceEndIndex': ranges[index].$2,
          'summary': _sceneDescriptionForRange(
            sentences,
            ranges[index].$1,
            ranges[index].$2,
          ),
          'text': sentences
              .sublist(ranges[index].$1, ranges[index].$2 + 1)
              .join(' '),
        },
    ];
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
      if (scene['sceneDescription']?.toString().trim().isNotEmpty == true)
        'Scene description: ${scene['sceneDescription']}',
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
      RegExp(r'\btext[- ]free\b', caseSensitive: false): 'full-frame in-world',
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

  static List<BookCharacter> _bookCharactersFromJson(Object? raw) {
    if (raw is String) {
      try {
        return _bookCharactersFromJson(jsonDecode(raw));
      } catch (_) {
        return const [];
      }
    }
    if (raw is! List) {
      return const [];
    }
    return _sanitizeBookCharacters(raw.map(BookCharacter.fromJson).toList());
  }

  static List<BookCharacter> _sanitizeBookCharacters(
    List<BookCharacter> characters,
  ) {
    final output = <BookCharacter>[];
    final seen = <String>{};
    for (final character in characters) {
      final name = character.name.replaceAll(RegExp(r'\s+'), ' ').trim();
      final description = _sanitizeForImagePrompt(character.description);
      if (name.isEmpty || description.isEmpty) {
        continue;
      }
      final key = name.toLowerCase();
      if (seen.contains(key)) {
        continue;
      }
      seen.add(key);
      output.add(BookCharacter(name: name, description: description));
    }
    return output;
  }

  static List<BookCharacter> _mergeBookCharacters(
    List<BookCharacter> base,
    List<BookCharacter> additions,
  ) {
    final output = <BookCharacter>[];
    final seen = <String>{};
    for (final character in [
      ..._sanitizeBookCharacters(base),
      ..._sanitizeBookCharacters(additions),
    ]) {
      final key = character.name.toLowerCase();
      if (seen.contains(key)) {
        continue;
      }
      seen.add(key);
      output.add(character);
    }
    return output;
  }

  static List<BookCharacter> _relevantBookCharactersForArticle(
    Article article,
    List<BookCharacter> characters,
  ) {
    final haystack = [
      article.title,
      article.content,
      ...article.sentences,
    ].join('\n').toLowerCase();
    return [
      for (final character in _sanitizeBookCharacters(characters))
        if (character.name.length >= 2 &&
            haystack.contains(character.name.toLowerCase()))
          character,
    ];
  }

  static String _charactersForPrompt(List<BookCharacter> characters) {
    final sanitized = _sanitizeBookCharacters(characters);
    if (sanitized.isEmpty) {
      return 'None';
    }
    return [
      for (final character in sanitized)
        '- ${character.name}: ${character.description}',
    ].join('\n');
  }

  static String _promptExcerpt(
    String text, {
    required int maxWords,
    required int maxChars,
  }) {
    var safe = _sanitizeForImagePrompt(text);
    if (safe.isEmpty) {
      return safe;
    }
    if (safe.length > maxChars) {
      safe = _shorten(safe, maxChars);
    }
    final words = safe
        .split(RegExp(r'\s+'))
        .where((word) => word.trim().isNotEmpty)
        .toList(growable: false);
    if (words.length <= maxWords) {
      return safe;
    }
    return _cleanPromptPunctuation(words.take(maxWords).join(' '));
  }

  static String _sanitizeBookDescription(String text) {
    var cleaned = _sanitizeForImagePrompt(text);
    if (cleaned.isEmpty) {
      return cleaned;
    }
    cleaned = cleaned.replaceAll(
      RegExp(
        r'\s*(Chapter mood and anchors|Chapter mood|Chapter anchors|Chapter character additions|Current chapter description|Current chapterDescription)\s*:\s*.*$',
        caseSensitive: false,
      ),
      '',
    );
    cleaned = cleaned.replaceAll(
      RegExp(
        r',?\s*with compact recurring character appearance anchors,\s*stable role-based appearances for recurring groups,\s*',
        caseSensitive: false,
      ),
      ', with ',
    );
    cleaned = cleaned.replaceAll(
      RegExp(
        r'\bas a warm child-friendly picture-book world\b',
        caseSensitive: false,
      ),
      'in a warm child-friendly storybook setting',
    );
    cleaned = cleaned.replaceAll(
      RegExp(r'\bstable appearance anchors\b', caseSensitive: false),
      'consistent visible details',
    );
    cleaned = cleaned.replaceAll(
      RegExp(r'\bclear scene details\b', caseSensitive: false),
      'clear visual detail',
    );
    cleaned = cleaned.replaceAll(
      RegExp(r'\s*,\s*,\s*'),
      ', ',
    );
    return _sanitizeForImagePrompt(cleaned);
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
    required this.summary,
  });

  final int pageIndex;
  final int pageCount;
  final int sentenceStartIndex;
  final int sentenceEndIndex;
  final String text;
  final String summary;

  _PicturePageSegment copyWith({
    int? pageIndex,
    int? pageCount,
    int? sentenceStartIndex,
    int? sentenceEndIndex,
    String? text,
    String? summary,
  }) =>
      _PicturePageSegment(
        pageIndex: pageIndex ?? this.pageIndex,
        pageCount: pageCount ?? this.pageCount,
        sentenceStartIndex: sentenceStartIndex ?? this.sentenceStartIndex,
        sentenceEndIndex: sentenceEndIndex ?? this.sentenceEndIndex,
        text: text ?? this.text,
        summary: summary ?? this.summary,
      );

  Map<String, dynamic> toJson() => {
        'pageIndex': pageIndex,
        'sentenceStartIndex': sentenceStartIndex,
        'sentenceEndIndex': sentenceEndIndex,
        'sceneDescription': summary,
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
        'sceneDescription': segment.summary,
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
    required this.bookCharacters,
    required this.relevantCharacters,
    required this.newCharacters,
    required this.chapterDescription,
    required this.groupPrompt,
    required this.createdAt,
    this.mode = 'group',
    this.targetPageIndex,
    this.referencePageIndex,
    this.referenceImagePath,
  });

  final String reviewId;
  final Article article;
  final StoryChapter chapter;
  final StorySeries series;
  final bool regenerate;
  final List<_PromptReviewPageDraft> pages;
  final String bookDescription;
  final List<BookCharacter> bookCharacters;
  final List<BookCharacter> relevantCharacters;
  final List<BookCharacter> newCharacters;
  final String chapterDescription;
  final String groupPrompt;
  final DateTime createdAt;
  final String mode;
  final int? targetPageIndex;
  final int? referencePageIndex;
  final String? referenceImagePath;

  _PictureBookPromptReviewDraft copyWith({
    StorySeries? series,
    List<_PromptReviewPageDraft>? pages,
    String? bookDescription,
    List<BookCharacter>? bookCharacters,
    List<BookCharacter>? relevantCharacters,
    List<BookCharacter>? newCharacters,
    String? chapterDescription,
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
        bookCharacters: bookCharacters ?? this.bookCharacters,
        relevantCharacters: relevantCharacters ?? this.relevantCharacters,
        newCharacters: newCharacters ?? this.newCharacters,
        chapterDescription: chapterDescription ?? this.chapterDescription,
        groupPrompt: groupPrompt ?? this.groupPrompt,
        createdAt: createdAt,
        mode: mode,
        targetPageIndex: targetPageIndex,
        referencePageIndex: referencePageIndex,
        referenceImagePath: referenceImagePath,
      );

  Map<String, dynamic> toPayload() => {
        'reviewId': reviewId,
        'articleId': article.id,
        'chapterId': chapter.id,
        'seriesId': series.id,
        'bookTitle': series.title,
        'mode': mode,
        if (targetPageIndex != null) 'targetPageIndex': targetPageIndex,
        if (referencePageIndex != null)
          'referencePageIndex': referencePageIndex,
        'regenerate': regenerate,
        'bookDescription': bookDescription,
        'bookCharacters':
            bookCharacters.map((item) => item.toJson()).toList(growable: false),
        'relevantCharacters': relevantCharacters
            .map((item) => item.toJson())
            .toList(growable: false),
        'newCharacters':
            newCharacters.map((item) => item.toJson()).toList(growable: false),
        'chapterDescription': chapterDescription,
        'groupPrompt': groupPrompt,
        'scenes': pages.map((page) => page.toPayload()).toList(growable: false),
        'createdAt': createdAt.toIso8601String(),
      };
}

class ChapterPicturePlan {
  const ChapterPicturePlan({
    required this.chapterDescription,
    required this.scenes,
    this.newCharacters = const [],
    required this.source,
  });

  final String chapterDescription;
  final List<PictureBookScene> scenes;
  final List<BookCharacter> newCharacters;
  final TextGenerationReplySource source;
}

class PictureBookScene {
  const PictureBookScene({
    required this.pageIndex,
    required this.sentenceStartIndex,
    required this.sentenceEndIndex,
    required this.sceneDescription,
  });

  final int pageIndex;
  final int sentenceStartIndex;
  final int sentenceEndIndex;
  final String sceneDescription;

  PictureBookScene copyWith({
    int? pageIndex,
    int? sentenceStartIndex,
    int? sentenceEndIndex,
    String? sceneDescription,
  }) =>
      PictureBookScene(
        pageIndex: pageIndex ?? this.pageIndex,
        sentenceStartIndex: sentenceStartIndex ?? this.sentenceStartIndex,
        sentenceEndIndex: sentenceEndIndex ?? this.sentenceEndIndex,
        sceneDescription: sceneDescription ?? this.sceneDescription,
      );

  Map<String, dynamic> toJson() => {
        'pageIndex': pageIndex,
        'sentenceStartIndex': sentenceStartIndex,
        'sentenceEndIndex': sentenceEndIndex,
        'sceneDescription': sceneDescription,
      };
}
