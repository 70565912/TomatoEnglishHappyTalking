#!/usr/bin/env node
/**
 * QA: hide listening subtitles via bridge (empty english = soft hide).
 *
 * Usage:
 *   node tools/qa_listening_hide_sentences.mjs --articleId 72 --indexes 44,45
 *   node tools/qa_listening_hide_sentences.mjs --port 39317 --bookId 23
 */

const config = parseArgs(process.argv.slice(2));
const base = `http://127.0.0.1:${config.port}`;
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function main() {
  await waitForHealth();
  console.log('=== QA listening hide sentences ===');
  console.log(`articleId=${config.articleId} indexes=${config.indexes.join(',')}`);

  const articles = await bridge('article.list', {});
  const article = (articles.articles ?? []).find((item) => Number(item.id) === config.articleId);
  if (!article) {
    throw new Error(`Article ${config.articleId} not found`);
  }
  console.log(`Article: ${article.title} slots=${article.sentenceCount} visible=${article.visibleSentenceCount ?? 'n/a'}`);

  await postJson('/navigate', {
    path: `/books/${config.bookId}/player?articleId=${config.articleId}&mode=listening`,
  });
  await wait(1500);

  const before = await bridge('listening.open', { articleId: config.articleId });
  const beforeVisible = countVisible(before.items ?? []);
  console.log(`Before: visible=${beforeVisible} total items=${(before.items ?? []).length}`);

  let hiddenThisRun = 0;
  for (const index of config.indexes) {
    const item = (before.items ?? []).find((row) => Number(row.index) === index);
    if (isHidden(item)) {
      console.log(`Index ${index} (UI #${index + 1}) already hidden, skipping.`);
      continue;
    }
    hiddenThisRun += 1;
    const previousEnglish = item?.english?.trim() || `slot-${index}`;
    const previousChinese = item?.chinese?.trim() || '';
    console.log(`Hiding index ${index} (UI #${index + 1})...`);
    const updated = await bridge('listening.updateSentence', {
      articleId: config.articleId,
      index,
      english: '',
      chinese: '',
      previousEnglish,
      previousChinese,
    });
    const hidden = (updated.items ?? []).find((row) => Number(row.index) === index);
    if (!hidden?.hidden && hidden?.english !== '') {
      throw new Error(`Index ${index} was not marked hidden: ${JSON.stringify(hidden)}`);
    }
    await wait(400);
  }

  const after = await bridge('listening.open', { articleId: config.articleId });
  const afterVisible = countVisible(after.items ?? []);
  console.log(`After hide: visible=${afterVisible} (delta ${beforeVisible - afterVisible})`);

  if (hiddenThisRun > 0 && afterVisible !== beforeVisible - hiddenThisRun) {
    throw new Error(
      `Expected visible count ${beforeVisible - hiddenThisRun}, got ${afterVisible}`,
    );
  }

  for (const index of config.indexes) {
    const row = (after.items ?? []).find((item) => Number(item.index) === index);
    if (!row?.hidden) {
      throw new Error(`Slot ${index} missing hidden flag after reopen`);
    }
  }

  const anchor = config.indexes[0] - 1;
  if (anchor >= 0) {
    const anchorRow = (after.items ?? []).find((item) => Number(item.index) === anchor);
    if (!anchorRow || isHidden(anchorRow)) {
      throw new Error(`Anchor slot ${anchor} missing or hidden`);
    }
  }

  const afterIndex = config.indexes[config.indexes.length - 1] + 1;
  const totalSlots = Number(after.article?.sentenceCount ?? (after.items ?? []).length);
  if (afterIndex < totalSlots) {
    const afterRow = (after.items ?? []).find((item) => Number(item.index) === afterIndex);
    if (!afterRow || isHidden(afterRow)) {
      throw new Error(`Following slot ${afterIndex} missing or hidden (index should be preserved)`);
    }
    console.log(`Slot ${afterIndex} still visible: ${String(afterRow.english).slice(0, 60)}...`);
  } else {
    console.log(`No slot after index ${afterIndex - 1}; article ends at UI #${totalSlots}`);
  }

  const audioStatus = await bridge('listening.audioStatus', { articleId: config.articleId });
  console.log(`Audio status: total=${audioStatus.total} ready=${audioStatus.ready} missing=${(audioStatus.missing ?? []).length}`);

  const fullscreenReady = await bridge('listening.fullscreenReady', {
    articleId: config.articleId,
    startIndex: Math.max(0, anchor),
    lookaheadCount: 2,
    items: after.items,
  });
  console.log(`Fullscreen ready: ${fullscreenReady.ready} reasons=${JSON.stringify(fullscreenReady.reasons ?? [])}`);

  await postJson('/navigate', { path: `/follow/${config.articleId}` });
  await wait(1200);
  const follow = await bridge('follow.open', { articleId: config.articleId });
  const followIndex = Number(follow.currentIndex ?? -1);
  const firstVisible = (after.items ?? []).find((item) => !isHidden(item))?.index;
  if (firstVisible != null && followIndex !== firstVisible) {
    throw new Error(`follow.open currentIndex=${followIndex}, expected first visible ${firstVisible}`);
  }
  console.log(`Follow opens at visible slot ${followIndex}`);

  const logs = await fetch(`${base}/logs/recent?limit=50&category=bridge,listening`).then((res) => res.json());
  const errors = (logs.entries ?? logs.items ?? []).filter((entry) => String(entry.level ?? '').toLowerCase() === 'error');
  if (errors.length > 0) {
    throw new Error(`Recent bridge/listening errors: ${JSON.stringify(errors.slice(0, 3))}`);
  }

  if (config.restoreFirstIndex != null) {
    const restoreIndex = config.restoreFirstIndex;
    const english = config.restoreEnglish || 'Restored sentence for QA.';
    console.log(`Restoring index ${restoreIndex}...`);
    const restored = await bridge('listening.updateSentence', {
      articleId: config.articleId,
      index: restoreIndex,
      english,
      chinese: 'QA 恢复句',
      previousEnglish: '',
      previousChinese: '',
    });
    const row = (restored.items ?? []).find((item) => Number(item.index) === restoreIndex);
    if (isHidden(row)) {
      throw new Error(`Restore failed for index ${restoreIndex}`);
    }
    console.log('Restore OK');
  }

  console.log('=== QA listening hide sentences: PASS ===');
}

