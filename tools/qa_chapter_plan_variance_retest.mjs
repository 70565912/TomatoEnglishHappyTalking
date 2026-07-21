/**
 * Repeated live chapter-plan probe over existing articles.
 *
 * Uses promptReview + refreshPromptReview only: no article creation, prompt
 * confirmation, image generation, or persisted chapter-plan replacement.
 *
 * Usage:
 *   node tools/qa_chapter_plan_variance_retest.mjs
 *   node tools/qa_chapter_plan_variance_retest.mjs --repeats 3 --articleIds 46,68,91
 */
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '..');
const config = parseArgs(process.argv.slice(2));

const QUOTED_SEGMENT_RE = /"([^"]+)"|“([^”]+)”/g;
const SPEECH_PROCESS_RE =
  /\b(?:asks?|answers?|explains?|tells?|replies?|says?|said|argues?|states?|notes? inwardly)\b/gi;
const NON_VISUAL_THOUGHT_RE =
  /\b(?:thinks?|thought|notes? inwardly|realizes?|understands?|wonders?|remembers?)\b/gi;
const MALFORMED_SAFETY_RE =
  /\b(?:dramatic|strict) royal punishment (?:him|her|them)\b/gi;

async function main() {
  await mkdir(config.outputDir, { recursive: true });
  const caseResults = config.analyzeOnly
    ? await loadStoredCaseResults()
    : await runRemoteMatrix();

  const report = {
    generatedAt: new Date().toISOString(),
    articleIds: config.articleIds,
    repeats: config.repeats,
    analyzeOnly: config.analyzeOnly,
    cases: caseResults,
  };
  await writeFile(
    path.join(config.outputDir, 'report.json'),
    JSON.stringify(report, null, 2),
    'utf8',
  );
  await writeFile(
    path.join(config.outputDir, 'REPORT.md'),
    renderMarkdown(report),
    'utf8',
  );

  const failedRuns = caseResults.flatMap((item) =>
    item.runs.filter((run) => run.error || run.integrityFailures?.length),
  );
  console.log(`\n[done] ${path.join(config.outputDir, 'REPORT.md')}`);
  if (failedRuns.length) {
    throw new Error(`${failedRuns.length} run(s) failed or violated integrity`);
  }
}

async function runRemoteMatrix() {
  await waitForHealth();
  const listed = await bridge('article.list', {});
  const articles = listed.articles ?? listed.payload?.articles ?? [];
  const selected = config.articleIds.map((articleId) => {
    const article = articles.find((item) => Number(item.id) === articleId);
    if (!article) throw new Error(`articleId ${articleId} not found`);
    return article;
  });
  const caseResults = [];
  for (const article of selected) {
    console.log(
      `\n=== article ${article.id}: ${article.title} (${article.sentences?.length ?? article.sentenceCount} slots) ===`,
    );
    const runs = [];
    for (let runIndex = 0; runIndex < config.repeats; runIndex += 1) {
      console.log(`[run ${runIndex + 1}/${config.repeats}] open local review`);
      const review = unwrap(
        await bridge('pictureBook.promptReview', {
          articleId: article.id,
          regenerate: false,
        }),
      );
      const reviewId = String(review.reviewId ?? '').trim();
      if (!reviewId) throw new Error(`article ${article.id}: missing reviewId`);

      const startedAt = Date.now();
      try {
        console.log(`[run ${runIndex + 1}/${config.repeats}] refresh chapter plan`);
        const refreshed = unwrap(
          await bridge(
            'pictureBook.refreshPromptReview',
            {
              reviewId,
              target: 'chapterPlan',
              bookDescription: review.bookDescription ?? '',
              bookCharacters: review.bookCharacters ?? [],
              newCharacters: review.newCharacters ?? [],
              chapterDescription: review.chapterDescription ?? '',
              scenes: review.scenes ?? [],
            },
            600_000,
          ),
        );
        const result = evaluateRun({
          article,
          plan: refreshed,
          runIndex,
          durationMs: Date.now() - startedAt,
        });
        runs.push(result);
        console.log(
          `[run ${runIndex + 1}] scenes=${result.sceneCount} boundaries=${result.boundaries.join(',')} integrity=${result.integrityFailures.length ? result.integrityFailures.join('|') : 'ok'}`,
        );
      } catch (error) {
        runs.push({
          runIndex,
          durationMs: Date.now() - startedAt,
          error: error instanceof Error ? error.message : String(error),
        });
        console.error(`[run ${runIndex + 1}] failed: ${runs.at(-1).error}`);
      }
    }

    const result = {
      articleId: article.id,
      title: article.title,
      seriesTitle: article.seriesTitle ?? '',
      sentenceCount: article.sentences?.length ?? article.sentenceCount ?? 0,
      runs,
      variability: summarizeVariability(runs),
    };
    caseResults.push(result);
    await writeFile(
      path.join(config.outputDir, `article-${article.id}.json`),
      JSON.stringify(result, null, 2),
      'utf8',
    );
  }
  return caseResults;
}

