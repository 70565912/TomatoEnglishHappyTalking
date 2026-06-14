import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';

const config = parseArgs(process.argv.slice(2));
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const screenshots = [];

async function main() {
  await mkdir(config.outputDir, { recursive: true });
  await waitForHealth();

  const rawText = await readFile(config.textPath, 'utf8');
  const textHash = createHash('sha256').update(rawText).digest('hex');
  const beforeArticles = await listArticles();
  let aliceSeries = null;
  let article = null;

  if (config.articleId != null) {
    article = await findArticleById(config.articleId);
    aliceSeries = {
      id: article.seriesId,
      title: article.seriesTitle || config.seriesTitle,
      created: false,
      reusedArticle: true,
    };
  } else {
    const beforeIds = new Set(beforeArticles.map((item) => item.id));
    aliceSeries = await ensureArticleFormAndSeries();

    await fill('#article-title', config.title);
    await fill('#article-content', rawText);
    await capture('article-filled');
    await click('保存章节');

    article = await waitFor(
      async () => {
        const articles = await listArticles();
        const candidates = articles
          .filter((item) => item.title === config.title && !beforeIds.has(item.id))
          .sort((left, right) => Number(right.id) - Number(left.id));
        return candidates[0] ?? null;
      },
      { label: 'new article in article.list', timeoutMs: 120000, intervalMs: 1500 },
    );

    await waitFor(
      async () => {
        const current = await snapshot();
        return current.hash === '#/' && current.visibleText?.includes(config.title)
          ? current
          : null;
      },
      { label: 'save completion on home page', timeoutMs: 120000, intervalMs: 1500 },
    );
  }

  await openListeningPage(article.id);
  await capture('listening-open');

  const loadingSnapshot = await waitForLoadingPlaceholder(article.id);
  const terminalPicture = await waitForPictureBookTerminal(article.id);
  const afterTerminalSnapshot = await waitForPictureSceneSettled(
    terminalPicture.status,
  );
  await capture(`picture-${terminalPicture.status}`);

  const translationSnapshot = await waitFor(
    async () => {
      const current = await snapshot();
      const chinese = current.pictureBookScene?.subtitles?.chinese ?? '';
      return chinese.trim() ? current : null;
    },
    {
      label: 'first listening Chinese subtitle',
      timeoutMs: config.translationTimeoutMs,
      intervalMs: 2000,
      optional: true,
    },
  );

  const playbackResult = await playCurrentSentence();
  await clickBySelector('.listening-row', 5);
  await waitFor(
    async () => {
      const current = await snapshot();
      return current.pictureBookScene?.badgeText === '2' ? current : null;
    },
    { label: 'sentence 6 mapped to picture page 2', timeoutMs: 30000, intervalMs: 1000 },
  );
  const sentenceSixSnapshot = await snapshot();
  await capture('listening-sentence-6');

  const result = {
    ok: terminalPicture.status === 'ready',
    baseUrl: config.baseUrl,
    textPath: config.textPath,
    textHash,
    title: config.title,
    articleId: article.id,
    series: aliceSeries,
    sentenceCount: article.sentenceCount,
    pictureBook: terminalPicture,
    loadingSeen: Boolean(loadingSnapshot),
    loadingScene: summarizeScene(loadingSnapshot?.pictureBookScene),
    terminalScene: summarizeScene(afterTerminalSnapshot?.pictureBookScene),
    translation: {
      seen: Boolean(translationSnapshot),
      firstChinese:
        translationSnapshot?.pictureBookScene?.subtitles?.chinese?.trim() ?? '',
    },
    playback: playbackResult,
    sentenceSixScene: summarizeScene(sentenceSixSnapshot.pictureBookScene),
    screenshots,
    outputDir: config.outputDir,
    finishedAt: new Date().toISOString(),
  };

  await writeResult(result);
  console.log(JSON.stringify(resultSummary(result), null, 2));

  if (config.cleanup) {
    await bridge('article.delete', { articleId: article.id });
  }

  if (terminalPicture.status !== 'ready') {
    process.exitCode = 2;
  }
}

