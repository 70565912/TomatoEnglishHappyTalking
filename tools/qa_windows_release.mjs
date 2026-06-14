import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

const config = parseArgs(process.argv.slice(2));
const oldAssetPattern =
  /monster-buddy|monster-mic|reward-star|reward-brick|lego\/prop-|tomato-(wave|headphones|pencil|secure|celebrate)/i;
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const qaStamp = Date.now();
const qaTitle = `QA Chapter ${qaStamp}`;
const qaSeriesTitle = `QA Book ${qaStamp}`;
const qaContent =
  'Tom opens a bright picture book. He listens to every chapter in order.';
const screenshots = [];
let createdArticleId = null;
let createdSeriesId = null;

async function main() {
  await waitForHealth();

  const home = await visit('/', 'home');
  assertCleanSnapshot(home, 'home');
  expectText(home, '书库、绘本和章节听力工作台', 'home hero headline');
  expectText(home, '我的书籍', 'book library heading');
  expectText(home, '新增章节', 'new chapter navigation');
  expectText(home, '创作中心', 'creation center navigation');
  expectText(home, '练习中心', 'practice center navigation');
  assertNoText(home, '今天也要快乐开口说英语！', 'home should not use the old game hero');

  const articleEmpty = await visit('/article/new', 'article-empty');
  assertCleanSnapshot(articleEmpty, 'article-empty');
  expectText(articleEmpty, '新增文章', 'new article heading');
  expectText(articleEmpty, '保存后会按本章分镜异步生成连续绘本图。', 'picture-book generation note');
  assert(findButton(articleEmpty, '保存章节')?.disabled === true, 'new chapter save should start disabled');
  assertNoText(articleEmpty, '保存任务', 'new article page should not show old task language');

  await fill('#series-select', 'new');
  await waitFor(
    async () => {
      const current = await snapshot();
      return current.formControls?.some(
        (control) => control.placeholder === '例如 The Secret Garden',
      )
        ? current
        : null;
    },
    { label: 'new series input', timeoutMs: 10000 },
  );
  await fill('[aria-label="新书籍名称"]', qaSeriesTitle);
  await fill('#article-title', qaTitle);
  await fill('#article-content', qaContent);
  await wait(500);
  const articleFilled = await snapshot();
  assertCleanSnapshot(articleFilled, 'article-filled');
  assert(findButton(articleFilled, '保存章节')?.disabled === false, 'save should enable after content');
  expectText(articleFilled, '句子预览（本地分句）', 'sentence preview heading');
  expectText(articleFilled, 'Tom opens a bright picture book.', 'first preview chunk');
  expectText(articleFilled, 'He listens to every chapter in order.', 'second preview chunk');
  await capture('article-filled');

  await click('保存章节');
  let lastCreatedCandidate = null;
  const qaArticle = await waitFor(
    async () => {
      const library = await listLibrary();
      const articles = library.articles;
      lastCreatedCandidate = articles.find((article) => article.title === qaTitle) ?? null;
      if (lastCreatedCandidate) {
        createdArticleId = lastCreatedCandidate.id;
        createdSeriesId = lastCreatedCandidate.seriesId;
      }
      return lastCreatedCandidate?.seriesTitle === qaSeriesTitle &&
        Number(lastCreatedCandidate.seriesId) > 0
        ? lastCreatedCandidate
        : null;
    },
    { label: 'created chapter attached to QA book in article.list', timeoutMs: 120000, intervalMs: 1500 },
  );
  createdArticleId = qaArticle.id;
  createdSeriesId = qaArticle.seriesId;
  assert(qaArticle.sentenceCount === 2, 'created chapter should use short reading chunks');
  assert(
    qaArticle.seriesTitle === qaSeriesTitle,
    `created chapter should attach to the QA book: ${JSON.stringify(lastCreatedCandidate)}`,
  );

  const bookDetail = await openBookDetail();
  assertCleanSnapshot(bookDetail, 'book-detail');
  expectText(bookDetail, qaSeriesTitle, 'book detail title');
  expectText(bookDetail, qaTitle, 'book detail chapter title');
  expectText(bookDetail, '章节目录', 'book detail chapter list');
  expectText(bookDetail, '连续听力', 'book detail listening action');
  expectText(bookDetail, '歌曲模式', 'book detail song action');
  expectText(bookDetail, '练习章节', 'book detail practice action');
  assertNoText(bookDetail, '任务卡', 'book detail should not use old task wording');

  const listeningPlayer = await openBookPlayer('listening');
  assertCleanSnapshot(listeningPlayer, 'book-player-listening');
  expectText(listeningPlayer, qaSeriesTitle, 'book player book title');
  expectText(listeningPlayer, qaTitle, 'book player chapter title');
  expectText(listeningPlayer, '听力', 'listening tab');
  expectText(listeningPlayer, '歌曲', 'song tab');
  expectText(listeningPlayer, '重听本句', 'listening replay control');
  expectText(listeningPlayer, '全屏播放', 'listening fullscreen control');
  assertNoText(listeningPlayer, '生成 Suno 歌曲', 'listening mode should not expose creation controls');
  assertNoText(listeningPlayer, '导出听力视频', 'listening mode should not expose video export');

  const songPlayer = await openBookPlayer('song');
  assertCleanSnapshot(songPlayer, 'book-player-song');
  expectText(songPlayer, '歌曲列表', 'song mode local song selector');
  expectText(songPlayer, '开始播放', 'song mode start playback');
  expectText(songPlayer, '创作中心', 'song mode creation handoff');
  assertNoText(songPlayer, '选择本地歌曲', 'song mode should not expose old local-song selector');
  assertNoText(songPlayer, '去创作中心生成', 'song mode should not expose old creation handoff');
  assertNoText(songPlayer, '重听本句', 'song mode should not expose TTS replay');
  assertNoText(songPlayer, '全屏播放', 'song mode should not expose listening fullscreen');

  const creationPicture = await visit(
    `/creation?seriesId=${createdSeriesId}&articleId=${createdArticleId}`,
    'creation-picture',
  );
  assertCleanSnapshot(creationPicture, 'creation-picture');
  expectText(creationPicture, '创作中心', 'creation heading');
  expectText(creationPicture, '我的书籍', 'creation book selector heading');
  expectText(creationPicture, qaSeriesTitle, 'creation selected book');
  expectText(creationPicture, qaTitle, 'creation selected chapter');
  expectText(creationPicture, '创作面板', 'creation workspace heading');
  expectText(creationPicture, '绘本组图', 'picture creation panel');
  expectText(creationPicture, '绘本生成使用整章连续分镜组图', 'picture creation note');
  expectText(creationPicture, '章节正文', 'picture panel chapter resource row');
  expectText(creationPicture, '绘本图片', 'picture panel image resource row');
  assertNoText(creationPicture, '资源库', 'creation center should not show a resource library tab');
  assertNoText(creationPicture, '重听本句', 'creation center should not show listening controls');

  await clickBySelector('.creation-tabs button', 1);
  await waitFor(
    async () => {
      const current = await snapshot();
      return current.visibleText?.includes('Suno 歌曲') ? current : null;
    },
    { label: 'song creation tab', timeoutMs: 15000 },
  );
  const creationSong = await snapshot();
  assertCleanSnapshot(creationSong, 'creation-song');
  expectText(creationSong, '歌曲生成只保留 Suno 网页自动化', 'Suno-only song creation note');
  expectText(creationSong, '生成 Suno 歌曲', 'Suno generate action');
  expectText(creationSong, 'Suno 音频', 'song panel Suno asset row');
  expectText(creationSong, '本地歌曲版本', 'song panel local versions row');
  assertNoText(creationSong, 'MiniMax API', 'MiniMax settings should not be visible in song creation');

  await clickBySelector('.creation-tabs button', 2);
  await waitFor(
    async () => {
      const current = await snapshot();
      return current.visibleText?.includes('视频导出') ? current : null;
    },
    { label: 'video creation tab', timeoutMs: 15000 },
  );
  const creationVideo = await snapshot();
  assertCleanSnapshot(creationVideo, 'creation-video');
  expectText(creationVideo, '视频导出', 'video export panel');
  expectText(creationVideo, '导出听力视频', 'listening video export action');
  expectText(creationVideo, '听力视频', 'video panel export resource row');
  expectText(creationVideo, '素材来源', 'video panel source resource row');
  assertNoText(creationVideo, '播放原音', 'creation video tab should not show follow-read controls');

  const practice = await visit(`/practice?seriesId=${createdSeriesId}`, 'practice');
  assertCleanSnapshot(practice, 'practice');
  expectText(practice, '练习中心', 'practice heading');
  expectText(practice, qaSeriesTitle, 'practice selected book');
  expectText(practice, qaTitle, 'practice chapter');
  expectText(practice, '跟读', 'practice follow action');
  expectText(practice, '对话', 'practice chat action');
  assertNoText(practice, '连续听力', 'practice center should not show listening player actions');

  const settings = await visit('/settings', 'settings');
  assertCleanSnapshot(settings, 'settings');
  expectText(settings, '可选声音', 'voice list heading');
  expectText(settings, 'Suno 输出目录', 'Suno output setting');
  expectText(settings, 'Suno 生成超时（分钟）', 'Suno timeout setting');
  assertNoText(settings, 'MiniMax API', 'settings should not expose MiniMax API fields');

  await cleanup();
  const finalSnapshot = await snapshot();

  console.log(
    JSON.stringify(
      {
        ok: true,
        baseUrl: config.baseUrl,
        finalHash: finalSnapshot.hash,
        createdArticleId,
        createdSeriesId,
        screenshots,
        checks: [
          'health',
          'book library shell',
          'new chapter form',
          'book attachment',
          'book detail actions',
          'book player listening mode',
          'book player song mode',
          'creation center picture/song/video panels',
          'practice center isolation',
          'Suno-only settings',
          'cleanup',
        ],
      },
      null,
      2,
    ),
  );
}

