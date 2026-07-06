#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
path = root / "app/lib/features/web_shell/web_shell_screen.dart"
lines = path.read_text(encoding="utf-8").splitlines()

# Delete script block _sunoInspectScript through _sunoDownloadScript closing brace
start = None
end = None
for i, line in enumerate(lines):
    if line.strip() == "String get _sunoInspectScript => r'''":
        start = i
    if start is not None and line.strip() == "Future<Map<String, dynamic>> _handleListeningPrepare(":
        end = i
        break

if start is not None and end is not None:
    lines = lines[:start] + lines[end:]

text = "\n".join(lines)

# import SunoWebScripts
if "suno_web_scripts.dart" not in text:
    text = text.replace(
        "import 'suno/suno_automation_controller.dart';",
        "import 'suno/suno_automation_controller.dart';\nimport 'suno/suno_web_scripts.dart';\nimport 'suno/suno_web_bridge.dart';\nimport 'suno/suno_utilities.dart';",
    )

replacements = [
    ("_sunoInspectScript", "SunoWebScripts.inspectScript"),
    ("_sunoDomDiagnosticsScript", "SunoWebScripts.domDiagnosticsScript"),
    ("_sunoSnapshotScript", "SunoWebScripts.snapshotScript"),
    ("_sunoRowsDebugScript(", "SunoWebScripts.rowsDebugScript("),
    ("_sunoFillScript(", "SunoWebScripts.fillScript("),
    ("_sunoCreateScript", "SunoWebScripts.createScript"),
    ("_sunoCompletionScript(", "SunoWebScripts.completionScript("),
    ("_sunoDownloadScript(", "SunoWebScripts.downloadScript("),
    ("_sunoPendingDownloadSongUrl", "_sunoEngine.state.pendingDownloadSongUrl"),
    ("_sunoTrustedSongUrls", "_sunoEngine.state.trustedSongUrls"),
    ("_sunoPageKind(", "SunoUtilities.pageKind("),
    ("_canonicalSunoSongUrl", "SunoUtilities.canonicalSongUrl"),
    ("_isSyntheticSunoSongKey", "SunoUtilities.isSyntheticSongKey"),
    ("_mergeSunoSongUrls", "SunoUtilities.mergeSongUrls"),
]
for old, new in replacements:
    text = text.replace(old, new)

wrappers = '''
  Future<Map<String, dynamic>> _startExistingSunoDownload(
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

  void _stopSunoAutomation({required bool clearVisible}) {
    _sunoEngine.stopAutomation(clearVisible: clearVisible);
  }

  Future<void> _continueSunoAutomation() async {
    _sunoEngine.attachWebController(_sunoController);
    await _sunoEngine.tick();
  }

  Future<void> _confirmSunoCreate() async {
    _sunoEngine.attachWebController(_sunoController);
    await _sunoEngine.confirmCreate();
  }

  Future<void> _handleSunoDownload(DownloadStartRequest request) async {
    await _sunoEngine.handleWebViewDownload(request);
  }

  void _closeCompletedSunoOverlay() {
    _stopSunoAutomation(clearVisible: true);
    final articleId = _sunoEngine.state.articleId;
    if (articleId != null) {
      unawaited(_pushSongState(articleId));
    }
  }

'''

if "Future<Map<String, dynamic>> _startExistingSunoDownload(" not in text:
    text = text.replace(
        "    return _songStatePayload(articleId);\n  }\n  Future<Map<String, dynamic>> _handleSunoDebugInspect(",
        "    return _songStatePayload(articleId);\n  }\n" + wrappers + "  Future<Map<String, dynamic>> _handleSunoDebugInspect(",
    )

# _trustedSunoSongUrls() helper -> state.trustedSongUrlsList()
text = text.replace("_trustedSunoSongUrls()", "_sunoEngine.state.trustedSongUrlsList()")
text = text.replace("_trustedSunoSongUrls(", "_sunoEngine.state.trustedSongUrlsList(")

# Remove broken trusted helper if duplicated
import re
text = re.sub(
    r"\n  List<String> _trustedSunoSongUrls\(\[Iterable<Object\?> extra = const \[\]\]\) =>[\s\S]*?\n  void _trustSunoSongUrls\([\s\S]*?\n  \}\n",
    "\n",
    text,
    count=1,
)

path.write_text(text + "\n", encoding="utf-8")
print("Second pass patch done")
