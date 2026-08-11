#!/usr/bin/env node

import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

const args = parseArgs(process.argv.slice(2));
const oldFinalRoot = path.resolve(args.oldFinalRoot ?? '');
const reviewRoot = path.resolve(args.reviewRoot ?? '');
const translationsRoot = path.resolve(
  args.translationsRoot ?? path.join(reviewRoot, 'translations'),
);
if (!args.oldFinalRoot || !args.reviewRoot) {
  throw new Error(
    'Usage: node port_willows_offline_translations.mjs ' +
      '--old-final-root <directory> --review-root <directory>',
  );
}

const available = (await readdir(oldFinalRoot))
  .filter((name) => /^E\d{2}\.json$/u.test(name))
  .map((name) => name.slice(0, 3))
  .sort();
const selected = String(args.episodes ?? '')
  .split(',')
  .map((value) => value.trim().toUpperCase())
  .filter(Boolean);
const episodes = selected.length ? selected : available;
await mkdir(translationsRoot, { recursive: true });

const summaries = [];
for (const episode of episodes) {
  if (!available.includes(episode)) {
    throw new Error(`${episode}: old reviewed final is unavailable`);
  }
  const oldFinal = JSON.parse(
    await readFile(path.join(oldFinalRoot, `${episode}.json`), 'utf8'),
  );
  const draft = JSON.parse(
    await readFile(path.join(reviewRoot, `${episode}.review.json`), 'utf8'),
  );
  if (oldFinal.episode !== episode || draft.episode !== episode) {
    throw new Error(`${episode}: episode header mismatch`);
  }

  const queues = new Map();
  for (const row of oldFinal.rows ?? []) {
    const queue = queues.get(row.english) ?? [];
    queue.push(row);
    queues.set(row.english, queue);
  }
  const approvedReuseIndexes = [];
  const translations = {};
  const unresolved = [];
  for (const row of draft.rows ?? []) {
    const queue = queues.get(row.english);
    const prior = queue?.length ? queue.shift() : null;
    if (!prior) {
      unresolved.push({ index: row.index, english: row.english });
      continue;
    }
    if (
      prior.reviewStatus === 'reused_checked' &&
      row.baselineDisposition === 'reuse_candidate' &&
      row.chinese.trim() === prior.chinese.trim()
    ) {
      approvedReuseIndexes.push(row.index);
    } else {
      translations[String(row.index)] = prior.chinese.trim();
    }
  }
  const output = {
    episode,
    approvedReuseIndexes,
    translations,
  };
  await writeFile(
    path.join(translationsRoot, `${episode}.json`),
    `${JSON.stringify(output, null, 2)}\n`,
    'utf8',
  );
  summaries.push({
    episode,
    sentenceCount: draft.rows.length,
    approvedReuseCount: approvedReuseIndexes.length,
    carriedTranslationCount: Object.keys(translations).length,
    unresolvedCount: unresolved.length,
    unresolved,
  });
}

await writeFile(
  path.join(translationsRoot, 'port-summary.json'),
  `${JSON.stringify({ schemaVersion: 1, chapters: summaries }, null, 2)}\n`,
  'utf8',
);
console.log(
  JSON.stringify(
    {
      episodeCount: summaries.length,
      sentenceCount: summaries.reduce(
        (total, item) => total + item.sentenceCount,
        0,
      ),
      approvedReuseCount: summaries.reduce(
        (total, item) => total + item.approvedReuseCount,
        0,
      ),
      carriedTranslationCount: summaries.reduce(
        (total, item) => total + item.carriedTranslationCount,
        0,
      ),
      unresolvedCount: summaries.reduce(
        (total, item) => total + item.unresolvedCount,
        0,
      ),
    },
    null,
    2,
  ),
);

function parseArgs(values) {
  const result = {};
  for (let index = 0; index < values.length; index += 1) {
    const current = values[index];
    const match = /^--([^=]+)=(.*)$/u.exec(current);
    if (match) {
      result[toCamelCase(match[1])] = match[2];
      continue;
    }
    if (current.startsWith('--')) {
      const key = toCamelCase(current.slice(2));
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
