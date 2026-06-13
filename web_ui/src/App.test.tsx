import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import App from './App';
import { splitSentences } from './sentenceSplitter';
import type { BridgeResponse } from './types';

describe('App', () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
    cleanup();
    window.location.hash = '';
    window.localStorage.clear();
    delete window.flutter_inappwebview;
  });

  it('renders the task hall shell', async () => {
    window.location.hash = '/';

    render(<App />);

    expect(await screen.findByText('今天也要快乐开口说英语！')).toBeInTheDocument();
    expect(await screen.findByText('我的书籍')).toBeInTheDocument();
    expect((await screen.findAllByText('Space Story Series')).length).toBeGreaterThan(0);
    expect(await screen.findByText('Tomato')).toBeInTheDocument();
    expect(await screen.findByText('English')).toBeInTheDocument();
    expect(await screen.findByText('Happy Talking')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '任务' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '新增' })).not.toBeInTheDocument();
    expect(screen.getByText('任务卡')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /Space Story Series/ }));
    expect(await screen.findByText('章节列表')).toBeInTheDocument();
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
        styleGuide: {},
        bible: {},
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
    fireEvent.click(await screen.findByRole('button', { name: /开始闯关/ }));
    await waitFor(() => expect(window.location.hash).toBe('#/listen/88'));

    cleanup();
    window.location.hash = '/';
    installBridge();
    render(<App />);
    fireEvent.click(await screen.findByRole('button', { name: /Alice's Adventures in Wonderland/ }));
    fireEvent.click(await screen.findByRole('button', { name: 'E28 Tail Story' }));
    await waitFor(() => expect(window.location.hash).toBe('#/listen/88'));

    cleanup();
    window.location.hash = '/';
    installBridge();
    render(<App />);
    fireEvent.click(await screen.findByRole('button', { name: /Alice's Adventures in Wonderland/ }));
    fireEvent.click(await screen.findByRole('button', { name: '进入《E28 Tail Story》听力' }));
    await waitFor(() => expect(window.location.hash).toBe('#/listen/88'));

    cleanup();
    window.location.hash = '/';
    installBridge();
    render(<App />);
    fireEvent.click(await screen.findByRole('button', { name: /Alice's Adventures in Wonderland/ }));
    fireEvent.click(await screen.findByRole('button', { name: '跟读' }));
    await waitFor(() => expect(window.location.hash).toBe('#/follow/88'));
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
        styleGuide: {},
        bible: {},
        coverImagePath: null,
        createdAt: now,
        updatedAt: now,
      },
      {
        id: 2,
        title: 'Beta Book',
        styleGuide: {},
        bible: {},
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
        styleGuide: {},
        bible: {},
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

  it('renders settings without manual API key input', async () => {
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
  });

  it('starts the new article editor empty and enables save after real content', async () => {
    window.location.hash = '/article/new';

    render(<App />);

    expect(await screen.findByText('新增文章')).toBeInTheDocument();

    const titleInput = screen.getByLabelText(/文章标题/);
    const contentInput = screen.getByLabelText(/文章内容/);
    const saveButton = screen.getByRole('button', { name: /保存任务/ });

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
    expect(await screen.findByText('任务卡已加入大厅')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /Space Story Series/ }));
    expect(await screen.findByText('Opens Lunch Shares')).toBeInTheDocument();
  });

  it('rejects article content over 8000 characters without truncating it', async () => {
    window.location.hash = '/article/new';

    render(<App />);

    const contentInput = await screen.findByLabelText(/文章内容/);
    const saveButton = screen.getByRole('button', { name: /保存任务/ });
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

  it('shows empty books and deletes only empty series', async () => {
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
      styleGuide: {},
      bible: {},
      coverImagePath: null,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };
    const filledSeries = {
      id: 2,
      title: 'Alice Series',
      styleGuide: {},
      bible: {},
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
        return ok(message.id, type, {});
      }),
    };

    const { container } = render(<App />);

    expect(await screen.findByText('Empty Book')).toBeInTheDocument();
    expect(screen.getAllByText('Alice Series').length).toBeGreaterThan(0);
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

  it('sends picture-book series choices when saving a new task', async () => {
    window.location.hash = '/article/new';
    const calls: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const series = [
      {
        id: 7,
        title: 'Alice Series',
        styleGuide: {},
        bible: {},
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
            chapterOrder: 2,
          };
          return ok(message.id, type, { article, articles: [article], series });
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
    fireEvent.click(screen.getByRole('button', { name: /保存任务/ }));

    await waitFor(() => {
      const createCall = calls.find((call) => call.type === 'article.create');
      expect(createCall?.payload).toMatchObject({
        title: 'Alice Tea Time',
        content: 'Alice sees a bright table.',
        pictureBookEnabled: true,
        seriesId: 7,
      });
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
          return ok(message.id, type, { article, articles: [article], series: [] });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    const titleInput = await screen.findByLabelText(/文章标题/);
    const contentInput = screen.getByLabelText(/文章内容/);
    const saveButton = screen.getByRole('button', { name: /保存任务/ });

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

  it('opens listening practice and switches to bilingual playback mode', async () => {
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

    expect(await screen.findByText('英文')).toBeInTheDocument();
    expect(await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' })).toBeInTheDocument();
    expect(screen.getAllByRole('button', { name: 'bright' })).toHaveLength(1);
    expect(screen.getAllByText('汤姆发现了一个明亮的零食盒。').length).toBeGreaterThan(0);
    expect(screen.getByRole('button', { name: /开始播放/ })).not.toBeDisabled();
    expect(screen.getByText(/听力进度/)).toBeInTheDocument();
    expect(document.querySelector('.picture-book-scene')).toBeInTheDocument();
    expect(document.querySelector('.listening-side')).not.toBeInTheDocument();

    const bilingualButton = screen.getByRole('button', { name: '中英对照' });
    fireEvent.click(bilingualButton);

    expect(bilingualButton).toHaveAttribute('aria-pressed', 'true');
    expect(screen.queryByText('会按顺序播放英文，再播放中文对照。')).not.toBeInTheDocument();
    expect(screen.queryByText('中英对照听力')).not.toBeInTheDocument();
    expect(document.querySelector('.listening-page .waveform')).not.toBeInTheDocument();
    expect(document.querySelector('.listening-page .wave-mini')).not.toBeInTheDocument();

    fireEvent.click(screen.getByText('He shares it with his team.').closest('.listening-row') as HTMLElement);
    fireEvent.click(screen.getByRole('button', { name: /开始播放/ }));

    await waitFor(() => {
      const playCalls = calls.filter((call) => call.type === 'listening.playSequence');
      expect(playCalls.length).toBeGreaterThan(0);
      expect(playCalls[0]?.payload).toMatchObject({ startIndex: 1, mode: 'bilingual' });
    });
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
            reasons: audioReady ? [] : ['英文音频还没有全部加载到内存'],
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
    expect(await screen.findByText('英文音频还没有全部加载到内存')).toBeInTheDocument();

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
        strictPreloaded: true,
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

  it('blocks the app with progress while exporting video and allows cancel', async () => {
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
        if (type === 'recording.settings.load') {
          return ok(message.id, type, {
            codec: 'h264',
            resolution: '1920x1080',
            pageTransition: 'none',
            outputDirectory: 'F:\\Tomato\\recording-export',
            ffmpegPath: 'F:\\Tomato\\ffmpeg.exe',
            fps: 25,
          });
        }
        if (type === 'recording.settings.save') {
          return ok(message.id, type, {
            codec: payload.codec,
            resolution: payload.resolution,
            pageTransition: payload.pageTransition,
            outputDirectory: 'F:\\Tomato\\recording-export',
            ffmpegPath: 'F:\\Tomato\\ffmpeg.exe',
            fps: 25,
          });
        }
        if (type === 'listening.open') {
          return ok(message.id, type, {
            article,
            items: [{ index: 0, english: article.sentences[0], chinese: '汤姆发现了一个明亮的零食盒。' }],
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
                sentenceEndIndex: 0,
                paragraphText: article.content,
                imagePath: 'ready.png',
                imageUri: 'data:image/png;base64,READY',
                status: 'ready',
              },
            ],
          });
        }
        if (type === 'listening.fullscreenReady' || type === 'listening.recordingReady') {
          return ok(message.id, type, {
            ready: true,
            reasons: [],
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
          queueMicrotask(() => {
            window.__tomatoNativeEvent?.({
              type: 'listening.recording.progress',
              payload: {
                articleId: 1,
                phase: 'rendering',
                progress: 0.42,
                completedFrames: 42,
                totalFrames: 100,
                message: '正在渲染视频帧',
              },
            });
          });
          return new Promise<BridgeResponse>(() => undefined);
        }
        if (type === 'listening.cancelRecording') {
          return ok(message.id, type, { cancelled: true });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' })).toBeInTheDocument();
    const recordButton = await screen.findByRole('button', { name: /录制视频/ });
    await waitFor(() => expect(recordButton).not.toBeDisabled());

    fireEvent.click(recordButton);
    const settingsDialog = await screen.findByRole('dialog', { name: '录制视频设置' });
    expect(within(settingsDialog).getByText('文件将保存到程序目录的 recording-export 文件夹。')).toBeInTheDocument();
    expect(within(settingsDialog).getByLabelText('编码')).toHaveValue('h264');
    expect(within(settingsDialog).getByLabelText('分辨率')).toHaveValue('1920x1080');
    expect(within(settingsDialog).getByLabelText('转场')).toHaveValue('none');
    expect(within(settingsDialog).queryByText('ffmpeg.exe 路径')).not.toBeInTheDocument();
    expect(within(settingsDialog).queryByText('保存文件夹')).not.toBeInTheDocument();
    fireEvent.click(within(settingsDialog).getByRole('button', { name: /开始录制/ }));
    const dialog = await screen.findByRole('dialog', { name: '录制视频中' });
    expect(dialog.parentElement).toHaveClass('recording-progress-overlay');
    expect(dialog.parentElement?.parentElement).toBe(document.body);
    expect(within(dialog).getByText('录制期间已禁止页面操作，可以随时取消并退出。')).toBeInTheDocument();
    expect(await within(dialog).findByText('正在渲染视频帧')).toBeInTheDocument();
    expect(within(dialog).getByText('42 / 100 帧')).toBeInTheDocument();

    fireEvent.click(within(dialog).getByRole('button', { name: '取消并退出' }));
    await waitFor(() => expect(screen.queryByRole('dialog', { name: '录制视频中' })).not.toBeInTheDocument());
    const saveCall = calls.find((call) => call.type === 'recording.settings.save');
    expect(saveCall?.payload).toMatchObject({
      codec: 'h264',
      resolution: '1920x1080',
      pageTransition: 'none',
    });
    expect(saveCall?.payload).not.toHaveProperty('outputDirectory');
    expect(saveCall?.payload).not.toHaveProperty('ffmpegPath');
    expect(calls.some((call) => call.type === 'listening.cancelRecording')).toBe(true);
    expect(await screen.findByText('录制已取消')).toBeInTheDocument();
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
        if (type === 'pictureBook.retryPage') {
          return ok(message.id, type, { ...failedPicture, status: 'generating' });
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
        type: 'pictureBook.retryPage',
        payload: { articleId: 1, pageIndex: 0 },
      });
    });
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
          ok('retry', 'pictureBook.retryPage', {
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
                imagePath: '/tmp/retry.png',
                imageUri: 'data:image/png;base64,READY',
                status: 'ready',
                errorMessage: null,
              },
            ],
          }),
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
        if (type === 'pictureBook.retryPage') {
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
      expect(calls.filter((call) => call.type === 'pictureBook.retryPage')).toHaveLength(1);
    });
    expect(retryButton).toBeDisabled();

    fireEvent.click(retryButton as HTMLElement);
    expect(calls.filter((call) => call.type === 'pictureBook.retryPage')).toHaveLength(1);

    act(() => {
      resolveRetry?.();
    });

    await waitFor(() => {
      expect(screen.queryByText('组图接口超时')).not.toBeInTheDocument();
    });
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

  it('opens song style dialog, suggests style, and shows completion after generation', async () => {
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
        if (type === 'pictureBook.state') {
          return ok(message.id, type, { articleId: article.id, enabled: true, status: 'empty', pages: [] });
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
        if (type === 'listening.songState') {
          return ok(message.id, type, {
            articleId: article.id,
            status: 'empty',
            stylePrompt: '',
            audioPath: null,
            errorMessage: '',
            source: 'minimax',
          });
        }
        if (type === 'listening.songSuggestStyle') {
          return ok(message.id, type, {
            articleId: article.id,
            status: 'empty',
            stylePrompt: 'bright children musical, whimsical adventure',
            audioPath: null,
            errorMessage: '',
            source: 'minimax',
          });
        }
        if (type === 'listening.songGenerate') {
          const payload = (message.payload ?? {}) as Record<string, unknown>;
          window.setTimeout(() => {
            window.__tomatoNativeEvent?.({
              type: 'listening.song.state',
              payload: {
                articleId: article.id,
                status: 'ready',
                stylePrompt: String(payload.stylePrompt ?? ''),
                audioPath: 'mock-song.mp3',
                errorMessage: '',
                lyricsCompressed: false,
                source: 'minimax',
              },
            });
          }, 5);
          return ok(message.id, type, {
            articleId: article.id,
            status: 'generating',
            stylePrompt: String(payload.stylePrompt ?? ''),
            source: String(payload.source ?? 'minimax'),
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /下载歌曲|歌曲/ }));
    expect(await screen.findByRole('dialog', { name: '歌曲风格设置' })).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: '生成合适的歌曲风格' }));
    expect(await screen.findByDisplayValue('bright children musical, whimsical adventure')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /开始生成歌曲/ }));

    await waitFor(() => expect(calls).toContain('listening.songGenerate'));
    expect(await screen.findByText('歌曲生成完成')).toBeInTheDocument();
  });

  it('submits Suno song generation with explicit login guidance', async () => {
    window.location.hash = '/listen/1';
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
            song: { defaultSource: 'suno', sunoOutputDirectory: 'mock', sunoTimeoutMinutes: 20 },
            voices: [],
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, { articleId: article.id, enabled: true, status: 'empty', pages: [] });
        }
        if (type === 'listening.open') {
          return ok(message.id, type, {
            article,
            items: [{ index: 0, english: article.sentences[0], chinese: '汤姆发现了一个明亮的零食盒。' }],
          });
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

    expect(await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /下载歌曲|歌曲/ }));
    expect(await screen.findByText(/优先点击 Suno 自带的魔法棒/)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '生成合适的歌曲风格' })).not.toBeInTheDocument();
    expect(screen.queryByLabelText('风格描述')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /开始生成歌曲/ }));

    await waitFor(() => expect(generatePayloads[0]?.source).toBe('suno'));
    expect(generatePayloads[0]?.stylePrompt).toBe('');
    expect(confirmSpy).toHaveBeenCalled();
    await waitFor(() =>
      expect(
        screen.getAllByText('Suno 歌词和自动风格已填写，请确认消耗 Suno credits 后创建。').length,
      ).toBeGreaterThan(0),
    );
    const songDialog = await screen.findByRole('dialog', { name: '歌曲风格设置' });
    fireEvent.click(within(songDialog).getByRole('button', { name: /确认创建歌曲/ }));

    await waitFor(() => expect(confirmPayloads[0]).toMatchObject({ articleId: 1 }));
    await waitFor(() => expect(screen.getAllByText('Suno 正在生成歌曲...').length).toBeGreaterThan(0));
    expect(confirmSpy).toHaveBeenCalledTimes(2);
    confirmSpy.mockRestore();
  });

  it('allows closing the song dialog when Suno needs manual action', async () => {
    window.location.hash = '/listen/1';
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
            song: { defaultSource: 'suno', sunoOutputDirectory: 'mock', sunoTimeoutMinutes: 20 },
            voices: [],
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, { articleId: article.id, enabled: true, status: 'empty', pages: [] });
        }
        if (type === 'listening.open') {
          return ok(message.id, type, {
            article,
            items: [{ index: 0, english: article.sentences[0], chinese: '汤姆发现了一个明亮的零食盒。' }],
          });
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

    expect(await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /下载歌曲|歌曲/ }));
    fireEvent.click(await screen.findByRole('button', { name: /开始生成歌曲/ }));

    await waitFor(() =>
      expect(
        screen.getAllByText('Suno 生成结果已出现，但没有找到 Download 或 Audio 下载按钮。').length,
      ).toBeGreaterThan(0),
    );
    const songDialog = screen.getByRole('dialog', { name: '歌曲风格设置' });
    expect(within(songDialog).getByRole('button', { name: /开始生成歌曲/ })).not.toBeDisabled();
    const closeButton = within(songDialog).getByRole('button', { name: '关闭' });
    expect(closeButton).not.toBeDisabled();
    fireEvent.click(closeButton);
    expect(screen.queryByRole('dialog', { name: '歌曲风格设置' })).not.toBeInTheDocument();
    confirmSpy.mockRestore();
  });

  it('retries downloading an existing Suno song link', async () => {
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
            song: { defaultSource: 'suno', sunoOutputDirectory: 'mock', sunoTimeoutMinutes: 20 },
            voices: [],
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, { articleId: article.id, enabled: true, status: 'empty', pages: [] });
        }
        if (type === 'listening.open') {
          return ok(message.id, type, {
            article,
            items: [{ index: 0, english: article.sentences[0], chinese: '汤姆发现了一个明亮的零食盒。' }],
          });
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
            automationStatus: 'downloading',
            manualActionMessage: '正在打开 Suno 已生成歌曲并尝试下载...',
          });
        }
        return ok(message.id, type, {});
      }),
    };

    render(<App />);

    expect(await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /下载歌曲|歌曲/ }));
    fireEvent.click(await screen.findByRole('tab', { name: '播放' }));
    fireEvent.click(await screen.findByRole('button', { name: /下载缺失版本/ }));

    await waitFor(() => expect(downloadPayloads[0]).toMatchObject({ articleId: 1 }));
    await waitFor(() =>
      expect(screen.getAllByText('正在打开 Suno 已生成歌曲并尝试下载...').length).toBeGreaterThan(0),
    );
  });

  it('plays a selected downloaded song version', async () => {
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
            song: { defaultSource: 'suno', sunoOutputDirectory: 'mock', sunoTimeoutMinutes: 20 },
            voices: [],
          });
        }
        if (type === 'pictureBook.state') {
          return ok(message.id, type, { articleId: article.id, enabled: true, status: 'empty', pages: [] });
        }
        if (type === 'listening.open') {
          return ok(message.id, type, {
            article,
            items: [{ index: 0, english: article.sentences[0], chinese: '汤姆发现了一个明亮的零食盒。' }],
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

    expect(await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '歌曲' }));
    expect(await screen.findByRole('tab', { name: '播放' })).toHaveAttribute('aria-selected', 'true');
    await waitFor(() => expect(screen.getAllByText('Suno auto style').length).toBeGreaterThan(0));
    expect(await screen.findByText('Dreamy lullaby style')).toBeInTheDocument();
    fireEvent.click(await screen.findByRole('button', { name: 'Suno 版本 2' }));

    await waitFor(() => expect(playPayloads[0]).toMatchObject({ articleId: 1, versionId: 'suno-v2' }));
  });

  it('generates song subtitles before recording a Suno song video', async () => {
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
            song: { defaultSource: 'suno', sunoOutputDirectory: 'mock', sunoTimeoutMinutes: 20 },
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
        if (type === 'listening.open') {
          return ok(message.id, type, {
            article,
            items: [{ index: 0, english: article.sentences[0], chinese: '汤姆发现了一个明亮的零食盒。' }],
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

    expect(await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '歌曲' }));
    const dialog = await screen.findByRole('dialog', { name: '歌曲风格设置' });
    const recordButton = await within(dialog).findByRole('button', { name: '录制歌曲视频' });
    expect(recordButton).toBeDisabled();

    fireEvent.click(within(dialog).getByRole('button', { name: '生成歌曲字幕' }));

    await waitFor(() => expect(timelinePayloads[0]).toMatchObject({ articleId: 1, versionId: 'suno-v1' }));
    const readyDialog = await screen.findByRole('dialog', { name: '歌曲风格设置' });
    expect(await within(readyDialog).findByRole('button', { name: '字幕已生成' })).toBeInTheDocument();
    const enabledRecordButton = within(readyDialog).getByRole('button', { name: '录制歌曲视频' });
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

  it('does not render old monster or reward artwork', async () => {
    window.location.hash = '/chat/1';
    const { container } = render(<App />);

    expect(await screen.findByText('奖励预览')).toBeInTheDocument();
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
    expect(imageSources.some((src) => src.includes('lego/prop-star.png'))).toBe(true);
    expect(imageSources.some((src) => src.includes('lego/prop-bricks.png'))).toBe(true);
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
