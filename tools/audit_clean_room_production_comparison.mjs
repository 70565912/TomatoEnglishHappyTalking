#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';

function fail(message = '') {
  if (message) console.error(message);
  console.error(
    'Usage: node tools/audit_clean_room_production_comparison.mjs ' +
      '--pair BASELINE.json=CANDIDATE.json [--pair ...] ' +
      '--json OUTPUT.json --markdown OUTPUT.md [--approvals APPROVALS.json]',
  );
  process.exit(2);
}

function argumentsOf(argv) {
  const result = { pairs: [], json: '', markdown: '', approvals: '' };
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!value) fail(`Missing value for ${key}`);
    if (key === '--pair') {
      const separator = value.indexOf('=');
      if (separator <= 0 || separator === value.length - 1) fail(`Invalid pair: ${value}`);
      result.pairs.push({ baseline: value.slice(0, separator), candidate: value.slice(separator + 1) });
    } else if (key === '--json') result.json = value;
    else if (key === '--markdown') result.markdown = value;
    else if (key === '--approvals') result.approvals = value;
    else fail(`Unknown argument: ${key}`);
  }
  if (!result.pairs.length || !result.json || !result.markdown) fail();
  return result;
}

const readJson = (file) => JSON.parse(fs.readFileSync(file, 'utf8'));
const normalize = (text) => text.replace(/\s+/gu, '');
const same = (left, right) =>
  left.length === right.length && left.every((value, index) => value === right[index]);
const boundaryMap = (values) => new Map(values.map((value) => [value.afterWord, value]));
const chapterSegments = (chapter) => chapter.v4AdditiveLocalSentences ?? chapter.v3LocalSentences;
const originalSegments = (original) => original.v4AdditiveSegments ?? original.segments;
const originalWordCounts = (original) => original.v4AdditiveWordCounts ?? original.wordCounts;
const originalBoundaries = (original) => original.v4AdditiveBoundaries ?? original.boundaries;
const sha256 = (value) => createHash('sha256').update(value).digest('hex');
const approvalKey = ({
  episode, originalIndex, sourceSha256, baselineSegmentsSha256, candidateSegmentsSha256,
}) => [episode, originalIndex, sourceSha256, baselineSegmentsSha256, candidateSegmentsSha256].join(':');

function signatureOfChange(change) {
  return {
    episode: change.episode,
    originalIndex: change.originalIndex,
    sourceSha256: sha256(normalize(change.original)),
    baselineSegmentsSha256: sha256(JSON.stringify(change.baseline.segments)),
    candidateSegmentsSha256: sha256(JSON.stringify(change.candidate.segments)),
  };
}

function countBy(values, keyOf) {
  const counts = new Map();
  for (const value of values) {
    const key = String(keyOf(value));
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return Object.fromEntries(
    [...counts].sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0])),
  );
}

