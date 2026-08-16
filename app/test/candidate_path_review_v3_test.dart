import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/practice_text_service.dart';
import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v3.dart';
import 'package:tomato_english_happy_talking/services/sentence_split_tuning_budget_v3.dart';
import 'package:tomato_english_happy_talking/services/text_generation_service.dart';

void main() {
  late Directory tempDir;
  late Directory previousDirectory;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    previousDirectory = Directory.current;
    tempDir = await Directory.systemTemp.createTemp('candidate_path_v3_');
    Directory.current = tempDir;
    await databaseFactory.setDatabasesPath(tempDir.path);
    DatabaseService.setDatabaseDirectoryOverrideForTest(tempDir.path);
    await DatabaseService.resetForTest();
    AppConfig.resetRuntimeConfigForTest();
    AppConfig.setRuntimeConfigForTest(
      aiProvider: AppConfig.aiProviderVolcengine,
      volcArkApiKey: 'candidate-path-test-key-1234567890',
      volcArkTextModel: 'doubao-seed-2-0-lite-260215',
    );
    PracticeTextService.setValidatedCandidateReviewModelsForTest({
      '${AppConfig.aiProviderVolcengine}/doubao-seed-2-0-lite-260215',
    });
    TextGenerationService.setPostOverrideForTest(null);
  });

  tearDown(() async {
    PracticeTextService.setValidatedCandidateReviewModelsForTest(null);
    TextGenerationService.setPostOverrideForTest(null);
    AppConfig.resetRuntimeConfigForTest();
    await DatabaseService.resetForTest();
    DatabaseService.setDatabaseDirectoryOverrideForTest(null);
    Directory.current = previousDirectory;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('AI can return only a supplied candidatePathId', () async {
    final plan = _riskPlan();
    final selected = plan.originals.single.initialCandidatePaths.last;
    Map<String, dynamic>? seenBody;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        seenBody = body;
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'items': [
                    {
                      'originalIndex': 0,
                      'candidatePathId': selected.pathId,
                    },
                  ],
                }),
              },
            },
          ],
          'usage': {
            'prompt_tokens': 120,
            'completion_tokens': 18,
            'total_tokens': 138,
          },
        };
      },
    );

    final review = await PracticeTextService.reviewCandidatePathsV3(
      plan: plan,
    );

    expect(review.selectedPathIds[0], selected.pathId);
    expect(review.usedLocalFallback, isFalse);
    expect(review.remoteAttempts, 1);
    expect(review.usage.totalTokens, 138);
    expect(seenBody?['temperature'], 0);
    expect(seenBody?['thinking'], {'type': 'disabled'});
    expect(seenBody, isNot(contains('enable_thinking')));
    final messages = seenBody?['messages'] as List;
    final prompt = messages.map((value) => (value as Map)['content']).join();
    expect(prompt, contains('candidatePathId'));
    expect(prompt, isNot(contains('endToken')));
    final payload = jsonDecode((messages.last as Map)['content'] as String)
        as Map<String, dynamic>;
    final original = (payload['originals'] as List).single as Map;
    expect(original['minimumBoundaryCount'], 0);
    final candidate = (original['candidatePaths'] as List).first as Map;
    expect(candidate, contains('isMinimumBoundaryCount'));
    expect(candidate, contains('shortFragmentCount'));
    expect(candidate, contains('totalBoundaryRisk'));
  });

  test('an invented path is rejected once and then retried', () async {
    final plan = _riskPlan();
    var calls = 0;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        calls += 1;
        final id =
            calls == 1 ? 'invented-path' : plan.originals.single.localPathId;
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'items': [
                    {'originalIndex': 0, 'candidatePathId': id},
                  ],
                }),
              },
            },
          ],
        };
      },
    );

    final review = await PracticeTextService.reviewCandidatePathsV3(
      plan: plan,
    );

    expect(calls, 2);
    expect(review.usedLocalFallback, isFalse);
    expect(review.remoteAttempts, 2);
    expect(review.selectedPathIds[0], plan.originals.single.localPathId);
  });

  test('REJECT expands candidates once and accepts only an expanded path',
      () async {
    final plan = _riskPlan();
    final expanded = plan.originals.single.expandedCandidatePaths.last;
    var calls = 0;
    final candidateCounts = <int>[];
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        calls += 1;
        final messages = body['messages'] as List;
        final user = jsonDecode((messages.last as Map)['content'] as String)
            as Map<String, dynamic>;
        final originals = user['originals'] as List;
        candidateCounts.add(
          ((originals.single as Map)['candidatePaths'] as List).length,
        );
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'items': [
                    {
                      'originalIndex': 0,
                      'candidatePathId':
                          calls == 1 ? 'REJECT' : expanded.pathId,
                    },
                  ],
                }),
              },
            },
          ],
        };
      },
    );

    final review = await PracticeTextService.reviewCandidatePathsV3(plan: plan);

    expect(calls, 2);
    expect(candidateCounts.first, lessThanOrEqualTo(8));
    expect(candidateCounts.last, lessThanOrEqualTo(24));
    expect(candidateCounts.last, greaterThan(candidateCounts.first));
    expect(review.selectedPathIds[0], expanded.pathId);
    expect(review.selectionTrace.map((entry) => entry['decision']),
        containsAllInOrder(['rejected', 'selected']));
  });

  test('a successful expanded decision cache skips the initial remote call',
      () async {
    final plan = _riskPlan();
    final expanded = plan.originals.single.expandedCandidatePaths.last;
    var calls = 0;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        calls += 1;
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'items': [
                    {
                      'originalIndex': 0,
                      'candidatePathId':
                          calls == 1 ? 'REJECT' : expanded.pathId,
                    },
                  ],
                }),
              },
            },
          ],
        };
      },
    );

    final first = await PracticeTextService.reviewCandidatePathsV3(plan: plan);
    expect(first.selectedPathIds[0], expanded.pathId);
    expect(calls, 2);

    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        fail('expanded cache should be checked before the initial request');
      },
    );
    final second = await PracticeTextService.reviewCandidatePathsV3(plan: plan);
    expect(second.source, TextGenerationReplySource.cached);
    expect(second.remoteAttempts, 0);
    expect(second.selectedPathIds[0], expanded.pathId);
  });

  test('two illegal replies use the deterministic local path', () async {
    final plan = _riskPlan();
    var calls = 0;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        calls += 1;
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'items': [
                    {
                      'originalIndex': 0,
                      'candidatePathId': 'invented-path',
                    },
                  ],
                }),
              },
            },
          ],
        };
      },
    );

    final review = await PracticeTextService.reviewCandidatePathsV3(
      plan: plan,
    );

    expect(calls, 2);
    expect(review.usedLocalFallback, isTrue);
    expect(review.fallbackReason, 'remote_failed_twice');
    expect(review.selectedPathIds[0], plan.originals.single.localPathId);
  });

  test('an unvalidated provider/model never calls the paid endpoint', () async {
    final plan = _riskPlan();
    PracticeTextService.setValidatedCandidateReviewModelsForTest(const {});
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        fail('unvalidated candidate reviewer must not call HTTP');
      },
    );

    final review = await PracticeTextService.reviewCandidatePathsV3(
      plan: plan,
    );

    expect(review.usedLocalFallback, isTrue);
    expect(review.fallbackReason, 'unvalidated_provider_model');
    expect(review.remoteAttempts, 0);
  });

  test('the production-validated Aliyun model may review candidate paths',
      () async {
    PracticeTextService.setValidatedCandidateReviewModelsForTest(null);
    AppConfig.setRuntimeConfigForTest(
      aiProvider: AppConfig.aiProviderAliyunBailian,
      aliyunBailianApiKey: 'candidate-path-test-key-1234567890',
      aliyunBailianTextModel: AppConfig.defaultAliyunBailianTextModel,
    );
    final selected = _riskPlan().originals.single.initialCandidatePaths.last;
    var remoteCalls = 0;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        remoteCalls += 1;
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'items': [
                    {
                      'originalIndex': 0,
                      'candidatePathId': selected.pathId,
                    },
                  ],
                }),
              },
            },
          ],
        };
      },
    );

    final review = await PracticeTextService.reviewCandidatePathsV3(
      plan: _riskPlan(),
    );

    expect(remoteCalls, 1);
    expect(review.selectedPathIds[0], selected.pathId);
    expect(review.usedLocalFallback, isFalse);
  });

  test('the validated DeepSeek model starts with compact expanded candidates',
      () async {
    PracticeTextService.setValidatedCandidateReviewModelsForTest(null);
    AppConfig.setRuntimeConfigForTest(
      aiProvider: AppConfig.aiProviderVolcengine,
      volcArkApiKey: 'candidate-path-test-key-1234567890',
      volcArkTextModel: 'deepseek-v4-flash-ga-260731',
    );
    final plan = _riskPlan();
    final selected = plan.originals.single.expandedCandidatePaths.last;
    Map<String, dynamic>? payload;
    var remoteCalls = 0;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        remoteCalls += 1;
        final messages = body['messages'] as List;
        payload = jsonDecode((messages.last as Map)['content'] as String)
            as Map<String, dynamic>;
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'items': [
                    {
                      'originalIndex': 0,
                      'candidatePathId': selected.pathId,
                    },
                  ],
                }),
              },
            },
          ],
        };
      },
    );

    final review = await PracticeTextService.reviewCandidatePathsV3(
      plan: plan,
    );

    expect(remoteCalls, 1);
    expect(review.selectedPathIds[0], selected.pathId);
    expect(review.usedLocalFallback, isFalse);
    final original = (payload!['originals'] as List).single as Map;
    expect(original['candidateRound'], 'expanded');
    expect(
      original['candidatePaths'],
      hasLength(plan.originals.single.expandedCandidatePaths.length),
    );
    final candidate = (original['candidatePaths'] as List).first as Map;
    expect(candidate, isNot(contains('stage')));
    expect(candidate, isNot(contains('totalBoundaryRisk')));
    expect(candidate, isNot(contains('boundaries')));
  });

  test('budgeted tuning can apply the complete P8 protocol to another model',
      () async {
    PracticeTextService.setValidatedCandidateReviewModelsForTest(const {});
    final plan = _riskPlan();
    final selected = plan.originals.single.expandedCandidatePaths.last;
    Map<String, dynamic>? payload;
    String? prompt;
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        final messages = body['messages'] as List;
        prompt = (messages.first as Map)['content'] as String;
        payload = jsonDecode((messages.last as Map)['content'] as String)
            as Map<String, dynamic>;
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'items': [
                    {
                      'originalIndex': 0,
                      'candidatePathId': selected.pathId,
                    },
                  ],
                }),
              },
            },
          ],
        };
      },
    );

    final review = await PracticeTextService.reviewCandidatePathsV3(
      plan: plan,
      allowUnvalidatedModelForTuning: true,
      forceRemoteForTuning: true,
      forceP8ProtocolForTuning: true,
      tuningBudget: SentenceSplitTuningBudgetV3(limitCny: 1),
    );

    expect(review.selectedPathIds[0], selected.pathId);
    expect(
      prompt,
      contains('boundary at that clause transition dominates'),
    );
    final original = (payload!['originals'] as List).single as Map;
    expect(original['candidateRound'], 'expanded');
    final candidate = (original['candidatePaths'] as List).first as Map;
    expect(candidate, isNot(contains('stage')));
    expect(candidate, isNot(contains('totalBoundaryRisk')));
    expect(candidate, isNot(contains('boundaries')));
  });

  test('reviews multiple risky originals in one article-level request',
      () async {
    final plan = _twoRiskPlan();
    var calls = 0;
    final requestedIndexes = <int>[];
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        calls += 1;
        final messages = body['messages'] as List;
        final user = jsonDecode((messages.last as Map)['content'] as String)
            as Map<String, dynamic>;
        final originals = user['originals'] as List;
        expect(originals, hasLength(2));
        final items = <Map<String, dynamic>>[];
        for (final raw in originals) {
          final original = raw as Map;
          final originalIndex = original['originalIndex'] as int;
          requestedIndexes.add(originalIndex);
          final decision = plan.originals.firstWhere(
            (value) => value.originalIndex == originalIndex,
          );
          items.add({
            'originalIndex': originalIndex,
            'candidatePathId': decision.initialCandidatePaths.last.pathId,
          });
        }
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'items': items,
                }),
              },
            },
          ],
        };
      },
    );

    final review = await PracticeTextService.reviewCandidatePathsV3(
      plan: plan,
    );

    expect(calls, 1);
    expect(requestedIndexes, [0, 1]);
    for (final decision in plan.originals) {
      expect(
        review.selectedPathIds[decision.originalIndex],
        decision.initialCandidatePaths.last.pathId,
      );
    }
  });

  test('one mixed REJECT expands the whole article exactly once', () async {
    final plan = _twoRiskPlan();
    var calls = 0;
    final rounds = <String>[];
    TextGenerationService.setPostOverrideForTest(
      ({required endpoint, required headers, required body}) async {
        calls += 1;
        final messages = body['messages'] as List;
        final payload = jsonDecode((messages.last as Map)['content'] as String)
            as Map<String, dynamic>;
        final originals = payload['originals'] as List;
        rounds.add((originals.first as Map)['candidateRound'] as String);
        return {
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'items': [
                    for (final raw in originals)
                      () {
                        final original = raw as Map;
                        final originalIndex = original['originalIndex'] as int;
                        final paths = original['candidatePaths'] as List;
                        return {
                          'originalIndex': originalIndex,
                          'candidatePathId': calls == 1 && originalIndex == 1
                              ? 'REJECT'
                              : (paths.last as Map)['candidatePathId'],
                        };
                      }(),
                  ],
                }),
              },
            },
          ],
        };
      },
    );

    final review = await PracticeTextService.reviewCandidatePathsV3(
      plan: plan,
    );

    expect(calls, 2);
    expect(rounds, ['initial', 'expanded']);
    expect(review.remoteAttempts, 2);
    expect(review.usedLocalFallback, isFalse);
    expect(review.selectedPathIds, hasLength(2));
  });
}

