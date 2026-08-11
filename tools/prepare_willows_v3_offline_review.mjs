import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

const args = parseArgs(process.argv.slice(2));
const repositoryRoot = path.resolve(import.meta.dirname, '..');
const auditRoot = path.resolve(
  args.auditRoot ??
    path.join(
      repositoryRoot,
      'output',
      'sentence-split-v3',
      'willows-boundary-whitespace-audit-2026-08-09',
    ),
);
const v2Root = path.resolve(args.v2Root ?? 'F:\\柳林风声\\work\\v2');
const outputRoot = path.resolve(
  args.outputRoot ??
    path.join(
      repositoryRoot,
      'output',
      'sentence-split-v3',
      'willows-offline-review-2026-08-10',
    ),
);

const qualityAudit = JSON.parse(
  await readFile(path.join(v2Root, 'zh-quality-reaudit.json'), 'utf8'),
);
const qualityFlags = new Map();
for (const candidate of qualityAudit.candidates ?? []) {
  const key = `${candidate.episode}:${candidate.index}`;
  const values = qualityFlags.get(key) ?? [];
  values.push({
    severity: candidate.severity,
    category: candidate.category,
    reason: candidate.reason,
  });
  qualityFlags.set(key, values);
}

await mkdir(outputRoot, { recursive: true });
let combinedAudit = null;
try {
  combinedAudit = JSON.parse(
    await readFile(path.join(auditRoot, 'willows-v3-report.json'), 'utf8'),
  );
} catch (error) {
  if (error?.code !== 'ENOENT') throw error;
}
const combinedChapters = new Map(
  (combinedAudit?.chapters ?? []).map((chapter) => [chapter.episode, chapter]),
);
const summary = [];
for (let number = 1; number <= 62; number += 1) {
  const episode = `E${String(number).padStart(2, '0')}`;
  const report = combinedAudit ??
    JSON.parse(
      await readFile(
        path.join(auditRoot, episode, 'willows-v3-report.json'),
        'utf8',
      ),
    );
  const chapter = combinedAudit
    ? combinedChapters.get(episode)
    : report.chapters?.[0];
  if (!chapter || chapter.episode !== episode) {
    throw new Error(`${episode}: V3 audit report is missing its chapter`);
  }
  const oldDocument = JSON.parse(
    await readFile(path.join(v2Root, episode, 'zh.json'), 'utf8'),
  );
  const oldRows = episode === 'E61'
    ? removeConfirmedE61Duplicate(oldDocument.translations ?? [])
    : episode === 'E35'
      ? removeConfirmedE35Duplicate(oldDocument.translations ?? [])
      : oldDocument.translations ?? [];
  const newSentences = removeNonBodyLabels(
    episode,
    chapter.v3LocalSentences ?? [],
  );
  validateOldRows(episode, oldRows);

  const oldSpans = sentenceSpans(oldRows.map((row) => row.en));
  const newSpans = sentenceSpans(newSentences);
  if (oldSpans.stream !== newSpans.stream) {
    throw new Error(`${episode}: canonical V2 and V3 English streams differ`);
  }

  const exactQueues = new Map();
  for (const row of oldRows) {
    const queue = exactQueues.get(row.en) ?? [];
    queue.push(row);
    exactQueues.set(row.en, queue);
  }

  let exactCandidateCount = 0;
  let flaggedExactCount = 0;
  const rows = newSentences.map((english, index) => {
    const exactQueue = exactQueues.get(english);
    const exact = exactQueue?.length ? exactQueue.shift() : null;
    const span = newSpans.spans[index];
    const overlaps = oldRows
      .map((row, oldIndex) => {
        const oldSpan = oldSpans.spans[oldIndex];
        const overlapCharacters = Math.max(
          0,
          Math.min(span.end, oldSpan.end) - Math.max(span.start, oldSpan.start),
        );
        if (overlapCharacters === 0) return null;
        return {
          index: oldIndex,
          english: row.en,
          chinese: row.zh,
          overlapCharacters,
          qualityFlags: qualityFlags.get(`${episode}:${oldIndex}`) ?? [],
        };
      })
      .filter(Boolean);
    const exactFlags = exact
      ? qualityFlags.get(`${episode}:${exact.index}`) ?? []
      : [];
    if (exact) exactCandidateCount += 1;
    if (exactFlags.length) flaggedExactCount += 1;
    return {
      index,
      english,
      baselineDisposition: exact ? 'reuse_candidate' : 'retranslate',
      reviewStatus: 'pending',
      chinese: exact?.zh ?? '',
      exactOldIndex: exact?.index ?? null,
      qualityFlags: exactFlags,
      oldContext: overlaps,
    };
  });

  const output = {
    schemaVersion: 1,
    episode,
    sentenceSplitVersion: 'reviewed_dp_v3',
    solverVersion: report.summary?.solverVersion ?? 'syntax_solver_v3_5',
    source: 'codex_offline_story_translation_v1',
    translationRules: {
      audience: 'children_story',
      characterNamesStayEnglish: true,
      requiredCharacterNames: [
        'Mole',
        'Rat',
        'Ratty',
        'Toad',
        'Toady',
        'Badger',
        'Otter',
        'Portly',
        'Pan',
        'Ulysses',
        'Wayfarer',
      ],
      changedBoundariesMustBeRetranslated: true,
      unchangedSentencesMayBeReusedAfterReview: true,
    },
    canonicalEnglishSha256: sha256(oldSpans.stream),
    baselineSentenceCount: newSentences.length,
    rows,
  };
  await writeFile(
    path.join(outputRoot, `${episode}.review.json`),
    `${JSON.stringify(output, null, 2)}\n`,
    'utf8',
  );
  summary.push({
    episode,
    oldSentenceCount: oldRows.length,
    v3SentenceCount: newSentences.length,
    exactCandidateCount,
    changedSentenceCount: newSentences.length - exactCandidateCount,
    flaggedExactCount,
  });
}

