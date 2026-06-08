import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path_lib;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/services/chat_chapter_guide_service.dart';
import 'package:tomato_english_happy_talking/services/content_safety_service.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = null;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    await DatabaseService.resetForTest();
    DatabaseService.setDatabaseDirectoryOverrideForTest(null);
  });

  test('generates and exports live chat guide for queen croquet chapter',
      () async {
    final workspaceRoot = Directory.current.parent.absolute.path;
    final releaseRoot = path_lib.join(
      workspaceRoot,
      'release',
      'windows',
      'tomato_english_happy_talking',
    );
    final releaseDbDir = path_lib.join(
      releaseRoot,
      '.dart_tool',
      'sqflite_common_ffi',
      'databases',
    );
    DatabaseService.setDatabaseDirectoryOverrideForTest(releaseDbDir);

    final arkKey = await AppConfig.volcArkTextApiKey;
    if (arkKey.trim().isEmpty) {
      fail('ark.txt / TOMATO_VOLC_ARK_API_KEY is empty; cannot run live probe');
    }

    final articles = await DatabaseService.getArticles();
    final article = articles.firstWhere(
      (item) => item.title == "The Queen's Croquet-Ground",
      orElse: () => throw StateError(
        'Article "The Queen\'s Croquet-Ground" was not found in release DB',
      ),
    );

    final reply = await ChatChapterGuideService.prepareGuide(
      articleTitle: article.title,
      articleContent: article.content,
      sentences: article.sentences,
      articleId: article.id,
    );
    final safetyReportPath = await ContentSafetyService.exportSafetyReport(
      outputDirectory: path_lib.join(releaseRoot, 'data', 'content_safety'),
    );
    final guide = reply.text.trim();
    final coveragePoints = _extractCoveragePoints(guide);
    final output = <String, dynamic>{
      'generatedAt': DateTime.now().toIso8601String(),
      'source': reply.source.name,
      'article': _articleSummary(article),
      'guidePurpose': ChatChapterGuideService.cachePurpose,
      'remoteCoveragePointCount': coveragePoints.length,
      'coveragePoints': coveragePoints,
      'guideText': guide,
      'releaseRoot': releaseRoot,
      'releaseDatabaseDirectory': releaseDbDir,
      'contentSafetyReportPath': safetyReportPath,
      'note':
          'This file is exported by live_chat_guide_probe_test.dart. The same guide is also stored in the release SQLite api_cache tables when source is remote.',
    };

    final outputDir = Directory(
      path_lib.join(releaseRoot, 'data', 'chat_guides'),
    );
    await outputDir.create(recursive: true);
    final latestPath = path_lib.join(
      outputDir.path,
      'the_queens_croquet_ground_guide_latest.json',
    );
    final stampedPath = path_lib.join(
      outputDir.path,
      'the_queens_croquet_ground_guide_${_timestampForFile()}.json',
    );
    const encoder = JsonEncoder.withIndent('  ');
    await File(latestPath).writeAsString(encoder.convert(output));
    await File(stampedPath).writeAsString(encoder.convert(output));

    debugPrint('Chat guide source=${reply.source.name}');
    debugPrint('Coverage point count=${coveragePoints.length}');
    debugPrint('Latest guide export=$latestPath');
    debugPrint('Stamped guide export=$stampedPath');
    debugPrint('Content safety report=$safetyReportPath');
    debugPrint(
      'Guide preview=${guide.substring(0, guide.length < 500 ? guide.length : 500)}',
    );

    expect(guide, isNotEmpty);
    expect(coveragePoints, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 90)));
}

Map<String, dynamic> _articleSummary(Article article) => {
      'id': article.id,
      'title': article.title,
      'contentLength': article.content.length,
      'sentenceCount': article.sentences.length,
    };

List<String> _extractCoveragePoints(String guide) {
  final lines = guide
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  final numbered = lines
      .where((line) => RegExp(r'^\d+\s*[\.)、:-]\s+').hasMatch(line))
      .toList(growable: false);
  if (numbered.isNotEmpty) {
    return numbered;
  }

  final lowerLines = lines.map((line) => line.toLowerCase()).toList();
  final start = lowerLines.indexWhere(
    (line) => line.contains('ordered coverage'),
  );
  if (start < 0) {
    return const [];
  }

  final points = <String>[];
  for (var index = start + 1; index < lines.length; index += 1) {
    final lower = lowerLines[index];
    if (lower.contains('character and setting') ||
        lower.contains('completion rubric') ||
        lower.contains('ability assessment')) {
      break;
    }
    final line = lines[index];
    if (line.startsWith('-') || line.startsWith('*')) {
      points.add(line);
    }
  }
  return points;
}

String _timestampForFile() {
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${now.year}${two(now.month)}${two(now.day)}-'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}';
}
