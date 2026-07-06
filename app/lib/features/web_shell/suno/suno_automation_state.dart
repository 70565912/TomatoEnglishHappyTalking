import '../../../data/models/article_song_model.dart';
import 'suno_create_batch.dart';
import 'suno_utilities.dart';

/// Mutable Suno automation session state.
class SunoAutomationState {
  SunoAutomationState();

  int? articleId;
  String stylePrompt = '';
  String lyrics = '';
  String statusKey = 'idle';
  String? manualActionMessage;
  String? errorMessage;
  String initialUrl = 'https://suno.com/create';
  String ignoredStylePrompt = '';
  String? songUrl;
  String? audioPath;
  String? metadataPath;
  int? creditsRemaining;
  DateTime? styleMagicRequestedAt;
  final List<ArticleSongVersion> versions = <ArticleSongVersion>[];
  final Set<String> downloadedSongUrls = <String>{};
  final Set<String> downloadedDownloadKeys = <String>{};
  final Set<String> downloadInFlightKeys = <String>{};
  final Set<String> detectedSongUrls = <String>{};
  final Set<String> trustedSongUrls = <String>{};
  final Set<String> rejectedCandidateSongUrls = <String>{};
  String? pendingDownloadSongUrl;
  String? pendingDownloadTitle;
  DateTime? existingDownloadStartedAt;
  int existingDownloadMenuRetries = 0;
  bool existingDownloadLibraryTried = false;
  DateTime? menuDownloadClickedAt;
  String? lastLoadStopUrl;
  DateTime? lastLoadStopAt;
  bool visible = false;
  bool createSubmitted = false;
  bool existingDownloadOnly = false;
  bool completedStandby = false;
  bool completedStandbyFilled = false;
  bool automationBusy = false;
  int createBaselineVersionCount = 0;
  int webViewInstance = 0;
  SunoCreateBatch createBatch = SunoCreateBatch();

  /// Suppress login false positives during navigation (loadUrl / confirm create).
  DateTime? navigatingUntil;

  /// Last library probe had candidates not yet opened.
  bool hasOpenLibraryCandidates = false;

  /// Page settled on library/create for scan exhaustion.
  bool libraryScanSettled = false;

  /// Lazy-loaded library may still have rows.
  bool mightHaveMoreLibraryRows = true;

  bool get hasAnyLocalVersion => versions.isNotEmpty;

  bool hasLocalVersionForSongUrl(String songUrl) {
    final canonical = SunoUtilities.canonicalSongUrl(songUrl);
    if (canonical == null) {
      return false;
    }
    return versions.any(
      (version) => SunoUtilities.canonicalSongUrl(version.songUrl) == canonical,
    );
  }

  bool get hasNewVersionsSinceCreate =>
      versions.length > createBaselineVersionCount;

  bool get allKnownUrlsDownloaded {
    if (detectedSongUrls.isEmpty && createBatch.downloadedUrls.isEmpty) {
      return false;
    }
    final targets = SunoUtilities.mergeSongUrls([
      detectedSongUrls,
      createBatch.downloadedUrls,
    ]);
    if (targets.isEmpty) {
      return downloadedSongUrls.isNotEmpty || versions.isNotEmpty;
    }
    return targets.every((url) {
      return downloadedSongUrls.contains(url) || hasLocalVersionForSongUrl(url);
    });
  }

  bool currentDownloadsComplete() {
    if (detectedSongUrls.isEmpty) {
      return false;
    }
    final downloaded = versions
        .map((version) => SunoUtilities.canonicalSongUrl(version.songUrl))
        .whereType<String>()
        .where(
          (value) =>
              value.isNotEmpty && !SunoUtilities.isSyntheticSongKey(value),
        )
        .toSet();
    return detectedSongUrls.every((value) {
      final canonical = SunoUtilities.canonicalSongUrl(value);
      return canonical != null && downloaded.contains(canonical);
    });
  }

  List<String> trustedSongUrlsList([Iterable<Object?> extra = const []]) =>
      SunoUtilities.mergeSongUrls([trustedSongUrls, extra]);

  void trustSongUrls(Iterable<Object?> values) {
    trustedSongUrls.addAll(
      SunoUtilities.mergeSongUrls([values]).where(
        (value) => !rejectedCandidateSongUrls.contains(value),
      ),
    );
  }

  void rememberDownloadedSongUrls() {
    downloadedSongUrls
      ..clear()
      ..addAll(
        versions
            .map((version) => SunoUtilities.canonicalSongUrl(version.songUrl))
            .whereType<String>()
            .where(
              (value) =>
                  value.isNotEmpty && !SunoUtilities.isSyntheticSongKey(value),
            ),
      );
  }

  void syncDownloadedIntoDetected() {
    detectedSongUrls.addAll(
      versions
          .map((version) => SunoUtilities.canonicalSongUrl(version.songUrl))
          .whereType<String>()
          .where(
            (value) =>
                value.isNotEmpty && !SunoUtilities.isSyntheticSongKey(value),
          ),
    );
  }

  void markNavigating([Duration hold = const Duration(seconds: 6)]) {
    navigatingUntil = DateTime.now().add(hold);
  }

  bool get suppressLoginProbe {
    final until = navigatingUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  String? pendingDownloadTarget(List<String> missingSongUrls) {
    final currentPending =
        SunoUtilities.canonicalSongUrl(pendingDownloadSongUrl) ?? '';
    if (currentPending.isNotEmpty && missingSongUrls.contains(currentPending)) {
      return currentPending;
    }
    return missingSongUrls.isEmpty ? null : missingSongUrls.first;
  }

  bool isAwaitingMenuDownload() {
    final clickedAt = menuDownloadClickedAt;
    if (clickedAt == null) {
      return false;
    }
    return DateTime.now().difference(clickedAt) < const Duration(seconds: 45);
  }

  void resetForStop({required bool clearVisible}) {
    createSubmitted = false;
    existingDownloadOnly = false;
    completedStandby = false;
    completedStandbyFilled = false;
    styleMagicRequestedAt = null;
    ignoredStylePrompt = '';
    pendingDownloadSongUrl = null;
    pendingDownloadTitle = null;
    existingDownloadStartedAt = null;
    existingDownloadMenuRetries = 0;
    existingDownloadLibraryTried = false;
    lastLoadStopUrl = null;
    lastLoadStopAt = null;
    menuDownloadClickedAt = null;
    createBaselineVersionCount = 0;
    downloadInFlightKeys.clear();
    rejectedCandidateSongUrls.clear();
    trustedSongUrls.clear();
    navigatingUntil = null;
    hasOpenLibraryCandidates = false;
    libraryScanSettled = false;
    mightHaveMoreLibraryRows = true;
    createBatch = SunoCreateBatch();
    if (clearVisible) {
      statusKey = 'idle';
      manualActionMessage = null;
      errorMessage = null;
      detectedSongUrls.clear();
      visible = false;
    }
  }
}
