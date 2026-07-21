/**
 * Live retest: resubmit the two latest Alice court chapters via article.create
 * (pictureBookEnabled) so chapter planning uses the real save path + optimized prompt.
 *
 * Prerequisites: Release app with QA remote on 127.0.0.1:39317
 *
 * Usage:
 *   node tools/qa_chapter_plan_prompt_opt_retest.mjs
 */
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '..');
const outDir = path.join(root, 'output', 'prompt-opt-retest');
const baseUrl = 'http://127.0.0.1:39317';
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const QUOTED_SEGMENT_RE = /"([^"]+)"|“([^”]+)”/g;

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
  if (result && typeof result === 'object' && result.payload != null) {
    return result.payload;
  }
  return result;
}

function sceneSummary(review) {
  const scenes = Array.isArray(review?.scenes) ? review.scenes : [];
  return {
    sceneCount: scenes.length,
    chapterDescription: String(review?.chapterDescription ?? '').trim(),
    chapterDescriptionChars: String(review?.chapterDescription ?? '').trim()
      .length,
    ranges: scenes.map((scene) => ({
      pageIndex: scene.pageIndex,
      sentenceStartIndex: scene.sentenceStartIndex,
      sentenceEndIndex: scene.sentenceEndIndex,
      span:
        Number(scene.sentenceEndIndex) - Number(scene.sentenceStartIndex) + 1,
      sceneDescription: String(scene.sceneDescription ?? '').trim(),
      sceneDescriptionChars: String(scene.sceneDescription ?? '').trim().length,
      paragraphPreview: String(scene.paragraphText ?? '')
        .replace(/\s+/g, ' ')
        .trim()
        .slice(0, 120),
    })),
  };
}

function evennessScore(ranges, sentenceCount) {
  if (!ranges.length || sentenceCount <= 0) {
    return { avgSpan: 0, stdDev: 0, maxSpan: 0, minSpan: 0, looksEvenSplit: false };
  }
  const spans = ranges.map((r) => r.span);
  const avg = spans.reduce((a, b) => a + b, 0) / spans.length;
  const variance =
    spans.reduce((sum, s) => sum + (s - avg) ** 2, 0) / spans.length;
  const stdDev = Math.sqrt(variance);
  const ideal = sentenceCount / ranges.length;
  // Placeholder even-split usually keeps spans within ~1 of ideal.
  const nearIdeal = spans.every((s) => Math.abs(s - ideal) <= 1.5);
  return {
    avgSpan: Number(avg.toFixed(2)),
    stdDev: Number(stdDev.toFixed(2)),
    maxSpan: Math.max(...spans),
    minSpan: Math.min(...spans),
    idealSpan: Number(ideal.toFixed(2)),
    looksEvenSplit: nearIdeal && ranges.length === 12,
  };
}

function sceneIntegrity(ranges, sentenceCount) {
  const spans = ranges.map((range) => range.span);
  const prefixSpans = spans.slice(0, -1);
  const oneSentencePrefixCount = prefixSpans.filter((span) => span <= 1).length;
  const lastSpan = spans.at(-1) ?? 0;
  const sequentialIndexes = ranges.every(
    (range, index) => Number(range.pageIndex) === index,
  );
  const contiguousCoverage =
    ranges.length > 0 &&
    Number(ranges[0].sentenceStartIndex) === 0 &&
    Number(ranges.at(-1).sentenceEndIndex) === sentenceCount - 1 &&
    ranges.every(
      (range, index) =>
        index === 0 ||
        Number(range.sentenceStartIndex) ===
          Number(ranges[index - 1].sentenceEndIndex) + 1,
    );
  const hasEmptySceneDescription = ranges.some(
    (range) => !range.sceneDescription,
  );
  const hasQuotedDialogueCandidate = ranges.some(
    (range) => quotedDialogueCandidates(range.sceneDescription).length > 0,
  );
  const looksTailDump =
    ranges.length >= 4 &&
    oneSentencePrefixCount >= Math.max(3, Math.ceil(prefixSpans.length * 0.6)) &&
    lastSpan >= Math.max(4, Math.ceil(sentenceCount * 0.35));
  return {
    sequentialIndexes,
    contiguousCoverage,
    hasEmptySceneDescription,
    hasQuotedDialogueCandidate,
    looksTailDump,
    oneSentencePrefixCount,
    lastSpan,
  };
}

function integrityFailures(label, result) {
  const failures = [];
  if (result.sceneCount < 1 || result.sceneCount > 12) {
    failures.push(`${label}: sceneCount=${result.sceneCount}`);
  }
  if (!result.integrity.sequentialIndexes) {
    failures.push(`${label}: pageIndex is not sequential`);
  }
  if (!result.integrity.contiguousCoverage) {
    failures.push(`${label}: sentence coverage is not contiguous/full`);
  }
  if (result.integrity.hasEmptySceneDescription) {
    failures.push(`${label}: empty sceneDescription`);
  }
  if (result.integrity.hasQuotedDialogueCandidate) {
    failures.push(`${label}: quoted dialogue candidate remains in sceneDescription`);
  }
  if (result.integrity.looksTailDump) {
    failures.push(`${label}: one-sentence prefix + tail dump detected`);
  }
  return failures;
}

