import { describe, expect, it, vi } from 'vitest';
import { emitNativeEvent, onNativeEvent, sendNative } from './bridge';
import type { SettingsState } from './types';

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
});
