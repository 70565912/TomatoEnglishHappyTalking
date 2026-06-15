class ArticleSongState {
  const ArticleSongState({
    required this.articleId,
    required this.status,
    this.stylePrompt = '',
    this.audioPath,
    this.errorMessage,
    this.durationMs,
    this.source = '',
    this.lyricsCompressed = false,
    this.songUrl,
    this.metadataPath,
    this.manualActionMessage,
    this.automationStatus,
    this.creditsRemaining,
    this.downloadComplete,
    this.detectedSongUrls = const [],
    this.versions = const [],
  });

  final int articleId;
  final String status;
  final String stylePrompt;
  final String? audioPath;
  final String? errorMessage;
  final int? durationMs;
  final String source;
  final bool lyricsCompressed;
  final String? songUrl;
  final String? metadataPath;
  final String? manualActionMessage;
  final String? automationStatus;
  final int? creditsRemaining;
  final bool? downloadComplete;
  final List<String> detectedSongUrls;
  final List<ArticleSongVersion> versions;

  Map<String, dynamic> toJson() => {
        'articleId': articleId,
        'status': status,
        'stylePrompt': stylePrompt,
        'audioPath': audioPath,
        'errorMessage': errorMessage,
        'durationMs': durationMs,
        'source': source,
        if (lyricsCompressed) 'lyricsCompressed': true,
        if (songUrl != null) 'songUrl': songUrl,
        if (metadataPath != null) 'metadataPath': metadataPath,
        if (manualActionMessage != null)
          'manualActionMessage': manualActionMessage,
        if (automationStatus != null) 'automationStatus': automationStatus,
        if (creditsRemaining != null) 'creditsRemaining': creditsRemaining,
        if (downloadComplete != null) 'downloadComplete': downloadComplete,
        if (detectedSongUrls.isNotEmpty) 'detectedSongUrls': detectedSongUrls,
        if (versions.isNotEmpty)
          'versions': versions.map((version) => version.toJson()).toList(),
      };

  ArticleSongState copyWith({
    String? status,
    String? stylePrompt,
    String? audioPath,
    String? errorMessage,
    int? durationMs,
    String? source,
    bool? lyricsCompressed,
    String? songUrl,
    String? metadataPath,
    String? manualActionMessage,
    String? automationStatus,
    int? creditsRemaining,
    bool? downloadComplete,
    List<String>? detectedSongUrls,
    List<ArticleSongVersion>? versions,
  }) =>
      ArticleSongState(
        articleId: articleId,
        status: status ?? this.status,
        stylePrompt: stylePrompt ?? this.stylePrompt,
        audioPath: audioPath ?? this.audioPath,
        errorMessage: errorMessage,
        durationMs: durationMs ?? this.durationMs,
        source: source ?? this.source,
        lyricsCompressed: lyricsCompressed ?? this.lyricsCompressed,
        songUrl: songUrl ?? this.songUrl,
        metadataPath: metadataPath ?? this.metadataPath,
        manualActionMessage: manualActionMessage ?? this.manualActionMessage,
        automationStatus: automationStatus ?? this.automationStatus,
        creditsRemaining: creditsRemaining ?? this.creditsRemaining,
        downloadComplete: downloadComplete ?? this.downloadComplete,
        detectedSongUrls: detectedSongUrls ?? this.detectedSongUrls,
        versions: versions ?? this.versions,
      );
}

class ArticleSongVersion {
  const ArticleSongVersion({
    required this.id,
    required this.audioPath,
    this.title,
    this.songUrl,
    this.durationMs,
    this.createdAt,
    this.stylePrompt,
    this.styleKey,
    this.lyricsHash,
    this.submittedLyrics,
    this.source = 'suno',
    this.timelinePath,
    this.timelineStatus,
    this.timelineConfidence,
    this.timelineError,
    this.isDefault = false,
  });

  final String id;
  final String audioPath;
  final String? title;
  final String? songUrl;
  final int? durationMs;
  final String? createdAt;
  final String? stylePrompt;
  final String? styleKey;
  final String? lyricsHash;
  final String? submittedLyrics;
  final String source;
  final String? timelinePath;
  final String? timelineStatus;
  final double? timelineConfidence;
  final String? timelineError;
  final bool isDefault;

  Map<String, dynamic> toJson() => {
        'id': id,
        'audioPath': audioPath,
        if (title != null) 'title': title,
        if (songUrl != null) 'songUrl': songUrl,
        if (durationMs != null) 'durationMs': durationMs,
        if (createdAt != null) 'createdAt': createdAt,
        if (stylePrompt != null) 'stylePrompt': stylePrompt,
        if (styleKey != null) 'styleKey': styleKey,
        if (lyricsHash != null) 'lyricsHash': lyricsHash,
        if (submittedLyrics != null) 'submittedLyrics': submittedLyrics,
        'source': source,
        if (timelinePath != null) 'timelinePath': timelinePath,
        if (timelineStatus != null) 'timelineStatus': timelineStatus,
        if (timelineConfidence != null)
          'timelineConfidence': timelineConfidence,
        if (timelineError != null) 'timelineError': timelineError,
        if (isDefault) 'isDefault': true,
      };

