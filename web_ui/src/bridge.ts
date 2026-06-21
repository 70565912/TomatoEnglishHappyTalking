import type {
  Article,
  ArticleFullTextPayload,
  BookCharacter,
  BridgeResponse,
  ChatState,
  DiagnosticLogEntry,
  FollowState,
  ListeningOpenPayload,
  NativeEvent,
  PictureBookPromptReview,
  PictureBookState,
  RecordingSettings,
  RecordingVideoVersion,
  SettingsState,
  SongSource,
  StorySeries,
  VoiceOption,
} from './types';
import { splitSentences } from './sentenceSplitter';

type NativeListener<T = unknown> = (payload: T) => void;
type AiProvider = 'aliyun_bailian' | 'volcengine';

declare global {
  interface Window {
    flutter_inappwebview?: {
      callHandler: (
        handlerName: string,
        message: Record<string, unknown>,
      ) => Promise<BridgeResponse>;
    };
    chrome?: {
      webview?: unknown;
    };
    __tomatoNativeEvent?: (event: NativeEvent) => void;
    __tomatoDiagnosticsInstalled?: boolean;
  }
}

const listeners = new Map<string, Set<NativeListener>>();
const FLUTTER_BRIDGE_WAIT_MS = 1800;
const FLUTTER_BRIDGE_POLL_MS = 50;
const DIAGNOSTICS_CLIENT_LOG = 'diagnostics.clientLog';
const CLIENT_LOG_MAX_STRING = 360;
const mockDiagnosticLogs: DiagnosticLogEntry[] = [];

export function onNativeEvent<T>(
  type: string,
  listener: NativeListener<T>,
): () => void {
  const bucket = listeners.get(type) ?? new Set<NativeListener>();
  bucket.add(listener as NativeListener);
  listeners.set(type, bucket);

  return () => {
    bucket.delete(listener as NativeListener);
    if (bucket.size === 0) {
      listeners.delete(type);
    }
  };
}

export function emitNativeEvent(event: NativeEvent): void {
  const bucket = listeners.get(event.type);
  if (!bucket) {
    return;
  }
  bucket.forEach((listener) => listener(event.payload));
}

window.__tomatoNativeEvent = emitNativeEvent;

export async function sendNative<T>(
  type: string,
  payload: Record<string, unknown> = {},
): Promise<T> {
  const startedAt = performanceNow();
  const message = {
    id: makeRequestId(),
    type,
    payload,
  };

  try {
    const flutterBridge = await resolveFlutterBridge();
    const response = flutterBridge
      ? await flutterBridge.callHandler('tomatoBridge', message)
      : await mockNativeResponse(type, payload, message.id);

    const durationMs = Math.round(performanceNow() - startedAt);
    if (!response.ok) {
      throw new Error(response.error?.message ?? `Native command failed: ${type}`);
    }
    reportClientLog({
      level: 'debug',
      category: 'bridge',
      event: 'command.success',
      message: type,
      durationMs,
      data: {
        type,
        id: message.id,
        payload: summarizeNativePayload(payload),
      },
    });
    return (response.payload ?? {}) as T;
  } catch (error) {
    reportClientLog({
      level: 'error',
      category: 'bridge',
      event: 'command.failed',
      message: type,
      durationMs: Math.round(performanceNow() - startedAt),
      data: {
        type,
        id: message.id,
        payload: summarizeNativePayload(payload),
      },
      error,
    });
    throw error;
  }
}

async function resolveFlutterBridge(): Promise<Window['flutter_inappwebview']> {
  if (window.flutter_inappwebview) {
    return window.flutter_inappwebview;
  }

  if (!isLikelyEmbeddedWebView()) {
    return undefined;
  }

  return waitForFlutterBridge(FLUTTER_BRIDGE_WAIT_MS);
}

function isLikelyEmbeddedWebView(): boolean {
  return Boolean(window.flutter_inappwebview || window.chrome?.webview);
}

function waitForFlutterBridge(timeoutMs: number): Promise<Window['flutter_inappwebview']> {
  if (window.flutter_inappwebview) {
    return Promise.resolve(window.flutter_inappwebview);
  }

  return new Promise((resolve) => {
    let settled = false;
    let pollTimer: number | undefined;

    const finish = () => {
      if (settled) {
        return;
      }
      settled = true;
      window.removeEventListener('flutterInAppWebViewPlatformReady', finish);
      if (pollTimer !== undefined) {
        window.clearInterval(pollTimer);
      }
      resolve(window.flutter_inappwebview);
    };

    pollTimer = window.setInterval(() => {
      if (window.flutter_inappwebview) {
        finish();
      }
    }, FLUTTER_BRIDGE_POLL_MS);

    window.addEventListener('flutterInAppWebViewPlatformReady', finish, {
      once: true,
    });
    window.setTimeout(finish, timeoutMs);
  });
}

function makeRequestId(): string {
  return `web_${Date.now()}_${Math.round(Math.random() * 1_000_000)}`;
}

function performanceNow(): number {
  return window.performance?.now?.() ?? Date.now();
}

function reportClientLog({
  level,
  category,
  event,
  message,
  durationMs,
  data,
  error,
}: {
  level: string;
  category: string;
  event: string;
  message?: string;
  durationMs?: number;
  data?: unknown;
  error?: unknown;
}): void {
  if (event !== 'command.failed' && message === DIAGNOSTICS_CLIENT_LOG) {
    return;
  }

  const bridge = window.flutter_inappwebview;
  if (!bridge) {
    return;
  }

  const errorInfo = errorInfoFrom(error);
  const payload = {
    level,
    category,
    event,
    message: sanitizeDiagnosticString(message ?? ''),
    durationMs,
    data: sanitizeDiagnosticValue(data),
    error: errorInfo.message,
    stack: errorInfo.stack,
  };

  try {
    void bridge
      .callHandler('tomatoBridge', {
        id: makeRequestId(),
        type: DIAGNOSTICS_CLIENT_LOG,
        payload,
      })
      .catch(() => undefined);
  } catch {
    // Diagnostics must never break the product UI.
  }
}

function installClientDiagnostics(): void {
  if (window.__tomatoDiagnosticsInstalled) {
    return;
  }
  window.__tomatoDiagnosticsInstalled = true;

  window.addEventListener('error', (event) => {
    reportClientLog({
      level: 'error',
      category: 'webview',
      event: 'window.error',
      message: event.message,
      data: {
        filename: event.filename,
        line: event.lineno,
        column: event.colno,
      },
      error: event.error,
    });
  });

  window.addEventListener('unhandledrejection', (event) => {
    reportClientLog({
      level: 'error',
      category: 'webview',
      event: 'window.unhandled_rejection',
      message: 'Unhandled promise rejection',
      error: event.reason,
    });
  });

  const originalWarn = console.warn.bind(console);
  console.warn = (...args: unknown[]) => {
    originalWarn(...args);
    reportClientLog({
      level: 'warn',
      category: 'webview',
      event: 'console.warn',
      message: formatDiagnosticArgs(args),
      data: {argCount: args.length},
    });
  };

  const originalError = console.error.bind(console);
  console.error = (...args: unknown[]) => {
    originalError(...args);
    reportClientLog({
      level: 'error',
      category: 'webview',
      event: 'console.error',
      message: formatDiagnosticArgs(args),
      data: {argCount: args.length},
      error: args.find((item) => item instanceof Error),
    });
  };
}

function summarizeNativePayload(payload: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(payload)
      .slice(0, 30)
      .map(([key, value]) => [key, summarizeDiagnosticValue(value, key)]),
  );
}

function summarizeDiagnosticValue(value: unknown, key?: string): unknown {
  if (isSensitiveKey(key)) {
    return '[redacted]';
  }
  if (value == null || typeof value === 'number' || typeof value === 'boolean') {
    return value;
  }
  if (typeof value === 'string') {
    return {
      type: 'string',
      length: value.length,
      sample: sanitizeDiagnosticString(value.slice(0, 80)),
    };
  }
  if (Array.isArray(value)) {
    return {type: 'array', length: value.length};
  }
  if (typeof value === 'object') {
    return {type: 'object', keys: Object.keys(value as Record<string, unknown>).slice(0, 20)};
  }
  return typeof value;
}

function sanitizeDiagnosticValue(value: unknown, key?: string, depth = 0): unknown {
  if (isSensitiveKey(key)) {
    return '[redacted]';
  }
  if (value == null || typeof value === 'number' || typeof value === 'boolean') {
    return value;
  }
  if (typeof value === 'string') {
    return sanitizeDiagnosticString(value);
  }
  if (depth >= 4) {
    return '[max-depth]';
  }
  if (Array.isArray(value)) {
    const items = value.slice(0, 30).map((item) => sanitizeDiagnosticValue(item, undefined, depth + 1));
    return value.length > 30 ? {items, truncated: true, length: value.length} : items;
  }
  if (typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .slice(0, 30)
        .map(([childKey, childValue]) => [
          childKey,
          sanitizeDiagnosticValue(childValue, childKey, depth + 1),
        ]),
    );
  }
  return sanitizeDiagnosticString(String(value));
}

