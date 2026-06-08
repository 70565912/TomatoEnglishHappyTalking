import { FormEvent, ReactNode, useEffect, useMemo, useRef, useState } from 'react';
import { onNativeEvent, sendNative } from './bridge';
import { splitSentences } from './sentenceSplitter';
import type {
  Article,
  ChatState,
  FollowState,
  ListeningItem,
  ListeningMode,
  ListeningOpenPayload,
  ListeningPausePayload,
  ListeningResumePayload,
  ListeningTranslationsPayload,
  PictureBookPage,
  PictureBookPageImagePayload,
  PictureBookState,
  VoicePreviewPayload,
  WordLookupPayload,
  WordPlaybackPayload,
  SettingsState,
  StorySeries,
} from './types';
import './styles.css';

const sampleText = 'Tom is on a space trip. He sees a bright snack box. It looks like a snack box! Tom opens it slowly.';

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
  const [series, setSeries] = useState<StorySeries[]>([]);
  const [notice, setNotice] = useState<string | null>(null);
  const pictureBookRetryGate = usePictureBookRetryGate();

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

    return () => {
      isMounted = false;
      offArticles();
      offFollow();
      offPictureBook();
      offChat();
      offSettings();
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
            onNavigate={navigate}
            onDelete={async (articleId) => {
              const payload = await sendNative<{ articles: Article[] }>(
                'article.delete',
                { articleId },
              );
              setArticles(payload.articles);
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
          <SettingsPage settings={settings} onLoaded={setSettings} />
        )}
      </main>
    </div>
  );
}

function HomePage({
  articles,
  series,
  latestArticle,
  onNavigate,
  onDelete,
}: {
  articles: Article[];
  series: StorySeries[];
  latestArticle?: Article;
  onNavigate: (path: string) => void;
  onDelete: (articleId: number) => Promise<void>;
}) {
  const [selectedBookKey, setSelectedBookKey] = useState<string | null>(null);
  const [chapterPage, setChapterPage] = useState(0);
  const [chapterOrder, setChapterOrder] = useState<ChapterOrder>('asc');
  const totalSentences = articles.reduce((sum, article) => sum + article.sentenceCount, 0);
  const averageScore =
    articles.length === 0
      ? 0
      : Math.round(
          articles.reduce((sum, article) => sum + article.averageScore, 0) /
            articles.length,
        );
  const books = useMemo(() => bookGroupsForArticles(articles, series), [articles, series]);
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
    if (selectedBookKey && !books.some((book) => book.key === selectedBookKey)) {
      setSelectedBookKey(null);
      setChapterPage(0);
    }
  }, [books, selectedBookKey]);

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
            <button className="primary-action" onClick={() => onNavigate(latestArticle ? `/follow/${latestArticle.id}` : '/article/new')}>
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
                <button
                  className={`book-card ${book.key === selectedBookKey ? 'active' : ''}`}
                  key={book.key}
                  type="button"
                  onClick={() => {
                    setSelectedBookKey(book.key);
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
                      onListen={() => onNavigate(`/listen/${article.id}`)}
                      onFollow={() => onNavigate(`/follow/${article.id}`)}
                      onChat={() => onNavigate(`/chat/${article.id}`)}
                      onDelete={() => onDelete(article.id)}
                    />
                  ))}
                </div>
              </section>
            )}
          </>
        )}
      </section>
    </section>
  );
}

type ChapterOrder = 'asc' | 'desc';

type BookGroup = {
  key: string;
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
    .filter((group) => group.articles.length > 0)
    .sort((a, b) => latestArticleTime(b.articles) - latestArticleTime(a.articles));
}

function sortBookChapters(articles: Article[], order: ChapterOrder): Article[] {
  const sorted = [...articles].sort((a, b) => {
    const aOrder = chapterSortValue(a);
    const bOrder = chapterSortValue(b);
    if (aOrder !== bOrder) return aOrder - bOrder;
    return a.title.localeCompare(b.title, undefined, { numeric: true, sensitivity: 'base' });
  });
  return order === 'asc' ? sorted : sorted.reverse();
}

