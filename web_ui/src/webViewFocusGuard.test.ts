import { describe, expect, it, beforeEach, afterEach } from 'vitest';
import { installWebViewFocusGuard } from './webViewFocusGuard';

describe('webViewFocusGuard', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
    window.__tomatoWebViewFocusGuardInstalled = undefined;
  });

  afterEach(() => {
    window.__tomatoWebViewFocusGuardInstalled = undefined;
  });

  it('refocuses editable control after immediate blur following pointer down', async () => {
    const input = document.createElement('input');
    input.id = 'probe-input';
    document.body.appendChild(input);
    installWebViewFocusGuard();

    input.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
    input.focus();
    input.blur();

    await new Promise((resolve) => {
      window.requestAnimationFrame(() => window.requestAnimationFrame(resolve));
    });

    expect(document.activeElement).toBe(input);
  });
});
