import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';
import App from './App';

describe('App', () => {
  afterEach(() => {
    cleanup();
    window.location.hash = '';
  });

  it('renders the task hall shell', async () => {
    window.location.hash = '/';

    render(<App />);

    expect(await screen.findByText('今天也要快乐开口说英语！')).toBeInTheDocument();
    expect(await screen.findByText('最新任务卡')).toBeInTheDocument();
    expect(await screen.findByText('Tomato English')).toBeInTheDocument();
    expect(await screen.findByText('Happy Talking')).toBeInTheDocument();
  });

  it('renders settings without manual API key input', async () => {
    window.location.hash = '/settings';

    render(<App />);

    expect(await screen.findByText('API 与服务')).toBeInTheDocument();
    expect(await screen.findByText('服务状态（运行时）')).toBeInTheDocument();
    expect(screen.getByLabelText('选择声音')).toBeInTheDocument();
    expect(screen.getByText(/Vivi 2.0 · 中文\/英文/)).toBeInTheDocument();
    expect(screen.getAllByText('TTS 语音合成').length).toBeGreaterThan(0);
    expect(screen.getAllByText('BigASR 语音识别').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Realtime 对话服务').length).toBeGreaterThan(0);
    expect(screen.getAllByText('TTS 资源 ID').length).toBeGreaterThan(0);
    expect(screen.queryByText('火山引擎 API Key')).not.toBeInTheDocument();
    expect(screen.queryByPlaceholderText(/api key/i)).not.toBeInTheDocument();
  });
});
