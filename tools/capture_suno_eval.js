(() => {
  const el = document.querySelector('[aria-label="Lyrics editor"]');
  const normalize = (v) => String(v || '').replace(/\s+/g, ' ').trim();
  const counter =
    normalize(document.body.innerText).match(/\d+\s*of\s*5000\s*characters\s*used|\d+\s*\/\s*5000/i)?.[0] ||
    null;
  return JSON.stringify(
    {
      url: location.href,
      title: document.title,
      counter,
      lyricsEditor: el
        ? {
            tag: el.tagName.toLowerCase(),
            role: el.getAttribute('role'),
            className: el.className,
            ariaLabel: el.getAttribute('aria-label'),
            contentEditable: el.getAttribute('contenteditable'),
            dataLexical: el.getAttribute('data-lexical-editor'),
            innerTextLength: normalize(el.innerText).length,
            innerTextStart: normalize(el.innerText).slice(0, 300),
            innerTextEnd: normalize(el.innerText).slice(-300),
            paragraphCount: el.querySelectorAll('p').length,
            lexicalTextNodes: Array.from(el.querySelectorAll('[data-lexical-text]')).length,
            rect: (() => {
              const r = el.getBoundingClientRect();
              return { x: r.x, y: r.y, w: r.width, h: r.height };
            })(),
            outerHtmlSample: el.outerHTML.slice(0, 4000),
            innerHtmlSample: el.innerHTML.slice(0, 4000),
          }
        : null,
      stylesField: (() => {
        const s = document.querySelector('textarea, [aria-label*="deep synths"]');
        if (!s) return null;
        return {
          tag: s.tagName.toLowerCase(),
          ariaLabel: s.getAttribute('aria-label'),
          valueLength: (s.value || s.innerText || '').length,
        };
      })(),
    },
    null,
    2,
  );
})()
