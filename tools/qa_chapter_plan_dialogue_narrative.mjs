/**
 * Live probe: dialogue-dense chapter → pictureBook chapterPlan refresh.
 * Checks that chapterDescription / sceneDescription convert dialogue into
 * narrative (keep plot facts) without quoted speech / speech-bubble wording.
 *
 * Requires a Windows build with the dialogue-to-narrative prompt and QA remote.
 *
 * Usage:
 *   node tools/qa_chapter_plan_dialogue_narrative.mjs
 *   node tools/qa_chapter_plan_dialogue_narrative.mjs --cleanup
 *   node tools/qa_chapter_plan_dialogue_narrative.mjs --articleId 123
 */
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const workspaceRoot = path.resolve(__dirname, '..');

const config = parseArgs(process.argv.slice(2));
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const QUOTED_SPEECH_RE =
  /[“”][^“”]{6,}[“”]|"[^"]{10,}"/;
const SPEECH_ACT_DENSE_RE =
  /\b(?:asks?|explains?|tells?|replies?|says?|said|argues?)\b/gi;
const SPEECH_BUBBLE_RE = /\bspeech[- ]?bubbles?\b/i;
const EMPTY_META_RE =
  /\b(they|the group|the party)\s+(exchange|converse|have a conversation|discuss|debate)\b/i;
const PLOT_MARKERS = [
  /wine/i,
  /tea/i,
  /pepper|saucepan|cookware|caldron|kitchen/i,
  /grin|cheshire|cat/i,
  /starfish|baby|pig/i,
  /raven|writing[- ]?desk|riddle/i,
  /ear|fur|chimney|mushroom/i,
];
const NARRATIVE_CONVERT_HINTS = [
  /offer(?:s|ed)?\s+(?:some\s+)?wine/i,
  /(?:only|nothing(?:\s+\w+){0,3}\s+but)\s+tea|no wine/i,
  /grin\s+without\s+a\s+cat|only\s+(?:its\s+)?grin|grin floating/i,
  /fling(?:s|ing)?\s+(?:it|the\s+baby)|toss(?:es|ing)?\s+the\s+baby/i,
  /chop\s+off|dramatic royal punishment|angry command/i,
];

async function main() {
  await mkdir(config.outputDir, { recursive: true });
  await waitForHealth();

  const rawText = await readFile(config.textPath, 'utf8');
  const textHash = createHash('sha256').update(rawText).digest('hex');

  let article;
  let created = false;
  if (config.articleId != null) {
    article = await findArticleById(config.articleId);
  } else {
    const series = await ensureAliceSeries();
    const createResult = await bridge('article.create', {
      title: config.title,
      content: rawText,
      seriesId: series.id,
      seriesTitle: series.title,
      pictureBookEnabled: false,
    });
    article = createResult.article ?? createResult.payload?.article ?? createResult;
    if (article?.id == null) {
      article = await waitForArticleByTitle(config.title);
    }
    created = true;
  }

  const review = await bridge('pictureBook.promptReview', {
    articleId: article.id,
    regenerate: true,
  });
  const reviewPayload = unwrap(review);
  const reviewId = String(reviewPayload.reviewId ?? '').trim();
  if (!reviewId) {
    throw new Error(`promptReview missing reviewId: ${JSON.stringify(reviewPayload)}`);
  }

  const refreshed = await bridge('pictureBook.refreshPromptReview', {
    reviewId,
    target: 'chapterPlan',
    bookDescription:
      reviewPayload.bookDescription ||
      'Victorian fantasy picture book; Alice wears a blue dress and white apron.',
    bookCharacters: reviewPayload.bookCharacters ?? [],
    newCharacters: reviewPayload.newCharacters ?? [],
    chapterDescription: reviewPayload.chapterDescription ?? '',
    scenes: reviewPayload.scenes ?? [],
  });
  const plan = unwrap(refreshed);

  const evaluation = evaluatePlan(plan);
  const result = {
    ok: evaluation.pass,
    generatedAt: new Date().toISOString(),
    textPath: config.textPath,
    textHash,
    title: config.title,
    articleId: article.id,
    sentenceCount: article.sentenceCount ?? plan.scenes?.at(-1)?.sentenceEndIndex,
    created,
    chapterDescription: plan.chapterDescription ?? '',
    scenes: (plan.scenes ?? []).map((scene) => ({
      pageIndex: scene.pageIndex,
      sentenceStartIndex: scene.sentenceStartIndex,
      sentenceEndIndex: scene.sentenceEndIndex,
      sceneDescription: scene.sceneDescription ?? '',
    })),
    groupPrompt: plan.groupPrompt ?? '',
    newCharacters: plan.newCharacters ?? [],
    evaluation,
    outputDir: config.outputDir,
  };

  await writeFile(
    path.join(config.outputDir, 'result.json'),
    JSON.stringify(result, null, 2),
    'utf8',
  );
  await writeFile(
    path.join(config.outputDir, 'evaluation.md'),
    renderEvaluationMarkdown(result),
    'utf8',
  );

  console.log(JSON.stringify({
    ok: result.ok,
    articleId: result.articleId,
    sceneCount: result.scenes.length,
    evaluation: {
      pass: evaluation.pass,
      issues: evaluation.issues,
      strengths: evaluation.strengths,
      needsOptimization: evaluation.needsOptimization,
    },
    resultPath: path.join(config.outputDir, 'result.json'),
    evaluationPath: path.join(config.outputDir, 'evaluation.md'),
  }, null, 2));

  if (config.cleanup && created && article.id != null) {
    await bridge('article.delete', { articleId: article.id });
  }

  if (!evaluation.pass) {
    process.exitCode = 2;
  }
}

