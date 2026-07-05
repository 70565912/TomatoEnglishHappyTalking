declare global {
  interface Window {
    __tomatoWebViewFocusGuardInstalled?: boolean;
  }
}

function isEditableControl(element: Element | null): element is HTMLElement {
  if (!element || !(element instanceof HTMLElement)) {
    return false;
  }
  if (element.isContentEditable) {
    return true;
  }
  const tag = element.tagName;
  if (tag === 'TEXTAREA' || tag === 'SELECT') {
    return true;
  }
  if (tag !== 'INPUT') {
    return false;
  }
  const input = element as HTMLInputElement;
  const type = (input.type || 'text').toLowerCase();
  return !['button', 'submit', 'reset', 'checkbox', 'radio', 'file', 'hidden', 'range', 'color'].includes(type);
}

function resolveEditableTarget(target: EventTarget | null): HTMLElement | null {
  if (!(target instanceof Element)) {
    return null;
  }
  const control = target.closest('input, textarea, select, [contenteditable="true"]');
  return control instanceof HTMLElement && isEditableControl(control) ? control : null;
}

/**
 * Windows WebView2 + flutter_inappwebview toggles Flutter/WebView focus on each click,
 * which makes HTML inputs briefly focus then blur. Re-focus the intended control when
 * that happens right after a pointer down on the same field.
 */
export function installWebViewFocusGuard(): void {
  if (typeof document === 'undefined' || window.__tomatoWebViewFocusGuardInstalled) {
    return;
  }
  window.__tomatoWebViewFocusGuardInstalled = true;

  let lastPointerTarget: EventTarget | null = null;
  let lastPointerAt = 0;

  document.addEventListener(
    'pointerdown',
    (event) => {
      lastPointerTarget = event.target;
      lastPointerAt = Date.now();
    },
    true,
  );

  document.addEventListener(
    'focusout',
    (event) => {
      const target = event.target;
      if (!(target instanceof HTMLElement) || !isEditableControl(target)) {
        return;
      }
      const related = event.relatedTarget;
      if (related instanceof HTMLElement && isEditableControl(related)) {
        return;
      }
      const pointerTarget = resolveEditableTarget(lastPointerTarget);
      if (!pointerTarget || (pointerTarget !== target && !target.contains(pointerTarget))) {
        return;
      }
      if (Date.now() - lastPointerAt > 300) {
        return;
      }

      window.requestAnimationFrame(() => {
        window.requestAnimationFrame(() => {
          if (!target.isConnected || document.activeElement === target) {
            return;
          }
          target.focus({ preventScroll: true });
        });
      });
    },
    true,
  );
}
