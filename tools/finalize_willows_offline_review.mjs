import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

const args = parseArgs(process.argv.slice(2));
const repositoryRoot = path.resolve(import.meta.dirname, '..');
const reviewRoot = path.resolve(
  args.reviewRoot ??
    path.join(
      repositoryRoot,
      'output',
      'sentence-split-v3',
      'willows-offline-review-2026-08-10',
    ),
);
const translationsRoot = path.resolve(
  args.translationsRoot ?? path.join(reviewRoot, 'translations'),
);
const finalRoot = path.resolve(args.finalRoot ?? path.join(reviewRoot, 'final'));
const episode = String(args.episode ?? '').trim().toUpperCase();
if (!/^E\d{2}$/u.test(episode)) {
  throw new Error('Required --episode E01-style value');
}

const draft = JSON.parse(
  await readFile(path.join(reviewRoot, `${episode}.review.json`), 'utf8'),
);
const decisions = JSON.parse(
  await readFile(path.join(translationsRoot, `${episode}.json`), 'utf8'),
);
if (draft.episode !== episode || decisions.episode !== episode) {
  throw new Error(`${episode}: episode header mismatch`);
}
const approvedReuseIndexes = new Set(decisions.approvedReuseIndexes ?? []);
const translations = new Map(
  Object.entries(decisions.translations ?? {}).map(([index, chinese]) => [
    Number(index),
    String(chinese).trim(),
  ]),
);
let rows = draft.rows.map((row, index) => {
  if (row.index !== index) throw new Error(`${episode}: draft index mismatch`);
  if (approvedReuseIndexes.has(index)) {
    if (row.baselineDisposition !== 'reuse_candidate' || !row.chinese.trim()) {
      throw new Error(`${episode}: row ${index} is not an exact reuse candidate`);
    }
    if (translations.has(index)) {
      throw new Error(`${episode}: row ${index} has both reuse and translation`);
    }
    return {
      index,
      english: row.english,
      chinese: row.chinese.trim(),
      reviewStatus: 'reused_checked',
    };
  }
  const chinese = translations.get(index);
  if (!chinese) {
    throw new Error(`${episode}: row ${index} has not been reviewed`);
  }
  return {
    index,
    english: row.english,
    chinese,
    reviewStatus: 'retranslated',
  };
});
const canonicalBeforeOverrides = canonicalCharacters(
  rows.map((row) => row.english).join(''),
);
const overrides = [...(decisions.sentenceOverrides ?? [])].sort(
  (left, right) => right.startIndex - left.startIndex,
);
for (const override of overrides) {
  const startIndex = Number(override.startIndex);
  const deleteCount = Number(override.deleteCount);
  if (
    !Number.isInteger(startIndex) ||
    !Number.isInteger(deleteCount) ||
    startIndex < 0 ||
    deleteCount <= 0 ||
    startIndex + deleteCount > rows.length ||
    !Array.isArray(override.rows) ||
    override.rows.length === 0
  ) {
    throw new Error(`${episode}: invalid sentence override at ${startIndex}`);
  }
  const replacements = override.rows.map((row, offset) => {
    const english = String(row.english ?? '').trim();
    const chinese = String(row.chinese ?? '').trim();
    if (!english || !chinese) {
      throw new Error(
        `${episode}: empty sentence override row ${startIndex + offset}`,
      );
    }
    if (wordCount(english) > 30) {
      throw new Error(
        `${episode}: sentence override row ${startIndex + offset} exceeds 30 words`,
      );
    }
    return {
      index: -1,
      english,
      chinese,
      reviewStatus: 'retranslated',
    };
  });
  rows.splice(startIndex, deleteCount, ...replacements);
}
rows = rows.map((row, index) => ({ ...row, index }));
if (
  canonicalCharacters(rows.map((row) => row.english).join('')) !==
  canonicalBeforeOverrides
) {
  throw new Error(`${episode}: sentence overrides changed the English stream`);
}
for (const index of translations.keys()) {
  if (!Number.isInteger(index) || index < 0 || index >= draft.rows.length) {
    throw new Error(`${episode}: translation index ${index} is out of range`);
  }
}
await mkdir(finalRoot, { recursive: true });
const output = {
  schemaVersion: 1,
  episode,
  sentenceSplitVersion: 'reviewed_dp_v3',
  source: 'codex_offline_story_translation_v1',
  rows,
};
await writeFile(
  path.join(finalRoot, `${episode}.json`),
  `${JSON.stringify(output, null, 2)}\n`,
  'utf8',
);
console.log(
  JSON.stringify(
    {
      episode,
      sentenceCount: rows.length,
      reusedChecked: rows.filter(
        (row) => row.reviewStatus === 'reused_checked',
      ).length,
      retranslated: rows.filter(
        (row) => row.reviewStatus === 'retranslated',
      ).length,
    },
    null,
    2,
  ),
);

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

function canonicalCharacters(value) {
  return String(value)
    .replace(/\r\n?/gu, '\n')
    .replace(/[‐‑‒]/gu, '-')
    .replace(/\s+/gu, '');
}

function wordCount(value) {
  return String(value)
    .trim()
    .split(/\s+/u)
    .filter((token) => /[\p{L}\p{N}]/u.test(token)).length;
}
