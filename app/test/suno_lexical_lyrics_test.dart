import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/features/web_shell/suno/suno_web_scripts.dart';

Future<void> expectValidJavaScript(String label, String source) async {
  final file = File(
    '${Directory.systemTemp.path}/suno-test-$label-${DateTime.now().microsecondsSinceEpoch}.js',
  );
  file.writeAsStringSync(source);
  final result = await Process.run('node', ['--check', file.path]);
  try {
    file.deleteSync();
  } catch (_) {}
  expect(
    result.exitCode,
    0,
    reason:
        '$label: node --check failed\n${result.stderr}\n${result.stdout}',
  );
}

void main() {
  final repoRoot = Directory.current.parent;
  final fixtureDir = Directory('${repoRoot.path}/docs/fixtures/suno');
  final analysisFile = File(
    '${fixtureDir.path}/lexical-v55-manual-fill-analysis.json',
  );
  final outerHtmlFile = File(
    '${fixtureDir.path}/lexical-v55-lyrics-editor-outerhtml-sample.txt',
  );

  group('Suno Lexical lyrics scripts', () {
    test('writeLexicalLyricsScript avoids chunked appendChild path', () {
      final script = SunoWebScripts.writeLexicalLyricsScript(
        lyrics: 'Hello world',
      );
      expect(script.contains('chunkSize'), isFalse);
      expect(script.contains('syntheticPaste'), isTrue);
      expect(script.contains('insertFromPaste'), isTrue);
      expect(script.contains('appendChild'), isFalse);
      expect(script.contains('insertText'), isTrue);
      expect(script.contains('writeLexicalLyricsOnce'), isTrue);
      expect(script.contains('.lyrics-editor-content'), isTrue);
    });

    test('focusLexicalLyricsEditorScript targets first paragraph click point', () {
      final script = SunoWebScripts.focusLexicalLyricsEditorScript();
      expect(script.contains('findLexicalLyricsEditor'), isTrue);
      expect(script.contains('clickX'), isTrue);
      expect(script.contains('clickY'), isTrue);
      expect(script.contains('lyrics-paragraph'), isTrue);
      expect(script.contains('isEmptyEditor'), isTrue);
      expect(script.contains('getBoundingClientRect'), isTrue);
    });

    test('fillScript embeds lexical helpers and skipStyles / lyricsWriteAttempted', () {
      final script = SunoWebScripts.fillScript(
        lyrics: 'Line one',
        stylePrompt: '',
        ignoredStylePrompt: '',
        allowMagicClick: true,
        magicAlreadyRequested: false,
        lyricsWriteAttempted: true,
        skipStyles: true,
      );
      expect(script.contains('readLexicalLyricsValue'), isTrue);
      expect(script.contains('readSunoLyricsCounter'), isTrue);
      expect(script.contains('findLexicalLyricsEditor'), isTrue);
      expect(script.contains('lyricsWriteAttempted'), isTrue);
      expect(script.contains('skipStyles'), isTrue);
      expect(script.contains('chunkSize'), isFalse);
    });

    test('quickLyricsFillScript delegates to writeLexicalLyricsScript', () {
      final quick = SunoWebScripts.quickLyricsFillScript(lyrics: 'abc');
      final direct = SunoWebScripts.writeLexicalLyricsScript(lyrics: 'abc');
      expect(quick, direct);
    });

    test('readLexicalLyricsProbeScript checks counter and lexical length', () {
      final script = SunoWebScripts.readLexicalLyricsProbeScript(
        expectedLyrics: 'Then the Queen left off',
      );
      expect(script.contains('lyricsOk'), isTrue);
      expect(script.contains('counterCount'), isTrue);
      expect(script.contains('lexicalLength'), isTrue);
      expect(script.contains('textExactMatch'), isTrue);
      expect(script.contains('counterExact'), isTrue);
      expect(script.contains('normalizeLyricsExact'), isTrue);
      expect(script.contains('0.85'), isFalse);
    });

    test('pasteLexicalLyricsFromClipboardScript is diagnostic execCommand only', () {
      final script = SunoWebScripts.pasteLexicalLyricsFromClipboardScript();
      expect(script.contains("execCommand('paste')"), isTrue);
      expect(script.contains('syntheticClipboardPaste'), isFalse);
      expect(script.contains('fallbackLyrics'), isFalse);
      expect(script.contains('insertText'), isFalse);
    });

    test('inspectScript avoids body innerText on create with lexical editor', () {
      final script = SunoWebScripts.inspectScript;
      expect(script.contains('chromeText'), isTrue);
      expect(script.contains('onSunoCreate && hasLexicalEditor'), isTrue);
    });

    test('lexical helper readSunoLyricsCounter avoids double-escaped regex trap', () {
      final script = SunoWebScripts.createLyricsPasteTickScript;
      expect(script.contains('lyrics-editor-char-count'), isTrue);
      expect(script.contains('parentElement'), isFalse);
      expect(script.contains('.concat([String(document.body'), isFalse);
      expect(script.contains(r'joined.match(/(\d+)\s*\/\s*5000/'), isTrue);
      expect(script.contains(r'joined.match(/(\\d+)'), isFalse);
    });

    test('createLyricsPasteTickScript is lightweight and checks editor readiness', () {
      final script = SunoWebScripts.createLyricsPasteTickScript;
      expect(script.contains('findLexicalLyricsEditor'), isTrue);
      expect(script.contains('lyricsEditorReady'), isTrue);
      expect(script.contains('clickAdvanced'), isTrue);
      expect(script.contains('createLyricsPasteTickScript'), isFalse);
      expect(script.length < 15000, isTrue);
    });
  });

  group('Suno injected JavaScript syntax', () {
    test('production Suno scripts pass node --check', () async {
      final scripts = <String, String>{
        'inspect': SunoWebScripts.inspectScript,
        'createLyricsPasteTick': SunoWebScripts.createLyricsPasteTickScript,
        'focusLexicalLyricsEditor':
            SunoWebScripts.focusLexicalLyricsEditorScript(),
        'pasteLexicalLyricsFromClipboard':
            SunoWebScripts.pasteLexicalLyricsFromClipboardScript(),
      };
      for (final entry in scripts.entries) {
        await expectValidJavaScript(entry.key, entry.value);
      }
    });
  });

  group('Suno Lexical fixture replay', () {
    test('manual fill analysis matches lexical node counts', () {
      expect(analysisFile.existsSync(), isTrue, reason: analysisFile.path);
      final map =
          jsonDecode(analysisFile.readAsStringSync()) as Map<String, dynamic>;
      final editor = map['lyricsEditor'] as Map<String, dynamic>;
      expect(editor['innerTextLength'], 3829);
      expect(editor['paragraphCount'], 55);
      expect(editor['lexicalTextNodeCount'], 55);
      expect(editor['characterCounter'], '3829 of 5000');
    });

    test('readLexicalLyricsValueFromHtml on captured outerHTML sample', () {
      expect(outerHtmlFile.existsSync(), isTrue, reason: outerHtmlFile.path);
      final html = extractFixtureHtml(outerHtmlFile.readAsStringSync());
      final read = readLexicalLyricsValueFromHtml(html);
      final nodes = RegExp(r'data-lexical-text="true"').allMatches(html).length;
      // Fixture outerHTML is truncated at 6000 chars by Playwright capture.
      expect(nodes, greaterThanOrEqualTo(30));
      expect(read.length, greaterThan(2000));
      expect(
        read.startsWith('Then the Queen left off, quite out of breath'),
        isTrue,
      );
    });

    test('readSunoLyricsCounterFromText parses v5.5 formats', () {
      expect(
        readSunoLyricsCounterFromText('3829 of 5000 characters used.'),
        3829,
      );
      expect(readSunoLyricsCounterFromText('panel 3829/5000 footer'), 3829);
      expect(readSunoLyricsCounterFromText('no counter here'), isNull);
    });
  });
}