ReadAloudSplitPlanV3 _riskPlan() {
  final source = List.generate(21, (index) => 'word${index + 1}').join(' ');
  final matches = RegExp(r'\S+').allMatches(source).toList(growable: false);
  return ReadAloudSplitterV3.plan(
    source: source,
    document: DependencyDocumentV3(
      parserVersion: 'fake-udpipe-1.4.0',
      modelSha256: 'fake-model-sha256',
      healthy: true,
      sentences: [
        DependencySentenceV3(
          start: 0,
          end: source.length,
          tokens: [
            for (var index = 0; index < matches.length; index += 1)
              DependencyTokenV3(
                id: index + 1,
                text: matches[index].group(0)!,
                start: matches[index].start,
                end: matches[index].end,
                upos: index == 10 ? 'SCONJ' : 'NOUN',
                head: index == 10 ? 10 : 0,
                deprel: index == 10 ? 'advcl' : 'root',
              ),
          ],
        ),
      ],
    ),
  );
}

ReadAloudSplitPlanV3 _twoRiskPlan() {
  final first = List.generate(21, (index) => 'alpha${index + 1}').join(' ');
  final second = List.generate(21, (index) => 'beta${index + 1}').join(' ');
  final source = '$first\n\n$second';
  final sentenceTexts = [first, second];
  var searchStart = 0;
  final sentences = <DependencySentenceV3>[];
  for (var sentenceIndex = 0;
      sentenceIndex < sentenceTexts.length;
      sentenceIndex += 1) {
    final sentenceText = sentenceTexts[sentenceIndex];
    final sentenceStart = source.indexOf(sentenceText, searchStart);
    final matches = RegExp(r'\S+').allMatches(sentenceText).toList();
    sentences.add(
      DependencySentenceV3(
        start: sentenceStart,
        end: sentenceStart + sentenceText.length,
        tokens: [
          for (var index = 0; index < matches.length; index += 1)
            DependencyTokenV3(
              id: index + 1,
              text: matches[index].group(0)!,
              start: sentenceStart + matches[index].start,
              end: sentenceStart + matches[index].end,
              upos: index == 10 ? 'SCONJ' : 'NOUN',
              head: index == 10 ? 10 : 0,
              deprel: index == 10 ? 'advcl' : 'root',
            ),
        ],
      ),
    );
    searchStart = sentenceStart + sentenceText.length;
  }
  return ReadAloudSplitterV3.plan(
    source: source,
    document: DependencyDocumentV3(
      parserVersion: 'fake-udpipe-1.4.0',
      modelSha256: 'fake-model-sha256',
      healthy: true,
      sentences: sentences,
    ),
  );
}
