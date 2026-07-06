import 'suno_utilities.dart';

/// Tracks post-create Suno batch: URLs that appeared on Create sidebar after submit.
class SunoCreateBatch {
  SunoCreateBatch({
    Set<String>? preCreateUrls,
    Set<String>? pendingUrls,
    Set<String>? downloadedUrls,
  })  : preCreateUrls = {...?preCreateUrls},
        pendingUrls = {...?pendingUrls},
        downloadedUrls = {...?downloadedUrls};

  final Set<String> preCreateUrls;
  final Set<String> pendingUrls;
  final Set<String> downloadedUrls;

  bool get hasPending => pendingUrls.isNotEmpty;

  int get pendingCount => pendingUrls.length;

  int get downloadedCount => downloadedUrls.length;

  /// Merge sidebar URLs from completion probe, excluding pre-create baseline.
  void absorbCreateSidebarUrls(Iterable<Object?> rawUrls) {
    for (final url in SunoUtilities.mergeSongUrls([rawUrls])) {
      if (preCreateUrls.contains(url)) {
        continue;
      }
      if (downloadedUrls.contains(url)) {
        pendingUrls.remove(url);
        continue;
      }
      pendingUrls.add(url);
    }
  }

  void markPreCreateUrls(Iterable<Object?> rawUrls) {
    preCreateUrls.addAll(SunoUtilities.mergeSongUrls([rawUrls]));
    pendingUrls.removeWhere(preCreateUrls.contains);
  }

  void markDownloaded(String songUrl) {
    final canonical = SunoUtilities.canonicalSongUrl(songUrl);
    if (canonical == null || SunoUtilities.isSyntheticSongKey(canonical)) {
      return;
    }
    downloadedUrls.add(canonical);
    pendingUrls.remove(canonical);
  }

  bool isPending(String songUrl) {
    final canonical = SunoUtilities.canonicalSongUrl(songUrl);
    return canonical != null && pendingUrls.contains(canonical);
  }

  String? nextPending({Set<String>? exclude}) {
    for (final url in pendingUrls) {
      if (exclude == null || !exclude.contains(url)) {
        return url;
      }
    }
    return null;
  }

  SunoCreateBatch copyWith({
    Set<String>? preCreateUrls,
    Set<String>? pendingUrls,
    Set<String>? downloadedUrls,
  }) {
    return SunoCreateBatch(
      preCreateUrls: preCreateUrls ?? this.preCreateUrls,
      pendingUrls: pendingUrls ?? this.pendingUrls,
      downloadedUrls: downloadedUrls ?? this.downloadedUrls,
    );
  }

  Map<String, Object?> snapshot() => {
        'preCreate': preCreateUrls.length,
        'pending': pendingUrls.length,
        'downloaded': downloadedUrls.length,
      };
}
