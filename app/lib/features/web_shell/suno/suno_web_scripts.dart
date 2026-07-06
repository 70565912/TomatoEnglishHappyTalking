import 'dart:convert';

import 'suno_utilities.dart';

/// Injected Suno WebView JavaScript builders.
class SunoWebScripts {
  SunoWebScripts._();

  static String get inspectScript => r'''
(() => {
  const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
  const visibleText = document.body ? document.body.innerText || '' : '';
  const visible = (el) => {
    const rect = el.getBoundingClientRect?.();
    if (!rect || rect.width <= 0 || rect.height <= 0) return false;
    const style = window.getComputedStyle(el);
    return style.visibility !== 'hidden' &&
      style.display !== 'none' &&
      Number(style.opacity || '1') > 0.01;
  };
  const controlText = Array.from(document.querySelectorAll('button,a,[role="button"],[aria-label],[title]'))
    .filter(visible)
    .map((el) => [
      el.innerText || el.textContent || '',
      el.getAttribute?.('aria-label') || '',
      el.getAttribute?.('title') || '',
      el.getAttribute?.('href') || ''
    ].join(' '))
    .join(' ');
  const text = normalize(`${visibleText} ${controlText}`);
  const creditsMatch = text.match(/Credits\s+remaining[:\s]+(\d+)/i) || text.match(/(\d+)\s+Credits/i);
  const hasCreateSurface = /Create song|Create|Lyrics|Instrumental|Advanced|Style of Music|Song Description/i.test(text);
  const hasLoginPrompt = /sign in|sign-in|signin|log in|log-in|login|join suno for free|join for free|sign up|sign-up|signup|create account|continue with google|continue with discord|continue with apple|get started|登录|登入|注册|註冊|免费加入/i.test(text);
  let host = '';
  let path = '';
  try {
    const url = new URL(location.href);
    host = url.hostname.toLowerCase();
    path = url.pathname.toLowerCase();
  } catch (_) {}
  const isSunoHost = host === 'suno.com' || host === 'www.suno.com';
  const isSunoAuthHost = /(^|\.)suno\.com$/.test(host) && /auth|account|login|clerk/i.test(host);
  const isExternalAuthHost = !isSunoHost && (
    isSunoAuthHost ||
    /accounts\.google\.com|discord(?:app)?\.com|appleid\.apple\.com|clerk|oauth|auth|login|sso|identity/i.test(host)
  );
  const isSunoAuthPath = isSunoHost && /\/(?:login|log-in|signin|sign-in|signup|sign-up|auth|oauth|sso)(?:\/|$)/i.test(path);
  const hasAccountSignal = /Profile menu button|\b\d+\s+Credits\b|Credits remaining[:\s]+\d+|Upgrade to Pro|Pro Plan|Library|Notifications|Workspaces/i.test(text);
  const hasSongDetail = /\/song\//i.test(location.href) && /Lyrics|Comments|Add a Caption|Show full styles|v\d/i.test(text);
  const onSunoCreate = isSunoHost && path === '/create';
  const loginFlow =
    isExternalAuthHost ||
    isSunoAuthPath ||
    (hasLoginPrompt && !hasAccountSignal && !onSunoCreate);
  return JSON.stringify({
    loggedIn: !loginFlow && (hasAccountSignal || hasSongDetail || hasCreateSurface),
    creditsRemaining: creditsMatch ? Number(creditsMatch[1]) : null,
    loginFlow,
    hasLoginPrompt,
    hasAccountSignal,
    currentUrl: location.href,
    textSample: text.slice(0, 800)
  });
})()
''';

  static String get domDiagnosticsScript => r'''
(() => {
  const normalize = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
  const rectOf = (el) => {
    const rect = el.getBoundingClientRect();
    return {
      x: Math.round(rect.x),
      y: Math.round(rect.y),
      width: Math.round(rect.width),
      height: Math.round(rect.height)
    };
  };
  const hitTestVisible = (el) => {
    const rect = el.getBoundingClientRect();
    const points = [
      [rect.left + rect.width / 2, rect.top + rect.height / 2],
      [rect.left + Math.min(rect.width - 1, Math.max(1, rect.width * 0.25)), rect.top + Math.min(rect.height - 1, Math.max(1, rect.height * 0.25))],
      [rect.left + Math.min(rect.width - 1, Math.max(1, rect.width * 0.75)), rect.top + Math.min(rect.height - 1, Math.max(1, rect.height * 0.75))]
    ];
    return points.some(([x, y]) => {
      if (x < 0 || y < 0 || x >= window.innerWidth || y >= window.innerHeight) return false;
      const hit = document.elementFromPoint(x, y);
      return hit === el || el.contains(hit);
    });
  };
  const rendered = (el) => {
    if (!el) return false;
    const rect = el.getBoundingClientRect();
    const style = window.getComputedStyle(el);
    return rect.width > 0 &&
      rect.height > 0 &&
      style.visibility !== 'hidden' &&
      style.display !== 'none' &&
      Number(style.opacity || '1') > 0.01;
  };
  const visible = (el) => {
    return rendered(el) && hitTestVisible(el);
  };
  const attrsText = (el) => normalize([
    el.getAttribute?.('aria-label'),
    el.getAttribute?.('placeholder'),
    el.getAttribute?.('data-testid'),
    el.getAttribute?.('data-test-id'),
    el.getAttribute?.('name'),
    el.getAttribute?.('id'),
    el.getAttribute?.('role'),
    el.getAttribute?.('type')
  ].filter(Boolean).join(' '));
  const inputValue = (el) => normalize(el?.matches?.('input,textarea') ? el.value || '' : '');
  const ownText = (el) => normalize(
    inputValue(el) ||
      el.getAttribute?.('aria-label') ||
      el.innerText ||
      el.textContent ||
      el.getAttribute?.('placeholder') ||
      ''
  );
  const contextText = (el) => {
    const parts = [attrsText(el), ownText(el)];
    let current = el.parentElement;
    for (let i = 0; current && i < 5; i += 1, current = current.parentElement) {
      const text = normalize(current.innerText || current.textContent || '');
      if (text && text.length <= 700) parts.push(text);
      parts.push(attrsText(current));
    }
    return normalize(parts.join(' ')).slice(0, 900);
  };
  const summarize = (el) => ({
    tag: el.tagName.toLowerCase(),
    role: el.getAttribute('role') || '',
    type: el.getAttribute('type') || '',
    id: el.id || '',
    name: el.getAttribute('name') || '',
    className: String(el.className || '').slice(0, 180),
    ariaLabel: el.getAttribute('aria-label') || '',
    placeholder: el.getAttribute('placeholder') || '',
    value: inputValue(el),
    dataTestId: el.getAttribute('data-testid') || el.getAttribute('data-test-id') || '',
    text: ownText(el).slice(0, 220),
    context: contextText(el).slice(0, 420),
    hitTestVisible: hitTestVisible(el),
    editable: Boolean(el.isContentEditable),
    disabled: Boolean(el.disabled) || el.getAttribute('aria-disabled') === 'true',
    rect: rectOf(el)
  });
  const controlSelector = [
    'button',
    '[role="button"]',
    '[role="tab"]',
    'a',
    'label',
    '[aria-label]',
    '[data-testid]',
    '[data-test-id]'
  ].join(',');
  const editorSelector = [
    'textarea',
    'input:not([type])',
    'input[type="text"]',
    'input[type="search"]',
    '[contenteditable="true"]',
    '[role="textbox"]',
    '.ProseMirror',
    '[data-slate-editor="true"]',
    '[data-lexical-editor="true"]'
  ].join(',');
  const controls = Array.from(document.querySelectorAll(controlSelector))
    .filter(visible)
    .filter((el) => /advanced|simple|create|lyrics|style|song|music|歌词|风格/i.test(contextText(el)))
    .slice(0, 80)
    .map(summarize);
  const editors = Array.from(document.querySelectorAll(editorSelector))
    .filter(visible)
    .slice(0, 60)
    .map(summarize);
  return JSON.stringify({
    href: location.href,
    title: document.title,
    bodyTextSample: normalize(document.body?.innerText || '').slice(0, 1600),
    controls,
    editors,
    controlCount: controls.length,
    editorCount: editors.length
  });
})()
''';

  static String get snapshotScript => r'''
(() => {
  const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim();
  const maskSensitiveText = (value) => normalize(value)
    .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, '[email]')
    .replace(/\b(?:Bearer|token|authorization|session|cookie)\s*[:=]\s*[A-Za-z0-9._~+/=-]{12,}/gi, '[secret]')
    .replace(/https:\/\/suno\.com\/@\w+/gi, 'https://suno.com/@user')
    .replace(/@\d{5,}/g, '@user')
    .replace(/\b\d{7,}\b/g, (match) => match.length >= 10 ? '[number]' : match);
  const rectOf = (el) => {
    const rect = el.getBoundingClientRect();
    return {
      x: Math.round(rect.x),
      y: Math.round(rect.y),
      width: Math.round(rect.width),
      height: Math.round(rect.height)
    };
  };
  const hitTestVisible = (el) => {
    const rect = el.getBoundingClientRect();
    const points = [
      [rect.left + rect.width / 2, rect.top + rect.height / 2],
      [rect.left + Math.min(rect.width - 1, Math.max(1, rect.width * 0.25)), rect.top + Math.min(rect.height - 1, Math.max(1, rect.height * 0.25))],
      [rect.left + Math.min(rect.width - 1, Math.max(1, rect.width * 0.75)), rect.top + Math.min(rect.height - 1, Math.max(1, rect.height * 0.75))]
    ];
    return points.some(([x, y]) => {
      if (x < 0 || y < 0 || x >= window.innerWidth || y >= window.innerHeight) return false;
      const hit = document.elementFromPoint(x, y);
      return hit === el || el.contains(hit);
    });
  };
  const rendered = (el) => {
    if (!el) return false;
    const rect = el.getBoundingClientRect();
    const style = window.getComputedStyle(el);
    return rect.width > 0 &&
      rect.height > 0 &&
      style.visibility !== 'hidden' &&
      style.display !== 'none' &&
      Number(style.opacity || '1') > 0.01;
  };
  const visible = (el) => {
    return rendered(el) && hitTestVisible(el);
  };
  const attrsText = (el) => normalize([
    el.getAttribute?.('aria-label'),
    el.getAttribute?.('title'),
    el.getAttribute?.('placeholder'),
    el.getAttribute?.('data-testid'),
    el.getAttribute?.('data-test-id'),
    el.getAttribute?.('name'),
    el.getAttribute?.('id'),
    el.getAttribute?.('role'),
    el.getAttribute?.('type'),
    el.getAttribute?.('download'),
    el.href
  ].filter(Boolean).join(' '));
  const ownText = (el) => normalize([
    el.matches?.('input,textarea') ? el.value || '' : '',
    el.getAttribute?.('aria-label'),
    el.getAttribute?.('title'),
    el.innerText,
    el.textContent,
    el.getAttribute?.('placeholder')
  ].filter(Boolean).join(' '));
  const contextText = (el) => {
    const parts = [attrsText(el), ownText(el)];
    let current = el.parentElement;
    for (let i = 0; current && i < 4; i += 1, current = current.parentElement) {
      const text = normalize(current.innerText || current.textContent || '');
      if (text && text.length <= 900) parts.push(text);
      parts.push(attrsText(current));
    }
    return maskSensitiveText(parts.join(' ')).slice(0, 1200);
  };
  const summarize = (el, index) => ({
    index,
    tag: el.tagName.toLowerCase(),
    role: el.getAttribute('role') || '',
    type: el.getAttribute('type') || '',
    id: maskSensitiveText(el.id || '').slice(0, 120),
    name: maskSensitiveText(el.getAttribute('name') || '').slice(0, 120),
    className: String(el.className || '').slice(0, 220),
    ariaLabel: maskSensitiveText(el.getAttribute('aria-label') || '').slice(0, 220),
    title: maskSensitiveText(el.getAttribute('title') || '').slice(0, 220),
    placeholder: maskSensitiveText(el.getAttribute('placeholder') || '').slice(0, 220),
    dataTestId: el.getAttribute('data-testid') || el.getAttribute('data-test-id') || '',
    href: maskSensitiveText(el.href || '').slice(0, 260),
    download: maskSensitiveText(el.getAttribute('download') || '').slice(0, 180),
    value: el.matches?.('input,textarea') && el.type !== 'password'
      ? maskSensitiveText(el.value || '').slice(0, 260)
      : '',
    text: maskSensitiveText(ownText(el)).slice(0, 360),
    context: contextText(el).slice(0, 700),
    hitTestVisible: hitTestVisible(el),
    editable: Boolean(el.isContentEditable),
    disabled: Boolean(el.disabled) || el.getAttribute('aria-disabled') === 'true',
    rect: rectOf(el)
  });
  const selectors = [
    'a[href]',
    'button',
    '[role="button"]',
    '[role="menuitem"]',
    '[role="tab"]',
    'label',
    'textarea',
    'input',
    '[contenteditable="true"]',
    '[role="textbox"]',
    '.ProseMirror',
    '[data-slate-editor="true"]',
    '[data-lexical-editor="true"]',
    '[aria-label]',
    '[title]',
    '[data-testid]',
    '[data-test-id]',
    'audio[src]',
    'video[src]'
  ].join(',');
  const elements = Array.from(document.querySelectorAll(selectors))
    .filter(visible)
    .slice(0, 450)
    .map(summarize);
  const songLinks = Array.from(document.querySelectorAll('a[href*="/song/"],a[href*="suno.com/song"]'))
    .filter(visible)
    .slice(0, 80)
    .map((el, index) => summarize(el, index));
  const media = Array.from(document.querySelectorAll('audio[src],video[src]'))
    .filter(visible)
    .slice(0, 40)
    .map((el, index) => summarize(el, index));
  const outline = [];
  const walk = (node, depth) => {
    if (!node || outline.length >= 900 || depth > 7 || node.nodeType !== Node.ELEMENT_NODE) return;
    const el = node;
    if (visible(el) || depth <= 2) {
      const text = maskSensitiveText(normalize(el.innerText || el.textContent || '')).slice(0, 160);
      outline.push({
        depth,
        tag: el.tagName.toLowerCase(),
        role: el.getAttribute('role') || '',
        id: maskSensitiveText(el.id || '').slice(0, 80),
        className: String(el.className || '').slice(0, 120),
        ariaLabel: maskSensitiveText(el.getAttribute('aria-label') || '').slice(0, 120),
        dataTestId: el.getAttribute('data-testid') || el.getAttribute('data-test-id') || '',
        text,
        rect: rectOf(el)
      });
    }
    Array.from(el.children || []).forEach((child) => walk(child, depth + 1));
  };
  walk(document.body, 0);

  const clone = document.documentElement.cloneNode(true);
  clone.querySelectorAll('script,style,noscript,template').forEach((el) => el.remove());
  clone.querySelectorAll('*').forEach((el) => {
    Array.from(el.attributes || []).forEach((attr) => {
      const name = attr.name.toLowerCase();
      if (name.startsWith('on') || /cookie|token|session|authorization|password/i.test(name)) {
        el.removeAttribute(attr.name);
      } else if (name === 'value' && /password/i.test(el.getAttribute('type') || '')) {
        el.setAttribute(attr.name, '[password]');
      } else if (attr.value) {
        el.setAttribute(attr.name, maskSensitiveText(attr.value).slice(0, 500));
      }
    });
    if (el.matches?.('input[type="password"]')) {
      el.setAttribute('value', '[password]');
    }
  });
  const sanitizedHtml = maskSensitiveText(clone.outerHTML).slice(0, 350000);
  return JSON.stringify({
    href: maskSensitiveText(location.href),
    rawHref: location.href,
    title: maskSensitiveText(document.title || ''),
    bodyTextSample: maskSensitiveText(document.body?.innerText || '').slice(0, 5000),
    elementCount: elements.length,
    elements,
    songLinks,
    media,
    outline,
    sanitizedHtml
  });
})()
''';