  ArticleSongVersion copyWith({
    String? id,
    String? audioPath,
    String? title,
    String? songUrl,
    int? durationMs,
    String? createdAt,
    String? stylePrompt,
    String? styleKey,
    String? lyricsHash,
    String? submittedLyrics,
    String? source,
    String? timelinePath,
    String? timelineStatus,
    double? timelineConfidence,
    String? timelineError,
    bool? isDefault,
  }) =>
      ArticleSongVersion(
        id: id ?? this.id,
        audioPath: audioPath ?? this.audioPath,
        title: title ?? this.title,
        songUrl: songUrl ?? this.songUrl,
        durationMs: durationMs ?? this.durationMs,
        createdAt: createdAt ?? this.createdAt,
        stylePrompt: stylePrompt ?? this.stylePrompt,
        styleKey: styleKey ?? this.styleKey,
        lyricsHash: lyricsHash ?? this.lyricsHash,
        submittedLyrics: submittedLyrics ?? this.submittedLyrics,
        source: source ?? this.source,
        timelinePath: timelinePath ?? this.timelinePath,
        timelineStatus: timelineStatus ?? this.timelineStatus,
        timelineConfidence: timelineConfidence ?? this.timelineConfidence,
        timelineError: timelineError,
        isDefault: isDefault ?? this.isDefault,
      );

  static ArticleSongVersion? fromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final id = (value['id'] ?? '').toString().trim();
    final audioPath = (value['audioPath'] ?? '').toString().trim();
    if (id.isEmpty || audioPath.isEmpty) {
      return null;
    }
    return ArticleSongVersion(
      id: id,
      audioPath: audioPath,
      title: _nonEmpty(value['title']),
      songUrl: _nonEmpty(value['songUrl']),
      durationMs: (value['durationMs'] as num?)?.toInt(),
      createdAt: _nonEmpty(value['createdAt']),
      stylePrompt: _nonEmpty(value['stylePrompt']),
      styleKey: _nonEmpty(value['styleKey']),
      lyricsHash: _nonEmpty(value['lyricsHash']),
      submittedLyrics: _nonEmpty(value['submittedLyrics']),
      source: _nonEmpty(value['source']) ?? 'suno',
      timelinePath: _nonEmpty(value['timelinePath']),
      timelineStatus: _nonEmpty(value['timelineStatus']),
      timelineConfidence: (value['timelineConfidence'] as num?)?.toDouble(),
      timelineError: _nonEmpty(value['timelineError']),
      isDefault: value['isDefault'] == true,
    );
  }

  static String? _nonEmpty(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }
}

class SunoCachedSongGroup {
  const SunoCachedSongGroup({
    required this.lyricsHash,
    required this.versions,
    required this.detectedSongUrls,
    required this.songUrl,
    required this.metadataPath,
    required this.manualActionMessage,
    this.stylePrompt = '',
  });

  final String lyricsHash;
  final List<ArticleSongVersion> versions;
  final List<String> detectedSongUrls;
  final String? songUrl;
  final String? metadataPath;
  final String? manualActionMessage;
  final String stylePrompt;

  bool get hasKnownCompleteDownloads {
    if (detectedSongUrls.isEmpty) {
      return false;
    }
    final downloaded = versions
        .map((version) => (version.songUrl ?? '').trim())
        .where((value) => value.isNotEmpty)
        .toSet();
    return detectedSongUrls.every(downloaded.contains);
  }

  List<String> get missingSongUrls {
    final downloaded = versions
        .map((version) => (version.songUrl ?? '').trim())
        .where((value) => value.isNotEmpty)
        .toSet();
    return detectedSongUrls
        .where((url) => url.trim().isNotEmpty && !downloaded.contains(url))
        .toList(growable: false);
  }
}

class SunoCachedSongGroupBuilder {
  SunoCachedSongGroupBuilder({
    required this.lyricsHash,
    this.stylePrompt = '',
  });

  final String lyricsHash;
  String stylePrompt;
  String? songUrl;
  String? metadataPath;
  String? manualActionMessage;
  final List<ArticleSongVersion> versions = <ArticleSongVersion>[];
  final Set<String> detectedSongUrls = <String>{};

  void addVersions(Iterable<ArticleSongVersion> nextVersions) {
    for (final version in nextVersions) {
      final versionSongUrl = (version.songUrl ?? '').trim();
      final duplicateIndex = versions.indexWhere((item) {
        final itemSongUrl = (item.songUrl ?? '').trim();
        if (versionSongUrl.isNotEmpty && itemSongUrl == versionSongUrl) {
          return true;
        }
        return item.audioPath == version.audioPath;
      });
      if (duplicateIndex >= 0) {
        versions[duplicateIndex] = version;
      } else {
        versions.add(version);
      }
    }
  }

  SunoCachedSongGroup build() {
    final mergedDetectedSongUrls = <String>{...detectedSongUrls};
    if (mergedDetectedSongUrls.isNotEmpty) {
      mergedDetectedSongUrls.addAll(
        versions
            .map((version) => (version.songUrl ?? '').trim())
            .where((value) => value.isNotEmpty),
      );
    } else {
      final knownSongUrl = (songUrl ?? '').trim();
      final hasKnownDownloadedVersion = knownSongUrl.isNotEmpty &&
          versions.any(
            (version) => (version.songUrl ?? '').trim() == knownSongUrl,
          );
      if (hasKnownDownloadedVersion) {
        mergedDetectedSongUrls.add(knownSongUrl);
      }
    }
    return SunoCachedSongGroup(
      lyricsHash: lyricsHash,
      stylePrompt: stylePrompt,
      versions: List<ArticleSongVersion>.unmodifiable(versions),
      detectedSongUrls: List<String>.unmodifiable(mergedDetectedSongUrls),
      songUrl: songUrl,
      metadataPath: metadataPath,
      manualActionMessage: manualActionMessage,
    );
  }
}
