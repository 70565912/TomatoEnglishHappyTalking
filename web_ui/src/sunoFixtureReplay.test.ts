import { describe, expect, it } from 'vitest';
import article82FalsePositive from '../../app/test/fixtures/suno/article-82-create-form-false-positive.json';
import article82SidebarTwo from '../../app/test/fixtures/suno/article-82-create-sidebar-two-songs.json';
import article82AfterFirst from '../../app/test/fixtures/suno/article-82-after-first-save-batch-pending.json';
import article83Generating403 from '../../app/test/fixtures/suno/article-83-song-generating-403.json';
import {
  assertSunoReplayFixture,
  batchAfterCompletionProbe,
  decidePostCreatePhase,
  replaySunoFixture,
  trimSnapshotToReplayFixture,
  type SunoReplayFixture,
} from './sunoFixtureReplay';

const fixtures: SunoReplayFixture[] = [
  article82FalsePositive as SunoReplayFixture,
  article82SidebarTwo as SunoReplayFixture,
  article82AfterFirst as SunoReplayFixture,
  article83Generating403 as SunoReplayFixture,
];

describe('suno fixture replay', () => {
  it.each(fixtures.map((fixture) => [fixture.id, fixture] as const))(
    'replays %s without expectation failures',
    (_id, fixture) => {
      const failures = assertSunoReplayFixture(fixture);
      expect(failures, failures.join('\n')).toEqual([]);
    },
  );

  it('absorbs two sidebar URLs excluding pre-create baseline', () => {
    const batch = batchAfterCompletionProbe(
      {
        preCreateUrls: ['https://suno.com/song/old'],
        pendingUrls: [],
        downloadedUrls: [],
      },
      {
        createSidebarSongUrls: [
          'https://suno.com/song/old',
          'https://suno.com/song/new-a',
          'https://suno.com/song/new-b',
        ],
      },
      'create',
    );
    expect(batch.pendingUrls).toHaveLength(2);
  });

  it('decidePostCreatePhase waits when Create sidebar empty but generating', () => {
    const phase = decidePostCreatePhase({
      pageKind: 'create',
      createSubmitted: true,
      existingDownloadOnly: false,
      batch: { preCreateUrls: [], pendingUrls: [], downloadedUrls: [] },
      completion: {
        createSidebarSongUrls: [],
        currentPageGenerating: true,
        linkCount: 0,
      },
      sidebarLyricsMatch: false,
    });
    expect(phase).toBe('postCreateWaiting');
  });

  it('trimSnapshotToReplayFixture maps completion fields from debug snapshot', () => {
    const trimmed = trimSnapshotToReplayFixture({
      schema: 'tomato_suno_snapshot_v1',
      url: 'https://suno.com/create',
      pageKind: 'create',
      status: 'creating',
      createSubmitted: true,
      completion: {
        songUrl: '',
        createSidebarSongUrls: ['https://suno.com/song/new-a'],
        createSidebarGeneratingCount: 1,
        currentPageLyricsExactMatch: false,
        currentPageGenerating: true,
        linkCount: 0,
      },
    }, { id: 'from-live-snapshot' });

    expect(trimmed.id).toBe('from-live-snapshot');
    expect(trimmed.completion.createSidebarSongUrls).toHaveLength(1);
    expect(trimmed.automation.createSubmitted).toBe(true);
  });

  it('article-82 false positive fixture blocks library open', () => {
    const result = replaySunoFixture(article82FalsePositive as SunoReplayFixture);
    expect(result.sidebarLyricsMatch).toBe(false);
    expect(result.shouldOpenLibraryCandidate).toBe(false);
    expect(result.postCreatePhase).toBe('postCreateWaiting');
  });
});