function chapterSortValue(article: Article): number {
  if (typeof article.chapterOrder === 'number' && Number.isFinite(article.chapterOrder)) {
    return article.chapterOrder;
  }
  const titleNumber = article.title.match(/(?:chapter|episode|ep|e|第)\s*(\d+)/i)?.[1];
  if (titleNumber) return Number(titleNumber);
  return article.id;
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
  const canSave = Boolean(content.trim()) && !saving;

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
    setContent(cleaned.slice(0, 5000));
    setError(null);
  };

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (!content.trim()) {
      setError('请先填写文章内容');
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
              maxLength={5000}
              placeholder={sampleText}
              onChange={(event) => {
                setContent(event.target.value);
                setError(null);
              }}
            />
            <small>{content.length}/5000</small>
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
}: {
  articleId: number;
  pictureBookState: PictureBookState | null;
  onNavigate: (path: string) => void;
  onPictureBookLoaded: PictureBookStateSetter;
  pictureBookRetryGate: PictureBookRetryGate;
}) {
  const [article, setArticle] = useState<Article | null>(null);
  const [items, setItems] = useState<ListeningItem[]>([]);
  const [mode, setMode] = useState<ListeningMode>('english');
  const [status, setStatus] = useState<ListeningStatus>('loading');
  const [currentIndex, setCurrentIndex] = useState(0);
  const [activePart, setActivePart] = useState<ListeningPart>(null);
  const [error, setError] = useState<string | null>(null);
  const [wordCard, setWordCard] = useState<WordCardState | null>(null);
  const playbackTokenRef = useRef(0);
  const wordCardTokenRef = useRef(0);

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
    wordCardTokenRef.current += 1;
    onPictureBookLoaded(loadingPictureBookState(articleId));

    const picturePromise = sendNative<PictureBookState>('pictureBook.state', { articleId })
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

    void Promise.allSettled([listeningPromise, picturePromise]);

    return () => {
      isMounted = false;
      playbackTokenRef.current += 1;
      wordCardTokenRef.current += 1;
      void sendNative('listening.stop').catch(() => undefined);
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
          const translated = translationMap.get(item.index);
          return translated ? { ...item, chinese: translated } : item;
        }),
      );
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

  const prepareListeningPart = (
    item: ListeningItem | undefined,
    part: Exclude<ListeningPart, null>,
  ) => {
    if (!item) return;
    const text = part === 'english' ? item.english : item.chinese;
    if (!text.trim()) return;
    void sendNative('listening.prepare', {
      text,
      index: item.index,
      part,
    }).catch(() => undefined);
  };

  const prepareListeningItem = (index: number, selectedMode: ListeningMode) => {
    const item = items[index];
    if (!item) return;
    prepareListeningPart(item, 'english');
    if (selectedMode === 'bilingual') {
      prepareListeningPart(item, 'chinese');
    }
  };

  const playFrom = async (startIndex: number, singleItem = false) => {
    if (items.length === 0 || isListeningBusy(status)) return;

    const token = ++playbackTokenRef.current;
    const safeStart = Math.max(0, Math.min(startIndex, items.length - 1));
    const finalIndex = singleItem ? safeStart : items.length - 1;
    const selectedMode = mode;

    setStatus('playing');
    setError(null);
    setActivePart(null);
    prepareListeningItem(safeStart, selectedMode);
    if (!singleItem) prepareListeningItem(safeStart + 1, selectedMode);

    try {
      for (let index = safeStart; index <= finalIndex; index += 1) {
        const item = items[index];
        if (!singleItem) prepareListeningItem(index + 1, selectedMode);
        setCurrentIndex(index);
        setActivePart('english');
        await sendNative('listening.play', {
          text: item.english,
          index,
          part: 'english',
        });
        if (playbackTokenRef.current !== token) return;

        if (selectedMode === 'bilingual' && item.chinese.trim()) {
          setActivePart('chinese');
          await sendNative('listening.play', {
            text: item.chinese,
            index,
            part: 'chinese',
          });
          if (playbackTokenRef.current !== token) return;
        }
      }

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

  const picturePage = currentPictureBookPage(pictureBookState, currentIndex);
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
          <PictureBookScene
            state={pictureBookState}
            page={picturePage}
            english={currentItem?.english ?? '正在准备句子...'}
            chinese={currentItem?.chinese}
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
            </div>
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
                  <span>
                    <strong className={active && activePart === 'english' ? 'playing-text' : undefined}>
                      {item.english}
                    </strong>
                    <small className={active && activePart === 'chinese' ? 'playing-text' : undefined}>
                      {item.chinese}
                    </small>
                  </span>
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
    </section>
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
}: {
  articleId: number;
  state: FollowState | null;
  pictureBookState: PictureBookState | null;
  onNavigate: (path: string) => void;
  onLoaded: (state: FollowState) => void;
  onPictureBookLoaded: PictureBookStateSetter;
  pictureBookRetryGate: PictureBookRetryGate;
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
        sendNative<PictureBookState>('pictureBook.state', { articleId })
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
      {page && (state?.pages.length ?? 0) > 1 && (
        <span className="picture-book-page-badge">{page.pageIndex + 1}</span>
      )}
      {showSubtitles && (
        <div className="picture-book-subtitles">
          <h1 className={englishActive ? 'playing-text' : undefined} aria-label={english}>
            <ClickableEnglishText
              text={english}
              sentence={english}
              onWordClick={onWordClick}
            />
          </h1>
          {chinese && <p className={chineseActive ? 'playing-text' : undefined}>{chinese}</p>}
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
    const picturePromise = sendNative<PictureBookState>('pictureBook.state', { articleId })
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

function MissionRow({
  article,
  imageSrc,
  onListen,
  onFollow,
  onChat,
  onDelete,
}: {
  article: Article;
  imageSrc: string;
  onListen: () => void;
  onFollow: () => void;
  onChat: () => void;
  onDelete: () => void;
}) {
  const score = article.averageScore > 0 ? Math.round(article.averageScore) : 40;
  return (
    <article className="mission-row">
      <button
        className="mission-cover-button"
        type="button"
        onClick={onFollow}
        aria-label={`进入《${article.title}》跟读`}
      >
        <img src={imageSrc} alt="" />
      </button>
      <div>
        <h3>
          <button type="button" className="mission-title-button" onClick={onFollow}>
            {article.title}
          </button>
        </h3>
        <p>{article.sentenceCount} 句子 · 最近学习 今天</p>
      </div>
      <span className="ring-score">{score}%</span>
      <button className="primary-action" onClick={onFollow}><Icon name="mic" /> 跟读</button>
      <button className="purple-action" onClick={onChat}><Icon name="chat" /> 对话</button>
      <button className="listen-action" onClick={onListen}><Icon name="sound" /> 听力</button>
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
  stop: <path d="M7 7h10v10H7z" />,
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
