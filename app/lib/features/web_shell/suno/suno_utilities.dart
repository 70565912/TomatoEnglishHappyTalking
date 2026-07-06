/// Shared Suno URL / page helpers (no WebView dependency).
class SunoUtilities {
  SunoUtilities._();

  static String? canonicalSongUrl(Object? value) {
    final raw = (value ?? '').toString().trim();
    if (raw.isEmpty) {
      return null;
    }
    final match = RegExp(
      r'/song/([0-9a-fA-F-]{36})',
      caseSensitive: false,
    ).firstMatch(raw);
    if (match != null) {
      return 'https://suno.com/song/${match.group(1)!.toLowerCase()}';
    }
    if (raw.startsWith('https://') && raw.contains('/song/')) {
      return raw.split('?').first.split('#').first;
    }
    return raw.startsWith('http') ? raw : null;
  }

  static bool isSyntheticSongKey(String value) {
    return value.trim().toLowerCase().startsWith('suno-row:');
  }

  static List<String> songUrlList(Object? value) {
    final urls = <String>[];
    if (value is List) {
      for (final item in value) {
        final text = canonicalSongUrl(item);
        if (text == null || isSyntheticSongKey(text)) {
          continue;
        }
        urls.add(text);
      }
    }
    return urls.toSet().toList(growable: false);
  }

  static List<String> mergeSongUrls(Iterable<Iterable<Object?>> sources) {
    final seen = <String>{};
    final urls = <String>[];
    for (final source in sources) {
      for (final value in source) {
        final text = canonicalSongUrl(value);
        if (text == null || isSyntheticSongKey(text) || !seen.add(text)) {
          continue;
        }
        urls.add(text);
      }
    }
    return urls;
  }

  static bool isLoginFlowUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) {
      return false;
    }
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    final isSunoHost = host == 'suno.com' || host == 'www.suno.com';
    final sunoAuthPath = RegExp(
      r'/(login|log-in|signin|sign-in|signup|sign-up|auth|oauth|sso)(/|$)',
      caseSensitive: false,
    ).hasMatch(path);
    if (isSunoHost && sunoAuthPath) {
      return true;
    }
    final sunoRelatedAuthHost = host.endsWith('.suno.com') &&
        RegExp(r'auth|account|login|clerk').hasMatch(host);
    final externalAuthHost = RegExp(
      r'accounts\.google\.com|discord(?:app)?\.com|appleid\.apple\.com|clerk|oauth|auth|login|sso|identity',
      caseSensitive: false,
    ).hasMatch(host);
    return !isSunoHost && (sunoRelatedAuthHost || externalAuthHost);
  }

  static bool isProfileUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) {
      return false;
    }
    final host = uri.host.toLowerCase();
    if (host != 'suno.com' && host != 'www.suno.com') {
      return false;
    }
    return uri.pathSegments.isNotEmpty &&
        uri.pathSegments.first.startsWith('@');
  }

  static String pageKind(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) {
      return 'unknown';
    }
    if (isLoginFlowUrl(url)) {
      return 'login';
    }
    final host = uri.host.toLowerCase();
    if (host != 'suno.com' && host != 'www.suno.com') {
      return 'external';
    }
    if (isProfileUrl(url)) {
      return 'profile';
    }
    if (uri.pathSegments.contains('song')) {
      return 'song';
    }
    if (uri.pathSegments.contains('create')) {
      return 'create';
    }
    if (uri.pathSegments.contains('library') ||
        (uri.pathSegments.length == 1 && uri.pathSegments.first == 'me')) {
      return 'library';
    }
    return uri.pathSegments.isEmpty ? 'home' : 'unknown';
  }

  static bool samePageLocation(String left, String right) {
    final leftUri = Uri.tryParse(left.trim());
    final rightUri = Uri.tryParse(right.trim());
    if (leftUri == null || rightUri == null) {
      return left.trim() == right.trim();
    }
    return leftUri.host.toLowerCase() == rightUri.host.toLowerCase() &&
        leftUri.path == rightUri.path;
  }

  static bool isPageSettled({
    required String currentUrl,
    required String? lastLoadStopUrl,
    required DateTime? lastLoadStopAt,
    Duration minSettle = const Duration(milliseconds: 800),
  }) {
    if (lastLoadStopUrl == null || lastLoadStopAt == null) {
      return false;
    }
    if (!samePageLocation(currentUrl, lastLoadStopUrl)) {
      return false;
    }
    return DateTime.now().difference(lastLoadStopAt) >= minSettle;
  }

  static String? songId(String songUrl) {
    final match = RegExp(
      r'/song/([0-9a-fA-F-]{36})',
      caseSensitive: false,
    ).firstMatch(songUrl);
    return match?.group(1)?.toLowerCase();
  }

  static String canonicalCdnMediaUrl(String songUrl) {
    final id = songId(songUrl);
    if (id == null || id.isEmpty) {
      return '';
    }
    return 'https://cdn1.suno.ai/$id.mp3';
  }

  static String? matchingMediaUrl(String mediaUrl, String songUrl) {
    final id = songId(songUrl);
    if (id == null || id.isEmpty) {
      return null;
    }
    final normalized = mediaUrl.trim();
    if (normalized.contains(id)) {
      return normalized;
    }
    return null;
  }

  static String mediaExtension(String mediaUrl) {
    final lower = mediaUrl.toLowerCase();
    if (lower.contains('.m4a')) {
      return '.m4a';
    }
    if (lower.contains('.wav')) {
      return '.wav';
    }
    if (lower.contains('.webm')) {
      return '.webm';
    }
    return '.mp3';
  }

  static bool isVerifiableMediaUrl(String mediaUrl) {
    final lower = mediaUrl.toLowerCase();
    return lower.contains('cdn') &&
        lower.contains('suno') &&
        RegExp(r'\.(mp3|m4a|wav|webm)').hasMatch(lower);
  }

  static bool isRejectedPreviewMediaUrl(String mediaUrl) {
    return RegExp(
      r'preview|sample|snippet|teaser|sil-100',
      caseSensitive: false,
    ).hasMatch(mediaUrl);
  }
}
