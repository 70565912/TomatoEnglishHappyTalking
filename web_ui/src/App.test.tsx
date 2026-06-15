import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import App from './App';
import { splitSentences } from './sentenceSplitter';
import type { BridgeResponse } from './types';

async function clickSelectedCreationAction(name: string | RegExp) {
  await screen.findByText('章节列表');
  const actions = await waitFor(() => {
    const element = document.querySelector('.mission-row.active .mission-actions');
    expect(element).not.toBeNull();
    return element as HTMLElement;
  });
  fireEvent.click(within(actions).getByRole('button', { name }));
}

function promptReviewPayloadForTest(articleId = 1, regenerate = false) {
  const scenes = [
    {
      pageIndex: 0,
      sentenceStartIndex: 0,
      sentenceEndIndex: 0,
      paragraphText: 'Tom finds a bright snack box.',
      title: 'The Box',
      story: 'Tom discovers the snack box.',
      visual: 'Tom finds a bright snack box in a cozy spaceship kitchen.',
    },
  ];
  return {
    reviewId: `review-${articleId}`,
    articleId,
    chapterId: 1,
    seriesId: 1,
    regenerate,
    bookDescription: 'A warm space picture book; Tom is a curious child in a red hoodie.',
    storyBrief: 'Tom explores small discoveries with a friendly team.',
    chapterBrief: 'Tom finds a bright snack box.',
    groupPrompt: `Generate a coherent sequence of full-frame 16:9 English picture-book illustrations.\n\nImage 1:\nVisual direction: ${scenes[0].visual}`,
    scenes,
    createdAt: new Date().toISOString(),
  };
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
    fireEvent.click(screen.getByRole('button', { name: /Space Story Series/ }));
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
    const now = new Date().toISOString();
    const alphaArticle = {
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
    const betaTwo = {
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
    const betaTen = {
      ...betaTwo,
      id: 3,
      title: 'E10 - Beta',
      content: 'Beta ten.',
      sentences: ['Beta ten.'],
      createdAt: '2026-06-09T10:00:00.000Z',
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
          return ok(message.id, type, { articles: [alphaArticle, betaTen, betaTwo], series });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByLabelText('Beta Book 章节列表')).toBeInTheDocument();
    const betaTwoButton = screen.getByRole('button', { name: 'E2 - Beta' });
    const betaTenButton = screen.getByRole('button', { name: 'E10 - Beta' });
    expect(betaTwoButton.compareDocumentPosition(betaTenButton) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(window.localStorage.getItem('tomato.recentSeriesKey.v1')).toBe('series:2');
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
    expect(screen.getByRole('button', { name: '跟读' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '对话' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '听力' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '删除' })).not.toBeInTheDocument();
    expect(screen.queryByText('Alpha Chapter')).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: /Alpha Book/ }));
    expect(await screen.findByText('Alpha Chapter')).toBeInTheDocument();
    expect(screen.queryByText('Beta Practice Chapter')).not.toBeInTheDocument();
  });

  it('renames an article title from the chapter list', async () => {
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

    fireEvent.click(await screen.findByRole('button', { name: /Alice Series/ }));
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
    expect(screen.getByText('Vivi 2.0')).toBeInTheDocument();
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

  it('switches cloud and song settings with tabs instead of select lists', async () => {
    window.location.hash = '/settings';

    render(<App />);

    expect(await screen.findByRole('tab', { name: '阿里云百炼' })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByLabelText(/^百炼 Key/)).toBeInTheDocument();
    expect(screen.getByText('百炼 Base URL')).toBeInTheDocument();
    expect(screen.queryByText('方舟 Base URL')).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole('tab', { name: '火山引擎' }));
    expect(screen.getByRole('tab', { name: '火山引擎' })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByLabelText(/^方舟 Key/)).toBeInTheDocument();
    expect(screen.getByText('方舟 Base URL')).toBeInTheDocument();
    expect(screen.queryByText('百炼 Base URL')).not.toBeInTheDocument();

    expect(screen.getByRole('tab', { name: 'Suno 网页自动化' })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByText('Suno 输出目录')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('tab', { name: '百炼 fun-music' }));
    expect(screen.getByRole('tab', { name: '百炼 fun-music' })).toHaveAttribute('aria-selected', 'true');
    expect(screen.queryByText('Suno 输出目录')).not.toBeInTheDocument();
    expect(screen.getByText(/Key 和音乐模型在上方/)).toBeInTheDocument();
  });

  it('starts the new article editor empty and enables save after real content', async () => {
    window.location.hash = '/article/new';

    render(<App />);

    expect(await screen.findByText('新增文章')).toBeInTheDocument();

    const titleInput = screen.getByLabelText(/文章标题/);
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

    expect(saveButton).not.toBeDisabled();
    expect(titleInput).toHaveValue('');
    expect(screen.getByText('Tom opens a lunch box.')).toBeInTheDocument();

    fireEvent.click(saveButton);
    expect(await screen.findByRole('dialog', { name: '绘本提示词审核' })).toBeInTheDocument();
    expect((await screen.findAllByText('Opens Lunch Shares')).length).toBeGreaterThan(0);
  });

  it('rejects article content over 8000 characters without truncating it', async () => {
    window.location.hash = '/article/new';

    render(<App />);

    const contentInput = await screen.findByLabelText(/文章内容/);
    const saveButton = screen.getByRole('button', { name: /保存章节/ });
    const overLimitContent = 'a'.repeat(8001);

    fireEvent.change(contentInput, { target: { value: overLimitContent } });

    expect(contentInput).toHaveValue(overLimitContent);
    expect(screen.getByText('文章内容不能超过 8000 个字符')).toBeInTheDocument();
    expect(screen.getByText('8001/8000')).toBeInTheDocument();
    expect(saveButton).toBeDisabled();

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
    const descriptionInput = screen.getByLabelText('书籍简介');
    const generateButton = screen.getByRole('button', { name: 'AI 自动生成新书籍简介' });

    expect(generateButton).toBeDisabled();
    fireEvent.change(bookTitleInput, { target: { value: 'Lily Garden' } });
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

    await waitFor(() => {
      expect(calls.find((call) => call.type === 'article.delete')?.payload).toMatchObject({ articleId: 42 });
    });
    expect(await screen.findByText('章节已删除')).toBeInTheDocument();
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

  it('collapses the creation-center chapter list after selecting a chapter', async () => {
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

    fireEvent.click(screen.getByRole('button', { name: '绘本' }));

    expect(await screen.findByText('章节列表已折叠')).toBeInTheDocument();
    const expandToggle = screen.getByRole('button', { name: '展开章节列表' });
    expect(expandToggle).toHaveTextContent('＞');
    expect(expandToggle).toHaveTextContent('Fold Me Chapter');
    expect(screen.getByText('Fold Me Chapter')).toBeInTheDocument();

    fireEvent.click(expandToggle);

    expect(await screen.findByText('章节列表')).toBeInTheDocument();
    const collapseToggle = screen.getByRole('button', { name: '折叠章节列表' });
    expect(collapseToggle).toHaveTextContent('∨');

    fireEvent.click(collapseToggle);

    expect(await screen.findByText('章节列表已折叠')).toBeInTheDocument();
  });

  it('sends picture-book series choices when saving a new chapter', async () => {
    window.location.hash = '/article/new';
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
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
            storyBrief: String(payload.storyBrief ?? ''),
            chapterBrief: String(payload.chapterBrief ?? ''),
            groupPrompt: String(payload.groupPrompt ?? ''),
            scenes: Array.isArray(payload.scenes) ? payload.scenes : [],
          });
        }
        if (type === 'pictureBook.confirmPromptReview') {
          return ok(message.id, type, {
            articleId: 42,
            enabled: true,
            status: 'generating',
            pages: [],
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
    expect(within(reviewDialog).getByRole('button', { name: 'AI 自动生成故事简述' })).toHaveTextContent(
      '自动生成故事简述',
    );
    expect(within(reviewDialog).getByRole('button', { name: 'AI 自动生成章节组图简述' })).toHaveTextContent(
      '自动生成章节组图简述',
    );
    expect(within(reviewDialog).getByRole('button', { name: 'AI 自动生成分镜描述' })).toHaveTextContent(
      '自动生成分镜描述',
    );
    expect(
      (within(reviewDialog).getByLabelText('组图总提示词') as HTMLTextAreaElement)
        .value,
    ).toContain('Scene story: Tom discovers the snack box.');
    fireEvent.click(within(reviewDialog).getByRole('button', { name: 'AI 自动生成书籍简介' }));
    await waitFor(() => {
      expect(calls.some((call) => call.type === 'pictureBook.refreshPromptReview')).toBe(true);
      expect(within(reviewDialog).getByLabelText('书籍简介')).toHaveValue(
        'Refreshed book description with a consistent Alice look.',
      );
    });
    fireEvent.change(within(reviewDialog).getByLabelText('书籍简介'), {
      target: { value: 'Alice keeps a blue dress and white apron.' },
    });
    fireEvent.change(within(reviewDialog).getByLabelText('第 1 个分镜画面描述'), {
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
      const confirmCall = calls.find((call) => call.type === 'pictureBook.confirmPromptReview');
      expect(confirmCall?.payload).toMatchObject({
        reviewId: 'review-42',
        bookDescription: 'Alice keeps a blue dress and white apron.',
      });
      expect(confirmCall?.payload.scenes).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            visual: 'Alice sees a bright table in a Victorian fantasy room.',
          }),
        ]),
      );
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
            seriesTitle: 'I Quit My Job',
            chapterOrder: 1,
          };
          return ok(message.id, type, {
            article,
            articles: [article],
            series: [
              {
                id: 12,
                title: 'I Quit My Job',
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
    const contentInput = screen.getByLabelText(/文章内容/);
    const saveButton = screen.getByRole('button', { name: /保存章节/ });

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
      });
    });
    expect(calls.some((call) => call.type === 'article.translateToEnglish')).toBe(false);
    expect(calls.some((call) => call.type === 'article.suggestTitle')).toBe(false);
    expect((await screen.findAllByText('I Quit My Job')).length).toBeGreaterThan(0);
  });

  it('splits long article preview text into short read-aloud chunks', () => {
    const chunks = splitSentences(
      'Tom walks into the bright library, finds a tiny blue robot beside the big window, and asks it to help him read a funny story before lunch.',
    );

    expect(chunks.length).toBeGreaterThan(1);
    expect(chunks.every((chunk) => chunk.split(/\s+/).length <= 22)).toBe(true);
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

    expect(chunks).toEqual([
      'There was a table set out under a tree in front of the house,',
      'and the March Hare and the Hatter were having tea at it:',
      'a Dormouse was sitting between them, fast asleep,',
      'and the other two were using it as a cushion,',
      'resting their elbows on it,',
      'and talking over its head.',
      '"Very uncomfortable for the Dormouse," thought Alice:',
      '"only as it\'s asleep, I suppose it doesn\'t mind."',
      'The table was a large one,',
      'but the three were all crowded together at one corner of it:',
      '"No room! No room!" they cried out when they saw Alice coming.',
    ]);
    expect(chunks.join(' ')).not.toContain('A Mad Tea-Party');
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
        if (type === 'listening.open') {
          return ok(message.id, type, {
            article,
            items: [
              { index: 0, english: article.sentences[0], chinese: '汤姆发现了一个明亮的零食盒。' },
              { index: 1, english: article.sentences[1], chinese: '他把它分享给自己的队友。' },
            ],
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
                imageUri: 'data:image/png;base64,READY',
                status: 'ready',
              },
            ],
          });
        }
        if (type === 'listening.fullscreenReady') {
          return ok(message.id, type, {
            ready: audioReady,
            reasons: audioReady ? [] : ['当前和下一句英文音频还没有加载到内存'],
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
    expect(await screen.findByText('当前和下一句英文音频还没有加载到内存')).toBeInTheDocument();

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
        if (type === 'listening.recordingReady') {
          return ok(message.id, type, {
            ready: true,
            reasons: [],
            encoderName: 'ffmpeg',
            resolution: '1920x1080',
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
          return ok(message.id, type, {
            outputPath: 'F:\\Tomato\\recording-export\\listening.mp4',
            durationMs: 3200,
            segments: 1,
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
    expect(await screen.findByText('听力视频')).toBeInTheDocument();
    expect(await screen.findByText('保存在 recording-export/')).toBeInTheDocument();
    expect(await screen.findByText('听力视频已准备好')).toBeInTheDocument();
    const exportButton = await screen.findByRole('button', { name: /导出听力视频/ });
    expect(exportButton).not.toBeDisabled();
    fireEvent.click(exportButton);

    await waitFor(() => {
      const recordCall = calls.find((call) => call.type === 'listening.recordVideo');
      expect(recordCall?.payload).toMatchObject({
        articleId: 1,
        codec: 'h264',
        resolution: '1920x1080',
        pageTransition: 'crossFade',
      });
    });
    expect(await screen.findByText('听力视频导出完成')).toBeInTheDocument();
    expect(screen.queryByRole('dialog', { name: '录制视频设置' })).not.toBeInTheDocument();
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

    await waitFor(() => {
      const generateCall = calls.find((call) => call.type === 'listening.songGenerate');
      expect(generateCall?.payload).toMatchObject({ articleId: 1, source: 'suno' });
    });
    expect(calls.some((call) => call.type === 'listening.songSuggestStyle')).toBe(false);
    expect(
      await screen.findByText('Suno 歌词和自动风格已填写，请确认消耗 Suno credits 后创建。'),
    ).toBeInTheDocument();
  });

  it('submits Suno song generation with explicit login guidance', async () => {
    window.location.hash = '/creation?articleId=1';
    const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(true);
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

    await waitFor(() => expect(generatePayloads[0]?.source).toBe('suno'));
    expect(generatePayloads[0]).not.toHaveProperty('stylePrompt');
    expect(confirmSpy).not.toHaveBeenCalled();
    await waitFor(() =>
      expect(
        screen.getAllByText('Suno 歌词和自动风格已填写，请确认消耗 Suno credits 后创建。').length,
      ).toBeGreaterThan(0),
    );
    fireEvent.click(await screen.findByRole('button', { name: /确认创建歌曲/ }));

    await waitFor(() => expect(confirmPayloads[0]).toMatchObject({ articleId: 1 }));
    await waitFor(() => expect(screen.getAllByText('Suno 正在生成歌曲...').length).toBeGreaterThan(0));
    expect(confirmSpy).toHaveBeenCalledTimes(1);
    confirmSpy.mockRestore();
  });

  it('shows manual Suno action guidance in the creation center', async () => {
    window.location.hash = '/creation?articleId=1';
    const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(true);
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

    await waitFor(() =>
      expect(
        screen.getAllByText('Suno 生成结果已出现，但没有找到 Download 或 Audio 下载按钮。').length,
      ).toBeGreaterThan(0),
    );
    expect(screen.queryByRole('dialog', { name: '歌曲设置' })).not.toBeInTheDocument();
    confirmSpy.mockRestore();
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
            status: 'ready',
            stylePrompt: 'Suno auto style',
            audioPath: 'suno-v1.mp3',
            errorMessage: '',
            source: 'suno',
            versions: [
              { id: 'suno-v1', audioPath: 'suno-v1.mp3', title: 'Suno 版本 1', songUrl: 'https://suno.com/song/one', stylePrompt: 'Suno auto style', styleKey: 'suno:suno auto style' },
              { id: 'suno-v2', audioPath: 'suno-v2.mp3', title: 'Suno 版本 2', songUrl: 'https://suno.com/song/two', stylePrompt: 'Suno auto style', styleKey: 'suno:suno auto style' },
              { id: 'suno-v3', audioPath: 'suno-v3.mp3', title: 'Dreamy 版本', songUrl: 'https://suno.com/song/three', stylePrompt: 'Dreamy lullaby style', styleKey: 'suno:dreamy lullaby style' },
            ],
          });
        }
        if (type === 'listening.songPlay') {
          const payload = (message.payload ?? {}) as Record<string, unknown>;
          playPayloads.push(payload);
          return ok(message.id, type, { playbackState: 'playing' });
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
            reasons: ['当前和下一句英文音频还没有加载到内存'],
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
          return ok(message.id, type, {
            articleId: article.id,
            status: 'ready',
            source: 'suno',
            stylePrompt: 'Suno auto style',
            audioPath: 'suno-v2.mp3',
            versions: versions.map((version) => ({ ...version, isDefault: version.id === 'suno-v2' })),
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
    expect(screen.queryByText('当前和下一句英文音频还没有加载到内存')).not.toBeInTheDocument();
    expect(screen.queryByText('这首歌还没有生成字幕，请到创作中心生成歌曲字幕。')).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /选择本地歌曲/ })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /去创作中心生成/ })).not.toBeInTheDocument();

    fireEvent.change(songSelect, { target: { value: 'suno-v2' } });
    expect(await screen.findByText('这首歌还没有生成字幕，请到创作中心生成歌曲字幕。')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '设为当前默认播放歌曲' }));
    await waitFor(() => expect(defaultPayloads[0]).toMatchObject({ articleId: 1, versionId: 'suno-v2' }));

    fireEvent.click(screen.getByRole('button', { name: '开始播放' }));
    await waitFor(() => expect(playPayloads[0]).toMatchObject({ articleId: 1, versionId: 'suno-v2' }));
    expect(screen.getAllByRole('button', { name: '创作中心' }).length).toBeGreaterThan(0);
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
          return ok(message.id, type, {
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
          });
        }
        if (type === 'listening.songTimelineGenerate') {
          const payload = (message.payload ?? {}) as Record<string, unknown>;
          timelinePayloads.push(payload);
          return ok(message.id, type, {
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
          });
        }
        if (type === 'listening.songRecordVideo') {
          const payload = (message.payload ?? {}) as Record<string, unknown>;
          recordPayloads.push(payload);
          return ok(message.id, type, {
            outputPath: 'F:\\Tomato\\recording-export\\song.mp4',
            srtPath: 'F:\\Tomato\\recording-export\\song.srt',
            durationMs: 3200,
            segments: 1,
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
    expect(await screen.findByRole('button', { name: '字幕已生成' })).toBeInTheDocument();
    const enabledRecordButton = screen.getByRole('button', { name: '导出歌曲视频' });
    expect(enabledRecordButton).not.toBeDisabled();
    fireEvent.click(enabledRecordButton);

    await waitFor(() => expect(recordPayloads[0]).toMatchObject({ articleId: 1, versionId: 'suno-v1' }));
  });

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