async function openBookPlayer(mode) {
  await request('/navigate', {
    path: `/books/${createdSeriesId}/player?articleId=${createdArticleId}&mode=${mode}`,
  });
  return waitFor(
    async () => {
      const current = await snapshot();
      if (
        current.hash ===
          `#/books/${createdSeriesId}/player?articleId=${createdArticleId}&mode=${mode}` &&
        current.visibleText?.includes(qaTitle) &&
        current.visibleText?.includes(mode === 'song' ? '歌曲列表' : '重听本句')
      ) {
        await capture(`book-player-${mode}`);
        return current;
      }
      return null;
    },
    { label: `book player ${mode}`, timeoutMs: 60000, intervalMs: 1000 },
  );
}

async function openBookDetail() {
  await request('/navigate', { path: `/books/${createdSeriesId}` });
  return waitFor(
    async () => {
      const current = await snapshot();
      if (
        current.hash === `#/books/${createdSeriesId}` &&
        current.visibleText?.includes(qaSeriesTitle) &&
        current.visibleText?.includes(qaTitle)
      ) {
        await capture('book-detail');
        return current;
      }
      return null;
    },
    { label: 'book detail for created QA book', timeoutMs: 60000, intervalMs: 1000 },
  );
}

async function visit(route, name, options = {}) {
  if (options.navigate !== false) {
    await request('/navigate', { path: route });
    await wait(900);
  }
  const current = await snapshot();
  if (options.screenshot !== false) {
    await capture(name);
  }
  return current;
}

