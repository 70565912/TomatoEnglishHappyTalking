/**
 * Quick Suno Create fill QA: Lyrics must actually be written (counter/lexicalLength).
 * Takes a screenshot for visual confirmation. Does NOT pass on "attempted only".
 *
 * Prerequisites:
 *   .\tools\build_windows.ps1 -Run
 *   Suno account logged in inside the WebView (Advanced Create page).
 *
 * Usage:
 *   node tools/qa_suno_fill_quick.mjs --articleId 84
 */
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

const config = parseArgs(process.argv.slice(2));
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const startedAt = Date.now();
const events = [];
const seenLogKeys = new Set();

async function main() {
  await mkdir(config.outputDir, { recursive: true });
  console.log(`=== Suno fill quick QA (article ${config.articleId}) ===`);
  console.log(`QA: ${config.baseUrl}`);

  await waitForHealth();
  const article = await findArticle(config.articleId);
  if (!article) {
    throw new Error(`Article ${config.articleId} not found`);
  }
  record('article', { id: article.id, title: article.title, seriesId: article.seriesId });

  await fetch(`${config.baseUrl}/navigate`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ path: '/#/article/new' }),
  });
  await wait(800);
  if (article.seriesId != null) {
    await bridge('series.openCreationCenter', { seriesId: article.seriesId });
    await wait(1000);
  }

  console.log('Starting listening.songGenerate (Suno)...');
  const generateState = await bridge('listening.songGenerate', {
    articleId: config.articleId,
    source: 'suno',
  });
  record('songGenerate', {
    status: generateState.status,
    automationStatus: generateState.automationStatus,
  });

  const deadline = Date.now() + config.timeoutMs;
  let lastStatus = '';
  let pasteMethod = null;
  let sawPasteAttempt = false;

  while (Date.now() < deadline) {
    await pollLogs();
    let state;
    try {
      state = await bridge('listening.songState', { articleId: config.articleId });
    } catch (error) {
      record('crash', { error: String(error) });
      throw new Error(`QA bridge failed (App may have crashed): ${error}`);
    }

    const automationStatus = String(
      state.automationStatus ?? state.status ?? '',
    ).trim();
    if (automationStatus !== lastStatus) {
      console.log(`[status] ${automationStatus}`);
      lastStatus = automationStatus;
      record(`status:${automationStatus}`, {});
    }

    for (const item of events) {
      if (item.name === 'clipboard_paste') {
        sawPasteAttempt = true;
        pasteMethod = item.data?.pasteMethod ?? pasteMethod;
      }
    }

    if (
      sawPasteAttempt &&
      ['cdpCtrlVKeys', 'cdpCtrlV'].includes(pasteMethod) &&
      automationStatus === 'waitingConfirm'
    ) {
      await wait(20_000);
      if (!(await healthOk())) {
        record('crash', { error: 'App died within 20s after waitingConfirm' });
        throw new Error('App crashed after paste (health check failed)');
      }
      await pollLogs();
      break;
    }

    await wait(config.pollMs);
  }

  const screenshotPath = path.join(config.outputDir, 'suno-fill-screenshot.png');
  try {
    const shot = await fetch(`${config.baseUrl}/screenshot`);
    if (shot.ok) {
      const buf = Buffer.from(await shot.arrayBuffer());
      await writeFile(screenshotPath, buf);
      record('screenshot', { path: screenshotPath, bytes: buf.length });
      console.log(`Screenshot: ${screenshotPath}`);
    }
  } catch (error) {
    record('screenshot_failed', { error: String(error) });
  }

  const crashed = events.some((item) => item.name === 'crash');
  const autoPasted =
    sawPasteAttempt &&
    ['osCtrlV', 'cdpCtrlVKeys', 'cdpCtrlV'].includes(pasteMethod) &&
    lastStatus === 'waitingConfirm';
  const pass = !crashed && autoPasted;

  const report = {
    articleId: config.articleId,
    durationMs: Date.now() - startedAt,
    sawPasteAttempt,
    autoPasted,
    pasteMethod,
    automationStatus: lastStatus,
    screenshotPath,
    events,
    pass,
  };
  const outPath = path.join(config.outputDir, 'suno-fill-quick-report.json');
  await writeFile(outPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  console.log(`Report: ${outPath}`);
  console.log(
    `Result: pass=${pass} method=${pasteMethod} status=${lastStatus}`,
  );

  if (!pass) {
    throw new Error(
      `Suno fill QA FAILED: autoPasted=${autoPasted}, method=${pasteMethod}, status=${lastStatus}, crash=${crashed}`,
    );
  }
  console.log('PASS: CDP paste dispatched and automation reached waitingConfirm.');
}