function sanitizeDiagnosticString(value: string): string {
  let text = value
    .replace(/Bearer\s+[A-Za-z0-9._~+/=-]{12,}/gi, 'Bearer [redacted]')
    .replace(
      /(X-Api-Key|api[_-]?key|authorization|cookie|token|secret)\s*[:=]\s*[^,\s;}]+/gi,
      '$1=[redacted]',
    )
    .replace(/[A-Za-z]:\\[^\s"<>|]+/g, (match) => `[path:${pathBaseName(match)}]`);
  if (text.length <= CLIENT_LOG_MAX_STRING) {
    return text;
  }
  return `${text.slice(0, 180)}...[truncated length=${text.length}]...${text.slice(-80)}`;
}

function isSensitiveKey(key?: string): boolean {
  return Boolean(key?.match(/api[_-]?key|authorization|bearer|cookie|token|secret|password|credential/i));
}

function pathBaseName(value: string): string {
  const normalized = value.replaceAll('\\', '/');
  const parts = normalized.split('/');
  return parts.at(-1) || 'file';
}

function errorInfoFrom(error: unknown): {message?: string; stack?: string} {
  if (!error) {
    return {};
  }
  if (error instanceof Error) {
    return {
      message: sanitizeDiagnosticString(error.message),
      stack: sanitizeDiagnosticString(error.stack ?? ''),
    };
  }
  return {message: sanitizeDiagnosticString(String(error))};
}

function formatDiagnosticArgs(args: unknown[]): string {
  return sanitizeDiagnosticString(
    args
      .slice(0, 6)
      .map((item) => {
        if (item instanceof Error) {
          return item.message;
        }
        if (typeof item === 'string') {
          return item;
        }
        try {
          return JSON.stringify(sanitizeDiagnosticValue(item));
        } catch {
          return String(item);
        }
      })
      .join(' '),
  );
}

installClientDiagnostics();

async function mockNativeResponse(
  type: string,
  payload: Record<string, unknown>,
  id: string,
): Promise<BridgeResponse> {
  await delay(80);
  const responsePayload = mockPayload(type, payload);
  return {
    id,
    ok: true,
    type: `${type}.result`,
    payload: responsePayload,
  };
}

function mockPayload(type: string, payload: Record<string, unknown>): unknown {
  if (type === 'diagnostics.logsRecent') {
    return {logs: mockDiagnosticLogs.slice(-Number(payload.limit ?? 200))};
  }
  if (type === 'diagnostics.logsExport') {
    return {path: 'mock-diagnostics', files: ['environment.json', 'recent.ndjson']};
  }
  if (type === DIAGNOSTICS_CLIENT_LOG) {
    const log = payload as Partial<DiagnosticLogEntry>;
    mockDiagnosticLogs.push({
      ts: new Date().toISOString(),
      level: String(log.level ?? 'info'),
      category: String(log.category ?? 'webview'),
      event: String(log.event ?? 'client.log'),
      message: log.message ?? null,
      durationMs: typeof log.durationMs === 'number' ? log.durationMs : null,
      data: sanitizeDiagnosticValue(log.data),
      error: log.error ?? null,
      stack: log.stack ?? null,
    });
    return {accepted: true};
  }
  if (type === 'article.list' || type === 'app.ready') {
    return { articles: mockArticles, series: mockSeries };
  }
  if (type === 'article.create') {
    const content = normalizePracticeContent(String(payload.content ?? ''));
    const sentences = splitSentences(content);
    const pictureBookEnabled = payload.pictureBookEnabled !== false;
    const requestedTitle = String(payload.title ?? '').trim();
    const resolvedTitle = requestedTitle || mockSuggestTitle(content);
    const requestedSeriesTitle = String(payload.seriesTitle ?? '').trim();
    const requestedSeriesId = payload.seriesId === undefined || payload.seriesId === null
      ? null
      : Number(payload.seriesId);
    const existingSeries = requestedSeriesId === null
      ? null
      : mockSeries.find((item) => item.id === requestedSeriesId) ?? null;
    const seriesTitle = requestedSeriesTitle || existingSeries?.title || '';
    const seriesDescription = String(payload.seriesDescription ?? '').trim() || existingSeries?.description || '';
    const seriesCharactersProvided = Object.prototype.hasOwnProperty.call(payload, 'seriesCharacters');
    const requestedSeriesCharacters = normalizeMockBookCharacters(payload.seriesCharacters);
    const seriesCharacters = seriesCharactersProvided
      ? requestedSeriesCharacters
      : existingSeries?.characters ?? [];
    const seriesId = requestedSeriesId ?? 12;
    const article: Article = {
      id: 99,
      title: resolvedTitle || 'New Chapter',
      content,
      sentences,
      sentenceCount: sentences.length,
      createdAt: new Date().toISOString(),
      averageScore: 0,
      pictureBookEnabled,
      seriesId: pictureBookEnabled ? seriesId : null,
      seriesTitle: pictureBookEnabled ? seriesTitle : '',
      seriesDescription: pictureBookEnabled ? seriesDescription : '',
      chapterOrder: pictureBookEnabled ? 2 : null,
    };
    const nextSeries = existingSeries
      ? mockSeries.map((item) =>
          item.id === seriesId ? { ...item, title: seriesTitle, description: seriesDescription, characters: seriesCharacters } : item,
        )
      : [
          {
            id: seriesId,
            title: seriesTitle,
            description: seriesDescription,
            characters: seriesCharacters,
            coverImagePath: null,
            createdAt: new Date().toISOString(),
            updatedAt: new Date().toISOString(),
          },
          ...mockSeries,
        ];
    return { article, articles: [article, ...mockArticles], series: nextSeries };
  }
  if (type === 'article.rename') {
    const articleId = Number(payload.articleId ?? mockArticles[0].id);
    const title = String(payload.title ?? '').trim() || mockArticles[0].title;
    const articles = mockArticles.map((article) =>
      article.id === articleId ? { ...article, title } : article,
    );
    return {
      article: articles.find((article) => article.id === articleId) ?? articles[0],
      articles,
      series: mockSeries,
    };
  }
  if (type === 'article.fullText') {
    const articleId = Number(payload.articleId ?? mockArticles[0].id);
    const article = mockArticles.find((item) => item.id === articleId) ?? mockListening.article;
    const fullText: ArticleFullTextPayload = {
      article,
      bookTitle: article.seriesTitle || mockSeries[0]?.title || article.title,
      items: article.sentences.map((sentence, index) => ({
        index,
        english: sentence,
        chinese: index === 0 ? '汤姆发现了一个明亮的零食盒。' : '',
      })),
    };
    return fullText;
  }
  if (type === 'article.suggestTitle') {
    return { title: mockSuggestTitle(String(payload.content ?? '')) };
  }
  if (type === 'article.translateToEnglish') {
    return {
      content: normalizePracticeContent(
        mockTranslateToEnglish(String(payload.content ?? '')),
      ),
    };
  }
  if (type === 'follow.open') {
    return mockFollow;
  }
  if (type === 'series.list') {
    return { series: mockSeries };
  }
  if (type === 'series.suggestDescription') {
    throw new Error('Mock bridge does not generate book descriptions. Configure the native AI provider and retry.');
  }
  if (type === 'series.create') {
    const title = String(payload.title ?? '').trim();
    const series: StorySeries = {
      id: 12,
      title,
      description: String(payload.description ?? '').trim(),
      characters: normalizeMockBookCharacters(payload.characters),
      coverImagePath: null,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };
    return { series: [series, ...mockSeries] };
  }
  if (type === 'series.update') {
    const seriesId = Number(payload.seriesId ?? mockSeries[0].id);
    const title = String(payload.title ?? '').trim() || mockSeries[0].title;
    const description = String(payload.description ?? '').trim();
    const characters = normalizeMockBookCharacters(payload.characters);
    const series = mockSeries.map((item) =>
      item.id === seriesId
        ? { ...item, title, description, characters, updatedAt: new Date().toISOString() }
        : item,
    );
    const articles = mockArticles.map((article) =>
      article.seriesId === seriesId
        ? { ...article, seriesTitle: title, seriesDescription: description }
        : article,
    );
    return { articles, series };
  }
  if (type === 'series.delete') {
    const seriesId = Number(payload.seriesId ?? 0);
    return {
      articles: mockArticles,
      series: mockSeries.filter((item) => item.id !== seriesId),
    };
  }
  if (type === 'series.attachArticle') {
    const articleId = Number(payload.articleId ?? mockArticles[0].id);
    const seriesId = Number(payload.seriesId ?? mockSeries[0].id);
    const seriesTitle = String(payload.seriesTitle ?? mockSeries[0].title);
    const seriesDescription = String(payload.seriesDescription ?? '').trim() || mockSeries[0].description || '';
    const seriesCharactersProvided = Object.prototype.hasOwnProperty.call(payload, 'seriesCharacters');
    const seriesCharacters = normalizeMockBookCharacters(payload.seriesCharacters);
    const article = {
      ...(mockArticles.find((item) => item.id === articleId) ??
        mockArticles[0]),
      pictureBookEnabled: true,
      seriesId,
      seriesTitle,
      seriesDescription,
      chapterOrder: 1,
    };
    return {
      article,
      chapter: {
        articleId,
        seriesId,
        chapterOrder: 1,
        chapterTitle: article.title,
      },
      articles: mockArticles.map((item) =>
        item.id === articleId ? article : item,
      ),
      series: mockSeries.map((item) =>
        item.id === seriesId && seriesCharactersProvided
          ? { ...item, characters: seriesCharacters }
          : item,
      ),
    };
  }
  if (type === 'series.export') {
    const seriesId = Number(payload.seriesId ?? mockSeries[0].id);
    const series = mockSeries.find((item) => item.id === seriesId) ?? mockSeries[0];
    return {
      cancelled: false,
      seriesId,
      title: series.title,
      outputPath: `C:\\TomatoExports\\${series.title}.zip`,
      articleCount: mockArticles.filter((article) => article.seriesId === seriesId).length,
      assetCount: 3,
      warnings: [],
    };
  }
  if (type === 'series.import') {
    const importedSeries: StorySeries = {
      id: 99,
      title: 'Imported Book',
      description: 'Imported from a Tomato English transfer package.',
      characters: [],
      coverImagePath: null,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };
    const importedArticle: Article = {
      ...mockArticles[0],
      id: 9901,
      title: 'Imported Chapter',
      seriesId: importedSeries.id,
      seriesTitle: importedSeries.title,
      seriesDescription: importedSeries.description,
      chapterOrder: 1,
      createdAt: new Date().toISOString(),
    };
    const articles = [importedArticle, ...mockArticles];
    const series = [importedSeries, ...mockSeries];
    return {
      cancelled: false,
      seriesId: importedSeries.id,
      title: importedSeries.title,
      articleIds: [importedArticle.id],
      articleCount: 1,
      assetCount: 3,
      warnings: [],
      articles,
      series,
    };
  }
  if (type === 'pictureBook.state') {
    return mockPictureBook(Number(payload.articleId ?? 1));
  }
  if (type === 'pictureBook.pageImage') {
    return {
      articleId: Number(payload.articleId ?? 1),
      pageIndex: Number(payload.pageIndex ?? 0),
      imageUri: assetUrl('card-space-snacks.png'),
    };
  }
  if (type === 'pictureBook.promptReview') {
    return mockPictureBookPromptReview(
      Number(payload.articleId ?? 1),
      payload.regenerate === true,
    );
  }
  if (type === 'pictureBook.pagePromptReview') {
    const articleId = Number(payload.articleId ?? 1);
    const pageIndex = Number(payload.pageIndex ?? 0);
    const review = mockPictureBookPromptReview(articleId, true);
    const scene = review.scenes.find((item) => item.pageIndex === pageIndex) ?? review.scenes[0];
    return {
      ...review,
      reviewId: `mock-page-review-${articleId}-${pageIndex}`,
      mode: 'singlePage',
      targetPageIndex: scene?.pageIndex ?? pageIndex,
      referencePageIndex: (scene?.pageIndex ?? pageIndex) > 0 ? (scene?.pageIndex ?? pageIndex) - 1 : 1,
      scenes: scene ? [scene] : [],
      groupPrompt: mockSinglePagePrompt(scene, review.bookCharacters ?? []),
    };
  }
  if (type === 'pictureBook.refreshPromptReview') {
    const review = mockPictureBookPromptReview(1, false);
    const target = String(payload.target ?? '');
    if (target === 'bookDescription') {
      return {
        ...review,
        bookDescription: 'Refreshed short picture-book world with a bright cozy spaceship interior.',
        bookCharacters: review.bookCharacters,
        groupPrompt:
          'Book name: Space Story Series\nBook description: Refreshed short picture-book world with a bright cozy spaceship interior.',
        refreshedTarget: target,
      };
    }
    if (target === 'chapterPlan') {
      return {
        ...review,
        chapterDescription:
          'Refreshed chapter description with one coherent visual sequence.',
        bookCharacters: normalizeMockBookCharacters(payload.bookCharacters).length > 0
          ? normalizeMockBookCharacters(payload.bookCharacters)
          : review.bookCharacters,
        newCharacters: normalizeMockBookCharacters(payload.newCharacters),
        scenes: review.scenes.map((scene, index) => ({
          ...scene,
          sceneDescription: `Refreshed scene action ${index + 1}`,
        })),
        groupPrompt:
          'Book name: Space Story Series\nBook description: A gentle space-adventure picture book about curious children exploring small wonders together.\n\nChapter description: Refreshed chapter description with one coherent visual sequence.',
        refreshedTarget: target,
      };
    }
    return review;
  }
  if (type === 'pictureBook.confirmPromptReview') {
    return mockPictureBook(Number(payload.articleId ?? 1), 'generating');
  }
  if (type === 'pictureBook.confirmPagePromptReview') {
    return mockPictureBook(Number(payload.articleId ?? 1), 'generating');
  }
  if (type === 'pictureBook.savePromptReview') {
    return {
      ...mockPictureBookPromptReview(Number(payload.articleId ?? 1), false),
      reviewId: String(payload.reviewId ?? 'mock-review-1'),
      bookDescription: String(payload.bookDescription ?? ''),
      bookCharacters: normalizeMockBookCharacters(payload.bookCharacters),
      relevantCharacters: normalizeMockBookCharacters(payload.bookCharacters),
      newCharacters: normalizeMockBookCharacters(payload.newCharacters),
      chapterDescription: String(payload.chapterDescription ?? ''),
      groupPrompt: String(payload.groupPrompt ?? ''),
      scenes: Array.isArray(payload.scenes) ? payload.scenes : [],
    };
  }
  if (type === 'pictureBook.cancelPromptReview') {
    return {
      reviewId: String(payload.reviewId ?? ''),
      cancelled: true,
    };
  }
  if (type === 'pictureBook.generate' || type === 'pictureBook.retryPage') {
    return mockPictureBookPromptReview(
      Number(payload.articleId ?? 1),
      type === 'pictureBook.retryPage' || payload.regenerate === true,
    );
  }
  if (type === 'listening.open') {
    return mockListening;
  }
  if (type === 'listening.songState') {
    return {
      articleId: Number(payload.articleId ?? mockListening.article.id),
      status: 'empty',
      stylePrompt: '',
      audioPath: null,
      errorMessage: '',
      source: mockSettings.song?.songProvider ?? 'suno',
    };
  }
  if (type === 'listening.songGenerate') {
    const articleId = Number(payload.articleId ?? mockListening.article.id);
    const source = String(payload.source ?? mockSettings.song?.songProvider ?? 'suno');
    if (source === 'bailian_fun_music') {
      const result = {
        articleId,
        status: 'ready',
        stylePrompt: '',
        audioPath: 'mock-bailian-fun-music.mp3',
        errorMessage: '',
        durationMs: 42000,
        source: 'bailian_fun_music',
        automationStatus: 'complete',
        manualActionMessage: '阿里云百聆已生成 mock 歌曲。',
        downloadComplete: true,
        versions: [
          {
            id: 'mock-bailian-fun-music-1',
            audioPath: 'mock-bailian-fun-music.mp3',
            title: '阿里云百聆版本 1',
            durationMs: 42000,
            source: 'bailian_fun_music',
            timelineStatus: 'missing',
            isDefault: true,
          },
        ],
      };
      window.setTimeout(() => {
        emitNativeEvent({ type: 'listening.song.state', payload: result });
      }, 40);
      return result;
    }
    const sunoResult = {
      articleId,
      status: 'generating',
      stylePrompt: '',
      audioPath: null,
      errorMessage: '',
      durationMs: null,
      source: 'suno',
      automationStatus: 'waitingLogin',
      manualActionMessage: 'Suno 页面已打开，请先在页面中自行登录。',
    };
    window.setTimeout(() => {
      emitNativeEvent({ type: 'listening.song.state', payload: sunoResult });
    }, 40);
    return sunoResult;
  }
  if (type === 'listening.songImportExternal') {
    const articleId = Number(payload.articleId ?? mockListening.article.id);
    const result = {
      articleId,
      status: 'ready',
      stylePrompt: '',
      audioPath: 'mock-external-audio.mp3',
      errorMessage: '',
      durationMs: 36000,
      source: 'external_audio',
      automationStatus: 'complete',
      manualActionMessage: '',
      downloadComplete: true,
      versions: [
        {
          id: 'mock-external-audio-1',
          audioPath: 'mock-external-audio.mp3',
          title: '导入音乐',
          durationMs: 36000,
          source: 'external_audio',
          timelineStatus: 'missing',
          isDefault: true,
        },
      ],
    };
    window.setTimeout(() => {
      emitNativeEvent({ type: 'listening.song.state', payload: result });
    }, 40);
    return result;
  }
  if (type === 'listening.songConfirmSunoCreate') {
    const articleId = Number(payload.articleId ?? mockListening.article.id);
    const result = {
      articleId,
      status: 'generating',
      stylePrompt: '',
      audioPath: null,
      errorMessage: '',
      durationMs: null,
      source: 'suno',
      automationStatus: 'creating',
      manualActionMessage: 'Suno 正在生成歌曲...',
    };
    window.setTimeout(() => {
      emitNativeEvent({ type: 'listening.song.state', payload: result });
    }, 40);
    return result;
  }
  if (type === 'listening.songDownloadSunoExisting') {
    const articleId = Number(payload.articleId ?? mockListening.article.id);
    const result = {
      articleId,
      status: 'generating',
      stylePrompt: '',
      audioPath: null,
      errorMessage: '',
      durationMs: null,
      source: 'suno',
      songUrl: 'https://suno.com/song/mock',
      automationStatus: 'downloading',
      manualActionMessage: '正在打开 Suno 已生成歌曲并尝试下载...',
    };
    window.setTimeout(() => {
      emitNativeEvent({ type: 'listening.song.state', payload: result });
    }, 40);
    return result;
  }
  if (type === 'listening.songPlay') {
    const articleId = Number(payload.articleId ?? mockListening.article.id);
    const versionId = String(payload.versionId ?? '');
    window.setTimeout(() => {
      emitNativeEvent({
        type: 'listening.song.state',
        payload: {
          articleId,
          status: 'playing',
          stylePrompt: '',
          audioPath: 'mock-song.mp3',
          errorMessage: '',
          versions: [
            {
              id: versionId || 'mock-suno-1',
              audioPath: 'mock-song.mp3',
              title: 'Suno 版本 1',
              durationMs: 32000,
              timelineStatus: 'ready',
              timelinePath: 'mock-song-timeline.json',
              timelineConfidence: 0.92,
            },
          ],
        },
      });
      emitNativeEvent({
        type: 'listening.song.position',
        payload: {
          articleId,
          versionId: versionId || 'mock-suno-1',
          positionMs: 1200,
          durationMs: 32000,
          cue: {
            lineIndex: 0,
            startMs: 0,
            endMs: 3200,
            english: mockListening.items[0]?.english ?? '',
            chinese: mockListening.items[0]?.chinese ?? '',
            confidence: 0.92,
            method: 'matched',
          },
        },
      });
    }, 20);
    return { playbackState: 'playing' };
  }
  if (type === 'listening.songTimelineGenerate') {
    const articleId = Number(payload.articleId ?? mockListening.article.id);
    const versionId = String(payload.versionId ?? 'mock-suno-1');
    const result = {
      articleId,
      status: 'ready',
      stylePrompt: '',
      audioPath: 'mock-song.mp3',
      errorMessage: '',
      source: 'suno',
      versions: [
        {
          id: versionId,
          audioPath: 'mock-song.mp3',
          title: 'Suno 版本 1',
          durationMs: 32000,
          timelineStatus: 'ready',
          timelinePath: 'mock-song-timeline.json',
          timelineConfidence: 0.92,
        },
      ],
    };
    window.setTimeout(() => {
      emitNativeEvent({ type: 'listening.song.state', payload: result });
    }, 40);
    return result;
  }
  if (type === 'listening.songRecordVideo') {
    const articleId = Number(payload.articleId ?? mockListening.article.id);
    const subtitleMode = String(payload.subtitleMode ?? mockRecordingSettings.subtitleMode);
    const result = {
      articleId,
      videoPath: 'C:\\Tomato\\recording-export\\mock-song.mp4',
      subtitlePath: subtitleMode === 'burnedIn' ? '' : 'C:\\Tomato\\recording-export\\mock-song.srt',
      durationMs: 32000,
      frameCount: 800,
      droppedFrameCount: 0,
      encoderName: 'libx264',
      codec: String(payload.codec ?? 'h264'),
      resolution: String(payload.resolution ?? '1920x1080'),
      pageTransition: String(payload.pageTransition ?? 'none'),
      warnings: [],
    };
    window.setTimeout(() => {
      emitNativeEvent({ type: 'listening.recording.completed', payload: result });
    }, 80);
    return result;
  }
  if (type === 'listening.songStop') {
    return { stopped: true };
  }
  if (type === 'listening.prepare') {
    return { prepared: true };
  }
  if (type === 'listening.playSequence') {
    return { playbackState: 'success' };
  }
  if (type === 'listening.fullscreenReady') {
    const items = Array.isArray(payload.items) ? payload.items : mockListening.items;
    const startIndex = Number(payload.startIndex ?? 0);
    const lookaheadCount = Math.max(1, Math.min(4, Number(payload.lookaheadCount ?? 2)));
    const startPosition = Math.max(0, Math.min(items.length - 1, Number.isFinite(startIndex) ? startIndex : 0));
    const requiredEnglish = items.slice(startPosition, startPosition + lookaheadCount).length;
    return {
      ready: true,
      reasons: [],
      requiredEnglish,
      readyEnglish: requiredEnglish,
      requiredChinese: 0,
      readyChinese: 0,
      missingEnglish: [],
      missingChinese: [],
      failed: 0,
    };
  }
  if (type === 'listening.recordingReady') {
    return {
      ready: true,
      reasons: [],
      encoderName: 'libx264',
      codec: String(payload.codec ?? mockRecordingSettings.codec),
      resolution: String(payload.resolution ?? mockRecordingSettings.resolution),
      pageTransition: String(payload.pageTransition ?? mockRecordingSettings.pageTransition),
      subtitleMode: String(payload.subtitleMode ?? mockRecordingSettings.subtitleMode),
      outputDirectory: mockRecordingSettings.outputDirectory,
      requiredEnglish: mockListening.items.length,
      readyEnglish: mockListening.items.length,
      requiredChinese: String(payload.mode ?? 'english') === 'bilingual' ? mockListening.items.length : 0,
      readyChinese: String(payload.mode ?? 'english') === 'bilingual' ? mockListening.items.length : 0,
      picturePageCount: 1,
    };
  }
  if (type === 'listening.recordVideo') {
    const articleId = Number(payload.articleId ?? mockListening.article.id);
    const videoPath = `${mockRecordingSettings.outputDirectory}\\Space Snacks ${mockRecordingVideos.length + 1}.mp4`;
    const subtitleMode = String(payload.subtitleMode ?? mockRecordingSettings.subtitleMode);
    const subtitlePath = subtitleMode === 'burnedIn' ? '' : videoPath.replace(/\.mp4$/i, '.srt');
    window.setTimeout(() => {
      emitNativeEvent({
        type: 'listening.recording.progress',
        payload: {
          articleId,
          phase: 'rendering',
          progress: 0.4,
          completedFrames: 40,
          totalFrames: 100,
          message: '正在渲染视频帧',
        },
      });
    }, 20);
    const result = {
      articleId,
      videoPath,
      subtitlePath,
      durationMs: 4200,
      frameCount: 105,
      droppedFrameCount: 0,
      encoderName: 'libx264',
      codec: String(payload.codec ?? mockRecordingSettings.codec),
      resolution: String(payload.resolution ?? mockRecordingSettings.resolution),
      pageTransition: String(payload.pageTransition ?? mockRecordingSettings.pageTransition),
      warnings: [],
    };
    const hasDefault = mockRecordingVideos.some((version) => version.articleId === articleId && version.isDefault);
    mockRecordingVideos = [
      {
        id: `mock-video-${Date.now()}-${mockRecordingVideos.length + 1}`,
        articleId,
        videoPath,
        subtitlePath,
        createdAt: new Date().toISOString(),
        source: 'listening',
        title: `Space Snacks ${mockRecordingVideos.length + 1}`,
        isDefault: !hasDefault,
        durationMs: result.durationMs,
        frameCount: result.frameCount,
        droppedFrameCount: result.droppedFrameCount,
        encoderName: result.encoderName,
        codec: result.codec,
        resolution: result.resolution,
        pageTransition: result.pageTransition,
      },
      ...mockRecordingVideos,
    ];
    window.setTimeout(() => {
      emitNativeEvent({ type: 'listening.recording.completed', payload: result });
    }, 40);
    return result;
  }
  if (type === 'recording.videoList') {
    const articleId = Number(payload.articleId ?? mockListening.article.id);
    return {
      articleId,
      outputDirectory: mockRecordingSettings.outputDirectory,
      versions: mockRecordingVideos.filter((version) => version.articleId === articleId),
    };
  }
  if (type === 'recording.videoSetDefault') {
    const articleId = Number(payload.articleId ?? mockListening.article.id);
    const videoId = String(payload.videoId ?? '');
    let found = false;
    mockRecordingVideos = mockRecordingVideos.map((version) => {
      if (version.articleId !== articleId) return version;
      const selected = version.id === videoId;
      found = found || selected;
      return { ...version, isDefault: selected };
    });
    if (!found) {
      throw new Error('没有找到视频版本');
    }
    return {
      articleId,
      outputDirectory: mockRecordingSettings.outputDirectory,
      versions: mockRecordingVideos.filter((version) => version.articleId === articleId),
    };
  }
  if (type === 'recording.videoPlay') {
    const articleId = Number(payload.articleId ?? mockListening.article.id);
    const videoId = String(payload.videoId ?? '');
    const versions = mockRecordingVideos.filter((version) => version.articleId === articleId);
    const selected = videoId
      ? versions.find((version) => version.id === videoId)
      : versions.find((version) => version.isDefault) ?? versions[0];
    if (!selected) {
      throw new Error('还没有可播放的视频版本');
    }
    return {
      played: true,
      articleId,
      videoId: selected.id,
      videoPath: selected.videoPath,
    };
  }
  if (type === 'listening.cancelRecording') {
    return { cancelled: true };
  }
  if (type === 'listening.updateSentence') {
    const index = Number(payload.index ?? 0);
    const item = {
      index,
      english: String(payload.english ?? mockListening.items[0].english),
      chinese: String(payload.chinese ?? mockListening.items[0].chinese),
    };
    const items = mockListening.items.map((current) =>
      current.index === index ? item : current,
    );
    const article: Article = {
      ...mockListening.article,
      sentences: items.map((current) => current.english),
      content: items.map((current) => current.english).join(' '),
      sentenceCount: items.length,
    };
    return {
      article,
      item,
      items,
      synthesis: { status: 'ready', english: 'ready', chinese: item.chinese ? 'ready' : 'unchanged', error: '' },
      articles: mockArticles.map((current) => (current.id === article.id ? article : current)),
      series: mockSeries,
    };
  }
  if (type === 'listening.resynthesizeSentence') {
    const index = Number(payload.index ?? 0);
    const item = mockListening.items.find((current) => current.index === index) ?? mockListening.items[0];
    return {
      item,
      synthesis: { status: 'ready', english: 'ready', chinese: item.chinese ? 'ready' : 'unchanged', error: '' },
    };
  }
  if (type === 'listening.play') {
    return { playbackState: 'success' };
  }
  if (type === 'listening.stop') {
    return { stopped: true };
  }
  if (type === 'listening.pause') {
    return { paused: true };
  }
  if (type === 'listening.resume') {
    return { resumed: true };
  }
  if (type === 'word.lookup') {
    return mockWordLookup(String(payload.word ?? ''), String(payload.sentence ?? ''));
  }
  if (type === 'word.play') {
    return { playbackState: 'success' };
  }
  if (type === 'word.stop') {
    return { stopped: true };
  }
  if (type === 'follow.play' || type === 'follow.replay' || type === 'follow.recordReplay') {
    return {
      ...mockFollow,
      step: 'idle',
      playbackState: 'success',
      result: type === 'follow.recordReplay' ? mockResult : null,
      hasRecording: type === 'follow.recordReplay',
    };
  }
  if (type === 'follow.next') {
    return {
      ...mockFollow,
      currentIndex: 1,
      currentSentence: mockArticles[0].sentences[1],
      currentTranslation: '他把它分享给自己的队友。',
      isLastSentence: true,
      step: 'idle',
      playbackState: 'idle',
      result: null,
    };
  }
  if (type === 'follow.pause') {
    return { paused: true };
  }
  if (type === 'follow.resume') {
    return { resumed: true };
  }
  if (type === 'follow.retry') {
    return {
      ...mockFollow,
      step: 'idle',
      playbackState: 'idle',
      result: null,
    };
  }
  if (type.startsWith('follow.')) {
    if (type === 'follow.recordStart') {
      return {
        ...mockFollow,
        step: 'recording',
        playbackState: 'idle',
        result: null,
        hasRecording: false,
        liveRecognizedText: 'Tom finds...',
      };
    }
    if (type === 'follow.recordStop') {
      return {
        ...mockFollow,
        step: 'result',
        playbackState: 'success',
        result: mockResult,
        hasRecording: true,
        liveRecognizedText: mockResult.recognizedText,
      };
    }
    return {
      ...mockFollow,
      step: 'idle',
      result: null,
      hasRecording: false,
    };
  }
  if (type === 'chat.open') {
    return mockChat;
  }
  if (type.startsWith('chat.')) {
    return mockChat;
  }
  if (type === 'settings.load') {
    return mockSettings;
  }
  if (type === 'settings.saveSong') {
    const songProvider = String(payload.songProvider ?? mockSettings.song?.songProvider ?? 'suno') === 'bailian_fun_music'
      ? 'bailian_fun_music'
      : 'suno';
    mockSettings = {
      ...mockSettings,
      song: {
        sunoOutputDirectory: String(payload.sunoOutputDirectory ?? mockSettings.song?.sunoOutputDirectory ?? ''),
        sunoTimeoutMinutes: Number(payload.sunoTimeoutMinutes ?? mockSettings.song?.sunoTimeoutMinutes ?? 20),
        songProvider: songProvider as SongSource,
      },
    };
    return mockSettings;
  }
  if (type === 'settings.saveCloud') {
    mockSettings = {
      ...mockSettings,
      cloud: {
        aiProvider: String(payload.aiProvider ?? mockSettings.cloud?.aiProvider ?? 'aliyun_bailian'),
        aliyunBailian: {
          apiKeyConfigured:
            Boolean(payload.aliyunBailianApiKey) ||
            (mockSettings.cloud?.aliyunBailian.apiKeyConfigured ?? false),
          apiKeyMask: payload.aliyunBailianApiKey ? '****MOCK' : mockSettings.cloud?.aliyunBailian.apiKeyMask ?? '',
          baseUrl: String(payload.aliyunBailianBaseUrl ?? mockSettings.cloud?.aliyunBailian.baseUrl ?? 'https://dashscope.aliyuncs.com/compatible-mode/v1'),
          apiBaseUrl: String(payload.aliyunBailianApiBaseUrl ?? mockSettings.cloud?.aliyunBailian.apiBaseUrl ?? 'https://dashscope.aliyuncs.com/api/v1'),
          textModel: String(payload.aliyunBailianTextModel ?? mockSettings.cloud?.aliyunBailian.textModel ?? 'qwen3.7-max'),
          musicModel: String(payload.aliyunBailianMusicModel ?? mockSettings.cloud?.aliyunBailian.musicModel ?? 'fun-music-v1'),
          imageModel: String(payload.aliyunBailianImageModel ?? mockSettings.cloud?.aliyunBailian.imageModel ?? 'wan2.7-image-pro'),
          imageSize: String(payload.aliyunBailianImageSize ?? mockSettings.cloud?.aliyunBailian.imageSize ?? '2K'),
          ttsModel: String(payload.aliyunBailianTtsModel ?? mockSettings.cloud?.aliyunBailian.ttsModel ?? 'cosyvoice-v3-flash'),
          ttsVoice: String(payload.aliyunBailianTtsVoice ?? mockSettings.cloud?.aliyunBailian.ttsVoice ?? 'loongabby_v3'),
          ttsSampleRate: Number(payload.aliyunBailianTtsSampleRate ?? mockSettings.cloud?.aliyunBailian.ttsSampleRate ?? 24000),
          asrModel: String(payload.aliyunBailianAsrModel ?? mockSettings.cloud?.aliyunBailian.asrModel ?? 'qwen3-asr-flash'),
          realtimeAsrModel: String(payload.aliyunBailianRealtimeAsrModel ?? mockSettings.cloud?.aliyunBailian.realtimeAsrModel ?? 'qwen3-asr-realtime'),
          realtimeAsrUrl: String(payload.aliyunBailianRealtimeAsrUrl ?? mockSettings.cloud?.aliyunBailian.realtimeAsrUrl ?? 'wss://dashscope.aliyuncs.com/api-ws/v1/realtime'),
        },
        volcengine: {
          arkApiKeyConfigured:
            Boolean(payload.volcArkApiKey) ||
            (mockSettings.cloud?.volcengine.arkApiKeyConfigured ?? false),
          arkApiKeyMask: payload.volcArkApiKey ? '****MOCK' : mockSettings.cloud?.volcengine.arkApiKeyMask ?? '',
          arkBaseUrl: String(payload.volcArkBaseUrl ?? mockSettings.cloud?.volcengine.arkBaseUrl ?? 'https://ark.cn-beijing.volces.com/api/v3'),
          arkTextModel: String(payload.volcArkTextModel ?? mockSettings.cloud?.volcengine.arkTextModel ?? 'doubao-seed-2-0-lite-260215'),
          arkImageModel: String(payload.volcArkImageModel ?? mockSettings.cloud?.volcengine.arkImageModel ?? 'doubao-seedream-5-0-260128'),
          speechApiKeyConfigured:
            Boolean(payload.volcSpeechApiKey) ||
            (mockSettings.cloud?.volcengine.speechApiKeyConfigured ?? false),
          speechApiKeyMask: payload.volcSpeechApiKey ? '****MOCK' : mockSettings.cloud?.volcengine.speechApiKeyMask ?? '',
          ttsResourceId: String(payload.volcTtsResourceId ?? mockSettings.cloud?.volcengine.ttsResourceId ?? 'seed-tts-2.0'),
          ttsSpeakerId: String(payload.volcTtsSpeakerId ?? mockSettings.cloud?.volcengine.ttsSpeakerId ?? mockSettings.tts.speakerId),
        },
      },
      tts: {
        resourceId: String(payload.aiProvider ?? mockSettings.cloud?.aiProvider) === 'aliyun_bailian'
          ? String(payload.aliyunBailianTtsModel ?? mockSettings.cloud?.aliyunBailian.ttsModel ?? 'cosyvoice-v3-flash')
          : String(payload.volcTtsResourceId ?? mockSettings.cloud?.volcengine.ttsResourceId ?? 'seed-tts-2.0'),
        speakerId: String(payload.aiProvider ?? mockSettings.cloud?.aiProvider) === 'aliyun_bailian'
          ? String(payload.aliyunBailianTtsVoice ?? mockSettings.cloud?.aliyunBailian.ttsVoice ?? 'loongabby_v3')
          : String(payload.volcTtsSpeakerId ?? mockSettings.cloud?.volcengine.ttsSpeakerId ?? mockSettings.tts.speakerId),
      },
    };
    return mockSettings;
  }
  if (type === 'recording.settings.load') {
    return mockRecordingSettings;
  }
  if (type === 'recording.settings.save') {
    mockRecordingSettings = {
      ...mockRecordingSettings,
      codec: String(payload.codec ?? mockRecordingSettings.codec) as RecordingSettings['codec'],
      resolution: String(payload.resolution ?? mockRecordingSettings.resolution) as RecordingSettings['resolution'],
      pageTransition: String(payload.pageTransition ?? mockRecordingSettings.pageTransition) as RecordingSettings['pageTransition'],
      subtitleMode: String(payload.subtitleMode ?? mockRecordingSettings.subtitleMode) as RecordingSettings['subtitleMode'],
    };
    return mockRecordingSettings;
  }
  if (type === 'settings.saveVoice') {
    const speakerId = String(payload.speakerId ?? mockSettings.tts.speakerId);
    const provider = normalizeAiProvider(
      String(payload.aiProvider ?? mockSettings.cloud?.aiProvider ?? 'aliyun_bailian'),
    );
    const voices = provider === 'aliyun_bailian'
      ? (mockSettings.voiceCatalog?.aliyunBailian ?? mockAliyunVoiceOptions)
      : (mockSettings.voiceCatalog?.volcengine ?? mockSettings.voices);
    const isKnownVoice = voices.some((voice) => voice.id === speakerId);
    mockSettings = {
      ...mockSettings,
      tts: {
        ...mockSettings.tts,
        speakerId: isKnownVoice ? speakerId : mockSettings.tts.speakerId,
      },
      cloud: {
        ...mockSettings.cloud!,
        aliyunBailian: {
          ...mockSettings.cloud!.aliyunBailian,
          ttsVoice: provider === 'aliyun_bailian' && isKnownVoice
            ? speakerId
            : mockSettings.cloud!.aliyunBailian.ttsVoice,
        },
        volcengine: {
          ...mockSettings.cloud!.volcengine,
          ttsSpeakerId: provider === 'volcengine' && isKnownVoice
            ? speakerId
            : mockSettings.cloud!.volcengine.ttsSpeakerId,
        },
      },
    };
    return mockSettings;
  }
  if (type === 'settings.previewVoice') {
    return { playbackState: 'success' };
  }
  if (type === 'contentSafety.setRuleEnabled') {
    const id = Number(payload.id ?? 0);
    const enabled = Boolean(payload.enabled);
    mockSettings = {
      ...mockSettings,
      contentSafety: {
        rules: (mockSettings.contentSafety?.rules ?? []).map((rule) =>
          rule.id === id ? { ...rule, enabled } : rule,
        ),
      },
    };
    return mockSettings;
  }
  if (type === 'contentSafety.deleteRule') {
    const id = Number(payload.id ?? 0);
    mockSettings = {
      ...mockSettings,
      contentSafety: {
        rules: (mockSettings.contentSafety?.rules ?? []).filter((rule) => rule.id !== id),
      },
    };
    return mockSettings;
  }
  return {};
}

function mockSuggestTitle(content: string): string {
  if (/[\u3400-\u9FFF]/.test(content)) {
    if (content.includes('母') || content.includes('妈')) return "A Mother's Choice";
    return 'English Practice';
  }
  const lowerContent = content.toLowerCase();
  if (lowerContent.includes('mother') && lowerContent.includes('choice')) {
    return "A Mother's Choice";
  }
  const words = content
    .toLowerCase()
    .replace(/[^a-z\s]/g, ' ')
    .split(/\s+/)
    .filter((word) => word.length > 3 && !mockTitleStopWords.has(word));
  const uniqueWords = Array.from(new Set(words)).slice(0, 3);
  if (uniqueWords.length === 0) return 'English Practice';
  return uniqueWords.map((word) => word[0].toUpperCase() + word.slice(1)).join(' ');
}

function mockTranslateToEnglish(content: string): string {
  if (/[\u3400-\u9FFF]/.test(content) && /[A-Za-z]/.test(content)) {
    return mockExtractEnglishStory(content);
  }
  if (content.includes('母') || content.includes('妈') || content.includes('选择')) {
    return 'A mother makes a choice for her child. She thinks about love, family, and the future.';
  }
  if (/[\u3400-\u9FFF]/.test(content)) {
    return 'This is a short English practice story. The people make a choice and learn something important.';
  }
  return content;
}

function normalizePracticeContent(content: string): string {
  const normalized = content.replace(/([A-Za-z])\s*-\s*([A-Za-z])/g, '$1-$2').trim();
  if (/[\u3400-\u9FFF]/.test(normalized) && /[A-Za-z]/.test(normalized)) {
    return mockExtractEnglishStory(normalized);
  }
  if (/[\u3400-\u9FFF]/.test(normalized)) {
    return mockTranslateToEnglish(normalized).replace(/([A-Za-z])\s*-\s*([A-Za-z])/g, '$1-$2').trim();
  }
  return normalized;
}

function mockExtractEnglishStory(content: string): string {
  const lines = content
    .replace(/[“”]/g, '"')
    .replace(/[‘’]/g, "'")
    .split(/\r?\n|(?<=[。！？；;])\s*/);
  const kept = lines
    .map((line) => line.trim())
    .filter((line) => {
      const englishWords = line.match(/[A-Za-z][A-Za-z'-]*/g) ?? [];
      const chineseChars = line.match(/[\u3400-\u9FFF]/g) ?? [];
      if (englishWords.length < 3) return false;
      if (/^(title|标题|中文|翻译|词汇|vocabulary|notes?|注释|讲解)\s*[:：]/i.test(line)) return false;
      return chineseChars.length <= englishWords.length;
    })
    .map((line) => line.replace(/[\u3400-\u9FFF]+/g, ' ').replace(/\s+/g, ' ').trim())
    .filter(Boolean);
  return kept.join(' ').trim() || content.replace(/[\u3400-\u9FFF]+/g, ' ').replace(/\s+/g, ' ').trim();
}

function mockWordLookup(word: string, sentence: string): Record<string, string> {
  const normalized = word.trim() || 'word';
  const lower = normalized.toLowerCase();
  const dictionary: Record<string, { phonetic: string; meaning: string; sentenceMeaning: string }> = {
    bright: {
      phonetic: '/brait/',
      meaning: '明亮的；聪明的；鲜艳的',
      sentenceMeaning: '在本句中表示“明亮的”。',
    },
    snack: {
      phonetic: '/snak/',
      meaning: '零食；小吃',
      sentenceMeaning: '在本句中表示“零食”。',
    },
    finds: {
      phonetic: '/faindz/',
      meaning: '找到；发现',
      sentenceMeaning: '在本句中表示“发现”。',
    },
    shares: {
      phonetic: '/sherz/',
      meaning: '分享；分给',
      sentenceMeaning: '在本句中表示“分享”。',
    },
  };
  const fallback = dictionary[lower] ?? {
    phonetic: '/.../',
    meaning: '这个单词的中文含义暂不可用。',
    sentenceMeaning: sentence.trim()
      ? '请结合本句理解这个单词。'
      : '请结合原句理解这个单词。',
  };

  return {
    word: normalized,
    phonetic: fallback.phonetic,
    meaning: fallback.meaning,
    sentenceMeaning: fallback.sentenceMeaning,
    source: 'mock',
  };
}

const mockTitleStopWords = new Set([
  'about',
  'after',
  'again',
  'bright',
  'little',
  'looks',
  'slowly',
  'that',
  'their',
  'there',
  'this',
  'with',
]);

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    window.setTimeout(resolve, ms);
  });
}