async function capture(name) {
  if (config.screenshots) {
    screenshots.push(await saveScreenshot(name));
  }
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
  assert(health.usesDevServer === false, 'QA should be checking built web assets, not dev server');
}

async function cleanup() {
  const library = await listLibrary();
  const articles = library.articles;
  const targets = articles.filter((article) => article.title === qaTitle);
  for (const article of targets) {
    await request('/bridge', {
      type: 'article.delete',
      payload: { articleId: article.id },
    });
  }
  if (createdSeriesId != null) {
    const remaining = await listArticles();
    const hasSeriesChapters = remaining.some(
      (article) => Number(article.seriesId) === Number(createdSeriesId),
    );
    if (!hasSeriesChapters) {
      try {
        await request('/bridge', {
          type: 'series.delete',
          payload: { seriesId: createdSeriesId },
        });
      } catch {
        // The series may already have been removed by app cleanup or contain user data.
      }
    }
  }
  let remainingLibrary = await listLibrary();
  for (const series of remainingLibrary.series.filter((item) =>
    String(item.title || '').startsWith('QA Book '),
  )) {
    const hasChapters = remainingLibrary.articles.some(
      (article) => Number(article.seriesId) === Number(series.id),
    );
    if (!hasChapters) {
      try {
        await request('/bridge', {
          type: 'series.delete',
          payload: { seriesId: series.id },
        });
        remainingLibrary = await listLibrary();
      } catch {
        // Ignore non-empty or already removed QA books.
      }
    }
  }
  const remaining = remainingLibrary.articles;
  assert(
    remaining.every((article) => article.title !== qaTitle),
    'QA chapter should be deleted after the run',
  );
  await request('/navigate', { path: '/' });
  await wait(500);
  const home = await snapshot();
  assert(home.hash === '#/', 'QA cleanup should return the app to the book library');
  assert(
    typeof home.visibleText === 'string' && !home.visibleText.includes(qaTitle),
    'QA cleanup should leave no test chapter visible on home',
  );
}

