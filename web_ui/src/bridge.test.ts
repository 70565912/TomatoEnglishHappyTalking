import { afterEach, describe, expect, it, vi } from 'vitest';
import { emitNativeEvent, onNativeEvent, sendNative } from './bridge';
import type {
  BookTransferPayload,
  ListeningSongStatePayload,
  SettingsState,
} from './types';

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

  it('mocks external song imports when Flutter bridge is unavailable', async () => {
    const response = await sendNative<ListeningSongStatePayload>(
      'listening.songImportExternal',
      { articleId: 12 },
    );

    expect(response.articleId).toBe(12);
    expect(response.source).toBe('external_audio');
    expect(response.versions?.[0]).toMatchObject({
      title: '导入音乐',
      source: 'external_audio',
      timelineStatus: 'missing',
    });
  });

  it('mocks book export and import when Flutter bridge is unavailable', async () => {
    const exported = await sendNative<BookTransferPayload>('series.export', {
      seriesId: 1,
    });
    expect(exported.cancelled).toBe(false);
    expect(exported.outputPath).toContain('.zip');

    const imported = await sendNative<BookTransferPayload>('series.import');
    expect(imported.cancelled).toBe(false);
    expect(imported.seriesId).toBe(99);
    expect(imported.articles?.[0].seriesId).toBe(99);
    expect(imported.series?.[0].title).toBe('Imported Book');
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
    expect(response.cloud?.textProvider).toBe('aliyun_bailian');
    expect(response.cloud?.imageProvider).toBe('aliyun_bailian');
    expect(response.cloud?.ttsProvider).toBe('aliyun_bailian');
    expect(response.cloud?.elevenLabs?.apiKeyConfigured).toBe(false);
    expect(response.cloud?.elevenLabs?.apiKeyMask).toBe('');
    expect(response.cloud?.elevenLabs?.ttsModel).toBe('eleven_multilingual_v2');
    expect(response.voiceCatalog?.elevenLabs?.length).toBeGreaterThan(0);
    expect(response.voiceCatalogErrors?.elevenLabs).toBeNull();
    expect(JSON.stringify(response)).not.toContain('eleven-music-key');
    expect(response.voices).toHaveLength(102);
    expect(response.voices[0].scene).toBeTruthy();
  });

  it('saves split cloud providers and masks ElevenLabs key in mock settings', async () => {
    const response = await sendNative<SettingsState>('settings.saveCloud', {
      textProvider: 'volcengine',
      imageProvider: 'aliyun_bailian',
      ttsProvider: 'elevenlabs',
      elevenLabsApiKey: 'eleven-secret-key-123456',
      elevenLabsTtsModel: 'eleven_turbo_v2_5',
      elevenLabsTtsVoiceId: 'JBFqnCBsd6RMkjVDRZzb',
      elevenLabsMusicModel: 'music_v2',
    });

    expect(response.cloud?.aiProvider).toBe('volcengine');
    expect(response.cloud?.textProvider).toBe('volcengine');
    expect(response.cloud?.imageProvider).toBe('aliyun_bailian');
    expect(response.cloud?.ttsProvider).toBe('elevenlabs');
    expect(response.cloud?.elevenLabs?.apiKeyConfigured).toBe(true);
    expect(response.cloud?.elevenLabs?.apiKeyMask).toBe('****MOCK');
    expect(response.cloud?.elevenLabs?.ttsModel).toBe('eleven_turbo_v2_5');
    expect(response.tts.resourceId).toBe('eleven_turbo_v2_5');
    expect(response.tts.speakerId).toBe('JBFqnCBsd6RMkjVDRZzb');
    expect(JSON.stringify(response)).not.toContain('eleven-secret-key-123456');
  });

  it('saves selected voice in mock settings payload', async () => {
    const response = await sendNative<SettingsState>('settings.saveVoice', {
      speakerId: 'en_male_tim_uranus_bigtts',
      aiProvider: 'volcengine',
    });

    expect(response.tts.speakerId).toBe('en_male_tim_uranus_bigtts');
    expect(response.cloud?.volcengine.ttsSpeakerId).toBe('en_male_tim_uranus_bigtts');
  });

  it('saves selected ElevenLabs voice in mock settings payload', async () => {
    const response = await sendNative<SettingsState>('settings.saveVoice', {
      speakerId: '21m00Tcm4TlvDq8ikWAM',
      ttsProvider: 'elevenlabs',
    });

    expect(response.tts.speakerId).toBe('21m00Tcm4TlvDq8ikWAM');
    expect(response.cloud?.elevenLabs?.ttsVoiceId).toBe('21m00Tcm4TlvDq8ikWAM');
  });

  it('mocks ElevenLabs song generation when Flutter bridge is unavailable', async () => {
    const response = await sendNative<ListeningSongStatePayload>(
      'listening.songGenerate',
      { articleId: 12, source: 'elevenlabs_music' },
    );

    expect(response.articleId).toBe(12);
    expect(response.source).toBe('elevenlabs_music');
    expect(response.versions?.[0]).toMatchObject({
      title: 'ElevenLabs 版本 1',
      source: 'elevenlabs_music',
    });
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