const mockArticles: Article[] = [
  {
    id: 1,
    title: 'Space Snacks',
    content: 'Tom finds a bright snack box. He shares it with his team.',
    sentences: [
      'Tom finds a bright snack box.',
      'He shares it with his team.',
    ],
    sentenceCount: 2,
    createdAt: new Date().toISOString(),
    averageScore: 86,
    coverImageUri: assetUrl('card-space-snacks.png'),
    coverImagePath: null,
    pictureBookEnabled: true,
    seriesId: 1,
    seriesTitle: 'Space Story Series',
    seriesDescription: 'A gentle space-adventure picture book about curious children exploring small wonders together.',
    chapterDescription: 'Tom finds a bright snack box and turns the discovery into a warm sharing moment.',
    chapterOrder: 1,
  },
];

const mockSeries: StorySeries[] = [
  {
    id: 1,
    title: 'Space Story Series',
    description: 'A gentle space-adventure picture book about curious children exploring small wonders together.',
    characters: [
      {
        name: 'Tom',
        description: 'Curious child explorer wearing a red hoodie and small silver backpack.',
      },
    ],
    coverImagePath: null,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  },
];

function mockPictureBook(
  articleId: number,
  status: PictureBookState['status'] = 'ready',
): PictureBookState {
  return {
    articleId,
    enabled: true,
    status,
    series: mockSeries[0],
    chapter: {
      articleId,
      seriesId: mockSeries[0].id,
      chapterOrder: 1,
      chapterTitle: 'Space Snacks',
    },
    pages: [
      {
        articleId,
        seriesId: mockSeries[0].id,
        pageIndex: 0,
        sentenceStartIndex: 0,
        sentenceEndIndex: 1,
        paragraphText: mockArticles[0].content,
        imageUri: assetUrl('card-space-snacks.png'),
        imagePath: assetUrl('card-space-snacks.png'),
        status: status === 'generating' ? 'generating' : 'ready',
        errorMessage: null,
      },
    ],
  };
}

