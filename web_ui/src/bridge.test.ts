import { describe, expect, it, vi } from 'vitest';
import { emitNativeEvent, onNativeEvent, sendNative } from './bridge';

describe('bridge client', () => {
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

  it('does not expose secret fields in settings payload', async () => {
    const response = await sendNative<Record<string, Record<string, unknown>>>(
      'settings.load',
    );

    expect(response.volcApi.configured).toBe(false);
    expect(response.volcApi.apiKey).toBeUndefined();
    expect(response.tts.apiKey).toBeUndefined();
    expect(response.bigAsr.apiKey).toBeUndefined();
    expect(response.realtime.accessKey).toBeUndefined();
  });
});
