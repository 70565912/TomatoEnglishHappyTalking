/**
 * Suno post-create live QA: opens creation center, starts Suno automation,
 * monitors structured logs for batch / download / complete milestones.
 *
 * Prerequisites:
 *   .\tools\build_windows.ps1 -Run -DartDefine "TOMATO_QA_REMOTE=true,TOMATO_QA_PORT=39317"
 *   Suno account logged in inside the WebView (first run may need manual login).
 *
 * Usage:
 *   node tools/qa_suno_live.mjs --articleId 82
 *   node tools/qa_suno_live.mjs --articleId 83 --auto-confirm --timeout-minutes 45
 */
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

const config = parseArgs(process.argv.slice(2));
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const startedAt = Date.now();
const milestones = [];
const logHits = {
  batchSidebarDetected: [],
  directMediaSaved: [],
  directMediaNotReady: [],
  completeAllowed: [],
  completeBlocked: [],
  completionProbe: [],
};

async function main() {
  await mkdir(config.outputDir, { recursive: true });
  console.log(`=== Suno live QA (article ${config.articleId}) ===`);
  console.log(`QA: ${config.baseUrl}`);
  console.log(`Output: ${config.outputDir}`);

  await waitForHealth();
  const article = await findArticle(config.articleId);
  if (!article) {
    throw new Error(`Article ${config.articleId} not found in article.list`);
  }
  record('article', { id: article.id, title: article.title, seriesId: article.seriesId });

  const baselineState = await bridge('listening.songState', { articleId: config.articleId });
  const baselineVersions = baselineState.versions?.length ?? 0;
  record('baseline', { versions: baselineVersions, status: baselineState.status });

  await openCreationSongTab(article);
  await capture('creation-song-before-generate');

  console.log('Starting listening.songGenerate (Suno WebView will open)...');
  const generateState = await bridge('listening.songGenerate', {
    articleId: config.articleId,
    source: 'suno',
  });
  record('songGenerate', {
    status: generateState.status,
    automationStatus: generateState.automationStatus,
  });

  let confirmed = false;
  const deadline = Date.now() + config.timeoutMs;
  let lastStatus = '';

  while (Date.now() < deadline) {
    await pollSunoLogs();
    const state = await bridge('listening.songState', { articleId: config.articleId });
    const automationStatus = String(state.automationStatus ?? state.status ?? '').trim();
    if (automationStatus !== lastStatus) {
      console.log(`[status] ${automationStatus} (versions=${state.versions?.length ?? 0})`);
      lastStatus = automationStatus;
      record(`status:${automationStatus}`, { versions: state.versions?.length ?? 0 });
    }

    if (config.autoConfirm && !confirmed && automationStatus === 'waitingConfirm') {
      console.log('Auto-calling listening.songConfirmSunoCreate (Suno form ready)...');
      try {
        await bridge('listening.songConfirmSunoCreate', { articleId: config.articleId });
        confirmed = true;
        record('songConfirmSunoCreate', { ok: true });
        await capture('after-confirm-create');
      } catch (error) {
        record('songConfirmSunoCreate', { ok: false, error: String(error) });
      }
    }

    if (automationStatus === 'waitingConfirm' && !config.autoConfirm) {
      console.log(
        '>>> 请在 App 中核对 Suno 填表后点击「确认创建」；Suno 真人审核通过后自动化会继续下载。',
      );
    }

    if (logHits.batchSidebarDetected.length > 0 && logHits.batchSidebarDetected.at(-1).count >= 2) {
      if (!milestones.some((item) => item.name === 'batch-sidebar-2')) {
        record('batch-sidebar-2', logHits.batchSidebarDetected.at(-1));
        await debugSnapshot('batch-sidebar-2');
        await capture('batch-sidebar-2');
      }
    }

    if (automationStatus === 'complete' || state.status === 'ready') {
      record('terminal', { automationStatus, versions: state.versions?.length ?? 0 });
      break;
    }
    if (automationStatus === 'failed') {
      record('terminal', { automationStatus, error: state.errorMessage });
      await debugSnapshot(`terminal-${automationStatus}`);
      await capture(`terminal-${automationStatus}`);
      break;
    }
    if (automationStatus === 'manualAction') {
      console.log(
        '>>> manualAction（可能为填表/魔法棒等待）：请在 Suno 窗口完成登录或点 App「继续检测」；脚本继续轮询…',
      );
    }

    await wait(config.pollIntervalMs);
  }

  await pollSunoLogs();
  const finalState = await bridge('listening.songState', { articleId: config.articleId });
  const finalVersions = finalState.versions?.length ?? 0;
  const report = buildReport(finalState, baselineVersions, finalVersions);
  const reportPath = path.join(config.outputDir, 'result.json');
  await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  console.log(`\nReport: ${reportPath}`);
  printSummary(report);
  if (!report.passed) {
    process.exitCode = 1;
  }
}

