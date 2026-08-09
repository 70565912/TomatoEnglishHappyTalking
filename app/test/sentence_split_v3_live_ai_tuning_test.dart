import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tomato_english_happy_talking/core/config/app_config.dart';
import 'package:tomato_english_happy_talking/services/database_service.dart';
import 'package:tomato_english_happy_talking/services/practice_text_service.dart';
import 'package:tomato_english_happy_talking/services/read_aloud_splitter_v3.dart';
import 'package:tomato_english_happy_talking/services/sentence_split_tuning_budget_v3.dart';
import 'package:tomato_english_happy_talking/services/udpipe_syntax_parser_v3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled =
      Platform.environment['TOMATO_RUN_SENTENCE_V3_AI_TUNING'] == '1';
  test(
    'compares constrained path selection across configured text providers',
    () async {
      HttpOverrides.global = null;
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final repository = Directory.current.parent;
      final probe = File(
        Platform.environment['TOMATO_UDPIPE_PROBE'] ??
            '${repository.path}/build/udpipe-v3-trainer/udpipe_v3_probe.exe',
      );
      final model = File(
        Platform.environment['TOMATO_UDPIPE_MODEL'] ??
            '${repository.path}/app/assets/models/'
                'english-ewt-r2.18-udpipe-v1.4.0.model',
      );
      final output = File(
        Platform.environment['TOMATO_SENTENCE_V3_AI_TUNING_OUTPUT'] ??
            '${repository.path}/output/sentence-split-v3/'
                'live-ai-path-tuning.json',
      );
      final repeats = int.tryParse(
            Platform.environment['TOMATO_SENTENCE_V3_AI_TUNING_REPEATS'] ?? '',
          ) ??
          3;
      final budgetLimitCny = double.tryParse(
            Platform.environment['TOMATO_SENTENCE_V3_AI_TUNING_BUDGET_CNY'] ??
                '',
          ) ??
          50;
      final preflightOnly =
          Platform.environment['TOMATO_SENTENCE_V3_AI_TUNING_PREFLIGHT_ONLY'] ==
              '1';
      final expandedFirst =
          Platform.environment['TOMATO_SENTENCE_V3_AI_TUNING_EXPANDED_FIRST'] ==
              '1';
      final compactCandidates = Platform
              .environment['TOMATO_SENTENCE_V3_AI_TUNING_COMPACT_CANDIDATES'] ==
          '1';
      final forceP8Protocol =
          Platform.environment['TOMATO_SENTENCE_V3_AI_TUNING_P8_PROTOCOL'] ==
              '1';
      expect(repeats, greaterThanOrEqualTo(3));
      expect(probe.existsSync(), isTrue, reason: probe.path);
      expect(model.existsSync(), isTrue, reason: model.path);

      final savedConfig = preflightOnly
          ? const _SavedProviderConfigV3(
              aliyunApiKey: '',
              aliyunModel: '',
              volcApiKey: '',
              volcModel: '',
            )
          : await _readSavedProviderConfig(repository);
      final modelOverrides = {
        AppConfig.aiProviderAliyunBailian: Platform
            .environment['TOMATO_SENTENCE_V3_AI_TUNING_ALIYUN_MODEL']
            ?.trim(),
        AppConfig.aiProviderVolcengine: Platform
            .environment['TOMATO_SENTENCE_V3_AI_TUNING_VOLC_MODEL']
            ?.trim(),
      };
      final requestedProviders =
          (Platform.environment['TOMATO_SENTENCE_V3_AI_TUNING_PROVIDERS'] ??
                  '${AppConfig.aiProviderAliyunBailian},'
                      '${AppConfig.aiProviderVolcengine}')
              .split(',')
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toSet();
      expect(
        requestedProviders,
        isNotEmpty,
        reason: '至少选择一个文本供应商进行 V3 调优。',
      );
      expect(
        requestedProviders.difference({
          AppConfig.aiProviderAliyunBailian,
          AppConfig.aiProviderVolcengine,
        }),
        isEmpty,
        reason: 'V3 调优只支持已接入的阿里云或火山文本供应商。',
      );
      final configured = savedConfig.providers
          .where(
            (provider) =>
                requestedProviders.contains(provider.provider) &&
                provider.apiKey.isNotEmpty,
          )
          .toList(growable: false);
      if (!preflightOnly) {
        expect(
          configured.map((value) => value.provider).toSet(),
          requestedProviders,
          reason: '选中的 V3 调优文本供应商必须已配置；不会打印 Key。',
        );
      }

      final fixture = jsonDecode(
        File('test/fixtures/sentence_split_v3_ai_tuning_cases.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      final cases = (fixture['items'] as List)
          .map(_TuningCaseV3.fromJson)
          .toList(growable: false);
      final source = cases.map((value) => value.source).join('\n\n');
      final digest = await Sha256().hash(await model.readAsBytes());
      final modelSha = digest.bytes
          .map((value) => value.toRadixString(16).padLeft(2, '0'))
          .join();
      final temp = await Directory.systemTemp.createTemp('tomato-v3-ai-tune-');
      expect(budgetLimitCny, greaterThan(0));
      expect(budgetLimitCny, lessThanOrEqualTo(50));
      final budget = SentenceSplitTuningBudgetV3(limitCny: budgetLimitCny);
      final providerReports = <Map<String, dynamic>>[];
      try {
        await databaseFactory.setDatabasesPath(temp.path);
        DatabaseService.setDatabaseDirectoryOverrideForTest(temp.path);
        await DatabaseService.resetForTest();
        var nativeCalls = 0;
        final document = await UdpipeSyntaxParserV3.parseRawPipelineForTest(
          source: source,
          modelSha256: modelSha,
          provider: ({required text, required presegmented}) async {
            nativeCalls += 1;
            final input = File('${temp.path}/parse-$nativeCalls.txt');
            await input.writeAsString(text, encoding: utf8, flush: true);
            final result = await Process.run(
              probe.path,
              [model.path, input.path, if (presegmented) '--presegmented'],
              stdoutEncoding: utf8,
              stderrEncoding: utf8,
            );
            if (result.exitCode != 0) {
              throw StateError('UDPipe probe failed: ${result.stderr}');
            }
            return result.stdout.toString();
          },
        );
        final plan = ReadAloudSplitterV3.plan(
          source: source,
          document: document,
        );
        final caseDecisions = _mapCasesToDecisions(cases, plan);
        final preflight = _candidatePreflight(cases, caseDecisions);
        await _writeReport(
          output,
          fixture: fixture,
          modelSha: modelSha,
          parserVersion: document.parserVersion,
          parserHealthy: plan.parserHealthy,
          preflight: preflight,
          providerReports: providerReports,
          budget: budget,
          status:
              preflight.every((value) => value['approvedPathAvailable'] == true)
                  ? 'remote_tuning_pending'
                  : 'candidate_preflight_failed',
        );
        expect(
          preflight.every(
            (value) => value['approvedPathAvailable'] == true,
          ),
          isTrue,
          reason: 'AI 不能修复代码未提供正确路径的输入，付费调用前必须先通过候选预检。',
        );
        if (preflightOnly) {
          await _writeReport(
            output,
            fixture: fixture,
            modelSha: modelSha,
            parserVersion: document.parserVersion,
            parserHealthy: plan.parserHealthy,
            preflight: preflight,
            providerReports: providerReports,
            budget: budget,
            status: 'candidate_preflight_passed',
          );
          return;
        }

        for (final savedProvider in configured) {
          final override = modelOverrides[savedProvider.provider];
          final provider = _ProviderConfigV3(
            provider: savedProvider.provider,
            apiKey: savedProvider.apiKey,
            model: override == null || override.isEmpty
                ? savedProvider.model
                : override,
          );
          AppConfig.resetRuntimeConfigForTest();
          AppConfig.setRuntimeConfigForTest(
            aiProvider: provider.provider,
            textProvider: provider.provider,
            aliyunBailianApiKey: savedConfig.aliyunApiKey,
            aliyunBailianTextModel:
                provider.provider == AppConfig.aiProviderAliyunBailian
                    ? provider.model
                    : savedConfig.aliyunModel,
            volcArkApiKey: savedConfig.volcApiKey,
            volcArkTextModel:
                provider.provider == AppConfig.aiProviderVolcengine
                    ? provider.model
                    : savedConfig.volcModel,
          );
          final runs = <Map<String, dynamic>>[];
          final selectionSignatures = <String>[];
          for (var repeat = 1; repeat <= repeats; repeat += 1) {
            final stopwatch = Stopwatch()..start();
            final review = await PracticeTextService.reviewCandidatePathsV3(
              plan: plan,
              allowUnvalidatedModelForTuning: true,
              forceRemoteForTuning: true,
              forceExpandedCandidatesForTuning: expandedFirst,
              compactCandidatePayloadForTuning: compactCandidates,
              forceP8ProtocolForTuning: forceP8Protocol,
              tuningBudget: budget,
            );
            stopwatch.stop();
            final selected = _selectedCaseResults(
              cases: cases,
              caseDecisions: caseDecisions,
              selectedPathIds: review.selectedPathIds,
            );
            final signature =
                selected.map((value) => value['candidatePathId']).join('|');
            selectionSignatures.add(signature);
            runs.add({
              'repeat': repeat,
              'latencyMs': stopwatch.elapsedMilliseconds,
              'source': review.source.name,
              'remoteAttempts': review.remoteAttempts,
              'usedLocalFallback': review.usedLocalFallback,
              'fallbackReason': review.fallbackReason,
              'selectionTrace': review.selectionTrace,
              'usage': review.usage.toJson(),
              'candidateResponseValid': !review.usedLocalFallback,
              'approvedHitCount':
                  selected.where((value) => value['approved'] == true).length,
              'caseCount': cases.length,
              'selections': selected,
            });
          }
          final allValid = runs.every(
            (value) => value['candidateResponseValid'] == true,
          );
          final allApproved = runs.every(
            (value) => value['approvedHitCount'] == cases.length,
          );
          providerReports.add({
            'provider': provider.provider,
            'model': provider.model,
            'candidateReviewProtocol': forceP8Protocol
                ? 'article_split_v3_candidate_path_p8'
                : 'model_default',
            'apiKeyConfigured': true,
            'repeatCount': repeats,
            'jsonAndCandidateValidityRate': runs
                    .where((value) => value['candidateResponseValid'] == true)
                    .length /
                repeats,
            'approvedPathHitRate': runs.fold<int>(
                  0,
                  (sum, value) => sum + (value['approvedHitCount'] as int),
                ) /
                (cases.length * repeats),
            'repeatConsistent': selectionSignatures.toSet().length == 1,
            'passed': allValid &&
                allApproved &&
                selectionSignatures.toSet().length == 1,
            'runs': runs,
          });
          await _writeReport(
            output,
            fixture: fixture,
            modelSha: modelSha,
            parserVersion: document.parserVersion,
            parserHealthy: plan.parserHealthy,
            preflight: preflight,
            providerReports: providerReports,
            budget: budget,
            status: 'remote_tuning_in_progress',
          );
        }
        final passed = providerReports.length == configured.length &&
            providerReports.every((value) => value['passed'] == true);
        await _writeReport(
          output,
          fixture: fixture,
          modelSha: modelSha,
          parserVersion: document.parserVersion,
          parserHealthy: plan.parserHealthy,
          preflight: preflight,
          providerReports: providerReports,
          budget: budget,
          status: passed ? 'passed' : 'failed',
        );
        expect(passed, isTrue);
        expect(budget.settledCny, lessThanOrEqualTo(50));
      } finally {
        AppConfig.resetRuntimeConfigForTest();
        await DatabaseService.resetForTest();
        DatabaseService.setDatabaseDirectoryOverrideForTest(null);
        if (await temp.exists()) await temp.delete(recursive: true);
      }
    },
    skip: enabled ? false : 'set TOMATO_RUN_SENTENCE_V3_AI_TUNING=1',
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

class _ProviderConfigV3 {
  const _ProviderConfigV3({
    required this.provider,
    required this.apiKey,
    required this.model,
  });

  final String provider;
  final String apiKey;
  final String model;
}

class _SavedProviderConfigV3 {
  const _SavedProviderConfigV3({
    required this.aliyunApiKey,
    required this.aliyunModel,
    required this.volcApiKey,
    required this.volcModel,
  });

  final String aliyunApiKey;
  final String aliyunModel;
  final String volcApiKey;
  final String volcModel;

  List<_ProviderConfigV3> get providers => [
        _ProviderConfigV3(
          provider: AppConfig.aiProviderAliyunBailian,
          apiKey: aliyunApiKey,
          model: aliyunModel,
        ),
        _ProviderConfigV3(
          provider: AppConfig.aiProviderVolcengine,
          apiKey: volcApiKey,
          model: volcModel,
        ),
      ];
}

Future<_SavedProviderConfigV3> _readSavedProviderConfig(
  Directory repository,
) async {
  final storedAliyunKey = await AppConfig.aliyunBailianApiKey;
  final storedVolcKey = await AppConfig.volcArkTextApiKey;
  return _SavedProviderConfigV3(
    aliyunApiKey: storedAliyunKey.isNotEmpty
        ? storedAliyunKey
        : _environmentOrSecurityKey(
            environmentNames: const [
              'TOMATO_ALIYUN_BAILIAN_API_KEY',
              'DASHSCOPE_API_KEY',
            ],
            file: File('${repository.path}/security/aliyunbailian.txt'),
          ),
    aliyunModel: await AppConfig.aliyunBailianTextModel,
    volcApiKey: storedVolcKey.isNotEmpty
        ? storedVolcKey
        : _environmentOrSecurityKey(
            environmentNames: const ['TOMATO_VOLC_ARK_API_KEY'],
            file: File('${repository.path}/security/ark.txt'),
            preferLastLine: true,
          ),
    volcModel: await AppConfig.volcArkTextModel,
  );
}

String _environmentOrSecurityKey({
  required List<String> environmentNames,
  required File file,
  bool preferLastLine = false,
}) {
  for (final name in environmentNames) {
    final value = Platform.environment[name]?.trim() ?? '';
    if (value.isNotEmpty) return _stripBearer(value);
  }
  if (!file.existsSync()) return '';
  final lines = file
      .readAsLinesSync()
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('#'))
      .toList(growable: false);
  if (lines.isEmpty) return '';
  return _stripBearer(preferLastLine ? lines.last : lines.first);
}

String _stripBearer(String value) => value
    .trim()
    .replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '')
    .replaceAll('"', '')
    .replaceAll("'", '')
    .trim();

class _TuningCaseV3 {
  const _TuningCaseV3({
    required this.id,
    required this.genre,
    required this.source,
    required this.approvedChunks,
  });

  factory _TuningCaseV3.fromJson(Object? value) {
    final json = Map<String, dynamic>.from(value as Map);
    return _TuningCaseV3(
      id: json['id'] as String,
      genre: json['genre'] as String,
      source: json['source'] as String,
      approvedChunks: (json['approvedChunks'] as List)
          .map(
            (path) => (path as List)
                .map((chunk) => chunk.toString())
                .toList(growable: false),
          )
          .toList(growable: false),
    );
  }

  final String id;
  final String genre;
  final String source;
  final List<List<String>> approvedChunks;
}

List<ReadAloudOriginalDecisionV3> _mapCasesToDecisions(
  List<_TuningCaseV3> cases,
  ReadAloudSplitPlanV3 plan,
) {
  final decisions = <ReadAloudOriginalDecisionV3>[];
  for (final tuningCase in cases) {
    final matches = plan.originals.where(
      (decision) =>
          _normalize(decision.source) == _normalize(tuningCase.source),
    );
    if (matches.length != 1) {
      throw FormatException(
        '调优输入 ${tuningCase.id} 未映射为一个独立正字句：${matches.length}',
      );
    }
    decisions.add(matches.single);
  }
  return decisions;
}

List<Map<String, dynamic>> _candidatePreflight(
  List<_TuningCaseV3> cases,
  List<ReadAloudOriginalDecisionV3> decisions,
) {
  return [
    for (var index = 0; index < cases.length; index += 1)
      {
        'id': cases[index].id,
        'genre': cases[index].genre,
        'source': cases[index].source,
        'requiresAiReview': decisions[index].requiresAiReview,
        'parseCost': decisions[index].parseCost,
        'parseCostPerToken': decisions[index].parseCostPerToken,
        'localPathId': decisions[index].localPathId,
        'approvedPathAvailable': decisions[index].candidatePaths.any(
              (path) => _isApproved(path.segments, cases[index].approvedChunks),
            ),
        'candidatePaths': decisions[index]
            .candidatePaths
            .map(
              (path) => {
                'candidatePathId': path.pathId,
                'stage': path.stage.name,
                'segments': path.segments,
                'wordCounts': path.wordCounts,
                'risk': path.boundaries.fold<int>(
                  0,
                  (sum, boundary) => sum + boundary.risk,
                ),
                'approved': _isApproved(
                  path.segments,
                  cases[index].approvedChunks,
                ),
              },
            )
            .toList(growable: false),
      },
  ];
}

List<Map<String, dynamic>> _selectedCaseResults({
  required List<_TuningCaseV3> cases,
  required List<ReadAloudOriginalDecisionV3> caseDecisions,
  required Map<int, String> selectedPathIds,
}) {
  return [
    for (var index = 0; index < cases.length; index += 1)
      () {
        final decision = caseDecisions[index];
        final selectedId = selectedPathIds[decision.originalIndex]!;
        final path = decision.candidatePaths.firstWhere(
          (candidate) => candidate.pathId == selectedId,
        );
        return <String, dynamic>{
          'id': cases[index].id,
          'genre': cases[index].genre,
          'candidatePathId': selectedId,
          'segments': path.segments,
          'approved': _isApproved(path.segments, cases[index].approvedChunks),
        };
      }(),
  ];
}

bool _isApproved(List<String> actual, List<List<String>> approvedPaths) {
  return approvedPaths.any(
    (expected) => _sameNormalized(actual, expected),
  );
}

bool _sameNormalized(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (_normalize(left[index]) != _normalize(right[index])) return false;
  }
  return true;
}

String _normalize(String value) =>
    value.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

Future<void> _writeReport(
  File output, {
  required Map<String, dynamic> fixture,
  required String modelSha,
  required String parserVersion,
  required bool parserHealthy,
  required List<Map<String, dynamic>> preflight,
  required List<Map<String, dynamic>> providerReports,
  required SentenceSplitTuningBudgetV3 budget,
  required String status,
}) async {
  await output.parent.create(recursive: true);
  await output.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert({
          'schemaVersion': 'sentence_split_live_ai_tuning_v3_1',
          'fixtureVersion': fixture['schemaVersion'],
          'status': status,
          'parserVersion': parserVersion,
          'solverVersion': ReadAloudSplitterV3.solverVersion,
          'modelSha256': modelSha,
          'parserHealthy': parserHealthy,
          'caseCount': preflight.length,
          'approvedCandidateCoverage': preflight.isEmpty
              ? 0
              : preflight
                      .where(
                        (value) => value['approvedPathAvailable'] == true,
                      )
                      .length /
                  preflight.length,
          'candidatePreflight': preflight,
          'providers': providerReports,
          'budget': budget.report(),
        })}\n',
    encoding: utf8,
    flush: true,
  );
}