function mockPictureBookPromptReview(
  articleId: number,
  regenerate = false,
): PictureBookPromptReview {
  const scenes = [
    {
      pageIndex: 0,
      sentenceStartIndex: 0,
      sentenceEndIndex: 0,
      paragraphText: 'Tom finds a bright snack box.',
      sceneDescription: 'Tom discovers a bright snack box.',
    },
    {
      pageIndex: 1,
      sentenceStartIndex: 1,
      sentenceEndIndex: 1,
      paragraphText: 'He shares it with his team.',
      sceneDescription: 'Tom shares the box with his team.',
    },
  ];
  return {
    reviewId: `mock-review-${articleId}`,
    articleId,
    chapterId: 1,
    seriesId: mockSeries[0].id,
    bookTitle: mockSeries[0].title,
    regenerate,
    bookDescription: mockSeries[0].description ?? '',
    bookCharacters: mockSeries[0].characters ?? [],
    relevantCharacters: mockSeries[0].characters ?? [],
    newCharacters: [],
    chapterDescription:
      'A gentle space-adventure chapter where Tom finds a bright snack box and turns the discovery into a warm sharing moment with his team.',
    groupPrompt: mockGroupPrompt(scenes, mockSeries[0].characters ?? []),
    scenes,
    createdAt: new Date().toISOString(),
  };
}

