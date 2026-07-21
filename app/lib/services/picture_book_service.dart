import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path_lib;

import '../core/logging/tomato_logger.dart';
import '../data/models/article_model.dart';
import '../data/models/picture_book_model.dart';
import 'api_cache_service.dart';
import 'database_service.dart';
import 'picture_book_image_service.dart';
import 'practice_text_service.dart';
import 'text_generation_service.dart';
import 'volc_image_service.dart';

typedef PictureBookProgressCallback = FutureOr<void> Function(
  Map<String, dynamic> state,
);

/// Result of a remote chapter-plan generation call.
class GeneratedChapterPlanResult {
  const GeneratedChapterPlanResult({
    required this.plan,
    this.title,
  });

  final ChapterPicturePlan plan;
  final String? title;
}

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
/// - 首次章节规划可在 `article.create` 时生成并写入 `summary_json`；之后需要新分镜时，只能由用户显式触发：`pictureBook.refreshPromptReview(target: chapterPlan)`，或删文后重新走审核流程。
/// - 打开 `pictureBook.promptReview` 时：优先读取 `summary_json` 中 `planKind=picture_book_chapter_scene_plan_v2` 且 `scenes[].sceneDescription` 非空的计划；读不到时才回退 `_blankPromptReviewSegments` 空占位。
/// - 「Relevant characters」只由本服务按文章正文 + 书籍角色表匹配（首字母大写整词）；Web UI 不得再本地重算，编辑书籍角色时走 `pictureBook.resolveRelevantCharacters`。
/// - **不要**在计划失效时只保留 `chapterDescription` 却清空分镜；这会让 UI 看起来像“有章节描述、没分镜”，并误导用户直接确认出图。
/// - 对话练习提纲（`ChatChapterGuideService`）仍可使用自己的 `contentHash`；那是独立链路，不要复用到绘本分镜。
///
/// ## 章节分镜切分调优（通用「插画情况」三轴）
///
/// 一张绘本页是听力区间共用的插画，不是文学微节拍列表。切分只看三轴是否变化：
/// 地点/时间、主视觉焦点人物组、中心进行中活动。中心活动 = 焦点人物的主任务及
/// 目标，**不是**每个新可见节拍/道具/姿态/台词。对话轮次、反应、情绪、旁白、
/// 同类型重复微动作、同一事故的直接结果与收拾余波不单独开景。每个分镜只描述
/// 自身句子区间内的事件并保持人物动作归属；返回前逐对审核相邻边界。编号句子只是
/// 覆盖锚点。不要在 prompt 里写死某本书或某类场景名当合并条件；细节见
/// `_chapterPlanPromptRuleLines`。完整调优过程与实测结论见
/// `docs/picture_book_chapter_plan_scene_split_tuning.md`。
class PictureBookService {
  static final Map<String, String> _imageUriCache = <String, String>{};
  static final Map<String, String> _thumbnailPathCache = <String, String>{};
  static final Map<String, String> _displayPathCache = <String, String>{};
  static final Queue<_PictureBookGenerationJob> _generationQueue =
      Queue<_PictureBookGenerationJob>();
  static final Map<String, _PictureBookPromptReviewDraft> _promptReviewDrafts =
      <String, _PictureBookPromptReviewDraft>{};
  static final Map<int, int> _scheduledGenerationCounts = <int, int>{};
  static int _activeGenerationJobs = 0;
  static int _promptReviewSequence = 0;
  static const int _creationThumbnailMaxWidth = 640;
  static const int _creationThumbnailMaxHeight = 360;
  static const int _maxSinglePageReferenceImages = 14;
  // "display" sits between the small list thumbnail and the raw remote original (up to
  // 2560x1440). Inline scene viewers (listening/follow/chat) render into a box no wider than
  // ~1120px via CSS `object-fit: cover`; feeding them the raw original there caused WebView2/
  // ANGLE GPU texture corruption (blocky color-noise artifacts) on some Windows GPU drivers
  // because of the very heavy downscale ratio. Only true fullscreen playback and the
  // creation-center lightbox preview should request the raw "full" original.
  static const int _creationDisplayMaxWidth = 1280;
  static const int _creationDisplayMaxHeight = 720;
  /// Matches Seedream remote full originals (16:9). Imported pages are
  /// cover-cropped and natively re-encoded to this size before cache write.
  static const int _importedFullWidth = 2560;
  static const int _importedFullHeight = 1440;
  static const List<String> importedImageExtensions = <String>[
    'png',
    'jpg',
    'jpeg',
    'webp',
  ];
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
    final generated = await generateChapterPlanForArticle(
      article: article,
      bookDescription: currentSeries.description,
      relevantCharacters: relevantCharacters,
    );
    await persistChapterPlanForArticle(
      article: article,
      chapter: chapter,
      plan: generated.plan,
    );
    return generated.plan;
  }

  /// Generate a chapter scene plan via text AI.
  ///
  /// When [includeTitle] is true, the same JSON response also includes a short
  /// English `title` so article create can avoid a separate title-only call.
  static Future<GeneratedChapterPlanResult> generateChapterPlanForArticle({
    required Article article,
    required String bookDescription,
    required List<BookCharacter> relevantCharacters,
    bool includeTitle = false,
  }) async {
    final reply = await TextGenerationService.generateStrict(
      turns: _chapterPlanPromptTurns(
        article: article,
        bookDescription: bookDescription,
        relevantCharacters: relevantCharacters,
        includeTitle: includeTitle,
      ),
      cachePurpose: _chapterPlanCachePurpose,
      articleId: article.id,
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
      strictSceneValidation: true,
    );
    if (plan == null) {
      throw const TextGenerationException(
        '文本提交处理失败：AI 未返回有效绘本分镜，请重试。',
      );
    }
    String? title;
    if (includeTitle) {
      final rawTitle = raw['title']?.toString().trim() ?? '';
      if (rawTitle.isEmpty) {
        throw const TextGenerationException(
          '标题生成失败：AI 未返回有效标题，请重试。',
        );
      }
      title = PracticeTextService.cleanArticleTitle(rawTitle);
    } else {
      final rawTitle = raw['title']?.toString().trim() ?? '';
      if (rawTitle.isNotEmpty) {
        try {
          title = PracticeTextService.cleanArticleTitle(rawTitle);
        } catch (_) {
          title = null;
        }
      }
    }
    return GeneratedChapterPlanResult(plan: plan, title: title);
  }

  /// Persist a generated chapter plan into `story_chapters.summary_json`.
  static Future<StoryChapter> persistChapterPlanForArticle({
    required Article article,
    required StoryChapter chapter,
    required ChapterPicturePlan plan,
  }) async {
    final updated = chapter.copyWith(
      summaryJson: ApiCacheService.canonicalJson(
        _chapterPlanSummaryJson(
          article: article,
          plan: plan,
        ),
      ),
      updatedAt: DateTime.now(),
    );
    await DatabaseService.updateStoryChapter(updated);
    return updated;
  }

  /// Parse a chapter-plan JSON payload, optionally requiring a title field.
  @visibleForTesting
  static GeneratedChapterPlanResult? parseGeneratedChapterPlan(
    Map<String, dynamic> json, {
    required int sentenceCount,
    required TextGenerationReplySource source,
    bool requireTitle = false,
  }) {
    final plan = _chapterPlanFromJson(
      json,
      sentenceCount: sentenceCount,
      source: source,
      strictSceneValidation: true,
    );
    if (plan == null) {
      return null;
    }
    String? title;
    final rawTitle = json['title']?.toString().trim() ?? '';
    if (rawTitle.isNotEmpty) {
      try {
        title = PracticeTextService.cleanArticleTitle(rawTitle);
      } catch (_) {
        if (requireTitle) {
          return null;
        }
      }
    } else if (requireTitle) {
      return null;
    }
    return GeneratedChapterPlanResult(plan: plan, title: title);
  }

  /// Exposed for unit tests that assert includeTitle JSON shape wording.
  @visibleForTesting
  static String chapterPlanJsonShapeForTest({required bool includeTitle}) =>
      _chapterPlanJsonShape(includeTitle: includeTitle);

  @visibleForTesting
  static List<TextGenerationTurn> chapterPlanPromptTurnsForTest({
    required Article article,
    required String bookDescription,
    required List<BookCharacter> relevantCharacters,
    bool includeTitle = false,
  }) =>
      _chapterPlanPromptTurns(
        article: article,
        bookDescription: bookDescription,
        relevantCharacters: relevantCharacters,
        includeTitle: includeTitle,
      );

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

    final referenceOptions = await _referencePageOptions(
      articleId: articleId,
      targetPageIndex: pageIndex,
    );
    if (referenceOptions.isEmpty) {
      return promptReviewPayload(
        article: article,
        chapter: currentChapter,
        regenerate: true,
      );
    }

    final referencePage = await _nearestReferencePage(
      articleId: articleId,
      targetPageIndex: pageIndex,
    );
    final defaultReferencePageIndex = referencePage != null &&
            referenceOptions.contains(referencePage.pageIndex)
        ? referencePage.pageIndex
        : referenceOptions.first;
    final defaultReferenceImagePath = await _referenceImagePathForPageIndex(
      articleId: articleId,
      pageIndex: defaultReferencePageIndex,
    );
    if (defaultReferenceImagePath == null) {
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

    final useLocalEdit =
        targetPage != null && await _hasUsableReferenceImage(targetPage);
    final editDefaultReferencePageIndex =
        useLocalEdit && referenceOptions.contains(pageIndex)
            ? pageIndex
            : defaultReferencePageIndex;
    final editDefaultReferenceImagePath = useLocalEdit
        ? await _referenceImagePathForPageIndex(
            articleId: articleId,
            pageIndex: editDefaultReferencePageIndex,
          )
        : defaultReferenceImagePath;
    if (editDefaultReferenceImagePath == null) {
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
    final singlePrompt = useLocalEdit
        ? ''
        : _composeSinglePagePrompt(
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
      mode: useLocalEdit ? 'singlePageEdit' : 'singlePage',
      targetPageIndex: pageIndex,
      referencePageIndex: editDefaultReferencePageIndex,
      referenceImagePath: editDefaultReferenceImagePath,
      referenceOptions: referenceOptions,
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
        final refreshed = await generateChapterPlanForArticle(
          article: draft.article,
          bookDescription: currentBookDescription,
          relevantCharacters: currentRelevantCharacters,
        );
        currentChapterDescription = refreshed.plan.chapterDescription;
        currentNewCharacters =
            _sanitizeBookCharacters(refreshed.plan.newCharacters);
        currentSegments = _segmentArticle(
          draft.article,
          refreshed.plan,
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
      _displayPathCache.clear();
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
    List<int>? referencePageIndexes,
    int? referencePageIndex,
    PictureBookProgressCallback? onProgress,
  }) async {
    final draft = _promptReviewDrafts[reviewId];
    if (draft == null) {
      throw const FormatException('绘本提示词审核已过期，请重新打开审核弹窗。');
    }
    final isLocalEdit = draft.mode == 'singlePageEdit';
    if (draft.mode != 'singlePage' && !isLocalEdit) {
      throw const FormatException('当前审核不是单页重生成审核，请重新打开审核弹窗。');
    }
    final articleId = draft.article.id;
    final seriesId = draft.series.id;
    final targetPageIndex = draft.targetPageIndex;
    if (articleId == null || seriesId == null || targetPageIndex == null) {
      throw const FormatException('绘本提示词审核缺少文章或书籍信息。');
    }

    final referenceOptions = await _referencePageOptions(
      articleId: articleId,
      targetPageIndex: targetPageIndex,
    );
    if (referenceOptions.isEmpty) {
      throw const FormatException('没有可用的参考图，请重新打开单页重生成。');
    }

    final requestedReferencePageIndexes = _resolveRequestedReferencePageIndexes(
      referencePageIndexes: referencePageIndexes,
      referencePageIndex: referencePageIndex,
      draftReferencePageIndex: draft.referencePageIndex,
    );
    if (requestedReferencePageIndexes.isEmpty) {
      throw const FormatException('请至少选择一张参考图片。');
    }
    if (requestedReferencePageIndexes.length > _maxSinglePageReferenceImages) {
      throw const FormatException('参考图最多选择 14 张，请减少选择后重试。');
    }
    for (final pageIndex in requestedReferencePageIndexes) {
      if (!referenceOptions.contains(pageIndex)) {
        throw const FormatException('所选参考图无效，请重新选择参考图片。');
      }
    }
    final referenceImagePaths = await _referenceImagePathsForPageIndexes(
      articleId: articleId,
      pageIndexes: requestedReferencePageIndexes,
    );
    if (referenceImagePaths.length != requestedReferencePageIndexes.length) {
      throw const FormatException('参考图文件不存在，请重新打开单页重生成。');
    }

    final targetSegment =
        draft.pages.length == 1 ? draft.pages.single.segment : null;
    if (targetSegment == null) {
      throw const FormatException('单页重生成只能提交一个分镜。');
    }

    late final String confirmedSinglePrompt;
    late final Map<String, dynamic> promptJson;
    late final _PicturePageSegment pageSegment;

    if (isLocalEdit) {
      final editInstruction = groupPrompt.trim();
      if (editInstruction.isEmpty) {
        throw const FormatException('请填写需要修改的内容说明。');
      }
      confirmedSinglePrompt = _composeSinglePageEditPrompt(editInstruction);
      pageSegment = targetSegment;
      promptJson = {
        ..._promptJsonForSegment(
          series: draft.series,
          chapter: draft.chapter,
          segment: pageSegment,
          chapterDescription: draft.chapterDescription,
          relevantCharacters: draft.relevantCharacters,
          newCharacters: draft.newCharacters,
          groupPrompt: confirmedSinglePrompt,
          reviewId: reviewId,
        ),
        'mode': 'singlePageEdit',
        'editInstruction': _sanitizeForImagePrompt(editInstruction),
        'targetPageIndex': pageSegment.pageIndex,
        'referencePageIndex': requestedReferencePageIndexes.first,
        'referencePageIndexes': requestedReferencePageIndexes,
      };
    } else {
      final confirmedSegments = _submittedSegmentsForDraft(draft, scenes);
      if (confirmedSegments.length != 1) {
        throw const FormatException('单页重生成只能提交一个分镜。');
      }
      pageSegment = confirmedSegments.single;
      final confirmedChapterDescription = chapterDescription.trim().isEmpty
          ? draft.chapterDescription
          : _sanitizeForImagePrompt(chapterDescription);
      final confirmedBookDescription =
          _sanitizeBookDescription(bookDescription);
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

      final fallbackSinglePrompt = _composeSinglePagePrompt(
        series: updatedSeries,
        chapterDescription: confirmedChapterDescription,
        segment: pageSegment,
        relevantCharacters: finalRelevantCharacters,
      );
      confirmedSinglePrompt = groupPrompt.trim().isEmpty
          ? fallbackSinglePrompt
          : _sanitizeForImagePrompt(groupPrompt);

      await _saveSinglePageConfirmedChapterPlan(
        article: draft.article,
        chapter: draft.chapter,
        bookDescription: confirmedBookDescription,
        relevantCharacters: finalRelevantCharacters,
        chapterDescription: confirmedChapterDescription,
        segment: pageSegment,
        newCharacters: confirmedNewCharacters,
      );

      promptJson = {
        ..._promptJsonForSegment(
          series: updatedSeries,
          chapter: draft.chapter,
          segment: pageSegment,
          chapterDescription: confirmedChapterDescription,
          relevantCharacters: finalRelevantCharacters,
          newCharacters: confirmedNewCharacters,
          groupPrompt: confirmedSinglePrompt,
          reviewId: reviewId,
        ),
        'mode': 'singlePage',
        'targetPageIndex': pageSegment.pageIndex,
        'referencePageIndex': requestedReferencePageIndexes.first,
        'referencePageIndexes': requestedReferencePageIndexes,
      };
    }

    final generatingPage = await _markPage(
      pageSegment,
      articleId: articleId,
      seriesId: seriesId,
      status: 'generating',
      promptJson: promptJson,
      errorMessage: '',
    );
    _imageUriCache.clear();
    _thumbnailPathCache.clear();
    _displayPathCache.clear();
    await _emit(articleId, onProgress);

    final results = await PictureBookImageService.generatePictureBookImageGroup(
      requests: [
        VolcImageBatchRequest(
          pageIndex: pageSegment.pageIndex,
          prompt: confirmedSinglePrompt,
          promptMetadata: promptJson,
        ),
      ],
      articleId: articleId,
      seriesId: seriesId,
      referenceImagePaths: referenceImagePaths,
      groupPromptOverride: confirmedSinglePrompt,
      useSequential: false,
      reusePartialCache: false,
    );
    final result = results.firstWhere(
      (item) => item.pageIndex == pageSegment.pageIndex,
      orElse: () => results.isNotEmpty
          ? results.first
          : VolcImageResult(
              source: VolcImageResultSource.failed,
              pageIndex: pageSegment.pageIndex,
              errorMessage: '单页图片接口未返回第 ${pageSegment.pageIndex + 1} 张图片',
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
    _displayPathCache.clear();
    await _emit(articleId, onProgress);

    _promptReviewDrafts.remove(reviewId);
    return statePayload(articleId);
  }

  /// Replace one existing page image with a local file.
  ///
  /// Does not call image APIs, open prompt review, or rewrite chapter plans.
  /// Sources already at [_importedFullWidth]×[_importedFullHeight] are stored
  /// as-is; others are cover-cropped with bilinear filtering to that size as PNG.
  static Future<Map<String, dynamic>> importPageImage({
    required int articleId,
    required int pageIndex,
    required String sourcePath,
  }) async {
    final trimmedPath = sourcePath.trim();
    if (trimmedPath.isEmpty) {
      throw const FormatException('请选择要导入的图片文件');
    }
    final extension = _normalizedImageExtension(trimmedPath);
    if (!importedImageExtensions.contains(extension)) {
      throw const FormatException('请选择 png、jpg、jpeg 或 webp 图片文件');
    }
    final sourceFile = File(trimmedPath);
    if (!await sourceFile.exists()) {
      throw const FormatException('选择的图片文件不存在');
    }

    final pages = await DatabaseService.getPictureBookPages(articleId);
    PictureBookPage? targetPage;
    for (final page in pages) {
      if (page.pageIndex == pageIndex) {
        targetPage = page;
        break;
      }
    }
    if (targetPage == null) {
      throw FormatException('绘本第 ${pageIndex + 1} 页不存在，无法导入图片');
    }
    if (targetPage.status == 'generating') {
      throw const FormatException('该页正在生成中，请稍后再导入图片');
    }

    final sourceBytes = await sourceFile.readAsBytes();
    if (sourceBytes.isEmpty) {
      throw const FormatException('选择的图片文件为空');
    }
    final normalized = await _prepareImportedImageBytes(
      Uint8List.fromList(sourceBytes),
      sourceExtension: extension,
    );
    if (normalized.bytes.isEmpty) {
      throw const FormatException('无法读取或转换所选图片');
    }

    final contentHash = await ApiCacheService.hashBytes(normalized.bytes);
    final request = <String, dynamic>{
      'kind': 'picture_book_page_import',
      'articleId': articleId,
      'pageIndex': pageIndex,
      'contentHash': contentHash,
      'width': _importedFullWidth,
      'height': _importedFullHeight,
      'resized': normalized.resized,
    };
    final cacheKey = await ApiCacheService.keyForJson(
      'picture_book_page_import',
      request,
    );
    final filePath = await ApiCacheService.putFileBytes(
      cacheKey: cacheKey,
      kind: 'file',
      purpose: 'picture_book_image',
      request: request,
      bytes: normalized.bytes,
      subdirectory: 'picture_book',
      extension: normalized.extension,
      contentType: normalized.contentType,
      articleId: articleId,
      source: 'import',
    );

    final previousCacheKey = (targetPage.imageCacheKey ?? '').trim();
    await DatabaseService.upsertPictureBookPage(
      targetPage.copyWith(
        imageCacheKey: cacheKey,
        imagePath: filePath,
        status: 'ready',
        errorMessage: '',
        updatedAt: DateTime.now(),
      ),
    );

    if (previousCacheKey.isNotEmpty && previousCacheKey != cacheKey) {
      await ApiCacheService.deleteEntriesByKeys({previousCacheKey});
    }
    _imageUriCache.clear();
    _thumbnailPathCache.clear();
    _displayPathCache.clear();

    TomatoLogger.info(
      category: 'pictureBook',
      event: 'page_image.imported',
      articleId: articleId,
      data: {
        'pageIndex': pageIndex,
        'cacheKeyHash':
            cacheKey.length > 16 ? cacheKey.substring(0, 16) : cacheKey,
        'byteLength': normalized.bytes.length,
        'width': _importedFullWidth,
        'height': _importedFullHeight,
        'resized': normalized.resized,
      },
    );

    return statePayload(articleId);
  }

  /// Export ready page images for one chapter into [outputDirectory].
  ///
  /// File names use 1-based zero-padded scene index plus the source extension
  /// (e.g. `01.png`). When [overwrite] is false and [namePrefix] is empty,
  /// existing target names return [needsConflictResolution] without writing.
  static Future<Map<String, dynamic>> exportChapterImages({
    required int articleId,
    required String outputDirectory,
    bool overwrite = false,
    String namePrefix = '',
  }) async {
    final directoryPath = outputDirectory.trim();
    if (directoryPath.isEmpty) {
      throw const FormatException('请选择导出目录');
    }
    final directory = Directory(directoryPath);
    if (!await directory.exists()) {
      throw const FormatException('导出目录不存在');
    }

    final pages = await DatabaseService.getPictureBookPages(articleId);
    final readyPages = pages
        .where((page) {
          if (page.status != 'ready') {
            return false;
          }
          final path = (page.imagePath ?? '').trim();
          return path.isNotEmpty;
        })
        .toList(growable: false)
      ..sort((a, b) => a.pageIndex.compareTo(b.pageIndex));

    if (readyPages.isEmpty) {
      throw const FormatException('本章还没有可导出的绘本图片');
    }

    final prefix = namePrefix.trim();
    final planned = <_ExportChapterImagePlan>[];
    for (final page in readyPages) {
      final sourcePath = page.imagePath!.trim();
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        throw FormatException(
          '第 ${page.pageIndex + 1} 页图片文件不存在，无法导出',
        );
      }
      final extension = _normalizedImageExtension(sourcePath);
      final safeExtension =
          extension.isEmpty ? 'png' : extension.replaceAll(RegExp(r'[^a-z0-9]'), '');
      final sceneLabel =
          (page.pageIndex + 1).toString().padLeft(2, '0');
      final fileName = '$prefix$sceneLabel.$safeExtension';
      planned.add(
        _ExportChapterImagePlan(
          pageIndex: page.pageIndex,
          sourcePath: sourcePath,
          fileName: fileName,
          targetPath: path_lib.join(directory.path, fileName),
        ),
      );
    }

    final conflicts = <Map<String, dynamic>>[];
    for (final item in planned) {
      if (await File(item.targetPath).exists()) {
        conflicts.add({
          'pageIndex': item.pageIndex,
          'fileName': item.fileName,
        });
      }
    }

    final hasResolution = overwrite || prefix.isNotEmpty;
    if (conflicts.isNotEmpty && !hasResolution) {
      return {
        'articleId': articleId,
        'cancelled': false,
        'needsConflictResolution': true,
        'outputDirectory': directory.path,
        'readyCount': planned.length,
        'conflicts': conflicts,
        'exportedCount': 0,
        'files': <String>[],
      };
    }

    if (conflicts.isNotEmpty && prefix.isNotEmpty && !overwrite) {
      throw FormatException(
        '自定义前缀后仍有同名文件：${conflicts.map((item) => item['fileName']).join('、')}。请换前缀或选择覆盖保存。',
      );
    }

    final exportedFiles = <String>[];
    for (final item in planned) {
      final target = File(item.targetPath);
      await target.parent.create(recursive: true);
      if (await target.exists()) {
        await target.delete();
      }
      await File(item.sourcePath).copy(item.targetPath);
      exportedFiles.add(item.fileName);
    }

    TomatoLogger.info(
      category: 'pictureBook',
      event: 'chapter_images.exported',
      articleId: articleId,
      data: {
        'exportedCount': exportedFiles.length,
        'overwrite': overwrite,
        'namePrefixLength': prefix.length,
        'conflictCount': conflicts.length,
      },
    );

    return {
      'articleId': articleId,
      'cancelled': false,
      'needsConflictResolution': false,
      'outputDirectory': directory.path,
      'readyCount': planned.length,
      'conflicts': <Map<String, dynamic>>[],
      'exportedCount': exportedFiles.length,
      'files': exportedFiles,
    };
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

  static Future<List<int>> _referencePageOptions({
    required int articleId,
    required int targetPageIndex,
  }) async {
    final pages = await DatabaseService.getPictureBookPages(articleId);
    final options = <int>[];
    for (final page in pages) {
      if (await _hasUsableReferenceImage(page)) {
        options.add(page.pageIndex);
      }
    }
    options.sort();
    return options;
  }

  static Future<String?> _referenceImagePathForPageIndex({
    required int articleId,
    required int pageIndex,
  }) =>
      _referenceImagePathForPageIndexLookup(
        articleId: articleId,
        pageIndex: pageIndex,
      );

  static Future<List<String>> _referenceImagePathsForPageIndexes({
    required int articleId,
    required List<int> pageIndexes,
  }) async {
    final sortedIndexes = pageIndexes.toSet().toList(growable: false)..sort();
    final paths = <String>[];
    for (final pageIndex in sortedIndexes) {
      final imagePath = await _referenceImagePathForPageIndexLookup(
        articleId: articleId,
        pageIndex: pageIndex,
      );
      if (imagePath == null || imagePath.isEmpty) {
        return const [];
      }
      paths.add(imagePath);
    }
    return paths;
  }

  static List<int> _resolveRequestedReferencePageIndexes({
    List<int>? referencePageIndexes,
    int? referencePageIndex,
    int? draftReferencePageIndex,
  }) {
    if (referencePageIndexes != null && referencePageIndexes.isNotEmpty) {
      return referencePageIndexes.toSet().toList(growable: false)..sort();
    }
    if (referencePageIndex != null) {
      return [referencePageIndex];
    }
    if (draftReferencePageIndex != null) {
      return [draftReferencePageIndex];
    }
    return const [];
  }

  static Future<String?> _referenceImagePathForPageIndexLookup({
    required int articleId,
    required int pageIndex,
  }) async {
    final pages = await DatabaseService.getPictureBookPages(articleId);
    for (final page in pages) {
      if (page.pageIndex != pageIndex) {
        continue;
      }
      if (!await _hasUsableReferenceImage(page)) {
        return null;
      }
      return page.imagePath?.trim();
    }
    return null;
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
    final useDisplay = normalizedVariant == 'display';
    final imageUri = useThumbnail
        ? await _thumbnailImageUriForPath(targetPage.imagePath)
        : useDisplay
            ? await _displayImageUriForPath(targetPage.imagePath)
            : await _imageUriForPath(targetPage.imagePath);
    final imagePath = targetPage.imagePath?.trim() ?? '';
    final resolvedVariant =
        useThumbnail ? 'thumbnail' : (useDisplay ? 'display' : 'full');
    return {
      'articleId': articleId,
      'pageIndex': pageIndex,
      'variant': resolvedVariant,
      'imageUri': imageUri,
      'missing': imageUri == null && imagePath.isNotEmpty,
      'errorMessage': imageUri == null && imagePath.isNotEmpty
          ? useThumbnail
              ? '绘本缩略图缓存生成失败，请重试'
              : useDisplay
                  ? '绘本预览图缓存生成失败，请重试'
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

  static String _chapterPlanJsonShape({required bool includeTitle}) {
    final titleField = includeTitle ? '"title":"...",' : '';
    return '{"planKind":"$_chapterPlanCachePurpose",$titleField"chapterDescription":"...","scenes":[{"pageIndex":0,"sentenceStartIndex":0,"sentenceEndIndex":2,"sceneDescription":"..."}],"newCharacters":[{"name":"...","description":"..."}]}';
  }

  /// Fixed chapter-plan prompt rules.
  ///
  /// ## Scene-split tuning (keep general; do not add book-specific patches)
  ///
  /// A picture-book page is one reusable illustration for a listening range.
  /// Split by **illustration situation**, not by literary micro-beats:
  /// 1. place/time
  /// 2. main on-stage cast (focus enter/leave that shifts attention)
  /// 3. central ongoing activity = the focused characters' main task and its
  ///    target, **not** each new visible beat / prop / pose / line
  ///
  /// A consecutive fact/list block about one subject remains one central topic
  /// and can share one montage. This local rule does not require the model to
  /// classify the whole chapter and never overrides real sequential action.
  ///
  /// Open a new scene only when at least one axis changes. Still the same
  /// situation: speech turns, reactions, emotion, asides, repeated same-type
  /// micro-actions, and immediate aftermath cleanup of one discrete accident.
  /// Numbered sentence indexes are coverage anchors only. Do not name specific
  /// settings in these rules.
  ///
  /// 2026-07-20 note: compressing all Scenes rules into 2–3 very long bullets
  /// caused a live regression (11 one-sentence pages + dump remainder into the
  /// last page). Keep Scenes as separate short bullets; only clarify activity≠beat.
  ///
  /// Narrative-conversion rules above the scene block remain tuned separately;
  /// when editing, prefer merging wording for length over dropping constraints.
  static List<String> _chapterPlanPromptRuleLines({
    required bool includeTitle,
    required int maxSentenceIndex,
  }) {
    return [
      '- Output valid JSON only.',
      if (includeTitle) ...[
        '- Also include top-level "title": a short English practice title, 2 to 5 words, title case.',
        '- Keep necessary apostrophes such as Mother\'s. Do not add trailing punctuation to title.',
        '- title must summarize this chapter for a children English practice list, not the whole book.',
      ],
      '- chapterDescription: describe only this chapter arc, settings, atmosphere, key actions, and ending; use bookDescription as context for the visual world, style, color mood, and setting.',
      '- Chapter text is the source prose. Base chapterDescription and sceneDescription on its drawable details, including plot and scene facts carried by dialogue, song lyrics, shouted text, and inner thoughts. Convert all direct dialogue, song lyrics, shouted text, and inner thoughts into third-person visible-scene narrative that preserves the story events, offers, refusals, discoveries, conflicts, and scene facts they convey.',
      '- Prefer visible action, pose, object, spatial relation, and facial or body expression over speech-process wording; avoid chaining ask, asks, explain, explains, tell, tells, reply, replies, say, says, said, argue, or argues as the main verbs that carry the scene; rewrite those beats as what can be seen happening.',
      '- For riddles, songs, shouts, and wordplay: keep only the visible event or result; do not restate the riddle wording, lyric lines, shouted lines, or puzzle phrasing.',
      '- Good example: The Hatter offers wine, but none is on the table.',
      '- Good example: The Cat fades from tail to grin until only the grin floats in the air.',
      '- Bad examples: "Would you like some wine?"; They exchange remarks; Alice asks and the Duchess explains; Why is a raven like a writing-desk?; any speech-bubble wording.',
      '- Keep source-prose drawable details: actions, objects, locations, positions, poses, visible states, character relationships, emotional behavior, and scene atmosphere. Never write quoted speech, verbatim dialogue, song lyrics, shouted lines, inner-thought wording, speech bubbles, or displayed text copied from speech.',
      '- Do not replace converted speech with empty meta words only: exchange, conversation, discuss, debate, or similar vague labels without saying what happens.',
      '- Use Relevant characters as the only source for approved recurring character appearance anchors; do not include character rosters, visual-anchor lists, or phrases like "Visual anchors" in chapterDescription. Do not repeat character appearance, clothing, hair, age, facial features, accessories, or other visual anchors already present in Relevant characters.',
      '- If this chapter introduces an image-relevant character or group not present in Relevant characters, add it to newCharacters with name and stable visible description.',
      '- newCharacters must include only characters or recurring visual groups that affect image consistency; do not include temporary props, places, actions, emotions, or ordinary background elements.',
      // Illustration-situation axes. Keep these as separate short bullets (do not
      // compress into one wall of text — that caused one-sentence-then-dump splits).
      '- Before splitting scenes, convert quoted speech, song text, shouted text, and inner thoughts into narrative story events. Decide boundaries by illustration situation—place/time, main visual focus group, and central ongoing activity—not by sentence boundaries or dialogue turns. Central ongoing activity means the focused characters\' main task and its target, not each new visible beat, prop, pose, or line. If the converted narrative leaves no material change on those three axes between two candidate boundaries, those sentence slots must stay in the same scene.',
      '- Build scenes by walking numbered sentences in order. Numbered indexes are coverage anchors only, not scene boundaries. One illustration may cover many consecutive sentences; put consecutive content from the same illustration situation into the same scene.',
      '- A consecutive run of facts, examples, list items, or general statements about the same subject in the same time/place frame is one central topic block, not one scene per fact. Render its related details together as one drawable montage. Split that fact/list block only when its main subject, purpose, time, or place changes materially. This local fact/list rule must not override sequential movement, object manipulation, discovery, accident, or other causal story action; keep those action ranges under the three illustration-situation axes above. Do not target a fixed number of scenes.',
      '- Start a new scene only when one axis changes materially enough that one shared illustration can no longer represent both sides: place/time changes, the main visual focus shifts whether or not anyone enters or leaves, or the main task is replaced by a different task. Do not start a new scene for conversation turns, questions, answers, riddles, arguments, remarks, jokes, reactions, emotion changes, asides, inner thoughts, or repeated same-type micro-actions while the illustration situation continues.',
      '- Keep the cause, immediate result, and direct recovery of one incident in the same scene unless another axis materially changes. If a candidate boundary differs only by speech turns, reactions, emotion, or immediate aftermath, merge it into the surrounding scene and describe later beats as changing poses, objects, and tension inside that scene.',
      '- Dialogue, song, shout, and inner-thought sentences are coverage anchors inside the surrounding story scene; convert their plot and scene meaning into visible narrative, not quoted text or speech-process summary. Dialogue-heavy ranges in one illustration situation must remain one scene even if they cover many sentence slots.',
      '- Each sceneDescription must use only events and scene facts from its own sentenceStartIndex through sentenceEndIndex range. Preserve who performs each action; do not assign an action to a different character or move an event into a neighboring range.',
      '- Before returning JSON, audit every adjacent scene boundary. If one shared illustration can represent both ranges and none of the three axes changes materially, merge them, then renumber pageIndex from 0.',
      '- Hard validation cap: scenes.length <= $_maxSceneCount. Scene count follows illustration-situation changes; do not invent splits to approach the cap, and do not open many one-sentence scenes then dump the rest into the last scene.',
      '- sceneDescription: describe the visible scene, action, objects, location, composition, emotion, and visible progression within that sentence range, including narrative converted from speech or thought; must not contain dialogue text, quoted speech, lyrics, riddle wording, displayed text copied from speech, speech bubbles, or inner-thought wording from the source prose.',
      '- In sceneDescription, use character names only; do not describe character clothing, hair, age, facial features, accessories, or parenthesized character details. Mention props only as active objects in the scene, not as repeated character appearance details.',
      '- Before returning JSON, remove all recurring character appearance details from chapterDescription and sceneDescription; those details belong only in Relevant characters or newCharacters.',
      '- Empty numbered slots are hidden sentence placeholders. Keep their original indexes, merge them into neighboring visual scenes, and never renumber later sentences.',
      '- scenes must cover every sentence slot from 0 to $maxSentenceIndex, in order, without overlap; scenes[i].pageIndex must equal i.',
    ];
  }

  static List<TextGenerationTurn> _chapterPlanPromptTurns({
    required Article article,
    required String bookDescription,
    required List<BookCharacter> relevantCharacters,
    bool includeTitle = false,
  }) {
    final sentenceSlots = _articleSentenceSlots(article);
    final numberedSentences = _numberedChapterSentencesForPrompt(article);
    final maxSentenceIndex =
        sentenceSlots.isEmpty ? 0 : sentenceSlots.length - 1;
    return [
      const TextGenerationTurn(
        role: 'system',
        content:
            'Create a picture-book narrative scene plan. Convert speech into drawable visible action. Return strict minified JSON only.',
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
          _chapterPlanJsonShape(includeTitle: includeTitle),
          '',
          'Rules:',
          ..._chapterPlanPromptRuleLines(
            includeTitle: includeTitle,
            maxSentenceIndex: maxSentenceIndex,
          ),
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

  /// Picture-book ranges always live in the raw `articles.sentences` index
  /// space. Empty strings are soft-hidden slots; do not filter them before
  /// calculating `sentenceStartIndex` / `sentenceEndIndex`, or later visible
  /// sentences shift onto the wrong picture page.
  static List<String> _articleSentenceSlots(Article article) {
    return article.sentences
        .map((sentence) => sentence.replaceAll(RegExp(r'\s+'), ' ').trim())
        .toList(growable: false);
  }

  static bool _hasVisibleSentenceSlot(List<String> sentenceSlots) {
    return sentenceSlots.any((sentence) => sentence.isNotEmpty);
  }

  static List<String> _visibleSentenceTextsInRange(
    List<String> sentenceSlots,
    int start,
    int end,
  ) {
    if (sentenceSlots.isEmpty) {
      return const [];
    }
    final normalizedStart = start.clamp(0, sentenceSlots.length - 1).toInt();
    final normalizedEnd = end
        .clamp(
          normalizedStart,
          sentenceSlots.length - 1,
        )
        .toInt();
    return sentenceSlots
        .sublist(normalizedStart, normalizedEnd + 1)
        .where((sentence) => sentence.isNotEmpty)
        .toList(growable: false);
  }

  static String _joinVisibleSentenceRange(
    List<String> sentenceSlots,
    int start,
    int end,
  ) {
    return _visibleSentenceTextsInRange(sentenceSlots, start, end).join(' ');
  }

  static String _numberedChapterSentencesForPrompt(Article article) {
    final sentenceSlots = _articleSentenceSlots(article);
    if (!_hasVisibleSentenceSlot(sentenceSlots)) {
      return article.content.replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    return [
      for (var i = 0; i < sentenceSlots.length; i += 1)
        sentenceSlots[i].isEmpty
            ? '$i. [hidden sentence slot]'
            : '$i. ${sentenceSlots[i]}',
    ].join('\n');
  }

  /// Public read of a persisted chapter scene plan from `summary_json`.
  ///
  /// Returns null when missing or invalid. Does not call remote AI.
  static ChapterPicturePlan? readPersistedChapterPlan({
    required String summaryJson,
    required int sentenceCount,
  }) =>
      _chapterPlanFromSummary(summaryJson, sentenceCount: sentenceCount);

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
    bool strictSceneValidation = false,
  }) {
    final planKind = json['planKind']?.toString();
    if (planKind != _chapterPlanCachePurpose) {
      return null;
    }
    final scenes = _pictureBookScenesFromJson(
      json['scenes'],
      sentenceCount: sentenceCount,
      strict: strictSceneValidation,
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
    bool strict = false,
  }) {
    if (raw is! List) {
      return const [];
    }
    if (strict &&
        (raw.isEmpty || raw.length > _maxSceneCount || sentenceCount <= 0)) {
      return const [];
    }
    final scenes = <PictureBookScene>[];
    final maxSentenceIndex = math.max(0, sentenceCount - 1);
    var expectedStart = 0;
    for (var i = 0; i < raw.length; i += 1) {
      final map = _mapValue(raw[i]);
      if (map.isEmpty) {
        if (strict) {
          return const [];
        }
        continue;
      }
      final rawIndex = map['pageIndex'];
      final index = rawIndex is num ? rawIndex.toInt() : i;
      if (strict && (rawIndex is! num || index != i)) {
        return const [];
      }
      if (index < 0 || index >= _maxSceneCount) {
        if (strict) {
          return const [];
        }
        continue;
      }
      final rawStart = map['sentenceStartIndex'];
      final rawEnd = map['sentenceEndIndex'];
      if (strict && (rawStart is! num || rawEnd is! num)) {
        return const [];
      }
      final start = rawStart is num ? rawStart.toInt() : 0;
      final end = rawEnd is num ? rawEnd.toInt() : start;
      if (strict &&
          (start != expectedStart || end < start || end > maxSentenceIndex)) {
        return const [];
      }
      final normalizedStart = start.clamp(0, maxSentenceIndex).toInt();
      final normalizedEnd =
          end.clamp(normalizedStart, maxSentenceIndex).toInt();
      final sceneDescription = _sanitizeForImagePrompt(
        map['sceneDescription']?.toString().trim() ?? '',
      );
      if (sceneDescription.isEmpty) {
        if (strict) {
          return const [];
        }
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
      expectedStart = end + 1;
    }
    if (strict) {
      if (scenes.length != raw.length ||
          scenes.last.sentenceEndIndex != maxSentenceIndex) {
        return const [];
      }
      return scenes;
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

    final sentenceSlots = _articleSentenceSlots(article);
    final maxSentenceIndex = math.max(0, sentenceSlots.length - 1);
    final start = sentenceSlots.isEmpty
        ? math.max(0, page.sentenceStartIndex)
        : page.sentenceStartIndex.clamp(0, maxSentenceIndex).toInt();
    final end = sentenceSlots.isEmpty
        ? math.max(start, page.sentenceEndIndex)
        : page.sentenceEndIndex.clamp(start, maxSentenceIndex).toInt();
    final pageText = page.paragraphText.replaceAll(RegExp(r'\s+'), ' ').trim();
    final text = pageText.isNotEmpty
        ? pageText
        : sentenceSlots.isEmpty
            ? ''
            : _joinVisibleSentenceRange(sentenceSlots, start, end);
    if (text.trim().isEmpty) {
      return null;
    }

    var summary = _pageSceneDescription(page);
    if (summary.isEmpty && sentenceSlots.isNotEmpty) {
      summary = _sceneDescriptionForRange(sentenceSlots, start, end);
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
        'Generate exactly one picture for Image ${segment.pageIndex + 1}. Use the reference images only for visual consistency.',
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

  /// Instruction-edit prompt for ready-page local fixes (Seedream/Wanx image + edit).
  static String _composeSinglePageEditPrompt(String editInstruction) {
    final change = _sanitizeForImagePrompt(editInstruction.trim());
    return [
      'Edit the reference image(s). Keep everything else unchanged unless specified.',
      'Change: $change',
    ].join('\n');
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
    final sentenceSlots = _articleSentenceSlots(article);
    if (!_hasVisibleSentenceSlot(sentenceSlots)) {
      return const [];
    }

    return plan.scenes.map((scene) {
      final start =
          scene.sentenceStartIndex.clamp(0, sentenceSlots.length - 1).toInt();
      final end =
          scene.sentenceEndIndex.clamp(start, sentenceSlots.length - 1).toInt();
      final text = _joinVisibleSentenceRange(sentenceSlots, start, end);
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
    final sentenceSlots = _articleSentenceSlots(article);
    if (!_hasVisibleSentenceSlot(sentenceSlots)) {
      return const [];
    }
    final ranges = _draftSceneRanges(article.content, sentenceSlots);
    return [
      for (var index = 0; index < ranges.length; index += 1)
        _PicturePageSegment(
          pageIndex: index,
          pageCount: ranges.length,
          sentenceStartIndex: ranges[index].$1,
          sentenceEndIndex: ranges[index].$2,
          text: _normalizeFullChapterStoryForPrompt(
            _joinVisibleSentenceRange(
              sentenceSlots,
              ranges[index].$1,
              ranges[index].$2,
            ),
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
    final slice = _visibleSentenceTextsInRange(sentences, start, end);
    if (slice.isEmpty) {
      return '';
    }
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
    final sentenceSlots = _articleSentenceSlots(article);
    if (!_hasVisibleSentenceSlot(sentenceSlots)) {
      return const [];
    }
    final ranges = _limitSceneRanges(
      _paragraphSentenceRanges(article.content, sentenceSlots),
      sentenceSlots.length,
    );
    return [
      for (var index = 0; index < ranges.length; index += 1)
        {
          'pageIndex': index,
          'sentenceStartIndex': ranges[index].$1,
          'sentenceEndIndex': ranges[index].$2,
          'summary': _sceneDescriptionForRange(
            sentenceSlots,
            ranges[index].$1,
            ranges[index].$2,
          ),
          'text': _joinVisibleSentenceRange(
            sentenceSlots,
            ranges[index].$1,
            ranges[index].$2,
          ),
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
    final thumbnailPath = await _resizedPathForImage(
      rawPath,
      cache: _thumbnailPathCache,
      cacheDirectoryName: 'picture_book_thumbnails',
      maxWidth: _creationThumbnailMaxWidth,
      maxHeight: _creationThumbnailMaxHeight,
      label: 'thumbnail',
    );
    if (thumbnailPath == null || thumbnailPath.trim().isEmpty) {
      return null;
    }
    return _imageUriForPath(thumbnailPath);
  }

  static Future<String?> _displayImageUriForPath(String? rawPath) async {
    final displayPath = await _resizedPathForImage(
      rawPath,
      cache: _displayPathCache,
      cacheDirectoryName: 'picture_book_display',
      maxWidth: _creationDisplayMaxWidth,
      maxHeight: _creationDisplayMaxHeight,
      label: 'display',
    );
    if (displayPath == null || displayPath.trim().isEmpty) {
      return null;
    }
    return _imageUriForPath(displayPath);
  }

  static Future<String?> _resizedPathForImage(
    String? rawPath, {
    required Map<String, String> cache,
    required String cacheDirectoryName,
    required int maxWidth,
    required int maxHeight,
    required String label,
  }) async {
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
      'maxWidth': maxWidth,
      'maxHeight': maxHeight,
    });
    final cachedPath = cache[cacheIdentity];
    if (cachedPath != null && await File(cachedPath).exists()) {
      return cachedPath;
    }

    final cacheKey = await ApiCacheService.hashUtf8(cacheIdentity);
    final directory = await ApiCacheService.cacheDirectory(cacheDirectoryName);
    final target = File(path_lib.join(directory.path, '$cacheKey.png'));
    if (await target.exists() && await target.length() > 0) {
      cache[cacheIdentity] = target.path;
      return target.path;
    }

    try {
      final bytes = await source.readAsBytes();
      final resized = await _resizeImageToPng(
        bytes,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      );
      if (resized.isEmpty) {
        return null;
      }
      await target.writeAsBytes(resized, flush: true);
      cache[cacheIdentity] = target.path;
      return target.path;
    } catch (error, stackTrace) {
      debugPrint('PictureBook $label generation failed: $error');
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'picture_book_service',
          context: ErrorDescription('generating picture-book $label'),
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

  /// Prepare import bytes: keep as-is when already full size; otherwise
  /// cover-crop with bilinear ([ui.FilterQuality.medium]) to full PNG.
  static Future<_PreparedImportedImage> _prepareImportedImageBytes(
    Uint8List bytes, {
    required String sourceExtension,
  }) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      if (width <= 0 || height <= 0) {
        return _PreparedImportedImage(
          bytes: Uint8List(0),
          resized: false,
          extension: 'png',
          contentType: 'image/png',
        );
      }
      if (width == _importedFullWidth && height == _importedFullHeight) {
        final extension = sourceExtension.isEmpty ? 'png' : sourceExtension;
        return _PreparedImportedImage(
          bytes: bytes,
          resized: false,
          extension: extension,
          contentType: _contentTypeForImageExtension(extension),
        );
      }
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }

    final resizedBytes = await _normalizeImportedImageToFullPng(bytes);
    return _PreparedImportedImage(
      bytes: resizedBytes,
      resized: true,
      extension: 'png',
      contentType: 'image/png',
    );
  }

  /// Cover-crop [bytes] into a native [_importedFullWidth]×[_importedFullHeight]
  /// PNG with bilinear filtering so imported pages match Seedream full size.
  static Future<Uint8List> _normalizeImportedImageToFullPng(
    Uint8List bytes,
  ) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.FrameInfo? frame;
    ui.Image? sourceImage;
    ui.Image? outputImage;
    ui.Picture? picture;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      if (width <= 0 || height <= 0) {
        return Uint8List(0);
      }
      codec = await descriptor.instantiateCodec();
      frame = await codec.getNextFrame();
      sourceImage = frame.image;

      final scale = math.max(
        _importedFullWidth / width,
        _importedFullHeight / height,
      );
      final scaledWidth = width * scale;
      final scaledHeight = height * scale;
      final dx = (_importedFullWidth - scaledWidth) / 2.0;
      final dy = (_importedFullHeight - scaledHeight) / 2.0;

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(
        recorder,
        ui.Rect.fromLTWH(
          0,
          0,
          _importedFullWidth.toDouble(),
          _importedFullHeight.toDouble(),
        ),
      );
      canvas.drawImageRect(
        sourceImage,
        ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        ui.Rect.fromLTWH(dx, dy, scaledWidth, scaledHeight),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      picture = recorder.endRecording();
      outputImage = await picture.toImage(
        _importedFullWidth,
        _importedFullHeight,
      );
      final data =
          await outputImage.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List() ?? Uint8List(0);
    } finally {
      outputImage?.dispose();
      picture?.dispose();
      sourceImage?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  static String _normalizedImageExtension(String filePath) {
    final extension = path_lib.extension(filePath).toLowerCase();
    if (extension.startsWith('.')) {
      return extension.substring(1);
    }
    return extension;
  }

  static String _contentTypeForImageExtension(String extension) {
    return switch (extension.toLowerCase()) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      _ => 'image/png',
    };
  }

  static String _imageContentType(String imagePath) {
    return _contentTypeForImageExtension(_normalizedImageExtension(imagePath));
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

  static List<BookCharacter> relevantCharactersForArticle(
    Article article,
    List<BookCharacter> characters,
  ) =>
      _relevantBookCharactersForArticle(article, characters);

  /// Sole production matcher for prompt-review "Relevant characters".
  /// Web UI must call this via bridge instead of re-filtering locally.
  static Map<String, dynamic> resolveRelevantCharacters({
    required String reviewId,
    required List<BookCharacter> bookCharacters,
  }) {
    final draft = _promptReviewDrafts[reviewId];
    if (draft == null) {
      throw const FormatException('绘本提示词审核已过期，请重新打开审核弹窗。');
    }
    final sanitizedBookCharacters = _sanitizeBookCharacters(bookCharacters);
    final relevantCharacters = _relevantBookCharactersForArticle(
      draft.article,
      sanitizedBookCharacters,
    );
    return {
      'reviewId': reviewId,
      'relevantCharacters': relevantCharacters
          .map((character) => character.toJson())
          .toList(growable: false),
    };
  }

  static List<BookCharacter> _relevantBookCharactersForArticle(
    Article article,
    List<BookCharacter> characters,
  ) {
    // Keep original casing: person-name hits must appear with an initial
    // capital (as stored on the roster), so common nouns like "bill" do not
    // match character "Bill".
    final haystack = [
      article.title,
      article.content,
      ...article.sentences,
    ].join('\n');
    return [
      for (final character in _sanitizeBookCharacters(characters))
        if (_articleTextMentionsCharacterName(haystack, character.name))
          character,
    ];
  }

  /// True when [name] appears in [text] as a whole token with the same
  /// capitalization. Only initial-capital roster names count as person names.
  static bool _articleTextMentionsCharacterName(String text, String name) {
    final trimmed = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (trimmed.length < 2) {
      return false;
    }
    final first = trimmed[0];
    if (!RegExp(r'[A-Z]').hasMatch(first)) {
      return false;
    }
    final pattern = RegExp(
      '(?<![A-Za-z0-9])${RegExp.escape(trimmed)}(?![A-Za-z0-9])',
    );
    return pattern.hasMatch(text);
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

class _PreparedImportedImage {
  const _PreparedImportedImage({
    required this.bytes,
    required this.resized,
    required this.extension,
    required this.contentType,
  });

  final Uint8List bytes;
  final bool resized;
  final String extension;
  final String contentType;
}

class _ExportChapterImagePlan {
  const _ExportChapterImagePlan({
    required this.pageIndex,
    required this.sourcePath,
    required this.fileName,
    required this.targetPath,
  });

  final int pageIndex;
  final String sourcePath;
  final String fileName;
  final String targetPath;
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
    this.referenceOptions = const [],
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
  final List<int> referenceOptions;

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
        referenceOptions: referenceOptions,
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
        if (referencePageIndex != null)
          'referencePageIndexes': [referencePageIndex],
        if (referenceOptions.isNotEmpty) 'referenceOptions': referenceOptions,
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
