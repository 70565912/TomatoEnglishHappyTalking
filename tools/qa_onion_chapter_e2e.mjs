import { mkdir, readFile, writeFile } from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';

const baseUrl = 'http://127.0.0.1:39317';
const outDir = path.resolve('output/onion-chapter');
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function request(route, body, timeoutMs = 600_000) {
  const payload = body == null ? null : JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        hostname: '127.0.0.1',
        port: 39317,
        path: route,
        method: body ? 'POST' : 'GET',
        headers: body
          ? {
              'Content-Type': 'application/json',
              'Content-Length': Buffer.byteLength(payload),
            }
          : undefined,
        timeout: timeoutMs,
      },
      (res) => {
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => {
          const text = Buffer.concat(chunks).toString('utf8');
          let parsed;
          try {
            parsed = JSON.parse(text);
          } catch {
            parsed = text;
          }
          if ((res.statusCode ?? 500) >= 400) {
            reject(
              new Error(
                `${route} failed: ${res.statusCode} ${String(text).slice(0, 2000)}`,
              ),
            );
            return;
          }
          resolve(parsed);
        });
      },
    );
    req.on('timeout', () => {
      req.destroy(new Error(`${route} timed out after ${timeoutMs}ms`));
    });
    req.on('error', reject);
    if (payload != null) {
      req.write(payload);
    }
    req.end();
  });
}

async function bridge(type, payload = {}, timeoutMs = 600_000) {
  console.log(`[bridge] ${type}`);
  const result = await request('/bridge', { type, payload }, timeoutMs);
  if (result?.ok === false) {
    throw new Error(`${type} failed: ${JSON.stringify(result.error ?? result)}`);
  }
  // QA wraps native handlers as { ok, type, payload }.
  if (result && typeof result === 'object' && result.payload != null) {
    return result.payload;
  }
  return result;
}

async function dump(name, value) {
  await writeFile(
    path.join(outDir, name),
    typeof value === 'string' ? value : JSON.stringify(value, null, 2),
    'utf8',
  );
}

function pagesFromState(state) {
  return Array.isArray(state?.pages) ? state.pages : [];
}

