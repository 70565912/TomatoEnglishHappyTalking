/**
 * Capture Suno Create lyrics editor DOM after manual fill (Playwright CLI session).
 * Usage: node tools/capture_suno_lyrics_dom.mjs
 */
import { execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const outDir = path.resolve('output/playwright');
fs.mkdirSync(outDir, { recursive: true });
const stamp = new Date().toISOString().replace(/[:.]/g, '-');

const runCode = String.raw`
(async () => {
  const normalize = (v) => String(v || '').replace(/\s+/g, ' ').trim();
  const rectOf = (el) => {
    const r = el.getBoundingClientRect();
    return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
  };
  const editors = Array.from(document.querySelectorAll(
    'textarea, input, [contenteditable="true"], [role="textbox"], .lyrics-editor-content, [data-lexical-editor="true"]'
  )).map((el) => ({
    tag: el.tagName.toLowerCase(),
    role: el.getAttribute('role') || '',
    className: String(el.className || '').slice(0, 200),
    ariaLabel: el.getAttribute('aria-label') || '',
    placeholder: el.getAttribute('placeholder') || '',
    contentEditable: el.getAttribute('contenteditable') || '',
    dataLexical: el.getAttribute('data-lexical-editor') || '',
    valueLength: el.matches?.('textarea,input') ? (el.value || '').length : 0,
    innerTextLength: normalize(el.innerText || el.textContent || '').length,
    innerTextSample: normalize(el.innerText || el.textContent || '').slice(0, 400),
    rect: rectOf(el),
    outerHtmlSample: el.outerHTML.slice(0, 1200),
    childSummary: Array.from(el.querySelectorAll('[data-lexical-text], p, span')).slice(0, 8).map((n) => ({
      tag: n.tagName.toLowerCase(),
      className: String(n.className || '').slice(0, 80),
      textLen: normalize(n.textContent || '').length,
      textSample: normalize(n.textContent || '').slice(0, 120),
    })),
  }));
  const lyricsEditor = document.querySelector('.lyrics-editor-content[role="textbox"], .lyrics-editor-content');
  const counterMatch = normalize(document.body.innerText).match(/(\d+)\s*\/\s*5000/);
  return JSON.stringify({
    url: location.href,
    title: document.title,
    counter: counterMatch ? counterMatch[0] : null,
    lyricsEditor: lyricsEditor ? {
      tag: lyricsEditor.tagName.toLowerCase(),
      className: lyricsEditor.className,
      ariaLabel: lyricsEditor.getAttribute('aria-label') || '',
      innerTextLength: normalize(lyricsEditor.innerText || '').length,
      innerTextStart: normalize(lyricsEditor.innerText || '').slice(0, 500),
      innerTextEnd: normalize(lyricsEditor.innerText || '').slice(-500),
      rect: rectOf(lyricsEditor),
      outerHtml: lyricsEditor.outerHTML.slice(0, 8000),
      html: lyricsEditor.innerHTML.slice(0, 8000),
    } : null,
    editors,
    bodyTextSample: normalize(document.body.innerText).slice(0, 3000),
  }, null, 2);
})()
`;

function sh(cmd) {
  return execSync(cmd, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
}

console.log('Capturing Suno lyrics DOM...');
sh('npx --package @playwright/cli playwright-cli snapshot');
try {
  sh(`npx --package @playwright/cli playwright-cli screenshot output/playwright/suno-lyrics-filled-${stamp}.png`);
} catch (e) {
  console.warn('screenshot failed:', e.message);
}

const jsonPath = path.join(outDir, `suno-lyrics-filled-${stamp}.json`);
const evalOut = sh(`npx --package @playwright/cli playwright-cli eval ${JSON.stringify(runCode)}`);
fs.writeFileSync(jsonPath, evalOut.trim(), 'utf8');
console.log('Saved:', jsonPath);
console.log(evalOut.slice(0, 2000));