const totals = summary.reduce(
  (result, item) => {
    for (const key of [
      'oldSentenceCount',
      'v3SentenceCount',
      'exactCandidateCount',
      'changedSentenceCount',
      'flaggedExactCount',
    ]) {
      result[key] += item[key];
    }
    return result;
  },
  {
    oldSentenceCount: 0,
    v3SentenceCount: 0,
    exactCandidateCount: 0,
    changedSentenceCount: 0,
    flaggedExactCount: 0,
  },
);
await writeFile(
  path.join(outputRoot, 'summary.json'),
  `${JSON.stringify({ schemaVersion: 1, chapters: summary, totals }, null, 2)}\n`,
  'utf8',
);
console.log(JSON.stringify({ outputRoot, ...totals }, null, 2));

function validateOldRows(episode, rows) {
  if (!Array.isArray(rows) || rows.length === 0) {
    throw new Error(`${episode}: old translation rows are missing`);
  }
  rows.forEach((row, index) => {
    if (
      row.index !== index ||
      typeof row.en !== 'string' ||
      !row.en.trim() ||
      typeof row.zh !== 'string' ||
      !row.zh.trim()
    ) {
      throw new Error(`${episode}: invalid old translation row ${index}`);
    }
  });
}

function removeConfirmedE61Duplicate(rows) {
  const repaired = rows.map((row) => ({ ...row }));
  const boundary = repaired[24];
  const expectedEnglish =
    'they had got ahead of him. His pleasant dream was shattered. "Now, look here, Toad,"';
  const expectedChinese =
    '抢在他前面了。他愉快的梦碎了。“听着，Toad，”';
  if (
    !boundary?.en?.startsWith(expectedEnglish) ||
    !boundary?.zh?.startsWith(expectedChinese) ||
    !repaired[28]?.en?.endsWith('His pleasant dream was shattered.')
  ) {
    throw new Error('E61: confirmed duplicate no longer matches the reviewed source');
  }
  boundary.en = 'they had got ahead of him. His pleasant dream was shattered.';
  boundary.zh = '抢在他前面了。他愉快的梦碎了。';
  repaired.splice(25, 4);
  return repaired.map((row, index) => ({ ...row, index }));
}