  static String rowsDebugScript({
    required String expectedStylePrompt,
    required String expectedLyrics,
  }) {
    final expectedStyleJson = jsonEncode(expectedStylePrompt.trim());
    final expectedLyricsJson = jsonEncode(expectedLyrics.trim());
    return '''
(() => {
  const expectedStyle = $expectedStyleJson;
  const expectedLyrics = $expectedLyricsJson;
  const normalize = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
  const normalizeLoose = (value) => normalize(value).toLowerCase();
  const expectedTokens = normalize(expectedLyrics)
    .split(/[^A-Za-z0-9\\u4e00-\\u9fff'-]+/g)
    .map((value) => value.trim())
    .filter((value) => value.length >= 4)
    .slice(0, 20);
  const lyricSamples = normalize(expectedLyrics)
    .split(/\\n+/g)
    .map((value) => value.trim())
    .filter((value) => value.length >= 24)
    .slice(0, 4)
    .map((value) => value.slice(0, 90));
  const expectedScore = (text) => {
    const haystack = normalizeLoose(text);
    let score = 0;
    for (const token of expectedTokens) {
      if (haystack.includes(token.toLowerCase())) score += 1;
    }
    for (const sample of lyricSamples) {
      if (haystack.includes(sample.toLowerCase())) score += 6;
    }
    return score;
  };
  const incomplete = /generating|creating|processing|queued|loading|failed|error|retry|生成中|创建中|处理中|排队|失败|重试/i;
  const preview = /preview|demo|sample|clip|snippet|teaser|试听|試聽|预览|預覽|片段|样例|樣例/i;
  const rows = Array.from(document.querySelectorAll('[data-testid="clip-row"],.clip-row,[role="group"][aria-label]'))
    .map((row, index) => {
      const text = normalize(row.innerText || row.textContent || '');
      const title = normalize(row.getAttribute('aria-label') || row.querySelector?.('h1,h2,h3,[role="heading"]')?.innerText || text.split('\\n')[0] || '');
      const anchor = row.querySelector?.('a[href*="/song/"],a[href*="suno.com/song"]');
      const rect = row.getBoundingClientRect();
      return {
        index,
        title,
        href: anchor?.href || '',
        text: text.slice(0, 500),
        expectedScore: expectedScore(title + '\\n' + text),
        incomplete: incomplete.test(text),
        preview: preview.test(text),
        rect: {
          x: Math.round(rect.x),
          y: Math.round(rect.y),
          width: Math.round(rect.width),
          height: Math.round(rect.height)
        }
      };
    });
  const visible = (el) => {
    if (!el) return false;
    const rect = el.getBoundingClientRect();
    const style = window.getComputedStyle(el);
    return rect.width > 0 &&
      rect.height > 0 &&
      style.visibility !== 'hidden' &&
      style.display !== 'none' &&
      Number(style.opacity || '1') > 0.01;
  };
  const textOf = (el) => normalize([
    el.getAttribute?.('aria-label'),
    el.getAttribute?.('title'),
    el.getAttribute?.('download'),
    el.getAttribute?.('data-testid'),
    el.getAttribute?.('data-test-id'),
    el.getAttribute?.('role'),
    el.href,
    el.innerText,
    el.textContent
  ].filter(Boolean).join(' '));
  const contextText = (el) => {
    const parts = [textOf(el)];
    let current = el.parentElement;
    for (let i = 0; current && i < 5; i += 1, current = current.parentElement) {
      const text = normalize(current.innerText || current.textContent || '');
      if (text && text.length <= 900) parts.push(text);
      parts.push(textOf(current));
    }
    return normalize(parts.join(' ')).slice(0, 1200);
  };
  const controlCandidates = Array.from(document.querySelectorAll(
    'a[href],button,[role="button"],[role="menuitem"],label,[aria-label],[title],[data-testid],[data-test-id]'
  ))
    .filter(visible)
    .map((el, index) => {
      const context = contextText(el);
      const score = expectedScore(context);
      const rect = el.getBoundingClientRect();
      return {
        index,
        tag: el.tagName.toLowerCase(),
        role: el.getAttribute('role') || '',
        ariaLabel: el.getAttribute('aria-label') || '',
        dataTestId: el.getAttribute('data-testid') || el.getAttribute('data-test-id') || '',
        text: textOf(el).slice(0, 140),
        expectedScore: score,
        context: context.slice(0, 420),
        rect: {
          x: Math.round(rect.x),
          y: Math.round(rect.y),
          width: Math.round(rect.width),
          height: Math.round(rect.height)
        }
      };
    })
    .filter((item) => item.expectedScore > 0 || /猫头|奇幻儿童|爱丽丝|Download|下载|More/i.test(item.context))
    .slice(0, 80);
  return JSON.stringify({
    expectedStyle,
    expectedTokens,
    lyricSamples,
    rowCount: rows.length,
    rows,
    controlCandidates
  });
})()
''';
  }

