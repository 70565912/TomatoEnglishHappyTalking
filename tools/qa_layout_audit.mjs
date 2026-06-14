import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

const config = parseArgs(process.argv.slice(2));
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const screenshots = [];
const pages = [];

async function main() {
  await mkdir(config.outputDir, { recursive: true });
  await mkdir(config.screenshotDir, { recursive: true });
  const health = await waitForHealth();
  const library = await bridge('article.list', {});
  const { series, article } = pickAuditTargets(library);

  await auditRoute({
    name: 'home',
    route: '/',
    expectText: '书库、绘本和章节听力工作台',
  });
  await auditRoute({
    name: 'article-new',
    route: '/article/new',
    expectText: '新增文章',
  });

  if (series && article) {
    const bookDetail = await auditRoute({
      name: 'book-detail',
      route: `/books/${series.id}`,
      expectText: series.title,
    });
    validateBookDetailCover(bookDetail, series.title);

    await auditRoute({
      name: 'book-player-listening',
      route: `/books/${series.id}/player?articleId=${article.id}&mode=listening`,
      expectText: '听力进度',
    });
    await auditBookPlayerDrawer();
    await auditRoute({
      name: 'book-player-song',
      route: `/books/${series.id}/player?articleId=${article.id}&mode=song`,
      expectText: '歌曲列表',
    });
    await auditRoute({
      name: 'creation-picture',
      route: `/creation?seriesId=${series.id}&articleId=${article.id}`,
      expectText: '绘本组图',
    });
    await assertNoResourceLibraryTab('creation-picture');
    await auditBookCardSwitch({
      name: 'creation-book-switch',
      route: `/creation?seriesId=${series.id}&articleId=${article.id}`,
      initialArticleTitle: article.title,
    });
    await auditCreationTab('creation-song', 1, 'Suno 歌曲');
    await auditCreationTab('creation-video', 2, '视频导出');
    await auditRoute({
      name: 'practice-center',
      route: `/practice?seriesId=${series.id}`,
      expectText: '练习中心',
    });
    await auditBookCardSwitch({
      name: 'practice-book-switch',
      route: `/practice?seriesId=${series.id}`,
      initialArticleTitle: article.title,
    });

    if (config.includeFollowPage) {
      await auditRoute({
        name: 'follow-page',
        route: `/follow/${article.id}`,
        expectText: '播放原音',
      });
    }
    if (config.includeChatPage) {
      await auditRoute({
        name: 'chat-page',
        route: `/chat/${article.id}`,
        expectText: '对话提纲',
        settleMs: 2500,
      });
    }
  }

  await auditRoute({
    name: 'settings',
    route: '/settings',
    expectText: 'Suno 输出目录',
  });
  await cleanupRoute();

  const issues = pages.flatMap((page) => page.issues.map((issue) => ({
    page: page.name,
    ...issue,
  })));
  const result = {
    ok: issues.length === 0,
    baseUrl: config.baseUrl,
    health: {
      webReady: Boolean(health.webReady),
      usesDevServer: Boolean(health.usesDevServer),
      url: health.url,
    },
    target: {
      series: series ? { id: series.id, title: series.title } : null,
      article: article ? { id: article.id, title: article.title } : null,
    },
    pages,
    issues,
    screenshots,
    outputDir: config.outputDir,
    finishedAt: new Date().toISOString(),
  };
  await writeFile(
    path.join(config.outputDir, 'result.json'),
    JSON.stringify(result, null, 2),
  );
  console.log(JSON.stringify(summaryFor(result), null, 2));
  if (!result.ok) {
    process.exitCode = 1;
  }
}

async function auditRoute({ name, route, expectText, settleMs = 1000 }) {
  await request('/navigate', { path: route });
  await wait(settleMs);
  const snapshot = await waitFor(
    async () => {
      const current = await request('/snapshot');
      if (expectText && !String(current.visibleText || '').includes(expectText)) {
        return null;
      }
      return current;
    },
    { label: `${name} snapshot`, timeoutMs: 60000, intervalMs: 1000 },
  );
  return recordPage(name, snapshot);
}

async function cleanupRoute() {
  await request('/navigate', { path: '/' });
  await wait(500);
  const snapshot = await request('/snapshot');
  assert(snapshot.hash === '#/', 'layout audit cleanup should return the app to the book library');
}

async function auditCreationTab(name, index, expectText) {
  const creationButtonIndex = Math.max(0, Math.min(index, 2));
  const click = await request('/click', { selector: '.mission-row.active .mission-actions .ghost-action', index: creationButtonIndex });
  assert(click.ok, `${name} creation action click should succeed: ${JSON.stringify(click)}`);
  await wait(1000);
  const snapshot = await waitFor(
    async () => {
      const current = await request('/snapshot');
      return String(current.visibleText || '').includes(expectText) ? current : null;
    },
    { label: `${name} snapshot`, timeoutMs: 30000, intervalMs: 1000 },
  );
  return recordPage(name, snapshot);
}

