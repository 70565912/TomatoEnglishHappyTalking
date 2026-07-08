import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import App from './App';
import { splitSentences } from './sentenceSplitter';
import type { Article, BridgeResponse, ListeningSongStatePayload, StorySeries } from './types';

async function clickSelectedCreationAction(name: string | RegExp) {
  await screen.findByText('章节列表');
  const actions = await waitFor(() => {
    const element = document.querySelector('.mission-row.active .mission-actions');
    expect(element).not.toBeNull();
    return element as HTMLElement;
  });
  fireEvent.click(within(actions).getByRole('button', { name }));
}

function chooseRecordingOption(dialog: HTMLElement, label: string, option: string) {
  fireEvent.click(within(dialog).getByRole('button', { name: new RegExp(label) }));
  fireEvent.click(within(dialog).getByRole('option', { name: option }));
}

async function findConfirmDialog(ariaLabel: string, message?: string | RegExp) {
  const dialog = await screen.findByRole('dialog', { name: ariaLabel });
  if (message) {
    expect(within(dialog).getByText(message)).toBeInTheDocument();
  }
  return dialog;
}

async function cancelConfirmDialog(ariaLabel: string, message?: string | RegExp) {
  const dialog = await findConfirmDialog(ariaLabel, message);
  fireEvent.click(within(dialog).getByRole('button', { name: '取消' }));
  await waitFor(() => {
    expect(screen.queryByRole('dialog', { name: ariaLabel })).not.toBeInTheDocument();
  });
}

async function confirmDialogAction(
  ariaLabel: string,
  confirmButtonName: string | RegExp,
  message?: string | RegExp,
) {
  const dialog = await findConfirmDialog(ariaLabel, message);
  fireEvent.click(within(dialog).getByRole('button', { name: confirmButtonName }));
}

function promptReviewPayloadForTest(articleId = 1, regenerate = false) {
  const scenes = [
    {
      pageIndex: 0,
      sentenceStartIndex: 0,
      sentenceEndIndex: 0,
      paragraphText: 'Tom finds a bright snack box.',
      sceneDescription: 'Tom discovers the snack box.',
    },
  ];
  return {
    reviewId: `review-${articleId}`,
    articleId,
    chapterId: 1,
    seriesId: 1,
    bookTitle: 'Space Story Series',
    regenerate,
    bookDescription: 'A warm space picture book; Tom is a curious child in a red hoodie.',
    chapterDescription:
      'Tom explores small discoveries with a friendly team and finds a bright snack box.',
    groupPrompt: `Book name: Space Story Series\nBook description: A warm space picture book; Tom is a curious child in a red hoodie.\nChapter description: Tom explores small discoveries with a friendly team and finds a bright snack box.\n\nImage 1:\nScene description: ${scenes[0].sceneDescription}`,
    scenes,
    createdAt: new Date().toISOString(),
  };
}

function expectElementBefore(first: HTMLElement, second: HTMLElement) {
  expect(first.compareDocumentPosition(second) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
}

function installChapterOrderBridge(articles: Article[], series: StorySeries[]) {
  const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
    id: String(id),
    ok: true,
    type: `${type}.result`,
    payload,
  });

  window.flutter_inappwebview = {
    callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
      const type = String(message.type ?? '');
      const payload = (message.payload ?? {}) as Record<string, unknown>;
      if (type === 'app.ready' || type === 'article.list' || type === 'series.list') {
        return ok(message.id, type, { articles, series });
      }
      if (type === 'listening.open') {
        const articleId = Number(payload.articleId ?? articles[0]?.id);
        const article = articles.find((item) => item.id === articleId) ?? articles[0];
        return ok(message.id, type, {
          article,
          items: [{ index: 0, english: article.sentences[0], chinese: '' }],
        });
      }
      if (type === 'pictureBook.state') {
        return ok(message.id, type, {
          articleId: payload.articleId,
          enabled: true,
          status: 'ready',
          pages: [],
        });
      }
      if (type === 'listening.audioStatus') {
        return ok(message.id, type, {
          articleId: payload.articleId,
          total: 1,
          ready: 1,
          missing: [],
          status: 'ready',
        });
      }
      if (type === 'recording.videoList') {
        return ok(message.id, type, { articleId: payload.articleId, versions: [] });
      }
      return ok(message.id, type, {});
    }),
  };
}

function chapterOrderFixture() {
  const now = new Date().toISOString();
  const alphaArticle: Article = {
    id: 1,
    title: 'Z Last Alpha',
    content: 'Alpha starts.',
    sentences: ['Alpha starts.'],
    sentenceCount: 1,
    createdAt: '2026-06-10T10:00:00.000Z',
    averageScore: 80,
    seriesId: 1,
    seriesTitle: 'Alpha Book',
  };
  const betaTwo: Article = {
    id: 2,
    title: 'E2 - Beta',
    content: 'Beta two.',
    sentences: ['Beta two.'],
    sentenceCount: 1,
    createdAt: now,
    averageScore: 90,
    seriesId: 2,
    seriesTitle: 'Beta Book',
  };
  const betaTen: Article = {
    ...betaTwo,
    id: 3,
    title: 'E10 - Beta',
    content: 'Beta ten.',
    sentences: ['Beta ten.'],
    createdAt: '2026-06-09T10:00:00.000Z',
  };
  const series: StorySeries[] = [
    {
      id: 1,
      title: 'Alpha Book',
      description: '',
      coverImagePath: null,
      createdAt: now,
      updatedAt: now,
    },
    {
      id: 2,
      title: 'Beta Book',
      description: '',
      coverImagePath: null,
      createdAt: now,
      updatedAt: now,
    },
  ];

  return { articles: [alphaArticle, betaTen, betaTwo], betaTen, betaTwo, series };
}