function removeConfirmedE35Duplicate(rows) {
  const repaired = rows.map((row) => ({ ...row }));
  const duplicateEnglish = repaired
    .slice(12, 14)
    .map((row) => row.en)
    .join('\n');
  const expectedSha256 =
    '344100f6d6bfd790c9baeb0899e7f5dcd30db03479d9a0c42c416d37db5bf66e';
  if (
    sha256(duplicateEnglish) !== expectedSha256 ||
    !repaired[14]?.en?.startsWith('O unhappy and forsaken Toad!')
  ) {
    throw new Error('E35: confirmed duplicate no longer matches the reviewed source');
  }
  repaired.splice(12, 2);
  return repaired.map((row, index) => ({ ...row, index }));
}

function sentenceSpans(sentences) {
  const spans = [];
  let stream = '';
  for (const sentence of sentences) {
    const normalized = canonicalCharacters(sentence);
    const start = stream.length;
    stream += normalized;
    spans.push({ start, end: stream.length });
  }
  return { stream, spans };
}

function canonicalCharacters(value) {
  return String(value)
    .replace(/\r\n?/gu, '\n')
    .replace(/[‐‑‒]/gu, '-')
    .replace(/\s+/gu, '');
}

function removeNonBodyLabels(episode, sentences) {
  const result = [...sentences];
  switch (episode) {
    case 'E14':
      if (sentenceEquals(result[0], 'Chapter 4: Mr. Badger')) {
        result.splice(0, 1);
      }
      break;
    case 'E24':
      removeExactSentence(result, 'CAROL');
      break;
    case 'E26':
      if (sentenceEquals(result[0], 'Chapter 6： MR. TOAD')) {
        result.splice(0, 1);
      }
      break;
    case 'E58':
      if (sentenceEquals(result[0], 'XII.')) {
        requireSentence(result, 1, 'THE RETURN OF ULYSSES', episode);
        result.splice(0, 2);
        if (sentenceEquals(result[0], 'WHEN')) {
          result[0] = `${result[0]} ${result[1]}`;
          result.splice(1, 1);
        } else if (!/^WHEN\b/u.test(result[0] ?? '')) {
          throw new Error(`${episode}: chapter body does not begin with WHEN`);
        }
      }
      break;
    case 'E60':
      {
        const labelIndex = removeExactSentence(result, 'OTHER COMPOSITIONS.');
        if (labelIndex >= 0) {
          requireSentence(
            result,
            labelIndex,
            'BY TOAD will be sung in the course of the evening by the...',
            episode,
          );
          result[labelIndex] = result[labelIndex].replace(/^BY TOAD\s+/u, '');
        }
      }
      break;
    case 'E62':
      if (sentenceEquals(result[0], "TOAD'S LAST LITTLE SONG")) {
        result.splice(0, 1);
      }
      break;
  }
  return result;
}

function sentenceEquals(actual, expected) {
  return canonicalCharacters(actual ?? '') === canonicalCharacters(expected);
}

function removeExactSentence(sentences, expected) {
  const index = sentences.findIndex((sentence) => sentenceEquals(sentence, expected));
  if (index >= 0) sentences.splice(index, 1);
  return index;
}

function requireSentence(sentences, index, expected, episode) {
  if (sentences[index] !== expected) {
    throw new Error(
      `${episode}: expected non-body label at ${index}: ${expected}`,
    );
  }
}

function sha256(value) {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

function parseArgs(values) {
  const result = {};
  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    const match = /^--([^=]+)=(.*)$/u.exec(value);
    if (match) {
      result[toCamelCase(match[1])] = match[2];
      continue;
    }
    if (value.startsWith('--')) {
      const key = toCamelCase(value.slice(2));
      const next = values[index + 1];
      if (!next || next.startsWith('--')) {
        result[key] = true;
      } else {
        result[key] = next;
        index += 1;
      }
    }
  }
  return result;
}

function toCamelCase(value) {
  return value.replace(/-([a-z])/gu, (_, letter) => letter.toUpperCase());
}