async function assertNoResourceLibraryTab(pageName) {
  const snapshot = await request('/snapshot');
  const text = String(snapshot.visibleText || '');
  assert(!text.includes('资源库'), `${pageName} should not expose a resource library tab`);
}

async function auditBookCardSwitch({ name, route, initialArticleTitle }) {
  await request('/navigate', { path: route });
  await wait(800);
  const click = await request('/click', { selector: '.book-card:not(.active)' });
  if (!click.ok) {
    return null;
  }
  await wait(800);
  const snapshot = await waitFor(
    async () => {
      const current = await request('/snapshot');
      const text = String(current.visibleText || '');
      return text.includes('章节列表') && !text.includes(initialArticleTitle) ? current : null;
    },
    { label: `${name} switched book`, timeoutMs: 30000, intervalMs: 1000 },
  );
  return recordPage(name, snapshot);
}

async function auditBookPlayerDrawer() {
  const click = await request('/click', { selector: '.chapter-drawer-trigger' });
  assert(click.ok, `chapter drawer trigger should succeed: ${JSON.stringify(click)}`);
  await wait(500);
  const snapshot = await waitFor(
    async () => {
      const current = await request('/snapshot');
      const text = String(current.visibleText || '');
      return text.includes('章节列表') && text.includes('书籍详情') ? current : null;
    },
    { label: 'book-player-chapters-drawer snapshot', timeoutMs: 30000, intervalMs: 1000 },
  );
  const result = await recordPage('book-player-chapters-drawer', snapshot);
  await request('/click', { selector: '.chapter-drawer-heading .icon-button' }).catch(() => undefined);
  return result;
}

async function recordPage(name, snapshot) {
  const significantOverflow = (snapshot.overflowElements ?? [])
    .filter(isSignificantOverflow)
    .map(summarizeOverflowElement);
  const brokenImages = (snapshot.brokenImages ?? []).slice(0, 8);
  const visibleText = String(snapshot.visibleText || '');
  const issues = [];
  if (brokenImages.length > 0) {
    issues.push({ type: 'broken-images', details: brokenImages });
  }
  if (significantOverflow.length > 0) {
    issues.push({ type: 'overflow', details: significantOverflow });
  }
  if (visibleText.includes('当前 Suno 自动风格')) {
    issues.push({ type: 'unexpected-copy', details: '当前 Suno 自动风格' });
  }
  if (visibleText.includes('选择本地歌曲')) {
    issues.push({ type: 'unexpected-copy', details: '选择本地歌曲' });
  }
  if (visibleText.includes('去创作中心生成')) {
    issues.push({ type: 'unexpected-copy', details: '去创作中心生成' });
  }
  if (config.screenshots) {
    screenshots.push(await saveScreenshot(name));
  }
  const page = {
    name,
    hash: snapshot.hash,
    visibleTextLength: String(snapshot.visibleText || '').length,
    imageCount: (snapshot.images ?? []).length,
    brokenImageCount: brokenImages.length,
    overflowCount: significantOverflow.length,
    issues,
  };
  pages.push(page);
  return snapshot;
}

function validateBookDetailCover(snapshot, seriesTitle) {
  const candidates = (snapshot.images ?? [])
    .filter((image) => image.rect?.width >= 240 && image.rect?.height >= 120)
    .sort((left, right) => (right.rect.width * right.rect.height) - (left.rect.width * left.rect.height));
  const cover = candidates[0];
  const issues = [];
  if (!cover) {
    issues.push({
      type: 'book-cover',
      details: `No book detail cover candidate found for ${seriesTitle}`,
    });
  } else {
    const width = Number(cover.rect.width);
    const height = Number(cover.rect.height);
    const ratio = width / Math.max(1, height);
    if (width > 460 || height > 280 || ratio < 1.45 || ratio > 1.95) {
      issues.push({
        type: 'book-cover',
        details: {
          rect: cover.rect,
          naturalWidth: cover.naturalWidth,
          naturalHeight: cover.naturalHeight,
        },
      });
    }
  }
  if (issues.length > 0) {
    const page = pages.find((item) => item.name === 'book-detail');
    if (page) {
      page.issues.push(...issues);
      page.overflowCount += issues.length;
    }
  }
}

function isSignificantOverflow(element) {
  const clientWidth = Number(element.clientWidth ?? 0);
  const scrollWidth = Number(element.scrollWidth ?? 0);
  const clientHeight = Number(element.clientHeight ?? 0);
  const scrollHeight = Number(element.scrollHeight ?? 0);
  const horizontal = scrollWidth > clientWidth + 2;
  const vertical = scrollHeight > clientHeight + 16;
  return horizontal || vertical;
}

function summarizeOverflowElement(element) {
  return {
    tag: element.tag,
    className: element.className,
    text: String(element.text || '').slice(0, 180),
    clientWidth: element.clientWidth,
    scrollWidth: element.scrollWidth,
    clientHeight: element.clientHeight,
    scrollHeight: element.scrollHeight,
    rect: element.rect,
  };
}