async function listArticles() {
  return (await listLibrary()).articles;
}

async function listLibrary() {
  const response = await request('/bridge', {
    type: 'article.list',
    payload: {},
  });
  return {
    articles: response.articles ?? response.payload?.articles ?? [],
    series: response.series ?? response.payload?.series ?? [],
  };
}

async function snapshot() {
  return request('/snapshot');
}

async function click(text) {
  const result = await request('/click', { text });
  assert(result.ok, `click "${text}" should succeed: ${JSON.stringify(result)}`);
  return result;
}

async function clickBySelector(selector, index = 0) {
  const result = await request('/click', { selector, index });
  assert(
    result.ok,
    `click selector "${selector}" should succeed: ${JSON.stringify(result)}`,
  );
  return result;
}

async function fill(selector, value) {
  const result = await request('/fill', { selector, value });
  assert(result.ok, `fill "${selector}" should succeed: ${JSON.stringify(result)}`);
  return result;
}

async function saveScreenshot(name) {
  await mkdir(config.screenshotDir, { recursive: true });
  const response = await fetch(`${config.baseUrl}/screenshot`, {
    headers: authHeaders(),
  });
  if (!response.ok) {
    throw new Error(`GET /screenshot failed: ${response.status} ${await response.text()}`);
  }
  const bytes = Buffer.from(await response.arrayBuffer());
  const file = path.join(config.screenshotDir, `${name}.png`);
  await writeFile(file, bytes);
  return file;
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

function authHeaders() {
  return config.token ? { 'X-Tomato-QA-Token': config.token } : {};
}

async function waitFor(check, { label, timeoutMs, intervalMs = 500 }) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const current = await check();
      if (current) return current;
    } catch (error) {
      lastError = error;
    }
    await wait(intervalMs);
  }
  throw new Error(
    `Timed out waiting for ${label}${lastError ? `: ${lastError.message}` : ''}`,
  );
}

function assertCleanSnapshot(current, label) {
  const overflowElements = (current.overflowElements ?? []).filter((element) => {
    const horizontal = Number(element.scrollWidth) > Number(element.clientWidth) + 1;
    const vertical = Number(element.scrollHeight) > Number(element.clientHeight) + 12;
    return horizontal || vertical;
  });
  assert(
    current.brokenImages?.length === 0,
    `${label} should have no broken images: ${JSON.stringify((current.brokenImages ?? []).slice(0, 5))}`,
  );
  assert(
    overflowElements.length === 0,
    `${label} should have no visible overflow: ${JSON.stringify(overflowElements.slice(0, 5))}`,
  );
  const oldAssets = (current.images ?? [])
    .map((image) => image.src ?? '')
    .filter((source) => oldAssetPattern.test(source));
  assert(oldAssets.length === 0, `${label} should not render old assets: ${oldAssets.join(', ')}`);
}

function expectText(current, text, label) {
  assert(
    typeof current.visibleText === 'string' && current.visibleText.includes(text),
    `${label} should include "${text}"`,
  );
}

function assertNoText(current, text, label) {
  assert(
    typeof current.visibleText === 'string' && !current.visibleText.includes(text),
    `${label} should not include "${text}"`,
  );
}

function findButton(current, text) {
  return current.buttons?.find((button) => button.text.includes(text));
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
    screenshots: true,
    screenshotDir: path.resolve('.tmp', 'qa-windows'),
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--base-url') {
      parsed.baseUrl = args[++index];
    } else if (arg === '--port') {
      parsed.baseUrl = `http://127.0.0.1:${args[++index]}`;
    } else if (arg === '--token') {
      parsed.token = args[++index];
    } else if (arg === '--no-screenshots') {
      parsed.screenshots = false;
    } else if (arg === '--screenshot-dir') {
      parsed.screenshotDir = path.resolve(args[++index]);
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
  console.log(`Usage: node tools/qa_windows_release.mjs [options]

Options:
  --base-url <url>          QA server base URL, default http://127.0.0.1:39317
  --port <port>             Shortcut for --base-url http://127.0.0.1:<port>
  --token <token>           TOMATO_QA_TOKEN value, if enabled
  --no-screenshots          Skip screenshot files
  --screenshot-dir <path>   Screenshot output directory, default .tmp/qa-windows
`);
}

main().catch(async (error) => {
  try {
    if (createdArticleId !== null) {
      await cleanup();
    }
  } catch (cleanupError) {
    console.error(`Cleanup failed: ${cleanupError.message}`);
  }
  console.error(error.stack || error.message);
  process.exit(1);
});
