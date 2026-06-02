import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

const config = parseArgs(process.argv.slice(2));
const oldAssetPattern =
  /monster-buddy|monster-mic|reward-star|reward-brick|tomato-(wave|headphones|pencil|secure|celebrate)/i;
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const qaTitle = `QA Windows ${Date.now()}`;
const qaContent =
  'Tom listens to the bright robot. He repeats the short sentence and smiles.';
const screenshots = [];
let createdArticleId = null;

async function main() {
  await waitForHealth();

  const home = await visit('/', 'home');
  assertCleanSnapshot(home, 'home');
  expectText(home, '今天也要快乐开口说英语！', 'home hero headline');

  const articleEmpty = await visit('/article/new', 'article-empty');
  assertCleanSnapshot(articleEmpty, 'article-empty');
  const saveEmpty = findButton(articleEmpty, '保存任务');
  assert(saveEmpty?.disabled === true, 'new article save button should start disabled');
  assert(
    articleEmpty.formControls?.some(
      (control) =>
        control.tag === 'input' &&
        control.placeholder === '给这张任务卡起个名字' &&
        control.value === '',
    ),
    'new article title should start empty',
  );
  assert(
    articleEmpty.formControls?.some(
      (control) =>
        control.tag === 'textarea' &&
        control.value === '',
    ),
    'new article content should start empty',
  );

  await fill('.article-form input', qaTitle);
  await fill('.article-form textarea', qaContent);
  await wait(300);
  const articleFilled = await snapshot();
  assertCleanSnapshot(articleFilled, 'article-filled');
  assert(findButton(articleFilled, '保存任务')?.disabled === false, 'save should enable after content');
  expectText(articleFilled, '句子预览（本地分句）', 'sentence preview heading');
  expectText(articleFilled, 'Tom listens to the bright robot.', 'first preview chunk');
  expectText(articleFilled, 'He repeats the short sentence and smiles.', 'second preview chunk');
  await capture('article-filled');

  await click('保存任务');
  await wait(900);
  const articlesAfterSave = await listArticles();
  const qaArticle = articlesAfterSave.find((article) => article.title === qaTitle);
  assert(qaArticle, 'created article should be saved');
  createdArticleId = qaArticle.id;
  assert(qaArticle.sentenceCount === 2, 'created article should use short reading chunks');

  const homeWithArticle = await visit('/', 'home-with-article');
  assertCleanSnapshot(homeWithArticle, 'home-with-article');
  expectText(homeWithArticle, qaTitle, 'saved article title on home');

  const settings = await visit('/settings', 'settings');
  assertCleanSnapshot(settings, 'settings');
  assert(
    !settings.formControls?.some((control) => control.tag === 'select'),
    'settings should use voice cards instead of a select',
  );
  expectText(settings, '可选声音', 'voice list heading');
  expectText(settings, '当前声音', 'selected voice panel');

  const followInitial = await visit(`/follow/${createdArticleId}`, 'follow-initial');
  assertCleanSnapshot(followInitial, 'follow-initial');
  assert(followInitial.runtimeState?.follow?.playbackState === 'idle', 'follow should start idle');
  assert(findButton(followInitial, '播放原音')?.disabled === false, 'play original should be enabled');
  assert(findRecordButton(followInitial)?.disabled === true, 'record button should wait for original audio');
  expectText(followInitial, '先听完原音，再开始录音', 'record wait cue');

  await click('播放原音');
  await waitFor(
    async () => {
      const current = await snapshot();
      return current.runtimeState?.follow?.playbackState === 'success' ? current : null;
    },
    { label: 'follow original playback success', timeoutMs: 22000 },
  );
  await wait(1200);
  const followAfterPlay = await visit(`/follow/${createdArticleId}`, 'follow-after-play', {
    navigate: false,
  });
  assertCleanSnapshot(followAfterPlay, 'follow-after-play');
  assert(
    followAfterPlay.runtimeState?.follow?.playbackState === 'success',
    'follow playback should report success',
  );
  assert(findRecordButton(followAfterPlay)?.disabled === false, 'record button should enable after playback');
  assert(findButton(followAfterPlay, '重播')?.disabled === false, 'replay should enable after playback');
  expectText(followAfterPlay, '点击录音，跟读这句话', 'record ready cue');

  await click('下一句');
  await wait(700);
  const followSecond = await snapshot();
  assert(followSecond.runtimeState?.follow?.isLastSentence === true, 'second sentence should be last');
  assert(findButton(followSecond, '完成')?.disabled === false, 'last sentence should show complete action');

  await visit(`/chat/${createdArticleId}`, 'chat-loading', { screenshot: false });
  await waitFor(
    async () => {
      const current = await snapshot();
      return current.runtimeState?.chat?.step === 'userIdle' ? current : null;
    },
    { label: 'chat user idle', timeoutMs: 22000 },
  );
  const chatReady = await snapshot();
  assertCleanSnapshot(chatReady, 'chat');
  assert(chatReady.formControls?.[0]?.disabled === false, 'chat input should enable at userIdle');
  expectText(chatReady, '轮到你说英语啦。', 'chat user cue');
  assert(
    chatReady.images?.some((image) => image.src.includes('lego/prop-star.png')) &&
      chatReady.images?.some((image) => image.src.includes('lego/prop-bricks.png')),
    'chat reward preview should use LEGO rewards',
  );
  await capture('chat');

  await cleanup();
  const finalSnapshot = await snapshot();

  console.log(
    JSON.stringify(
      {
        ok: true,
        baseUrl: config.baseUrl,
        finalHash: finalSnapshot.hash,
        screenshots,
        checks: [
          'health',
          'home',
          'new article',
          'settings voice list',
          'follow playback gating',
          'chat user idle',
          'old asset absence',
          'cleanup',
        ],
      },
      null,
      2,
    ),
  );
}

