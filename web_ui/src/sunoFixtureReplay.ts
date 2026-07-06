import {
  absorbCreateSidebarUrls,
  canCompleteAutomation,
  isDirectMediaNotReady,
  probeCreatePageLyricsMatch,
  type SunoCompleteBlockReason,
  type SunoCompletionAutomationState,
  type SunoCreateBatchState,
  type SunoPageKind,
} from './sunoAutomationSimulator';

export const SUNO_REPLAY_FIXTURE_SCHEMA = 'tomato_suno_replay_fixture_v1';

export type SunoPostCreatePhase =
  | 'idle'
  | 'postCreateWaiting'
  | 'openingCandidate'
  | 'verifyingDetail'
  | 'scanCreateSidebar'
  | 'downloading'
  | 'complete';

export interface SunoCompletionProbe {
  songUrl?: string;
  songUrls?: string[];
  candidateSongUrls?: string[];
  currentPageLyricsExactMatch?: boolean;
  currentPageGenerating?: boolean;
  createSidebarSongUrls?: string[];
  createSidebarGeneratingCount?: number;
  linkCount?: number;
}

export interface SunoReplayAutomationState {
  createSubmitted: boolean;
  existingDownloadOnly: boolean;
  createBaselineVersionCount: number;
  versionsCount: number;
  statusKey: string;
  libraryScanSettled: boolean;
  mightHaveMoreLibraryRows: boolean;
  detectedUrlCount: number;
  allKnownUrlsDownloaded: boolean;
  hasOpenLibraryCandidates: boolean;
  batch: SunoCreateBatchState;
}

export interface SunoReplayFixtureExpected {
  sidebarLyricsMatch?: boolean;
  batchPendingCount?: number;
  postCreatePhase?: SunoPostCreatePhase;
  completeAllowed?: boolean;
  completeBlockReason?: SunoCompleteBlockReason;
  shouldOpenLibraryCandidate?: boolean;
  directMediaNotReady?: boolean;
}

export interface SunoReplayFixture {
  schema: typeof SUNO_REPLAY_FIXTURE_SCHEMA;
  id: string;
  description?: string;
  source?: string;
  url: string;
  pageKind: SunoPageKind;
  automation: SunoReplayAutomationState;
  completion: SunoCompletionProbe;
  probe?: {
    formLyricsPresent?: boolean;
    sidebarText?: string;
    expectedLyrics?: string;
  };
  directMedia?: {
    httpStatus: number;
    songUrl?: string;
  };
  expected?: SunoReplayFixtureExpected;
}

export interface SunoReplayResult {
  fixtureId: string;
  batch: SunoCreateBatchState;
  sidebarLyricsMatch: boolean;
  postCreatePhase: SunoPostCreatePhase;
  complete: { allowed: boolean; reason: SunoCompleteBlockReason };
  directMediaNotReady: boolean;
  shouldOpenLibraryCandidate: boolean;
}

export function batchAfterCompletionProbe(
  initialBatch: SunoCreateBatchState,
  completion: SunoCompletionProbe,
  pageKind: SunoPageKind,
): SunoCreateBatchState {
  const sidebar = completion.createSidebarSongUrls ?? [];
  let batch = initialBatch;
  if (sidebar.length > 0) {
    batch = absorbCreateSidebarUrls(batch, sidebar);
  }
  if (pageKind === 'create') {
    const candidates = completion.candidateSongUrls ?? [];
    if (candidates.length > 0) {
      batch = absorbCreateSidebarUrls(batch, candidates);
    }
  }
  return batch;
}

