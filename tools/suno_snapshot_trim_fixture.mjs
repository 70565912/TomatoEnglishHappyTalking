#!/usr/bin/env node
/**
 * Trim a full tomato_suno_snapshot_v1 JSON (from suno.debugSnapshot) into a
 * tomato_suno_replay_fixture_v1 file for vitest / Dart replay tests.
 *
 * Usage:
 *   node tools/suno_snapshot_trim_fixture.mjs <snapshot.json> [--out fixtures.json] [--id my-id]
 *
 * Optional env:
 *   TOMATO_SUNO_FIXTURE_DIR — default output directory (app/test/fixtures/suno)
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');
const defaultOutDir =
  process.env.TOMATO_SUNO_FIXTURE_DIR?.trim() ||
  path.join(repoRoot, 'app', 'test', 'fixtures', 'suno');

function parseArgs(argv) {
  const positional = [];
  let out = '';
  let id = '';
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--out') {
      out = argv[i + 1] ?? '';
      i += 1;
      continue;
    }
    if (arg === '--id') {
      id = argv[i + 1] ?? '';
      i += 1;
      continue;
    }
    if (!arg.startsWith('--')) {
      positional.push(arg);
    }
  }
  return { input: positional[0] ?? '', out, id };
}

function stemFromUrl(url) {
  try {
    const parsed = new URL(url);
    const parts = parsed.pathname.split('/').filter(Boolean);
    return parts.join('-') || 'suno';
  } catch {
    return 'suno';
  }
}

function trimSnapshot(snapshot, { id: overrideId }) {
  const completion = snapshot.completion ?? {};
  const url = String(snapshot.url ?? '');
  const pageKind = String(snapshot.pageKind ?? 'unknown');
  const fixtureId =
    overrideId ||
    `${stemFromUrl(url)}-${String(snapshot.capturedAt ?? '')
      .replace(/[:.]/g, '-')
      .slice(0, 19) || 'replay'}`;

  return {
    schema: 'tomato_suno_replay_fixture_v1',
    id: fixtureId,
    description: `Trimmed from ${snapshot.schema ?? 'snapshot'} at ${snapshot.capturedAt ?? 'unknown'}`,
    source: snapshot.schema ?? 'tomato_suno_snapshot_v1',
    url,
    pageKind,
    automation: {
      createSubmitted: snapshot.createSubmitted === true,
      existingDownloadOnly: snapshot.existingDownloadOnly === true,
      createBaselineVersionCount: 0,
      versionsCount: 0,
      statusKey: String(snapshot.status ?? 'creating'),
      libraryScanSettled: false,
      mightHaveMoreLibraryRows: true,
      detectedUrlCount: 0,
      allKnownUrlsDownloaded: false,
      hasOpenLibraryCandidates: false,
      batch: {
        preCreateUrls: [],
        pendingUrls: [],
        downloadedUrls: [],
      },
    },
    completion: {
      songUrl: String(completion.songUrl ?? ''),
      songUrls: completion.songUrls ?? [],
      candidateSongUrls: completion.candidateSongUrls ?? [],
      currentPageLyricsExactMatch: completion.currentPageLyricsExactMatch === true,
      currentPageGenerating: completion.currentPageGenerating === true,
      createSidebarSongUrls: completion.createSidebarSongUrls ?? [],
      createSidebarGeneratingCount: Number(completion.createSidebarGeneratingCount ?? 0),
      linkCount: Number(completion.linkCount ?? 0),
    },
    probe: {
      formLyricsPresent: Boolean(snapshot.lyricsSample),
      sidebarText: '',
      expectedLyrics: String(snapshot.lyricsSample ?? '').slice(0, 240),
    },
    expected: {},
  };
}

function main() {
  const { input, out, id } = parseArgs(process.argv.slice(2));
  if (!input) {
    console.error(
      'Usage: node tools/suno_snapshot_trim_fixture.mjs <snapshot.json> [--out path.json] [--id fixture-id]',
    );
    process.exit(1);
  }
  const inputPath = path.resolve(input);
  const raw = fs.readFileSync(inputPath, 'utf8');
  const snapshot = JSON.parse(raw);
  const fixture = trimSnapshot(snapshot, { id });
  const outPath = out
    ? path.resolve(out)
    : path.join(defaultOutDir, `${fixture.id}.json`);
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, `${JSON.stringify(fixture, null, 2)}\n`, 'utf8');
  console.log(`Wrote replay fixture: ${outPath}`);
  console.log(
    `  completion: sidebar=${fixture.completion.createSidebarSongUrls.length} generating=${fixture.completion.createSidebarGeneratingCount}`,
  );
  console.log('  Edit "expected" and automation.batch, then run:');
  console.log('    cd web_ui && npx vitest run src/sunoFixtureReplay.test.ts');
}

main();