function quotedDialogueCandidates(text) {
  return [...text.matchAll(new RegExp(QUOTED_SEGMENT_RE.source, 'g'))]
    .map((match) => String(match[1] ?? match[2] ?? '').trim())
    .filter((content) => {
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

async function createAndReview({
  label,
  title,
  content,
  seriesId,
  seriesTitle,
}) {
  console.log(`\n=== ${label}: create ${title} ===`);
  const created = await bridge(
    'article.create',
    {
      title,
      content,
      seriesId,
      seriesTitle,
      pictureBookEnabled: true,
    },
    600_000,
  );
  const article = created?.article ?? created;
  const articleId = article?.id;
  if (articleId == null) {
    throw new Error(`${label}: article.create returned no id: ${JSON.stringify(created).slice(0, 1000)}`);
  }
  console.log(`[ok] ${label} articleId=${articleId} sentences=${article?.sentences?.length ?? '?'}`);

  // Wait briefly for chapter plan persistence / UI events.
  await wait(1500);

  const review = await bridge(
    'pictureBook.promptReview',
    { articleId, regenerate: false },
    120_000,
  );
  const summary = sceneSummary(review);
  const sentenceCount = Array.isArray(article?.sentences)
    ? article.sentences.length
    : 0;
  const evenness = evennessScore(summary.ranges, sentenceCount);
  const integrity = sceneIntegrity(summary.ranges, sentenceCount);

  const result = {
    label,
    requestedTitle: title,
    articleId,
    savedTitle: article?.title ?? title,
    sentenceCount,
    seriesId: review?.seriesId ?? seriesId,
    seriesTitle: review?.bookTitle ?? seriesTitle,
    reviewId: review?.reviewId ?? null,
    ...summary,
    evenness,
    integrity,
    emptySceneDescriptions: summary.ranges.every(
      (r) => !r.sceneDescription,
    ),
  };

  await writeFile(
    path.join(outDir, `${label}-create.json`),
    JSON.stringify(
      {
        article: {
          id: articleId,
          title: article?.title ?? title,
          sentences: article?.sentences ?? [],
        },
        review,
      },
      null,
      2,
    ),
    'utf8',
  );
  await writeFile(
    path.join(outDir, `${label}-summary.json`),
    JSON.stringify(result, null, 2),
    'utf8',
  );
  console.log(
    `[ok] ${label} scenes=${result.sceneCount} evenSplit=${result.evenness.looksEvenSplit} emptyDesc=${result.emptySceneDescriptions}`,
  );
  return result;
}

async function main() {
  await mkdir(outDir, { recursive: true });
  const health = await request('/health');
  if (!health?.ok || !health?.webReady) {
    throw new Error(`QA not ready: ${JSON.stringify(health)}`);
  }
  await writeFile(
    path.join(outDir, 'health.json'),
    JSON.stringify(health, null, 2),
    'utf8',
  );

  const baseline = JSON.parse(
    await readFile(path.join(outDir, 'baseline.json'), 'utf8'),
  );
  const contentA = await readFile(
    path.join(outDir, 'article-a-content.txt'),
    'utf8',
  );
  const contentB = await readFile(
    path.join(outDir, 'article-b-content.txt'),
    'utf8',
  );

  // article-a = id 98 E38, article-b = id 97 E37
  const seriesTitle =
    baseline?.articles?.[0]?.seriesTitle ||
    baseline?.seriesTitle ||
    "Alice's Adventures in Wonderland";

  // Resolve series id from live app list.
  const seriesList = await bridge('series.list', {});
  const seriesItems = Array.isArray(seriesList?.series)
    ? seriesList.series
    : Array.isArray(seriesList)
      ? seriesList
      : [];
  const series =
    seriesItems.find((s) => s.title === seriesTitle) ||
    seriesItems.find((s) =>
      String(s.title || '').includes("Alice's Adventures in Wonderland"),
    );
  if (!series?.id) {
    throw new Error(
      `Series not found: ${seriesTitle}; have=${seriesItems.map((s) => s.title).join(' | ')}`,
    );
  }
  console.log(`[ok] series id=${series.id} title=${series.title}`);

  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const resultA = await createAndReview({
    label: 'retest-e38',
    title: `E38 Retest Prompt Opt ${stamp.slice(0, 16)}`,
    content: contentA,
    seriesId: series.id,
    seriesTitle: series.title,
  });
  const resultB = await createAndReview({
    label: 'retest-e37',
    title: `E37 Retest Prompt Opt ${stamp.slice(0, 16)}`,
    content: contentB,
    seriesId: series.id,
    seriesTitle: series.title,
  });

  const baselineByTitle = Object.fromEntries(
    (baseline.articles || []).map((a) => [a.title, a]),
  );
  const baselineE38 =
    baselineByTitle['E38 - The Court Trial Scene'] || baseline.articles?.[0];
  const baselineE37 =
    baselineByTitle["E37 - The Hatter's Testimony"] || baseline.articles?.[1];
  const baselineE38Scenes =
    baselineE38?.previousSceneCount ?? baselineE38?.sceneCount ?? 12;
  const baselineE37Scenes =
    baselineE37?.previousSceneCount ?? baselineE37?.sceneCount ?? 12;
  const failures = [
    ...integrityFailures('E38', resultA),
    ...integrityFailures('E37', resultB),
  ];
  const compare = {
    testedAt: new Date().toISOString(),
    promptChange:
      'General visual focus + range-local actor fidelity + cause/result/recovery + adjacent-boundary audit + strict generated-plan validation.',
    baseline: {
      e38: baselineE38,
      e37: baselineE37,
    },
    retest: {
      e38: resultA,
      e37: resultB,
    },
    verdict: {
      e38SceneDelta: (resultA.sceneCount ?? 0) - baselineE38Scenes,
      e37SceneDelta: (resultB.sceneCount ?? 0) - baselineE37Scenes,
      e38StillCap12: resultA.sceneCount === 12,
      e37StillCap12: resultB.sceneCount === 12,
      e38LooksEvenSplit: resultA.evenness.looksEvenSplit,
      e37LooksEvenSplit: resultB.evenness.looksEvenSplit,
      e38HasAiDescriptions: !resultA.emptySceneDescriptions,
      e37HasAiDescriptions: !resultB.emptySceneDescriptions,
      integrityFailures: failures,
    },
  };

  await writeFile(
    path.join(outDir, 'compare.json'),
    JSON.stringify(compare, null, 2),
    'utf8',
  );

  const report = [
    '# Chapter plan prompt opt retest',
    '',
    `Tested at: ${compare.testedAt}`,
    `Series: ${series.title} (id=${series.id})`,
    '',
    '## Baseline (pre-opt, from DB)',
    `- E38 id=${compare.baseline.e38?.id} scenes=${baselineE38Scenes}`,
    `- E37 id=${compare.baseline.e37?.id} scenes=${baselineE37Scenes}`,
    '',
    '## Retest (article.create + pictureBookEnabled)',
    `- E38 new id=${resultA.articleId} scenes=${resultA.sceneCount} span ${resultA.evenness.minSpan}-${resultA.evenness.maxSpan} (std=${resultA.evenness.stdDev}) evenSplit=${resultA.evenness.looksEvenSplit} aiDesc=${!resultA.emptySceneDescriptions}`,
    `- E37 new id=${resultB.articleId} scenes=${resultB.sceneCount} span ${resultB.evenness.minSpan}-${resultB.evenness.maxSpan} (std=${resultB.evenness.stdDev}) evenSplit=${resultB.evenness.looksEvenSplit} aiDesc=${!resultB.emptySceneDescriptions}`,
    '',
    '## Verdict',
    `- E38 scene delta: ${compare.verdict.e38SceneDelta} (stillCap12=${compare.verdict.e38StillCap12})`,
    `- E37 scene delta: ${compare.verdict.e37SceneDelta} (stillCap12=${compare.verdict.e37StillCap12})`,
    `- Even-split placeholder? E38=${compare.verdict.e38LooksEvenSplit} E37=${compare.verdict.e37LooksEvenSplit}`,
    `- AI scene descriptions present? E38=${compare.verdict.e38HasAiDescriptions} E37=${compare.verdict.e37HasAiDescriptions}`,
    `- Integrity E38: ${JSON.stringify(resultA.integrity)}`,
    `- Integrity E37: ${JSON.stringify(resultB.integrity)}`,
    `- Integrity failures: ${failures.length ? failures.join(' | ') : 'none'}`,
    '',
    '## Scene ranges',
    '### E38',
    ...resultA.ranges.map(
      (r) =>
        `- p${r.pageIndex}: ${r.sentenceStartIndex}-${r.sentenceEndIndex} (${r.span}) ${r.sceneDescription.slice(0, 100)}`,
    ),
    '',
    '### E37',
    ...resultB.ranges.map(
      (r) =>
        `- p${r.pageIndex}: ${r.sentenceStartIndex}-${r.sentenceEndIndex} (${r.span}) ${r.sceneDescription.slice(0, 100)}`,
    ),
    '',
  ].join('\n');

  await writeFile(path.join(outDir, 'REVIEW.md'), report, 'utf8');
  console.log('\n' + report);
  console.log(`[done] wrote ${path.join(outDir, 'REVIEW.md')}`);
  if (failures.length) {
    throw new Error(`Chapter-plan integrity check failed: ${failures.join(' | ')}`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