export function decidePostCreatePhase(params: {
  pageKind: SunoPageKind;
  createSubmitted: boolean;
  existingDownloadOnly: boolean;
  batch: SunoCreateBatchState;
  completion: SunoCompletionProbe;
  sidebarLyricsMatch: boolean;
}): SunoPostCreatePhase {
  if (!params.createSubmitted || params.existingDownloadOnly) {
    return 'idle';
  }

  const generating = params.completion.currentPageGenerating === true;
  const lyricsMatch = params.completion.currentPageLyricsExactMatch === true;
  const sidebar = params.completion.createSidebarSongUrls ?? [];
  const pending = params.batch.pendingUrls.length;

  if (params.pageKind === 'create') {
    if (params.sidebarLyricsMatch && (params.completion.linkCount ?? 0) === 0) {
      return 'postCreateWaiting';
    }
    if (sidebar.length === 0 && generating) {
      return 'postCreateWaiting';
    }
    if (pending > 0 && !params.completion.songUrl) {
      return 'openingCandidate';
    }
    if (pending > 0) {
      return 'scanCreateSidebar';
    }
    if (sidebar.length === 0) {
      return 'postCreateWaiting';
    }
    return 'openingCandidate';
  }

  if (params.pageKind === 'song') {
    if (generating || !lyricsMatch) {
      return 'verifyingDetail';
    }
    return 'downloading';
  }

  if (params.pageKind === 'library') {
    return (params.completion.candidateSongUrls ?? []).length > 0
      ? 'openingCandidate'
      : 'complete';
  }

  return 'postCreateWaiting';
}

export function shouldOpenLibraryCandidate(params: {
  pageKind: SunoPageKind;
  existingDownloadOnly: boolean;
  libraryBroadRecall: boolean;
  libraryCandidateCount: number;
  sidebarLyricsMatch: boolean;
  songUrlCount: number;
}): boolean {
  if (!params.libraryBroadRecall || params.libraryCandidateCount <= 0) {
    return false;
  }
  if (params.pageKind === 'create') {
    return false;
  }
  if (params.pageKind !== 'library') {
    return false;
  }
  return params.existingDownloadOnly || params.libraryCandidateCount > 0;
}

export function replaySunoFixture(fixture: SunoReplayFixture): SunoReplayResult {
  const probe = fixture.probe ?? {};
  const sidebarLyricsMatch = probeCreatePageLyricsMatch({
    pageKind: fixture.pageKind,
    formLyricsPresent: probe.formLyricsPresent ?? false,
    sidebarText: probe.sidebarText ?? '',
    expectedLyrics: probe.expectedLyrics ?? '',
  });

  const batch = batchAfterCompletionProbe(
    fixture.automation.batch,
    fixture.completion,
    fixture.pageKind,
  );

  const automationState: SunoCompletionAutomationState = {
    existingDownloadOnly: fixture.automation.existingDownloadOnly,
    createSubmitted: fixture.automation.createSubmitted,
    statusKey: fixture.automation.statusKey,
    versionsCount: fixture.automation.versionsCount,
    createBaselineVersionCount: fixture.automation.createBaselineVersionCount,
    batch,
    detectedUrlCount: fixture.automation.detectedUrlCount,
    libraryScanSettled: fixture.automation.libraryScanSettled,
    hasOpenLibraryCandidates: fixture.automation.hasOpenLibraryCandidates,
    mightHaveMoreLibraryRows: fixture.automation.mightHaveMoreLibraryRows,
    allKnownUrlsDownloaded: fixture.automation.allKnownUrlsDownloaded,
  };

  const complete = canCompleteAutomation(automationState);
  const postCreatePhase = decidePostCreatePhase({
    pageKind: fixture.pageKind,
    createSubmitted: fixture.automation.createSubmitted,
    existingDownloadOnly: fixture.automation.existingDownloadOnly,
    batch,
    completion: fixture.completion,
    sidebarLyricsMatch,
  });

  const directMediaNotReady = fixture.directMedia
    ? isDirectMediaNotReady(fixture.directMedia.httpStatus)
    : false;

  const libraryCandidateCount = (fixture.completion.candidateSongUrls ?? []).length;
  const shouldOpenLibrary = shouldOpenLibraryCandidate({
    pageKind: fixture.pageKind,
    existingDownloadOnly: fixture.automation.existingDownloadOnly,
    libraryBroadRecall: true,
    libraryCandidateCount,
    sidebarLyricsMatch,
    songUrlCount: (fixture.completion.songUrls ?? []).length,
  });

  return {
    fixtureId: fixture.id,
    batch,
    sidebarLyricsMatch,
    postCreatePhase,
    complete,
    directMediaNotReady,
    shouldOpenLibraryCandidate: shouldOpenLibrary,
  };
}