function mockGroupPrompt(
  scenes: Array<{ sceneDescription: string }>,
  characters: BookCharacter[] = [],
): string {
  const characterLines = normalizeMockBookCharacters(characters);
  return [
    'Book name: Space Story Series',
    'Book description: A gentle space-adventure picture book about curious children exploring small wonders together.',
    ...(characterLines.length > 0
      ? [
          '',
          'Relevant characters:',
          ...characterLines.map((character) => `- ${character.name}: ${character.description}`),
        ]
      : []),
    '',
    'Chapter description: A gentle space-adventure chapter where Tom finds a bright snack box and turns the discovery into a warm sharing moment with his team.',
    ...scenes.flatMap((scene, index) => [
      '',
      `Image ${index + 1}:`,
      `Scene description: ${scene.sceneDescription}`,
    ]),
  ].join('\n').trim();
}

function mockSinglePagePrompt(
  scene: { pageIndex: number; sceneDescription: string } | undefined,
  characters: BookCharacter[] = [],
): string {
  const imageNumber = Math.max(1, Number(scene?.pageIndex ?? 0) + 1);
  const characterLines = normalizeMockBookCharacters(characters);
  return [
    'Book name: Space Story Series',
    'Book description: A gentle space-adventure picture book about curious children exploring small wonders together.',
    ...(characterLines.length > 0
      ? [
          '',
          'Relevant characters:',
          ...characterLines.map((character) => `- ${character.name}: ${character.description}`),
        ]
      : []),
    '',
    'Chapter description: A gentle space-adventure chapter where Tom finds a bright snack box and turns the discovery into a warm sharing moment with his team.',
    '',
    `Generate exactly one picture for Image ${imageNumber}. Use the reference image only for visual consistency.`,
    'Do not generate other scenes, a collage, comic panels, or a multi-image sheet.',
    '',
    `Image ${imageNumber}:`,
    `Scene description: ${scene?.sceneDescription ?? ''}`,
  ].join('\n').trim();
}