async function loadStoredCaseResults() {
  const results = [];
  for (const articleId of config.articleIds) {
    const stored = JSON.parse(
      await readFile(
        path.join(config.outputDir, `article-${articleId}.json`),
        'utf8',
      ),
    );
    const runs = stored.runs.map((run) => {
      if (run.error) return run;
      const allSceneText = run.scenes
        .map((scene) => scene.sceneDescription)
        .join('\n');
      return {
        ...run,
        quotedTextHits: quotedSegments(allSceneText).length,
        quotedDialogueCandidateHits:
          quotedDialogueCandidates(allSceneText).length,
        integrityFailures: validateIntegrity(
          run.scenes,
          Number(stored.sentenceCount),
        ),
      };
    });
    const recalculated = {
      ...stored,
      runs,
      variability: summarizeVariability(runs),
    };
    await writeFile(
      path.join(config.outputDir, `article-${articleId}.json`),
      JSON.stringify(recalculated, null, 2),
      'utf8',
    );
    results.push(recalculated);
  }
  return results;
}

function evaluateRun({ article, plan, runIndex, durationMs }) {
  const sentenceSlots = Array.isArray(article.sentences) ? article.sentences : [];
  const scenes = (Array.isArray(plan.scenes) ? plan.scenes : []).map((scene) => {
    const start = Number(scene.sentenceStartIndex);
    const end = Number(scene.sentenceEndIndex);
    return {
      pageIndex: Number(scene.pageIndex),
      sentenceStartIndex: start,
      sentenceEndIndex: end,
      span: end - start + 1,
      sceneDescription: String(scene.sceneDescription ?? '').trim(),
      sourceText: sentenceSlots.slice(start, end + 1).join(' ').trim(),
    };
  });
  const sceneTexts = scenes.map((scene) => scene.sceneDescription);
  const allSceneText = sceneTexts.join('\n');
  const integrityFailures = validateIntegrity(scenes, sentenceSlots.length);
  return {
    runIndex,
    durationMs,
    sceneCount: scenes.length,
    chapterDescription: String(plan.chapterDescription ?? '').trim(),
    boundaries: scenes.slice(0, -1).map((scene) => scene.sentenceEndIndex),
    spans: scenes.map((scene) => scene.span),
    quotedTextHits: quotedSegments(allSceneText).length,
    quotedDialogueCandidateHits:
      quotedDialogueCandidates(allSceneText).length,
    speechProcessHits: countMatches(allSceneText, SPEECH_PROCESS_RE),
    nonVisualThoughtHits: countMatches(allSceneText, NON_VISUAL_THOUGHT_RE),
    malformedSafetyHits: countMatches(allSceneText, MALFORMED_SAFETY_RE),
    integrityFailures,
    scenes,
  };
}

function validateIntegrity(scenes, sentenceCount) {
  const failures = [];
  if (scenes.length < 1 || scenes.length > 12) {
    failures.push(`sceneCount=${scenes.length}`);
    return failures;
  }
  if (scenes.some((scene, index) => scene.pageIndex !== index)) {
    failures.push('pageIndex_not_sequential');
  }
  if (scenes.some((scene) => !scene.sceneDescription)) {
    failures.push('empty_scene_description');
  }
  if (
    scenes[0].sentenceStartIndex !== 0 ||
    scenes.at(-1).sentenceEndIndex !== sentenceCount - 1 ||
    scenes.some(
      (scene, index) =>
        index > 0 &&
        scene.sentenceStartIndex !== scenes[index - 1].sentenceEndIndex + 1,
    )
  ) {
    failures.push('coverage_not_contiguous_full');
  }
  const spans = scenes.map((scene) => scene.span);
  const prefix = spans.slice(0, -1);
  const oneSentencePrefixCount = prefix.filter((span) => span <= 1).length;
  if (
    scenes.length >= 4 &&
    oneSentencePrefixCount >= Math.max(3, Math.ceil(prefix.length * 0.6)) &&
    spans.at(-1) >= Math.max(4, Math.ceil(sentenceCount * 0.35))
  ) {
    failures.push('one_sentence_prefix_tail_dump');
  }
  if (
    scenes.some(
      (scene) => quotedDialogueCandidates(scene.sceneDescription).length > 0,
    )
  ) {
    failures.push('quoted_dialogue_candidate_in_scene_description');
  }
  return failures;
}

