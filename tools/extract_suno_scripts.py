#!/usr/bin/env python3
"""One-off extractor: web_shell_screen.dart Suno JS -> suno_web_scripts.dart"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
screen = root / "app/lib/features/web_shell/web_shell_screen.dart"
out = root / "app/lib/features/web_shell/suno/suno_web_scripts.dart"
lines = screen.read_text(encoding="utf-8").splitlines()
body = "\n".join(lines[5779:8263])
replacements = [
    ("String get _sunoInspectScript", "static String get inspectScript"),
    ("String get _sunoDomDiagnosticsScript", "static String get domDiagnosticsScript"),
    ("String get _sunoSnapshotScript", "static String get snapshotScript"),
    ("String _sunoRowsDebugScript", "static String rowsDebugScript"),
    ("String _sunoFillScript", "static String fillScript"),
    ("String get _sunoCreateScript", "static String get createScript"),
    ("String _sunoCompletionScript", "static String completionScript"),
    ("String _sunoDownloadScript", "static String downloadScript"),
    ("_mergeSunoSongUrls", "SunoUtilities.mergeSongUrls"),
]
for old, new in replacements:
    body = body.replace(old, new)
header = """import 'dart:convert';

import 'suno_utilities.dart';

/// Injected Suno WebView JavaScript builders.
class SunoWebScripts {
  SunoWebScripts._();

"""
out.write_text(header + body + "\n}\n", encoding="utf-8")
print(f"Wrote {out} ({len(body)} chars)")