function normalizeMockBookCharacters(raw: unknown): BookCharacter[] {
  if (!Array.isArray(raw)) return [];
  return raw
    .map((item) => {
      const record = item as Partial<BookCharacter>;
      return {
        name: String(record.name ?? '').replace(/\s+/g, ' ').trim(),
        description: String(record.description ?? '').replace(/\s+/g, ' ').trim(),
      };
    })
    .filter((item) => item.name && item.description);
}

function assetUrl(name: string): string {
  return `assets/ui/${name}`;
}

const mockResult = {
  overallScore: 88,
  accuracyScore: 91,
  fluencyScore: 84,
  completenessScore: 90,
  prosodyScore: 83,
  recognizedText: 'Tom finds a bright snack box.',
  isMock: true,
  words: [
    { word: 'Tom', score: 90, errorType: 'None' },
    { word: 'finds', score: 82, errorType: 'None' },
    { word: 'bright', score: 72, errorType: 'None' },
  ],
};

const mockFollow: FollowState = {
  status: 'ready',
  article: mockArticles[0],
  currentIndex: 0,
  totalSentences: 2,
  currentSentence: mockArticles[0].sentences[0],
  currentTranslation: '汤姆发现了一个明亮的零食盒。',
  isLastSentence: false,
  step: 'idle',
  playbackState: 'idle',
  hasRecording: false,
  liveRecognizedText: '',
  result: null,
  avatar: {
    mode: 'idle',
    emotion: 'encouraging',
    mouth: 'closed',
    volume: 0,
  },
};

