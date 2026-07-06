#!/usr/bin/env python3
"""Port _continueSunoAutomation from web_shell_screen to controller tick body."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
screen = root / "app/lib/features/web_shell/web_shell_screen.dart"
body = "\n".join(screen.read_text(encoding="utf-8").splitlines()[3863:4727])
# strip outer function wrapper lines
body = body.replace("Future<void> _continueSunoAutomation() async {", "")
if body.rstrip().endswith("}"):
    body = body.rstrip()[:-1]

subs = [
    ("_sunoAutomationBusy", "state.automationBusy"),
    ("_sunoArticleId", "state.articleId"),
    ("_sunoController", "webController"),
    ("_sunoAutomationStatus", "state.statusKey"),
    ("_sunoStylePrompt", "state.stylePrompt"),
    ("_sunoLyrics", "state.lyrics"),
    ("_sunoIgnoredStylePrompt", "state.ignoredStylePrompt"),
    ("_sunoVersions", "state.versions"),
    ("_sunoDownloadedSongUrls", "state.downloadedSongUrls"),
    ("_sunoDownloadedDownloadKeys", "state.downloadedDownloadKeys"),
    ("_sunoDownloadInFlightKeys", "state.downloadInFlightKeys"),
    ("_sunoDetectedSongUrls", "state.detectedSongUrls"),
    ("_sunoTrustedSongUrls", "state.trustedSongUrls"),
    ("_sunoRejectedCandidateSongUrls", "state.rejectedCandidateSongUrls"),
    ("_sunoPendingDownloadSongUrl", "state.pendingDownloadSongUrl"),
    ("_sunoPendingDownloadTitle", "state.pendingDownloadTitle"),
    ("_sunoExistingDownloadStartedAt", "state.existingDownloadStartedAt"),
    ("_sunoExistingDownloadMenuRetries", "state.existingDownloadMenuRetries"),
    ("_sunoExistingDownloadLibraryTried", "state.existingDownloadLibraryTried"),
    ("_sunoMenuDownloadClickedAt", "state.menuDownloadClickedAt"),
    ("_sunoCreateSubmitted", "state.createSubmitted"),
    ("_sunoExistingDownloadOnly", "state.existingDownloadOnly"),
    ("_sunoCompletedStandby", "state.completedStandby"),
    ("_sunoCompletedStandbyFilled", "state.completedStandbyFilled"),
    ("_sunoStyleMagicRequestedAt", "state.styleMagicRequestedAt"),
    ("_sunoCreateBaselineVersionCount", "state.createBaselineVersionCount"),
    ("_sunoSongUrl", "state.songUrl"),
    ("_sunoLastLoadStopUrl", "state.lastLoadStopUrl"),
    ("_sunoLastLoadStopAt", "state.lastLoadStopAt"),
    ("_sunoAutomationTimer", "_timer"),
    ("_evaluateSunoJson(controller,", "_bridge.evaluateJson(webController,"),
    ("_sunoInspectScript", "SunoWebScripts.inspectScript"),
    ("_sunoFillScript(", "SunoWebScripts.fillScript("),
    ("_sunoCompletionScript(", "SunoWebScripts.completionScript("),
    ("_sunoDownloadScript(", "SunoWebScripts.downloadScript("),
    ("_canonicalSunoSongUrl", "SunoUtilities.canonicalSongUrl"),
    ("_sunoPageKind", "SunoUtilities.pageKind"),
    ("_isSunoLoginFlowUrl", "SunoUtilities.isLoginFlowUrl"),
    ("_isSunoProfileUrl", "SunoUtilities.isProfileUrl"),
    ("_isSyntheticSunoSongKey", "SunoUtilities.isSyntheticSongKey"),
    ("_mergeSunoSongUrls", "SunoUtilities.mergeSongUrls"),
    ("_trustedSunoSongUrls()", "state.trustedSongUrlsList()"),
    ("_trustSunoSongUrls", "_trustSongUrls"),
    ("_rememberDownloadedSunoUrls()", "state.rememberDownloadedSongUrls()"),
    ("_syncDownloadedSunoUrlsIntoDetected()", "state.syncDownloadedIntoDetected()"),
    ("_hasSunoVersionForSongUrl", "state.hasLocalVersionForSongUrl"),
    ("_currentSunoDownloadsComplete()", "state.currentDownloadsComplete()"),
    ("_hasNewSunoVersionsSinceCreate()", "state.hasNewVersionsSinceCreate"),
    ("_isSunoPageSettled(currentUrl)", "_isPageSettled(currentUrl)"),
    ("_isAwaitingSunoMenuDownload()", "state.isAwaitingMenuDownload()"),
    ("_pendingSunoDownloadTarget", "_pendingDownloadTarget"),
    ("_downloadSunoDirectMediaUrls", "_downloadDirectMediaUrls"),
    ("_sunoNavigateToLibraryForMoreCandidates", "_navigateToLibraryForMoreCandidates"),
    ("_sunoUseLibraryBroadRecall", "_useLibraryBroadRecall"),
    ("_sunoLibraryCandidateSongUrls", "_libraryCandidateSongUrls"),
    ("_sunoDownloadProbeLogData", "_downloadProbeLogData"),
    ("_isTransientSunoWebViewError", "_isTransientWebViewError"),
    ("_failSunoAutomation", "failAutomation"),
    ("_displayError", "_host.displayError"),
    ("_setSunoStatus", "setStatus"),
    ("_saveSunoMetadata", "saveMetadata"),
    ("mounted", "_host.isMounted"),
    ("setState(() {})", "_host.requestSetState()"),
    ("if (mounted) {\n        setState(() {});\n      }", "_host.requestSetState()"),
]
for old, new in subs:
    body = body.replace(old, new)

out = root / "app/lib/features/web_shell/suno/_tick_body.dart.txt"
out.write_text(body, encoding="utf-8")
print(f"Wrote {out} ({len(body)} chars)")