async function visit(route, name, options = {}) {
  if (options.navigate !== false) {
    await request('/navigate', { path: route });
    await wait(800);
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
    { label: 'QA health', timeoutMs: 20000 },
  );
  assert(health.usesDevServer === false, 'QA should be checking built web assets, not dev server');
}

async function cleanup() {
  const articles = await listArticles();
  const targets = articles.filter((article) => article.title === qaTitle);
  for (const article of targets) {
    await request('/bridge', {
      type: 'article.delete',
      payload: { articleId: article.id },
    });
  }
  const remaining = await listArticles();
  assert(
    remaining.every((article) => article.title !== qaTitle),
    'QA article should be deleted after the run',
  );
  await request('/navigate', { path: '/' });
  await wait(500);
  const home = await snapshot();
  assert(home.hash === '#/', 'QA cleanup should return the app to the hall');
  assert(
    typeof home.visibleText === 'string' && !home.visibleText.includes(qaTitle),
    'QA cleanup should leave no test article visible on home',
  );
}

async function listArticles() {
  const response = await request('/bridge', {
    type: 'article.list',
    payload: {},
  });
  return response.articles ?? response.payload?.articles ?? [];
}

async function snapshot() {
  return request('/snapshot');
}

async function click(text) {
  const result = await request('/click', { text });
  assert(result.ok, `click "${text}" should succeed: ${JSON.stringify(result)}`);
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

async function waitFor(check, { label, timeoutMs }) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    last = await check();
    if (last) return last;
    await wait(500);
  }
  throw new Error(`Timed out waiting for ${label}`);
}

function assertCleanSnapshot(current, label) {
  assert(current.brokenImages?.length === 0, `${label} should have no broken images`);
  assert(current.overflowElements?.length === 0, `${label} should have no visible overflow`);
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

function findButton(current, text) {
  return current.buttons?.find((button) => button.text.includes(text));
}

function findRecordButton(current) {
  return current.buttons?.find(
    (button) =>
      button.text === '' &&
      button.rect?.width >= 80 &&
      button.rect?.height >= 80,
  );
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