function wordCount(text) {
  let count = 0;
  for (const token of text.match(/\S+/gu) ?? []) {
    let start = 0;
    for (let offset = 0; offset + 1 < token.length; offset += 1) {
      const mark = token[offset];
      if (!/[;:—–,]/u.test(mark) || !/^["'“‘(\[]*[\p{L}\p{N}]/u.test(token.slice(offset + 1))) continue;
      if (/[,:]/u.test(mark) && /\d/u.test(token[offset - 1] ?? '') && /\d/u.test(token[offset + 1])) continue;
      if (/[\p{L}\p{N}]/u.test(token.slice(start, offset + 1))) count += 1;
      start = offset + 1;
    }
    if (/[\p{L}\p{N}]/u.test(token.slice(start))) count += 1;
  }
  return count;
}

function emptyStats() {
  return {
    chapters: 0, originals: 0, sentences: 0, selectedBoundariesBeforeOneWordMerge: 0,
    oneWord: 0, words2To5: 0, words6To7: 0, words8To16: 0, words17To20: 0,
    words21To24: 0, words25To27: 0, words28To30: 0, over30: 0, maximum: 0,
    emergencyBoundaries: 0, chapterRoundTripFailures: 0, originalRoundTripFailures: 0,
  };
}

function addChapter(stats, source, segments) {
  stats.chapters += 1;
  stats.sentences += segments.length;
  if (normalize(segments.join(' ')) !== normalize(source)) stats.chapterRoundTripFailures += 1;
  for (const segment of segments) {
    const count = wordCount(segment);
    const bucket = count === 1 ? 'oneWord'
      : count <= 5 ? 'words2To5'
      : count <= 7 ? 'words6To7'
      : count <= 16 ? 'words8To16'
      : count <= 20 ? 'words17To20'
      : count <= 24 ? 'words21To24'
      : count <= 27 ? 'words25To27'
      : count <= 30 ? 'words28To30' : 'over30';
    stats[bucket] += 1;
    stats.maximum = Math.max(stats.maximum, count);
  }
}

function addOriginal(stats, source, segments, boundaries) {
  stats.originals += 1;
  stats.selectedBoundariesBeforeOneWordMerge += boundaries.length;
  stats.emergencyBoundaries += boundaries.filter((value) => value.kind === 'emergency').length;
  if (normalize(segments.join(' ')) !== normalize(source)) stats.originalRoundTripFailures += 1;
}

function context(segments, counts, afterWord) {
  let end = 0;
  for (let index = 0; index < counts.length - 1; index += 1) {
    end += counts[index];
    if (end === afterWord) {
      return {
        leftSegment: segments[index], leftWords: counts[index],
        rightSegment: segments[index + 1], rightWords: counts[index + 1],
      };
    }
  }
  return null;
}

function changedBoundaries(fromMap, toMap, segments, counts) {
  return [...toMap.keys()]
    .filter((afterWord) => !fromMap.has(afterWord))
    .sort((left, right) => left - right)
    .map((afterWord) => ({ ...toMap.get(afterWord), context: context(segments, counts, afterWord) }));
}

const options = argumentsOf(process.argv.slice(2));
const baseline = emptyStats();
const candidate = emptyStats();
const changes = [];
const comparison = {
  changedChapters: 0, changedOriginals: 0, addedBoundaries: 0,
  removedBoundaries: 0, sourceAlignmentFailures: 0,
};

for (const pair of options.pairs) {
  const beforeReport = readJson(pair.baseline);
  const afterReport = readJson(pair.candidate);
  const chapters = new Map(beforeReport.chapters.map((chapter) => [chapter.episode, chapter]));
  for (const afterChapter of afterReport.chapters) {
    const beforeChapter = chapters.get(afterChapter.episode);
    if (!beforeChapter || beforeChapter.originals.length !== afterChapter.originals.length) {
      comparison.sourceAlignmentFailures += 1;
      continue;
    }
    const beforeChapterSegments = chapterSegments(beforeChapter);
    addChapter(baseline, beforeChapter.source, beforeChapterSegments);
    addChapter(candidate, afterChapter.source, afterChapter.v4AdditiveLocalSentences);
    if (!same(beforeChapterSegments, afterChapter.v4AdditiveLocalSentences)) {
      comparison.changedChapters += 1;
    }
    for (let index = 0; index < afterChapter.originals.length; index += 1) {
      const before = beforeChapter.originals[index];
      const after = afterChapter.originals[index];
      if (before.original !== after.original || before.originalIndex !== after.originalIndex) {
        comparison.sourceAlignmentFailures += 1;
        continue;
      }
      const beforeSegments = originalSegments(before);
      const beforeWordCounts = originalWordCounts(before);
      const beforeBoundaries = originalBoundaries(before);
      addOriginal(baseline, before.original, beforeSegments, beforeBoundaries);
      addOriginal(candidate, after.original, after.v4AdditiveSegments, after.v4AdditiveBoundaries);
      if (same(beforeSegments, after.v4AdditiveSegments)) continue;
      comparison.changedOriginals += 1;
      const beforeMap = boundaryMap(beforeBoundaries);
      const afterMap = boundaryMap(after.v4AdditiveBoundaries);
      const added = changedBoundaries(beforeMap, afterMap, after.v4AdditiveSegments, after.v4AdditiveWordCounts);
      const removed = changedBoundaries(afterMap, beforeMap, beforeSegments, beforeWordCounts);
      comparison.addedBoundaries += added.length;
      comparison.removedBoundaries += removed.length;
      changes.push({
        episode: afterChapter.episode, originalIndex: after.originalIndex, original: after.original,
        baseline: { segments: beforeSegments, wordCounts: beforeWordCounts, boundaries: beforeBoundaries },
        candidate: {
          segments: after.v4AdditiveSegments, wordCounts: after.v4AdditiveWordCounts,
          boundaries: after.v4AdditiveBoundaries,
        },
        added, removed,
      });
    }
  }
}

const added = changes.flatMap((change) => change.added);
const removed = changes.flatMap((change) => change.removed);
const punctuation = new Set(['strongPunctuation', 'clauseComma', 'phraseComma', 'ambiguousComma']);
const groups = {
  addedByKind: countBy(added, (value) => value.kind),
  addedByRisk: countBy(added, (value) => value.risk),
  addedByProtectedCrossings: countBy(added, (value) => value.protectedRelationCrossings),
  addedBySpanPosition: countBy(added, (value) =>
    value.insideQuotedSpeech ? 'quote' : value.insideParenthetical ? 'parenthetical' : 'ordinary'),
  addedByWarnings: countBy(added, (value) => value.softWarnings?.join('+') || 'none'),
  removedByKind: countBy(removed, (value) => value.kind),
};
const flagged = {
  changesWithOneWord: changes.filter((change) => change.candidate.wordCounts.includes(1)).length,
  changesWithTwoToFiveWords: changes.filter((change) =>
    change.candidate.wordCounts.some((count) => count >= 2 && count <= 5)).length,
  changesOver30Words: changes.filter((change) => change.candidate.wordCounts.some((count) => count > 30)).length,
  addedEmergency: added.filter((value) => value.kind === 'emergency').length,
  addedNonPunctuation: added.filter((value) => !punctuation.has(value.kind)).length,
  addedWithRisk: added.filter((value) => value.risk > 0).length,
  addedWithProtectedCrossings: added.filter((value) => value.protectedRelationCrossings > 0).length,
  addedHardBlocked: added.filter((value) => value.hardBlocked).length,
  addedInsideQuote: added.filter((value) => value.insideQuotedSpeech).length,
  addedInsideParenthetical: added.filter((value) => value.insideParenthetical).length,
};
let review = null;
if (options.approvals) {
  const manifest = readJson(options.approvals);
  if (manifest.schemaVersion !== 'read_aloud_splitter_change_approvals_v1' ||
      !Array.isArray(manifest.approvals) ||
      manifest.approvalCount !== manifest.approvals.length ||
      !Number.isInteger(manifest.expectedPairCount) || manifest.expectedPairCount < 1 ||
      !Number.isInteger(manifest.expectedChapterCount) || manifest.expectedChapterCount < 1) {
    throw new Error(`Invalid splitter approval manifest: ${options.approvals}`);
  }
  const approvals = new Map();
  for (const approval of manifest.approvals) {
    const key = approvalKey(approval);
    if (approvals.has(key)) throw new Error(`Duplicate splitter approval: ${key}`);
    if (!approval.reason || !['supported', 'unsupported'].includes(approval.decision)) {
      throw new Error(`Incomplete splitter approval: ${key}`);
    }
    approvals.set(key, approval);
  }
  const matched = new Set();
  const reviewedChanges = changes.map((change) => {
    const signature = signatureOfChange(change);
    const key = approvalKey(signature);
    const approval = approvals.get(key);
    if (approval) matched.add(key);
    return {
      ...signature,
      decision: approval?.decision ?? 'unclassified',
      reason: approval?.reason ?? 'missing_exact_approval',
    };
  });
  const unclassified = reviewedChanges.filter((change) => change.decision === 'unclassified');
  const unsupported = reviewedChanges.filter((change) => change.decision === 'unsupported');
  const unusedApprovals = [...approvals.entries()]
    .filter(([key]) => !matched.has(key))
    .map(([, approval]) => approval);
  const gates = {
    pairCountMatches: options.pairs.length === manifest.expectedPairCount,
    chapterCountMatches:
      baseline.chapters === manifest.expectedChapterCount &&
      candidate.chapters === manifest.expectedChapterCount,
    sourceAlignmentFailures: comparison.sourceAlignmentFailures,
    candidateChapterRoundTripFailures: candidate.chapterRoundTripFailures,
    candidateOriginalRoundTripFailures: candidate.originalRoundTripFailures,
    candidateOneWord: candidate.oneWord,
    candidateOver30: candidate.over30,
    emergencyBoundaryRegression: Math.max(
      0,
      candidate.emergencyBoundaries - baseline.emergencyBoundaries,
    ),
  };
  const scopeAndQualityPassed = Object.values(gates).every(
    (value) => value === true || value === 0,
  );
  review = {
    manifest: options.approvals,
    approvedChangeCount: reviewedChanges.length - unclassified.length - unsupported.length,
    unsupportedChangeCount: unsupported.length,
    unclassifiedChangeCount: unclassified.length,
    unusedApprovalCount: unusedApprovals.length,
    gates,
    passed:
      scopeAndQualityPassed &&
      unclassified.length === 0 &&
      unsupported.length === 0 &&
      unusedApprovals.length === 0,
    changes: reviewedChanges,
    unusedApprovals,
  };
}
const reviewSummary = review && {
  approvedChangeCount: review.approvedChangeCount,
  unsupportedChangeCount: review.unsupportedChangeCount,
  unclassifiedChangeCount: review.unclassifiedChangeCount,
  unusedApprovalCount: review.unusedApprovalCount,
  gates: review.gates,
  passed: review.passed,
};
const report = {
  schemaVersion: 'clean_room_production_comparison_v1', generatedAt: new Date().toISOString(),
  inputs: options.pairs, baseline, candidate, comparison, groups, flagged: { counts: flagged }, review, changes,
};
const markdown = `# Clean-room V4 vs frozen production V3.7 audit

- Baseline: ${JSON.stringify(baseline)}
- Candidate: ${JSON.stringify(candidate)}
- Comparison: ${JSON.stringify(comparison)}
- Added kinds: ${JSON.stringify(groups.addedByKind)}
- Removed kinds: ${JSON.stringify(groups.removedByKind)}
- Review flags: ${JSON.stringify(flagged)}
${reviewSummary ? `- Approval review: ${JSON.stringify(reviewSummary)}` : ''}

The JSON companion contains every changed original and selected boundary object.
`;
for (const file of [options.json, options.markdown]) fs.mkdirSync(path.dirname(file), { recursive: true });
fs.writeFileSync(options.json, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
fs.writeFileSync(options.markdown, markdown, 'utf8');
console.log(JSON.stringify({
  baseline, candidate, comparison, groups, flagged: { counts: flagged }, review: reviewSummary,
}, null, 2));
if (review && !review.passed) process.exitCode = 1;
