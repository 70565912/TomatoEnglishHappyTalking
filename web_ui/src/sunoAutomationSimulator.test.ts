import { describe, expect, it } from 'vitest';
import {
  detectSunoPageKind,
  selectSunoCreateFields,
  selectSunoDownloadCandidate,
  shouldOpenLibraryForExistingDownload,
  shouldReloadExistingSunoSong,
  simulateSunoCreateFill,
} from './sunoAutomationSimulator';

const targetSongUrl = 'https://suno.com/song/e2cfe4ec-4a40-490a-9af7-f665a9485311';

describe('suno automation simulator', () => {
  it('classifies Suno create, song, and profile pages', () => {
    expect(detectSunoPageKind('https://suno.com/create')).toBe('create');
    expect(detectSunoPageKind(targetSongUrl)).toBe('song');
    expect(detectSunoPageKind('https://suno.com/@70565912')).toBe('profile');
    expect(detectSunoPageKind('https://example.com/song/one')).toBe('external');
  });

  it('does not reload forever after Suno redirects an existing song to profile', () => {
    expect(
      shouldReloadExistingSunoSong({
        currentUrl: 'https://suno.com/@70565912',
        targetSongUrl,
        pendingSongUrl: targetSongUrl,
      }),
    ).toEqual({ reload: false, reason: 'profile-redirect' });
  });

  it('reloads an existing song detail only before the first attempted open', () => {
    expect(
      shouldReloadExistingSunoSong({
        currentUrl: 'https://suno.com/create',
        targetSongUrl,
        pendingSongUrl: null,
      }),
    ).toEqual({ reload: true, reason: 'not-suno-song' });
    expect(
      shouldReloadExistingSunoSong({
        currentUrl: 'https://suno.com/create',
        targetSongUrl,
        pendingSongUrl: targetSongUrl,
      }),
    ).toEqual({ reload: false, reason: 'already-tried' });
  });

  it('falls back from song detail/profile to Library only once for existing downloads', () => {
    expect(
      shouldOpenLibraryForExistingDownload({
        currentUrl: targetSongUrl,
        targetSongUrl,
        triedLibrary: false,
      }),
    ).toBe(true);
    expect(
      shouldOpenLibraryForExistingDownload({
        currentUrl: 'https://suno.com/me',
        targetSongUrl,
        triedLibrary: false,
      }),
    ).toBe(false);
    expect(
      shouldOpenLibraryForExistingDownload({
        currentUrl: 'https://suno.com/@70565912',
        targetSongUrl,
        triedLibrary: true,
      }),
    ).toBe(false);
  });

  it('prefers a direct audio download action for the expected full song', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: targetSongUrl,
      allowedSongUrls: [targetSongUrl],
      controls: [
        {
          label: 'Share',
          context: 'Share song',
          songUrl: targetSongUrl,
          expectedScore: 8,
        },
        {
          label: 'Download Audio',
          context: 'Download Audio MP3 for 猫头摘帽令',
          songUrl: targetSongUrl,
          expectedScore: 8,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('download');
    expect(decision.candidate?.label).toBe('Download Audio');
  });

  it('opens a safe more menu for the expected song when no direct audio action exists', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: 'https://suno.com/library',
      allowedSongUrls: [targetSongUrl],
      controls: [
        {
          label: 'More options',
          context: '猫头摘帽令 whimsical Alice song More options',
          songUrl: targetSongUrl,
          expectedScore: 5,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('openMenu');
    expect(decision.candidate?.songUrl).toBe(targetSongUrl);
  });

  it('opens the matching Library row menu without a direct song link when pending target is known', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: 'https://suno.com/me',
      allowedSongUrls: [targetSongUrl],
      pendingSongUrl: targetSongUrl,
      controls: [
        {
          label: 'More options',
          context: 'unrelated song More options',
          expectedScore: 0,
        },
        {
          label: 'More options',
          context: '猫头摘帽令 奇幻儿童叙事民谣 诙谐滑稽 More options',
          expectedScore: 5,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('openMenu');
    expect(decision.candidate?.context).toMatch('猫头摘帽令');
  });

  it('rejects an unrelated Library row menu even when a pending target exists', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: 'https://suno.com/me',
      allowedSongUrls: [targetSongUrl],
      pendingSongUrl: targetSongUrl,
      controls: [
        {
          label: 'More options',
          context: 'unrelated song More options',
          expectedScore: 0,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('none');
  });

  it('treats the Suno playbar more menu as a menu step on song detail pages', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: targetSongUrl,
      allowedSongUrls: [targetSongUrl],
      pendingSongUrl: targetSongUrl,
      currentPageExpectedScore: 5,
      controls: [
        {
          label: 'More menu contents',
          context: 'Playbar More menu contents 猫头摘帽令 0:00 2:04',
          expectedScore: 0,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('openMenu');
  });

  it('uses the pending song url when a Library download menu is already open', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: 'https://suno.com/me',
      allowedSongUrls: [targetSongUrl],
      pendingSongUrl: targetSongUrl,
      currentPageExpectedScore: 5,
      controls: [
        {
          label: 'Download',
          inOpenMenu: true,
          context: 'Remix Edit Publish Share Download Manage Add to Queue Add to Playlist Song Radio Move to Trash',
          expectedScore: 0,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('openMenu');
    expect(decision.candidate?.label).toBe('Download');
  });

  it('prefers an opened Download menu item over the playbar More button', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: targetSongUrl,
      allowedSongUrls: [targetSongUrl],
      pendingSongUrl: targetSongUrl,
      currentPageExpectedScore: 5,
      controls: [
        {
          label: 'More menu contents',
          context: 'Playbar More menu contents 猫头摘帽令 0:00 2:04',
          rect: { x: 645, width: 40 },
          expectedScore: 0,
        },
        {
          label: 'Download',
          role: 'menuitem',
          context: 'Remix Edit Publish Share Download Manage Add to Queue Add to Playlist Song Radio Move to Trash',
          inOpenMenu: true,
          expectedScore: 0,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('openMenu');
    expect(decision.candidate?.label).toBe('Download');
  });

  it('stops retrying a song-detail menu that only offers restore/report/delete actions', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: targetSongUrl,
      allowedSongUrls: [targetSongUrl],
      pendingSongUrl: targetSongUrl,
      currentPageExpectedScore: 5,
      controls: [
        {
          label: 'More menu contents',
          context: 'Playbar More menu contents 猫头摘帽令 0:00 2:04',
          rect: { x: 645, width: 40 },
          expectedScore: 0,
        },
        {
          label: 'Restore to Library',
          role: 'menuitem',
          context: 'Restore to Library Report Delete Permanently',
          inOpenMenu: true,
          expectedScore: 0,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('none');
    expect(decision.reason).toBe('non-download-menu');
  });

  it('uses the pending song url for a concrete audio item inside an opened Download menu', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: 'https://suno.com/me',
      allowedSongUrls: [targetSongUrl],
      pendingSongUrl: targetSongUrl,
      currentPageExpectedScore: 5,
      controls: [
        {
          label: 'Audio',
          inOpenMenu: true,
          context: 'Download Audio MP3',
          expectedScore: 0,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('download');
  });

  it('does not treat Create page Add audio as a download candidate', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: 'https://suno.com/create',
      allowedSongUrls: [targetSongUrl],
      pendingSongUrl: targetSongUrl,
      controls: [
        {
          label: 'Add audio - Browse, upload, or record audio',
          context: 'Audio Voice New Inspo Lyrics Styles Create song',
          expectedScore: 0,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('none');
  });

  it('rejects pending-song download controls when the current page content does not match the lyrics or style', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: targetSongUrl,
      allowedSongUrls: [targetSongUrl],
      pendingSongUrl: targetSongUrl,
      currentPageExpectedScore: 0,
      controls: [
        {
          label: 'Audio',
          context: 'Wrong Seat Apology Download Audio MP3',
          expectedScore: 0,
        },
        {
          label: 'More menu contents',
          context: 'Wrong Seat Apology country Americana bluegrass',
          expectedScore: 0,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('none');
  });

  it('rejects a stale target row that only partially overlaps the expected style tokens', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: 'https://suno.com/me',
      allowedSongUrls: [targetSongUrl],
      pendingSongUrl: targetSongUrl,
      currentPageExpectedScore: 16,
      expectedMatchThreshold: 10,
      controls: [
        {
          label: 'More options',
          songUrl: targetSongUrl,
          context: 'Wrong Seat Apology Country arrangement, brushed snare, upright bass, pedal steel',
          expectedScore: 8,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('none');
  });

  it('rejects a stale song detail that scores below the stricter long-style threshold', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: targetSongUrl,
      allowedSongUrls: [targetSongUrl],
      pendingSongUrl: targetSongUrl,
      currentPageExpectedScore: 13,
      expectedMatchThreshold: 14,
      controls: [
        {
          label: 'More menu contents',
          context: 'Wrong Seat Apology playbar menu',
          expectedScore: 13,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('none');
  });

  it('does not let sidebar controls borrow page-level song text as download intent', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: 'https://suno.com/me',
      allowedSongUrls: [targetSongUrl],
      pendingSongUrl: targetSongUrl,
      currentPageExpectedScore: 16,
      expectedMatchThreshold: 10,
      controls: [
        {
          label: 'Collapse sidebar',
          context: 'Home Explore Create Studio Library More Croquet Hedgehog storybook folk-pop brushed snare',
          expectedScore: 16,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('none');
  });

  it('rejects Suno style tags even when their title contains Audio', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: targetSongUrl,
      allowedSongUrls: [targetSongUrl],
      pendingSongUrl: targetSongUrl,
      currentPageExpectedScore: 5,
      controls: [
        {
          label: '[痛快] Audio: High Fidelity',
          href: 'https://suno.com/style/%E7%97%9B%E5%BF%AB%0AAudio%3A-High-Fidelity',
          context: '奇幻儿童叙事民谣 [痛快] Audio: High Fidelity',
          expectedScore: 5,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('none');
  });

  it('rejects non-interactive style text blocks that mention music or audio', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: targetSongUrl,
      allowedSongUrls: [targetSongUrl],
      pendingSongUrl: targetSongUrl,
      currentPageExpectedScore: 5,
      controls: [
        {
          label: '歌曲风格：儿童流行 Kids Pop 音乐感觉 Audio: High Fidelity',
          context: '歌曲风格 音乐感觉 旋律朗朗上口',
          interactive: false,
          expectedScore: 5,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('none');
  });

  it('rejects sidebar More navigation and keeps the playbar More menu candidate', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: targetSongUrl,
      allowedSongUrls: [targetSongUrl],
      pendingSongUrl: targetSongUrl,
      currentPageExpectedScore: 5,
      controls: [
        {
          label: 'More More',
          context: 'Home Explore Create Studio Library Notifications Labs Terms Policies More',
          rect: { x: 16, width: 152 },
          expectedScore: 0,
        },
        {
          label: 'More menu contents',
          context: 'Playbar More menu contents 猫头摘帽令',
          rect: { x: 645, width: 40 },
          expectedScore: 0,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('openMenu');
    expect(decision.candidate?.label).toBe('More menu contents');
  });

  it('rejects global Suno More menu items such as Earn Credits and Help', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: 'https://suno.com/listen-and-rank',
      allowedSongUrls: [targetSongUrl],
      pendingSongUrl: targetSongUrl,
      controls: [
        {
          label: 'Earn Credits',
          href: 'https://suno.com/listen-and-rank',
          context: "Invite friends Earn Credits What's new? Help About Blog Careers Feedback",
          expectedScore: 0,
        },
        {
          label: 'Help',
          href: 'https://help.suno.com/',
          context: "Invite friends Earn Credits What's new? Help About Blog Careers Feedback",
          expectedScore: 0,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('none');
  });

  it('can still choose a real Audio item that is not a style tag', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: targetSongUrl,
      allowedSongUrls: [targetSongUrl],
      pendingSongUrl: targetSongUrl,
      currentPageExpectedScore: 5,
      controls: [
        {
          label: 'Audio',
          href: 'https://suno.com/api/download/song.mp3',
          context: 'Download Audio MP3',
          expectedScore: 0,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('download');
  });

  it('rejects account/profile controls even when the profile page contains song text', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: 'https://suno.com/@70565912',
      allowedSongUrls: [targetSongUrl],
      controls: [
        {
          label: 'Profile',
          href: 'https://suno.com/@70565912',
          context: '猫头摘帽令 Download Audio Profile Subscription Account Sign Out',
          expectedScore: 9,
        },
        {
          label: 'Upgrade to Pro',
          context: '猫头摘帽令 account menu',
          expectedScore: 9,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('none');
  });

  it('does not select already downloaded versions again', () => {
    const decision = selectSunoDownloadCandidate({
      currentUrl: targetSongUrl,
      allowedSongUrls: [targetSongUrl],
      downloadedSongUrls: [targetSongUrl],
      controls: [
        {
          label: 'Download Audio',
          context: 'Download Audio MP3',
          songUrl: targetSongUrl,
          expectedScore: 8,
        },
      ],
      requireExpectedMatch: true,
    });
    expect(decision.action).toBe('none');
  });

  it('selects the Suno Advanced lyrics and styles fields from the saved Create-page structure', () => {
    const selection = selectSunoCreateFields([
      {
        label: 'Lyrics',
        placeholder: '[Verse]\nThis is where you write your rhymes\nor give our Magic Wand a try',
        context: 'Lyrics 1998/5000',
        rect: { height: 248 },
      },
      {
        label: 'Styles',
        context: 'Styles 0/1000 pop urbano atmospheric textures 80s rock duett electro latino',
        value: 'pop urbano, atmospheric textures, 80s rock, duett, electro latino',
        rect: { height: 88 },
      },
    ]);
    expect(selection.lyricsField?.label).toBe('Lyrics');
    expect(selection.styleField?.label).toBe('Styles');
  });

  it('selects the large textarea below lyrics as Styles instead of search inputs', () => {
    const selection = selectSunoCreateFields([
      {
        label: 'Search workspaces',
        placeholder: 'Search',
        context: 'Archived Create New Workspace My Workspace',
        rect: { x: 240, y: 24, width: 159, height: 21 },
      },
      {
        label: 'Lyrics',
        context: 'Lyrics 63/5000',
        value: 'Tom finds a bright snack box. He sings a happy song with Alice.',
        rect: { x: 232, y: -117, width: 371, height: 100 },
      },
      {
        label: 'Enhance lyrics',
        placeholder: 'Enhance lyrics (e.g. "make it sound happier")',
        context: 'Lyrics 63/5000',
        rect: { x: 240, y: 57, width: 311, height: 36 },
      },
      {
        label: '',
        placeholder: 'vinahouse, classical rock, 90s pop, new age piano, urban',
        value:
          'chant-driven stadium chorus, 128 BPM, big group chant, unison shout vocals, crowd singalong hooks',
        context: '336/1000',
        rect: { x: 232, y: 141, width: 371, height: 100 },
      },
      {
        label: 'Search clips',
        placeholder: 'Search',
        context: 'Filters (3) Newest List',
        rect: { x: 691, y: 78, width: 159, height: 21 },
      },
    ]);

    expect(selection.lyricsField?.label).toBe('Lyrics');
    expect(selection.styleField?.value).toContain('chant-driven stadium chorus');
  });

  it('does not treat lyrics text containing the word search as a utility search field', () => {
    const selection = selectSunoCreateFields([
      {
        label: 'Search clips',
        placeholder: 'Search',
        type: 'search',
        context: 'Filters (3) Newest List',
        rect: { x: 691, y: 78, width: 159, height: 21 },
      },
      {
        label: 'Lyrics',
        value: 'Alice went off in search of her hedgehog and found the garden in confusion.',
        context: 'Lyrics 74/5000',
        rect: { x: 232, y: 20, width: 371, height: 100 },
      },
      {
        label: 'Styles',
        value: '奇幻儿童叙事民谣, 诙谐滑稽, 轻快跳脱, 木吉他',
        context: 'Styles 31/1000',
        rect: { x: 232, y: 170, width: 371, height: 100 },
      },
    ]);

    expect(selection.lyricsField?.label).toBe('Lyrics');
    expect(selection.styleField?.label).toBe('Styles');
  });

  it('clicks the blue Suno style magic button after the Advanced Create form is filled but style is blank', () => {
    const decision = simulateSunoCreateFill({
      currentUrl: 'https://suno.com/create',
      lyrics: '"Well, it must be removed," said the King very decidedly,',
      controls: [
        { label: 'Advanced', selected: true },
        {
          label: 'Personalize style prompt to match your taste',
          className: 'hxc-btn-variant-standard bg-accent-blue text-white',
          context: 'Styles 0/1000',
        },
        { label: 'Refresh recommended styles', context: 'Styles recommended styles' },
      ],
      fields: [
        {
          label: 'Lyrics',
          context: 'Lyrics 1998/5000',
          rect: { height: 248 },
        },
        {
          label: 'Styles',
          context: 'Styles 0/1000',
          rect: { height: 88 },
        },
      ],
      allowMagicClick: true,
    });
    expect(decision.action).toBe('clickStyleMagic');
    expect(decision.styleSource).toBe('sunoMagic');
    expect(decision.magicControl?.label).toBe('Personalize style prompt to match your taste');
  });

  it('does not treat Refresh recommended styles as the lyric-aware style magic button', () => {
    const decision = simulateSunoCreateFill({
      currentUrl: 'https://suno.com/create',
      lyrics: '"Well, it must be removed," said the King very decidedly,',
      controls: [
        { label: 'Advanced', selected: true },
        { label: 'Refresh recommended styles', context: 'Styles recommended styles' },
      ],
      fields: [
        {
          label: 'Lyrics',
          context: 'Lyrics 1998/5000',
          rect: { height: 248 },
        },
        {
          label: 'Styles',
          context: 'Styles 0/1000',
          rect: { height: 88 },
        },
      ],
      allowMagicClick: true,
    });
    expect(decision.action).toBe('manualAction');
    expect(decision.missing).toContain('styleMagic');
  });

  it('reuses the previous Suno-generated style before clicking style magic again', () => {
    const previousStyle = 'mariachi, neo-rockabilly, gregorian chant, dark female voice, dubstep beats';
    const decision = simulateSunoCreateFill({
      currentUrl: 'https://suno.com/create',
      lyrics: '"Well, it must be removed," said the King very decidedly,',
      fallbackStyle: previousStyle,
      controls: [
        { label: 'Advanced', selected: true },
        {
          label: 'Personalize style prompt to match your taste',
          className: 'hxc-btn-variant-standard bg-accent-blue text-white',
          context: 'Styles 0/1000',
        },
      ],
      fields: [
        {
          label: 'Lyrics',
          context: 'Lyrics 1998/5000',
          rect: { height: 248 },
        },
        {
          label: 'Styles',
          placeholder: 'binaural, patriotic, electronic piano, transverse flute, high-nrg',
          context: 'Styles 0/1000',
          rect: { height: 88 },
        },
      ],
      allowMagicClick: true,
    });
    expect(decision.action).toBe('readyToConfirm');
    expect(decision.stylePrompt).toBe(previousStyle);
    expect(decision.styleSource).toBe('fallback');
  });

  it('keeps waiting when Styles still contains an ignored value from the previous article', () => {
    const ignoredStyle = '奇幻儿童叙事民谣, 诙谐滑稽, 轻快跳脱, 木吉他, 木琴';
    const decision = simulateSunoCreateFill({
      currentUrl: 'https://suno.com/create',
      lyrics: 'Tom finds a bright snack box. He sings a happy song with Alice.',
      ignoredStyle,
      magicAlreadyRequested: true,
      allowMagicClick: false,
      controls: [
        { label: 'Advanced', selected: true },
        {
          label: 'Personalize style prompt to match your taste',
          className: 'hxc-btn-variant-standard bg-accent-blue text-white',
          context: 'Styles 0/1000',
        },
      ],
      fields: [
        {
          label: 'Lyrics',
          context: 'Lyrics 1998/5000',
          rect: { height: 248 },
        },
        {
          label: 'Styles',
          value: ignoredStyle,
          context: 'Styles 0/1000',
          rect: { height: 88 },
        },
      ],
    });
    expect(decision.action).toBe('waitStyleMagic');
    expect(decision.stylePrompt).toBeUndefined();
  });

  it('switches Simple Create mode to Advanced before filling lyrics and styles', () => {
    const decision = simulateSunoCreateFill({
      currentUrl: 'https://suno.com/create',
      lyrics: 'Alice looked around.',
      controls: [{ label: 'Advanced', selected: false }],
      fields: [],
    });
    expect(decision.action).toBe('switchAdvanced');
  });
});