function pickAuditTargets(library) {
  const articles = library.articles ?? library.payload?.articles ?? [];
  const allSeries = library.series ?? library.payload?.series ?? [];
  const seriesWithChapters = allSeries
    .map((item) => ({
      ...item,
      articles: articles.filter((article) => Number(article.seriesId) === Number(item.id)),
    }))
    .filter((item) => item.articles.length > 0);
  const alice = seriesWithChapters.find((item) =>
    String(item.title || '').toLowerCase().includes("alice's adventures"),
  );
  const series = alice ?? seriesWithChapters[0] ?? null;
  const article = series?.articles?.[0] ?? articles.find((item) => item.id != null) ?? null;
  return { series, article };
}

async function saveScreenshot(name) {
  const response = await fetch(`${config.baseUrl}/screenshot`, {
    headers: authHeaders(),
  });
  if (!response.ok) {
    throw new Error(`GET /screenshot failed: ${response.status} ${await response.text()}`);
  }
  const file = path.join(config.screenshotDir, `${name}.png`);
  await writeFile(file, Buffer.from(await response.arrayBuffer()));
  return file;
}

async function waitForHealth() {
  const health = await waitFor(
    async () => {
      try {
        const current = await request('/health');
        return current.ok && current.webReady ? current : null;
      } catch {
        return null;
      }
    },
    { label: 'QA health', timeoutMs: 60000, intervalMs: 1000 },
  );
  assert(health.usesDevServer === false, 'layout audit should use built web assets');
  return health;
}

async function bridge(type, payload) {
  return request('/bridge', { type, payload });
}

async function request(route, body) {
  const response = await fetch(`${config.baseUrl}${route}`, {
    method: body ? 'POST' : 'GET',
    headers: body
      ? { 'Content-Type': 'application/json', ...authHeaders() }
      : authHeaders(),
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  let payload;
  try {
    payload = JSON.parse(text);
  } catch {
    payload = text;
  }
  if (!response.ok) {
    throw new Error(`${route} failed: ${response.status} ${text}`);
  }
  return payload;
}

async function waitFor(check, { label, timeoutMs, intervalMs }) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const result = await check();
      if (result) return result;
    } catch (error) {
      lastError = error;
    }
    await wait(intervalMs);
  }
  throw new Error(
    `Timed out waiting for ${label}${lastError ? `: ${lastError.message}` : ''}`,
  );
}

function summaryFor(result) {
  return {
    ok: result.ok,
    target: result.target,
    pageCount: result.pages.length,
    issueCount: result.issues.length,
    issues: result.issues,
    screenshots: result.screenshots,
    resultPath: path.join(config.outputDir, 'result.json'),
  };
}

function authHeaders() {
  return config.token ? { 'X-Tomato-QA-Token': config.token } : {};
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function parseArgs(args) {
  const parsed = {
    baseUrl: 'http://127.0.0.1:39317',
    token: '',
    outputDir: path.resolve('.tmp', 'qa-layout-audit'),
    screenshotDir: path.resolve('.tmp', 'qa-layout-audit', 'screenshots'),
    screenshots: true,
    includeFollowPage: false,
    includeChatPage: false,
  };
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--base-url') {
      parsed.baseUrl = args[++index];
    } else if (arg === '--port') {
      parsed.baseUrl = `http://127.0.0.1:${args[++index]}`;
    } else if (arg === '--token') {
      parsed.token = args[++index];
    } else if (arg === '--output-dir') {
      parsed.outputDir = path.resolve(args[++index]);
      parsed.screenshotDir = path.join(parsed.outputDir, 'screenshots');
    } else if (arg === '--screenshot-dir') {
      parsed.screenshotDir = path.resolve(args[++index]);
    } else if (arg === '--no-screenshots') {
      parsed.screenshots = false;
    } else if (arg === '--include-practice-pages') {
      parsed.includeFollowPage = true;
      parsed.includeChatPage = true;
    } else if (arg === '--include-follow-page') {
      parsed.includeFollowPage = true;
    } else if (arg === '--include-chat-page') {
      parsed.includeChatPage = true;
    } else if (arg === '--help') {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return parsed;
}

function printHelp() {
  console.log(`Usage: node tools/qa_layout_audit.mjs [options]

Options:
  --base-url <url>             QA server base URL, default http://127.0.0.1:39317
  --port <port>                Shortcut for --base-url http://127.0.0.1:<port>
  --token <token>              TOMATO_QA_TOKEN value, if enabled
  --output-dir <path>          Result directory, default .tmp/qa-layout-audit
  --screenshot-dir <path>      Screenshot output directory
  --no-screenshots             Skip /screenshot captures
  --include-chat-page          Also open the chat page without sending messages
  --include-follow-page        Also open the follow page, which may trigger audio services
  --include-practice-pages     Open both follow and chat pages
`);
}

main().catch(async (error) => {
  const failure = {
    ok: false,
    error: error.stack || error.message,
    pages,
    screenshots,
    finishedAt: new Date().toISOString(),
  };
  await mkdir(config.outputDir, { recursive: true });
  await writeFile(
    path.join(config.outputDir, 'result.json'),
    JSON.stringify(failure, null, 2),
  );
  console.error(error.stack || error.message);
  process.exit(1);
});