  static String fillScript({
    required String lyrics,
    required String stylePrompt,
    required String ignoredStylePrompt,
    required bool allowMagicClick,
    required bool magicAlreadyRequested,
    bool readOnly = false,
  }) {
    final lyricsJson = jsonEncode(lyrics);
    final styleJson = jsonEncode(stylePrompt);
    final ignoredStyleJson = jsonEncode(ignoredStylePrompt);
    final allowMagicClickJson = jsonEncode(allowMagicClick);
    final magicAlreadyRequestedJson = jsonEncode(magicAlreadyRequested);
    final readOnlyJson = jsonEncode(readOnly);
    return '''
(() => {
  try {
  const lyrics = $lyricsJson;
  const style = $styleJson;
  const ignoredStyleRaw = $ignoredStyleJson;
  const allowMagicClick = $allowMagicClickJson;
  const magicAlreadyRequested = $magicAlreadyRequestedJson;
  const readOnly = $readOnlyJson;
  const normalize = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
  const ignoredStyle = normalize(ignoredStyleRaw);
  const isCreatePage = (() => {
    try {
      const url = new URL(window.location.href);
      const host = url.hostname.toLowerCase();
      return (host === 'suno.com' || host === 'www.suno.com') &&
        url.pathname.split('/').filter(Boolean).includes('create');
    } catch (_) {
      return false;
    }
  })();
  if (!isCreatePage) {
    return JSON.stringify({
      ok: false,
      retry: true,
      missing: ['createPage'],
      message: 'Suno 当前不在 Create 页面，Tomato 会重新打开 Create 后再填写。',
      currentUrl: window.location.href
    });
  }
  const rectOf = (el) => {
    const rect = el.getBoundingClientRect();
    return {
      x: Math.round(rect.x),
      y: Math.round(rect.y),
      width: Math.round(rect.width),
      height: Math.round(rect.height)
    };
  };
  const hitTestVisible = (el) => {
    const rect = el.getBoundingClientRect();
    const points = [
      [rect.left + rect.width / 2, rect.top + rect.height / 2],
      [rect.left + Math.min(rect.width - 1, Math.max(1, rect.width * 0.25)), rect.top + Math.min(rect.height - 1, Math.max(1, rect.height * 0.25))],
      [rect.left + Math.min(rect.width - 1, Math.max(1, rect.width * 0.75)), rect.top + Math.min(rect.height - 1, Math.max(1, rect.height * 0.75))]
    ];
    return points.some(([x, y]) => {
      if (x < 0 || y < 0 || x >= window.innerWidth || y >= window.innerHeight) return false;
      const hit = document.elementFromPoint(x, y);
      return hit === el || el.contains(hit);
    });
  };
  const rendered = (el) => {
    if (!el) return false;
    const rect = el.getBoundingClientRect();
    const style = window.getComputedStyle(el);
    return rect.width > 0 &&
      rect.height > 0 &&
      style.visibility !== 'hidden' &&
      style.display !== 'none' &&
      Number(style.opacity || '1') > 0.01;
  };
  const visible = (el) => {
    return rendered(el) && hitTestVisible(el);
  };
  const textOf = (el) => [
    el.getAttribute?.('aria-label'),
    el.getAttribute?.('placeholder'),
    el.getAttribute?.('data-testid'),
    el.getAttribute?.('data-test-id'),
    el.getAttribute?.('role'),
    el.name,
    el.id,
    el.innerText,
    el.textContent,
    el.value
  ].filter(Boolean).join(' ');
  const inputValue = (el) => normalize(el?.matches?.('input,textarea') ? el.value || '' : '');
  const ownText = (el) => normalize(
    inputValue(el) ||
      el.getAttribute?.('aria-label') ||
      el.innerText ||
      el.textContent ||
      el.getAttribute?.('placeholder') ||
      ''
  );
  const contextText = (el) => {
    const parts = [textOf(el)];
    let current = el.parentElement;
    for (let i = 0; current && i < 5; i += 1, current = current.parentElement) {
      const text = normalize(current.innerText || current.textContent || '');
      if (text && text.length <= 800) parts.push(text);
      parts.push(textOf(current));
    }
    return normalize(parts.join(' ')).slice(0, 1200);
  };
  const summarize = (el) => el ? {
    tag: el.tagName.toLowerCase(),
    role: el.getAttribute('role') || '',
    type: el.getAttribute('type') || '',
    id: el.id || '',
    name: el.getAttribute('name') || '',
    className: String(el.className || '').slice(0, 160),
    ariaLabel: el.getAttribute('aria-label') || '',
    placeholder: el.getAttribute('placeholder') || '',
    value: inputValue(el),
    text: ownText(el).slice(0, 160),
    context: contextText(el).slice(0, 260),
    hitTestVisible: hitTestVisible(el),
    editable: Boolean(el.isContentEditable),
    rect: rectOf(el)
  } : null;
  const isDisabled = (el) =>
    Boolean(el?.disabled) || el?.getAttribute?.('aria-disabled') === 'true';
  const clickableAncestor = (el) =>
    el?.closest?.('button,[role="button"],[role="tab"],a,label') || el;
  const clickCookieBanner = () => {
    const cookiePattern = /cookie|cookies|privacy|consent|tracking|隐私|隱私/i;
    const positivePattern = /accept all|accept cookies|accept|agree|i agree|allow all|allow|got it|ok|okay|同意|接受|全部接受|允许全部|允許全部|知道了/i;
    const softPositivePattern = /continue|继续/i;
    const negativePattern = /reject|decline|manage|settings|preferences|customize|learn more|privacy policy|terms|拒绝|拒絕|管理|设置|設定|偏好/i;
    const nearbyCookieText = (el) => {
      const parts = [];
      let current = el;
      for (let i = 0; current && i < 6; i += 1, current = current.parentElement) {
        const attrs = normalize([
          current.getAttribute?.('id'),
          current.getAttribute?.('class'),
          current.getAttribute?.('aria-label'),
          current.getAttribute?.('data-testid'),
          current.getAttribute?.('data-test-id')
        ].filter(Boolean).join(' '));
        if (attrs) parts.push(attrs);
        const text = normalize(current.innerText || current.textContent || '');
        if (text && text.length <= 1200) {
          parts.push(text);
        }
      }
      return normalize(parts.join(' '));
    };
    const candidates = Array.from(document.querySelectorAll(
      'button,[role="button"],a,label'
    ))
      .filter(visible)
      .map((el) => {
        const clickable = clickableAncestor(el);
        const label = normalize(textOf(el));
        const context = nearbyCookieText(clickable);
        const hasCookieContext = cookiePattern.test(context);
        const hasStrongPositive = positivePattern.test(label);
        const hasSoftPositive = softPositivePattern.test(label) && hasCookieContext;
        if ((!hasStrongPositive && !hasSoftPositive) || !hasCookieContext) {
          return null;
        }
        if (isDisabled(clickable)) {
          return null;
        }
        let score = 0;
        if (clickable === el || clickable.contains(el)) score += 2;
        if (clickable.tagName === 'BUTTON') score += 10;
        if (/button/i.test(clickable.getAttribute('role') || '')) score += 6;
        if (/accept all|全部接受|允许全部|允許全部/i.test(label)) score += 10;
        if (/accept cookies|accept|agree|同意|接受/i.test(label)) score += 7;
        if (hasSoftPositive) score += 3;
        if (negativePattern.test(label)) score -= 20;
        if (negativePattern.test(context) && !/accept|agree|同意|接受/i.test(label)) score -= 5;
        score -= Math.max(0, label.length - 40) / 30;
        return { clickable, label, score };
      })
      .filter(Boolean)
      .sort((left, right) => right.score - left.score);
    const match = candidates[0];
    if (!match || match.score < 6) {
      return { clicked: false, target: null };
    }
    match.clickable.scrollIntoView({ block: 'center', inline: 'center' });
    match.clickable.focus?.();
    match.clickable.click();
    return { clicked: true, target: summarize(match.clickable) };
  };
  const isAdvancedActive = () => {
    const candidates = Array.from(document.querySelectorAll(
      'button,[role="button"],[role="tab"],a,label,[aria-label],[data-testid],[data-test-id]'
    )).filter(visible);
    return candidates.some((el) => {
      const label = normalize(textOf(el));
      if (!/\\badvanced\\b/i.test(label)) return false;
      const className = String(el.className || '');
      return el.getAttribute('aria-selected') === 'true' ||
        el.getAttribute('aria-pressed') === 'true' ||
        el.getAttribute('data-state') === 'active' ||
        /active|selected|checked/i.test(className);
    });
  };
  const clickAdvanced = () => {
    if (isAdvancedActive()) {
      return { clicked: false, alreadyActive: true, target: null };
    }
    const candidates = Array.from(document.querySelectorAll(
      'button,[role="button"],[role="tab"],a,label,span,div,[aria-label],[data-testid],[data-test-id]'
    ))
      .filter(visible)
      .map((el) => {
        const label = normalize(textOf(el));
        const exact = label.toLowerCase() === 'advanced';
        const shortMatch = /\\badvanced\\b/i.test(label) && label.length <= 120;
        if (!exact && !shortMatch) return null;
        const clickable = clickableAncestor(el);
        const role = clickable.getAttribute('role') || '';
        let score = 0;
        if (exact) score += 20;
        if (/button|tab/i.test(role) || clickable.tagName === 'BUTTON') score += 8;
        if (clickable.getAttribute('aria-selected') === 'false') score += 3;
        if (!isDisabled(clickable)) score += 2;
        score -= Math.max(0, label.length - 8) / 20;
        return { el, clickable, label, score };
      })
      .filter(Boolean)
      .sort((left, right) => right.score - left.score);
    const match = candidates[0];
    if (!match || isDisabled(match.clickable)) {
      return { clicked: false, alreadyActive: false, target: null };
    }
    match.clickable.scrollIntoView({ block: 'center', inline: 'center' });
    match.clickable.focus?.();
    match.clickable.click();
    return { clicked: true, alreadyActive: false, target: summarize(match.clickable) };
  };
  const cookieResult = clickCookieBanner();
  const advancedResult = clickAdvanced();
  if (cookieResult.clicked || advancedResult.clicked) {
    return JSON.stringify({
      ok: false,
      retry: true,
      message: cookieResult.clicked
        ? 'Tomato 已处理 Suno Cookies 提示，正在等待页面刷新后继续填写。'
        : 'Tomato 已尝试切换 Suno Advanced，正在等待页面刷新后继续填写。',
      cookieAccepted: cookieResult.clicked,
      cookieTarget: cookieResult.target,
      advancedClicked: advancedResult.clicked,
      advancedAlreadyActive: advancedResult.alreadyActive,
      advancedActive: isAdvancedActive(),
      advancedTarget: advancedResult.target
    });
  }
  const editorSelector = [
    'textarea',
    'input:not([type])',
    'input[type="text"]',
    'input[type="search"]',
    '[contenteditable="true"]',
    '[role="textbox"]',
    '.ProseMirror',
    '[data-slate-editor="true"]',
    '[data-lexical-editor="true"]'
  ].join(',');
  const utilityMeta = (el) => normalize([
    el.getAttribute?.('aria-label'),
    el.getAttribute?.('placeholder'),
    el.getAttribute?.('name'),
    el.getAttribute?.('id'),
    el.getAttribute?.('data-testid'),
    el.getAttribute?.('data-test-id'),
    el.getAttribute?.('type')
  ].filter(Boolean).join(' '));
  const isUtilityEditor = (el, context) => {
    const meta = utilityMeta(el);
    if (/\\bsearch\\b|current page|song title|enhance lyrics|搜索|页码|标题|增强歌词/i.test(meta)) {
      return true;
    }
    return el.matches?.('input[type="search"]') === true;
  };
  const looksLikeSunoGeneratedStyle = (value) => {
    const text = normalize(value);
    if (text.length < 8 || text.length > 1000) return false;
    if (/style of music|song description|describe|enter|type|optional|风格描述|曲风描述|输入|填写/i.test(text)) {
      return false;
    }
    return /[,，]|\\bbpm\\b|vocals?|guitar|drum|bass|piano|synth|folk|pop|rock|rap|house|ambient|trance|beats?|minor|major|music|melody|rhythm|voice|vocal|和声|鼓|吉他|钢琴|贝斯|旋律|节奏|人声|民谣|流行|摇滚|说唱|电子/i.test(text);
  };
  const allFields = Array.from(document.querySelectorAll(editorSelector))
    .filter(rendered)
    .filter((el) => !isDisabled(el))
    .map((el) => {
      const context = contextText(el);
      const rect = el.getBoundingClientRect();
      return { el, context, rect };
    });
  const formFields = allFields.filter((item) => !isUtilityEditor(item.el, item.context));
  const fieldByExplicitMeta = (pattern, reject = null) => {
    const match = formFields.find((item) => {
      const meta = normalize([
        utilityMeta(item.el),
        item.el.getAttribute?.('aria-label'),
        item.el.getAttribute?.('placeholder')
      ].filter(Boolean).join(' '));
      return pattern.test(meta) && !(reject && reject.test(meta));
    });
    return match?.el || null;
  };
  const editorIn = (root, reject = null) => {
    if (!root) return null;
    const editors = Array.from(root.querySelectorAll(editorSelector))
      .filter(rendered)
      .filter((el) => !isDisabled(el))
      .filter((el) => !isUtilityEditor(el, contextText(el)))
      .filter((el) => !(reject && reject.test(normalize([utilityMeta(el), contextText(el)].join(' ')))))
      .sort((left, right) => left.getBoundingClientRect().top - right.getBoundingClientRect().top);
    return editors[0] || null;
  };
  const directTextOf = (el) => normalize(
    Array.from(el.childNodes || [])
      .filter((node) => node.nodeType === Node.TEXT_NODE)
      .map((node) => node.textContent || '')
      .join(' ')
  );
  const headingTextOf = (el) => normalize([
    directTextOf(el),
    Array.from(el.children || [])
      .slice(0, 4)
      .map((child) => child.matches?.('h1,h2,h3,h4,button,[role="button"],summary,[aria-label]')
        ? textOf(child)
        : directTextOf(child))
      .join(' ')
  ].join(' '));
  const panelByTestId = (pattern, reject = null) => {
    const panels = Array.from(document.querySelectorAll('[data-testid],[data-test-id]'))
      .filter(rendered)
      .filter((el) => {
        const meta = normalize([
          el.getAttribute?.('data-testid'),
          el.getAttribute?.('data-test-id'),
          el.getAttribute?.('aria-label')
        ].filter(Boolean).join(' '));
        return pattern.test(meta) && !(reject && reject.test(meta));
      })
      .filter((el) => editorIn(el, reject))
      .sort((left, right) => left.getBoundingClientRect().top - right.getBoundingClientRect().top);
    return panels[0] || null;
  };
  const panelByTitle = (titlePattern, rejectTitlePattern = null) => {
    const panels = Array.from(document.querySelectorAll('section,article,[role="group"],div'))
      .filter(rendered)
      .filter((el) => editorIn(el, rejectTitlePattern))
      .filter((el) => {
        const rect = el.getBoundingClientRect();
        if (rect.width < 160 || rect.height < 36) return false;
        const title = headingTextOf(el).slice(0, 220);
        return titlePattern.test(title) &&
          !(rejectTitlePattern && rejectTitlePattern.test(title));
      })
      .sort((left, right) => left.getBoundingClientRect().top - right.getBoundingClientRect().top);
    return panels[0] || null;
  };
  const styleWrapperSelectorForFields =
    '[data-testid="create-form-styles-wrapper"],[data-test-id="create-form-styles-wrapper"]';
  const lyricsPanel =
    panelByTestId(/lyrics?|歌词|歌詞/i, /styles?|风格|曲风/i) ||
    panelByTitle(/\\blyrics?\\b|歌词|歌詞/i, /\\bstyles?\\b|风格|曲风/i);
  const stylePanelForFields =
    document.querySelector(styleWrapperSelectorForFields) ||
    panelByTestId(/styles?|style|genre|music|风格|曲风/i, /lyrics?|歌词|歌詞/i) ||
    panelByTitle(/\\bstyles?\\b|style prompt|music style|genre|风格|曲风/i, /\\blyrics?\\b|歌词|歌詞/i);
  let lyricsField =
    editorIn(lyricsPanel, /styles?|style prompt|music style|genre|风格|曲风/i) ||
    fieldByExplicitMeta(/lyrics?|歌词|歌詞/i, /styles?|风格|曲风/i);
  let styleField =
    editorIn(stylePanelForFields, /lyrics?|歌词|歌詞/i) ||
    fieldByExplicitMeta(/styles?|style prompt|music style|genre|风格|曲风/i, /lyrics?|歌词|歌詞/i);
  if (styleField === lyricsField) {
    styleField = null;
  }
  const fillTarget = (el) => {
    if (!el) return null;
    if (el.matches?.('input,textarea') || el.isContentEditable) return el;
    return el.querySelector?.('textarea,input,[contenteditable="true"],[role="textbox"],.ProseMirror') || el;
  };
  const dispatchInput = (el, value) => {
    try {
      el.dispatchEvent(new InputEvent('beforeinput', {
        bubbles: true,
        cancelable: true,
        inputType: 'insertText',
        data: value
      }));
    } catch (_) {}
    try {
      el.dispatchEvent(new InputEvent('input', {
        bubbles: true,
        inputType: 'insertText',
        data: value
      }));
    } catch (_) {
      el.dispatchEvent(new Event('input', { bubbles: true }));
    }
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
    el.blur?.();
  };
  const setValue = (rawEl, value) => {
    const el = fillTarget(rawEl);
    if (!el) return false;
    const currentValue = el.matches?.('input,textarea')
      ? normalize(el.value || '')
      : normalize(el.innerText || el.textContent || el.value || '');
    if (currentValue === normalize(value)) return true;
    el.scrollIntoView({ block: 'center', inline: 'center' });
    el.focus?.();
    if (el.matches?.('input,textarea')) {
      const nativePrototype = el.tagName === 'TEXTAREA'
        ? HTMLTextAreaElement.prototype
        : HTMLInputElement.prototype;
      const nativeSetter = Object.getOwnPropertyDescriptor(nativePrototype, 'value')?.set;
      const ownSetter = Object.getOwnPropertyDescriptor(el, 'value')?.set;
      const setNativeValue = (nextValue) => {
        if (ownSetter && ownSetter !== nativeSetter) {
          ownSetter.call(el, nextValue);
        } else if (nativeSetter) {
          nativeSetter.call(el, nextValue);
        } else {
          el.value = nextValue;
        }
      };
      try {
        el.setSelectionRange?.(0, (el.value || '').length);
      } catch (_) {}
      try {
        el.select?.();
      } catch (_) {}
      try {
        el._valueTracker?.setValue('');
      } catch (_) {}
      let inserted = false;
      try {
        if (typeof el.setRangeText === 'function') {
          el.setRangeText(value, 0, (el.value || '').length, 'end');
          inserted = normalize(el.value || '') === normalize(value);
        }
      } catch (_) {
        inserted = false;
      }
      if (!inserted) {
        try {
          inserted = document.execCommand && document.execCommand('insertText', false, value);
        } catch (_) {
          inserted = false;
        }
      }
      if (!inserted || normalize(el.value || '') !== normalize(value)) {
        setNativeValue(value);
      }
      dispatchInput(el, value);
      try {
        el.setSelectionRange?.((el.value || '').length, (el.value || '').length);
      } catch (_) {}
      return true;
    }
    if (el.isContentEditable || el.getAttribute?.('role') === 'textbox') {
      const selection = window.getSelection?.();
      const range = document.createRange();
      try {
        range.selectNodeContents(el);
        selection?.removeAllRanges();
        selection?.addRange(range);
      } catch (_) {}
      let inserted = false;
      try {
        inserted = document.execCommand && document.execCommand('insertText', false, value);
      } catch (_) {
        inserted = false;
      }
      if (!inserted) {
        el.textContent = value;
      }
      dispatchInput(el, value);
      return true;
    }
    return false;
  };
  const fields = allFields.map((item) => ({
    field: summarize(item.el)
  })).slice(0, 20);
  const getValue = (rawEl) => {
    const el = fillTarget(rawEl);
    if (!el) return '';
    if (el.matches?.('input,textarea')) return normalize(el.value || '');
    return normalize(el.innerText || el.textContent || el.value || '');
  };
  const textIsMuted = (el) => {
    if (!el) return true;
    const color = window.getComputedStyle(el).color || '';
    const match = color.match(/rgba?\\(([^)]+)\\)/i);
    if (!match) return false;
    const parts = match[1]
      .split(',')
      .map((part) => Number(String(part).trim()))
      .filter((part) => Number.isFinite(part));
    if (parts.length < 3) return false;
    const alpha = parts.length >= 4 ? parts[3] : 1;
    const luma = parts[0] * 0.299 + parts[1] * 0.587 + parts[2] * 0.114;
    return alpha < 0.65 || luma < 150;
  };
  const isStyleToolText = (el) =>
    Boolean(el?.closest?.('button,[role="button"],a,label'));
  const stylePanelSelector =
    '[data-testid="create-form-styles-wrapper"],[data-test-id="create-form-styles-wrapper"]';
  const findStylePanel = (anchor = null) => {
    const direct = anchor?.closest?.(stylePanelSelector);
    if (rendered(direct)) return direct;
    const panels = Array.from(document.querySelectorAll(stylePanelSelector))
      .filter(rendered);
    if (panels.length > 0) {
      const lyricsRect = lyricsField?.getBoundingClientRect?.();
      if (lyricsRect) {
        const belowLyrics = panels
          .filter((panel) => panel.getBoundingClientRect().top > lyricsRect.top)
          .sort((left, right) =>
            left.getBoundingClientRect().top - right.getBoundingClientRect().top
          );
        if (belowLyrics.length > 0) return belowLyrics[0];
      }
      return panels[0];
    }
    const styleCards = Array.from(document.querySelectorAll('section,article,div,[role="group"]'))
      .filter(rendered)
      .filter((el) => {
        const rect = el.getBoundingClientRect();
        const ownText = normalize(textOf(el));
        if (!/^\\s*styles?\\b/i.test(ownText)) return false;
        if (rect.height < 44 || rect.width < 180) return false;
        return /styles?|personalize style prompt|magic|wand|风格|曲风/i.test(
          normalize(ownText + ' ' + contextText(el))
        );
      })
      .sort((left, right) =>
        left.getBoundingClientRect().top - right.getBoundingClientRect().top
      );
    return styleCards[0] || null;
  };
  const stylePanelTextValue = (panel) => {
    if (!panel) return '';
    const usableLine = (value) => {
      const line = normalize(value);
      if (!line) return '';
      if (/^styles?\$/i.test(line)) return '';
      if (/^\\d+\\s*\\/\\s*\\d+\$/.test(line)) return '';
      if (/personalize style prompt|refresh recommended styles|recommended styles|add style|no saved styles|save prompt|undo changes|clear styles|clear all|lyrics?|create song|download|delete|remove|upload|advanced|simple|sign in|log in|credits|刷新推荐|推荐风格|添加风格|保存提示|撤销|清空|歌词|创建|下载|删除|上传|登录/i.test(line)) {
        return '';
      }
      const cleaned = line.replace(/\\s+\\d+\\s*\\/\\s*\\d+\$/, '').trim();
      return looksLikeSunoGeneratedStyle(cleaned) ? cleaned : '';
    };
    const walker = document.createTreeWalker(panel, NodeFilter.SHOW_TEXT);
    let node = walker.nextNode();
    while (node) {
      const parent = node.parentElement;
      if (rendered(parent) && !isStyleToolText(parent) && !textIsMuted(parent)) {
        const lines = String(node.textContent || '').split(/\\n+/);
        for (const line of lines) {
          const candidate = usableLine(line);
          if (candidate) return candidate;
        }
      }
      node = walker.nextNode();
    }
    return '';
  };
  const findStyleContainer = (anchor = null) => {
    const panel = findStylePanel(anchor);
    let node = panel || anchor;
    while (node && node !== document.body && node !== document.documentElement) {
      if (rendered(node)) {
        const text = normalize(node.innerText || node.textContent || '');
        const hasStyleTitle = /\\bstyles?\\b|风格|曲风/i.test(text);
        const hasLyricsTitle = /\\blyrics?\\b|歌词|歌詞/i.test(text);
        const hasControls = node.querySelectorAll?.('button,[role="button"],a,label').length > 0;
        if (hasStyleTitle && !hasLyricsTitle && hasControls) {
          return node;
        }
      }
      node = node.parentElement;
    }
    return panel || anchor;
  };
  const getStyleValue = (rawEl) => {
    const el = fillTarget(rawEl);
    if (el) {
      const direct = el.matches?.('input,textarea')
        ? normalize(el.value || '')
        : normalize(el.innerText || el.textContent || el.value || '');
      if (el.matches?.('input,textarea')) {
        return looksLikeSunoGeneratedStyle(direct) ? direct : '';
      }
      if (looksLikeSunoGeneratedStyle(direct) &&
          (el.matches?.('input,textarea') || !textIsMuted(el))) {
        return direct;
      }
    }
    return stylePanelTextValue(findStylePanel(rawEl));
  };
  const getPlaceholder = (rawEl) => {
    const el = fillTarget(rawEl);
    return normalize(
      el?.getAttribute?.('placeholder') ||
        rawEl?.getAttribute?.('placeholder') ||
        ''
    );
  };
  const expectedLyrics = normalize(lyrics);
  const bodyText = normalize(document.body?.innerText || '');
  const presenceText = (value) => normalize(value)
    .toLowerCase()
    .replace(/([a-z0-9])[’'`´](?=[a-z0-9])/gi, '\$1')
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
  const expectedLyricTokens = presenceText(expectedLyrics)
    .split(' ')
    .filter((token) => token.length > 1);
  const lyricProbe = expectedLyricTokens.slice(0, 14).join(' ');
  const containsLyricProbe = (value) =>
    lyricProbe.length >= 24 && presenceText(value).includes(lyricProbe);
  const stylePanel = findStylePanel(styleField);
  const styleSurface = styleField || stylePanel;
  const styleLooksLikeLyrics = styleSurface ? containsLyricProbe(getStyleValue(styleSurface)) : false;
  const lyricsValueAlreadyPresent = Array.from(document.querySelectorAll(editorSelector))
    .some((el) => {
      const labelText = normalize([textOf(el), contextText(el)].join(' '));
      if (!/lyrics?|歌词|歌詞/i.test(labelText)) return false;
      return containsLyricProbe(inputValue(el) || textOf(el) || el.innerText || el.textContent || '');
    });
  const lyricsAlreadyPresent =
    lyricsValueAlreadyPresent || (containsLyricProbe(bodyText) && !styleLooksLikeLyrics);
  if (readOnly) {
    return JSON.stringify({
      ok: Boolean((lyricsField || lyricsAlreadyPresent) && styleSurface),
      retry: false,
      stylePrompt: styleSurface ? getStyleValue(styleSurface) : '',
      lyricsPrompt: lyricsField ? getValue(lyricsField) : '',
      stylePlaceholder: styleField ? getPlaceholder(styleField) : '',
      lyricsAlreadyPresent,
      fieldCount: allFields.length,
      lyricsField: summarize(lyricsField),
      styleField: summarize(styleField),
      fields,
      textSample: normalize(document.body?.innerText || '').slice(0, 1000)
    });
  }
  const isRejectedStyleMagicLabel = (label, context) => {
    const labelText = normalize(label);
    const text = normalize(String(label || '') + ' ' + String(context || ''));
    if (/view saved style prompts?|saved style prompts?|refresh recommended styles|recommended styles|add style|no saved styles|save prompt|undo changes|clear styles|clear all|more options|additional options|lyrics?|create song|download|delete|remove|upload|advanced|simple|sign in|log in|credits|instrumental|extend|cover|\\bpersona\\b|查看已保存|已保存风格|刷新推荐|推荐风格|添加风格|保存提示|撤销|清空|更多选项|更多设置|歌词|创建|下载|删除|上传|登录/i.test(labelText)) {
      return true;
    }
    return /view saved style prompts?|saved style prompts?|refresh recommended styles|add style|no saved styles|save prompt|undo changes|clear styles|clear all|查看已保存|已保存风格|刷新推荐|添加风格|保存提示|撤销|清空/i.test(text);
  };
  const hasVisibleStyleMagic = (panel) => {
    const root = findStyleContainer(panel);
    if (!root) return false;
    return Array.from(root.querySelectorAll('button,[role="button"],a,label,[aria-label],[data-testid],[data-test-id]'))
      .filter(rendered)
      .some((el) => {
        const clickable = clickableAncestor(el);
        if (!clickable || isDisabled(clickable)) return false;
        const label = normalize(textOf(el));
        const context = contextText(el);
        const hasIcon = Boolean(clickable.querySelector?.('svg,img,[class*="icon"],[class*="magic"],[class*="wand"],[class*="spark"]'));
        const classText = normalize(String(clickable.className || '') + ' ' + String(el.className || ''));
        const styleText = normalize([
          clickable.getAttribute?.('style'),
          el.getAttribute?.('style')
        ].filter(Boolean).join(' '));
        const hasStyleMagicColor =
          /accent-blue|bg-accent-blue|blue|primary-blue/i.test(classText) ||
          /rgb\\(47,\\s*127,\\s*252\\)|rgb\\(59,\\s*130,\\s*246\\)|rgb\\(37,\\s*99,\\s*235\\)|#2f7ffc|#3b82f6|#2563eb|blue/i.test(styleText);
        const positive = /personalize style prompt|magic wand|magic|wand|spark|auto.*style|style.*auto|generate.*style|style.*generate|inspire|style prompt|风格.*魔法|魔法.*风格|自动.*风格|风格.*自动|生成.*风格|风格.*生成|曲风.*生成|生成.*曲风/i;
        if (isRejectedStyleMagicLabel(label, context)) return false;
        if (/^styles?\$/i.test(label) && !hasStyleMagicColor) return false;
        if (/chevron|accordion|collapse|expand/i.test(classText) && !hasStyleMagicColor) return false;
        return positive.test(label) || positive.test(context) || hasStyleMagicColor || (hasIcon && hasStyleMagicColor);
      });
  };
  const findStyleExpansionButton = () => {
    const hasVisibleStylesPanel = Boolean(
      styleField ||
      hasVisibleStyleMagic(stylePanel)
    );
    if (hasVisibleStylesPanel) return null;
    const lyricsRect = lyricsField?.getBoundingClientRect?.();
    const styleRect = styleField?.getBoundingClientRect?.();
    const candidates = Array.from(document.querySelectorAll(
      'button,[role="button"],summary,a,label,[aria-expanded],[data-state],[tabindex]'
    ))
      .filter(rendered)
      .map((el) => {
        const clickable = clickableAncestor(el);
        if (!clickable || isDisabled(clickable)) return null;
        const label = normalize(textOf(el));
        const ownMeta = normalize([
          label,
          clickable.getAttribute?.('aria-label'),
          el.getAttribute?.('aria-label'),
          clickable.getAttribute?.('data-testid'),
          el.getAttribute?.('data-testid'),
          clickable.getAttribute?.('data-test-id'),
          el.getAttribute?.('data-test-id')
        ].filter(Boolean).join(' '));
        const className = normalize(String(clickable.className || '') + ' ' + String(el.className || ''));
        const styleText = /\\bstyles?\\b|style of music|style prompt|music style|genre|风格|曲风/i.test(ownMeta);
        const moreOptionsText = /more options|additional options|options|更多选项|更多设置/i.test(ownMeta);
        if (!styleText || moreOptionsText) return null;
        if (/advanced|simple|create song|lyrics?|download|login|sign in|credits|refresh recommended|add style|save prompt|clear all|instrumental|terms|policies|home|explore|studio|library|notifications|labs|more|创建|歌词|下载|登录|推荐风格|添加风格/i.test(ownMeta)) {
          return null;
        }
        const rect = clickable.getBoundingClientRect();
        const nearbyText = contextText(clickable);
        const expandedContentVisible = Boolean(
          styleField ||
          hasVisibleStyleMagic(stylePanel) ||
          /\\b\\d+\\s*\\/\\s*\\d+\\b|personalize style prompt|undo changes|save prompt|clear styles|refresh recommended styles|add style:|create-form-styles-wrapper|自动风格|生成风格|保存提示|清空风格/i.test(nearbyText)
        );
        const expandedAttr = normalize(
          clickable.getAttribute?.('aria-expanded') ||
          el.getAttribute?.('aria-expanded') ||
          ''
        ).toLowerCase();
        const stateText = normalize([
          clickable.getAttribute?.('data-state'),
          el.getAttribute?.('data-state'),
          clickable.getAttribute?.('aria-label'),
          el.getAttribute?.('aria-label'),
          className
        ].filter(Boolean).join(' '));
        const inferredCollapsed =
          !expandedContentVisible &&
          rect.height <= 80 &&
          /\\bstyles?\\b|style prompt|music style|genre|风格|曲风/i.test(
            ownMeta
          );
        const explicitCollapsed =
          expandedAttr === 'false' ||
          /closed|collapsed|折叠|收起/i.test(stateText) ||
          inferredCollapsed;
        if (!explicitCollapsed) return null;
        if (lyricsRect &&
            rect.top <= lyricsRect.top + 20 &&
            !styleField &&
            !styleRect) return null;
        return { clickable, label, context: ownMeta, top: rect.top };
      })
      .filter(Boolean)
      .sort((left, right) => left.top - right.top);
    const match = candidates[0];
    return match || null;
  };
  const expandStylesIfNeeded = () => {
    const expansion = findStyleExpansionButton();
    if (!expansion) return null;
    const rect = expansion.clickable.getBoundingClientRect();
    const outsideViewport =
      rect.top < 0 ||
      rect.bottom > window.innerHeight ||
      rect.left < 0 ||
      rect.right > window.innerWidth;
    if (outsideViewport) {
      expansion.clickable.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    }
    expansion.clickable.focus?.();
    expansion.clickable.click();
    const scrollStylesIntoView = () => {
      try {
        expansion.clickable.scrollIntoView({ block: 'start', inline: 'nearest' });
      } catch (_) {}
    };
    try {
      window.setTimeout(scrollStylesIntoView, 120);
    } catch (_) {
      scrollStylesIntoView();
    }
    return JSON.stringify({
      ok: false,
      retry: true,
      magicClicked: false,
      styleExpanded: true,
      message: 'Tomato 已展开 Suno Styles，正在等待魔法棒出现。',
      stylePrompt: '',
      styleSource: 'sunoMagic',
      styleExpandTarget: summarize(expansion.clickable),
      fieldCount: allFields.length,
      lyricsField: summarize(lyricsField),
      styleField: summarize(styleField),
      stylePlaceholder,
      lyricsAlreadyPresent,
      fields,
      textSample: normalize(document.body?.innerText || '').slice(0, 1000)
    });
  };
  const scrollParentFor = (element) => {
    let node = element?.parentElement;
    while (node && node !== document.body && node !== document.documentElement) {
      const computed = window.getComputedStyle(node);
      const overflowText = String(computed.overflowY || '') +
        ' ' +
        String(computed.overflow || '');
      if (/(auto|scroll|overlay)/i.test(overflowText) &&
          node.scrollHeight > node.clientHeight + 12) {
        return node;
      }
      node = node.parentElement;
    }
    return document.scrollingElement || document.documentElement;
  };
  const scrollStylesPanelIntoView = (reason) => {
    const target = findStyleContainer(styleSurface || stylePanel) ||
      styleSurface ||
      stylePanel;
    if (!target) return null;
    const before = target.getBoundingClientRect();
    const parent = scrollParentFor(target);
    const scrollDown = () => {
      try {
        target.scrollIntoView({ block: 'center', inline: 'nearest' });
      } catch (_) {}
      try {
        parent?.scrollBy?.({ top: 220, left: 0, behavior: 'auto' });
      } catch (_) {
        try {
          if (parent) parent.scrollTop += 220;
        } catch (_) {}
      }
    };
    scrollDown();
    try {
      window.setTimeout(scrollDown, 120);
    } catch (_) {}
    return JSON.stringify({
      ok: false,
      retry: true,
      magicClicked: false,
      styleScrolled: true,
      message: 'Tomato 已滚动到 Suno Styles 工具栏，正在等待蓝色魔法棒出现。',
      stylePrompt: '',
      styleSource: 'sunoMagic',
      styleScrollReason: reason,
      styleScrollTarget: summarize(target),
      styleScrollParent: summarize(parent),
      styleScrollBefore: {
        top: before.top,
        bottom: before.bottom,
        height: before.height
      },
      fieldCount: allFields.length,
      lyricsField: summarize(lyricsField),
      styleField: summarize(styleField),
      stylePlaceholder,
      lyricsAlreadyPresent,
      fields,
      textSample: normalize(document.body?.innerText || '').slice(0, 1000)
    });
  };
  const findStyleMagicButton = () => {
    const styleAnchor = styleField || stylePanel;
    if (!styleAnchor) return null;
    const styleRect = styleAnchor.getBoundingClientRect();
    const searchRoot = findStyleContainer(styleAnchor);
    const roots = searchRoot ? [searchRoot] : [document];
    const candidates = roots
      .flatMap((root) => Array.from(root.querySelectorAll(
        'button,[role="button"],a,label,[aria-label],[data-testid],[data-test-id]'
      )))
      .filter(rendered)
      .map((el) => {
        const clickable = clickableAncestor(el);
        if (!clickable || isDisabled(clickable)) return null;
        const label = normalize(textOf(el));
        const context = contextText(el);
        const rect = clickable.getBoundingClientRect();
        const nearStyle =
          rect.bottom >= styleRect.top - 180 &&
          rect.top <= styleRect.bottom + 180 &&
          rect.right >= styleRect.left - 260 &&
          rect.left <= styleRect.right + 260;
        const hasIcon = Boolean(clickable.querySelector?.('svg,img,[class*="icon"],[class*="magic"],[class*="wand"],[class*="spark"]'));
        const classText = normalize(String(clickable.className || '') + ' ' + String(el.className || ''));
        const styleText = normalize([
          clickable.getAttribute?.('style'),
          el.getAttribute?.('style')
        ].filter(Boolean).join(' '));
        const hasStyleMagicColor =
          /accent-blue|bg-accent-blue|blue|primary-blue/i.test(classText) ||
          /rgb\\(47,\\s*127,\\s*252\\)|rgb\\(59,\\s*130,\\s*246\\)|rgb\\(37,\\s*99,\\s*235\\)|#2f7ffc|#3b82f6|#2563eb|blue/i.test(styleText);
        const positive = /personalize style prompt|magic wand|magic|wand|spark|auto.*style|style.*auto|generate.*style|style.*generate|inspire|style prompt|风格.*魔法|魔法.*风格|自动.*风格|风格.*自动|生成.*风格|风格.*生成|曲风.*生成|生成.*曲风/i;
        const strongMagic = /personalize style prompt|magic wand|magic|wand|spark|魔法|自动.*风格|生成.*风格|曲风.*生成|inspire/i;
        if (isRejectedStyleMagicLabel(label, context)) return null;
        if (!searchRoot && !nearStyle) return null;
        if (/^styles?\$/i.test(label) && !hasStyleMagicColor) return null;
        if (/chevron|accordion|collapse|expand/i.test(classText) && !hasStyleMagicColor) return null;
        if (!positive.test(label) && !positive.test(context) && !hasStyleMagicColor) {
          return null;
        }
        const namedMagic = strongMagic.test(label) || positive.test(label);
        const blueMagic =
          hasStyleMagicColor &&
          (hasIcon || !label || positive.test(context) || strongMagic.test(context));
        return {
          clickable,
          label,
          context,
          namedMagic,
          blueMagic,
          top: rect.top,
          left: rect.left
        };
      })
      .filter(Boolean)
      .sort((left, right) => (left.top - right.top) || (left.left - right.left));
    return candidates.find((item) => item.namedMagic) ||
      candidates.find((item) => item.blueMagic) ||
      candidates[0] ||
      null;
  };
  const triggerStyleMagicButton = (magic) => {
    const target = magic?.clickable;
    if (!target) {
      return {
        clicked: false,
        waiting: false,
        method: '',
        error: 'missingTarget'
      };
    }
    let result = {};
    try {
      target.scrollIntoView?.({ block: 'nearest', inline: 'nearest' });
    } catch (_) {}
    try {
      target.focus?.();
    } catch (_) {}
    try {
      target.click();
      result = {
        ok: true
      };
    } catch (error) {
      result = {
        ok: false,
        error: String(error && error.message ? error.message : error)
      };
    }
    return {
      clicked: result.ok !== false,
      waiting: false,
      method: 'nativeClick',
      result
    };
  };
  const missing = [];
  let styleValue = styleSurface ? getStyleValue(styleSurface) : '';
  let stylePlaceholder = styleField ? getPlaceholder(styleField) : '';
  let styleFilled = false;
  let styleSource = '';
  let magicClicked = false;
  let magicTarget = null;
  let magicTrigger = null;
  if (!lyricsField && !lyricsAlreadyPresent) {
    missing.push('lyrics');
  } else if (!expectedLyrics) {
    missing.push('lyricsText');
  } else if (lyricsField && getValue(lyricsField) !== expectedLyrics) {
    const lyricsFilled = setValue(lyricsField, lyrics);
    const lyricsValue = getValue(lyricsField);
    if (!lyricsFilled || lyricsValue !== expectedLyrics) {
      missing.push('lyricsFill');
    } else {
      return JSON.stringify({
        ok: false,
        retry: true,
        magicClicked: false,
        message: 'Tomato 已把歌词写入 Suno Lyrics，正在确认页面渲染。',
        stylePrompt: '',
        styleSource: '',
        fieldCount: allFields.length,
        lyricsField: summarize(lyricsField),
        styleField: summarize(styleField),
        fields,
        textSample: normalize(document.body?.innerText || '').slice(0, 1000)
      });
    }
  }
  if (missing.length > 0) {
    return JSON.stringify({
      ok: false,
      missing,
      retry: false,
      magicClicked: false,
      message: 'Suno Lyrics 尚未确认写入，暂不处理 Styles。',
      stylePrompt: '',
      styleSource: '',
      fieldCount: allFields.length,
      lyricsField: summarize(lyricsField),
      styleField: summarize(styleField),
      stylePlaceholder,
      lyricsAlreadyPresent,
      fields,
      textSample: normalize(document.body?.innerText || '').slice(0, 1000)
    });
  }
  if (!styleSurface) {
    const expanded = expandStylesIfNeeded();
    if (expanded) {
      return expanded;
    }
    const scrolled = scrollStylesPanelIntoView('missingStyleSurface');
    if (scrolled) {
      return scrolled;
    }
    missing.push('style');
  } else {
    const magic = findStyleMagicButton();
    const expandedStyleSurface = Boolean(styleField || magic ||
      (magicAlreadyRequested && looksLikeSunoGeneratedStyle(styleValue)));
    if (!expandedStyleSurface) {
      const expanded = expandStylesIfNeeded();
      if (expanded) {
        return expanded;
      }
      const scrolled = scrollStylesPanelIntoView('styleSurfaceNeedsToolbar');
      if (scrolled) {
        return scrolled;
      }
      missing.push('style');
    } else if (magicAlreadyRequested &&
        styleValue.length >= 6 &&
        styleValue !== ignoredStyle) {
      styleSource = 'sunoMagic';
    } else if (!magic) {
      const expanded = expandStylesIfNeeded();
      if (expanded) {
        return expanded;
      }
      const scrolled = scrollStylesPanelIntoView('styleMagicNotVisible');
      if (scrolled) {
        return scrolled;
      }
      if (magicAlreadyRequested) {
        return JSON.stringify({
          ok: false,
          retry: true,
          magicClicked: false,
          message: '正在等待 Suno 自动风格生成完成...',
          stylePrompt: '',
          styleSource: 'sunoMagic',
          magicTarget: null,
          ignoredStylePrompt: ignoredStyle,
          stylePlaceholder,
          fieldCount: allFields.length,
          lyricsField: summarize(lyricsField),
          styleField: summarize(styleField),
          fields,
          textSample: normalize(document.body?.innerText || '').slice(0, 1000)
        });
      }
      missing.push('styleMagic');
    } else if (styleField && styleValue.length >= 6 && !magicAlreadyRequested) {
      const ignoredStylePrompt = ignoredStyle || styleValue;
      styleFilled = setValue(styleField, '');
      styleValue = getStyleValue(styleField);
      return JSON.stringify({
        ok: false,
        retry: true,
        magicClicked: false,
        message: 'Tomato 已清空 Suno Styles 中的旧风格，准备点击自动风格魔法棒。',
        stylePrompt: '',
        styleSource: 'sunoMagic',
        ignoredStylePrompt,
        styleFilled,
        fieldCount: allFields.length,
        lyricsField: summarize(lyricsField),
        styleField: summarize(styleField),
        stylePlaceholder,
        fields,
        textSample: normalize(document.body?.innerText || '').slice(0, 1000)
      });
    } else if (magic && !magicAlreadyRequested && allowMagicClick) {
      magicTrigger = triggerStyleMagicButton(magic);
      magicClicked = magicTrigger.clicked;
      magicTarget = summarize(magic.clickable);
      return JSON.stringify({
        ok: false,
        retry: magicClicked,
        missing: magicClicked ? [] : ['styleMagicClick'],
        magicClicked,
        message: magicClicked
          ? 'Tomato 已通过 DOM 触发 Suno 自动风格魔法棒，正在等待 Suno 根据歌词生成风格。'
          : 'Tomato 已找到 Suno 自动风格魔法棒，但 DOM click 触发失败。',
        stylePrompt: '',
        styleSource: 'sunoMagic',
        magicTarget,
        magicTrigger,
        ignoredStylePrompt: ignoredStyle,
        fieldCount: allFields.length,
        lyricsField: summarize(lyricsField),
        styleField: summarize(styleField),
        stylePlaceholder,
        fields,
        textSample: normalize(document.body?.innerText || '').slice(0, 1000)
      });
    } else if (magic && magicAlreadyRequested) {
      return JSON.stringify({
        ok: false,
        retry: true,
        magicClicked: false,
        message: '正在等待 Suno 自动风格生成完成...',
        stylePrompt: '',
        styleSource: 'sunoMagic',
        magicTarget: summarize(magic.clickable),
        ignoredStylePrompt: ignoredStyle,
        stylePlaceholder,
        fieldCount: allFields.length,
        lyricsField: summarize(lyricsField),
        styleField: summarize(styleField),
        fields,
        textSample: normalize(document.body?.innerText || '').slice(0, 1000)
      });
    } else if (magic && !allowMagicClick) {
      return JSON.stringify({
        ok: false,
        retry: true,
        magicClicked: false,
        message: '正在等待 Suno 自动风格生成完成...',
        stylePrompt: '',
        styleSource: 'sunoMagic',
        magicTarget: magic ? summarize(magic.clickable) : null,
        magicTrigger,
        ignoredStylePrompt: ignoredStyle,
        stylePlaceholder,
        fieldCount: allFields.length,
        lyricsField: summarize(lyricsField),
        styleField: summarize(styleField),
        fields,
        textSample: normalize(document.body?.innerText || '').slice(0, 1000)
      });
    }
  }
  const advancedActive = isAdvancedActive();
  return JSON.stringify({
    ok: missing.length === 0,
    missing,
    retry: false,
    magicClicked,
    magicTarget,
    magicTrigger,
    stylePrompt: styleValue,
    stylePlaceholder,
    styleSource,
    styleFilled,
    cookieAccepted: cookieResult.clicked,
    cookieTarget: cookieResult.target,
    advancedClicked: advancedResult.clicked,
    advancedAlreadyActive: advancedResult.alreadyActive,
    advancedActive,
    advancedTarget: advancedResult.target,
    fieldCount: allFields.length,
    lyricsField: summarize(lyricsField),
    styleField: summarize(styleField),
    fields,
    textSample: normalize(document.body?.innerText || '').slice(0, 1000)
  });
  } catch (error) {
    return JSON.stringify({
      ok: false,
      retry: false,
      missing: ['scriptError'],
      magicClicked: false,
      message: 'Suno 填表脚本执行失败：' +
        String(error && error.message ? error.message : error),
      error: String(error && error.message ? error.message : error),
      stack: String(error && error.stack ? error.stack : '')
    });
  }
})()
''';
  }