const mockListening: ListeningOpenPayload = {
  article: mockArticles[0],
  items: [
    {
      index: 0,
      english: mockArticles[0].sentences[0],
      chinese: '汤姆发现了一个明亮的零食盒。',
    },
    {
      index: 1,
      english: mockArticles[0].sentences[1],
      chinese: '他把它分享给自己的队友。',
    },
  ],
};

const mockChat: ChatState = {
  articleTitle: 'Space Snacks',
  step: 'userIdle',
  questionCount: 1,
  maxQuestions: 8,
  messages: [
    {
      id: 'ai_1',
      isAi: true,
      text: 'What did Tom find?',
      translation: '汤姆发现了什么？',
      playbackState: 'success',
    },
  ],
  avatar: {
    mode: 'idle',
    emotion: 'encouraging',
    mouth: 'closed',
    volume: 0,
  },
};

const mockVoiceOptions: VoiceOption[] = `
zh_female_vv_uranus_bigtts|Vivi 2.0|中文、日文、印尼、墨西哥西班牙语|通用场景
zh_female_xiaohe_uranus_bigtts|小何 2.0|中文|通用场景
zh_male_m191_uranus_bigtts|云舟 2.0|中文|通用场景
zh_male_taocheng_uranus_bigtts|小天 2.0|中文|通用场景
zh_male_liufei_uranus_bigtts|刘飞 2.0|中文|通用场景
zh_female_sophie_uranus_bigtts|魅力苏菲 2.0|中文|通用场景
zh_female_qingxinnvsheng_uranus_bigtts|清新女声 2.0|中文|通用场景
zh_female_cancan_uranus_bigtts|知性灿灿 2.0|中文|角色扮演
zh_female_sajiaoxuemei_uranus_bigtts|撒娇学妹 2.0|中文|角色扮演
zh_female_tianmeixiaoyuan_uranus_bigtts|甜美小源 2.0|中文|通用场景
zh_female_tianmeitaozi_uranus_bigtts|甜美桃子 2.0|中文|通用场景
zh_female_shuangkuaisisi_uranus_bigtts|爽快思思 2.0|中文|通用场景
zh_female_peiqi_uranus_bigtts|佩奇猪 2.0|中文|视频配音
zh_female_linjianvhai_uranus_bigtts|邻家女孩 2.0|中文|通用场景
zh_male_shaonianzixin_uranus_bigtts|少年梓辛/Brayan 2.0|中文|通用场景
zh_male_sunwukong_uranus_bigtts|猴哥 2.0|中文|视频配音
zh_female_yingyujiaoxue_uranus_bigtts|Tina老师 2.0|中文、英式英语|教育场景
zh_female_kefunvsheng_uranus_bigtts|暖阳女声 2.0|中文|客服场景
zh_female_xiaoxue_uranus_bigtts|儿童绘本 2.0|中文|有声阅读
zh_male_dayi_uranus_bigtts|大壹 2.0|中文|视频配音
zh_female_mizai_uranus_bigtts|黑猫侦探社咪仔 2.0|中文|视频配音
zh_female_jitangnv_uranus_bigtts|鸡汤女 2.0|中文|视频配音
zh_female_meilinvyou_uranus_bigtts|魅力女友 2.0|中文|通用场景
zh_female_liuchangnv_uranus_bigtts|流畅女声 2.0|中文|视频配音
zh_male_ruyayichen_uranus_bigtts|儒雅逸辰 2.0|中文|视频配音
en_male_tim_uranus_bigtts|Tim|美式英语|多语种
en_female_dacey_uranus_bigtts|Dacey|美式英语|多语种
en_female_stokie_uranus_bigtts|Stokie|美式英语|多语种
zh_female_wenroumama_uranus_bigtts|温柔妈妈 2.0|中文|通用场景
zh_male_jieshuoxiaoming_uranus_bigtts|解说小明 2.0|中文|通用场景
zh_female_tvbnv_uranus_bigtts|TVB女声 2.0|中文|通用场景
zh_male_yizhipiannan_uranus_bigtts|译制片男 2.0|中文|通用场景
zh_female_qiaopinv_uranus_bigtts|俏皮女声 2.0|中文|通用场景
zh_female_zhishuaiyingzi_uranus_bigtts|直率英子 2.0|中文|角色扮演
zh_male_linjiananhai_uranus_bigtts|邻家男孩 2.0|中文|通用场景
zh_male_silang_uranus_bigtts|四郎 2.0|中文|角色扮演
zh_male_ruyaqingnian_uranus_bigtts|儒雅青年 2.0|中文|通用场景
zh_male_qingcang_uranus_bigtts|擎苍 2.0|中文|角色扮演
zh_male_xionger_uranus_bigtts|熊二 2.0|中文|角色扮演
zh_female_yingtaowanzi_uranus_bigtts|樱桃丸子 2.0|中文|角色扮演
zh_male_wennuanahu_uranus_bigtts|温暖阿虎/Alvin 2.0|中文|通用场景
zh_male_naiqimengwa_uranus_bigtts|奶气萌娃 2.0|中文|通用场景
zh_female_popo_uranus_bigtts|婆婆 2.0|中文|通用场景
zh_female_gaolengyujie_uranus_bigtts|高冷御姐 2.0|中文|通用场景
zh_male_aojiaobazong_uranus_bigtts|傲娇霸总 2.0|中文|通用场景
zh_male_lanyinmianbao_uranus_bigtts|懒音绵宝 2.0|中文|角色扮演
zh_male_fanjuanqingnian_uranus_bigtts|反卷青年 2.0|中文|通用场景
zh_female_wenroushunv_uranus_bigtts|温柔淑女 2.0|中文|通用场景
zh_female_gufengshaoyu_uranus_bigtts|古风少御 2.0|中文|角色扮演
zh_male_huolixiaoge_uranus_bigtts|活力小哥 2.0|中文|通用场景
zh_male_baqiqingshu_uranus_bigtts|霸气青叔 2.0|中文|有声阅读
zh_male_xuanyijieshuo_uranus_bigtts|悬疑解说 2.0|中文|有声阅读
zh_female_mengyatou_uranus_bigtts|萌丫头/Cutey 2.0|中文|通用场景
zh_female_tiexinnvsheng_uranus_bigtts|贴心女声/Candy 2.0|中文|通用场景
zh_female_jitangmei_uranus_bigtts|鸡汤妹妹/Hope 2.0|中文|通用场景
zh_male_cixingjieshuonan_uranus_bigtts|磁性解说男声/Morgan 2.0|中文|通用场景
zh_male_liangsangmengzai_uranus_bigtts|亮嗓萌仔 2.0|中文|通用场景
zh_female_kailangjiejie_uranus_bigtts|开朗姐姐 2.0|中文|通用场景
zh_male_gaolengchenwen_uranus_bigtts|高冷沉稳 2.0|中文|通用场景
zh_male_shenyeboke_uranus_bigtts|深夜播客 2.0|中文|通用场景
zh_male_lubanqihao_uranus_bigtts|鲁班七号 2.0|中文|角色扮演
zh_female_jiaochuannv_uranus_bigtts|娇喘女声 2.0|中文|通用场景
zh_female_linxiao_uranus_bigtts|林潇 2.0|中文|角色扮演
zh_female_lingling_uranus_bigtts|玲玲姐姐 2.0|中文|角色扮演
zh_female_chunribu_uranus_bigtts|春日部姐姐 2.0|中文|角色扮演
zh_male_tangseng_uranus_bigtts|唐僧 2.0|中文|角色扮演
zh_male_zhuangzhou_uranus_bigtts|庄周 2.0|中文|角色扮演
zh_male_kailangdidi_uranus_bigtts|开朗弟弟 2.0|中文|通用场景
zh_male_zhubajie_uranus_bigtts|猪八戒 2.0|中文|角色扮演
zh_female_ganmaodianyin_uranus_bigtts|感冒电音姐姐 2.0|中文|角色扮演
zh_female_chanmeinv_uranus_bigtts|谄媚女声 2.0|中文|通用场景
zh_female_nvleishen_uranus_bigtts|女雷神 2.0|中文|角色扮演
zh_female_qinqienv_uranus_bigtts|亲切女声 2.0|中文|通用场景
zh_male_kuailexiaodong_uranus_bigtts|快乐小东 2.0|中文|通用场景
zh_male_kailangxuezhang_uranus_bigtts|开朗学长 2.0|中文|通用场景
zh_male_youyoujunzi_uranus_bigtts|悠悠君子 2.0|中文|通用场景
zh_female_wenjingmaomao_uranus_bigtts|文静毛毛 2.0|中文|通用场景
zh_female_zhixingnv_uranus_bigtts|知性女声 2.0|中文|通用场景
zh_male_qingshuangnanda_uranus_bigtts|清爽男大 2.0|中文|通用场景
zh_male_yuanboxiaoshu_uranus_bigtts|渊博小叔 2.0|中文|通用场景
zh_male_yangguangqingnian_uranus_bigtts|阳光青年 2.0|中文|通用场景
zh_female_qingchezizi_uranus_bigtts|清澈梓梓 2.0|中文|通用场景
zh_female_tianmeiyueyue_uranus_bigtts|甜美悦悦 2.0|中文|通用场景
zh_female_xinlingjitang_uranus_bigtts|心灵鸡汤 2.0|中文|通用场景
zh_male_wenrouxiaoge_uranus_bigtts|温柔小哥 2.0|中文|通用场景
zh_female_roumeinvyou_uranus_bigtts|柔美女友 2.0|中文|通用场景
zh_male_dongfanghaoran_uranus_bigtts|东方浩然 2.0|中文|通用场景
zh_female_wenrouxiaoya_uranus_bigtts|温柔小雅 2.0|中文|通用场景
zh_male_tiancaitongsheng_uranus_bigtts|天才童声 2.0|中文|通用场景
zh_female_wuzetian_uranus_bigtts|武则天 2.0|中文|角色扮演
zh_female_gujie_uranus_bigtts|顾姐 2.0|中文|角色扮演
zh_male_guanggaojieshuo_uranus_bigtts|广告解说 2.0|中文|通用场景
zh_female_shaoergushi_uranus_bigtts|少儿故事 2.0|中文|有声阅读
saturn_zh_female_tiaopigongzhu_tob|调皮公主|中文|角色扮演
saturn_zh_female_keainvsheng_tob|可爱女生|中文|角色扮演
saturn_zh_male_shuanglangshaonian_tob|爽朗少年|中文|角色扮演
saturn_zh_male_tiancaitongzhuo_tob|天才同桌|中文|角色扮演
saturn_zh_female_cancan_tob|知性灿灿|中文|角色扮演
saturn_zh_female_qingyingduoduo_cs_tob|轻盈朵朵 2.0|中文|客服场景
saturn_zh_female_wenwanshanshan_cs_tob|温婉珊珊 2.0|中文|客服场景
saturn_zh_female_reqingaina_cs_tob|热情艾娜 2.0|中文|客服场景
saturn_zh_male_qingxinmumu_cs_tob|清新沐沐 2.0|中文|客服场景
`
  .trim()
  .split('\n')
  .map((line) => {
    const [id, name, lang, scene] = line.split('|');
    return {
      id,
      name,
      lang,
      scene,
      gender: inferVoiceGender(id),
    };
  });