function buildReport(finalState, baselineVersions, finalVersions) {
  const sidebarMax = Math.max(
    0,
    ...logHits.batchSidebarDetected.map((item) => item.count ?? 0),
  );
  const savedCount = logHits.directMediaSaved.length;
  const checks = {
    batchSidebarAtLeast2: sidebarMax >= 2,
    twoDirectMediaSaved: savedCount >= 2,
    completeAllowedSeen: logHits.completeAllowed.length > 0,
    versionsGrewBy2: finalVersions >= baselineVersions + 2,
    terminalReadyOrComplete:
      finalState.status === 'ready' ||
      String(finalState.automationStatus ?? '') === 'complete',
    noEarlyFalsePositiveOpen:
      !logHits.completionProbe.some(
        (item) =>
          item.currentPageLyricsExactMatch === true &&
          (item.songUrlCount ?? 0) === 0 &&
          (item.url ?? '').includes('/create'),
      ),
  };
  const passed = Object.values(checks).every(Boolean);
  return {
    passed,
    articleId: config.articleId,
    durationMs: Date.now() - startedAt,
    baselineVersions,
    finalVersions,
    sidebarMax,
    directMediaSavedCount: savedCount,
    checks,
    milestones,
    logHits,
    finalState: {
      status: finalState.status,
      automationStatus: finalState.automationStatus,
      downloadComplete: finalState.downloadComplete,
      versions: finalState.versions?.length ?? 0,
      errorMessage: finalState.errorMessage,
    },
  };
}

function printSummary(report) {
  console.log('\n=== Suno QA summary ===');
  for (const [key, value] of Object.entries(report.checks)) {
    console.log(`  ${value ? 'PASS' : 'FAIL'} ${key}`);
  }
  console.log(
    `  versions ${report.baselineVersions} -> ${report.finalVersions}, saved=${report.directMediaSavedCount}, sidebarMax=${report.sidebarMax}`,
  );
  console.log(report.passed ? '\nOverall: PASS' : '\nOverall: FAIL (see result.json)');
}

async function openCreationSongTab(article) {
  const seriesId = article.seriesId;
  const route =
    seriesId != null
      ? `/creation?articleId=${article.id}&seriesId=${seriesId}`
      : `/creation?articleId=${article.id}`;
  await navigate(route);
  await wait(1200);
  await waitFor(
    async () => {
      const current = await snapshot();
      return current.visibleText?.includes('创作中心') ? current : null;
    },
    { label: 'creation center', timeoutMs: 30000 },
  );
  await click('歌曲');
  await waitFor(
    async () => {
      const current = await snapshot();
      return current.visibleText?.includes('生成 Suno 歌曲') ? current : null;
    },
    { label: 'song creation tab', timeoutMs: 20000 },
  );
}

async function pollSunoLogs() {
  const logs = await request(
    `/logs/recent?limit=300&category=suno&since=${new Date(startedAt - 5000).toISOString()}`,
  );
  const entries = Array.isArray(logs.entries) ? logs.entries : Array.isArray(logs) ? logs : [];
  for (const entry of entries) {
    const event = String(entry.event ?? '');
    const data = entry.data ?? {};
    if (event === 'batch.sidebar_detected') {
      pushUnique(logHits.batchSidebarDetected, 'ts', entry.ts, {
        count: data.pending ?? data.pendingCount ?? 0,
        pending: data.pending,
        generatingCount: data.generatingCount,
      });
    }
    if (event === 'direct_media.saved') {
      pushUnique(logHits.directMediaSaved, 'ts', entry.ts, { songUrl: data.songUrl });
    }
    if (event === 'direct_media.not_ready') {
      pushUnique(logHits.directMediaNotReady, 'ts', entry.ts, { status: data.status });
    }
    if (event === 'complete.allowed') {
      pushUnique(logHits.completeAllowed, 'ts', entry.ts, data);
    }
    if (event === 'complete.blocked') {
      pushUnique(logHits.completeBlocked, 'ts', entry.ts, { reason: data.reason });
    }
    if (event === 'completion.probe') {
      pushUnique(logHits.completionProbe, 'ts', entry.ts, {
        url: data.url,
        songUrlCount: data.songUrlCount,
        currentPageLyricsExactMatch: data.currentPageLyricsExactMatch,
        currentPageGenerating: data.currentPageGenerating,
      });
    }
  }
}

