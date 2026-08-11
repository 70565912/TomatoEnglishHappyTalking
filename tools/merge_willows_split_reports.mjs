#!/usr/bin/env node

import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

function values(name) {
  const result = [];
  for (let index = 0; index < process.argv.length; index += 1) {
    if (process.argv[index] === name && process.argv[index + 1]) {
      result.push(process.argv[index + 1]);
    }
  }
  return result;
}

function value(name) {
  return values(name).at(-1);
}

const inputPaths = values('--input').map((entry) => path.resolve(entry));
const replacementPaths = values('--replacement').map((entry) =>
  path.resolve(entry),
);
const outputRoot = path.resolve(value('--output') ?? '');
const parsedReportPath = path.resolve(value('--parsed-report') ?? '');
if (inputPaths.length < 2 || !value('--output') || !value('--parsed-report')) {
  throw new Error(
    'Usage: node merge_willows_split_reports.mjs ' +
      '--input <group-report.json> [--input ...] ' +
      '--parsed-report <full-parser-report.json> --output <directory>',
  );
}

const parsedBaseline = JSON.parse(await readFile(parsedReportPath, 'utf8'));
const baselineSummary = parsedBaseline.summary;
if (!baselineSummary?.combinedSourceSha256 || !baselineSummary?.modelSha256) {
  throw new Error('Parsed baseline is missing source/model fingerprints');
}

const groupReports = [];
for (const inputPath of [...inputPaths, ...replacementPaths]) {
  const report = JSON.parse(await readFile(inputPath, 'utf8'));
  if (!Array.isArray(report.chapters) || !report.summary) {
    throw new Error(`Invalid group report: ${inputPath}`);
  }
  for (const key of ['parserVersion', 'modelSha256', 'solverVersion']) {
    if (report.summary[key] !== baselineSummary[key] && key !== 'solverVersion') {
      throw new Error(
        `Group report ${key} differs from parsed baseline: ${inputPath}`,
      );
    }
  }
  if (report.summary.nativeCalls !== 0 || !report.summary.reusedParsedReport) {
    throw new Error(`Group report did not reuse parsed data: ${inputPath}`);
  }
  groupReports.push({
    inputPath,
    report,
    replacement: replacementPaths.includes(inputPath),
  });
}

const chapterByEpisode = new Map();
for (const { report, replacement } of groupReports) {
  for (const chapter of report.chapters) {
    if (!replacement && chapterByEpisode.has(chapter.episode)) {
      throw new Error(`Duplicate base chapter: ${chapter.episode}`);
    }
    chapterByEpisode.set(chapter.episode, chapter);
  }
}
const chapters = [...chapterByEpisode.values()].sort((left, right) =>
  left.episode.localeCompare(right.episode),
);
const expectedEpisodes = Array.from(
  { length: 62 },
  (_, index) => `E${String(index + 1).padStart(2, '0')}`,
);
const actualEpisodes = chapters.map((chapter) => chapter.episode);
if (
  actualEpisodes.length !== expectedEpisodes.length ||
  actualEpisodes.some((episode, index) => episode !== expectedEpisodes[index])
) {
  throw new Error(
    `Merged chapter coverage mismatch: ${actualEpisodes.join(',')}`,
  );
}
if (chapters.some((chapter) => chapter.parserHealthy !== true)) {
  throw new Error('At least one merged chapter is not parser-healthy');
}

const sum = (key) =>
  chapters.reduce((total, chapter) => total + Number(chapter[key] ?? 0), 0);
const firstSummary = groupReports[0].report.summary;
for (const { inputPath, report } of groupReports.slice(1)) {
  for (const key of [
    'sentenceSplitVersion',
    'reviewedVersion',
    'solverVersion',
    'parserVersion',
    'modelSha256',
  ]) {
    if (report.summary[key] !== firstSummary[key]) {
      throw new Error(`Group ${key} mismatch: ${inputPath}`);
    }
  }
}