describe('App', () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
    cleanup();
    window.location.hash = '';
    window.localStorage.clear();
    delete window.flutter_inappwebview;
  });

  it('renders the book library shell', async () => {
    window.location.hash = '/';

    render(<App />);

    expect(await screen.findByText('书库、绘本和章节听力工作台')).toBeInTheDocument();
    expect(await screen.findByText('我的书籍')).toBeInTheDocument();
    expect((await screen.findAllByText('Space Story Series')).length).toBeGreaterThan(0);
    expect(await screen.findByText('Tomato')).toBeInTheDocument();
    expect(await screen.findByText('English')).toBeInTheDocument();
    expect(await screen.findByText('Happy Talking')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '书库' })).toBeInTheDocument();
    expect(screen.getAllByRole('button', { name: '新增章节' }).length).toBeGreaterThan(0);
    expect(screen.getByRole('button', { name: '创作中心' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '练习中心' })).toBeInTheDocument();
    expect(screen.queryByText('任务卡')).not.toBeInTheDocument();
    fireEvent.click(screen.getAllByRole('button', { name: /Space Story Series/ })[0]);
    expect(await screen.findByText('章节目录')).toBeInTheDocument();
    expect(screen.getByText('跟读')).toBeInTheDocument();
    expect(screen.getByText('对话')).toBeInTheDocument();
    expect(screen.getByText('听力')).toBeInTheDocument();
    expect(screen.queryByText('听全文')).not.toBeInTheDocument();
  });

  it('opens listening from default article entries and keeps follow explicit', async () => {
    const article = {
      id: 88,
      title: 'E28 Tail Story',
      content: 'Alice walks back to the garden.',
      sentences: ['Alice walks back to the garden.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 72,
      pictureBookEnabled: true,
      seriesId: 7,
      seriesTitle: "Alice's Adventures in Wonderland",
      chapterOrder: 28,
    };
    const series = [
      {
        id: 7,
        title: "Alice's Adventures in Wonderland",
        description: '',
        coverImagePath: null,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      },
    ];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });
    const installBridge = () => {
      window.flutter_inappwebview = {
        callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
          const type = String(message.type ?? '');
          if (type === 'app.ready' || type === 'article.list') {
            return ok(message.id, type, { articles: [article], series });
          }
          if (type === 'listening.open') {
            return ok(message.id, type, {
              article,
              items: [{ index: 0, english: article.sentences[0], chinese: '' }],
            });
          }
          if (type === 'follow.open') {
            return ok(message.id, type, {
              article,
              currentIndex: 0,
              currentSentence: article.sentences[0],
              step: 'idle',
              playbackState: 'idle',
              isRecording: false,
              hasRecording: false,
              result: null,
              translations: {},
            });
          }
          if (type === 'pictureBook.state') {
            return ok(message.id, type, {
              articleId: article.id,
              enabled: true,
              status: 'empty',
              pages: [],
            });
          }
          return ok(message.id, type, {});
        }),
      };
    };

    window.location.hash = '/';
    installBridge();
    render(<App />);
    fireEvent.click(await screen.findByRole('button', { name: /继续听力/ }));
    await waitFor(() => expect(window.location.hash).toBe('#/books/7/player?articleId=88&mode=listening'));

    cleanup();
    window.location.hash = '/';
    installBridge();
    render(<App />);
    fireEvent.click(await screen.findByRole('button', { name: /Alice's Adventures in Wonderland/ }));
    await waitFor(() => expect(window.location.hash).toBe('#/books/7'));

    cleanup();
    window.location.hash = '/';
    installBridge();
    render(<App />);
    fireEvent.click(await screen.findByRole('button', { name: /Alice's Adventures in Wonderland/ }));
    fireEvent.click(await screen.findByRole('button', { name: '进入《E28 Tail Story》听力' }));
    await waitFor(() => expect(window.location.hash).toBe('#/books/7/player?articleId=88&mode=listening'));

    cleanup();
    window.location.hash = '/';
    installBridge();
    render(<App />);
    fireEvent.click(await screen.findByRole('button', { name: /Alice's Adventures in Wonderland/ }));
    fireEvent.click(await screen.findByRole('button', { name: '跟读' }));
    await waitFor(() => expect(window.location.hash).toBe('#/follow/88'));
  });

  it('keeps the book player chapter list in a right-side drawer', async () => {
    window.location.hash = '/books/7/player?articleId=88&mode=listening';
    const articles = [
      {
        id: 88,
        title: 'E28 Tail Story',
        content: 'Alice walks back to the garden.',
        sentences: ['Alice walks back to the garden.'],
        sentenceCount: 1,
        createdAt: new Date().toISOString(),
        averageScore: 72,
        pictureBookEnabled: true,
        seriesId: 7,
        seriesTitle: "Alice's Adventures in Wonderland",
        chapterOrder: 28,
      },
      {
        id: 89,
        title: 'E29 Next Story',
        content: 'Alice follows the path.',
        sentences: ['Alice follows the path.'],
        sentenceCount: 1,
        createdAt: new Date().toISOString(),
        averageScore: 80,
        pictureBookEnabled: true,
        seriesId: 7,
        seriesTitle: "Alice's Adventures in Wonderland",
        chapterOrder: 29,
      },
    ];
    const series = [
      {
        id: 7,
        title: "Alice's Adventures in Wonderland",
        description: '',
        coverImagePath: null,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      },
    ];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles, series });
        }
        if (type === 'listening.open') {
          const articleId = Number(payload.articleId ?? 88);
          const article = articles.find((item) => item.id === articleId) ?? articles[0];
          return ok(message.id, type, {
            article,
            items: [{ index: 0, english: article.sentences[0], chinese: '' }],
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: payload.articleId,
            enabled: true,
            status: 'empty',
            pages: [],
          });
        }
        return ok(message.id, type, {});
      }),
    };

    const { container } = render(<App />);

    expect(await screen.findByText('E28 Tail Story')).toBeInTheDocument();
    expect(container.querySelector('.book-player-strip')).not.toBeInTheDocument();
    expect(screen.queryByRole('dialog', { name: /章节列表/ })).not.toBeInTheDocument();
    expect(screen.queryByLabelText(/播放队列/)).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: '章节' }));
    const drawer = await screen.findByRole('dialog', { name: /章节列表/ });
    expect(within(drawer).getByText("Alice's Adventures in Wonderland")).toBeInTheDocument();
    fireEvent.click(within(drawer).getByRole('button', { name: /E29 Next Story/ }));

    await waitFor(() => expect(window.location.hash).toBe('#/books/7/player?articleId=89&mode=listening'));
    await waitFor(() => expect(screen.queryByRole('dialog', { name: /章节列表/ })).not.toBeInTheDocument());
  });

  it('restores the recent book and sorts chapters by title', async () => {
    window.location.hash = '/';
    window.localStorage.setItem('tomato.recentSeriesKey.v1', 'series:2');
    const { articles, series } = chapterOrderFixture();
    installChapterOrderBridge(articles, series);

    render(<App />);

    expect(await screen.findByLabelText('Beta Book 章节列表')).toBeInTheDocument();
    const betaTwoButton = screen.getByRole('button', { name: 'E2 - Beta' });
    const betaTenButton = screen.getByRole('button', { name: 'E10 - Beta' });
    expectElementBefore(betaTwoButton, betaTenButton);
    expect(screen.getByRole('button', { name: /正序/ })).toBeInTheDocument();
    expect(window.localStorage.getItem('tomato.chapterOrder.v1')).toBeNull();
    expect(window.localStorage.getItem('tomato.recentSeriesKey.v1')).toBe('series:2');
  });

  it('persists chapter order across library, centers, details, and player drawer', async () => {
    const { articles, series } = chapterOrderFixture();
    installChapterOrderBridge(articles, series);
    window.localStorage.setItem('tomato.recentSeriesKey.v1', 'series:2');
    window.location.hash = '/';
    render(<App />);

    expect(await screen.findByLabelText('Beta Book 章节列表')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /正序/ }));
    expect(window.localStorage.getItem('tomato.chapterOrder.v1')).toBe('desc');
    expectElementBefore(
      screen.getByRole('button', { name: 'E10 - Beta' }),
      screen.getByRole('button', { name: 'E2 - Beta' }),
    );

    cleanup();
    window.location.hash = '/practice?seriesId=2';
    installChapterOrderBridge(articles, series);
    render(<App />);
    expect((await screen.findAllByText('练习中心')).length).toBeGreaterThan(0);
    expect(await screen.findByRole('button', { name: /倒序/ })).toBeInTheDocument();
    expectElementBefore(
      screen.getByRole('button', { name: 'E10 - Beta' }),
      screen.getByRole('button', { name: 'E2 - Beta' }),
    );

    cleanup();
    window.location.hash = '/books/2';
    installChapterOrderBridge(articles, series);
    render(<App />);
    const detailList = await screen.findByLabelText('Beta Book 章节列表');
    expect(within(detailList).getByRole('button', { name: /倒序/ })).toBeInTheDocument();
    expectElementBefore(
      within(detailList).getByText('E10 - Beta'),
      within(detailList).getByText('E2 - Beta'),
    );

    cleanup();
    window.location.hash = '/creation?seriesId=2';
    installChapterOrderBridge(articles, series);
    render(<App />);
    expect((await screen.findAllByText('创作中心')).length).toBeGreaterThan(0);
    expect(await screen.findByRole('button', { name: /倒序/ })).toBeInTheDocument();
    expectElementBefore(
      screen.getByRole('button', { name: 'E10 - Beta' }),
      screen.getByRole('button', { name: 'E2 - Beta' }),
    );

    cleanup();
    window.location.hash = '/books/2/player?articleId=3&mode=listening';
    installChapterOrderBridge(articles, series);
    render(<App />);
    expect(await screen.findByText('E10 - Beta')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '章节' }));
    const drawer = await screen.findByRole('dialog', { name: /章节列表/ });
    expectElementBefore(
      within(drawer).getByRole('button', { name: /E10 - Beta/ }),
      within(drawer).getByRole('button', { name: /E2 - Beta/ }),
    );
  });

  it('falls back to ascending chapter order for invalid stored values', async () => {
    window.location.hash = '/';
    window.localStorage.setItem('tomato.recentSeriesKey.v1', 'series:2');
    window.localStorage.setItem('tomato.chapterOrder.v1', 'sideways');
    const { articles, series } = chapterOrderFixture();
    installChapterOrderBridge(articles, series);

    render(<App />);

    expect(await screen.findByLabelText('Beta Book 章节列表')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /正序/ })).toBeInTheDocument();
    expectElementBefore(
      screen.getByRole('button', { name: 'E2 - Beta' }),
      screen.getByRole('button', { name: 'E10 - Beta' }),
    );
  });

  it('opens the practice center at the requested book', async () => {
    window.location.hash = '/practice?seriesId=2';
    const now = new Date().toISOString();
    const alphaArticle = {
      id: 1,
      title: 'Alpha Chapter',
      content: 'Alpha starts.',
      sentences: ['Alpha starts.'],
      sentenceCount: 1,
      createdAt: now,
      averageScore: 80,
      seriesId: 1,
      seriesTitle: 'Alpha Book',
    };
    const betaArticle = {
      id: 2,
      title: 'Beta Practice Chapter',
      content: 'Beta starts.',
      sentences: ['Beta starts.'],
      sentenceCount: 1,
      createdAt: now,
      averageScore: 92,
      seriesId: 2,
      seriesTitle: 'Beta Book',
    };
    const series = [
      {
        id: 1,
        title: 'Alpha Book',
        description: '',
        coverImagePath: null,
        createdAt: now,
        updatedAt: now,
      },
      {
        id: 2,
        title: 'Beta Book',
        description: '',
        coverImagePath: null,
        createdAt: now,
        updatedAt: now,
      },
    ];

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => ({
        id: String(message.id),
        ok: true,
        type: `${String(message.type)}.result`,
        payload: { articles: [alphaArticle, betaArticle], series },
      })),
    };

    render(<App />);

    expect((await screen.findAllByText('练习中心')).length).toBeGreaterThan(0);
    expect(await screen.findByText('我的书籍')).toBeInTheDocument();
    expect(await screen.findByText('章节列表')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Alpha Book/ })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Beta Book/ })).toBeInTheDocument();
    expect(await screen.findByText('Beta Practice Chapter')).toBeInTheDocument();
    const listeningButton = screen.getByRole('button', { name: '听力' });
    const followButton = screen.getByRole('button', { name: '跟读' });
    const chatButton = screen.getByRole('button', { name: '对话' });
    const videoButton = screen.getByRole('button', { name: '视频' });
    expect(listeningButton).toBeInTheDocument();
    expect(followButton).toBeInTheDocument();
    expect(chatButton).toBeInTheDocument();
    expect(videoButton).toBeDisabled();
    expect(listeningButton.compareDocumentPosition(followButton) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(followButton.compareDocumentPosition(chatButton) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(chatButton.compareDocumentPosition(videoButton) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(screen.queryByRole('button', { name: '删除' })).not.toBeInTheDocument();
    expect(screen.queryByText('Alpha Chapter')).not.toBeInTheDocument();

    const collapseToggle = screen.getByRole('button', { name: '折叠章节列表' });
    expect(collapseToggle).toHaveTextContent('∨');
    fireEvent.click(collapseToggle);
    expect(await screen.findByText('章节列表已折叠')).toBeInTheDocument();
    expect(screen.queryByText('Beta Practice Chapter')).not.toBeInTheDocument();
    const expandToggle = screen.getByRole('button', { name: '展开章节列表' });
    expect(expandToggle).toHaveTextContent('＞');
    fireEvent.click(expandToggle);
    expect(await screen.findByText('Beta Practice Chapter')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: /Alpha Book/ }));
    expect(await screen.findByText('Alpha Chapter')).toBeInTheDocument();
    expect(screen.queryByText('Beta Practice Chapter')).not.toBeInTheDocument();
  });

  it('plays the default exported video from the practice center', async () => {
    window.location.hash = '/practice?seriesId=7';
    const now = new Date().toISOString();
    const article = {
      id: 21,
      title: 'Video Ready Chapter',
      content: 'Alice follows the rabbit.',
      sentences: ['Alice follows the rabbit.'],
      sentenceCount: 1,
      createdAt: now,
      averageScore: 91,
      seriesId: 7,
      seriesTitle: 'Video Book',
    };
    const series = [
      {
        id: 7,
        title: 'Video Book',
        description: 'Book with exported videos.',
        coverImagePath: null,
        createdAt: now,
        updatedAt: now,
      },
    ];
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series });
        }
        if (type === 'recording.videoList') {
          return ok(message.id, type, {
            articleId: article.id,
            outputDirectory: 'F:\\Tomato\\recording-export',
            versions: [
              {
                id: 'video-default',
                articleId: article.id,
                videoPath: 'F:\\Tomato\\recording-export\\video-default.mp4',
                subtitlePath: 'F:\\Tomato\\recording-export\\video-default.srt',
                createdAt: '2026-06-17T05:07:00.000Z',
                source: 'listening',
                title: 'Default Video',
                isDefault: true,
                durationMs: 3200,
                codec: 'h264',
                resolution: '1920x1080',
              },
            ],
          });
        }
        if (type === 'recording.videoPlay') {
          return ok(message.id, type, {
            played: true,
            articleId: article.id,
            videoId: payload.videoId,
            videoPath: 'F:\\Tomato\\recording-export\\video-default.mp4',
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByText('Video Ready Chapter')).toBeInTheDocument();
    const videoButton = await screen.findByRole('button', { name: '视频' });
    await waitFor(() => expect(videoButton).not.toBeDisabled());
    fireEvent.click(videoButton);

    await waitFor(() => {
      expect(calls.some((call) =>
        call.type === 'recording.videoPlay' &&
        call.payload.articleId === article.id &&
        call.payload.videoId === 'video-default',
      )).toBe(true);
    });
  });

  it('edits article titles only from the creation center list', async () => {
    window.location.hash = '/';
    const now = new Date().toISOString();
    const article = {
      id: 5,
      title: 'Old Title',
      content: 'Alice looks at the garden.',
      sentences: ['Alice looks at the garden.'],
      sentenceCount: 1,
      createdAt: now,
      averageScore: 90,
      seriesId: 2,
      seriesTitle: 'Alice Series',
    };
    const renamedArticle = { ...article, title: 'New Title' };
    const series = [
      {
        id: 2,
        title: 'Alice Series',
        description: '',
        coverImagePath: null,
        createdAt: now,
        updatedAt: now,
      },
    ];
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series });
        }
        if (type === 'article.rename') {
          return ok(message.id, type, { article: renamedArticle, articles: [renamedArticle], series });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    await screen.findByText('Old Title');
    expect(screen.queryByRole('button', { name: '修改《Old Title》标题' })).not.toBeInTheDocument();

    cleanup();
    window.location.hash = '/creation?articleId=5&seriesId=2';
    render(<App />);

    fireEvent.click(await screen.findByRole('button', { name: '修改《Old Title》标题' }));
    const dialog = await screen.findByRole('dialog', { name: '修改文章标题' });
    expect(dialog.closest('.edit-dialog-backdrop')?.parentElement).toBe(document.body);
    const titleInput = await screen.findByLabelText('标题');
    fireEvent.change(titleInput, { target: { value: 'New Title' } });
    fireEvent.click(screen.getByRole('button', { name: /保存/ }));

    await waitFor(() => {
      expect(calls.find((call) => call.type === 'article.rename')?.payload).toMatchObject({
        articleId: 5,
        title: 'New Title',
      });
    });
    expect(await screen.findByRole('button', { name: 'New Title' })).toBeInTheDocument();
  });

  it('prefers generated picture-book covers in book and mission cards', async () => {
    window.location.hash = '/';
    const generatedCover = 'data:image/png;base64,AAAA';
    const article = {
      id: 77,
      title: 'Generated Cover Story',
      content: 'Mia opens a map and smiles.',
      sentences: ['Mia opens a map and smiles.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 64,
      coverImageUri: generatedCover,
      coverImagePath: null,
      pictureBookEnabled: true,
      seriesId: 7,
      seriesTitle: 'Generated Series',
      chapterOrder: 1,
    };
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });
    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series: [] });
        }
        return ok(message.id, type, {});
      }),
    };

    const { container } = render(<App />);

    expect(await screen.findByText('Generated Series')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /Generated Series/ }));
    expect(await screen.findByText('章节列表')).toBeInTheDocument();
    expect(await screen.findByText('Generated Cover Story')).toBeInTheDocument();
    const imageSources = Array.from(container.querySelectorAll('.book-card img, .mission-row img')).map((img) =>
      img.getAttribute('src'),
    );
    expect(imageSources).toEqual([generatedCover, generatedCover]);
  });

  it('renders settings with masked cloud key controls', async () => {
    window.location.hash = '/settings';

    render(<App />);

    expect(await screen.findByText('选择番茄助教的发音')).toBeInTheDocument();
    expect(await screen.findByText('发音人')).toBeInTheDocument();
    expect(screen.getByRole('listbox', { name: '可选声音' })).toBeInTheDocument();
    expect(screen.queryByText('视频导出')).not.toBeInTheDocument();
    expect(screen.queryByLabelText('编码')).not.toBeInTheDocument();
    expect(screen.queryByLabelText('分辨率')).not.toBeInTheDocument();
    expect(screen.queryByLabelText('转场')).not.toBeInTheDocument();
    expect(screen.queryByText('ffmpeg.exe 路径')).not.toBeInTheDocument();
    expect(screen.getAllByText('Abby').length).toBeGreaterThan(0);
    expect(screen.getAllByRole('button', { name: /预览/ }).length).toBeGreaterThan(0);
    expect(screen.getByText(/个发音人/)).toBeInTheDocument();
    expect(screen.getByText('当前声音')).toBeInTheDocument();
    expect(screen.getByText('内容安全规则')).toBeInTheDocument();
    expect(screen.getByText('heads')).toBeInTheDocument();
    expect(screen.getByText('he-ads')).toBeInTheDocument();
    expect(screen.queryByText('服务状态（运行时）')).not.toBeInTheDocument();
    expect(screen.queryByText('TTS 语音合成')).not.toBeInTheDocument();
    expect(screen.queryByText('TTS 资源 ID')).not.toBeInTheDocument();
    expect(screen.queryByText('火山引擎 API Key')).not.toBeInTheDocument();
    expect(screen.queryByPlaceholderText(/api key/i)).not.toBeInTheDocument();
    expect(screen.queryByRole('checkbox', { name: /清除百炼 Key/ })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: /清除百炼 Key/ })).toBeInTheDocument();
  }, 10000);

  it('keeps the API key reveal control available after toggling visibility', async () => {
    window.location.hash = '/settings';

    render(<App />);

    const bailianKeyInput = (await screen.findByLabelText(/^百炼 Key/)) as HTMLInputElement;
    const field = bailianKeyInput.closest('.settings-label') as HTMLElement;
    const revealButton = within(field).getByRole('button', { name: '显示 Key' });

    expect(bailianKeyInput).toHaveAttribute('type', 'password');
    expect(revealButton).toBeDisabled();

    fireEvent.change(bailianKeyInput, { target: { value: 'dashscope-test-key' } });
    expect(revealButton).not.toBeDisabled();

    fireEvent.click(revealButton);
    expect(bailianKeyInput).toHaveAttribute('type', 'text');
    expect(bailianKeyInput).toHaveValue('dashscope-test-key');
    expect(within(field).getByRole('button', { name: '隐藏 Key' })).toBeInTheDocument();

    fireEvent.click(within(field).getByRole('button', { name: '隐藏 Key' }));
    expect(bailianKeyInput).toHaveAttribute('type', 'password');
    expect(within(field).getByRole('button', { name: '显示 Key' })).toBeInTheDocument();
  });

  it('shows split cloud capabilities and song provider tabs', async () => {
    window.location.hash = '/settings';

    render(<App />);

    expect(await screen.findByText('文本处理')).toBeInTheDocument();
    expect(screen.getByText('图片生成')).toBeInTheDocument();
    expect(screen.getByText('语音合成')).toBeInTheDocument();
    expect(screen.getByText('音乐生成模型')).toBeInTheDocument();
    expect(screen.getByRole('tab', { name: '阿里云百炼' })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByRole('tab', { name: '阿里云万相' })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByRole('tab', { name: '阿里云 CosyVoice' })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByLabelText(/^百炼 Key/)).toBeInTheDocument();
    expect(screen.queryAllByLabelText(/^百炼 Key/)).toHaveLength(1);
    expect(screen.getByText('百炼兼容模式 Base URL')).toBeInTheDocument();
    expect(screen.getByText('DashScope API Base URL')).toBeInTheDocument();
    expect(screen.getByText('ElevenLabs Base URL')).toBeInTheDocument();
    expect(screen.getByLabelText(/^ElevenLabs Key/)).toBeInTheDocument();
    expect(screen.queryByText('Key 操作')).not.toBeInTheDocument();
    expect(screen.getByText('方舟 Base URL')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('tab', { name: '火山引擎' }));
    expect(screen.getByRole('tab', { name: '火山引擎' })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByText('方舟文本模型')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('tab', { name: '火山 Seedream' }));
    expect(screen.getByRole('tab', { name: '火山 Seedream' })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByText('Seedream 图片模型')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('tab', { name: 'ElevenLabs' }));
    expect(screen.getByRole('tab', { name: 'ElevenLabs' })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByText('ElevenLabs TTS 模型')).toBeInTheDocument();
    expect(screen.getAllByText('George').length).toBeGreaterThan(0);
    expect(screen.getByLabelText(/^方舟 Key/)).toBeInTheDocument();
    expect(screen.getByLabelText(/^火山语音 Key/)).toBeInTheDocument();

    expect(screen.getByRole('tab', { name: 'Suno 网页自动化' })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByText('Suno 输出目录')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('tab', { name: '阿里云百聆' }));
    expect(screen.getByRole('tab', { name: '阿里云百聆' })).toHaveAttribute('aria-selected', 'true');
    expect(screen.queryByText('Suno 输出目录')).not.toBeInTheDocument();
    expect(screen.getAllByText('百聆音乐模型').length).toBeGreaterThan(0);
    fireEvent.click(screen.getByRole('tab', { name: 'ElevenLabs Music' }));
    expect(screen.getByRole('tab', { name: 'ElevenLabs Music' })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByText('音乐模型')).toBeInTheDocument();
    expect(screen.getByText('输出格式')).toBeInTheDocument();
  });

  it('starts the new article editor empty and enables save after real content and book title', async () => {
    window.location.hash = '/article/new';

    render(<App />);

    expect(await screen.findByText('新增文章')).toBeInTheDocument();

    const titleInput = screen.getByLabelText(/文章标题/);
    const bookTitleInput = screen.getByLabelText('新书籍名称');
    const contentInput = screen.getByLabelText(/文章内容/);
    const saveButton = screen.getByRole('button', { name: /保存章节/ });

    expect(titleInput).toHaveValue('');
    expect(contentInput).toHaveValue('');
    expect(saveButton).toBeDisabled();
    expect(screen.queryByRole('button', { name: /自动标题/ })).not.toBeInTheDocument();
    expect(screen.queryByRole('checkbox', { name: /生成英语绘本图/ })).not.toBeInTheDocument();
    expect(screen.getByLabelText('书籍')).toBeInTheDocument();
    expect(screen.queryByText('任务编辑台')).not.toBeInTheDocument();
    expect(screen.queryByText('短句越清楚，闯关越顺滑。')).not.toBeInTheDocument();
    expect(screen.getByText('输入短文后，这里会自动切成适合跟读的英文短句。')).toBeInTheDocument();

    fireEvent.change(contentInput, {
      target: {
        value: 'Tom opens a lunch box. He shares a red apple with Mia.',
      },
    });

    expect(saveButton).toBeDisabled();
    fireEvent.change(bookTitleInput, { target: { value: 'Lunch Box Stories' } });
    expect(saveButton).not.toBeDisabled();
    expect(titleInput).toHaveValue('');
    expect(screen.getByText('Tom opens a lunch box.')).toBeInTheDocument();

    fireEvent.click(saveButton);
    expect(await screen.findByRole('dialog', { name: '绘本提示词审核' })).toBeInTheDocument();
    expect((await screen.findAllByText('Opens Lunch Shares')).length).toBeGreaterThan(0);
  });

  it('can save a new book before saving the chapter', async () => {
    window.location.hash = '/article/new';
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });
    const savedSeries: StorySeries = {
      id: 77,
      title: 'Wonder Book',
      description: 'A bright storybook world with clear recurring visual anchors.',
      characters: [{ name: 'Alice', description: 'Blue dress and white pinafore.' }],
      coverImagePath: null,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list' || type === 'series.list') {
          return ok(message.id, type, { articles: [], series: [] });
        }
        if (type === 'series.create') {
          return ok(message.id, type, { articles: [], series: [savedSeries] });
        }
        if (type === 'article.create') {
          const article = {
            id: 101,
            title: 'Chapter One',
            content: String(payload.content ?? ''),
            sentences: ['Alice sees a door.'],
            sentenceCount: 1,
            createdAt: new Date().toISOString(),
            averageScore: 0,
            pictureBookEnabled: true,
            seriesId: 77,
            seriesTitle: savedSeries.title,
          };
          return ok(message.id, type, { article, articles: [article], series: [savedSeries] });
        }
        if (type === 'pictureBook.promptReview') {
          return ok(message.id, type, {
            reviewId: 'review-101',
            articleId: 101,
            regenerate: false,
            bookTitle: savedSeries.title,
            bookDescription: savedSeries.description,
            bookCharacters: savedSeries.characters,
            relevantCharacters: savedSeries.characters,
            newCharacters: [],
            chapterDescription: 'Alice sees a door.',
            groupPrompt: '',
            scenes: [],
            createdAt: new Date().toISOString(),
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    const bookTitleInput = await screen.findByLabelText('新书籍名称');
    const contentInput = screen.getByLabelText(/文章内容/);
    expect(screen.queryByLabelText('书籍简介')).not.toBeInTheDocument();
    fireEvent.change(bookTitleInput, { target: { value: savedSeries.title } });
    fireEvent.click(screen.getByRole('button', { name: savedSeries.title }));
    const descriptionInput = screen.getByLabelText('书籍简介');
    fireEvent.change(descriptionInput, { target: { value: savedSeries.description } });
    fireEvent.click(screen.getByRole('button', { name: '新增角色' }));
    fireEvent.change(screen.getByLabelText('书籍角色 1 名称'), { target: { value: 'Alice' } });
    fireEvent.change(screen.getByLabelText('书籍角色 1 描述'), {
      target: { value: 'Blue dress and white pinafore.' },
    });

    fireEvent.click(screen.getByRole('button', { name: /保存书籍/ }));

    await waitFor(() => {
      expect(calls.find((call) => call.type === 'series.create')?.payload).toMatchObject({
        title: savedSeries.title,
        description: savedSeries.description,
        characters: savedSeries.characters,
      });
    });
    expect(screen.queryByLabelText('新书籍名称')).not.toBeInTheDocument();

    fireEvent.change(contentInput, { target: { value: 'Alice sees a door.' } });
    fireEvent.click(screen.getByRole('button', { name: /保存章节/ }));

    await waitFor(() => {
      expect(calls.find((call) => call.type === 'article.create')?.payload).toMatchObject({
        seriesId: 77,
        seriesTitle: '',
        seriesDescription: savedSeries.description,
        seriesCharacters: savedSeries.characters,
      });
    });
  });

  it('rejects article content over 8000 characters without truncating it', async () => {
    window.location.hash = '/article/new';

    render(<App />);

    const bookTitleInput = await screen.findByLabelText('新书籍名称');
    const contentInput = screen.getByLabelText(/文章内容/);
    const saveButton = screen.getByRole('button', { name: /保存章节/ });
    const overLimitContent = 'a'.repeat(8001);

    fireEvent.change(contentInput, { target: { value: overLimitContent } });

    expect(contentInput).toHaveValue(overLimitContent);
    expect(screen.getByText('文章内容不能超过 8000 个字符')).toBeInTheDocument();
    expect(screen.getByText('8001/8000')).toBeInTheDocument();
    expect(saveButton).toBeDisabled();

    fireEvent.change(bookTitleInput, { target: { value: 'Long Text Book' } });
    fireEvent.change(contentInput, { target: { value: 'a'.repeat(8000) } });

    expect(screen.queryByText('文章内容不能超过 8000 个字符')).not.toBeInTheDocument();
    expect(screen.getByText('8000/8000')).toBeInTheDocument();
    expect(saveButton).not.toBeDisabled();
  });

  it('auto-generates the new book description before saving a chapter', async () => {
    window.location.hash = '/article/new';
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list' || type === 'series.list') {
          return ok(message.id, type, { articles: [], series: [] });
        }
        if (type === 'series.suggestDescription') {
          return ok(message.id, type, {
            description: 'A gentle garden picture book with Lily, soft watercolor colors, and cozy animal friends.',
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    const bookTitleInput = await screen.findByLabelText('新书籍名称');
    const articleTitleInput = screen.getByLabelText(/文章标题/);
    const contentInput = screen.getByLabelText(/文章内容/);

    expect(screen.queryByLabelText('书籍简介')).not.toBeInTheDocument();
    fireEvent.change(bookTitleInput, { target: { value: 'Lily Garden' } });
    fireEvent.click(screen.getByRole('button', { name: 'Lily Garden' }));
    const descriptionInput = screen.getByLabelText('书籍简介');
    const generateButton = screen.getByRole('button', { name: 'AI 自动生成新书籍简介' });
    fireEvent.change(articleTitleInput, { target: { value: 'The Little Gate' } });
    fireEvent.change(contentInput, {
      target: { value: 'Lily opens a little green gate. A rabbit waves from the flowers.' },
    });

    expect(generateButton).not.toBeDisabled();
    fireEvent.click(generateButton);

    await waitFor(() => {
      expect(descriptionInput).toHaveValue(
        'A gentle garden picture book with Lily, soft watercolor colors, and cozy animal friends.',
      );
      expect(calls.find((call) => call.type === 'series.suggestDescription')?.payload).toMatchObject({
        seriesTitle: 'Lily Garden',
        articleTitle: 'The Little Gate',
        content: 'Lily opens a little green gate. A rabbit waves from the flowers.',
      });
    });
  });

  it('enables new book description generation with only a book title', async () => {
    window.location.hash = '/article/new';
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list' || type === 'series.list') {
          return ok(message.id, type, { articles: [], series: [] });
        }
        if (type === 'series.suggestDescription') {
          return ok(message.id, type, {
            description: 'A whimsical Wonderland picture book with a compact recurring character roster.',
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    await screen.findByPlaceholderText('例如 The Secret Garden');
    const bookTitleInput = document.querySelector('input[placeholder*="The Secret Garden"]') as HTMLInputElement;
    expect(document.querySelector('.prompt-magic-button')).toBeNull();
    expect(screen.queryByLabelText('书籍简介')).not.toBeInTheDocument();
    fireEvent.change(bookTitleInput, { target: { value: "Alice's Adventures in Wonderland" } });
    fireEvent.click(screen.getByRole('button', { name: "Alice's Adventures in Wonderland" }));

    const generateButton = screen.getByRole('button', { name: 'AI 自动生成新书籍简介' });
    expect(generateButton).not.toBeDisabled();
    fireEvent.click(generateButton);

    await waitFor(() => {
      const request = calls.find((call) => call.type === 'series.suggestDescription');
      expect(request?.payload).toMatchObject({
        seriesTitle: "Alice's Adventures in Wonderland",
        articleTitle: '',
      });
      expect(String(request?.payload.content ?? '')).toContain("Alice's Adventures in Wonderland");
    });
  });

  it('moves empty-book deletion to the creation center', async () => {
    window.location.hash = '/';
    const article = {
      id: 5,
      title: 'Chapter One',
      content: 'Alice looks at the garden.',
      sentences: ['Alice looks at the garden.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 90,
      seriesId: 2,
      seriesTitle: 'Alice Series',
      chapterOrder: 1,
    };
    const emptySeries = {
      id: 1,
      title: 'Empty Book',
        description: '',
      coverImagePath: null,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };
    const filledSeries = {
      id: 2,
      title: 'Alice Series',
        description: '',
      coverImagePath: null,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series: [emptySeries, filledSeries] });
        }
        if (type === 'series.delete') {
          return ok(message.id, type, { articles: [article], series: [filledSeries] });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: Number(payload.articleId ?? article.id),
            enabled: true,
            status: 'ready',
            completed: 0,
            total: 0,
            pages: [],
          });
        }
        return ok(message.id, type, {});
      }),
    };

    const { container } = render(<App />);

    expect(await screen.findByText('Empty Book')).toBeInTheDocument();
    expect(screen.getAllByText('Alice Series').length).toBeGreaterThan(0);
    expect(container.querySelectorAll('.book-delete-button')).toHaveLength(0);

    fireEvent.click(screen.getByRole('button', { name: '创作中心' }));
    expect(await screen.findByRole('heading', { name: '创作中心' })).toBeInTheDocument();
    const emptyBookDeleteButtons = container.querySelectorAll('.book-delete-button');
    expect(emptyBookDeleteButtons).toHaveLength(1);

    fireEvent.click(emptyBookDeleteButtons[0]);

    await waitFor(() => {
      expect(calls.find((call) => call.type === 'series.delete')?.payload).toMatchObject({ seriesId: 1 });
    });
    expect(await screen.findByText('空书籍已删除')).toBeInTheDocument();
    expect(screen.queryByText('Empty Book')).not.toBeInTheDocument();
    expect(screen.getAllByText('Alice Series').length).toBeGreaterThan(0);
  });

  it('moves chapter deletion to the creation center', async () => {
    window.location.hash = '/';
    const article = {
      id: 42,
      title: 'Draft Chapter',
      content: 'Alice keeps walking.',
      sentences: ['Alice keeps walking.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 0,
      pictureBookEnabled: true,
      seriesId: 9,
      seriesTitle: 'Draft Book',
      chapterOrder: 1,
    };
    const series = [{
      id: 9,
      title: 'Draft Book',
        description: '',
      coverImagePath: null,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    }];
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series });
        }
        if (type === 'article.delete') {
          return ok(message.id, type, { articles: [], series });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: Number(payload.articleId ?? article.id),
            enabled: true,
            status: 'ready',
            completed: 0,
            total: 0,
            pages: [],
          });
        }
        return ok(message.id, type, {});
      }),
    };

    const { container } = render(<App />);

    expect(await screen.findByText('Draft Chapter')).toBeInTheDocument();
    expect(container.querySelectorAll('.mission-row .delete-action')).toHaveLength(0);

    fireEvent.click(screen.getByRole('button', { name: '创作中心' }));
    expect(await screen.findByRole('heading', { name: '创作中心' })).toBeInTheDocument();
    const chapterDeleteButtons = container.querySelectorAll('.mission-row .delete-action');
    expect(chapterDeleteButtons).toHaveLength(1);

    fireEvent.click(chapterDeleteButtons[0]);
    await cancelConfirmDialog('删除章节确认', '确定删除章节“Draft Chapter”？删除后不可恢复。');
    expect(calls.some((call) => call.type === 'article.delete')).toBe(false);

    fireEvent.click(chapterDeleteButtons[0]);
    await confirmDialogAction('删除章节确认', '删除', '确定删除章节“Draft Chapter”？删除后不可恢复。');

    await waitFor(() => {
      expect(calls.find((call) => call.type === 'article.delete')?.payload).toMatchObject({ articleId: 42 });
    });
    expect(await screen.findByText('章节已删除')).toBeInTheDocument();
  });

  it('exports and imports books from the creation center', async () => {
    window.location.hash = '/';
    const article = {
      id: 7,
      title: 'Chapter Export',
      content: 'Alice saves a book.',
      sentences: ['Alice saves a book.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 0,
      pictureBookEnabled: true,
      seriesId: 3,
      seriesTitle: 'Portable Book',
      chapterOrder: 1,
    };
    const series = [{
      id: 3,
      title: 'Portable Book',
      description: '',
      coverImagePath: null,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    }];
    const importedSeries = {
      ...series[0],
      id: 4,
      title: 'Imported Book',
    };
    const importedArticle = {
      ...article,
      id: 8,
      title: 'Imported Chapter',
      seriesId: 4,
      seriesTitle: 'Imported Book',
    };
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series });
        }
        if (type === 'series.export') {
          return ok(message.id, type, {
            cancelled: false,
            seriesId: 3,
            title: 'Portable Book',
            outputPath: 'C:\\Exports\\Portable Book.zip',
            warnings: [],
          });
        }
        if (type === 'series.import') {
          return ok(message.id, type, {
            cancelled: false,
            seriesId: 4,
            title: 'Imported Book',
            articleIds: [8],
            warnings: [],
            articles: [importedArticle, article],
            series: [importedSeries, ...series],
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: Number(payload.articleId ?? article.id),
            enabled: true,
            status: 'ready',
            completed: 0,
            total: 0,
            pages: [],
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    fireEvent.click(screen.getByRole('button', { name: '创作中心' }));
    expect(await screen.findByRole('heading', { name: '创作中心' })).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: '导出书籍' }));
    await waitFor(() => {
      expect(calls.find((call) => call.type === 'series.export')?.payload).toMatchObject({ seriesId: 3 });
    });
    expect(await screen.findByText(/书籍已导出/)).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: '导入书籍' }));
    await waitFor(() => {
      expect(calls.some((call) => call.type === 'series.import')).toBe(true);
    });
    expect(await screen.findByText('Imported Chapter')).toBeInTheDocument();
    expect(await screen.findByText(/书籍已导入/)).toBeInTheDocument();
  });

  it('refreshes creation picture thumbnails when generated image paths change', async () => {
    window.location.hash = '/creation?articleId=1&seriesId=1';
    const article = {
      id: 1,
      title: 'E01 - The Bright Gate',
      content: 'Alice finds a bright gate.',
      sentences: ['Alice finds a bright gate.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 40,
      pictureBookEnabled: true,
      seriesId: 1,
      seriesTitle: 'Alice Book',
      chapterOrder: 1,
      coverImageUri: 'data:image/png;base64,OLD_COVER',
    };
    const series = [{
      id: 1,
      title: 'Alice Book',
      description: '',
      coverImagePath: null,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    }];
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: article.id,
            enabled: true,
            status: 'ready',
            pages: [
              {
                articleId: article.id,
                pageIndex: 0,
                sentenceStartIndex: 0,
                sentenceEndIndex: 0,
                paragraphText: article.content,
                imagePath: 'old.png',
                imageUri: 'data:image/png;base64,OLD_THUMB',
                imageVariant: 'thumbnail',
                status: 'ready',
              },
            ],
          });
        }
        if (type === 'pictureBook.pageImage') {
          return ok(message.id, type, {
            articleId: article.id,
            pageIndex: Number(payload.pageIndex ?? 0),
            variant: payload.variant,
            imageUri: 'data:image/png;base64,NEW_THUMB',
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByText('绘本组图')).toBeInTheDocument();
    await waitFor(() => {
      expect(document.querySelector('.picture-creation-media img')?.getAttribute('src')).toBe(
        'data:image/png;base64,OLD_THUMB',
      );
    });

    act(() => {
      window.__tomatoNativeEvent?.({
        type: 'pictureBook.state',
        payload: {
          articleId: article.id,
          enabled: true,
          status: 'ready',
          pages: [
            {
              articleId: article.id,
              pageIndex: 0,
              sentenceStartIndex: 0,
              sentenceEndIndex: 0,
              paragraphText: article.content,
              imagePath: 'new.png',
              status: 'ready',
            },
          ],
        },
      });
    });

    await waitFor(() => {
      expect(
        calls.some(
          (call) =>
            call.type === 'pictureBook.pageImage' &&
            call.payload.articleId === 1 &&
            call.payload.pageIndex === 0 &&
            call.payload.variant === 'thumbnail',
        ),
      ).toBe(true);
    });
    await waitFor(() => {
      expect(document.querySelector('.picture-creation-media img')?.getAttribute('src')).toBe(
        'data:image/png;base64,NEW_THUMB',
      );
    });
  });

  it('opens a blocking full-size preview when clicking a creation picture thumbnail', async () => {
    window.location.hash = '/creation?articleId=1&seriesId=1';
    const article = {
      id: 1,
      title: 'E01 - The Bright Gate',
      content: 'Alice finds a bright gate.',
      sentences: ['Alice finds a bright gate.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 40,
      pictureBookEnabled: true,
      seriesId: 1,
      seriesTitle: 'Alice Book',
      chapterOrder: 1,
    };
    const series = [{
      id: 1,
      title: 'Alice Book',
      description: '',
      coverImagePath: null,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    }];
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: article.id,
            enabled: true,
            status: 'ready',
            pages: [{
              articleId: article.id,
              pageIndex: 0,
              sentenceStartIndex: 0,
              sentenceEndIndex: 0,
              paragraphText: article.content,
              imagePath: 'page-0.png',
              imageUri: 'data:image/png;base64,THUMB',
              imageVariant: 'thumbnail',
              status: 'ready',
            }],
          });
        }
        if (type === 'pictureBook.pageImage') {
          return ok(message.id, type, {
            articleId: article.id,
            pageIndex: Number(payload.pageIndex ?? 0),
            variant: payload.variant,
            imageUri: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAD0lEQVR42mP8z5QBDwAFhQZYgOy/0wAAAABJRU5ErkJggg==',
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByText('绘本组图')).toBeInTheDocument();
    fireEvent.click(await screen.findByRole('button', { name: '查看第 1 页大图' }));

    const previewDialog = await screen.findByRole('dialog', { name: '第 1 页绘本大图' });
    expect(previewDialog.closest('.picture-book-preview-overlay')?.parentElement).toBe(document.body);
    await waitFor(() => {
      // The lightbox requests "display" (1280x720), never the raw 2560x1440 original:
      // the WebView must not render the original (GPU downscale corruption on Windows).
      expect(calls.find((call) => call.type === 'pictureBook.pageImage')?.payload).toMatchObject({
        articleId: 1,
        pageIndex: 0,
        variant: 'display',
      });
    });
    const previewButton = await within(previewDialog).findByRole('button', { name: '关闭大图预览' });
    const previewImage = previewButton.querySelector('img');
    expect(previewImage?.getAttribute('src')).toMatch(/^(blob:|data:image\/)/);
    if (previewImage) {
      fireEvent.load(previewImage);
    }

    fireEvent.click(previewButton);
    expect(screen.queryByRole('dialog', { name: '第 1 页绘本大图' })).not.toBeInTheDocument();
  });

  it('edits book info from the creation center without showing book descriptions in the book card', async () => {
    window.location.hash = '/creation?articleId=42';
    const now = new Date().toISOString();
    const article = {
      id: 42,
      title: 'Storyboard Chapter',
      content: 'Alice meets the White Rabbit.',
      sentences: ['Alice meets the White Rabbit.'],
      sentenceCount: 1,
      createdAt: now,
      averageScore: 0,
      pictureBookEnabled: true,
      seriesId: 9,
      seriesTitle: 'Wonderland Book',
      seriesDescription: 'Victorian fantasy book world with recurring Wonderland characters.',
      chapterDescription: 'A one-scene storyboard where Alice notices the hurried White Rabbit.',
      chapterOrder: 1,
    };
    const series = [{
      id: 9,
      title: 'Wonderland Book',
      description: 'Victorian fantasy book world with recurring Wonderland characters.',
      coverImagePath: null,
      createdAt: now,
      updatedAt: now,
    }];
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series });
        }
        if (type === 'series.suggestDescription') {
          return ok(message.id, type, {
            description: 'AI refreshed Wonderland book description with stable character anchors.',
          });
        }
        if (type === 'series.update') {
          return ok(message.id, type, {
            articles: [{
              ...article,
              seriesTitle: String(payload.title ?? article.seriesTitle),
              seriesDescription: String(payload.description ?? article.seriesDescription),
            }],
            series: [{
              ...series[0],
              title: String(payload.title ?? series[0].title),
              description: String(payload.description ?? series[0].description),
            }],
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: article.id,
            enabled: true,
            status: 'empty',
            pages: [],
          });
        }
        return ok(message.id, type, {});
      }),
    };

    const { container } = render(<App />);

    expect(await screen.findByRole('heading', { name: '创作中心' })).toBeInTheDocument();
    expect(screen.queryByText('Victorian fantasy book world with recurring Wonderland characters.')).not.toBeInTheDocument();
    expect(await screen.findByText('A one-scene storyboard where Alice notices the hurried White Rabbit.')).toBeInTheDocument();
    const chapterToolbar = container.querySelector('.creation-library-selector .chapter-toolbar') as HTMLElement;
    expect(chapterToolbar).toHaveTextContent('章节列表');
    expect(chapterToolbar).not.toHaveTextContent('Wonderland Book');
    expect(chapterToolbar).not.toHaveTextContent('Victorian fantasy book world with recurring Wonderland characters.');
    expect(screen.queryByRole('button', { name: '展开《Wonderland Book》书籍简介' })).not.toBeInTheDocument();

    const headingActions = container.querySelector('.creation-library-selector .section-heading-actions') as HTMLElement;
    const headingButtons = within(headingActions).getAllByRole('button');
    expect(headingButtons[0]).toHaveTextContent('编辑书籍');
    expect(headingButtons[1]).toHaveTextContent('新增章节');

    fireEvent.click(headingButtons[0]);
    const dialog = await screen.findByRole('dialog', { name: '编辑书籍信息' });
    fireEvent.change(within(dialog).getByLabelText('书籍名称'), { target: { value: 'Updated Wonderland Book' } });
    const descriptionInput = within(dialog).getByLabelText('书籍简介');
    fireEvent.click(within(dialog).getByRole('button', { name: 'AI 自动生成书籍简介' }));
    await waitFor(() => {
      expect(descriptionInput).toHaveValue('AI refreshed Wonderland book description with stable character anchors.');
      expect(calls.find((call) => call.type === 'series.suggestDescription')?.payload).toMatchObject({
        seriesTitle: 'Updated Wonderland Book',
        articleTitle: 'Storyboard Chapter',
        content: 'Alice meets the White Rabbit.',
        description: 'Victorian fantasy book world with recurring Wonderland characters.',
      });
    });
    fireEvent.change(descriptionInput, { target: { value: 'Updated character roster and visual style.' } });
    fireEvent.click(within(dialog).getByRole('button', { name: /保存/ }));

    await waitFor(() => {
      expect(calls.find((call) => call.type === 'series.update')?.payload).toMatchObject({
        seriesId: 9,
        title: 'Updated Wonderland Book',
        description: 'Updated character roster and visual style.',
      });
    });
    expect(await screen.findByText('书籍信息已更新')).toBeInTheDocument();
  });

  it('updates creation-center picture-book status from native events', async () => {
    window.location.hash = '/';
    const article = {
      id: 42,
      title: 'Draft Chapter',
      content: 'Alice keeps walking.',
      sentences: ['Alice keeps walking.', 'She sees the garden.'],
      sentenceCount: 2,
      createdAt: new Date().toISOString(),
      averageScore: 0,
      pictureBookEnabled: true,
      seriesId: 9,
      seriesTitle: 'Draft Book',
      chapterOrder: 1,
    };
    const series = [{
      id: 9,
      title: 'Draft Book',
        description: '',
      coverImagePath: null,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    }];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });
    const generatingPictureBook = {
      articleId: article.id,
      enabled: true,
      status: 'generating',
      pages: [
        {
          articleId: article.id,
          pageIndex: 0,
          sentenceStartIndex: 0,
          sentenceEndIndex: 0,
          paragraphText: 'Alice keeps walking.',
          status: 'generating',
        },
        {
          articleId: article.id,
          pageIndex: 1,
          sentenceStartIndex: 1,
          sentenceEndIndex: 1,
          paragraphText: 'She sees the garden.',
          status: 'queued',
        },
      ],
    };

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            ...generatingPictureBook,
            articleId: Number(payload.articleId ?? article.id),
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByText('Draft Chapter')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '创作中心' }));
    expect(await screen.findByRole('heading', { name: '创作中心' })).toBeInTheDocument();
    expect(await screen.findByText('2 页 · 生成中')).toBeInTheDocument();

    await act(async () => {
      window.__tomatoNativeEvent?.({
        type: 'pictureBook.state',
        payload: {
          ...generatingPictureBook,
          status: 'ready',
          pages: generatingPictureBook.pages.map((page) => ({
            ...page,
            status: 'ready',
            imageUri: 'data:image/png;base64,ready',
          })),
        },
      });
    });

    expect(await screen.findByText('2 页 · 已完成')).toBeInTheDocument();
  });

  it('shows listening audio regeneration after picture regeneration and fills missing audio', async () => {
    window.location.hash = '/creation?articleId=42&seriesId=9';
    const article = {
      id: 42,
      title: 'Draft Chapter',
      content: 'Alice keeps walking. She sees the garden.',
      sentences: ['Alice keeps walking.', 'She sees the garden.'],
      sentenceCount: 2,
      createdAt: new Date().toISOString(),
      averageScore: 0,
      pictureBookEnabled: true,
      seriesId: 9,
      seriesTitle: 'Draft Book',
      chapterOrder: 1,
    };
    const series = [{
      id: 9,
      title: 'Draft Book',
      description: '',
      coverImagePath: null,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    }];
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    let resolveGenerate: (() => void) | null = null;
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: article.id,
            enabled: true,
            status: 'ready',
            pages: [],
          });
        }
        if (type === 'listening.audioStatus') {
          return ok(message.id, type, {
            articleId: article.id,
            total: 2,
            ready: 0,
            missing: [0, 1],
            failed: 0,
            status: 'missing',
          });
        }
        if (type === 'listening.audioGenerate') {
          return new Promise<BridgeResponse>((resolve) => {
            resolveGenerate = () => resolve(ok(message.id, type, {
              articleId: article.id,
              total: 2,
              ready: 2,
              missing: [],
              failed: 0,
              status: 'ready',
              requested: 2,
              overwrite: false,
            }));
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByRole('heading', { name: '创作中心' })).toBeInTheDocument();
    expect(await screen.findByText('0 / 2 已生成 · 缺 2 句')).toBeInTheDocument();
    const picturePanel = screen.getByText('绘本组图').closest('.creation-panel') as HTMLElement;
    const buttonRow = picturePanel.querySelector('.button-row.compact') as HTMLElement;
    const buttonLabels = within(buttonRow).getAllByRole('button').map((button) => button.textContent ?? '');
    expect(buttonLabels.findIndex((label) => label.includes('生成组图')))
      .toBeLessThan(buttonLabels.findIndex((label) => label.includes('生成听力')));
    expect(buttonLabels.findIndex((label) => label.includes('生成听力')))
      .toBeLessThan(buttonLabels.findIndex((label) => label.includes('刷新状态')));

    const generateButton = within(buttonRow).getByRole('button', { name: /生成听力/ });
    fireEvent.click(generateButton);

    const progressDialog = await screen.findByRole('dialog', { name: '正在生成听力材料' });
    expect(progressDialog).toHaveAttribute('aria-modal', 'true');
    expect(progressDialog.closest('.edit-dialog-backdrop')).toBeNull();
    const progressOverlay = progressDialog.closest('.audio-material-progress-overlay');
    expect(progressOverlay).toBeTruthy();
    expect(progressOverlay?.parentElement).toBe(document.body);
    expect(within(progressDialog).getByText('生成期间已禁止页面操作，请等待完成')).toBeInTheDocument();
    await waitFor(() => {
      expect(calls.filter((call) => call.type === 'listening.audioGenerate')).toHaveLength(1);
    });
    const busyGenerateButton = within(buttonRow).getByRole('button', { name: /生成中/ });
    expect(busyGenerateButton).toBeDisabled();
    fireEvent.click(busyGenerateButton);
    expect(calls.filter((call) => call.type === 'listening.audioGenerate')).toHaveLength(1);
    await act(async () => {
      window.__tomatoNativeEvent?.({
        type: 'listening.audioMaterial.progress',
        payload: {
          articleId: article.id,
          status: 'loading',
          completed: 1,
          total: 2,
          failed: 0,
          overwrite: false,
        },
      });
    });
    expect(await screen.findByText('正在提交远程语音合成 1 / 2')).toBeInTheDocument();
    await act(async () => {
      resolveGenerate?.();
    });

    await waitFor(() => {
      expect(calls.find((call) => call.type === 'listening.audioGenerate')?.payload).toMatchObject({
        articleId: article.id,
        overwrite: false,
      });
    });
    expect(await screen.findByText('听力材料已生成')).toBeInTheDocument();
    await waitFor(() => {
      expect(screen.queryByRole('dialog', { name: '正在生成听力材料' })).not.toBeInTheDocument();
    });
  });

  it('confirms before overwriting complete listening audio material', async () => {
    window.location.hash = '/creation?articleId=42&seriesId=9';
    const article = {
      id: 42,
      title: 'Draft Chapter',
      content: 'Alice keeps walking. She sees the garden.',
      sentences: ['Alice keeps walking.', 'She sees the garden.'],
      sentenceCount: 2,
      createdAt: new Date().toISOString(),
      averageScore: 0,
      pictureBookEnabled: true,
      seriesId: 9,
      seriesTitle: 'Draft Book',
      chapterOrder: 1,
    };
    const series = [{
      id: 9,
      title: 'Draft Book',
      description: '',
      coverImagePath: null,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    }];
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    let resolveGenerate: (() => void) | null = null;
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: article.id,
            enabled: true,
            status: 'ready',
            pages: [],
          });
        }
        if (type === 'listening.audioStatus') {
          return ok(message.id, type, {
            articleId: article.id,
            total: 2,
            ready: 2,
            missing: [],
            failed: 0,
            status: 'ready',
          });
        }
        if (type === 'listening.audioGenerate') {
          return new Promise<BridgeResponse>((resolve) => {
            resolveGenerate = () => resolve(ok(message.id, type, {
              articleId: article.id,
              total: 2,
              ready: 2,
              missing: [],
              failed: 0,
              status: 'ready',
              requested: 2,
              overwrite: true,
            }));
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);
    expect(await screen.findByText('2 / 2 已生成')).toBeInTheDocument();
    fireEvent.click(await screen.findByRole('button', { name: /生成听力/ }));

    await cancelConfirmDialog(
      '覆盖听力材料确认',
      '听力材料已经生成 2 / 2。是否覆盖原内容并重新提交远程语音合成？',
    );
    expect(calls.some((call) => call.type === 'listening.audioGenerate')).toBe(false);

    fireEvent.click(await screen.findByRole('button', { name: /生成听力/ }));
    const confirmDialog = await findConfirmDialog('覆盖听力材料确认', '听力材料已经生成 2 / 2。是否覆盖原内容并重新提交远程语音合成？');
    expect(confirmDialog.closest('.edit-dialog-backdrop')?.parentElement).toBe(document.body);
    expect(calls.some((call) => call.type === 'listening.audioGenerate')).toBe(false);

    await confirmDialogAction('覆盖听力材料确认', /覆盖生成/);
    const progressDialog = await screen.findByRole('dialog', { name: '正在生成听力材料' });
    expect(screen.queryByRole('dialog', { name: '覆盖听力材料确认' })).not.toBeInTheDocument();
    expect(progressDialog.closest('.audio-material-progress-overlay')).toBeTruthy();
    expect(progressDialog.closest('.edit-dialog-backdrop')).toBeNull();
    await waitFor(() => {
      expect(calls.find((call) => call.type === 'listening.audioGenerate')?.payload).toMatchObject({
        articleId: article.id,
        overwrite: true,
      });
    });
    await act(async () => {
      resolveGenerate?.();
    });
    await waitFor(() => {
      expect(screen.queryByRole('dialog', { name: '正在生成听力材料' })).not.toBeInTheDocument();
    });
  });

  it('keeps the creation-center chapter list expanded when selecting chapter actions', async () => {
    window.location.hash = '/';
    const now = new Date().toISOString();
    const article = {
      id: 42,
      title: 'Fold Me Chapter',
      content: 'Alice keeps walking.',
      sentences: ['Alice keeps walking.'],
      sentenceCount: 1,
      createdAt: now,
      averageScore: 0,
      pictureBookEnabled: true,
      seriesId: 9,
      seriesTitle: 'Foldable Book',
      chapterOrder: 1,
    };
    const series = [{
      id: 9,
      title: 'Foldable Book',
      description: '',
      coverImagePath: null,
      createdAt: now,
      updatedAt: now,
    }];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: Number(payload.articleId ?? article.id),
            enabled: true,
            status: 'ready',
            pages: [],
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByText('Fold Me Chapter')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '创作中心' }));
    expect(await screen.findByText('章节列表')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: '进入《Fold Me Chapter》创作' }));
    expect(screen.queryByText('章节列表已折叠')).not.toBeInTheDocument();
    expect(screen.getByText('章节列表')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: '绘本' }));

    expect(screen.queryByText('章节列表已折叠')).not.toBeInTheDocument();
    expect(screen.getByText('章节列表')).toBeInTheDocument();
    const collapseToggle = screen.getByRole('button', { name: '折叠章节列表' });
    expect(collapseToggle).toHaveTextContent('∨');
    expect(screen.getByText('Fold Me Chapter')).toBeInTheDocument();
  });

  it('sends picture-book series choices when saving a new chapter', async () => {
    window.location.hash = '/article/new';
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    let resolveConfirm: (() => void) | null = null;
    const series = [
      {
        id: 7,
        title: 'Alice Series',
        description: '',
        coverImagePath: null,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      },
    ];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [], series });
        }
        if (type === 'series.list') {
          return ok(message.id, type, { series });
        }
        if (type === 'article.create') {
          const article = {
            id: 42,
            title: String(payload.title),
            content: String(payload.content),
            sentences: ['Alice sees a bright table.'],
            sentenceCount: 1,
            createdAt: new Date().toISOString(),
            averageScore: 0,
            pictureBookEnabled: true,
            seriesId: Number(payload.seriesId),
            seriesTitle: 'Alice Series',
            seriesDescription: String(payload.seriesDescription ?? ''),
            chapterOrder: 2,
          };
          return ok(message.id, type, { article, articles: [article], series });
        }
        if (type === 'pictureBook.promptReview') {
          return ok(
            message.id,
            type,
            promptReviewPayloadForTest(Number(payload.articleId ?? 42), false),
          );
        }
        if (type === 'pictureBook.refreshPromptReview') {
          return ok(message.id, type, {
            ...promptReviewPayloadForTest(42, false),
            bookDescription: 'Refreshed book description with a consistent Alice look.',
            refreshedTarget: payload.target,
          });
        }
        if (type === 'pictureBook.savePromptReview') {
          return ok(message.id, type, {
            ...promptReviewPayloadForTest(42, false),
            reviewId: String(payload.reviewId ?? 'review-42'),
            bookDescription: String(payload.bookDescription ?? ''),
            chapterDescription: String(payload.chapterDescription ?? ''),
            groupPrompt: String(payload.groupPrompt ?? ''),
            scenes: Array.isArray(payload.scenes) ? payload.scenes : [],
          });
        }
        if (type === 'pictureBook.confirmPromptReview') {
          return new Promise<BridgeResponse>((resolve) => {
            resolveConfirm = () => {
              resolve(
                ok(message.id, type, {
                  articleId: 42,
                  enabled: true,
                  status: 'ready',
                  pages: [],
                }),
              );
            };
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    const titleInput = await screen.findByLabelText(/文章标题/);
    const contentInput = screen.getByLabelText(/文章内容/);
    const bookSelect = await screen.findByLabelText('书籍');

    expect(screen.queryByRole('checkbox', { name: /生成英语绘本图/ })).not.toBeInTheDocument();
    fireEvent.change(titleInput, { target: { value: 'Alice Tea Time' } });
    fireEvent.change(contentInput, { target: { value: 'Alice sees a bright table.' } });
    fireEvent.change(bookSelect, { target: { value: '7' } });
    fireEvent.click(screen.getByRole('button', { name: /保存章节/ }));

    await waitFor(() => {
      const createCall = calls.find((call) => call.type === 'article.create');
      expect(createCall?.payload).toMatchObject({
        title: 'Alice Tea Time',
        content: 'Alice sees a bright table.',
        pictureBookEnabled: true,
        seriesId: 7,
      });
    });
    const reviewDialog = await screen.findByRole('dialog', { name: '绘本提示词审核' });
    expect(reviewDialog).toBeInTheDocument();
    expect(calls.some((call) => call.type === 'pictureBook.promptReview')).toBe(true);
    expect(within(reviewDialog).getByRole('button', { name: 'AI 自动生成书籍简介' })).toHaveTextContent(
      '自动生成书籍简介',
    );
    expect(within(reviewDialog).getByRole('button', { name: 'AI 自动生成章节描述和分镜描述' })).toHaveTextContent(
      '自动生成章节规划',
    );
    expect(within(reviewDialog).queryByLabelText('书籍简介')).not.toBeInTheDocument();
    expect(within(reviewDialog).queryByLabelText('章节分镜简述')).not.toBeInTheDocument();
    const sceneHeading = within(reviewDialog).getByRole('heading', { name: '章节分镜描述' });
    expect(sceneHeading).toBeInTheDocument();
    const groupPromptInput = within(reviewDialog).getByLabelText('组图总提示词') as HTMLTextAreaElement;
    expect(
      Boolean(sceneHeading.compareDocumentPosition(groupPromptInput) & Node.DOCUMENT_POSITION_FOLLOWING),
    ).toBe(true);
    expect(
      groupPromptInput.value,
    ).toContain('Scene description: Tom discovers the snack box.');
    fireEvent.click(within(reviewDialog).getByRole('button', { name: 'Space Story Series' }));
    const bookDescriptionInput = within(reviewDialog).getByLabelText('书籍简介');
    fireEvent.click(within(reviewDialog).getByRole('button', { name: 'AI 自动生成书籍简介' }));
    await waitFor(() => {
      expect(calls.some((call) => call.type === 'pictureBook.refreshPromptReview')).toBe(true);
      expect(bookDescriptionInput).toHaveValue(
        'Refreshed book description with a consistent Alice look.',
      );
    });
    fireEvent.change(bookDescriptionInput, {
      target: { value: 'Alice keeps a blue dress and white apron.' },
    });
    fireEvent.change(within(reviewDialog).getByLabelText('第 1 个分镜描述'), {
      target: { value: 'Alice sees a bright table in a Victorian fantasy room.' },
    });
    fireEvent.click(within(reviewDialog).getByRole('button', { name: '保存提示词' }));

    await waitFor(() => {
      const saveCall = calls.find((call) => call.type === 'pictureBook.savePromptReview');
      expect(saveCall?.payload).toMatchObject({
        reviewId: 'review-42',
        bookDescription: 'Alice keeps a blue dress and white apron.',
      });
    });

    fireEvent.click(within(reviewDialog).getByRole('button', { name: '生成组图' }));

    await waitFor(() => {
      expect(screen.getByText('正在提交绘本组图')).toBeInTheDocument();
      expect(screen.getByText(/预计超时倒计时/)).toBeInTheDocument();
    });

    await waitFor(() => {
      const confirmCall = calls.find((call) => call.type === 'pictureBook.confirmPromptReview');
      expect(confirmCall?.payload).toMatchObject({
        reviewId: 'review-42',
        bookDescription: 'Alice keeps a blue dress and white apron.',
      });
      expect(confirmCall?.payload.scenes).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            sceneDescription: 'Alice sees a bright table in a Victorian fantasy room.',
          }),
        ]),
      );
    });

    await act(async () => {
      resolveConfirm?.();
    });
    await waitFor(() => {
      expect(screen.queryByText('正在提交绘本组图')).not.toBeInTheDocument();
    });
  });

  it('lets native generate missing titles and extract English from mixed input on save', async () => {
    window.location.hash = '/article/new';
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });
    const mixedContent =
      '中文讲解：下面是故事原文\nOne month ago, I did something everyone thought was unbelievable—I quit my job.\n中文翻译：一个月前，我做了一件大家觉得难以置信的事。';
    const englishContent =
      'One month ago, I did something everyone thought was unbelievable—I quit my job.';
    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [], series: [] });
        }
        if (type === 'series.list') {
          return ok(message.id, type, { series: [] });
        }
        if (type === 'article.create') {
          const article = {
            id: 42,
            title: 'I Quit My Job',
            content: englishContent,
            sentences: [englishContent],
            sentenceCount: 1,
            createdAt: new Date().toISOString(),
            averageScore: 0,
            pictureBookEnabled: true,
            seriesId: 12,
            seriesTitle: String(payload.seriesTitle ?? ''),
            chapterOrder: 1,
          };
          return ok(message.id, type, {
            article,
            articles: [article],
            series: [
              {
                id: 12,
                title: String(payload.seriesTitle ?? ''),
                description: '',
                coverImagePath: null,
                createdAt: new Date().toISOString(),
                updatedAt: new Date().toISOString(),
              },
            ],
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    const titleInput = await screen.findByLabelText(/文章标题/);
    const bookTitleInput = screen.getByLabelText('新书籍名称');
    const contentInput = screen.getByLabelText(/文章内容/);
    const saveButton = screen.getByRole('button', { name: /保存章节/ });

    fireEvent.change(bookTitleInput, { target: { value: 'Work Change Stories' } });
    fireEvent.change(contentInput, {
      target: {
        value: mixedContent,
      },
    });

    expect(titleInput).toHaveValue('');
    expect(contentInput).toHaveValue(mixedContent);
    expect(saveButton).not.toBeDisabled();

    fireEvent.click(saveButton);
    await waitFor(() => {
      const createCall = calls.find((call) => call.type === 'article.create');
      expect(createCall?.payload).toMatchObject({
        title: '',
        content: mixedContent,
        seriesTitle: 'Work Change Stories',
      });
    });
    expect(calls.some((call) => call.type === 'article.translateToEnglish')).toBe(false);
    expect(calls.some((call) => call.type === 'article.suggestTitle')).toBe(false);
    expect((await screen.findAllByText('I Quit My Job')).length).toBeGreaterThan(0);
  });

  it('splits long article preview text into short read-aloud chunks', () => {
    const chunks = splitSentences(
      'Tom walks into the bright library, finds a tiny blue robot beside the big window, and asks it to help him read a funny story before lunch, because his little sister wants to hear every silly voice before bedtime.',
    );

    expect(chunks.length).toBeGreaterThan(1);
    expect(chunks.every((chunk) => chunk.split(/\s+/).length <= 32)).toBe(true);
  });

  it('keeps hyphenated English words joined in article preview chunks', () => {
    const chunks = splitSentences(
      'The well - known mother - in - law smiles at the child.',
    );

    expect(chunks.join(' ')).toContain('well-known');
    expect(chunks.join(' ')).toContain('mother-in-law');
    expect(chunks.join(' ')).not.toContain('well - known');
  });

  it('skips imported Alice episode headings in article preview text', () => {
    const chunks = splitSentences(
      [
        'E25',
        '',
        '爱丽丝梦游仙境（原著领读版）- E61',
        '',
        "Alice's Adventures in Wonderland - Episod 61",
        '"They were learning to draw," the Dormouse went on, yawning and rubbing its eyes.',
      ].join('\n'),
    );

    expect(chunks[0]).toMatch(/^"They were learning to draw,"/);
    expect(chunks.join(' ')).not.toContain('爱丽丝');
    expect(chunks.join(' ')).not.toContain('E25');
    expect(chunks.join(' ')).not.toContain('Episod 61');
  });

  it('splits Alice Mad Tea-Party long sentences into read-aloud phrase chunks', () => {
    const chunks = splitSentences(
      [
        'A Mad Tea-Party',
        'There was a table set out under a tree in front of the house, and the March Hare and the Hatter were having tea at it: a Dormouse was sitting between them, fast asleep, and the other two were using it as a cushion, resting their elbows on it, and talking over its head.',
        '"Very uncomfortable for the Dormouse," thought Alice: "only as it\'s asleep, I suppose it doesn\'t mind."',
        'The table was a large one, but the three were all crowded together at one corner of it: "No room! No room!" they cried out when they saw Alice coming.',
      ].join('\n'),
    );

    expect(chunks.length).toBeGreaterThanOrEqual(4);
    expect(chunks.join(' ')).toContain('a Dormouse was sitting between them');
    expect(chunks.join(' ')).toContain('"No room! No room!"');
    expect(chunks.every((chunk) => chunk.split(/\s+/).length <= 32)).toBe(true);
    expect(chunks.join(' ')).not.toContain('A Mad Tea-Party');
  });

  it('splits long pre-quote Alice narration before forcing direct quote breaks', () => {
    const chunks = splitSentences(
      'It was so large a house, that she did not like to go nearer till she had nibbled some more of the left-hand bit of mushroom, and raised herself to about two feet high; even then she walked up toward it rather timidly, saying to herself, "Suppose it should be raving mad after all, I almost wish I\'d gone to see the Hatter instead."',
    );
    const joined = chunks.join(' ');

    expect(chunks.length).toBeGreaterThan(2);
    expect(chunks.every((chunk) => chunk.split(/\s+/).length <= 32)).toBe(true);
    expect(joined).toContain('left-hand bit of mushroom,');
    expect(joined).toContain('and raised herself to about two feet high;');
    expect(joined).toContain('"Suppose it should be raving mad after all');
  });

  it('auto-plays the first follow sentence and enables recording afterward', async () => {
    window.location.hash = '/follow/1';

    render(<App />);

    expect(await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' })).toBeInTheDocument();
    await waitFor(() => {
      expect(screen.getByRole('button', { name: /开始录音/ })).not.toBeDisabled();
    });
    expect(screen.getByRole('button', { name: /播放原音/ })).not.toBeDisabled();
    expect(screen.queryByRole('button', { name: /重播/ })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /再试一次/ })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: /播放录音/ })).toBeDisabled();
    expect(screen.getByRole('button', { name: /下一句/ })).not.toBeDisabled();
    expect(screen.queryByText('原音播放完成，现在可以开始跟读。')).not.toBeInTheDocument();
    expect(screen.queryByText('点击录音，跟读这句话')).not.toBeInTheDocument();
    expect(screen.queryByText('伙伴状态')).not.toBeInTheDocument();
    expect(document.querySelector('.step-track')).not.toBeInTheDocument();
    expect(document.querySelector('.partner-status')).not.toBeInTheDocument();
    expect(document.querySelector('.picture-book-scene')).toBeInTheDocument();
  });

  it('auto-plays the user recording once after recording stops', async () => {
    window.location.hash = '/follow/1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box.',
      sentences: ['Tom finds a bright snack box.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 0,
    };
    const calls: string[] = [];
    const result = {
      overallScore: 88,
      accuracyScore: 91,
      fluencyScore: 84,
      completenessScore: 90,
      prosodyScore: 83,
      recognizedText: 'Tom finds a bright snack box.',
      isMock: false,
      words: [{ word: 'Tom', score: 90, errorType: 'None' }],
    };
    const followBase = {
      status: 'ready',
      article,
      currentIndex: 0,
      totalSentences: 1,
      currentSentence: article.sentences[0],
      currentTranslation: '汤姆发现了一个明亮的零食盒。',
      isLastSentence: true,
      playbackState: 'success',
      hasRecording: false,
      liveRecognizedText: '',
      result: null,
    };
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        calls.push(type);
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article] });
        }
        if (type === 'follow.open') {
          return ok(message.id, type, { ...followBase, step: 'idle' });
        }
        if (type === 'follow.play') {
          return ok(message.id, type, { ...followBase, step: 'idle', playbackState: 'success' });
        }
        if (type === 'follow.recordStart') {
          return ok(message.id, type, { ...followBase, step: 'recording', playbackState: 'idle' });
        }
        if (type === 'follow.recordStop') {
          return ok(message.id, type, {
            ...followBase,
            step: 'result',
            hasRecording: true,
            result,
            liveRecognizedText: result.recognizedText,
          });
        }
        if (type === 'follow.recordReplay') {
          return ok(message.id, type, {
            ...followBase,
            step: 'result',
            hasRecording: true,
            result,
            liveRecognizedText: result.recognizedText,
            playbackState: 'success',
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    await waitFor(() => {
      expect(screen.getByRole('button', { name: /开始录音/ })).not.toBeDisabled();
    });
    fireEvent.click(screen.getByRole('button', { name: /开始录音/ }));

    await waitFor(() => {
      expect(screen.getByRole('button', { name: /停止录音/ })).not.toBeDisabled();
    });
    fireEvent.click(screen.getByRole('button', { name: /停止录音/ }));

    await waitFor(() => {
      expect(calls.filter((type) => type === 'follow.recordReplay')).toHaveLength(1);
    });
    expect(calls.filter((type) => type === 'follow.recordStop')).toHaveLength(1);
  });

  it('allows next sentence to interrupt recording playback', async () => {
    window.location.hash = '/follow/1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box. He shares it with his team.',
      sentences: ['Tom finds a bright snack box.', 'He shares it with his team.'],
      sentenceCount: 2,
      createdAt: new Date().toISOString(),
      averageScore: 0,
    };
    const result = {
      overallScore: 88,
      accuracyScore: 91,
      fluencyScore: 84,
      completenessScore: 90,
      prosodyScore: 83,
      recognizedText: 'Tom finds a bright snack box.',
      isMock: false,
      words: [{ word: 'Tom', score: 90, errorType: 'None' }],
    };
    const calls: string[] = [];
    let resolveRecordingPlayback: (() => void) | null = null;
    const followBase = {
      status: 'ready',
      article,
      currentIndex: 0,
      totalSentences: 2,
      currentSentence: article.sentences[0],
      currentTranslation: '汤姆发现了一个明亮的零食盒。',
      isLastSentence: false,
      playbackState: 'success',
      hasRecording: false,
      liveRecognizedText: '',
      result: null,
    };
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        calls.push(type);
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article] });
        }
        if (type === 'follow.open') {
          return ok(message.id, type, { ...followBase, step: 'idle' });
        }
        if (type === 'follow.play') {
          return ok(message.id, type, { ...followBase, step: 'idle', playbackState: 'success' });
        }
        if (type === 'follow.recordReplay') {
          return new Promise((resolve) => {
            resolveRecordingPlayback = () =>
              resolve(ok(message.id, type, {
                ...followBase,
                step: 'result',
                hasRecording: true,
                result,
                liveRecognizedText: result.recognizedText,
              }));
          });
        }
        if (type === 'follow.next') {
          return ok(message.id, type, {
            ...followBase,
            currentIndex: 1,
            currentSentence: article.sentences[1],
            currentTranslation: '他把它分享给自己的队友。',
            isLastSentence: true,
            step: 'idle',
            hasRecording: false,
            result: null,
            liveRecognizedText: '',
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' })).toBeInTheDocument();
    act(() => {
      window.__tomatoNativeEvent?.({
        type: 'follow.state',
        payload: {
          ...followBase,
          step: 'result',
          hasRecording: true,
          result,
          liveRecognizedText: result.recognizedText,
        },
      });
    });

    fireEvent.click(screen.getByRole('button', { name: /播放录音/ }));
    act(() => {
      window.__tomatoNativeEvent?.({
        type: 'follow.state',
        payload: {
          ...followBase,
          step: 'playing',
          playbackState: 'playing',
          hasRecording: true,
          result,
          liveRecognizedText: result.recognizedText,
        },
      });
    });

    await waitFor(() => {
      expect(screen.getByRole('button', { name: /下一句/ })).not.toBeDisabled();
    });
    fireEvent.click(screen.getByRole('button', { name: /下一句/ }));

    await waitFor(() => {
      expect(calls).toContain('follow.next');
    });
    act(() => {
      resolveRecordingPlayback?.();
    });
  });

  it('opens a word translation card from follow reading and resumes follow playback', async () => {
    window.location.hash = '/follow/1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box.',
      sentences: ['Tom finds a bright snack box.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 0,
    };
    const calls: string[] = [];
    let resolveFollowPlayback: (() => void) | null = null;
    const followBase = {
      status: 'ready',
      article,
      currentIndex: 0,
      totalSentences: 1,
      currentSentence: article.sentences[0],
      currentTranslation: '汤姆发现了一个明亮的零食盒。',
      isLastSentence: true,
      playbackState: 'success',
      hasRecording: false,
      liveRecognizedText: '',
      result: null,
    };
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        calls.push(type);
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article] });
        }
        if (type === 'follow.open') {
          return ok(message.id, type, { ...followBase, step: 'idle' });
        }
        if (type === 'follow.play') {
          return new Promise((resolve) => {
            resolveFollowPlayback = () =>
              resolve(ok(message.id, type, { ...followBase, step: 'idle', playbackState: 'success' }));
          });
        }
        if (type === 'follow.pause') {
          return ok(message.id, type, { paused: true });
        }
        if (type === 'follow.resume') {
          return ok(message.id, type, { resumed: true });
        }
        if (type === 'word.lookup') {
          return ok(message.id, type, {
            word: 'bright',
            phonetic: '/brait/',
            meaning: '明亮的；聪明的；鲜艳的',
            sentenceMeaning: '在本句中表示“明亮的”。',
          });
        }
        if (type === 'word.play') {
          return ok(message.id, type, { playbackState: 'success' });
        }
        if (type === 'word.stop') {
          return ok(message.id, type, { stopped: true });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    const heading = await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' });
    act(() => {
      window.__tomatoNativeEvent?.({
        type: 'follow.state',
        payload: {
          ...followBase,
          step: 'playing',
          playbackState: 'playing',
        },
      });
    });

    fireEvent.click(within(heading).getByRole('button', { name: 'bright' }));

    expect(await screen.findByRole('dialog', { name: 'bright' })).toBeInTheDocument();
    expect(await screen.findByText('/brait/')).toBeInTheDocument();
    await waitFor(() => {
      expect(calls).toContain('follow.pause');
      expect(calls).toContain('word.play');
      expect(calls).toContain('word.lookup');
    });

    fireEvent.click(screen.getByRole('button', { name: '关闭单词翻译' }));

    await waitFor(() => {
      expect(calls).toContain('word.stop');
      expect(calls).toContain('follow.resume');
    });

    act(() => {
      resolveFollowPlayback?.();
    });
  });

  it('opens listening practice with English-only playback while showing subtitles', async () => {
    window.location.hash = '/listen/1';
    const clipboard = { writeText: vi.fn().mockResolvedValue(undefined) };
    Object.defineProperty(navigator, 'clipboard', {
      value: clipboard,
      configurable: true,
    });
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box. He shares it with his team.',
      sentences: ['Tom finds a bright snack box.', 'He shares it with his team.'],
      sentenceCount: 2,
      createdAt: new Date().toISOString(),
      averageScore: 86,
      seriesId: 10,
      seriesTitle: 'Space Book',
    };
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article] });
        }
        if (type === 'listening.open') {
          return ok(message.id, type, {
            article,
            items: [
              { index: 0, english: article.sentences[0], chinese: '汤姆发现了一个明亮的零食盒。' },
              { index: 1, english: article.sentences[1], chinese: '他把它分享给自己的队友。' },
            ],
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: article.id,
            enabled: true,
            status: 'ready',
            pages: [
              {
                articleId: article.id,
                pageIndex: 0,
                sentenceStartIndex: 0,
                sentenceEndIndex: 1,
                paragraphText: article.content,
                imagePath: 'ready.png',
                imageUri: 'data:image/png;base64,READY',
                status: 'ready',
              },
            ],
          });
        }
        if (type === 'listening.fullscreenReady') {
          return ok(message.id, type, {
            ready: true,
            reasons: [],
            requiredEnglish: 2,
            readyEnglish: 2,
            requiredChinese: 0,
            readyChinese: 0,
            missingEnglish: [],
            missingChinese: [],
            failed: 0,
          });
        }
        if (type === 'recording.settings.load') {
          return ok(message.id, type, {
            codec: 'h264',
            resolution: '1920x1080',
            pageTransition: 'none',
            subtitleMode: 'srt',
            outputDirectory: 'F:\\Tomato\\recording-export',
            fps: 25,
          });
        }
        if (type === 'recording.settings.save') {
          return ok(message.id, type, {
            codec: String(payload.codec ?? 'h264'),
            resolution: String(payload.resolution ?? '1920x1080'),
            pageTransition: String(payload.pageTransition ?? 'none'),
            subtitleMode: String(payload.subtitleMode ?? 'srt'),
            outputDirectory: 'F:\\Tomato\\recording-export',
            fps: 25,
          });
        }
        if (type === 'listening.recordingReady') {
          return ok(message.id, type, {
            ready: true,
            reasons: [],
            encoderName: 'ffmpeg',
            codec: payload.codec,
            resolution: payload.resolution,
            pageTransition: payload.pageTransition,
            subtitleMode: payload.subtitleMode,
            outputDirectory: 'F:\\Tomato\\recording-export',
            requiredEnglish: 2,
            readyEnglish: 2,
            requiredChinese: 0,
            readyChinese: 0,
            missingEnglish: [],
            missingChinese: [],
            failed: 0,
          });
        }
        if (type === 'listening.recordVideo') {
          return ok(message.id, type, {
            articleId: article.id,
            videoPath: 'F:\\Tomato\\recording-export\\listening.mp4',
            subtitlePath: 'F:\\Tomato\\recording-export\\listening.srt',
            durationMs: 3200,
            frameCount: 80,
            droppedFrameCount: 0,
            codec: payload.codec,
            resolution: payload.resolution,
            warnings: [],
          });
        }
        if (type === 'listening.prepare' || type === 'listening.play' || type === 'listening.playSequence' || type === 'listening.stop') {
          return ok(message.id, type, { playbackState: 'success', prepared: true, stopped: true });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' })).toBeInTheDocument();
    expect(screen.getAllByRole('button', { name: 'bright' })).toHaveLength(1);
    expect(screen.getAllByText('汤姆发现了一个明亮的零食盒。').length).toBeGreaterThan(0);
    expect(screen.getByRole('button', { name: /开始播放/ })).not.toBeDisabled();
    expect(screen.getByText(/听力进度/)).toBeInTheDocument();
    expect(document.querySelector('.picture-book-scene')).toBeInTheDocument();
    expect(document.querySelector('.listening-side')).not.toBeInTheDocument();

    expect(screen.queryByRole('button', { name: '中英对照' })).not.toBeInTheDocument();
    expect(screen.queryByText('会按顺序播放英文，再播放中文对照。')).not.toBeInTheDocument();
    expect(screen.queryByText('中英对照听力')).not.toBeInTheDocument();
    expect(document.querySelector('.listening-page .waveform')).not.toBeInTheDocument();
    expect(document.querySelector('.listening-page .wave-mini')).not.toBeInTheDocument();

    fireEvent.click(screen.getByText('He shares it with his team.').closest('.listening-row') as HTMLElement);
    fireEvent.click(screen.getByRole('button', { name: /开始播放/ }));

    await waitFor(() => {
      const playCalls = calls.filter((call) => call.type === 'listening.playSequence');
      expect(playCalls.length).toBeGreaterThan(0);
      expect(playCalls[0]?.payload).toMatchObject({ startIndex: 1, mode: 'english' });
    });
    expect(calls.some((call) => call.type === 'listening.preloadChinese')).toBe(false);

    const exportButton = await screen.findByRole('button', { name: /导出视频/ });
    await waitFor(() => expect(exportButton).not.toBeDisabled());
    fireEvent.click(screen.getByRole('button', { name: /复制全文/ }));
    await waitFor(() => expect(clipboard.writeText).toHaveBeenCalledTimes(1));
    const copiedText = String(clipboard.writeText.mock.calls[0]?.[0] ?? '');
    expect(copiedText.split('\n').slice(0, 2)).toEqual(['Space Book', 'Space Snacks']);
    expect(copiedText).not.toContain('书名：');
    expect(copiedText).not.toContain('章节：');
    expect(copiedText).not.toContain('1. Tom finds a bright snack box.');
    expect(copiedText).toContain('Tom finds a bright snack box.');
    expect(copiedText).toContain('汤姆发现了一个明亮的零食盒。');

    fireEvent.click(exportButton);
    const dialog = await screen.findByRole('dialog', { name: '录制视频设置' });
    expect(
      within(dialog).getByText('文件将保存到程序目录 recording-export 的分类子目录。'),
    ).toBeInTheDocument();
    chooseRecordingOption(dialog, '转场', '卷边翻页');
    chooseRecordingOption(dialog, '字幕', '两版视频 + SRT');
    fireEvent.click(within(dialog).getByRole('button', { name: '开始录制' }));

    await waitFor(() => {
      expect(calls.find((call) => call.type === 'recording.settings.save')?.payload).toMatchObject({
        codec: 'h264',
        resolution: '1920x1080',
        pageTransition: 'pageCurl',
        subtitleMode: 'both',
      });
      expect(calls.find((call) => call.type === 'listening.recordVideo')?.payload).toMatchObject({
        articleId: 1,
        codec: 'h264',
        resolution: '1920x1080',
        pageTransition: 'pageCurl',
        subtitleMode: 'both',
      });
    });
    act(() => {
      window.__tomatoNativeEvent?.({
        type: 'listening.recording.completed',
        payload: {
          articleId: 1,
          videoPath: 'F:\\Tomato\\recording-export\\subtitled\\listening-subtitled.mp4',
          subtitlePath: 'F:\\Tomato\\recording-export\\srt\\listening-srt.srt',
          videoVariants: [
            {
              kind: 'srt',
              videoPath: 'F:\\Tomato\\recording-export\\srt\\listening-srt.mp4',
              subtitlePath: 'F:\\Tomato\\recording-export\\srt\\listening-srt.srt',
            },
            {
              kind: 'subtitled',
              videoPath: 'F:\\Tomato\\recording-export\\subtitled\\listening-subtitled.mp4',
              subtitlePath: '',
            },
          ],
          durationMs: 3200,
          frameCount: 80,
          droppedFrameCount: 0,
          encoderName: 'ffmpeg',
          codec: 'h264',
          resolution: '1920x1080',
          pageTransition: 'pageCurl',
          warnings: [],
        },
      });
    });
    expect(await screen.findByText('无内置字幕视频：F:\\Tomato\\recording-export\\srt\\listening-srt.mp4')).toBeInTheDocument();
    expect(screen.getByText('字幕：F:\\Tomato\\recording-export\\srt\\listening-srt.srt')).toBeInTheDocument();
    expect(screen.getByText('内置字幕视频：F:\\Tomato\\recording-export\\subtitled\\listening-subtitled.mp4')).toBeInTheDocument();
  });

  it('keeps subtitle editing on listening rows but not on the picture subtitle overlay', async () => {
    window.location.hash = '/listen/1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box. He shares it with his team.',
      sentences: ['Tom finds a bright snack box.', 'He shares it with his team.'],
      sentenceCount: 2,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series: [] });
        }
        if (type === 'listening.open') {
          return ok(message.id, type, {
            article,
            items: [
              { index: 0, english: article.sentences[0], chinese: '汤姆发现了一个明亮的零食盒。' },
              { index: 1, english: article.sentences[1], chinese: '他把它分享给自己的队友。' },
            ],
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: article.id,
            enabled: true,
            status: 'ready',
            pages: [],
          });
        }
        if (type === 'listening.updateSentence') {
          const updatedArticle = {
            ...article,
            content: 'Tom finds a silver snack box. He shares it with his team.',
            sentences: ['Tom finds a silver snack box.', 'He shares it with his team.'],
          };
          return ok(message.id, type, {
            article: updatedArticle,
            item: {
              index: 0,
              english: 'Tom finds a silver snack box.',
              chinese: '汤姆发现了一个银色的零食盒。',
            },
            items: [
              { index: 0, english: 'Tom finds a silver snack box.', chinese: '汤姆发现了一个银色的零食盒。' },
              { index: 1, english: article.sentences[1], chinese: '他把它分享给自己的队友。' },
            ],
            synthesis: { status: 'error', error: 'TTS 内容安全拒绝' },
            articles: [updatedArticle],
            series: [],
          });
        }
        if (type === 'listening.resynthesizeSentence') {
          return ok(message.id, type, {
            item: {
              index: 0,
              english: 'Tom finds a silver snack box.',
              chinese: '汤姆发现了一个银色的零食盒。',
            },
            synthesis: { status: 'ready', english: 'ready', chinese: 'ready', error: '' },
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' })).toBeInTheDocument();
    const pictureSubtitle = document.querySelector('.picture-book-subtitle-line.english');
    expect(pictureSubtitle).toBeTruthy();
    expect(
      within(pictureSubtitle as HTMLElement).queryByRole('button', { name: '修改第 1 句字幕' }),
    ).not.toBeInTheDocument();

    const firstRowEdit = screen.getByRole('button', { name: '修改第 1 句字幕' });
    fireEvent.click(firstRowEdit);

    expect(await screen.findByRole('dialog', { name: '修改字幕' })).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText('英文'), {
      target: { value: 'Tom finds a silver snack box.' },
    });
    fireEvent.change(screen.getByLabelText('中文'), {
      target: { value: '汤姆发现了一个银色的零食盒。' },
    });
    fireEvent.click(screen.getByRole('button', { name: /保存/ }));

    await waitFor(() => {
      expect(calls.find((call) => call.type === 'listening.updateSentence')?.payload).toMatchObject({
        articleId: 1,
        index: 0,
        english: 'Tom finds a silver snack box.',
        chinese: '汤姆发现了一个银色的零食盒。',
      });
    });
    expect(await screen.findByText('TTS 内容安全拒绝')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: '重新合成语音' }));
    await waitFor(() => {
      expect(calls.find((call) => call.type === 'listening.resynthesizeSentence')?.payload).toMatchObject({
        articleId: 1,
        index: 0,
        part: 'both',
      });
    });
    await waitFor(() => {
      expect(screen.queryByText('TTS 内容安全拒绝')).not.toBeInTheDocument();
    });
  });

  it('hides a listening sentence when english is cleared after confirmation', async () => {
    window.location.hash = '/listen/1';

    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'First line. Second line. Third line.',
      sentences: ['First line.', 'Second line.', 'Third line.'],
      sentenceCount: 3,
      visibleSentenceCount: 3,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series: [] });
        }
        if (type === 'listening.open') {
          return ok(message.id, type, {
            article,
            items: [
              { index: 0, english: article.sentences[0], chinese: '第一句。' },
              { index: 1, english: article.sentences[1], chinese: '第二句。' },
              { index: 2, english: article.sentences[2], chinese: '第三句。' },
            ],
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: article.id,
            enabled: false,
            status: 'empty',
            pages: [],
          });
        }
        if (type === 'listening.updateSentence') {
          const hiddenIndex = Number(payload.index ?? 1);
          const updatedArticle = {
            ...article,
            content: 'First line. Third line.',
            sentences: ['First line.', '', 'Third line.'],
            visibleSentenceCount: 2,
          };
          return ok(message.id, type, {
            article: updatedArticle,
            item: {
              index: hiddenIndex,
              english: '',
              chinese: '',
              hidden: true,
            },
            items: [
              { index: 0, english: 'First line.', chinese: '第一句。' },
              { index: 1, english: '', chinese: '', hidden: true },
              { index: 2, english: 'Third line.', chinese: '第三句。' },
            ],
            synthesis: { status: 'ready', english: 'cleared', chinese: 'cleared', error: '' },
            articles: [updatedArticle],
            series: [],
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByRole('heading', { name: 'First line.' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '修改第 2 句字幕' }));
    expect(await screen.findByRole('dialog', { name: '修改字幕' })).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText('英文'), { target: { value: '' } });
    fireEvent.change(screen.getByLabelText('中文'), { target: { value: '' } });
    fireEvent.click(screen.getByRole('button', { name: '隐藏本句' }));
    await cancelConfirmDialog(
      '隐藏字幕确认',
      '槽位编号不变，歌曲字幕不变。稍后重新填入英文即可恢复。',
    );
    expect(calls.some((call) => call.type === 'listening.updateSentence')).toBe(false);

    fireEvent.click(screen.getByRole('button', { name: '隐藏本句' }));
    await confirmDialogAction(
      '隐藏字幕确认',
      '确定隐藏',
      '槽位编号不变，歌曲字幕不变。稍后重新填入英文即可恢复。',
    );

    await waitFor(() => {
      expect(calls.find((call) => call.type === 'listening.updateSentence')?.payload).toMatchObject({
        articleId: 1,
        index: 1,
        english: '',
        chinese: '',
      });
    });
    expect(await screen.findByText('（已隐藏）')).toBeInTheDocument();
  });

  it('enables fullscreen listening only after audio and picture preloading are ready', async () => {
    window.location.hash = '/listen/1';
    class InstantImage {
      decoding = '';
      complete = true;
      naturalWidth = 1280;
      onload: (() => void) | null = null;
      onerror: (() => void) | null = null;
      set src(_value: string) {
        queueMicrotask(() => this.onload?.());
      }
      decode() {
        return Promise.resolve();
      }
    }
    vi.stubGlobal('Image', InstantImage);

    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box. He shares it with his team.',
      sentences: ['Tom finds a bright snack box.', 'He shares it with his team.'],
      sentenceCount: 2,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    let audioReady = false;
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series: [] });
        }
        if (type === 'listening.open') {
          return ok(message.id, type, {
            article,
            items: [
              { index: 0, english: article.sentences[0], chinese: '汤姆发现了一个明亮的零食盒。' },
              { index: 1, english: article.sentences[1], chinese: '他把它分享给自己的队友。' },
            ],
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: article.id,
            enabled: true,
            status: 'ready',
            pages: [
              {
                articleId: article.id,
                pageIndex: 0,
                sentenceStartIndex: 0,
                sentenceEndIndex: 1,
                paragraphText: article.content,
                imagePath: 'ready.png',
                imageUri: 'data:image/png;base64,THUMBNAIL',
                imageVariant: 'thumbnail',
                status: 'ready',
              },
            ],
          });
        }
        if (type === 'pictureBook.pageImage') {
          return ok(message.id, type, {
            articleId: article.id,
            pageIndex: Number(payload.pageIndex ?? 0),
            variant: payload.variant,
            imageUri: 'data:image/png;base64,FULL',
          });
        }
        if (type === 'listening.fullscreenReady') {
          return ok(message.id, type, {
            ready: audioReady,
            reasons: audioReady ? [] : ['当前和下一句英文音频文件还没有预热完成'],
            requiredEnglish: 2,
            readyEnglish: audioReady ? 2 : 1,
            requiredChinese: 0,
            readyChinese: 0,
            missingEnglish: audioReady ? [] : [1],
            missingChinese: [],
            failed: 0,
          });
        }
        if (type === 'listening.playSequence') {
          window.__tomatoNativeEvent?.({
            type: 'listening.playback',
            payload: { articleId: 1, index: 0, part: 'english', state: 'partStart' },
          });
          return new Promise<BridgeResponse>(() => undefined);
        }
        if (type === 'listening.pause' || type === 'listening.resume' || type === 'listening.stop') {
          return ok(message.id, type, { paused: true, resumed: true, stopped: true });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' })).toBeInTheDocument();
    const fullscreenButton = await screen.findByRole('button', { name: /全屏播放/ });
    await waitFor(() => expect(fullscreenButton).toBeDisabled());
    expect(await screen.findByText('当前和下一句英文音频文件还没有预热完成')).toBeInTheDocument();
    await waitFor(() => {
      // The inline (non-fullscreen) scene view only ever requests the "display" resolution;
      // the raw "full" original is reserved for true fullscreen playback to avoid WebView2
      // GPU downscale artifacts when a large image is squeezed into a small on-screen box.
      expect(calls.find((call) => call.type === 'pictureBook.pageImage')?.payload).toMatchObject({
        articleId: 1,
        pageIndex: 0,
        variant: 'display',
      });
    });

    audioReady = true;
    act(() => {
      window.__tomatoNativeEvent?.({
        type: 'preload.state',
        payload: {
          articleId: 1,
          mode: 'listening',
          scope: 'english',
          runId: 'listening_english_1_1',
          status: 'complete',
          completed: 2,
          total: 2,
          failed: 0,
        },
      });
    });

    await waitFor(() => expect(fullscreenButton).not.toBeDisabled());
    fireEvent.click(fullscreenButton);
    const fullscreenDialog = await screen.findByRole('dialog', { name: '全屏听力播放' });
    expect(fullscreenDialog).toBeInTheDocument();
    expect(fullscreenDialog.parentElement).toBe(document.body);
    expect(fullscreenDialog.querySelector('.fullscreen-listening-frame')).toBeInTheDocument();
    const fullscreenToolbar = fullscreenDialog.querySelector('.fullscreen-listening-toolbar') as HTMLElement;
    expect(fullscreenDialog).toHaveClass('controls-hidden');
    expect(fullscreenDialog).toHaveClass('cursor-hidden');
    expect(fullscreenToolbar).toHaveAttribute('aria-hidden', 'true');

    await waitFor(() => {
      const playCall = calls.find((call) => call.type === 'listening.playSequence');
      expect(playCall?.payload).toMatchObject({
        startIndex: 0,
        mode: 'english',
        singleItem: false,
      });
    });

    // Fullscreen playback reuses the already-loaded "display" bitmap; the WebView must
    // never request the raw "full" original (GPU downscale corruption on Windows).
    expect(
      calls.some(
        (call) => call.type === 'pictureBook.pageImage' && call.payload.variant === 'full',
      ),
    ).toBe(false);

    vi.useFakeTimers();
    fireEvent.pointerMove(fullscreenDialog);
    expect(fullscreenDialog).toHaveClass('cursor-visible');
    act(() => {
      vi.advanceTimersByTime(2000);
    });
    expect(fullscreenDialog).toHaveClass('cursor-hidden');

    fireEvent.click(fullscreenDialog);
    expect(fullscreenDialog).toHaveClass('controls-visible');
    expect(fullscreenToolbar).toHaveAttribute('aria-hidden', 'false');
    act(() => {
      vi.advanceTimersByTime(3000);
    });
    expect(fullscreenDialog).toHaveClass('controls-hidden');
    expect(fullscreenToolbar).toHaveAttribute('aria-hidden', 'true');

    fireEvent.click(fullscreenDialog);
    const pauseButton = within(fullscreenDialog).getByRole('button', { name: '暂停' });
    fireEvent.click(pauseButton);
    await act(async () => {
      await Promise.resolve();
    });
    expect(calls.some((call) => call.type === 'listening.pause')).toBe(true);
    act(() => {
      vi.advanceTimersByTime(3000);
    });
    expect(fullscreenDialog).toHaveClass('controls-visible');
    expect(fullscreenToolbar).toHaveAttribute('aria-hidden', 'false');
  });

  it('exports listening video from the creation center video tab', async () => {
    window.location.hash = '/creation?articleId=1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box.',
      sentences: ['Tom finds a bright snack box.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    let videoVersions = [
      {
        id: 'video-new',
        articleId: article.id,
        videoPath: 'F:\\Tomato\\recording-export\\new.mp4',
        subtitlePath: 'F:\\Tomato\\recording-export\\new.srt',
        createdAt: '2026-06-17T05:07:00.000Z',
        source: 'listening',
        title: 'New Video',
        isDefault: true,
        durationMs: 3200,
        codec: 'h264',
        resolution: '1920x1080',
      },
      {
        id: 'video-old',
        articleId: article.id,
        videoPath: 'F:\\Tomato\\recording-export\\old.mp4',
        subtitlePath: 'F:\\Tomato\\recording-export\\old.srt',
        createdAt: '2026-06-17T04:30:00.000Z',
        source: 'listening',
        title: 'Old Video',
        isDefault: false,
        durationMs: 2800,
        codec: 'h264',
        resolution: '1280x720',
      },
    ];
    let resolveRecordVideo: (() => void) | null = null;
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series: [] });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: article.id,
            enabled: true,
            status: 'ready',
            pages: [
              {
                articleId: article.id,
                pageIndex: 0,
                sentenceStartIndex: 0,
                sentenceEndIndex: 0,
                paragraphText: article.content,
                imagePath: 'ready.png',
                imageUri: 'data:image/png;base64,READY',
                status: 'ready',
              },
            ],
          });
        }
        if (type === 'recording.videoList') {
          return ok(message.id, type, {
            articleId: article.id,
            outputDirectory: 'F:\\Tomato\\recording-export',
            versions: videoVersions,
          });
        }
        if (type === 'recording.videoSetDefault') {
          const videoId = String(payload.videoId ?? '');
          videoVersions = videoVersions.map((version) => ({
            ...version,
            isDefault: version.id === videoId,
          }));
          return ok(message.id, type, {
            articleId: article.id,
            outputDirectory: 'F:\\Tomato\\recording-export',
            versions: videoVersions,
          });
        }
        if (type === 'recording.videoPlay') {
          return ok(message.id, type, {
            played: true,
            articleId: article.id,
            videoId: payload.videoId,
            videoPath: 'F:\\Tomato\\recording-export\\new.mp4',
          });
        }
        if (type === 'recording.videoOpenDirectory') {
          return ok(message.id, type, {
            opened: true,
            articleId: article.id,
            outputDirectory: 'F:\\Tomato\\recording-export',
          });
        }
        if (type === 'recording.videoDelete') {
          const videoId = String(payload.videoId ?? '');
          videoVersions = videoVersions.filter((version) => version.id !== videoId);
          if (videoVersions.length > 0 && !videoVersions.some((version) => version.isDefault)) {
            videoVersions = videoVersions.map((version, index) => ({ ...version, isDefault: index === 0 }));
          }
          return ok(message.id, type, {
            articleId: article.id,
            outputDirectory: 'F:\\Tomato\\recording-export',
            versions: videoVersions,
          });
        }
        if (type === 'recording.settings.load') {
          return ok(message.id, type, {
            codec: 'h264',
            resolution: '1920x1080',
            pageTransition: 'crossFade',
            subtitleMode: 'srt',
            outputDirectory: 'F:\\Tomato\\recording-export',
            fps: 25,
          });
        }
        if (type === 'recording.settings.save') {
          return ok(message.id, type, {
            codec: String(payload.codec ?? 'h264'),
            resolution: String(payload.resolution ?? '1920x1080'),
            pageTransition: String(payload.pageTransition ?? 'crossFade'),
            subtitleMode: String(payload.subtitleMode ?? 'srt'),
            outputDirectory: 'F:\\Tomato\\recording-export',
            fps: 25,
          });
        }
        if (type === 'listening.recordingReady') {
          return ok(message.id, type, {
            ready: true,
            reasons: [],
            encoderName: 'ffmpeg',
            codec: 'h264',
            resolution: '1920x1080',
            pageTransition: 'crossFade',
            subtitleMode: 'srt',
            outputDirectory: 'F:\\Tomato\\recording-export',
            requiredEnglish: 1,
            readyEnglish: 1,
            requiredChinese: 0,
            readyChinese: 0,
            missingEnglish: [],
            missingChinese: [],
            failed: 0,
          });
        }
        if (type === 'listening.recordVideo') {
          videoVersions = [
            {
              id: 'video-exported',
              articleId: article.id,
              videoPath: 'F:\\Tomato\\recording-export\\listening.mp4',
              subtitlePath: 'F:\\Tomato\\recording-export\\listening.srt',
              createdAt: '2026-06-17T06:00:00.000Z',
              source: 'listening',
              title: 'Exported Video',
              isDefault: false,
              durationMs: 3200,
              codec: 'h264',
              resolution: '1920x1080',
            },
            ...videoVersions,
          ];
          const response = ok(message.id, type, {
            outputPath: 'F:\\Tomato\\recording-export\\listening.mp4',
            durationMs: 3200,
            segments: 1,
          });
          return new Promise<BridgeResponse>((resolve) => {
            resolveRecordVideo = () => resolve(response);
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByText('我的书籍')).toBeInTheDocument();
    expect(screen.queryByText('创作面板')).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '资源库' })).not.toBeInTheDocument();
    await clickSelectedCreationAction('视频');
    const videoList = await screen.findByLabelText('已导出视频版本');
    expect(screen.queryByText('保存在 recording-export/')).not.toBeInTheDocument();
    expect(screen.queryByText('素材来源')).not.toBeInTheDocument();
    expect(screen.queryByText('听力视频已准备好')).not.toBeInTheDocument();
    expect(within(videoList).getByText('2 个版本')).toBeInTheDocument();
    fireEvent.click(await screen.findByRole('button', { name: /打开保存目录/ }));
    await waitFor(() => {
      expect(calls.some((call) => call.type === 'recording.videoOpenDirectory' && call.payload.articleId === 1)).toBe(true);
    });
    fireEvent.click(within(videoList).getAllByRole('button', { name: /播放视频：/ })[0]);
    await waitFor(() => {
      expect(calls.some((call) => call.type === 'recording.videoPlay' && call.payload.videoId === 'video-new')).toBe(true);
    });
    fireEvent.click(within(videoList).getByRole('button', { name: /设为默认播放视频：/ }));
    await waitFor(() => {
      expect(calls.some((call) => call.type === 'recording.videoSetDefault' && call.payload.videoId === 'video-old')).toBe(true);
    });
    fireEvent.click(within(videoList).getAllByRole('button', { name: /删除视频：/ })[0]);
    await confirmDialogAction('删除视频确认', '删除', /确定删除视频“.+”？此操作会删除本地视频文件和字幕文件，不能撤销。/);
    await waitFor(() => {
      expect(calls.some((call) => call.type === 'recording.videoDelete' && call.payload.videoId === 'video-new')).toBe(true);
    });
    expect(await within(videoList).findByText('1 个版本')).toBeInTheDocument();
    const exportButton = await screen.findByRole('button', { name: /导出听力视频/ });
    await waitFor(() => expect(exportButton).not.toBeDisabled());
    fireEvent.click(exportButton);
    const dialog = await screen.findByRole('dialog', { name: '录制视频设置' });
    chooseRecordingOption(dialog, '转场', '卷边翻页');
    chooseRecordingOption(dialog, '字幕', '两版视频 + SRT');
    fireEvent.click(within(dialog).getByRole('button', { name: '开始录制' }));

    await waitFor(() => {
      const readyCall = calls.find((call) => call.type === 'listening.recordingReady');
      expect(readyCall?.payload).toMatchObject({
        articleId: 1,
        codec: 'h264',
        resolution: '1920x1080',
        pageTransition: 'crossFade',
        subtitleMode: 'srt',
      });
      expect(calls.find((call) => call.type === 'recording.settings.save')?.payload).toMatchObject({
        codec: 'h264',
        resolution: '1920x1080',
        pageTransition: 'pageCurl',
        subtitleMode: 'both',
      });
      const recordCall = calls.find((call) => call.type === 'listening.recordVideo');
      expect(recordCall?.payload).toMatchObject({
        articleId: 1,
        codec: 'h264',
        resolution: '1920x1080',
        pageTransition: 'pageCurl',
        subtitleMode: 'both',
      });
    });
    expect(await screen.findByText('正在导出听力视频')).toBeInTheDocument();
    expect(screen.getByText(/预计超时倒计时/)).toBeInTheDocument();
    await act(async () => {
      resolveRecordVideo?.();
    });
    expect(await screen.findByText('听力视频导出完成')).toBeInTheDocument();
    await waitFor(() => expect(screen.queryByText('正在导出听力视频')).not.toBeInTheDocument());
    expect(await within(videoList).findByText('2 个版本')).toBeInTheDocument();
    expect(screen.queryByRole('dialog', { name: '录制视频设置' })).not.toBeInTheDocument();
  });

  it('keeps creation-center listening video export clickable while settings and readiness are loading', async () => {
    window.location.hash = '/creation?articleId=7';
    const article = {
      id: 7,
      title: 'Slow Readiness',
      content: 'Tom waits for the video check.',
      sentences: ['Tom waits for the video check.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 80,
    };
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    let resolveSettings: (() => void) | null = null;
    let resolveReady: (() => void) | null = null;
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series: [] });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: article.id,
            enabled: true,
            status: 'ready',
            pages: [
              {
                articleId: article.id,
                pageIndex: 0,
                sentenceStartIndex: 0,
                sentenceEndIndex: 0,
                paragraphText: article.content,
                imagePath: 'ready.png',
                imageUri: 'data:image/png;base64,READY',
                status: 'ready',
              },
            ],
          });
        }
        if (type === 'recording.settings.load') {
          return new Promise<BridgeResponse>((resolve) => {
            resolveSettings = () =>
              resolve(
                ok(message.id, type, {
                  codec: 'h264',
                  resolution: '1920x1080',
                  pageTransition: 'crossFade',
                  subtitleMode: 'srt',
                  outputDirectory: 'F:\\Tomato\\recording-export',
                  fps: 25,
                }),
              );
          });
        }
        if (type === 'recording.videoList') {
          return ok(message.id, type, {
            articleId: article.id,
            outputDirectory: 'F:\\Tomato\\recording-export',
            versions: [],
          });
        }
        if (type === 'listening.audioStatus') {
          return ok(message.id, type, {
            articleId: article.id,
            total: 1,
            ready: 0,
            missing: [0],
            failed: 0,
            status: 'missing',
          });
        }
        if (type === 'listening.audioGenerate') {
          return ok(message.id, type, {
            articleId: article.id,
            total: 1,
            ready: 1,
            missing: [],
            failed: 0,
            status: 'ready',
            requested: 1,
            overwrite: false,
          });
        }
        if (type === 'listening.recordingReady') {
          return new Promise<BridgeResponse>((resolve) => {
            resolveReady = () =>
              resolve(
                ok(message.id, type, {
                  ready: true,
                  reasons: [],
                  encoderName: 'ffmpeg',
                  codec: 'h264',
                  resolution: '1920x1080',
                  pageTransition: 'crossFade',
                  subtitleMode: 'srt',
                  outputDirectory: 'F:\\Tomato\\recording-export',
                  requiredEnglish: 1,
                  readyEnglish: 1,
                  requiredChinese: 0,
                  readyChinese: 0,
                  missingEnglish: [],
                  missingChinese: [],
                  failed: 0,
                }),
              );
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    await clickSelectedCreationAction('视频');
    await waitFor(() => {
      expect(calls.some((call) => call.type === 'listening.recordingReady')).toBe(true);
    });
    expect(calls.some((call) => call.type === 'recording.settings.load')).toBe(true);
    const exportButton = await screen.findByRole('button', { name: /导出听力视频/ });
    expect(exportButton).not.toBeDisabled();
    expect(screen.getByRole('button', { name: /检查中/ })).toBeDisabled();
    expect(await screen.findByText('0 / 1 已生成 · 缺 1 句')).toBeInTheDocument();

    const videoPanel = screen.getByText('视频导出').closest('.creation-panel') as HTMLElement;
    expect(screen.queryByLabelText('可导出歌曲视频版本')).not.toBeInTheDocument();
    expect(within(videoPanel).queryByRole('button', { name: /导出歌曲视频/ })).not.toBeInTheDocument();
    fireEvent.click(within(videoPanel).getByRole('button', { name: /生成听力/ }));
    await waitFor(() => {
      expect(calls.find((call) => call.type === 'listening.audioGenerate')?.payload).toMatchObject({
        articleId: article.id,
        overwrite: false,
      });
    });
    expect(await screen.findByText('听力材料已生成')).toBeInTheDocument();
    await waitFor(() => {
      expect(calls.filter((call) => call.type === 'listening.recordingReady').length).toBeGreaterThanOrEqual(2);
    });

    fireEvent.click(exportButton);
    expect(await screen.findByRole('dialog', { name: '录制视频设置' })).toBeInTheDocument();

    await act(async () => {
      resolveSettings?.();
      resolveReady?.();
    });
  });

  it('allows switching books in the creation center after opening from a routed book', async () => {
    window.location.hash = '/creation?seriesId=1&articleId=1';
    const now = new Date().toISOString();
    const alphaArticle = {
      id: 1,
      title: 'Alpha Creation Chapter',
      content: 'Alpha starts.',
      sentences: ['Alpha starts.'],
      sentenceCount: 1,
      createdAt: now,
      averageScore: 80,
      seriesId: 1,
      seriesTitle: 'Alpha Book',
    };
    const betaArticle = {
      id: 2,
      title: 'Beta Creation Chapter',
      content: 'Beta starts.',
      sentences: ['Beta starts.'],
      sentenceCount: 1,
      createdAt: now,
      averageScore: 92,
      seriesId: 2,
      seriesTitle: 'Beta Book',
    };
    const series = [
      {
        id: 1,
        title: 'Alpha Book',
        description: '',
        coverImagePath: null,
        createdAt: now,
        updatedAt: now,
      },
      {
        id: 2,
        title: 'Beta Book',
        description: '',
        coverImagePath: null,
        createdAt: now,
        updatedAt: now,
      },
    ];

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        if (type === 'app.ready' || type === 'article.list') {
          return {
            id: String(message.id),
            ok: true,
            type: `${type}.result`,
            payload: { articles: [alphaArticle, betaArticle], series },
          };
        }
        if (type === 'pictureBook.state') {
          return {
            id: String(message.id),
            ok: true,
            type: `${type}.result`,
            payload: { articleId: Number(payload.articleId), enabled: true, status: 'empty', pages: [] },
          };
        }
        return {
          id: String(message.id),
          ok: true,
          type: `${type}.result`,
          payload: {},
        };
      }),
    };

    render(<App />);

    await waitFor(() => expect(screen.getAllByText('Alpha Creation Chapter').length).toBeGreaterThan(0));
    expect(screen.queryAllByText('Beta Creation Chapter')).toHaveLength(0);

    fireEvent.click(screen.getByRole('button', { name: /Beta Book/ }));

    await waitFor(() => expect(screen.getAllByText('Beta Creation Chapter').length).toBeGreaterThan(0));
    expect(screen.queryAllByText('Alpha Creation Chapter')).toHaveLength(0);
  });

  it('loads creation center picture-book images as persisted thumbnails after metadata', async () => {
    window.location.hash = '/creation?articleId=1';
    const clipboard = { writeText: vi.fn().mockResolvedValue(undefined) };
    Object.defineProperty(navigator, 'clipboard', {
      value: clipboard,
      configurable: true,
    });
    const now = new Date().toISOString();
    const article = {
      id: 1,
      title: 'Thumbnail Chapter',
      content: 'Tom finds a bright snack box. He shares it with his team.',
      sentences: ['Tom finds a bright snack box.', 'He shares it with his team.'],
      sentenceCount: 2,
      createdAt: now,
      averageScore: 86,
      seriesId: 1,
      seriesTitle: 'Thumbnail Book',
      chapterOrder: 1,
    };
    const series = [
      {
        id: 1,
        title: 'Thumbnail Book',
        description: '',
        coverImagePath: null,
        createdAt: now,
        updatedAt: now,
      },
    ];
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: article.id,
            enabled: true,
            status: 'ready',
            pages: [
              {
                articleId: article.id,
                seriesId: 1,
                pageIndex: 0,
                sentenceStartIndex: 0,
                sentenceEndIndex: 0,
                paragraphText: article.sentences[0],
                imagePath: 'F:/Tomato/picture_book/original-0.png',
                imageUri: null,
                status: 'ready',
                errorMessage: null,
              },
              {
                articleId: article.id,
                seriesId: 1,
                pageIndex: 1,
                sentenceStartIndex: 1,
                sentenceEndIndex: 1,
                paragraphText: article.sentences[1],
                imagePath: 'F:/Tomato/picture_book/original-1.png',
                imageUri: null,
                status: 'ready',
                errorMessage: null,
              },
            ],
          });
        }
        if (type === 'pictureBook.pageImage') {
          return ok(message.id, type, {
            articleId: article.id,
            pageIndex: Number(payload.pageIndex ?? 0),
            variant: payload.variant,
            imageUri: `data:image/png;base64,THUMBNAIL_${payload.pageIndex}`,
          });
        }
        if (type === 'article.fullText') {
          return ok(message.id, type, {
            article,
            bookTitle: 'Thumbnail Book',
            items: [
              { index: 0, english: article.sentences[0], chinese: '汤姆发现了一个明亮的零食盒。' },
              { index: 1, english: article.sentences[1], chinese: '他把它分享给自己的队友。' },
            ],
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByText('绘本组图')).toBeInTheDocument();
    await waitFor(() => {
      const stateCall = calls.find((call) => call.type === 'pictureBook.state');
      expect(stateCall?.payload).toMatchObject({
        articleId: 1,
        includeImageUris: false,
      });
    });
    await waitFor(() => {
      const pageImageCalls = calls.filter((call) => call.type === 'pictureBook.pageImage');
      expect(pageImageCalls).toHaveLength(2);
      expect(pageImageCalls.map((call) => call.payload)).toEqual([
        { articleId: 1, pageIndex: 0, variant: 'thumbnail' },
        { articleId: 1, pageIndex: 1, variant: 'thumbnail' },
      ]);
    });
    await waitFor(() => {
      const thumbnails = Array.from(document.querySelectorAll('.picture-creation-media img'))
        .map((image) => image.getAttribute('src'));
      expect(thumbnails).toEqual([
        'data:image/png;base64,THUMBNAIL_0',
        'data:image/png;base64,THUMBNAIL_1',
      ]);
    });

    fireEvent.click(screen.getByRole('button', { name: /刷新状态/ }));
    await waitFor(() => {
      const stateCalls = calls.filter((call) => call.type === 'pictureBook.state');
      expect(stateCalls.length).toBeGreaterThanOrEqual(2);
    });
    await waitFor(() => {
      const thumbnails = Array.from(document.querySelectorAll('.picture-creation-media img'))
        .map((image) => image.getAttribute('src'));
      expect(thumbnails).toEqual([
        'data:image/png;base64,THUMBNAIL_0',
        'data:image/png;base64,THUMBNAIL_1',
      ]);
    });
    expect(screen.queryByText('加载缩略图')).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: /复制全文/ }));
    await waitFor(() => {
      expect(calls.find((call) => call.type === 'article.fullText')?.payload).toMatchObject({
        articleId: 1,
      });
      expect(clipboard.writeText).toHaveBeenCalledTimes(1);
    });
    const copiedText = String(clipboard.writeText.mock.calls[0]?.[0] ?? '');
    expect(copiedText.split('\n').slice(0, 2)).toEqual(['Thumbnail Book', 'Thumbnail Chapter']);
    expect(copiedText).not.toContain('书名：');
    expect(copiedText).not.toContain('章节：');
    expect(copiedText).not.toContain('2. He shares it with his team.');
    expect(copiedText).toContain('He shares it with his team.');
  });

  it('opens single-page picture prompt review from a creation page card', async () => {
    window.location.hash = '/creation?articleId=1';
    const now = new Date().toISOString();
    const article = {
      id: 1,
      title: 'Single Page Retry Chapter',
      content: 'Tom finds a bright snack box. He shares it with his team.',
      sentences: ['Tom finds a bright snack box.', 'He shares it with his team.'],
      sentenceCount: 2,
      createdAt: now,
      averageScore: 86,
      seriesId: 1,
      seriesTitle: 'Single Retry Book',
      chapterOrder: 1,
    };
    const series = [
      {
        id: 1,
        title: 'Single Retry Book',
        description: 'A warm space picture book with stable character design.',
        coverImagePath: null,
        createdAt: now,
        updatedAt: now,
      },
    ];
    const pictureState = {
      articleId: article.id,
      enabled: true,
      status: 'ready',
      pages: [
        {
          articleId: article.id,
          seriesId: 1,
          pageIndex: 0,
          sentenceStartIndex: 0,
          sentenceEndIndex: 0,
          paragraphText: article.sentences[0],
          prompt: {
            scene: {
              sceneDescription: 'Tom discovers the snack box.',
            },
          },
          imagePath: 'F:/Tomato/picture_book/original-0.png',
          imageUri: 'data:image/png;base64,THUMBNAIL_0',
          imageVariant: 'thumbnail',
          status: 'ready',
          errorMessage: null,
        },
        {
          articleId: article.id,
          seriesId: 1,
          pageIndex: 1,
          sentenceStartIndex: 1,
          sentenceEndIndex: 1,
          paragraphText: article.sentences[1],
          prompt: {
            scene: {
              sceneDescription: 'Tom shares the snack box with his team.',
            },
          },
          imagePath: 'F:/Tomato/picture_book/original-1.png',
          imageUri: 'data:image/png;base64,THUMBNAIL_1',
          imageVariant: 'thumbnail',
          status: 'ready',
          errorMessage: null,
        },
      ],
    };
    const singlePageReview = {
      ...promptReviewPayloadForTest(article.id, true),
      reviewId: 'page-review-1-1',
      mode: 'singlePage',
      targetPageIndex: 1,
      referencePageIndex: 0,
      referencePageIndexes: [0],
      referenceOptions: [0, 1],
      chapterDescription: 'Tom finds a snack box and shares it with the team.',
      groupPrompt:
        'Book name: Single Retry Book\nBook description: A warm space picture book with stable character design.\nChapter description: Tom finds a snack box and shares it with the team.\n\nGenerate exactly one picture for Image 2. Use the reference image only for visual consistency.\nDo not generate other scenes, a collage, comic panels, or a multi-image sheet.\n\nImage 2:\nScene description: Tom shares the snack box with his team.',
      scenes: [
        {
          pageIndex: 1,
          sentenceStartIndex: 1,
          sentenceEndIndex: 1,
          paragraphText: article.sentences[1],
          sceneDescription: 'Tom shares the snack box with his team.',
        },
      ],
    };
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list' || type === 'series.list') {
          return ok(message.id, type, { articles: [article], series });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, pictureState);
        }
        if (type === 'pictureBook.pageImage') {
          const pageIndex = Number(payload.pageIndex ?? 0);
          const page = pictureState.pages.find((item) => item.pageIndex === pageIndex);
          return ok(message.id, type, {
            articleId: Number(payload.articleId ?? 1),
            pageIndex,
            imagePath: page?.imagePath ?? '',
            imageUri: page?.imageUri ?? '',
            imageVariant: 'thumbnail',
          });
        }
        if (type === 'pictureBook.pagePromptReview') {
          return ok(message.id, type, singlePageReview);
        }
        if (type === 'pictureBook.confirmPagePromptReview') {
          return ok(message.id, type, {
            ...pictureState,
            status: 'generating',
            pages: pictureState.pages.map((page) =>
              page.pageIndex === 1 ? { ...page, status: 'generating' } : page,
            ),
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByText('绘本组图')).toBeInTheDocument();
    const pageTwoCard = (await screen.findByText('第 2 页')).closest('article');
    expect(pageTwoCard).not.toBeNull();
    fireEvent.click(within(pageTwoCard as HTMLElement).getByRole('button', { name: '重新生成' }));

    await waitFor(() => {
      expect(calls).toContainEqual({
        type: 'pictureBook.pagePromptReview',
        payload: { articleId: 1, pageIndex: 1 },
      });
    });

    const dialog = await screen.findByRole('dialog', { name: '绘本单页提示词审核' });
    expect(within(dialog).getByText('确认后只替换第 2 页')).toBeInTheDocument();
    expect(within(dialog).queryByRole('button', { name: 'AI 自动生成书籍简介' })).not.toBeInTheDocument();
    expect(within(dialog).queryByRole('button', { name: 'AI 自动生成章节描述和分镜描述' })).not.toBeInTheDocument();
    expect(within(dialog).queryByRole('button', { name: '保存提示词' })).not.toBeInTheDocument();
    expect(within(dialog).getByRole('heading', { name: '当前分镜描述' })).toBeInTheDocument();
    expect(within(dialog).getByLabelText('第 2 个分镜描述')).toHaveValue(
      'Tom shares the snack box with his team.',
    );
    expect(within(dialog).queryByLabelText('第 1 个分镜描述')).not.toBeInTheDocument();

    const promptInput = within(dialog).getByLabelText('单张生成提示词') as HTMLTextAreaElement;
    expect(promptInput.value).toContain('Generate exactly one picture');
    expect(promptInput.value).toContain('Image 2:');
    expect(promptInput.value).not.toContain('Image 1:');
    expect(within(dialog).getByRole('heading', { name: '参考图片' })).toBeInTheDocument();
    expect(within(dialog).getByRole('option', { name: '第 1 张' })).toHaveClass('is-selected');
    expect(within(dialog).getByRole('option', { name: '第 2 张（当前页）' })).toBeInTheDocument();
    expect(within(dialog).getByAltText('第 1 张')).toHaveAttribute('src', 'data:image/png;base64,THUMBNAIL_0');
    fireEvent.change(promptInput, {
      target: {
        value:
          'Edited single prompt\n\nGenerate exactly one picture for Image 2.\n\nImage 2:\nScene description: Tom shares the snack box under a glowing window.',
      },
    });
    fireEvent.click(within(dialog).getByRole('button', { name: '生成这一张' }));

    await waitFor(() => {
      const confirmCall = calls.find((call) => call.type === 'pictureBook.confirmPagePromptReview');
      expect(confirmCall?.payload).toMatchObject({
        reviewId: 'page-review-1-1',
        referencePageIndex: 0,
        referencePageIndexes: [0],
        groupPrompt:
          'Edited single prompt\n\nGenerate exactly one picture for Image 2.\n\nImage 2:\nScene description: Tom shares the snack box under a glowing window.',
        scenes: [
          expect.objectContaining({
            pageIndex: 1,
            sceneDescription: 'Tom shares the snack box with his team.',
          }),
        ],
      });
    });
    expect(calls.some((call) => call.type === 'pictureBook.confirmPromptReview')).toBe(false);
  });

  it('submits multiple selected reference images in single-page prompt review', async () => {
    window.location.hash = '/creation?articleId=1';
    const now = new Date().toISOString();
    const article = {
      id: 1,
      title: 'Multi Reference Retry Book',
      content: 'Tom finds a snack box. He shares it with his team. They celebrate together.',
      sentences: [
        'Tom finds a snack box.',
        'He shares it with his team.',
        'They celebrate together.',
      ],
      sentenceCount: 3,
      createdAt: now,
      averageScore: 88,
      seriesId: 1,
      seriesTitle: 'Multi Reference Book',
      chapterOrder: 1,
    };
    const series = [{ id: 1, title: 'Multi Reference Book', description: 'A warm picture book.' }];
    const pictureState = {
      articleId: article.id,
      enabled: true,
      status: 'ready',
      pages: [0, 1, 2].map((pageIndex) => ({
        articleId: article.id,
        seriesId: 1,
        pageIndex,
        sentenceStartIndex: pageIndex,
        sentenceEndIndex: pageIndex,
        paragraphText: article.sentences[pageIndex],
        prompt: {
          scene: {
            sceneDescription: `Scene ${pageIndex + 1}`,
          },
        },
        imagePath: `F:/Tomato/picture_book/original-${pageIndex}.png`,
        imageUri: `data:image/png;base64,THUMBNAIL_${pageIndex}`,
        imageVariant: 'thumbnail',
        status: 'ready',
        errorMessage: null,
      })),
    };
    const singlePageReview = {
      ...promptReviewPayloadForTest(article.id, true),
      reviewId: 'page-review-1-2',
      mode: 'singlePage',
      targetPageIndex: 2,
      referencePageIndex: 1,
      referencePageIndexes: [1],
      referenceOptions: [0, 1, 2],
      chapterDescription: 'Tom shares snacks and celebrates with his team.',
      scenes: [
        {
          pageIndex: 2,
          sentenceStartIndex: 2,
          sentenceEndIndex: 2,
          paragraphText: article.sentences[2],
          sceneDescription: 'They celebrate together.',
        },
      ],
    };
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list' || type === 'series.list') {
          return ok(message.id, type, { articles: [article], series });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, pictureState);
        }
        if (type === 'pictureBook.pageImage') {
          const pageIndex = Number(payload.pageIndex ?? 0);
          const page = pictureState.pages.find((item) => item.pageIndex === pageIndex);
          return ok(message.id, type, {
            articleId: Number(payload.articleId ?? 1),
            pageIndex,
            imagePath: page?.imagePath ?? '',
            imageUri: page?.imageUri ?? '',
            imageVariant: 'thumbnail',
          });
        }
        if (type === 'pictureBook.pagePromptReview') {
          return ok(message.id, type, singlePageReview);
        }
        if (type === 'pictureBook.confirmPagePromptReview') {
          return ok(message.id, type, {
            ...pictureState,
            status: 'generating',
            pages: pictureState.pages.map((page) =>
              page.pageIndex === 2 ? { ...page, status: 'generating' } : page,
            ),
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByText('绘本组图')).toBeInTheDocument();
    const pageThreeCard = (await screen.findByText('第 3 页')).closest('article');
    expect(pageThreeCard).not.toBeNull();
    fireEvent.click(within(pageThreeCard as HTMLElement).getByRole('button', { name: '重新生成' }));

    const dialog = await screen.findByRole('dialog', { name: '绘本单页提示词审核' });
    expect(within(dialog).getByText('已选 1 张')).toBeInTheDocument();
    expect(within(dialog).getByRole('option', { name: '第 2 张' })).toHaveClass('is-selected');
    expect(within(dialog).getByRole('option', { name: '第 3 张（当前页）' })).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole('option', { name: '第 1 张' }));
    expect(within(dialog).getByText('已选 2 张')).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole('button', { name: '生成这一张' }));

    await waitFor(() => {
      const confirmCall = calls.find((call) => call.type === 'pictureBook.confirmPagePromptReview');
      expect(confirmCall?.payload).toMatchObject({
        reviewId: 'page-review-1-2',
        referencePageIndexes: [0, 1],
        referencePageIndex: 0,
      });
    });
  });

  it('shows queued storyboard descriptions before picture images are ready', async () => {
    window.location.hash = '/creation?articleId=1';
    const now = new Date().toISOString();
    const article = {
      id: 1,
      title: 'Queued Picture Chapter',
      content: 'Tom finds a bright snack box.',
      sentences: ['Tom finds a bright snack box.'],
      sentenceCount: 1,
      createdAt: now,
      averageScore: 86,
      seriesId: 1,
      seriesTitle: 'Queued Book',
      chapterOrder: 1,
    };
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series: [] });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: article.id,
            enabled: true,
            status: 'generating',
            pages: [
              {
                articleId: article.id,
                seriesId: 1,
                pageIndex: 0,
                sentenceStartIndex: 0,
                sentenceEndIndex: 0,
                paragraphText: article.sentences[0],
                prompt: {
                  scene: {
                    sceneDescription: 'Tom discovers the snack box before the image is ready.',
                  },
                },
                imagePath: null,
                imageUri: null,
                status: 'queued',
                errorMessage: null,
              },
            ],
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByText('Tom discovers the snack box before the image is ready.')).toBeInTheDocument();
    expect(calls.some((call) => call.type === 'pictureBook.pageImage')).toBe(false);
  });

  it('shows preload progress and hides the completed listening preload notice after 3 seconds', async () => {
    window.location.hash = '/listen/1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box.',
      sentences: ['Tom finds a bright snack box.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series: [] });
        }
        if (type === 'listening.open') {
          return ok(message.id, type, {
            article,
            items: [{ index: 0, english: article.sentences[0], chinese: '' }],
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, { articleId: 1, enabled: true, status: 'ready', pages: [] });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' })).toBeInTheDocument();

    act(() => {
      window.__tomatoNativeEvent?.({
        type: 'preload.state',
        payload: {
          articleId: 1,
          mode: 'listening',
          runId: 'listening_1_1',
          status: 'loading',
          completed: 1,
          total: 2,
          failed: 0,
        },
      });
    });
    expect(screen.getByText('正在进行预加载... 1 / 2')).toBeInTheDocument();

    vi.useFakeTimers();
    act(() => {
      window.__tomatoNativeEvent?.({
        type: 'preload.state',
        payload: {
          articleId: 1,
          mode: 'listening',
          runId: 'listening_1_1',
          status: 'complete',
          completed: 2,
          total: 2,
          failed: 0,
        },
      });
    });
    await act(async () => {
      await Promise.resolve();
    });
    expect(screen.getByText('完成加载！')).toBeInTheDocument();

    act(() => {
      vi.advanceTimersByTime(3000);
    });
    expect(screen.queryByText('完成加载！')).not.toBeInTheDocument();
    vi.useRealTimers();
  });

  it('does not show the preload strip while only picture decoding is pending', async () => {
    window.location.hash = '/listen/1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box.',
      sentences: ['Tom finds a bright snack box.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    const originalDecode = window.HTMLImageElement.prototype.decode;
    window.HTMLImageElement.prototype.decode = vi.fn(() => new Promise<void>(() => undefined));
    try {
      window.flutter_inappwebview = {
        callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
          const type = String(message.type ?? '');
          if (type === 'app.ready' || type === 'article.list') {
            return ok(message.id, type, { articles: [article], series: [] });
          }
          if (type === 'listening.open') {
            return ok(message.id, type, {
              article,
              items: [{ index: 0, english: article.sentences[0], chinese: '' }],
            });
          }
          if (type === 'pictureBook.state') {
            return ok(message.id, type, { articleId: 1, enabled: true, status: 'ready', pages: [] });
          }
          return ok(message.id, type, {});
        }),
      };

      render(<App />);

      expect(await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' })).toBeInTheDocument();

      vi.useFakeTimers();
      act(() => {
        window.__tomatoNativeEvent?.({
          type: 'pictureBook.state',
          payload: {
            articleId: 1,
            enabled: true,
            status: 'ready',
            pages: [
              {
                articleId: 1,
                pageIndex: 0,
                sentenceStartIndex: 0,
                sentenceEndIndex: 0,
                paragraphText: article.sentences[0],
                imageUri: 'data:image/png;base64,stub',
                status: 'ready',
              },
            ],
          },
        });
        window.__tomatoNativeEvent?.({
          type: 'preload.state',
          payload: {
            articleId: 1,
            mode: 'listening',
            runId: 'listening_1_2',
            status: 'complete',
            completed: 2,
            total: 2,
            failed: 0,
          },
        });
      });

      expect(screen.queryByText('正在进行预加载...')).not.toBeInTheDocument();
      expect(screen.queryByText('正在进行预加载... 2 / 2')).not.toBeInTheDocument();
      expect(screen.getByText('完成加载！')).toBeInTheDocument();
      vi.useRealTimers();
    } finally {
      window.HTMLImageElement.prototype.decode = originalDecode;
    }
  });

  it('shows picture-book loading placeholders in listening, follow, and chat', async () => {
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box.',
      sentences: ['Tom finds a bright snack box.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });
    const loadingPicture = {
      articleId: 1,
      enabled: true,
      status: 'generating',
      pages: [
        {
          articleId: 1,
          seriesId: 1,
          pageIndex: 0,
          sentenceStartIndex: 0,
          sentenceEndIndex: 0,
          paragraphText: article.content,
          imagePath: null,
          imageUri: null,
          status: 'generating',
          errorMessage: null,
        },
      ],
    };

    const renderRoute = async (hash: string) => {
      cleanup();
      window.location.hash = hash;
      window.flutter_inappwebview = {
        callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
          const type = String(message.type ?? '');
          if (type === 'app.ready' || type === 'article.list') {
            return ok(message.id, type, { articles: [article], series: [] });
          }
          if (type === 'pictureBook.state') {
            return ok(message.id, type, loadingPicture);
          }
          if (type === 'listening.open') {
            return ok(message.id, type, {
              article,
              items: [{ index: 0, english: article.sentences[0], chinese: '汤姆发现了一个明亮的零食盒。' }],
            });
          }
          if (type === 'listening.prepare') {
            return ok(message.id, type, { prepared: true });
          }
          if (type === 'follow.open' || type === 'follow.play') {
            return ok(message.id, type, {
              status: 'ready',
              article,
              currentIndex: 0,
              totalSentences: 1,
              currentSentence: article.sentences[0],
              currentTranslation: '汤姆发现了一个明亮的零食盒。',
              isLastSentence: true,
              step: 'idle',
              playbackState: 'success',
              hasRecording: false,
              liveRecognizedText: '',
              result: null,
            });
          }
          if (type === 'chat.open') {
            return ok(message.id, type, {
              articleTitle: article.title,
              step: 'userIdle',
              questionCount: 1,
              maxQuestions: 4,
              messages: [
                {
                  id: 'ai_1',
                  isAi: true,
                  text: 'What did Tom find?',
                  translation: '汤姆发现了什么？',
                  playbackState: 'success',
                },
              ],
            });
          }
          return ok(message.id, type, {});
        }),
      };

      render(<App />);
      expect(await screen.findByText('绘本图正在生成中...')).toBeInTheDocument();
    };

    await renderRoute('/listen/1');
    await renderRoute('/follow/1');
    await renderRoute('/chat/1');
  });

  it('keeps a loading placeholder while a listening page image is hydrated lazily', async () => {
    window.location.hash = '/listen/1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box.',
      sentences: ['Tom finds a bright snack box.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const calls: string[] = [];
    let resolvePageImage: (() => void) | null = null;
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        calls.push(type);
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series: [] });
        }
        if (type === 'listening.open') {
          return ok(message.id, type, {
            article,
            items: [{ index: 0, english: article.sentences[0], chinese: '汤姆发现了一个明亮的零食盒。' }],
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: 1,
            enabled: true,
            status: 'ready',
            pages: [
              {
                articleId: 1,
                seriesId: 1,
                pageIndex: 0,
                sentenceStartIndex: 0,
                sentenceEndIndex: 0,
                paragraphText: article.content,
                imagePath: 'F:/tmp/picture-book-page.png',
                imageUri: null,
                status: 'ready',
                errorMessage: null,
              },
            ],
          });
        }
        if (type === 'pictureBook.pageImage') {
          return new Promise((resolve) => {
            resolvePageImage = () =>
              resolve(
                ok(message.id, type, {
                  articleId: 1,
                  pageIndex: 0,
                  imageUri: 'data:image/png;base64,READY',
                }),
              );
          });
        }
        if (type === 'listening.prepare' || type === 'listening.playSequence') {
          return ok(message.id, type, { prepared: true, playbackState: 'success' });
        }
        return ok(message.id, type, {});
      }),
    };

    const { container } = render(<App />);

    expect(await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' })).toBeInTheDocument();
    expect(await screen.findByText('正在加载绘本图...')).toBeInTheDocument();
    expect(screen.queryByText('绘本图暂不可用')).not.toBeInTheDocument();

    await waitFor(() => {
      expect(calls).toContain('pictureBook.pageImage');
    });

    act(() => {
      resolvePageImage?.();
    });

    await waitFor(() => {
      const image = container.querySelector('.picture-book-scene img');
      expect(image?.getAttribute('src')).toBe('data:image/png;base64,READY');
    });
  });

  it('shows picture-book failure reasons and retries from chat', async () => {
    window.location.hash = '/chat/1';
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box.',
      sentences: ['Tom finds a bright snack box.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });
    const failedPicture = {
      articleId: 1,
      enabled: true,
      status: 'error',
      pages: [
        {
          articleId: 1,
          seriesId: 1,
          pageIndex: 0,
          sentenceStartIndex: 0,
          sentenceEndIndex: 0,
          paragraphText: article.content,
          imagePath: null,
          imageUri: null,
          status: 'error',
          errorMessage: '组图接口超时',
        },
      ],
    };

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series: [] });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, failedPicture);
        }
        if (type === 'pictureBook.promptReview') {
          return ok(
            message.id,
            type,
            promptReviewPayloadForTest(Number(payload.articleId ?? 1), true),
          );
        }
        if (type === 'chat.open') {
          return ok(message.id, type, {
            articleTitle: article.title,
            step: 'userIdle',
            questionCount: 1,
            maxQuestions: 4,
            messages: [
              {
                id: 'ai_1',
                isAi: true,
                text: 'What did Tom find?',
                translation: '汤姆发现了什么？',
                playbackState: 'success',
              },
            ],
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByText('组图接口超时')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /重试/ }));

    await waitFor(() => {
      expect(calls).toContainEqual({
        type: 'pictureBook.promptReview',
        payload: { articleId: 1, regenerate: true },
      });
    });
    expect(await screen.findByRole('dialog', { name: '绘本提示词审核' })).toBeInTheDocument();
  });

  it('disables repeated picture-book retry clicks while a retry is running', async () => {
    window.location.hash = '/chat/1';
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box.',
      sentences: ['Tom finds a bright snack box.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });
    let resolveRetry: (() => void) | null = null;
    const retryPromise = new Promise<BridgeResponse>((resolve) => {
      resolveRetry = () => {
        resolve(
          ok(
            'retry',
            'pictureBook.promptReview',
            promptReviewPayloadForTest(1, true),
          ),
        );
      };
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series: [] });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: 1,
            enabled: true,
            status: 'error',
            pages: [
              {
                articleId: 1,
                seriesId: 1,
                pageIndex: 0,
                sentenceStartIndex: 0,
                sentenceEndIndex: 0,
                paragraphText: article.content,
                imagePath: null,
                imageUri: null,
                status: 'error',
                errorMessage: '组图接口超时',
              },
            ],
          });
        }
        if (type === 'pictureBook.promptReview') {
          return retryPromise;
        }
        if (type === 'chat.open') {
          return ok(message.id, type, {
            articleTitle: article.title,
            step: 'userIdle',
            questionCount: 1,
            maxQuestions: 4,
            messages: [
              {
                id: 'ai_1',
                isAi: true,
                text: 'What did Tom find?',
                translation: '汤姆发现了什么？',
                playbackState: 'success',
              },
            ],
          });
        }
        return ok(message.id, type, {});
      }),
    };

    const { container } = render(<App />);

    expect(await screen.findByText('组图接口超时')).toBeInTheDocument();
    const retryButton = container.querySelector('.picture-book-retry');
    expect(retryButton).not.toBeNull();
    fireEvent.click(retryButton as HTMLElement);

    await waitFor(() => {
      expect(calls.filter((call) => call.type === 'pictureBook.promptReview')).toHaveLength(1);
    });
    expect(retryButton).toBeDisabled();

    fireEvent.click(retryButton as HTMLElement);
    expect(calls.filter((call) => call.type === 'pictureBook.promptReview')).toHaveLength(1);

    act(() => {
      resolveRetry?.();
    });

    expect(await screen.findByRole('dialog', { name: '绘本提示词审核' })).toBeInTheDocument();
  });

  it('turns a missing chat picture-book cache file into a retryable error', async () => {
    window.location.hash = '/chat/1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box. He shares it with his team.',
      sentences: ['Tom finds a bright snack box.', 'He shares it with his team.'],
      sentenceCount: 2,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series: [] });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: 1,
            enabled: true,
            status: 'ready',
            pages: [
              {
                articleId: 1,
                seriesId: 1,
                pageIndex: 0,
                sentenceStartIndex: 0,
                sentenceEndIndex: 0,
                paragraphText: article.sentences[0],
                imageUri: null,
                imagePath: 'F:/tmp/missing-picture-book-page.png',
                status: 'ready',
                errorMessage: null,
              },
            ],
          });
        }
        if (type === 'pictureBook.pageImage') {
          return ok(message.id, type, {
            articleId: 1,
            pageIndex: 0,
            imageUri: null,
            missing: true,
            errorMessage: '绘本缓存文件丢失，请重试生成',
          });
        }
        if (type === 'chat.open') {
          return ok(message.id, type, {
            articleTitle: article.title,
            step: 'userIdle',
            questionCount: 1,
            maxQuestions: 4,
            messages: [
              {
                id: 'ai_1',
                isAi: true,
                text: 'What did Tom find?',
                translation: '汤姆发现了什么？',
                playbackState: 'success',
              },
            ],
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByText('绘本缓存文件丢失，请重试生成')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /重试/ })).toBeInTheDocument();
    expect(screen.queryByText('正在加载绘本图...')).not.toBeInTheDocument();
  });

  it('maps late chat progress to the later picture-book page', async () => {
    window.location.hash = '/chat/1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box. He shares it with his team.',
      sentences: ['Tom finds a bright snack box.', 'He shares it with his team.'],
      sentenceCount: 2,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series: [] });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: 1,
            enabled: true,
            status: 'ready',
            pages: [
              {
                articleId: 1,
                seriesId: 1,
                pageIndex: 0,
                sentenceStartIndex: 0,
                sentenceEndIndex: 0,
                paragraphText: article.sentences[0],
                imageUri: 'data:image/png;base64,FIRST',
                imagePath: null,
                status: 'ready',
                errorMessage: null,
              },
              {
                articleId: 1,
                seriesId: 1,
                pageIndex: 1,
                sentenceStartIndex: 1,
                sentenceEndIndex: 1,
                paragraphText: article.sentences[1],
                imageUri: 'data:image/png;base64,SECOND',
                imagePath: null,
                status: 'ready',
                errorMessage: null,
              },
            ],
          });
        }
        if (type === 'chat.open') {
          return ok(message.id, type, {
            articleTitle: article.title,
            step: 'userIdle',
            questionCount: 4,
            maxQuestions: 4,
            messages: [
              {
                id: 'ai_4',
                isAi: true,
                text: 'What happens at the end?',
                translation: '最后发生了什么？',
                playbackState: 'success',
              },
            ],
          });
        }
        return ok(message.id, type, {});
      }),
    };

    const { container } = render(<App />);

    expect(await screen.findByText('最后发生了什么？')).toBeInTheDocument();
    const images = Array.from(
      container.querySelectorAll('.chat-room-card .picture-book-scene img'),
    ).map((image) => image.getAttribute('src'));
    expect(images).toEqual(['data:image/png;base64,FIRST', 'data:image/png;base64,SECOND']);
  });

  it('reveals chat storyboard images one scene per question round', async () => {
    window.location.hash = '/chat/1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box. He shares it with his team. They open it together. Everyone cheers.',
      sentences: [
        'Tom finds a bright snack box.',
        'He shares it with his team.',
        'They open it together.',
        'Everyone cheers.',
      ],
      sentenceCount: 4,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series: [] });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: 1,
            enabled: true,
            status: 'ready',
            pages: [
              {
                articleId: 1,
                seriesId: 1,
                pageIndex: 0,
                sentenceStartIndex: 0,
                sentenceEndIndex: 0,
                paragraphText: article.sentences[0],
                imageUri: 'data:image/png;base64,FIRST',
                imagePath: null,
                status: 'ready',
                errorMessage: null,
              },
              {
                articleId: 1,
                seriesId: 1,
                pageIndex: 1,
                sentenceStartIndex: 1,
                sentenceEndIndex: 1,
                paragraphText: article.sentences[1],
                imageUri: 'data:image/png;base64,SECOND',
                imagePath: null,
                status: 'ready',
                errorMessage: null,
              },
              {
                articleId: 1,
                seriesId: 1,
                pageIndex: 2,
                sentenceStartIndex: 2,
                sentenceEndIndex: 2,
                paragraphText: article.sentences[2],
                imageUri: 'data:image/png;base64,THIRD',
                imagePath: null,
                status: 'ready',
                errorMessage: null,
              },
              {
                articleId: 1,
                seriesId: 1,
                pageIndex: 3,
                sentenceStartIndex: 3,
                sentenceEndIndex: 3,
                paragraphText: article.sentences[3],
                imageUri: 'data:image/png;base64,FOURTH',
                imagePath: null,
                status: 'ready',
                errorMessage: null,
              },
            ],
          });
        }
        if (type === 'chat.open') {
          return ok(message.id, type, {
            articleTitle: article.title,
            step: 'userIdle',
            questionCount: 2,
            maxQuestions: 8,
            messages: [
              {
                id: 'ai_1',
                isAi: true,
                text: 'What did Tom find first?',
                translation: '汤姆先发现了什么？',
                playbackState: 'success',
              },
              {
                id: 'user_1',
                isAi: false,
                text: 'He found a bright snack box.',
                translation: null,
                playbackState: 'success',
              },
              {
                id: 'ai_2',
                isAi: true,
                text: 'Great. What did he do next?',
                translation: '很好。接下来他做了什么？',
                playbackState: 'success',
              },
            ],
          });
        }
        return ok(message.id, type, {});
      }),
    };

    const { container } = render(<App />);

    expect(await screen.findByText('Great. What did he do next?')).toBeInTheDocument();
    const images = Array.from(
      container.querySelectorAll('.chat-room-card .picture-book-scene img'),
    ).map((image) => image.getAttribute('src'));
    expect(images).toEqual(['data:image/png;base64,FIRST', 'data:image/png;base64,SECOND']);
  });

  it('marks the active listening text while playback is pending', async () => {
    window.location.hash = '/listen/1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box. He shares it with his team.',
      sentences: ['Tom finds a bright snack box.', 'He shares it with his team.'],
      sentenceCount: 2,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    let resolvePlayback: (() => void) | null = null;
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article] });
        }
        if (type === 'listening.open') {
          return ok(message.id, type, {
            article,
            items: [
              { index: 0, english: article.sentences[0], chinese: '汤姆发现了一个明亮的零食盒。' },
              { index: 1, english: article.sentences[1], chinese: '他把它分享给自己的队友。' },
            ],
          });
        }
        if (type === 'listening.prepare') {
          return ok(message.id, type, { prepared: true });
        }
        if (type === 'listening.playSequence') {
          window.__tomatoNativeEvent?.({
            type: 'listening.playback',
            payload: { articleId: 1, index: 0, part: 'english', state: 'partStart' },
          });
          return new Promise((resolve) => {
            resolvePlayback = () =>
              resolve(ok(message.id, type, { playbackState: 'success' }));
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    const heading = await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' });
    fireEvent.click(screen.getByRole('button', { name: '重听本句' }));

    await waitFor(() => expect(heading).toHaveClass('playing-text'));
    expect(document.querySelector('.listening-page .waveform')).not.toBeInTheDocument();

    act(() => {
      resolvePlayback?.();
    });
  });

  it('starts Suno song generation from the creation center', async () => {
    window.location.hash = '/creation?articleId=1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box. He shares it with his team.',
      sentences: ['Tom finds a bright snack box.', 'He shares it with his team.'],
      sentenceCount: 2,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article] });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, { articleId: article.id, enabled: true, status: 'empty', pages: [] });
        }
        if (type === 'listening.songState') {
          return ok(message.id, type, {
            articleId: article.id,
            status: 'empty',
            stylePrompt: '',
            audioPath: null,
            errorMessage: '',
            source: 'suno',
          });
        }
        if (type === 'listening.songGenerate') {
          return ok(message.id, type, {
            articleId: article.id,
            status: 'generating',
            stylePrompt: String(payload.stylePrompt ?? ''),
            source: 'suno',
            automationStatus: 'waitingConfirm',
            manualActionMessage: 'Suno 歌词和自动风格已填写，请确认消耗 Suno credits 后创建。',
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    await clickSelectedCreationAction('歌曲');
    expect(await screen.findByText('歌曲生成')).toBeInTheDocument();
    const generateButton = await screen.findByRole('button', { name: /生成 Suno 歌曲/ });
    await waitFor(() => expect(generateButton).not.toBeDisabled());
    fireEvent.click(generateButton);
    await confirmDialogAction('确认生成歌曲', '继续', /即将打开 Suno/);

    await waitFor(() => {
      const generateCall = calls.find((call) => call.type === 'listening.songGenerate');
      expect(generateCall?.payload).toMatchObject({ articleId: 1, source: 'suno' });
    });
    expect(calls.some((call) => call.type === 'listening.songSuggestStyle')).toBe(false);
    expect(
      await screen.findByText('Suno 歌词和自动风格已填写，请确认消耗 Suno credits 后创建。'),
    ).toBeInTheDocument();
  });

  it('blocks the UI while submitting Bailian song generation from the creation center', async () => {
    window.location.hash = '/creation?articleId=1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box. He shares it with his team.',
      sentences: ['Tom finds a bright snack box.', 'He shares it with his team.'],
      sentenceCount: 2,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const generatePayloads: Array<Record<string, unknown>> = [];
    let resolveGenerate: (() => void) | null = null;
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article] });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, { articleId: article.id, enabled: true, status: 'empty', pages: [] });
        }
        if (type === 'listening.songState') {
          return ok(message.id, type, {
            articleId: article.id,
            status: 'empty',
            stylePrompt: '',
            audioPath: null,
            errorMessage: '',
            source: 'bailian_fun_music',
          });
        }
        if (type === 'listening.songGenerate') {
          generatePayloads.push(payload);
          const response = ok(message.id, type, {
            articleId: article.id,
            status: 'ready',
            source: 'bailian_fun_music',
            versions: [
              {
                id: 'bailian-1',
                audioPath: 'song.mp3',
                title: '阿里云百聆版本 1',
                source: 'bailian_fun_music',
              },
            ],
          });
          return new Promise<BridgeResponse>((resolve) => {
            resolveGenerate = () => resolve(response);
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    await clickSelectedCreationAction('歌曲');
    expect(await screen.findByText('歌曲生成')).toBeInTheDocument();
    const generateButton = await screen.findByRole('button', { name: /生成百聆歌曲/ });
    await waitFor(() => expect(generateButton).not.toBeDisabled());
    fireEvent.click(generateButton);
    await confirmDialogAction('确认生成歌曲', '继续', /百聆/);

    await waitFor(() => expect(generatePayloads[0]).toMatchObject({ articleId: 1, source: 'bailian_fun_music' }));
    expect(await screen.findByText('正在提交百聆歌曲')).toBeInTheDocument();
    expect(screen.getByText(/预计超时倒计时/)).toBeInTheDocument();

    await act(async () => {
      resolveGenerate?.();
    });

    await waitFor(() => expect(screen.queryByText('正在提交百聆歌曲')).not.toBeInTheDocument());
    expect(await screen.findByText('阿里云百聆版本 1')).toBeInTheDocument();
  });

  it('submits ElevenLabs song generation from the creation center', async () => {
    window.location.hash = '/creation?articleId=1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box. He shares it with his team.',
      sentences: ['Tom finds a bright snack box.', 'He shares it with his team.'],
      sentenceCount: 2,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const generatePayloads: Array<Record<string, unknown>> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article] });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, { articleId: article.id, enabled: true, status: 'empty', pages: [] });
        }
        if (type === 'listening.songState') {
          return ok(message.id, type, {
            articleId: article.id,
            status: 'empty',
            stylePrompt: '',
            audioPath: null,
            errorMessage: '',
            source: 'elevenlabs_music',
          });
        }
        if (type === 'listening.songGenerate') {
          generatePayloads.push(payload);
          return ok(message.id, type, {
            articleId: article.id,
            status: 'ready',
            source: 'elevenlabs_music',
            versions: [
              {
                id: 'eleven-1',
                audioPath: 'eleven.mp3',
                title: 'ElevenLabs 版本 1',
                source: 'elevenlabs_music',
              },
            ],
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    await clickSelectedCreationAction('歌曲');
    expect(await screen.findByText('歌曲生成')).toBeInTheDocument();
    const generateButton = await screen.findByRole('button', { name: /生成 ElevenLabs 歌曲/ });
    await waitFor(() => expect(generateButton).not.toBeDisabled());
    fireEvent.click(generateButton);
    await confirmDialogAction('确认生成歌曲', '继续', /ElevenLabs Music/);

    await waitFor(() => expect(generatePayloads[0]).toMatchObject({ articleId: 1, source: 'elevenlabs_music' }));
    expect(await screen.findByText('ElevenLabs 版本 1')).toBeInTheDocument();
  });

  it('imports external audio songs from the creation center', async () => {
    window.location.hash = '/creation?articleId=1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box. He shares it with his team.',
      sentences: ['Tom finds a bright snack box.', 'He shares it with his team.'],
      sentenceCount: 2,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const importPayloads: Array<Record<string, unknown>> = [];
    const audioExportPayloads: Array<Record<string, unknown>> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article] });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, { articleId: article.id, enabled: true, status: 'empty', pages: [] });
        }
        if (type === 'listening.songState') {
          return ok(message.id, type, {
            articleId: article.id,
            status: 'empty',
            source: 'suno',
            versions: [],
          });
        }
        if (type === 'listening.songImportExternal') {
          importPayloads.push(payload);
          return ok(message.id, type, {
            articleId: article.id,
            status: 'ready',
            source: 'suno',
            audioPath: 'external-song.mp3',
            downloadComplete: true,
            versions: [
              {
                id: 'external-1',
                audioPath: 'external-song.mp3',
                title: '导入音乐',
                durationMs: 36000,
                source: 'external_audio',
                timelineStatus: 'missing',
                isDefault: true,
              },
            ],
          });
        }
        if (type === 'listening.songExportAudio') {
          audioExportPayloads.push(payload);
          return ok(message.id, type, {
            articleId: article.id,
            versionId: 'external-1',
            sourcePath: 'external-song.mp3',
            outputPath: 'F:\\Tomato\\recording-export\\mp3\\external-song.mp3',
            outputDirectory: 'F:\\Tomato\\recording-export\\mp3',
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    await clickSelectedCreationAction('歌曲');
    const importButton = await screen.findByRole('button', { name: /导入本地音乐/ });
    await waitFor(() => expect(importButton).not.toBeDisabled());
    fireEvent.click(importButton);

    await waitFor(() => expect(importPayloads[0]).toMatchObject({ articleId: 1, source: 'suno' }));
    expect(await screen.findByText('外部导入')).toBeInTheDocument();
    expect(screen.getByText('导入音乐 · 默认')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /检测下载/ })).toBeInTheDocument();
    const actionButtons = Array.from(importButton.closest('.creation-actions')?.querySelectorAll('button') ?? []);
    const actionLabels = actionButtons.map((button) => button.textContent ?? '');
    expect(actionLabels.findIndex((label) => label.includes('检测下载'))).toBeLessThan(
      actionLabels.findIndex((label) => label.includes('导入本地音乐')),
    );
    expect(screen.getByRole('button', { name: '生成歌曲字幕' })).toBeInTheDocument();
    const videoButton = screen.getByRole('button', { name: '导出歌曲视频' });
    const audioButton = screen.getByRole('button', { name: '导出音频文件' });
    expect(videoButton).toBeDisabled();
    expect(audioButton).not.toBeDisabled();
    const versionActionLabels = Array.from(
      videoButton.closest('.song-version-actions')?.querySelectorAll('button') ?? [],
    ).map((button) => button.textContent ?? '');
    expect(versionActionLabels.findIndex((label) => label.includes('导出音频文件'))).toBeGreaterThan(
      versionActionLabels.findIndex((label) => label.includes('导出歌曲视频')),
    );

    fireEvent.click(audioButton);
    await waitFor(() => expect(audioExportPayloads[0]).toMatchObject({ articleId: 1, versionId: 'external-1' }));
    expect(await screen.findByText('音频已导出到 recording-export/mp3')).toBeInTheDocument();
  });

  it('submits Suno song generation with explicit login guidance', async () => {
    window.location.hash = '/creation?articleId=1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box.',
      sentences: ['Tom finds a bright snack box.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const generatePayloads: Array<Record<string, unknown>> = [];
    const confirmPayloads: Array<Record<string, unknown>> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article] });
        }
        if (type === 'settings.load') {
          return ok(message.id, type, {
            tts: { resourceId: 'seed-tts-2.0', speakerId: 'en_female_dacey_uranus_bigtts' },
            song: { sunoOutputDirectory: 'mock', sunoTimeoutMinutes: 20 },
            voices: [],
          });
        }
        if (type === 'recording.settings.load') {
          return ok(message.id, type, {
            codec: 'h264',
            resolution: '1920x1080',
            pageTransition: 'none',
            subtitleMode: 'srt',
            outputDirectory: 'F:\\Tomato\\recording-export',
            fps: 25,
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, { articleId: article.id, enabled: true, status: 'empty', pages: [] });
        }
        if (type === 'listening.songState') {
          return ok(message.id, type, {
            articleId: article.id,
            status: 'empty',
            stylePrompt: '',
            audioPath: null,
            errorMessage: '',
            source: 'suno',
          });
        }
        if (type === 'listening.songGenerate') {
          const payload = (message.payload ?? {}) as Record<string, unknown>;
          generatePayloads.push(payload);
          return ok(message.id, type, {
            articleId: article.id,
            status: 'generating',
            source: 'suno',
            stylePrompt: String(payload.stylePrompt ?? ''),
            automationStatus: 'waitingConfirm',
            manualActionMessage: 'Suno 歌词和自动风格已填写，请确认消耗 Suno credits 后创建。',
          });
        }
        if (type === 'listening.songConfirmSunoCreate') {
          const payload = (message.payload ?? {}) as Record<string, unknown>;
          confirmPayloads.push(payload);
          return ok(message.id, type, {
            articleId: article.id,
            status: 'generating',
            source: 'suno',
            stylePrompt: 'whimsical acoustic storybook pop generated by Suno',
            automationStatus: 'creating',
            manualActionMessage: 'Suno 正在生成歌曲...',
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    await clickSelectedCreationAction('歌曲');
    expect(await screen.findByText('歌曲生成')).toBeInTheDocument();
    const generateButton = await screen.findByRole('button', { name: /生成 Suno 歌曲/ });
    await waitFor(() => expect(generateButton).not.toBeDisabled());
    fireEvent.click(generateButton);
    await confirmDialogAction('确认生成歌曲', '继续', /即将打开 Suno/);

    await waitFor(() => expect(generatePayloads[0]?.source).toBe('suno'));
    expect(generatePayloads[0]).not.toHaveProperty('stylePrompt');
    await waitFor(() =>
      expect(
        screen.getAllByText('Suno 歌词和自动风格已填写，请确认消耗 Suno credits 后创建。').length,
      ).toBeGreaterThan(0),
    );
    fireEvent.click(await screen.findByRole('button', { name: /确认创建歌曲/ }));
    await confirmDialogAction('确认创建 Suno 歌曲', '确认创建', '确认消耗 Suno credits 并创建歌曲？');

    await waitFor(() => expect(confirmPayloads[0]).toMatchObject({ articleId: 1 }));
    await waitFor(() => expect(screen.getAllByText('Suno 正在生成歌曲...').length).toBeGreaterThan(0));
  });

  it('shows manual Suno action guidance in the creation center', async () => {
    window.location.hash = '/creation?articleId=1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box.',
      sentences: ['Tom finds a bright snack box.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article] });
        }
        if (type === 'settings.load') {
          return ok(message.id, type, {
            tts: { resourceId: 'seed-tts-2.0', speakerId: 'en_female_dacey_uranus_bigtts' },
            song: { sunoOutputDirectory: 'mock', sunoTimeoutMinutes: 20 },
            voices: [],
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, { articleId: article.id, enabled: true, status: 'empty', pages: [] });
        }
        if (type === 'listening.songState') {
          return ok(message.id, type, {
            articleId: article.id,
            status: 'empty',
            stylePrompt: 'Suno auto style',
            audioPath: null,
            errorMessage: '',
            source: 'suno',
            songUrl: 'https://suno.com/song/one',
            automationStatus: 'manualAction',
            manualActionMessage: 'Suno 歌曲已生成记录，但还没有本地音频文件。',
          });
        }
        if (type === 'listening.songGenerate') {
          return ok(message.id, type, {
            articleId: article.id,
            status: 'generating',
            source: 'suno',
            stylePrompt: 'Suno auto style',
            songUrl: 'https://suno.com/song/one',
            automationStatus: 'manualAction',
            manualActionMessage: 'Suno 生成结果已出现，但没有找到 Download 或 Audio 下载按钮。',
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    await clickSelectedCreationAction('歌曲');
    expect(await screen.findByText('歌曲生成')).toBeInTheDocument();
    fireEvent.click(await screen.findByRole('button', { name: /生成 Suno 歌曲/ }));
    await confirmDialogAction('确认生成歌曲', '继续', /即将打开 Suno/);

    await waitFor(() =>
      expect(
        screen.getAllByText('Suno 生成结果已出现，但没有找到 Download 或 Audio 下载按钮。').length,
      ).toBeGreaterThan(0),
    );
    expect(screen.queryByRole('dialog', { name: '歌曲设置' })).not.toBeInTheDocument();
  });

  it('cancels creation-center song generation confirms without submitting', async () => {
    window.location.hash = '/creation?articleId=1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box.',
      sentences: ['Tom finds a bright snack box.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const generatePayloads: Array<Record<string, unknown>> = [];
    const confirmPayloads: Array<Record<string, unknown>> = [];
    let songStatePayload: Record<string, unknown> = {
      articleId: article.id,
      status: 'empty',
      source: 'suno',
      stylePrompt: '',
      audioPath: null,
      errorMessage: '',
    };
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article] });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, { articleId: article.id, enabled: true, status: 'empty', pages: [] });
        }
        if (type === 'listening.songState') {
          return ok(message.id, type, songStatePayload);
        }
        if (type === 'listening.songGenerate') {
          generatePayloads.push(payload);
          songStatePayload = {
            articleId: article.id,
            status: 'generating',
            source: 'suno',
            automationStatus: 'waitingConfirm',
            manualActionMessage: 'Suno 歌词和自动风格已填写，请确认消耗 Suno credits 后创建。',
          };
          return ok(message.id, type, songStatePayload);
        }
        if (type === 'listening.songConfirmSunoCreate') {
          confirmPayloads.push(payload);
          return ok(message.id, type, { articleId: article.id, status: 'generating', source: 'suno' });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    await clickSelectedCreationAction('歌曲');
    expect(await screen.findByText('歌曲生成')).toBeInTheDocument();

    fireEvent.click(await screen.findByRole('button', { name: /生成百聆歌曲/ }));
    await cancelConfirmDialog('确认生成歌曲', /百聆/);
    expect(generatePayloads).toHaveLength(0);

    fireEvent.click(await screen.findByRole('button', { name: /生成 Suno 歌曲/ }));
    await cancelConfirmDialog('确认生成歌曲', /即将打开 Suno/);
    expect(generatePayloads).toHaveLength(0);

    fireEvent.click(await screen.findByRole('button', { name: /生成 Suno 歌曲/ }));
    await confirmDialogAction('确认生成歌曲', '继续', /即将打开 Suno/);
    await waitFor(() => expect(generatePayloads).toHaveLength(1));

    fireEvent.click(await screen.findByRole('button', { name: /确认创建歌曲/ }));
    await cancelConfirmDialog('确认创建 Suno 歌曲', '确认消耗 Suno credits 并创建歌曲？');
    expect(confirmPayloads).toHaveLength(0);
  });

  it('retries downloading an existing Suno song link', async () => {
    window.location.hash = '/creation?articleId=1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box.',
      sentences: ['Tom finds a bright snack box.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const downloadPayloads: Array<Record<string, unknown>> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article] });
        }
        if (type === 'settings.load') {
          return ok(message.id, type, {
            tts: { resourceId: 'seed-tts-2.0', speakerId: 'en_female_dacey_uranus_bigtts' },
            song: { sunoOutputDirectory: 'mock', sunoTimeoutMinutes: 20 },
            voices: [],
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, { articleId: article.id, enabled: true, status: 'empty', pages: [] });
        }
        if (type === 'listening.songState') {
          return ok(message.id, type, {
            articleId: article.id,
            status: 'empty',
            stylePrompt: 'Suno auto style',
            audioPath: null,
            errorMessage: '',
            source: 'suno',
            songUrl: 'https://suno.com/song/one',
            downloadComplete: false,
            automationStatus: 'manualAction',
            manualActionMessage: 'Suno 歌曲已生成记录，但还没有本地音频文件。',
          });
        }
        if (type === 'listening.songDownloadSunoExisting') {
          const payload = (message.payload ?? {}) as Record<string, unknown>;
          downloadPayloads.push(payload);
          return ok(message.id, type, {
            articleId: article.id,
            status: 'generating',
            stylePrompt: 'Suno auto style',
            audioPath: null,
            errorMessage: '',
            source: 'suno',
            songUrl: 'https://suno.com/song/one',
            downloadComplete: false,
            automationStatus: 'downloading',
            manualActionMessage: '正在打开 Suno 已生成歌曲并尝试下载...',
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    await clickSelectedCreationAction('歌曲');
    fireEvent.click(await screen.findByRole('button', { name: /检测下载/ }));

    await waitFor(() => expect(downloadPayloads[0]).toMatchObject({ articleId: 1 }));
    await waitFor(() =>
      expect(screen.getAllByText('正在打开 Suno 已生成歌曲并尝试下载...').length).toBeGreaterThan(0),
    );
  });

  it('plays a selected downloaded song version', async () => {
    window.location.hash = '/creation?articleId=1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box.',
      sentences: ['Tom finds a bright snack box.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const playPayloads: Array<Record<string, unknown>> = [];
    const timelinePayloads: Array<Record<string, unknown>> = [];
    const deletePayloads: Array<Record<string, unknown>> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });
    let currentSongState = {
      articleId: article.id,
      status: 'ready',
      stylePrompt: 'Suno auto style',
      audioPath: 'suno-v1.mp3',
      errorMessage: '',
      source: 'suno',
      versions: [
        { id: 'suno-v1', audioPath: 'suno-v1.mp3', title: 'Suno 版本 1', songUrl: 'https://suno.com/song/one', stylePrompt: 'Suno auto style', styleKey: 'suno:suno auto style' },
        { id: 'suno-v2', audioPath: 'suno-v2.mp3', title: 'Suno 版本 2', songUrl: 'https://suno.com/song/two', stylePrompt: 'Suno auto style', styleKey: 'suno:suno auto style', timelineStatus: 'ready' },
        { id: 'suno-v3', audioPath: 'suno-v3.mp3', title: 'Dreamy 版本', songUrl: 'https://suno.com/song/three', stylePrompt: 'Dreamy lullaby style', styleKey: 'suno:dreamy lullaby style' },
      ],
    };

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article] });
        }
        if (type === 'settings.load') {
          return ok(message.id, type, {
            tts: { resourceId: 'seed-tts-2.0', speakerId: 'en_female_dacey_uranus_bigtts' },
            song: { sunoOutputDirectory: 'mock', sunoTimeoutMinutes: 20 },
            voices: [],
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, { articleId: article.id, enabled: true, status: 'empty', pages: [] });
        }
        if (type === 'listening.songState') {
          return ok(message.id, type, currentSongState);
        }
        if (type === 'listening.songPlay') {
          const payload = (message.payload ?? {}) as Record<string, unknown>;
          playPayloads.push(payload);
          return ok(message.id, type, { playbackState: 'playing' });
        }
        if (type === 'listening.songTimelineGenerate') {
          const payload = (message.payload ?? {}) as Record<string, unknown>;
          timelinePayloads.push(payload);
          const generatingState = {
            ...currentSongState,
            status: 'ready',
            versions: currentSongState.versions.map((version) =>
              version.id === payload.versionId
                ? { ...version, timelineStatus: 'generating', timelineError: null }
                : version,
            ),
          };
          window.__tomatoNativeEvent?.({ type: 'listening.song.state', payload: generatingState });
          currentSongState = {
            ...currentSongState,
            status: 'ready',
            versions: currentSongState.versions.map((version) =>
              version.id === payload.versionId
                ? { ...version, timelineStatus: 'ready', timelinePath: 'timeline-v2.json', timelineError: null }
                : version,
            ),
          };
          return ok(message.id, type, currentSongState);
        }
        if (type === 'listening.songDeleteVersion') {
          const payload = (message.payload ?? {}) as Record<string, unknown>;
          deletePayloads.push(payload);
          currentSongState = {
            ...currentSongState,
            versions: currentSongState.versions.filter((version) => version.id !== payload.versionId),
          };
          return ok(message.id, type, currentSongState);
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    await clickSelectedCreationAction('歌曲');
    expect(screen.queryByLabelText('当前 Suno 自动风格')).not.toBeInTheDocument();
    expect(screen.queryByText('Suno auto style')).not.toBeInTheDocument();
    expect(screen.queryByText('Dreamy lullaby style')).not.toBeInTheDocument();
    expect(await screen.findByRole('button', { name: 'Suno 版本 2' })).toBeInTheDocument();
    expect(await screen.findByRole('button', { name: 'Dreamy 版本' })).toBeInTheDocument();
    fireEvent.click(await screen.findByRole('button', { name: 'Suno 版本 2' }));

    await waitFor(() => expect(playPayloads[0]).toMatchObject({ articleId: 1, versionId: 'suno-v2' }));
    await waitFor(() => {
      const playingVersionButton = screen
        .getAllByRole('button', { name: /Suno 版本 2/ })
        .find((button) => button.className.includes('song-title-button'));
      expect(playingVersionButton?.className).toContain('active');
    });
    fireEvent.click(screen.getByRole('button', { name: '字幕已生成' }));
    await waitFor(() => expect(timelinePayloads[0]).toMatchObject({ articleId: 1, versionId: 'suno-v2' }));
    await waitFor(() => {
      const playingVersionButton = screen
        .getAllByRole('button', { name: /Suno 版本 2/ })
        .find((button) => button.className.includes('song-title-button'));
      expect(playingVersionButton?.className).toContain('active');
    });

    fireEvent.click(screen.getByRole('button', { name: '删除歌曲：Suno 版本 2' }));
    await confirmDialogAction('删除歌曲确认', '删除', '确认删除歌曲「Suno 版本 2」以及它的字幕时间轴？删除后不可恢复。');
    await waitFor(() => expect(deletePayloads[0]).toMatchObject({ articleId: 1, versionId: 'suno-v2' }));
    expect(await screen.findByText('已删除歌曲')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Suno 版本 2' })).not.toBeInTheDocument();
  }, 10000);

  it('marks stale song timelines as needing regeneration in the creation center', async () => {
    window.location.hash = '/creation?articleId=1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box.',
      sentences: ['Tom finds a bright snack box.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const deletePayloads: Array<Record<string, unknown>> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });
    let currentSongState = {
      articleId: article.id,
      status: 'ready',
      audioPath: 'suno-stale.mp3',
      source: 'suno',
      versions: [
        {
          id: 'suno-stale',
          audioPath: 'suno-stale.mp3',
          title: '旧字幕版本',
          source: 'suno',
          timelinePath: 'old-timeline.json',
          timelineStatus: 'stale',
          timelineError: '歌曲字幕时间线版本过旧，请重新生成歌曲字幕',
          isDefault: true,
        },
      ],
    };

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article] });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, { articleId: article.id, enabled: true, status: 'empty', pages: [] });
        }
        if (type === 'listening.songState') {
          return ok(message.id, type, currentSongState);
        }
        if (type === 'listening.songDeleteVersion') {
          const payload = (message.payload ?? {}) as Record<string, unknown>;
          deletePayloads.push(payload);
          currentSongState = { ...currentSongState, versions: [] };
          return ok(message.id, type, currentSongState);
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    await clickSelectedCreationAction('歌曲');
    expect(await screen.findByRole('button', { name: '旧字幕版本 · 默认' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '重新生成字幕' })).toBeInTheDocument();
    const recordButton = screen.getByRole('button', { name: '导出歌曲视频' });
    expect(recordButton).toBeDisabled();
    expect(recordButton).toHaveAttribute('title', '歌曲字幕时间线版本过旧，请重新生成字幕');
    expect(screen.getByRole('button', { name: '导出音频文件' })).not.toBeDisabled();

    fireEvent.click(screen.getByRole('button', { name: '删除歌曲：旧字幕版本' }));
    await confirmDialogAction('删除歌曲确认', '删除', '确认删除歌曲「旧字幕版本」以及它的字幕时间轴？删除后不可恢复。');
    await waitFor(() => expect(deletePayloads[0]).toMatchObject({ articleId: 1, versionId: 'suno-stale' }));
  });

  it('plays and defaults a selected song from the book player controls', async () => {
    window.location.hash = '/books/7/player?articleId=1&mode=song';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box.',
      sentences: ['Tom finds a bright snack box.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 86,
      seriesId: 7,
      seriesTitle: 'Space Story Series',
    };
    const series = [
      {
        id: 7,
        title: 'Space Story Series',
        description: '',
        coverImagePath: null,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      },
    ];
    const versions = [
      { id: 'suno-v1', audioPath: 'suno-v1.mp3', title: 'Suno 版本 1', stylePrompt: 'Suno auto style', styleKey: 'suno:suno auto style', timelineStatus: 'ready', timelinePath: 'timeline-v1.json', isDefault: true },
      { id: 'suno-v2', audioPath: 'suno-v2.mp3', title: 'Suno 版本 2', stylePrompt: 'Suno auto style', styleKey: 'suno:suno auto style', timelineStatus: 'missing' },
      { id: 'external-v1', audioPath: 'external-v1.mp3', title: 'Alice 外部导入', source: 'external_audio', timelineStatus: 'missing' },
    ];
    const playPayloads: Array<Record<string, unknown>> = [];
    const defaultPayloads: Array<Record<string, unknown>> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article], series });
        }
        if (type === 'listening.open') {
          return ok(message.id, type, {
            article,
            items: [{ index: 0, english: article.sentences[0], chinese: '' }],
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, { articleId: article.id, enabled: true, status: 'empty', pages: [] });
        }
        if (type === 'listening.fullscreenReady') {
          return ok(message.id, type, {
            ready: false,
            reasons: ['当前和下一句英文音频文件还没有预热完成'],
            requiredEnglish: 1,
            readyEnglish: 0,
            requiredChinese: 0,
            readyChinese: 0,
            missingEnglish: [0],
            missingChinese: [],
            failed: 0,
          });
        }
        if (type === 'listening.songState') {
          return ok(message.id, type, {
            articleId: article.id,
            status: 'ready',
            source: 'suno',
            stylePrompt: 'Suno auto style',
            audioPath: 'suno-v1.mp3',
            versions,
          });
        }
        if (type === 'listening.songSetDefault') {
          defaultPayloads.push(payload);
          const selectedVersionId = String(payload.versionId ?? '');
          const selectedVersion = versions.find((version) => version.id === selectedVersionId) ?? versions[0];
          return ok(message.id, type, {
            articleId: article.id,
            status: 'ready',
            source: 'suno',
            stylePrompt: 'Suno auto style',
            audioPath: selectedVersion.audioPath,
            versions: versions.map((version) => ({ ...version, isDefault: version.id === selectedVersionId })),
          });
        }
        if (type === 'listening.songPlay') {
          playPayloads.push(payload);
          return ok(message.id, type, { playbackState: 'playing' });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    const songSelect = await screen.findByRole('combobox', { name: '歌曲列表' });
    await waitFor(() => expect(songSelect).toHaveValue('suno-v1'));
    expect(screen.queryByText('当前和下一句英文音频文件还没有预热完成')).not.toBeInTheDocument();
    expect(screen.queryByText('这首歌还没有生成字幕，请到创作中心生成歌曲字幕。')).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /选择本地歌曲/ })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /去创作中心生成/ })).not.toBeInTheDocument();

    fireEvent.change(songSelect, { target: { value: 'external-v1' } });
    expect(await screen.findByText('这首歌还没有生成字幕，请到创作中心生成歌曲字幕。')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '设为当前默认播放歌曲' }));
    await waitFor(() => expect(defaultPayloads[0]).toMatchObject({ articleId: 1, versionId: 'external-v1' }));
    expect(await screen.findByRole('button', { name: '当前歌曲已是默认播放歌曲' })).not.toBeDisabled();

    fireEvent.click(screen.getByRole('button', { name: '开始播放' }));
    await waitFor(() => expect(playPayloads[0]).toMatchObject({ articleId: 1, versionId: 'external-v1' }));
    expect(await screen.findByRole('button', { name: '停止歌曲' })).toBeInTheDocument();
    expect(songSelect).not.toBeDisabled();
    fireEvent.change(songSelect, { target: { value: 'suno-v2' } });
    fireEvent.click(screen.getByRole('button', { name: '设为当前默认播放歌曲' }));
    await waitFor(() => expect(defaultPayloads[1]).toMatchObject({ articleId: 1, versionId: 'suno-v2' }));
    expect(screen.getByRole('button', { name: '当前歌曲已是默认播放歌曲' })).not.toBeDisabled();
    const songControls = screen.getByRole('button', { name: '导出视频' }).closest('.song-listening-controls') as HTMLElement;
    expect(within(songControls).queryByRole('button', { name: '创作中心' })).not.toBeInTheDocument();
    expect(within(songControls).getByRole('button', { name: '导出视频' })).toBeDisabled();
  });

  it('starts song playback from the selected original line', async () => {
    window.location.hash = '/books/7/player?articleId=1&mode=song';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box. He shares it with his team.',
      sentences: ['Tom finds a bright snack box.', 'He shares it with his team.'],
      sentenceCount: 2,
      createdAt: new Date().toISOString(),
      averageScore: 86,
      seriesId: 7,
      seriesTitle: 'Space Story Series',
    };
    const playPayloads: Array<Record<string, unknown>> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, {
            articles: [article],
            series: [
              {
                id: 7,
                title: 'Space Story Series',
                description: '',
                coverImagePath: null,
                createdAt: new Date().toISOString(),
                updatedAt: new Date().toISOString(),
              },
            ],
          });
        }
        if (type === 'listening.open') {
          return ok(message.id, type, {
            article,
            items: article.sentences.map((english, index) => ({ index, english, chinese: '' })),
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, { articleId: article.id, enabled: true, status: 'empty', pages: [] });
        }
        if (type === 'listening.fullscreenReady') {
          return ok(message.id, type, { ready: true, reasons: [] });
        }
        if (type === 'listening.songState') {
          return ok(message.id, type, {
            articleId: article.id,
            status: 'ready',
            source: 'suno',
            audioPath: 'suno-v1.mp3',
            versions: [
              {
                id: 'suno-v1',
                audioPath: 'suno-v1.mp3',
                title: 'Suno 版本 1',
                timelineStatus: 'ready',
                timelinePath: 'timeline-v1.json',
                isDefault: true,
              },
            ],
          });
        }
        if (type === 'listening.songPlay') {
          playPayloads.push(payload);
          return ok(message.id, type, { playbackState: 'playing' });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    fireEvent.click(await screen.findByText('Tom finds a bright snack box.'));
    fireEvent.click(await screen.findByRole('button', { name: '开始播放' }));
    await waitFor(() =>
      expect(playPayloads[0]).toMatchObject({
        articleId: 1,
        versionId: 'suno-v1',
        startLineIndex: 0,
      }),
    );
    expect(await screen.findByRole('button', { name: '停止歌曲' })).toBeInTheDocument();

    fireEvent.click(await screen.findByText('He shares it with his team.'));
    await waitFor(() =>
      expect(playPayloads[1]).toMatchObject({
        articleId: 1,
        versionId: 'suno-v1',
        startLineIndex: 1,
      }),
    );
  });

  it('exports the selected song video from the song player action', async () => {
    window.location.hash = '/books/7/player?articleId=1&mode=song';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box.',
      sentences: ['Tom finds a bright snack box.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 86,
      seriesId: 7,
      seriesTitle: 'Space Story Series',
    };
    const settingsPayloads: Array<Record<string, unknown>> = [];
    const recordPayloads: Array<Record<string, unknown>> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, {
            articles: [article],
            series: [
              {
                id: 7,
                title: 'Space Story Series',
                description: '',
                coverImagePath: null,
                createdAt: new Date().toISOString(),
                updatedAt: new Date().toISOString(),
              },
            ],
          });
        }
        if (type === 'listening.open') {
          return ok(message.id, type, {
            article,
            items: [{ index: 0, english: article.sentences[0], chinese: '汤姆找到一个明亮的点心盒。' }],
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: article.id,
            enabled: true,
            status: 'ready',
            pages: [
              {
                articleId: article.id,
                seriesId: 7,
                pageIndex: 0,
                sentenceStartIndex: 0,
                sentenceEndIndex: 0,
                paragraphText: article.sentences[0],
                imagePath: 'F:/Tomato/picture_book/song-video.png',
                status: 'ready',
                errorMessage: null,
              },
            ],
          });
        }
        if (type === 'recording.settings.load') {
          return ok(message.id, type, {
            codec: 'h264',
            resolution: '1920x1080',
            pageTransition: 'none',
            subtitleMode: 'srt',
            outputDirectory: 'F:\\Tomato\\recording-export',
            fps: 25,
          });
        }
        if (type === 'recording.settings.save') {
          settingsPayloads.push(payload);
          return ok(message.id, type, {
            codec: String(payload.codec ?? 'h264'),
            resolution: String(payload.resolution ?? '1920x1080'),
            pageTransition: String(payload.pageTransition ?? 'none'),
            subtitleMode: String(payload.subtitleMode ?? 'srt'),
            outputDirectory: 'F:\\Tomato\\recording-export',
            fps: 25,
          });
        }
        if (type === 'listening.recordingReady') {
          return ok(message.id, type, { ready: true, reasons: [] });
        }
        if (type === 'listening.songState') {
          return ok(message.id, type, {
            articleId: article.id,
            status: 'ready',
            source: 'suno',
            audioPath: 'suno-v1.mp3',
            versions: [
              {
                id: 'suno-v1',
                audioPath: 'suno-v1.mp3',
                title: 'Suno 版本 1',
                timelineStatus: 'ready',
                timelinePath: 'timeline-v1.json',
                isDefault: true,
              },
            ],
          });
        }
        if (type === 'listening.songRecordVideo') {
          recordPayloads.push(payload);
          return ok(message.id, type, {
            outputPath: 'F:\\Tomato\\recording-export\\subtitled\\song-subtitled.mp4',
            subtitlePath: 'F:\\Tomato\\recording-export\\srt\\song-srt.srt',
            durationMs: 5000,
            segments: 1,
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    const exportButton = await screen.findByRole('button', { name: '导出视频' });
    await waitFor(() => expect(exportButton).not.toBeDisabled());
    const songControls = exportButton.closest('.song-listening-controls') as HTMLElement;
    expect(within(songControls).queryByRole('button', { name: '创作中心' })).not.toBeInTheDocument();
    fireEvent.click(exportButton);

    const dialog = await screen.findByRole('dialog', { name: '录制视频设置' });
    chooseRecordingOption(dialog, '字幕', '两版视频 + SRT');
    fireEvent.click(within(dialog).getByRole('button', { name: '开始录制' }));

    await waitFor(() => expect(settingsPayloads[0]).toMatchObject({ subtitleMode: 'both' }));
    await waitFor(() => expect(recordPayloads[0]).toMatchObject({
      articleId: 1,
      versionId: 'suno-v1',
      codec: 'h264',
      resolution: '1920x1080',
      pageTransition: 'none',
      subtitleMode: 'both',
      fps: 25,
    }));
  });

  it('keeps the current picture during song subtitle gaps', async () => {
    window.location.hash = '/books/7/player?articleId=1&mode=song';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box. He shares it with his team.',
      sentences: ['Tom finds a bright snack box.', 'He shares it with his team.'],
      sentenceCount: 2,
      createdAt: new Date().toISOString(),
      averageScore: 86,
      seriesId: 7,
      seriesTitle: 'Space Story Series',
    };
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, {
            articles: [article],
            series: [
              {
                id: 7,
                title: 'Space Story Series',
                description: '',
                coverImagePath: null,
                createdAt: new Date().toISOString(),
                updatedAt: new Date().toISOString(),
              },
            ],
          });
        }
        if (type === 'listening.open') {
          return ok(message.id, type, {
            article,
            items: article.sentences.map((english, index) => ({ index, english, chinese: '' })),
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: article.id,
            enabled: true,
            status: 'ready',
            pages: [
              {
                articleId: article.id,
                seriesId: 7,
                pageIndex: 0,
                sentenceStartIndex: 0,
                sentenceEndIndex: 0,
                paragraphText: article.sentences[0],
                imagePath: 'F:/Tomato/picture_book/original-0.png',
                imageUri: null,
                status: 'ready',
                errorMessage: null,
              },
              {
                articleId: article.id,
                seriesId: 7,
                pageIndex: 1,
                sentenceStartIndex: 1,
                sentenceEndIndex: 1,
                paragraphText: article.sentences[1],
                imagePath: 'F:/Tomato/picture_book/original-1.png',
                imageUri: null,
                status: 'ready',
                errorMessage: null,
              },
            ],
          });
        }
        if (type === 'pictureBook.pageImage') {
          return ok(message.id, type, {
            articleId: article.id,
            pageIndex: Number(payload.pageIndex ?? 0),
            variant: payload.variant,
            imageUri: `data:image/png;base64,THUMBNAIL_${payload.pageIndex}`,
          });
        }
        if (type === 'listening.fullscreenReady') {
          return ok(message.id, type, {
            ready: true,
            reasons: [],
            requiredEnglish: 2,
            readyEnglish: 2,
            requiredChinese: 0,
            readyChinese: 0,
            missingEnglish: [],
            missingChinese: [],
            failed: 0,
          });
        }
        if (type === 'listening.songState') {
          return ok(message.id, type, {
            articleId: article.id,
            status: 'ready',
            source: 'suno',
            audioPath: 'suno-v1.mp3',
            versions: [
              {
                id: 'suno-v1',
                audioPath: 'suno-v1.mp3',
                title: 'Suno 版本 1',
                timelineStatus: 'ready',
                timelinePath: 'timeline-v1.json',
                isDefault: true,
              },
            ],
          });
        }
        if (type === 'listening.songPlay') {
          return ok(message.id, type, { playbackState: 'playing' });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    const sceneImage = () => document.querySelector('.picture-book-scene img') as HTMLImageElement | null;
    await waitFor(() => expect(sceneImage()?.getAttribute('src')).toBe('data:image/png;base64,THUMBNAIL_0'));
    fireEvent.click(await screen.findByRole('button', { name: '开始播放' }));

    act(() => {
      window.__tomatoNativeEvent?.({
        type: 'listening.song.position',
        payload: {
          articleId: article.id,
          versionId: 'suno-v1',
          positionMs: 1000,
          durationMs: 5000,
          cue: {
            lineIndex: 0,
            startMs: 900,
            endMs: 1300,
            english: 'Song first line',
            chinese: '',
            confidence: 0.92,
            method: 'matched',
          },
        },
      });
    });
    expect(await screen.findByRole('heading', { name: 'Song first line' })).toBeInTheDocument();
    await waitFor(() => expect(sceneImage()?.getAttribute('src')).toBe('data:image/png;base64,THUMBNAIL_0'));

    act(() => {
      window.__tomatoNativeEvent?.({
        type: 'listening.song.position',
        payload: {
          articleId: article.id,
          versionId: 'suno-v1',
          positionMs: 1800,
          durationMs: 5000,
          cue: null,
        },
      });
    });
    expect(screen.getByRole('heading', { name: 'Song first line' })).toBeInTheDocument();
    expect(sceneImage()?.getAttribute('src')).toBe('data:image/png;base64,THUMBNAIL_0');

    act(() => {
      window.__tomatoNativeEvent?.({
        type: 'listening.song.position',
        payload: {
          articleId: article.id,
          versionId: 'suno-v1',
          positionMs: 2600,
          durationMs: 5000,
          cue: {
            lineIndex: 1,
            startMs: 2500,
            endMs: 3000,
            english: 'Song second line',
            chinese: '',
            confidence: 0.9,
            method: 'matched',
          },
        },
      });
    });
    expect(await screen.findByRole('heading', { name: 'Song second line' })).toBeInTheDocument();
    await waitFor(() => expect(sceneImage()?.getAttribute('src')).toBe('data:image/png;base64,THUMBNAIL_1'));
  });

  it('opens fullscreen song playback with subtitle cues and pause controls', async () => {
    window.location.hash = '/books/7/player?articleId=1&mode=song';
    class InstantImage {
      decoding = '';
      complete = true;
      naturalWidth = 1280;
      onload: (() => void) | null = null;
      onerror: (() => void) | null = null;
      set src(_value: string) {
        queueMicrotask(() => this.onload?.());
      }
      decode() {
        return Promise.resolve();
      }
    }
    vi.stubGlobal('Image', InstantImage);

    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box. He shares it with his team.',
      sentences: ['Tom finds a bright snack box.', 'He shares it with his team.'],
      sentenceCount: 2,
      createdAt: new Date().toISOString(),
      averageScore: 86,
      seriesId: 7,
      seriesTitle: 'Space Story Series',
    };
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        const payload = (message.payload ?? {}) as Record<string, unknown>;
        calls.push({ type, payload });
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, {
            articles: [article],
            series: [
              {
                id: 7,
                title: 'Space Story Series',
                description: '',
                coverImagePath: null,
                createdAt: new Date().toISOString(),
                updatedAt: new Date().toISOString(),
              },
            ],
          });
        }
        if (type === 'listening.open') {
          return ok(message.id, type, {
            article,
            items: article.sentences.map((english, index) => ({ index, english, chinese: '' })),
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: article.id,
            enabled: true,
            status: 'ready',
            pages: [
              {
                articleId: article.id,
                seriesId: 7,
                pageIndex: 0,
                sentenceStartIndex: 0,
                sentenceEndIndex: 0,
                paragraphText: article.sentences[0],
                imagePath: 'F:/Tomato/picture_book/original-0.png',
                imageUri: 'data:image/png;base64,FULL_0',
                status: 'ready',
                errorMessage: null,
              },
              {
                articleId: article.id,
                seriesId: 7,
                pageIndex: 1,
                sentenceStartIndex: 1,
                sentenceEndIndex: 1,
                paragraphText: article.sentences[1],
                imagePath: 'F:/Tomato/picture_book/original-1.png',
                imageUri: 'data:image/png;base64,FULL_1',
                status: 'ready',
                errorMessage: null,
              },
            ],
          });
        }
        if (type === 'recording.settings.load') {
          return ok(message.id, type, {
            codec: 'h264',
            resolution: '1920x1080',
            pageTransition: 'none',
            subtitleMode: 'srt',
            outputDirectory: 'F:\\Tomato\\recording-export',
            fps: 25,
          });
        }
        if (type === 'listening.recordingReady') {
          return ok(message.id, type, { ready: true, reasons: [] });
        }
        if (type === 'listening.songState') {
          return ok(message.id, type, {
            articleId: article.id,
            status: 'ready',
            source: 'suno',
            audioPath: 'suno-v1.mp3',
            versions: [
              {
                id: 'suno-v1',
                audioPath: 'suno-v1.mp3',
                title: 'Suno 版本 1',
                durationMs: 5000,
                timelineStatus: 'ready',
                timelinePath: 'timeline-v1.json',
                isDefault: true,
              },
            ],
          });
        }
        if (type === 'listening.songPlay') {
          return ok(message.id, type, { playbackState: 'playing' });
        }
        if (type === 'listening.songPause') {
          return ok(message.id, type, { paused: true });
        }
        if (type === 'listening.songResume') {
          return ok(message.id, type, { resumed: true });
        }
        if (type === 'listening.songStop') {
          return ok(message.id, type, { stopped: true });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    const fullscreenButton = await screen.findByRole('button', { name: '全屏播放' });
    await waitFor(() => expect(fullscreenButton).not.toBeDisabled());
    fireEvent.click(fullscreenButton);
    const dialog = await screen.findByRole('dialog', { name: '全屏歌曲播放' });
    await waitFor(() =>
      expect(calls.find((call) => call.type === 'listening.songPlay')?.payload).toMatchObject({
        articleId: 1,
        versionId: 'suno-v1',
      }),
    );

    act(() => {
      window.__tomatoNativeEvent?.({
        type: 'listening.song.position',
        payload: {
          articleId: article.id,
          versionId: 'suno-v1',
          positionMs: 1000,
          durationMs: 5000,
          cue: {
            lineIndex: 0,
            startMs: 900,
            endMs: 1300,
            english: 'Song first line',
            chinese: '歌曲第一句',
            confidence: 0.92,
            method: 'matched',
          },
        },
      });
    });
    expect(await within(dialog).findByRole('heading', { name: 'Song first line' })).toBeInTheDocument();
    expect(within(dialog).getByText('歌曲第一句')).toBeInTheDocument();
    expect(within(dialog).getByLabelText('播放进度 20%')).toBeInTheDocument();

    act(() => {
      window.__tomatoNativeEvent?.({
        type: 'listening.song.position',
        payload: {
          articleId: article.id,
          versionId: 'suno-v1',
          positionMs: 1500,
          durationMs: 5000,
          cue: null,
        },
      });
    });
    expect(within(dialog).getByRole('heading', { name: 'Song first line' })).toBeInTheDocument();

    fireEvent.click(dialog);
    fireEvent.click(within(dialog).getByRole('button', { name: '暂停' }));
    await waitFor(() => expect(calls.some((call) => call.type === 'listening.songPause')).toBe(true));
    expect(within(dialog).getByRole('button', { name: '继续' })).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole('button', { name: '继续' }));
    await waitFor(() => expect(calls.some((call) => call.type === 'listening.songResume')).toBe(true));

    fireEvent.click(within(dialog).getByRole('button', { name: '退出全屏' }));
    await waitFor(() => expect(screen.queryByRole('dialog', { name: '全屏歌曲播放' })).not.toBeInTheDocument());
    await waitFor(() => expect(calls.some((call) => call.type === 'listening.songStop')).toBe(true));
  });

  it('generates song subtitles before recording a Suno song video', async () => {
    window.location.hash = '/creation?articleId=1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box.',
      sentences: ['Tom finds a bright snack box.'],
      sentenceCount: 1,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const timelinePayloads: Array<Record<string, unknown>> = [];
    const recordPayloads: Array<Record<string, unknown>> = [];
    const settingsPayloads: Array<Record<string, unknown>> = [];
    let resolveTimelineCommand: (() => void) | null = null;
    let resolveRecordCommand: (() => void) | null = null;
    let currentSongState: ListeningSongStatePayload = {
      articleId: article.id,
      status: 'ready',
      stylePrompt: 'Suno auto style',
      audioPath: 'suno-v1.mp3',
      errorMessage: '',
      source: 'suno',
      versions: [
        {
          id: 'suno-v1',
          audioPath: 'suno-v1.mp3',
          title: 'Suno 版本 1',
          stylePrompt: 'Suno auto style',
          styleKey: 'suno:suno auto style',
          timelineStatus: 'missing',
        },
      ],
    };
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article] });
        }
        if (type === 'settings.load') {
          return ok(message.id, type, {
            tts: { resourceId: 'seed-tts-2.0', speakerId: 'en_female_dacey_uranus_bigtts' },
            song: { sunoOutputDirectory: 'mock', sunoTimeoutMinutes: 20 },
            voices: [],
          });
        }
        if (type === 'recording.settings.load') {
          return ok(message.id, type, {
            codec: 'h264',
            resolution: '1920x1080',
            pageTransition: 'none',
            subtitleMode: 'srt',
            outputDirectory: 'F:\\Tomato\\recording-export',
            fps: 25,
          });
        }
        if (type === 'recording.settings.save') {
          const payload = (message.payload ?? {}) as Record<string, unknown>;
          settingsPayloads.push(payload);
          return ok(message.id, type, {
            codec: String(payload.codec ?? 'h264'),
            resolution: String(payload.resolution ?? '1920x1080'),
            pageTransition: String(payload.pageTransition ?? 'none'),
            subtitleMode: String(payload.subtitleMode ?? 'srt'),
            outputDirectory: 'F:\\Tomato\\recording-export',
            fps: 25,
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, {
            articleId: article.id,
            enabled: true,
            status: 'ready',
            pages: [
              {
                articleId: article.id,
                pageNumber: 1,
                sentenceStartIndex: 0,
                sentenceEndIndex: 0,
                imagePath: 'page-1.png',
                imageDataUrl: 'data:image/png;base64,PAGE',
              },
            ],
          });
        }
        if (type === 'listening.songState') {
          return ok(message.id, type, currentSongState);
        }
        if (type === 'listening.songTimelineGenerate') {
          const payload = (message.payload ?? {}) as Record<string, unknown>;
          timelinePayloads.push(payload);
          return new Promise<BridgeResponse>((resolve) => {
            resolveTimelineCommand = () => {
              currentSongState = {
                articleId: article.id,
                status: 'ready',
                stylePrompt: 'Suno auto style',
                audioPath: 'suno-v1.mp3',
                errorMessage: '',
                source: 'suno',
                versions: [
                  {
                    id: 'suno-v1',
                    audioPath: 'suno-v1.mp3',
                    title: 'Suno 版本 1',
                    stylePrompt: 'Suno auto style',
                    styleKey: 'suno:suno auto style',
                    timelineStatus: 'ready',
                    timelinePath: 'timeline.json',
                    timelineConfidence: 0.92,
                  },
                ],
              };
              resolve(ok(message.id, type, currentSongState));
            };
          });
        }
        if (type === 'listening.songRecordVideo') {
          const payload = (message.payload ?? {}) as Record<string, unknown>;
          recordPayloads.push(payload);
          return new Promise<BridgeResponse>((resolve) => {
            resolveRecordCommand = () => {
              resolve(ok(message.id, type, {
                outputPath: 'F:\\Tomato\\recording-export\\song.mp4',
                srtPath: 'F:\\Tomato\\recording-export\\song.srt',
                durationMs: 3200,
                segments: 1,
              }));
            };
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    await clickSelectedCreationAction('歌曲');
    expect(await screen.findByRole('button', { name: 'Suno 版本 1' })).toBeInTheDocument();
    expect(screen.queryByText('Suno auto style')).not.toBeInTheDocument();
    const recordButton = await screen.findByRole('button', { name: '导出歌曲视频' });
    expect(recordButton).toBeDisabled();

    fireEvent.click(screen.getByRole('button', { name: '生成歌曲字幕' }));

    await waitFor(() => expect(timelinePayloads[0]).toMatchObject({ articleId: 1, versionId: 'suno-v1' }));
    expect(screen.getByText('正在生成歌曲字幕')).toBeInTheDocument();
    expect(screen.getByText(/预计超时倒计时/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '设置' }));
    expect(window.location.hash).toBe('#/creation?articleId=1');
    expect(screen.getByText('正在生成歌曲字幕')).toBeInTheDocument();
    await act(async () => {
      resolveTimelineCommand?.();
    });
    await waitFor(() => expect(screen.queryByText('正在生成歌曲字幕')).not.toBeInTheDocument());
    expect(await screen.findByRole('button', { name: '字幕已生成' })).toBeInTheDocument();
    const enabledRecordButton = screen.getByRole('button', { name: '导出歌曲视频' });
    expect(enabledRecordButton).not.toBeDisabled();
    fireEvent.click(enabledRecordButton);
    const dialog = await screen.findByRole('dialog', { name: '录制视频设置' });
    chooseRecordingOption(dialog, '字幕', '内置字幕视频');
    fireEvent.click(within(dialog).getByRole('button', { name: '开始录制' }));

    await waitFor(() => expect(recordPayloads[0]).toMatchObject({
      articleId: 1,
      versionId: 'suno-v1',
      codec: 'h264',
      resolution: '1920x1080',
      pageTransition: 'none',
      subtitleMode: 'burnedIn',
    }));
    expect(settingsPayloads[0]).toMatchObject({ subtitleMode: 'burnedIn' });
    expect(screen.getByText('正在导出歌曲视频')).toBeInTheDocument();
    expect(screen.getByText(/预计超时倒计时/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '设置' }));
    expect(window.location.hash).toBe('#/creation?articleId=1');
    expect(screen.getByText('正在导出歌曲视频')).toBeInTheDocument();
    await act(async () => {
      resolveRecordCommand?.();
    });
    await waitFor(() => expect(screen.queryByText('正在导出歌曲视频')).not.toBeInTheDocument());
    await waitFor(() => expect(screen.getByRole('button', { name: 'Suno 版本 1' })).toBeInTheDocument());
    expect(screen.getByRole('button', { name: '字幕已生成' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '导出歌曲视频' })).not.toBeDisabled();
  }, 10000);

  it('opens a word translation card and resumes listening after closing it', async () => {
    window.location.hash = '/listen/1';
    const article = {
      id: 1,
      title: 'Space Snacks',
      content: 'Tom finds a bright snack box. He shares it with his team.',
      sentences: ['Tom finds a bright snack box.', 'He shares it with his team.'],
      sentenceCount: 2,
      createdAt: new Date().toISOString(),
      averageScore: 86,
    };
    const calls: string[] = [];
    let resolvePlayback: (() => void) | null = null;
    const ok = (id: unknown, type: string, payload: unknown): BridgeResponse => ({
      id: String(id),
      ok: true,
      type: `${type}.result`,
      payload,
    });

    window.flutter_inappwebview = {
      callHandler: vi.fn(async (_handlerName: string, message: Record<string, unknown>): Promise<BridgeResponse> => {
        const type = String(message.type ?? '');
        calls.push(type);
        if (type === 'app.ready' || type === 'article.list') {
          return ok(message.id, type, { articles: [article] });
        }
        if (type === 'listening.open') {
          return ok(message.id, type, {
            article,
            items: [
              { index: 0, english: article.sentences[0], chinese: '汤姆发现了一个明亮的零食盒。' },
              { index: 1, english: article.sentences[1], chinese: '他把它分享给自己的队友。' },
            ],
          });
        }
        if (type === 'listening.prepare') {
          return ok(message.id, type, { prepared: true });
        }
        if (type === 'listening.playSequence') {
          window.__tomatoNativeEvent?.({
            type: 'listening.playback',
            payload: { articleId: 1, index: 0, part: 'english', state: 'partStart' },
          });
          return new Promise((resolve) => {
            resolvePlayback = () =>
              resolve(ok(message.id, type, { playbackState: 'success' }));
          });
        }
        if (type === 'listening.pause') {
          return ok(message.id, type, { paused: true });
        }
        if (type === 'listening.resume') {
          return ok(message.id, type, { resumed: true });
        }
        if (type === 'word.lookup') {
          return ok(message.id, type, {
            word: 'bright',
            phonetic: '/brait/',
            meaning: '明亮的；聪明的；鲜艳的',
            sentenceMeaning: '在本句中表示“明亮的”。',
          });
        }
        if (type === 'word.play') {
          return ok(message.id, type, { playbackState: 'success' });
        }
        if (type === 'word.stop') {
          return ok(message.id, type, { stopped: true });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    const heading = await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' });
    fireEvent.click(screen.getByRole('button', { name: '重听本句' }));
    await waitFor(() => expect(heading).toHaveClass('playing-text'));

    fireEvent.click(within(heading).getByRole('button', { name: 'bright' }));

    expect(await screen.findByRole('dialog', { name: 'bright' })).toBeInTheDocument();
    expect(await screen.findByText('/brait/')).toBeInTheDocument();
    expect(screen.getByText('明亮的；聪明的；鲜艳的')).toBeInTheDocument();
    expect(screen.getByText('在本句中表示“明亮的”。')).toBeInTheDocument();
    await waitFor(() => {
      expect(calls).toContain('listening.pause');
      expect(calls).toContain('word.play');
      expect(calls).toContain('word.lookup');
    });

    fireEvent.click(screen.getByRole('button', { name: '关闭单词翻译' }));

    await waitFor(() => {
      expect(calls).toContain('word.stop');
      expect(calls).toContain('listening.resume');
    });

    act(() => {
      resolvePlayback?.();
    });
  });

  it('labels the final follow action as complete on the last sentence', async () => {
    window.location.hash = '/follow/1';

    render(<App />);

    expect(await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' })).toBeInTheDocument();
    await waitFor(() => {
      expect(screen.getByRole('button', { name: /开始录音/ })).not.toBeDisabled();
    });

    act(() => {
      window.__tomatoNativeEvent?.({
        type: 'follow.state',
        payload: {
          status: 'ready',
          article: {
            id: 1,
            title: 'Space Snacks',
            content: 'Tom finds a bright snack box. He shares it with his team.',
            sentences: ['Tom finds a bright snack box.', 'He shares it with his team.'],
            sentenceCount: 2,
            createdAt: new Date().toISOString(),
            averageScore: 86,
          },
          currentIndex: 1,
          totalSentences: 2,
          currentSentence: 'He shares it with his team.',
          currentTranslation: '他把它分享给自己的队友。',
          isLastSentence: true,
          step: 'idle',
          playbackState: 'success',
          result: null,
          hasRecording: false,
        },
      });
    });

    expect(screen.getByRole('button', { name: /完成/ })).not.toBeDisabled();
    expect(screen.getByRole('button', { name: /开始录音/ })).not.toBeDisabled();
    expect(screen.getByText('他把它分享给自己的队友。')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /下一句/ })).not.toBeInTheDocument();
    expect(screen.queryByText('伙伴状态')).not.toBeInTheDocument();
    expect(document.querySelector('.partner-status')).not.toBeInTheDocument();
  });

  it('shows only the compact follow score after recording result', async () => {
    window.location.hash = '/follow/1';

    render(<App />);

    expect(await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' })).toBeInTheDocument();
    await waitFor(() => {
      expect(screen.getByRole('button', { name: /开始录音/ })).not.toBeDisabled();
    });

    act(() => {
      window.__tomatoNativeEvent?.({
        type: 'follow.state',
        payload: {
          status: 'ready',
          article: {
            id: 1,
            title: 'Space Snacks',
            content: 'Tom finds a bright snack box.',
            sentences: ['Tom finds a bright snack box.'],
            sentenceCount: 1,
            createdAt: new Date().toISOString(),
            averageScore: 88,
          },
          currentIndex: 0,
          totalSentences: 1,
          currentSentence: 'Tom finds a bright snack box.',
          currentTranslation: '汤姆发现了一个明亮的零食盒。',
          isLastSentence: true,
          step: 'result',
          playbackState: 'success',
          hasRecording: true,
          result: {
            overallScore: 88,
            accuracyScore: 91,
            fluencyScore: 84,
            completenessScore: 90,
            prosodyScore: 83,
            recognizedText: 'Tom finds a bright snack box.',
            isMock: false,
            words: [{ word: 'Tom', score: 90, errorType: 'None' }],
          },
        },
      });
    });

    expect(screen.getByText('总体评分')).toBeInTheDocument();
    expect(screen.getByText('88')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /播放录音/ })).not.toBeDisabled();
    expect(screen.queryByText('看完得分后，可以重播、重试或进入下一句。')).not.toBeInTheDocument();
    expect(screen.queryByText('Accuracy 准确度')).not.toBeInTheDocument();
    expect(screen.queryByText('识别结果')).not.toBeInTheDocument();
  });

  it('reveals chat translations only after clicking the blurred text', async () => {
    window.location.hash = '/chat/1';
    render(<App />);

    const translation = await screen.findByRole('button', { name: '汤姆发现了什么？' });
    expect(translation).toHaveClass('chat-translation');
    expect(translation).not.toHaveClass('revealed');

    fireEvent.click(translation);

    expect(translation).toHaveClass('revealed');
  });

  it('does not render old monster, reward, or mascot artwork', async () => {
    window.location.hash = '/chat/1';
    const { container } = render(<App />);

    expect(await screen.findByText('对话提纲')).toBeInTheDocument();
    expect(await screen.findByText('轮到你说英语啦。')).toBeInTheDocument();
    expect(await screen.findByText('对话进度 1 / 8')).toBeInTheDocument();
    expect(await screen.findByPlaceholderText('输入或按住说英语')).not.toBeDisabled();
    const imageSources = Array.from(container.querySelectorAll('img')).map((img) =>
      img.getAttribute('src') ?? '',
    );
    expect(imageSources.length).toBeGreaterThan(0);
    expect(imageSources.some((src) => src.includes('monster-buddy.png'))).toBe(false);
    expect(imageSources.some((src) => src.includes('monster-mic.png'))).toBe(false);
    expect(imageSources.some((src) => src.includes('reward-star.png'))).toBe(false);
    expect(imageSources.some((src) => src.includes('reward-brick.png'))).toBe(false);
    expect(imageSources.some((src) => src.includes('lego/'))).toBe(false);
    expect(container.querySelector('.chat-side-card')).toBeNull();
  });

  it('returns to the hall when ending chat', async () => {
    window.location.hash = '/chat/1';
    render(<App />);

    const endButton = await screen.findByText('结束对话');
    fireEvent.click(endButton);

    expect(window.location.hash).toBe('#/');
  });
});
