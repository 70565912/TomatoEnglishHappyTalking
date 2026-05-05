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

    expect(await screen.findByText('今日任务大厅')).toBeInTheDocument();
    expect(await screen.findByText('Tomato Quest')).toBeInTheDocument();
  });

  it('renders settings as read-only encrypted configuration status', async () => {
    window.location.hash = '/settings';

    render(<App />);

    expect(await screen.findByText('火山引擎 API Key')).toBeInTheDocument();
    expect(screen.getByText('语音合成')).toBeInTheDocument();
    expect(screen.getByText('语音识别')).toBeInTheDocument();
    expect(screen.getAllByText('统一火山引擎 API Key').length).toBeGreaterThan(0);
    expect(screen.queryByPlaceholderText(/api key/i)).not.toBeInTheDocument();
    expect(screen.queryByText('保存语音装备')).not.toBeInTheDocument();
  });
});
