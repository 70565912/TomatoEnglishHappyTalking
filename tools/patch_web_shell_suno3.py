#!/usr/bin/env python3
from pathlib import Path

path = Path(__file__).resolve().parents[1] / "app/lib/features/web_shell/web_shell_screen.dart"
lines = path.read_text(encoding="utf-8").splitlines()

def find_line(prefix):
    for i, line in enumerate(lines):
        if line.startswith(prefix):
            return i
    return None

# Remove dead automation helpers between _deleteFileIfExists and _evaluateSunoJson
start = find_line("  Future<int> _downloadSunoDirectMediaUrls({")
end = find_line("  Future<Map<String, dynamic>> _evaluateSunoJson(")
if start is not None and end is not None:
    lines = lines[:start] + lines[end:]

text = "\n".join(lines)

# Remove duplicate suno helpers near end (keep _currentSunoDownloadsComplete and _sunoSongUrlsForOtherArticles)
import re
text = re.sub(
    r"\n  bool _hasNewSunoVersionsSinceCreate\(\)[\s\S]*?"
    r"\n  String _sunoOutputDirectorySettingForSave\(",
    "\n  String _sunoOutputDirectorySettingForSave(",
    text,
    count=1,
)

text = text.replace(
    "_sunoEngine.state.songUrlList(",
    "SunoUtilities.songUrlList(",
)

# Simplify overlay text
text = text.replace(
    """  String _sunoOverlayStatusText() {
    if (_sunoEngine.state.errorMessage != null) {
      return 'Suno 自动化失败：${_sunoEngine.state.errorMessage}';
    }
    if ((_sunoEngine.state.manualActionMessage ?? '').trim().isNotEmpty) {
      return _sunoEngine.state.manualActionMessage!;
    }
    switch (_sunoEngine.state.statusKey) {
      case 'waitingLogin':
        return '等待 Suno 登录';
      case 'waitingConfirm':
        return 'Suno 歌词和自动风格已填写，等待确认创建';
      case 'creating':
        return 'Suno 正在生成歌曲';
      case 'downloading':
        return '正在下载 Suno 歌曲';
      case 'complete':
        return 'Suno 歌曲下载完成，请确认关闭 Suno 窗口。';
      default:
        return 'Suno 自动操作中';
    }
  }""",
    "  String _sunoOverlayStatusText() => _sunoEngine.overlayStatusText();",
)

host = '''
class _WebShellSunoHost implements SunoAutomationHost {
  _WebShellSunoHost(this._state);

  final WebShellScreenState _state;

  @override
  bool get isMounted => _state.mounted;

  @override
  void requestSetState() {
    if (_state.mounted) {
      _state.setState(() {});
    }
  }

  @override
  Future<Article> loadSongArticle(int articleId) =>
      _state._songArticle(articleId);

  @override
  Future<String> articleSongLyricsHash(Article article) =>
      _state._articleSongLyricsHash(article);

  @override
  Future<List<SunoCachedSongGroup>> cachedSunoSongGroups(Article article) =>
      _state._cachedSunoSongGroups(article);

  @override
  Future<ArticleSongState?> cachedSunoSongState(Article article) =>
      _state._cachedSunoSongState(article);

  @override
  Future<void> pushSongState(int articleId) => _state._pushSongState(articleId);

  @override
  Future<void> saveSunoMetadataForVersions({
    required Article article,
    required List<ArticleSongVersion> versions,
    String? manualActionMessage,
    bool? downloadCompleteOverride,
    String? stylePromptOverride,
    List<String>? detectedSongUrlsOverride,
  }) =>
      _state._saveSunoMetadataForVersions(
        article: article,
        versions: versions,
        manualActionMessage: manualActionMessage,
        downloadCompleteOverride: downloadCompleteOverride,
        stylePromptOverride: stylePromptOverride,
        detectedSongUrlsOverride: detectedSongUrlsOverride,
      );

  @override
  Future<String> resolvedSunoOutputDirectory() =>
      _state._resolvedSunoOutputDirectorySetting();

  @override
  Future<Set<String>> sunoSongUrlsForOtherArticles(int articleId) =>
      _state._sunoSongUrlsForOtherArticles(articleId);

  @override
  String displayError(Object error) => _state._displayError(error);

  @override
  Future<List<int>> downloadUrl(String url, {String? userAgent}) =>
      _state._downloadSunoUrl(url, userAgent: userAgent);
}
'''

if "_WebShellSunoHost" not in text:
    text = text.replace(
        "\nclass _NativeErrorView extends StatelessWidget {",
        "\n" + host + "\nclass _NativeErrorView extends StatelessWidget {",
    )

path.write_text(text + "\n", encoding="utf-8")
print("cleanup done")