async function ensureArticleFormAndSeries() {
  await navigate('/article/new');
  await waitFor(
    async () => {
      const current = await snapshot();
      return current.hash === '#/article/new' &&
        current.formControls?.some((control) => control.placeholder === '不填则自动生成短标题')
        ? current
        : null;
    },
    { label: 'new article form', timeoutMs: 60000, intervalMs: 1000 },
  );

  const seriesPayload = await bridge('series.list', {});
  const series = seriesPayload.series ?? [];
  const existing = series.find(
    (item) => String(item.title || '').trim().toLowerCase() ===
      config.seriesTitle.toLowerCase(),
  );
  if (existing?.id != null) {
    await fill('#series-select', String(existing.id));
    return { id: existing.id, title: existing.title, created: false };
  }

  await fill('#series-select', 'new');
  await fill('[aria-label="新书籍名称"]', config.seriesTitle);
  return { id: null, title: config.seriesTitle, created: true };
}

async function findArticleById(articleId) {
  const articles = await listArticles();
  const article = articles.find((item) => Number(item.id) === Number(articleId));
  assert(article, `article ${articleId} should exist`);
  return article;
}

async function openListeningPage(articleId) {
  const deadline = Date.now() + 120000;
  let attempt = 0;
  while (Date.now() < deadline) {
    attempt += 1;
    await navigate(`/listen/${articleId}`);
    const current = await waitFor(
      async () => {
        const page = await snapshot();
        return page.hash === `#/listen/${articleId}` &&
          page.visibleText?.includes(config.firstSentenceNeedle)
          ? page
          : null;
      },
      {
        label: `listening page first sentence attempt ${attempt}`,
        timeoutMs: 10000,
        intervalMs: 1000,
        optional: true,
      },
    );
    if (current) return current;
  }
  throw new Error(`Timed out opening listening page for article ${articleId}`);
}

async function waitForLoadingPlaceholder(articleId) {
  return waitFor(
    async () => {
      const current = await snapshot();
      const scene = current.pictureBookScene;
      const runtime = current.runtimeState?.pictureBook;
      if (scene?.busy || scene?.placeholderText === '绘本图正在生成中...') {
        return current;
      }
      if (runtime?.articleId === articleId && runtime.status === 'generating') {
        return current;
      }
      return null;
    },
    {
      label: 'picture-book loading placeholder',
      timeoutMs: 180000,
      intervalMs: 2000,
      optional: true,
    },
  );
}

async function waitForPictureBookTerminal(articleId) {
  const startedAt = Date.now();
  let last = null;
  while (Date.now() - startedAt < config.pictureTimeoutMs) {
    const current = await health();
    const pictureBook = current.runtimeState?.pictureBook;
    if (pictureBook?.articleId === articleId) {
      last = pictureBook;
      if (['ready', 'partial', 'skipped', 'error'].includes(pictureBook.status)) {
        return decoratePictureSummary(pictureBook);
      }
    }
    await wait(config.picturePollMs);
  }
  return decoratePictureSummary({
    ...(last ?? { articleId, pageCount: 0, statusCounts: {} }),
    status: 'timeout',
  });
}

async function waitForPictureSceneSettled(status) {
  return waitFor(
    async () => {
      const current = await snapshot();
      const scene = current.pictureBookScene;
      if (!scene) return null;
      if (status === 'ready' && scene.ready && scene.image?.naturalWidth > 0) {
        return current;
      }
      if (status === 'error' && scene.failed && scene.hasRetry) {
        return current;
      }
      if (status === 'skipped' && scene.failed && scene.hasRetry) {
        return current;
      }
      if (status === 'partial' && (scene.ready || scene.failed)) {
        return current;
      }
      if (status === 'timeout') {
        return current;
      }
      return null;
    },
    {
      label: `picture-book scene settled (${status})`,
      timeoutMs: 60000,
      intervalMs: 2000,
      optional: true,
    },
  );
}