async function debugSnapshot(name) {
  try {
    const result = await bridge('suno.debugSnapshot', {
      directory: path.join(config.outputDir, 'snapshots'),
      includeScreenshot: true,
    });
    record(`snapshot:${name}`, { path: result.path, ok: result.ok !== false });
    return result;
  } catch (error) {
    record(`snapshot:${name}`, { ok: false, error: String(error) });
    return null;
  }
}

function pushUnique(list, keyField, key, value) {
  if (list.some((item) => item[keyField] === key)) return;
  list.push({ [keyField]: key, ...value });
}

function record(name, data) {
  milestones.push({ at: new Date().toISOString(), name, ...data });
}

async function findArticle(articleId) {
  const articles = await listArticles();
  return articles.find((item) => Number(item.id) === Number(articleId)) ?? null;
}

async function listArticles() {
  const list = await bridge('article.list', {});
  return list.articles ?? list.items ?? [];
}

function unwrapBridge(response) {
  if (response && typeof response === 'object' && response.payload != null) {
    return response.payload;
  }
  return response;
}

async function bridge(type, payload = {}) {
  const response = await request('/bridge', { type, payload });
  return unwrapBridge(response);
}

async function navigate(routePath) {
  await request('/navigate', { path: routePath });
  await wait(800);
}

async function click(text) {
  const result = await request('/click', { text });
  if (!result.ok) throw new Error(`click "${text}": ${JSON.stringify(result)}`);
  return result;
}

async function snapshot() {
  return request('/snapshot');
}

async function health() {
  return request('/health');
}

async function capture(name) {
  if (!config.screenshots) return null;
  const dir = path.join(config.outputDir, 'screenshots');
  await mkdir(dir, { recursive: true });
  const response = await fetch(`${config.baseUrl}/screenshot`, { headers: authHeaders() });
  if (!response.ok) return null;
  const file = path.join(dir, `${name}.png`);
  await writeFile(file, Buffer.from(await response.arrayBuffer()));
  return file;
}

async function clickBySelector(selector, index = 0) {
  const result = await request('/click', { selector, index });
  if (!result.ok) throw new Error(`click ${selector}: ${JSON.stringify(result)}`);
  return result;
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
    { label: 'QA health', timeoutMs: 120000, intervalMs: 1500 },
  );
}

async function waitFor(check, options) {
  const deadline = Date.now() + options.timeoutMs;
  while (Date.now() < deadline) {
    const result = await check();
    if (result) return result;
    await wait(options.intervalMs ?? 1000);
  }
  throw new Error(`Timed out waiting for ${options.label}`);
}

function parseArgs(argv) {
  let articleId = 82;
  let port = 39317;
  let token = '';
  let timeoutMinutes = 45;
  let autoConfirm = false;
  let screenshots = true;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--articleId') articleId = Number(argv[++i]);
    else if (arg === '--port') port = Number(argv[++i]);
    else if (arg === '--token') token = argv[++i] ?? '';
    else if (arg === '--timeout-minutes') timeoutMinutes = Number(argv[++i]);
    else if (arg === '--auto-confirm') autoConfirm = true;
    else if (arg === '--no-screenshots') screenshots = false;
  }
  const outputDir = path.resolve('.tmp', 'qa-suno-live', `article-${articleId}`);
  return {
    articleId,
    port,
    token,
    autoConfirm,
    screenshots,
    timeoutMs: timeoutMinutes * 60 * 1000,
    pollIntervalMs: 5000,
    baseUrl: `http://127.0.0.1:${port}`,
    outputDir,
  };
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
