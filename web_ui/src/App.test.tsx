import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import App from './App';
import { splitSentences } from './sentenceSplitter';
import type { BridgeResponse } from './types';

describe('App', () => {
  afterEach(() => {
    cleanup();
    window.location.hash = '';
    delete window.flutter_inappwebview;
  });

  it('renders the task hall shell', async () => {
    window.location.hash = '/';

    render(<App />);

    expect(await screen.findByText('今天也要快乐开口说英语！')).toBeInTheDocument();
    expect(await screen.findByText('主线任务')).toBeInTheDocument();
    expect(await screen.findByText('Tomato')).toBeInTheDocument();
    expect(await screen.findByText('English')).toBeInTheDocument();
    expect(await screen.findByText('Happy Talking')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '任务' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: '新增' })).not.toBeInTheDocument();
    expect(screen.getByText('我的书籍')).toBeInTheDocument();
    expect(screen.getByText('开口读')).toBeInTheDocument();
    expect(screen.queryByText('听全文')).not.toBeInTheDocument();
  });

  it('prefers generated picture-book covers in latest and mission cards', async () => {
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

    expect(await screen.findAllByText('Generated Cover Story')).toHaveLength(1);
    expect(await screen.findByText('Generated Series')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /Generated Series/ }));
    expect(await screen.findByText('章节列表')).toBeInTheDocument();
    const imageSources = Array.from(container.querySelectorAll('.latest-content img, .book-card img, .mission-row img')).map((img) =>
      img.getAttribute('src'),
    );
    expect(imageSources).toEqual([generatedCover, generatedCover, generatedCover]);
  });

  it('renders settings without manual API key input', async () => {
    window.location.hash = '/settings';

    render(<App />);

    expect(await screen.findByText('选择番茄助教的发音')).toBeInTheDocument();
    expect(await screen.findByText('发音人')).toBeInTheDocument();
    expect(screen.getByRole('listbox', { name: '可选声音' })).toBeInTheDocument();
    expect(screen.queryByRole('combobox')).not.toBeInTheDocument();
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
    await waitFor(() => {
      expect(screen.getAllByText('Opens Lunch Shares').length).toBeGreaterThan(0);
    });
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

    render(<App />);

    expect(await screen.findByText('英文')).toBeInTheDocument();
    expect(await screen.findByRole('heading', { name: 'Tom finds a bright snack box.' })).toBeInTheDocument();
    expect(screen.getAllByRole('button', { name: 'bright' })).toHaveLength(1);
    expect(screen.getAllByText('汤姆发现了一个明亮的零食盒。').length).toBeGreaterThan(0);
    expect(screen.getByRole('button', { name: /开始听全文/ })).not.toBeDisabled();
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
        if (type === 'listening.play') {
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
        if (type === 'listening.play') {
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
    expect(screen.getByText('/brait/')).toBeInTheDocument();
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
  });

  it('returns to the hall when ending chat', async () => {
    window.location.hash = '/chat/1';
    render(<App />);

    const endButton = await screen.findByText('结束对话');
    fireEvent.click(endButton);

    expect(window.location.hash).toBe('#/');
  });
});
