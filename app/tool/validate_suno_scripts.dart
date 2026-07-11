// Validates Suno WebView injected JavaScript with `node --check`.
// Usage: dart run tool/validate_suno_scripts.dart
import 'dart:io';

import 'package:tomato_english_happy_talking/features/web_shell/suno/suno_web_scripts.dart';

Future<void> main() async {
  final scripts = <String, String>{
    'inspect': SunoWebScripts.inspectScript,
    'createLyricsPasteTick': SunoWebScripts.createLyricsPasteTickScript,
    'focusLexicalLyricsEditor':
        SunoWebScripts.focusLexicalLyricsEditorScript(),
    'pasteLexicalLyricsFromClipboard':
        SunoWebScripts.pasteLexicalLyricsFromClipboardScript(),
  };

  var failed = 0;
  for (final entry in scripts.entries) {
    final file = File(
      '${Directory.systemTemp.path}/suno-${entry.key}-${DateTime.now().microsecondsSinceEpoch}.js',
    );
    file.writeAsStringSync(entry.value);
    final result = await Process.run('node', ['--check', file.path]);
    try {
      file.deleteSync();
    } catch (_) {}
    if (result.exitCode == 0) {
      stdout.writeln('OK  ${entry.key}');
    } else {
      failed += 1;
      stderr.writeln('FAIL ${entry.key}');
      stderr.writeln(result.stderr);
    }
  }
  if (failed > 0) {
    stderr.writeln('$failed script(s) failed node --check');
    exitCode = 1;
  }
}
