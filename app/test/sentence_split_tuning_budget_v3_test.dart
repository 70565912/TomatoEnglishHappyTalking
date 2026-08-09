import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_english_happy_talking/services/sentence_split_tuning_budget_v3.dart';
import 'package:tomato_english_happy_talking/services/text_generation_service.dart';

void main() {
  const turns = [
    TextGenerationTurn(role: 'user', content: 'Choose candidate path v3_o0_8d'),
  ];

  test('uses conservative verified list prices for current China models', () {
    expect(
      TextGenerationService.estimateCostCny(
        provider: 'aliyun_bailian',
        model: 'qwen3.7-max',
        inputTokens: 1000,
        outputTokens: 100,
      ),
      closeTo(0.0156, 0.0000001),
    );
    expect(
      TextGenerationService.estimateCostCny(
        provider: 'volcengine',
        model: 'doubao-seed-2-0-lite-260215',
        inputTokens: 1000,
        outputTokens: 100,
      ),
      closeTo(0.00096, 0.0000001),
    );
    expect(
      TextGenerationService.estimateCostCny(
        provider: 'volcengine',
        model: 'doubao-seed-2-0-pro-260215',
        inputTokens: 1000,
        outputTokens: 100,
      ),
      closeTo(0.0048, 0.0000001),
    );
    expect(
      TextGenerationService.estimateCostCny(
        provider: 'volcengine',
        model: 'deepseek-v4-flash-ga-260731',
        inputTokens: 1000,
        outputTokens: 100,
      ),
      closeTo(0.0012, 0.0000001),
    );
    expect(
      TextGenerationService.estimateCostCny(
        provider: 'volcengine',
        model: 'unknown-model',
        inputTokens: 1,
        outputTokens: 1,
      ),
      isNull,
    );
  });

  test('refuses an unknown price before any paid call', () {
    final budget = SentenceSplitTuningBudgetV3();

    expect(
      () => budget.reserve(
        provider: 'volcengine',
        model: 'unknown-model',
        turns: turns,
        maxOutputTokens: 256,
      ),
      throwsA(isA<SentenceSplitTuningBudgetExceededV3>()),
    );
    expect(budget.report()['remoteCalls'], 0);
    expect(budget.settledCny, 0);
  });

  test('stops before a reservation can cross the hard total', () {
    final budget = SentenceSplitTuningBudgetV3(limitCny: 0.001);
    final reservation = budget.reserve(
      provider: 'volcengine',
      model: 'doubao-seed-2-0-lite-260215',
      turns: turns,
      maxOutputTokens: 100,
    );

    expect(
      () => budget.reserve(
        provider: 'volcengine',
        model: 'doubao-seed-2-0-lite-260215',
        turns: turns,
        maxOutputTokens: 1000,
      ),
      throwsA(isA<SentenceSplitTuningBudgetExceededV3>()),
    );
    reservation.complete(
      const TextGenerationReply(
        text: '{}',
        source: TextGenerationReplySource.remote,
        usage: TextGenerationUsage(
          inputTokens: 50,
          outputTokens: 10,
          totalTokens: 60,
          estimatedCostCny: 0.000066,
        ),
      ),
    );
    expect(budget.settledCny, closeTo(0.000066, 0.0000001));
    expect(budget.report()['remoteCalls'], 1);
  });

  test('failed requests consume their conservative reservation', () {
    final budget = SentenceSplitTuningBudgetV3(limitCny: 1);
    final reservation = budget.reserve(
      provider: 'aliyun_bailian',
      model: 'qwen3.7-max',
      turns: turns,
      maxOutputTokens: 256,
    );
    final reserved = reservation.worstCaseCostCny;

    reservation.fail();

    expect(budget.settledCny, reserved);
    expect(budget.report()['failedCalls'], 1);
    expect(budget.reservedCny, 0);
  });
}