  static String get createScript => r'''
(() => {
  const visible = (el) => {
    if (!el) return false;
    const rect = el.getBoundingClientRect();
    const style = window.getComputedStyle(el);
    return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
  };
  const textOf = (el) => [
    el.getAttribute?.('aria-label'),
    el.innerText,
    el.textContent
  ].filter(Boolean).join(' ');
  const buttons = Array.from(document.querySelectorAll('button,[role="button"]')).filter(visible);
  const button = buttons.find((el) => /create song/i.test(textOf(el))) ||
    buttons.find((el) => /^create$/i.test(textOf(el).trim())) ||
    buttons.find((el) => /create/i.test(textOf(el)));
  if (!button) {
    return JSON.stringify({ ok: false, message: '没有找到 Suno Create 按钮。' });
  }
  if (button.disabled || button.getAttribute('aria-disabled') === 'true') {
    return JSON.stringify({ ok: false, message: 'Suno Create 按钮仍不可用，请检查歌词、风格或 credits。' });
  }
  button.click();
  return JSON.stringify({ ok: true });
})()
''';

  static String completionScript({
    required String expectedStylePrompt,
    required String expectedLyrics,
    required bool requireExpectedMatch,
    List<String> trustedSongUrls = const <String>[],
  }) {
    final expectedStyleJson = jsonEncode(expectedStylePrompt.trim());
    final expectedLyricsJson = jsonEncode(expectedLyrics.trim());
    final requireExpectedJson = jsonEncode(requireExpectedMatch);
    final trustedSongUrlsJson = jsonEncode(
      SunoUtilities.mergeSongUrls([trustedSongUrls]),
    );
    return '''
(() => {
  const expectedStyle = $expectedStyleJson;
  const expectedLyrics = $expectedLyricsJson;
  const requireExpectedMatch = $requireExpectedJson;
  const normalize = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
  const normalizeLoose = (value) => normalize(value).toLowerCase();
  const normalizeLyricsExact = (value) => normalize(value)
    .replace(/[“”]/g, '"')
    .replace(/[‘’]/g, "'")
    .toLowerCase()
    .replace(/[^a-z0-9\\u4e00-\\u9fff']+/g, ' ')
    .replace(/\\s+/g, ' ')
    .trim();
  const expectedLyricsExact = normalizeLyricsExact(expectedLyrics);
  const lyricsExactMatch = (text) => {
    if (!expectedLyricsExact) return false;
    return normalizeLyricsExact(text).includes(expectedLyricsExact);
  };
  const expectedTokens = normalize(expectedLyrics)
    .split(/[^A-Za-z0-9\\u4e00-\\u9fff'-]+/g)
    .map((value) => value.trim())
    .filter((value) => value.length >= 4)
    .slice(0, 20);
  const lyricSamples = normalize(expectedLyrics)
    .split(/\\n+/g)
    .map((value) => value.trim())
    .filter((value) => value.length >= 24)
    .slice(0, 4)
    .map((value) => value.slice(0, 90));
  const expectedScore = (text) => {
    const haystack = normalizeLoose(text);
    let score = 0;
    for (const token of expectedTokens) {
      if (haystack.includes(token.toLowerCase())) score += 1;
    }
    for (const sample of lyricSamples) {
      if (haystack.includes(sample.toLowerCase())) score += 6;
    }
    return score;
  };
  const visible = (el) => {
    if (!el) return false;
    const rect = el.getBoundingClientRect();
    const style = window.getComputedStyle(el);
    return rect.width > 0 &&
      rect.height > 0 &&
      style.visibility !== 'hidden' &&
      style.display !== 'none' &&
      Number(style.opacity || '1') > 0.01;
  };
  const songIdFromUrl = (url) => {
    const match = String(url || '').match(/\\/song\\/([0-9a-fA-F-]{36})/);
    return match ? match[1].toLowerCase() : '';
  };
  const canonicalSongUrl = (url) => {
    const songId = songIdFromUrl(url);
    return songId ? 'https://suno.com/song/' + songId : String(url || '').trim();
  };
  const trustedSongUrls = new Set(
    ($trustedSongUrlsJson).map(canonicalSongUrl).filter(Boolean)
  );
  const isTrustedSongUrl = (url) => trustedSongUrls.has(canonicalSongUrl(url));
  const incomplete = /generating|creating|processing|queued|loading|failed|error|retry|生成中|创建中|处理中|排队|失败|重试/i;
  const preview = /preview|demo|sample|clip|snippet|teaser|试听|試聽|预览|預覽|片段|样例|樣例/i;
  const rawAnchors = Array.from(document.querySelectorAll('a[href]'))
    .filter(visible)
    .filter((a) => /suno\\.com\\/song|\\/song\\//i.test(a.href))
    .map((a) => {
      const container = a.closest('article,section,[data-testid],[data-test-id],div') || a;
      const text = normalize(container.innerText || container.textContent || a.innerText || '');
      const title = normalize(container.querySelector?.('h1,h2,h3,[role="heading"]')?.innerText || a.innerText || '');
      return {
        href: canonicalSongUrl(a.href),
        title,
        text,
        expectedScore: expectedScore(title + '\\n' + text),
        lyricsExactMatch: lyricsExactMatch(title + '\\n' + text)
      };
    })
    .filter((item) => item.href && !incomplete.test(item.text) && !preview.test(item.text));
  const anchors = rawAnchors
    .filter((item) => !requireExpectedMatch || item.lyricsExactMatch || isTrustedSongUrl(item.href));
  const rawRows = Array.from(document.querySelectorAll('[data-testid="clip-row"],.clip-row,[role="group"][aria-label]'))
    .map((row, index) => {
      const text = normalize(row.innerText || row.textContent || '');
      const title = normalize(row.getAttribute('aria-label') || row.querySelector?.('h1,h2,h3,[role="heading"]')?.innerText || text.split('\\n')[0] || '');
      const anchor = row.querySelector?.('a[href*="/song/"],a[href*="suno.com/song"]');
      const href = canonicalSongUrl(anchor?.href || '') || ('suno-row:' + index + ':' + (title || 'untitled'));
      return {
        href,
        title,
        text,
        expectedScore: expectedScore(title + '\\n' + text),
        lyricsExactMatch: lyricsExactMatch(title + '\\n' + text)
      };
    })
    .filter((item) => item.href && !incomplete.test(item.text) && !preview.test(item.text));
  const rows = rawRows
    .filter((item) => !requireExpectedMatch || item.lyricsExactMatch || isTrustedSongUrl(item.href));
  const seen = new Set();
  const songCandidates = anchors.concat(rows).filter((item) => {
    if (seen.has(item.href)) return false;
    seen.add(item.href);
    return true;
  }).sort((left, right) => right.expectedScore - left.expectedScore);
  const rawSeen = new Set();
  const rawSongRows = rawRows.filter((item) => /\\/song\\//i.test(item.href));
  const unverifiedSource = rawSongRows.length > 0 ? rawSongRows : rawAnchors;
  const unverifiedSongCandidates = unverifiedSource.filter((item) => {
    if (!/\\/song\\//i.test(item.href)) return false;
    if (rawSeen.has(item.href)) return false;
    rawSeen.add(item.href);
    return true;
  });
  const mediaRank = (url) => {
    if (/\\.mp3(?:[?#]|\$)/i.test(url)) return 4;
    if (/\\.m4a(?:[?#]|\$)/i.test(url)) return 3;
    if (/\\.wav(?:[?#]|\$)/i.test(url)) return 2;
    if (/\\.webm(?:[?#]|\$)/i.test(url)) return 1;
    return 0;
  };
  const mediaUrls = Array.from(new Set(
    Array.from(document.querySelectorAll('audio[src],video[src],source[src]'))
      .map((el) => el.src)
      .concat(
        Array.from((document.documentElement?.innerHTML || '').matchAll(/https:\\/\\/cdn\\d*\\.suno\\.ai\\/[^"'<>\\s\\\\]+?\\.(?:mp3|m4a|wav|webm)(?:\\?[^"'<>\\s\\\\]*)?/gi))
          .map((match) => match[0])
      )
      .map((value) => String(value || '').replace(/&amp;/g, '&').trim())
      .filter((value) => value && !/sil-100|preview|sample|snippet|teaser/i.test(value))
  )).sort((left, right) => mediaRank(right) - mediaRank(left));
  const mediaBySongUrl = {};
  for (const song of songCandidates) {
    const songId = songIdFromUrl(song.href);
    if (!songId) continue;
    const matched = mediaUrls.find((url) => url.includes(songId));
    if (matched) mediaBySongUrl[song.href] = matched;
  }
  const isCreatePage = /\\/create(?:\\/|\$)/i.test(location.pathname || '');
  const sidebarRows = Array.from(document.querySelectorAll('[data-testid="clip-row"],.clip-row,[role="group"][aria-label]'));
  const sidebarText = normalize(sidebarRows.map((row) => row.innerText || row.textContent || '').join('\\n'));
  const detailLyricsText = normalize(
    Array.from(document.querySelectorAll('h1,h2,h3,[role="heading"],[data-testid*="lyric"],section,article,main'))
      .map((el) => el.innerText || el.textContent || '')
      .join('\\n')
  );
  const lyricsProbeText = isCreatePage
    ? sidebarText
    : (detailLyricsText || normalize(document.body?.innerText || document.body?.textContent || ''));
  const currentPageExpectedScore = expectedScore(lyricsProbeText);
  const currentPageLyricsExactMatch = lyricsExactMatch(lyricsProbeText);
  const currentPageBodyText = normalize(document.body?.innerText || document.body?.textContent || '');
  const createSidebarGeneratingCount = isCreatePage
    ? sidebarRows.filter((row) => incomplete.test(normalize(row.innerText || row.textContent || ''))).length
    : 0;
  const createSidebarSongUrls = isCreatePage
    ? unverifiedSongCandidates.map((item) => item.href)
    : [];
  const currentPageGenerating = (
    /\\/song\\//i.test(location.href) && incomplete.test(currentPageBodyText)
  ) || (isCreatePage && createSidebarGeneratingCount > 0);
  const canonicalCurrentUrl = canonicalSongUrl(location.href);
  const currentSongUrl = /\\/song\\//i.test(location.href) &&
    (!requireExpectedMatch ||
      currentPageLyricsExactMatch ||
      isTrustedSongUrl(canonicalCurrentUrl))
    ? canonicalCurrentUrl
    : '';
  // Suno detail pages can match the lyrics without exposing their own /song/
  // anchor. Keep the verified current URL so Dart can download by songUrl.
  if (currentSongUrl) {
    const currentSongId = songIdFromUrl(currentSongUrl);
    const matched = currentSongId
      ? mediaUrls.find((url) => url.includes(currentSongId))
      : '';
    if (matched) mediaBySongUrl[currentSongUrl] = matched;
  }
  const completedSongs = songCandidates.slice();
  if (currentSongUrl && !completedSongs.some((item) => item.href === currentSongUrl)) {
    completedSongs.unshift({
      href: currentSongUrl,
      title: normalize(document.querySelector('h1,h2,h3,[role="heading"]')?.innerText || ''),
      text: normalize(document.body?.innerText || document.body?.textContent || ''),
      expectedScore: currentPageExpectedScore
    });
  }
  const primarySongUrl = songCandidates[0]?.href || currentSongUrl;
  const primarySongId = songIdFromUrl(primarySongUrl);
  const primaryMediaUrl = primarySongUrl && mediaBySongUrl[primarySongUrl]
    ? mediaBySongUrl[primarySongUrl]
    : primarySongId
      ? (mediaUrls.find((url) => url.includes(primarySongId)) || '')
      : '';
  return JSON.stringify({
    songUrl: completedSongs[0]?.href || '',
    songUrls: completedSongs.map((item) => item.href),
    songs: completedSongs,
    candidateSongUrls: unverifiedSongCandidates.map((item) => item.href),
    candidateSongs: unverifiedSongCandidates,
    mediaUrl: primaryMediaUrl,
    mediaUrls,
    mediaBySongUrl,
    currentPageExpectedScore,
    currentPageLyricsExactMatch,
    currentPageGenerating,
    createSidebarSongUrls,
    createSidebarGeneratingCount,
    linkCount: songCandidates.length
  });
})()
''';
  }