function parseArgs(argv) {
  const options = {
    articleId: 82,
    port: 39317,
    timeoutMs: 8 * 60 * 1000,
    pollMs: 3000,
    outputDir: path.join('output', 'qa', 'suno-fill-quick'),
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--articleId') options.articleId = Number(argv[++i]);
    else if (arg === '--port') options.port = Number(argv[++i]);
    else if (arg === '--timeout-minutes') {
      options.timeoutMs = Number(argv[++i]) * 60 * 1000;
    } else if (arg === '--output') options.outputDir = argv[++i];
  }
  options.baseUrl = `http://127.0.0.1:${options.port}`;
  return options;
}

function record(name, data) {
  events.push({ name, at: new Date().toISOString(), data });
}

async function healthOk() {
  try {
    const res = await fetch(`${config.baseUrl}/health`);
    if (!res.ok) return false;
    const body = await res.json();
    return body.ok === true;
  } catch (_) {
    return false;
  }
}

async function waitForHealth() {
  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${config.baseUrl}/health`);
      if (res.ok) return;
    } catch (_) {}
    await wait(2000);
  }
  throw new Error(`QA health check failed: ${config.baseUrl}/health`);
}

async function bridge(type, payload = {}) {
  const res = await fetch(`${config.baseUrl}/bridge`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ type, payload }),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`bridge ${type} failed: ${res.status} ${text}`);
  }
  const response = await res.json();
  if (response && typeof response === 'object' && response.payload != null) {
    return response.payload;
  }
  return response;
}

async function findArticle(articleId) {
  const list = await bridge('article.list', {});
  const articles = list.articles ?? list.items ?? [];
  return articles.find((item) => Number(item.id) === Number(articleId)) ?? null;
}

async function pollLogs() {
  try {
    const res = await fetch(
      `${config.baseUrl}/logs/recent?limit=200&category=suno`,
    );
    if (!res.ok) return;
    const body = await res.json();
    const entries = body.entries ?? body.logs ?? body.items ?? [];
    for (const entry of entries) {
      const key = `${entry.ts}|${entry.event}|${entry.data?.pasteMethod}|${entry.data?.counterCount}|${entry.data?.lyricsOk}`;
      if (seenLogKeys.has(key)) continue;
      seenLogKeys.add(key);
      if (entry.event === 'create.clipboard_paste') {
        record('clipboard_paste', {
          pasteOk: entry.data?.pasteOk,
          focusOk: entry.data?.focusOk,
          pasteMethod: entry.data?.pasteMethod,
          expectedLength: entry.data?.expectedLength,
        });
        console.log(
          `[paste] ok=${entry.data?.pasteOk} method=${entry.data?.pasteMethod}`,
        );
      }
      if (entry.event === 'create.clipboard_paste.sent') {
        record('clipboard_paste', {
          pasteMethod: entry.data?.pasteMethod,
          pasteOk: entry.data?.pasteOk,
        });
        console.log(
          `[paste] sent method=${entry.data?.pasteMethod} ok=${entry.data?.pasteOk}`,
        );
      }
      if (entry.event === 'create.lyrics_probe_after_paste') {
        record('lyrics_probe', {
          lyricsOk: entry.data?.lyricsOk,
          counterCount: entry.data?.counterCount,
          lexicalLength: entry.data?.lexicalLength,
          expectedLength: entry.data?.expectedLength,
        });
      }
      if (entry.event === 'create.lexical_lyrics_write') {
        record('lexical_write', {
          ok: entry.data?.ok,
          counterCount: entry.data?.counterCount,
          lexicalLength: entry.data?.lexicalLength,
          method: entry.data?.method,
        });
      }
      if (entry.event === 'create.fill_probe') {
        record('fill_probe', {
          ok: entry.data?.ok,
          lyricsCounterCount: entry.data?.lyricsCounterCount,
          lyricsLexicalLength: entry.data?.lyricsLexicalLength,
          missing: entry.data?.missing,
        });
      }
    }
  } catch (_) {}
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
