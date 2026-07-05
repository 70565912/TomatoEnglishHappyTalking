import { FormEvent, ReactNode, useEffect, useId, useMemo, useRef, useState } from 'react';
import type { TextareaHTMLAttributes } from 'react';
import { createPortal } from 'react-dom';
import { onNativeEvent, sendNative } from './bridge';
import {
  firstVisibleSlotIndex,
  isHiddenListeningItem,
  isHiddenListeningSentence,
  resolveListeningItemBySlotIndex,
  visibleItemPosition,
  visibleListeningItems,
  visiblePositionForSlotIndex,
  visibleSentenceCountFromItems,
} from './listeningSentenceVisibility';
import { splitSentences } from './sentenceSplitter';
import {
  pictureBookGroupSubmitOverlay,
  pictureBookPromptRefreshOverlay,
  pictureBookSinglePageSubmitOverlay,
  type BlockingOverlayConfig,
  type PictureBookPromptRefreshTarget,
} from './pictureBookBlockingOverlay';
import type {
  Article,
  ArticleFullTextPayload,
  BookTransferPayload,
  BookCharacter,
  ChatState,
  DiagnosticLogExportPayload,
  FollowState,
  ListeningAudioMaterialProgress,
  ListeningAudioMaterialStatus,
  ListeningItem,
  ListeningFullscreenReadyPayload,
  ListeningOpenPayload,
  ListeningPausePayload,
  ListeningPlaybackPayload,
  ListeningRecordingProgressPayload,
  ListeningRecordingReadyPayload,
  ListeningRecordingResultPayload,
  ListeningResumePayload,
  ListeningSentenceUpdatePayload,
  ListeningSongAudioExportPayload,
  ListeningSongPositionPayload,
  ListeningSongStatePayload,
  ListeningTranslationsPayload,
  PictureBookPage,
  PictureBookPageImagePayload,
  PictureBookPromptReview,
  PictureBookPromptReviewScene,
  PictureBookState,
  PreloadState,
  VoicePreviewPayload,
  WordLookupPayload,
  WordPlaybackPayload,
  SettingsState,
  RecordingSettings,
  RecordingVideoLibraryPayload,
  RecordingVideoVersion,
  SongSource,
  AiProvider,
  StorySeries,
} from './types';
import './styles.css';

const sampleText = 'Tom is on a space trip. He sees a bright snack box. It looks like a snack box! Tom opens it slowly.';
const ARTICLE_CONTENT_MAX_CHARS = 8000;
const PRELOAD_COMPLETE_VISIBLE_MS = 3000;
const PRELOAD_IMAGE_DECODE_TIMEOUT_MS = 8000;
const RECENT_SERIES_STORAGE_KEY = 'tomato.recentSeriesKey.v1';
const CHAPTER_ORDER_STORAGE_KEY = 'tomato.chapterOrder.v1';

type ChapterOrder = 'asc' | 'desc';

type SelectOption = {
  value: string;
  label: string;
};

function normalizeChapterOrder(value: unknown): ChapterOrder {
  return value === 'desc' ? 'desc' : 'asc';
}

function readStoredChapterOrder(): ChapterOrder {
  try {
    return normalizeChapterOrder(window.localStorage.getItem(CHAPTER_ORDER_STORAGE_KEY));
  } catch {
    return 'asc';
  }
}

function saveStoredChapterOrder(order: ChapterOrder) {
  try {
    window.localStorage.setItem(CHAPTER_ORDER_STORAGE_KEY, order);
  } catch {
    // localStorage can be unavailable in embedded test shells.
  }
}

const ALIYUN_TEXT_MODEL_OPTIONS: SelectOption[] = [
  { value: 'qwen3.7-max', label: 'qwen3.7-max · 最高效果' },
  { value: 'qwen3.7-plus', label: 'qwen3.7-plus · 均衡效果' },
  { value: 'qwen3.6-plus', label: 'qwen3.6-plus · 兼容示例' },
  { value: 'qwen3.6-flash', label: 'qwen3.6-flash · 快速低成本' },
];

const ALIYUN_IMAGE_MODEL_OPTIONS: SelectOption[] = [
  { value: 'wan2.7-image-pro', label: 'wan2.7-image-pro · 万相组图' },
  { value: 'wan2.7-image', label: 'wan2.7-image · 万相组图' },
];

const ALIYUN_IMAGE_SIZE_OPTIONS: SelectOption[] = [
  { value: '2K', label: '2K · 16:9 绘本默认' },
  { value: '1K', label: '1K · 16:9 更快更省' },
];

const ALIYUN_TTS_MODEL_OPTIONS: SelectOption[] = [
  { value: 'cosyvoice-v3-flash', label: 'cosyvoice-v3-flash · 默认低延迟' },
  { value: 'cosyvoice-v3.5-plus', label: 'cosyvoice-v3.5-plus · 更高效果' },
];

const ALIYUN_ASR_MODEL_OPTIONS: SelectOption[] = [
  { value: 'qwen3-asr-flash', label: 'qwen3-asr-flash · 当前默认' },
  { value: 'fun-asr', label: 'fun-asr · 专业文件识别' },
  { value: 'qwen3.5-omni-plus', label: 'qwen3.5-omni-plus · 大模型识别' },
];

const ALIYUN_REALTIME_ASR_MODEL_OPTIONS: SelectOption[] = [
  { value: 'qwen3-asr-realtime', label: 'qwen3-asr-realtime · 当前默认' },
  { value: 'fun-asr-realtime', label: 'fun-asr-realtime · 实时专业识别' },
  { value: 'qwen3.5-omni-plus-realtime', label: 'qwen3.5-omni-plus-realtime · 实时大模型识别' },
];

const VOLC_TEXT_MODEL_OPTIONS: SelectOption[] = [
  { value: 'doubao-seed-2-0-pro-250528', label: 'doubao-seed-2-0-pro-250528 · 更高效果' },
  { value: 'doubao-seed-2-0-lite-260215', label: 'doubao-seed-2-0-lite-260215 · 默认低成本' },
];

const VOLC_IMAGE_MODEL_OPTIONS: SelectOption[] = [
  { value: 'doubao-seedream-5-0-260128', label: 'doubao-seedream-5-0-260128 · Seedream 组图' },
];

const VOLC_TTS_RESOURCE_OPTIONS: SelectOption[] = [
  { value: 'seed-tts-2.0', label: 'seed-tts-2.0 · Doubao TTS 2.0' },
];

const asset = (name: string) => `assets/ui/${name}`;

const fallbackCards = [
  'card-space-snacks.png',
  'card-daisy-diver.png',
  'card-rocket-race.png',
];

type StateSetter<T> = (value: T | ((current: T) => T)) => void;
type PictureBookStateSetter = StateSetter<PictureBookState | null>;

type PictureBookRetryGate = {
  begin: (articleId: number, pageIndex: number) => boolean;
  finish: (articleId: number, pageIndex: number) => void;
  isRetrying: (articleId: number, pageIndex: number) => boolean;
};

type PreloadStateMap = Record<string, PreloadState>;

function preloadKey(mode: string, articleId: number, scope?: string) {
  const normalizedScope = scope ?? (mode === 'listening' || mode === 'follow' ? 'english' : 'default');
  return `${mode}:${normalizedScope}:${articleId}`;
}

function isPreloadSettled(state?: PreloadState) {
  if (!state) return false;
  return state.status === 'complete' || state.status === 'partial' || state.status === 'error';
}

function preloadRunOrder(runId?: string): number {
  const match = runId?.match(/_(\d+)$/);
  return match ? Number(match[1]) : 0;
}

function loadingPictureBookState(articleId: number): PictureBookState {
  return {
    articleId,
    enabled: false,
    status: 'loading',
    pages: [],
  };
}

function formatCountdown(totalSeconds: number): string {
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}:${seconds.toString().padStart(2, '0')}`;
}

function AiBlockingOverlay({
  title,
  detail,
  timeoutSeconds,
}: BlockingOverlayConfig) {
  const [elapsedSeconds, setElapsedSeconds] = useState(0);

  useEffect(() => {
    const startedAt = Date.now();
    setElapsedSeconds(0);
    const timer = window.setInterval(() => {
      setElapsedSeconds(Math.floor((Date.now() - startedAt) / 1000));
    }, 1000);
    return () => window.clearInterval(timer);
  }, [detail, timeoutSeconds, title]);

  const remainingSeconds = Math.max(0, timeoutSeconds - elapsedSeconds);
  const timedOut = remainingSeconds === 0;

  return createPortal(
    <div className="ai-blocking-backdrop" role="presentation">
      <section className="ai-blocking-panel" role="status" aria-live="polite">
        <div className="ai-blocking-spinner" aria-hidden="true">
          <Icon name="refresh" />
        </div>
        <div>
          <b>{title}</b>
          <p>{detail}</p>
          <span>{timedOut ? '已超过预计等待时间，仍在等待服务返回' : `预计超时倒计时 ${formatCountdown(remainingSeconds)}`}</span>
        </div>
      </section>
    </div>,
    document.body,
  );
}

function AutoResizeTextarea({
  className,
  onInput,
  rows = 3,
  value,
  ...props
}: TextareaHTMLAttributes<HTMLTextAreaElement>) {
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);

  const resize = () => {
    const textarea = textareaRef.current;
    if (!textarea) return;
    textarea.style.height = 'auto';
    textarea.style.height = `${textarea.scrollHeight}px`;
  };

  useEffect(resize, [value]);

  return (
    <textarea
      {...props}
      ref={textareaRef}
      className={['auto-resize-textarea', className].filter(Boolean).join(' ')}
      rows={rows}
      value={value}
      onInput={(event) => {
        resize();
        onInput?.(event);
      }}
    />
  );
}

function mergePictureBookState(
  current: PictureBookState | null,
  next: PictureBookState | null,
): PictureBookState | null {
  if (!next) {
    return current;
  }
  if (!current || current.articleId !== next.articleId) {
    return normalizePictureBookState(next);
  }

  const currentPages = Array.isArray(current.pages) ? current.pages : [];
  const nextPages = Array.isArray(next.pages) ? next.pages : [];
  const imageByPage = new Map(
    currentPages
      .filter(
        (page) =>
          page.status === 'ready' &&
          page.imageUri?.trim() &&
          page.imagePath?.trim(),
      )
      .map((page) => [
        page.pageIndex,
        {
          imagePath: page.imagePath?.trim() ?? '',
          imageUri: page.imageUri?.trim() ?? '',
          imageVariant: normalizedPictureBookImageVariant(page.imageVariant),
        },
      ]),
  );
  let changed = false;
  const pages = nextPages.map((page) => {
    if (page.imageUri?.trim()) {
      return page;
    }
    const imagePath = page.imagePath?.trim() ?? '';
    if (page.status !== 'ready' || !imagePath) {
      return page;
    }
    const image = imageByPage.get(page.pageIndex);
    if (!image?.imageUri || image.imagePath !== imagePath) {
      return page;
    }
    changed = true;
    return {
      ...page,
      imageUri: image.imageUri,
      imageVariant: image.imageVariant,
    };
  });

  return normalizePictureBookState(changed ? { ...next, pages } : next);
}

function mergePictureBookPageImage(
  current: PictureBookState | null,
  payload: PictureBookPageImagePayload,
): PictureBookState | null {
  const imageUri = payload.imageUri?.trim() ?? '';
  const imageVariant = normalizedPictureBookImageVariant(payload.variant);
  if (!current || current.articleId !== payload.articleId) {
    return current;
  }

  let changed = false;
  const currentPages = Array.isArray(current.pages) ? current.pages : [];
  const pages = currentPages.map((page) => {
    if (page.pageIndex !== payload.pageIndex) {
      return page;
    }

    if (imageUri) {
      const incomingRank = PICTURE_BOOK_IMAGE_VARIANT_RANK[imageVariant];
      const currentRank = PICTURE_BOOK_IMAGE_VARIANT_RANK[normalizedPictureBookImageVariant(page.imageVariant)];
      if (incomingRank < currentRank && page.imageUri?.trim()) {
        return page;
      }
      if (
        page.imageUri === imageUri &&
        normalizedPictureBookImageVariant(page.imageVariant) === imageVariant
      ) {
        return page;
      }
      changed = true;
      return {
        ...page,
        imageUri,
        imageVariant,
      };
    }

    if (!payload.missing) {
      return page;
    }

    const errorMessage =
      payload.errorMessage?.trim() || page.errorMessage?.trim() || '绘本缓存文件丢失，请重试生成';
    if (page.status === 'error' && (page.errorMessage?.trim() ?? '') === errorMessage) {
      return page;
    }
    changed = true;
    return {
      ...page,
      status: 'error',
      errorMessage,
    };
  });

  return normalizePictureBookState(changed ? { ...current, pages } : current);
}

type PictureBookImageVariant = 'thumbnail' | 'display' | 'full';

// Rank order matters: never let a lower-resolution fetch (e.g. thumbnail) overwrite
// an already-loaded higher-resolution image (display/full) for the same page.
const PICTURE_BOOK_IMAGE_VARIANT_RANK: Record<PictureBookImageVariant, number> = {
  thumbnail: 0,
  display: 1,
  full: 2,
};

function normalizedPictureBookImageVariant(
  variant?: PictureBookPage['imageVariant'] | PictureBookPageImagePayload['variant'] | null,
): PictureBookImageVariant {
  if (variant === 'thumbnail') return 'thumbnail';
  if (variant === 'display') return 'display';
  return 'full';
}

function pageHasPictureBookImageVariant(
  page: PictureBookPage | null | undefined,
  requiredVariant: PictureBookImageVariant,
): boolean {
  if (!page?.imageUri?.trim()) {
    return false;
  }
  if (requiredVariant === 'thumbnail') {
    return true;
  }
  const currentRank = PICTURE_BOOK_IMAGE_VARIANT_RANK[normalizedPictureBookImageVariant(page.imageVariant)];
  return currentRank >= PICTURE_BOOK_IMAGE_VARIANT_RANK[requiredVariant];
}

function normalizePictureBookState(state: PictureBookState): PictureBookState {
  const pages = Array.isArray(state.pages) ? state.pages : [];
  const normalized = pages === state.pages ? state : { ...state, pages };
  const status = inferPictureBookStatus(normalized);
  return status === normalized.status ? normalized : { ...normalized, status };
}

function inferPictureBookStatus(state: PictureBookState): PictureBookState['status'] {
  if (state.pages.length === 0) {
    return state.status;
  }
  const statuses = state.pages.map((page) => page.status);
  if (statuses.some((status) => status === 'queued' || status === 'prompting' || status === 'generating')) {
    return 'generating';
  }
  if (statuses.every((status) => status === 'ready')) {
    return 'ready';
  }
  if (statuses.every((status) => status === 'skipped')) {
    return 'skipped';
  }
  if (statuses.some((status) => status === 'ready')) {
    return 'partial';
  }
  if (statuses.some((status) => status === 'error')) {
    return 'error';
  }
  return state.status;
}

function usePictureBookRetryGate(): PictureBookRetryGate {
  const retryingKeysRef = useRef<Set<string>>(new Set());
  const [retryingKeys, setRetryingKeys] = useState<string[]>([]);

  const syncState = () => {
    setRetryingKeys(Array.from(retryingKeysRef.current));
  };

  const keyFor = (articleId: number, pageIndex: number) => `${articleId}:${pageIndex}`;

  const begin = (articleId: number, pageIndex: number) => {
    const key = keyFor(articleId, pageIndex);
    if (retryingKeysRef.current.has(key)) {
      return false;
    }
    retryingKeysRef.current.add(key);
    syncState();
    return true;
  };

  const finish = (articleId: number, pageIndex: number) => {
    const key = keyFor(articleId, pageIndex);
    if (!retryingKeysRef.current.delete(key)) {
      return;
    }
    syncState();
  };

  const isRetrying = (articleId: number, pageIndex: number) =>
    retryingKeys.includes(keyFor(articleId, pageIndex));

  return {
    begin,
    finish,
    isRetrying,
  };
}

type PlayerMode = 'listening' | 'song';

function App() {
  const [route, setRoute] = useHashRoute();
  const [articles, setArticles] = useState<Article[]>([]);
  const [followState, setFollowState] = useState<FollowState | null>(null);
  const [pictureBookState, setPictureBookState] = useState<PictureBookState | null>(null);
  const [chatState, setChatState] = useState<ChatState | null>(null);
  const [settings, setSettings] = useState<SettingsState | null>(null);
  const [recordingSettings, setRecordingSettings] = useState<RecordingSettings | null>(null);
  const applyRecordingSettings = (payload: RecordingSettings) => {
    setRecordingSettings(normalizeRecordingSettings(payload));
  };
  const [chapterOrder, setChapterOrder] = useState<ChapterOrder>(readStoredChapterOrder);
  const [series, setSeries] = useState<StorySeries[]>([]);
  const [preloadStates, setPreloadStates] = useState<PreloadStateMap>({});
  const [recentSeriesKey, setRecentSeriesKey] = useState<string | null>(() => {
    try {
      return window.localStorage.getItem(RECENT_SERIES_STORAGE_KEY);
    } catch {
      return null;
    }
  });
  const [notice, setNotice] = useState<string | null>(null);
  const [appBlockingOverlay, setAppBlockingOverlay] = useState<BlockingOverlayConfig | null>(null);
  const [picturePromptReview, setPicturePromptReview] = useState<PictureBookPromptReview | null>(null);
  const [picturePromptReviewLoadingArticleId, setPicturePromptReviewLoadingArticleId] = useState<number | null>(null);
  const pictureBookRetryGate = usePictureBookRetryGate();

  const rememberSeriesKey = (key: string | null) => {
    setRecentSeriesKey(key);
    try {
      if (key) {
        window.localStorage.setItem(RECENT_SERIES_STORAGE_KEY, key);
      } else {
        window.localStorage.removeItem(RECENT_SERIES_STORAGE_KEY);
      }
    } catch {
      // localStorage can be unavailable in embedded test shells.
    }
  };

  const rememberChapterOrder = (order: ChapterOrder) => {
    const normalized = normalizeChapterOrder(order);
    setChapterOrder(normalized);
    saveStoredChapterOrder(normalized);
  };

  const navigate = (path: string) => {
    if (appBlockingOverlay) return;
    setNotice(null);
    setRoute(path);
    void sendNative('app.navigate', { path });
  };

  const openPictureBookPromptReview = async (articleId: number, regenerate = false) => {
    setPicturePromptReviewLoadingArticleId(articleId);
    setNotice(regenerate ? '正在读取本地绘本提示词草稿' : '章节已保存，正在读取本地绘本提示词草稿');
    try {
      const review = await sendNative<PictureBookPromptReview>('pictureBook.promptReview', {
        articleId,
        regenerate,
      });
      if (!review?.reviewId || !Array.isArray(review.scenes)) {
        throw new Error('绘本提示词准备失败');
      }
      setPicturePromptReview(review);
      setNotice(null);
    } catch (error) {
      setNotice(error instanceof Error ? error.message : '绘本提示词准备失败');
    } finally {
      setPicturePromptReviewLoadingArticleId(null);
    }
  };

  const openPictureBookPagePromptReview = async (articleId: number, pageIndex: number) => {
    setPicturePromptReviewLoadingArticleId(articleId);
    setNotice(`正在准备第 ${pageIndex + 1} 页绘本提示词`);
    try {
      const review = await sendNative<PictureBookPromptReview>('pictureBook.pagePromptReview', {
        articleId,
        pageIndex,
      });
      if (!review?.reviewId || !Array.isArray(review.scenes)) {
        throw new Error('绘本提示词准备失败');
      }
      setPicturePromptReview(review);
      setNotice(null);
    } catch (error) {
      setNotice(error instanceof Error ? error.message : '绘本提示词准备失败');
    } finally {
      setPicturePromptReviewLoadingArticleId(null);
    }
  };

  useEffect(() => {
    let isMounted = true;
    const offArticles = onNativeEvent<{ articles: Article[]; series?: StorySeries[] }>(
      'article.state',
      (payload) => {
        if (isMounted) {
          setArticles(payload.articles);
          if (payload.series) setSeries(payload.series);
        }
      },
    );
    const offFollow = onNativeEvent<FollowState>('follow.state', (payload) => {
      if (isMounted) setFollowState(payload);
    });
    const offPictureBook = onNativeEvent<PictureBookState>('pictureBook.state', (payload) => {
      if (isMounted) {
        setPictureBookState((current) => mergePictureBookState(current, payload));
      }
    });
    const offChat = onNativeEvent<ChatState>('chat.state', (payload) => {
      if (isMounted) setChatState(payload);
    });
    const offSettings = onNativeEvent<SettingsState>('settings.state', (payload) => {
      if (isMounted) setSettings(payload);
    });
    const offRecordingSettings = onNativeEvent<RecordingSettings>('recording.settings.state', (payload) => {
      if (isMounted) applyRecordingSettings(payload);
    });
    const offPreload = onNativeEvent<PreloadState>('preload.state', (payload) => {
      if (!isMounted) return;
      setPreloadStates((current) => {
        const key = preloadKey(payload.mode, payload.articleId, payload.scope);
        const existing = current[key];
        if (
          existing?.runId &&
          payload.runId &&
          existing.runId !== payload.runId &&
          preloadRunOrder(payload.runId) < preloadRunOrder(existing.runId)
        ) {
          return current;
        }
        return {
          ...current,
          [key]: payload,
        };
      });
    });

    sendNative<{ articles: Article[]; series?: StorySeries[] }>('app.ready')
      .then((payload) => {
        if (isMounted) {
          setArticles(payload.articles);
          if (payload.series) setSeries(payload.series);
        }
      })
      .catch((error) => {
        if (isMounted) setNotice(error.message);
      });
    sendNative<RecordingSettings>('recording.settings.load')
      .then((payload) => {
        if (isMounted) applyRecordingSettings(payload);
      })
      .catch(() => undefined);
    sendNative<SettingsState>('settings.load')
      .then((payload) => {
        if (isMounted) setSettings(payload);
      })
      .catch(() => undefined);

    return () => {
      isMounted = false;
      offArticles();
      offFollow();
      offPictureBook();
      offChat();
      offSettings();
      offRecordingSettings();
      offPreload();
    };
  }, []);

  useEffect(() => {
    if (!notice) return undefined;
    const timer = window.setTimeout(() => setNotice(null), 2800);
    return () => window.clearTimeout(timer);
  }, [notice]);

  const parsedRoute = parseRoute(route);
  const latestArticle = articles[0];
  const updateSeries = async (
    seriesId: number,
    title: string,
    description: string,
    characters: BookCharacter[],
  ) => {
    const payload = await sendNative<{ articles: Article[]; series?: StorySeries[] }>(
      'series.update',
      { seriesId, title, description, characters: normalizeBookCharacters(characters) },
    );
    setArticles(payload.articles);
    if (payload.series) setSeries(payload.series);
    rememberSeriesKey(`series:${seriesId}`);
    setNotice('书籍信息已更新');
  };

  return (
    <div className="app-shell">
      <div className="soft-grid" aria-hidden="true" />

      <aside className="side-rail">
        <button className="brand-card" onClick={() => navigate('/')}>
          <span className="brand-mark" aria-hidden="true">T</span>
          <span className="brand-copy">
            <b>
              <span>Tomato</span>
              {' '}
              <span>English</span>
              {' '}
              <span>Happy Talking</span>
            </b>
          </span>
        </button>
        <NavButton label="书库" icon="home" active={parsedRoute.kind === 'home' || parsedRoute.kind === 'book'} onClick={() => navigate('/')} />
        <NavButton
          label="新增章节"
          icon="task"
          active={route === '/article/new'}
          onClick={() => navigate('/article/new')}
        />
        <NavButton
          label="创作中心"
          icon="recordVideo"
          active={parsedRoute.kind === 'creation'}
          onClick={() => navigate('/creation')}
        />
        <NavButton
          label="练习中心"
          icon="mic"
          active={parsedRoute.kind === 'practice'}
          onClick={() => navigate('/practice')}
        />
        <NavButton
          label="设置"
          icon="gear"
          active={route === '/settings'}
          onClick={() => navigate('/settings')}
        />
        <UserBadge />
      </aside>

      <main className="main-stage">
        {notice && (
          <div className="toast" role="status">
            {notice}
            <button onClick={() => setNotice(null)}>知道了</button>
          </div>
        )}

        {parsedRoute.kind === 'home' && (
          <HomePage
            articles={articles}
            series={series}
            latestArticle={latestArticle}
            recentBookKey={recentSeriesKey}
            chapterOrder={chapterOrder}
            onRecentBookKeyChange={rememberSeriesKey}
            onChapterOrderChange={rememberChapterOrder}
            onNavigate={navigate}
            onOpenBook={(book) => {
              if (book.seriesId != null) {
                navigate(`/books/${book.seriesId}`);
                return;
              }
              rememberSeriesKey(book.key);
            }}
            onUpdateSeries={updateSeries}
          />
        )}

        {parsedRoute.kind === 'article' && (
          <ArticlePage
            series={series}
            onSeriesUpdated={setSeries}
            onCancel={() => navigate('/')}
            onSaved={(payload) => {
              setArticles(payload.articles);
              if (payload.series) setSeries(payload.series);
              rememberSeriesKey(bookKeyForArticle(payload.article));
              navigate(payload.article.seriesId != null ? `/books/${payload.article.seriesId}` : '/');
              setNotice('章节已加入书库');
              if (payload.article.pictureBookEnabled !== false) {
                void openPictureBookPromptReview(payload.article.id, false);
              }
            }}
          />
        )}

        {parsedRoute.kind === 'book' && (
          <BookDetailPage
            seriesId={parsedRoute.seriesId}
            articles={articles}
            series={series}
            chapterOrder={chapterOrder}
            onNavigate={navigate}
            onRecentBookKeyChange={rememberSeriesKey}
            onChapterOrderChange={rememberChapterOrder}
            onUpdateSeries={updateSeries}
          />
        )}

        {parsedRoute.kind === 'bookPlayer' && (
          <BookPlayerPage
            seriesId={parsedRoute.seriesId}
            startArticleId={parsedRoute.articleId}
            mode={parsedRoute.mode}
            articles={articles}
            series={series}
            chapterOrder={chapterOrder}
            pictureBookState={pictureBookState?.articleId === parsedRoute.articleId ? pictureBookState : null}
            onNavigate={navigate}
            onPictureBookLoaded={setPictureBookState}
            pictureBookRetryGate={pictureBookRetryGate}
            onOpenPicturePromptReview={openPictureBookPromptReview}
            englishPreloadState={preloadStates[preloadKey('listening', parsedRoute.articleId, 'english')]}
            recordingSettings={recordingSettings}
            onRecordingSettingsLoaded={applyRecordingSettings}
            songSettings={settings?.song ?? null}
            onNotice={setNotice}
            onArticlesUpdated={(payload) => {
              if (payload.articles) setArticles(payload.articles);
              if (payload.series) setSeries(payload.series);
            }}
          />
        )}

        {parsedRoute.kind === 'listen' && (
          <ListeningPage
            articleId={parsedRoute.articleId}
            mode="listening"
            pictureBookState={pictureBookState?.articleId === parsedRoute.articleId ? pictureBookState : null}
            onNavigate={navigate}
            onPictureBookLoaded={setPictureBookState}
            pictureBookRetryGate={pictureBookRetryGate}
            onOpenPicturePromptReview={openPictureBookPromptReview}
            englishPreloadState={preloadStates[preloadKey('listening', parsedRoute.articleId, 'english')]}
            recordingSettings={recordingSettings}
            onRecordingSettingsLoaded={applyRecordingSettings}
            songSettings={settings?.song ?? null}
            onNotice={setNotice}
            onArticlesUpdated={(payload) => {
              if (payload.articles) setArticles(payload.articles);
              if (payload.series) setSeries(payload.series);
            }}
          />
        )}

        {parsedRoute.kind === 'creation' && (
          <CreationCenterPage
            articles={articles}
            series={series}
            initialSeriesId={parsedRoute.seriesId}
            initialArticleId={parsedRoute.articleId}
            chapterOrder={chapterOrder}
            recordingSettings={recordingSettings}
            onRecordingSettingsLoaded={applyRecordingSettings}
            pictureBookRetryGate={pictureBookRetryGate}
            picturePromptReviewLoadingArticleId={picturePromptReviewLoadingArticleId}
            onNavigate={navigate}
            onNotice={setNotice}
            onBlockingOverlayChange={setAppBlockingOverlay}
            onOpenPicturePromptReview={openPictureBookPromptReview}
            onOpenPicturePagePromptReview={openPictureBookPagePromptReview}
            onChapterOrderChange={rememberChapterOrder}
            onArticlesUpdated={(payload) => {
              if (payload.articles) setArticles(payload.articles);
              if (payload.series) setSeries(payload.series);
            }}
            onRename={async (articleId, title) => {
              const payload = await sendNative<{ article: Article; articles: Article[]; series?: StorySeries[] }>(
                'article.rename',
                { articleId, title },
              );
              setArticles(payload.articles);
              if (payload.series) setSeries(payload.series);
              rememberSeriesKey(bookKeyForArticle(payload.article));
              setNotice('章节标题已更新');
            }}
            onDelete={async (articleId) => {
              const payload = await sendNative<{ articles: Article[]; series?: StorySeries[] }>(
                'article.delete',
                { articleId },
              );
              setArticles(payload.articles);
              if (payload.series) setSeries(payload.series);
              setNotice('章节已删除');
            }}
            onDeleteSeries={async (seriesId) => {
              try {
                const payload = await sendNative<{ articles: Article[]; series?: StorySeries[] }>(
                  'series.delete',
                  { seriesId },
                );
                setArticles(payload.articles);
                if (payload.series) setSeries(payload.series);
                setNotice('空书籍已删除');
              } catch (err) {
                setNotice(err instanceof Error ? err.message : String(err));
              }
            }}
            onUpdateSeries={updateSeries}
          />
        )}

        {parsedRoute.kind === 'practice' && (
          <PracticeCenterPage
            articles={articles}
            series={series}
            initialSeriesId={parsedRoute.seriesId}
            chapterOrder={chapterOrder}
            onNavigate={navigate}
            onNotice={setNotice}
            onRecentBookKeyChange={rememberSeriesKey}
            onChapterOrderChange={rememberChapterOrder}
          />
        )}

        {parsedRoute.kind === 'follow' && (
          <FollowPage
            articleId={parsedRoute.articleId}
            state={followState}
            pictureBookState={pictureBookState?.articleId === parsedRoute.articleId ? pictureBookState : null}
            onNavigate={navigate}
            onLoaded={setFollowState}
            onPictureBookLoaded={setPictureBookState}
            pictureBookRetryGate={pictureBookRetryGate}
            onOpenPicturePromptReview={openPictureBookPromptReview}
            preloadState={preloadStates[preloadKey('follow', parsedRoute.articleId, 'english')]}
          />
        )}

        {parsedRoute.kind === 'chat' && (
          <ChatPage
            articleId={parsedRoute.articleId}
            state={chatState}
            pictureBookState={pictureBookState?.articleId === parsedRoute.articleId ? pictureBookState : null}
            onNavigate={navigate}
            onLoaded={setChatState}
            onPictureBookLoaded={setPictureBookState}
            pictureBookRetryGate={pictureBookRetryGate}
            onOpenPicturePromptReview={openPictureBookPromptReview}
          />
        )}

        {parsedRoute.kind === 'settings' && (
          <SettingsPage
            settings={settings}
            onLoaded={setSettings}
          />
        )}
      </main>
      {picturePromptReview && (
        <PictureBookPromptReviewDialog
          review={picturePromptReview}
          onClose={() => {
            const reviewId = picturePromptReview.reviewId;
            setPicturePromptReview(null);
            void sendNative('pictureBook.cancelPromptReview', { reviewId }).catch(() => undefined);
          }}
          onConfirmed={(payload) => {
            setPictureBookState(payload);
            setPicturePromptReview(null);
            setNotice(
              picturePromptReview.mode === 'singlePage'
                ? '已提交单张绘本图生成'
                : '已提交绘本组图生成',
            );
          }}
          onNotice={setNotice}
          onBlockingOverlayChange={setAppBlockingOverlay}
        />
      )}
      {picturePromptReviewLoadingArticleId !== null && (
        <AiBlockingOverlay
          title="正在读取绘本提示词"
          detail="正在从本地读取分镜草稿；如需 AI 自动生成，可在审核框中点击自动生成章节规划。"
          timeoutSeconds={180}
        />
      )}
      {appBlockingOverlay && (
        <AiBlockingOverlay
          title={appBlockingOverlay.title}
          detail={appBlockingOverlay.detail}
          timeoutSeconds={appBlockingOverlay.timeoutSeconds}
        />
      )}
    </div>
  );
}

function HomePage({
  articles,
  series,
  latestArticle,
  recentBookKey,
  chapterOrder,
  onRecentBookKeyChange,
  onChapterOrderChange,
  onNavigate,
  onOpenBook,
  onUpdateSeries,
}: {
  articles: Article[];
  series: StorySeries[];
  latestArticle?: Article;
  recentBookKey: string | null;
  chapterOrder: ChapterOrder;
  onRecentBookKeyChange: (key: string | null) => void;
  onChapterOrderChange: (order: ChapterOrder) => void;
  onNavigate: (path: string) => void;
  onOpenBook: (book: BookGroup) => void;
  onUpdateSeries: (seriesId: number, title: string, description: string, characters: BookCharacter[]) => Promise<void>;
}) {
  const [selectedBookKey, setSelectedBookKey] = useState<string | null>(null);
  const [chapterPage, setChapterPage] = useState(0);
  const [bookEditDraft, setBookEditDraft] = useState<BookGroup | null>(null);
  const [bookEditTitle, setBookEditTitle] = useState('');
  const [bookEditDescription, setBookEditDescription] = useState('');
  const [bookEditCharacters, setBookEditCharacters] = useState<BookCharacter[]>([]);
  const [bookEditSaving, setBookEditSaving] = useState(false);
  const [bookEditError, setBookEditError] = useState<string | null>(null);
  const totalSentences = articles.reduce((sum, article) => sum + article.sentenceCount, 0);
  const averageScore =
    articles.length === 0
      ? 0
      : Math.round(
          articles.reduce((sum, article) => sum + article.averageScore, 0) /
            articles.length,
        );
  const books = useMemo(() => bookGroupsForArticles(articles, series), [articles, series]);
  const preferredBookKey = useMemo(
    () => preferredHomeBookKey(books, recentBookKey, latestArticle),
    [books, latestArticle, recentBookKey],
  );
  const selectedBook =
    selectedBookKey == null
      ? null
      : books.find((book) => book.key === selectedBookKey) ?? null;

  useEffect(() => {
    if (books.length === 0) {
      if (selectedBookKey !== null) {
        setSelectedBookKey(null);
      }
      setChapterPage(0);
      return;
    }
    if (!selectedBookKey || !books.some((book) => book.key === selectedBookKey)) {
      setSelectedBookKey(preferredBookKey);
      if (preferredBookKey) {
        onRecentBookKeyChange(preferredBookKey);
      }
      setChapterPage(0);
    }
  }, [books, onRecentBookKeyChange, preferredBookKey, selectedBookKey]);

  useEffect(() => {
    if (
      recentBookKey &&
      recentBookKey !== selectedBookKey &&
      books.some((book) => book.key === recentBookKey)
    ) {
      setSelectedBookKey(recentBookKey);
      setChapterPage(0);
    }
  }, [books, recentBookKey, selectedBookKey]);

  return (
    <section className="page home-page">
      <header className="home-hero">
        <div className="hero-copy">
          <h1>书库、绘本和章节听力工作台</h1>
          <p>按书籍管理章节，把英文内容变成可连续播放的绘本听力、歌曲和学习视频。</p>
          <div className="hero-actions">
            <button
              className="primary-action"
              onClick={() => {
                if (latestArticle) {
                  onRecentBookKeyChange(bookKeyForArticle(latestArticle));
                  if (latestArticle.seriesId != null) {
                    onNavigate(`/books/${latestArticle.seriesId}/player?articleId=${latestArticle.id}&mode=listening`);
                  } else {
                    onNavigate(`/listen/${latestArticle.id}`);
                  }
                } else {
                  onNavigate('/article/new');
                }
              }}
            >
              <Icon name="play" /> 继续听力
            </button>
            <button className="ghost-action" type="button" onClick={() => onNavigate('/creation')}>
              <Icon name="recordVideo" /> 打开创作中心
            </button>
          </div>
        </div>
        <div className="hero-stage library-stage">
          <div className="library-stage-preview">
            <span>当前书库</span>
            <b>{books.length} 本书</b>
            <small>{articles.length} 个章节 · {totalSentences} 句英文</small>
          </div>
        </div>
      </header>

      <div className="dashboard-grid">
        <section className="stats-row" aria-label="learning stats">
          <StatTile label="章节" value={articles.length.toString()} icon="card" />
          <StatTile label="句子" value={totalSentences.toString()} icon="sentence" />
          <StatTile label="平均跟读分" value={averageScore > 0 ? averageScore.toString() : '--'} icon="star" />
        </section>
      </div>

      <BookLibrarySelectorPanel
        books={books}
        selectedBookKey={selectedBook?.key ?? null}
        chapterPage={chapterPage}
        chapterOrder={chapterOrder}
        emptyState={<EmptyMission onNavigate={onNavigate} />}
        onAddChapter={() => onNavigate('/article/new')}
        onSelectBook={(book) => {
          setSelectedBookKey(book.key);
          onRecentBookKeyChange(book.key);
          setChapterPage(0);
          onOpenBook(book);
        }}
        onChapterPageChange={setChapterPage}
        onChapterOrderChange={(nextOrder) => {
          onChapterOrderChange(nextOrder);
          setChapterPage(0);
        }}
        onEditSeries={(book) => {
          setBookEditDraft(book);
          setBookEditTitle(book.title);
          setBookEditDescription(book.description ?? '');
          setBookEditCharacters(editableBookCharacters(book.characters));
          setBookEditError(null);
        }}
        renderChapterRow={({ selectedBook: book, article, imageSrc }) => (
          <MissionRow
            key={article.id}
            article={article}
            imageSrc={imageSrc}
            onListen={() => {
              onRecentBookKeyChange(book.key);
              onNavigate(
                book.seriesId != null
                  ? `/books/${book.seriesId}/player?articleId=${article.id}&mode=listening`
                  : `/listen/${article.id}`,
              );
            }}
            onFollow={() => {
              onRecentBookKeyChange(book.key);
              onNavigate(`/follow/${article.id}`);
            }}
            onChat={() => {
              onRecentBookKeyChange(book.key);
              onNavigate(`/chat/${article.id}`);
            }}
          />
        )}
      />
      {bookEditDraft && (
        <BookEditDialog
          title={bookEditTitle}
          description={bookEditDescription}
          characters={bookEditCharacters}
          error={bookEditError}
          saving={bookEditSaving}
          onTitleChange={(title) => {
            setBookEditTitle(title);
            setBookEditError(null);
          }}
          onDescriptionChange={(description) => {
            setBookEditDescription(description);
            setBookEditError(null);
          }}
          onCharactersChange={(characters) => {
            setBookEditCharacters(characters);
            setBookEditError(null);
          }}
          onCancel={() => {
            if (bookEditSaving) return;
            setBookEditDraft(null);
            setBookEditError(null);
          }}
          onSave={async () => {
            if (!bookEditDraft?.seriesId || bookEditSaving) return;
            setBookEditSaving(true);
            setBookEditError(null);
            try {
              await onUpdateSeries(
                bookEditDraft.seriesId,
                bookEditTitle.trim(),
                bookEditDescription.trim(),
                bookEditCharacters,
              );
              setBookEditDraft(null);
            } catch (error) {
              setBookEditError(error instanceof Error ? error.message : '书籍信息保存失败');
            } finally {
              setBookEditSaving(false);
            }
          }}
        />
      )}
    </section>
  );
}

function BookDetailPage({
  seriesId,
  articles,
  series,
  chapterOrder,
  onNavigate,
  onRecentBookKeyChange,
  onChapterOrderChange,
  onUpdateSeries,
}: {
  seriesId: number;
  articles: Article[];
  series: StorySeries[];
  chapterOrder: ChapterOrder;
  onNavigate: (path: string) => void;
  onRecentBookKeyChange: (key: string | null) => void;
  onChapterOrderChange: (order: ChapterOrder) => void;
  onUpdateSeries: (seriesId: number, title: string, description: string, characters: BookCharacter[]) => Promise<void>;
}) {
  const [bookEditOpen, setBookEditOpen] = useState(false);
  const [bookEditTitle, setBookEditTitle] = useState('');
  const [bookEditDescription, setBookEditDescription] = useState('');
  const [bookEditCharacters, setBookEditCharacters] = useState<BookCharacter[]>([]);
  const [bookEditSaving, setBookEditSaving] = useState(false);
  const [bookEditError, setBookEditError] = useState<string | null>(null);
  const book = useMemo(
    () => bookGroupsForArticles(articles, series).find((item) => item.seriesId === seriesId) ?? null,
    [articles, series, seriesId],
  );
  const chapters = useMemo(
    () => sortBookChapters(book?.articles ?? [], chapterOrder),
    [book?.articles, chapterOrder],
  );
  const firstChapter = chapters[0];

  if (!book) {
    return (
      <section className="page book-detail-page">
        <TopBar title="书籍不存在" onBack={() => onNavigate('/')} />
        <div className="loading-panel">
          <p>没有找到这本书，可能已被删除或尚未同步。</p>
          <button className="primary-action" type="button" onClick={() => onNavigate('/')}>
            <Icon name="back" /> 返回书库
          </button>
        </div>
      </section>
    );
  }

  const bookKey = `series:${seriesId}`;
  const openPlayer = (mode: PlayerMode, articleId = firstChapter?.id) => {
    if (!articleId) return;
    onRecentBookKeyChange(bookKey);
    onNavigate(`/books/${seriesId}/player?articleId=${articleId}&mode=${mode}`);
  };

  return (
    <section className="page book-detail-page">
      <TopBar title={book.title} onBack={() => onNavigate('/')}>
        <button
          className="ghost-action"
          type="button"
          onClick={() => {
            setBookEditTitle(book.title);
            setBookEditDescription(book.description ?? '');
            setBookEditCharacters(editableBookCharacters(book.characters));
            setBookEditError(null);
            setBookEditOpen(true);
          }}
        >
          <Icon name="edit" /> 编辑书籍
        </button>
        <button className="ghost-action" type="button" onClick={() => onNavigate('/article/new')}>
          <Icon name="plus" /> 新增章节
        </button>
        <button className="ghost-action" type="button" onClick={() => onNavigate(`/creation?seriesId=${seriesId}`)}>
          <Icon name="recordVideo" /> 创作中心
        </button>
      </TopBar>

      <section className="book-overview-panel">
        <img src={bookCoverSource(book, 0)} alt="" />
        <div className="book-overview-copy">
          <h2>{book.title}</h2>
          {book.description && <p>{book.description}</p>}
          <p>{book.articles.length} 个章节 · {book.sentenceCount} 句英文 · 平均跟读分 {book.averageScore || '--'}</p>
          <div className="button-row">
            <button className="primary-action" type="button" disabled={!firstChapter} onClick={() => openPlayer('listening')}>
              <Icon name="play" /> 连续听力
            </button>
            <button className="ghost-action" type="button" disabled={!firstChapter} onClick={() => openPlayer('song')}>
              <Icon name="music" /> 歌曲模式
            </button>
            <button className="ghost-action" type="button" onClick={() => onNavigate(`/practice?seriesId=${seriesId}`)}>
              <Icon name="mic" /> 练习章节
            </button>
          </div>
        </div>
      </section>

      <section className="chapter-list-panel book-detail-chapters" aria-label={`${book.title} 章节列表`}>
        <div className="chapter-toolbar">
          <div>
            <span>章节目录</span>
            <b>{chapters.length} 个章节</b>
          </div>
          <button
            className="ghost-action small"
            type="button"
            onClick={() => onChapterOrderChange(chapterOrder === 'asc' ? 'desc' : 'asc')}
          >
            <Icon name="swap" /> {chapterOrder === 'asc' ? '正序' : '倒序'}
          </button>
        </div>
        {chapters.length === 0 ? (
          <EmptyMission onNavigate={onNavigate} />
        ) : (
          <div className="mission-list">
            {chapters.map((article, index) => (
              <MissionRow
                key={article.id}
                article={article}
                imageSrc={articleCoverSource(article, index)}
                onListen={() => openPlayer('listening', article.id)}
                onFollow={() => onNavigate(`/follow/${article.id}`)}
                onChat={() => onNavigate(`/chat/${article.id}`)}
                extraAction={
                  <button className="ghost-action small" type="button" onClick={() => onNavigate(`/creation?articleId=${article.id}&seriesId=${seriesId}`)}>
                    <Icon name="recordVideo" /> 生成
                  </button>
                }
              />
            ))}
          </div>
        )}
      </section>

      {bookEditOpen && (
        <BookEditDialog
          title={bookEditTitle}
          description={bookEditDescription}
          characters={bookEditCharacters}
          error={bookEditError}
          saving={bookEditSaving}
          onTitleChange={(title) => {
            setBookEditTitle(title);
            setBookEditError(null);
          }}
          onDescriptionChange={(description) => {
            setBookEditDescription(description);
            setBookEditError(null);
          }}
          onCharactersChange={(characters) => {
            setBookEditCharacters(characters);
            setBookEditError(null);
          }}
          onCancel={() => {
            if (bookEditSaving) return;
            setBookEditOpen(false);
            setBookEditError(null);
          }}
          onSave={async () => {
            if (bookEditSaving) return;
            setBookEditSaving(true);
            setBookEditError(null);
            try {
              await onUpdateSeries(
                seriesId,
                bookEditTitle.trim(),
                bookEditDescription.trim(),
                bookEditCharacters,
              );
              setBookEditOpen(false);
            } catch (error) {
              setBookEditError(error instanceof Error ? error.message : '书籍信息保存失败');
            } finally {
              setBookEditSaving(false);
            }
          }}
        />
      )}
    </section>
  );
}

function BookPlayerPage({
  seriesId,
  startArticleId,
  mode,
  articles,
  series,
  chapterOrder,
  pictureBookState,
  onNavigate,
  onPictureBookLoaded,
  pictureBookRetryGate,
  onOpenPicturePromptReview,
  englishPreloadState,
  recordingSettings,
  onRecordingSettingsLoaded,
  songSettings,
  onNotice,
  onArticlesUpdated,
}: {
  seriesId: number;
  startArticleId: number;
  mode: PlayerMode;
  articles: Article[];
  series: StorySeries[];
  chapterOrder: ChapterOrder;
  pictureBookState: PictureBookState | null;
  onNavigate: (path: string) => void;
  onPictureBookLoaded: PictureBookStateSetter;
  pictureBookRetryGate: PictureBookRetryGate;
  onOpenPicturePromptReview: (articleId: number, regenerate?: boolean) => void | Promise<void>;
  englishPreloadState?: PreloadState;
  recordingSettings: RecordingSettings | null;
  onRecordingSettingsLoaded: (settings: RecordingSettings) => void;
  songSettings: SettingsState['song'] | null;
  onNotice: (message: string) => void;
  onArticlesUpdated: (payload: { articles?: Article[]; series?: StorySeries[] }) => void;
}) {
  const book = useMemo(
    () => bookGroupsForArticles(articles, series).find((item) => item.seriesId === seriesId) ?? null,
    [articles, series, seriesId],
  );
  const chapters = useMemo(
    () => sortBookChapters(book?.articles ?? [], chapterOrder),
    [book?.articles, chapterOrder],
  );
  const activeIndex = Math.max(0, chapters.findIndex((article) => article.id === startArticleId));
  const activeArticle = chapters[activeIndex] ?? chapters[0];
  const previousArticle = activeIndex > 0 ? chapters[activeIndex - 1] : null;
  const nextArticle = activeIndex >= 0 && activeIndex < chapters.length - 1 ? chapters[activeIndex + 1] : null;
  const [chapterDrawerOpen, setChapterDrawerOpen] = useState(false);

  useEffect(() => {
    setChapterDrawerOpen(false);
  }, [startArticleId, mode]);

  useEffect(() => {
    if (!chapterDrawerOpen) return undefined;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        setChapterDrawerOpen(false);
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [chapterDrawerOpen]);

  if (!book || !activeArticle) {
    return (
      <section className="page book-player-page">
        <TopBar title="书籍播放器" onBack={() => onNavigate(`/books/${seriesId}`)} />
        <LoadingPanel text="正在准备书籍章节..." />
      </section>
    );
  }

  const navigatePlayer = (articleId: number, nextMode = mode) => {
    onNavigate(`/books/${seriesId}/player?articleId=${articleId}&mode=${nextMode}`);
  };

  return (
    <section className="page book-player-page">
      <div className="book-player-layout">
        <div className="book-player-main">
          <ListeningPage
            articleId={activeArticle.id}
            mode={mode}
            bookTitle={book.title}
            chapterLabel={`第 ${activeIndex + 1} / ${chapters.length} 章`}
            onPrevChapter={previousArticle ? () => navigatePlayer(previousArticle.id) : undefined}
            onNextChapter={nextArticle ? () => navigatePlayer(nextArticle.id) : undefined}
            onSwitchMode={(nextMode) => navigatePlayer(activeArticle.id, nextMode)}
            chapterDrawerOpen={chapterDrawerOpen}
            onOpenChapterDrawer={() => setChapterDrawerOpen(true)}
            pictureBookState={pictureBookState}
            onNavigate={onNavigate}
            onPictureBookLoaded={onPictureBookLoaded}
            pictureBookRetryGate={pictureBookRetryGate}
            onOpenPicturePromptReview={onOpenPicturePromptReview}
            englishPreloadState={englishPreloadState}
            recordingSettings={recordingSettings}
            onRecordingSettingsLoaded={onRecordingSettingsLoaded}
            songSettings={songSettings}
            onNotice={onNotice}
            onArticlesUpdated={onArticlesUpdated}
          />
        </div>
      </div>
      <ChapterDrawer
        book={book}
        chapters={chapters}
        activeArticle={activeArticle}
        activeIndex={activeIndex}
        open={chapterDrawerOpen}
        onClose={() => setChapterDrawerOpen(false)}
        onSelect={(articleId) => navigatePlayer(articleId)}
        onOpenBook={() => onNavigate(`/books/${seriesId}`)}
      />
    </section>
  );
}

function ChapterDrawer({
  book,
  chapters,
  activeArticle,
  activeIndex,
  open,
  onClose,
  onSelect,
  onOpenBook,
}: {
  book: BookGroup;
  chapters: Article[];
  activeArticle: Article;
  activeIndex: number;
  open: boolean;
  onClose: () => void;
  onSelect: (articleId: number) => void;
  onOpenBook: () => void;
}) {
  if (!open) return null;

  return createPortal(
    <div className="chapter-drawer-backdrop" role="presentation" onClick={onClose}>
      <aside
        id="book-chapter-drawer"
        className="chapter-drawer"
        role="dialog"
        aria-modal="true"
        aria-label={`${book.title} 章节列表`}
        onClick={(event) => event.stopPropagation()}
      >
        <header className="chapter-drawer-heading">
          <div>
            <span>章节列表</span>
            <b>{book.title}</b>
            <small>当前第 {activeIndex + 1} / {chapters.length} 章</small>
          </div>
          <button className="icon-button small" type="button" aria-label="关闭章节列表" onClick={onClose}>
            <Icon name="close" />
          </button>
        </header>
        <div className="chapter-queue chapter-drawer-list" aria-label={`${book.title} 播放队列`}>
          {chapters.map((chapter, index) => (
            <button
              key={chapter.id}
              type="button"
              className={chapter.id === activeArticle.id ? 'active' : ''}
              onClick={() => {
                onSelect(chapter.id);
                onClose();
              }}
            >
              <b>{index + 1}</b>
              <span>{chapter.title}</span>
              <small>{chapter.sentenceCount ?? chapter.sentences?.length ?? 0} 句</small>
            </button>
          ))}
        </div>
        <footer className="chapter-drawer-footer">
          <button className="ghost-action" type="button" onClick={onOpenBook}>
            <Icon name="back" /> 书籍详情
          </button>
        </footer>
      </aside>
    </div>,
    document.body,
  );
}

function BookLibrarySelectorPanel({
  books,
  selectedBookKey,
  chapterPage,
  chapterOrder,
  emptyState,
  className,
  showHeaderEditAction = false,
  onAddChapter,
  onSelectBook,
  onChapterPageChange,
  onChapterOrderChange,
  onDeleteSeries,
  onEditSeries,
  chapterListCollapsed = false,
  collapsedChapterTitle,
  onChapterListCollapsedChange,
  renderChapterRow,
}: {
  books: BookGroup[];
  selectedBookKey: string | null;
  chapterPage: number;
  chapterOrder: ChapterOrder;
  emptyState: ReactNode;
  className?: string;
  showHeaderEditAction?: boolean;
  onAddChapter: () => void;
  onSelectBook: (book: BookGroup) => void;
  onChapterPageChange: (page: number | ((current: number) => number)) => void;
  onChapterOrderChange: (order: ChapterOrder) => void;
  onDeleteSeries?: (seriesId: number) => void | Promise<void>;
  onEditSeries?: (book: BookGroup) => void;
  chapterListCollapsed?: boolean;
  collapsedChapterTitle?: string | null;
  onChapterListCollapsedChange?: (collapsed: boolean) => void;
  renderChapterRow: (context: {
    selectedBook: BookGroup;
    article: Article;
    imageSrc: string;
    visibleIndex: number;
    absoluteIndex: number;
  }) => ReactNode;
}) {
  const selectedBook =
    selectedBookKey == null
      ? null
      : books.find((book) => book.key === selectedBookKey) ?? null;
  const orderedChapters = useMemo(
    () => (selectedBook ? sortBookChapters(selectedBook.articles, chapterOrder) : []),
    [selectedBook, chapterOrder],
  );
  const totalChapterPages = Math.max(1, Math.ceil(orderedChapters.length / 10));
  const safeChapterPage = Math.max(0, Math.min(chapterPage, totalChapterPages - 1));
  const visibleChapters = orderedChapters.slice(safeChapterPage * 10, safeChapterPage * 10 + 10);
  const panelClassName = ['mission-list-panel', 'book-library-selector-panel', className]
    .filter(Boolean)
    .join(' ');

  return (
    <section className={panelClassName}>
      <div className="section-heading with-action">
        <span>我的书籍</span>
        <div className="section-heading-actions">
          {showHeaderEditAction && onEditSeries && selectedBook?.seriesId != null && (
            <button type="button" onClick={() => onEditSeries(selectedBook)}>
              <Icon name="edit" /> 编辑书籍
            </button>
          )}
          <button type="button" onClick={onAddChapter}>
            <Icon name="plus" /> 新增章节
          </button>
        </div>
      </div>
      {books.length === 0 ? (
        emptyState
      ) : (
        <>
          <div className="book-list" role="list" aria-label="书籍列表">
            {books.map((book, index) => (
              <div className="book-card-wrap" key={book.key}>
                <article className={`book-card ${book.key === selectedBook?.key ? 'active' : ''}`}>
                  <button
                    className="book-card-main"
                    type="button"
                    onClick={() => onSelectBook(book)}
                  >
                    <img src={bookCoverSource(book, index)} alt="" />
                    <span>
                      <b>{book.title}</b>
                      <small>{book.articles.length} 篇章节 · {book.sentenceCount} 句子</small>
                    </span>
                    <Icon name="next" />
                  </button>
                </article>
                {onDeleteSeries && book.seriesId != null && book.articles.length === 0 && (
                  <button
                    className="danger-light small book-delete-button"
                    type="button"
                    onClick={(event) => {
                      event.stopPropagation();
                      void onDeleteSeries(book.seriesId!);
                    }}
                  >
                    删除
                  </button>
                )}
              </div>
            ))}
          </div>

          {selectedBook && (
            chapterListCollapsed ? (
              <section className="chapter-list-panel collapsed" aria-label={`${selectedBook.title} 章节列表`}>
                <button
                  className="chapter-toggle-row collapsed"
                  type="button"
                  aria-label="展开章节列表"
                  aria-expanded="false"
                  onClick={() => onChapterListCollapsedChange?.(false)}
                >
                  <span className="chapter-toggle-label">
                    <span aria-hidden="true">＞</span>
                    <span>章节列表已折叠</span>
                  </span>
                  <b>{collapsedChapterTitle?.trim() || selectedBook.title}</b>
                  <small>{selectedBook.title}</small>
                </button>
              </section>
            ) : (
              <section className="chapter-list-panel" aria-label={`${selectedBook.title} 章节列表`}>
              <div className="chapter-toolbar">
                <button
                  className="chapter-toggle-row expanded"
                  type="button"
                  aria-label="折叠章节列表"
                  aria-expanded="true"
                  onClick={() => onChapterListCollapsedChange?.(true)}
                  disabled={!onChapterListCollapsedChange}
                >
                  <span className="chapter-toggle-label">
                    <span aria-hidden="true">∨</span>
                    <span>章节列表</span>
                  </span>
                </button>
                <div className="chapter-tools">
                  <div className="pagination" aria-label="章节分页">
                    <button
                      type="button"
                      onClick={() => onChapterPageChange((page) => Math.max(0, page - 1))}
                      disabled={safeChapterPage === 0}
                    >
                      <Icon name="prev" /> 上一页
                    </button>
                    <button
                      type="button"
                      onClick={() => onChapterOrderChange(chapterOrder === 'asc' ? 'desc' : 'asc')}
                    >
                      <Icon name="swap" /> {chapterOrder === 'asc' ? '正序' : '倒序'}
                    </button>
                    <span>第 {safeChapterPage + 1} / {totalChapterPages} 页 · 每页 10 篇</span>
                    <button
                      type="button"
                      onClick={() => onChapterPageChange((page) => Math.min(totalChapterPages - 1, page + 1))}
                      disabled={safeChapterPage >= totalChapterPages - 1}
                    >
                      下一页 <Icon name="next" />
                    </button>
                  </div>
                </div>
              </div>

              <div className="mission-list">
                {visibleChapters.map((article, index) =>
                  renderChapterRow({
                    selectedBook,
                    article,
                    imageSrc: articleCoverSource(article, safeChapterPage * 10 + index),
                    visibleIndex: index,
                    absoluteIndex: safeChapterPage * 10 + index,
                  }),
                )}
              </div>
            </section>
            )
          )}
        </>
      )}
    </section>
  );
}

function PracticeCenterPage({
  articles,
  series,
  initialSeriesId,
  chapterOrder,
  onNavigate,
  onNotice,
  onRecentBookKeyChange,
  onChapterOrderChange,
}: {
  articles: Article[];
  series: StorySeries[];
  initialSeriesId?: number;
  chapterOrder: ChapterOrder;
  onNavigate: (path: string) => void;
  onNotice: (message: string) => void;
  onRecentBookKeyChange: (key: string | null) => void;
  onChapterOrderChange: (order: ChapterOrder) => void;
}) {
  const books = useMemo(() => bookGroupsForArticles(articles, series), [articles, series]);
  const routeBook = books.find((book) => book.seriesId === initialSeriesId) ?? null;
  const [selectedBookKey, setSelectedBookKey] = useState<string | null>(() => routeBook?.key ?? books[0]?.key ?? null);
  const syncedRouteBookKeyRef = useRef<string | null>(null);
  const [chapterPage, setChapterPage] = useState(0);
  const [chapterListCollapsed, setChapterListCollapsed] = useState(false);
  const resolvedSelectedBookKey =
    selectedBookKey && books.some((book) => book.key === selectedBookKey)
      ? selectedBookKey
      : books[0]?.key ?? null;
  const selectedBook =
    resolvedSelectedBookKey == null
      ? null
      : books.find((book) => book.key === resolvedSelectedBookKey) ?? null;
  const selectedBookArticleIds = useMemo(
    () => selectedBook?.articles.map((article) => article.id) ?? [],
    [selectedBook],
  );
  const selectedBookArticleKey = selectedBookArticleIds.join(',');
  const [videoLibrariesByArticleId, setVideoLibrariesByArticleId] = useState<
    Record<number, RecordingVideoLibraryPayload | null>
  >({});

  useEffect(() => {
    if (books.length === 0) {
      if (selectedBookKey !== null) {
        setSelectedBookKey(null);
      }
      setChapterPage(0);
      setChapterListCollapsed(false);
      return;
    }
    const routeBookKey = routeBook?.key ?? null;
    if (routeBookKey && syncedRouteBookKeyRef.current !== routeBookKey) {
      syncedRouteBookKeyRef.current = routeBookKey;
      if (selectedBookKey !== routeBookKey) {
        setSelectedBookKey(routeBookKey);
      }
      setChapterPage(0);
      setChapterListCollapsed(false);
      return;
    }
    if (!routeBookKey) {
      syncedRouteBookKeyRef.current = null;
    }
    if (!selectedBookKey || !books.some((book) => book.key === selectedBookKey)) {
      setSelectedBookKey(books[0].key);
      setChapterPage(0);
      setChapterListCollapsed(false);
    }
  }, [books, routeBook?.key, selectedBookKey]);

  useEffect(() => {
    let cancelled = false;
    if (selectedBookArticleIds.length === 0) {
      setVideoLibrariesByArticleId({});
      return () => {
        cancelled = true;
      };
    }
    selectedBookArticleIds.forEach((articleId) => {
      sendNative<RecordingVideoLibraryPayload>('recording.videoList', { articleId })
        .then((library) => {
          if (!cancelled) {
            setVideoLibrariesByArticleId((current) => ({
              ...current,
              [articleId]: library,
            }));
          }
        })
        .catch(() => {
          if (!cancelled) {
            setVideoLibrariesByArticleId((current) => ({
              ...current,
              [articleId]: null,
            }));
          }
        });
    });
    return () => {
      cancelled = true;
    };
  }, [selectedBookArticleKey]);

  return (
    <section className="page practice-center-page">
      <TopBar title="练习中心" onBack={() => onNavigate('/')} />
      <BookLibrarySelectorPanel
        books={books}
        selectedBookKey={resolvedSelectedBookKey}
        chapterPage={chapterPage}
        chapterOrder={chapterOrder}
        className="practice-library-selector"
        chapterListCollapsed={chapterListCollapsed}
        collapsedChapterTitle={books.find((book) => book.key === resolvedSelectedBookKey)?.title}
        emptyState={<EmptyMission onNavigate={onNavigate} />}
        onAddChapter={() => onNavigate('/article/new')}
        onSelectBook={(book) => {
          setSelectedBookKey(book.key);
          onRecentBookKeyChange(book.key);
          setChapterPage(0);
          setChapterListCollapsed(false);
        }}
        onChapterListCollapsedChange={setChapterListCollapsed}
        onChapterPageChange={setChapterPage}
        onChapterOrderChange={(nextOrder) => {
          onChapterOrderChange(nextOrder);
          setChapterPage(0);
          setChapterListCollapsed(false);
        }}
        renderChapterRow={({ selectedBook, article, imageSrc }) => {
          const videoVersions = videoLibrariesByArticleId[article.id]?.versions ?? [];
          const defaultVideo = defaultRecordingVideo(videoVersions);
          return (
            <MissionRow
              key={article.id}
              article={article}
              imageSrc={imageSrc}
              onListen={() => {
                onRecentBookKeyChange(selectedBook.key);
                onNavigate(
                  selectedBook.seriesId != null
                    ? `/books/${selectedBook.seriesId}/player?articleId=${article.id}&mode=listening`
                    : `/listen/${article.id}`,
                );
              }}
              onVideo={defaultVideo ? () => {
                onRecentBookKeyChange(selectedBook.key);
                sendNative('recording.videoPlay', {
                  articleId: article.id,
                  videoId: defaultVideo.id,
                }).catch((error) => {
                  onNotice(error instanceof Error ? error.message : '视频播放失败');
                });
              } : undefined}
              videoDisabled={!defaultVideo}
              onFollow={() => {
                onRecentBookKeyChange(selectedBook.key);
                onNavigate(`/follow/${article.id}`);
              }}
              onChat={() => {
                onRecentBookKeyChange(selectedBook.key);
                onNavigate(`/chat/${article.id}`);
              }}
            />
          );
        }}
      />
    </section>
  );
}

function CreationCenterPage({
  articles,
  series,
  initialSeriesId,
  initialArticleId,
  chapterOrder,
  recordingSettings,
  onRecordingSettingsLoaded,
  pictureBookRetryGate,
  picturePromptReviewLoadingArticleId,
  onNavigate,
  onNotice,
  onBlockingOverlayChange,
  onOpenPicturePromptReview,
  onOpenPicturePagePromptReview,
  onChapterOrderChange,
  onArticlesUpdated,
  onRename,
  onDelete,
  onDeleteSeries,
  onUpdateSeries,
}: {
  articles: Article[];
  series: StorySeries[];
  initialSeriesId?: number;
  initialArticleId?: number;
  chapterOrder: ChapterOrder;
  recordingSettings: RecordingSettings | null;
  onRecordingSettingsLoaded: (settings: RecordingSettings) => void;
  pictureBookRetryGate: PictureBookRetryGate;
  picturePromptReviewLoadingArticleId: number | null;
  onNavigate: (path: string) => void;
  onNotice: (message: string) => void;
  onBlockingOverlayChange: (overlay: BlockingOverlayConfig | null) => void;
  onOpenPicturePromptReview: (articleId: number, regenerate?: boolean) => void | Promise<void>;
  onOpenPicturePagePromptReview: (articleId: number, pageIndex: number) => void | Promise<void>;
  onChapterOrderChange: (order: ChapterOrder) => void;
  onArticlesUpdated: (payload: { articles?: Article[]; series?: StorySeries[] }) => void;
  onRename: (articleId: number, title: string) => Promise<void>;
  onDelete: (articleId: number) => Promise<void>;
  onDeleteSeries: (seriesId: number) => Promise<void>;
  onUpdateSeries: (seriesId: number, title: string, description: string, characters: BookCharacter[]) => Promise<void>;
}) {
  const books = useMemo(() => bookGroupsForArticles(articles, series), [articles, series]);
  const routeBook = books.find((book) => book.seriesId === initialSeriesId) ??
    books.find((book) => book.articles.some((article) => article.id === initialArticleId)) ??
    null;
  const [selectedBookKey, setSelectedBookKey] = useState<string | null>(() => routeBook?.key ?? books[0]?.key ?? null);
  const syncedRouteSelectionRef = useRef<string | null>(null);
  const [chapterPage, setChapterPage] = useState(0);
  const [selectedArticleId, setSelectedArticleId] = useState<number | null>(() => initialArticleId ?? null);
  const [activeTab, setActiveTab] = useState<'picture' | 'song' | 'video'>('picture');
  const [chapterListCollapsed, setChapterListCollapsed] = useState(false);
  const [renameDraft, setRenameDraft] = useState<{ article: Article; title: string } | null>(null);
  const [renameSaving, setRenameSaving] = useState(false);
  const [renameError, setRenameError] = useState<string | null>(null);
  const [bookEditDraft, setBookEditDraft] = useState<BookGroup | null>(null);
  const [bookEditTitle, setBookEditTitle] = useState('');
  const [bookEditDescription, setBookEditDescription] = useState('');
  const [bookEditCharacters, setBookEditCharacters] = useState<BookCharacter[]>([]);
  const [bookEditSaving, setBookEditSaving] = useState(false);
  const [bookEditGeneratingDescription, setBookEditGeneratingDescription] = useState(false);
  const [bookEditError, setBookEditError] = useState<string | null>(null);
  const [bookTransferBusy, setBookTransferBusy] = useState<'export' | 'import' | null>(null);
  const resolvedSelectedBookKey =
    selectedBookKey && books.some((book) => book.key === selectedBookKey)
      ? selectedBookKey
      : books[0]?.key ?? null;
  const selectedBook =
    resolvedSelectedBookKey == null
      ? null
      : books.find((book) => book.key === resolvedSelectedBookKey) ?? null;
  const orderedChapters = useMemo(
    () => sortBookChapters(selectedBook?.articles ?? [], chapterOrder),
    [selectedBook?.articles, chapterOrder],
  );
  const selectedArticle =
    orderedChapters.find((article) => article.id === selectedArticleId) ??
    orderedChapters.find((article) => article.id === initialArticleId) ??
    orderedChapters[0] ??
    null;

  useEffect(() => {
    if (books.length === 0) {
      if (selectedBookKey !== null) {
        setSelectedBookKey(null);
      }
      if (selectedArticleId !== null) {
        setSelectedArticleId(null);
      }
      setChapterPage(0);
      return;
    }
    const routeSelectionKey = routeBook
      ? `${routeBook.key}:${initialArticleId ?? ''}`
      : null;
    if (routeBook && routeSelectionKey && syncedRouteSelectionRef.current !== routeSelectionKey) {
      syncedRouteSelectionRef.current = routeSelectionKey;
      const routeChapters = sortBookChapters(routeBook.articles, chapterOrder);
      const routeArticleId =
        routeChapters.find((article) => article.id === initialArticleId)?.id ??
        routeChapters[0]?.id ??
        null;
      if (selectedBookKey !== routeBook.key) {
        setSelectedBookKey(routeBook.key);
      }
      if (selectedArticleId !== routeArticleId) {
        setSelectedArticleId(routeArticleId);
      }
      setChapterPage(0);
      return;
    }
    if (!routeSelectionKey) {
      syncedRouteSelectionRef.current = null;
    }
    if (!selectedBookKey || !books.some((book) => book.key === selectedBookKey)) {
      const fallbackBook = books[0];
      setSelectedBookKey(fallbackBook.key);
      setSelectedArticleId(sortBookChapters(fallbackBook.articles, chapterOrder)[0]?.id ?? null);
      setChapterPage(0);
    }
  }, [books, chapterOrder, initialArticleId, routeBook, selectedArticleId, selectedBookKey]);

  useEffect(() => {
    if (orderedChapters.length === 0) {
      if (selectedArticleId !== null) {
        setSelectedArticleId(null);
      }
      return;
    }
    if (!selectedArticle || selectedArticle.id !== selectedArticleId) {
      setSelectedArticleId(selectedArticle?.id ?? orderedChapters[0].id);
    }
  }, [orderedChapters, selectedArticle, selectedArticleId]);

  const selectCreationArticle = (
    articleId: number,
    tab: 'picture' | 'song' | 'video' = activeTab,
    collapseChapterList = false,
  ) => {
    setSelectedArticleId(articleId);
    setActiveTab(tab);
    if (collapseChapterList) {
      setChapterListCollapsed(true);
    }
  };

  const exportSelectedBook = async () => {
    const seriesId = selectedBook?.seriesId;
    if (seriesId == null) {
      onNotice('请选择要导出的书籍');
      return;
    }
    setBookTransferBusy('export');
    try {
      const payload = await sendNative<BookTransferPayload>('series.export', { seriesId });
      if (payload.cancelled) {
        onNotice('已取消导出书籍');
        return;
      }
      const warningSuffix = payload.warnings?.length ? `，${payload.warnings.length} 个提示` : '';
      onNotice(`书籍已导出：${payload.outputPath ?? payload.title ?? '完成'}${warningSuffix}`);
    } catch (error) {
      onNotice(error instanceof Error ? error.message : '书籍导出失败');
    } finally {
      setBookTransferBusy(null);
    }
  };

  const importBook = async () => {
    setBookTransferBusy('import');
    try {
      const payload = await sendNative<BookTransferPayload>('series.import');
      if (payload.cancelled) {
        onNotice('已取消导入书籍');
        return;
      }
      onArticlesUpdated({ articles: payload.articles, series: payload.series });
      if (payload.seriesId != null) {
        setSelectedBookKey(`series:${payload.seriesId}`);
        setChapterPage(0);
        setChapterListCollapsed(false);
        setSelectedArticleId(payload.articleIds?.[0] ?? null);
      }
      const warningSuffix = payload.warnings?.length ? `，${payload.warnings.length} 个提示` : '';
      onNotice(`书籍已导入：${payload.title ?? '新书籍'}${warningSuffix}`);
    } catch (error) {
      onNotice(error instanceof Error ? error.message : '书籍导入失败');
    } finally {
      setBookTransferBusy(null);
    }
  };

  return (
    <section className="page creation-center-page">
      <TopBar title="创作中心" onBack={() => onNavigate('/')}>
        <button
          className="ghost-action"
          type="button"
          onClick={() => void importBook()}
          disabled={bookTransferBusy !== null}
        >
          <Icon name={bookTransferBusy === 'import' ? 'refresh' : 'upload'} />
          {bookTransferBusy === 'import' ? '导入中' : '导入书籍'}
        </button>
        <button
          className="ghost-action"
          type="button"
          onClick={() => void exportSelectedBook()}
          disabled={bookTransferBusy !== null || selectedBook?.seriesId == null}
        >
          <Icon name={bookTransferBusy === 'export' ? 'refresh' : 'download'} />
          {bookTransferBusy === 'export' ? '导出中' : '导出书籍'}
        </button>
        {selectedBook?.seriesId != null && (
          <button className="ghost-action" type="button" onClick={() => onNavigate(`/books/${selectedBook.seriesId}`)}>
            <Icon name="back" /> 返回书籍
          </button>
        )}
      </TopBar>

      <BookLibrarySelectorPanel
        books={books}
        selectedBookKey={resolvedSelectedBookKey}
        chapterPage={chapterPage}
        chapterOrder={chapterOrder}
        className="creation-library-selector"
        chapterListCollapsed={chapterListCollapsed}
        collapsedChapterTitle={selectedArticle?.title}
        emptyState={<EmptyMission onNavigate={onNavigate} />}
        showHeaderEditAction
        onAddChapter={() => onNavigate('/article/new')}
        onSelectBook={(book) => {
          const firstArticle = sortBookChapters(book.articles, chapterOrder)[0] ?? null;
          setSelectedBookKey(book.key);
          setSelectedArticleId(firstArticle?.id ?? null);
          setChapterPage(0);
          setChapterListCollapsed(false);
        }}
        onChapterListCollapsedChange={setChapterListCollapsed}
        onChapterPageChange={setChapterPage}
        onChapterOrderChange={(nextOrder) => {
          onChapterOrderChange(nextOrder);
          setChapterPage(0);
          setChapterListCollapsed(false);
        }}
        onDeleteSeries={onDeleteSeries}
        onEditSeries={(book) => {
          setBookEditDraft(book);
          setBookEditTitle(book.title);
          setBookEditDescription(book.description ?? '');
          setBookEditCharacters(editableBookCharacters(book.characters));
          setBookEditGeneratingDescription(false);
          setBookEditError(null);
        }}
        renderChapterRow={({ article, imageSrc }) => (
          <MissionRow
            key={article.id}
            article={article}
            imageSrc={imageSrc}
            selected={article.id === selectedArticle?.id}
            openLabel="创作"
            onOpen={() => selectCreationArticle(article.id)}
            onRename={() => {
              setRenameDraft({ article, title: article.title });
              setRenameError(null);
            }}
            extraAction={
              <>
                <button
                  className={`ghost-action small ${article.id === selectedArticle?.id && activeTab === 'picture' ? 'active' : ''}`}
                  type="button"
                  onClick={() => selectCreationArticle(article.id, 'picture', false)}
                >
                  <Icon name="card" /> 绘本
                </button>
                <button
                  className={`ghost-action small ${article.id === selectedArticle?.id && activeTab === 'song' ? 'active' : ''}`}
                  type="button"
                  onClick={() => selectCreationArticle(article.id, 'song', false)}
                >
                  <Icon name="music" /> 歌曲
                </button>
                <button
                  className={`ghost-action small ${article.id === selectedArticle?.id && activeTab === 'video' ? 'active' : ''}`}
                  type="button"
                  onClick={() => selectCreationArticle(article.id, 'video', false)}
                >
                  <Icon name="recordVideo" /> 视频
                </button>
              </>
            }
            onDelete={() => {
              const title = article.title.trim() || '当前章节';
              const confirmed = window.confirm(`确定删除章节“${title}”？删除后不可恢复。`);
              if (!confirmed) {
                return;
              }
              void onDelete(article.id).catch((error) => {
                onNotice(error instanceof Error ? error.message : '章节删除失败');
              });
            }}
          />
        )}
      />

      <section className="creation-workspace">
        {!selectedArticle ? (
          <section className="creation-panel">
            <p className="sentence-empty">请先在书库中新建章节。</p>
            <button className="primary-action" type="button" onClick={() => onNavigate('/article/new')}>
              <Icon name="plus" /> 新增章节
            </button>
          </section>
        ) : activeTab === 'picture' ? (
          <PictureBookCreationPanel
            article={selectedArticle}
            pictureBookRetryGate={pictureBookRetryGate}
            promptReviewLoading={picturePromptReviewLoadingArticleId === selectedArticle.id}
            onNotice={onNotice}
            onOpenPromptReview={onOpenPicturePromptReview}
            onOpenPagePromptReview={onOpenPicturePagePromptReview}
          />
        ) : activeTab === 'song' ? (
          <SongCreationPanel
            article={selectedArticle}
            recordingSettings={recordingSettings}
            onRecordingSettingsLoaded={onRecordingSettingsLoaded}
            onNotice={onNotice}
            onBlockingOverlayChange={onBlockingOverlayChange}
          />
        ) : (
          <VideoCreationPanel
            article={selectedArticle}
            recordingSettings={recordingSettings}
            onRecordingSettingsLoaded={onRecordingSettingsLoaded}
            onNotice={onNotice}
            onArticlesUpdated={onArticlesUpdated}
          />
        )}
      </section>
      {renameDraft && (
        <EditTitleDialog
          title={renameDraft.title}
          error={renameError}
          saving={renameSaving}
          onTitleChange={(title) => {
            setRenameDraft((current) => (current ? { ...current, title } : current));
            setRenameError(null);
          }}
          onCancel={() => {
            if (renameSaving) return;
            setRenameDraft(null);
            setRenameError(null);
          }}
          onSave={async () => {
            if (!renameDraft || renameSaving) return;
            setRenameSaving(true);
            setRenameError(null);
            try {
              await onRename(renameDraft.article.id, renameDraft.title.trim());
              setRenameDraft(null);
            } catch (error) {
              setRenameError(error instanceof Error ? error.message : '章节标题保存失败');
            } finally {
              setRenameSaving(false);
            }
          }}
        />
      )}
      {bookEditDraft && (
        <BookEditDialog
          title={bookEditTitle}
          description={bookEditDescription}
          characters={bookEditCharacters}
          error={bookEditError}
          saving={bookEditSaving}
          generatingDescription={bookEditGeneratingDescription}
          onTitleChange={(title) => {
            setBookEditTitle(title);
            setBookEditError(null);
          }}
          onDescriptionChange={(description) => {
            setBookEditDescription(description);
            setBookEditError(null);
          }}
          onCharactersChange={(characters) => {
            setBookEditCharacters(characters);
            setBookEditError(null);
          }}
          onCancel={() => {
            if (bookEditSaving || bookEditGeneratingDescription) return;
            setBookEditDraft(null);
            setBookEditError(null);
          }}
          onGenerateDescription={async () => {
            if (!bookEditDraft || bookEditGeneratingDescription) return;
            const descriptionSeedTitle = bookEditTitle.trim();
            if (!descriptionSeedTitle) {
              setBookEditError('请先填写书籍名称');
              return;
            }
            setBookEditGeneratingDescription(true);
            setBookEditError(null);
            try {
              const article = bookEditDraft.articles[0] ?? null;
              const descriptionContent = article?.content.trim()
                ? article.content
                : `Book title: ${descriptionSeedTitle}. Generate a concise book-level visual description for this picture-book series.`;
              const payload = await sendNative<{ description: string; characters?: BookCharacter[] }>('series.suggestDescription', {
                seriesTitle: descriptionSeedTitle,
                articleTitle: article?.title ?? '',
                content: descriptionContent,
                description: bookEditDescription.trim(),
                characters: normalizeBookCharacters(bookEditCharacters),
              });
              setBookEditDescription(payload.description ?? '');
              if (payload.characters) {
                setBookEditCharacters(editableBookCharacters(payload.characters));
              }
            } catch (error) {
              setBookEditError(error instanceof Error ? error.message : '书籍简介生成失败');
            } finally {
              setBookEditGeneratingDescription(false);
            }
          }}
          onSave={async () => {
            if (!bookEditDraft?.seriesId || bookEditSaving || bookEditGeneratingDescription) return;
            setBookEditSaving(true);
            setBookEditError(null);
            try {
              await onUpdateSeries(
                bookEditDraft.seriesId,
                bookEditTitle.trim(),
                bookEditDescription.trim(),
                bookEditCharacters,
              );
              setBookEditDraft(null);
            } catch (error) {
              setBookEditError(error instanceof Error ? error.message : '书籍信息保存失败');
            } finally {
              setBookEditSaving(false);
            }
          }}
        />
      )}
    </section>
  );
}

function useListeningAudioMaterial(
  article: Article,
  onNotice: (message: string) => void,
  options: { onGenerated?: (status: ListeningAudioMaterialStatus) => void } = {},
) {
  const [audioStatus, setAudioStatus] = useState<ListeningAudioMaterialStatus | null>(null);
  const [audioStatusLoading, setAudioStatusLoading] = useState(true);
  const [audioGenerating, setAudioGenerating] = useState(false);
  const [audioProgress, setAudioProgress] = useState<ListeningAudioMaterialProgress | null>(null);
  const [audioOverwriteConfirm, setAudioOverwriteConfirm] = useState<ListeningAudioMaterialStatus | null>(null);

  const loadAudioStatus = async () => {
    setAudioStatusLoading(true);
    try {
      const payload = await sendNative<ListeningAudioMaterialStatus>('listening.audioStatus', { articleId: article.id });
      const normalized = normalizeAudioMaterialStatus(payload, article.id);
      setAudioStatus(normalized);
      return normalized;
    } catch (error) {
      onNotice(error instanceof Error ? error.message : '听力材料状态加载失败');
      return null;
    } finally {
      setAudioStatusLoading(false);
    }
  };

  useEffect(() => {
    void loadAudioStatus();
  }, [article.id]);

  useEffect(() => {
    return onNativeEvent<ListeningAudioMaterialProgress>('listening.audioMaterial.progress', (payload) => {
      if (payload.articleId !== article.id) {
        return;
      }
      setAudioProgress(payload);
    });
  }, [article.id]);

  const startListeningAudioGeneration = async (
    currentStatus: ListeningAudioMaterialStatus,
    overwrite: boolean,
  ) => {
    const requestTotal = overwrite ? currentStatus.total : currentStatus.missing.length;
    setAudioGenerating(true);
    setAudioProgress({
      articleId: article.id,
      status: 'loading',
      completed: 0,
      total: requestTotal,
      failed: 0,
      overwrite,
    });
    try {
      const payload = normalizeAudioMaterialStatus(await sendNative<ListeningAudioMaterialStatus>('listening.audioGenerate', {
        articleId: article.id,
        overwrite,
      }), article.id);
      setAudioStatus(payload);
      options.onGenerated?.(payload);
      if (payload.ready >= payload.total && payload.missing.length === 0 && payload.failed === 0) {
        onNotice('听力材料已生成');
      } else {
        onNotice('听力材料生成完成，但仍有缺失项');
      }
    } catch (error) {
      onNotice(error instanceof Error ? error.message : '听力材料生成失败');
    } finally {
      setAudioGenerating(false);
    }
  };

  const generateListeningAudio = async () => {
    if (audioGenerating) return;
    const currentStatus = audioStatus ?? (await loadAudioStatus());
    if (!currentStatus || currentStatus.total <= 0) {
      onNotice('章节没有可生成的英文听力材料');
      return;
    }
    const complete = currentStatus.ready >= currentStatus.total && currentStatus.missing.length === 0;
    if (complete) {
      setAudioOverwriteConfirm(currentStatus);
      return;
    }
    await startListeningAudioGeneration(currentStatus, false);
  };

  return {
    audioStatus,
    audioStatusLoading,
    audioGenerating,
    audioProgress,
    audioOverwriteConfirm,
    setAudioOverwriteConfirm,
    startListeningAudioGeneration,
    generateListeningAudio,
  };
}

function PictureBookCreationPanel({
  article,
  pictureBookRetryGate,
  promptReviewLoading,
  onNotice,
  onOpenPromptReview,
  onOpenPagePromptReview,
}: {
  article: Article;
  pictureBookRetryGate: PictureBookRetryGate;
  promptReviewLoading: boolean;
  onNotice: (message: string) => void;
  onOpenPromptReview: (articleId: number, regenerate?: boolean) => void | Promise<void>;
  onOpenPagePromptReview: (articleId: number, pageIndex: number) => void | Promise<void>;
}) {
  const [state, setState] = useState<PictureBookState | null>(null);
  const [loading, setLoading] = useState(true);
  const [picturePreview, setPicturePreview] = useState<PictureBookPagePreviewState | null>(null);
  const {
    audioStatus,
    audioStatusLoading,
    audioGenerating,
    audioProgress,
    audioOverwriteConfirm,
    setAudioOverwriteConfirm,
    startListeningAudioGeneration,
    generateListeningAudio,
  } = useListeningAudioMaterial(article, onNotice);

  const loadState = () => {
    setLoading(true);
    sendNative<PictureBookState>('pictureBook.state', { articleId: article.id, includeImageUris: false })
      .then((payload) => setState((current) => mergePictureBookState(current, payload)))
      .catch((error) => onNotice(error instanceof Error ? error.message : '绘本状态加载失败'))
      .finally(() => setLoading(false));
  };

  useEffect(loadState, [article.id]);
  useEffect(() => {
    setPicturePreview(null);
  }, [article.id]);
  useEffect(() => {
    return onNativeEvent<PictureBookState>('pictureBook.state', (payload) => {
      if (payload.articleId !== article.id) {
        return;
      }
      setState((current) => mergePictureBookState(current, payload));
      setLoading(false);
    });
  }, [article.id]);
  useEnsureAllPictureBookPageImages({
    articleId: article.id,
    state,
    enabled: Boolean(state),
    imageVariant: 'thumbnail',
    onPictureBookLoaded: setState,
  });

  const retryPage = (page: PictureBookPage) => {
    if (!pictureBookRetryGate.begin(article.id, page.pageIndex)) return;
    Promise.resolve(onOpenPagePromptReview(article.id, page.pageIndex))
      .then(() => onNotice('请审核这一页提示词后确认重新生成'))
      .catch((error) => onNotice(error instanceof Error ? error.message : '绘本重试失败'))
      .finally(() => pictureBookRetryGate.finish(article.id, page.pageIndex));
  };

  const copyFullText = async () => {
    try {
      const payload = await sendNative<ArticleFullTextPayload>('article.fullText', { articleId: article.id });
      await copyArticleFullText(payload);
      onNotice('全文已复制到剪贴板');
    } catch (error) {
      onNotice(error instanceof Error ? error.message : '全文复制失败');
    }
  };

  const openPicturePreview = async (page: PictureBookPage, pageIndex: number) => {
    if (!directImageSource(page.imageUri)) {
      return;
    }

    setPicturePreview({ pageIndex, imageUri: null, loading: true });

    try {
      // Never feed the raw 2560x1440 original into a WebView <img>: downscaling that
      // texture into the window-sized preview stage corrupts on some Windows GPU
      // drivers (blocky color noise). The product-facing resolution is 1280x720, so
      // the "display" variant is the largest bitmap the WebView should ever render.
      let imageUri =
        normalizedPictureBookImageVariant(page.imageVariant) === 'display' &&
        pageHasPictureBookImageVariant(page, 'display')
          ? directImageSource(page.imageUri)
          : null;
      if (!imageUri) {
        const payload = await sendNative<PictureBookPageImagePayload>('pictureBook.pageImage', {
          articleId: article.id,
          pageIndex,
          variant: 'display',
        });
        imageUri = directImageSource(payload.imageUri);
      }
      if (!imageUri) {
        onNotice('绘本原图加载失败');
        setPicturePreview(null);
        return;
      }
      setPicturePreview({
        pageIndex,
        imageUri: preferBlobImageUrl(imageUri),
        loading: false,
      });
    } catch (error) {
      onNotice(error instanceof Error ? error.message : '绘本原图加载失败');
      setPicturePreview(null);
    }
  };

  return (
    <section className="creation-panel">
      <div className="section-heading with-action">
        <span>绘本组图</span>
        <div className="button-row compact">
          <button
            className="ghost-action small"
            type="button"
            onClick={() => void onOpenPromptReview(article.id, true)}
            disabled={promptReviewLoading}
          >
            <Icon name={promptReviewLoading ? 'refresh' : 'wand'} />
            {promptReviewLoading ? '准备中' : '生成组图'}
          </button>
          <button
            className="ghost-action small"
            type="button"
            onClick={() => void generateListeningAudio()}
            disabled={audioGenerating || audioStatusLoading}
          >
            <Icon name={audioGenerating ? 'refresh' : 'sound'} />
            {audioGenerating ? '生成中' : '生成听力'}
          </button>
          <button className="ghost-action small" type="button" onClick={loadState} disabled={loading}>
            <Icon name="refresh" /> 刷新状态
          </button>
          <button className="ghost-action small" type="button" onClick={() => void copyFullText()}>
            <Icon name="copy" /> 复制全文
          </button>
        </div>
      </div>
      <p className="creation-panel-note">绘本生成使用整章连续分镜组图；提交前会先打开提示词审核。</p>
      <div className="creation-resource-grid" aria-label="绘本资源状态">
        <ResourceRow label="章节正文" value={`${article.sentenceCount} 句英文`} />
        <ResourceRow label="绘本图片" value={state ? `${state.pages.length} 页 · ${pictureBookStatusLabel(state.status)}` : '读取中'} />
        <ResourceRow label="听力材料" value={audioMaterialStatusLabel(audioStatus, audioStatusLoading)} />
      </div>
      {audioOverwriteConfirm && (
        <AudioMaterialOverwriteConfirmDialog
          status={audioOverwriteConfirm}
          busy={audioGenerating}
          onCancel={() => setAudioOverwriteConfirm(null)}
          onConfirm={() => {
            const status = audioOverwriteConfirm;
            setAudioOverwriteConfirm(null);
            void startListeningAudioGeneration(status, true);
          }}
        />
      )}
      {audioGenerating && <AudioMaterialProgressDialog progress={audioProgress} />}
      {loading && <LoadingPanel text="正在读取绘本状态" />}
      {!loading && !state && <p className="sentence-empty">还没有绘本状态。</p>}
      {state && (
        <div className="picture-creation-grid">
          {state.pages.length === 0 ? (
            <p className="sentence-empty">这章还没有绘本页。</p>
          ) : (
            state.pages.map((page, index) => {
              const safePageIndex = Number.isFinite(page.pageIndex) ? page.pageIndex : index;
              const imageSource = directImageSource(page.imageUri);
              const scenePreview = pictureBookPageScenePreview(page);
              const retrying = pictureBookRetryGate.isRetrying(article.id, safePageIndex);
              return (
                <article className={`picture-creation-card ${page.status}`} key={`${safePageIndex}:${page.imagePath ?? page.imageUri ?? ''}`}>
                  {imageSource ? (
                    <button
                      type="button"
                      className="picture-creation-media is-clickable"
                      onClick={() => void openPicturePreview(page, safePageIndex)}
                      aria-label={`查看第 ${safePageIndex + 1} 页大图`}
                    >
                      <img src={imageSource} alt="" />
                    </button>
                  ) : (
                    <div className="picture-creation-media is-empty">
                      <span>{page.status === 'error' ? '生成失败' : pictureBookStatusLabel(page.status)}</span>
                    </div>
                  )}
                  <div className="picture-creation-copy">
                    <b>第 {safePageIndex + 1} 页</b>
                    <small>句子 {page.sentenceStartIndex + 1} - {page.sentenceEndIndex + 1}</small>
                    {scenePreview.sceneDescription && <p className="picture-scene-description">{scenePreview.sceneDescription}</p>}
                    <p>{page.paragraphText}</p>
                    {page.errorMessage && <em>{page.errorMessage}</em>}
                    <button
                      className="ghost-action small"
                      type="button"
                      disabled={retrying || promptReviewLoading}
                      onClick={() => retryPage({ ...page, pageIndex: safePageIndex })}
                    >
                      <Icon name="refresh" /> {retrying ? '准备中' : '重新生成'}
                    </button>
                  </div>
                </article>
              );
            })
          )}
        </div>
      )}
      {picturePreview && (
        <PictureBookPagePreviewOverlay
          state={picturePreview}
          onClose={() => {
            if (picturePreview.imageUri) {
              releaseBlobImageUrl(picturePreview.imageUri);
            }
            setPicturePreview(null);
          }}
          onDisplayError={() => {
            if (picturePreview.imageUri) {
              releaseBlobImageUrl(picturePreview.imageUri);
            }
            onNotice('绘本原图显示失败');
            setPicturePreview(null);
          }}
        />
      )}
    </section>
  );
}

type PictureBookPagePreviewState = {
  pageIndex: number;
  imageUri: string | null;
  loading: boolean;
};

function PictureBookPagePreviewOverlay({
  state,
  onClose,
  onDisplayError,
}: {
  state: PictureBookPagePreviewState;
  onClose: () => void;
  onDisplayError: () => void;
}) {
  // Keep backdrop-filter off this overlay: WebView2 can corrupt large images underneath.
  const [imageReady, setImageReady] = useState(false);

  useEffect(() => {
    setImageReady(false);
  }, [state.imageUri, state.loading]);

  const waitingForImage = Boolean(state.imageUri) && !state.loading && !imageReady;

  return createPortal(
    <div className="picture-book-preview-overlay" role="presentation">
      <div className="picture-book-preview-backdrop" aria-hidden="true" />
      <div
        className="picture-book-preview-stage"
        role="dialog"
        aria-modal="true"
        aria-label={`第 ${state.pageIndex + 1} 页绘本大图`}
      >
        {(state.loading || waitingForImage) && (
          <div className="picture-book-preview-loading" aria-live="polite">
            <Icon name="refresh" />
            <span>正在加载原图</span>
          </div>
        )}
        {state.imageUri && !state.loading ? (
          <button
            type="button"
            className={`picture-book-preview-image-button${imageReady ? ' is-ready' : ''}`}
            onClick={onClose}
            aria-label="关闭大图预览"
          >
            <img
              src={state.imageUri}
              alt=""
              className="picture-book-preview-image"
              onLoad={() => setImageReady(true)}
              onError={() => onDisplayError()}
            />
          </button>
        ) : null}
      </div>
    </div>,
    document.body,
  );
}

function PictureBookPromptReviewDialog({
  review,
  onClose,
  onConfirmed,
  onNotice,
  onBlockingOverlayChange,
}: {
  review: PictureBookPromptReview;
  onClose: () => void;
  onConfirmed: (payload: PictureBookState) => void;
  onNotice: (message: string) => void;
  onBlockingOverlayChange: (overlay: BlockingOverlayConfig | null) => void;
}) {
  const [bookDescription, setBookDescription] = useState(review.bookDescription ?? '');
  const [bookCharacters, setBookCharacters] = useState<BookCharacter[]>(
    () => editableBookCharacters(review.bookCharacters),
  );
  const [newCharacters, setNewCharacters] = useState<BookCharacter[]>(
    () => editableBookCharacters(review.newCharacters),
  );
  const [chapterDescription, setChapterDescription] = useState(review.chapterDescription ?? '');
  const [scenes, setScenes] = useState<PictureBookPromptReviewScene[]>(review.scenes ?? []);
  const [bookDescriptionExpanded, setBookDescriptionExpanded] = useState(false);
  const [bookCharactersExpanded, setBookCharactersExpanded] = useState(false);
  const relevantCharacters = useMemo(
    () => resolveRelevantCharactersForReview(chapterDescription, scenes, bookCharacters),
    [bookCharacters, chapterDescription, scenes],
  );
  const initialGroupPrompt = resolvePictureBookGroupPrompt(review, review.scenes ?? []);
  const [groupPrompt, setGroupPrompt] = useState(initialGroupPrompt);
  const groupPromptRef = useRef(initialGroupPrompt);
  const groupPromptTouchedRef = useRef(false);
  const setGroupPromptValue = (value: string) => {
    groupPromptRef.current = value;
    setGroupPrompt(value);
  };
  const [groupPromptTouched, setGroupPromptTouched] = useState(false);
  const [savingPrompt, setSavingPrompt] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [refreshingPrompt, setRefreshingPrompt] = useState<PictureBookPromptRefreshTarget | null>(null);
  const [error, setError] = useState<string | null>(null);
  const busy = savingPrompt || submitting || refreshingPrompt !== null;
  const isSinglePageReview = review.mode === 'singlePage';
  const referenceOptions = isSinglePageReview ? (review.referenceOptions ?? []) : [];
  const maxReferenceSelections = Math.min(referenceOptions.length, 14);
  const [selectedReferencePageIndexes, setSelectedReferencePageIndexes] = useState<number[]>(
    () => resolveInitialReferencePageIndexes(review, referenceOptions),
  );
  const [referencePictureBookState, setReferencePictureBookState] = useState<PictureBookState | null>(null);
  const reviewBookTitle = review.bookTitle?.trim() || '书籍信息';
  const targetPageNumber = Math.max(
    1,
    Number(
      review.targetPageIndex ?? scenes[0]?.pageIndex ?? 0,
    ) + 1,
  );

  useEffect(() => {
    const nextScenes = review.scenes ?? [];
    setBookDescription(review.bookDescription ?? '');
    setBookCharacters(editableBookCharacters(review.bookCharacters));
    setNewCharacters(editableBookCharacters(review.newCharacters));
    setChapterDescription(review.chapterDescription ?? '');
    setScenes(nextScenes);
    setBookDescriptionExpanded(false);
    setBookCharactersExpanded(false);
    groupPromptTouchedRef.current = false;
    setGroupPromptValue(resolvePictureBookGroupPrompt(review, nextScenes));
    setGroupPromptTouched(false);
    setError(null);
    setSavingPrompt(false);
    setSubmitting(false);
    setRefreshingPrompt(null);
    setSelectedReferencePageIndexes(resolveInitialReferencePageIndexes(review, review.referenceOptions ?? []));
    setReferencePictureBookState(null);
  }, [review]);

  useEffect(() => {
    if (!isSinglePageReview || !review.articleId || referenceOptions.length === 0) {
      return;
    }
    let cancelled = false;
    void sendNative<PictureBookState>('pictureBook.state', {
      articleId: review.articleId,
      includeImageUris: false,
    })
      .then((payload) => {
        if (!cancelled) {
          setReferencePictureBookState((current) => mergePictureBookState(current, payload));
        }
      })
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [isSinglePageReview, referenceOptions.length, review.articleId, review.reviewId]);

  useEnsureAllPictureBookPageImages({
    articleId: review.articleId,
    state: referencePictureBookState,
    enabled: isSinglePageReview && referenceOptions.length > 0,
    imageVariant: 'thumbnail',
    onPictureBookLoaded: setReferencePictureBookState,
  });

  useEffect(() => {
    if (groupPromptTouched || groupPromptTouchedRef.current) return;
    setGroupPromptValue(composePictureBookPromptForReview({
      ...review,
      bookDescription,
      relevantCharacters,
      newCharacters,
      chapterDescription,
    }, scenes));
  }, [bookDescription, chapterDescription, groupPromptTouched, newCharacters, relevantCharacters, review, scenes]);

  const updateScene = (
    pageIndex: number,
    key: keyof Pick<PictureBookPromptReviewScene, 'sceneDescription'>,
    value: string,
  ) => {
    setScenes((current) =>
      current.map((scene) =>
        scene.pageIndex === pageIndex ? { ...scene, [key]: value } : scene,
      ),
    );
  };

  const applyReviewUpdate = (nextReview: PictureBookPromptReview) => {
    const nextScenes = nextReview.scenes ?? [];
    setBookDescription(nextReview.bookDescription ?? '');
    setBookCharacters(editableBookCharacters(nextReview.bookCharacters));
    setNewCharacters(editableBookCharacters(nextReview.newCharacters));
    setChapterDescription(nextReview.chapterDescription ?? '');
    setScenes(nextScenes);
    if (!groupPromptTouched && !groupPromptTouchedRef.current) {
      setGroupPromptValue(resolvePictureBookGroupPrompt(nextReview, nextScenes));
    }
  };

  const refreshPrompt = async (target: PictureBookPromptRefreshTarget) => {
    setRefreshingPrompt(target);
    setError(null);
    onBlockingOverlayChange(pictureBookPromptRefreshOverlay(target));
    try {
      const payload = await sendNative<PictureBookPromptReview>('pictureBook.refreshPromptReview', {
        reviewId: review.reviewId,
        target,
        bookDescription,
        bookCharacters: normalizeBookCharacters(bookCharacters),
        newCharacters: normalizeBookCharacters(newCharacters),
        chapterDescription,
        scenes,
      });
      applyReviewUpdate(payload);
      if (groupPromptTouched) {
        onNotice('提示词已刷新；组图总 Prompt 已手动锁定，未自动覆盖。');
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setError(message);
      onNotice(message);
    } finally {
      setRefreshingPrompt(null);
      onBlockingOverlayChange(null);
    }
  };

  const toggleReferencePageIndex = (pageIndex: number) => {
    setSelectedReferencePageIndexes((current) => {
      if (current.includes(pageIndex)) {
        if (current.length <= 1) {
          setError('请至少保留一张参考图片');
          return current;
        }
        setError(null);
        return current.filter((item) => item !== pageIndex);
      }
      if (current.length >= maxReferenceSelections) {
        setError(`参考图最多选择 ${maxReferenceSelections} 张`);
        return current;
      }
      setError(null);
      return [...current, pageIndex].sort((a, b) => a - b);
    });
  };

  const reviewSubmissionPayload = (currentGroupPrompt = groupPromptRef.current) => ({
    reviewId: review.reviewId,
    groupPrompt: currentGroupPrompt,
    bookDescription,
    bookCharacters: normalizeBookCharacters(bookCharacters),
    newCharacters: normalizeBookCharacters(newCharacters),
    chapterDescription,
    scenes,
    ...(isSinglePageReview && selectedReferencePageIndexes.length > 0
      ? {
          referencePageIndexes: [...selectedReferencePageIndexes].sort((a, b) => a - b),
          referencePageIndex: [...selectedReferencePageIndexes].sort((a, b) => a - b)[0],
        }
      : {}),
  });

  const savePrompt = async () => {
    const currentGroupPrompt = groupPromptRef.current;
    if (!currentGroupPrompt.trim()) {
      setError(isSinglePageReview ? '单张生成提示词不能为空' : '组图总提示词不能为空');
      return;
    }
    setSavingPrompt(true);
    setError(null);
    try {
      const payload = await sendNative<PictureBookPromptReview>(
        'pictureBook.savePromptReview',
        reviewSubmissionPayload(currentGroupPrompt),
      );
      applyReviewUpdate(payload);
      onNotice('提示词已保存，尚未生成组图。');
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setError(message);
      onNotice(message);
    } finally {
      setSavingPrompt(false);
    }
  };

  const confirm = async () => {
    const currentGroupPrompt = groupPromptRef.current;
    if (!currentGroupPrompt.trim()) {
      setError(isSinglePageReview ? '单张生成提示词不能为空' : '组图总提示词不能为空');
      return;
    }
    if (isSinglePageReview && referenceOptions.length > 0 && selectedReferencePageIndexes.length === 0) {
      setError('请至少选择一张参考图片');
      return;
    }
    setSubmitting(true);
    setError(null);
    onBlockingOverlayChange(
      isSinglePageReview
        ? pictureBookSinglePageSubmitOverlay(targetPageNumber)
        : pictureBookGroupSubmitOverlay(scenes.length),
    );
    try {
      const payload = await sendNative<PictureBookState>(
        isSinglePageReview ? 'pictureBook.confirmPagePromptReview' : 'pictureBook.confirmPromptReview',
        {
          ...reviewSubmissionPayload(currentGroupPrompt),
        },
      );
      onConfirmed(payload);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setError(message);
      onNotice(message);
    } finally {
      setSubmitting(false);
      onBlockingOverlayChange(null);
    }
  };

  const savePromptLabel = savingPrompt ? '保存中' : '保存提示词';
  const confirmLabel = submitting ? '生成中' : isSinglePageReview ? '生成这一张' : '生成组图';
  const renderRefreshButton = (
    target: PictureBookPromptRefreshTarget,
    label: string,
    ariaLabel: string,
  ) => (
    <button
      className="icon-button small prompt-magic-button"
      type="button"
      aria-label={ariaLabel}
      title={ariaLabel}
      disabled={busy}
      onClick={() => void refreshPrompt(target)}
    >
      <Icon name={refreshingPrompt === target ? 'refresh' : 'wand'} />
      <span>{refreshingPrompt === target ? '生成中' : label}</span>
    </button>
  );

  return createPortal(
    <div className="edit-dialog-backdrop picture-prompt-backdrop" role="presentation">
      <section
        className="edit-dialog picture-prompt-dialog"
        role="dialog"
        aria-modal="true"
        aria-label={isSinglePageReview ? '绘本单页提示词审核' : '绘本提示词审核'}
      >
        <div className="edit-dialog-heading">
          <div>
            <b>{isSinglePageReview ? '绘本单页提示词审核' : '绘本提示词审核'}</b>
            <small>
              {isSinglePageReview
                ? `确认后只替换第 ${targetPageNumber} 页`
                : review.regenerate
                  ? '确认后会删除旧组图并重新生成'
                  : '确认后才会提交图片生成'}
            </small>
          </div>
          <button className="icon-button small" type="button" aria-label="关闭绘本提示词审核" onClick={onClose} disabled={busy}>
            <Icon name="close" />
          </button>
        </div>

        <div className="picture-prompt-layout">
          <section className="picture-prompt-section full">
            <div className="picture-prompt-section-heading collapsible">
              <button
                className={`collapsible-heading ${bookDescriptionExpanded ? 'expanded' : ''}`}
                type="button"
                aria-expanded={bookDescriptionExpanded}
                onClick={() => setBookDescriptionExpanded((expanded) => !expanded)}
              >
                <Icon name="chevron" />
                <span>{reviewBookTitle}</span>
              </button>
              {!isSinglePageReview && renderRefreshButton('bookDescription', '自动生成书籍简介', 'AI 自动生成书籍简介')}
            </div>
            {bookDescriptionExpanded && (
              <textarea
                aria-label="书籍简介"
                value={bookDescription}
                rows={5}
                placeholder="时代、整体画风和视觉世界；角色外貌请放在角色列表里。"
                onChange={(event) => setBookDescription(event.target.value)}
              />
            )}
          </section>

          <section className="picture-prompt-section full">
            <div className="picture-prompt-section-heading collapsible">
              <button
                className={`collapsible-heading ${bookCharactersExpanded ? 'expanded' : ''}`}
                type="button"
                aria-expanded={bookCharactersExpanded}
                onClick={() => setBookCharactersExpanded((expanded) => !expanded)}
              >
                <Icon name="chevron" />
                <span>书籍角色</span>
              </button>
            </div>
            {bookCharactersExpanded && (
              <BookCharacterEditor
                label="书籍角色"
                characters={bookCharacters}
                onChange={setBookCharacters}
                disabled={busy}
              />
            )}
          </section>

          <section className="picture-prompt-section full">
            <div className="picture-prompt-section-heading">
              <h3>章节描述</h3>
              {!isSinglePageReview && renderRefreshButton('chapterPlan', '自动生成章节规划', 'AI 自动生成章节描述和分镜描述')}
            </div>
            <textarea
              aria-label="章节描述"
              value={chapterDescription}
              rows={5}
              onChange={(event) => setChapterDescription(event.target.value)}
            />
          </section>

          <section className="picture-prompt-section full">
            <BookCharacterEditor
              label="本章新增角色"
              characters={newCharacters}
              onChange={setNewCharacters}
              disabled={busy}
            />
          </section>

          <section className="picture-prompt-section full">
            <div className="picture-prompt-section-heading">
              <h3>{isSinglePageReview ? '当前分镜描述' : '章节分镜描述'}</h3>
            </div>
            <div className="picture-page-prompt-list">
              {scenes.map((scene) => (
                <label key={scene.pageIndex}>
                  <span>第 {scene.pageIndex + 1} 张 · 句子 {scene.sentenceStartIndex + 1} - {scene.sentenceEndIndex + 1}</span>
                  <small>{scene.paragraphText}</small>
                  <AutoResizeTextarea
                    aria-label={`第 ${scene.pageIndex + 1} 个分镜描述`}
                    value={scene.sceneDescription}
                    rows={2}
                    placeholder="这一张图对应的分镜描述"
                    onChange={(event) => updateScene(scene.pageIndex, 'sceneDescription', event.target.value)}
                  />
                </label>
              ))}
            </div>
          </section>

          <section className="picture-prompt-section full">
            <div className="picture-prompt-section-heading">
              <h3>{isSinglePageReview ? '单张生成 Prompt' : '组图总 Prompt'}</h3>
              {groupPromptTouched && <span>已手动锁定</span>}
            </div>
            <textarea
              aria-label={isSinglePageReview ? '单张生成提示词' : '组图总提示词'}
              value={groupPrompt}
              rows={10}
              onChange={(event) => {
                groupPromptTouchedRef.current = true;
                setGroupPromptValue(event.target.value);
                setGroupPromptTouched(true);
              }}
            />
            {groupPromptTouched && !isSinglePageReview && (
              <p className="picture-prompt-note">后续每页 prompt 修改不会自动覆盖组图总 prompt，最终以当前组图总 prompt 为准。</p>
            )}
          </section>

          {isSinglePageReview && referenceOptions.length > 0 && (
            <section className="picture-prompt-section full">
              <div className="picture-prompt-section-heading reference-toggle-row">
                <div>
                  <h3>参考图片</h3>
                  <small>点选一张或多张已生成图片作为风格参考（含当前重生成页）</small>
                </div>
                <small>已选 {selectedReferencePageIndexes.length} 张</small>
              </div>
              <div
                className="picture-reference-picker"
                role="listbox"
                aria-label="参考图片选择"
                aria-multiselectable="true"
              >
                {referenceOptions.map((pageIndex) => {
                  const page = referencePictureBookState?.pages.find((item) => item.pageIndex === pageIndex);
                  const selected = selectedReferencePageIndexes.includes(pageIndex);
                  const isTargetPage =
                    review.targetPageIndex != null && pageIndex === review.targetPageIndex;
                  const pageLabel = isTargetPage
                    ? `第 ${pageIndex + 1} 张（当前页）`
                    : `第 ${pageIndex + 1} 张`;
                  return (
                    <button
                      key={pageIndex}
                      type="button"
                      className={`picture-reference-option${selected ? ' is-selected' : ''}`}
                      role="option"
                      aria-selected={selected}
                      aria-label={pageLabel}
                      disabled={busy}
                      onClick={() => toggleReferencePageIndex(pageIndex)}
                    >
                      <span className="picture-reference-option-label">{pageLabel}</span>
                      <span className="picture-reference-option-media">
                        {page?.imageUri ? (
                          <img src={page.imageUri} alt={pageLabel} />
                        ) : (
                          <span>加载中</span>
                        )}
                      </span>
                    </button>
                  );
                })}
              </div>
            </section>
          )}
        </div>

        {error && <p className="edit-dialog-error">{error}</p>}
        <div className="edit-dialog-actions">
          <button className="ghost-action" type="button" onClick={onClose} disabled={busy}>
            取消
          </button>
          {!isSinglePageReview && (
            <button className="ghost-action" type="button" onClick={() => void savePrompt()} disabled={busy}>
              <Icon name={savingPrompt ? 'refresh' : 'save'} /> {savePromptLabel}
            </button>
          )}
          <button className="primary-action" type="button" onClick={() => void confirm()} disabled={busy}>
            <Icon name={submitting ? 'refresh' : 'wand'} /> {confirmLabel}
          </button>
        </div>
      </section>
    </div>,
    document.body,
  );
}

function resolveInitialReferencePageIndexes(
  review: Pick<PictureBookPromptReview, 'referencePageIndexes' | 'referencePageIndex'>,
  referenceOptions: number[],
): number[] {
  const fromReview = Array.isArray(review.referencePageIndexes)
    ? review.referencePageIndexes.filter((pageIndex) => referenceOptions.includes(pageIndex))
    : [];
  if (fromReview.length > 0) {
    return [...fromReview].sort((a, b) => a - b);
  }
  if (
    review.referencePageIndex != null &&
    referenceOptions.includes(review.referencePageIndex)
  ) {
    return [review.referencePageIndex];
  }
  return referenceOptions.length > 0 ? [referenceOptions[0]] : [];
}

function normalizeBookCharacters(characters?: BookCharacter[] | null): BookCharacter[] {
  if (!Array.isArray(characters)) return [];
  return characters
    .map((character) => ({
      name: normalizeInlineText(character?.name ?? ''),
      description: normalizeInlineText(character?.description ?? ''),
    }))
    .filter((character) => character.name && character.description);
}

function editableBookCharacters(characters?: BookCharacter[] | null): BookCharacter[] {
  return Array.isArray(characters)
    ? characters.map((character) => ({
        name: normalizeInlineText(character?.name ?? ''),
        description: normalizeInlineText(character?.description ?? ''),
      }))
    : [];
}

function mergeBookCharacters(
  base: BookCharacter[],
  additions: BookCharacter[],
): BookCharacter[] {
  const merged: BookCharacter[] = [];
  const seen = new Set<string>();
  [...normalizeBookCharacters(base), ...normalizeBookCharacters(additions)].forEach((character) => {
    const key = character.name.trim().toLowerCase();
    if (!key || seen.has(key)) return;
    seen.add(key);
    merged.push(character);
  });
  return merged;
}

function resolveRelevantCharactersForReview(
  chapterDescription: string,
  scenes: PictureBookPromptReviewScene[],
  characters: BookCharacter[],
): BookCharacter[] {
  const searchText = [
    chapterDescription,
    ...scenes.flatMap((scene) => [scene.paragraphText, scene.sceneDescription]),
  ].join('\n').toLowerCase();
  return normalizeBookCharacters(characters).filter((character) => {
    const key = character.name.trim().toLowerCase();
    return key.length >= 2 && searchText.includes(key);
  });
}

function normalizeInlineText(value: string): string {
  return value.replace(/\s+/g, ' ').trim();
}

function resolvePictureBookGroupPrompt(
  review: Pick<
    PictureBookPromptReview,
    | 'bookTitle'
    | 'bookDescription'
    | 'chapterDescription'
    | 'groupPrompt'
    | 'mode'
    | 'relevantCharacters'
    | 'newCharacters'
  >,
  scenes: PictureBookPromptReviewScene[],
): string {
  const nativePrompt = review.groupPrompt?.trim() ?? '';
  if (pictureBookGroupPromptHasSceneDetails(nativePrompt, scenes)) {
    return nativePrompt;
  }
  return composePictureBookPromptForReview(review, scenes);
}

function pictureBookGroupPromptHasSceneDetails(
  prompt: string,
  scenes: PictureBookPromptReviewScene[],
): boolean {
  if (!prompt.trim()) {
    return false;
  }
  if (!/^Book name:/im.test(prompt)) {
    return false;
  }
  if (scenes.length === 0) {
    return true;
  }
  const imageBlocks = prompt.match(/\bImage\s+\d+\s*:/gi) ?? [];
  return (
    imageBlocks.length >= scenes.length &&
    /Scene description:/i.test(prompt)
  );
}

function composePictureBookPromptForReview(
  review: Pick<
    PictureBookPromptReview,
    | 'bookTitle'
    | 'bookDescription'
    | 'chapterDescription'
    | 'mode'
    | 'relevantCharacters'
    | 'newCharacters'
  >,
  scenes: PictureBookPromptReviewScene[],
): string {
  if (review.mode !== 'singlePage') {
    return composePictureBookGroupPrompt(review, scenes);
  }
  const scene = scenes[0];
  const imageNumber = Math.max(1, Number(scene?.pageIndex ?? 0) + 1);
  const characters = mergeBookCharacters(
    normalizeBookCharacters(review.relevantCharacters),
    normalizeBookCharacters(review.newCharacters),
  );
  const lines = [
    `Book name: ${review.bookTitle ?? ''}`,
    `Book description: ${review.bookDescription ?? ''}`,
  ];
  if (characters.length > 0) {
    lines.push('', 'Relevant characters:');
    characters.forEach((character) => {
      lines.push(`- ${character.name}: ${character.description}`);
    });
  }
  lines.push(
    '',
    `Chapter description: ${review.chapterDescription ?? ''}`,
    '',
    `Generate exactly one picture for Image ${imageNumber}. Use the reference images only for visual consistency.`,
    'Do not generate other scenes, a collage, comic panels, or a multi-image sheet.',
  );
  if (scene) {
    lines.push('', `Image ${imageNumber}:`, `Scene description: ${scene.sceneDescription}`);
  }
  return lines.join('\n').trim();
}

function composePictureBookGroupPrompt(
  review: Pick<
    PictureBookPromptReview,
    'bookTitle' | 'bookDescription' | 'chapterDescription' | 'relevantCharacters' | 'newCharacters'
  >,
  scenes: PictureBookPromptReviewScene[],
): string {
  const characters = mergeBookCharacters(
    normalizeBookCharacters(review.relevantCharacters),
    normalizeBookCharacters(review.newCharacters),
  );
  const lines = [
    `Book name: ${review.bookTitle ?? ''}`,
    `Book description: ${review.bookDescription ?? ''}`,
  ];
  if (characters.length > 0) {
    lines.push('', 'Relevant characters:');
    characters.forEach((character) => {
      lines.push(`- ${character.name}: ${character.description}`);
    });
  }
  lines.push(
    '',
    `Chapter description: ${review.chapterDescription ?? ''}`,
  );
  scenes.forEach((scene, index) => {
    lines.push(
      '',
      `Image ${index + 1}:`,
      `Scene description: ${scene.sceneDescription}`,
    );
  });
  return lines.join('\n').trim();
}

function SongCreationPanel({
  article,
  recordingSettings,
  onRecordingSettingsLoaded,
  onNotice,
  onBlockingOverlayChange,
}: {
  article: Article;
  recordingSettings: RecordingSettings | null;
  onRecordingSettingsLoaded: (settings: RecordingSettings) => void;
  onNotice: (message: string) => void;
  onBlockingOverlayChange: (overlay: BlockingOverlayConfig | null) => void;
}) {
  const [songState, setSongState] = useState<ListeningSongStatePayload | null>(null);
  const [busy, setBusy] = useState(false);
  const [playingSongVersionId, setPlayingSongVersionId] = useState<string | null>(null);
  const [recordingDialogDraft, setRecordingDialogDraft] = useState<RecordingSettings | null>(null);
  const [recordingDialogSaving, setRecordingDialogSaving] = useState(false);
  const [recordingDialogVersionId, setRecordingDialogVersionId] = useState('');

  const loadState = () => {
    setBusy(true);
    sendNative<ListeningSongStatePayload>('listening.songState', { articleId: article.id })
      .then(setSongState)
      .catch((error) => onNotice(error instanceof Error ? error.message : '歌曲状态加载失败'))
      .finally(() => setBusy(false));
  };

  useEffect(() => {
    setPlayingSongVersionId(null);
    loadState();
  }, [article.id]);

  useEffect(() => onNativeEvent<ListeningSongStatePayload>('listening.song.state', (payload) => {
    if (payload.articleId === article.id) {
      setSongState(payload);
      setPlayingSongVersionId((current) => {
        if (!current) return null;
        if (payload.status === 'empty' || payload.status === 'error') return null;
        if (!payload.versions?.some((version) => version.id === current)) return null;
        return current;
      });
    }
  }), [article.id]);

  useEffect(() => onNativeEvent<ListeningSongPositionPayload>('listening.song.position', (payload) => {
    if (payload.articleId !== article.id) return;
    const durationMs = payload.durationMs ?? null;
    const reachedEnd =
      durationMs !== null &&
      durationMs > 0 &&
      payload.positionMs >= Math.max(0, durationMs - 250);
    if (!reachedEnd) return;
    setPlayingSongVersionId((current) => {
      if (!current) return current;
      if (payload.versionId && payload.versionId !== current) return current;
      return null;
    });
  }), [article.id]);
  const runSongCommand = async (
    command: string,
    payload: Record<string, unknown> = {},
    successMessage?: string,
    blockingOverlay?: BlockingOverlayConfig,
  ) => {
    setBusy(true);
    if (blockingOverlay) onBlockingOverlayChange(blockingOverlay);
    try {
      const next = await sendNative<ListeningSongStatePayload>(command, {
        articleId: article.id,
        ...payload,
      });
      setSongState(next);
      if (successMessage) onNotice(successMessage);
    } catch (error) {
      onNotice(error instanceof Error ? error.message : '歌曲操作失败');
    } finally {
      setBusy(false);
      if (blockingOverlay) onBlockingOverlayChange(null);
    }
  };

  const importExternalSong = async () => {
    setBusy(true);
    try {
      const next = await sendNative<ListeningSongStatePayload>('listening.songImportExternal', {
        articleId: article.id,
        source: songState?.source ?? 'suno',
      });
      setSongState(next);
      onNotice(next.importCancelled ? '已取消导入本地音乐' : '已导入本地音乐');
    } catch (error) {
      onNotice(error instanceof Error ? error.message : '本地音乐导入失败');
    } finally {
      setBusy(false);
    }
  };

  const recordSongVideoFromCreation = async (versionId: string, selectedSettings: RecordingSettings) => {
    setBusy(true);
    onBlockingOverlayChange({
      title: '正在导出歌曲视频',
      detail: '正在合成歌曲音频、字幕和绘本画面，请等待导出完成。',
      timeoutSeconds: 900,
    });
    try {
      await sendNative<ListeningRecordingResultPayload>('listening.songRecordVideo', {
        articleId: article.id,
        versionId,
        codec: selectedSettings.codec,
        resolution: selectedSettings.resolution,
        pageTransition: selectedSettings.pageTransition,
        subtitleMode: selectedSettings.subtitleMode,
        fps: selectedSettings.fps || 25,
      });
      const next = await sendNative<ListeningSongStatePayload>('listening.songState', {
        articleId: article.id,
      });
      setSongState(next);
      onNotice('歌曲视频导出完成');
    } catch (error) {
      onNotice(error instanceof Error ? error.message : '歌曲视频导出失败');
    } finally {
      setBusy(false);
      onBlockingOverlayChange(null);
    }
  };

  const exportSongAudioFromCreation = async (versionId: string) => {
    setBusy(true);
    try {
      await sendNative<ListeningSongAudioExportPayload>('listening.songExportAudio', {
        articleId: article.id,
        versionId,
      });
      onNotice('音频已导出到 recording-export/mp3');
    } catch (error) {
      onNotice(error instanceof Error ? error.message : '音频导出失败');
    } finally {
      setBusy(false);
    }
  };

  const openSongRecordingDialog = (versionId: string) => {
    if (!recordingSettings) {
      onNotice('录制设置尚未加载，请稍后重试');
      return;
    }
    setRecordingDialogVersionId(versionId);
    setRecordingDialogDraft(recordingSettings);
  };

  const updateRecordingDialogDraft = (patch: Partial<RecordingSettings>) => {
    setRecordingDialogDraft((draft) => (draft ? { ...draft, ...patch } : draft));
  };

  const confirmSongRecordingDialog = async () => {
    if (!recordingDialogDraft || !recordingDialogVersionId || recordingDialogSaving) return;
    setRecordingDialogSaving(true);
    try {
      const savedSettings = await sendNative<RecordingSettings>('recording.settings.save', {
        codec: recordingDialogDraft.codec,
        resolution: recordingDialogDraft.resolution,
        pageTransition: recordingDialogDraft.pageTransition,
        subtitleMode: recordingDialogDraft.subtitleMode,
      });
      onRecordingSettingsLoaded(savedSettings);
      const versionId = recordingDialogVersionId;
      setRecordingDialogDraft(null);
      setRecordingDialogVersionId('');
      await recordSongVideoFromCreation(versionId, savedSettings);
    } catch (error) {
      onNotice(error instanceof Error ? error.message : '录制设置保存失败');
    } finally {
      setRecordingDialogSaving(false);
    }
  };

  const playSongVersionFromCreation = async (versionId: string) => {
    const isPlaying = playingSongVersionId === versionId;
    setBusy(true);
    try {
      if (isPlaying) {
        await sendNative('listening.songStop', { articleId: article.id });
        setPlayingSongVersionId(null);
        const next = await sendNative<ListeningSongStatePayload>('listening.songState', {
          articleId: article.id,
        });
        setSongState(next);
        return;
      }
      await sendNative('listening.songPlay', { articleId: article.id, versionId });
      setPlayingSongVersionId(versionId);
      setSongState((current) => (current ? { ...current, status: 'playing' } : current));
    } catch (error) {
      onNotice(error instanceof Error ? error.message : '歌曲播放失败');
    } finally {
      setBusy(false);
    }
  };

  const deleteSongVersionFromCreation = async (
    versionId: string,
    title: string,
    timelineStatus: string,
  ) => {
    const deleteTimeline = timelineStatus === 'ready' || timelineStatus === 'stale';
    const message = deleteTimeline
      ? `确认删除歌曲「${title}」以及它的字幕时间轴？删除后不可恢复。`
      : `确认删除歌曲「${title}」？删除后不可恢复。`;
    if (!window.confirm(message)) {
      return;
    }
    setBusy(true);
    try {
      if (playingSongVersionId === versionId) {
        setPlayingSongVersionId(null);
      }
      const next = await sendNative<ListeningSongStatePayload>('listening.songDeleteVersion', {
        articleId: article.id,
        versionId,
      });
      setSongState(next);
      onNotice('已删除歌曲');
    } catch (error) {
      onNotice(error instanceof Error ? error.message : '歌曲删除失败');
    } finally {
      setBusy(false);
    }
  };

  const versions = songState?.versions?.filter((version) => version.id && version.audioPath) ?? [];
  const groupedVersions = groupSongVersionsForDisplay(versions);
  const waitingConfirm = isSunoWaitingConfirm(songState);
  // 检测下载：每次点击都进 Suno 扫描（含用户在外站用新风格 Create 后的补拉）。
  // 不因 downloadComplete / 本地已有版本隐藏或跳过；见 docs/suno_song_download_rules.md。
  const canDownloadMissing =
    songState?.source === 'suno' &&
    songState.status !== 'generating' &&
    !waitingConfirm;

  return (
    <section className="creation-panel">
      <div className="section-heading with-action">
        <span>歌曲生成</span>
        <button className="ghost-action small" type="button" onClick={loadState} disabled={busy}>
          <Icon name="refresh" /> 刷新状态
        </button>
      </div>
      {songState?.manualActionMessage && <p className="playback-cue">{songState.manualActionMessage}</p>}
      {songState?.status === 'generating' && songState.automationStatus && !songState.manualActionMessage && (
        <p className="playback-cue">{songAutomationStatusText(songState)}</p>
      )}
      {songState?.status === 'error' && songState.errorMessage && (
        <p className="playback-cue error">{songState.errorMessage}</p>
      )}
      <div className="button-row creation-actions">
        <button
          className="primary-action"
          type="button"
          disabled={busy || songState?.status === 'generating'}
          onClick={() => runSongCommand('listening.songGenerate', {
            source: 'bailian_fun_music',
            lyrics: '',
          }, '已提交阿里云百聆生成任务', {
            title: '正在提交百聆歌曲',
            detail: '正在向阿里云百聆 Fun-Music 提交歌曲生成，请等待服务返回。',
            timeoutSeconds: 480,
          })}
        >
          <Icon name="music" /> 生成百聆歌曲
        </button>
        <button
          className="suno-action"
          type="button"
          disabled={busy || songState?.status === 'generating'}
          onClick={() => runSongCommand('listening.songGenerate', {
            source: 'suno',
            lyrics: '',
          }, '已打开 Suno 歌曲生成流程')}
        >
          <Icon name="music" /> 生成 Suno 歌曲
        </button>
        {songState?.source === 'suno' && waitingConfirm && (
          <button
            className="primary-action"
            type="button"
            disabled={busy}
            onClick={() => {
              const confirmed = window.confirm('确认消耗 Suno credits 并创建歌曲？');
              if (confirmed) {
                void runSongCommand('listening.songConfirmSunoCreate', {}, '已确认创建 Suno 歌曲');
              }
            }}
          >
            <Icon name="music" /> 确认创建歌曲
          </button>
        )}
        {songState?.source === 'suno' && canDownloadMissing && (
          <button
            className="suno-download-action"
            type="button"
            disabled={busy}
            onClick={() => runSongCommand('listening.songDownloadSunoExisting', {}, '已开始检测并下载未保存版本')}
          >
            <Icon name="download" /> 检测下载
          </button>
        )}
        <button
          className="ghost-action"
          type="button"
          disabled={busy || songState?.status === 'generating'}
          onClick={() => void importExternalSong()}
        >
          <Icon name="folder" /> 导入本地音乐
        </button>
      </div>
      <div className="song-style-groups creation-song-groups">
        {groupedVersions.length === 0 ? (
          <p className="sentence-empty">还没有本地完整歌曲版本。</p>
        ) : groupedVersions.map((group) => (
          <div className="song-style-group" key={group.key}>
            <div className="song-style-group-heading">
              <span>版本</span>
              <b>{group.label}</b>
            </div>
            <div className="song-version-row">
              {group.versions.map((version, index) => {
                const timelineStatus = normalizeTimelineStatus(version.timelineStatus, version.timelinePath);
                const title = version.title?.trim() || `版本 ${index + 1}`;
                const isPlaying = playingSongVersionId === version.id;
                const timelineBlockedTitle =
                  timelineStatus === 'stale' ? '歌曲字幕时间线版本过旧，请重新生成字幕' : '请先生成歌曲字幕';
                return (
                  <div className="song-version-actions" key={version.id}>
                    <button
                      className={`icon-button small song-default-button ${version.isDefault ? 'active' : ''}`}
                      type="button"
                      disabled={busy}
                      aria-label={version.isDefault ? `${title} 已是默认播放歌曲` : `设为默认播放歌曲：${title}`}
                      title={version.isDefault ? '默认播放歌曲' : '设为默认播放歌曲'}
                      onClick={() => runSongCommand('listening.songSetDefault', { versionId: version.id }, '已设为默认播放歌曲')}
                    >
                      <Icon name="star" />
                    </button>
                    <button
                      className={`ghost-action small song-title-button ${isPlaying ? 'active' : ''}`}
                      type="button"
                      disabled={busy}
                      onClick={() => void playSongVersionFromCreation(version.id)}
                    >
                      {isPlaying && <Icon name="sound" />}
                      <span className="song-version-title">{title}{version.isDefault ? ' · 默认' : ''}</span>
                    </button>
                    <button
                      className="danger-light small song-delete-button"
                      type="button"
                      disabled={busy}
                      aria-label={`删除歌曲：${title}`}
                      title="删除歌曲"
                      onClick={() => void deleteSongVersionFromCreation(version.id, title, timelineStatus)}
                    >
                      <Icon name="trash" />
                    </button>
                    <button
                      className="ghost-action small"
                      type="button"
                      disabled={busy || timelineStatus === 'generating'}
                      onClick={() => runSongCommand(
                        'listening.songTimelineGenerate',
                        { versionId: version.id },
                        '已提交歌词时间轴生成',
                        {
                          title: '正在生成歌曲字幕',
                          detail: '正在识别歌曲音频并生成字幕时间轴，请等待服务返回。',
                          timeoutSeconds: 600,
                        },
                      )}
                    >
                      <Icon name={timelineStatus === 'generating' ? 'refresh' : 'sentence'} /> {songTimelineLabel(timelineStatus)}
                    </button>
                    <button
                      className="ghost-action small"
                      type="button"
                      disabled={busy || timelineStatus !== 'ready'}
                      title={timelineStatus === 'ready' ? '导出歌曲视频' : timelineBlockedTitle}
                      onClick={() => openSongRecordingDialog(version.id)}
                    >
                      <Icon name="recordVideo" /> 导出歌曲视频
                    </button>
                    <button
                      className="ghost-action small"
                      type="button"
                      disabled={busy || !version.audioPath?.trim()}
                      title="导出音频文件"
                      onClick={() => void exportSongAudioFromCreation(version.id)}
                    >
                      <Icon name="download" /> 导出音频文件
                    </button>
                  </div>
                );
              })}
            </div>
          </div>
        ))}
      </div>
      {recordingDialogDraft && (
        <RecordingSettingsDialog
          settings={recordingDialogDraft}
          saving={recordingDialogSaving}
          onChange={updateRecordingDialogDraft}
          onCancel={() => {
            if (recordingDialogSaving) return;
            setRecordingDialogDraft(null);
            setRecordingDialogVersionId('');
          }}
          onConfirm={() => void confirmSongRecordingDialog()}
        />
      )}
    </section>
  );
}

function VideoCreationPanel({
  article,
  recordingSettings,
  onRecordingSettingsLoaded,
  onNotice,
  onArticlesUpdated,
}: {
  article: Article;
  recordingSettings: RecordingSettings | null;
  onRecordingSettingsLoaded: (settings: RecordingSettings) => void;
  onNotice: (message: string) => void;
  onArticlesUpdated: (payload: { articles?: Article[]; series?: StorySeries[] }) => void;
}) {
  const [recordingReady, setRecordingReady] = useState<ListeningRecordingReadyPayload | null>(null);
  const [recordingReadyLoading, setRecordingReadyLoading] = useState(false);
  const [videoLibrary, setVideoLibrary] = useState<RecordingVideoLibraryPayload | null>(null);
  const [busy, setBusy] = useState(false);
  const [videoBusy, setVideoBusy] = useState(false);
  const [exportingListeningVideo, setExportingListeningVideo] = useState(false);
  const [recordingDialogDraft, setRecordingDialogDraft] = useState<RecordingSettings | null>(null);
  const [recordingDialogSaving, setRecordingDialogSaving] = useState(false);

  const checkReady = () => {
    const selectedSettings = recordingSettings ?? normalizeRecordingSettings({} as RecordingSettings);
    setRecordingReady(null);
    setRecordingReadyLoading(true);
    sendNative<ListeningRecordingReadyPayload>('listening.recordingReady', {
      articleId: article.id,
      codec: selectedSettings.codec,
      resolution: selectedSettings.resolution,
      pageTransition: selectedSettings.pageTransition,
      subtitleMode: selectedSettings.subtitleMode,
      fps: selectedSettings.fps || 25,
    })
      .then(setRecordingReady)
      .catch((error) => onNotice(error instanceof Error ? error.message : '视频准备状态检查失败'))
      .finally(() => setRecordingReadyLoading(false));
  };
  const {
    audioStatus,
    audioStatusLoading,
    audioGenerating,
    audioProgress,
    audioOverwriteConfirm,
    setAudioOverwriteConfirm,
    startListeningAudioGeneration,
    generateListeningAudio,
  } = useListeningAudioMaterial(article, onNotice, {
    onGenerated: () => checkReady(),
  });

  const loadVideoLibrary = async () => {
    setVideoBusy(true);
    try {
      const library = await sendNative<RecordingVideoLibraryPayload>('recording.videoList', {
        articleId: article.id,
      });
      setVideoLibrary(library);
    } catch (error) {
      onNotice(error instanceof Error ? error.message : '视频版本列表加载失败');
    } finally {
      setVideoBusy(false);
    }
  };

  useEffect(checkReady, [article.id, recordingSettings?.codec, recordingSettings?.resolution, recordingSettings?.pageTransition, recordingSettings?.subtitleMode, recordingSettings?.fps]);
  useEffect(() => {
    void loadVideoLibrary();
  }, [article.id]);

  const recordListeningVideo = async (selectedSettings: RecordingSettings) => {
    setBusy(true);
    setExportingListeningVideo(true);
    try {
      await sendNative<ListeningRecordingResultPayload>('listening.recordVideo', {
        articleId: article.id,
        codec: selectedSettings.codec,
        resolution: selectedSettings.resolution,
        pageTransition: selectedSettings.pageTransition,
        subtitleMode: selectedSettings.subtitleMode,
        fps: selectedSettings.fps || 25,
      });
      onNotice('听力视频导出完成');
      await loadVideoLibrary();
      onArticlesUpdated({});
    } catch (error) {
      onNotice(error instanceof Error ? error.message : '听力视频导出失败');
    } finally {
      setBusy(false);
      setExportingListeningVideo(false);
    }
  };

  const openRecordingDialog = () => {
    if (recordingReady && !recordingReady.ready) {
      onNotice(recordingReady.reasons?.[0] ?? '视频准备状态检查未通过');
      return;
    }
    setRecordingDialogDraft(recordingSettings ?? normalizeRecordingSettings({} as RecordingSettings));
  };

  const updateRecordingDialogDraft = (patch: Partial<RecordingSettings>) => {
    setRecordingDialogDraft((draft) => (draft ? { ...draft, ...patch } : draft));
  };

  const confirmRecordingDialog = async () => {
    if (!recordingDialogDraft || recordingDialogSaving) return;
    setRecordingDialogSaving(true);
    try {
      const savedSettings = await sendNative<RecordingSettings>('recording.settings.save', {
        codec: recordingDialogDraft.codec,
        resolution: recordingDialogDraft.resolution,
        pageTransition: recordingDialogDraft.pageTransition,
        subtitleMode: recordingDialogDraft.subtitleMode,
      });
      onRecordingSettingsLoaded(savedSettings);
      setRecordingDialogDraft(null);
      await recordListeningVideo(savedSettings);
    } catch (error) {
      onNotice(error instanceof Error ? error.message : '录制设置保存失败');
    } finally {
      setRecordingDialogSaving(false);
    }
  };

  const openVideoDirectory = async () => {
    setVideoBusy(true);
    try {
      await sendNative('recording.videoOpenDirectory', {
        articleId: article.id,
      });
      onNotice('已打开视频保存目录');
    } catch (error) {
      onNotice(error instanceof Error ? error.message : '视频保存目录打开失败');
    } finally {
      setVideoBusy(false);
    }
  };

  const playVideo = async (videoId: string) => {
    setVideoBusy(true);
    try {
      await sendNative('recording.videoPlay', {
        articleId: article.id,
        videoId,
      });
      onNotice('已调用系统播放器');
    } catch (error) {
      onNotice(error instanceof Error ? error.message : '视频播放失败');
    } finally {
      setVideoBusy(false);
    }
  };

  const setDefaultVideo = async (videoId: string) => {
    setVideoBusy(true);
    try {
      const library = await sendNative<RecordingVideoLibraryPayload>('recording.videoSetDefault', {
        articleId: article.id,
        videoId,
      });
      setVideoLibrary(library);
      onNotice('已设为默认播放视频');
    } catch (error) {
      onNotice(error instanceof Error ? error.message : '默认视频设置失败');
    } finally {
      setVideoBusy(false);
    }
  };

  const deleteVideo = async (version: RecordingVideoVersion, title: string) => {
    const confirmed = window.confirm(`确定删除视频“${title}”？此操作会删除本地视频文件和字幕文件，不能撤销。`);
    if (!confirmed) return;
    setVideoBusy(true);
    try {
      const library = await sendNative<RecordingVideoLibraryPayload>('recording.videoDelete', {
        articleId: article.id,
        videoId: version.id,
      });
      setVideoLibrary(library);
      onNotice('视频已删除');
      onArticlesUpdated({});
    } catch (error) {
      onNotice(error instanceof Error ? error.message : '视频删除失败');
    } finally {
      setVideoBusy(false);
    }
  };

  const videoVersions = videoLibrary?.versions?.filter((version) => version.id && version.videoPath) ?? [];

  return (
    <section className="creation-panel">
      <div className="section-heading with-action">
        <span>视频导出</span>
        <div className="section-heading-actions">
          <button
            className="ghost-action small"
            type="button"
            onClick={() => void generateListeningAudio()}
            disabled={audioGenerating || audioStatusLoading}
          >
            <Icon name={audioGenerating ? 'refresh' : 'sound'} />
            {audioGenerating ? '生成中' : '生成听力'}
          </button>
          <button className="ghost-action small" type="button" onClick={() => void openVideoDirectory()} disabled={videoBusy}>
            <Icon name="folder" /> 打开保存目录
          </button>
          <button className="ghost-action small" type="button" onClick={checkReady} disabled={recordingReadyLoading}>
            <Icon name="refresh" /> {recordingReadyLoading ? '检查中' : '检查准备状态'}
          </button>
        </div>
      </div>
      <div className="creation-resource-grid" aria-label="视频资源状态">
        <ResourceRow label="章节正文" value={`${article.sentenceCount} 句英文`} />
        <ResourceRow label="听力材料" value={audioMaterialStatusLabel(audioStatus, audioStatusLoading)} />
        <ResourceRow
          label="视频准备"
          value={recordingReadyLoading ? '检查中' : recordingReady?.ready ? '已就绪' : recordingReady ? '未就绪' : '未检查'}
        />
      </div>
      <div className="video-version-list" aria-label="已导出视频版本">
        <div className="song-style-group-heading">
          <span>已导出视频</span>
          <b>{videoBusy ? '刷新中' : `${videoVersions.length} 个版本`}</b>
        </div>
        {videoVersions.length === 0 ? (
          <p className="sentence-empty">还没有本地导出视频。</p>
        ) : (
          videoVersions.map((version, index) => {
            const title = recordingVideoTitle(version, index);
            return (
              <div className="video-version-actions" key={version.id}>
                <button
                  className={`icon-button small song-default-button ${version.isDefault ? 'active' : ''}`}
                  type="button"
                  disabled={videoBusy}
                  aria-label={version.isDefault ? `${title} 已是默认播放视频` : `设为默认播放视频：${title}`}
                  title={version.isDefault ? '默认播放视频' : '设为默认播放视频'}
                  onClick={() => void setDefaultVideo(version.id)}
                >
                  <Icon name="star" />
                </button>
                <button
                  className="ghost-action small"
                  type="button"
                  disabled={videoBusy}
                  aria-label={`播放视频：${title}`}
                  onClick={() => void playVideo(version.id)}
                >
                  <Icon name="play" />
                  <span className="song-version-title">{title}{version.isDefault ? ' · 默认' : ''}</span>
                </button>
                <button
                  className="danger-light small"
                  type="button"
                  disabled={videoBusy}
                  aria-label={`删除视频：${title}`}
                  onClick={() => void deleteVideo(version, title)}
                >
                  <Icon name="trash" /> 删除
                </button>
                <small>{recordingVideoMeta(version)}</small>
              </div>
            );
          })
        )}
      </div>
      <div className="button-row">
        <button className="primary-action" type="button" disabled={busy || exportingListeningVideo} onClick={openRecordingDialog}>
          <Icon name="recordVideo" /> 导出听力视频
        </button>
        <button className="ghost-action" type="button" disabled>
          <Icon name="recordVideo" /> 歌曲视频请在歌曲标签选择版本
        </button>
      </div>
      {exportingListeningVideo && (
        <AiBlockingOverlay
          title="正在导出听力视频"
          detail="正在渲染听力视频文件，请等待导出完成。"
          timeoutSeconds={900}
        />
      )}
      {audioOverwriteConfirm && (
        <AudioMaterialOverwriteConfirmDialog
          status={audioOverwriteConfirm}
          busy={audioGenerating}
          onCancel={() => setAudioOverwriteConfirm(null)}
          onConfirm={() => {
            const status = audioOverwriteConfirm;
            setAudioOverwriteConfirm(null);
            void startListeningAudioGeneration(status, true);
          }}
        />
      )}
      {audioGenerating && <AudioMaterialProgressDialog progress={audioProgress} />}
      {recordingDialogDraft && (
        <RecordingSettingsDialog
          settings={recordingDialogDraft}
          saving={recordingDialogSaving}
          onChange={updateRecordingDialogDraft}
          onCancel={() => {
            if (recordingDialogSaving) return;
            setRecordingDialogDraft(null);
          }}
          onConfirm={() => void confirmRecordingDialog()}
        />
      )}
    </section>
  );
}

function ResourceRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="resource-row">
      <span>{label}</span>
      <b>{value}</b>
    </div>
  );
}

function normalizeAudioMaterialStatus(payload: Partial<ListeningAudioMaterialStatus> | null | undefined, articleId: number): ListeningAudioMaterialStatus {
  const total = Number.isFinite(payload?.total) ? Number(payload?.total) : 0;
  const ready = Number.isFinite(payload?.ready) ? Number(payload?.ready) : 0;
  const failed = Number.isFinite(payload?.failed) ? Number(payload?.failed) : 0;
  const missing = Array.isArray(payload?.missing)
    ? payload!.missing.map((item) => Number(item)).filter((item) => Number.isFinite(item))
    : [];
  return {
    articleId: Number.isFinite(payload?.articleId) ? Number(payload?.articleId) : articleId,
    total,
    ready,
    missing,
    failed,
    status: typeof payload?.status === 'string' ? payload.status : total > 0 && ready >= total && missing.length === 0 ? 'ready' : 'missing',
    requested: Number.isFinite(payload?.requested) ? Number(payload?.requested) : undefined,
    overwrite: typeof payload?.overwrite === 'boolean' ? payload.overwrite : undefined,
  };
}

function audioMaterialStatusLabel(status: ListeningAudioMaterialStatus | null, loading: boolean) {
  if (loading && !status) return '读取中';
  if (!status) return '未检查';
  if (status.total <= 0) return '无英文句子';
  const suffix = status.missing.length > 0 ? ` · 缺 ${status.missing.length} 句` : '';
  return `${status.ready} / ${status.total} 已生成${suffix}`;
}

function AudioMaterialOverwriteConfirmDialog({
  status,
  busy,
  onCancel,
  onConfirm,
}: {
  status: ListeningAudioMaterialStatus;
  busy: boolean;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  return (
    <ConfirmDialog
      ariaLabel="覆盖听力材料确认"
      title="覆盖听力材料"
      subtitle="远程语音合成将重新提交"
      message={`听力材料已经生成 ${status.ready} / ${status.total}。是否覆盖原内容并重新提交远程语音合成？`}
      confirmLabel="覆盖生成"
      confirmIcon="sound"
      busy={busy}
      onCancel={onCancel}
      onConfirm={onConfirm}
    />
  );
}

function ConfirmDialog({
  ariaLabel,
  title,
  subtitle,
  message,
  confirmLabel = '确定',
  cancelLabel = '取消',
  confirmIcon,
  busy = false,
  onCancel,
  onConfirm,
}: {
  ariaLabel: string;
  title: string;
  subtitle?: string;
  message: string;
  confirmLabel?: string;
  cancelLabel?: string;
  confirmIcon?: string;
  busy?: boolean;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  return createPortal(
    <div className="edit-dialog-backdrop confirm-dialog-backdrop" role="presentation">
      <section
        className="edit-dialog confirm-dialog"
        role="dialog"
        aria-modal="true"
        aria-label={ariaLabel}
        onMouseDown={(event) => event.stopPropagation()}
      >
        <div className="edit-dialog-heading">
          <b>{title}</b>
          {subtitle ? <small>{subtitle}</small> : null}
        </div>
        <p>{message}</p>
        <div className="edit-dialog-actions">
          <button className="ghost-action" type="button" onClick={onCancel} disabled={busy}>
            {cancelLabel}
          </button>
          <button className="primary-action" type="button" onClick={onConfirm} disabled={busy}>
            {confirmIcon ? <Icon name={busy ? 'refresh' : confirmIcon} /> : null}
            {confirmLabel}
          </button>
        </div>
      </section>
    </div>,
    document.body,
  );
}

function AudioMaterialProgressDialog({ progress }: { progress: ListeningAudioMaterialProgress | null }) {
  const completed = progress?.completed ?? 0;
  const total = progress?.total ?? 0;
  const value = total > 0 ? (completed / total) * 100 : 0;
  const label = total > 0
    ? `正在提交远程语音合成 ${Math.min(completed, total)} / ${total}`
    : '正在确认听力材料状态';

  return createPortal(
    <div className="audio-material-progress-overlay" role="presentation">
      <section className="audio-material-progress-panel" role="dialog" aria-modal="true" aria-label="正在生成听力材料">
        <div className="audio-material-progress-heading">
          <b>正在生成听力材料</b>
          <small>生成期间已禁止页面操作，请等待完成</small>
        </div>
        <ProgressLine value={value} label={label} />
        {progress?.failed ? <p className="edit-dialog-error">{progress.failed} 句生成失败</p> : null}
      </section>
    </div>,
    document.body,
  );
}

function promptRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function promptText(value: unknown): string {
  return typeof value === 'string' ? value.replace(/\s+/g, ' ').trim() : '';
}

function pictureBookPageScenePreview(page: PictureBookPage): { sceneDescription: string } {
  const prompt = promptRecord(page.prompt);
  const scene = promptRecord(prompt?.scene);
  return {
    sceneDescription: promptText(scene?.sceneDescription),
  };
}

function pictureBookStatusLabel(status?: string | null): string {
  switch (status) {
    case 'loading':
      return '读取中';
    case 'empty':
      return '未生成';
    case 'queued':
      return '排队中';
    case 'generating':
      return '生成中';
    case 'ready':
      return '已完成';
    case 'partial':
      return '部分完成';
    case 'skipped':
      return '已跳过';
    case 'error':
      return '有错误';
    default:
      return status?.trim() || '未知';
  }
}

type BookGroup = {
  key: string;
  seriesId?: number;
  title: string;
  description?: string;
  characters: BookCharacter[];
  articles: Article[];
  sentenceCount: number;
  averageScore: number;
  coverImagePath?: string | null;
};

function bookGroupsForArticles(articles: Article[], series: StorySeries[]): BookGroup[] {
  const groups = new Map<string, BookGroup>();

  for (const item of series) {
    groups.set(`series:${item.id}`, {
      key: `series:${item.id}`,
      seriesId: item.id,
      title: item.title,
      description: item.description ?? '',
      characters: normalizeBookCharacters(item.characters),
      articles: [],
      sentenceCount: 0,
      averageScore: 0,
      coverImagePath: item.coverImagePath,
    });
  }

  for (const article of articles) {
    const seriesTitle = article.seriesTitle?.trim() ?? '';
    const key =
      article.seriesId != null
        ? `series:${article.seriesId}`
        : seriesTitle
          ? `title:${seriesTitle.toLowerCase()}`
          : `article:${article.id}`;
    const fallbackTitle = seriesTitle || article.title || '未归档书籍';
    if (!groups.has(key)) {
      groups.set(key, {
        key,
        title: fallbackTitle,
        description: article.seriesDescription ?? '',
        characters: [],
        articles: [],
        sentenceCount: 0,
        averageScore: 0,
      });
    }
    groups.get(key)?.articles.push(article);
  }

  return Array.from(groups.values())
    .map((group) => {
      const sentenceCount = group.articles.reduce((sum, article) => sum + article.sentenceCount, 0);
      const averageScore =
        group.articles.length === 0
          ? 0
          : Math.round(group.articles.reduce((sum, article) => sum + article.averageScore, 0) / group.articles.length);
      return {
        ...group,
        sentenceCount,
        averageScore,
      };
    })
    .sort((a, b) => latestArticleTime(b.articles) - latestArticleTime(a.articles));
}

function bookKeyForArticle(article?: Article | null): string | null {
  if (!article) return null;
  const seriesTitle = article.seriesTitle?.trim() ?? '';
  if (article.seriesId != null) return `series:${article.seriesId}`;
  if (seriesTitle) return `title:${seriesTitle.toLowerCase()}`;
  return `article:${article.id}`;
}

function preferredHomeBookKey(
  books: BookGroup[],
  recentBookKey: string | null,
  latestArticle?: Article,
): string | null {
  if (recentBookKey && books.some((book) => book.key === recentBookKey)) {
    return recentBookKey;
  }
  const latestKey = bookKeyForArticle(latestArticle);
  if (latestKey && books.some((book) => book.key === latestKey)) {
    return latestKey;
  }
  return books[0]?.key ?? null;
}

function sortBookChapters(articles: Article[], order: ChapterOrder): Article[] {
  const sorted = [...articles].sort((a, b) =>
    a.title.localeCompare(b.title, undefined, { numeric: true, sensitivity: 'base' }),
  );
  return order === 'asc' ? sorted : sorted.reverse();
}

function latestArticleTime(articles: Article[]): number {
  return Math.max(
    0,
    ...articles.map((article) => {
      const time = Date.parse(article.createdAt);
      return Number.isFinite(time) ? time : 0;
    }),
  );
}

function chapterDescriptionForArticle(article: Article): string {
  return article.chapterDescription?.replace(/\s+/g, ' ').trim() ?? '';
}

function formatArticleFullText(payload: ArticleFullTextPayload): string {
  const bookTitle = payload.bookTitle?.trim() || payload.article.seriesTitle?.trim() || payload.article.title.trim();
  const chapterTitle = payload.article.title.trim();
  const lines: string[] = [bookTitle];
  if (chapterTitle && chapterTitle !== bookTitle) {
    lines.push(chapterTitle);
  }
  lines.push('');
  payload.items.forEach((item) => {
    if (isHiddenListeningItem(item)) return;
    const english = item.english.trim();
    const chinese = item.chinese.trim();
    if (!english && !chinese) return;
    if (english) {
      lines.push(english);
    }
    if (chinese) {
      lines.push(chinese);
    }
    lines.push('');
  });
  return lines.join('\n').trim();
}

async function writeTextToClipboard(text: string): Promise<void> {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text);
    return;
  }
  const textarea = document.createElement('textarea');
  textarea.value = text;
  textarea.setAttribute('readonly', 'true');
  textarea.style.position = 'fixed';
  textarea.style.left = '-9999px';
  document.body.appendChild(textarea);
  textarea.select();
  const copied = document.execCommand('copy');
  textarea.remove();
  if (!copied) {
    throw new Error('复制到剪贴板失败');
  }
}

async function copyArticleFullText(payload: ArticleFullTextPayload): Promise<void> {
  const text = formatArticleFullText(payload);
  if (!text) {
    throw new Error('没有可复制的文章内容');
  }
  await writeTextToClipboard(text);
}

function bookCoverSource(book: BookGroup, index: number): string {
  const firstGenerated = book.articles.find(
    (article) => directImageSource(article.coverImageUri) || directImageSource(article.coverImagePath),
  );
  if (firstGenerated) return articleCoverSource(firstGenerated, index);
  const seriesCover = directImageSource(book.coverImagePath);
  if (seriesCover) return seriesCover;
  if (book.articles.length === 0) return asset(fallbackCards[index % fallbackCards.length]);
  return articleCoverSource(book.articles[0], index);
}

function ArticlePage({
  series,
  onSeriesUpdated,
  onCancel,
  onSaved,
}: {
  series: StorySeries[];
  onSeriesUpdated: (series: StorySeries[]) => void;
  onCancel: () => void;
  onSaved: (payload: { article: Article; articles: Article[]; series?: StorySeries[] }) => void;
}) {
  const [title, setTitle] = useState('');
  const [content, setContent] = useState('');
  const [selectedSeriesId, setSelectedSeriesId] = useState<string>(() => 'new');
  const [newSeriesTitle, setNewSeriesTitle] = useState('');
  const [seriesDescription, setSeriesDescription] = useState('');
  const [seriesCharacters, setSeriesCharacters] = useState<BookCharacter[]>([]);
  const [bookInfoExpanded, setBookInfoExpanded] = useState(false);
  const [generatingSeriesDescription, setGeneratingSeriesDescription] = useState(false);
  const [savingSeries, setSavingSeries] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const sentences = useMemo(() => splitSentences(content), [content]);
  const contentTooLong = content.length > ARTICLE_CONTENT_MAX_CHARS;
  const creatingNewSeries = selectedSeriesId === 'new' || series.length === 0;
  const newSeriesTitleReady = !creatingNewSeries || Boolean(newSeriesTitle.trim());
  const canSave =
    Boolean(content.trim()) &&
    newSeriesTitleReady &&
    !contentTooLong &&
    !saving &&
    !savingSeries &&
    !generatingSeriesDescription;
  const seriesDescriptionSeed = newSeriesTitle.trim();
  const canGenerateSeriesDescription =
    creatingNewSeries &&
    Boolean(seriesDescriptionSeed) &&
    !contentTooLong &&
    !saving &&
    !savingSeries &&
    !generatingSeriesDescription;
  const canSaveSeries =
    creatingNewSeries &&
    Boolean(newSeriesTitle.trim()) &&
    !saving &&
    !savingSeries &&
    !generatingSeriesDescription;
  const selectedSeries = useMemo(
    () => series.find((item) => String(item.id) === selectedSeriesId) ?? null,
    [selectedSeriesId, series],
  );
  const currentBookTitle = creatingNewSeries
    ? newSeriesTitle.trim() || '新建书籍'
    : selectedSeries?.title?.trim() || '书籍信息';

  useEffect(() => {
    let isMounted = true;
    sendNative<{ series: StorySeries[] }>('series.list')
      .then((payload) => {
        if (isMounted) {
          onSeriesUpdated(payload.series);
          if (payload.series.length > 0) {
            setSelectedSeriesId((current) => (current === 'new' ? String(payload.series[0].id) : current));
          }
        }
      })
      .catch(() => undefined);
    return () => {
      isMounted = false;
    };
  }, [onSeriesUpdated]);

  useEffect(() => {
    if (selectedSeriesId === 'new') {
      return;
    }
    setSeriesDescription(selectedSeries?.description ?? '');
    setSeriesCharacters(editableBookCharacters(selectedSeries?.characters));
  }, [selectedSeries, selectedSeriesId]);

  const importFile = async (file: File | undefined) => {
    if (!file) return;
    if (!file.type.startsWith('text/') && !/\.(txt|md|markdown)$/i.test(file.name)) {
      setError('请导入 txt 或 markdown 文本文件');
      return;
    }
    const text = await file.text();
    const cleaned = text.trim();
    if (!cleaned) {
      setError('这个文件没有可导入的文字内容');
      return;
    }
    if (cleaned.length > ARTICLE_CONTENT_MAX_CHARS) {
      setError(`文章内容不能超过 ${ARTICLE_CONTENT_MAX_CHARS} 个字符`);
      return;
    }
    setContent(cleaned);
    setError(null);
  };

  const generateSeriesDescription = async () => {
    if (!newSeriesTitle.trim()) {
      setError('请先填写书籍名称');
      return;
    }
    if (contentTooLong) {
      setError(`文章内容不能超过 ${ARTICLE_CONTENT_MAX_CHARS} 个字符`);
      return;
    }
    setGeneratingSeriesDescription(true);
    setError(null);
    try {
      const descriptionSeedTitle = newSeriesTitle.trim();
      const descriptionContent = content.trim()
        ? content
        : `Book title: ${descriptionSeedTitle}. Generate a concise book-level visual description for this picture-book series.`;
      const payload = await sendNative<{ description: string; characters?: BookCharacter[] }>('series.suggestDescription', {
        seriesTitle: newSeriesTitle.trim(),
        articleTitle: title.trim(),
        content: descriptionContent,
        description: seriesDescription.trim(),
        characters: normalizeBookCharacters(seriesCharacters),
      });
      setSeriesDescription(payload.description ?? '');
      if (payload.characters) {
        setSeriesCharacters(editableBookCharacters(payload.characters));
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setGeneratingSeriesDescription(false);
    }
  };

  const saveSeries = async () => {
    const trimmedTitle = newSeriesTitle.trim();
    if (!trimmedTitle) {
      setError('请填写书籍名称');
      return;
    }
    setSavingSeries(true);
    setError(null);
    try {
      const payload = await sendNative<{ series?: StorySeries[] }>('series.create', {
        title: trimmedTitle,
        description: seriesDescription.trim(),
        characters: normalizeBookCharacters(seriesCharacters),
      });
      const nextSeries = payload.series ?? [];
      onSeriesUpdated(nextSeries);
      const savedSeries =
        nextSeries.find((item) => item.title.trim().toLowerCase() === trimmedTitle.toLowerCase()) ?? nextSeries[0];
      if (savedSeries?.id != null) {
        setSelectedSeriesId(String(savedSeries.id));
        setNewSeriesTitle('');
        setSeriesDescription(savedSeries.description ?? seriesDescription.trim());
        setSeriesCharacters(editableBookCharacters(savedSeries.characters ?? seriesCharacters));
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setSavingSeries(false);
    }
  };

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (!content.trim()) {
      setError('请先填写文章内容');
      return;
    }
    if (contentTooLong) {
      setError(`文章内容不能超过 ${ARTICLE_CONTENT_MAX_CHARS} 个字符`);
      return;
    }
    if (creatingNewSeries && !newSeriesTitle.trim()) {
      setError('请填写书籍名称');
      return;
    }

    setSaving(true);
    setError(null);
    try {
      const resolvedSeriesId =
        selectedSeriesId !== 'new'
          ? Number(selectedSeriesId)
          : undefined;
      const resolvedSeriesTitle =
        selectedSeriesId === 'new'
          ? newSeriesTitle.trim()
          : '';
      const payload = await sendNative<{ article: Article; articles: Article[]; series?: StorySeries[] }>(
        'article.create',
        {
          title: title.trim(),
          content,
          pictureBookEnabled: true,
          seriesId: resolvedSeriesId,
          seriesTitle: resolvedSeriesTitle,
          seriesDescription: seriesDescription.trim(),
          seriesCharacters: normalizeBookCharacters(seriesCharacters),
        },
      );
      onSaved(payload);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setSaving(false);
    }
  };

  return (
    <section className="page article-page">
      <TopBar title="新增文章" onBack={onCancel}>
        <button className="ghost-action" type="button" onClick={() => fileInputRef.current?.click()}>
          <Icon name="upload" /> 导入文件
        </button>
        <input
          ref={fileInputRef}
          className="visually-hidden"
          type="file"
          accept=".txt,.md,.markdown,text/plain,text/markdown"
          onChange={(event) => {
            void importFile(event.target.files?.[0]);
            event.target.value = '';
          }}
        />
      </TopBar>

      <form className="article-editor" onSubmit={submit}>
        <div className="article-form">
          <section className="book-picker-panel" aria-label="书籍设置">
            <div className="series-picker">
              <label htmlFor="series-select">书籍</label>
              <select
                id="series-select"
                value={series.length === 0 ? 'new' : selectedSeriesId}
                onChange={(event) => {
                  const next = event.target.value;
                  setSelectedSeriesId(next);
                  if (next === 'new') {
                    setSeriesDescription('');
                    setSeriesCharacters([]);
                  } else {
                    const nextSeries = series.find((item) => String(item.id) === next);
                    setSeriesDescription(nextSeries?.description ?? '');
                    setSeriesCharacters(editableBookCharacters(nextSeries?.characters));
                  }
                }}
              >
                {series.map((item) => (
                  <option value={String(item.id)} key={item.id}>
                    {item.title}
                  </option>
                ))}
                <option value="new">新建书籍</option>
              </select>
              {creatingNewSeries && (
                <input
                  aria-label="新书籍名称"
                  value={newSeriesTitle}
                  maxLength={80}
                  placeholder="例如 The Secret Garden"
                  onChange={(event) => setNewSeriesTitle(event.target.value)}
                />
              )}
              <button
                className={`collapsible-heading book-info-toggle ${bookInfoExpanded ? 'expanded' : ''}`}
                type="button"
                aria-expanded={bookInfoExpanded}
                onClick={() => setBookInfoExpanded((expanded) => !expanded)}
              >
                <Icon name="chevron" />
                <span>{currentBookTitle}</span>
              </button>
              {bookInfoExpanded && (
                <div className="book-info-collapsible">
                  <div className="field-label-row">
                    <label htmlFor="series-description">书籍简介</label>
                    {creatingNewSeries && (
                      <button
                        className="icon-button small prompt-magic-button"
                        type="button"
                        aria-label="AI 自动生成新书籍简介"
                        title="AI 自动生成新书籍简介"
                        disabled={!canGenerateSeriesDescription}
                        onClick={() => void generateSeriesDescription()}
                      >
                        <Icon name={generatingSeriesDescription ? 'refresh' : 'wand'} />
                        <span>{generatingSeriesDescription ? '生成中' : '自动生成'}</span>
                      </button>
                    )}
                  </div>
                  <textarea
                    id="series-description"
                    aria-label="书籍简介"
                    value={seriesDescription}
                    rows={4}
                    placeholder="可写时代、整体画风和视觉世界；角色外貌请放在角色列表里。"
                    onChange={(event) => setSeriesDescription(event.target.value)}
                  />
                  <BookCharacterEditor
                    label="书籍角色"
                    characters={seriesCharacters}
                    onChange={setSeriesCharacters}
                    disabled={saving || savingSeries || generatingSeriesDescription}
                  />
                </div>
              )}
              {creatingNewSeries && (
                <div className="series-save-row">
                  <button
                    className="ghost-action small"
                    type="button"
                    disabled={!canSaveSeries}
                    onClick={() => void saveSeries()}
                  >
                    <Icon name="save" /> {savingSeries ? '保存中' : '保存书籍'}
                  </button>
                </div>
              )}
            </div>
            <small>保存后会先审核绘本提示词，确认后再生成组图。</small>
          </section>

          <div className="article-field title-field">
            <div className="field-label-row">
              <label htmlFor="article-title">文章标题</label>
            </div>
            <input
              id="article-title"
              value={title}
              maxLength={80}
              placeholder="不填则自动生成短标题"
              onChange={(event) => {
                setTitle(event.target.value);
                setError(null);
              }}
            />
            <small>{title.length}/80</small>
          </div>
          <div className="article-field">
            <label htmlFor="article-content">文章内容</label>
            <textarea
              id="article-content"
              value={content}
              placeholder={sampleText}
              onChange={(event) => {
                const nextContent = event.target.value;
                setContent(nextContent);
                setError(
                  nextContent.length > ARTICLE_CONTENT_MAX_CHARS
                    ? `文章内容不能超过 ${ARTICLE_CONTENT_MAX_CHARS} 个字符`
                    : null,
                );
              }}
            />
            <small>{content.length}/{ARTICLE_CONTENT_MAX_CHARS}</small>
          </div>
        </div>

        <section className="sentence-board">
          <div className="section-heading">
            <span>句子预览（本地分句）</span>
          </div>
          {sentences.length > 0 ? (
            <div className="sentence-grid">
              {sentences.map((sentence, index) => (
              <div className="sentence-pill" key={`${sentence}-${index}`}>
                <b>{index + 1}</b>
                <span>{sentence}</span>
                <Icon name="drag" />
              </div>
              ))}
            </div>
          ) : (
            <p className="sentence-empty">输入短文后，这里会自动切成适合跟读的英文短句。</p>
          )}
        </section>

        <footer className="form-footer">
          {error && <span className="error-text">{error}</span>}
          <button type="button" className="ghost-action" onClick={onCancel}>
            取消
          </button>
          <button className="primary-action" disabled={!canSave}>
            <Icon name="save" /> {saving ? '保存中' : '保存章节'}
          </button>
        </footer>
      </form>
      {generatingSeriesDescription && (
        <AiBlockingOverlay
          title="正在生成书籍简介"
          detail="AI 正在根据书名、章节标题或正文生成书籍级视觉简介。"
          timeoutSeconds={90}
        />
      )}
      {savingSeries && (
        <AiBlockingOverlay
          title="正在保存书籍"
          detail="正在写入书籍简介和角色列表。"
          timeoutSeconds={45}
        />
      )}
      {saving && (
        <AiBlockingOverlay
          title="正在保存并处理章节"
          detail="正在解析正文、生成必要的标题或英文内容，并写入书库。"
          timeoutSeconds={180}
        />
      )}
    </section>
  );
}

type ListeningStatus = 'loading' | 'ready' | 'playing' | 'stopping' | 'done' | 'error';
type ListeningPart = 'english' | 'chinese' | null;
type SongGenerationSource = Exclude<SongSource, 'external_audio'>;
type WordCardState = {
  word: string;
  sentence: string;
  resumeBackground: boolean;
  loading: boolean;
  playing: boolean;
  position: WordCardPosition;
  lookup?: WordLookupPayload;
  error?: string | null;
};
type SentenceEditState = {
  item: ListeningItem;
  english: string;
  chinese: string;
  saving: boolean;
  error: string | null;
  confirmingHide?: boolean;
};
type SongDialogTab = 'play' | 'settings';
type SongDialogState = {
  activeTab: SongDialogTab;
  source: SongGenerationSource;
  suggesting: boolean;
  submitting: boolean;
  error: string | null;
};
type SongVersionPayload = NonNullable<ListeningSongStatePayload['versions']>[number];
type SongVersionGroup = {
  key: string;
  label: string;
  versions: SongVersionPayload[];
};
type PictureBookDecodeState = {
  total: number;
  decoded: number;
  failed: number;
  pending: number;
  ready: boolean;
  missingImagePages: number[];
};
type FullscreenReadiness = {
  ready: boolean;
  reason: string;
};
type WordCardPosition = {
  top: number;
  left: number;
  placement: 'above' | 'below';
};
type FollowControl = 'source' | 'record' | 'recording';

function ListeningPage({
  articleId,
  mode = 'listening',
  bookTitle,
  chapterLabel,
  onPrevChapter,
  onNextChapter,
  onSwitchMode,
  chapterDrawerOpen = false,
  onOpenChapterDrawer,
  pictureBookState,
  onNavigate,
  onPictureBookLoaded,
  pictureBookRetryGate,
  onOpenPicturePromptReview,
  englishPreloadState,
  recordingSettings,
  onRecordingSettingsLoaded,
  songSettings,
  onNotice,
  onArticlesUpdated,
}: {
  articleId: number;
  mode?: PlayerMode;
  bookTitle?: string;
  chapterLabel?: string;
  onPrevChapter?: () => void;
  onNextChapter?: () => void;
  onSwitchMode?: (mode: PlayerMode) => void;
  chapterDrawerOpen?: boolean;
  onOpenChapterDrawer?: () => void;
  pictureBookState: PictureBookState | null;
  onNavigate: (path: string) => void;
  onPictureBookLoaded: PictureBookStateSetter;
  pictureBookRetryGate: PictureBookRetryGate;
  onOpenPicturePromptReview: (articleId: number, regenerate?: boolean) => void | Promise<void>;
  englishPreloadState?: PreloadState;
  recordingSettings: RecordingSettings | null;
  onRecordingSettingsLoaded: (settings: RecordingSettings) => void;
  songSettings: SettingsState['song'] | null;
  onNotice: (message: string) => void;
  onArticlesUpdated: (payload: { articles?: Article[]; series?: StorySeries[] }) => void;
}) {
  const [article, setArticle] = useState<Article | null>(null);
  const [items, setItems] = useState<ListeningItem[]>([]);
  const [status, setStatus] = useState<ListeningStatus>('loading');
  const [currentIndex, setCurrentIndex] = useState(0);
  const [activePart, setActivePart] = useState<ListeningPart>(null);
  const [error, setError] = useState<string | null>(null);
  const [wordCard, setWordCard] = useState<WordCardState | null>(null);
  const [sentenceEdit, setSentenceEdit] = useState<SentenceEditState | null>(null);
  const [sentenceSynthesisErrors, setSentenceSynthesisErrors] = useState<Record<number, string>>({});
  const [retryingSynthesisIndex, setRetryingSynthesisIndex] = useState<number | null>(null);
  const [fullscreenReady, setFullscreenReady] = useState<ListeningFullscreenReadyPayload | null>(null);
  const [fullscreenReadyLoading, setFullscreenReadyLoading] = useState(false);
  const [fullscreenPlayerOpen, setFullscreenPlayerOpen] = useState(false);
  const [songFullscreenPlayerOpen, setSongFullscreenPlayerOpen] = useState(false);
  const [songFullscreenStartIndex, setSongFullscreenStartIndex] = useState(0);
  const [recordingReady, setRecordingReady] = useState<ListeningRecordingReadyPayload | null>(null);
  const [recordingReadyLoading, setRecordingReadyLoading] = useState(false);
  const [recordingProgress, setRecordingProgress] = useState<ListeningRecordingProgressPayload | null>(null);
  const [recordingResult, setRecordingResult] = useState<ListeningRecordingResultPayload | null>(null);
  const [recordingError, setRecordingError] = useState<string | null>(null);
  const [recordingBusy, setRecordingBusy] = useState(false);
  const [recordingDialogDraft, setRecordingDialogDraft] = useState<RecordingSettings | null>(null);
  const [recordingDialogSaving, setRecordingDialogSaving] = useState(false);
  const [recordingDialogSongVersionId, setRecordingDialogSongVersionId] = useState('');
  const [songState, setSongState] = useState<ListeningSongStatePayload | null>(null);
  const [songCue, setSongCue] = useState<ListeningSongPositionPayload['cue']>(null);
  const [songDialog, setSongDialog] = useState<SongDialogState | null>(null);
  const [selectedSongVersionId, setSelectedSongVersionId] = useState('');
  const playbackTokenRef = useRef(0);
  const wordCardTokenRef = useRef(0);
  const fullscreenReadyTokenRef = useRef(0);
  const recordingReadyTokenRef = useRef(0);
  const manualTranslationIndexesRef = useRef<Set<number>>(new Set());
  const pictureBookRecordingReadinessKey = useMemo(() => {
    if (pictureBookState?.articleId !== articleId) return 'none';
    return [
      pictureBookState.status,
      pictureBookState.pages.length,
      pictureBookState.pages
        .map((page) => `${page.pageIndex}:${page.status}:${page.imagePath?.trim() ? 1 : 0}`)
        .join('|'),
    ].join(':');
  }, [articleId, pictureBookState]);

  useEffect(() => {
    let isMounted = true;
    playbackTokenRef.current += 1;
    setArticle(null);
    setItems([]);
    setStatus('loading');
    setCurrentIndex(0);
    setActivePart(null);
    setError(null);
    setWordCard(null);
    setSentenceEdit(null);
    setSentenceSynthesisErrors({});
    setRetryingSynthesisIndex(null);
    setFullscreenReady(null);
    setFullscreenReadyLoading(false);
    setFullscreenPlayerOpen(false);
    setSongFullscreenPlayerOpen(false);
    setRecordingReady(null);
    setRecordingReadyLoading(false);
    setRecordingProgress(null);
    setRecordingResult(null);
    setRecordingError(null);
    setRecordingBusy(false);
    setRecordingDialogDraft(null);
    setRecordingDialogSaving(false);
    setRecordingDialogSongVersionId('');
    setSongState(null);
    setSongCue(null);
    setSongDialog(null);
    setSelectedSongVersionId('');
    wordCardTokenRef.current += 1;
    fullscreenReadyTokenRef.current += 1;
    recordingReadyTokenRef.current += 1;
    manualTranslationIndexesRef.current = new Set();
    onPictureBookLoaded(loadingPictureBookState(articleId));

    const picturePromise = sendNative<PictureBookState>('pictureBook.state', { articleId, includeImageUris: false })
      .then((picturePayload) => {
        if (isMounted) {
          onPictureBookLoaded((current) => mergePictureBookState(current, picturePayload));
        }
      })
      .catch(() => undefined);

    const listeningPromise = sendNative<ListeningOpenPayload>('listening.open', { articleId })
      .then((payload) => {
        if (!isMounted) return;
        setArticle(payload.article);
        setItems(payload.items);
        const visibleCount = visibleSentenceCountFromItems(payload.items);
        setCurrentIndex(firstVisibleSlotIndex(payload.items) ?? 0);
        setStatus(visibleCount > 0 ? 'ready' : 'error');
        if (visibleCount === 0) {
          setError('这篇文章还没有可朗读的英文句子。');
        }
      })
      .catch((loadError) => {
        if (!isMounted) return;
        setStatus('error');
        setError(loadError instanceof Error ? loadError.message : '听力任务打开失败');
      });

    void Promise.allSettled([listeningPromise, picturePromise]);

    return () => {
      isMounted = false;
      playbackTokenRef.current += 1;
      wordCardTokenRef.current += 1;
      void sendNative('listening.stop').catch(() => undefined);
      void sendNative('listening.songStop').catch(() => undefined);
      void sendNative('listening.cancelRecording').catch(() => undefined);
      void sendNative('word.stop').catch(() => undefined);
    };
  }, [articleId, onPictureBookLoaded]);

  useEffect(() => {
    if (mode !== 'song') return;
    let isMounted = true;
    sendNative<ListeningSongStatePayload>('listening.songState', { articleId })
      .then((payload) => {
        if (isMounted) {
          setSongState(payload);
        }
      })
      .catch((loadError) => {
        if (!isMounted) return;
        setSongState({
          articleId,
          status: 'error',
          source: 'suno',
          audioPath: null,
          errorMessage: loadError instanceof Error ? loadError.message : '本地歌曲状态读取失败',
        });
      });
    return () => {
      isMounted = false;
    };
  }, [articleId, mode]);

  useEffect(() => {
    return onNativeEvent<ListeningTranslationsPayload>('listening.translations', (payload) => {
      if (payload.articleId !== articleId) return;
      const translationMap = new Map(
        payload.translations
          .filter((item) => item.chinese.trim())
          .map((item) => [item.index, item.chinese.trim()]),
      );
      if (translationMap.size === 0) return;

      setItems((currentItems) =>
        currentItems.map((item) => {
          if (manualTranslationIndexesRef.current.has(item.index)) {
            return item;
          }
          const translated = translationMap.get(item.index);
          return translated ? { ...item, chinese: translated } : item;
        }),
      );
    });
  }, [articleId]);

  useEffect(() => {
    if (recordingSettings) return;
    let isMounted = true;
    sendNative<RecordingSettings>('recording.settings.load')
      .then((payload) => {
        if (!isMounted) return;
        onRecordingSettingsLoaded(payload);
      })
      .catch(() => undefined);
    return () => {
      isMounted = false;
    };
  }, [onRecordingSettingsLoaded, recordingSettings]);

  useEffect(() => {
    const offProgress = onNativeEvent<ListeningRecordingProgressPayload>('listening.recording.progress', (payload) => {
      if (payload.articleId !== articleId) return;
      setRecordingProgress(payload);
      setRecordingBusy(payload.phase !== 'completed');
    });
    const offCompleted = onNativeEvent<ListeningRecordingResultPayload>('listening.recording.completed', (payload) => {
      if (payload.articleId !== articleId) return;
      setRecordingResult(payload);
      setRecordingProgress(null);
      setRecordingBusy(false);
      setRecordingError(null);
    });
    const offError = onNativeEvent<{ articleId: number; message: string }>('listening.recording.error', (payload) => {
      if (payload.articleId !== articleId) return;
      setRecordingBusy(false);
      setRecordingError(payload.message || '录制视频失败');
    });
    return () => {
      offProgress();
      offCompleted();
      offError();
    };
  }, [articleId]);

  useEffect(() => {
    return onNativeEvent<ListeningSongStatePayload>('listening.song.state', (payload) => {
      if (payload.articleId !== articleId) return;
      setSongState((current) => {
        if (
          current?.status === 'playing' &&
          payload.status !== 'playing' &&
          payload.status !== 'empty' &&
          payload.status !== 'error'
        ) {
          return { ...payload, status: 'playing' };
        }
        return payload;
      });
      if (payload.status === 'empty' || payload.status === 'error') {
        setSongCue(null);
      }
      if (payload.status === 'ready') {
        setSongDialog((current) =>
          current
            ? {
                ...current,
                activeTab: 'play',
                source: normalizeSongGenerationSource(payload.source ?? current.source),
                submitting: false,
                suggesting: false,
                error: null,
              }
            : current,
        );
        onNotice(payload.lyricsCompressed ? '歌曲生成完成，歌词已按上限改写压缩' : '歌曲生成完成');
      } else if (isSunoWaitingConfirm(payload)) {
        setSongDialog((current) =>
          current
            ? {
                ...current,
                activeTab: 'play',
                source: normalizeSongGenerationSource(payload.source ?? current.source),
                submitting: false,
                suggesting: false,
                error: null,
              }
            : current,
        );
      }
    });
  }, [articleId, onNotice]);

  useEffect(() => {
    return onNativeEvent<ListeningSongPositionPayload>('listening.song.position', (payload) => {
      if (payload.articleId !== articleId) return;
      const cue = payload.cue ?? null;
      if (cue) {
        setSongCue(cue);
        setCurrentIndex(cue.lineIndex);
        setActivePart('english');
      } else {
        setActivePart(null);
        const durationMs = payload.durationMs ?? null;
        if (
          durationMs !== null &&
          durationMs > 0 &&
          payload.positionMs >= Math.max(0, durationMs - 250)
        ) {
          setSongCue(null);
          setSongState((current) =>
            current?.status === 'playing' ? { ...current, status: 'ready' } : current,
          );
        }
      }
    });
  }, [articleId]);

  useEffect(() => {
    const versions = songState?.versions?.filter((version) => version.id && version.audioPath) ?? [];
    if (versions.length === 0) {
      setSelectedSongVersionId('');
      return;
    }
    setSelectedSongVersionId((current) => {
      if (versions.some((version) => version.id === current)) {
        return current;
      }
      return versions.find((version) => version.isDefault)?.id ?? versions[0]?.id ?? '';
    });
  }, [songState?.articleId, songState?.versions]);

  useEffect(() => {
    if (mode === 'song') {
      fullscreenReadyTokenRef.current += 1;
      setFullscreenReady(null);
      setFullscreenReadyLoading(false);
      return;
    }
    if (items.length === 0) {
      setFullscreenReady(null);
      setFullscreenReadyLoading(false);
      return;
    }
    if (englishPreloadState && !isPreloadSettled(englishPreloadState)) {
      fullscreenReadyTokenRef.current += 1;
      setFullscreenReady(null);
      setFullscreenReadyLoading(true);
      return;
    }

    const token = ++fullscreenReadyTokenRef.current;
    setFullscreenReadyLoading(true);
    sendNative<ListeningFullscreenReadyPayload>('listening.fullscreenReady', {
      articleId,
      mode: 'english',
      startIndex: currentIndex,
      lookaheadCount: 2,
      items,
    })
      .then((payload) => {
        if (fullscreenReadyTokenRef.current !== token) return;
        setFullscreenReady(payload);
      })
      .catch((readyError) => {
        if (fullscreenReadyTokenRef.current !== token) return;
        setFullscreenReady({
          ready: false,
          reasons: [readyError instanceof Error ? readyError.message : '全屏播放准备状态检查失败'],
          requiredEnglish: 0,
          readyEnglish: 0,
          requiredChinese: 0,
          readyChinese: 0,
          missingEnglish: [],
          missingChinese: [],
          failed: 0,
        });
      })
      .finally(() => {
        if (fullscreenReadyTokenRef.current === token) {
          setFullscreenReadyLoading(false);
        }
      });
  }, [
    articleId,
    currentIndex,
    items,
    mode,
    englishPreloadState?.runId,
    englishPreloadState?.status,
  ]);

  useEffect(() => {
    if (mode !== 'song') {
      setSongFullscreenPlayerOpen(false);
    }
  }, [mode]);

  useEffect(() => {
    if (items.length === 0 || !recordingSettings) {
      setRecordingReady(null);
      setRecordingReadyLoading(false);
      return;
    }
    if (englishPreloadState && !isPreloadSettled(englishPreloadState)) {
      recordingReadyTokenRef.current += 1;
      setRecordingReady(null);
      setRecordingReadyLoading(true);
      return;
    }
    const token = ++recordingReadyTokenRef.current;
    setRecordingReadyLoading(true);
    const subtitleTranslations = items
      .map((item) => ({ index: item.index, chinese: item.chinese.trim() }))
      .filter((item) => item.chinese.length > 0);
    sendNative<ListeningRecordingReadyPayload>('listening.recordingReady', {
      articleId,
      mode: 'english',
      codec: recordingSettings.codec,
      resolution: recordingSettings.resolution,
      pageTransition: recordingSettings.pageTransition,
      subtitleMode: recordingSettings.subtitleMode,
      fps: recordingSettings.fps || 25,
      subtitleTranslations,
    })
      .then((payload) => {
        if (recordingReadyTokenRef.current !== token) return;
        setRecordingReady(payload);
      })
      .catch((readyError) => {
        if (recordingReadyTokenRef.current !== token) return;
        setRecordingReady({
          ready: false,
          reasons: [readyError instanceof Error ? readyError.message : '录制准备状态检查失败'],
          encoderName: '',
          codec: recordingSettings.codec,
          resolution: recordingSettings.resolution,
          pageTransition: recordingSettings.pageTransition,
          subtitleMode: recordingSettings.subtitleMode,
          outputDirectory: recordingSettings.outputDirectory,
          requiredEnglish: 0,
          readyEnglish: 0,
          requiredChinese: 0,
          readyChinese: 0,
          picturePageCount: 0,
        });
      })
      .finally(() => {
        if (recordingReadyTokenRef.current === token) {
          setRecordingReadyLoading(false);
        }
      });
  }, [
    articleId,
    items,
    recordingSettings,
    englishPreloadState?.runId,
    englishPreloadState?.status,
    pictureBookRecordingReadinessKey,
  ]);

  useEffect(() => {
    return onNativeEvent<ListeningPlaybackPayload>('listening.playback', (payload) => {
      if (payload.articleId !== articleId) return;
      if (payload.state === 'partStart') {
        setCurrentIndex(payload.index);
        setActivePart(payload.part);
        return;
      }
      if (payload.state === 'stopped') {
        setActivePart(null);
        setStatus('ready');
        return;
      }
      if (payload.state === 'error') {
        setActivePart(null);
        setStatus('error');
        setError(payload.error?.trim() || '听力播放失败，请重试');
      }
    });
  }, [articleId]);

  useEffect(() => {
    if (!wordCard) return undefined;

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        void closeWordCard();
      }
    };

    window.addEventListener('keydown', onKeyDown);
    return () => {
      window.removeEventListener('keydown', onKeyDown);
    };
  }, [wordCard]);

  const playFrom = async (startIndex: number, singleItem = false) => {
    if (visibleListeningItems(items).length === 0 || isListeningBusy(status)) return;

    let slotIndex = startIndex;
    const target = resolveListeningItemBySlotIndex(items, startIndex);
    if (!target || isHiddenListeningItem(target)) {
      const fallback = firstVisibleSlotIndex(items);
      if (fallback == null) return;
      slotIndex = fallback;
    }

    const token = ++playbackTokenRef.current;

    setStatus('playing');
    setError(null);
    setActivePart(null);

    try {
      await sendNative('listening.playSequence', {
        startIndex: slotIndex,
        mode: 'english',
        singleItem,
        items,
      });

      if (playbackTokenRef.current !== token) return;
      setActivePart(null);
      setStatus(singleItem ? 'ready' : 'done');
    } catch (playError) {
      if (playbackTokenRef.current !== token) return;
      setActivePart(null);
      setStatus('error');
      setError(playError instanceof Error ? playError.message : '听力播放失败，请重试');
    }
  };

  const stopPlayback = async () => {
    if (!isListeningBusy(status)) return;
    const token = ++playbackTokenRef.current;
    setStatus('stopping');
    setActivePart(null);
    try {
      await sendNative('listening.stop');
    } finally {
      if (playbackTokenRef.current === token) {
        setStatus('ready');
      }
    }
  };

  const startRecording = async (selectedSettings = recordingSettings) => {
    if (!selectedSettings || recordingBusy || busy || items.length === 0) return;
    setRecordingBusy(true);
    setRecordingError(null);
    setRecordingResult(null);
    setRecordingProgress({
      articleId,
      phase: 'preparing',
      progress: 0,
      completedFrames: 0,
      totalFrames: 0,
      message: '正在准备录制',
    });
    const subtitleTranslations = items
      .map((item) => ({ index: item.index, chinese: item.chinese.trim() }))
      .filter((item) => item.chinese.length > 0);
    try {
      await sendNative<ListeningRecordingResultPayload>('listening.recordVideo', {
        articleId,
        mode: 'english',
        codec: selectedSettings.codec,
        resolution: selectedSettings.resolution,
        pageTransition: selectedSettings.pageTransition,
        subtitleMode: selectedSettings.subtitleMode,
        fps: selectedSettings.fps || 25,
        subtitleTranslations,
      });
    } catch (recordError) {
      setRecordingError(recordError instanceof Error ? recordError.message : '录制视频失败');
    } finally {
      setRecordingBusy(false);
    }
  };

  const openRecordingDialog = () => {
    if (!canRecordVideo || !recordingSettings) return;
    setRecordingDialogSongVersionId('');
    setRecordingDialogDraft(recordingSettings);
    setRecordingError(null);
  };

  const openSongRecordingDialog = (versionId?: string) => {
    if (!versionId) {
      setRecordingError('请选择要导出的歌曲');
      return;
    }
    if (!recordingSettings) {
      setRecordingError('录制设置尚未加载，请稍后重试');
      return;
    }
    setRecordingDialogSongVersionId(versionId);
    setRecordingDialogDraft(recordingSettings);
    setRecordingError(null);
  };

  const copyFullText = async () => {
    if (!article || items.length === 0) {
      onNotice('没有可复制的文章内容');
      return;
    }
    try {
      await copyArticleFullText({ article, bookTitle, items });
      onNotice('全文已复制到剪贴板');
    } catch (copyError) {
      onNotice(copyError instanceof Error ? copyError.message : '全文复制失败');
    }
  };

  const updateRecordingDialogDraft = (patch: Partial<RecordingSettings>) => {
    setRecordingDialogDraft((draft) => (draft ? { ...draft, ...patch } : draft));
  };

  const confirmRecordingDialog = async () => {
    if (!recordingDialogDraft || recordingDialogSaving) return;
    setRecordingDialogSaving(true);
    setRecordingError(null);
    const songVersionId = recordingDialogSongVersionId;
    try {
      const savedSettings = await sendNative<RecordingSettings>('recording.settings.save', {
        codec: recordingDialogDraft.codec,
        resolution: recordingDialogDraft.resolution,
        pageTransition: recordingDialogDraft.pageTransition,
        subtitleMode: recordingDialogDraft.subtitleMode,
      });
      onRecordingSettingsLoaded(savedSettings);
      setRecordingDialogDraft(null);
      setRecordingDialogSongVersionId('');
      if (songVersionId) {
        await recordSongVideo(songVersionId, savedSettings);
      } else {
        await startRecording(savedSettings);
      }
    } catch (saveError) {
      setRecordingError(saveError instanceof Error ? saveError.message : '录制设置保存失败');
    } finally {
      setRecordingDialogSaving(false);
    }
  };

  const cancelRecording = async () => {
    setRecordingError(null);
    try {
      await sendNative('listening.cancelRecording');
      setRecordingBusy(false);
      setRecordingProgress(null);
      setRecordingError('录制已取消');
    } catch (cancelError) {
      setRecordingError(cancelError instanceof Error ? cancelError.message : '取消录制失败');
    }
  };

  const openSongDialog = async () => {
    if (busy) return;
    let currentSongState = songState;
    if (!currentSongState) {
      try {
        currentSongState = await sendNative<ListeningSongStatePayload>('listening.songState', { articleId });
        setSongState(currentSongState);
      } catch {
        currentSongState = null;
      }
    }
    const versions = currentSongState?.versions?.filter((version) => version.id && version.audioPath) ?? [];
    const preferredSource = normalizeSongGenerationSource(
      songSettings?.songProvider ?? currentSongState?.source ?? 'suno',
    );
    setSongDialog({
      activeTab: mode === 'song' || versions.length > 0 ? 'play' : 'settings',
      source: preferredSource,
      suggesting: false,
      submitting: false,
      error: currentSongState?.status === 'error' ? currentSongState.errorMessage?.trim() || null : null,
    });
  };

  const generateSong = async () => {
    if (!songDialog || songDialog.submitting || songDialog.suggesting) return;

    const lyrics = songLyricsFromItems(items);
    const selectedSource = normalizeSongGenerationSource(songDialog.source);
    const confirmed = selectedSource === 'suno'
      ? window.confirm(
          '即将打开 Suno 页面，请自行登录 Suno。登录后 Tomato 会自动填写歌词，并每次点击 Suno 蓝色魔法棒根据歌词重新生成风格；点击 Create 前会再次确认消耗 Suno credits。是否继续？',
        )
      : window.confirm('将调用阿里云百聆（Fun-Music）根据当前英文歌词生成歌曲。若 Key 未开通该能力，供应商错误会直接显示，且不会自动回退到 Suno。是否继续？');
    if (!confirmed) return;

    setSongDialog((current) => (current ? { ...current, submitting: true, error: null } : current));
    setSongState({
      articleId,
      status: 'generating',
      errorMessage: null,
      source: selectedSource,
      manualActionMessage:
        selectedSource === 'suno'
          ? 'Suno 页面已打开，请先在页面中自行登录。'
          : '阿里云百聆正在根据当前歌词生成歌曲。',
    });
    try {
      const payload = await sendNative<ListeningSongStatePayload>('listening.songGenerate', {
        articleId,
        source: selectedSource,
        lyrics,
      });
      setSongState(payload);
      setSongDialog((current) =>
        current
            ? {
                ...current,
                activeTab: payload.status === 'ready' || isSunoWaitingConfirm(payload) ? 'play' : current.activeTab,
                source: normalizeSongGenerationSource(payload.source ?? selectedSource),
                submitting: false,
              }
            : current,
      );
    } catch (songError) {
      const message = songError instanceof Error ? songError.message : '歌曲生成提交失败';
      setSongState({
        articleId,
        status: 'error',
        source: selectedSource,
        errorMessage: message,
      });
      setSongDialog((current) =>
        current
          ? {
              ...current,
              submitting: false,
              error: message,
            }
          : current,
      );
    }
  };

  const importExternalSong = async () => {
    if (songDialog?.submitting || songDialog?.suggesting) return;
    setSongDialog((current) => (current ? { ...current, submitting: true, error: null } : current));
    try {
      const payload = await sendNative<ListeningSongStatePayload>('listening.songImportExternal', {
        articleId,
        source: songState?.source ?? songDialog?.source ?? 'suno',
      });
      setSongState(payload);
      if (!payload.importCancelled) {
        const importedDefaultId = payload.versions?.find((version) => version.isDefault)?.id ?? '';
        if (importedDefaultId) {
          setSelectedSongVersionId(importedDefaultId);
        }
      }
      setSongDialog((current) =>
        current
          ? {
              ...current,
              activeTab: 'play',
              submitting: false,
              error: null,
            }
          : current,
      );
      onNotice(payload.importCancelled ? '已取消导入本地音乐' : '已导入本地音乐');
    } catch (importError) {
      const message = importError instanceof Error ? importError.message : '本地音乐导入失败';
      setSongDialog((current) =>
        current
          ? {
              ...current,
              submitting: false,
              error: message,
            }
          : current,
      );
      onNotice(message);
    }
  };

  const confirmSunoCreate = async () => {
    if (!songState || !isSunoWaitingConfirm(songState)) return;
    const confirmed = window.confirm('确认消耗 Suno credits 并创建歌曲？');
    if (!confirmed) return;
    const previousState = songState;
    setSongState({
      ...previousState,
      status: 'generating',
      automationStatus: 'creating',
      manualActionMessage: 'Suno 正在生成歌曲...',
      errorMessage: null,
    });
    try {
      const payload = await sendNative<ListeningSongStatePayload>('listening.songConfirmSunoCreate', { articleId });
      setSongState(payload);
    } catch (songError) {
      setSongState({
        ...previousState,
        status: 'error',
        errorMessage: songError instanceof Error ? songError.message : 'Suno 确认创建失败',
      });
    }
  };

  const retrySunoDownload = async () => {
    if (songState?.source !== 'suno') return;
    const previousState = songState;
    setSongState({
      ...previousState,
      status: 'generating',
      automationStatus: 'downloading',
      manualActionMessage: '正在打开 Suno 已生成歌曲并尝试下载...',
      errorMessage: null,
    });
    try {
      const payload = await sendNative<ListeningSongStatePayload>('listening.songDownloadSunoExisting', { articleId });
      setSongState(payload);
    } catch (songError) {
      setSongState({
        ...previousState,
        status: 'error',
        errorMessage: songError instanceof Error ? songError.message : 'Suno 歌曲下载检测失败',
      });
    }
  };

  const playSongVersion = async (versionId?: string, startLineIndex = currentIndex) => {
    if (!songState || (songState.status !== 'ready' && songState.status !== 'playing')) return;
    const safeStartLineIndex = Math.max(0, Math.min(startLineIndex, Math.max(items.length - 1, 0)));
    try {
      await sendNative('listening.songPlay', {
        articleId,
        versionId,
        startLineIndex: safeStartLineIndex,
      });
      setSongState((current) => (current ? { ...current, status: 'playing' } : current));
    } catch (songError) {
      setSongState((current) => ({
        articleId,
        status: 'error',
        source: current?.source,
        versions: current?.versions,
        errorMessage: songError instanceof Error ? songError.message : '歌曲播放失败',
      }));
    }
  };

  const setDefaultSongVersion = async (versionId: string) => {
    if (!versionId.trim()) return;
    try {
      const payload = await sendNative<ListeningSongStatePayload>('listening.songSetDefault', {
        articleId,
        versionId,
      });
      setSongState((current) =>
        current?.status === 'playing' ? { ...payload, status: 'playing' } : payload,
      );
      setSelectedSongVersionId(versionId);
      onNotice('已设为默认播放歌曲');
    } catch (songError) {
      setSongState((current) => ({
        articleId,
        status: 'error',
        source: current?.source,
        versions: current?.versions,
        errorMessage: songError instanceof Error ? songError.message : '默认歌曲设置失败',
      }));
    }
  };

  const generateSongTimeline = async (versionId: string) => {
    if (!songState) return;
    setSongState((current) =>
      current
        ? {
            ...current,
            versions: current.versions?.map((version) =>
              version.id === versionId
                ? { ...version, timelineStatus: 'generating', timelineError: null }
                : version,
            ),
          }
        : current,
    );
    try {
      const payload = await sendNative<ListeningSongStatePayload>('listening.songTimelineGenerate', {
        articleId,
        versionId,
      });
      setSongState((current) =>
        current?.status === 'playing' ? { ...payload, status: 'playing' } : payload,
      );
    } catch (songError) {
      const message = songError instanceof Error ? songError.message : '歌曲字幕生成失败';
      setSongState((current) =>
        current
          ? {
              ...current,
              versions: current.versions?.map((version) =>
                version.id === versionId
                  ? { ...version, timelineStatus: 'error', timelineError: message }
                  : version,
              ),
            }
          : current,
      );
    }
  };

  const recordSongVideo = async (versionId: string, selectedSettings = recordingSettings) => {
    if (!selectedSettings || recordingBusy) return;
    setRecordingBusy(true);
    setRecordingError(null);
    setRecordingResult(null);
    setRecordingProgress({
      articleId,
      phase: 'preparing',
      progress: 0,
      completedFrames: 0,
      totalFrames: 0,
      message: '正在准备歌曲视频',
    });
    try {
      await sendNative<ListeningRecordingResultPayload>('listening.songRecordVideo', {
        articleId,
        versionId,
        codec: selectedSettings.codec,
        resolution: selectedSettings.resolution,
        pageTransition: selectedSettings.pageTransition,
        subtitleMode: selectedSettings.subtitleMode,
        fps: selectedSettings.fps || 25,
      });
    } catch (recordError) {
      setRecordingError(recordError instanceof Error ? recordError.message : '录制歌曲视频失败');
    } finally {
      setRecordingBusy(false);
    }
  };

  const exportSongAudio = async (versionId: string) => {
    try {
      await sendNative<ListeningSongAudioExportPayload>('listening.songExportAudio', {
        articleId,
        versionId,
      });
      onNotice('音频已导出到 recording-export/mp3');
    } catch (exportError) {
      onNotice(exportError instanceof Error ? exportError.message : '音频导出失败');
    }
  };

  const stopSong = async () => {
    try {
      await sendNative('listening.songStop');
      setSongCue(null);
      setSongState((current) => (current ? { ...current, status: current.status === 'playing' ? 'ready' : current.status } : current));
    } catch (songError) {
      setSongState((current) => ({
        articleId,
        status: 'error',
        source: current?.source,
        versions: current?.versions,
        errorMessage: songError instanceof Error ? songError.message : '歌曲停止失败',
      }));
    }
  };

  const playWordAudio = async (word: string, token = wordCardTokenRef.current) => {
    setWordCard((current) =>
      current && wordCardTokenRef.current === token
        ? { ...current, playing: true, error: null }
        : current,
    );
    try {
      await sendNative<WordPlaybackPayload>('word.play', { word });
    } catch (playError) {
      if (wordCardTokenRef.current === token) {
        setWordCard((current) =>
          current
            ? {
                ...current,
                error: playError instanceof Error ? playError.message : '单词发音失败',
              }
            : current,
        );
      }
    } finally {
      if (wordCardTokenRef.current === token) {
        setWordCard((current) => (current ? { ...current, playing: false } : current));
      }
    }
  };

  const openWordCard = async (word: string, sentence: string, anchor: DOMRect) => {
    if (sentenceEdit) return;
    if (isHiddenListeningSentence(sentence)) return;
    const normalizedWord = normalizeLookupWord(word);
    if (!normalizedWord) return;

    const token = ++wordCardTokenRef.current;
    const shouldPauseListening = status === 'playing' && activePart !== null;
    let resumeBackground = false;

    setWordCard({
      word: normalizedWord,
      sentence,
      resumeBackground: false,
      loading: true,
      playing: false,
      position: wordCardPositionFor(anchor),
      error: null,
    });

    try {
      if (shouldPauseListening) {
        const pausePayload = await sendNative<ListeningPausePayload>('listening.pause');
        resumeBackground = Boolean(pausePayload.paused);
        if (wordCardTokenRef.current !== token) return;
        setWordCard((current) => (current ? { ...current, resumeBackground } : current));
      }

      void playWordAudio(normalizedWord, token);

      const lookup = await sendNative<WordLookupPayload>('word.lookup', {
        word: normalizedWord,
        sentence,
      });
      if (wordCardTokenRef.current !== token) return;
      setWordCard((current) =>
        current
          ? {
              ...current,
              lookup,
              loading: false,
              error: null,
            }
          : current,
      );
    } catch (lookupError) {
      if (wordCardTokenRef.current !== token) return;
      setWordCard((current) =>
        current
          ? {
              ...current,
              loading: false,
              error: lookupError instanceof Error ? lookupError.message : '单词解释加载失败',
            }
          : current,
      );
    }
  };

  const closeWordCard = async () => {
    const current = wordCard;
    const shouldResume = Boolean(current?.resumeBackground);
    wordCardTokenRef.current += 1;
    setWordCard(null);
    try {
      await sendNative('word.stop');
    } catch {
      // Word playback cleanup is best effort.
    }

    if (shouldResume && status === 'playing') {
      try {
        await sendNative<ListeningResumePayload>('listening.resume');
      } catch {
        // If the original segment ended or was stopped, there is nothing to resume.
      }
    }
  };

  const openSentenceEdit = (item: ListeningItem) => {
    if (busy) return;
    if (wordCard) {
      void closeWordCard();
    }
    setSentenceEdit({
      item,
      english: item.english,
      chinese: item.chinese,
      saving: false,
      error: null,
    });
  };

  const applySentenceUpdatePayload = (payload: ListeningSentenceUpdatePayload) => {
    setArticle((current) => payload.article ?? current);
    setItems((current) => payload.items ?? current.map((item) => (item.index === payload.item.index ? payload.item : item)));
    if (payload.item.chinese.trim() && !isHiddenListeningItem(payload.item)) {
      manualTranslationIndexesRef.current.add(payload.item.index);
    }
    if (payload.articles || payload.series) {
      onArticlesUpdated(payload);
    }
    if (payload.synthesis.status === 'error') {
      setSentenceSynthesisErrors((current) => ({
        ...current,
        [payload.item.index]: payload.synthesis.error?.trim() || '语音重新合成失败，请重试',
      }));
    } else {
      setSentenceSynthesisErrors((current) => {
        const next = { ...current };
        delete next[payload.item.index];
        return next;
      });
    }
  };

  const saveSentenceEdit = async (skipHideConfirm = false) => {
    if (!sentenceEdit) return;
    const english = sentenceEdit.english.trim();
    const chinese = sentenceEdit.chinese.trim();
    const isHiding = !english;
    if (isHiding && !skipHideConfirm) {
      setSentenceEdit((current) => (current ? { ...current, confirmingHide: true, error: null } : current));
      return;
    }

    setSentenceEdit((current) => (current ? { ...current, saving: true, error: null, confirmingHide: false } : current));
    try {
      await sendNative('listening.stop').catch(() => undefined);
      const payload = await sendNative<ListeningSentenceUpdatePayload>('listening.updateSentence', {
        articleId,
        index: sentenceEdit.item.index,
        english,
        chinese: isHiding ? '' : chinese,
        previousEnglish: sentenceEdit.item.english,
        previousChinese: sentenceEdit.item.chinese,
      });
      applySentenceUpdatePayload(payload);
      setCurrentIndex(sentenceEdit.item.index);
      setStatus('ready');
      setActivePart(null);
      setSentenceEdit(null);
    } catch (updateError) {
      setSentenceEdit((current) =>
        current
          ? {
              ...current,
              saving: false,
              error: updateError instanceof Error ? updateError.message : '字幕保存失败，请重试',
            }
          : current,
      );
    }
  };

  const retrySentenceSynthesis = async (item: ListeningItem) => {
    if (retryingSynthesisIndex !== null) return;
    setRetryingSynthesisIndex(item.index);
    try {
      const payload = await sendNative<ListeningSentenceUpdatePayload>('listening.resynthesizeSentence', {
        articleId,
        index: item.index,
        part: 'both',
      });
      applySentenceUpdatePayload(payload);
    } catch (synthesisError) {
      setSentenceSynthesisErrors((current) => ({
        ...current,
        [item.index]: synthesisError instanceof Error ? synthesisError.message : '语音重新合成失败，请重试',
      }));
    } finally {
      setRetryingSynthesisIndex(null);
    }
  };

  const picturePage = currentPictureBookPage(pictureBookState, currentIndex);
  const nextPicturePage = nextPictureBookPage(pictureBookState, picturePage);
  const pictureDecodeState = usePredecodePictureBookImages(articleId, pictureBookState, picturePage);
  useEnsurePictureBookPageImage({
    articleId,
    state: pictureBookState,
    page: picturePage,
    imageVariant: 'display',
    onPictureBookLoaded,
  });
  useEnsurePictureBookPageImage({
    articleId,
    state: pictureBookState,
    page: nextPicturePage,
    imageVariant: 'display',
    onPictureBookLoaded,
  });

  if (status === 'loading') {
    return (
      <section className="page listening-page">
        <TopBar title="听力练习准备中" onBack={() => onNavigate('/')}>
          <button className="ghost-action" onClick={() => onNavigate('/')}>
            <Icon name="exit" /> 退出
          </button>
        </TopBar>
        <LoadingPanel text="正在准备英文句子和中文对照" />
      </section>
    );
  }

  if (!article) {
    return (
      <section className="page listening-page">
        <TopBar title="听力练习暂时打不开" onBack={() => onNavigate('/')}>
          <button className="ghost-action" onClick={() => onNavigate('/')}>
            <Icon name="exit" /> 退出
          </button>
        </TopBar>
        <section className="loading-panel">
          <span className="assistant-avatar large" aria-hidden="true">T</span>
          <p>{error ?? '听力练习打开失败，请回到书库后重试。'}</p>
        </section>
      </section>
    );
  }

  const visibleItems = visibleListeningItems(items);
  const currentItem =
    resolveListeningItemBySlotIndex(items, currentIndex) ?? visibleItems[0] ?? null;
  const currentItemHidden = currentItem ? isHiddenListeningItem(currentItem) : false;
  const currentVisiblePosition = visibleItemPosition(items, currentIndex);
  const sceneEnglish =
    songCue?.english?.trim() ||
    (currentItemHidden ? '本句已隐藏' : currentItem?.english) ||
    '正在准备句子...';
  const sceneChinese = currentItemHidden ? undefined : songCue?.chinese?.trim() || currentItem?.chinese;
  const busy = isListeningBusy(status);
  const progress =
    visibleItems.length === 0
      ? 0
      : status === 'done'
        ? 100
        : Math.round(
            ((Math.max(currentVisiblePosition, 0) + (busy ? 0.5 : 0)) / visibleItems.length) * 100,
          );
  const playbackError = status === 'error' ? error : null;
  const startLabel = status === 'done' ? '重新播放' : '开始播放';
  const titleParts = storyTitlePartsFor(
    article,
    pictureBookState,
    article.title,
    bookTitle,
  );
  const visiblePreloadState = englishPreloadState;
  const fullscreenPictureReadiness = pictureBookFullscreenReadiness(
    pictureBookState,
    items,
    pictureDecodeState,
  );
  const fullscreenAudioReadiness = listeningFullscreenAudioReadiness(
    fullscreenReady,
    fullscreenReadyLoading,
  );
  const fullscreenReadiness = combineFullscreenReadiness(
    fullscreenAudioReadiness,
    fullscreenPictureReadiness,
  );
  const canOpenFullscreen = fullscreenReadiness.ready && !busy && visibleItems.length > 0;
  const recordingPictureReadiness = pictureBookFullscreenReadiness(
    pictureBookState,
    items,
    pictureDecodeState,
    { requireDecodedImages: false },
  );
  const recordingNativeReadiness: FullscreenReadiness =
    !recordingSettings
      ? { ready: false, reason: '正在读取录制设置' }
      : recordingReadyLoading
        ? { ready: false, reason: '正在检查录制准备状态...' }
        : recordingReady?.ready
          ? { ready: true, reason: '录制已准备好' }
          : {
              ready: false,
              reason: recordingReady?.reasons?.[0] ?? '录制准备状态检查未完成',
            };
  const recordingReadiness = combineFullscreenReadiness(
    recordingNativeReadiness,
    recordingPictureReadiness,
  );
  const canRecordVideo = recordingReadiness.ready && !busy && !recordingBusy && visibleItems.length > 0;
  const songWaitingConfirm = isSunoWaitingConfirm(songState);
  const songGenerating = songState?.status === 'generating';
  const songPlaying = songState?.status === 'playing';
  const songVersions = songState?.versions?.filter((version) => version.id && version.audioPath) ?? [];
  const selectedSongVersion =
    songVersions.find((version) => version.id === selectedSongVersionId) ??
    songVersions.find((version) => version.isDefault) ??
    songVersions[0] ??
    null;
  const selectedSongSubtitleNotice = songSubtitleNoticeForVersion(selectedSongVersion);
  const songFullscreenReadiness = songFullscreenReadinessForVersion({
    version: selectedSongVersion,
    hasSongVersions: songVersions.length > 0,
    songGenerating,
    recordingBusy,
    pictureReadiness: fullscreenPictureReadiness,
  });
  const canOpenSongFullscreen = songFullscreenReadiness.ready;
  const songFullscreenHint =
    !songFullscreenReadiness.ready &&
    songFullscreenReadiness.reason !== selectedSongSubtitleNotice
      ? songFullscreenReadiness.reason
      : null;
  const songVideoExportReadiness = songVideoExportReadinessForVersion({
    version: selectedSongVersion,
    hasSongVersions: songVersions.length > 0,
    songGenerating,
    recordingBusy,
    recordingSettingsLoaded: Boolean(recordingSettings),
    pictureReadiness: recordingPictureReadiness,
  });
  const canRecordSongVideo = songVideoExportReadiness.ready && !busy;
  const canRetrySunoDownload =
    songState?.source === 'suno' &&
    songState?.status !== 'playing' &&
    songState?.downloadComplete !== true &&
    !songWaitingConfirm &&
    !(songGenerating && songState?.automationStatus !== 'manualAction');
  const modeSwitch = onSwitchMode ? (
    <div className="segmented-control listening-mode-switch" role="tablist" aria-label="播放模式">
      <button
        type="button"
        role="tab"
        aria-selected={mode === 'listening'}
        className={mode === 'listening' ? 'active' : ''}
        onClick={() => onSwitchMode('listening')}
      >
        听力
      </button>
      <button
        type="button"
        role="tab"
        aria-selected={mode === 'song'}
        className={mode === 'song' ? 'active' : ''}
        onClick={() => onSwitchMode('song')}
      >
        歌曲
      </button>
    </div>
  ) : null;
  const retryPicturePage = (page: PictureBookPage) => {
    if (!pictureBookRetryGate.begin(articleId, page.pageIndex)) {
      return;
    }

    void Promise.resolve(onOpenPicturePromptReview(articleId, true))
      .catch(() => undefined)
      .finally(() => {
        pictureBookRetryGate.finish(articleId, page.pageIndex);
      });
  };

  return (
    <section className="page listening-page">
      <TopBar
        title={<StoryTitle parts={titleParts} />}
        onBack={() => onNavigate(article?.seriesId != null ? `/books/${article.seriesId}` : '/')}
      >
        <div className="player-chapter-actions" aria-label="章节导航">
          <span className="player-chapter-count">{chapterLabel}</span>
          <button className="ghost-action small" type="button" disabled={!onPrevChapter} onClick={onPrevChapter}>
            <Icon name="prev" /> 上一章
          </button>
          <button className="ghost-action small" type="button" disabled={!onNextChapter} onClick={onNextChapter}>
            下一章 <Icon name="next" />
          </button>
          {onOpenChapterDrawer && (
            <button
              className="ghost-action small chapter-drawer-trigger"
              type="button"
              aria-controls="book-chapter-drawer"
              aria-expanded={chapterDrawerOpen}
              onClick={onOpenChapterDrawer}
            >
              <Icon name="list" /> 章节
            </button>
          )}
        </div>
        <div className="listening-progress-summary">
          <ProgressLine
            value={progress}
            label={`${mode === 'song' ? '歌曲字幕' : '听力进度'} ${
              currentItemHidden
                ? `第 ${currentIndex + 1} 句已隐藏`
                : `${Math.max(currentVisiblePosition + 1, 1)} / ${Math.max(visibleItems.length, 1)}`
            }`}
            compact
          />
        </div>
        <button className="ghost-action" onClick={() => onNavigate(article?.seriesId != null ? `/books/${article.seriesId}` : '/')}>
          <Icon name="exit" /> 退出
        </button>
      </TopBar>

      <div className="listening-layout">
        <main className="listening-main">
          <PreloadStatusStrip state={visiblePreloadState} />
          <PictureBookScene
            state={pictureBookState}
            page={picturePage}
            english={sceneEnglish}
            chinese={sceneChinese}
            englishActive={activePart === 'english'}
            chineseActive={activePart === 'chinese'}
            onWordClick={openWordCard}
            onRetry={retryPicturePage}
            isRetrying={picturePage ? pictureBookRetryGate.isRetrying(articleId, picturePage.pageIndex) : false}
          />
          {playbackError && <p className="playback-cue error">{playbackError}</p>}
          <div className="listening-control-panel">
            {mode === 'song' ? (
              <div className="song-listening-controls">
                <div className="button-row">
                  {modeSwitch}
                  {songPlaying ? (
                    <button className="danger-light" onClick={() => void stopSong()}>
                      <Icon name="stop" /> 停止歌曲
                    </button>
                  ) : (
                    <button
                      className={`primary-action song-action ${songGenerating && !songWaitingConfirm ? 'loading' : ''}`}
                      onClick={() => void playSongVersion(selectedSongVersion?.id, currentIndex)}
                      disabled={busy || items.length === 0 || !selectedSongVersion || songGenerating}
                      title={songState?.status === 'error' ? songState.errorMessage?.trim() || '歌曲播放失败' : undefined}
                    >
                      <Icon name={songGenerating && !songWaitingConfirm ? 'refresh' : 'play'} /> 开始播放
                    </button>
                  )}
                  <button
                    className="ghost-action fullscreen-start-button"
                    type="button"
                    onClick={() => {
                      setSongFullscreenStartIndex(currentIndex);
                      setSongFullscreenPlayerOpen(true);
                    }}
                    disabled={!canOpenSongFullscreen}
                    title={songFullscreenReadiness.reason}
                  >
                    <Icon name="fullscreen" /> 全屏播放
                  </button>
                  <button
                    className="ghost-action"
                    type="button"
                    onClick={() => openSongRecordingDialog(selectedSongVersion?.id)}
                    disabled={!canRecordSongVideo}
                    title={songVideoExportReadiness.reason}
                  >
                    <Icon name="recordVideo" /> 导出视频
                  </button>
                </div>
                <div className="song-version-picker">
                  <label htmlFor={`song-version-${articleId}`}>歌曲列表</label>
                  <select
                    id={`song-version-${articleId}`}
                    aria-label="歌曲列表"
                    value={selectedSongVersion?.id ?? ''}
                    disabled={busy || songVersions.length === 0}
                    onChange={(event) => setSelectedSongVersionId(event.target.value)}
                  >
                    {songVersions.length === 0 ? (
                      <option value="">还没有本地歌曲</option>
                    ) : songVersions.map((version, index) => (
                      <option value={version.id} key={version.id}>
                        {(version.title?.trim() || `版本 ${index + 1}`)}{version.isDefault ? ' · 默认' : ''}
                      </option>
                    ))}
                  </select>
                  <button
                    className={`icon-button small song-default-button ${selectedSongVersion?.isDefault ? 'active' : ''}`}
                    type="button"
                    disabled={!selectedSongVersion || busy}
                    aria-label={selectedSongVersion?.isDefault ? '当前歌曲已是默认播放歌曲' : '设为当前默认播放歌曲'}
                    title={selectedSongVersion?.isDefault ? '当前默认播放歌曲' : '设为当前默认播放歌曲'}
                    onClick={() => selectedSongVersion && void setDefaultSongVersion(selectedSongVersion.id)}
                  >
                    <Icon name="star" />
                  </button>
                </div>
                {songVersions.length === 0 && (
                  <p className="fullscreen-ready-hint">还没有本地歌曲，请到创作中心生成或下载。</p>
                )}
                {selectedSongSubtitleNotice && (
                  <p className="fullscreen-ready-hint">{selectedSongSubtitleNotice}</p>
                )}
                {songFullscreenHint && (
                  <p className="fullscreen-ready-hint">{songFullscreenHint}</p>
                )}
              </div>
            ) : (
              <div className="button-row">
                {modeSwitch}
                {busy ? (
                  <button className="danger-light" onClick={stopPlayback}>
                    <Icon name="stop" /> 停止
                  </button>
                ) : (
                  <button className="primary-action" onClick={() => void playFrom(currentIndex)} disabled={items.length === 0}>
                    <Icon name="play" /> {startLabel}
                  </button>
                )}
                <button
                  className="ghost-action"
                  onClick={() => void playFrom(currentIndex, true)}
                  disabled={busy || items.length === 0}
                >
                  <Icon name="replay" /> 重听本句
                </button>
                <button
                  className="ghost-action fullscreen-start-button"
                  onClick={() => setFullscreenPlayerOpen(true)}
                  disabled={!canOpenFullscreen || recordingBusy}
                  title={fullscreenReadiness.reason}
                >
                  <Icon name="fullscreen" /> 全屏播放
                </button>
                <button
                  className="ghost-action"
                  onClick={openRecordingDialog}
                  disabled={!canRecordVideo}
                  title={recordingReadiness.reason}
                >
                  <Icon name="recordVideo" /> 导出视频
                </button>
                <button
                  className="ghost-action"
                  type="button"
                  onClick={() => void copyFullText()}
                  disabled={!article || items.length === 0}
                >
                  <Icon name="copy" /> 复制全文
                </button>
              </div>
            )}
            {mode !== 'song' && !fullscreenReadiness.ready && (
              <p className="fullscreen-ready-hint">{fullscreenReadiness.reason}</p>
            )}
            {songState?.status === 'error' && songState.errorMessage?.trim() && (
              <p className="playback-cue error">{songState.errorMessage}</p>
            )}
            {songState?.status === 'generating' &&
              songState?.automationStatus?.trim() &&
              !songState?.manualActionMessage?.trim() && (
              <p className="playback-cue">{songAutomationStatusText(songState)}</p>
            )}
            {songState?.manualActionMessage?.trim() && (
              <p className="playback-cue">{songState.manualActionMessage}</p>
            )}
          </div>

          <div className="listening-list" aria-label="听力句子列表">
            {items.map((item) => {
              const active = item.index === currentIndex;
              const hidden = isHiddenListeningItem(item);
              return (
                <div
                  className={`listening-row ${active ? 'active' : ''} ${hidden ? 'hidden' : ''}`}
                  key={`${item.index}-${hidden ? 'hidden' : item.english}`}
                  onClick={() => {
                    if (busy) return;
                    setCurrentIndex(item.index);
                    if (mode === 'song' && songPlaying && selectedSongVersion?.id && !hidden) {
                      void playSongVersion(selectedSongVersion.id, item.index);
                    }
                  }}
                  onKeyDown={(event) => {
                    if (busy) return;
                    if (event.key === 'Enter' || event.key === ' ') {
                      event.preventDefault();
                      setCurrentIndex(item.index);
                      if (mode === 'song' && songPlaying && selectedSongVersion?.id && !hidden) {
                        void playSongVersion(selectedSongVersion.id, item.index);
                      }
                    }
                  }}
                  role="button"
                  tabIndex={0}
                  aria-disabled={busy}
                  aria-current={active ? 'true' : undefined}
                >
                  <b>{item.index + 1}</b>
                  <span className="listening-row-copy">
                    <strong className={active && activePart === 'english' ? 'playing-text' : undefined}>
                      {hidden ? '（已隐藏）' : item.english}
                    </strong>
                    <small className={active && activePart === 'chinese' ? 'playing-text' : undefined}>
                      {hidden ? '重新填入英文即可恢复' : item.chinese}
                    </small>
                    {!hidden && sentenceSynthesisErrors[item.index] && (
                      <em className="sentence-synthesis-error">
                        {sentenceSynthesisErrors[item.index]}
                        <button
                          type="button"
                          onClick={(event) => {
                            event.stopPropagation();
                            void retrySentenceSynthesis(item);
                          }}
                          disabled={retryingSynthesisIndex === item.index}
                        >
                          {retryingSynthesisIndex === item.index ? '重新合成中' : '重新合成语音'}
                        </button>
                      </em>
                    )}
                  </span>
                  <button
                    className="icon-button tiny sentence-row-edit"
                    type="button"
                    onClick={(event) => {
                      event.stopPropagation();
                      openSentenceEdit(item);
                    }}
                    disabled={busy}
                    aria-label={`修改第 ${item.index + 1} 句字幕`}
                  >
                    <Icon name="edit" />
                  </button>
                </div>
              );
            })}
          </div>
        </main>
      </div>
      {wordCard && (
        <WordTranslationCard
          state={wordCard}
          onClose={closeWordCard}
          onReplay={() => void playWordAudio(wordCard.word)}
        />
      )}
      {sentenceEdit && (
        <SentenceEditDialog
          state={sentenceEdit}
          onEnglishChange={(english) => setSentenceEdit((current) => (current ? { ...current, english, error: null } : current))}
          onChineseChange={(chinese) => setSentenceEdit((current) => (current ? { ...current, chinese, error: null } : current))}
          onCancel={() => setSentenceEdit(null)}
          onSave={() => void saveSentenceEdit()}
        />
      )}
      {sentenceEdit?.confirmingHide && (
        <ConfirmDialog
          ariaLabel="隐藏字幕确认"
          title={`隐藏第 ${sentenceEdit.item.index + 1} 句字幕`}
          message="槽位编号不变，歌曲字幕不变。稍后重新填入英文即可恢复。"
          confirmLabel="确定隐藏"
          busy={sentenceEdit.saving}
          onCancel={() =>
            setSentenceEdit((current) => (current ? { ...current, confirmingHide: false } : current))
          }
          onConfirm={() => void saveSentenceEdit(true)}
        />
      )}
      {songDialog && (
        <SongDialog
          state={songDialog}
          songState={songState}
          songVersions={songVersions}
          allowGeneration={mode !== 'song'}
          canRetrySunoDownload={canRetrySunoDownload}
          songWaitingConfirm={songWaitingConfirm}
          songGenerating={songGenerating}
          songPlaying={songPlaying}
          recordingBusy={recordingBusy}
          onSourceChange={(source) =>
            setSongDialog((current) => (current ? { ...current, source, error: null } : current))
          }
          onTabChange={(activeTab) =>
            setSongDialog((current) => (current ? { ...current, activeTab } : current))
          }
          onCancel={() => {
            setSongDialog(null);
          }}
          onConfirm={() => void generateSong()}
          onImportExternal={() => void importExternalSong()}
          onConfirmSunoCreate={() => void confirmSunoCreate()}
          onRetrySunoDownload={() => void retrySunoDownload()}
          onPlayVersion={(versionId) => void playSongVersion(versionId)}
          onSetDefaultVersion={(versionId) => void setDefaultSongVersion(versionId)}
          onGenerateTimeline={(versionId) => void generateSongTimeline(versionId)}
          onRecordSongVideo={(versionId) => void recordSongVideo(versionId)}
          onExportSongAudio={(versionId) => void exportSongAudio(versionId)}
          onStopSong={() => void stopSong()}
        />
      )}
      {fullscreenPlayerOpen && article && (
        <FullscreenListeningPlayer
          article={article}
          items={items}
          pictureBookState={pictureBookState}
          onPictureBookLoaded={onPictureBookLoaded}
          onClose={() => setFullscreenPlayerOpen(false)}
        />
      )}
      {songFullscreenPlayerOpen && article && selectedSongVersion && (
        <FullscreenSongPlayer
          article={article}
          version={selectedSongVersion}
          startLineIndex={songFullscreenStartIndex}
          pictureBookState={pictureBookState}
          onPictureBookLoaded={onPictureBookLoaded}
          onPlaybackStopped={() => {
            setSongCue(null);
            setSongState((current) =>
              current?.status === 'playing' ? { ...current, status: 'ready' } : current,
            );
          }}
          onClose={() => setSongFullscreenPlayerOpen(false)}
        />
      )}
      {recordingDialogDraft && (
        <RecordingSettingsDialog
          settings={recordingDialogDraft}
          saving={recordingDialogSaving}
          onChange={updateRecordingDialogDraft}
          onCancel={() => {
            if (!recordingDialogSaving) {
              setRecordingDialogDraft(null);
              setRecordingDialogSongVersionId('');
            }
          }}
          onConfirm={() => void confirmRecordingDialog()}
        />
      )}
      {(recordingBusy || recordingProgress) && (
        <RecordingProgressOverlay
          progress={recordingProgress}
          onCancel={cancelRecording}
        />
      )}
      {recordingResult && (
        <RecordingResultCard
          result={recordingResult}
          onClose={() => setRecordingResult(null)}
        />
      )}
    </section>
  );
}

function SentenceEditDialog({
  state,
  onEnglishChange,
  onChineseChange,
  onCancel,
  onSave,
}: {
  state: SentenceEditState;
  onEnglishChange: (english: string) => void;
  onChineseChange: (chinese: string) => void;
  onCancel: () => void;
  onSave: () => void;
}) {
  const englishRef = useRef<HTMLTextAreaElement | null>(null);

  useEffect(() => {
    englishRef.current?.focus({ preventScroll: true });
  }, []);

  return createPortal(
    <div className="edit-dialog-backdrop" role="presentation">
      <section
        className="edit-dialog sentence-edit-dialog"
        role="dialog"
        aria-modal="true"
        aria-label="修改字幕"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <div className="edit-dialog-heading">
          <b>修改第 {state.item.index + 1} 句字幕</b>
          <button className="icon-button small" type="button" onClick={onCancel} disabled={state.saving} aria-label="关闭">
            <Icon name="exit" />
          </button>
        </div>
        <label>
          <span>英文</span>
          <textarea
            ref={englishRef}
            value={state.english}
            rows={3}
            maxLength={600}
            onChange={(event) => onEnglishChange(event.target.value)}
          />
        </label>
        <label>
          <span>中文</span>
          <textarea
            value={state.chinese}
            rows={3}
            maxLength={600}
            onChange={(event) => onChineseChange(event.target.value)}
          />
        </label>
        {state.error && <p className="edit-dialog-error">{state.error}</p>}
        <div className="edit-dialog-actions">
          <button className="ghost-action" type="button" onClick={onCancel} disabled={state.saving}>
            取消
          </button>
          <button className="primary-action" type="button" onClick={onSave} disabled={state.saving}>
            <Icon name="save" /> {state.saving ? '保存中' : state.english.trim() ? '保存' : '隐藏本句'}
          </button>
        </div>
      </section>
    </div>,
    document.body,
  );
}

function SongDialog({
  state,
  songState,
  songVersions,
  allowGeneration = true,
  canRetrySunoDownload,
  songWaitingConfirm,
  songGenerating,
  songPlaying,
  recordingBusy,
  onTabChange,
  onSourceChange,
  onCancel,
  onConfirm,
  onImportExternal,
  onConfirmSunoCreate,
  onRetrySunoDownload,
  onPlayVersion,
  onSetDefaultVersion,
  onGenerateTimeline,
  onRecordSongVideo,
  onExportSongAudio,
  onStopSong,
}: {
  state: SongDialogState;
  songState: ListeningSongStatePayload | null;
  songVersions: NonNullable<ListeningSongStatePayload['versions']>;
  allowGeneration?: boolean;
  canRetrySunoDownload: boolean;
  songWaitingConfirm: boolean;
  songGenerating: boolean;
  songPlaying: boolean;
  recordingBusy: boolean;
  onTabChange: (tab: SongDialogTab) => void;
  onSourceChange: (source: SongGenerationSource) => void;
  onCancel: () => void;
  onConfirm: () => void;
  onImportExternal: () => void;
  onConfirmSunoCreate: () => void;
  onRetrySunoDownload: () => void;
  onPlayVersion: (versionId?: string) => void;
  onSetDefaultVersion: (versionId: string) => void;
  onGenerateTimeline: (versionId: string) => void;
  onRecordSongVideo: (versionId: string) => void;
  onExportSongAudio: (versionId: string) => void;
  onStopSong: () => void;
}) {
  const busy = state.suggesting || state.submitting;
  const groupedVersions = useMemo(() => groupSongVersionsForDisplay(songVersions), [songVersions]);
  const showBailianBlocking = state.submitting && state.source === 'bailian_fun_music';

  return createPortal(
    <>
      <div className="edit-dialog-backdrop" role="presentation">
        <section className="edit-dialog song-style-dialog" role="dialog" aria-modal="true" aria-label="歌曲设置">
        <div className="edit-dialog-heading">
          <div>
            <b>歌曲设置</b>
            <small>{state.activeTab === 'play' ? '选择本地完整歌曲版本播放。' : '选择阿里云百聆或 Suno 网页自动化生成。'}</small>
          </div>
          <div className="song-style-heading-actions">
            <button className="icon-button small" type="button" onClick={onCancel} aria-label="关闭">
              <Icon name="exit" />
            </button>
          </div>
        </div>

        <div className="song-dialog-tabs" role="tablist" aria-label="歌曲面板">
          <button
            type="button"
            role="tab"
            aria-selected={state.activeTab === 'play'}
            className={state.activeTab === 'play' ? 'active' : ''}
            onClick={() => onTabChange('play')}
          >
            播放
          </button>
          {allowGeneration && (
            <button
              type="button"
              role="tab"
              aria-selected={state.activeTab === 'settings'}
              className={state.activeTab === 'settings' ? 'active' : ''}
              onClick={() => onTabChange('settings')}
            >
              生成
            </button>
          )}
        </div>

        {state.activeTab === 'play' ? (
          <div className="song-play-tab" role="tabpanel" aria-label="歌曲播放">
            {songState?.status === 'error' && songState.errorMessage?.trim() && (
              <p className="edit-dialog-error">{songState.errorMessage}</p>
            )}
            {songState?.manualActionMessage?.trim() && (
              <p className="song-source-note">{songState.manualActionMessage}</p>
            )}
            {songGenerating && !songWaitingConfirm && (
              <p className="song-source-note">{songAutomationStatusText(songState!)}</p>
            )}
            {groupedVersions.length > 0 ? (
              <div className="song-style-groups">
                {groupedVersions.map((group) => (
                  <div className="song-style-group" key={group.key}>
                    <div className="song-style-group-heading">
                      <span>版本</span>
                      <b>{group.label}</b>
                    </div>
                    <div className="song-version-row" aria-label={`${group.label} 歌曲版本`}>
                      {group.versions.map((version, index) => {
                        const title = version.title?.trim() || `版本 ${index + 1}`;
                        const timelineStatus = normalizeTimelineStatus(version.timelineStatus, version.timelinePath);
                        const timelineReady = timelineStatus === 'ready';
                        const timelineGenerating = timelineStatus === 'generating';
                        const timelineBlockedTitle =
                          timelineStatus === 'stale' ? '歌曲字幕时间线版本过旧，请重新生成字幕' : '请先生成歌曲字幕';
                        return (
                          <div className="song-version-actions" key={version.id}>
                            <button
                              className={`icon-button small song-default-button ${version.isDefault ? 'active' : ''}`}
                              type="button"
                              disabled={busy}
                              aria-label={version.isDefault ? `${title} 已是默认播放歌曲` : `设为默认播放歌曲：${title}`}
                              title={version.isDefault ? '默认播放歌曲' : '设为默认播放歌曲'}
                              onClick={() => onSetDefaultVersion(version.id)}
                            >
                              <Icon name="star" />
                            </button>
                            <button
                              className="ghost-action small song-title-button"
                              type="button"
                              onClick={() => onPlayVersion(version.id)}
                              disabled={busy || songGenerating}
                              title={title}
                            >
                              <Icon name="sound" /> <span className="song-version-title">{title}{version.isDefault ? ' · 默认' : ''}</span>
                            </button>
                            <button
                              className="ghost-action small"
                              type="button"
                              onClick={() => onGenerateTimeline(version.id)}
                              disabled={busy || songGenerating || timelineGenerating}
                              title={version.timelineError?.trim() || undefined}
                            >
                              <Icon name={timelineGenerating ? 'refresh' : 'sentence'} /> {songTimelineLabel(timelineStatus)}
                            </button>
                            <button
                              className="ghost-action small"
                              type="button"
                              onClick={() => onRecordSongVideo(version.id)}
                              disabled={busy || songGenerating || recordingBusy || !timelineReady}
                              title={timelineReady ? '录制歌曲视频' : timelineBlockedTitle}
                            >
                              <Icon name="recordVideo" /> 录制歌曲视频
                            </button>
                            <button
                              className="ghost-action small"
                              type="button"
                              onClick={() => onExportSongAudio(version.id)}
                              disabled={busy || songGenerating || recordingBusy || !version.audioPath?.trim()}
                              title="导出音频文件"
                            >
                              <Icon name="download" /> 导出音频文件
                            </button>
                          </div>
                        );
                      })}
                    </div>
                  </div>
                ))}
              </div>
            ) : (
              <p className="song-source-note">还没有本地完整歌曲版本。</p>
            )}
            <div className="song-dialog-action-row">
              {songPlaying && (
                <button className="danger-light small" type="button" onClick={onStopSong}>
                  <Icon name="stop" /> 停止播放
                </button>
              )}
              {state.source === 'suno' && songWaitingConfirm && (
                <button className="primary-action small" type="button" onClick={onConfirmSunoCreate} disabled={busy}>
                  <Icon name="music" /> 确认创建歌曲
                </button>
              )}
              {state.source === 'suno' && canRetrySunoDownload && (
                <button className="suno-download-action small" type="button" onClick={onRetrySunoDownload} disabled={busy}>
                  <Icon name="download" /> 检测下载
                </button>
              )}
              <button className="ghost-action small" type="button" onClick={onImportExternal} disabled={busy || songGenerating}>
                <Icon name="folder" /> 导入本地音乐
              </button>
              {allowGeneration && (
                <button className="ghost-action small" type="button" onClick={() => onTabChange('settings')} disabled={busy}>
                  <Icon name="music" /> 生成新版本
                </button>
              )}
            </div>
          </div>
        ) : (
          <>
            <div className="song-source-options" aria-label="生成来源">
              <button
                type="button"
                className={state.source === 'bailian_fun_music' ? 'active' : ''}
                disabled={busy}
                onClick={() => onSourceChange('bailian_fun_music')}
              >
                阿里云百聆
              </button>
              <button
                type="button"
                className={state.source === 'suno' ? 'active' : ''}
                disabled={busy}
                onClick={() => onSourceChange('suno')}
              >
                Suno 网页自动化
              </button>
            </div>
            <div className="song-source-note suno-style-preview">
              {state.source === 'suno' ? (
                <p>
                  将打开 Suno 页面，请自行登录；登录后 Tomato 会自动填写歌词，并清空旧 Styles，让 Suno 自带魔法棒每次根据歌词重新生成风格。Tomato 不保存 Suno 用户名、密码或验证码。
                </p>
              ) : (
                <p>
                  将调用阿里云百聆（Fun-Music）生成音频，使用当前英文歌词作为 lyrics。该能力可能需要百炼账号开通权限，失败时会直接显示供应商返回错误。
                </p>
              )}
            </div>
          </>
        )}
        {state.error && <p className="edit-dialog-error">{state.error}</p>}
        <div className="edit-dialog-actions">
          <button className="ghost-action" type="button" onClick={onCancel}>
            取消
          </button>
          {state.activeTab === 'settings' && (
            <button
              className="primary-action"
              type="button"
              onClick={onConfirm}
              disabled={busy}
            >
              <Icon name={state.submitting ? 'refresh' : 'music'} /> {state.submitting ? '提交生成中' : '开始生成歌曲'}
            </button>
          )}
        </div>
        </section>
      </div>
      {showBailianBlocking && (
        <AiBlockingOverlay
          title="正在提交百聆歌曲"
          detail="正在向阿里云百聆 Fun-Music 提交歌曲生成，请等待服务返回。"
          timeoutSeconds={480}
        />
      )}
    </>,
    document.body,
  );
}

function FullscreenListeningPlayer({
  article,
  items,
  pictureBookState,
  onPictureBookLoaded,
  onClose,
}: {
  article: Article;
  items: ListeningItem[];
  pictureBookState: PictureBookState | null;
  onPictureBookLoaded: PictureBookStateSetter;
  onClose: () => void;
}) {
  const rootRef = useRef<HTMLDivElement | null>(null);
  const closingRef = useRef(false);
  const enteredFullscreenRef = useRef(false);
  const [currentIndex, setCurrentIndex] = useState(0);
  const [activePart, setActivePart] = useState<ListeningPart>(null);
  const [status, setStatus] = useState<'starting' | 'playing' | 'paused' | 'completed' | 'error'>('starting');
  const [error, setError] = useState<string | null>(null);
  const [controlsVisible, setControlsVisible] = useState(false);
  const [cursorVisible, setCursorVisible] = useState(false);
  const controlsHideTimerRef = useRef<number | null>(null);
  const cursorHideTimerRef = useRef<number | null>(null);
  const articleId = article.id ?? 0;
  const currentItem = items.find((item) => item.index === currentIndex) ?? items[0];
  const currentPage = currentPictureBookPage(pictureBookState, currentIndex);
  const nextFullscreenPage = nextPictureBookPage(pictureBookState, currentPage);
  // "display" (1280x720) is the largest bitmap the WebView should ever render; the raw
  // 2560x1440 original corrupts on some Windows GPU drivers when downscaled into the
  // window (blocky color noise). 1280x720 is also the product-facing resolution.
  useEnsurePictureBookPageImage({
    articleId,
    state: pictureBookState,
    page: currentPage,
    imageVariant: 'display',
    onPictureBookLoaded,
  });
  useEnsurePictureBookPageImage({
    articleId,
    state: pictureBookState,
    page: nextFullscreenPage,
    imageVariant: 'display',
    onPictureBookLoaded,
  });
  const imageSrc = pageHasPictureBookImageVariant(currentPage, 'display')
    ? directImageSource(currentPage?.imageUri) ?? ''
    : '';
  const progress = items.length === 0 ? 0 : Math.round(((currentIndex + 1) / items.length) * 100);
  const keepControlsVisible = status === 'paused' || status === 'completed' || status === 'error';
  const shouldShowControls = controlsVisible || keepControlsVisible;

  const clearControlsHideTimer = () => {
    if (controlsHideTimerRef.current !== null) {
      window.clearTimeout(controlsHideTimerRef.current);
      controlsHideTimerRef.current = null;
    }
  };

  const clearCursorHideTimer = () => {
    if (cursorHideTimerRef.current !== null) {
      window.clearTimeout(cursorHideTimerRef.current);
      cursorHideTimerRef.current = null;
    }
  };

  const showControls = () => {
    setControlsVisible(true);
    clearControlsHideTimer();
    if (!keepControlsVisible) {
      controlsHideTimerRef.current = window.setTimeout(() => {
        setControlsVisible(false);
        controlsHideTimerRef.current = null;
      }, 3000);
    }
  };

  const showCursorTemporarily = () => {
    setCursorVisible(true);
    clearCursorHideTimer();
    cursorHideTimerRef.current = window.setTimeout(() => {
      setCursorVisible(false);
      cursorHideTimerRef.current = null;
    }, 2000);
  };

  useEffect(() => {
    const element = rootRef.current;
    if (!element) return undefined;

    const request = element.requestFullscreen?.();
    if (request) {
      request
        .then(() => {
          enteredFullscreenRef.current = true;
        })
        .catch(() => {
          enteredFullscreenRef.current = false;
        });
    }

    const onFullscreenChange = () => {
      if (enteredFullscreenRef.current && !document.fullscreenElement && !closingRef.current) {
        onClose();
      }
    };
    document.addEventListener('fullscreenchange', onFullscreenChange);
    return () => {
      document.removeEventListener('fullscreenchange', onFullscreenChange);
    };
  }, [onClose]);

  useEffect(() => {
    let cancelled = false;
    setStatus('starting');
    setError(null);
    setCurrentIndex(0);
    setActivePart(null);

    sendNative('listening.playSequence', {
      startIndex: 0,
      mode: 'english',
      singleItem: false,
      items,
    })
      .then(() => {
        if (cancelled) return;
        setStatus('completed');
        setActivePart(null);
        const last = items[items.length - 1];
        if (last) {
          setCurrentIndex(last.index);
        }
      })
      .catch((playError) => {
        if (cancelled) return;
        setStatus('error');
        setActivePart(null);
        setError(playError instanceof Error ? playError.message : '全屏播放失败');
      });

    return () => {
      cancelled = true;
      void sendNative('listening.stop').catch(() => undefined);
    };
  }, [items]);

  useEffect(() => {
    if (keepControlsVisible) {
      clearControlsHideTimer();
      setControlsVisible(true);
      return undefined;
    }
    if (!controlsVisible) {
      return undefined;
    }
    clearControlsHideTimer();
    controlsHideTimerRef.current = window.setTimeout(() => {
      setControlsVisible(false);
      controlsHideTimerRef.current = null;
    }, 3000);
    return () => {
      clearControlsHideTimer();
    };
  }, [controlsVisible, keepControlsVisible]);

  useEffect(() => {
    return () => {
      clearControlsHideTimer();
      clearCursorHideTimer();
    };
  }, []);

  useEffect(() => {
    return onNativeEvent<ListeningPlaybackPayload>('listening.playback', (payload) => {
      if (payload.articleId !== articleId) return;
      if (payload.state === 'partStart') {
        setCurrentIndex(payload.index);
        setActivePart(payload.part);
        setStatus((current) => (current === 'paused' ? current : 'playing'));
        return;
      }
      if (payload.state === 'completed') {
        setStatus('completed');
        setActivePart(null);
        return;
      }
      if (payload.state === 'stopped') {
        setActivePart(null);
        return;
      }
      if (payload.state === 'error') {
        setStatus('error');
        setActivePart(null);
        setError(payload.error?.trim() || '全屏播放失败');
      }
    });
  }, [articleId]);

  const close = () => {
    closingRef.current = true;
    if (document.fullscreenElement) {
      void document.exitFullscreen().catch(() => undefined);
    }
    onClose();
  };

  const togglePause = async () => {
    if (status === 'paused') {
      const payload = await sendNative<ListeningResumePayload>('listening.resume');
      if (payload.resumed) {
        setStatus('playing');
      }
      return;
    }
    if (status !== 'playing' && status !== 'starting') {
      return;
    }
    const payload = await sendNative<ListeningPausePayload>('listening.pause');
    if (payload.paused) {
      setStatus('paused');
    }
  };

  const rootClassName = [
    'fullscreen-listening',
    shouldShowControls ? 'controls-visible' : 'controls-hidden',
    cursorVisible ? 'cursor-visible' : 'cursor-hidden',
  ].join(' ');

  return createPortal(
    <div
      className={rootClassName}
      ref={rootRef}
      role="dialog"
      aria-modal="true"
      aria-label="全屏听力播放"
      onClick={showControls}
      onPointerMove={showCursorTemporarily}
    >
      <div className="fullscreen-listening-stage">
        <div className="fullscreen-listening-frame">
          {imageSrc ? (
            <img src={imageSrc} alt="" />
          ) : (
            <div className="fullscreen-listening-missing">
              <Icon name="spark" />
              <span>绘本图暂不可用</span>
            </div>
          )}
          <div className="fullscreen-listening-subtitles">
            <h1 className={activePart === 'english' ? 'playing-text' : undefined}>
              {currentItem?.english ?? article.title}
            </h1>
            {currentItem?.chinese && (
              <p className={activePart === 'chinese' ? 'playing-text' : undefined}>
                {currentItem.chinese}
              </p>
            )}
          </div>
        </div>
      </div>
      <div
        className="fullscreen-listening-toolbar"
        aria-hidden={!shouldShowControls}
        onClick={(event) => event.stopPropagation()}
      >
        <div className="fullscreen-listening-progress" aria-label={`播放进度 ${progress}%`}>
          <span style={{ width: `${progress}%` }} />
        </div>
        <div className="fullscreen-listening-meta">
          <strong>{article.title}</strong>
          <small>{Math.min(currentIndex + 1, items.length)} / {items.length}</small>
        </div>
        {error && <p className="fullscreen-listening-error">{error}</p>}
        <div className="fullscreen-listening-actions">
          <button
            className="ghost-action"
            type="button"
            onClick={(event) => {
              event.stopPropagation();
              void togglePause();
            }}
            disabled={status === 'completed' || status === 'error'}
          >
            <Icon name={status === 'paused' ? 'play' : 'pause'} />
            {status === 'paused' ? '继续' : '暂停'}
          </button>
          <button
            className="primary-action"
            type="button"
            onClick={(event) => {
              event.stopPropagation();
              close();
            }}
          >
            <Icon name="exit" /> 退出全屏
          </button>
        </div>
      </div>
    </div>,
    document.body,
  );
}

function FullscreenSongPlayer({
  article,
  version,
  startLineIndex,
  pictureBookState,
  onPictureBookLoaded,
  onPlaybackStopped,
  onClose,
}: {
  article: Article;
  version: SongVersionPayload;
  startLineIndex: number;
  pictureBookState: PictureBookState | null;
  onPictureBookLoaded: PictureBookStateSetter;
  onPlaybackStopped: () => void;
  onClose: () => void;
}) {
  const rootRef = useRef<HTMLDivElement | null>(null);
  const closingRef = useRef(false);
  const enteredFullscreenRef = useRef(false);
  const [currentCue, setCurrentCue] = useState<NonNullable<ListeningSongPositionPayload['cue']> | null>(null);
  const [currentLineIndex, setCurrentLineIndex] = useState(0);
  const [positionMs, setPositionMs] = useState(0);
  const [durationMs, setDurationMs] = useState(version.durationMs ?? 0);
  const [status, setStatus] = useState<'starting' | 'playing' | 'paused' | 'completed' | 'error'>('starting');
  const [error, setError] = useState<string | null>(null);
  const [controlsVisible, setControlsVisible] = useState(false);
  const [cursorVisible, setCursorVisible] = useState(false);
  const controlsHideTimerRef = useRef<number | null>(null);
  const cursorHideTimerRef = useRef<number | null>(null);
  const stoppedRef = useRef(false);
  const onPlaybackStoppedRef = useRef(onPlaybackStopped);
  const articleId = article.id ?? 0;
  const currentPage = currentPictureBookPage(pictureBookState, currentLineIndex);
  const nextFullscreenPage = nextPictureBookPage(pictureBookState, currentPage);
  // "display" (1280x720) is the largest bitmap the WebView should ever render; the raw
  // 2560x1440 original corrupts on some Windows GPU drivers when downscaled into the
  // window (blocky color noise). 1280x720 is also the product-facing resolution.
  useEnsurePictureBookPageImage({
    articleId,
    state: pictureBookState,
    page: currentPage,
    imageVariant: 'display',
    onPictureBookLoaded,
  });
  useEnsurePictureBookPageImage({
    articleId,
    state: pictureBookState,
    page: nextFullscreenPage,
    imageVariant: 'display',
    onPictureBookLoaded,
  });
  const imageSrc = pageHasPictureBookImageVariant(currentPage, 'display')
    ? directImageSource(currentPage?.imageUri) ?? ''
    : '';
  const safeDurationMs = Math.max(0, durationMs || version.durationMs || 0);
  const progress = safeDurationMs > 0
    ? Math.min(100, Math.max(0, Math.round((positionMs / safeDurationMs) * 100)))
    : 0;
  const title = version.title?.trim() || article.title;
  const english = currentCue?.english?.trim() || title;
  const chinese = currentCue?.chinese?.trim() || '';
  const keepControlsVisible = status === 'paused' || status === 'completed' || status === 'error';
  const shouldShowControls = controlsVisible || keepControlsVisible;
  const statusText =
    status === 'completed'
      ? '播放完成'
      : status === 'paused'
        ? '已暂停'
        : status === 'starting'
          ? '正在启动'
          : '正在播放';

  const clearControlsHideTimer = () => {
    if (controlsHideTimerRef.current !== null) {
      window.clearTimeout(controlsHideTimerRef.current);
      controlsHideTimerRef.current = null;
    }
  };

  const clearCursorHideTimer = () => {
    if (cursorHideTimerRef.current !== null) {
      window.clearTimeout(cursorHideTimerRef.current);
      cursorHideTimerRef.current = null;
    }
  };

  useEffect(() => {
    onPlaybackStoppedRef.current = onPlaybackStopped;
  }, [onPlaybackStopped]);

  const showControls = () => {
    setControlsVisible(true);
    clearControlsHideTimer();
    if (!keepControlsVisible) {
      controlsHideTimerRef.current = window.setTimeout(() => {
        setControlsVisible(false);
        controlsHideTimerRef.current = null;
      }, 3000);
    }
  };

  const showCursorTemporarily = () => {
    setCursorVisible(true);
    clearCursorHideTimer();
    cursorHideTimerRef.current = window.setTimeout(() => {
      setCursorVisible(false);
      cursorHideTimerRef.current = null;
    }, 2000);
  };

  useEffect(() => {
    const element = rootRef.current;
    if (!element) return undefined;

    const request = element.requestFullscreen?.();
    if (request) {
      request
        .then(() => {
          enteredFullscreenRef.current = true;
        })
        .catch(() => {
          enteredFullscreenRef.current = false;
        });
    }

    const onFullscreenChange = () => {
      if (enteredFullscreenRef.current && !document.fullscreenElement && !closingRef.current) {
        onClose();
      }
    };
    document.addEventListener('fullscreenchange', onFullscreenChange);
    return () => {
      document.removeEventListener('fullscreenchange', onFullscreenChange);
    };
  }, [onClose]);

  useEffect(() => {
    let cancelled = false;
    stoppedRef.current = false;
    setStatus('starting');
    setError(null);
    setCurrentCue(null);
    setCurrentLineIndex(Math.max(0, startLineIndex));
    setPositionMs(0);
    setDurationMs(version.durationMs ?? 0);

    sendNative('listening.songPlay', {
      articleId,
      versionId: version.id,
      startLineIndex: Math.max(0, startLineIndex),
    })
      .then(() => {
        if (cancelled) return;
        setStatus((current) => (current === 'paused' ? current : 'playing'));
      })
      .catch((playError) => {
        if (cancelled) return;
        setStatus('error');
        setError(playError instanceof Error ? playError.message : '歌曲全屏播放失败');
      });

    return () => {
      cancelled = true;
      if (!stoppedRef.current) {
        stoppedRef.current = true;
        onPlaybackStoppedRef.current();
        void sendNative('listening.songStop', { articleId }).catch(() => undefined);
      }
    };
  }, [articleId, startLineIndex, version.id]);

  useEffect(() => {
    if (keepControlsVisible) {
      clearControlsHideTimer();
      setControlsVisible(true);
      return undefined;
    }
    if (!controlsVisible) {
      return undefined;
    }
    clearControlsHideTimer();
    controlsHideTimerRef.current = window.setTimeout(() => {
      setControlsVisible(false);
      controlsHideTimerRef.current = null;
    }, 3000);
    return () => {
      clearControlsHideTimer();
    };
  }, [controlsVisible, keepControlsVisible]);

  useEffect(() => {
    return () => {
      clearControlsHideTimer();
      clearCursorHideTimer();
    };
  }, []);

  useEffect(() => {
    return onNativeEvent<ListeningSongPositionPayload>('listening.song.position', (payload) => {
      if (payload.articleId !== articleId) return;
      if (payload.versionId && payload.versionId !== version.id) return;
      const nextDurationMs = payload.durationMs ?? 0;
      setPositionMs(Math.max(0, payload.positionMs));
      setDurationMs((current) => (nextDurationMs > 0 ? nextDurationMs : current));
      if (payload.cue) {
        setCurrentCue(payload.cue);
        setCurrentLineIndex(payload.cue.lineIndex);
        setStatus((current) => (current === 'paused' ? current : 'playing'));
        return;
      }
      if (
        nextDurationMs > 0 &&
        payload.positionMs >= Math.max(0, nextDurationMs - 250)
      ) {
        setStatus('completed');
      }
    });
  }, [articleId, version.id]);

  const close = () => {
    closingRef.current = true;
    if (document.fullscreenElement) {
      void document.exitFullscreen().catch(() => undefined);
    }
    onClose();
  };

  const togglePause = async () => {
    if (status === 'paused') {
      const payload = await sendNative<ListeningResumePayload>('listening.songResume');
      if (payload.resumed) {
        setStatus('playing');
      }
      return;
    }
    if (status !== 'playing' && status !== 'starting') {
      return;
    }
    const payload = await sendNative<ListeningPausePayload>('listening.songPause');
    if (payload.paused) {
      setStatus('paused');
    }
  };

  const rootClassName = [
    'fullscreen-listening',
    'fullscreen-song',
    shouldShowControls ? 'controls-visible' : 'controls-hidden',
    cursorVisible ? 'cursor-visible' : 'cursor-hidden',
  ].join(' ');

  return createPortal(
    <div
      className={rootClassName}
      ref={rootRef}
      role="dialog"
      aria-modal="true"
      aria-label="全屏歌曲播放"
      onClick={showControls}
      onPointerMove={showCursorTemporarily}
    >
      <div className="fullscreen-listening-stage">
        <div className="fullscreen-listening-frame">
          {imageSrc ? (
            <img src={imageSrc} alt="" />
          ) : (
            <div className="fullscreen-listening-missing">
              <Icon name="spark" />
              <span>绘本图暂不可用</span>
            </div>
          )}
          <div className="fullscreen-listening-subtitles">
            <h1>{english}</h1>
            {chinese && <p>{chinese}</p>}
          </div>
        </div>
      </div>
      <div
        className="fullscreen-listening-toolbar"
        aria-hidden={!shouldShowControls}
        onClick={(event) => event.stopPropagation()}
      >
        <div className="fullscreen-listening-progress" aria-label={`播放进度 ${progress}%`}>
          <span style={{ width: `${progress}%` }} />
        </div>
        <div className="fullscreen-listening-meta">
          <strong>{title}</strong>
          <small>
            {statusText} · {formatDurationMs(positionMs)} / {safeDurationMs > 0 ? formatDurationMs(safeDurationMs) : '--:--'}
          </small>
        </div>
        {error && <p className="fullscreen-listening-error">{error}</p>}
        <div className="fullscreen-listening-actions">
          <button
            className="ghost-action"
            type="button"
            onClick={(event) => {
              event.stopPropagation();
              void togglePause();
            }}
            disabled={status === 'completed' || status === 'error'}
          >
            <Icon name={status === 'paused' ? 'play' : 'pause'} />
            {status === 'paused' ? '继续' : '暂停'}
          </button>
          <button
            className="primary-action"
            type="button"
            onClick={(event) => {
              event.stopPropagation();
              close();
            }}
          >
            <Icon name="exit" /> 退出全屏
          </button>
        </div>
      </div>
    </div>,
    document.body,
  );
}

function ClickableEnglishText({
  text,
  sentence,
  onWordClick,
  highlightFirst = false,
}: {
  text: string;
  sentence: string;
  onWordClick: (word: string, sentence: string, anchor: DOMRect) => void;
  highlightFirst?: boolean;
}) {
  let highlighted = false;
  return (
    <>
      {tokenizeEnglishText(text).map((token, index) => {
        if (!token.word) {
          return <span key={`${token.text}-${index}`}>{token.text}</span>;
        }
        const isFirstWord = highlightFirst && !highlighted;
        highlighted = true;

        return (
          <button
            className={`word-token ${isFirstWord ? 'first-word' : ''}`}
            key={`${token.text}-${index}`}
            type="button"
            onClick={(event) => {
              event.stopPropagation();
              onWordClick(token.text, sentence, event.currentTarget.getBoundingClientRect());
            }}
          >
            {token.text}
          </button>
        );
      })}
    </>
  );
}

function WordTranslationCard({
  state,
  onClose,
  onReplay,
}: {
  state: WordCardState;
  onClose: () => void;
  onReplay: () => void;
}) {
  const lookup = state.lookup;
  const phonetic = lookup?.phonetic.trim() || '/.../';
  const meaning = lookup?.meaning.trim();
  const sentenceMeaning = lookup?.sentenceMeaning.trim();

  return (
    <>
      <div
        className="word-card-dismiss-layer"
        role="presentation"
        onMouseDown={(event) => {
          event.preventDefault();
          void onClose();
        }}
      />
      <section
        className={`word-card ${state.position.placement}`}
        role="dialog"
        aria-labelledby="word-card-title"
        style={{
          top: `${state.position.top}px`,
          left: `${state.position.left}px`,
        }}
      >
        <button className="word-card-close" type="button" aria-label="关闭单词翻译" onClick={() => void onClose()}>
          <Icon name="exit" />
        </button>
        <p className="eyebrow">Word</p>
        <h2 id="word-card-title">{lookup?.word || state.word}</h2>
        <div className="word-phonetic-row">
          <span>{phonetic}</span>
          <button
            className={`word-sound-button ${state.playing ? 'active' : ''}`}
            type="button"
            aria-label={`播放 ${state.word} 发音`}
            onClick={() => onReplay()}
          >
            <Icon name="sound" />
          </button>
        </div>

        {state.loading && (
          <div className="word-card-loading">
            <span />
            <span />
          </div>
        )}

        {state.error && <p className="word-card-error">{state.error}</p>}

        {!state.loading && (
          <dl className="word-meaning-list">
            <div>
              <dt>含义</dt>
              <dd>{meaning || '这个单词的含义暂不可用。'}</dd>
            </div>
            <div>
              <dt>本句中的含义</dt>
              <dd>{sentenceMeaning || '请结合原句理解这个单词。'}</dd>
            </div>
          </dl>
        )}
      </section>
    </>
  );
}

function FollowPage({
  articleId,
  state,
  pictureBookState,
  onNavigate,
  onLoaded,
  onPictureBookLoaded,
  pictureBookRetryGate,
  onOpenPicturePromptReview,
  preloadState,
}: {
  articleId: number;
  state: FollowState | null;
  pictureBookState: PictureBookState | null;
  onNavigate: (path: string) => void;
  onLoaded: (state: FollowState) => void;
  onPictureBookLoaded: PictureBookStateSetter;
  pictureBookRetryGate: PictureBookRetryGate;
  onOpenPicturePromptReview: (articleId: number, regenerate?: boolean) => void | Promise<void>;
  preloadState?: PreloadState;
}) {
  const [commandBusy, setCommandBusy] = useState(false);
  const [activeFollowControl, setActiveFollowControl] = useState<FollowControl | null>(null);
  const [wordCard, setWordCard] = useState<WordCardState | null>(null);
  const wordCardTokenRef = useRef(0);

  useEffect(() => {
    let isMounted = true;

    setCommandBusy(false);
    setWordCard(null);
    wordCardTokenRef.current += 1;
    onLoaded({ status: 'loading' });
    onPictureBookLoaded(loadingPictureBookState(articleId));

    const openAndPlay = async () => {
      try {
        const payload = await sendNative<FollowState>('follow.open', { articleId });
        if (!isMounted || !payload) return;
        onLoaded(payload);
        sendNative<PictureBookState>('pictureBook.state', { articleId, includeImageUris: true })
          .then((picturePayload) => {
            if (isMounted) {
              onPictureBookLoaded((current) => mergePictureBookState(current, picturePayload));
            }
          })
          .catch(() => undefined);
        if (payload.status === 'ready' && payload.step !== 'completed') {
          const played = await sendNative<FollowState>('follow.play');
          if (isMounted && played) onLoaded(played);
        }
      } catch (error) {
        if (!isMounted) return;
        onLoaded({
          status: 'error',
          step: 'idle',
          playbackState: 'failed',
          error: error instanceof Error ? error.message : '无法打开跟读任务',
        });
      }
    };

    void openAndPlay();
    return () => {
      isMounted = false;
      wordCardTokenRef.current += 1;
      void sendNative('word.stop').catch(() => undefined);
    };
  }, [articleId, onLoaded, onPictureBookLoaded]);

  useEffect(() => {
    if (!wordCard) return undefined;

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        void closeWordCard();
      }
    };

    window.addEventListener('keydown', onKeyDown);
    return () => {
      window.removeEventListener('keydown', onKeyDown);
    };
  }, [wordCard]);

  const runFollowCommand = async (
    type: string,
    activeControl?: FollowControl,
  ): Promise<FollowState | null> => {
    setCommandBusy(true);
    if (activeControl) setActiveFollowControl(activeControl);
    try {
      const payload = await sendNative<FollowState>(type);
      if (payload) onLoaded(payload);
      return payload ?? null;
    } catch (error) {
      onLoaded({
        status: 'error',
        step: 'idle',
        playbackState: 'failed',
        error: error instanceof Error ? error.message : '跟读操作失败，请重试',
      });
      return null;
    } finally {
      setCommandBusy(false);
      if (activeControl) setActiveFollowControl(null);
    }
  };

  const playCurrent = () => {
    void runFollowCommand('follow.play', 'source');
  };

  const playRecording = () => {
    void runFollowCommand('follow.recordReplay', 'recording');
  };

  const playWordAudio = async (word: string, token = wordCardTokenRef.current) => {
    setWordCard((current) =>
      current && wordCardTokenRef.current === token
        ? { ...current, playing: true, error: null }
        : current,
    );
    try {
      await sendNative<WordPlaybackPayload>('word.play', { word });
    } catch (playError) {
      if (wordCardTokenRef.current === token) {
        setWordCard((current) =>
          current
            ? {
                ...current,
                error: playError instanceof Error ? playError.message : '单词发音失败',
              }
            : current,
        );
      }
    } finally {
      if (wordCardTokenRef.current === token) {
        setWordCard((current) => (current ? { ...current, playing: false } : current));
      }
    }
  };

  const openWordCard = async (word: string, sentence: string, anchor: DOMRect) => {
    const normalizedWord = normalizeLookupWord(word);
    if (!normalizedWord) return;

    const token = ++wordCardTokenRef.current;
    const shouldPauseFollow = state?.step === 'playing';
    let resumeBackground = false;

    setWordCard({
      word: normalizedWord,
      sentence,
      resumeBackground: false,
      loading: true,
      playing: false,
      position: wordCardPositionFor(anchor),
      error: null,
    });

    try {
      if (shouldPauseFollow) {
        const pausePayload = await sendNative<ListeningPausePayload>('follow.pause');
        resumeBackground = Boolean(pausePayload.paused);
        if (wordCardTokenRef.current !== token) return;
        setWordCard((current) => (current ? { ...current, resumeBackground } : current));
      }

      void playWordAudio(normalizedWord, token);

      const lookup = await sendNative<WordLookupPayload>('word.lookup', {
        word: normalizedWord,
        sentence,
      });
      if (wordCardTokenRef.current !== token) return;
      setWordCard((current) =>
        current
          ? {
              ...current,
              lookup,
              loading: false,
              error: null,
            }
          : current,
      );
    } catch (lookupError) {
      if (wordCardTokenRef.current !== token) return;
      setWordCard((current) =>
        current
          ? {
              ...current,
              loading: false,
              error: lookupError instanceof Error ? lookupError.message : '单词解释加载失败',
            }
          : current,
      );
    }
  };

  const closeWordCard = async () => {
    const current = wordCard;
    const shouldResume = Boolean(current?.resumeBackground);
    wordCardTokenRef.current += 1;
    setWordCard(null);
    try {
      await sendNative('word.stop');
    } catch {
      // Word playback cleanup is best effort.
    }

    if (shouldResume) {
      try {
        await sendNative<ListeningResumePayload>('follow.resume');
      } catch {
        // If the original playback ended or was stopped, there is nothing to resume.
      }
    }
  };

  const stopRecordingAndAutoPlay = () => {
    void (async () => {
      const stopped = await runFollowCommand('follow.recordStop', 'record');
      if (stopped?.status === 'ready' && stopped.step !== 'completed' && stopped.hasRecording) {
        await runFollowCommand('follow.recordReplay', 'recording');
      }
    })();
  };

  const advanceSentence = () => {
    void (async () => {
      setCommandBusy(true);
      try {
        const next = await sendNative<FollowState>('follow.next');
        if (next) onLoaded(next);
        if (next?.status === 'ready' && next.step !== 'completed') {
          const played = await sendNative<FollowState>('follow.play');
          if (played) onLoaded(played);
        }
      } catch (error) {
        onLoaded({
          status: 'error',
          step: 'idle',
          playbackState: 'failed',
          error: error instanceof Error ? error.message : '无法进入下一句，请重试',
        });
      } finally {
        setCommandBusy(false);
      }
    })();
  };

  const currentIndex = state?.currentIndex ?? 0;
  const picturePage = currentPictureBookPage(pictureBookState, currentIndex);
  usePredecodePictureBookImages(articleId, pictureBookState, picturePage);
  useEnsurePictureBookPageImage({
    articleId,
    state: pictureBookState,
    page: picturePage,
    imageVariant: 'display',
    onPictureBookLoaded,
  });

  if (!state || state.status === 'loading') {
    return (
      <section className="page follow-page">
        <TopBar title="跟读练习准备中" onBack={() => onNavigate('/')}>
          <button className="ghost-action" onClick={() => onNavigate('/')}>
            <Icon name="exit" /> 退出
          </button>
        </TopBar>
        <LoadingPanel text="正在准备句子、中文翻译和原音" />
      </section>
    );
  }

  if (state.status === 'error') {
    return (
      <section className="page follow-page">
        <TopBar title="跟读练习暂时打不开" onBack={() => onNavigate('/')}>
          <button className="ghost-action" onClick={() => onNavigate('/')}>
            <Icon name="exit" /> 退出
          </button>
        </TopBar>
        <section className="loading-panel">
          <span className="assistant-avatar large" aria-hidden="true">T</span>
          <p>{state.error ?? '跟读任务打开失败，请回到书库后重试。'}</p>
        </section>
      </section>
    );
  }

  const step = state?.step ?? 'idle';
  const currentSentence = state?.currentSentence ?? '正在准备句子...';
  const currentTranslation = state?.currentTranslation ?? '';
  const result = state?.result;
  const totalSentences = state?.totalSentences ?? 0;
  const visibleSentenceTotal = state?.visibleSentenceCount ?? totalSentences;
  const visibleCurrentPosition = visiblePositionForSlotIndex(
    state?.article?.sentences ?? [],
    currentIndex,
  );
  const canInterruptRecordingPlayback =
    commandBusy &&
    activeFollowControl === 'recording' &&
    Boolean(state?.hasRecording) &&
    step !== 'recording' &&
    step !== 'scoring';
  const bottomActionsDisabled = isFollowActionLocked(step) || commandBusy;
  const canPlaySource = !bottomActionsDisabled && step !== 'completed';
  const canPlayRecording = !bottomActionsDisabled && step !== 'completed' && Boolean(state?.hasRecording);
  const canAdvanceSentence =
    (!bottomActionsDisabled || canInterruptRecordingPlayback) &&
    step !== 'completed' &&
    visibleSentenceTotal > 0;
  const advanceLabel = state?.isLastSentence ? '完成' : '下一句';
  const canRecordCurrent =
    !commandBusy &&
    (step === 'recording' || step === 'result' || (step === 'idle' && state?.playbackState === 'success'));
  const sourceActive = activeFollowControl === 'source' && ['loadingTts', 'playing'].includes(step);
  const recordActive = step === 'recording' || step === 'scoring';
  const recordingPlaybackActive = activeFollowControl === 'recording' && step === 'playing';
  const liveTranscript = (state?.liveRecognizedText || result?.recognizedText || '').trim();
  const transcriptHint =
    step === 'recording'
      ? liveTranscript || '正在听你朗读...'
      : step === 'scoring'
        ? liveTranscript || '正在整理识别结果...'
      : liveTranscript;
  const titleParts = storyTitlePartsFor(state?.article, pictureBookState, '跟读任务');
  const retryPicturePage = (page: PictureBookPage) => {
    if (!pictureBookRetryGate.begin(articleId, page.pageIndex)) {
      return;
    }

    void Promise.resolve(onOpenPicturePromptReview(articleId, true))
      .catch(() => undefined)
      .finally(() => {
        pictureBookRetryGate.finish(articleId, page.pageIndex);
      });
  };

  return (
    <section className="page follow-page">
      <TopBar title={<StoryTitle parts={titleParts} />} onBack={() => onNavigate('/')}>
        <Pager current={visibleCurrentPosition || 1} total={visibleSentenceTotal || 2} />
        <button className="ghost-action" onClick={() => onNavigate('/')}>
          <Icon name="exit" /> 退出
        </button>
      </TopBar>

      <div className="follow-layout">
        <main className="follow-main">
          <PreloadStatusStrip state={preloadState} />
          <PictureBookScene
            state={pictureBookState}
            page={picturePage}
            english={currentSentence}
            chinese={currentTranslation}
            englishActive={sourceActive}
            onWordClick={openWordCard}
            onRetry={retryPicturePage}
            isRetrying={picturePage ? pictureBookRetryGate.isRetrying(articleId, picturePage.pageIndex) : false}
          />
          {state?.playbackError && <p className="error-text">{state.playbackError}</p>}
          {state?.error && <p className="error-text">{state.error}</p>}
          <div className="follow-control-panel">
            {transcriptHint && <p className="follow-live-transcript">{transcriptHint}</p>}
            <div className="follow-control-row">
              <div className="follow-control-deck" aria-label="跟读控制">
                <button
                  className={`follow-control-button source ${sourceActive ? 'active' : ''}`}
                  type="button"
                  onClick={playCurrent}
                  disabled={!canPlaySource}
                >
                  <span className="follow-control-icon-shell">
                    <Icon name={sourceActive ? 'sound' : 'play'} />
                  </span>
                  <span className="follow-control-label">播放原音</span>
                </button>
                <button
                  className={`follow-control-button record ${recordActive ? 'active' : ''}`}
                  type="button"
                  aria-label={step === 'recording' ? '停止录音' : step === 'scoring' ? '评分中' : '开始录音'}
                  onClick={() => {
                    if (step === 'recording') {
                      stopRecordingAndAutoPlay();
                    } else {
                      void runFollowCommand('follow.recordStart', 'record');
                    }
                  }}
                  disabled={!canRecordCurrent}
                >
                  <span className="follow-control-icon-shell">
                    <Icon name={step === 'recording' ? 'stop' : 'mic'} />
                  </span>
                  <span className="follow-control-label">
                    {step === 'recording' ? '停止录音' : step === 'scoring' ? '评分中' : '录音'}
                  </span>
                </button>
                <button
                  className={`follow-control-button recording ${recordingPlaybackActive ? 'active' : ''}`}
                  type="button"
                  onClick={playRecording}
                  disabled={!canPlayRecording}
                >
                  <span className="follow-control-icon-shell">
                    <Icon name={recordingPlaybackActive ? 'sound' : 'replay'} />
                  </span>
                  <span className="follow-control-label">播放录音</span>
                </button>
                {result && <FollowScoreBadge result={result} compact />}
              </div>
              <button className="primary-action follow-next-action" onClick={advanceSentence} disabled={!canAdvanceSentence}>
                {advanceLabel} <Icon name="arrow" />
              </button>
            </div>
          </div>
        </main>

      </div>
      {wordCard && (
        <WordTranslationCard
          state={wordCard}
          onClose={closeWordCard}
          onReplay={() => void playWordAudio(wordCard.word)}
        />
      )}
    </section>
  );
}

function currentPictureBookPage(
  state: PictureBookState | null,
  currentIndex: number,
): PictureBookPage | null {
  if (!state?.pages.length) return null;
  return (
    state.pages.find(
      (page) =>
        currentIndex >= page.sentenceStartIndex &&
        currentIndex <= page.sentenceEndIndex,
    ) ?? state.pages[0]
  );
}

function nextPictureBookPage(
  state: PictureBookState | null,
  currentPage: PictureBookPage | null,
): PictureBookPage | null {
  if (!state?.pages.length || !currentPage) return null;
  const orderedPages = [...state.pages].sort((left, right) => left.pageIndex - right.pageIndex);
  const currentPosition = orderedPages.findIndex(
    (page) => page.pageIndex === currentPage.pageIndex,
  );
  if (currentPosition < 0 || currentPosition + 1 >= orderedPages.length) {
    return null;
  }
  return orderedPages[currentPosition + 1];
}

function listeningFullscreenAudioReadiness(
  payload: ListeningFullscreenReadyPayload | null,
  loading: boolean,
): FullscreenReadiness {
  if (loading && !payload?.ready) {
    return { ready: false, reason: '正在确认当前和下一句音频是否已加载...' };
  }
  if (!payload) {
    return { ready: false, reason: '正在等待音频预加载状态...' };
  }
  if (payload.ready) {
    return { ready: true, reason: '' };
  }
  const reasons = Array.isArray(payload.reasons)
    ? payload.reasons.filter((reason) => String(reason).trim())
    : [];
  const readyEnglish = Number(payload.readyEnglish ?? 0);
  const requiredEnglish = Number(payload.requiredEnglish ?? 0);
  if (reasons.length > 0) {
    return { ready: false, reason: String(reasons[0]) };
  }
  if (readyEnglish < requiredEnglish) {
    return {
      ready: false,
      reason: `当前和下一句英文音频正在预热 ${readyEnglish} / ${requiredEnglish}`,
    };
  }
  return { ready: false, reason: '当前和下一句音频还没有完成预热' };
}

function pictureBookFullscreenReadiness(
  state: PictureBookState | null,
  items: ListeningItem[],
  decodeState: PictureBookDecodeState,
  options: { requireDecodedImages?: boolean } = {},
): FullscreenReadiness {
  const visibleItems = visibleListeningItems(items);
  if (visibleItems.length === 0) {
    return { ready: false, reason: '这篇文章还没有可播放的句子' };
  }
  if (!state || state.status === 'loading') {
    return { ready: false, reason: '正在读取绘本图状态...' };
  }
  if (state.pages.length === 0) {
    return { ready: false, reason: '绘本图还没有准备好' };
  }
  const failed = state.pages.find((page) => page.status === 'error' || page.status === 'skipped');
  if (failed) {
    return {
      ready: false,
      reason: failed.errorMessage?.trim() || '绘本图生成失败，请先重试绘本图',
    };
  }
  const generating = state.pages.some((page) =>
    ['queued', 'prompting', 'generating'].includes(page.status),
  );
  if (generating || state.status === 'generating') {
    return { ready: false, reason: '绘本图正在生成中...' };
  }
  const notReady = state.pages.some((page) => page.status !== 'ready');
  if (notReady) {
    return { ready: false, reason: '绘本图还没有全部生成完成' };
  }
  const missingSentence = visibleItems.find(
    (item) =>
      !state.pages.some(
        (page) =>
          item.index >= page.sentenceStartIndex &&
          item.index <= page.sentenceEndIndex,
      ),
  );
  if (missingSentence) {
    return { ready: false, reason: '绘本分镜还没有覆盖全部句子' };
  }
  if (options.requireDecodedImages === false) {
    return { ready: true, reason: '' };
  }
  if (decodeState.missingImagePages.length > 0) {
    return { ready: false, reason: '正在准备当前和下一张绘本图...' };
  }
  if (decodeState.failed > 0) {
    return { ready: false, reason: '有绘本图片载入失败，请退出后重试' };
  }
  if (!decodeState.ready) {
    return {
      ready: false,
      reason: `正在载入当前和下一张绘本图 ${decodeState.decoded} / ${decodeState.total}`,
    };
  }
  return { ready: true, reason: '' };
}

function combineFullscreenReadiness(
  audio: FullscreenReadiness,
  picture: FullscreenReadiness,
): FullscreenReadiness {
  if (!audio.ready) {
    return audio;
  }
  if (!picture.ready) {
    return picture;
  }
  return { ready: true, reason: '全屏播放已准备好' };
}

function songFullscreenReadinessForVersion({
  version,
  hasSongVersions,
  songGenerating,
  recordingBusy,
  pictureReadiness,
}: {
  version: SongVersionPayload | null;
  hasSongVersions: boolean;
  songGenerating: boolean;
  recordingBusy: boolean;
  pictureReadiness: FullscreenReadiness;
}): FullscreenReadiness {
  if (!hasSongVersions) {
    return { ready: false, reason: '还没有本地歌曲，请到创作中心生成或下载。' };
  }
  if (songGenerating) {
    return { ready: false, reason: '歌曲正在生成或下载中...' };
  }
  if (recordingBusy) {
    return { ready: false, reason: '正在导出视频，请等待完成后再全屏播放。' };
  }
  if (!version) {
    return { ready: false, reason: '请选择要全屏播放的歌曲。' };
  }
  if (!version.audioPath?.trim()) {
    return { ready: false, reason: '这首歌还没有本地音频文件。' };
  }
  const timelineStatus = String(version.timelineStatus ?? '').trim();
  if (timelineStatus !== 'ready' || !version.timelinePath?.trim()) {
    return {
      ready: false,
      reason: songSubtitleNoticeForVersion(version) ?? '这首歌还没有生成字幕，请到创作中心生成歌曲字幕。',
    };
  }
  if (!pictureReadiness.ready) {
    return pictureReadiness;
  }
  return { ready: true, reason: '歌曲全屏播放已准备好' };
}

function songVideoExportReadinessForVersion({
  version,
  hasSongVersions,
  songGenerating,
  recordingBusy,
  recordingSettingsLoaded,
  pictureReadiness,
}: {
  version: SongVersionPayload | null;
  hasSongVersions: boolean;
  songGenerating: boolean;
  recordingBusy: boolean;
  recordingSettingsLoaded: boolean;
  pictureReadiness: FullscreenReadiness;
}): FullscreenReadiness {
  if (!recordingSettingsLoaded) {
    return { ready: false, reason: '正在读取录制设置' };
  }
  if (!hasSongVersions) {
    return { ready: false, reason: '还没有本地歌曲，请到创作中心生成或下载。' };
  }
  if (songGenerating) {
    return { ready: false, reason: '歌曲正在生成或下载中，请等待完成后再导出视频。' };
  }
  if (recordingBusy) {
    return { ready: false, reason: '正在导出视频，请等待完成后再导出。' };
  }
  if (!version) {
    return { ready: false, reason: '请选择要导出视频的歌曲。' };
  }
  if (!version.audioPath?.trim()) {
    return { ready: false, reason: '这首歌还没有本地音频文件。' };
  }
  const timelineStatus = String(version.timelineStatus ?? '').trim();
  if (timelineStatus !== 'ready' || !version.timelinePath?.trim()) {
    return {
      ready: false,
      reason: songSubtitleNoticeForVersion(version) ?? '这首歌还没有生成字幕，请到创作中心生成歌曲字幕。',
    };
  }
  if (!pictureReadiness.ready) {
    return pictureReadiness;
  }
  return { ready: true, reason: '歌曲视频导出已准备好' };
}

type ChatTimelineEntry =
  | {
      kind: 'scene';
      key: string;
      page: PictureBookPage | null;
    }
  | {
      kind: 'message';
      key: string;
      message: ChatState['messages'][number];
    };

function pictureBookPagesForChatConversation(
  state: PictureBookState | null,
  questionCount: number,
): PictureBookPage[] {
  if (!state?.pages.length) {
    return [];
  }

  const orderedPages = [...state.pages].sort((left, right) => left.pageIndex - right.pageIndex);
  // Keep chat scene changes aligned to storyboard beats instead of jumping across
  // multiple multi-sentence pages on a single question round.
  const visibleCount = Math.min(
    orderedPages.length,
    Math.max(questionCount, 1),
  );
  return orderedPages.slice(0, visibleCount);
}

function buildChatTimelineEntries(
  messages: ChatState['messages'],
  pages: PictureBookPage[],
  showLeadingScene: boolean,
): ChatTimelineEntry[] {
  const orderedPages = [...pages].sort((left, right) => left.pageIndex - right.pageIndex);
  const sceneEntries: Array<PictureBookPage | null> =
    orderedPages.length > 0 ? orderedPages : showLeadingScene ? [null] : [];
  const timeline: ChatTimelineEntry[] = [];
  const scenesByPosition = new Map<number, Array<PictureBookPage | null>>();

  sceneEntries.forEach((page, index) => {
    const position =
      index === 0
        ? 0
        : Math.min(
            messages.length,
            Math.max(1, Math.round((index / sceneEntries.length) * messages.length)),
          );
    const bucket = scenesByPosition.get(position) ?? [];
    bucket.push(page);
    scenesByPosition.set(position, bucket);
  });

  const pushScenes = (position: number) => {
    const bucket = scenesByPosition.get(position) ?? [];
    bucket.forEach((page, index) => {
      timeline.push({
        kind: 'scene',
        key: page ? `scene-${page.pageIndex}` : `scene-loading-${position}-${index}`,
        page,
      });
    });
  };

  pushScenes(0);
  messages.forEach((message, index) => {
    timeline.push({
      kind: 'message',
      key: message.id,
      message,
    });
    pushScenes(index + 1);
  });

  return timeline;
}

function useEnsurePictureBookPageImage({
  articleId,
  state,
  page,
  imageVariant = 'full',
  onPictureBookLoaded,
}: {
  articleId: number;
  state: PictureBookState | null;
  page: PictureBookPage | null;
  imageVariant?: PictureBookImageVariant;
  onPictureBookLoaded: PictureBookStateSetter;
}) {
  const requestKeyRef = useRef('');
  const stateArticleId = state?.articleId ?? null;
  const pageIndex = page?.pageIndex ?? -1;
  const pageStatus = page?.status ?? '';
  const imagePath = page?.imagePath?.trim() ?? '';
  const hasRequiredImage = pageHasPictureBookImageVariant(page, imageVariant);

  useEffect(() => {
    if (stateArticleId !== articleId || pageIndex < 0) {
      requestKeyRef.current = '';
      return;
    }
    if (pageStatus !== 'ready' || hasRequiredImage || !imagePath) {
      return;
    }

    const requestKey = `${imageVariant}:${articleId}:${pageIndex}:${imagePath}`;
    if (requestKeyRef.current === requestKey) {
      return;
    }
    requestKeyRef.current = requestKey;

    let isMounted = true;
    sendNative<PictureBookPageImagePayload>('pictureBook.pageImage', {
      articleId,
      pageIndex,
      variant: imageVariant,
    })
      .then((payload) => {
        if (!isMounted) {
          return;
        }
        onPictureBookLoaded((current) => mergePictureBookPageImage(current, payload));
      })
      .catch(() => {
        if (requestKeyRef.current === requestKey) {
          requestKeyRef.current = '';
        }
      });

    return () => {
      isMounted = false;
    };
  }, [
    articleId,
    hasRequiredImage,
    imagePath,
    imageVariant,
    onPictureBookLoaded,
    pageIndex,
    pageStatus,
    stateArticleId,
  ]);
}

function useEnsureAllPictureBookPageImages({
  articleId,
  state,
  enabled,
  imageVariant = 'full',
  onPictureBookLoaded,
}: {
  articleId: number;
  state: PictureBookState | null;
  enabled: boolean;
  imageVariant?: 'full' | 'thumbnail';
  onPictureBookLoaded: PictureBookStateSetter;
}) {
  const requestedRef = useRef<Set<string>>(new Set());
  const mountedRef = useRef(true);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  useEffect(() => {
    requestedRef.current = new Set();
  }, [articleId]);

  const missing = enabled && state?.articleId === articleId
    ? state.pages
        .filter((page) => page.status === 'ready')
        .filter((page) => !pageHasPictureBookImageVariant(page, imageVariant) && page.imagePath?.trim())
        .map((page) => ({
          pageIndex: page.pageIndex,
          imagePath: page.imagePath?.trim() ?? '',
        }))
        .filter((page) => {
          const key = `${imageVariant}:${articleId}:${page.pageIndex}:${page.imagePath}`;
          return !requestedRef.current.has(key);
        })
    : [];
  const missingKey = missing
    .map((page) => `${page.pageIndex}:${page.imagePath}`)
    .join('|');

  useEffect(() => {
    if (!enabled || missing.length === 0) return;
    const page = missing[0];
    const key = `${imageVariant}:${articleId}:${page.pageIndex}:${page.imagePath}`;
    requestedRef.current.add(key);
    void sendNative<PictureBookPageImagePayload>('pictureBook.pageImage', {
      articleId,
      pageIndex: page.pageIndex,
      variant: imageVariant,
    })
      .then((payload) => {
        if (mountedRef.current) {
          onPictureBookLoaded((current) => mergePictureBookPageImage(current, payload));
        }
      })
      .catch(() => {
        requestedRef.current.delete(key);
      });
  }, [articleId, enabled, imageVariant, missingKey, onPictureBookLoaded]);
}

function decodeImageSource(src: string): Promise<boolean> {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (ok: boolean) => {
      if (settled) return;
      settled = true;
      window.clearTimeout(timer);
      resolve(ok);
    };
    const timer = window.setTimeout(() => finish(false), PRELOAD_IMAGE_DECODE_TIMEOUT_MS);
    const image = new Image();
    image.decoding = 'async';
    image.onload = () => finish(true);
    image.onerror = () => finish(false);
    image.src = src;
    if (typeof image.decode === 'function') {
      image
        .decode()
        .then(() => finish(true))
        .catch(() => finish(image.complete && image.naturalWidth > 0));
    }
  });
}

function usePredecodePictureBookImages(
  articleId: number,
  state: PictureBookState | null,
  activePage: PictureBookPage | null,
) : PictureBookDecodeState {
  const decodedRef = useRef<Set<string>>(new Set());
  const failedRef = useRef<Set<string>>(new Set());
  const [, setDecodeVersion] = useState(0);

  useEffect(() => {
    decodedRef.current = new Set();
    failedRef.current = new Set();
    setDecodeVersion((version) => version + 1);
  }, [articleId]);

  const activePageIndex = activePage?.pageIndex ?? null;
  const allReadyPages = state?.articleId === articleId
    ? [...state.pages]
        .filter((page) => page.status === 'ready')
        .sort((left, right) => left.pageIndex - right.pageIndex)
    : [];
  const activeReadyPosition = activePageIndex === null
    ? -1
    : allReadyPages.findIndex((page) => page.pageIndex === activePageIndex);
  const readyPages = activeReadyPosition >= 0
    ? allReadyPages.slice(activeReadyPosition, activeReadyPosition + 2)
    : allReadyPages.slice(0, 2);
  const imageItems = readyPages
    .map((page) => ({
      pageIndex: page.pageIndex,
      src: pageHasPictureBookImageVariant(page, 'display') ? directImageSource(page.imageUri) ?? '' : '',
    }))
    .filter((item) => item.src);
  const missingImagePages = readyPages
    .filter((page) => !pageHasPictureBookImageVariant(page, 'display') || !directImageSource(page.imageUri))
    .map((page) => page.pageIndex);
  const pending = imageItems.filter((item) => {
    const key = `${item.pageIndex}:${item.src}`;
    return !decodedRef.current.has(key) && !failedRef.current.has(key);
  });
  const pendingKey = pending
    .map((item) => `${item.pageIndex}:${item.src.length}:${item.src.slice(0, 64)}`)
    .join('|');

  useEffect(() => {
    if (pending.length === 0) return;

    let cancelled = false;
    void (async () => {
      for (const item of pending) {
        if (cancelled) return;
        const key = `${item.pageIndex}:${item.src}`;
        const ok = await decodeImageSource(item.src);
        if (cancelled) return;
        if (ok) {
          decodedRef.current.add(key);
        } else {
          failedRef.current.add(key);
        }
        setDecodeVersion((version) => version + 1);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [pendingKey]);

  const decoded = imageItems.filter((item) =>
    decodedRef.current.has(`${item.pageIndex}:${item.src}`),
  ).length;
  const failed = imageItems.filter((item) =>
    failedRef.current.has(`${item.pageIndex}:${item.src}`),
  ).length;
  const total = readyPages.length;
  return {
    total,
    decoded,
    failed,
    pending: Math.max(0, imageItems.length - decoded - failed),
    ready:
      total > 0 &&
      missingImagePages.length === 0 &&
      failed === 0 &&
      decoded === total,
    missingImagePages,
  };
}

function PreloadStatusStrip({
  state,
}: {
  state?: PreloadState;
}) {
  const [showComplete, setShowComplete] = useState(false);
  const shownCompleteRunRef = useRef<string | null>(null);
  const failed = state?.failed ?? 0;
  const isLoading = state?.status === 'loading';
  const isComplete =
    Boolean(state) && (state?.status === 'complete' || state?.status === 'partial' || state?.status === 'error');
  const runKey = state?.runId ?? `${state?.mode ?? 'image'}:${state?.articleId ?? 0}:${state?.completed ?? 0}:${state?.total ?? 0}`;

  useEffect(() => {
    if (!isComplete || failed > 0) return undefined;
    if (shownCompleteRunRef.current === runKey) return undefined;
    shownCompleteRunRef.current = runKey;
    setShowComplete(true);
    const timer = window.setTimeout(() => setShowComplete(false), PRELOAD_COMPLETE_VISIBLE_MS);
    return () => window.clearTimeout(timer);
  }, [failed, isComplete, runKey]);

  useEffect(() => {
    if (isLoading) {
      setShowComplete(false);
    }
  }, [isLoading, runKey]);

  if (isLoading) {
    const completed = state?.completed ?? 0;
    const total = state?.total ?? 0;
    const suffix = total > 0 ? ` ${Math.min(completed, total)} / ${total}` : '';
    return (
      <div className="preload-status-strip" role="status">
        <Icon name="refresh" />
        <span>正在进行预加载...{suffix}</span>
      </div>
    );
  }

  if (isComplete && failed > 0) {
    return (
      <div className="preload-status-strip warning" role="status">
        <Icon name="spark" />
        <span>预加载完成，{failed} 项失败，可继续边播边加载</span>
      </div>
    );
  }

  if (showComplete) {
    return (
      <div className="preload-status-strip complete" role="status">
        <Icon name="star" />
        <span>完成加载！</span>
      </div>
    );
  }

  return null;
}

function ChatPictureSceneBlock({
  articleId,
  state,
  page,
  onPictureBookLoaded,
  onRetry,
  isRetrying,
}: {
  articleId: number;
  state: PictureBookState | null;
  page: PictureBookPage | null;
  onPictureBookLoaded: PictureBookStateSetter;
  onRetry: (page: PictureBookPage) => void;
  isRetrying: boolean;
}) {
  useEnsurePictureBookPageImage({
    articleId,
    state,
    page,
    imageVariant: 'display',
    onPictureBookLoaded,
  });

  return (
    <div className="chat-scene-block">
      <PictureBookScene
        state={state}
        page={page}
        english=""
        showSubtitles={false}
        onWordClick={() => undefined}
        onRetry={onRetry}
        isRetrying={isRetrying}
      />
    </div>
  );
}

function RecordingProgressCard({
  progress,
  onCancel,
}: {
  progress: ListeningRecordingProgressPayload | null;
  onCancel: () => void;
}) {
  const value = Math.max(0, Math.min(100, Math.round((progress?.progress ?? 0) * 100)));
  const frameText =
    progress && progress.totalFrames > 0
      ? `${progress.completedFrames} / ${progress.totalFrames} 帧`
      : '正在准备';
  return (
    <div className="recording-progress-card" role="status">
      <div>
        <b>{progress?.message?.trim() || '正在录制视频'}</b>
        <small>{frameText}</small>
      </div>
      <ProgressLine value={value} label={`录制进度 ${value}%`} compact />
      <button className="danger-light small" type="button" onClick={() => void onCancel()}>
        取消并退出
      </button>
    </div>
  );
}

function RecordingProgressOverlay({
  progress,
  onCancel,
}: {
  progress: ListeningRecordingProgressPayload | null;
  onCancel: () => void;
}) {
  return createPortal(
    <div className="recording-progress-overlay" role="presentation">
      <section
        className="recording-progress-panel"
        role="dialog"
        aria-modal="true"
        aria-label="录制视频中"
      >
        <div className="recording-progress-heading">
          <b>正在离线渲染录制视频</b>
          <small>录制期间已禁止页面操作，可以随时取消并退出。</small>
        </div>
        <RecordingProgressCard progress={progress} onCancel={onCancel} />
      </section>
    </div>,
    document.body,
  );
}

function RecordingResultCard({
  result,
  onClose,
}: {
  result: ListeningRecordingResultPayload;
  onClose: () => void;
}) {
  const hasWarnings = result.droppedFrameCount > 0 || result.warnings.length > 0;
  const variants = result.videoVariants ?? [];
  const srtVariant = variants.find((variant) => variant.kind === 'srt');
  const subtitledVariant = variants.find((variant) => variant.kind === 'subtitled');
  return (
    <div className={`recording-result-card ${hasWarnings ? 'warning' : ''}`} role="status">
      <div>
        <b>{hasWarnings ? '录制完成，有提示需要留意' : '录制完成'}</b>
        <small>
          {result.resolution} · {String(result.codec).toUpperCase()} · {formatDurationMs(result.durationMs)}
        </small>
      </div>
      {hasWarnings && (
        <ul>
          {result.droppedFrameCount > 0 && <li>丢帧 {result.droppedFrameCount} 帧</li>}
          {result.warnings.map((warning) => (
            <li key={warning}>{warning}</li>
          ))}
        </ul>
      )}
      <p>
        {variants.length > 0 ? (
          <>
            {srtVariant && <span>无内置字幕视频：{srtVariant.videoPath}</span>}
            {(srtVariant?.subtitlePath ?? result.subtitlePath).trim() && (
              <span>字幕：{(srtVariant?.subtitlePath ?? result.subtitlePath).trim()}</span>
            )}
            {subtitledVariant && <span>内置字幕视频：{subtitledVariant.videoPath}</span>}
          </>
        ) : (
          <>
            <span>视频：{result.videoPath}</span>
            {result.subtitlePath.trim() && <span>字幕：{result.subtitlePath}</span>}
          </>
        )}
      </p>
      <button className="ghost-action small" type="button" onClick={onClose}>
        知道了
      </button>
    </div>
  );
}

function RecordingSettingsDialog({
  settings,
  saving,
  onChange,
  onCancel,
  onConfirm,
}: {
  settings: RecordingSettings;
  saving: boolean;
  onChange: (patch: Partial<RecordingSettings>) => void;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  return createPortal(
    <div className="edit-dialog-backdrop recording-settings-backdrop" role="presentation">
      <section
        className="edit-dialog recording-settings-dialog"
        role="dialog"
        aria-modal="true"
        aria-label="录制视频设置"
      >
        <header className="edit-dialog-heading">
          <b>录制视频设置</b>
          <small>文件将保存到程序目录 recording-export 的分类子目录。</small>
        </header>
        <div className="recording-dialog-grid">
          <RecordingChoiceField
            label="编码"
            value={settings.codec}
            options={recordingCodecOptions}
            disabled={saving}
            onChange={(value) => onChange({ codec: value as RecordingSettings['codec'] })}
          />
          <RecordingChoiceField
            label="分辨率"
            value={settings.resolution}
            options={recordingResolutionOptions}
            disabled={saving}
            onChange={(value) => onChange({ resolution: value as RecordingSettings['resolution'] })}
          />
          <RecordingChoiceField
            label="转场"
            value={settings.pageTransition}
            options={recordingTransitionOptions}
            disabled={saving}
            onChange={(value) => onChange({ pageTransition: value as RecordingSettings['pageTransition'] })}
          />
          <RecordingChoiceField
            label="字幕"
            value={settings.subtitleMode}
            options={recordingSubtitleModeOptions}
            disabled={saving}
            onChange={(value) => onChange({ subtitleMode: value as RecordingSettings['subtitleMode'] })}
          />
        </div>
        <footer className="edit-dialog-actions">
          <button className="ghost-action" type="button" disabled={saving} onClick={onCancel}>
            取消
          </button>
          <button className="primary-action" type="button" disabled={saving} onClick={onConfirm}>
            <Icon name="recordVideo" /> {saving ? '准备中' : '开始录制'}
          </button>
        </footer>
      </section>
    </div>,
    document.body,
  );
}

const recordingCodecOptions: SelectOption[] = [
  { value: 'h264', label: 'H.264' },
  { value: 'h265', label: 'H.265 / HEVC' },
];

const recordingResolutionOptions: SelectOption[] = [
  { value: '2560x1440', label: '2560x1440' },
  { value: '1920x1080', label: '1920x1080' },
  { value: '1280x720', label: '1280x720' },
];

const recordingTransitionOptions: SelectOption[] = [
  { value: 'none', label: '不用转场' },
  { value: 'crossFade', label: '淡入淡出' },
  { value: 'panZoomFade', label: '轻微推拉淡入' },
  { value: 'slide', label: '滑动翻页' },
  { value: 'pageCurl', label: '卷边翻页' },
];

const recordingSubtitleModeOptions: SelectOption[] = [
  { value: 'srt', label: '无内置字幕视频 + SRT' },
  { value: 'burnedIn', label: '内置字幕视频' },
  { value: 'both', label: '两版视频 + SRT' },
];

function RecordingChoiceField({
  label,
  value,
  options,
  disabled,
  onChange,
}: {
  label: string;
  value: string;
  options: SelectOption[];
  disabled?: boolean;
  onChange: (value: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const fieldRef = useRef<HTMLDivElement | null>(null);
  const id = useId();
  const labelId = `${id}-label`;
  const valueId = `${id}-value`;
  const listboxId = `${id}-listbox`;
  const selectedOption = options.find((option) => option.value === value) ?? options[0];

  useEffect(() => {
    if (!open) return;
    const onPointerDown = (event: MouseEvent) => {
      if (!fieldRef.current?.contains(event.target as Node)) {
        setOpen(false);
      }
    };
    document.addEventListener('mousedown', onPointerDown);
    return () => document.removeEventListener('mousedown', onPointerDown);
  }, [open]);

  useEffect(() => {
    if (disabled) {
      setOpen(false);
    }
  }, [disabled]);

  return (
    <div
      ref={fieldRef}
      className={`recording-choice-field ${open ? 'open' : ''}`}
      onKeyDown={(event) => {
        if (event.key === 'Escape') {
          setOpen(false);
        }
      }}
    >
      <span id={labelId}>{label}</span>
      <button
        className="recording-choice-trigger"
        type="button"
        disabled={disabled}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={listboxId}
        aria-labelledby={`${labelId} ${valueId}`}
        onClick={() => setOpen((current) => !current)}
      >
        <span id={valueId}>{selectedOption?.label ?? value}</span>
        <Icon name="chevron" />
      </button>
      {open && (
        <div className="recording-choice-list" id={listboxId} role="listbox" aria-labelledby={labelId}>
          {options.map((option) => (
            <button
              key={option.value}
              className={option.value === value ? 'selected' : ''}
              type="button"
              role="option"
              aria-selected={option.value === value}
              onClick={() => {
                onChange(option.value);
                setOpen(false);
              }}
            >
              {option.label}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

function PictureBookScene({
  state,
  page,
  english,
  chinese,
  englishActive = false,
  chineseActive = false,
  showSubtitles = true,
  onWordClick,
  onRetry,
  isRetrying = false,
}: {
  state: PictureBookState | null;
  page: PictureBookPage | null;
  english: string;
  chinese?: string;
  englishActive?: boolean;
  chineseActive?: boolean;
  showSubtitles?: boolean;
  onWordClick: (word: string, sentence: string, anchor: DOMRect) => void;
  onRetry: (page: PictureBookPage) => void;
  isRetrying?: boolean;
}) {
  // Inline scene viewers render inside a small box (<= ~1120px wide) via CSS `object-fit: cover`.
  // Feeding the raw 2560x1440 "full" original through that heavy downscale triggers WebView2/ANGLE
  // GPU texture corruption (blocky color-noise artifacts) on some Windows GPU drivers. Use the
  // pre-resized "display" bitmap here instead; only true fullscreen playback needs "full".
  const imageSrc = pageHasPictureBookImageVariant(page, 'display')
    ? directImageSource(page?.imageUri) ?? directImageSource(page?.imagePath) ?? ''
    : '';
  const isReady = page?.status === 'ready' && imageSrc;
  const hasPotentialPicture = Boolean(
    state?.status === 'loading' || state?.enabled || (state?.pages.length ?? 0) > 0,
  );
  const isLoadingImage =
    state?.status === 'loading' ||
    (!page && hasPotentialPicture) ||
    (page?.status === 'ready' && !imageSrc && Boolean(page?.imagePath?.trim()));
  const isBusy =
    isLoadingImage ||
    isRetrying ||
    state?.status === 'generating' ||
    page?.status === 'queued' ||
    page?.status === 'prompting' ||
    page?.status === 'generating';
  const isRetryable = Boolean(page && (page.status === 'error' || page.status === 'skipped'));
  const failureText = page?.errorMessage?.trim() || (page?.status === 'skipped' ? '缺少图片引擎 Key' : '绘本图生成失败');
  const placeholderText = isLoadingImage
    ? '正在加载绘本图...'
    : isRetrying
      ? '正在重试生成...'
      : isBusy
        ? '绘本图正在生成中...'
        : isRetryable
          ? failureText
          : '绘本图暂不可用';

  return (
    <section className={`picture-book-scene ${isReady ? 'ready' : ''} ${isBusy ? 'busy' : ''} ${isRetryable ? 'failed' : ''}`}>
      {isReady ? (
        <img src={imageSrc} alt="" />
      ) : (
        <div className={`picture-book-placeholder ${isBusy ? 'busy' : ''}`}>
          <Icon name={isBusy ? 'refresh' : isRetryable ? 'replay' : 'spark'} />
          <span>{placeholderText}</span>
        </div>
      )}
      {showSubtitles && (
        <div className="picture-book-subtitles">
          <div className="picture-book-subtitle-line english">
            <h1 className={englishActive ? 'playing-text' : undefined} aria-label={english}>
              <ClickableEnglishText
                text={english}
                sentence={english}
                onWordClick={onWordClick}
              />
            </h1>
          </div>
          {chinese && (
            <div className="picture-book-subtitle-line chinese">
              <p className={chineseActive ? 'playing-text' : undefined}>{chinese}</p>
            </div>
          )}
        </div>
      )}
      {isRetryable && page && (
        <button className="picture-book-retry" type="button" disabled={isRetrying} onClick={() => onRetry(page)}>
          <Icon name="replay" /> 重试
        </button>
      )}
    </section>
  );
}

type StoryTitleParts = {
  seriesTitle: string;
  chapterTitle: string;
};

function storyTitlePartsFor(
  article?: Article | null,
  pictureBookState?: PictureBookState | null,
  fallback = '',
  seriesFallback = '',
): StoryTitleParts {
  const articleTitle = article?.title?.trim() ?? '';
  const seriesTitle =
    pictureBookState?.series?.title?.trim() ||
    article?.seriesTitle?.trim() ||
    seriesFallback.trim();
  const chapterTitle = chapterTitleForDisplay(articleTitle, seriesTitle) || articleTitle || fallback.trim() || seriesTitle;
  return {
    seriesTitle,
    chapterTitle,
  };
}

function chapterTitleForDisplay(articleTitle: string, seriesTitle: string): string {
  if (!articleTitle || !seriesTitle) return articleTitle;
  if (!articleTitle.toLowerCase().startsWith(seriesTitle.toLowerCase())) {
    return articleTitle;
  }
  return articleTitle
    .slice(seriesTitle.length)
    .replace(/^[\s·:：\-–—|]+/, '')
    .trim() || articleTitle;
}

function StoryTitle({ parts }: { parts: StoryTitleParts }) {
  const hasSeries = parts.seriesTitle.trim().length > 0 && parts.chapterTitle.trim() !== parts.seriesTitle.trim();
  if (!hasSeries) {
    return (
      <span className="story-title single">
        <span className="story-title-book">{parts.chapterTitle || parts.seriesTitle}</span>
      </span>
    );
  }

  return (
    <span className="story-title">
      <span className="story-title-book">{parts.seriesTitle}</span>
      <span className="story-title-chapter">{parts.chapterTitle}</span>
    </span>
  );
}

function ChatPage({
  articleId,
  state,
  pictureBookState,
  onNavigate,
  onLoaded,
  onPictureBookLoaded,
  pictureBookRetryGate,
  onOpenPicturePromptReview,
}: {
  articleId: number;
  state: ChatState | null;
  pictureBookState: PictureBookState | null;
  onNavigate: (path: string) => void;
  onLoaded: (state: ChatState) => void;
  onPictureBookLoaded: PictureBookStateSetter;
  pictureBookRetryGate: PictureBookRetryGate;
  onOpenPicturePromptReview: (articleId: number, regenerate?: boolean) => void | Promise<void>;
}) {
  const [text, setText] = useState('');
  const [revealedTranslations, setRevealedTranslations] = useState<Set<string>>(() => new Set());

  useEffect(() => {
    let isMounted = true;
    onPictureBookLoaded(loadingPictureBookState(articleId));
    const picturePromise = sendNative<PictureBookState>('pictureBook.state', { articleId, includeImageUris: true })
      .then((payload) => {
        if (isMounted) {
          onPictureBookLoaded((current) => mergePictureBookState(current, payload));
        }
      })
      .catch(() => undefined);
    const chatPromise = sendNative<ChatState>('chat.open', { articleId })
      .then((payload) => {
        if (isMounted && payload) onLoaded(payload);
      })
      .catch((error) => {
        if (!isMounted) return;
        onLoaded({
          articleTitle: 'Space Snacks',
          step: 'error',
          error: error instanceof Error ? error.message : '无法打开对话任务',
          questionCount: 0,
          maxQuestions: 8,
          messages: [],
        });
      });
    void Promise.allSettled([chatPromise, picturePromise]);
    return () => {
      isMounted = false;
    };
  }, [articleId, onLoaded, onPictureBookLoaded]);

  useEffect(() => {
    setRevealedTranslations(new Set());
  }, [articleId]);

  const step = state?.step ?? 'init';
  const canTalk = step === 'userIdle' || step === 'recording';
  const questionCount = state?.questionCount ?? 0;
  const maxQuestions = state?.maxQuestions ?? 8;
  const messages = state?.messages ?? [];
  const chatCue = chatSideCue(step);
  const chatInputPlaceholder = chatInputCue(step);
  const chatProgress = maxQuestions > 0 ? (questionCount / maxQuestions) * 100 : 0;
  const visibleScenePages = pictureBookPagesForChatConversation(
    pictureBookState,
    questionCount,
  );
  const chatTimeline = buildChatTimelineEntries(
    messages,
    visibleScenePages,
    Boolean(pictureBookState?.status === 'loading' || pictureBookState?.enabled),
  );
  const retryPicturePage = (page: PictureBookPage) => {
    if (!pictureBookRetryGate.begin(articleId, page.pageIndex)) {
      return;
    }

    void Promise.resolve(onOpenPicturePromptReview(articleId, true))
      .catch(() => undefined)
      .finally(() => {
        pictureBookRetryGate.finish(articleId, page.pageIndex);
      });
  };

  const sendText = async () => {
    const draft = text.trim();
    if (!draft || step !== 'userIdle') return;
    setText('');
    try {
      await sendNative('chat.sendText', { text: draft });
    } catch {
      setText(draft);
    }
  };

  return (
    <section className="page chat-page">
      <TopBar title={state?.articleTitle || 'Space Snacks'} onBack={() => onNavigate('/')}>
        <Pager current={state?.questionCount ?? 1} total={state?.maxQuestions ?? 8} />
        <button className="danger-light" onClick={() => onNavigate('/')}>结束对话</button>
      </TopBar>

      <div className="chat-layout">
        <main className="chat-room-card">
          <div className="chat-status-strip">
            <div className="voice-state chat-voice-state">
              <WaveMini />
              <span>{chatCue}</span>
            </div>
            <ProgressLine value={chatProgress} label={`对话进度 ${questionCount} / ${maxQuestions}`} compact />
            <div className="dialogue-outline-preview">
              <span>对话提纲</span>
              <b>{maxQuestions} 轮</b>
            </div>
          </div>
          {step === 'completed' && (state?.abilityLevel || state?.practiceSummary) && (
            <div className="chat-completion-card chat-completion-inline">
              {state?.abilityLevel && (
                <div>
                  <span>能力级别</span>
                  <b>{state.abilityLevel}</b>
                </div>
              )}
              {state?.practiceSummary && <p>{state.practiceSummary}</p>}
            </div>
          )}
          <div className="chat-list">
            {chatTimeline.map((entry) => {
              if (entry.kind === 'scene') {
                return (
                  <ChatPictureSceneBlock
                    key={entry.key}
                    articleId={articleId}
                    state={pictureBookState}
                    page={entry.page}
                    onPictureBookLoaded={onPictureBookLoaded}
                    onRetry={retryPicturePage}
                    isRetrying={entry.page ? pictureBookRetryGate.isRetrying(articleId, entry.page.pageIndex) : false}
                  />
                );
              }

              const message = entry.message;
              return (
                <div
                  className={`chat-bubble ${message.isAi ? 'ai-bubble' : 'user-bubble'}`}
                  key={entry.key}
                >
                  {message.isAi && <span className="assistant-avatar" aria-hidden="true">T</span>}
                  <div>
                    <p>{message.text}</p>
                    {message.isAi && (
                      <button
                        aria-label="重播这句"
                        disabled={['waitingStart', 'playing'].includes(message.playbackState)}
                        onClick={() => sendNative('chat.replay', { messageId: message.id })}
                      >
                        <Icon name="sound" />
                      </button>
                    )}
                    {message.translation && (
                      <button
                        className={`chat-translation ${revealedTranslations.has(message.id) ? 'revealed' : ''}`}
                        type="button"
                        onClick={() => {
                          setRevealedTranslations((previous) => {
                            const next = new Set(previous);
                            next.add(message.id);
                            return next;
                          });
                        }}
                      >
                        {message.translation}
                      </button>
                    )}
                  </div>
                </div>
              );
            })}
            {messages.length === 0 && (
              <div className="chat-empty">
                <span className="assistant-avatar large" aria-hidden="true">T</span>
                <span>番茄助教正在准备第一个问题。</span>
              </div>
            )}
          </div>
          {state?.error && <p className="error-text">{state.error}</p>}
          <div className="chat-input">
            <Icon name="keyboard" />
            <input
              value={text}
              onChange={(event) => setText(event.target.value)}
              placeholder={chatInputPlaceholder}
              disabled={step !== 'userIdle'}
              onKeyDown={(event) => {
                if (event.key === 'Enter') void sendText();
              }}
            />
            <button className="ghost-action" onClick={sendText} disabled={step !== 'userIdle' || !text.trim()}>
              发送
            </button>
            <button
              className={step === 'recording' ? 'record-button mini active' : 'record-button mini'}
              disabled={!canTalk}
              aria-label={step === 'recording' ? '停止录音' : '开始录音'}
              onClick={() => sendNative(step === 'recording' ? 'chat.recordStop' : 'chat.recordStart')}
            >
              <Icon name={step === 'recording' ? 'stop' : 'mic'} />
            </button>
          </div>
        </main>
      </div>
    </section>
  );
}

function SecretInput({
  id,
  value,
  onValueChange,
  placeholder,
}: {
  id: string;
  value: string;
  onValueChange: (value: string) => void;
  placeholder?: string;
}) {
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    if (!value) setVisible(false);
  }, [value]);

  return (
    <span className="secret-input-control">
      <input
        id={id}
        type={visible ? 'text' : 'password'}
        value={value}
        onChange={(event) => onValueChange(event.target.value)}
        placeholder={placeholder}
        autoComplete="off"
        spellCheck={false}
      />
      <button
        type="button"
        className="secret-input-toggle"
        aria-label={visible ? '隐藏 Key' : '显示 Key'}
        aria-pressed={visible}
        title={visible ? '隐藏 Key' : '显示 Key'}
        disabled={!value}
        onClick={(event) => {
          event.preventDefault();
          setVisible((current) => !current);
        }}
      >
        <Icon name={visible ? 'eyeOff' : 'eye'} />
      </button>
    </span>
  );
}

function SecretClearButton({
  label,
  configured,
  pending,
  hasDraft,
  disabled,
  onClear,
  onCancel,
}: {
  label: string;
  configured: boolean;
  pending: boolean;
  hasDraft: boolean;
  disabled?: boolean;
  onClear: () => void;
  onCancel: () => void;
}) {
  const text = pending
    ? `取消清除${label}`
    : !configured && hasDraft
      ? '清空输入'
      : `清除${label}`;

  return (
    <button
      className={`key-clear-button ${pending ? 'active' : ''}`}
      type="button"
      disabled={disabled || (!configured && !pending && !hasDraft)}
      onClick={pending ? onCancel : onClear}
    >
      <Icon name={pending ? 'close' : 'trash'} />
      {text}
    </button>
  );
}

function SecretKeyRow({
  id,
  label,
  value,
  configured,
  mask,
  pending,
  disabled,
  onValueChange,
  onClear,
  onCancel,
}: {
  id: string;
  label: string;
  value: string;
  configured: boolean;
  mask?: string;
  pending: boolean;
  disabled?: boolean;
  onValueChange: (value: string) => void;
  onClear: () => void;
  onCancel: () => void;
}) {
  return (
    <div className="settings-label secret-key-row">
      <label htmlFor={id}>
        {label} {configured ? `（${mask || '已配置'}）` : '（未配置）'}
      </label>
      <div className="secret-key-control-row">
        <SecretInput
          id={id}
          value={value}
          onValueChange={onValueChange}
          placeholder="留空保持不变"
        />
        <SecretClearButton
          label={label}
          configured={configured}
          pending={pending}
          hasDraft={Boolean(value.trim())}
          disabled={disabled}
          onClear={onClear}
          onCancel={onCancel}
        />
      </div>
    </div>
  );
}

function ModelSelectField({
  label,
  value,
  options,
  onChange,
  hint,
  className,
}: {
  label: string;
  value: string;
  options: SelectOption[];
  onChange: (value: string) => void;
  hint?: string;
  className?: string;
}) {
  const normalizedValue = value.trim();
  const hasCurrentOption = options.some((option) => option.value === normalizedValue);
  const selectValue = !normalizedValue ? '' : hasCurrentOption ? normalizedValue : value;
  return (
    <label className={`settings-label model-select-label ${className ?? ''}`.trim()}>
      <span>{label}</span>
      <select value={selectValue} onChange={(event) => onChange(event.target.value)}>
        {!normalizedValue && <option value="">请选择模型</option>}
        {normalizedValue && !hasCurrentOption && (
          <option value={value}>{`当前自定义 · ${normalizedValue}`}</option>
        )}
        {options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
      {hint && <small className="settings-hint">{hint}</small>}
    </label>
  );
}

function SettingsPage({
  settings,
  onLoaded,
}: {
  settings: SettingsState | null;
  onLoaded: (settings: SettingsState) => void;
}) {
  const [current, setCurrent] = useState<SettingsState | null>(settings);
  const [selectedVoiceId, setSelectedVoiceId] = useState(settings?.tts.speakerId ?? '');
  const [sunoOutputDirectory, setSunoOutputDirectory] = useState(settings?.song?.sunoOutputDirectory ?? '');
  const [sunoTimeoutMinutes, setSunoTimeoutMinutes] = useState(settings?.song?.sunoTimeoutMinutes ?? 20);
  const [songProvider, setSongProvider] = useState<SongGenerationSource>(
    normalizeSongGenerationSource(settings?.song?.songProvider ?? 'suno'),
  );
  const [aiProvider, setAiProvider] = useState<AiProvider>(
    normalizeAiProvider(settings?.cloud?.aiProvider),
  );
  const [aliyunBailianApiKey, setAliyunBailianApiKey] = useState('');
  const [clearAliyunBailianApiKey, setClearAliyunBailianApiKey] = useState(false);
  const [aliyunBailianBaseUrl, setAliyunBailianBaseUrl] = useState(settings?.cloud?.aliyunBailian.baseUrl ?? '');
  const [aliyunBailianApiBaseUrl, setAliyunBailianApiBaseUrl] = useState(settings?.cloud?.aliyunBailian.apiBaseUrl ?? '');
  const [aliyunBailianTextModel, setAliyunBailianTextModel] = useState(settings?.cloud?.aliyunBailian.textModel ?? '');
  const [aliyunBailianMusicModel, setAliyunBailianMusicModel] = useState(settings?.cloud?.aliyunBailian.musicModel ?? '');
  const [aliyunBailianImageModel, setAliyunBailianImageModel] = useState(settings?.cloud?.aliyunBailian.imageModel ?? '');
  const [aliyunBailianImageSize, setAliyunBailianImageSize] = useState(settings?.cloud?.aliyunBailian.imageSize ?? '');
  const [aliyunBailianTtsModel, setAliyunBailianTtsModel] = useState(settings?.cloud?.aliyunBailian.ttsModel ?? '');
  const [aliyunBailianTtsVoice, setAliyunBailianTtsVoice] = useState(settings?.cloud?.aliyunBailian.ttsVoice ?? '');
  const [aliyunBailianTtsSampleRate, setAliyunBailianTtsSampleRate] = useState(
    String(settings?.cloud?.aliyunBailian.ttsSampleRate ?? ''),
  );
  const [aliyunBailianAsrModel, setAliyunBailianAsrModel] = useState(settings?.cloud?.aliyunBailian.asrModel ?? '');
  const [aliyunBailianRealtimeAsrModel, setAliyunBailianRealtimeAsrModel] = useState(settings?.cloud?.aliyunBailian.realtimeAsrModel ?? '');
  const [aliyunBailianRealtimeAsrUrl, setAliyunBailianRealtimeAsrUrl] = useState(settings?.cloud?.aliyunBailian.realtimeAsrUrl ?? '');
  const [volcArkApiKey, setVolcArkApiKey] = useState('');
  const [clearVolcArkApiKey, setClearVolcArkApiKey] = useState(false);
  const [volcArkBaseUrl, setVolcArkBaseUrl] = useState(settings?.cloud?.volcengine.arkBaseUrl ?? '');
  const [volcArkTextModel, setVolcArkTextModel] = useState(settings?.cloud?.volcengine.arkTextModel ?? '');
  const [volcArkImageModel, setVolcArkImageModel] = useState(settings?.cloud?.volcengine.arkImageModel ?? '');
  const [volcSpeechApiKey, setVolcSpeechApiKey] = useState('');
  const [clearVolcSpeechApiKey, setClearVolcSpeechApiKey] = useState(false);
  const [volcTtsResourceId, setVolcTtsResourceId] = useState(settings?.cloud?.volcengine.ttsResourceId ?? '');
  const [volcTtsSpeakerId, setVolcTtsSpeakerId] = useState(settings?.cloud?.volcengine.ttsSpeakerId ?? '');
  const [savingCloudSettings, setSavingCloudSettings] = useState(false);
  const [savingSongSettings, setSavingSongSettings] = useState(false);
  const [exportingDiagnostics, setExportingDiagnostics] = useState(false);
  const [saving, setSaving] = useState(false);
  const [previewingVoiceId, setPreviewingVoiceId] = useState<string | null>(null);
  const [status, setStatus] = useState<string | null>(null);
  const selectedVoiceButtonRef = useRef<HTMLDivElement | null>(null);

  const syncSettingsDraft = (payload: SettingsState) => {
    setCurrent(payload);
    setSelectedVoiceId(payload.tts.speakerId);
    setSunoOutputDirectory(payload.song?.sunoOutputDirectory ?? '');
    setSunoTimeoutMinutes(payload.song?.sunoTimeoutMinutes ?? 20);
    setSongProvider(normalizeSongGenerationSource(payload.song?.songProvider ?? 'suno'));
    setAiProvider(normalizeAiProvider(payload.cloud?.aiProvider));
    setAliyunBailianApiKey('');
    setClearAliyunBailianApiKey(false);
    setAliyunBailianBaseUrl(payload.cloud?.aliyunBailian.baseUrl ?? 'https://dashscope.aliyuncs.com/compatible-mode/v1');
    setAliyunBailianApiBaseUrl(payload.cloud?.aliyunBailian.apiBaseUrl ?? 'https://dashscope.aliyuncs.com/api/v1');
    setAliyunBailianTextModel(payload.cloud?.aliyunBailian.textModel ?? 'qwen3.7-max');
    setAliyunBailianMusicModel(payload.cloud?.aliyunBailian.musicModel ?? 'fun-music-v1');
    setAliyunBailianImageModel(payload.cloud?.aliyunBailian.imageModel ?? 'wan2.7-image-pro');
    setAliyunBailianImageSize(payload.cloud?.aliyunBailian.imageSize ?? '2K');
    setAliyunBailianTtsModel(payload.cloud?.aliyunBailian.ttsModel ?? 'cosyvoice-v3-flash');
    setAliyunBailianTtsVoice(payload.cloud?.aliyunBailian.ttsVoice ?? 'loongabby_v3');
    setAliyunBailianTtsSampleRate(String(payload.cloud?.aliyunBailian.ttsSampleRate ?? 24000));
    setAliyunBailianAsrModel(payload.cloud?.aliyunBailian.asrModel ?? 'qwen3-asr-flash');
    setAliyunBailianRealtimeAsrModel(payload.cloud?.aliyunBailian.realtimeAsrModel ?? 'qwen3-asr-realtime');
    setAliyunBailianRealtimeAsrUrl(payload.cloud?.aliyunBailian.realtimeAsrUrl ?? 'wss://dashscope.aliyuncs.com/api-ws/v1/realtime');
    setVolcArkApiKey('');
    setClearVolcArkApiKey(false);
    setVolcArkBaseUrl(payload.cloud?.volcengine.arkBaseUrl ?? 'https://ark.cn-beijing.volces.com/api/v3');
    setVolcArkTextModel(payload.cloud?.volcengine.arkTextModel ?? 'doubao-seed-2-0-lite-260215');
    setVolcArkImageModel(payload.cloud?.volcengine.arkImageModel ?? 'doubao-seedream-5-0-260128');
    setVolcSpeechApiKey('');
    setClearVolcSpeechApiKey(false);
    setVolcTtsResourceId(payload.cloud?.volcengine.ttsResourceId ?? 'seed-tts-2.0');
    setVolcTtsSpeakerId(payload.cloud?.volcengine.ttsSpeakerId ?? payload.tts.speakerId);
  };

  useEffect(() => {
    let isMounted = true;
    sendNative<SettingsState>('settings.load')
      .then((payload) => {
        if (!isMounted) return;
        syncSettingsDraft(payload);
        onLoaded(payload);
      })
      .catch((error) => {
        if (isMounted) setStatus(error.message);
      });
    return () => {
      isMounted = false;
    };
  }, [onLoaded]);

  useEffect(() => {
    if (settings) {
      syncSettingsDraft(settings);
    } else {
      setCurrent(settings);
    }
  }, [settings]);

  useEffect(() => {
    selectedVoiceButtonRef.current?.scrollIntoView?.({ block: 'center', inline: 'nearest' });
  }, [selectedVoiceId]);

  if (!current) {
    return <LoadingPanel text="正在打开声音设置" />;
  }

  const activeVoices = aiProvider === 'aliyun_bailian'
    ? (current.voiceCatalog?.aliyunBailian ?? [])
    : (current.voiceCatalog?.volcengine ?? current.voices);
  const selectedVoice = activeVoices.find((voice) => voice.id === selectedVoiceId);
  const unchanged = selectedVoiceId === current.tts.speakerId;
  const safetyRules = current.contentSafety?.rules ?? [];
  const songSettingsUnchanged =
    sunoOutputDirectory.trim() === (current.song?.sunoOutputDirectory ?? '').trim() &&
    Number(sunoTimeoutMinutes) === Number(current.song?.sunoTimeoutMinutes ?? 20) &&
    songProvider === normalizeSongGenerationSource(current.song?.songProvider ?? 'suno');
  const cloudSettingsUnchanged =
    aiProvider === normalizeAiProvider(current.cloud?.aiProvider) &&
    !aliyunBailianApiKey.trim() &&
    !clearAliyunBailianApiKey &&
    aliyunBailianBaseUrl.trim() === (current.cloud?.aliyunBailian.baseUrl ?? 'https://dashscope.aliyuncs.com/compatible-mode/v1') &&
    aliyunBailianApiBaseUrl.trim() === (current.cloud?.aliyunBailian.apiBaseUrl ?? 'https://dashscope.aliyuncs.com/api/v1') &&
    aliyunBailianTextModel.trim() === (current.cloud?.aliyunBailian.textModel ?? 'qwen3.7-max') &&
    aliyunBailianMusicModel.trim() === (current.cloud?.aliyunBailian.musicModel ?? 'fun-music-v1') &&
    aliyunBailianImageModel.trim() === (current.cloud?.aliyunBailian.imageModel ?? 'wan2.7-image-pro') &&
    aliyunBailianImageSize.trim() === (current.cloud?.aliyunBailian.imageSize ?? '2K') &&
    aliyunBailianTtsModel.trim() === (current.cloud?.aliyunBailian.ttsModel ?? 'cosyvoice-v3-flash') &&
    aliyunBailianTtsVoice.trim() === (current.cloud?.aliyunBailian.ttsVoice ?? 'loongabby_v3') &&
    aliyunBailianTtsSampleRate.trim() === String(current.cloud?.aliyunBailian.ttsSampleRate ?? 24000) &&
    aliyunBailianAsrModel.trim() === (current.cloud?.aliyunBailian.asrModel ?? 'qwen3-asr-flash') &&
    aliyunBailianRealtimeAsrModel.trim() === (current.cloud?.aliyunBailian.realtimeAsrModel ?? 'qwen3-asr-realtime') &&
    aliyunBailianRealtimeAsrUrl.trim() === (current.cloud?.aliyunBailian.realtimeAsrUrl ?? 'wss://dashscope.aliyuncs.com/api-ws/v1/realtime') &&
    !volcArkApiKey.trim() &&
    !clearVolcArkApiKey &&
    volcArkBaseUrl.trim() === (current.cloud?.volcengine.arkBaseUrl ?? 'https://ark.cn-beijing.volces.com/api/v3') &&
    volcArkTextModel.trim() === (current.cloud?.volcengine.arkTextModel ?? 'doubao-seed-2-0-lite-260215') &&
    volcArkImageModel.trim() === (current.cloud?.volcengine.arkImageModel ?? 'doubao-seedream-5-0-260128') &&
    !volcSpeechApiKey.trim() &&
    !clearVolcSpeechApiKey &&
    volcTtsResourceId.trim() === (current.cloud?.volcengine.ttsResourceId ?? 'seed-tts-2.0') &&
    volcTtsSpeakerId.trim() === (current.cloud?.volcengine.ttsSpeakerId ?? current.tts.speakerId);

  const selectCloudProvider = (provider: AiProvider) => {
    setAiProvider(provider);
    setSelectedVoiceId(
      provider === 'aliyun_bailian'
        ? (aliyunBailianTtsVoice.trim() || 'loongabby_v3')
        : (volcTtsSpeakerId.trim() || current.tts.speakerId),
    );
    setStatus(null);
  };

  const selectVoice = (voiceId: string) => {
    setSelectedVoiceId(voiceId);
    if (aiProvider === 'aliyun_bailian') {
      setAliyunBailianTtsVoice(voiceId);
    } else {
      setVolcTtsSpeakerId(voiceId);
    }
    setStatus(null);
  };

  const previewVoice = async (speakerId: string) => {
    if (previewingVoiceId) return;

    setPreviewingVoiceId(speakerId);
    setStatus(null);
    try {
      await sendNative<VoicePreviewPayload>('settings.previewVoice', {
        speakerId,
        aiProvider,
      });
      setStatus('声音预览已播放');
    } catch (error) {
      setStatus(error instanceof Error ? error.message : '声音预览失败');
    } finally {
      setPreviewingVoiceId(null);
    }
  };

  const saveVoice = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!selectedVoiceId) return;

    setSaving(true);
    setStatus(null);
    try {
      const payload = await sendNative<SettingsState>('settings.saveVoice', {
        speakerId: selectedVoiceId,
        aiProvider,
      });
      syncSettingsDraft(payload);
      onLoaded(payload);
      setStatus('声音设置已保存');
    } catch (error) {
      setStatus(error instanceof Error ? error.message : '声音设置保存失败');
    } finally {
      setSaving(false);
    }
  };

  const saveSongSettings = async () => {
    setSavingSongSettings(true);
    setStatus(null);
    try {
      const payload = await sendNative<SettingsState>('settings.saveSong', {
        sunoOutputDirectory: sunoOutputDirectory.trim(),
        sunoTimeoutMinutes: Number(sunoTimeoutMinutes) || 20,
        songProvider,
      });
      syncSettingsDraft(payload);
      onLoaded(payload);
      setStatus('歌曲设置已保存');
    } catch (error) {
      setStatus(error instanceof Error ? error.message : '歌曲设置保存失败');
    } finally {
      setSavingSongSettings(false);
    }
  };

  const saveCloudSettings = async () => {
    setSavingCloudSettings(true);
    setStatus(null);
    try {
      const payload = await sendNative<SettingsState>('settings.saveCloud', {
        aiProvider,
        aliyunBailianApiKey: aliyunBailianApiKey.trim(),
        clearAliyunBailianApiKey,
        aliyunBailianBaseUrl: aliyunBailianBaseUrl.trim(),
        aliyunBailianApiBaseUrl: aliyunBailianApiBaseUrl.trim(),
        aliyunBailianTextModel: aliyunBailianTextModel.trim(),
        aliyunBailianMusicModel: aliyunBailianMusicModel.trim(),
        aliyunBailianImageModel: aliyunBailianImageModel.trim(),
        aliyunBailianImageSize: aliyunBailianImageSize.trim(),
        aliyunBailianTtsModel: aliyunBailianTtsModel.trim(),
        aliyunBailianTtsVoice: aliyunBailianTtsVoice.trim(),
        aliyunBailianTtsSampleRate: aliyunBailianTtsSampleRate.trim(),
        aliyunBailianAsrModel: aliyunBailianAsrModel.trim(),
        aliyunBailianRealtimeAsrModel: aliyunBailianRealtimeAsrModel.trim(),
        aliyunBailianRealtimeAsrUrl: aliyunBailianRealtimeAsrUrl.trim(),
        volcArkApiKey: volcArkApiKey.trim(),
        clearVolcArkApiKey,
        volcArkBaseUrl: volcArkBaseUrl.trim(),
        volcArkTextModel: volcArkTextModel.trim(),
        volcArkImageModel: volcArkImageModel.trim(),
        volcSpeechApiKey: volcSpeechApiKey.trim(),
        clearVolcSpeechApiKey,
        volcTtsResourceId: volcTtsResourceId.trim(),
        volcTtsSpeakerId: volcTtsSpeakerId.trim(),
      });
      syncSettingsDraft(payload);
      onLoaded(payload);
      setStatus('云服务设置已保存');
    } catch (error) {
      setStatus(error instanceof Error ? error.message : '云服务设置保存失败');
    } finally {
      setSavingCloudSettings(false);
    }
  };

  const exportDiagnostics = async () => {
    setExportingDiagnostics(true);
    setStatus(null);
    try {
      const payload = await sendNative<DiagnosticLogExportPayload>('diagnostics.logsExport');
      setStatus(`诊断日志已导出：${payload.path}`);
    } catch (error) {
      setStatus(error instanceof Error ? error.message : '诊断日志导出失败');
    } finally {
      setExportingDiagnostics(false);
    }
  };

  const setSafetyRuleEnabled = async (id: number, enabled: boolean) => {
    setStatus(null);
    try {
      const payload = await sendNative<SettingsState>('contentSafety.setRuleEnabled', {
        id,
        enabled,
      });
      setCurrent(payload);
      onLoaded(payload);
      setStatus(enabled ? '安全规则已启用' : '安全规则已停用');
    } catch (error) {
      setStatus(error instanceof Error ? error.message : '安全规则更新失败');
    }
  };

  const deleteSafetyRule = async (id: number) => {
    setStatus(null);
    try {
      const payload = await sendNative<SettingsState>('contentSafety.deleteRule', {
        id,
      });
      setCurrent(payload);
      onLoaded(payload);
      setStatus('安全规则已删除');
    } catch (error) {
      setStatus(error instanceof Error ? error.message : '安全规则删除失败');
    }
  };

  return (
    <section className="page settings-page">
      <form className="settings-shell voice-settings-shell" onSubmit={saveVoice}>
        <main className="settings-main">
          <header className="settings-header">
            <p className="eyebrow">Voice</p>
            <h1>选择番茄助教的发音</h1>
            <p>选择一个适合孩子跟读和对话的声音，保存后会用于朗读和聊天。</p>
          </header>

          <div className="settings-grid voice-settings-grid">
            <FieldGroup title="发音人">
              <div className="voice-list-header">
                <span>可选声音</span>
                <small>{activeVoices.length} 个发音人</small>
              </div>
              <div className="voice-list-scroll" role="listbox" aria-label="可选声音">
                <div className="voice-list">
                  {activeVoices.map((voice) => (
                  <div
                    className={`voice-card ${voice.id === selectedVoiceId ? 'selected' : ''}`}
                    key={voice.id}
                    ref={voice.id === selectedVoiceId ? selectedVoiceButtonRef : undefined}
                    role="option"
                    tabIndex={0}
                    aria-selected={voice.id === selectedVoiceId}
                    onClick={() => {
                      selectVoice(voice.id);
                    }}
                    onKeyDown={(event) => {
                      if (event.key === 'Enter' || event.key === ' ') {
                        event.preventDefault();
                        selectVoice(voice.id);
                      }
                    }}
                  >
                    <span className="voice-avatar">{voice.name.slice(0, 1)}</span>
                    <span>
                      <b>{voice.name}</b>
                      <small>{displayVoiceLanguage(voice.lang)} · {voice.gender === 'female' ? '女声' : '男声'}</small>
                    </span>
                    <button
                      className="voice-preview-button"
                      type="button"
                      disabled={previewingVoiceId !== null}
                      onClick={(event) => {
                        event.stopPropagation();
                        void previewVoice(voice.id);
                      }}
                    >
                      <Icon name="sound" />
                      {previewingVoiceId === voice.id ? '试听中' : '预览'}
                    </button>
                  </div>
                ))}
                </div>
              </div>
            </FieldGroup>

            <aside className="selected-voice-panel">
              <span className="selected-voice-mark" aria-hidden="true">
                {selectedVoice?.name.slice(0, 1) ?? 'V'}
              </span>
              <span>当前声音</span>
              <b>{selectedVoice?.name ?? '未选择'}</b>
              {selectedVoice && (
                <small>{displayVoiceLanguage(selectedVoice.lang)} · {selectedVoice.gender === 'female' ? '女声' : '男声'}</small>
              )}
            </aside>
          </div>

          <FieldGroup title="云服务">
            <div className="settings-tabs" role="tablist" aria-label="AI 文本供应商">
              <button
                className={aiProvider === 'aliyun_bailian' ? 'active' : ''}
                type="button"
                role="tab"
                aria-selected={aiProvider === 'aliyun_bailian'}
                onClick={() => selectCloudProvider('aliyun_bailian')}
              >
                阿里云百炼
              </button>
              <button
                className={aiProvider === 'volcengine' ? 'active' : ''}
                type="button"
                role="tab"
                aria-selected={aiProvider === 'volcengine'}
                onClick={() => selectCloudProvider('volcengine')}
              >
                火山引擎
              </button>
            </div>
            <div className="cloud-settings-panel">
              {aiProvider === 'aliyun_bailian' ? (
                <>
                  <div className="settings-subsection">
                    <h3>凭据</h3>
                    <SecretKeyRow
                      id="aliyun-bailian-api-key"
                      label="百炼 Key"
                      value={aliyunBailianApiKey}
                      configured={Boolean(current.cloud?.aliyunBailian.apiKeyConfigured)}
                      mask={current.cloud?.aliyunBailian.apiKeyMask}
                      pending={clearAliyunBailianApiKey}
                      disabled={savingCloudSettings}
                      onValueChange={(value) => {
                        setAliyunBailianApiKey(value);
                        if (value.trim()) setClearAliyunBailianApiKey(false);
                      }}
                      onClear={() => {
                        setAliyunBailianApiKey('');
                        setClearAliyunBailianApiKey(Boolean(current.cloud?.aliyunBailian.apiKeyConfigured));
                      }}
                      onCancel={() => setClearAliyunBailianApiKey(false)}
                    />
                  </div>
                  <div className="settings-subsection">
                    <h3>平台地址</h3>
                    <label className="settings-label">
                      <span>百炼兼容模式 Base URL</span>
                      <input
                        value={aliyunBailianBaseUrl}
                        onChange={(event) => setAliyunBailianBaseUrl(event.target.value)}
                      />
                    </label>
                    <label className="settings-label">
                      <span>DashScope API Base URL</span>
                      <input
                        value={aliyunBailianApiBaseUrl}
                        onChange={(event) => setAliyunBailianApiBaseUrl(event.target.value)}
                      />
                    </label>
                  </div>
                  <div className="settings-subsection">
                    <h3>模型与语音</h3>
                    <div className="settings-grid model-settings-grid">
                      <ModelSelectField
                        label="百炼文本模型"
                        value={aliyunBailianTextModel}
                        options={ALIYUN_TEXT_MODEL_OPTIONS}
                        onChange={setAliyunBailianTextModel}
                      />
                      <ModelSelectField
                        label="万相图片模型"
                        value={aliyunBailianImageModel}
                        options={ALIYUN_IMAGE_MODEL_OPTIONS}
                        onChange={setAliyunBailianImageModel}
                        hint="仅列出当前组图链路可用的万相模型。"
                      />
                      <ModelSelectField
                        label="万相图片规格"
                        value={aliyunBailianImageSize}
                        options={ALIYUN_IMAGE_SIZE_OPTIONS}
                        onChange={setAliyunBailianImageSize}
                      />
                      <ModelSelectField
                        label="CosyVoice 模型"
                        value={aliyunBailianTtsModel}
                        options={ALIYUN_TTS_MODEL_OPTIONS}
                        onChange={setAliyunBailianTtsModel}
                      />
                      <label className="settings-label">
                        <span>CosyVoice 音色</span>
                        <select
                          value={aliyunBailianTtsVoice}
                          onChange={(event) => selectVoice(event.target.value)}
                        >
                          {(current.voiceCatalog?.aliyunBailian ?? activeVoices).map((voice) => (
                            <option key={voice.id} value={voice.id}>{voice.name} · {voice.id}</option>
                          ))}
                        </select>
                      </label>
                      <label className="settings-label">
                        <span>CosyVoice 采样率</span>
                        <input
                          value={aliyunBailianTtsSampleRate}
                          onChange={(event) => setAliyunBailianTtsSampleRate(event.target.value)}
                        />
                      </label>
                      <ModelSelectField
                        label="Qwen-ASR 文件模型"
                        value={aliyunBailianAsrModel}
                        options={ALIYUN_ASR_MODEL_OPTIONS}
                        onChange={setAliyunBailianAsrModel}
                      />
                      <ModelSelectField
                        label="Qwen-ASR 实时模型"
                        value={aliyunBailianRealtimeAsrModel}
                        options={ALIYUN_REALTIME_ASR_MODEL_OPTIONS}
                        onChange={setAliyunBailianRealtimeAsrModel}
                      />
                      <label className="settings-label wide-field">
                        <span>Qwen-ASR 实时 WebSocket</span>
                        <input
                          value={aliyunBailianRealtimeAsrUrl}
                          onChange={(event) => setAliyunBailianRealtimeAsrUrl(event.target.value)}
                        />
                      </label>
                    </div>
                  </div>
                </>
              ) : (
                <>
                  <div className="settings-subsection">
                    <h3>凭据</h3>
                    <SecretKeyRow
                      id="volc-ark-api-key"
                      label="方舟 Key"
                      value={volcArkApiKey}
                      configured={Boolean(current.cloud?.volcengine.arkApiKeyConfigured)}
                      mask={current.cloud?.volcengine.arkApiKeyMask}
                      pending={clearVolcArkApiKey}
                      disabled={savingCloudSettings}
                      onValueChange={(value) => {
                        setVolcArkApiKey(value);
                        if (value.trim()) setClearVolcArkApiKey(false);
                      }}
                      onClear={() => {
                        setVolcArkApiKey('');
                        setClearVolcArkApiKey(Boolean(current.cloud?.volcengine.arkApiKeyConfigured));
                      }}
                      onCancel={() => setClearVolcArkApiKey(false)}
                    />
                    <SecretKeyRow
                      id="volc-speech-api-key"
                      label="火山语音 Key"
                      value={volcSpeechApiKey}
                      configured={Boolean(current.cloud?.volcengine.speechApiKeyConfigured)}
                      mask={current.cloud?.volcengine.speechApiKeyMask}
                      pending={clearVolcSpeechApiKey}
                      disabled={savingCloudSettings}
                      onValueChange={(value) => {
                        setVolcSpeechApiKey(value);
                        if (value.trim()) setClearVolcSpeechApiKey(false);
                      }}
                      onClear={() => {
                        setVolcSpeechApiKey('');
                        setClearVolcSpeechApiKey(Boolean(current.cloud?.volcengine.speechApiKeyConfigured));
                      }}
                      onCancel={() => setClearVolcSpeechApiKey(false)}
                    />
                  </div>
                  <div className="settings-subsection">
                    <h3>平台地址</h3>
                    <label className="settings-label">
                      <span>方舟 Base URL</span>
                      <input
                        value={volcArkBaseUrl}
                        onChange={(event) => setVolcArkBaseUrl(event.target.value)}
                      />
                    </label>
                  </div>
                  <div className="settings-subsection">
                    <h3>模型与语音</h3>
                    <div className="settings-grid model-settings-grid">
                      <ModelSelectField
                        label="方舟文本模型"
                        value={volcArkTextModel}
                        options={VOLC_TEXT_MODEL_OPTIONS}
                        onChange={setVolcArkTextModel}
                      />
                      <ModelSelectField
                        label="Seedream 图片模型"
                        value={volcArkImageModel}
                        options={VOLC_IMAGE_MODEL_OPTIONS}
                        onChange={setVolcArkImageModel}
                        hint="仅列出当前顺序组图链路可用的 Seedream 模型。"
                      />
                      <ModelSelectField
                        label="Doubao TTS Resource"
                        value={volcTtsResourceId}
                        options={VOLC_TTS_RESOURCE_OPTIONS}
                        onChange={setVolcTtsResourceId}
                      />
                      <label className="settings-label">
                        <span>Doubao TTS Speaker</span>
                        <select
                          value={volcTtsSpeakerId}
                          onChange={(event) => selectVoice(event.target.value)}
                        >
                          {(current.voiceCatalog?.volcengine ?? activeVoices).map((voice) => (
                            <option key={voice.id} value={voice.id}>{voice.name} · {voice.id}</option>
                          ))}
                        </select>
                      </label>
                    </div>
                  </div>
                </>
              )}
            </div>
            <button
              className="ghost-action"
              type="button"
              disabled={savingCloudSettings || cloudSettingsUnchanged}
              onClick={() => void saveCloudSettings()}
            >
              <Icon name="save" /> {savingCloudSettings ? '保存中' : '保存云服务设置'}
            </button>
          </FieldGroup>

          <FieldGroup title="歌曲生成">
            <div className="settings-tabs" role="tablist" aria-label="默认歌曲来源">
              <button
                className={songProvider === 'suno' ? 'active' : ''}
                type="button"
                role="tab"
                aria-selected={songProvider === 'suno'}
                onClick={() => setSongProvider('suno')}
              >
                Suno 网页自动化
              </button>
              <button
                className={songProvider === 'bailian_fun_music' ? 'active' : ''}
                type="button"
                role="tab"
                aria-selected={songProvider === 'bailian_fun_music'}
                onClick={() => setSongProvider('bailian_fun_music')}
              >
                阿里云百聆
              </button>
            </div>
            <div className="song-settings-grid">
              {songProvider === 'suno' ? (
                <>
                  <label className="settings-label">
                    <span>Suno 输出目录</span>
                    <input
                      value={sunoOutputDirectory}
                      onChange={(event) => setSunoOutputDirectory(event.target.value)}
                      placeholder="留空使用程序目录下的 suno-music；不要填写 .tmp 或系统临时目录"
                    />
                  </label>
                  <label className="settings-label">
                    <span>Suno 生成超时（分钟）</span>
                    <input
                      type="number"
                      min={5}
                      max={120}
                      value={sunoTimeoutMinutes}
                      onChange={(event) => setSunoTimeoutMinutes(Number(event.target.value) || 20)}
                    />
                  </label>
                </>
              ) : (
                <div className="song-provider-summary">
                  <div>
                    <span>百炼 Key</span>
                    <b>{current.cloud?.aliyunBailian.apiKeyConfigured ? (current.cloud.aliyunBailian.apiKeyMask || '已配置') : '未配置'}</b>
                  </div>
                  <div>
                    <span>百聆音乐模型</span>
                    <b>{aliyunBailianMusicModel || current.cloud?.aliyunBailian.musicModel || 'fun-music-v1'}</b>
                  </div>
                </div>
              )}
            </div>
            {songProvider === 'suno' && (
              <p className="settings-help">
                Suno 会打开页面让用户自行登录，登录态来自内置浏览器会话；Tomato 不保存 Suno 用户名、密码、验证码或 cookie 明文。
              </p>
            )}
            <button
              className="ghost-action"
              type="button"
              disabled={savingSongSettings || songSettingsUnchanged}
              onClick={() => void saveSongSettings()}
            >
              <Icon name="save" /> {savingSongSettings ? '保存中' : '保存歌曲设置'}
            </button>
          </FieldGroup>

          <FieldGroup title="内容安全规则">
            <div className="safety-rule-header">
              <span>提交给云 API 前自动替换</span>
              <small>{safetyRules.length} 条规则</small>
            </div>
            <div className="safety-rule-list">
              {safetyRules.length === 0 && (
                <p className="empty-note">还没有记录到需要自动处理的安全规则。</p>
              )}
              {safetyRules.map((rule) => (
                <div className={`safety-rule-row ${rule.enabled ? '' : 'disabled'}`} key={rule.id}>
                  <span className="safety-rule-term">{rule.sourceTerm}</span>
                  <Icon name="arrow" />
                  <span className="safety-rule-replacement">{rule.replacement}</span>
                  <small>
                    {rule.serviceKind === '*' ? '全部服务' : rule.serviceKind}
                    {' · '}
                    {rule.purposeScope === '*' ? '全部用途' : rule.purposeScope}
                  </small>
                  <button
                    className="ghost-action small"
                    type="button"
                    onClick={() => {
                      void setSafetyRuleEnabled(rule.id, !rule.enabled);
                    }}
                  >
                    {rule.enabled ? '停用' : '启用'}
                  </button>
                  <button
                    className="danger-light small"
                    type="button"
                    onClick={() => {
                      void deleteSafetyRule(rule.id);
                    }}
                  >
                    删除
                  </button>
                </div>
              ))}
            </div>
          </FieldGroup>

          <FieldGroup title="诊断日志">
            <div className="safety-rule-header">
              <span>导出运行日志和最近状态</span>
              <small>logs</small>
            </div>
            <button
              className="ghost-action"
              type="button"
              disabled={exportingDiagnostics}
              onClick={() => void exportDiagnostics()}
            >
              <Icon name="download" /> {exportingDiagnostics ? '导出中' : '导出诊断日志'}
            </button>
          </FieldGroup>

          <footer className="settings-footer">
            <button className="primary-action" disabled={saving || unchanged}>
              <Icon name="save" /> {saving ? '保存中' : '保存声音'}
            </button>
            {status && <span role="status">{status}</span>}
          </footer>
        </main>
      </form>
    </section>
  );
}

function FollowScoreBadge({
  result,
  compact = false,
}: {
  result: NonNullable<FollowState['result']>;
  compact?: boolean;
}) {
  return (
    <div className={`follow-score-badge ${compact ? 'compact' : ''}`}>
      <span>总体评分</span>
      <b>{Math.round(result.overallScore)}</b>
      <small>{result.isMock ? '示例评分' : '本句得分'}</small>
    </div>
  );
}

function MapStep({
  number,
  title,
  text,
  active = false,
}: {
  number: string;
  title: string;
  text: string;
  active?: boolean;
}) {
  return (
    <article className={`map-step ${active ? 'active' : ''}`}>
      <b>{number}</b>
      <span>
        <strong>{title}</strong>
        <small>{text}</small>
      </span>
    </article>
  );
}

function EditTitleDialog({
  title,
  error,
  saving,
  onTitleChange,
  onCancel,
  onSave,
}: {
  title: string;
  error: string | null;
  saving: boolean;
  onTitleChange: (title: string) => void;
  onCancel: () => void;
  onSave: () => void;
}) {
  const inputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    inputRef.current?.focus({ preventScroll: true });
  }, []);

  return createPortal(
    <div className="edit-dialog-backdrop" role="presentation">
      <section
        className="edit-dialog"
        role="dialog"
        aria-modal="true"
        aria-label="修改文章标题"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <div className="edit-dialog-heading">
          <b>修改文章标题</b>
          <button className="icon-button small" type="button" onClick={onCancel} disabled={saving} aria-label="关闭">
            <Icon name="exit" />
          </button>
        </div>
        <label>
          <span>标题</span>
          <input
            ref={inputRef}
            value={title}
            maxLength={120}
            onChange={(event) => onTitleChange(event.target.value)}
          />
        </label>
        {error && <p className="edit-dialog-error">{error}</p>}
        <div className="edit-dialog-actions">
          <button className="ghost-action" type="button" onClick={onCancel} disabled={saving}>
            取消
          </button>
          <button className="primary-action" type="button" onClick={onSave} disabled={saving || !title.trim()}>
            <Icon name="save" /> {saving ? '保存中' : '保存'}
          </button>
        </div>
      </section>
    </div>,
    document.body,
  );
}

function BookCharacterEditor({
  label,
  characters,
  onChange,
  disabled = false,
}: {
  label: string;
  characters: BookCharacter[];
  onChange: (characters: BookCharacter[]) => void;
  disabled?: boolean;
}) {
  const rows = characters.length > 0 ? characters : [];
  const updateCharacter = (
    index: number,
    key: keyof BookCharacter,
    value: string,
  ) => {
    onChange(
      rows.map((character, rowIndex) =>
        rowIndex === index ? { ...character, [key]: value } : character,
      ),
    );
  };
  const removeCharacter = (index: number) => {
    onChange(rows.filter((_, rowIndex) => rowIndex !== index));
  };
  const addCharacter = () => {
    onChange([...rows, { name: '', description: '' }]);
  };

  return (
    <div className="book-character-editor">
      <div className="field-label-row">
        <span>{label}</span>
        <button
          className="ghost-action small"
          type="button"
          onClick={addCharacter}
          disabled={disabled}
        >
          <Icon name="plus" /> 新增角色
        </button>
      </div>
      {rows.length === 0 ? (
        <p className="book-character-empty">暂无角色。新增后填写名称和外貌描述。</p>
      ) : (
        <div className="book-character-list">
          {rows.map((character, index) => (
            <div className="book-character-row" key={`${index}-${character.name}`}>
              <input
                aria-label={`${label} ${index + 1} 名称`}
                value={character.name}
                maxLength={80}
                placeholder="角色名称"
                disabled={disabled}
                onChange={(event) => updateCharacter(index, 'name', event.target.value)}
              />
              <button
                className="icon-button small"
                type="button"
                aria-label={`删除${character.name || `第 ${index + 1} 个角色`}`}
                disabled={disabled}
                onClick={() => removeCharacter(index)}
              >
                <Icon name="trash" />
              </button>
              <textarea
                aria-label={`${label} ${index + 1} 描述`}
                value={character.description}
                maxLength={600}
                rows={2}
                placeholder="稳定外貌、服饰或物种特征"
                disabled={disabled}
                onChange={(event) => updateCharacter(index, 'description', event.target.value)}
              />
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function BookEditDialog({
  title,
  description,
  characters,
  error,
  saving,
  generatingDescription = false,
  onTitleChange,
  onDescriptionChange,
  onCharactersChange,
  onGenerateDescription,
  onCancel,
  onSave,
}: {
  title: string;
  description: string;
  characters: BookCharacter[];
  error: string | null;
  saving: boolean;
  generatingDescription?: boolean;
  onTitleChange: (title: string) => void;
  onDescriptionChange: (description: string) => void;
  onCharactersChange: (characters: BookCharacter[]) => void;
  onGenerateDescription?: () => void | Promise<void>;
  onCancel: () => void;
  onSave: () => void;
}) {
  const inputRef = useRef<HTMLInputElement | null>(null);
  const busy = saving || generatingDescription;

  useEffect(() => {
    inputRef.current?.focus({ preventScroll: true });
  }, []);

  return createPortal(
    <div className="edit-dialog-backdrop" role="presentation">
      <section
        className="edit-dialog book-edit-dialog"
        role="dialog"
        aria-modal="true"
        aria-label="编辑书籍信息"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <div className="edit-dialog-heading">
          <b>编辑书籍信息</b>
          <button className="icon-button small" type="button" onClick={onCancel} disabled={busy} aria-label="关闭">
            <Icon name="exit" />
          </button>
        </div>

        <div className="edit-dialog-scroll-body">
          <label>
            <span>书籍名称</span>
            <input
              ref={inputRef}
              value={title}
              maxLength={120}
              onChange={(event) => onTitleChange(event.target.value)}
            />
          </label>
          <div className="edit-dialog-field">
            <div className="field-label-row">
              <span>书籍简介</span>
              {onGenerateDescription && (
                <button
                  className="icon-button small prompt-magic-button"
                  type="button"
                  aria-label="AI 自动生成书籍简介"
                  title="AI 自动生成书籍简介"
                  disabled={busy || !title.trim()}
                  onClick={() => void onGenerateDescription()}
                >
                  <Icon name={generatingDescription ? 'refresh' : 'wand'} />
                  <span>{generatingDescription ? '生成中' : '自动生成'}</span>
                </button>
              )}
            </div>
            <textarea
              aria-label="书籍简介"
              value={description}
              maxLength={1000}
              rows={5}
              onChange={(event) => onDescriptionChange(event.target.value)}
            />
          </div>
          <BookCharacterEditor
            label="书籍角色"
            characters={characters}
            onChange={onCharactersChange}
            disabled={busy}
          />
          {error && <p className="edit-dialog-error">{error}</p>}
        </div>

        <div className="edit-dialog-actions">
          <button className="ghost-action" type="button" onClick={onCancel} disabled={busy}>
            取消
          </button>
          <button className="primary-action" type="button" onClick={onSave} disabled={busy || !title.trim()}>
            <Icon name="save" /> {saving ? '保存中' : '保存'}
          </button>
        </div>
      </section>
    </div>,
    document.body,
  );
}

function MissionRow({
  article,
  imageSrc,
  selected,
  openLabel,
  onOpen,
  onListen,
  onVideo,
  videoDisabled,
  onFollow,
  onChat,
  onDelete,
  onRename,
  extraAction,
}: {
  article: Article;
  imageSrc: string;
  selected?: boolean;
  openLabel?: string;
  onOpen?: () => void;
  onListen?: () => void;
  onVideo?: () => void;
  videoDisabled?: boolean;
  onFollow?: () => void;
  onChat?: () => void;
  onDelete?: () => void;
  onRename?: () => void;
  extraAction?: ReactNode;
}) {
  const score = article.averageScore > 0 ? Math.round(article.averageScore) : 40;
  const openArticle = onOpen ?? onListen ?? onFollow ?? onChat;
  const chapterDescription = chapterDescriptionForArticle(article);
  return (
    <article className={`mission-row ${selected ? 'active' : ''}`}>
      <button
        className="mission-cover-button"
        type="button"
        onClick={openArticle}
        disabled={!openArticle}
        aria-label={`进入《${article.title}》${openLabel ?? (onListen ? '听力' : '练习')}`}
      >
        <img src={imageSrc} alt="" />
      </button>
      <div>
        <h3 className="mission-title-line">
          <button type="button" className="mission-title-button" onClick={openArticle} disabled={!openArticle}>
            {article.title}
          </button>
          {onRename && (
            <button
              className="icon-button tiny"
              type="button"
              onClick={onRename}
              aria-label={`修改《${article.title}》标题`}
            >
              <Icon name="edit" />
            </button>
          )}
        </h3>
        {chapterDescription && <p className="mission-chapter-brief">{chapterDescription}</p>}
        <p className={chapterDescription ? 'mission-meta' : undefined}>{article.sentenceCount} 句子 · 最近学习 今天</p>
      </div>
      <span className="ring-score">{score}%</span>
      <div className="mission-actions">
        {onListen && <button className="listen-action" onClick={onListen}><Icon name="sound" /> 听力</button>}
        {onFollow && <button className="primary-action" onClick={onFollow}><Icon name="mic" /> 跟读</button>}
        {onChat && <button className="purple-action" onClick={onChat}><Icon name="chat" /> 对话</button>}
        {(onVideo || videoDisabled) && (
          <button className="video-action" onClick={onVideo} disabled={videoDisabled || !onVideo}>
            <Icon name="recordVideo" /> 视频
          </button>
        )}
        {extraAction}
        {onDelete && <button className="delete-action" onClick={onDelete}>删除</button>}
      </div>
    </article>
  );
}

function EmptyMission({ onNavigate }: { onNavigate: (path: string) => void }) {
  return (
    <div className="empty-mission">
      <div className="empty-book-mark" aria-hidden="true">
        <Icon name="card" />
      </div>
      <p>先放入一篇英文短文，系统会把它保存为书籍章节，并异步生成连续绘本图。</p>
      <button className="primary-action" onClick={() => onNavigate('/article/new')}>
        <Icon name="plus" /> 创建第一章
      </button>
    </div>
  );
}

function TopBar({
  title,
  onBack,
  children,
}: {
  title: ReactNode;
  onBack: () => void;
  children?: ReactNode;
}) {
  return (
    <header className="top-bar">
      <button className="icon-button" onClick={onBack} aria-label="返回">
        <Icon name="back" />
      </button>
      <h1>{title}</h1>
      <div className="top-actions">{children}</div>
    </header>
  );
}

function UserBadge() {
  return (
    <div className="user-badge">
      <span>本地书库</span>
      <b>练习与创作分离</b>
      <ProgressLine value={65} label="绘本 / 听力 / 歌曲" compact />
    </div>
  );
}

function WaveMini() {
  return (
    <span className="wave-mini">
      <i /><i /><i /><i />
    </span>
  );
}

function StatTile({ label, value, icon }: { label: string; value: string; icon: string }) {
  return (
    <div className="stat-tile">
      <span className={`stat-icon ${icon}`}>
        <Icon name={icon} />
      </span>
      <span>{label}</span>
      <b>{value}</b>
    </div>
  );
}

function ProgressLine({
  value,
  label,
  compact = false,
}: {
  value: number;
  label: string;
  compact?: boolean;
}) {
  return (
    <div className={`progress-line ${compact ? 'compact' : ''}`}>
      <span>{label}</span>
      <div><i style={{ width: `${Math.max(0, Math.min(100, value))}%` }} /></div>
    </div>
  );
}

function Pager({ current, total }: { current: number; total: number }) {
  return (
    <div className="pager">
      <Icon name="chevron" />
      <span>{current} / {total}</span>
      <Icon name="chevron" />
    </div>
  );
}

function FieldGroup({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="field-group">
      <h2>{title}</h2>
      {children}
    </section>
  );
}

function LoadingPanel({ text }: { text: string }) {
  return (
    <div className="loading-panel">
      <span className="assistant-avatar large" aria-hidden="true">T</span>
      <p>{text}</p>
    </div>
  );
}

function NavButton({
  label,
  icon,
  active,
  onClick,
}: {
  label: string;
  icon: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button className={`nav-button ${active ? 'active' : ''}`} onClick={onClick}>
      <Icon name={icon} />
      {label}
    </button>
  );
}

const iconPaths: Record<string, ReactNode> = {
  home: (
    <>
      <path d="M4 11.5 12 5l8 6.5" />
      <path d="M6.5 10.5V20h11v-9.5" />
      <path d="M10 20v-5h4v5" />
    </>
  ),
  task: (
    <>
      <path d="M8 5h8" />
      <path d="M9 3h6l1 3H8l1-3Z" />
      <path d="M6.5 6.5h11V21h-11z" />
      <path d="m9 13 2 2 4-5" />
      <path d="M9 18h6" />
    </>
  ),
  plus: (
    <>
      <circle cx="12" cy="12" r="8" />
      <path d="M12 8v8" />
      <path d="M8 12h8" />
    </>
  ),
  gear: (
    <>
      <circle cx="12" cy="12" r="3.2" />
      <path d="M12 3.5v2.2" />
      <path d="M12 18.3v2.2" />
      <path d="M3.5 12h2.2" />
      <path d="M18.3 12h2.2" />
      <path d="m5.9 5.9 1.6 1.6" />
      <path d="m16.5 16.5 1.6 1.6" />
      <path d="m18.1 5.9-1.6 1.6" />
      <path d="m7.5 16.5-1.6 1.6" />
    </>
  ),
  play: <path d="M8 5.5v13l10-6.5-10-6.5Z" />,
  pause: (
    <>
      <path d="M8 5.5h3v13H8z" />
      <path d="M13 5.5h3v13h-3z" />
    </>
  ),
  stop: <path d="M7 7h10v10H7z" />,
  fullscreen: (
    <>
      <path d="M4 9V4h5" />
      <path d="M20 9V4h-5" />
      <path d="M4 15v5h5" />
      <path d="M20 15v5h-5" />
    </>
  ),
  list: (
    <>
      <path d="M8 6.5h12" />
      <path d="M8 12h12" />
      <path d="M8 17.5h12" />
      <path d="M4.5 6.5h.1" />
      <path d="M4.5 12h.1" />
      <path d="M4.5 17.5h.1" />
    </>
  ),
  close: (
    <>
      <path d="m6 6 12 12" />
      <path d="M18 6 6 18" />
    </>
  ),
  recordVideo: (
    <>
      <rect x="4" y="7" width="11" height="10" rx="2" />
      <path d="m15 10 5-3v10l-5-3Z" />
      <path d="M8 12h3" />
    </>
  ),
  download: (
    <>
      <path d="M12 4v10" />
      <path d="m8 10 4 4 4-4" />
      <path d="M5 18.5h14" />
    </>
  ),
  copy: (
    <>
      <rect x="8" y="8" width="10" height="12" rx="2" />
      <path d="M6 16H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v1" />
    </>
  ),
  folder: (
    <>
      <path d="M4 6.5h6l2 2h8v9.5H4z" />
      <path d="M4 10h16" />
    </>
  ),
  music: (
    <>
      <path d="M9 18V6l10-2v12" />
      <circle cx="6.5" cy="18" r="2.5" />
      <circle cx="16.5" cy="16" r="2.5" />
      <path d="M9 9.5 19 7.5" />
    </>
  ),
  wand: (
    <>
      <path d="m5 19 9.5-9.5" />
      <path d="m13 7 4 4" />
      <path d="M17.5 3.5 18 5" />
      <path d="M21 8h-1.5" />
      <path d="M4 5l1 1" />
      <path d="M8 3v2" />
      <path d="M3 10h2" />
    </>
  ),
  mic: (
    <>
      <rect x="9" y="3.5" width="6" height="10" rx="3" />
      <path d="M6.5 11.5a5.5 5.5 0 0 0 11 0" />
      <path d="M12 17v3.5" />
      <path d="M9 20.5h6" />
    </>
  ),
  chat: (
    <>
      <path d="M5 6.5h14v9H9l-4 3v-12Z" />
      <path d="M8 10h8" />
      <path d="M8 13h5" />
    </>
  ),
  sound: (
    <>
      <path d="M4 10v4h4l5 4V6l-5 4H4Z" />
      <path d="M16 9a4 4 0 0 1 0 6" />
      <path d="M18.5 6.5a7.5 7.5 0 0 1 0 11" />
    </>
  ),
  eye: (
    <>
      <path d="M2.8 12s3.4-6 9.2-6 9.2 6 9.2 6-3.4 6-9.2 6-9.2-6-9.2-6Z" />
      <circle cx="12" cy="12" r="2.8" />
    </>
  ),
  eyeOff: (
    <>
      <path d="M2.8 12s3.4-6 9.2-6 9.2 6 9.2 6-3.4 6-9.2 6-9.2-6-9.2-6Z" />
      <circle cx="12" cy="12" r="2.8" />
      <path d="M4 4l16 16" />
    </>
  ),
  exit: (
    <>
      <path d="M10 5H6v14h4" />
      <path d="M12.5 12h7" />
      <path d="m16.5 8 4 4-4 4" />
    </>
  ),
  replay: (
    <>
      <path d="M7 7h5a5 5 0 1 1-4.4 7.4" />
      <path d="M7 7v5" />
      <path d="M7 7h5" />
    </>
  ),
  refresh: (
    <>
      <path d="M18 8a7 7 0 0 0-12-1.5" />
      <path d="M6 3.5v3h3" />
      <path d="M6 16a7 7 0 0 0 12 1.5" />
      <path d="M18 20.5v-3h-3" />
    </>
  ),
  back: (
    <>
      <path d="M19 12H6" />
      <path d="m11 7-5 5 5 5" />
    </>
  ),
  arrow: (
    <>
      <path d="M5 12h13" />
      <path d="m13 7 5 5-5 5" />
    </>
  ),
  prev: (
    <>
      <path d="M19 12H6" />
      <path d="m11 7-5 5 5 5" />
    </>
  ),
  next: (
    <>
      <path d="M5 12h13" />
      <path d="m13 7 5 5-5 5" />
    </>
  ),
  swap: (
    <>
      <path d="M7 7h10" />
      <path d="m14 4 3 3-3 3" />
      <path d="M17 17H7" />
      <path d="m10 14-3 3 3 3" />
    </>
  ),
  save: (
    <>
      <path d="M5 4h11l3 3v13H5z" />
      <path d="M8 4v6h7V4" />
      <path d="M8 20v-6h8v6" />
    </>
  ),
  trash: (
    <>
      <path d="M5 7h14" />
      <path d="M9 7V5h6v2" />
      <path d="M7 7l1 13h8l1-13" />
      <path d="M10 11v5" />
      <path d="M14 11v5" />
    </>
  ),
  upload: (
    <>
      <path d="M12 16V5" />
      <path d="m8 9 4-4 4 4" />
      <path d="M5 17v3h14v-3" />
    </>
  ),
  keyboard: (
    <>
      <rect x="4" y="6" width="16" height="12" rx="2" />
      <path d="M7 10h.1" />
      <path d="M11 10h.1" />
      <path d="M15 10h.1" />
      <path d="M8 14h8" />
    </>
  ),
  edit: (
    <>
      <path d="M4.5 19.5h15" />
      <path d="M6 15.5 15.5 6l2.5 2.5-9.5 9.5H6v-2.5Z" />
      <path d="m14.5 7 2.5 2.5" />
    </>
  ),
  drag: (
    <>
      <path d="M9 6h.1" />
      <path d="M15 6h.1" />
      <path d="M9 12h.1" />
      <path d="M15 12h.1" />
      <path d="M9 18h.1" />
      <path d="M15 18h.1" />
    </>
  ),
  chevron: <path d="m14.5 6-6 6 6 6" />,
  card: (
    <>
      <rect x="4" y="6" width="16" height="12" rx="2" />
      <path d="M7 10h10" />
      <path d="M7 14h6" />
    </>
  ),
  sentence: (
    <>
      <path d="M5 7h14" />
      <path d="M5 12h14" />
      <path d="M5 17h10" />
    </>
  ),
  star: (
    <path d="m12 4 2.3 4.7 5.2.8-3.8 3.7.9 5.2-4.6-2.5-4.6 2.5.9-5.2-3.8-3.7 5.2-.8L12 4Z" />
  ),
  spark: (
    <>
      <path d="M12 3l1.5 5.5L19 10l-5.5 1.5L12 17l-1.5-5.5L5 10l5.5-1.5L12 3Z" />
      <path d="M18 16l.7 2.3L21 19l-2.3.7L18 22l-.7-2.3L15 19l2.3-.7L18 16Z" />
    </>
  ),
};

function Icon({ name }: { name: string }) {
  return (
    <span className={`icon icon-${name}`} aria-hidden="true">
      <svg viewBox="0 0 24 24" focusable="false">
        {iconPaths[name] ?? iconPaths.card}
      </svg>
    </span>
  );
}

function cardArtForArticle(article: Article, index: number): string {
  const title = article.title.toLowerCase();
  if (title.includes('daisy') || title.includes('diver')) return 'card-daisy-diver.png';
  if (title.includes('rocket') || title.includes('race')) return 'card-rocket-race.png';
  return fallbackCards[index % fallbackCards.length];
}

function articleCoverSource(article: Article, index: number): string {
  const generatedCover =
    directImageSource(article.coverImageUri) ?? directImageSource(article.coverImagePath);
  return generatedCover ?? asset(cardArtForArticle(article, index));
}

function directImageSource(source?: string | null): string | null {
  // Do not accept file:// cache paths: WebView cannot load tomato_api_cache files
  // as <img src>. pictureBook.pageImage must return data: URIs instead.
  const trimmed = source?.trim() ?? '';
  if (!trimmed) return null;
  if (/^(data:image\/|blob:|https?:\/\/|assets\/|\.\/|\/assets\/)/i.test(trimmed)) {
    return trimmed;
  }
  return null;
}

function preferBlobImageUrl(source: string): string {
  if (!/^data:image\//i.test(source)) {
    return source;
  }
  const match = /^data:([^;]+);base64,(.+)$/i.exec(source.trim());
  if (!match) {
    return source;
  }
  try {
    const mime = match[1];
    const binary = atob(match[2]);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
    return URL.createObjectURL(new Blob([bytes], { type: mime }));
  } catch {
    return source;
  }
}

function releaseBlobImageUrl(source?: string | null): void {
  const trimmed = source?.trim() ?? '';
  if (trimmed.startsWith('blob:')) {
    URL.revokeObjectURL(trimmed);
  }
}

function displayVoiceLanguage(lang: string): string {
  return lang.replaceAll('中文', '中文/英文');
}

function formatDurationMs(durationMs: number): string {
  const safeMs = Math.max(0, Math.round(durationMs));
  const totalSeconds = Math.floor(safeMs / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}:${seconds.toString().padStart(2, '0')}`;
}

function defaultRecordingVideo(versions: RecordingVideoVersion[]): RecordingVideoVersion | null {
  const usableVersions = versions.filter((version) => version.id && version.videoPath);
  return usableVersions.find((version) => version.isDefault) ?? usableVersions[0] ?? null;
}

function recordingVideoTitle(version: RecordingVideoVersion, index: number): string {
  const createdAt = formatRecordingVideoCreatedAt(version.createdAt);
  if (createdAt) {
    return createdAt;
  }
  return version.title?.trim() || `版本 ${index + 1}`;
}

function recordingVideoSourceLabel(source?: string | null): string {
  if (source === 'song') return '歌曲视频';
  if (source === 'listening') return '听力视频';
  return '视频';
}

function recordingVideoMeta(version: RecordingVideoVersion): string {
  const parts = [
    recordingVideoSourceLabel(version.source),
    version.resolution?.toString().trim(),
    version.codec?.toString().trim().toUpperCase(),
    typeof version.durationMs === 'number' ? formatDurationMs(version.durationMs) : '',
  ].filter((part): part is string => Boolean(part));
  return parts.join(' · ');
}

function normalizeRecordingSettings(settings: RecordingSettings): RecordingSettings {
  const codec = settings.codec === 'h265' ? 'h265' : 'h264';
  const resolution =
    settings.resolution === '2560x1440' || settings.resolution === '1280x720'
      ? settings.resolution
      : '1920x1080';
  const pageTransition =
    settings.pageTransition === 'crossFade' ||
    settings.pageTransition === 'panZoomFade' ||
    settings.pageTransition === 'slide' ||
    settings.pageTransition === 'pageCurl'
      ? settings.pageTransition
      : 'none';
  const subtitleMode =
    settings.subtitleMode === 'burnedIn' || settings.subtitleMode === 'both'
      ? settings.subtitleMode
      : 'srt';
  const fps = Number(settings.fps);
  return {
    ...settings,
    codec,
    resolution,
    pageTransition,
    subtitleMode,
    outputDirectory: settings.outputDirectory ?? '',
    fps: Number.isFinite(fps) && fps > 0 ? fps : 25,
  };
}

function formatRecordingVideoCreatedAt(value?: string | null): string {
  if (!value) return '';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';
  const month = `${date.getMonth() + 1}`.padStart(2, '0');
  const day = `${date.getDate()}`.padStart(2, '0');
  const hour = `${date.getHours()}`.padStart(2, '0');
  const minute = `${date.getMinutes()}`.padStart(2, '0');
  return `${month}-${day} ${hour}:${minute}`;
}

function songLyricsFromItems(items: ListeningItem[]): string {
  return items
    .map((item) => item.english.trim())
    .filter(Boolean)
    .join('\n')
    .trim();
}

function normalizeSongSource(source?: string | null): SongSource {
  if (source === 'external_audio') return 'external_audio';
  return source === 'bailian_fun_music' ? 'bailian_fun_music' : 'suno';
}

function normalizeSongGenerationSource(source?: string | null): SongGenerationSource {
  return source === 'bailian_fun_music' ? 'bailian_fun_music' : 'suno';
}

function normalizeAiProvider(provider?: string | null): AiProvider {
  return provider === 'volcengine' ? 'volcengine' : 'aliyun_bailian';
}

function songSourceLabel(source?: string | null): string {
  const normalized = normalizeSongSource(source);
  if (normalized === 'external_audio') return '外部导入';
  return normalized === 'bailian_fun_music' ? '阿里云百聆' : 'Suno 网页自动化';
}

function groupSongVersionsForDisplay(versions: SongVersionPayload[]): SongVersionGroup[] {
  const groups = new Map<SongSource, SongVersionPayload[]>();
  versions.forEach((version) => {
    const source = normalizeSongSource(version.source);
    groups.set(source, [...(groups.get(source) ?? []), version]);
  });
  return Array.from(groups.entries()).map(([source, groupVersions]) => ({
    key: `${source}-local-versions`,
    label: songSourceLabel(source),
    versions: groupVersions,
  }));
}

function normalizeTimelineStatus(status?: string | null, timelinePath?: string | null): string {
  const value = (status ?? '').trim();
  if (value) return value;
  return timelinePath?.trim() ? 'ready' : 'missing';
}

function songSubtitleNoticeForVersion(version?: SongVersionPayload | null): string | null {
  if (!version) return null;
  const status = normalizeTimelineStatus(version.timelineStatus, version.timelinePath);
  if (status === 'ready') return null;
  if (status === 'generating') {
    return '这首歌的字幕正在生成，生成完成后会同步歌词。';
  }
  if (status === 'error') {
    const detail = version.timelineError?.trim();
    return detail
      ? `这首歌字幕生成失败：${detail}。请到创作中心重新生成歌曲字幕。`
      : '这首歌字幕生成失败，请到创作中心重新生成歌曲字幕。';
  }
  if (status === 'stale') {
    return '这首歌的字幕时间线版本过旧，请到创作中心重新生成歌曲字幕。';
  }
  return '这首歌还没有生成字幕，请到创作中心生成歌曲字幕。';
}

function songTimelineLabel(status?: string | null): string {
  switch ((status ?? '').trim()) {
    case 'ready':
      return '字幕已生成';
    case 'generating':
      return '字幕生成中';
    case 'error':
      return '重新生成字幕';
    case 'stale':
      return '重新生成字幕';
    default:
      return '生成歌曲字幕';
  }
}

function isSunoWaitingConfirm(state?: ListeningSongStatePayload | null): boolean {
  return (
    state?.source === 'suno' &&
    state.status === 'generating' &&
    (state.automationStatus ?? '').trim() === 'waitingConfirm'
  );
}

function songAutomationStatusText(state: ListeningSongStatePayload): string {
  const manual = state.manualActionMessage?.trim();
  if (manual) return manual;
  if (state.source === 'bailian_fun_music') {
    return '阿里云百聆正在生成歌曲...';
  }
  switch ((state.automationStatus ?? '').trim()) {
    case 'waitingLogin':
      return 'Suno 页面已打开，请先在页面中自行登录。';
    case 'filling':
      return '正在自动填写 Suno 歌词并生成风格...';
    case 'waitingConfirm':
      return '已填写完成，等待确认消耗 Suno credits。';
    case 'creating':
      return 'Suno 正在生成歌曲...';
    case 'downloading':
      return '正在下载 Suno 生成的歌曲...';
    case 'manualAction':
      return '需要在 Suno 页面手工完成当前步骤。';
    default:
      return 'Suno 自动操作中...';
  }
}

function tokenizeEnglishText(text: string): Array<{ text: string; word: boolean }> {
  const matches = text.match(/[A-Za-z]+(?:[-'][A-Za-z]+)*|[^A-Za-z]+/g);
  if (!matches) {
    return [{ text, word: false }];
  }

  return matches.map((part) => ({
    text: part,
    word: /^[A-Za-z]+(?:[-'][A-Za-z]+)*$/.test(part),
  }));
}

function normalizeLookupWord(word: string): string {
  return word
    .replace(/[‘’]/g, "'")
    .replace(/^[^A-Za-z]+|[^A-Za-z]+$/g, '')
    .trim();
}

function wordCardPositionFor(anchor: DOMRect): WordCardPosition {
  const margin = 12;
  const container = document.querySelector('.main-stage')?.getBoundingClientRect();
  const containerLeft = container?.left ?? 0;
  const containerTop = container?.top ?? 0;
  const cardWidth = Math.min(360, Math.max(280, window.innerWidth - margin * 2));
  const estimatedHeight = 320;
  const centerLeft = anchor.left + anchor.width / 2 - cardWidth / 2;
  const viewportLeft = Math.min(Math.max(centerLeft, margin), window.innerWidth - cardWidth - margin);
  const belowTop = anchor.bottom + 10;
  const canFitBelow = belowTop + estimatedHeight <= window.innerHeight - margin;
  const preferredTop = canFitBelow
    ? belowTop
    : Math.max(margin, anchor.top - estimatedHeight - 10);
  const maxTop = Math.max(margin, window.innerHeight - estimatedHeight - margin);
  const viewportTop = Math.min(Math.max(preferredTop, margin), maxTop);

  return {
    top: Math.round(viewportTop - containerTop),
    left: Math.round(viewportLeft - containerLeft),
    placement: canFitBelow ? 'below' : 'above',
  };
}

function useHashRoute(): [string, (path: string) => void] {
  const read = () => window.location.hash.replace(/^#/, '') || '/';
  const [route, setRouteState] = useState(read);

  useEffect(() => {
    const onHashChange = () => setRouteState(read());
    window.addEventListener('hashchange', onHashChange);
    return () => window.removeEventListener('hashchange', onHashChange);
  }, []);

  const setRoute = (path: string) => {
    window.location.hash = path;
    setRouteState(path);
  };

  return [route, setRoute];
}

function parseRoute(route: string):
  | { kind: 'home' }
  | { kind: 'article' }
  | { kind: 'book'; seriesId: number }
  | { kind: 'bookPlayer'; seriesId: number; articleId: number; mode: PlayerMode }
  | { kind: 'creation'; seriesId?: number; articleId?: number }
  | { kind: 'practice'; seriesId?: number }
  | { kind: 'listen'; articleId: number }
  | { kind: 'follow'; articleId: number }
  | { kind: 'chat'; articleId: number }
  | { kind: 'settings' } {
  const [path, rawQuery = ''] = route.split('?');
  const query = new URLSearchParams(rawQuery);
  if (path === '/article/new') return { kind: 'article' };
  if (path === '/settings' || path === '/profile') return { kind: 'settings' };
  if (path === '/creation') {
    const seriesId = Number(query.get('seriesId') ?? '');
    const articleId = Number(query.get('articleId') ?? '');
    return {
      kind: 'creation',
      seriesId: Number.isFinite(seriesId) && seriesId > 0 ? seriesId : undefined,
      articleId: Number.isFinite(articleId) && articleId > 0 ? articleId : undefined,
    };
  }
  if (path === '/practice') {
    const seriesId = Number(query.get('seriesId') ?? '');
    return {
      kind: 'practice',
      seriesId: Number.isFinite(seriesId) && seriesId > 0 ? seriesId : undefined,
    };
  }

  const bookPlayer = path.match(/^\/books\/(\d+)\/player/);
  if (bookPlayer) {
    const articleId = Number(query.get('articleId') ?? 0);
    const rawMode = query.get('mode')?.trim();
    return {
      kind: 'bookPlayer',
      seriesId: Number(bookPlayer[1]),
      articleId: Number.isFinite(articleId) ? articleId : 0,
      mode: rawMode === 'song' ? 'song' : 'listening',
    };
  }

  const book = path.match(/^\/books\/(\d+)/);
  if (book) return { kind: 'book', seriesId: Number(book[1]) };

  const follow = path.match(/^\/follow\/(\d+)/);
  if (follow) return { kind: 'follow', articleId: Number(follow[1]) };

  const listen = path.match(/^\/listen\/(\d+)/);
  if (listen) return { kind: 'listen', articleId: Number(listen[1]) };

  const chat = path.match(/^\/chat\/(\d+)/);
  if (chat) return { kind: 'chat', articleId: Number(chat[1]) };

  return { kind: 'home' };
}

function isListeningBusy(status: ListeningStatus): boolean {
  return status === 'playing' || status === 'stopping';
}

function isFollowActionLocked(step: string): boolean {
  return ['loadingTts', 'playing', 'recording', 'scoring'].includes(step);
}

function chatSideCue(step: string): string {
  if (step === 'init') return '番茄助教正在准备问题...';
  if (step === 'aiSpeaking') return '番茄助教正在说，认真听。';
  if (step === 'recording') return '正在听你说英语。';
  if (step === 'processing') return '番茄助教正在想答案。';
  if (step === 'completed') return '这轮对话完成啦。';
  if (step === 'error') return '对话暂时卡住了。';
  return '轮到你说英语啦。';
}

function chatInputCue(step: string): string {
  if (step === 'init') return '正在准备第一个问题';
  if (step === 'aiSpeaking') return '先听番茄助教说完';
  if (step === 'recording') return '正在录音';
  if (step === 'processing') return '番茄助教思考中';
  if (step === 'completed') return '这轮对话已经完成';
  if (step === 'error') return '可以返回后重新进入对话';
  return '输入或按住说英语';
}

export default App;
