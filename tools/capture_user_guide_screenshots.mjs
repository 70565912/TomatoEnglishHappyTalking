import { execFile } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';
import sharp from 'sharp';

const execFileAsync = promisify(execFile);
const baseUrl = 'http://127.0.0.1:39317';
const outputDir = path.resolve('docs/user-guide/screenshots');
const repoRoot = path.resolve('tools/..');
const resizeScript = path.join(repoRoot, 'tools/qa_set_window_size.ps1');
const TARGET_WIDTH = Number(process.env.TOMATO_CAPTURE_WIDTH ?? 1920);
const TARGET_HEIGHT = Number(process.env.TOMATO_CAPTURE_HEIGHT ?? 1080);
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function request(endpoint, options) {
  const response = await fetch(`${baseUrl}${endpoint}`, options);
  if (endpoint.startsWith('/screenshot')) {
    if (!response.ok) {
      throw new Error(`screenshot failed: ${response.status}`);
    }
    return Buffer.from(await response.arrayBuffer());
  }
  const payload = await response.json();
  if (!response.ok) {
    throw new Error(payload?.error?.message ?? `request failed: ${endpoint}`);
  }
  return payload;
}

async function setWindowSize(width, height) {
  const { stdout } = await execFileAsync('powershell', [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    resizeScript,
    '-Width',
    String(Math.round(width)),
    '-Height',
    String(Math.round(height)),
  ], { cwd: repoRoot });
  return JSON.parse(stdout.trim());
}

async function navigate(route) {
  await request('/navigate', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ path: route }),
  });
  await wait(1800);
}

async function click(text) {
  await request('/click', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text }),
  });
  await wait(900);
}

async function evalJs(source) {
  const payload = await request('/eval', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ source }),
  });
  if (payload.ok === false) {
    throw new Error(payload.error?.message ?? 'eval failed');
  }
  return payload;
}

async function fullPageScreenshot(name) {
  const bytes = await request('/screenshot');
  const filePath = path.join(outputDir, `${name}.png`);
  await writeFile(filePath, bytes);
  const meta = await sharp(bytes).metadata();
  console.log(
    `saved ${filePath} (${bytes.length} bytes, ${meta.width}x${meta.height}, single-shot)`,
  );
}

async function main() {
  await mkdir(outputDir, { recursive: true });

  const health = await request('/health');
  if (!health.webReady) {
    throw new Error('QA health check failed: web is not ready');
  }

  try {
    await evalJs('JSON.stringify({ ok: true, probe: true })');
  } catch {
    throw new Error('当前运行的程序不支持 /eval，请先重新构建并启动 Windows 版后再截图');
  }

  await setWindowSize(TARGET_WIDTH, TARGET_HEIGHT);
  await wait(500);

  const library = await request('/bridge', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ type: 'article.list', payload: {} }),
  });
  const series = library.payload.series[0];
  const article =
    library.payload.articles.find((item) => item.seriesId === series.id) ??
    library.payload.articles[0];
  console.log(`using ${series.title} (${series.id}) / ${article.title} (${article.id})`);
  console.log(`capture viewport=${TARGET_WIDTH}x${TARGET_HEIGHT}, mode=cdp-full-page`);

  const routes = [
    ['01-home', '/'],
    ['02-article-new', '/article/new'],
    ['03-book-detail', `/books/${series.id}`],
    ['04-listening', `/books/${series.id}/player?articleId=${article.id}&mode=listening`],
    ['05-song', `/books/${series.id}/player?articleId=${article.id}&mode=song`],
    ['06-creation-picture', `/creation?seriesId=${series.id}&articleId=${article.id}`],
    ['07-practice', `/practice?seriesId=${series.id}`],
    ['08-follow', `/follow/${article.id}`],
    ['09-chat', `/chat/${article.id}`],
    ['10-settings', '/settings'],
  ];

  try {
    for (const [name, route] of routes) {
      await navigate(route);
      if (name === '09-chat') {
        await wait(1200);
      }
      if (name === '06-creation-picture') {
        await fullPageScreenshot(name);
        await click('歌曲');
        await fullPageScreenshot('06b-creation-song');
        await click('视频导出');
        await fullPageScreenshot('06c-creation-video');
        continue;
      }
      await fullPageScreenshot(name);
    }
  } finally {
    await setWindowSize(1440, 900);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