export function assertSunoReplayFixture(fixture: SunoReplayFixture): string[] {
  const expected = fixture.expected;
  if (!expected) {
    return [];
  }
  const result = replaySunoFixture(fixture);
  const failures: string[] = [];

  if (
    expected.sidebarLyricsMatch !== undefined &&
    expected.sidebarLyricsMatch !== result.sidebarLyricsMatch
  ) {
    failures.push(
      `sidebarLyricsMatch: expected ${expected.sidebarLyricsMatch}, got ${result.sidebarLyricsMatch}`,
    );
  }
  if (
    expected.batchPendingCount !== undefined &&
    expected.batchPendingCount !== result.batch.pendingUrls.length
  ) {
    failures.push(
      `batchPendingCount: expected ${expected.batchPendingCount}, got ${result.batch.pendingUrls.length}`,
    );
  }
  if (expected.postCreatePhase !== undefined && expected.postCreatePhase !== result.postCreatePhase) {
    failures.push(
      `postCreatePhase: expected ${expected.postCreatePhase}, got ${result.postCreatePhase}`,
    );
  }
  if (expected.completeAllowed !== undefined && expected.completeAllowed !== result.complete.allowed) {
    failures.push(
      `completeAllowed: expected ${expected.completeAllowed}, got ${result.complete.allowed} (${result.complete.reason})`,
    );
  }
  if (
    expected.completeBlockReason !== undefined &&
    expected.completeBlockReason !== result.complete.reason
  ) {
    failures.push(
      `completeBlockReason: expected ${expected.completeBlockReason}, got ${result.complete.reason}`,
    );
  }
  if (
    expected.shouldOpenLibraryCandidate !== undefined &&
    expected.shouldOpenLibraryCandidate !== result.shouldOpenLibraryCandidate
  ) {
    failures.push(
      `shouldOpenLibraryCandidate: expected ${expected.shouldOpenLibraryCandidate}, got ${result.shouldOpenLibraryCandidate}`,
    );
  }
  if (
    expected.directMediaNotReady !== undefined &&
    expected.directMediaNotReady !== result.directMediaNotReady
  ) {
    failures.push(
      `directMediaNotReady: expected ${expected.directMediaNotReady}, got ${result.directMediaNotReady}`,
    );
  }
  return failures;
}

export function trimSnapshotToReplayFixture(
  snapshot: Record<string, unknown>,
  overrides: Partial<SunoReplayFixture> = {},
): SunoReplayFixture {
  const completion = (snapshot.completion as Record<string, unknown>) ?? {};
  const url = String(snapshot.url ?? overrides.url ?? '');
  const pageKind = (snapshot.pageKind ?? overrides.pageKind ?? 'unknown') as SunoPageKind;

  return {
    schema: SUNO_REPLAY_FIXTURE_SCHEMA,
    id: String(overrides.id ?? snapshot.id ?? `trimmed-${Date.now()}`),
    description: overrides.description,
    source: overrides.source ?? 'tomato_suno_snapshot_v1',
    url,
    pageKind,
    automation: overrides.automation ?? {
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
      batch: { preCreateUrls: [], pendingUrls: [], downloadedUrls: [] },
    },
    completion: {
      songUrl: String(completion.songUrl ?? ''),
      songUrls: (completion.songUrls as string[]) ?? [],
      candidateSongUrls: (completion.candidateSongUrls as string[]) ?? [],
      currentPageLyricsExactMatch: completion.currentPageLyricsExactMatch === true,
      currentPageGenerating: completion.currentPageGenerating === true,
      createSidebarSongUrls: (completion.createSidebarSongUrls as string[]) ?? [],
      createSidebarGeneratingCount: Number(completion.createSidebarGeneratingCount ?? 0),
      linkCount: Number(completion.linkCount ?? 0),
    },
    expected: overrides.expected,
  };
}