function evaluatePlan(plan) {
  const chapterDescription = String(plan.chapterDescription ?? '').trim();
  const scenes = Array.isArray(plan.scenes) ? plan.scenes : [];
  const sceneTexts = scenes.map((s) => String(s.sceneDescription ?? '').trim());
  const allText = [chapterDescription, ...sceneTexts].join('\n');
  const issues = [];
  const strengths = [];

  if (!chapterDescription) {
    issues.push('chapterDescription is empty');
  }
  if (scenes.length === 0) {
    issues.push('scenes[] is empty');
  }
  if (scenes.length > 12) {
    issues.push(`scenes.length ${scenes.length} exceeds hard cap 12`);
  }

  const quotedHits = findMatches(allText, QUOTED_SPEECH_RE);
  if (quotedHits.length > 0) {
    issues.push(`quoted speech still present: ${quotedHits.slice(0, 3).join(' | ')}`);
  } else {
    strengths.push('no long quoted speech in descriptions');
  }

  if (SPEECH_BUBBLE_RE.test(allText)) {
    issues.push('speech-bubble wording present');
  } else {
    strengths.push('no speech-bubble wording');
  }

  if (EMPTY_META_RE.test(allText)) {
    issues.push('empty dialogue-meta wording (exchange/converse/discuss without plot)');
  }

  const speechActHits = findMatches(allText, SPEECH_ACT_DENSE_RE);
  if (speechActHits.length >= 12) {
    issues.push(
      `speech-act verbs still dense (${speechActHits.length} hits: ask/explain/tell/reply/say/argue); prefer visible action over dialogue process`,
    );
  } else {
    strengths.push(`speech-act verb density moderate (${speechActHits.length})`);
  }

  const plotHits = PLOT_MARKERS.filter((re) => re.test(allText)).map((re) => re.source);
  if (plotHits.length >= 4) {
    strengths.push(`plot/scene facts retained (${plotHits.length} marker families)`);
  } else {
    issues.push(
      `too few dialogue-borne plot markers retained (${plotHits.length}); expected wine/tea/kitchen/cat/riddle style facts`,
    );
  }

  // Same continuous tea table should not explode into many scenes.
  const teaTableScenes = scenes.filter((scene) => {
    const text = String(scene.sceneDescription ?? '');
    return /tea table|under a tree|offers? alice wine|no wine|raven|writing desk|mean what/i.test(
      text,
    );
  });
  if (teaTableScenes.length >= 4) {
    issues.push(
      `tea-table content split across ${teaTableScenes.length} scenes; likely still dialogue-turn splitting`,
    );
  } else if (teaTableScenes.length > 0) {
    strengths.push(`tea-table content covered in ${teaTableScenes.length} scene(s)`);
  }

  const convertHits = NARRATIVE_CONVERT_HINTS.filter((re) => re.test(allText));
  if (convertHits.length >= 2) {
    strengths.push(
      `dialogue meaning converted to narrative (${convertHits.length} conversion patterns)`,
    );
  } else {
    issues.push(
      'weak dialogue→narrative conversion; expected facts like wine offered/none on table, lingering grin, baby flung, etc.',
    );
  }

  const pass = issues.length === 0;
  return {
    pass,
    needsOptimization:
      !pass || convertHits.length < 3 || teaTableScenes.length >= 3 || speechActHits.length >= 12,
    sceneCount: scenes.length,
    plotMarkerFamilies: plotHits.length,
    conversionPatternHits: convertHits.length,
    teaSceneCount: teaTableScenes.length,
    speechActVerbHits: speechActHits.length,
    issues,
    strengths,
  };
}

function findMatches(text, re) {
  const flags = re.flags.includes('g') ? re.flags : `${re.flags}g`;
  const global = new RegExp(re.source, flags);
  return [...text.matchAll(global)].map((m) => m[0]);
}