  static String downloadScript({
    required List<String> downloadedSongUrls,
    required List<String> allowedSongUrls,
    required String expectedStylePrompt,
    required String expectedLyrics,
    required bool requireExpectedMatch,
    List<String> trustedSongUrls = const <String>[],
    bool dryRun = false,
    String? pendingSongUrl,
  }) {
    final downloadedJson = jsonEncode(downloadedSongUrls);
    final allowedJson = jsonEncode(allowedSongUrls);
    final expectedStyleJson = jsonEncode(expectedStylePrompt.trim());
    final expectedLyricsJson = jsonEncode(expectedLyrics.trim());
    final requireExpectedJson = jsonEncode(requireExpectedMatch);
    final dryRunJson = jsonEncode(dryRun);
    final pendingJson = jsonEncode((pendingSongUrl ?? '').trim());
    final trustedSongUrlsJson = jsonEncode(
      SunoUtilities.mergeSongUrls([trustedSongUrls]),
    );
    return '''
(() => {
  const canonicalSongUrl = (url) => {
    const match = String(url || '').match(/\\/song\\/([0-9a-fA-F-]{36})/);
    return match ? 'https://suno.com/song/' + match[1].toLowerCase() : String(url || '').trim();
  };
  const downloadedSongUrls = new Set(
    ($downloadedJson).map(canonicalSongUrl).filter(Boolean)
  );
  const allowedSongUrls = new Set(
    ($allowedJson).map(canonicalSongUrl).filter(Boolean)
  );
  const trustedSongUrls = new Set(
    ($trustedSongUrlsJson).map(canonicalSongUrl).filter(Boolean)
  );
  const expectedStyle = $expectedStyleJson;
  const expectedLyrics = $expectedLyricsJson;
  const requireExpectedMatch = $requireExpectedJson;
  const dryRun = $dryRunJson;
  const pendingSongUrl = canonicalSongUrl($pendingJson);
  const normalize = (value) => String(value || '').replace(/\\s+/g, ' ').trim();
  const normalizeLoose = (value) => normalize(value).toLowerCase();
  const normalizeLyricsExact = (value) => normalize(value)
    .replace(/[“”]/g, '"')
    .replace(/[‘’]/g, "'")
    .toLowerCase()
    .replace(/[^a-z0-9\\u4e00-\\u9fff']+/g, ' ')
    .replace(/\\s+/g, ' ')
    .trim();
  const expectedLyricsExact = normalizeLyricsExact(expectedLyrics);
  const lyricsExactMatch = (text) => {
    if (!expectedLyricsExact) return false;
    return normalizeLyricsExact(text).includes(expectedLyricsExact);
  };
  const expectedTokens = normalize(expectedLyrics)
    .split(/[^A-Za-z0-9\\u4e00-\\u9fff'-]+/g)
    .map((value) => value.trim())
    .filter((value) => value.length >= 4)
    .slice(0, 20);
  const lyricSamples = normalize(expectedLyrics)
    .split(/\\n+/g)
    .map((value) => value.trim())
    .filter((value) => value.length >= 24)
    .slice(0, 4)
    .map((value) => value.slice(0, 90));
  const expectedScore = (text) => {
    const haystack = normalizeLoose(text);
    let score = 0;
    for (const token of expectedTokens) {
      if (haystack.includes(token.toLowerCase())) score += 1;
    }
    for (const sample of lyricSamples) {
      if (haystack.includes(sample.toLowerCase())) score += 6;
    }
    return score;
  };
  const currentPageExpectedScore = expectedScore(
    document.body?.innerText || document.body?.textContent || ''
  );
  const currentPageLyricsExactMatch = lyricsExactMatch(
    document.body?.innerText || document.body?.textContent || ''
  );
  const isExpectedMatch = (text) =>
    !requireExpectedMatch || lyricsExactMatch(text);
  const isTrustedSongUrl = (url) => trustedSongUrls.has(canonicalSongUrl(url));
  const isBoundSongUrl = (url) => {
    const canonical = canonicalSongUrl(url);
    return Boolean(canonical) && (
      allowedSongUrls.has(canonical) ||
      isTrustedSongUrl(canonical)
    );
  };
  const visible = (el) => {
    if (!el) return false;
    const rect = el.getBoundingClientRect();
    const style = window.getComputedStyle(el);
    return rect.width > 0 &&
      rect.height > 0 &&
      style.visibility !== 'hidden' &&
      style.display !== 'none' &&
      Number(style.opacity || '1') > 0.01;
  };
  const textOf = (el) => normalize([
    el.getAttribute?.('aria-label'),
    el.getAttribute?.('title'),
    el.getAttribute?.('download'),
    el.getAttribute?.('data-testid'),
    el.getAttribute?.('data-test-id'),
    el.getAttribute?.('role'),
    el.href,
    el.innerText,
    el.textContent
  ].filter(Boolean).join(' '));
  const contextText = (el) => {
    const parts = [textOf(el)];
    let current = el.parentElement;
    for (let i = 0; current && i < 5; i += 1, current = current.parentElement) {
      const text = normalize(current.innerText || current.textContent || '');
      if (text && text.length <= 900) parts.push(text);
      parts.push(textOf(current));
    }
    return normalize(parts.join(' ')).slice(0, 1200);
  };
  const summarize = (el) => {
    if (!el) return null;
    const rect = el.getBoundingClientRect();
    return {
      tag: el.tagName.toLowerCase(),
      role: el.getAttribute('role') || '',
      type: el.getAttribute('type') || '',
      id: el.id || '',
      className: String(el.className || '').slice(0, 160),
      ariaLabel: el.getAttribute('aria-label') || '',
      title: el.getAttribute('title') || '',
      href: el.href || '',
      text: textOf(el).slice(0, 180),
      rect: {
        x: Math.round(rect.x),
        y: Math.round(rect.y),
        width: Math.round(rect.width),
        height: Math.round(rect.height)
      }
    };
  };
  const menuLayerSelector = '[role="menu"],[role="listbox"],[data-radix-popper-content-wrapper],[data-floating-ui-portal],[data-side][data-align]';
  const menuLayerFor = (el) => el?.closest?.(menuLayerSelector) || null;
  const clickLikeUser = (el, options = {}) => {
    if (!el) return;
    const label = textOf(el);
    const nativeOnly =
      options.nativeOnly === true ||
      /more menu contents|more options/i.test(label);
    el.scrollIntoView({ block: 'center', inline: 'center' });
    if (nativeOnly) {
      el.focus?.();
      el.click?.();
      return;
    }
    el.focus?.();
    const rect = el.getBoundingClientRect();
    const x = Math.max(0, Math.min(window.innerWidth - 1, rect.left + rect.width / 2));
    const y = Math.max(0, Math.min(window.innerHeight - 1, rect.top + rect.height / 2));
    const hit = document.elementFromPoint(x, y);
    const target = hit && (hit === el || el.contains(hit)) ? hit : el;
    const pointerOptions = {
      bubbles: true,
      cancelable: true,
      composed: true,
      view: window,
      clientX: x,
      clientY: y,
      screenX: window.screenX + x,
      screenY: window.screenY + y,
      button: 0,
      buttons: 1,
      pointerId: 1,
      pointerType: 'mouse',
      isPrimary: true
    };
    const mouseOptions = {
      bubbles: true,
      cancelable: true,
      composed: true,
      view: window,
      clientX: x,
      clientY: y,
      screenX: window.screenX + x,
      screenY: window.screenY + y,
      button: 0,
      buttons: 1
    };
    try {
      if (typeof PointerEvent === 'function') {
        target.dispatchEvent(new PointerEvent('pointerover', pointerOptions));
        target.dispatchEvent(new PointerEvent('pointermove', pointerOptions));
        target.dispatchEvent(new PointerEvent('pointerdown', pointerOptions));
      }
      target.dispatchEvent(new MouseEvent('mouseover', mouseOptions));
      target.dispatchEvent(new MouseEvent('mousemove', mouseOptions));
      target.dispatchEvent(new MouseEvent('mousedown', mouseOptions));
      if (typeof PointerEvent === 'function') {
        target.dispatchEvent(new PointerEvent('pointerup', {
          ...pointerOptions,
          buttons: 0
        }));
      }
      target.dispatchEvent(new MouseEvent('mouseup', {
        ...mouseOptions,
        buttons: 0
      }));
      el.click?.();
    } catch (_) {
      el.click?.();
    }
  };
  const isDisabled = (el) =>
    Boolean(el?.disabled) || el?.getAttribute?.('aria-disabled') === 'true';
  const clickableAncestor = (el) =>
    el?.closest?.('button,[role="button"],[role="menuitem"],a,label');
  const songUrlFor = (el) => {
    const anchor = el.closest?.('a[href*="/song/"],a[href*="suno.com/song"]') ||
      el.querySelector?.('a[href*="/song/"],a[href*="suno.com/song"]') ||
      el.closest?.('[data-testid],[data-test-id],article,section,div')?.querySelector?.('a[href*="/song/"],a[href*="suno.com/song"]');
    const href = String(anchor?.href || '');
    return canonicalSongUrl(href) || '';
  };
  const titleFor = (el) => {
    const container = el.closest?.('article,section,[data-testid],[data-test-id],div') || el;
    const heading = container.querySelector?.('h1,h2,h3,[role="heading"]');
    const headingText = normalize(heading?.innerText || heading?.textContent || '');
    if (headingText) return headingText.slice(0, 120);
    const text = normalize(container.innerText || container.textContent || '');
    return text.split(/\\n|\\|/).map((part) => normalize(part)).find((part) =>
      part.length >= 3 &&
      part.length <= 120 &&
      !/download|audio|mp3|create|share|more|下载|音频|创建|分享|更多/i.test(part)
    ) || '';
  };
  const controls = Array.from(document.querySelectorAll(
    'a[href],button,[role="button"],[role="menuitem"],label,[aria-label],[title],[data-testid],[data-test-id]'
  ))
    .filter(visible)
    .map((el) => {
      const clickable = clickableAncestor(el);
      if (!clickable || isDisabled(clickable)) return null;
      const label = textOf(el);
      const context = contextText(el);
      const contextMatchesLyrics = isExpectedMatch(context);
      const inOpenMenu = Boolean(menuLayerFor(clickable) || menuLayerFor(el));
      const hasBoundSongTarget =
        Boolean(pendingSongUrl) || allowedSongUrls.size > 0 || trustedSongUrls.size > 0;
      if (requireExpectedMatch && !hasBoundSongTarget && !contextMatchesLyrics) return null;
      const href = String(clickable.href || el.href || '');
      if (/suno\\.com\\/@|\\/\\@/i.test(href)) return null;
      if (/\\/style\\//i.test(href)) return null;
      if (href && !/\\/song\\//i.test(href) && !/download|audio|mp3/i.test(href)) return null;
      const songUrl = songUrlFor(clickable) || songUrlFor(el);
      const onSongDetail = /\\/song\\//i.test(location.href);
      const onCreatePage = /\\/create(?:\\/|\$)/i.test(location.pathname);
      const currentSongUrl = canonicalSongUrl(location.href);
      const currentUrlMatchesPending = pendingSongUrl &&
        location.href.startsWith(pendingSongUrl);
      const clickableRect = clickable.getBoundingClientRect();
      const downloadMenuContext =
        /download|save|export|mp3|下载|下載|保存|导出|匯出|音频下载|下载音频|音頻下載|下載音頻/i.test(context);
      const targetBoundToExpected =
        Boolean(songUrl && isBoundSongUrl(songUrl)) ||
        Boolean(pendingSongUrl && currentUrlMatchesPending && isBoundSongUrl(pendingSongUrl));
      const currentSongDetailMatchesExpected =
        onSongDetail &&
        currentSongUrl &&
        currentPageLyricsExactMatch &&
        (!pendingSongUrl || currentUrlMatchesPending || isBoundSongUrl(currentSongUrl));
      if (allowedSongUrls.size > 0 && !songUrl && !onSongDetail && !pendingSongUrl) return null;
      if (allowedSongUrls.size > 0 && songUrl && !allowedSongUrls.has(songUrl)) return null;
      if (pendingSongUrl && songUrl && songUrl !== pendingSongUrl) return null;
      if (songUrl && downloadedSongUrls.has(songUrl)) return null;
      if (!songUrl && pendingSongUrl && downloadedSongUrls.has(pendingSongUrl)) return null;
      if (requireExpectedMatch && songUrl && !contextMatchesLyrics && !isBoundSongUrl(songUrl)) {
        const trustedSongDetail =
          onSongDetail &&
          currentSongUrl === songUrl &&
          (isBoundSongUrl(songUrl) || currentPageLyricsExactMatch);
        if (!trustedSongDetail) return null;
      }
      if (requireExpectedMatch && pendingSongUrl && !songUrl) {
        const pendingTrusted = isBoundSongUrl(pendingSongUrl);
        const trustedPendingDetail =
          onSongDetail &&
          currentUrlMatchesPending &&
          (pendingTrusted || currentPageLyricsExactMatch);
        const trustedLibraryContext =
          !onSongDetail && contextMatchesLyrics;
        const trustedOpenMenu =
          inOpenMenu &&
          downloadMenuContext &&
          ((onSongDetail && pendingTrusted) ||
            (!onSongDetail && currentPageLyricsExactMatch));
        if (!trustedPendingDetail && !trustedLibraryContext && !trustedOpenMenu) {
          return null;
        }
      }
      if (requireExpectedMatch &&
          !contextMatchesLyrics &&
          !targetBoundToExpected &&
          !currentSongDetailMatchesExpected &&
          !(inOpenMenu && downloadMenuContext && currentPageLyricsExactMatch)) {
        return null;
      }
      let score = 0;
      const audioPattern = /\\bmp3\\b|\\baudio\\b|download audio|下载音频|音频下载|音频|聲音/i;
      const downloadPattern = /download|save|export|下载|下載|保存/i;
      const menuPattern = /more|options|menu|actions|ellipsis|更多|菜单|選單|操作/i;
      const confirmDownloadPattern =
        /download anyway|keep download|continue download|confirm download|仍然下载|继续下载|确认下载/i;
      const audioDownloadIntent =
        /download audio|audio download|mp3|下载音频|音频下载|下載音頻|音頻下載/i.test(label) ||
        (inOpenMenu && audioPattern.test(label) && downloadMenuContext) ||
        /download|audio|mp3/i.test(href);
      const hasDownloadIntent =
        audioDownloadIntent ||
        downloadPattern.test(label) ||
        confirmDownloadPattern.test(label) ||
        confirmDownloadPattern.test(context) ||
        (inOpenMenu && (downloadMenuContext || downloadPattern.test(context)));
      const hasMenuIntent =
        menuPattern.test(label) ||
        /more menu contents|more options/i.test(label) ||
        (inOpenMenu && menuPattern.test(context));
      if (!hasDownloadIntent && !hasMenuIntent) return null;
      const previewReject = /preview|demo|sample|clip|snippet|teaser|试听|試聽|预览|預覽|片段|样例|樣例/i;
      const incompleteReject = /generating|creating|processing|queued|loading|failed|error|retry|生成中|创建中|处理中|排队|失败|重试/i;
      const reject = /video|mp4|wav|midi|stems?|instrumental|share|copy|remix|extend|cover|image|artwork|delete|report|play|like|dislike|publish|创建|create|视频|影片|分享|复制|删除|举报|播放|喜欢|不喜欢|發布|发布|封面|图片|圖片/i;
      const profileReject = /profile|subscription|account|followers|following|upgrade|sign out|signout|log out|logout|my taste|个人主页|账户|账号|订阅|退出/i;
      const sidebarReject = /home|explore|create|studio|library|notifications|labs|terms|policies|upgrade|首页|探索|工作室|资料库|通知|条款/i;
      const globalMenuReject = /earn credits|invite friends|what'?s new|help|about|blog|careers|feedback|instagram|discord|twitter|\\bx\\b|积分|邀请|帮助|关于|博客|职业|反馈/i;
      const createFormReject = /add audio|browse|upload|record audio|save prompt|clear all form|save lyrics|clear lyrics|generate lyrics|enhance lyrics|saved styles|recommended styles|添加音频|上传|录音|保存歌词|清空歌词|生成歌词|推荐风格/i;
      const openMenuContext = /remix|edit|publish|share|download|manage|queue|playlist|song radio|trash|audio|mp3/i.test(context);
      if (previewReject.test(label) || previewReject.test(context)) return null;
      if (incompleteReject.test(context)) return null;
      if (profileReject.test(label) && !audioPattern.test(label)) return null;
      if (menuPattern.test(label) && clickableRect.left < 220 && clickableRect.width >= 80) return null;
      if (globalMenuReject.test(label) ||
          /listen-and-rank|release-notes|help\\.suno|\\/about|\\/blog|ashbyhq|x\\.com|instagram|discord/i.test(href)) return null;
      if (menuPattern.test(label) &&
          sidebarReject.test(context) &&
          !/download|audio|mp3|remix|edit|publish|share/i.test(context)) return null;
      if (onCreatePage &&
          !songUrl &&
          clickableRect.left < Math.min(820, window.innerWidth * 0.55) &&
          (createFormReject.test(label) ||
            (audioPattern.test(label) && !downloadMenuContext))) {
        return null;
      }
      if (onCreatePage &&
          inOpenMenu &&
          /upload|record|browse|上传|錄音|录音/i.test(context) &&
          !downloadMenuContext) {
        return null;
      }
      if (reject.test(label) && !audioPattern.test(label)) return null;
      if (allowedSongUrls.size > 0 &&
          !songUrl &&
          !onSongDetail &&
          pendingSongUrl &&
          !openMenuContext) return null;
      if (confirmDownloadPattern.test(label)) score += 42;
      if (confirmDownloadPattern.test(context)) score += 16;
      if (audioDownloadIntent) score += 35;
      if (audioPattern.test(context) && downloadMenuContext) score += 12;
      if (downloadPattern.test(label)) score += 24;
      if (downloadPattern.test(context)) score += 8;
      if (menuPattern.test(label)) score += 9;
      if (inOpenMenu && audioPattern.test(label)) score += 28;
      if (inOpenMenu && downloadPattern.test(label)) score += 18;
      if (contextMatchesLyrics) score += 18;
      if (/download|audio|mp3/i.test(href)) score += 20;
      if (clickable.tagName === 'A' && href) score += 6;
      if (clickable.tagName === 'BUTTON') score += 4;
      if (!label && clickable.querySelector?.('svg')) score += 2;
      score -= Math.max(0, label.length - 80) / 30;
      if (songUrl) score += 8;
      const directDownload = confirmDownloadPattern.test(label) ||
        /download audio|audio download|mp3/i.test(label) ||
        (inOpenMenu && audioPattern.test(label) && downloadMenuContext) ||
        /download|audio|mp3/i.test(href);
      return {
        clickable,
        label,
        context,
        href,
        score,
        directDownload,
        songUrl,
        title: titleFor(clickable),
        inOpenMenu
      };
    })
    .filter(Boolean)
    .sort((left, right) => right.score - left.score);
  const augmentedControls = controls.slice();
  const playbarMenu = Array.from(document.querySelectorAll('button,[role="button"],[aria-label]'))
    .filter(visible)
    .find((el) => /more menu contents/i.test(textOf(el)));
  const playbarSongUrl = playbarMenu ? songUrlFor(playbarMenu) : '';
  const playbarAllowed =
    allowedSongUrls.size === 0 ||
    (playbarSongUrl && allowedSongUrls.has(playbarSongUrl));
  if (playbarMenu &&
      playbarAllowed &&
      !augmentedControls.some((item) => item.clickable === playbarMenu)) {
    augmentedControls.push({
      clickable: playbarMenu,
      label: textOf(playbarMenu),
      context: contextText(playbarMenu),
      href: '',
      score: 18,
      directDownload: false,
      songUrl: playbarSongUrl || pendingSongUrl || '',
      title: titleFor(playbarMenu),
      inOpenMenu: false
    });
  }
  augmentedControls.sort((left, right) => right.score - left.score);
  const isDownloadMenuItem = (item) =>
    item.directDownload ||
    /download audio|audio download|mp3|下载音频|音频下载|下載音頻|音頻下載/i.test(
      [
        item.label,
        item.context,
        item.href
      ].join(' ')
    );
  const canUseCurrentSongDetail =
    location.href.toLowerCase().includes('/song/') &&
    currentPageLyricsExactMatch &&
    (!pendingSongUrl || location.href.startsWith(pendingSongUrl));
  const isSongMenuTrigger = (item) =>
    !item.inOpenMenu &&
    !hasDownloadAdvanceStep &&
    /more menu contents|more options|actions|ellipsis|更多|菜单|選單|操作/i.test(
      [item.label, item.context].join(' ')
    ) &&
    canUseCurrentSongDetail;
  // 新版 Suno 歌曲详情 More 菜单不再带 role="menu"/radix/floating-ui 标记，
  // 打开后的“Download”菜单项 inOpenMenu 探测不到，也不含 audio/mp3 字样。
  // 在已核对歌词的详情页上，把纯 Download 标签按钮当作下一步推进项点击，
  // 否则查找器会一直回落到 More 触发器，反复开关菜单形成下载死循环。
  const isDownloadAdvanceItem = (item) =>
    canUseCurrentSongDetail &&
    !/more menu contents|more options/i.test(item.label) && (
      /^(?:download\\s*)+\$/i.test(item.label) ||
      /mp3|audio/i.test(item.label)
    );
  const hasDownloadAdvanceStep = augmentedControls.some(isDownloadAdvanceItem);
  const direct = augmentedControls.find(isDownloadMenuItem);
  const openMenuText = normalize(Array.from(document.querySelectorAll(menuLayerSelector))
    .filter(visible)
    .map((el) => el.innerText || el.textContent || '')
    .join(' '));
  const nonDownloadSongMenuOpen =
    /restore to library|delete permanently|report|恢复到资料库|永久删除|举报/i.test(openMenuText) &&
    !/download|audio|mp3|下载|下載|音频|音頻/i.test(openMenuText);
  if (!direct && nonDownloadSongMenuOpen) {
    return JSON.stringify({
      ok: false,
      retry: false,
      stage: 'nonDownloadMenu',
      message: 'Suno 当前歌曲详情菜单没有 Download/Audio 项，将改到 Library 查找完整歌曲。',
      menuText: openMenuText.slice(0, 240),
      candidates: augmentedControls.slice(0, 12).map((item) => ({
        label: item.label,
        score: item.score,
        directDownload: item.directDownload,
        songUrl: item.songUrl,
        title: item.title,
        inOpenMenu: item.inOpenMenu,
        target: summarize(item.clickable)
      })),
      currentPageExpectedScore,
      currentPageLyricsExactMatch
    });
  }
  const menu = augmentedControls.find((item) =>
    item.inOpenMenu &&
    !/more menu contents/i.test(item.label) &&
    isDownloadMenuItem(item)
  ) || augmentedControls.find(isDownloadAdvanceItem)
    || augmentedControls.find(isSongMenuTrigger);
  const target = direct || menu;
  if (!target) {
    return JSON.stringify({
      ok: false,
      retry: false,
      message: 'Suno 生成结果已出现，但没有找到 Download 或 Audio 下载按钮。',
      candidates: augmentedControls.slice(0, 12).map((item) => ({
        label: item.label,
        score: item.score,
        directDownload: item.directDownload,
        songUrl: item.songUrl,
        title: item.title,
        inOpenMenu: item.inOpenMenu,
        target: summarize(item.clickable)
      })),
      currentPageExpectedScore,
      currentPageLyricsExactMatch
    });
  }
  if (dryRun) {
    return JSON.stringify({
      ok: Boolean(direct),
      retry: !direct,
      dryRun: true,
      wouldClick: true,
      stage: direct ? 'download' : 'menu',
      songUrl: target.songUrl || pendingSongUrl || ('suno-row:' + (target.title || 'matched')),
      title: target.title || '',
      target: summarize(target.clickable),
      candidates: augmentedControls.slice(0, 12).map((item) => ({
        label: item.label,
        score: item.score,
        directDownload: item.directDownload,
        songUrl: item.songUrl,
        title: item.title,
        inOpenMenu: item.inOpenMenu,
        target: summarize(item.clickable)
      })),
      currentPageExpectedScore,
      currentPageLyricsExactMatch
    });
  }
  clickLikeUser(target.clickable, {
    nativeOnly: /more menu contents|more options/i.test(target.label)
  });
  return JSON.stringify({
    ok: Boolean(direct),
    retry: !direct,
    clicked: true,
    stage: direct ? 'download' : 'menu',
    songUrl: target.songUrl || pendingSongUrl || ('suno-row:' + (target.title || 'matched')),
    title: target.title || '',
    target: summarize(target.clickable),
    candidates: augmentedControls.slice(0, 12).map((item) => ({
      label: item.label,
      score: item.score,
      directDownload: item.directDownload,
      songUrl: item.songUrl,
      title: item.title,
      inOpenMenu: item.inOpenMenu,
      target: summarize(item.clickable)
    })),
    currentPageExpectedScore,
    currentPageLyricsExactMatch
  });
})()
''';
  }
}