async function playCurrentSentence() {
  const before = await snapshot();
  await click('重听本句');
  const playing = await waitFor(
    async () => {
      const current = await snapshot();
      return findButton(current, '停止') ? current : null;
    },
    {
      label: 'listening playback started',
      timeoutMs: 12000,
      intervalMs: 500,
      optional: true,
    },
  );
  const finished = await waitFor(
    async () => {
      const current = await snapshot();
      return !findButton(current, '停止') && findButton(current, '重听本句')
        ? current
        : null;
    },
    {
      label: 'listening playback finished',
      timeoutMs: 45000,
      intervalMs: 1000,
      optional: true,
    },
  );
  return {
    clicked: true,
    started: Boolean(playing),
    finished: Boolean(finished),
    beforeScene: summarizeScene(before.pictureBookScene),
    afterScene: summarizeScene(finished?.pictureBookScene),
  };
}

function decoratePictureSummary(pictureBook) {
  const ranges = pictureBook.ranges ?? [];
  return {
    articleId: pictureBook.articleId,
    status: pictureBook.status,
    pageCount: pictureBook.pageCount ?? ranges.length,
    statusCounts: pictureBook.statusCounts ?? {},
    readyPageCount: ranges.filter((page) => page.status === 'ready').length,
    errorPageCount: ranges.filter((page) => page.status === 'error').length,
    skippedPageCount: ranges.filter((page) => page.status === 'skipped').length,
    ranges,
    imagePaths: ranges
      .map((page) => page.imagePath)
      .filter((value) => typeof value === 'string' && value.trim()),
    missingImagePaths: ranges
      .filter((page) => page.status === 'ready' && !existsSync(page.imagePath || ''))
      .map((page) => page.imagePath || `page:${page.pageIndex}`),
    firstError:
      ranges.find((page) => String(page.errorMessage || '').trim())?.errorMessage ??
      '',
  };
}

function summarizeScene(scene) {
  if (!scene) return null;
  return {
    ready: scene.ready,
    busy: scene.busy,
    failed: scene.failed,
    placeholderText: scene.placeholderText,
    hasRetry: scene.hasRetry,
    retryText: scene.retryText,
    badgeText: scene.badgeText,
    imageNaturalWidth: scene.image?.naturalWidth ?? 0,
    imageNaturalHeight: scene.image?.naturalHeight ?? 0,
    english: scene.subtitles?.english ?? '',
    chinese: scene.subtitles?.chinese ?? '',
  };
}

function resultSummary(result) {
  return {
    ok: result.ok,
    articleId: result.articleId,
    series: result.series,
    sentenceCount: result.sentenceCount,
    pictureStatus: result.pictureBook.status,
    pageCount: result.pictureBook.pageCount,
    readyPageCount: result.pictureBook.readyPageCount,
    errorPageCount: result.pictureBook.errorPageCount,
    loadingSeen: result.loadingSeen,
    retrySeen: Boolean(result.terminalScene?.hasRetry),
    firstError: result.pictureBook.firstError,
    firstChinese: result.translation.firstChinese,
    playback: {
      started: result.playback.started,
      finished: result.playback.finished,
    },
    sentenceSixBadge: result.sentenceSixScene?.badgeText,
    resultPath: path.join(config.outputDir, 'result.json'),
  };
}

async function writeResult(result) {
  await writeFile(
    path.join(config.outputDir, 'result.json'),
    JSON.stringify(result, null, 2),
  );
}

async function listArticles() {
  const response = await bridge('article.list', {});
  return response.articles ?? response.payload?.articles ?? [];
}

async function bridge(type, payload) {
  return request('/bridge', { type, payload });
}

async function navigate(route) {
  await request('/navigate', { path: route });
  await wait(800);
}

async function snapshot() {
  return request('/snapshot');
}