function summarizeVariability(runs) {
  const successful = runs.filter((run) => !run.error);
  if (!successful.length) {
    return {
      successfulRuns: 0,
      failedRuns: runs.length,
      level: 'unavailable',
    };
  }
  const counts = successful.map((run) => run.sceneCount);
  const mean = counts.reduce((sum, value) => sum + value, 0) / counts.length;
  const variance =
    counts.reduce((sum, value) => sum + (value - mean) ** 2, 0) /
    counts.length;
  const similarities = [];
  for (let i = 0; i < successful.length; i += 1) {
    for (let j = i + 1; j < successful.length; j += 1) {
      similarities.push(
        jaccard(successful[i].boundaries, successful[j].boundaries),
      );
    }
  }
  const boundaryJaccardMean = similarities.length
    ? similarities.reduce((sum, value) => sum + value, 0) / similarities.length
    : 1;
  const countRange = Math.max(...counts) - Math.min(...counts);
  const level =
    countRange <= 1 && boundaryJaccardMean >= 0.65
      ? 'low'
      : countRange <= 2 && boundaryJaccardMean >= 0.45
        ? 'medium'
        : 'high';
  const boundaryFrequency = new Map();
  for (const run of successful) {
    for (const boundary of run.boundaries) {
      boundaryFrequency.set(boundary, (boundaryFrequency.get(boundary) ?? 0) + 1);
    }
  }
  return {
    successfulRuns: successful.length,
    failedRuns: runs.length - successful.length,
    sceneCounts: counts,
    sceneCountMean: Number(mean.toFixed(2)),
    sceneCountStdDev: Number(Math.sqrt(variance).toFixed(2)),
    sceneCountRange: countRange,
    boundaryJaccardMean: Number(boundaryJaccardMean.toFixed(3)),
    boundaryFrequency: Object.fromEntries(
      [...boundaryFrequency.entries()].sort((a, b) => a[0] - b[0]),
    ),
    level,
  };
}

function jaccard(left, right) {
  const a = new Set(left);
  const b = new Set(right);
  const union = new Set([...a, ...b]);
  if (!union.size) return 1;
  let intersection = 0;
  for (const value of a) if (b.has(value)) intersection += 1;
  return intersection / union.size;
}

function countMatches(text, regex) {
  const flags = regex.flags.includes('g') ? regex.flags : `${regex.flags}g`;
  return [...text.matchAll(new RegExp(regex.source, flags))].length;
}

function quotedSegments(text) {
  return [...text.matchAll(new RegExp(QUOTED_SEGMENT_RE.source, 'g'))].map(
    (match) => String(match[1] ?? match[2] ?? '').trim(),
  );
}

