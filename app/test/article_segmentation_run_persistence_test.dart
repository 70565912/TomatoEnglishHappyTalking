import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/data/models/article_model.dart';
import 'package:tomato_english_happy_talking/data/models/article_segmentation_run_model.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';

void main() {
  late Directory tempDir;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tomato_split_run_');
    await databaseFactory.setDatabasesPath(tempDir.path);
    DatabaseService.setDatabaseDirectoryOverrideForTest(tempDir.path);
    DatabaseService.setRuntimeDataRootOverrideForTest(tempDir.path);
    await DatabaseService.resetForTest();
  });

  tearDown(() async {
    await DatabaseService.resetForTest();
    DatabaseService.setDatabaseDirectoryOverrideForTest(null);
    DatabaseService.setRuntimeDataRootOverrideForTest(null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('stores the article and reproducible V3.6 run in one transaction',
      () async {
    final now = DateTime.utc(2026, 8, 8, 19, 30);
    final article = Article(
      title: 'Syntax audit',
      content: 'Mole looked up.',
      sentences: const ['Mole looked up.'],
      sentenceSplitVersion: 'reviewed_dp_v3',
      createdAt: now,
    );
    final run = ArticleSegmentationRunRecord(
      sourceHash: 'source-sha256',
      sentenceSplitVersion: 'reviewed_dp_v3',
      solverVersion: 'syntax_solver_v3_6',
      parserVersion: 'udpipe-1.4.0',
      modelSha256: 'model-sha256',
      parserHealthy: true,
      parserIssues: const [],
      candidatePaths: const [
        {
          'originalIndex': 0,
          'candidatePaths': [
            {'pathId': 'v3_o0_keep'},
          ],
        },
      ],
      selectedPaths: const {0: 'v3_o0_keep'},
      selectionTrace: const [
        {
          'originalIndex': 0,
          'round': 'initial',
          'candidateSetHash': 'initial-hash',
          'response': 'v3_o0_keep',
          'source': 'cache',
        },
      ],
      aiSource: 'stored',
      aiRemoteAttempts: 0,
      usedLocalFallback: false,
      translationSource: 'imported_bilingual',
      createdAt: now,
    );

    final articleId = await DatabaseService.saveArticleWithSegmentationRun(
      article: article,
      segmentationRun: run,
    );

    final rows = await DatabaseService.getArticleSegmentationRuns(articleId);
    expect(rows, hasLength(1));
    expect(rows.single['sentence_split_version'], 'reviewed_dp_v3');
    expect(rows.single['solver_version'], 'syntax_solver_v3_6');
    expect(rows.single['parser_version'], 'udpipe-1.4.0');
    expect(rows.single['model_sha256'], 'model-sha256');
    expect(rows.single['selected_paths_json'], '{"0":"v3_o0_keep"}');
    final candidateAudit = jsonDecode(
      rows.single['candidate_paths_json'] as String,
    ) as Map<String, dynamic>;
    expect(
      candidateAudit['schemaVersion'],
      'article_segmentation_candidate_audit_v3_6',
    );
    expect(candidateAudit['originals'], hasLength(1));
    expect(candidateAudit['selectionTrace'], hasLength(1));
    expect(
      ((candidateAudit['selectionTrace'] as List).single
          as Map<String, dynamic>)['candidateSetHash'],
      'initial-hash',
    );
    expect(rows.single['translation_source'], 'imported_bilingual');
  });
}
