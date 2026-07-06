import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/data/models/article_song_model.dart';
import 'package:tomato_english_happy_talking/features/web_shell/suno/suno_automation_state.dart';
import 'package:tomato_english_happy_talking/features/web_shell/suno/suno_completion_policy.dart';
import 'package:tomato_english_happy_talking/features/web_shell/suno/suno_create_batch.dart';

void main() {
  group('SunoCreateBatch', () {
    test('absorbs sidebar urls excluding pre-create baseline', () {
      final batch = SunoCreateBatch(
        preCreateUrls: {'https://suno.com/song/old'},
      );
      batch.absorbCreateSidebarUrls([
        'https://suno.com/song/old',
        'https://suno.com/song/new-a',
        'https://suno.com/song/new-b',
      ]);
      expect(batch.pendingCount, 2);
      expect(batch.hasPending, isTrue);
    });

    test('markDownloaded moves url from pending to downloaded', () {
      final batch = SunoCreateBatch(
        pendingUrls: {'https://suno.com/song/new-a'},
      );
      batch.markDownloaded('https://suno.com/song/new-a');
      expect(batch.hasPending, isFalse);
      expect(batch.downloadedCount, 1);
    });
  });

  group('SunoCompletionPolicy', () {
    const policy = SunoCompletionPolicy();

    test('allows post-create complete when only batch pending remains', () {
      final state = SunoAutomationState()
        ..createSubmitted = true
        ..statusKey = 'downloading'
        ..createBaselineVersionCount = 0
        ..versions.add(
          _fakeVersion('https://suno.com/song/a'),
        );
      state.createBatch = SunoCreateBatch(
        pendingUrls: {'https://suno.com/song/b'},
        downloadedUrls: {'https://suno.com/song/a'},
      );
      state.detectedSongUrls.add('https://suno.com/song/a');
      state.downloadedSongUrls.add('https://suno.com/song/a');
      state.libraryScanSettled = true;
      state.mightHaveMoreLibraryRows = false;

      expect(policy.canComplete(state), isTrue);
      expect(policy.blockReason(state), SunoCompleteBlockReason.none);
    });

    test('blocks post-create complete while library scan is unsettled', () {
      final state = SunoAutomationState()
        ..createSubmitted = true
        ..statusKey = 'downloading'
        ..createBaselineVersionCount = 0
        ..libraryScanSettled = false
        ..mightHaveMoreLibraryRows = true;
      state.versions.add(_fakeVersion('https://suno.com/song/a'));
      state.createBatch = SunoCreateBatch(
        pendingUrls: {'https://suno.com/song/b'},
        downloadedUrls: {'https://suno.com/song/a'},
      );
      state.detectedSongUrls.add('https://suno.com/song/a');
      state.downloadedSongUrls.add('https://suno.com/song/a');

      expect(policy.canComplete(state), isFalse);
      expect(
          policy.blockReason(state), SunoCompleteBlockReason.libraryNotSettled);
    });

    test('blocks post-create complete while library candidates remain', () {
      final state = SunoAutomationState()
        ..createSubmitted = true
        ..statusKey = 'downloading'
        ..createBaselineVersionCount = 0
        ..libraryScanSettled = true
        ..mightHaveMoreLibraryRows = false
        ..hasOpenLibraryCandidates = true;
      state.versions.add(_fakeVersion('https://suno.com/song/a'));
      state.createBatch = SunoCreateBatch(
        pendingUrls: {'https://suno.com/song/b'},
        downloadedUrls: {'https://suno.com/song/a'},
      );
      state.detectedSongUrls.add('https://suno.com/song/a');
      state.downloadedSongUrls.add('https://suno.com/song/a');

      expect(policy.canComplete(state), isFalse);
      expect(policy.blockReason(state),
          SunoCompleteBlockReason.openCandidatesRemain);
    });

    test('allows complete when batch empty and versions grew', () {
      final state = SunoAutomationState()
        ..createSubmitted = true
        ..statusKey = 'downloading'
        ..createBaselineVersionCount = 0
        ..libraryScanSettled = true
        ..mightHaveMoreLibraryRows = false;
      state.versions.addAll([
        _fakeVersion('https://suno.com/song/a'),
        _fakeVersion('https://suno.com/song/b'),
      ]);
      state.createBatch = SunoCreateBatch(
        downloadedUrls: {
          'https://suno.com/song/a',
          'https://suno.com/song/b',
        },
      );
      state.detectedSongUrls.addAll(state.createBatch.downloadedUrls);
      state.downloadedSongUrls.addAll(state.createBatch.downloadedUrls);

      expect(policy.canComplete(state), isTrue);
    });
  });
}

ArticleSongVersion _fakeVersion(String songUrl) {
  return ArticleSongVersion(
    id: 'test_${songUrl.hashCode}',
    audioPath: '/tmp/test.mp3',
    songUrl: songUrl,
  );
}
