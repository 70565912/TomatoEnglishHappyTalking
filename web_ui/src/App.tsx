import { FormEvent, ReactNode, useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { onNativeEvent, sendNative } from './bridge';
import { splitSentences } from './sentenceSplitter';
import type {
  Article,
  ChatState,
  DiagnosticLogExportPayload,
  FollowState,
  ListeningItem,
  ListeningFullscreenReadyPayload,
  ListeningMode,
  ListeningOpenPayload,
  ListeningPausePayload,
  ListeningPlaybackPayload,
  ListeningRecordingProgressPayload,
  ListeningRecordingReadyPayload,
  ListeningRecordingResultPayload,
  ListeningResumePayload,
  ListeningSentenceUpdatePayload,
  ListeningSongPositionPayload,
  ListeningSongStatePayload,
  ListeningTranslationsPayload,
  PictureBookPage,
  PictureBookPageImagePayload,
  PictureBookState,
  PreloadState,
  VoicePreviewPayload,
  WordLookupPayload,
  WordPlaybackPayload,
  SettingsState,
  RecordingSettings,
  SongSource,
  StorySeries,
} from './types';
import './styles.css';

const sampleText = 'Tom is on a space trip. He sees a bright snack box. It looks like a snack box! Tom opens it slowly.';
const ARTICLE_CONTENT_MAX_CHARS = 8000;
const PRELOAD_COMPLETE_VISIBLE_MS = 3000;
const PRELOAD_IMAGE_DECODE_TIMEOUT_MS = 8000;
const RECENT_SERIES_STORAGE_KEY = 'tomato.recentSeriesKey.v1';

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

function mergePictureBookState(
  current: PictureBookState | null,
  next: PictureBookState | null,
): PictureBookState | null {
  if (!next) {
    return current;
  }
  if (!current || current.articleId !== next.articleId) {
    return next;
  }

  const imageUriByPage = new Map(
    current.pages
      .filter((page) => page.imageUri?.trim())
      .map((page) => [page.pageIndex, page.imageUri?.trim() ?? '']),
  );
  let changed = false;
  const pages = next.pages.map((page) => {
    if (page.imageUri?.trim()) {
      return page;
    }
    const imageUri = imageUriByPage.get(page.pageIndex);
    if (!imageUri) {
      return page;
    }
    changed = true;
    return {
      ...page,
      imageUri,
    };
  });

  return changed ? { ...next, pages } : next;
}

function mergePictureBookPageImage(
  current: PictureBookState | null,
  payload: PictureBookPageImagePayload,
): PictureBookState | null {
  const imageUri = payload.imageUri?.trim() ?? '';
  if (!current || current.articleId !== payload.articleId) {
    return current;
  }

  let changed = false;
  const pages = current.pages.map((page) => {
    if (page.pageIndex !== payload.pageIndex) {
      return page;
    }

    if (imageUri && page.imageUri === imageUri) {
      return page;
    }

    if (imageUri) {
      changed = true;
      return {
        ...page,
        imageUri,
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

  return changed ? { ...current, pages } : current;
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

const mascotBlinkFrames = [
  'lego/mascot-blink/frame-01.png',
  'lego/mascot-blink/frame-02.png',
  'lego/mascot-blink/frame-03.png',
  'lego/mascot-blink/frame-04.png',
  'lego/mascot-blink/frame-05.png',
  'lego/mascot-blink/frame-06.png',
  'lego/mascot-blink/frame-07.png',
];

const legoMascot = {
  idle: mascotBlinkFrames[0],
  blink: mascotBlinkFrames[3],
  blinkFrames: mascotBlinkFrames,
};

const pngAsset = {
  star: 'lego/prop-star.png',
  brick: 'lego/prop-bricks.png',
  legoLogo: 'lego/brand-tomato.png',
  legoListen: 'lego/prop-headphones.png',
  legoRecord: 'lego/prop-microphone.png',
  legoScore: 'lego/prop-shield.png',
  legoMonster: 'lego/prop-monster.png',
};

function App() {
  const [route, setRoute] = useHashRoute();
  const [articles, setArticles] = useState<Article[]>([]);
  const [followState, setFollowState] = useState<FollowState | null>(null);
  const [pictureBookState, setPictureBookState] = useState<PictureBookState | null>(null);
  const [chatState, setChatState] = useState<ChatState | null>(null);
  const [settings, setSettings] = useState<SettingsState | null>(null);
  const [recordingSettings, setRecordingSettings] = useState<RecordingSettings | null>(null);
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

  const navigate = (path: string) => {
    setNotice(null);
    setRoute(path);
    void sendNative('app.navigate', { path });
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
      if (isMounted) setRecordingSettings(payload);
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
        if (isMounted) setRecordingSettings(payload);
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

  return (
    <div className="app-shell">
      <div className="soft-grid" aria-hidden="true" />

      <aside className="side-rail">
        <button className="brand-card" onClick={() => navigate('/')}>
          <img src={asset(pngAsset.legoLogo)} alt="" />
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
        <NavButton label="大厅" icon="home" active={route === '/'} onClick={() => navigate('/')} />
        <NavButton
          label="任务"
          icon="task"
          active={route === '/article/new'}
          onClick={() => navigate('/article/new')}
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
            onRecentBookKeyChange={rememberSeriesKey}
            onNavigate={navigate}
            onDelete={async (articleId) => {
              const payload = await sendNative<{ articles: Article[]; series?: StorySeries[] }>(
                'article.delete',
                { articleId },
              );
              setArticles(payload.articles);
              if (payload.series) setSeries(payload.series);
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
            onRename={async (articleId, title) => {
              const payload = await sendNative<{ article: Article; articles: Article[]; series?: StorySeries[] }>(
                'article.rename',
                { articleId, title },
              );
              setArticles(payload.articles);
              if (payload.series) setSeries(payload.series);
              rememberSeriesKey(bookKeyForArticle(payload.article));
              setNotice('文章标题已更新');
            }}
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
              navigate('/');
              setNotice('任务卡已加入大厅');
            }}
          />
        )}

        {parsedRoute.kind === 'listen' && (
          <ListeningPage
            articleId={parsedRoute.articleId}
            pictureBookState={pictureBookState?.articleId === parsedRoute.articleId ? pictureBookState : null}
            onNavigate={navigate}
            onPictureBookLoaded={setPictureBookState}
            pictureBookRetryGate={pictureBookRetryGate}
            englishPreloadState={preloadStates[preloadKey('listening', parsedRoute.articleId, 'english')]}
            chinesePreloadState={preloadStates[preloadKey('listening', parsedRoute.articleId, 'chinese')]}
            recordingSettings={recordingSettings}
            onRecordingSettingsLoaded={setRecordingSettings}
            songSettings={settings?.song ?? null}
            onNotice={setNotice}
            onArticlesUpdated={(payload) => {
              if (payload.articles) setArticles(payload.articles);
              if (payload.series) setSeries(payload.series);
            }}
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
          />
        )}

        {parsedRoute.kind === 'settings' && (
          <SettingsPage
            settings={settings}
            onLoaded={setSettings}
          />
        )}
      </main>
    </div>
  );
}

function HomePage({
  articles,
  series,
  latestArticle,
  recentBookKey,
  onRecentBookKeyChange,
  onNavigate,
  onDelete,
  onDeleteSeries,
  onRename,
}: {
  articles: Article[];
  series: StorySeries[];
  latestArticle?: Article;
  recentBookKey: string | null;
  onRecentBookKeyChange: (key: string | null) => void;
  onNavigate: (path: string) => void;
  onDelete: (articleId: number) => Promise<void>;
  onDeleteSeries: (seriesId: number) => Promise<void>;
  onRename: (articleId: number, title: string) => Promise<void>;
}) {
  const [selectedBookKey, setSelectedBookKey] = useState<string | null>(null);
  const [chapterPage, setChapterPage] = useState(0);
  const [chapterOrder, setChapterOrder] = useState<ChapterOrder>('asc');
  const [renameDraft, setRenameDraft] = useState<{ article: Article; title: string } | null>(null);
  const [renameSaving, setRenameSaving] = useState(false);
  const [renameError, setRenameError] = useState<string | null>(null);
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
  const orderedChapters = useMemo(
    () => (selectedBook ? sortBookChapters(selectedBook.articles, chapterOrder) : []),
    [selectedBook, chapterOrder],
  );
  const totalChapterPages = Math.max(1, Math.ceil(orderedChapters.length / 10));
  const safeChapterPage = Math.min(chapterPage, totalChapterPages - 1);
  const visibleChapters = orderedChapters.slice(safeChapterPage * 10, safeChapterPage * 10 + 10);

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

  useEffect(() => {
    setChapterPage((current) => Math.min(current, totalChapterPages - 1));
  }, [totalChapterPages]);

  return (
    <section className="page home-page">
      <header className="home-hero">
        <div className="hero-copy">
          <p className="eyebrow">Level 12 · Speaking Quest</p>
          <h1>今天也要快乐开口说英语！</h1>
          <p>把文章变成闯关卡：先跟读、再对话，也可以随时听全文。</p>
          <div className="hero-actions">
            <button
              className="primary-action"
              onClick={() => {
                if (latestArticle) {
                  onRecentBookKeyChange(bookKeyForArticle(latestArticle));
                  onNavigate(`/listen/${latestArticle.id}`);
                } else {
                  onNavigate('/article/new');
                }
              }}
            >
              <Icon name="play" /> 开始闯关
            </button>
          </div>
        </div>
        <div className="hero-stage">
          <MascotBlinker className="hero-mascot" />
          <div className="xp-chip">
            <span>Next reward</span>
            <b>+350 XP</b>
          </div>
        </div>
      </header>

      <div className="dashboard-grid">
        <section className="stats-row" aria-label="learning stats">
          <StatTile label="任务卡" value={articles.length.toString()} icon="card" />
          <StatTile label="句子" value={totalSentences.toString()} icon="sentence" />
          <StatTile label="平均分" value={averageScore > 0 ? averageScore.toString() : '--'} icon="star" />
        </section>
      </div>

      <section className="mission-list-panel">
        <div className="section-heading with-action">
          <span>我的书籍</span>
          <button onClick={() => onNavigate('/article/new')}>
            <Icon name="plus" /> 新增任务
          </button>
        </div>
        {books.length === 0 ? (
          <EmptyMission onNavigate={onNavigate} />
        ) : (
          <>
            <div className="book-list" role="list" aria-label="书籍列表">
              {books.map((book, index) => (
                <div className="book-card-wrap" key={book.key}>
                  <button
                    className={`book-card ${book.key === selectedBookKey ? 'active' : ''}`}
                    type="button"
                    onClick={() => {
                      setSelectedBookKey(book.key);
                      onRecentBookKeyChange(book.key);
                      setChapterPage(0);
                    }}
                  >
                    <img src={bookCoverSource(book, index)} alt="" />
                    <span>
                      <b>{book.title}</b>
                      <small>{book.articles.length} 篇章节 · {book.sentenceCount} 句子</small>
                    </span>
                    <Icon name="next" />
                  </button>
                  {book.seriesId != null && book.articles.length === 0 && (
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
              <section className="chapter-list-panel" aria-label={`${selectedBook.title} 章节列表`}>
                <div className="chapter-toolbar">
                  <div>
                    <span>章节列表</span>
                    <b>{selectedBook.title}</b>
                  </div>
                  <div className="chapter-tools">
                    <div className="pagination" aria-label="章节分页">
                      <button
                        type="button"
                        onClick={() => setChapterPage((page) => Math.max(0, page - 1))}
                        disabled={safeChapterPage === 0}
                      >
                        <Icon name="prev" /> 上一页
                      </button>
                      <button
                        type="button"
                        onClick={() => {
                          setChapterOrder((current) => (current === 'asc' ? 'desc' : 'asc'));
                          setChapterPage(0);
                        }}
                      >
                        <Icon name="swap" /> {chapterOrder === 'asc' ? '正序' : '倒序'}
                      </button>
                      <span>第 {safeChapterPage + 1} / {totalChapterPages} 页 · 每页 10 篇</span>
                      <button
                        type="button"
                        onClick={() => setChapterPage((page) => Math.min(totalChapterPages - 1, page + 1))}
                        disabled={safeChapterPage >= totalChapterPages - 1}
                      >
                        下一页 <Icon name="next" />
                      </button>
                    </div>
                  </div>
                </div>

                <div className="mission-list">
                  {visibleChapters.map((article, index) => (
                    <MissionRow
                      key={article.id}
                      article={article}
                      imageSrc={articleCoverSource(article, safeChapterPage * 10 + index)}
                      onListen={() => {
                        onRecentBookKeyChange(selectedBook.key);
                        onNavigate(`/listen/${article.id}`);
                      }}
                      onFollow={() => {
                        onRecentBookKeyChange(selectedBook.key);
                        onNavigate(`/follow/${article.id}`);
                      }}
                      onChat={() => {
                        onRecentBookKeyChange(selectedBook.key);
                        onNavigate(`/chat/${article.id}`);
                      }}
                      onDelete={() => onDelete(article.id)}
                      onRename={() => {
                        setRenameDraft({ article, title: article.title });
                        setRenameError(null);
                      }}
                    />
                  ))}
                </div>
              </section>
            )}
          </>
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
              setRenameError(error instanceof Error ? error.message : '文章标题保存失败');
            } finally {
              setRenameSaving(false);
            }
          }}
        />
      )}
    </section>
  );
}

type ChapterOrder = 'asc' | 'desc';

type BookGroup = {
  key: string;
  seriesId?: number;
  title: string;
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
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const sentences = useMemo(() => splitSentences(content), [content]);
  const contentTooLong = content.length > ARTICLE_CONTENT_MAX_CHARS;
  const canSave = Boolean(content.trim()) && !contentTooLong && !saving;

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

    setSaving(true);
    setError(null);
    try {
      const resolvedSeriesId =
        selectedSeriesId !== 'new'
          ? Number(selectedSeriesId)
          : undefined;
      const resolvedSeriesTitle =
        selectedSeriesId === 'new'
          ? (newSeriesTitle.trim() || title.trim())
          : '';
      const payload = await sendNative<{ article: Article; articles: Article[]; series?: StorySeries[] }>(
        'article.create',
        {
          title: title.trim(),
          content,
          pictureBookEnabled: true,
          seriesId: resolvedSeriesId,
          seriesTitle: resolvedSeriesTitle,
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
                onChange={(event) => setSelectedSeriesId(event.target.value)}
              >
                {series.map((item) => (
                  <option value={String(item.id)} key={item.id}>
                    {item.title}
                  </option>
                ))}
                <option value="new">新建书籍</option>
              </select>
              {(selectedSeriesId === 'new' || series.length === 0) && (
                <input
                  aria-label="新书籍名称"
                  value={newSeriesTitle}
                  maxLength={80}
                  placeholder="例如 The Secret Garden"
                  onChange={(event) => setNewSeriesTitle(event.target.value)}
                />
              )}
            </div>
            <small>保存后会按本章分镜异步生成连续绘本图。</small>
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
            <Icon name="save" /> {saving ? '保存中' : '保存任务'}
          </button>
        </footer>
      </form>
    </section>
  );
}

type ListeningStatus = 'loading' | 'ready' | 'playing' | 'stopping' | 'done' | 'error';
type ListeningPart = 'english' | 'chinese' | null;
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
};
type SongDialogTab = 'play' | 'settings';
type SongDialogState = {
  activeTab: SongDialogTab;
  source: SongSource;
  stylePrompt: string;
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
  pictureBookState,
  onNavigate,
  onPictureBookLoaded,
  pictureBookRetryGate,
  englishPreloadState,
  chinesePreloadState,
  recordingSettings,
  onRecordingSettingsLoaded,
  songSettings,
  onNotice,
  onArticlesUpdated,
}: {
  articleId: number;
  pictureBookState: PictureBookState | null;
  onNavigate: (path: string) => void;
  onPictureBookLoaded: PictureBookStateSetter;
  pictureBookRetryGate: PictureBookRetryGate;
  englishPreloadState?: PreloadState;
  chinesePreloadState?: PreloadState;
  recordingSettings: RecordingSettings | null;
  onRecordingSettingsLoaded: (settings: RecordingSettings) => void;
  songSettings: SettingsState['song'] | null;
  onNotice: (message: string) => void;
  onArticlesUpdated: (payload: { articles?: Article[]; series?: StorySeries[] }) => void;
}) {
  const [article, setArticle] = useState<Article | null>(null);
  const [items, setItems] = useState<ListeningItem[]>([]);
  const [mode, setMode] = useState<ListeningMode>('english');
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
  const [recordingReady, setRecordingReady] = useState<ListeningRecordingReadyPayload | null>(null);
  const [recordingReadyLoading, setRecordingReadyLoading] = useState(false);
  const [recordingProgress, setRecordingProgress] = useState<ListeningRecordingProgressPayload | null>(null);
  const [recordingResult, setRecordingResult] = useState<ListeningRecordingResultPayload | null>(null);
  const [recordingError, setRecordingError] = useState<string | null>(null);
  const [recordingBusy, setRecordingBusy] = useState(false);
  const [recordingDialogDraft, setRecordingDialogDraft] = useState<RecordingSettings | null>(null);
  const [recordingDialogSaving, setRecordingDialogSaving] = useState(false);
  const [songState, setSongState] = useState<ListeningSongStatePayload | null>(null);
  const [songCue, setSongCue] = useState<ListeningSongPositionPayload['cue']>(null);
  const [songDialog, setSongDialog] = useState<SongDialogState | null>(null);
  const playbackTokenRef = useRef(0);
  const wordCardTokenRef = useRef(0);
  const fullscreenReadyTokenRef = useRef(0);
  const recordingReadyTokenRef = useRef(0);
  const chinesePreloadKeysRef = useRef<Set<string>>(new Set());
  const manualTranslationIndexesRef = useRef<Set<number>>(new Set());

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
    setRecordingReady(null);
    setRecordingReadyLoading(false);
    setRecordingProgress(null);
    setRecordingResult(null);
    setRecordingError(null);
    setRecordingBusy(false);
    setRecordingDialogDraft(null);
    setRecordingDialogSaving(false);
    setSongState(null);
    setSongCue(null);
    setSongDialog(null);
    wordCardTokenRef.current += 1;
    fullscreenReadyTokenRef.current += 1;
    recordingReadyTokenRef.current += 1;
    chinesePreloadKeysRef.current = new Set();
    manualTranslationIndexesRef.current = new Set();
    onPictureBookLoaded(loadingPictureBookState(articleId));

    const picturePromise = sendNative<PictureBookState>('pictureBook.state', { articleId, includeImageUris: true })
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
        setStatus(payload.items.length > 0 ? 'ready' : 'error');
        if (payload.items.length === 0) {
          setError('这篇文章还没有可朗读的英文句子。');
        }
      })
      .catch((loadError) => {
        if (!isMounted) return;
        setStatus('error');
        setError(loadError instanceof Error ? loadError.message : '听力任务打开失败');
      });

    const songPromise = sendNative<ListeningSongStatePayload>('listening.songState', { articleId })
      .then((payload) => {
        if (isMounted) setSongState(payload);
      })
      .catch(() => undefined);

    void Promise.allSettled([listeningPromise, picturePromise, songPromise]);

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
      setSongState(payload);
      if (payload.status !== 'playing') {
        setSongCue(null);
      }
      if (payload.status === 'ready') {
        setSongDialog((current) =>
          current
            ? {
                ...current,
                activeTab: 'play',
                submitting: false,
                suggesting: false,
                stylePrompt: payload.stylePrompt?.trim() ?? current.stylePrompt,
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
                submitting: false,
                suggesting: false,
                stylePrompt: payload.stylePrompt?.trim() ?? current.stylePrompt,
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
      setSongCue(cue);
      if (cue) {
        setCurrentIndex(cue.lineIndex);
        setActivePart('english');
      } else {
        setActivePart(null);
      }
    });
  }, [articleId]);

  useEffect(() => {
    if (mode !== 'bilingual') return;
    const preloadItems = items.filter((item) => {
      const chinese = item.chinese.trim();
      if (!chinese) return false;
      const key = `${item.index}:${chinese}`;
      if (chinesePreloadKeysRef.current.has(key)) return false;
      chinesePreloadKeysRef.current.add(key);
      return true;
    });
    if (preloadItems.length === 0) return;

    void sendNative('listening.preloadChinese', {
      articleId,
      items: preloadItems,
    }).catch(() => undefined);
  }, [articleId, items, mode]);

  useEffect(() => {
    if (items.length === 0) {
      setFullscreenReady(null);
      setFullscreenReadyLoading(false);
      return;
    }

    const token = ++fullscreenReadyTokenRef.current;
    setFullscreenReadyLoading(true);
    sendNative<ListeningFullscreenReadyPayload>('listening.fullscreenReady', {
      articleId,
      mode,
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
    items,
    mode,
    englishPreloadState?.runId,
    englishPreloadState?.status,
    englishPreloadState?.completed,
    englishPreloadState?.total,
    englishPreloadState?.failed,
    chinesePreloadState?.runId,
    chinesePreloadState?.status,
    chinesePreloadState?.completed,
    chinesePreloadState?.total,
      chinesePreloadState?.failed,
    ]);

  useEffect(() => {
    if (items.length === 0 || !recordingSettings) {
      setRecordingReady(null);
      setRecordingReadyLoading(false);
      return;
    }
    const token = ++recordingReadyTokenRef.current;
    setRecordingReadyLoading(true);
    const subtitleTranslations = items
      .map((item) => ({ index: item.index, chinese: item.chinese.trim() }))
      .filter((item) => item.chinese.length > 0);
    sendNative<ListeningRecordingReadyPayload>('listening.recordingReady', {
      articleId,
      mode,
      codec: recordingSettings.codec,
      resolution: recordingSettings.resolution,
      pageTransition: recordingSettings.pageTransition,
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
    mode,
    recordingSettings,
    englishPreloadState?.runId,
    englishPreloadState?.status,
    englishPreloadState?.completed,
    englishPreloadState?.total,
    englishPreloadState?.failed,
    chinesePreloadState?.runId,
    chinesePreloadState?.status,
    chinesePreloadState?.completed,
    chinesePreloadState?.total,
    chinesePreloadState?.failed,
    pictureBookState?.status,
    pictureBookState?.pages,
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
    if (items.length === 0 || isListeningBusy(status)) return;

    const token = ++playbackTokenRef.current;
    const safeStart = Math.max(0, Math.min(startIndex, items.length - 1));
    const selectedMode = mode;

    setStatus('playing');
    setError(null);
    setActivePart(null);

    try {
      await sendNative('listening.playSequence', {
        startIndex: safeStart,
        mode: selectedMode,
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
        mode,
        codec: selectedSettings.codec,
        resolution: selectedSettings.resolution,
        pageTransition: selectedSettings.pageTransition,
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
    setRecordingDialogDraft(recordingSettings);
    setRecordingError(null);
  };

  const updateRecordingDialogDraft = (patch: Partial<RecordingSettings>) => {
    setRecordingDialogDraft((draft) => (draft ? { ...draft, ...patch } : draft));
  };

  const confirmRecordingDialog = async () => {
    if (!recordingDialogDraft || recordingDialogSaving) return;
    setRecordingDialogSaving(true);
    setRecordingError(null);
    try {
      const savedSettings = await sendNative<RecordingSettings>('recording.settings.save', {
        codec: recordingDialogDraft.codec,
        resolution: recordingDialogDraft.resolution,
        pageTransition: recordingDialogDraft.pageTransition,
      });
      onRecordingSettingsLoaded(savedSettings);
      setRecordingDialogDraft(null);
      await startRecording(savedSettings);
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

  const openSongDialog = () => {
    if (busy) return;
    const defaultSource = normalizeSongSource(songState?.source ?? songSettings?.defaultSource ?? 'suno');
    const versions = songState?.versions?.filter((version) => version.id && version.audioPath) ?? [];
    setSongDialog({
      activeTab: versions.length > 0 ? 'play' : 'settings',
      source: defaultSource,
      stylePrompt: songState?.stylePrompt?.trim() ?? '',
      suggesting: false,
      submitting: false,
      error: songState?.status === 'error' ? songState.errorMessage?.trim() || null : null,
    });
  };

  const suggestSongStyle = async () => {
    if (!songDialog || songDialog.suggesting || songDialog.submitting) return;
    if (songDialog.source !== 'minimax') return;
    setSongDialog((current) => (current ? { ...current, suggesting: true, error: null } : current));
    try {
      const payload = await sendNative<ListeningSongStatePayload>('listening.songSuggestStyle', { articleId });
      setSongState(payload);
      setSongDialog((current) =>
        current
          ? {
              ...current,
              stylePrompt: payload.stylePrompt?.trim() ?? current.stylePrompt,
              suggesting: false,
              error: null,
            }
          : current,
      );
    } catch (styleError) {
      setSongDialog((current) =>
        current
          ? {
              ...current,
              suggesting: false,
              error: styleError instanceof Error ? styleError.message : '歌曲风格生成失败',
            }
          : current,
      );
    }
  };

  const generateSong = async () => {
    if (!songDialog || songDialog.submitting || songDialog.suggesting) return;
    const stylePrompt = songDialog.stylePrompt.trim();
    if (songDialog.source !== 'suno' && !stylePrompt) {
      setSongDialog((current) => (current ? { ...current, error: '请先填写歌曲风格描述。' } : current));
      return;
    }

    const lyrics = songLyricsFromItems(items);
    let compressLyrics = false;
    if (songDialog.source === 'minimax' && lyrics.length > 3500) {
      const confirmed = window.confirm(
        `整篇文章歌词约 ${lyrics.length} 个字符，超过 MiniMax 3500 字符上限。是否先调用 AI 改写压缩后再生成歌曲？`,
      );
      if (!confirmed) return;
      compressLyrics = true;
    }
    if (songDialog.source === 'suno') {
      const confirmed = window.confirm(
        '即将打开 Suno 页面，请自行登录 Suno。登录后 Tomato 会自动填写歌词；如果这篇文章已有上次 Suno 自动风格会直接复用，否则点击 Suno 蓝色魔法棒根据歌词生成风格，并在点击 Create 前再次确认消耗 Suno credits。是否继续？',
      );
      if (!confirmed) return;
    }
    if (songDialog.source === 'other') {
      setSongDialog((current) => (current ? { ...current, error: '其它生成方式还没有开放。' } : current));
      return;
    }

    setSongDialog((current) => (current ? { ...current, submitting: true, error: null } : current));
    setSongState({
      articleId,
      status: 'generating',
      stylePrompt,
      errorMessage: null,
      source: songDialog.source,
    });
    try {
      const payload = await sendNative<ListeningSongStatePayload>('listening.songGenerate', {
        articleId,
        source: songDialog.source,
        stylePrompt,
        compressLyrics,
        lyrics,
      });
      setSongState(payload);
      setSongDialog((current) =>
        current
          ? {
              ...current,
              activeTab: payload.status === 'ready' || isSunoWaitingConfirm(payload) ? 'play' : current.activeTab,
              submitting:
                songDialog.source !== 'suno' && payload.status === 'generating' && !isSunoWaitingConfirm(payload)
                  ? current.submitting
                  : false,
              stylePrompt: payload.stylePrompt?.trim() ?? current.stylePrompt,
            }
          : current,
      );
    } catch (songError) {
      const message = songError instanceof Error ? songError.message : '歌曲生成提交失败';
      setSongState({
        articleId,
        status: 'error',
        stylePrompt,
        source: songDialog.source,
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
    if (!songState?.songUrl || songState.source !== 'suno') return;
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

  const playSongVersion = async (versionId?: string) => {
    if (!songState || (songState.status !== 'ready' && songState.status !== 'playing')) return;
    try {
      await sendNative('listening.songPlay', { articleId, versionId });
      setSongState((current) => (current ? { ...current, status: 'playing' } : current));
    } catch (songError) {
      setSongState((current) => ({
        articleId,
        status: 'error',
        stylePrompt: current?.stylePrompt ?? '',
        source: current?.source,
        versions: current?.versions,
        errorMessage: songError instanceof Error ? songError.message : '歌曲播放失败',
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
      setSongState(payload);
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
        fps: selectedSettings.fps || 25,
      });
    } catch (recordError) {
      setRecordingError(recordError instanceof Error ? recordError.message : '录制歌曲视频失败');
    } finally {
      setRecordingBusy(false);
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
        stylePrompt: current?.stylePrompt ?? '',
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
    if (payload.item.chinese.trim()) {
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

  const saveSentenceEdit = async () => {
    if (!sentenceEdit) return;
    const english = sentenceEdit.english.trim();
    const chinese = sentenceEdit.chinese.trim();
    if (!english) {
      setSentenceEdit((current) => (current ? { ...current, error: '英文字幕不能为空。' } : current));
      return;
    }

    setSentenceEdit((current) => (current ? { ...current, saving: true, error: null } : current));
    try {
      await sendNative('listening.stop').catch(() => undefined);
      const payload = await sendNative<ListeningSentenceUpdatePayload>('listening.updateSentence', {
        articleId,
        index: sentenceEdit.item.index,
        english,
        chinese,
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
  useEnsureAllPictureBookPageImages({
    articleId,
    state: pictureBookState,
    onPictureBookLoaded,
  });
  const pictureDecodeState = usePredecodePictureBookImages(articleId, pictureBookState, picturePage);
  useEnsurePictureBookPageImage({
    articleId,
    state: pictureBookState,
    page: picturePage,
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
          <img src={asset(legoMascot.idle)} alt="" />
          <p>{error ?? '听力练习打开失败，请回到大厅后重试。'}</p>
        </section>
      </section>
    );
  }

  const currentItem = items[currentIndex] ?? items[0];
  const sceneEnglish = songCue?.english?.trim() || currentItem?.english || '正在准备句子...';
  const sceneChinese = songCue?.chinese?.trim() || currentItem?.chinese;
  const busy = isListeningBusy(status);
  const progress =
    items.length === 0
      ? 0
      : status === 'done'
        ? 100
        : Math.round(((currentIndex + (busy ? 0.5 : 0)) / items.length) * 100);
  const playbackError = status === 'error' ? error : null;
  const startLabel = status === 'done' ? '重新播放' : '开始播放';
  const titleParts = storyTitlePartsFor(article, pictureBookState, article.title);
  const visiblePreloadState =
    mode === 'bilingual' && chinesePreloadState ? chinesePreloadState : englishPreloadState;
  const fullscreenPictureReadiness = pictureBookFullscreenReadiness(
    pictureBookState,
    items,
    pictureDecodeState,
  );
  const fullscreenAudioReadiness = listeningFullscreenAudioReadiness(
    fullscreenReady,
    fullscreenReadyLoading,
    mode,
  );
  const fullscreenReadiness = combineFullscreenReadiness(
    fullscreenAudioReadiness,
    fullscreenPictureReadiness,
  );
  const canOpenFullscreen = fullscreenReadiness.ready && !busy && items.length > 0;
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
    fullscreenPictureReadiness,
  );
  const canRecordVideo = recordingReadiness.ready && !busy && !recordingBusy && items.length > 0;
  const songWaitingConfirm = isSunoWaitingConfirm(songState);
  const songGenerating = songState?.status === 'generating';
  const songPlaying = songState?.status === 'playing';
  const songVersions = songState?.versions?.filter((version) => version.id && version.audioPath) ?? [];
  const canRetrySunoDownload =
    songState?.source === 'suno' &&
    Boolean(songState?.songUrl?.trim()) &&
    songState?.status !== 'playing' &&
    (songState?.status !== 'ready' || songState.downloadComplete === false) &&
    !songWaitingConfirm &&
    !(songGenerating && songState?.automationStatus !== 'manualAction');
  const songButtonLabel = songWaitingConfirm
    ? '确认创建歌曲'
    : songGenerating
      ? '生成歌曲中'
      : songPlaying
        ? '播放歌曲中'
        : canRetrySunoDownload
          ? '下载歌曲'
        : '歌曲';
  const retryPicturePage = (page: PictureBookPage) => {
    if (!pictureBookRetryGate.begin(articleId, page.pageIndex)) {
      return;
    }

    void sendNative<PictureBookState>('pictureBook.retryPage', {
      articleId,
      pageIndex: page.pageIndex,
    })
      .then((payload) => {
        onPictureBookLoaded((current) => mergePictureBookState(current, payload));
      })
      .catch(() => undefined)
      .finally(() => {
        pictureBookRetryGate.finish(articleId, page.pageIndex);
      });
  };

  return (
    <section className="page listening-page">
      <TopBar title={<StoryTitle parts={titleParts} />} onBack={() => onNavigate('/')}>
        <div className="listening-progress-summary">
          <ProgressLine
            value={progress}
            label={`听力进度 ${Math.min(currentIndex + 1, Math.max(items.length, 1))} / ${Math.max(items.length, 1)}`}
            compact
          />
        </div>
        <button className="ghost-action" onClick={() => onNavigate('/')}>
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
            <div className="mode-dots listening-mode-dots" aria-label="听力播放模式">
              <button
                className={mode === 'english' ? 'active' : ''}
                type="button"
                aria-pressed={mode === 'english'}
                disabled={busy}
                onClick={() => setMode('english')}
              >
                <span aria-hidden="true" />
                英文
              </button>
              <button
                className={mode === 'bilingual' ? 'active' : ''}
                type="button"
                aria-pressed={mode === 'bilingual'}
                disabled={busy}
                onClick={() => setMode('bilingual')}
              >
                <span aria-hidden="true" />
                中英对照
              </button>
            </div>
            <div className="button-row">
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
                className={`ghost-action song-action ${songGenerating && !songWaitingConfirm ? 'loading' : ''}`}
                onClick={openSongDialog}
                disabled={busy || items.length === 0}
                title={songState?.status === 'error' ? songState.errorMessage?.trim() || '歌曲生成失败' : undefined}
              >
                <Icon name={songGenerating && !songWaitingConfirm ? 'refresh' : songPlaying ? 'sound' : 'music'} /> {songButtonLabel}
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
                className="ghost-action recording-start-button"
                onClick={openRecordingDialog}
                disabled={!canRecordVideo}
                title={recordingReadiness.reason}
              >
                <Icon name="recordVideo" /> 录制视频
              </button>
            </div>
            {!fullscreenReadiness.ready && (
              <p className="fullscreen-ready-hint">{fullscreenReadiness.reason}</p>
            )}
            {!recordingReadiness.ready && (
              <p className="fullscreen-ready-hint">{recordingReadiness.reason}</p>
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
            {songState?.source === 'suno' && songState?.stylePrompt?.trim() && (
              <div className="suno-style-chip" aria-label="当前 Suno 自动风格">
                <span>当前 Suno 自动风格</span>
                <b>{songState.stylePrompt.trim()}</b>
              </div>
            )}
            {recordingError && <p className="playback-cue error">{recordingError}</p>}
            {recordingResult && (
              <RecordingResultCard
                result={recordingResult}
                onClose={() => setRecordingResult(null)}
              />
            )}
          </div>

          <div className="listening-list" aria-label="听力句子列表">
            {items.map((item) => {
              const active = item.index === currentIndex;
              return (
                <div
                  className={`listening-row ${active ? 'active' : ''}`}
                  key={`${item.index}-${item.english}`}
                  onClick={() => {
                    if (!busy) setCurrentIndex(item.index);
                  }}
                  onKeyDown={(event) => {
                    if (busy) return;
                    if (event.key === 'Enter' || event.key === ' ') {
                      event.preventDefault();
                      setCurrentIndex(item.index);
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
                      {item.english}
                    </strong>
                    <small className={active && activePart === 'chinese' ? 'playing-text' : undefined}>
                      {item.chinese}
                    </small>
                    {sentenceSynthesisErrors[item.index] && (
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
      {songDialog && (
        <SongDialog
          state={songDialog}
          songState={songState}
          songVersions={songVersions}
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
          onStyleChange={(stylePrompt) =>
            setSongDialog((current) => (current ? { ...current, stylePrompt, error: null } : current))
          }
          onSuggest={() => void suggestSongStyle()}
          onCancel={() => {
            setSongDialog(null);
          }}
          onConfirm={() => void generateSong()}
          onConfirmSunoCreate={() => void confirmSunoCreate()}
          onRetrySunoDownload={() => void retrySunoDownload()}
          onPlayVersion={(versionId) => void playSongVersion(versionId)}
          onGenerateTimeline={(versionId) => void generateSongTimeline(versionId)}
          onRecordSongVideo={(versionId) => void recordSongVideo(versionId)}
          onStopSong={() => void stopSong()}
        />
      )}
      {fullscreenPlayerOpen && article && (
        <FullscreenListeningPlayer
          article={article}
          items={items}
          mode={mode}
          pictureBookState={pictureBookState}
          onClose={() => setFullscreenPlayerOpen(false)}
        />
      )}
      {recordingDialogDraft && (
        <RecordingSettingsDialog
          settings={recordingDialogDraft}
          saving={recordingDialogSaving}
          onChange={updateRecordingDialogDraft}
          onCancel={() => {
            if (!recordingDialogSaving) setRecordingDialogDraft(null);
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
    englishRef.current?.select();
  }, []);

  return createPortal(
    <div className="edit-dialog-backdrop" role="presentation">
      <section className="edit-dialog sentence-edit-dialog" role="dialog" aria-modal="true" aria-label="修改字幕">
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
          <button className="primary-action" type="button" onClick={onSave} disabled={state.saving || !state.english.trim()}>
            <Icon name="save" /> {state.saving ? '保存中' : '保存'}
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
  canRetrySunoDownload,
  songWaitingConfirm,
  songGenerating,
  songPlaying,
  recordingBusy,
  onTabChange,
  onSourceChange,
  onStyleChange,
  onSuggest,
  onCancel,
  onConfirm,
  onConfirmSunoCreate,
  onRetrySunoDownload,
  onPlayVersion,
  onGenerateTimeline,
  onRecordSongVideo,
  onStopSong,
}: {
  state: SongDialogState;
  songState: ListeningSongStatePayload | null;
  songVersions: NonNullable<ListeningSongStatePayload['versions']>;
  canRetrySunoDownload: boolean;
  songWaitingConfirm: boolean;
  songGenerating: boolean;
  songPlaying: boolean;
  recordingBusy: boolean;
  onTabChange: (tab: SongDialogTab) => void;
  onSourceChange: (source: SongSource) => void;
  onStyleChange: (stylePrompt: string) => void;
  onSuggest: () => void;
  onCancel: () => void;
  onConfirm: () => void;
  onConfirmSunoCreate: () => void;
  onRetrySunoDownload: () => void;
  onPlayVersion: (versionId?: string) => void;
  onGenerateTimeline: (versionId: string) => void;
  onRecordSongVideo: (versionId: string) => void;
  onStopSong: () => void;
}) {
  const styleRef = useRef<HTMLTextAreaElement | null>(null);
  const busy = state.suggesting || state.submitting;
  const groupedVersions = useMemo(() => groupSongVersionsByStyle(songVersions), [songVersions]);

  useEffect(() => {
    if (state.activeTab === 'settings') {
      styleRef.current?.focus({ preventScroll: true });
    }
  }, [state.activeTab]);

  return createPortal(
    <div className="edit-dialog-backdrop" role="presentation">
      <section className="edit-dialog song-style-dialog" role="dialog" aria-modal="true" aria-label="歌曲风格设置">
        <div className="edit-dialog-heading">
          <div>
            <b>歌曲风格设置</b>
            <small>{state.activeTab === 'play' ? '选择本地已下载的完整歌曲版本播放。' : state.source === 'suno' ? '已有 Suno 风格会复用；没有时由 Suno 根据歌词生成。' : '确认后会使用整篇文章生成歌曲。'}</small>
          </div>
          <div className="song-style-heading-actions">
            {state.activeTab === 'settings' && state.source === 'minimax' && (
              <button
                className={`icon-button small ${state.suggesting ? 'loading' : ''}`}
                type="button"
                onClick={onSuggest}
                disabled={busy}
                aria-label="生成合适的歌曲风格"
                title="生成合适的歌曲风格"
              >
                <Icon name={state.suggesting ? 'refresh' : 'wand'} />
              </button>
            )}
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
          <button
            type="button"
            role="tab"
            aria-selected={state.activeTab === 'settings'}
            className={state.activeTab === 'settings' ? 'active' : ''}
            onClick={() => onTabChange('settings')}
          >
            设置
          </button>
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
                      <span>风格</span>
                      <b>{group.label}</b>
                    </div>
                    <div className="song-version-row" aria-label={`${group.label} 歌曲版本`}>
                      {group.versions.map((version, index) => {
                        const title = version.title?.trim() || `版本 ${index + 1}`;
                        const timelineStatus = normalizeTimelineStatus(version.timelineStatus, version.timelinePath);
                        const timelineReady = timelineStatus === 'ready';
                        const timelineGenerating = timelineStatus === 'generating';
                        return (
                          <div className="song-version-actions" key={version.id}>
                            <button
                              className="ghost-action small"
                              type="button"
                              onClick={() => onPlayVersion(version.id)}
                              disabled={busy || songGenerating}
                              title={title}
                            >
                              <Icon name="sound" /> {title}
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
                              title={timelineReady ? '录制歌曲视频' : '请先生成歌曲字幕'}
                            >
                              <Icon name="recordVideo" /> 录制歌曲视频
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
              {songWaitingConfirm && (
                <button className="primary-action small" type="button" onClick={onConfirmSunoCreate} disabled={busy}>
                  <Icon name="music" /> 确认创建歌曲
                </button>
              )}
              {canRetrySunoDownload && (
                <button className="ghost-action small" type="button" onClick={onRetrySunoDownload} disabled={busy}>
                  <Icon name="download" /> 下载缺失版本
                </button>
              )}
              <button className="ghost-action small" type="button" onClick={() => onTabChange('settings')} disabled={busy}>
                <Icon name="music" /> 生成新版本
              </button>
            </div>
          </div>
        ) : (
          <>
            <div className="song-source-options" aria-label="生成来源">
              <button
                type="button"
                className={state.source === 'suno' ? 'active' : ''}
                disabled={busy}
                onClick={() => onSourceChange('suno')}
              >
                Suno 网页自动化
              </button>
              <button
                type="button"
                className={state.source === 'minimax' ? 'active' : ''}
                disabled={busy}
                onClick={() => onSourceChange('minimax')}
              >
                MiniMax API
              </button>
              <button type="button" disabled>
                其它方式
              </button>
            </div>
            {state.source === 'suno' ? (
              <div className="song-source-note suno-style-preview">
                <p>
                  将打开 Suno 页面，请自行登录；登录后 Tomato 会自动填写歌词，复用本篇文章上次 Suno 风格；没有已保存风格时，优先点击 Suno 自带的魔法棒根据歌词生成风格。Tomato 不保存 Suno 用户名、密码或验证码。
                </p>
                <label>
                  <span>Suno 自动风格</span>
                  <textarea
                    ref={styleRef}
                    value={state.stylePrompt || '没有已保存风格，登录后由 Suno 蓝色魔法棒根据歌词自动生成'}
                    rows={3}
                    readOnly
                  />
                </label>
              </div>
            ) : (
              <p className="song-source-note">
                MiniMax 使用本机配置的 API Key 直接生成歌曲，长歌词会先询问是否压缩。
              </p>
            )}
            {state.source !== 'suno' && (
              <label>
                <span>风格描述</span>
                <textarea
                  ref={styleRef}
                  value={state.stylePrompt}
                  rows={5}
                  maxLength={2000}
                  placeholder="例如：明亮的儿童音乐剧, 奇幻冒险, 轻快节奏, 弦乐和木琴, 适合绘本故事"
                  onChange={(event) => onStyleChange(event.target.value)}
                  disabled={state.submitting}
                />
              </label>
            )}
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
              disabled={busy || (state.source !== 'suno' && !state.stylePrompt.trim())}
            >
              <Icon name={state.submitting ? 'refresh' : 'music'} /> {state.submitting ? '提交生成中' : '开始生成歌曲'}
            </button>
          )}
        </div>
      </section>
    </div>,
    document.body,
  );
}

function FullscreenListeningPlayer({
  article,
  items,
  mode,
  pictureBookState,
  onClose,
}: {
  article: Article;
  items: ListeningItem[];
  mode: ListeningMode;
  pictureBookState: PictureBookState | null;
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
  const imageSrc = directImageSource(currentPage?.imageUri) ?? '';
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
      mode,
      singleItem: false,
      strictPreloaded: true,
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
  }, [items, mode]);

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
      <button
        className="word-card-dismiss-layer"
        type="button"
        aria-label="关闭单词翻译浮层"
        onClick={() => void onClose()}
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
  preloadState,
}: {
  articleId: number;
  state: FollowState | null;
  pictureBookState: PictureBookState | null;
  onNavigate: (path: string) => void;
  onLoaded: (state: FollowState) => void;
  onPictureBookLoaded: PictureBookStateSetter;
  pictureBookRetryGate: PictureBookRetryGate;
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
    onPictureBookLoaded,
  });

  if (!state || state.status === 'loading') {
    return (
      <section className="page follow-page">
        <TopBar title="跟读任务准备中" onBack={() => onNavigate('/')}>
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
        <TopBar title="跟读任务暂时打不开" onBack={() => onNavigate('/')}>
          <button className="ghost-action" onClick={() => onNavigate('/')}>
            <Icon name="exit" /> 退出
          </button>
        </TopBar>
        <section className="loading-panel">
          <img src={asset(legoMascot.idle)} alt="" />
          <p>{state.error ?? '跟读任务打开失败，请回到大厅后重试。'}</p>
        </section>
      </section>
    );
  }

  const step = state?.step ?? 'idle';
  const currentSentence = state?.currentSentence ?? '正在准备句子...';
  const currentTranslation = state?.currentTranslation ?? '';
  const result = state?.result;
  const totalSentences = state?.totalSentences ?? 0;
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
    (!bottomActionsDisabled || canInterruptRecordingPlayback) && step !== 'completed' && totalSentences > 0;
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

    void sendNative<PictureBookState>('pictureBook.retryPage', {
      articleId,
      pageIndex: page.pageIndex,
    })
      .then((payload) => {
        onPictureBookLoaded((current) => mergePictureBookState(current, payload));
      })
      .catch(() => undefined)
      .finally(() => {
        pictureBookRetryGate.finish(articleId, page.pageIndex);
      });
  };

  return (
    <section className="page follow-page">
      <TopBar title={<StoryTitle parts={titleParts} />} onBack={() => onNavigate('/')}>
        <Pager current={currentIndex + 1} total={totalSentences || 2} />
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
            <div className="follow-control-deck" aria-label="跟读控制">
              <button
                className={`follow-control-button source ${sourceActive ? 'active' : ''}`}
                type="button"
                onClick={playCurrent}
                disabled={!canPlaySource}
              >
                <Icon name={sourceActive ? 'sound' : 'play'} />
                <span>播放原音</span>
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
                <Icon name={step === 'recording' ? 'stop' : 'mic'} />
                <span>{step === 'recording' ? '停止录音' : step === 'scoring' ? '评分中' : '录音'}</span>
              </button>
              <button
                className={`follow-control-button recording ${recordingPlaybackActive ? 'active' : ''}`}
                type="button"
                onClick={playRecording}
                disabled={!canPlayRecording}
              >
                <Icon name={recordingPlaybackActive ? 'sound' : 'replay'} />
                <span>播放录音</span>
              </button>
              {result && <FollowScoreBadge result={result} compact />}
            </div>
            <button className="primary-action follow-next-action" onClick={advanceSentence} disabled={!canAdvanceSentence}>
              {advanceLabel} <Icon name="arrow" />
            </button>
          </div>
          {transcriptHint && <p className="follow-live-transcript">{transcriptHint}</p>}
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

function listeningFullscreenAudioReadiness(
  payload: ListeningFullscreenReadyPayload | null,
  loading: boolean,
  mode: ListeningMode,
): FullscreenReadiness {
  if (loading && !payload?.ready) {
    return { ready: false, reason: '正在确认音频是否已全部加载到内存...' };
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
  const readyChinese = Number(payload.readyChinese ?? 0);
  const requiredChinese = Number(payload.requiredChinese ?? 0);
  if (reasons.length > 0) {
    return { ready: false, reason: String(reasons[0]) };
  }
  if (readyEnglish < requiredEnglish) {
    return {
      ready: false,
      reason: `英文音频正在预加载 ${readyEnglish} / ${requiredEnglish}`,
    };
  }
  if (mode === 'bilingual' && readyChinese < requiredChinese) {
    return {
      ready: false,
      reason: `中文音频正在预加载 ${readyChinese} / ${requiredChinese}`,
    };
  }
  return { ready: false, reason: '音频还没有完成内存预加载' };
}

function pictureBookFullscreenReadiness(
  state: PictureBookState | null,
  items: ListeningItem[],
  decodeState: PictureBookDecodeState,
): FullscreenReadiness {
  if (items.length === 0) {
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
  const missingSentence = items.find(
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
  if (decodeState.missingImagePages.length > 0) {
    return { ready: false, reason: '正在下载绘本图片到内存...' };
  }
  if (decodeState.failed > 0) {
    return { ready: false, reason: '有绘本图片载入失败，请退出后重试' };
  }
  if (!decodeState.ready) {
    return {
      ready: false,
      reason: `正在载入绘本图片 ${decodeState.decoded} / ${decodeState.total}`,
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
  onPictureBookLoaded,
}: {
  articleId: number;
  state: PictureBookState | null;
  page: PictureBookPage | null;
  onPictureBookLoaded: PictureBookStateSetter;
}) {
  const requestKeyRef = useRef('');
  const stateArticleId = state?.articleId ?? null;
  const pageIndex = page?.pageIndex ?? -1;
  const pageStatus = page?.status ?? '';
  const imagePath = page?.imagePath?.trim() ?? '';
  const imageUri = page?.imageUri?.trim() ?? '';

  useEffect(() => {
    if (stateArticleId !== articleId || pageIndex < 0) {
      requestKeyRef.current = '';
      return;
    }
    if (pageStatus !== 'ready' || imageUri || !imagePath) {
      return;
    }

    const requestKey = `${articleId}:${pageIndex}:${imagePath}`;
    if (requestKeyRef.current === requestKey) {
      return;
    }
    requestKeyRef.current = requestKey;

    let isMounted = true;
    sendNative<PictureBookPageImagePayload>('pictureBook.pageImage', {
      articleId,
      pageIndex,
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
  }, [articleId, imagePath, imageUri, onPictureBookLoaded, pageIndex, pageStatus, stateArticleId]);
}

function useEnsureAllPictureBookPageImages({
  articleId,
  state,
  onPictureBookLoaded,
}: {
  articleId: number;
  state: PictureBookState | null;
  onPictureBookLoaded: PictureBookStateSetter;
}) {
  const requestedRef = useRef<Set<string>>(new Set());

  useEffect(() => {
    requestedRef.current = new Set();
  }, [articleId]);

  const missing = state?.articleId === articleId
    ? state.pages
        .filter((page) => page.status === 'ready')
        .filter((page) => !page.imageUri?.trim() && page.imagePath?.trim())
        .map((page) => ({
          pageIndex: page.pageIndex,
          imagePath: page.imagePath?.trim() ?? '',
        }))
        .filter((page) => {
          const key = `${articleId}:${page.pageIndex}:${page.imagePath}`;
          return !requestedRef.current.has(key);
        })
    : [];
  const missingKey = missing
    .map((page) => `${page.pageIndex}:${page.imagePath}`)
    .join('|');

  useEffect(() => {
    if (missing.length === 0) return;
    let cancelled = false;
    void (async () => {
      for (const page of missing) {
        if (cancelled) return;
        const key = `${articleId}:${page.pageIndex}:${page.imagePath}`;
        requestedRef.current.add(key);
        try {
          const payload = await sendNative<PictureBookPageImagePayload>('pictureBook.pageImage', {
            articleId,
            pageIndex: page.pageIndex,
          });
          if (!cancelled) {
            onPictureBookLoaded((current) => mergePictureBookPageImage(current, payload));
          }
        } catch {
          requestedRef.current.delete(key);
        }
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [articleId, missingKey, onPictureBookLoaded]);
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

  const activePageIndex = activePage?.pageIndex ?? 0;
  const readyPages = state?.articleId === articleId
    ? [...state.pages]
        .filter((page) => page.status === 'ready')
        .sort((left, right) => {
          const leftDistance = Math.abs(left.pageIndex - activePageIndex);
          const rightDistance = Math.abs(right.pageIndex - activePageIndex);
          return leftDistance === rightDistance
            ? left.pageIndex - right.pageIndex
            : leftDistance - rightDistance;
        })
    : [];
  const imageItems = readyPages
    .map((page) => ({
      pageIndex: page.pageIndex,
      src: directImageSource(page.imageUri) ?? '',
    }))
    .filter((item) => item.src);
  const missingImagePages = readyPages
    .filter((page) => !directImageSource(page.imageUri))
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
        <span>视频：{result.videoPath}</span>
        <span>字幕：{result.subtitlePath}</span>
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
          <small>文件将保存到程序目录的 recording-export 文件夹。</small>
        </header>
        <div className="recording-dialog-grid">
          <label>
            <span>编码</span>
            <select
              value={settings.codec}
              disabled={saving}
              onChange={(event) => onChange({ codec: event.target.value as RecordingSettings['codec'] })}
            >
              <option value="h264">H.264</option>
              <option value="h265">H.265 / HEVC</option>
            </select>
          </label>
          <label>
            <span>分辨率</span>
            <select
              value={settings.resolution}
              disabled={saving}
              onChange={(event) => onChange({ resolution: event.target.value as RecordingSettings['resolution'] })}
            >
              <option value="2560x1440">2560x1440</option>
              <option value="1920x1080">1920x1080</option>
              <option value="1280x720">1280x720</option>
            </select>
          </label>
          <label>
            <span>转场</span>
            <select
              value={settings.pageTransition}
              disabled={saving}
              onChange={(event) =>
                onChange({ pageTransition: event.target.value as RecordingSettings['pageTransition'] })
              }
            >
              <option value="none">不用转场</option>
              <option value="crossFade">淡入淡出</option>
              <option value="panZoomFade">轻微推拉淡入</option>
              <option value="slide">滑动翻页</option>
            </select>
          </label>
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
  const imageSrc = directImageSource(page?.imageUri) ?? directImageSource(page?.imagePath) ?? '';
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
): StoryTitleParts {
  const articleTitle = article?.title?.trim() ?? '';
  const seriesTitle = pictureBookState?.series?.title?.trim() || article?.seriesTitle?.trim() || '';
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
}: {
  articleId: number;
  state: ChatState | null;
  pictureBookState: PictureBookState | null;
  onNavigate: (path: string) => void;
  onLoaded: (state: ChatState) => void;
  onPictureBookLoaded: PictureBookStateSetter;
  pictureBookRetryGate: PictureBookRetryGate;
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

    void sendNative<PictureBookState>('pictureBook.retryPage', {
      articleId,
      pageIndex: page.pageIndex,
    })
      .then((payload) => {
        onPictureBookLoaded((current) => mergePictureBookState(current, payload));
      })
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
            <div className="reward-preview chat-reward-preview">
              <span>奖励预览</span>
              <img src={asset(pngAsset.star)} alt="" />
              <img src={asset(pngAsset.brick)} alt="" />
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
                  {message.isAi && <img src={asset(legoMascot.idle)} alt="" />}
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
                <img src={asset(pngAsset.legoMonster)} alt="" />
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

function SettingsPage({
  settings,
  onLoaded,
}: {
  settings: SettingsState | null;
  onLoaded: (settings: SettingsState) => void;
}) {
  const [current, setCurrent] = useState<SettingsState | null>(settings);
  const [selectedVoiceId, setSelectedVoiceId] = useState(settings?.tts.speakerId ?? '');
  const [songDefaultSource, setSongDefaultSource] = useState<SongSource>(
    normalizeSongSource(settings?.song?.defaultSource ?? 'suno'),
  );
  const [sunoOutputDirectory, setSunoOutputDirectory] = useState(settings?.song?.sunoOutputDirectory ?? '');
  const [sunoTimeoutMinutes, setSunoTimeoutMinutes] = useState(settings?.song?.sunoTimeoutMinutes ?? 20);
  const [savingSongSettings, setSavingSongSettings] = useState(false);
  const [exportingDiagnostics, setExportingDiagnostics] = useState(false);
  const [saving, setSaving] = useState(false);
  const [previewingVoiceId, setPreviewingVoiceId] = useState<string | null>(null);
  const [status, setStatus] = useState<string | null>(null);
  const selectedVoiceButtonRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    let isMounted = true;
    sendNative<SettingsState>('settings.load')
      .then((payload) => {
        if (!isMounted) return;
        setCurrent(payload);
        setSelectedVoiceId(payload.tts.speakerId);
        setSongDefaultSource(normalizeSongSource(payload.song?.defaultSource ?? 'suno'));
        setSunoOutputDirectory(payload.song?.sunoOutputDirectory ?? '');
        setSunoTimeoutMinutes(payload.song?.sunoTimeoutMinutes ?? 20);
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
    setCurrent(settings);
    if (settings) {
      setSelectedVoiceId(settings.tts.speakerId);
      setSongDefaultSource(normalizeSongSource(settings.song?.defaultSource ?? 'suno'));
      setSunoOutputDirectory(settings.song?.sunoOutputDirectory ?? '');
      setSunoTimeoutMinutes(settings.song?.sunoTimeoutMinutes ?? 20);
    }
  }, [settings]);

  useEffect(() => {
    selectedVoiceButtonRef.current?.scrollIntoView?.({ block: 'center', inline: 'nearest' });
  }, [selectedVoiceId]);

  if (!current) {
    return <LoadingPanel text="正在打开声音设置" />;
  }

  const selectedVoice = current.voices.find((voice) => voice.id === selectedVoiceId);
  const unchanged = selectedVoiceId === current.tts.speakerId;
  const safetyRules = current.contentSafety?.rules ?? [];
  const songSettingsUnchanged =
    songDefaultSource === normalizeSongSource(current.song?.defaultSource ?? 'suno') &&
    sunoOutputDirectory.trim() === (current.song?.sunoOutputDirectory ?? '').trim() &&
    Number(sunoTimeoutMinutes) === Number(current.song?.sunoTimeoutMinutes ?? 20);

  const selectVoice = (voiceId: string) => {
    setSelectedVoiceId(voiceId);
    setStatus(null);
  };

  const previewVoice = async (speakerId: string) => {
    if (previewingVoiceId) return;

    setPreviewingVoiceId(speakerId);
    setStatus(null);
    try {
      await sendNative<VoicePreviewPayload>('settings.previewVoice', {
        speakerId,
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
      });
      setCurrent(payload);
      setSelectedVoiceId(payload.tts.speakerId);
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
        defaultSource: songDefaultSource,
        sunoOutputDirectory: sunoOutputDirectory.trim(),
        sunoTimeoutMinutes: Number(sunoTimeoutMinutes) || 20,
      });
      setCurrent(payload);
      setSongDefaultSource(normalizeSongSource(payload.song?.defaultSource ?? 'suno'));
      setSunoOutputDirectory(payload.song?.sunoOutputDirectory ?? '');
      setSunoTimeoutMinutes(payload.song?.sunoTimeoutMinutes ?? 20);
      onLoaded(payload);
      setStatus('歌曲设置已保存');
    } catch (error) {
      setStatus(error instanceof Error ? error.message : '歌曲设置保存失败');
    } finally {
      setSavingSongSettings(false);
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
                <small>{current.voices.length} 个发音人</small>
              </div>
              <div className="voice-list-scroll" role="listbox" aria-label="可选声音">
                <div className="voice-list">
                  {current.voices.map((voice) => (
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
              <MascotBlinker className="settings-mascot" />
              <span>当前声音</span>
              <b>{selectedVoice?.name ?? '未选择'}</b>
              {selectedVoice && (
                <small>{displayVoiceLanguage(selectedVoice.lang)} · {selectedVoice.gender === 'female' ? '女声' : '男声'}</small>
              )}
            </aside>
          </div>

          <FieldGroup title="歌曲生成">
            <div className="song-settings-grid">
              <label className="settings-label">
                <span>默认生成来源</span>
                <select
                  value={songDefaultSource}
                  onChange={(event) => setSongDefaultSource(normalizeSongSource(event.target.value))}
                >
                  <option value="suno">Suno 网页自动化</option>
                  <option value="minimax">MiniMax API</option>
                </select>
              </label>
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
            </div>
            <p className="settings-help">
              Suno 会打开页面让用户自行登录，登录态来自内置浏览器会话；Tomato 不保存 Suno 用户名、密码、验证码或 cookie 明文。
            </p>
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
    inputRef.current?.select();
  }, []);

  return createPortal(
    <div className="edit-dialog-backdrop" role="presentation">
      <section className="edit-dialog" role="dialog" aria-modal="true" aria-label="修改文章标题">
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

function MissionRow({
  article,
  imageSrc,
  onListen,
  onFollow,
  onChat,
  onDelete,
  onRename,
}: {
  article: Article;
  imageSrc: string;
  onListen: () => void;
  onFollow: () => void;
  onChat: () => void;
  onDelete: () => void;
  onRename: () => void;
}) {
  const score = article.averageScore > 0 ? Math.round(article.averageScore) : 40;
  return (
    <article className="mission-row">
      <button
        className="mission-cover-button"
        type="button"
        onClick={onListen}
        aria-label={`进入《${article.title}》听力`}
      >
        <img src={imageSrc} alt="" />
      </button>
      <div>
        <h3 className="mission-title-line">
          <button type="button" className="mission-title-button" onClick={onListen}>
            {article.title}
          </button>
          <button
            className="icon-button tiny"
            type="button"
            onClick={onRename}
            aria-label={`修改《${article.title}》标题`}
          >
            <Icon name="edit" />
          </button>
        </h3>
        <p>{article.sentenceCount} 句子 · 最近学习 今天</p>
      </div>
      <span className="ring-score">{score}%</span>
      <button className="listen-action" onClick={onListen}><Icon name="sound" /> 听力</button>
      <button className="primary-action" onClick={onFollow}><Icon name="mic" /> 跟读</button>
      <button className="purple-action" onClick={onChat}><Icon name="chat" /> 对话</button>
      <button className="delete-action" onClick={onDelete}>删除</button>
    </article>
  );
}

function EmptyMission({ onNavigate }: { onNavigate: (path: string) => void }) {
  return (
    <div className="empty-mission">
      <img src={asset(legoMascot.idle)} alt="" />
      <p>先放入一篇英文短文，番茄助教会把它变成闯关任务。</p>
      <button className="primary-action" onClick={() => onNavigate('/article/new')}>
        <Icon name="plus" /> 创建第一张任务卡
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
      <span>Tommy</span>
      <b>Lv.12 Star</b>
      <ProgressLine value={65} label="650 / 1000 XP" compact />
    </div>
  );
}

function StatusItem({ image, text, active = false }: { image: string; text: string; active?: boolean }) {
  return (
    <div className={`status-item ${active ? 'active' : ''}`}>
      <img src={asset(image)} alt="" />
      <span>{text}</span>
    </div>
  );
}

function MascotBlinker({ className }: { className: string }) {
  const [frameIndex, setFrameIndex] = useState(0);

  useEffect(() => {
    let blinkTimer: number | undefined;
    let frameTimer: number | undefined;

    const scheduleBlink = () => {
      const delay = 2400 + Math.round(Math.random() * 3600);
      blinkTimer = window.setTimeout(() => {
        let nextFrame = 1;
        const playFrame = () => {
          setFrameIndex(nextFrame);
          nextFrame += 1;

          if (nextFrame < legoMascot.blinkFrames.length) {
            frameTimer = window.setTimeout(playFrame, 58);
            return;
          }

          frameTimer = window.setTimeout(() => {
            setFrameIndex(0);
            scheduleBlink();
          }, 72);
        };

        playFrame();
      }, delay);
    };

    scheduleBlink();
    return () => {
      if (blinkTimer !== undefined) window.clearTimeout(blinkTimer);
      if (frameTimer !== undefined) window.clearTimeout(frameTimer);
    };
  }, []);

  return (
    <span className={`mascot-blinker ${className}`} aria-hidden="true">
      <img className="mascot-frame" src={asset(legoMascot.blinkFrames[frameIndex])} alt="" />
    </span>
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
      <img src={asset(legoMascot.idle)} alt="" />
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
  const trimmed = source?.trim() ?? '';
  if (!trimmed) return null;
  if (/^(data:image\/|blob:|https?:\/\/|assets\/|\.\/|\/assets\/)/i.test(trimmed)) {
    return trimmed;
  }
  return null;
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

function songLyricsFromItems(items: ListeningItem[]): string {
  return items
    .map((item) => item.english.trim())
    .filter(Boolean)
    .join('\n')
    .trim();
}

function normalizeSongSource(source?: string | null): SongSource {
  const value = (source ?? '').trim().toLowerCase();
  if (value === 'minimax') return 'minimax';
  if (value === 'other') return 'other';
  return 'suno';
}

function groupSongVersionsByStyle(versions: SongVersionPayload[]): SongVersionGroup[] {
  const groups = new Map<string, SongVersionGroup>();
  for (const version of versions) {
    const stylePrompt = version.stylePrompt?.trim() ?? '';
    const key = version.styleKey?.trim() || `legacy:${stylePrompt || 'unknown'}`;
    const label = stylePrompt || '未命名风格';
    const group = groups.get(key);
    if (group) {
      group.versions.push(version);
    } else {
      groups.set(key, { key, label, versions: [version] });
    }
  }
  return Array.from(groups.values());
}

function normalizeTimelineStatus(status?: string | null, timelinePath?: string | null): string {
  const value = (status ?? '').trim();
  if (value) return value;
  return timelinePath?.trim() ? 'ready' : 'missing';
}

function songTimelineLabel(status?: string | null): string {
  switch ((status ?? '').trim()) {
    case 'ready':
      return '字幕已生成';
    case 'generating':
      return '字幕生成中';
    case 'error':
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
  switch ((state.automationStatus ?? '').trim()) {
    case 'waitingLogin':
      return 'Suno 页面已打开，请先在页面中自行登录。';
    case 'filling':
      return '正在自动填写 Suno 歌词和风格...';
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
  | { kind: 'listen'; articleId: number }
  | { kind: 'follow'; articleId: number }
  | { kind: 'chat'; articleId: number }
  | { kind: 'settings' } {
  if (route === '/article/new') return { kind: 'article' };
  if (route === '/settings' || route === '/profile') return { kind: 'settings' };

  const follow = route.match(/^\/follow\/(\d+)/);
  if (follow) return { kind: 'follow', articleId: Number(follow[1]) };

  const listen = route.match(/^\/listen\/(\d+)/);
  if (listen) return { kind: 'listen', articleId: Number(listen[1]) };

  const chat = route.match(/^\/chat\/(\d+)/);
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