function quotedDialogueCandidates(text) {
  return quotedSegments(text).filter((content) => {
    if (!content) return false;
    const words = content.split(/\s+/).filter(Boolean);
    const labelLike =
      words.length <= 5 &&
      !/[!?]/.test(content) &&
      /^[A-Z0-9][A-Z0-9 &'/-]*$/.test(content);
    if (labelLike) return false;
    return (
      words.length >= 6 ||
      /[!?]/.test(content) ||
      /\b(?:i|i'm|i'll|me|my|you|your|we|our|please|oh|dear)\b/i.test(
        content,
      )
    );
  });
}

function renderMarkdown(report) {
  const lines = [
    '# Chapter plan v4 repeated variance retest',
    '',
    `Generated: ${report.generatedAt}`,
    `Repeats per article: ${report.repeats}`,
    '',
    '## Summary',
    '',
    '| Article | Slots | Scene counts | Count sd | Boundary Jaccard | Variability |',
    '|---|---:|---|---:|---:|---|',
  ];
  for (const item of report.cases) {
    const variability = item.variability;
    lines.push(
      `| ${item.articleId} ${item.title} | ${item.sentenceCount} | ${(variability.sceneCounts ?? []).join(' / ')} | ${variability.sceneCountStdDev ?? '-'} | ${variability.boundaryJaccardMean ?? '-'} | ${variability.level} |`,
    );
  }
  for (const item of report.cases) {
    lines.push(
      '',
      `## ${item.articleId} ${item.title}`,
      '',
      `- Series: ${item.seriesTitle}`,
      `- Variability: ${JSON.stringify(item.variability)}`,
    );
    for (const run of item.runs) {
      lines.push('', `### Run ${run.runIndex + 1}`, '');
      if (run.error) {
        lines.push(`- Error: ${run.error}`);
        continue;
      }
      lines.push(
        `- Scenes: ${run.sceneCount}`,
        `- Boundaries: ${run.boundaries.join(', ')}`,
        `- Spans: ${run.spans.join(', ')}`,
        `- Integrity: ${run.integrityFailures.length ? run.integrityFailures.join(', ') : 'ok'}`,
        `- Quoted text / dialogue candidates: ${run.quotedTextHits} / ${run.quotedDialogueCandidateHits}`,
        `- Speech-process hits: ${run.speechProcessHits}`,
        `- Non-visible thought hits: ${run.nonVisualThoughtHits}`,
        `- Malformed safety hits: ${run.malformedSafetyHits}`,
        '',
      );
      for (const scene of run.scenes) {
        lines.push(
          `#### Scene ${scene.pageIndex} [${scene.sentenceStartIndex}-${scene.sentenceEndIndex}]`,
          '',
          `Source: ${scene.sourceText}`,
          '',
          `Description: ${scene.sceneDescription}`,
          '',
        );
      }
    }
  }
  return `${lines.join('\n')}\n`;
}

function parseArgs(argv) {
  const result = {
    baseUrl: 'http://127.0.0.1:39317',
    articleIds: [46, 68, 91],
    repeats: 3,
    outputDir: path.join(root, 'output', 'chapter-plan-variance-v4'),
    analyzeOnly: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--baseUrl') result.baseUrl = argv[++index];
    else if (arg === '--articleIds') {
      result.articleIds = argv[++index]
        .split(',')
        .map((value) => Number(value.trim()))
        .filter((value) => Number.isInteger(value) && value > 0);
    } else if (arg === '--repeats') {
      result.repeats = Number(argv[++index]);
    } else if (arg === '--outputDir') {
      result.outputDir = path.resolve(argv[++index]);
    } else if (arg === '--analyzeOnly') {
      result.analyzeOnly = true;
    }
  }
  if (!result.articleIds.length) throw new Error('No valid articleIds');
  if (!Number.isInteger(result.repeats) || result.repeats < 1) {
    throw new Error('repeats must be a positive integer');
  }
  return result;
}

async function request(route, body, timeoutMs = 120_000) {
  const response = await fetch(`${config.baseUrl}${route}`, {
    method: body == null ? 'GET' : 'POST',
    headers: body == null ? undefined : { 'Content-Type': 'application/json' },
    body: body == null ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(timeoutMs),
  });
  const text = await response.text();
  let json;
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    throw new Error(`${route} non-JSON ${response.status}: ${text.slice(0, 500)}`);
  }
  if (!response.ok || json.ok === false) {
    const detail = json.error ?? json.message ?? text.slice(0, 1000);
    throw new Error(
      `${route} failed ${response.status}: ${typeof detail === 'string' ? detail : JSON.stringify(detail)}`,
    );
  }
  return json.result ?? json.payload ?? json;
}

async function bridge(type, payload, timeoutMs = 120_000) {
  return request('/bridge', { type, payload }, timeoutMs);
}

function unwrap(value) {
  if (
    value &&
    typeof value === 'object' &&
    value.payload &&
    typeof value.payload === 'object'
  ) {
    return value.payload;
  }
  return value;
}

async function waitForHealth() {
  const health = await request('/health', null, 10_000);
  if (!health.ok || !health.webReady) {
    throw new Error(`QA not ready: ${JSON.stringify(health)}`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
