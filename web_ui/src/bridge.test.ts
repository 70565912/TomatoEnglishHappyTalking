import { afterEach, describe, expect, it, vi } from 'vitest';
import { emitNativeEvent, onNativeEvent, sendNative } from './bridge';
import type { SettingsState } from './types';

describe('bridge client', () => {
  afterEach(() => {
    delete window.flutter_inappwebview;
    delete window.chrome;
    vi.useRealTimers();
  });

  it('delivers native events to listeners', () => {
    const listener = vi.fn();
    const off = onNativeEvent('avatar.state', listener);

    emitNativeEvent({
      type: 'avatar.state',
      payload: { mode: 'idle' },
    });

    expect(listener).toHaveBeenCalledWith({ mode: 'idle' });
    off();
  });

  it('uses mock native response when Flutter bridge is unavailable', async () => {
    const response = await sendNative<{ articles: unknown[] }>('article.list');

    expect(response.articles.length).toBeGreaterThan(0);
  });

  it('waits for a delayed Flutter bridge in embedded WebView', async () => {
    vi.useFakeTimers();
    window.chrome = { webview: {} };
    const callHandler = vi.fn().mockResolvedValue({
      id: 'native_1',
      ok: true,
      type: 'article.list.result',
      payload: { articles: [{ id: 7, title: 'Native Article' }] },
    });

    const pending = sendNative<{ articles: Array<{ id: number }> }>(
      'article.list',
    );
    window.setTimeout(() => {
      window.flutter_inappwebview = { callHandler };
      window.dispatchEvent(new Event('flutterInAppWebViewPlatformReady'));
    }, 25);

    await vi.advanceTimersByTimeAsync(30);
    const response = await pending;

    expect(callHandler).toHaveBeenCalledWith(
      'tomatoBridge',
      expect.objectContaining({ type: 'article.list' }),
    );
    expect(response.articles[0].id).toBe(7);
  });


  it('does not expose secret or non-voice config fields in settings payload', async () => {
    const response = await sendNative<SettingsState>('settings.load');
    const rawResponse = response as unknown as Record<string, unknown>;

    expect(rawResponse.volcApi).toBeUndefined();
    expect(rawResponse.bigAsr).toBeUndefined();
    expect(rawResponse.realtime).toBeUndefined();
    expect((response.tts as unknown as Record<string, unknown>).apiKey).toBeUndefined();
    expect(response.voices).toHaveLength(102);
    expect(response.voices[0].scene).toBeTruthy();
  });

  it('saves selected voice in mock settings payload', async () => {
    const response = await sendNative<SettingsState>('settings.saveVoice', {
      speakerId: 'en_male_tim_uranus_bigtts',
    });

    expect(response.tts.speakerId).toBe('en_male_tim_uranus_bigtts');
  });

  it('reports bridge success and failure summaries to native diagnostics', async () => {
    const calls: Array<Record<string, unknown>> = [];
    const callHandler = vi.fn().mockImplementation(
      async (_handlerName: string, message: Record<string, unknown>) => {
        calls.push(message);
        if (message.type === 'diagnostics.clientLog') {
          return {
            id: message.id,
            ok: true,
            type: 'diagnostics.clientLog.result',
            payload: { accepted: true },
          };
        }
        if (message.type === 'article.fail') {
          return {
            id: message.id,
            ok: false,
            type: 'article.fail.error',
            error: { message: 'native failed' },
          };
        }
        return {
          id: message.id,
          ok: true,
          type: `${message.type}.result`,
          payload: { ok: true },
        };
      },
    );
    window.flutter_inappwebview = { callHandler };

    await sendNative('article.list', {
      apiKey: 'secret-token-123456789012',
      content: 'Tom reads a story.',
    });
    await flushPromises();

    await expect(sendNative('article.fail')).rejects.toThrow('native failed');
    await flushPromises();

    const diagnosticMessages = calls.filter(
      (message) => message.type === 'diagnostics.clientLog',
    );
    expect(
      diagnosticMessages.map((message) => (message.payload as Record<string, unknown>).event),
    ).toEqual(expect.arrayContaining(['command.success', 'command.failed']));

    const successPayload = diagnosticMessages.find(
      (message) => (message.payload as Record<string, unknown>).event === 'command.success',
    )?.payload as Record<string, unknown>;
    const data = successPayload.data as {
      payload: Record<string, unknown>;
    };
    expect(data.payload.apiKey).toBe('[redacted]');
  });

  it('reports console errors through diagnostics without leaking secrets', async () => {
    const calls: Array<Record<string, unknown>> = [];
    window.flutter_inappwebview = {
      callHandler: vi.fn().mockImplementation(
        async (_handlerName: string, message: Record<string, unknown>) => {
          calls.push(message);
          return {
            id: message.id,
            ok: true,
            type: `${message.type}.result`,
            payload: { accepted: true },
          };
        },
      ),
    };

    console.error('client render failed');
    const event = new Event('unhandledrejection') as PromiseRejectionEvent;
    Object.defineProperty(event, 'reason', {
      value: new Error('Bearer secret-token-123456789012 exploded'),
    });
    window.dispatchEvent(event);
    await flushPromises();

    const diagnosticMessages = calls.filter(
      (message) => message.type === 'diagnostics.clientLog',
    );
    expect(
      diagnosticMessages.map((message) => (message.payload as Record<string, unknown>).event),
    ).toEqual(expect.arrayContaining(['console.error', 'window.unhandled_rejection']));
    expect(JSON.stringify(diagnosticMessages)).not.toContain('secret-token-123456789012');
    expect(JSON.stringify(diagnosticMessages)).toContain('[redacted]');
  });
});

function flushPromises() {
  return new Promise((resolve) => window.setTimeout(resolve, 0));
}
