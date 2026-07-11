import '../../../data/models/article_model.dart';
import '../../../data/models/article_song_model.dart';

/// Host callbacks from [WebShellScreen] for persistence, articles, and UI refresh.
abstract class SunoAutomationHost {
  bool get isMounted;

  void requestSetState();

  Future<Article> loadSongArticle(int articleId);

  Future<String> articleSongLyricsHash(Article article);

  Future<List<SunoCachedSongGroup>> cachedSunoSongGroups(Article article);

  Future<ArticleSongState?> cachedSunoSongState(Article article);

  Future<void> pushSongState(int articleId);

  Future<void> saveSunoMetadataForVersions({
    required Article article,
    required List<ArticleSongVersion> versions,
    String? manualActionMessage,
    bool? downloadCompleteOverride,
    String? stylePromptOverride,
    List<String>? detectedSongUrlsOverride,
  });

  Future<String> resolvedSunoOutputDirectory();

  Future<Set<String>> sunoSongUrlsForOtherArticles(int articleId);

  String displayError(Object error);

  /// Navigate the single app WebView to Suno (saves Web UI route first).
  Future<void> beginSunoSession(String initialUrl);

  /// Restore Web UI in the single app WebView after Suno automation ends.
  Future<void> endSunoSession();

  Future<List<int>> downloadUrl(
    String url, {
    String? userAgent,
  });
}