async function main() {
  await mkdir(outDir, { recursive: true });
  const health = await request('/health');
  if (!health?.ok || !health?.webReady) {
    throw new Error(`QA not ready: ${JSON.stringify(health)}`);
  }

  const content = await readFile(path.join(outDir, 'bilingual-content.txt'), 'utf8');
  const lyrics = await readFile(path.join(outDir, 'song-lyrics-zh.txt'), 'utf8');
  const mp3Path = path.resolve(
    'release/windows/tomato_english_happy_talking/downloads/我是一根葱.mp3',
  );

  const resumeArticleId = Number(process.env.TOMATO_ONION_ARTICLE_ID || '');
  let articleId;
  if (Number.isFinite(resumeArticleId) && resumeArticleId > 0) {
    articleId = resumeArticleId;
    console.log(`resuming articleId=${articleId}`);
  } else {
    const create = await bridge('article.create', {
      title: '我是一根葱',
      content,
      pictureBookEnabled: true,
      seriesId: 28,
    }, 900_000);
    await dump('article-create.json', create);
    articleId = Number(create?.article?.id);
    if (!Number.isFinite(articleId)) {
      throw new Error(`articleId missing: ${JSON.stringify(create).slice(0, 1000)}`);
    }
  }
  await dump('article-id.txt', `articleId=${articleId}\n`);
  console.log(`articleId=${articleId}`);

  const existingState = await bridge('pictureBook.state', { articleId }, 120_000);
  await dump('picture-book-state.json', existingState);
  const existingPages = pagesFromState(existingState);
  const existingStatuses = existingPages.map((page) => String(page.status ?? ''));
  const alreadyWorking =
    existingPages.length > 0 &&
    existingStatuses.every(
      (status) => status === 'ready' || status === 'generating' || status === 'loading',
    );
  if (alreadyWorking) {
    console.log(
      `skip confirm; existing pages=${existingPages.length} ${existingStatuses.join(',')}`,
    );
  } else {
    const review = await bridge('pictureBook.promptReview', { articleId }, 300_000);
    await dump('prompt-review.json', review);
    const reviewId = String(review?.reviewId ?? '').trim();
    if (!reviewId) {
      throw new Error(`reviewId missing: ${JSON.stringify(review).slice(0, 1000)}`);
    }

    const confirm = await bridge(
      'pictureBook.confirmPromptReview',
      {
        reviewId,
        groupPrompt: String(review.groupPrompt ?? ''),
        bookDescription: String(review.bookDescription ?? ''),
        chapterDescription: String(review.chapterDescription ?? ''),
        bookCharacters: review.bookCharacters ?? [],
        newCharacters: review.newCharacters ?? [],
        scenes: review.scenes ?? [],
      },
      2_700_000,
    );
    await dump('prompt-confirm.json', confirm);
    console.log('confirm submitted; polling pictureBook.state');
  }

  let ready = false;
  const deadline = Date.now() + 45 * 60_000;
  while (Date.now() < deadline) {
    const state = await bridge('pictureBook.state', { articleId }, 120_000);
    await dump('picture-book-state.json', state);
    const pages = pagesFromState(state);
    const statuses = pages.map((page) => String(page.status ?? ''));
    const summary = Object.entries(
      statuses.reduce((acc, status) => {
        acc[status] = (acc[status] ?? 0) + 1;
        return acc;
      }, {}),
    )
      .map(([status, count]) => `${status}=${count}`)
      .join(', ');
    console.log(`pages=${pages.length} ${summary}`);
    if (pages.length > 0 && statuses.every((status) => status === 'ready')) {
      ready = true;
      break;
    }
    if (statuses.some((status) => status === 'error' || status === 'failed')) {
      throw new Error(`picture book page error: ${summary}`);
    }
    await wait(20_000);
  }
  if (!ready) {
    throw new Error('picture book not ready before timeout');
  }
  await dump('article-id.txt', `articleId=${articleId}\npictureBookReady=true\n`);

  // Listening must be open for some song handlers that fall back to activeListeningArticleId,
  // but songImportExternal accepts articleId explicitly.
  const songImport = await bridge(
    'listening.songImportExternal',
    {
      articleId,
      sourcePath: mp3Path,
      lyrics,
    },
    300_000,
  );
  await dump('song-import.json', songImport);
  const versionId = String(
    songImport?.versions?.find((v) => v.isDefault)?.id ??
      songImport?.versions?.[0]?.id ??
      '',
  ).trim();
  if (!versionId) {
    throw new Error(`versionId missing after import: ${JSON.stringify(songImport).slice(0, 1500)}`);
  }
  console.log(`versionId=${versionId}`);

  console.log('generating song timeline...');
  const timeline = await bridge(
    'listening.songTimelineGenerate',
    { articleId, versionId },
    900_000,
  );
  await dump('song-timeline.json', timeline);
  const timelineVersion =
    timeline?.versions?.find((v) => v.id === versionId) ??
    timeline?.versions?.find((v) => v.isDefault) ??
    timeline?.versions?.[0];
  console.log(
    `timelineStatus=${timelineVersion?.timelineStatus} confidence=${timelineVersion?.timelineConfidence}`,
  );
  if (String(timelineVersion?.timelineStatus) !== 'ready') {
    throw new Error(
      `timeline not ready: ${JSON.stringify(timelineVersion ?? timeline).slice(0, 2000)}`,
    );
  }

  console.log('exporting song video...');
  const exportResult = await bridge(
    'listening.songRecordVideo',
    { articleId, versionId },
    900_000,
  );
  await dump('song-video-export.json', exportResult);
  console.log(JSON.stringify({
    articleId,
    versionId,
    exportResultKeys: Object.keys(exportResult ?? {}),
    outputPath: exportResult?.outputPath ?? exportResult?.videoPath,
    videoVariants: exportResult?.videoVariants,
  }, null, 2));
}

main().catch(async (error) => {
  console.error(error);
  await dump('e2e-error.txt', String(error?.stack ?? error));
  process.exitCode = 1;
});
