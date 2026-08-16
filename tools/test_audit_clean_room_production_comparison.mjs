import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const auditScript = fileURLToPath(
  new URL('./audit_clean_room_production_comparison.mjs', import.meta.url),
);
const source = 'Alpha beta gamma delta epsilon zeta.';
const baselineSegments = ['Alpha beta', 'gamma delta epsilon zeta.'];
const candidateSegments = ['Alpha beta gamma', 'delta epsilon zeta.'];
const sha256 = (value) => createHash('sha256').update(value).digest('hex');
const boundary = (afterWord) => ({
  afterWord,
  kind: 'phraseComma',
  risk: 0,
  protectedRelationCrossings: 0,
  hardBlocked: false,
  insideQuotedSpeech: false,
  insideParenthetical: false,
  softWarnings: [],
});

function reports() {
  return {
    baseline: {
      chapters: [{
        episode: 'E01',
        source,
        v3LocalSentences: baselineSegments,
        originals: [{
          originalIndex: 0,
          original: source,
          segments: baselineSegments,
          wordCounts: [2, 4],
          boundaries: [boundary(2)],
        }],
      }],
    },
    candidate: {
      chapters: [{
        episode: 'E01',
        source,
        v4AdditiveLocalSentences: candidateSegments,
        originals: [{
          originalIndex: 0,
          original: source,
          v4AdditiveSegments: candidateSegments,
          v4AdditiveWordCounts: [3, 3],
          v4AdditiveBoundaries: [boundary(3)],
        }],
      }],
    },
  };
}

function approvalManifest() {
  return {
    schemaVersion: 'read_aloud_splitter_change_approvals_v1',
    expectedPairCount: 1,
    expectedChapterCount: 1,
    approvalCount: 1,
    approvals: [{
      episode: 'E01',
      originalIndex: 0,
      sourceSha256: sha256(source.replace(/\s+/gu, '')),
      baselineSegmentsSha256: sha256(JSON.stringify(baselineSegments)),
      candidateSegmentsSha256: sha256(JSON.stringify(candidateSegments)),
      decision: 'supported',
      reason: 'test_fixture',
    }],
  };
}

function runAudit(t, mutateManifest = () => {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'splitter-audit-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const { baseline, candidate } = reports();
  const manifest = approvalManifest();
  mutateManifest(manifest);
  const files = Object.fromEntries(
    ['baseline', 'candidate', 'approvals', 'report', 'markdown']
      .map((name) => [name, path.join(directory, `${name}.${name === 'markdown' ? 'md' : 'json'}`)]),
  );
  fs.writeFileSync(files.baseline, JSON.stringify(baseline));
  fs.writeFileSync(files.candidate, JSON.stringify(candidate));
  fs.writeFileSync(files.approvals, JSON.stringify(manifest));
  const result = spawnSync(process.execPath, [
    auditScript,
    '--pair', `${files.baseline}=${files.candidate}`,
    '--json', files.report,
    '--markdown', files.markdown,
    '--approvals', files.approvals,
  ], { encoding: 'utf8' });
  return {
    result,
    report: fs.existsSync(files.report) ? JSON.parse(fs.readFileSync(files.report, 'utf8')) : null,
  };
}

test('exact approval passes the complete audit gate', (t) => {
  const { result, report } = runAudit(t);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(report.review.passed, true);
  assert.equal(report.review.approvedChangeCount, 1);
  assert.equal(report.review.unclassifiedChangeCount, 0);
  assert.equal(report.review.unusedApprovalCount, 0);
});

test('changed segmentation signature fails closed', (t) => {
  const { result, report } = runAudit(t, (manifest) => {
    manifest.approvals[0].candidateSegmentsSha256 = '0'.repeat(64);
  });
  assert.equal(result.status, 1);
  assert.equal(report.review.passed, false);
  assert.equal(report.review.unclassifiedChangeCount, 1);
  assert.equal(report.review.unusedApprovalCount, 1);
});

test('incomplete chapter scope fails closed', (t) => {
  const { result, report } = runAudit(t, (manifest) => {
    manifest.expectedChapterCount = 2;
  });
  assert.equal(result.status, 1);
  assert.equal(report.review.passed, false);
  assert.equal(report.review.gates.chapterCountMatches, false);
});

test('inconsistent approval count is rejected', (t) => {
  const { result, report } = runAudit(t, (manifest) => {
    manifest.approvalCount = 2;
  });
  assert.equal(result.status, 1);
  assert.equal(report, null);
  assert.match(result.stderr, /Invalid splitter approval manifest/u);
});