const summary = {
  sentenceSplitVersion: firstSummary.sentenceSplitVersion,
  reviewedVersion: firstSummary.reviewedVersion,
  solverVersion: firstSummary.solverVersion,
  parserVersion: firstSummary.parserVersion,
  modelSha256: firstSummary.modelSha256,
  combinedSourceSha256: baselineSummary.combinedSourceSha256,
  nativeCalls: 0,
  reusedParsedReport: parsedReportPath,
  parallelGroupCount: groupReports.length,
  replacementChapterCount: replacementPaths.length
    ? groupReports
        .filter((item) => item.replacement)
        .reduce((total, item) => total + item.report.chapters.length, 0)
    : 0,
  chapterCount: chapters.length,
  v2V3DifferentChapterCount: chapters.filter(
    (chapter) => chapter.v2V3Different === true,
  ).length,
  parserHealthyChapterCount: chapters.filter(
    (chapter) => chapter.parserHealthy === true,
  ).length,
  sourceWordCount: sum('sourceWordCount'),
  oldSentenceCount: sum('oldSentenceCount'),
  v3OriginalSentenceCount: sum('v3OriginalSentenceCount'),
  v3SentenceCount: sum('v3SentenceCount'),
  aiReviewOriginalCount: sum('aiReviewOriginalCount'),
  emergencyOriginalCount: sum('emergencyOriginalCount'),
  over16UnpunctuatedSegmentCount: sum('over16UnpunctuatedSegmentCount'),
  newUnder8FragmentCount: sum('newUnder8FragmentCount'),
  nonPunctuationCutCount: sum('nonPunctuationCutCount'),
  emergencyCutCount: sum('emergencyCutCount'),
  shortQuoteInternalCandidateCount: sum('shortQuoteInternalCandidateCount'),
  shortQuoteInternalSelectedCount: sum('shortQuoteInternalSelectedCount'),
  insideQuotedSpeechCutCount: sum('insideQuotedSpeechCutCount'),
  quoteEdgeCutCount: sum('quoteEdgeCutCount'),
};

await mkdir(outputRoot, { recursive: true });
for (const { inputPath, report } of groupReports) {
  const groupRoot = path.dirname(inputPath);
  for (const chapter of report.chapters) {
    await copyFile(
      path.join(groupRoot, `${chapter.episode}.md`),
      path.join(outputRoot, `${chapter.episode}.md`),
    );
  }
}
await writeFile(
  path.join(outputRoot, 'willows-v3-report.json'),
  `${JSON.stringify(
    {
      schemaVersion: 'willows_sentence_split_corpus_v3_1',
      summary,
      chapters,
    },
    null,
    2,
  )}\n`,
  'utf8',
);
await writeFile(
  path.join(outputRoot, 'README.md'),
  `# Willows V3 local corpus report

- Chapters: ${summary.chapterCount}
- Parser/model: ${summary.parserVersion} / \`${summary.modelSha256}\`
- Reused parser report: \`${summary.reusedParsedReport}\`
- Native UDPipe calls: ${summary.nativeCalls}
- Parallel score groups: ${summary.parallelGroupCount}
- Current-DB replacement chapters: ${summary.replacementChapterCount}
- Original orthographic sentences: ${summary.v3OriginalSentenceCount}
- Local V3 sentences: ${summary.v3SentenceCount}
- AI-review originals: ${summary.aiReviewOriginalCount}
- Emergency originals: ${summary.emergencyOriginalCount}
- New fragments below 8 words: ${summary.newUnder8FragmentCount}
- Unpunctuated segments above 16 words: ${summary.over16UnpunctuatedSegmentCount}
- Non-punctuation cuts: ${summary.nonPunctuationCutCount}
- Emergency cuts: ${summary.emergencyCutCount}
- Short-quote internal candidates: ${summary.shortQuoteInternalCandidateCount}
- Short-quote internal selected cuts: ${summary.shortQuoteInternalSelectedCount}
- Selected quote-internal cuts: ${summary.insideQuotedSpeechCutCount}
- Selected quote-edge cuts: ${summary.quoteEdgeCutCount}

This merged report is read-only. It does not authorize database, TTS,
subtitle, video, picture mapping, or NAS migration.
`,
  'utf8',
);

console.log(
  JSON.stringify(
    {
      outputRoot,
      chapterCount: summary.chapterCount,
      nativeCalls: summary.nativeCalls,
      parserHealthyChapterCount: summary.parserHealthyChapterCount,
    },
    null,
    2,
  ),
);