async function health() {
  return request('/health');
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

async function capture(name) {
  if (!config.screenshots) return null;
  await mkdir(config.screenshotDir, { recursive: true });
  const response = await fetch(`${config.baseUrl}/screenshot`, {
    headers: authHeaders(),
  });
  if (!response.ok) {
    screenshots.push({ name, error: `${response.status} ${await response.text()}` });
    return null;
  }
  const bytes = Buffer.from(await response.arrayBuffer());
  const file = path.join(config.screenshotDir, `${name}.png`);
  await writeFile(file, bytes);
  screenshots.push(file);
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

async function waitForHealth() {
  await waitFor(
    async () => {
      try {
        const current = await health();
        return current.ok && current.webReady ? current : null;
      } catch {
        return null;
      }
    },
    { label: 'QA health', timeoutMs: 60000, intervalMs: 1000 },
  );
}

async function waitFor(check, options) {
  const {
    label,
    timeoutMs,
    intervalMs = 1000,
    optional = false,
  } = options;
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
  if (optional) return null;
  throw new Error(
    `Timed out waiting for ${label}${lastError ? `: ${lastError.message}` : ''}`,
  );
}

function findButton(current, text) {
  return current.buttons?.find((button) => String(button.text || '').includes(text));
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
    textPath:
      'C:\\Users\\Ryan\\.codex\\attachments\\4e679701-4b06-422c-a2c9-8b14ff7e7668\\pasted-text.txt',
    title: "E27 - The Queen's Croquet-Ground",
    seriesTitle: "Alice's Adventures in Wonderland",
    firstSentenceNeedle: `"It's—it's a very fine day!"`,
    outputDir: path.resolve('.tmp', 'qa-picture-book-live'),
    screenshotDir: path.resolve('.tmp', 'qa-picture-book-live', 'screenshots'),
    screenshots: true,
    cleanup: false,
    articleId: null,
    pictureTimeoutMs: 50 * 60 * 1000,
    picturePollMs: 15000,
    translationTimeoutMs: 180000,
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--base-url') {
      parsed.baseUrl = args[++index];
    } else if (arg === '--port') {
      parsed.baseUrl = `http://127.0.0.1:${args[++index]}`;
    } else if (arg === '--token') {
      parsed.token = args[++index];
    } else if (arg === '--text') {
      parsed.textPath = path.resolve(args[++index]);
    } else if (arg === '--title') {
      parsed.title = args[++index];
    } else if (arg === '--article-id') {
      parsed.articleId = Number(args[++index]);
    } else if (arg === '--series') {
      parsed.seriesTitle = args[++index];
    } else if (arg === '--output-dir') {
      parsed.outputDir = path.resolve(args[++index]);
      parsed.screenshotDir = path.join(parsed.outputDir, 'screenshots');
    } else if (arg === '--screenshot-dir') {
      parsed.screenshotDir = path.resolve(args[++index]);
    } else if (arg === '--picture-timeout-minutes') {
      parsed.pictureTimeoutMs = Number(args[++index]) * 60 * 1000;
    } else if (arg === '--picture-poll-seconds') {
      parsed.picturePollMs = Number(args[++index]) * 1000;
    } else if (arg === '--translation-timeout-seconds') {
      parsed.translationTimeoutMs = Number(args[++index]) * 1000;
    } else if (arg === '--no-screenshots') {
      parsed.screenshots = false;
    } else if (arg === '--cleanup') {
      parsed.cleanup = true;
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
  console.log(`Usage: node tools/qa_picture_book_live.mjs [options]

Options:
  --base-url <url>                    QA server base URL, default http://127.0.0.1:39317
  --port <port>                       Shortcut for --base-url http://127.0.0.1:<port>
  --token <token>                     TOMATO_QA_TOKEN value, if enabled
  --text <path>                       Input text file
  --title <title>                     Chapter title
  --article-id <id>                   Continue from an existing article; skips UI save
  --series <title>                    Story series title
  --picture-timeout-minutes <number>  Max async picture wait, default 50
  --picture-poll-seconds <number>     Poll interval, default 15
  --translation-timeout-seconds <n>   First Chinese subtitle wait, default 180
  --output-dir <path>                 Result directory
  --no-screenshots                    Skip /screenshot captures
  --cleanup                           Delete the created article after the run
`);
}

main().catch(async (error) => {
  const failure = {
    ok: false,
    error: error.stack || error.message,
    screenshots,
    finishedAt: new Date().toISOString(),
  };
  await mkdir(config.outputDir, { recursive: true });
  await writeResult(failure);
  console.error(error.stack || error.message);
  process.exit(1);
});