/// Extract Playwright-captured HTML from fixture text files.
String extractFixtureHtml(String raw) {
  var body = raw;
  if (body.contains('### Result')) {
    body = body.split('### Result').last.split('### Ran Playwright').first.trim();
  }
  if (body.startsWith('"') && body.endsWith('"')) {
    body = body.substring(1, body.length - 1);
  }
  return body.replaceAll(r'\"', '"');
}

/// Mirrors [SunoWebScripts] JS `readLexicalLyricsValue` for fixture replay.
String readLexicalLyricsValueFromHtml(String html) {
  final pattern = RegExp(
    r'data-lexical-text="true"[^>]*>([^<]*)</span>',
    multiLine: true,
  );
  final parts = pattern
      .allMatches(html)
      .map((match) => match.group(1) ?? '')
      .where((part) => part.isNotEmpty)
      .toList();
  return parts.join('\n');
}

/// Mirrors [SunoWebScripts] JS `readSunoLyricsCounter` for fixture replay.
int? readSunoLyricsCounterFromText(String text) {
  final ofMatch = RegExp(r'(\d+)\s*of\s*5000', caseSensitive: false)
      .firstMatch(text);
  if (ofMatch != null) {
    return int.parse(ofMatch.group(1)!);
  }
  final slashMatch = RegExp(r'(\d+)\s*/\s*5000').firstMatch(text);
  if (slashMatch != null) {
    return int.parse(slashMatch.group(1)!);
  }
  return null;
}
