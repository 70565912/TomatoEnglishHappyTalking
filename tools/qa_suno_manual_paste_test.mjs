/**
 * Suno manual paste test: open Create, copy lyrics to OS clipboard, stop polling,
 * then let the operator paste with Ctrl+V and watch whether the App stays alive.
 *
 * Prerequisites:
 *   .\tools\build_windows.ps1 -Run -DartDefine "TOMATO_QA_REMOTE=true,TOMATO_QA_PORT=39317"
 *   Suno account logged in inside the Suno WebView.
 *
 * Usage:
 *   node tools/qa_suno_manual_paste_test.mjs --articleId 84
 *   node tools/qa_suno_manual_paste_test.mjs --articleId 84 --watch-minutes 10
 */
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

const config = parseArgs(process.argv.slice(2));
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const startedAt = Date.now();
const events = [];

async function main() {
  await mkdir(config.outputDir, { recursive: true });
  console.log(`=== Suno manual paste test (article ${config.articleId}) ===`);
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

  console.log('Starting suno.manualPasteTest...');
  const startState = await bridge('suno.manualPasteTest', {
    articleId: config.articleId,
  });
  record('manualPasteTest.start', startState);

  const openDeadline = Date.now() + config.openTimeoutMs;
  let readyState = null;
  while (Date.now() < openDeadline) {
    if (!(await healthOk())) {
      throw new Error('App crashed while opening Suno manual paste test');
    }
    const state = await bridge('listening.songState', {
      articleId: config.articleId,
    });
    record('poll', {
      automationStatus: state.automationStatus,
      manualPasteReady: state.manualPasteReady,
      expectedLyricsLength: state.expectedLyricsLength,
    });
    if (state.manualPasteReady === true) {
      readyState = state;
      break;
    }
    await wait(config.pollMs);
  }

  if (!readyState) {
    throw new Error(
      'Timed out waiting for manualPasteReady. Is Suno Create loaded and logged in?',
    );
  }

  console.log('');
  console.log('=== READY FOR MANUAL PASTE ===');
  console.log(
    `Lyrics length in clipboard: ${readyState.expectedLyricsLength ?? 'unknown'}`,
  );
  console.log('1. Click the Suno Lyrics editor in the overlay WebView.');
  console.log('2. Press Ctrl+V to paste the full lyrics.');
  console.log('3. Watch whether the App crashes or freezes.');
  console.log(
    `Health watch: ${config.watchMinutes} minute(s). Press Ctrl+C to stop early.`,
  );
  console.log('');

  const watchDeadline = Date.now() + config.watchMinutes * 60 * 1000;
  let checks = 0;
  while (Date.now() < watchDeadline) {
    await wait(config.healthPollMs);
    checks += 1;
    if (!(await healthOk())) {
      record('crash', { afterChecks: checks });
      throw new Error('App health check failed after manual paste window');
    }
    if (checks % 5 === 0) {
      console.log(`[health] ok (${checks} checks)`);
    }
  }

  const report = {
    articleId: config.articleId,
    durationMs: Date.now() - startedAt,
    manualPasteReady: true,
    expectedLyricsLength: readyState.expectedLyricsLength ?? null,
    healthChecks: checks,
    pass: true,
    events,
  };
  const outPath = path.join(config.outputDir, 'suno-manual-paste-report.json');
  await writeFile(outPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  console.log(`Report: ${outPath}`);
  console.log(
    'PASS: manual paste test session stayed healthy through the watch window.',
  );
}

function parseArgs(argv) {
  const options = {
    articleId: 84,
    port: 39317,
    openTimeoutMs: 8 * 60 * 1000,
    pollMs: 3000,
    watchMinutes: 5,
    healthPollMs: 3000,
    outputDir: path.join('output', 'qa', 'suno-manual-paste'),
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--articleId') options.articleId = Number(argv[++i]);
    else if (arg === '--port') options.port = Number(argv[++i]);
    else if (arg === '--watch-minutes') options.watchMinutes = Number(argv[++i]);
    else if (arg === '--output') options.outputDir = argv[++i];
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
    if (await healthOk()) return;
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

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