function countVisible(items) {
  return items.filter((item) => !isHidden(item)).length;
}

function isHidden(item) {
  if (!item) return true;
  return item.hidden === true || String(item.english ?? '').trim().length === 0;
}

async function waitForHealth() {
  for (let attempt = 0; attempt < 30; attempt += 1) {
    try {
      const res = await fetch(`${base}/health`);
      if (res.ok) {
        const body = await res.json();
        if (body.webReady) return body;
      }
    } catch (_) {
      // retry
    }
    await wait(1000);
  }
  throw new Error(`QA server not ready at ${base}/health`);
}

async function bridge(type, payload) {
  const res = await postJson('/bridge', { type, payload });
  if (res.ok === false) {
    throw new Error(`${type} failed: ${JSON.stringify(res.error ?? res)}`);
  }
  return res.payload ?? res;
}

async function postJson(path, body) {
  const res = await fetch(`${base}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch (_) {
    throw new Error(`Invalid JSON from ${path}: ${text.slice(0, 200)}`);
  }
}

function parseArgs(argv) {
  const config = {
    port: 39317,
    articleId: 72,
    bookId: 23,
    indexes: [44, 45],
    restoreFirstIndex: null,
    restoreEnglish: '',
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--port') config.port = Number(argv[++i]);
    else if (arg === '--articleId') config.articleId = Number(argv[++i]);
    else if (arg === '--bookId') config.bookId = Number(argv[++i]);
    else if (arg === '--indexes') {
      config.indexes = String(argv[++i])
        .split(',')
        .map((value) => Number(value.trim()))
        .filter((value) => Number.isFinite(value));
    } else if (arg === '--restore' || arg === '--restoreFirstIndex') {
      config.restoreFirstIndex = Number(argv[++i]);
    } else if (arg === '--restoreEnglish') {
      config.restoreEnglish = String(argv[++i]);
    }
  }
  return config;
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
