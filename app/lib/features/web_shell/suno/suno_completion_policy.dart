import 'suno_automation_state.dart';
import 'suno_utilities.dart';

/// Why [canComplete] returned false — for diagnostics.
enum SunoCompleteBlockReason {
  noNewVersionsSinceCreate,
  libraryNotSettled,
  openCandidatesRemain,
  urlsNotAllDownloaded,
  existingDownloadNoVersions,
  none,
}

/// Central gate for marking Suno automation complete.
class SunoCompletionPolicy {
  const SunoCompletionPolicy();

  SunoCompleteBlockReason blockReason(SunoAutomationState state) {
    if (state.existingDownloadOnly) {
      if (!state.hasAnyLocalVersion) {
        return SunoCompleteBlockReason.existingDownloadNoVersions;
      }
      if (!state.libraryScanSettled) {
        return SunoCompleteBlockReason.libraryNotSettled;
      }
      if (state.hasOpenLibraryCandidates) {
        return SunoCompleteBlockReason.openCandidatesRemain;
      }
      if (!state.allKnownUrlsDownloaded) {
        return SunoCompleteBlockReason.urlsNotAllDownloaded;
      }
      return SunoCompleteBlockReason.none;
    }

    if (!state.hasNewVersionsSinceCreate) {
      return SunoCompleteBlockReason.noNewVersionsSinceCreate;
    }
    if (!state.libraryScanSettled) {
      return SunoCompleteBlockReason.libraryNotSettled;
    }
    if (state.hasOpenLibraryCandidates) {
      return SunoCompleteBlockReason.openCandidatesRemain;
    }
    if (!state.allKnownUrlsDownloaded) {
      return SunoCompleteBlockReason.urlsNotAllDownloaded;
    }
    return SunoCompleteBlockReason.none;
  }

  bool canComplete(SunoAutomationState state) {
    return blockReason(state) == SunoCompleteBlockReason.none;
  }

  Map<String, Object?> allowedSummary(SunoAutomationState state) => {
        'existingDownloadOnly': state.existingDownloadOnly,
        'versions': state.versions.length,
        'baseline': state.createBaselineVersionCount,
        'batch': state.createBatch.snapshot(),
        'detectedUrls': state.detectedSongUrls.length,
        'librarySettled': state.libraryScanSettled,
      };

  Map<String, Object?> blockedSummary(
    SunoAutomationState state,
    SunoCompleteBlockReason reason,
  ) =>
      {
        'reason': reason.name,
        ...allowedSummary(state),
      };

  /// Library broad recall: detect-download OR post-create downloading.
  bool useLibraryBroadRecall(SunoAutomationState state) {
    return state.existingDownloadOnly ||
        (state.createSubmitted && state.statusKey == 'downloading');
  }

  List<String> libraryCandidateSongUrls(
    Map<String, dynamic> probe, {
    required bool broadRecall,
    required Set<String> downloadedUrls,
    required Set<String> rejectedUrls,
    required bool Function(String) hasLocalVersion,
  }) {
    final rawCandidates = probe['candidateSongs'];
    if (rawCandidates is! List) {
      return const <String>[];
    }
    final candidates = rawCandidates.whereType<Map>().toList(growable: false);
    if (candidates.isEmpty) {
      return const <String>[];
    }
    final scored = <({String url, int domIndex, int score})>[];
    for (var index = 0; index < candidates.length; index++) {
      final candidate = candidates[index];
      final url = SunoUtilities.canonicalSongUrl(candidate['href']);
      if (url == null ||
          SunoUtilities.isSyntheticSongKey(url) ||
          downloadedUrls.contains(url) ||
          rejectedUrls.contains(url) ||
          hasLocalVersion(url)) {
        continue;
      }
      final score = (candidate['expectedScore'] as num?)?.toInt() ?? 0;
      if (!broadRecall && score <= 0) {
        continue;
      }
      scored.add((url: url, domIndex: index, score: score));
    }
    if (broadRecall) {
      scored.sort((left, right) => left.domIndex.compareTo(right.domIndex));
    } else {
      scored.sort((left, right) => right.score.compareTo(left.score));
    }
    return scored.map((item) => item.url).toList(growable: false);
  }
}