function renderEvaluationMarkdown(result) {
  const lines = [
    '# Dialogue-to-Narrative Chapter Plan Probe',
    '',
    `- Generated: ${result.generatedAt}`,
    `- Article ID: ${result.articleId}`,
    `- Scenes: ${result.scenes.length}`,
    `- Pass: ${result.evaluation.pass}`,
    `- Needs optimization: ${result.evaluation.needsOptimization}`,
    '',
    '## Strengths',
    ...result.evaluation.strengths.map((item) => `- ${item}`),
    '',
    '## Issues',
    ...(result.evaluation.issues.length
      ? result.evaluation.issues.map((item) => `- ${item}`)
      : ['- (none)']),
    '',
    '## Chapter description',
    '',
    result.chapterDescription || '(empty)',
    '',
    '## Scenes',
    '',
  ];
  for (const scene of result.scenes) {
    lines.push(
      `### Scene ${scene.pageIndex} [${scene.sentenceStartIndex}-${scene.sentenceEndIndex}]`,
      '',
      scene.sceneDescription || '(empty)',
      '',
    );
  }
  return `${lines.join('\n')}\n`;
}

function parseArgs(argv) {
  const defaults = {
    baseUrl: 'http://127.0.0.1:39317',
    token: process.env.TOMATO_QA_TOKEN?.trim() || '',
    textPath: path.join(
      workspaceRoot,
      'app',
      'test',
      'fixtures',
      'dialogue_to_narrative_probe_input.txt',
    ),
    title: `Dialogue Narrative Probe ${new Date().toISOString().slice(0, 16).replace('T', ' ')}`,
    seriesTitle: "Alice's Adventures in Wonderland",
    outputDir: path.join(workspaceRoot, '.tmp', 'qa_chapter_plan_dialogue_narrative'),
    articleId: null,
    cleanup: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--baseUrl') defaults.baseUrl = argv[++i];
    else if (arg === '--token') defaults.token = argv[++i];
    else if (arg === '--textPath') defaults.textPath = path.resolve(argv[++i]);
    else if (arg === '--title') defaults.title = argv[++i];
    else if (arg === '--seriesTitle') defaults.seriesTitle = argv[++i];
    else if (arg === '--outputDir') defaults.outputDir = path.resolve(argv[++i]);
    else if (arg === '--articleId') defaults.articleId = Number(argv[++i]);
    else if (arg === '--cleanup') defaults.cleanup = true;
  }
  return defaults;
}

function authHeaders() {
  const headers = { 'Content-Type': 'application/json' };
  if (config.token) headers.Authorization = `Bearer ${config.token}`;
  return headers;
}

async function request(routePath, body) {
  const response = await fetch(`${config.baseUrl}${routePath}`, {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify(body ?? {}),
  });
  const text = await response.text();
  let json;
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    throw new Error(`${routePath} non-JSON ${response.status}: ${text.slice(0, 300)}`);
  }
  if (!response.ok || json.ok === false) {
    const detail = formatError(json.error ?? json.message ?? text.slice(0, 500));
    throw new Error(`${routePath} failed ${response.status}: ${detail}`);
  }
  return json.result ?? json.payload ?? json;
}

function formatError(error) {
  if (error == null) return '(unknown)';
  if (typeof error === 'string') return error;
  if (typeof error === 'object') {
    return error.message || error.error || JSON.stringify(error);
  }
  return String(error);
}

async function bridge(type, payload) {
  return request('/bridge', { type, payload });
}

function unwrap(value) {
  if (value && typeof value === 'object' && value.payload && typeof value.payload === 'object') {
    return value.payload;
  }
  return value;
}

async function waitForHealth() {
  const started = Date.now();
  while (Date.now() - started < 60000) {
    try {
      const response = await fetch(`${config.baseUrl}/health`, {
        headers: authHeaders(),
      });
      if (response.ok) return;
    } catch {
      // retry
    }
    await wait(1000);
  }
  throw new Error(`QA health not ready at ${config.baseUrl}`);
}

async function ensureAliceSeries() {
  const listed = await bridge('series.list', {});
  const series = listed.series ?? listed.payload?.series ?? [];
  const existing = series.find(
    (item) =>
      String(item.title || '').trim().toLowerCase() ===
      config.seriesTitle.toLowerCase(),
  );
  if (existing) return existing;
  const created = await bridge('series.create', {
    title: config.seriesTitle,
    description:
      'Victorian fantasy picture book; Alice wears a blue dress and white apron.',
  });
  return created.series ?? created.payload?.series ?? created;
}

async function findArticleById(articleId) {
  const listed = await bridge('article.list', {});
  const articles = listed.articles ?? listed.payload?.articles ?? [];
  const article = articles.find((item) => Number(item.id) === Number(articleId));
  if (!article) throw new Error(`articleId ${articleId} not found`);
  return article;
}

async function waitForArticleByTitle(title) {
  const started = Date.now();
  while (Date.now() - started < 120000) {
    const listed = await bridge('article.list', {});
    const articles = listed.articles ?? listed.payload?.articles ?? [];
    const matches = articles
      .filter((item) => item.title === title)
      .sort((a, b) => Number(b.id) - Number(a.id));
    if (matches[0]) return matches[0];
    await wait(1500);
  }
  throw new Error(`Timed out waiting for article titled ${title}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
