import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';
import App from './App';
import { splitSentences } from './sentenceSplitter';

describe('App', () => {
  afterEach(() => {
    cleanup();
    window.location.hash = '';
  });

  it('renders the task hall shell', async () => {
    window.location.hash = '/';

    render(<App />);

    expect(await screen.findByText('今天也要快乐开口说英语！')).toBeInTheDocument();
    expect(await screen.findByText('主线任务')).toBeInTheDocument();
    expect(await screen.findByText('Tomato')).toBeInTheDocument();
    expect(await screen.findByText('English')).toBeInTheDocument();
    expect(await screen.findByText('Happy Talking')).toBeInTheDocument();
  });

  it('renders settings without manual API key input', async () => {
    window.location.hash = '/settings';

    render(<App />);

    expect(await screen.findByText('选择番茄伙伴的发音')).toBeInTheDocument();
    expect(await screen.findByText('发音人')).toBeInTheDocument();
    expect(screen.getByRole('listbox', { name: '可选声音' })).toBeInTheDocument();
    expect(screen.queryByRole('combobox')).not.toBeInTheDocument();
    expect(screen.getByText('Vivi 2.0')).toBeInTheDocument();
    expect(screen.getByText(/个发音人/)).toBeInTheDocument();
    expect(screen.getByText('当前声音')).toBeInTheDocument();
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
    expect(screen.getByText('输入英文短文后，这里会自动切成适合跟读的短句。')).toBeInTheDocument();

    fireEvent.change(titleInput, { target: { value: 'Lunch Mission' } });
    fireEvent.change(contentInput, {
      target: {
        value: 'Tom opens a lunch box. He shares a red apple with Mia.',
      },
    });

    expect(saveButton).not.toBeDisabled();
    expect(screen.getByText('Tom opens a lunch box.')).toBeInTheDocument();
  });

  it('splits long article preview text into standard reading chunks', () => {
    const chunks = splitSentences(
      'Tom walks into the bright library, finds a tiny blue robot beside the big window, and asks it to help him read a funny story before lunch.',
    );

    expect(chunks.length).toBeGreaterThan(1);
    expect(chunks.every((chunk) => chunk.split(/\s+/).length <= 18)).toBe(true);
    expect(chunks.every((chunk) => chunk.length <= 106)).toBe(true);
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

  it('auto-plays the first follow sentence and enables recording afterward', async () => {
    window.location.hash = '/follow/1';

    render(<App />);

    expect(await screen.findByText(/finds a bright snack box\./)).toBeInTheDocument();
    await waitFor(() => {
      expect(screen.getByRole('button', { name: /开始录音/ })).not.toBeDisabled();
    });
    expect(screen.getByRole('button', { name: /播放原音/ })).not.toBeDisabled();
    expect(screen.getByRole('button', { name: /重播/ })).not.toBeDisabled();
    expect(screen.getByRole('button', { name: /再试一次/ })).toBeDisabled();
    expect(screen.getByRole('button', { name: /下一句/ })).not.toBeDisabled();
    expect(screen.getByText('原音播放完成，现在可以开始跟读。')).toBeInTheDocument();
    expect(screen.getByText('点击录音，跟读这句话')).toBeInTheDocument();
  });

  it('labels the final follow action as complete on the last sentence', async () => {
    window.location.hash = '/follow/1';

    render(<App />);

    expect(await screen.findByText(/finds a bright snack box\./)).toBeInTheDocument();
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
        },
      });
    });

    expect(screen.getByRole('button', { name: /完成/ })).not.toBeDisabled();
    expect(screen.getByRole('button', { name: /开始录音/ })).not.toBeDisabled();
    expect(screen.getByText('他把它分享给自己的队友。')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /下一句/ })).not.toBeInTheDocument();
    const recordStatus = screen.getByText('跟读录音').closest('.status-item');
    if (!recordStatus) throw new Error('Missing record status item');
    expect(recordStatus).toHaveClass('active');
  });

  it('shows only the compact follow score after recording result', async () => {
    window.location.hash = '/follow/1';

    render(<App />);

    expect(await screen.findByText(/finds a bright snack box\./)).toBeInTheDocument();
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
