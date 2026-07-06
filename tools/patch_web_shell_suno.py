#!/usr/bin/env python3
"""Patch web_shell_screen.dart to use SunoAutomationController."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
path = root / "app/lib/features/web_shell/web_shell_screen.dart"
text = path.read_text(encoding="utf-8")
lines = text.splitlines()

# 1. Add imports if missing
import_line = "import 'suno/suno_automation_controller.dart';"
if import_line not in text:
    for i, line in enumerate(lines):
        if line.startswith("import 'web_bridge_protocol.dart'"):
            lines.insert(i, import_line)
            lines.insert(i, "import 'suno/suno_automation_host.dart';")
            break

text = "\n".join(lines) + "\n"
lines = text.splitlines()

# 2. Replace field block (82-119 approx)
old_fields = """  InAppWebViewController? _sunoController;
  Timer? _sunoAutomationTimer;
  int _sunoWebViewInstance = 0;
  int? _sunoArticleId;
  String _sunoStylePrompt = '';
  String _sunoLyrics = '';
  String _sunoAutomationStatus = 'idle';
  String? _sunoManualActionMessage;
  String? _sunoErrorMessage;
  String _sunoInitialUrl = 'https://suno.com/create';
  String _sunoIgnoredStylePrompt = '';
  String? _sunoSongUrl;
  String? _sunoAudioPath;
  String? _sunoMetadataPath;
  int? _sunoCreditsRemaining;
  DateTime? _sunoStyleMagicRequestedAt;
  final List<ArticleSongVersion> _sunoVersions = <ArticleSongVersion>[];
  final Set<String> _sunoDownloadedSongUrls = <String>{};
  final Set<String> _sunoDownloadedDownloadKeys = <String>{};
  final Set<String> _sunoDownloadInFlightKeys = <String>{};
  final Set<String> _sunoDetectedSongUrls = <String>{};
  final Set<String> _sunoTrustedSongUrls = <String>{};
  final Set<String> _sunoRejectedCandidateSongUrls = <String>{};
  String? _sunoPendingDownloadSongUrl;
  String? _sunoPendingDownloadTitle;
  DateTime? _sunoExistingDownloadStartedAt;
  int _sunoExistingDownloadMenuRetries = 0;
  bool _sunoExistingDownloadLibraryTried = false;
  DateTime? _sunoMenuDownloadClickedAt;
  String? _sunoLastLoadStopUrl;
  DateTime? _sunoLastLoadStopAt;
  bool _sunoVisible = false;
  bool _sunoCreateSubmitted = false;
  bool _sunoExistingDownloadOnly = false;
  bool _sunoCompletedStandby = false;
  bool _sunoCompletedStandbyFilled = false;
  bool _sunoAutomationBusy = false;
  int _sunoCreateBaselineVersionCount = 0;"""

new_fields = """  InAppWebViewController? _sunoController;
  late final SunoAutomationController _sunoEngine;"""

if old_fields in text:
    text = text.replace(old_fields, new_fields, 1)

# 3. initState
if "_sunoEngine = SunoAutomationController" not in text:
    text = text.replace(
        "  void initState() {\n    super.initState();",
        "  void initState() {\n    super.initState();\n"
        "    _sunoEngine = SunoAutomationController(host: _WebShellSunoHost(this));",
        1,
    )

subs = [
    ("_sunoAutomationStatus", "_sunoEngine.state.statusKey"),
    ("_sunoManualActionMessage", "_sunoEngine.state.manualActionMessage"),
    ("_sunoErrorMessage", "_sunoEngine.state.errorMessage"),
    ("_sunoArticleId", "_sunoEngine.state.articleId"),
    ("_sunoStylePrompt", "_sunoEngine.state.stylePrompt"),
    ("_sunoLyrics", "_sunoEngine.state.lyrics"),
    ("_sunoInitialUrl", "_sunoEngine.state.initialUrl"),
    ("_sunoIgnoredStylePrompt", "_sunoEngine.state.ignoredStylePrompt"),
    ("_sunoSongUrl", "_sunoEngine.state.songUrl"),
    ("_sunoAudioPath", "_sunoEngine.state.audioPath"),
    ("_sunoMetadataPath", "_sunoEngine.state.metadataPath"),
    ("_sunoCreditsRemaining", "_sunoEngine.state.creditsRemaining"),
    ("_sunoVersions", "_sunoEngine.state.versions"),
    ("_sunoDownloadedSongUrls", "_sunoEngine.state.downloadedSongUrls"),
    ("_sunoDetectedSongUrls", "_sunoEngine.state.detectedSongUrls"),
    ("_sunoVisible", "_sunoEngine.state.visible"),
    ("_sunoCreateSubmitted", "_sunoEngine.state.createSubmitted"),
    ("_sunoExistingDownloadOnly", "_sunoEngine.state.existingDownloadOnly"),
    ("_sunoCompletedStandby", "_sunoEngine.state.completedStandby"),
    ("_sunoAutomationBusy", "_sunoEngine.state.automationBusy"),
    ("_sunoWebViewInstance", "_sunoEngine.state.webViewInstance"),
    ("_sunoLastLoadStopUrl", "_sunoEngine.state.lastLoadStopUrl"),
    ("_sunoLastLoadStopAt", "_sunoEngine.state.lastLoadStopAt"),
]
for old, new in subs:
    text = text.replace(old, new)

# 4. Remove giant automation + script blocks by line markers
out_lines = []
skip = False
for i, line in enumerate(text.splitlines()):
    if line.strip() == "Future<Map<String, dynamic>> _startSunoAutomation({":
        skip = True
        out_lines.append("  Future<Map<String, dynamic>> _startSunoAutomation({")
        out_lines.append("    required Article article,")
        out_lines.append("    required String stylePrompt,")
        out_lines.append("    required String lyrics,")
        out_lines.append("    bool completedStandby = false,")
        out_lines.append("  }) async {")
        out_lines.append("    await _sunoEngine.startAutomation(")
        out_lines.append("      article: article,")
        out_lines.append("      stylePrompt: stylePrompt,")
        out_lines.append("      lyrics: lyrics,")
        out_lines.append("      completedStandby: completedStandby,")
        out_lines.append("      loadGroups: _cachedSunoSongGroups,")
        out_lines.append("      loadCachedState: _cachedSunoSongState,")
        out_lines.append("    );")
        out_lines.append("    final articleId = article.id;")
        out_lines.append("    if (articleId == null) {")
        out_lines.append("      throw const FormatException('文章尚未保存，不能生成歌曲');")
        out_lines.append("    }")
        out_lines.append("    return _songStatePayload(articleId);")
        out_lines.append("  }")
        continue
    if skip and line.strip() == "Future<Map<String, dynamic>> _handleSunoDebugInspect(":
        skip = False
    if skip:
        continue
    out_lines.append(line)

text = "\n".join(out_lines) + "\n"

# Replace other key methods with thin wrappers
replacements = [
    (
        """  Future<Map<String, dynamic>> _startExistingSunoDownload(
      Article article) async {""",
        """  Future<Map<String, dynamic>> _startExistingSunoDownload(
    Article article,
  ) async {
    final articleId = article.id;
    if (articleId == null) {
      throw const FormatException('文章尚未保存，不能下载歌曲');
    }
    await _sunoEngine.startExistingDownload(
      article: article,
      lyrics: _articleSongLyrics(article),
      loadGroups: _cachedSunoSongGroups,
      loadCachedState: _cachedSunoSongState,
      otherArticleUrls: _sunoSongUrlsForOtherArticles,
    );
    return _songStatePayload(articleId);
  }

  void __removed_startExistingSunoDownload(
      Article article) async {""",
    ),
    (
        """  void _stopSunoAutomation({required bool clearVisible}) {""",
        """  void _stopSunoAutomation({required bool clearVisible}) {
    _sunoEngine.stopAutomation(clearVisible: clearVisible);
  }

  void __removed_stopSunoAutomation({required bool clearVisible}) {""",
    ),
    (
        """  Future<void> _continueSunoAutomation() async {""",
        """  Future<void> _continueSunoAutomation() async {
    _sunoEngine.attachWebController(_sunoController);
    await _sunoEngine.tick();
  }

  Future<void> __removed_continueSunoAutomation() async {""",
    ),
    (
        """  Future<void> _confirmSunoCreate() async {""",
        """  Future<void> _confirmSunoCreate() async {
    _sunoEngine.attachWebController(_sunoController);
    await _sunoEngine.confirmCreate();
  }

  Future<void> __removed_confirmSunoCreate() async {""",
    ),
    (
        """  Future<void> _handleSunoDownload(DownloadStartRequest request) async {""",
        """  Future<void> _handleSunoDownload(DownloadStartRequest request) async {
    await _sunoEngine.handleWebViewDownload(request);
  }

  Future<void> __removed_handleSunoDownload(DownloadStartRequest request) async {""",
    ),
    (
        """  String _sunoOverlayStatusText() {""",
        """  String _sunoOverlayStatusText() => _sunoEngine.overlayStatusText();

  String __removed_sunoOverlayStatusText() {""",
    ),
]
for old, new in replacements:
    if old in text and new.split("(")[0] not in text:
        text = text.replace(old, new, 1)

# Remove dead __removed_ functions - crude: delete from __removed_ to next top-level private method at same indent
import re
text = re.sub(
    r"\n  (?:Future<[^>]+>|void|String|bool|int|List<[^>]+>|Map<[^>]+>) __removed_[\s\S]*?"
    r"(?=\n  (?:Future<|void |String |bool |int |List<|Map<|Widget |\@override))",
    "\n",
    text,
)

# WebView hooks
text = text.replace(
    "                  _sunoController = controller;",
    "                  _sunoController = controller;\n"
    "                  _sunoEngine.attachWebController(controller);",
)
text = text.replace(
    """                onLoadStop: (controller, url) {
                  _sunoEngine.state.lastLoadStopUrl = url?.toString();
                  _sunoEngine.state.lastLoadStopAt = DateTime.now();""",
    """                onLoadStop: (controller, url) {
                  _sunoEngine.onLoadStop(url?.toString());""",
)

# _startSunoPolling -> engine
text = text.replace("_startSunoPolling();", "_sunoEngine.startPolling();")
text = text.replace("_startSunoPolling()", "_sunoEngine.startPolling()")

# Add host class at end if missing
host_class = '''
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
    text = text.rstrip() + "\n" + host_class + "\n"

path.write_text(text, encoding="utf-8")
print("Patched web_shell_screen.dart")