function inferVoiceGender(id: string): string {
  if (id.includes('_female_') || id.includes('female')) return 'female';
  if (id.includes('_male_') || id.includes('male')) return 'male';
  if (/abby|annie|anhuan/i.test(id)) return 'female';
  if (/andy|anyang/i.test(id)) return 'male';
  return 'unknown';
}

function normalizeAiProvider(provider?: string | null): AiProvider {
  return provider === 'volcengine' ? 'volcengine' : 'aliyun_bailian';
}

const mockAliyunVoiceOptions: VoiceOption[] = [
  { id: 'loongabby_v3', name: 'Abby', lang: '中文、英文', gender: 'female', scene: '通用朗读' },
  { id: 'loongandy_v3', name: 'Andy', lang: '中文、英文', gender: 'male', scene: '通用朗读' },
  { id: 'loongannie_v3', name: 'Annie', lang: '中文、英文', gender: 'female', scene: '儿童/故事' },
  { id: 'longanyang', name: 'An Yang', lang: '中文、英文', gender: 'male', scene: '通用朗读' },
  { id: 'longanhuan', name: 'An Huan', lang: '中文、英文', gender: 'female', scene: '通用朗读' },
];

let mockSettings: SettingsState = {
  tts: {
    resourceId: 'seed-tts-2.0',
    speakerId: 'en_female_dacey_uranus_bigtts',
  },
  song: {
    sunoOutputDirectory: 'mock-suno-output',
    sunoTimeoutMinutes: 20,
    songProvider: 'suno',
  },
  cloud: {
    aiProvider: 'aliyun_bailian',
    aliyunBailian: {
      apiKeyConfigured: false,
      apiKeyMask: '',
      baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      apiBaseUrl: 'https://dashscope.aliyuncs.com/api/v1',
      textModel: 'qwen3.7-max',
      musicModel: 'fun-music-v1',
      imageModel: 'wan2.7-image-pro',
      imageSize: '2K',
      ttsModel: 'cosyvoice-v3-flash',
      ttsVoice: 'loongabby_v3',
      ttsSampleRate: 24000,
      asrModel: 'qwen3-asr-flash',
      realtimeAsrModel: 'qwen3-asr-realtime',
      realtimeAsrUrl: 'wss://dashscope.aliyuncs.com/api-ws/v1/realtime',
    },
    volcengine: {
      arkApiKeyConfigured: false,
      arkApiKeyMask: '',
      arkBaseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
      arkTextModel: 'doubao-seed-2-0-lite-260215',
      arkImageModel: 'doubao-seedream-5-0-260128',
      speechApiKeyConfigured: false,
      speechApiKeyMask: '',
      ttsResourceId: 'seed-tts-2.0',
      ttsSpeakerId: 'en_female_dacey_uranus_bigtts',
    },
  },
  voices: mockVoiceOptions,
  voiceCatalog: {
    aliyunBailian: mockAliyunVoiceOptions,
    volcengine: mockVoiceOptions,
  },
  contentSafety: {
    rules: [
      {
        id: 1,
        sourceTerm: 'heads',
        replacement: 'he-ads',
        serviceKind: '*',
        purposeScope: '*',
        matchType: 'word',
        confidence: 0.55,
        enabled: true,
        sourceFailureId: null,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      },
      {
        id: 2,
        sourceTerm: 'beheaded',
        replacement: 'be-headed',
        serviceKind: '*',
        purposeScope: '*',
        matchType: 'word',
        confidence: 0.55,
        enabled: true,
        sourceFailureId: null,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      },
    ],
  },
};

let mockRecordingSettings: RecordingSettings = {
  codec: 'h264',
  resolution: '1920x1080',
  pageTransition: 'none',
  subtitleMode: 'srt',
  outputDirectory: 'C:\\Program Files\\TomatoEnglishHappyTalking\\recording-export',
  ffmpegPath: 'C:\\Program Files\\TomatoEnglishHappyTalking\\ffmpeg.exe',
  fps: 25,
  quality: 'high',
  hardwareBackend: 'auto',
};

let mockRecordingVideos: RecordingVideoVersion[] = [
  {
    id: 'mock-video-default',
    articleId: mockArticles[0].id,
    videoPath: 'C:\\Program Files\\TomatoEnglishHappyTalking\\recording-export\\Space Snacks.mp4',
    subtitlePath: 'C:\\Program Files\\TomatoEnglishHappyTalking\\recording-export\\Space Snacks.srt',
    createdAt: new Date().toISOString(),
    source: 'listening',
    title: 'Space Snacks',
    isDefault: true,
    durationMs: 4200,
    frameCount: 105,
    droppedFrameCount: 0,
    encoderName: 'libx264',
    codec: 'h264',
    resolution: '1920x1080',
    pageTransition: 'none',
  },
];
